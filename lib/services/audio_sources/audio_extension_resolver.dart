import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/constants/app_constants.dart';
import '../../features/music/domain/entities/track_info.dart';
import '../downloader/audio_stream_resolver.dart';
import '../jiosaavn/jiosaavn_recording_matcher.dart';
import 'audio_extension.dart';
import 'audio_source_policy.dart';
import 'bounded_audio_http_transport.dart';
import 'flac_stream_info.dart';
import 'monochrome_audio_source.dart';

enum AudioExtensionError {
  invalidUrl,
  unavailable,
  unsupported,
  restricted,
  officialClientOnly,
  outputRequired,
  moduleIndex,
  noAvailableSources,
}

class AudioExtensionException implements Exception {
  const AudioExtensionException(this.reason);

  final AudioExtensionError reason;
}

class _AudioExtensionModuleIndex extends AudioExtensionException {
  const _AudioExtensionModuleIndex(
    this.uri,
    this.id,
    this.entries,
    this.allowDownloads,
  ) : super(AudioExtensionError.moduleIndex);

  final Uri uri;
  final String id;
  final List<Object?> entries;
  final bool allowDownloads;
}

/// A client for declarative HTTP source manifests. These sources supply audio
/// for a known catalog recording and cannot replace its identity or metadata.
class AudioExtensionResolver {
  AudioExtensionResolver({
    HttpClient? client,
    BoundedAudioHttpTransport? transport,
    DateTime Function()? now,
  }) : _transport = transport ?? IoBoundedAudioHttpTransport(client: client),
       _now = now ?? DateTime.now;

  static const _matcher = JioSaavnRecordingMatcher();
  static const _appUserAgent = 'BStream-Music/${AppConstants.appVersion}';
  static const _jsonHeaders = {
    'Accept': 'application/json',
    'Accept-Encoding': 'identity',
    'User-Agent': _appUserAgent,
  };
  static const _manifestTimeout = Duration(milliseconds: 2500);
  static const _searchTimeout = Duration(seconds: 5);
  static const _streamTimeout = Duration(seconds: 4);
  static const _mediaProbeTimeout = Duration(milliseconds: 2500);
  static const _lookupTimeout = Duration(seconds: 8);
  static const _manifestTtl = Duration(minutes: 10);

  final BoundedAudioHttpTransport _transport;
  final DateTime Function() _now;
  final _manifests = <Uri, ({_Manifest manifest, DateTime expiresAt})>{};
  final _pendingManifests = <Uri, Future<_Manifest>>{};
  bool _disposed = false;

  Future<AudioExtension> load(String url) async {
    final parsed = audioExtensionHttpsUri(url);
    if (parsed == null) {
      throw const AudioExtensionException(AudioExtensionError.invalidUrl);
    }
    final segments = parsed.pathSegments;
    final uri =
        segments.isNotEmpty && segments.last.toLowerCase().endsWith('.json,')
        ? _withPath(parsed, [
            ...segments.take(segments.length - 1),
            segments.last.substring(0, segments.last.length - 1),
          ])
        : parsed;
    final path = uri.path.toLowerCase();
    if (uri.origin == 'https://tracks.monochrome.st' &&
        (path.isEmpty || path == '/')) {
      return AudioExtension(
        id: 'monochrome',
        name: 'Monochrome',
        manifestUri: uri,
        protocol: AudioExtensionProtocol.monochrome,
      );
    }
    if (const [
      '.sflx',
      '.spotiflac-ext',
      '.mornye-ext',
      '.js',
    ].any(path.endsWith)) {
      throw const AudioExtensionException(AudioExtensionError.unsupported);
    }
    if (path.endsWith('.json')) {
      return (await _manifest(uri, refresh: true)).extension;
    }
    final manifestUri = _withPath(uri, [
      ..._baseSegments(uri),
      'manifest.json',
    ]);
    try {
      return (await _manifest(manifestUri, refresh: true)).extension;
    } on AudioExtensionException catch (error) {
      if (error.reason != AudioExtensionError.unsupported) rethrow;
      return (await _manifest(uri, refresh: true)).extension;
    }
  }

  /// Imports a standalone add-on or the HTTP services described by a catalog.
  Future<List<AudioExtension>> loadSources(String url) async {
    try {
      return [await load(url)];
    } on _AudioExtensionModuleIndex catch (catalog) {
      return _loadCatalogSources(catalog);
    }
  }

