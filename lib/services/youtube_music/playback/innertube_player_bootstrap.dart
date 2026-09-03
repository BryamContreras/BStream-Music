import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../innertube_transport.dart';
import 'ejs_solver.dart';

enum InnerTubePlayerBootstrapPage { web, embedded, music, mobile, tv }

/// Session/player values extracted from one YouTube watch-page generation.
final class InnerTubePlayerBootstrap {
  const InnerTubePlayerBootstrap({
    required this.playerUrl,
    required this.visitorData,
    required this.signatureTimestamp,
    required this.encryptedHostFlags,
    this.clientVersion,
    this.clientName,
    this.clientId,
    this.embeddedPlayerEncryptedContext,
  });

  final Uri? playerUrl;
  final String? visitorData;
  final int? signatureTimestamp;
  final String? encryptedHostFlags;
  final String? clientVersion;
  final String? clientName;
  final int? clientId;
  final String? embeddedPlayerEncryptedContext;
}

abstract interface class InnerTubePlayerBootstrapSource {
  Future<InnerTubePlayerBootstrap> load(
    String videoId, {
    bool forceRefresh = false,
    bool embedded = false,
    InnerTubePlayerBootstrapPage? page,
    String? userAgent,
  });

  void invalidate();
}

/// Loads and caches the small set of dynamic values needed by `/player`.
///
/// The HTML is parsed as data; page JavaScript is never evaluated. Player
/// script URLs are restricted to YouTube HTTPS before they leave this layer.
/// Keeping visitor identity, player URL and STS in one snapshot avoids mixing
/// values from unrelated player generations.
final class InnerTubePlayerBootstrapper
    implements InnerTubePlayerBootstrapSource {
  InnerTubePlayerBootstrapper({
    required InnerTubeTransport transport,
    this.requestTimeout = const Duration(seconds: 12),
    this.cacheTtl = const Duration(minutes: 30),
    this.language = 'en',
    this.region = 'US',
    DateTime Function()? clock,
  }) : // Keep the public parameter free of the private-field underscore.
       // ignore: prefer_initializing_formals
       _transport = transport,
       _clock = clock ?? DateTime.now {
    if (requestTimeout <= Duration.zero || cacheTtl <= Duration.zero) {
      throw ArgumentError('Bootstrap timeouts must be positive.');
    }
  }

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/140.0.0.0 Safari/537.36';

  final InnerTubeTransport _transport;
  final DateTime Function() _clock;
  final Duration requestTimeout;
  final Duration cacheTtl;
  final String language;
  final String region;

  final Map<
    (String, InnerTubePlayerBootstrapPage, String),
    _BootstrapCacheEntry
  >
  _cache = {};
  final Map<
    (String, InnerTubePlayerBootstrapPage, String),
    Future<InnerTubePlayerBootstrap>
  >
  _inFlight = {};
  var _generation = 0;

  @override
  Future<InnerTubePlayerBootstrap> load(
    String videoId, {
    bool forceRefresh = false,
    bool embedded = false,
    InnerTubePlayerBootstrapPage? page,
    String? userAgent,
  }) {
    final effectivePage =
        page ??
        (embedded
            ? InnerTubePlayerBootstrapPage.embedded
            : InnerTubePlayerBootstrapPage.web);
    final effectiveUserAgent = userAgent?.trim().isNotEmpty == true
        ? userAgent!.trim()
        : InnerTubePlayerBootstrapper.userAgent;
    final key = (videoId, effectivePage, effectiveUserAgent);
    if (!forceRefresh) {
      final cached = _cache[key];
      final expiresAt = cached?.expiresAt;
      if (cached != null && expiresAt != null && _clock().isBefore(expiresAt)) {
        return Future<InnerTubePlayerBootstrap>.value(cached.value);
      }
      final pending = _inFlight[key];
      if (pending != null) return pending;
    }

    final generation = _generation;
    final next = _load(
      videoId,
      page: effectivePage,
      userAgent: effectiveUserAgent,
    );
    _inFlight[key] = next;
    unawaited(
      next.then<void>(
        (value) {
          if (generation == _generation && identical(_inFlight[key], next)) {
            _inFlight.remove(key);
            _cache.remove(key);
            _cache[key] = _BootstrapCacheEntry(value, _clock().add(cacheTtl));
            while (_cache.length > 8) {
              _cache.remove(_cache.keys.first);
            }
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_inFlight[key], next)) _inFlight.remove(key);
        },
      ),
    );
    return next;
  }

  Future<InnerTubePlayerBootstrap> _load(
    String videoId, {
    required InnerTubePlayerBootstrapPage page,
    required String userAgent,
  }) async {
    final uri = switch (page) {
      InnerTubePlayerBootstrapPage.embedded => Uri.https(
        'www.youtube.com',
        '/embed/$videoId',
        <String, String>{'html5': '1', 'hl': language, 'gl': region},
      ),
      InnerTubePlayerBootstrapPage.music => _watchUri(
        'music.youtube.com',
        videoId,
      ),
      InnerTubePlayerBootstrapPage.mobile => _watchUri(
        'm.youtube.com',
        videoId,
      ),
      InnerTubePlayerBootstrapPage.tv => Uri.https(
        'www.youtube.com',
        '/tv',
        <String, String>{'hl': language, 'gl': region},
      ),
      InnerTubePlayerBootstrapPage.web => _watchUri('www.youtube.com', videoId),
    };
    final embeddedPage = page == InnerTubePlayerBootstrapPage.embedded;
    final response = await _transport.get(
      uri,
      headers: <String, String>{
        HttpHeaders.acceptHeader: 'text/html,application/xhtml+xml',
        HttpHeaders.userAgentHeader: userAgent,
        if (embeddedPage) HttpHeaders.refererHeader: 'https://www.reddit.com/',
      },
      timeout: requestTimeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw InnerTubePlayerBootstrapException(
        'The YouTube watch page returned HTTP ${response.statusCode}.',
      );
    }
    final effectiveUri = response.effectiveUri;
    if (effectiveUri != null && !isTrustedYouTubeUri(effectiveUri)) {
      throw const InnerTubePlayerBootstrapException(
        'The YouTube watch page redirected to an untrusted origin.',
      );
    }
    return InnerTubePlayerBootstrapParser.parse(response.body);
  }

  Uri _watchUri(String host, String videoId) =>
      Uri.https(host, '/watch', <String, String>{
        'v': videoId,
        'bpctr': '9999999999',
        'has_verified': '1',
        'hl': language,
        'gl': region,
      });

  @override
  void invalidate() {
    _generation += 1;
    _cache.clear();
    _inFlight.clear();
  }
}

