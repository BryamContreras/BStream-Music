import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

typedef CastRelayAddressResolver =
    Future<InternetAddress> Function(InternetAddress? receiverAddress);

/// A session-only media endpoint. It exposes neither a directory nor a general
/// proxy: each unguessable URL grants access to exactly one prepared source.
/// Encoded media streams with backpressure; it is never decoded or cached here.
class MediaCastRelay {
  MediaCastRelay({
    CastRelayAddressResolver? addressResolver,
    HttpClient Function()? httpClientFactory,
    this.maxConcurrentRequests = 4,
  }) : _addressResolver = addressResolver ?? _lanAddress,
       _httpClientFactory = httpClientFactory ?? HttpClient.new {
    if (maxConcurrentRequests < 1) {
      throw ArgumentError.value(maxConcurrentRequests);
    }
  }

  final CastRelayAddressResolver _addressResolver;
  final HttpClient Function() _httpClientFactory;
  final int maxConcurrentRequests;
  final Map<String, _RelaySource> _sources = {};
  final Set<_RelayTransfer> _transfers = {};
  final Random _random = Random.secure();
  HttpServer? _server;
  InternetAddress? _boundAddress;
  InternetAddress? _receiverAddress;
  bool _disposed = false;
  int _generation = 0;
  Future<void> _preparation = Future<void>.value();

  bool get isRunning => _server != null;

  Future<Uri> startForRemote({
    required Uri source,
    Map<String, String> headers = const {},
    required String contentType,
    InternetAddress? receiverAddress,
  }) async {
    if (!['http', 'https'].contains(source.scheme) ||
        source.host.isEmpty ||
        source.userInfo.isNotEmpty) {
      throw ArgumentError.value(source, 'source', 'Expected an HTTP media URL');
    }
    return _prepare(
      _RelaySource.remote(source, Map.unmodifiable(headers), contentType),
      receiverAddress,
    );
  }

  Future<Uri> startForFile({
    required String path,
    required String contentType,
    InternetAddress? receiverAddress,
  }) async {
    final generation = _generation;
    if (_disposed) throw StateError('The media relay is disposed');
    final file = File(path);
    if (!await file.exists()) {
      throw FileSystemException('Media not found', path);
    }
    final canonical = await file.resolveSymbolicLinks();
    if (_disposed || generation != _generation) {
      throw StateError('Media relay preparation cancelled');
    }
    return _prepare(
      _RelaySource.file(File(canonical), contentType),
      receiverAddress,
    );
  }