  Future<List<AudioExtension>> _loadCatalogSources(
    _AudioExtensionModuleIndex catalog,
  ) async {
    // WioLand publishes the source descriptors used to generate its modules
    // in a sibling JSON file. Read the HTTP URLs from those descriptors.
    if (!const {
      'art.wiochord.lossless',
      'art.wiojelt.bitchord.modules',
    }.contains(catalog.id)) {
      throw catalog;
    }
    final entries = <String, String>{
      for (final entry in catalog.entries.whereType<Map>())
        if (entry['type'] == 'MODULE' &&
            entry['id'] is String &&
            entry['download'] is String)
          entry['id'] as String: entry['download'] as String,
    };
    final descriptorsUri = _withPath(catalog.uri, [
      ..._baseSegments(catalog.uri),
      'sources.json',
    ]);
    final Object? descriptors;
    try {
      descriptors = (await _jsonDocument(
        descriptorsUri,
        timeout: _manifestTimeout,
      )).body;
    } on Exception {
      throw const AudioExtensionException(
        AudioExtensionError.noAvailableSources,
      );
    }
    if (descriptors is! List) {
      throw const AudioExtensionException(
        AudioExtensionError.noAvailableSources,
      );
    }
    final urls = <Uri, AudioExtension?>{};
    for (final descriptor in descriptors.whereType<Map>()) {
      final id = audioExtensionText(descriptor['id'], maximumLength: 128);
      final uri = audioExtensionHttpsUri(descriptor['url']);
      if (id == null ||
          entries['wiojelt-$id'] != 'modules/$id.js' ||
          uri == null) {
        continue;
      }
      switch (descriptor['type']) {
        case 'addon':
          urls.putIfAbsent(uri, () => null);
        case 'monochrome':
          urls[uri] = AudioExtension(
            id: id,
            name: audioExtensionText(descriptor['name']) ?? 'Monochrome',
            manifestUri: uri,
            protocol: AudioExtensionProtocol.monochrome,
          );
      }
    }
    final extensions = <Uri, AudioExtension>{};
    final loaded = await Future.wait(
      urls.entries.take(8).map((entry) async {
        if (entry.value != null) return entry.value;
        try {
          return await load(entry.key.toString());
        } on Exception {
          // A restricted or unavailable member cannot block usable siblings.
          return null;
        }
      }),
    );
    for (final extension in loaded.whereType<AudioExtension>()) {
      extensions[extension.manifestUri] = catalog.allowDownloads
          ? extension
          : extension.copyWith(allowDownloads: false);
    }
    if (extensions.isEmpty) {
      throw const AudioExtensionException(
        AudioExtensionError.noAvailableSources,
      );
    }
    return extensions.values.toList(growable: false);
  }

  Future<AudioStreamResolution?> findUpgrade(
    TrackInfo track, {
    required List<AudioExtension> extensions,
    bool forDownload = false,
    bool Function()? shouldContinue,
  }) async {
    final duration = track.duration;
    if (duration == null || duration <= Duration.zero) return null;
    final queries = _matcher.searchQueries(track);
    if (queries.isEmpty) return null;
    bool stillSelected() => !_disposed && (shouldContinue?.call() ?? true);

    for (final extension in extensions) {
      if (!stillSelected()) return null;
      if (!extension.enabled || (forDownload && !extension.allowDownloads)) {
        continue;
      }
      // A slow preferred source must leave time for the next source.
      final elapsed = Stopwatch()..start();
      bool current() => stillSelected() && elapsed.elapsed < _lookupTimeout;
      try {
        if (extension.protocol == AudioExtensionProtocol.monochrome) {
          final resolution = await _findMonochrome(
            extension,
            track,
            queries,
            current: current,
            timeout: () => _lookupTimeout - elapsed.elapsed,
          );
          if (current() && resolution != null) return resolution;
          continue;
        }
        final manifest = await _manifest(
          extension.manifestUri,
        ).timeout(_lookupTimeout - elapsed.elapsed);
        if (!current()) continue;
        if (manifest.extension.id != extension.id ||
            (forDownload && !manifest.extension.allowDownloads)) {
          continue;
        }
        final resolution = await _findRecording(
          manifest,
          track,
          queries,
          current: current,
          timeout: () => _lookupTimeout - elapsed.elapsed,
        );
        if (current() && resolution != null) return resolution;
      } on Exception {
        // An optional source can miss, time out or become unavailable while
        // the already-selected stream continues playing.
      }
    }
    return null;
  }

