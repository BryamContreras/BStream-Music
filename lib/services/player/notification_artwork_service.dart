import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

import '../../core/utils/bounded_byte_stream.dart';
import '../../core/utils/image_source.dart';

typedef NotificationArtworkCacheDirectoryProvider =
    Future<Directory> Function();
typedef NotificationArtworkServerBinder = Future<HttpServer> Function();
typedef DeviceAudioArtworkLoader =
    Future<Uint8List?> Function(String audioUri, int targetWidth);

/// Supplies square, center-cropped artwork to mobile system media controls.
///
/// [uriFor] is synchronous and never downloads or decodes an image. The mobile
/// audio service requests the returned loopback URL after playback metadata is
/// published, so network and image work stay outside the audio startup path.
/// Generated JPEGs are reused from a small application-cache directory.
class NotificationArtworkService {
  NotificationArtworkService({
    NotificationArtworkCacheDirectoryProvider? cacheDirectoryProvider,
    NotificationArtworkServerBinder? serverBinder,
    DeviceAudioArtworkLoader? deviceAudioArtworkLoader,
    // Android and iOS commonly render lock-screen artwork at 300–400 dp.
    // Keep a 2x square derivative so the system does not upscale a visibly
    // soft 320 px bitmap on high-density phones.
    this.outputSize = 640,
    this.maximumCacheEntries = 128,
    this.maximumRegisteredSources = 512,
    this.maximumConcurrentWork = 2,
    this.maximumSourceBytes = 10 * 1024 * 1024,
    this.sourceIdleTimeout = const Duration(seconds: 10),
    this.sourceTotalTimeout = const Duration(seconds: 30),
  }) : assert(outputSize > 0),
       assert(maximumCacheEntries > 0),
       assert(maximumRegisteredSources > 0),
       assert(maximumConcurrentWork > 0),
       assert(maximumSourceBytes > 0),
       assert(sourceIdleTimeout > Duration.zero),
       assert(sourceTotalTimeout > Duration.zero),
       _cacheDirectoryProvider =
           cacheDirectoryProvider ?? _defaultCacheDirectory,
       _serverBinder = serverBinder ?? _bindLoopbackServer,
       _deviceAudioArtworkLoader =
           deviceAudioArtworkLoader ?? _loadDeviceAudioArtwork;

  static final NotificationArtworkService instance =
      NotificationArtworkService();

  static const _cacheVersion = 'center-crop-v1';
  static const _routePrefix = 'notification-artwork';

  final NotificationArtworkCacheDirectoryProvider _cacheDirectoryProvider;
  final NotificationArtworkServerBinder _serverBinder;
  final DeviceAudioArtworkLoader _deviceAudioArtworkLoader;
  final int outputSize;
  final int maximumCacheEntries;
  final int maximumRegisteredSources;
  final int maximumConcurrentWork;
  final int maximumSourceBytes;
  final Duration sourceIdleTimeout;
  final Duration sourceTotalTimeout;

  final LinkedHashMap<String, String> _sources =
      LinkedHashMap<String, String>();
  final Map<String, Future<File?>> _inFlight = <String, Future<File?>>{};
  final Queue<Completer<void>> _workWaiters = Queue<Completer<void>>();
  final String _sessionToken = _randomToken();

  HttpServer? _server;
  Future<void>? _initialization;
  bool _disposed = false;
  int _activeWork = 0;

  /// Starts the optional loopback endpoint.
  ///
  /// A failure is reported to the startup coordinator, while clearing the
  /// cached attempt allows a later retry. Playback remains independent from
  /// this service and can keep using the original artwork URI.
  Future<void> initialize() {
    final current = _initialization;
    if (current != null) {
      return current;
    }
    late final Future<void> attempt;
    attempt = _startServer().whenComplete(() {
      if (_server == null && identical(_initialization, attempt)) {
        _initialization = null;
      }
    });
    _initialization = attempt;
    return attempt;
  }

  /// Returns a local artwork URL without doing file, network, or image work.
  ///
  /// The original source remains registered for as long as this service owns
  /// the native playback session, which also supports large local queues whose
  /// later items may not play for hours.
  Uri? uriFor(String? rawSource) {
    final server = _server;
    final source = _normalizedSupportedSource(rawSource);
    if (_disposed || server == null || source == null) {
      return null;
    }

    final key = _cacheKey(source);
    _sources.remove(key);
    _sources[key] = source;
    while (_sources.length > maximumRegisteredSources) {
      _sources.remove(_sources.keys.first);
    }
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      pathSegments: <String>[_routePrefix, _sessionToken, '$key.jpg'],
    );
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _sources.clear();
    _inFlight.clear();
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<void> _startServer() async {
    if (_disposed || _server != null) {
      return;
    }
    final server = await _serverBinder();
    if (_disposed) {
      await server.close(force: true);
      return;
    }
    _server = server;
    unawaited(
      server.forEach(_handleRequest).catchError((Object _, StackTrace _) {}),
    );
  }