final class _BootstrapCacheEntry {
  const _BootstrapCacheEntry(this.value, this.expiresAt);

  final InnerTubePlayerBootstrap value;
  final DateTime expiresAt;
}

abstract final class InnerTubePlayerBootstrapParser {
  static InnerTubePlayerBootstrap parse(String html) {
    final innerTubeContext = _objectAfterKey(html, 'INNERTUBE_CONTEXT');
    final client = innerTubeContext?['client'];
    final clientMap = client is Map ? client : null;
    final encodedPlayerPath = _firstString(html, const <String>[
      'jsUrl',
      'PLAYER_JS_URL',
    ]);
    Uri? playerUrl;
    if (encodedPlayerPath != null) {
      final candidate = Uri.parse(
        'https://www.youtube.com/',
      ).resolve(encodedPlayerPath);
      if (!isTrustedYouTubePlayerUri(candidate)) {
        throw const InnerTubePlayerBootstrapException(
          'The watch page exposed an untrusted player URL.',
        );
      }
      playerUrl = candidate;
    } else {
      final scriptPath = RegExp(
        r'''<script[^>]+src=["']([^"']+/base\.js)["']''',
        caseSensitive: false,
      ).firstMatch(html)?.group(1);
      if (scriptPath != null) {
        final candidate = Uri.parse(
          'https://www.youtube.com/',
        ).resolve(scriptPath.replaceAll(r'\/', '/'));
        if (!isTrustedYouTubePlayerUri(candidate)) {
          throw const InnerTubePlayerBootstrapException(
            'The watch page exposed an untrusted player URL.',
          );
        }
        playerUrl = candidate;
      }
    }

    final signatureTimestamp = int.tryParse(
      RegExp(
            r'"(?:STS|signatureTimestamp)"\s*:\s*([0-9]{5})',
          ).firstMatch(html)?.group(1) ??
          '',
    );
    return InnerTubePlayerBootstrap(
      playerUrl: playerUrl,
      visitorData: _firstString(html, const <String>[
        'VISITOR_DATA',
        'visitorData',
      ]),
      signatureTimestamp: signatureTimestamp,
      encryptedHostFlags: _firstString(html, const <String>[
        'encryptedHostFlags',
      ]),
      clientVersion:
          _firstString(html, const <String>[
            'INNERTUBE_CONTEXT_CLIENT_VERSION',
          ]) ??
          _nonEmptyString(clientMap?['clientVersion']),
      clientName: _nonEmptyString(clientMap?['clientName']),
      clientId: _intValue(
        _firstNumber(html, 'INNERTUBE_CONTEXT_CLIENT_NAME') ??
            clientMap?['clientNameId'],
      ),
      embeddedPlayerEncryptedContext: _firstString(html, const <String>[
        'embeddedPlayerEncryptedContext',
      ]),
    );
  }

