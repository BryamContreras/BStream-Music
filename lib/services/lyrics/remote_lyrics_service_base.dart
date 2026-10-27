import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../features/music/domain/entities/lyrics_candidate.dart';
import '../../features/music/domain/entities/lyrics_document.dart';
import '../../features/music/domain/entities/lyrics_lookup.dart';
import 'lrclib_transport.dart';
import 'lyrics_document_quality.dart';
import 'lyrics_service.dart';

/// A provider failure is different from a genuine catalogue miss. In
/// particular, HTTP errors must never turn into an "instrumental" result.
class RemoteLyricsHttpException implements Exception {
  const RemoteLyricsHttpException({
    required this.provider,
    required this.statusCode,
    this.retryAfter,
  });

  final String provider;
  final int statusCode;
  final Duration? retryAfter;

  @override
  String toString() => '$provider request failed with HTTP $statusCode.';
}

/// Shared bounded transport/caching for online-only metadata lookups.
/// No lyrics, credentials or catalogue data are written to disk.
abstract class RemoteLyricsServiceBase implements LyricsService {
  RemoteLyricsServiceBase({
    required String userAgent,
    LrclibTransport? transport,
    this.requestTimeout = const Duration(seconds: 7),
    this.cacheTtl = const Duration(minutes: 15),
    this.maxCacheEntries = 24,
    DateTime Function()? clock,
  }) : _userAgent = userAgent.trim(),
       _transport =
           transport ?? IoLrclibTransport(connectionTimeout: requestTimeout),
       _clock = clock ?? DateTime.now {
    if (_userAgent.isEmpty) {
      throw ArgumentError.value(userAgent, 'userAgent', 'Must not be empty.');
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(requestTimeout, 'requestTimeout');
    }
    if (cacheTtl < Duration.zero) {
      throw ArgumentError.value(cacheTtl, 'cacheTtl');
    }
    if (maxCacheEntries <= 0) {
      throw ArgumentError.value(maxCacheEntries, 'maxCacheEntries');
    }
  }

  static const maximumResponseBytes = 2 * 1024 * 1024;
  static const maximumCachedCharacters = 256 * 1024;
  final String _userAgent;
  final LrclibTransport _transport;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  final Duration cacheTtl;
  final int maxCacheEntries;
  final Map<LyricsLookup, _RemoteCacheEntry> _cache = {};
  final _pending = <LyricsLookup, Future<LyricsDocument?>>{};
  int _cachedCharacters = 0;
  DateTime? _rateLimitedUntil;
  bool _disposed = false;

  String get provider;

  Uri requestUri(LyricsLookup lookup);

  /// Provider-specific discovery, capped below regardless of implementation.
  Iterable<Uri> requestUris(LyricsLookup lookup) => [requestUri(lookup)];

  /// An optional PUBLIC alternative endpoint is not an authorization bypass.
  /// The default never retries authentication, rate-limit or server failures.
  bool canTryAfterFailure(RemoteLyricsHttpException error, Uri next) => false;

