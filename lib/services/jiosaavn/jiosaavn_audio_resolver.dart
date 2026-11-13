import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/desede_engine.dart';

import '../../features/music/domain/entities/track_info.dart';
import '../downloader/audio_stream_resolver.dart';
import 'jiosaavn_audio_format_probe.dart';
import 'jiosaavn_http_transport.dart';
import 'jiosaavn_recording_matcher.dart';

/// An optional transport-only lookup. YouTube metadata and logical queue
/// identities stay authoritative regardless of which CDN serves the audio.
class JioSaavnAudioResolver {
  JioSaavnAudioResolver({
    JioSaavnHttpTransport? transport,
    this.cacheDuration = const Duration(minutes: 10),
    this.missCacheDuration = const Duration(minutes: 2),
    this.maximumCacheEntries = 32,
    this.disposeTransport = true,
    DateTime Function()? now,
  }) : _transport = transport ?? IoJioSaavnHttpTransport(),
       _now = now ?? DateTime.now,
       assert(maximumCacheEntries > 0);

  static final _endpoint = Uri.https('www.jiosaavn.com', '/api.php');
  // The catalog uses these compatibility headers in the reference client's
  // requests. Keep them scoped to api.php: they are not playback/CDN headers.
  static const _catalogHeaders = {
    'Accept': 'application/json',
    'Accept-Encoding': 'identity',
    'Accept-Language': 'en',
    'User-Agent': 'Mozilla/5.0',
    'Cookie': 'explicit_content=1',
    'X-Forwarded-For': '49.36.0.1',
    'X-Real-IP': '49.36.0.1',
  };
  static const _matcher = JioSaavnRecordingMatcher();

  final JioSaavnHttpTransport _transport;
  final DateTime Function() _now;
  final Duration cacheDuration;
  final Duration missCacheDuration;
  final int maximumCacheEntries;
  final bool disposeTransport;
  final _cache = <String, _CachedUpgrade>{};
  final _inFlight = <String, _UpgradeFlight>{};
  final _waiting = Queue<Completer<void>>();
  int _activeLookups = 0;
  bool _disposed = false;

  Future<AudioStreamResolution?> findUpgrade(
    TrackInfo track, {
    int? currentBitrate,
    bool Function()? shouldContinue,
  }) async {
    final bitrate = currentBitrate ?? track.streamBitrate;
    final codec = track.streamCodec?.toLowerCase() ?? '';
    if (_disposed ||
        !_continues(shouldContinue) ||
        (bitrate != null && bitrate >= 320000) ||
        codec.startsWith('flac') ||
        codec.startsWith('alac') ||
        codec.startsWith('pcm') ||
        track.duration == null ||
        track.duration! <= Duration.zero) {
      return null;
    }
    final key = jsonEncode([
      track.id,
      track.title,
      track.artist,
      track.artists,
      track.album,
      track.duration!.inSeconds,
    ]);
    final cached = _cache.remove(key);
    if (cached != null && _now().isBefore(cached.expiresAt)) {
      _cache[key] = cached;
      return cached.resolution;
    }
    var flight = _inFlight[key];
    if (flight == null) {
      flight = _UpgradeFlight();
      _inFlight[key] = flight;
      final created = flight;
      created.waiters.add(shouldContinue);
      created.result = _find(track, () => !_disposed && created.isUseful)
          .then((resolution) {
            if (!_disposed && created.isUseful) {
              _cache[key] = _CachedUpgrade(
                resolution,
                resolution?.expiresAt ?? _now().add(missCacheDuration),
              );
              while (_cache.length > maximumCacheEntries) {
                _cache.remove(_cache.keys.first);
              }
            }
            return resolution;
          })
          .whenComplete(() {
            if (identical(_inFlight[key], created)) _inFlight.remove(key);
          });
    } else {
      flight.waiters.add(shouldContinue);
    }
    try {
      final result = await flight.result;
      return !_disposed && _continues(shouldContinue) ? result : null;
    } finally {
      flight.waiters.remove(shouldContinue);
    }
  }