  static String? _firstString(String html, List<String> keys) {
    for (final key in keys) {
      final encoded = RegExp(
        '"${RegExp.escape(key)}"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"',
      ).firstMatch(html)?.group(1);
      if (encoded == null) continue;
      try {
        final decoded = jsonDecode('"$encoded"');
        if (decoded is String &&
            decoded.trim().isNotEmpty &&
            decoded.length <= 4096) {
          return decoded.trim();
        }
      } on FormatException {
        // Ignore malformed page fragments and continue to the next key.
      }
    }
    return null;
  }

  static Object? _firstNumber(String html, String key) {
    final raw = RegExp(
      '"${RegExp.escape(key)}"\\s*:\\s*([0-9]+)',
    ).firstMatch(html)?.group(1);
    return raw == null ? null : int.tryParse(raw);
  }

  static String? _nonEmptyString(Object? value) {
    final text = value is String ? value.trim() : '';
    return text.isEmpty || text.length > 4096 ? null : text;
  }

  static int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static Map<String, Object?>? _objectAfterKey(String html, String key) {
    final match = RegExp('"${RegExp.escape(key)}"\\s*:').firstMatch(html);
    if (match == null) return null;
    var start = match.end;
    while (start < html.length && _isWhitespace(html.codeUnitAt(start))) {
      start += 1;
    }
    if (start >= html.length || html.codeUnitAt(start) != 0x7b) return null;
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (var index = start; index < html.length; index += 1) {
      final unit = html.codeUnitAt(index);
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (unit == 0x5c) {
          escaped = true;
        } else if (unit == 0x22) {
          quoted = false;
        }
        continue;
      }
      if (unit == 0x22) {
        quoted = true;
      } else if (unit == 0x7b) {
        depth += 1;
      } else if (unit == 0x7d && --depth == 0) {
        final encoded = html.substring(start, index + 1);
        if (encoded.length > 256 * 1024) return null;
        try {
          final decoded = jsonDecode(encoded);
          return decoded is Map ? Map<String, Object?>.from(decoded) : null;
        } on FormatException {
          return null;
        }
      }
    }
    return null;
  }

  static bool _isWhitespace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d;
}

final class InnerTubePlayerBootstrapException implements Exception {
  const InnerTubePlayerBootstrapException(this.message);

  final String message;

  @override
  String toString() => 'InnerTubePlayerBootstrapException: $message';
}