  Future<LyricsDocument?> parseResponse(String body, LyricsLookup lookup);

  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) {
    if (_disposed) throw StateError('$provider lyrics service is disposed.');
    if (!lookup.isValid) {
      throw ArgumentError.value(lookup, 'lookup', 'Title must not be empty.');
    }
    // Neither public service supports title-only automatic matching safely.
    if (lookup.artist.trim().isEmpty) return Future.value(null);
    final existing = _pending[lookup];
    if (existing != null) return existing;
    final now = _clock();
    _cache.removeWhere((_, entry) {
      final expired = now.difference(entry.createdAt) >= cacheTtl;
      if (expired) _cachedCharacters -= entry.characters;
      return expired;
    });
    final cached = _cache.remove(lookup);
    if (cached != null) {
      _cache[lookup] = cached;
      return Future.value(cached.document);
    }
    if (_rateLimitedUntil case final until? when until.isAfter(now)) {
      return Future.error(
        RemoteLyricsHttpException(
          provider: provider,
          statusCode: 429,
          retryAfter: until.difference(now),
        ),
      );
    }
    if (_pending.length >= maxCacheEntries) {
      return Future.error(StateError('Too many pending $provider lookups.'));
    }
    final operation = _findUncached(lookup);
    _pending[lookup] = operation;
    return operation;
  }

  Future<LyricsDocument?> _findUncached(LyricsLookup lookup) async {
    try {
      final document = await _loadVariants(lookup);
      if (_disposed) throw StateError('$provider lyrics service is disposed.');
      if (cacheTtl > Duration.zero) {
        final characters = _documentCharacters(document);
        if (characters <= maximumCachedCharacters) {
          _cache[lookup] = _RemoteCacheEntry(document, _clock(), characters);
          _cachedCharacters += characters;
          while (_cache.length > maxCacheEntries ||
              _cachedCharacters > maximumCachedCharacters) {
            final removed = _cache.remove(_cache.keys.first)!;
            _cachedCharacters -= removed.characters;
          }
        }
      }
      return document;
    } on SocketException catch (error) {
      throw LyricsConnectionException(error);
    } on HttpException catch (error) {
      throw LyricsConnectionException(error);
    } on TimeoutException catch (error) {
      throw LyricsConnectionException(error);
    } finally {
      _pending.remove(lookup);
    }
  }

  Future<LyricsDocument?> _loadVariants(LyricsLookup lookup) async {
    final elapsed = Stopwatch()..start();
    LyricsDocument? fallback;
    RemoteLyricsHttpException? endpointFailure;
    var receivedResponse = false;
    final requests = requestUris(lookup).toSet().take(3);
    for (final uri in requests) {
      if (_disposed) throw StateError('$provider lyrics service is disposed.');
      if (endpointFailure != null &&
          !canTryAfterFailure(endpointFailure, uri)) {
        continue;
      }
      final remaining = requestTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) break;
      final timeout = elapsed.elapsedMilliseconds == 0
          ? requestTimeout
          : remaining;
      LrclibResponse response;
      try {
        response = await _transport
            .get(
              uri,
              headers: {'Accept': 'application/json', 'User-Agent': _userAgent},
              timeout: timeout,
            )
            .timeout(timeout);
      } on TimeoutException {
        if (fallback != null) return fallback;
        rethrow;
      } on SocketException {
        if (fallback != null) return fallback;
        rethrow;
      } on HttpException {
        if (fallback != null) return fallback;
        rethrow;
      }
      if (_disposed) throw StateError('$provider lyrics service is disposed.');
      LyricsDocument? document;
      if (response.statusCode == 404 || response.statusCode == 204) {
        document = null;
      } else {
        if (response.statusCode != 200) {
          Duration? retryAfter;
          if (response.statusCode == 429) {
            retryAfter = _retryAfter(response.header('retry-after'));
            _rateLimitedUntil = _clock().add(retryAfter);
          }
          final error = RemoteLyricsHttpException(
            provider: provider,
            statusCode: response.statusCode,
            retryAfter: retryAfter,
          );
          // Never fan out after throttling or an unstable server response.
          if (response.statusCode == 429 || response.statusCode >= 500) {
            if (fallback != null) return fallback;
            throw error;
          }
          endpointFailure ??= error;
          continue;
        }
        if (response.body.length > maximumResponseBytes ||
            utf8.encode(response.body).length > maximumResponseBytes) {
          if (fallback != null) return fallback;
          throw const FormatException('Lyrics response exceeds size limit.');
        }
        try {
          document = await parseResponse(response.body, lookup);
        } on FormatException {
          if (fallback != null) return fallback;
          rethrow;
        }
      }
      receivedResponse = true;
      if (_disposed) throw StateError('$provider lyrics service is disposed.');
      if (document != null) {
        if (lyricsTimingQuality(document, lookup) ==
            LyricsTimingQuality.reliable) {
          return document;
        }
        if (fallback == null ||
            lyricsPlainFallbackIsFuller(document, fallback)) {
          fallback = document;
        }
      }
    }
    if (fallback != null || receivedResponse) return fallback;
    if (endpointFailure != null) throw endpointFailure;
    throw TimeoutException('$provider lookup budget exhausted.');
  }

  int _documentCharacters(LyricsDocument? document) {
    if (document == null) return 0;
    return (document.plainLyrics?.length ?? 0) +
        (document.syncedLyrics?.length ?? 0) +
        document.lines.fold(0, (count, line) => count + line.text.length);
  }

  Duration _retryAfter(String? value) {
    final seconds = int.tryParse(value ?? '');
    if (seconds != null) {
      return Duration(seconds: seconds.clamp(1, 300));
    }
    try {
      final until = HttpDate.parse(value ?? '');
      final seconds = until.difference(_clock()).inSeconds.clamp(1, 300);
      return Duration(seconds: seconds);
    } on HttpException {
      return const Duration(seconds: 30);
    }
  }

  @override
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  }) async {
    if (limit <= 0) return const [];
    final document = await findLyrics(lookup);
    if (document == null ||
        (!document.hasPlainLyrics && !document.hasSyncedLyrics)) {
      return const [];
    }
    return [LyricsCandidate(document: document, similarity: 1)];
  }

  @override
  Future<List<LyricsCandidate>> searchLyricsByTitle(
    String title, {
    required LyricsLookup context,
    int limit = 8,
  }) {
    if (title.trim().isEmpty || limit <= 0) return Future.value(const []);
    return findSimilarLyrics(
      LyricsLookup(
        title: title.trim(),
        artist: context.artist,
        album: context.album,
        duration: context.duration,
        sourceId: context.sourceId,
      ),
      limit: limit,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cache.clear();
    _cachedCharacters = 0;
    _pending.clear();
    _transport.close();
  }
}

class _RemoteCacheEntry {
  const _RemoteCacheEntry(this.document, this.createdAt, this.characters);

  final LyricsDocument? document;
  final DateTime createdAt;
  final int characters;
}