  Future<Uri> _prepare(_RelaySource source, InternetAddress? receiver) {
    final generation = _generation;
    final operation = _preparation.then((_) {
      if (generation != _generation) {
        throw StateError('Media relay preparation cancelled');
      }
      return _prepareSerial(source, receiver);
    });
    _preparation = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<Uri> _prepareSerial(
    _RelaySource source,
    InternetAddress? receiver,
  ) async {
    if (_disposed) throw StateError('The media relay is disposed');
    final generation = _generation;
    if (_server == null) {
      final address = await _addressResolver(receiver);
      if (_disposed || generation != _generation) {
        throw StateError('Media relay preparation cancelled');
      }
      final server = await HttpServer.bind(address, 0, shared: false);
      if (_disposed || generation != _generation) {
        await server.close(force: true);
        throw StateError('Media relay preparation cancelled');
      }
      _server = server;
      _boundAddress = address;
      _receiverAddress = receiver;
      server.listen((request) => unawaited(_serve(request)), onError: (_) {});
    }
    // Keep the current and previous source until the receiver acknowledges the
    // next load. A third preparation retires old transfers and their URLs.
    while (_sources.length >= 2) {
      final expired = _sources.keys.first;
      _sources.remove(expired);
      for (final transfer
          in _transfers.where((t) => t.path == expired).toList()) {
        transfer.cancel();
      }
    }
    final token = base64Url
        .encode(List.generate(32, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    final route = '/media/$token';
    _sources[route] = source;
    return Uri(
      scheme: 'http',
      host: _boundAddress!.address,
      port: _server!.port,
      path: route,
    );
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final source = _sources[request.uri.path];
    if (source == null || request.uri.hasQuery) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final peer = request.connectionInfo?.remoteAddress;
    if (!_allowedPeer(peer)) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Range');
    response.headers.set(
      'Access-Control-Expose-Headers',
      'Content-Range, Accept-Ranges, Content-Length',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD, OPTIONS');
      await response.close();
      return;
    }
    if (_transfers.length >= maxConcurrentRequests) {
      response.statusCode = HttpStatus.serviceUnavailable;
      response.headers.set(HttpHeaders.retryAfterHeader, '1');
      await response.close();
      return;
    }
    final transfer = _RelayTransfer(request.uri.path, response);
    _transfers.add(transfer);
    try {
      if (source.file != null) {
        await _serveFile(request, source, transfer);
      } else {
        await _serveRemote(request, source, transfer);
      }
    } catch (_) {
      // Socket aborts and track changes are normal. Never log signed URLs,
      // cookies, or local filenames in a remote-visible response.
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {}
    } finally {
      transfer.client?.close(force: true);
      _transfers.remove(transfer);
    }
  }

  bool _allowedPeer(InternetAddress? peer) {
    if (peer == null) return false;
    if (_boundAddress?.isLoopback == true) return peer.isLoopback;
    if (_receiverAddress != null) {
      return peer.address == _receiverAddress!.address;
    }
    return _isPrivateV4(peer);
  }

  Future<void> _serveFile(
    HttpRequest request,
    _RelaySource source,
    _RelayTransfer transfer,
  ) async {
    final response = request.response;
    final file = source.file!;
    final length = await file.length();
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final range = _FileRange.parse(rangeHeader, length);
    response.headers.set(HttpHeaders.contentTypeHeader, source.contentType);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set('transferMode.dlna.org', 'Streaming');
    if (range == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      await response.close();
      return;
    }
    response.statusCode = rangeHeader == null
        ? HttpStatus.ok
        : HttpStatus.partialContent;
    response.contentLength = range.end - range.start;
    if (rangeHeader != null) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end - 1}/$length',
      );
    }
    if (request.method == 'GET' && !transfer.cancelled) {
      await _pump(file.openRead(range.start, range.end), transfer);
    }
    await response.close();
  }