  Future<_Manifest> _manifest(Uri uri, {bool refresh = false}) async {
    if (_disposed || audioExtensionHttpsUri(uri.toString()) == null) {
      throw const AudioExtensionException(AudioExtensionError.invalidUrl);
    }
    final cached = _manifests[uri];
    if (!refresh && cached != null && _now().isBefore(cached.expiresAt)) {
      return cached.manifest;
    }
    return _pendingManifests.putIfAbsent(uri, () async {
      try {
        final document = await _jsonDocument(uri, timeout: _manifestTimeout);
        final body = document.body;
        final manifest = _Manifest.parse(
          document.uri,
          body is Map ? body : null,
        );
        if (!_disposed) {
          _manifests.remove(document.uri);
          _manifests[document.uri] = (
            manifest: manifest,
            expiresAt: _now().add(_manifestTtl),
          );
          if (_manifests.length > 32) _manifests.remove(_manifests.keys.first);
        }
        return manifest;
      } on AudioExtensionException {
        rethrow;
      } on Exception {
        throw const AudioExtensionException(AudioExtensionError.unavailable);
      } finally {
        _pendingManifests.remove(uri);
      }
    });
  }

  Future<AudioStreamResolution?> _findRecording(
    _Manifest manifest,
    TrackInfo track,
    List<String> queries, {
    required bool Function() current,
    required Duration Function() timeout,
  }) async {
    final attempted = <String>{};
    for (final query in queries) {
      if (!current() || attempted.length >= 3) return null;
      final response = await _json(
        manifest.endpoint(['search'], {'q': query}),
        timeout: _limitTimeout(timeout(), _searchTimeout),
      );
      if (!current()) return null;
      final rows = response?['tracks'];
      if (rows is! List) continue;
      final results = <String, _Candidate>{};
      for (final row in rows.take(20)) {
        final candidate = _Candidate.parse(row);
        if (candidate != null) {
          results.putIfAbsent(candidate.recording.id, () => candidate);
        }
      }
      final matches = _matcher.rankedMatches(
        track,
        results.values.map((row) => row.recording),
        // Some HTTP catalogs omit the duration. The FLAC header must still
        // prove that the stream fits the selected recording.
        allowMissingDuration: true,
      );
      for (final match in matches) {
        if (!current() || attempted.length >= 3) return null;
        if (!attempted.add(match.id)) continue;
        try {
          final candidate = results[match.id]!;
          Map<Object?, Object?>? stream;
          if (manifest.hasStream) {
            stream = await _json(
              manifest.endpoint(['stream', match.id]),
              timeout: _limitTimeout(timeout(), _streamTimeout),
            );
            if (stream == null && candidate.streamUrl == null && current()) {
              // Older bridges use a query argument for the same opaque ID.
              stream = await _json(
                manifest.endpoint(['stream'], {'id': match.id}),
                timeout: _limitTimeout(timeout(), _streamTimeout),
              );
            }
          }
          if (!current()) return null;
          if (stream != null &&
              (_flag(stream['encrypted']) ||
                  !const {'none', 'direct', ''}.contains(
                    '${stream['manifest'] ?? ''}'.toLowerCase().trim(),
                  ))) {
            continue;
          }
          final uri = audioExtensionHttpsUri(
            stream?['url'] ??
                stream?['streamURL'] ??
                stream?['streamUrl'] ??
                candidate.streamUrl,
          );
          if (uri == null) continue;
          final identity = jsonEncode([
            manifest.extension.manifestUri.toString(),
            match.id,
          ]);
          final audio = await _probeFlac(
            uri,
            duration: track.duration!,
            formatId: sha256.convert(utf8.encode(identity)).toString(),
            headers: _mediaHeaders(stream?['headers']),
            timeout: timeout(),
          );
          if (audio != null) return audio;
        } on AudioExtensionException catch (error) {
          if (error.reason == AudioExtensionError.restricted) rethrow;
        } on Exception {
          // A bad rendition does not disqualify the other verified matches.
        }
      }
    }
    return null;
  }

