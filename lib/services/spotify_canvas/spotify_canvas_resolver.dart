import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../visual_track_identity.dart';

/// Canvas is not available in Spotify's public Web API. This optional lookup
/// uses a public third-party endpoint; failure must never affect playback.
typedef CanvasJsonFetcher = Future<Map<String, dynamic>?> Function(Uri uri);
typedef CanvasMediaSizeProbe = Future<int?> Function(Uri uri);

class SpotifyCanvasTrack {
  const SpotifyCanvasTrack(this.title, this.artist, this.duration);

  final String title;
  final String artist;
  final Duration duration;

  @override
  bool operator ==(Object other) =>
      other is SpotifyCanvasTrack &&
      title == other.title &&
      artist == other.artist &&
      duration == other.duration;

  @override
  int get hashCode => Object.hash(title, artist, duration);
}

class SpotifyCanvasResolver {
  SpotifyCanvasResolver({
    CanvasJsonFetcher? fetchJson,
    CanvasMediaSizeProbe? probeMediaSize,
  }) : _fetchJson = fetchJson ?? _requestJson,
       _probeMediaSize = probeMediaSize ?? _requestMediaSize;

  static const maxCanvasBytes = 10 * 1024 * 1024;

  final CanvasJsonFetcher _fetchJson;
  final CanvasMediaSizeProbe _probeMediaSize;
  final Map<SpotifyCanvasTrack, _CachedCanvas> _cache = {};
  final Map<SpotifyCanvasTrack, Future<Uri?>> _inFlight = {};
  DateTime? _cooldownUntil;