  Future<AudioStreamResolution?> _find(
    TrackInfo track,
    bool Function() current,
  ) async {
    if (_activeLookups >= 2) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _activeLookups++;
    }
    try {
      return current() ? await _lookup(track, current) : null;
    } finally {
      if (_waiting.isEmpty) {
        _activeLookups--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }

  Future<AudioStreamResolution?> _lookup(
    TrackInfo track,
    bool Function() current,
  ) async {
    try {
      final candidates = <String, JioSaavnSong>{};
      for (final query in _matcher.searchQueries(track)) {
        if (!current()) return null;
        final response = await _api({
          '__call': 'search.getResults',
          'q': query,
          'p': '1',
          'n': '10',
        });
        if (!current()) return null;
        final rows = response is Map ? response['results'] : null;
        if (rows is List) {
          for (final row in rows.take(10)) {
            final song = JioSaavnSong.fromJson(row);
            if (song != null && song.supports320) candidates[song.id] = song;
          }
        }
        final ranked = _matcher.rankedMatches(track, candidates.values);
        if (ranked.isEmpty) continue;
        // One selected counterpart, one detail request, one bounded probe. Do
        // not fan out CDN requests across vaguely similar search results.
        final chosen = ranked.first;
        final details = await _api({
          '__call': 'song.getDetails',
          'pids': chosen.id,
        });
        if (!current()) return null;
        final verified = _detailsSong(details, chosen.id);
        if (verified == null ||
            !verified.supports320 ||
            _matcher.rankedMatches(track, [verified]).isEmpty) {
          return null;
        }
        final uri = decodeJioSaavn320Uri(verified.encryptedMediaUrl);
        if (uri == null) return null;
        final expiresAt = _streamExpiry(uri, _now(), cacheDuration);
        if (!expiresAt.isAfter(_now().add(const Duration(seconds: 15)))) {
          return null;
        }
        final probe = await _transport.get(
          uri,
          headers: const {
            'Range': 'bytes=0-4095',
            'Accept-Encoding': 'identity',
            'User-Agent': 'Mozilla/5.0',
          },
          maximumBytes: 4096,
          readPrefix: true,
        );
        final totalBytes = _verifiedProbeLength(probe, verified.duration);
        if (!current() || totalBytes == null) return null;
        final format = await probeJioSaavnAudioFormat(
          uri,
          transport: _transport,
          prefix: probe,
          fileLength: totalBytes,
          shouldContinue: current,
        );
        if (!current()) return null;
        return AudioStreamResolution(
          source: AudioStreamSource.jioSaavn,
          streamUrl: uri.toString(),
          streamExtension: 'm4a',
          streamMimeType: 'audio/mp4',
          codec: format?.codec ?? 'aac',
          bitrate: format?.bitrate ?? 320000,
          sampleRate: format?.sampleRate,
          channels: format?.channels,
          formatId: 'jiosaavn:${verified.id}:320',
          httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
          expiresAt: expiresAt,
        );
      }
    } on Object {
      // An optional source cannot interrupt an already-playing YouTube track.
    }
    return null;
  }

  Future<Object?> _api(Map<String, String> parameters) async {
    final response = await _transport.get(
      _endpoint.replace(
        queryParameters: {
          '_format': 'json',
          '_marker': '0',
          'api_version': '4',
          'ctx': 'android',
          ...parameters,
        },
      ),
      headers: _catalogHeaders,
    );
    if (response.statusCode != 200) {
      throw const FormatException('JioSaavn API unavailable');
    }
    // The public API currently labels JSON responses text/html. Parse the
    // bounded response itself instead of relying on that inconsistent header.
    return jsonDecode(utf8.decode(response.body));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cache.clear();
    if (disposeTransport) await _transport.close();
  }
}

JioSaavnSong? _detailsSong(Object? json, String expectedId) {
  if (json is! Map) return null;
  final direct = JioSaavnSong.fromJson(json[expectedId]);
  if (direct != null && direct.id == expectedId) return direct;
  final songs = json['songs'];
  if (songs is List) {
    for (final row in songs.take(10)) {
      final song = JioSaavnSong.fromJson(row);
      if (song?.id == expectedId) return song;
    }
  }
  return null;
}

/// Decodes the catalog's public URL-obfuscation format. Only its explicitly
/// offered 320 rendition is requested, on the catalog's own HTTPS CDN.
Uri? decodeJioSaavn320Uri(String? encoded) {
  if (encoded == null || encoded.length > 8192) return null;
  try {
    final input = base64.decode(encoded);
    if (input.isEmpty || input.length % 8 != 0) return null;
    // Triple DES EDE with three identical component keys equals DES. Import
    // only this maintained primitive, avoiding the package's full registry.
    final key = ascii.encode('38346591');
    final cipher = DESedeEngine()
      ..init(false, KeyParameter(Uint8List.fromList([...key, ...key, ...key])));
    final output = Uint8List(input.length);
    for (var offset = 0; offset < input.length; offset += 8) {
      cipher.processBlock(input, offset, output, offset);
    }
    final padding = output.last;
    if (padding < 1 || padding > 8 || padding > output.length) return null;
    for (var index = output.length - padding; index < output.length; index++) {
      if (output[index] != padding) return null;
    }
    final decoded = utf8
        .decode(output.sublist(0, output.length - padding))
        .trim();
    final uri = Uri.tryParse(decoded);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !_isSaavnCdn(uri.host)) {
      return null;
    }
    final rendition = RegExp(r'_(48|96|160|320)\.mp4$', caseSensitive: false);
    if (!rendition.hasMatch(uri.path)) return null;
    return uri.replace(
      scheme: 'https',
      path: uri.path.replaceFirst(rendition, '_320.mp4'),
    );
  } on Object {
    return null;
  }
}