  Future<void> _serveRemote(
    HttpRequest request,
    _RelaySource source,
    _RelayTransfer transfer,
  ) async {
    final client = _httpClientFactory();
    transfer.client = client;
    client.connectionTimeout = const Duration(seconds: 12);
    client.autoUncompress = false;
    client.maxConnectionsPerHost = 1;
    var uri = source.remote!;
    var headers = Map<String, String>.of(source.headers);
    HttpClientResponse? upstream;
    for (var redirect = 0; redirect <= 4; redirect++) {
      if (transfer.cancelled) return;
      final outgoing = await client.openUrl(request.method, uri);
      outgoing.followRedirects = false;
      for (final entry in headers.entries) {
        if (!_hopHeaders.contains(entry.key.toLowerCase())) {
          outgoing.headers.set(entry.key, entry.value);
        }
      }
      outgoing.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        if (!RegExp(r'^bytes=\d*-\d*$').hasMatch(range)) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await request.response.close();
          return;
        }
        outgoing.headers.set(HttpHeaders.rangeHeader, range);
      }
      upstream = await outgoing.close().timeout(const Duration(seconds: 15));
      final location = upstream.headers.value(HttpHeaders.locationHeader);
      if (![301, 302, 303, 307, 308].contains(upstream.statusCode) ||
          location == null) {
        break;
      }
      if (redirect == 4) throw const HttpException('Too many media redirects');
      final next = uri.resolve(location);
      if (!['http', 'https'].contains(next.scheme) ||
          next.userInfo.isNotEmpty ||
          (uri.scheme == 'https' && next.scheme != 'https')) {
        throw const HttpException('Invalid media redirect');
      }
      if (next.origin != uri.origin) {
        headers = {
          for (final entry in headers.entries)
            if (_safeRedirectHeaders.contains(entry.key.toLowerCase()))
              entry.key: entry.value,
        };
      }
      await upstream.drain<void>().timeout(const Duration(seconds: 5));
      uri = next;
    }
    if (upstream == null || transfer.cancelled) return;
    final response = request.response;
    response.statusCode = upstream.statusCode;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      upstream.headers.value(HttpHeaders.contentTypeHeader) ??
          source.contentType,
    );
    for (final name in [
      HttpHeaders.contentRangeHeader,
      HttpHeaders.acceptRangesHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.lastModifiedHeader,
    ]) {
      final value = upstream.headers.value(name);
      if (value != null) response.headers.set(name, value);
    }
    if (upstream.contentLength >= 0) {
      response.contentLength = upstream.contentLength;
    }
    response.headers.set('transferMode.dlna.org', 'Streaming');
    if (request.method == 'GET') {
      await _pump(upstream.timeout(const Duration(seconds: 20)), transfer);
    }
    await response.close();
  }

  Future<void> _pump(Stream<List<int>> source, _RelayTransfer transfer) async {
    final iterator = StreamIterator(source);
    transfer.iterator = iterator;
    try {
      while (!transfer.cancelled && await iterator.moveNext()) {
        if (transfer.cancelled) break;
        transfer.response.add(iterator.current);
        // Flush applies backpressure without retaining a full track. File and
        // upstream chunks are bounded by their native streaming implementations.
        await transfer.response.flush().timeout(const Duration(seconds: 10));
      }
    } finally {
      transfer.iterator = null;
      await iterator.cancel();
    }
  }

  Future<void> stop() async {
    _generation++;
    _sources.clear();
    for (final transfer in _transfers.toList()) {
      transfer.cancel();
    }
    _transfers.clear();
    final server = _server;
    _server = null;
    _boundAddress = null;
    _receiverAddress = null;
    await server?.close(force: true);
  }

  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }

  static const _hopHeaders = {
    'host',
    'connection',
    'content-length',
    'transfer-encoding',
    'range',
    'proxy-authorization',
    'proxy-authenticate',
    'keep-alive',
    'te',
    'trailer',
    'upgrade',
  };
  static const _safeRedirectHeaders = {
    'user-agent',
    'accept',
    'accept-language',
  };

  static bool _isPrivateV4(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final b = address.rawAddress;
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254);
  }

  static Future<InternetAddress> _lanAddress(InternetAddress? receiver) async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final addresses = interfaces
        .expand((i) => i.addresses)
        .where(_isPrivateV4)
        .toList();
    if (addresses.isEmpty) {
      throw const SocketException('No local Wi-Fi network available');
    }
    if (receiver != null && receiver.type == InternetAddressType.IPv4) {
      int score(InternetAddress candidate) {
        final a = candidate.rawAddress;
        final b = receiver.rawAddress;
        var common = 0;
        for (var i = 0; i < 4; i++) {
          final xor = a[i] ^ b[i];
          if (xor == 0) {
            common += 8;
          } else {
            common += 8 - xor.bitLength;
            break;
          }
        }
        return common;
      }

      addresses.sort((a, b) => score(b).compareTo(score(a)));
    }
    return addresses.first;
  }
}

class _RelaySource {
  const _RelaySource.remote(this.remote, this.headers, this.contentType)
    : file = null;
  const _RelaySource.file(this.file, this.contentType)
    : remote = null,
      headers = const {};
  final Uri? remote;
  final File? file;
  final Map<String, String> headers;
  final String contentType;
}

class _RelayTransfer {
  _RelayTransfer(this.path, this.response);
  final String path;
  final HttpResponse response;
  HttpClient? client;
  StreamIterator<List<int>>? iterator;
  bool cancelled = false;
  void cancel() {
    cancelled = true;
    client?.close(force: true);
    unawaited(iterator?.cancel());
    try {
      unawaited(
        response
            .detachSocket(writeHeaders: false)
            .then((socket) {
              socket.destroy();
            })
            .catchError((_) {}),
      );
    } catch (_) {
      // After headers have been sent, canceling the iterator terminates the
      // payload. A short Content-Length closes the socket rather than exposing
      // any bytes from a replacement source. The active pump owns the response
      // until its flush completes; closing a bound sink here would throw.
    }
  }
}

class _FileRange {
  const _FileRange(this.start, this.end);
  final int start;
  final int end;
  static _FileRange? parse(String? header, int length) {
    if (header == null) return _FileRange(0, length);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
    if (match == null || length == 0) return null;
    final first = match.group(1)!;
    final last = match.group(2)!;
    if (first.isEmpty) {
      final suffix = int.tryParse(last);
      if (suffix == null || suffix <= 0) return null;
      return _FileRange(max(0, length - suffix), length);
    }
    final start = int.tryParse(first);
    final inclusiveEnd = last.isEmpty ? length - 1 : int.tryParse(last);
    if (start == null ||
        inclusiveEnd == null ||
        start >= length ||
        inclusiveEnd < start) {
      return null;
    }
    return _FileRange(start, min(length, inclusiveEnd + 1));
  }
}