  Future<Uri?> resolve(SpotifyCanvasTrack track) {
    if (track.title.trim().isEmpty || track.artist.trim().isEmpty) {
      return Future.value(null);
    }
    final cached = _cache[track];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      return Future.value(cached.url);
    }
    if (_cooldownUntil?.isAfter(DateTime.now()) == true) {
      return Future.value(null);
    }
    return _inFlight.putIfAbsent(track, () async {
      Uri? url;
      var transientFailure = false;
      try {
        url = await _resolveUncached(track);
      } on _CanvasThrottled {
        _cooldownUntil = DateTime.now().add(const Duration(seconds: 60));
        transientFailure = true;
      } catch (_) {
        // Offline, rate limited, or provider changed: retain album artwork.
        transientFailure = true;
      } finally {
        _inFlight.remove(track);
      }
      _cache[track] = _CachedCanvas(
        url,
        DateTime.now().add(
          transientFailure
              ? const Duration(seconds: 30)
              : url == null
              ? const Duration(minutes: 5)
              : const Duration(hours: 3),
        ),
      );
      if (_cache.length > 100) _cache.remove(_cache.keys.first);
      return url;
    });
  }

  Future<Uri?> _resolveUncached(SpotifyCanvasTrack track) async {
    final queryTitle = cleanVisualTrackTitle(track.title);
    if (queryTitle.isEmpty) return null;
    final artist = primaryVisualArtist(track.artist);
    final fullArtist = track.artist
        .trim()
        .replaceFirst(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '')
        .trim();
    final ids = <String>[];
    final queries = <String>[queryTitle, '$artist - $queryTitle'];
    for (final query in queries.toSet()) {
      final search = await _fetchJson(
        Uri.https('www.spotycovs.lol', '/api/search', {'track': query}),
      );
      _checkThrottle(search);
      final results = search?['results'];
      if (results is! List) continue;
      for (final result in results) {
        if (result is! Map) continue;
        final name = result['name'];
        final artists = result['artistNames'];
        final id = result['trackId'];
        if (name is! String || artists is! List || id is! String) continue;
        if (!sameVisualTitle(queryTitle, name) || artists.isEmpty) {
          continue;
        }
        final primaryMatch =
            artists.first is String &&
            sameVisualArtist(track.artist, artists.first as String);
        final collaboratorMatch =
            !primaryMatch &&
            artists
                .skip(1)
                .any(
                  (value) =>
                      value is String && sameVisualArtist(track.artist, value),
                );
        if (!primaryMatch && !collaboratorMatch) continue;
        final durationMs = result['durationMs'];
        final visualVideo =
            cleanVisualTrackTitle(track.title) != track.title.trim();
        final tolerance = visualVideo ? 60000 : 15000;
        // A secondary credit alone is ambiguous without a matching duration.
        if (collaboratorMatch &&
            (track.duration <= Duration.zero || durationMs is! num)) {
          continue;
        }
        if (track.duration > Duration.zero &&
            durationMs is num &&
            (track.duration.inMilliseconds - durationMs).abs() > tolerance) {
          continue;
        }
        if (!RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(id)) continue;
        if (!ids.contains(id)) ids.add(id);
        if (ids.length == 2) break;
      }
      // A verified title/artist already identifies the releases to inspect.
      // A second search here usually repeats the same IDs and costs a rate-
      // limited request even when Spotify has no Canvas for the song.
      if (ids.isNotEmpty) break;
    }
    for (final spotifyId in ids) {
      final canvas = await _fetchJson(
        Uri.https('www.spotycovs.lol', '/api/canvas', {'id': spotifyId}),
      );
      _checkThrottle(canvas);
      final url = await _videoFromCanvasPayload(canvas);
      if (url != null) return url;
    }

    // The provider's short /api/search list can omit a popular studio track
    // entirely (for example, returning only a live "vampire" rendition).
    // Its own best-match endpoint searches the full catalog. Accept it only
    // when the returned resolution explicitly confirms title and artist.
    // Keep a band's full name ("Polo & Pan") in the query. Splitting on '&'
    // alone cannot distinguish a band from a collaboration.
    final directArtists = <String>[fullArtist];
    if (normalVisualText(fullArtist) != normalVisualText(artist) &&
        RegExp(
          r'\s+(?:feat\.?|ft\.?|featuring|x)\s+',
          caseSensitive: false,
        ).hasMatch(fullArtist)) {
      directArtists.add(artist);
    }
    for (final queryArtist in directArtists) {
      final direct = await _fetchJson(
        Uri.https('www.spotycovs.lol', '/api/canvas', {
          'track': '$queryTitle $queryArtist',
        }),
      );
      _checkThrottle(direct);
      final resolution = direct?['resolution'];
      final resolvedId = direct?['trackId'];
      if (resolution is! Map ||
          resolvedId is! String ||
          !RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(resolvedId) ||
          resolution['matchedTrack'] is! String ||
          resolution['matchedArtist'] is! String ||
          !sameVisualTitle(queryTitle, resolution['matchedTrack'] as String) ||
          normalVisualText(resolution['matchedArtist'] as String) !=
              normalVisualText(queryArtist)) {
        continue;
      }
      final url = await _videoFromCanvasPayload(direct);
      if (url != null) return url;
    }
    return null;
  }

  Future<Uri?> _videoFromCanvasPayload(Map<String, dynamic>? canvas) async {
    final canvases = canvas?['canvases'];
    if (canvas?['hasCanvas'] != true || canvases is! List) return null;
    for (final item in canvases) {
      if (item is! Map || item['type'] != 'VIDEO') continue;
      final rawUrl = item['canvasUrl'];
      if (rawUrl is! String) continue;
      final url = Uri.tryParse(rawUrl);
      if (url != null &&
          url.scheme == 'https' &&
          url.host == 'canvaz.scdn.co' &&
          url.path.endsWith('.mp4')) {
        final bytes = await _probeMediaSize(url);
        if (bytes != null && bytes > 0 && bytes <= maxCanvasBytes) {
          return url;
        }
      }
    }
    return null;
  }

  static void _checkThrottle(Map<String, dynamic>? response) {
    final code = response?['code'] ?? response?['error'];
    if (code is String &&
        (code.contains('cooldown') || code.contains('rate_limit'))) {
      throw const _CanvasThrottled();
    }
  }

  static Future<Map<String, dynamic>?> _requestJson(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode == HttpStatus.tooManyRequests) {
        throw const _CanvasThrottled();
      }
      if (response.statusCode >= HttpStatus.internalServerError) {
        throw HttpException('Canvas service temporarily unavailable');
      }
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength > 256 * 1024) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        bytes.addAll(chunk);
        if (bytes.length > 256 * 1024) {
          return null;
        }
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<int?> _requestMediaSize(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      return await (() async {
        final request = await client.headUrl(uri);
        final response = await request.close();
        return response.statusCode == HttpStatus.ok &&
                response.contentLength > 0
            ? response.contentLength
            : null;
      })().timeout(const Duration(seconds: 4));
    } finally {
      client.close(force: true);
    }
  }
}

class _CanvasThrottled implements Exception {
  const _CanvasThrottled();
}

class _CachedCanvas {
  const _CachedCanvas(this.url, this.expires);

  final Uri? url;
  final DateTime expires;
}