bool _isSaavnCdn(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'saavncdn.com' || normalized.endsWith('.saavncdn.com');
}

DateTime _streamExpiry(Uri uri, DateTime now, Duration maximumAge) {
  var expiresAt = now.add(maximumAge);
  for (final name in const ['expire', 'expires', 'exp', 'Expires']) {
    final value = int.tryParse(uri.queryParameters[name] ?? '');
    if (value == null || value < 1000000000 || value > 9999999999999) continue;
    final candidate = DateTime.fromMillisecondsSinceEpoch(
      value < 100000000000 ? value * 1000 : value,
    );
    if (candidate.isBefore(expiresAt)) expiresAt = candidate;
  }
  return expiresAt;
}

int? _verifiedProbeLength(JioSaavnHttpResponse response, Duration duration) {
  if ((response.statusCode != 200 && response.statusCode != 206) ||
      response.body.length < 12 ||
      ascii.decode(response.body.sublist(4, 8), allowInvalid: true) != 'ftyp') {
    return null;
  }
  final contentRange = response.headers['content-range'];
  final range = contentRange == null
      ? null
      : RegExp(r'^bytes 0-[0-9]+/([0-9]+)$').firstMatch(contentRange.trim());
  final total = response.statusCode == 206
      ? int.tryParse(range?.group(1) ?? '')
      : int.tryParse(response.headers['content-length'] ?? '');
  if (total == null || total <= 0) return null;
  // A valid MP4 URL alone is not evidence of 320 kbps. Reject shortened
  // previews or lower-bitrate objects served under an unexpected CDN alias.
  final estimatedBitrate = total * 8000 ~/ duration.inMilliseconds;
  return estimatedBitrate >= 256000 ? total : null;
}

bool _continues(bool Function()? callback) {
  try {
    return callback?.call() ?? true;
  } on Object {
    return false;
  }
}

class _CachedUpgrade {
  const _CachedUpgrade(this.resolution, this.expiresAt);
  final AudioStreamResolution? resolution;
  final DateTime expiresAt;
}

class _UpgradeFlight {
  final waiters = <bool Function()?>[];
  late Future<AudioStreamResolution?> result;

  bool get isUseful => waiters.any(_continues);
}
