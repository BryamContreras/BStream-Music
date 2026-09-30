import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef ArtworkJsonFetcher = Future<Map<String, dynamic>?> Function(Uri uri);
typedef ArtworkTextFetcher = Future<String?> Function(Uri uri);

class AppleAnimatedArtworkTrack {
  const AppleAnimatedArtworkTrack({
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.preferVertical,
  });

  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final bool preferVertical;

  @override
  bool operator ==(Object other) =>
      other is AppleAnimatedArtworkTrack &&
      title == other.title &&
      artist == other.artist &&
      album == other.album &&
      duration == other.duration &&
      preferVertical == other.preferVertical;

  @override
  int get hashCode =>
      Object.hash(title, artist, album, duration, preferVertical);
}

/// Resolves Apple Music animated artwork without interrupting the still cover.
/// m8tec is tried first; boidu.dev is used when it cannot serve a playable MP4.
class AppleAnimatedArtworkResolver {
  static const _maxVideoDimension = 960;
  static const _targetVideoDimension = 720;
  static const _maxVideoBandwidth = 3000000;

  AppleAnimatedArtworkResolver({
    ArtworkJsonFetcher? fetchJson,
    ArtworkTextFetcher? fetchText,
  }) : _fetchJson = fetchJson ?? _requestJson,
       _fetchText = fetchText ?? _requestText;

  final ArtworkJsonFetcher _fetchJson;
  final ArtworkTextFetcher _fetchText;
  final Map<AppleAnimatedArtworkTrack, _CachedArtwork> _cache = {};
  final Map<AppleAnimatedArtworkTrack, Future<Uri?>> _inFlight = {};