  Future<AudioStreamResolution?> _findMonochrome(
    AudioExtension extension,
    TrackInfo track,
    List<String> queries, {
    required bool Function() current,
    required Duration Function() timeout,
  }) async {
    final attempted = <String>{};
    for (final query in queries) {
      if (!current()) return null;
      final result = await _jsonDocument(
        MonochromeAudioSource.searchUri(extension.manifestUri, query),
        timeout: _limitTimeout(timeout(), _searchTimeout),
      );
      final matches = _matcher.rankedMatches(
        track,
        MonochromeAudioSource.parseSearch(result.body),
      );
      for (final match in matches) {
        if (!current() || attempted.length >= 3) return null;
        if (!attempted.add(match.id)) continue;
        final identity = '${extension.manifestUri}\u0000${match.id}';
        try {
          final audio = await _probeFlac(
            MonochromeAudioSource.streamUri(extension.manifestUri, match.id),
            duration: track.duration!,
            formatId: sha256.convert(utf8.encode(identity)).toString(),
            headers: const {
              'User-Agent': _appUserAgent,
              'Accept': 'audio/flac, application/octet-stream, */*',
            },
            timeout: timeout(),
          );
          if (audio != null) return audio;
        } on Exception {
          // Continue when one rendition's CDN is slow or unavailable.
        }
      }
    }
    return null;
  }

  Future<Map<Object?, Object?>?> _json(
    Uri uri, {
    required Duration timeout,
  }) async {
    final document = await _jsonDocument(uri, timeout: timeout);
    final body = document.body;
    if (body == null) return null;
    if (body is Map<Object?, Object?>) return body;
    throw const AudioExtensionException(AudioExtensionError.unsupported);
  }

  Future<({Uri uri, Object? body})> _jsonDocument(
    Uri uri, {
    required Duration timeout,
  }) async {
    final result = await _get(uri, headers: _jsonHeaders, timeout: timeout);
    final response = result.response;
    if (response.statusCode == 404 || response.statusCode == 204) {
      return (uri: result.uri, body: null);
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const AudioExtensionException(AudioExtensionError.restricted);
    }
    if (response.statusCode != 200) {
      throw const AudioExtensionException(AudioExtensionError.unavailable);
    }
    try {
      return (uri: result.uri, body: jsonDecode(utf8.decode(response.body)));
    } on FormatException {
      // HTML application pages and extension archives are different formats.
    }
    throw const AudioExtensionException(AudioExtensionError.unsupported);
  }