  static Future<HttpServer> _bindLoopbackServer() =>
      HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length != 3 ||
          segments[0] != _routePrefix ||
          segments[1] != _sessionToken ||
          !segments[2].endsWith('.jpg')) {
        response.statusCode = HttpStatus.notFound;
        return;
      }

      final key = segments[2].substring(0, segments[2].length - 4);
      final source = _sources[key];
      if (source == null || _cacheKey(source) != key) {
        response.statusCode = HttpStatus.notFound;
        return;
      }

      final artwork = await _resolveArtwork(key, source);
      if (artwork == null || !await artwork.exists()) {
        await _serveOriginalSource(request, source);
        return;
      }
      final length = await artwork.length();
      if (length <= 0) {
        response.statusCode = HttpStatus.notFound;
        return;
      }

      response.headers
        ..contentType = ContentType('image', 'jpeg')
        ..contentLength = length
        ..set(
          HttpHeaders.cacheControlHeader,
          'private, max-age=31536000, immutable',
        );
      if (request.method == 'GET') {
        await response.addStream(artwork.openRead());
      }
      unawaited(_touch(artwork));
    } catch (_) {
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {
        // The body may already be streaming when the notification is replaced.
      }
    } finally {
      try {
        await response.close();
      } catch (_) {
        // The notification may be replaced while its previous image is still
        // loading. A disconnected artwork client is harmless.
      }
    }
  }

  Future<File?> _resolveArtwork(String key, String source) async {
    final directory = await _cacheDirectoryProvider();
    await directory.create(recursive: true);
    final target = File(p.join(directory.path, '$key.jpg'));
    if (await _isUsable(target)) {
      return target;
    }

    final pending = _inFlight[key];
    if (pending != null) {
      return pending;
    }

    late final Future<File?> generation;
    generation = _withWorkPermit(() => _generateArtwork(source, target))
        .whenComplete(() {
          if (identical(_inFlight[key], generation)) {
            _inFlight.remove(key);
          }
        });
    _inFlight[key] = generation;
    return generation;
  }

  Future<T> _withWorkPermit<T>(Future<T> Function() operation) async {
    if (_activeWork >= maximumConcurrentWork) {
      final waiter = Completer<void>();
      _workWaiters.add(waiter);
      await waiter.future;
    } else {
      _activeWork++;
    }

    try {
      return await operation();
    } finally {
      if (_workWaiters.isNotEmpty) {
        // Transfer this occupied slot directly to the oldest waiter. Keeping
        // _activeWork unchanged avoids a new request overtaking that waiter.
        _workWaiters.removeFirst().complete();
      } else {
        _activeWork--;
      }
    }
  }

  Future<File?> _generateArtwork(String source, File target) async {
    File? temporary;
    try {
      final bytes = await _loadSourceBytes(source);
      if (bytes == null || bytes.isEmpty) {
        return null;
      }

      temporary = File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp.jpg',
      );
      final transformInput = bytes;
      final transformSize = outputSize;
      final encoded = await Isolate.run(
        () => _centerCropJpeg(transformInput, transformSize),
      );
      if (encoded == null || encoded.isEmpty) {
        return null;
      }
      await temporary.writeAsBytes(encoded, flush: true);
      if (!await _isUsable(temporary)) {
        return null;
      }

      if (await target.exists()) {
        await target.delete();
      }
      final generated = await temporary.rename(target.path);
      temporary = null;
      unawaited(_trimCache(generated));
      return generated;
    } catch (_) {
      return null;
    } finally {
      if (temporary != null && await temporary.exists()) {
        try {
          await temporary.delete();
        } catch (_) {
          // Best effort cleanup after a failed decode or interrupted client.
        }
      }
    }
  }

  Future<Uint8List?> _loadSourceBytes(String source) async {
    final deviceAudioUri = deviceAudioUriFromArtworkSource(source);
    if (deviceAudioUri != null) {
      try {
        return await _deviceAudioArtworkLoader(deviceAudioUri, outputSize);
      } catch (_) {
        return null;
      }
    }
    if (isNetworkImageSource(source)) {
      return _loadNetworkBytes(source);
    }

    final file = imageFileFromSource(source);
    if (file == null || !await file.exists()) {
      return null;
    }
    final length = await file.length();
    if (length <= 0 || length > maximumSourceBytes) {
      return null;
    }
    final bytes = await collectBoundedByteStream(
      file.openRead(),
      maximumBytes: maximumSourceBytes,
      declaredLength: length,
      idleTimeout: sourceIdleTimeout,
      totalTimeout: sourceTotalTimeout,
    );
    return Uint8List.fromList(bytes);
  }

  Future<void> _serveOriginalSource(HttpRequest request, String source) async {
    final response = request.response;
    if (isNetworkImageSource(source)) {
      // Preserve audio_service's previous direct-network behavior when this
      // optional transform cannot fetch or decode an artwork.
      response.statusCode = HttpStatus.temporaryRedirect;
      response.headers.set(HttpHeaders.locationHeader, source);
      return;
    }

    final file = imageFileFromSource(source);
    if (file == null || !await file.exists()) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    final length = await file.length();
    if (length <= 0) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    response.headers.contentLength = length;
    if (request.method == 'GET') {
      await response.addStream(file.openRead());
    }
  }

  Future<Uint8List?> _loadNetworkBytes(String source) async {
    final client = HttpClient()..connectionTimeout = sourceIdleTimeout;
    try {
      for (final candidate in artworkSourceCandidates(source)) {
        final uri = Uri.tryParse(candidate);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
          continue;
        }
        try {
          final request = await client.getUrl(uri);
          request.headers
            ..set(
              HttpHeaders.userAgentHeader,
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36',
            )
            ..set(HttpHeaders.acceptHeader, 'image/*,*/*;q=0.8');
          final response = await request.close();
          if (response.statusCode < 200 || response.statusCode >= 300) {
            await response.drain<void>();
            continue;
          }
          final bytes = await collectBoundedByteStream(
            response,
            maximumBytes: maximumSourceBytes,
            declaredLength: response.contentLength < 0
                ? null
                : response.contentLength,
            idleTimeout: sourceIdleTimeout,
            totalTimeout: sourceTotalTimeout,
          );
          if (bytes.isNotEmpty) {
            return Uint8List.fromList(bytes);
          }
        } catch (_) {
          // Try the next stable YouTube artwork variant when available.
        }
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _trimCache(File protectedFile) async {
    try {
      final directory = protectedFile.parent;
      final files = await directory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.jpg'))
          .cast<File>()
          .toList();
      if (files.length <= maximumCacheEntries) {
        return;
      }
      final dated = <({File file, DateTime modified})>[];
      for (final file in files) {
        dated.add((file: file, modified: await file.lastModified()));
      }
      dated.sort((left, right) => left.modified.compareTo(right.modified));
      var remaining = files.length;
      for (final entry in dated) {
        if (remaining <= maximumCacheEntries) {
          break;
        }
        if (p.equals(entry.file.path, protectedFile.path)) {
          continue;
        }
        try {
          await entry.file.delete();
          remaining--;
        } catch (_) {
          // Cache maintenance must never affect artwork delivery.
        }
      }
    } catch (_) {
      // Best effort cache maintenance.
    }
  }

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // Access-time updates are only an LRU hint.
    }
  }

  Future<bool> _isUsable(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  String? _normalizedSupportedSource(String? rawSource) {
    // Keep the original CDN URL as the registered source. The network loader
    // asks for the sharp rendition first and retains this URL as a fallback
    // when a provider does not expose the requested size.
    final normalized = canonicalYouTubeThumbnailSource(rawSource);
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    if (isDeviceAudioArtworkSource(normalized)) {
      return normalized;
    }
    if (isNetworkImageSource(normalized)) {
      final uri = Uri.tryParse(normalized);
      return uri != null && uri.hasAuthority ? normalized : null;
    }

    if (p.isAbsolute(normalized)) {
      return normalized;
    }
    final uri = Uri.tryParse(normalized);
    if (uri != null && uri.hasScheme && uri.scheme != 'file') {
      return null;
    }
    return uri != null && uri.scheme == 'file' ? normalized : null;
  }

  String _cacheKey(String source) =>
      sha256.convert(utf8.encode('$_cacheVersion\u0000$source')).toString();

  static Future<Directory> _defaultCacheDirectory() async {
    final root = await getApplicationCacheDirectory();
    return Directory(p.join(root.path, 'notification-artwork'));
  }

  static Future<Uint8List?> _loadDeviceAudioArtwork(
    String audioUri,
    int targetWidth,
  ) {
    return const MethodChannel(
      'bstream_music/local_audio',
    ).invokeMethod<Uint8List>('loadArtwork', <String, Object>{
      'audioUri': audioUri,
      'targetWidth': targetWidth.clamp(32, 1280),
    });
  }

  static String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

Uint8List? _centerCropJpeg(Uint8List bytes, int outputSize) {
  final decoded = image.decodeImage(bytes);
  if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
    return null;
  }
  final oriented = image.bakeOrientation(decoded);
  final side = min(oriented.width, oriented.height);
  final cropped = image.copyCrop(
    oriented,
    x: (oriented.width - side) ~/ 2,
    y: (oriented.height - side) ~/ 2,
    width: side,
    height: side,
  );
  final resized = image.copyResize(
    cropped,
    width: outputSize,
    height: outputSize,
    interpolation: image.Interpolation.linear,
  );
  return image.encodeJpg(resized, quality: 88);
}
