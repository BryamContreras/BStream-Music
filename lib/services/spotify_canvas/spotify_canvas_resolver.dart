import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  Future<Uri?> resolve(SpotifyCanvasTrack track) {
    if (track.title.trim().isEmpty || track.artist.trim().isEmpty) {
      return Future.value(null);
    }
    final cached = _cache[track];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      return Future.value(cached.url);
    }
    return _inFlight.putIfAbsent(track, () async {
      Uri? url;
      var transientFailure = false;
      try {
        url = await _resolveUncached(track);
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
    final queryTitle = _cleanTitle(track.title);
    if (queryTitle.isEmpty) return null;
    final search = await _fetchJson(
      Uri.https('www.spotycovs.lol', '/api/search', {'track': queryTitle}),
    );
    final results = search?['results'];
    if (results is! List) return null;
    String? spotifyId;
    for (final result in results) {
      if (result is! Map) continue;
      final name = result['name'];
      final artists = result['artistNames'];
      final id = result['trackId'];
      if (name is! String || artists is! List || id is! String) continue;
      if (!_sameTitle(queryTitle, name) ||
          !_sameArtist(track.artist, artists)) {
        continue;
      }
      final durationMs = result['durationMs'];
      if (track.duration > Duration.zero &&
          durationMs is num &&
          (track.duration.inMilliseconds - durationMs).abs() > 15000) {
        continue;
      }
      if (!RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(id)) continue;
      spotifyId = id;
      break;
    }
    if (spotifyId == null) return null;
    final canvas = await _fetchJson(
      Uri.https('www.spotycovs.lol', '/api/canvas', {'id': spotifyId}),
    );
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

  static String _cleanTitle(String title) => title
      .replaceAll(
        RegExp(
          r'\s*[\[(]\s*(?:official\s+)?(?:music\s+)?(?:video|audio|lyrics?|visualizer)\s*[\])]',
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  static String _normal(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[áàäâ]'), 'a')
      .replaceAll(RegExp(r'[éèëê]'), 'e')
      .replaceAll(RegExp(r'[íìïî]'), 'i')
      .replaceAll(RegExp(r'[óòöô]'), 'o')
      .replaceAll(RegExp(r'[úùüû]'), 'u')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  static bool _sameTitle(String requested, String found) =>
      _normal(_cleanTitle(requested)) == _normal(_cleanTitle(found));

  static bool _sameArtist(String requested, List<dynamic> found) {
    final primary = requested
        .split(
          RegExp(r'\s*(?:,|&| feat\.? | ft\.? | x )\s*', caseSensitive: false),
        )
        .first;
    final normalized = _normal(primary);
    return normalized.isNotEmpty &&
        found.any(
          (artist) => artist is String && _normal(artist) == normalized,
        );
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
      if (response.statusCode == HttpStatus.tooManyRequests ||
          response.statusCode >= HttpStatus.internalServerError) {
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

class _CachedCanvas {
  const _CachedCanvas(this.url, this.expires);

  final Uri? url;
  final DateTime expires;
}