  Future<AudioStreamResolution?> _probeFlac(
    Uri uri, {
    required Duration duration,
    required String formatId,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final result = await _get(
      uri,
      headers: {
        ...headers,
        'Range': 'bytes=0-${FlacStreamInfo.prefixLength - 1}',
        'Accept-Encoding': 'identity',
      },
      timeout: _limitTimeout(timeout, _mediaProbeTimeout),
      probe: true,
    );
    final response = result.response;
    if (response.statusCode != 200 && response.statusCode != 206) return null;
    final info = FlacStreamInfo.fromPrefix(response.body);
    if (info == null ||
        info.sampleRate != 44100 ||
        info.channels != 2 ||
        info.bitDepth != 16 ||
        info.sampleCount == 0) {
      return null;
    }
    final measuredDuration = Duration(
      microseconds:
          info.sampleCount * Duration.microsecondsPerSecond ~/ info.sampleRate,
    );
    final milliseconds = measuredDuration.inMilliseconds;
    if (milliseconds <= 0 ||
        (duration - measuredDuration).abs() > audioUpgradeDurationTolerance) {
      return null;
    }
    final length = switch (response.statusCode) {
      206 => int.tryParse(
        RegExp(
              '^bytes 0-${FlacStreamInfo.prefixLength - 1}/([0-9]+)\$',
            ).firstMatch(response.headers['content-range'] ?? '')?.group(1) ??
            '',
      ),
      _ => int.tryParse(response.headers['content-length'] ?? ''),
    };
    if ((response.statusCode == 206 && length == null) ||
        (length != null &&
            (length <= FlacStreamInfo.prefixLength ||
                length > 100 * 1024 * 1024 * 1024))) {
      return null;
    }
    final bitrate = length == null ? null : length * 8000 ~/ milliseconds;
    return AudioStreamResolution(
      source: AudioStreamSource.audioExtension,
      streamUrl: result.uri.toString(),
      streamExtension: 'flac',
      streamMimeType: 'audio/flac',
      codec: 'flac',
      formatId: formatId,
      bitrate: bitrate,
      sampleRate: info.sampleRate,
      channels: info.channels,
      bitDepth: info.bitDepth,
      httpHeaders: Map.unmodifiable({
        for (final key in headers.keys)
          if (result.headers.containsKey(key)) key: result.headers[key]!,
      }),
    );
  }

  Future<
    ({Uri uri, BoundedAudioHttpResponse response, Map<String, String> headers})
  >
  _get(
    Uri uri, {
    required Map<String, String> headers,
    required Duration timeout,
    bool probe = false,
  }) async {
    final elapsed = Stopwatch()..start();
    for (var remainingRedirects = 2; ; remainingRedirects--) {
      final response = await _transport.get(
        uri,
        headers: headers,
        maximumBytes: probe ? FlacStreamInfo.prefixLength : 256 * 1024,
        readPrefix: probe,
        timeout: timeout - elapsed.elapsed,
      );
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return (uri: uri, response: response, headers: headers);
      }
      final location = response.headers['location'];
      final redirected = location == null
          ? null
          : audioExtensionHttpsUri(uri.resolve(location).toString());
      if (redirected == null ||
          remainingRedirects <= 0 ||
          (!probe && redirected.origin != uri.origin)) {
        throw const AudioExtensionException(AudioExtensionError.unavailable);
      }
      if (redirected.origin != uri.origin) {
        headers = Map.of(headers)
          ..remove('Referer')
          ..remove('Origin');
      }
      uri = redirected;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _manifests.clear();
    _pendingManifests.clear();
    await _transport.close();
  }
}

Duration _limitTimeout(Duration remaining, Duration limit) =>
    remaining < limit ? remaining : limit;

class _Manifest {
  const _Manifest(this.extension, this.hasStream, this.parameters);

  final AudioExtension extension;
  final bool hasStream;
  final Map<String, String> parameters;

  static _Manifest parse(Uri manifestUri, Map<Object?, Object?>? body) {
    final id = audioExtensionText(body?['id'], maximumLength: 256);
    if (id == null || body == null) {
      throw const AudioExtensionException(AudioExtensionError.unsupported);
    }
    if (_flag(body['bitchordAuth'])) {
      throw const AudioExtensionException(
        AudioExtensionError.officialClientOnly,
      );
    }
    if (_flag(body['checkValidLossless'])) {
      throw const AudioExtensionException(AudioExtensionError.outputRequired);
    }
    final allowDownloads = !_flag(body['allowDownloads'], falseValue: true);
    final modules = body['category:music'];
    if (modules is List) {
      throw _AudioExtensionModuleIndex(
        manifestUri,
        id,
        modules,
        allowDownloads,
      );
    }
    final resources = body['resources'];
    if ((resources is List && !resources.contains('search')) ||
        body['entry'] != null ||
        body['modules'] != null ||
        modules != null) {
      throw const AudioExtensionException(AudioExtensionError.unsupported);
    }
    final extension = AudioExtension(
      id: id,
      name: audioExtensionText(body['name'], maximumLength: 256) ?? id,
      manifestUri: manifestUri,
      allowDownloads: allowDownloads,
    );
    final settings = body['settings'];
    final parameters = <String, String>{};
    var quality = 'LOSSLESS';
    if (settings is List) {
      for (final setting in settings.whereType<Map>().take(20)) {
        final key = audioExtensionText(setting['key'], maximumLength: 128);
        if (key == 'quality' || key == 'audio_quality') {
          quality = _cdQualityOption(setting['options']) ?? quality;
        } else if (key != null && !const {'q', 'atmos'}.contains(key)) {
          final value = setting['default'];
          final text = switch (value) {
            bool() || num() => value.toString(),
            _ => audioExtensionText(value),
          };
          if (text != null) parameters[key] = text;
        }
      }
    }
    parameters['quality'] = quality;
    return _Manifest(
      extension,
      resources is! List || resources.contains('stream'),
      parameters,
    );
  }