  Future<Uri?> resolve(AppleAnimatedArtworkTrack track) {
    if (track.title.trim().isEmpty || track.artist.trim().isEmpty) {
      return Future.value(null);
    }
    final cached = _cache[track];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      return Future.value(cached.url);
    }
    return _inFlight.putIfAbsent(track, () async {
      Uri? url;
      try {
        url = await _resolveUncached(track);
      } catch (_) {
        // Network, provider or playlist errors never affect audio playback.
      } finally {
        _inFlight.remove(track);
      }
      _cache[track] = _CachedArtwork(
        url,
        DateTime.now().add(
          url == null ? const Duration(minutes: 2) : const Duration(hours: 3),
        ),
      );
      if (_cache.length > 100) _cache.remove(_cache.keys.first);
      return url;
    });
  }

  Future<Uri?> _resolveUncached(AppleAnimatedArtworkTrack track) async {
    final artist = _primaryArtist(track.artist);
    final album = track.album.trim();
    final knownAlbum =
        album.isNotEmpty &&
        !RegExp(
          r'^(youtube music|unknown album|single)$',
          caseSensitive: false,
        ).hasMatch(album);
    if (knownAlbum) {
      try {
        final data = await _fetchJson(
          Uri.https('artwork.m8tec.top', '/api/v1/artwork/search', {
            'artist': artist,
            'album': album,
          }),
        );
        if (data != null &&
            _matches(artist, data['artist']) &&
            _matches(album, data['album'])) {
          final hls =
              _appleUrl(
                track.preferVertical ? data['url_tall'] : data['url'],
                '.m3u8',
              ) ??
              _appleUrl(data['url'], '.m3u8');
          if (hls != null) {
            final mp4 = await _playlistMp4(hls);
            if (mp4 != null) return mp4;
          }
        }
      } catch (_) {
        // Continue with the secondary source.
      }
    }

    try {
      final query = <String, String>{
        's': _cleanTitle(track.title),
        'a': artist,
        if (knownAlbum) 'al': album,
        if (track.duration > Duration.zero) 'd': '${track.duration.inSeconds}',
      };
      final data = await _fetchJson(Uri.https('artwork.boidu.dev', '/', query));
      if (data == null ||
          !_matches(_cleanTitle(track.title), data['name']) ||
          !_matches(artist, data['artist'])) {
        return null;
      }
      final hls =
          _appleUrl(
            track.preferVertical ? data['animatedVertical'] : data['animated'],
            '.m3u8',
          ) ??
          _appleUrl(data['animated'], '.m3u8');
      if (hls != null) {
        final mp4 = await _playlistMp4(hls);
        if (mp4 != null) return mp4;
      }
      return _boundedDirectMp4(
            track.preferVertical ? data['videoUrlVertical'] : data['videoUrl'],
          ) ??
          _boundedDirectMp4(data['videoUrl']);
    } catch (_) {
      return null;
    }
  }

  Future<Uri?> _playlistMp4(
    Uri master, [
    int depth = 0,
    int? selectedDimension,
  ]) async {
    if (depth > 2) return null;
    final text = await _fetchText(master);
    if (text == null || !text.startsWith('#EXTM3U')) return null;
    final lines = text.split(RegExp(r'\r?\n'));
    // A media playlist points to a single fragmented MP4 through EXT-X-MAP.
    if (text.contains('#EXT-X-MAP:')) {
      if (selectedDimension == null && !_isBoundedVideoPath(master.path)) {
        return null;
      }
      final map = RegExp(r'#EXT-X-MAP:URI="([^"]+\.mp4)"').firstMatch(text);
      return map == null
          ? null
          : _appleUrl(master.resolve(map.group(1)!), '.mp4');
    }
    final variants = <(int, Uri)>[];
    for (var i = 0; i < lines.length - 1; i++) {
      final line = lines[i];
      if (!line.startsWith('#EXT-X-STREAM-INF:') ||
          !line.contains('CODECS="avc1.')) {
        continue;
      }
      final dimensions = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
      final width = int.tryParse(dimensions?.group(1) ?? '') ?? 0;
      final height = int.tryParse(dimensions?.group(2) ?? '') ?? 0;
      final longestSide = width > height ? width : height;
      final bandwidth =
          int.tryParse(
            RegExp(r'(?:^|[:,])BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ??
                '',
          ) ??
          0;
      final uri = _appleUrl(master.resolve(lines[i + 1].trim()), '.m3u8');
      if (uri != null &&
          width > 0 &&
          height > 0 &&
          longestSide <= _maxVideoDimension &&
          bandwidth > 0 &&
          bandwidth <= _maxVideoBandwidth) {
        variants.add((longestSide, uri));
      }
    }
    if (variants.isEmpty) return null;
    // Prefer a 720-ish H.264 stream without loading oversized artwork.
    variants.sort(
      (a, b) => (a.$1 - _targetVideoDimension).abs().compareTo(
        (b.$1 - _targetVideoDimension).abs(),
      ),
    );
    return _playlistMp4(variants.first.$2, depth + 1, variants.first.$1);
  }

  static Uri? _boundedDirectMp4(Object? value) {
    final uri = _appleUrl(value, '.mp4');
    return uri != null && _isBoundedVideoPath(uri.path) ? uri : null;
  }

  static bool _isBoundedVideoPath(String path) {
    final dimensions = RegExp(r'_(\d+)x(\d+)(?:-|\.)').firstMatch(path);
    if (dimensions == null) return false;
    final width = int.tryParse(dimensions.group(1)!) ?? 0;
    final height = int.tryParse(dimensions.group(2)!) ?? 0;
    return width >= 240 &&
        height >= 240 &&
        width <= _maxVideoDimension &&
        height <= _maxVideoDimension;
  }

  static Uri? _appleUrl(Object? value, String extension) {
    final uri = value is Uri
        ? value
        : Uri.tryParse(value is String ? value : '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'mvod.itunes.apple.com' ||
        !uri.path.toLowerCase().endsWith(extension)) {
      return null;
    }
    return uri;
  }

  static String _primaryArtist(String artist) => artist
      .split(
        RegExp(r'\s*(?:,|&| feat\.? | ft\.? | x )\s*', caseSensitive: false),
      )
      .first
      .trim();

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
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  static bool _matches(String requested, Object? found) {
    if (found is! String) return false;
    final a = _normal(requested);
    final b = _normal(found);
    return a.isNotEmpty &&
        b.isNotEmpty &&
        (a == b || (a.length >= 6 && b.startsWith('$a ')));
  }

  static Future<Map<String, dynamic>?> _requestJson(Uri uri) async {
    final text = await _requestText(uri);
    if (text == null) return null;
    final data = jsonDecode(text);
    return data is Map<String, dynamic> ? data : null;
  }

  static Future<String?> _requestText(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 5));
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength > 256 * 1024) {
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        bytes.addAll(chunk);
        if (bytes.length > 256 * 1024) return null;
      }
      return utf8.decode(bytes);
    } finally {
      client.close(force: true);
    }
  }
}

class _CachedArtwork {
  const _CachedArtwork(this.url, this.expires);
  final Uri? url;
  final DateTime expires;
}