  Uri endpoint(List<String> path, [Map<String, String> query = const {}]) {
    final uri = extension.manifestUri;
    return _withPath(uri, [..._baseSegments(uri), ...path]).replace(
      queryParameters: {...uri.queryParametersAll, ...parameters, ...query},
    );
  }
}

Iterable<String> _baseSegments(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.isEmpty) return segments;
  final last = segments.last.toLowerCase();
  return last.isEmpty || last.endsWith('.json')
      ? segments.take(segments.length - 1)
      : segments;
}

class _Candidate {
  const _Candidate(this.recording, this.streamUrl);

  final JioSaavnSong recording;
  final Object? streamUrl;

  static _Candidate? parse(Object? value) {
    if (value is! Map) return null;
    final rawId = value['id'];
    final id = audioExtensionText(
      rawId is int && rawId >= 0 ? rawId.toString() : rawId,
      maximumLength: 256,
    );
    final title = audioExtensionText(value['title']);
    final artist = audioExtensionText(value['artist']);
    final rawDuration = value['duration'];
    final seconds = rawDuration == null ? 0.0 : double.tryParse('$rawDuration');
    if (id == null ||
        id == '.' ||
        id == '..' ||
        title == null ||
        artist == null ||
        seconds == null ||
        !seconds.isFinite ||
        seconds < 0 ||
        seconds > 86400) {
      return null;
    }
    return _Candidate(
      JioSaavnSong(
        id: id,
        title: title,
        artists: artist.split(RegExp(r'\s*[,;]\s*')).take(20).toList(),
        album: audioExtensionText(value['album']),
        duration: Duration(
          microseconds: (seconds * Duration.microsecondsPerSecond).round(),
        ),
        supports320: false,
        explicit: _flag(value['explicit']),
      ),
      value['streamURL'] ?? value['streamUrl'],
    );
  }
}

Uri _withPath(Uri uri, List<String> segments) => Uri(
  scheme: uri.scheme,
  host: uri.host,
  port: uri.hasPort ? uri.port : null,
  pathSegments: segments,
  query: uri.hasQuery ? uri.query : null,
);

bool _flag(Object? value, {bool falseValue = false}) =>
    (falseValue ? const {'false', '0'} : const {'true', '1'}).contains(
      '$value'.toLowerCase().trim(),
    );

String? _cdQualityOption(Object? value) {
  if (value is! List) return null;
  String? preferred;
  var preferredScore = 0;
  for (final option in value.take(20)) {
    final raw = option is Map ? option['value'] : option;
    if (raw is! String && raw is! num) continue;
    final key = audioExtensionText('$raw', maximumLength: 128);
    if (key == null) continue;
    final label = '${option is Map ? option['label'] ?? '' : ''} $key'
        .toLowerCase()
        .replaceAll('_', ' ');
    if (RegExp(r'\b(hi[ -]?res|aac|mp3|opus|vorbis|alac)\b').hasMatch(label)) {
      continue;
    }
    final depths = RegExp(r'\b(\d{1,2})[ -]?bit\b').allMatches(label);
    if (depths.any((match) => match.group(1) != '16')) continue;
    final rates = RegExp(
      r'\b(\d{2,6}(?:[.,]\d+)?)\s*(khz|hz)\b',
    ).allMatches(label);
    if (rates.any((match) {
      final number = double.parse(match.group(1)!.replaceAll(',', '.'));
      return number != (match.group(2) == 'khz' ? 44.1 : 44100);
    })) {
      continue;
    }
    final score = RegExp(r'\bcd\b').hasMatch(label) || depths.isNotEmpty
        ? 3
        : rates.isNotEmpty
        ? 2
        : RegExp(r'\blossless\b').hasMatch(label)
        ? 1
        : 0;
    if (score > preferredScore) {
      preferred = key;
      preferredScore = score;
    }
  }
  return preferred;
}

Map<String, String> _mediaHeaders(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.key is String && audioExtensionText(entry.value) != null)
        if (const {
              'user-agent': 'User-Agent',
              'referer': 'Referer',
              'origin': 'Origin',
            }[(entry.key as String).toLowerCase()]
            case final String name)
          name: (entry.value as String).trim(),
  };
}
