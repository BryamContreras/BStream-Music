import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'local_overlay_hosts.dart';

typedef LocalOverlayServerBinder =
    Future<HttpServer> Function(InternetAddress address, int port);

typedef LocalOverlayDnsResolver =
    Future<List<InternetAddress>> Function(String host);
typedef LocalOverlayHealthProbe =
    Future<void> Function(Uri uri, Duration timeout);
typedef LocalOverlayRetryDelay = Future<void> Function(Duration duration);

final class LocalLiveOverlayServerException implements Exception {
  const LocalLiveOverlayServerException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() {
    final suffix = cause == null ? '' : ': $cause';
    return 'LocalLiveOverlayServerException: $message$suffix';
  }
}

final class LocalLiveOverlayPortInUseException
    extends LocalLiveOverlayServerException {
  const LocalLiveOverlayPortInUseException(super.message, [super.cause]);
}

final class LocalLiveOverlayPortAccessException
    extends LocalLiveOverlayServerException {
  const LocalLiveOverlayPortAccessException(super.message, [super.cause]);
}

final class LocalLiveOverlayVerificationException
    extends LocalLiveOverlayServerException {
  const LocalLiveOverlayVerificationException(super.message, [super.cause]);
}

/// Loopback-only HTTP and WebSocket server for a browser-source LIVE overlay.
///
/// The visual document is injected so presentation can evolve independently
/// from host provisioning, socket, and lifecycle concerns.
final class LocalLiveOverlayServer {
  LocalLiveOverlayServer({
    required this.hostProvisioner,
    required this.htmlDocument,
    Uint8List? brandIconBytes,
    InternetAddress? address,
    this.host = localLiveOverlayHost,
    this.port = localLiveOverlayPort,
    this.maxWebSocketClients = 8,
    this.verificationAttempts = 4,
    this.verificationTimeout = const Duration(seconds: 2),
    this.verificationRetryDelay = const Duration(milliseconds: 250),
    LocalOverlayServerBinder? serverBinder,
    LocalOverlayDnsResolver? dnsResolver,
    LocalOverlayHealthProbe? healthProbe,
    LocalOverlayRetryDelay? retryDelay,
  }) : brandIconBytes = brandIconBytes == null
           ? null
           : Uint8List.fromList(brandIconBytes),
       _address = address ?? InternetAddress.loopbackIPv4,
       _serverBinder = serverBinder ?? _bind,
       _dnsResolver = dnsResolver ?? _resolveIpv4,
       _healthProbe = healthProbe ?? _probeHealthDirect,
       _retryDelay = retryDelay ?? Future<void>.delayed {
    if (maxWebSocketClients <= 0) {
      throw ArgumentError.value(
        maxWebSocketClients,
        'maxWebSocketClients',
        'The WebSocket client limit must be positive.',
      );
    }
    if (verificationAttempts <= 0) {
      throw ArgumentError.value(
        verificationAttempts,
        'verificationAttempts',
        'The verification attempt count must be positive.',
      );
    }
    if (verificationTimeout <= Duration.zero) {
      throw ArgumentError.value(
        verificationTimeout,
        'verificationTimeout',
        'The verification timeout must be positive.',
      );
    }
    if (verificationRetryDelay < Duration.zero) {
      throw ArgumentError.value(
        verificationRetryDelay,
        'verificationRetryDelay',
        'The verification retry delay cannot be negative.',
      );
    }
    if (host.trim().isEmpty || Uri.tryParse('http://$host')?.host != host) {
      throw ArgumentError.value(host, 'host', 'Expected one exact DNS name.');
    }
  }

  final LocalOverlayHostProvisioner hostProvisioner;
  final String htmlDocument;
  final Uint8List? brandIconBytes;
  final InternetAddress _address;
  final LocalOverlayServerBinder _serverBinder;
  final LocalOverlayDnsResolver _dnsResolver;
  final LocalOverlayHealthProbe _healthProbe;
  final LocalOverlayRetryDelay _retryDelay;
  final String host;
  final int port;
  final int maxWebSocketClients;
  final int verificationAttempts;
  final Duration verificationTimeout;
  final Duration verificationRetryDelay;

  final Set<WebSocket> _clients = <WebSocket>{};
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _requestSubscription;
  Future<Uri>? _starting;
  Future<void>? _stopOperation;
  bool _stopping = false;
  String? _latestJson;

  bool get isRunning => _server != null;

  int? get boundPort => _server?.port;

  Uri? get uri {
    final activePort = boundPort;
    if (activePort == null) {
      return null;
    }
    return Uri(
      scheme: 'http',
      host: host,
      port: activePort,
      path: localLiveOverlayPath,
    );
  }

  Uri? get webSocketUri {
    final activePort = boundPort;
    if (activePort == null) {
      return null;
    }
    return Uri(scheme: 'ws', host: host, port: activePort, path: '/ws');
  }

  /// Starts the server once. Concurrent callers share the same operation.
  Future<Uri> start() async {
    final stopping = _stopOperation;
    if (stopping != null) {
      await stopping;
    }
    final pending = _starting;
    if (pending != null) {
      return pending;
    }
    final currentUri = uri;
    if (currentUri != null) {
      return currentUri;
    }

    final operation = _startInternal();
    _starting = operation;
    try {
      return await operation;
    } finally {
      if (identical(_starting, operation)) {
        _starting = null;
      }
    }
  }

  Future<Uri> _startInternal() async {
    if (_stopping) {
      throw const LocalLiveOverlayServerException(
        'The local overlay server is stopping.',
      );
    }
    if (!_address.isLoopback) {
      throw ArgumentError.value(
        _address.address,
        'address',
        'The LIVE overlay server may only bind to a loopback address.',
      );
    }

    HttpServer? boundServer;
    StreamSubscription<HttpRequest>? requestSubscription;
    try {
      // Claim port 80 before asking Windows to configure the hostname. This
      // avoids an unnecessary UAC prompt when another application owns it and
      // closes the race between a separate availability probe and the bind.
      final server = await _serverBinder(_address, port);
      boundServer = server;
      await hostProvisioner.ensureConfigured();
      if (_stopping) {
        throw const LocalLiveOverlayServerException(
          'The local overlay server was stopped during startup.',
        );
      }

      server.autoCompress = true;
      _server = server;
      requestSubscription = server.listen(
        _handleRequest,
        onError: (_) {
          // Individual transport failures do not invalidate the listening
          // socket. HttpServer.close remains the lifecycle authority.
        },
      );
      _requestSubscription = requestSubscription;
      await _verifyLocalEndpoint(server.port);
      if (_stopping) {
        throw const LocalLiveOverlayServerException(
          'The local overlay server was stopped during startup.',
        );
      }
      return uri!;
    } on Object catch (error, stackTrace) {
      await _cleanupFailedStartup(
        server: boundServer,
        requestSubscription: requestSubscription,
      );
      if (error is LocalLiveOverlayServerException) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      final endpoint = port == HttpClient.defaultHttpPort
          ? 'http://$host$localLiveOverlayPath'
          : 'http://$host:$port$localLiveOverlayPath';
      if (boundServer == null &&
          error is SocketException &&
          error.osError?.errorCode == 10048) {
        throw LocalLiveOverlayPortInUseException(
          'No se pudo iniciar $endpoint porque el puerto $port ya est\u00e1 en uso.',
          error,
        );
      }
      if (boundServer == null &&
          error is SocketException &&
          error.osError?.errorCode == 10013) {
        throw LocalLiveOverlayPortAccessException(
          'No se pudo iniciar $endpoint porque Windows deneg\u00f3 o reserv\u00f3 el puerto $port.',
          error,
        );
      }
      throw LocalLiveOverlayServerException(
        'No se pudo iniciar $endpoint.',
        error,
      );
    }
  }

  Future<void> _verifyLocalEndpoint(int activePort) async {
    final endpoint = Uri(
      scheme: 'http',
      host: host,
      port: activePort,
      path: '/health',
    );
    Object? lastError;

    for (var attempt = 0; attempt < verificationAttempts; attempt++) {
      if (_stopping) {
        throw const LocalLiveOverlayServerException(
          'The local overlay server was stopped during startup.',
        );
      }
      var attemptActive = true;
      try {
        await (() async {
          final addresses = await _dnsResolver(host);
          if (!attemptActive) return;
          final safe =
              addresses.isNotEmpty &&
              addresses.every(
                (address) =>
                    address.type == InternetAddressType.IPv4 &&
                    address.address == localLiveOverlayIpv4,
              );
          if (!safe) {
            final resolved = addresses.isEmpty
                ? 'no IPv4 addresses'
                : addresses.map((address) => address.address).join(', ');
            throw StateError('$host resolved to $resolved.');
          }
          await _healthProbe(endpoint, verificationTimeout);
        })().timeout(verificationTimeout);
        return;
      } on Object catch (error) {
        if (_stopping) {
          throw const LocalLiveOverlayServerException(
            'The local overlay server was stopped during startup.',
          );
        }
        lastError = error;
      } finally {
        attemptActive = false;
      }

      if (attempt + 1 < verificationAttempts &&
          verificationRetryDelay > Duration.zero) {
        await _retryDelay(verificationRetryDelay);
      }
    }

    throw LocalLiveOverlayVerificationException(
      'Windows configur\u00f3 el dominio local, pero BStream no pudo verificar '
      'de forma segura http://$host/health.',
      lastError,
    );
  }

  Future<void> _cleanupFailedStartup({
    required HttpServer? server,
    required StreamSubscription<HttpRequest>? requestSubscription,
  }) async {
    if (identical(_requestSubscription, requestSubscription)) {
      _requestSubscription = null;
    }
    if (identical(_server, server)) {
      _server = null;
    }

    Future<void>? cancelRequests;
    try {
      cancelRequests = requestSubscription?.cancel();
    } on Object {
      // Continue with the listening-socket close below.
    }
    Future<dynamic>? closeServer;
    try {
      closeServer = server?.close(force: true);
    } on Object {
      // State is already reset; cleanup remains best-effort.
    }
    if (cancelRequests != null || closeServer != null) {
      try {
        await Future.wait<void>(<Future<void>>[
          cancelRequests ?? Future<void>.value(),
          closeServer?.then<void>((_) {}) ?? Future<void>.value(),
        ], eagerError: false);
      } on Object {
        // Preserve the startup failure while still resetting local state.
      }
    }

    while (_clients.isNotEmpty) {
      final clients = List<WebSocket>.of(_clients);
      _clients.removeAll(clients);
      await Future.wait<void>(
        clients.map(
          (client) => _closeSocket(
            client,
            WebSocketStatus.goingAway,
            'BStream LIVE overlay startup failed',
          ),
        ),
      );
    }
  }

  static Future<List<InternetAddress>> _resolveIpv4(String host) {
    return InternetAddress.lookup(host, type: InternetAddressType.IPv4);
  }

  static Future<void> _probeHealthDirect(Uri uri, Duration timeout) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      await (() async {
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException(
            'The local overlay health check returned '
            '${response.statusCode}.',
            uri: uri,
          );
        }
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
          throw const FormatException(
            'The local overlay health response is invalid.',
          );
        }
      })().timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  /// Stores and broadcasts any JSON-encodable overlay state.
  ///
  /// A browser that connects later immediately receives the last value.
  void publishJson(Object? value) {
    final encoded = jsonEncode(value);
    _latestJson = encoded;
    for (final client in List<WebSocket>.of(_clients)) {
      try {
        client.add(encoded);
      } on Object {
        _clients.remove(client);
        unawaited(client.close().catchError((_) {}));
      }
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (_stopping) {
        await _serviceUnavailable(request.response);
        return;
      }
      if (!_isLoopbackRequest(request) || !_isAllowedHost(request)) {
        request.response.statusCode = 421;
        request.response.headers.contentType = ContentType.text;
        request.response.write('Misdirected request');
        await request.response.close();
        return;
      }
      switch (request.uri.path) {
        case '/':
        case '/index.html':
        case localLiveOverlayPath:
          if (request.method != 'GET') {
            await _methodNotAllowed(request.response, allow: 'GET');
            return;
          }
          _applyNoCacheHeaders(request.response);
          request.response.headers.contentType = ContentType.html;
          request.response.write(htmlDocument);
          await request.response.close();
        case '/health':
          if (request.method != 'GET') {
            await _methodNotAllowed(request.response, allow: 'GET');
            return;
          }
          _applyNoCacheHeaders(request.response);
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object>{
              'ok': true,
              'clients': _clients.length,
            }),
          );
          await request.response.close();
        case '/bstream-icon.png':
          if (request.method != 'GET') {
            await _methodNotAllowed(request.response, allow: 'GET');
            return;
          }
          final icon = brandIconBytes;
          if (icon == null || icon.isEmpty) {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
            return;
          }
          _applyNoCacheHeaders(request.response);
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(icon);
          await request.response.close();
        case '/ws':
          if (!WebSocketTransformer.isUpgradeRequest(request)) {
            request.response.statusCode = HttpStatus.upgradeRequired;
            request.response.headers.set(
              HttpHeaders.upgradeHeader,
              'websocket',
            );
            await request.response.close();
            return;
          }
          if (!_isAllowedWebSocketOrigin(request)) {
            request.response.statusCode = HttpStatus.forbidden;
            await request.response.close();
            return;
          }
          if (_clients.length >= maxWebSocketClients) {
            await _serviceUnavailable(request.response);
            return;
          }
          final socket = await WebSocketTransformer.upgrade(request);
          socket.pingInterval = const Duration(seconds: 20);
          if (_stopping) {
            await _closeSocket(
              socket,
              WebSocketStatus.goingAway,
              'BStream LIVE overlay is stopping',
            );
            return;
          }
          if (_clients.length >= maxWebSocketClients) {
            await _closeSocket(
              socket,
              WebSocketStatus.policyViolation,
              'Too many overlay clients',
            );
            return;
          }
          _clients.add(socket);
          socket.listen(
            (_) {
              if (_clients.remove(socket)) {
                unawaited(
                  _closeSocket(
                    socket,
                    WebSocketStatus.policyViolation,
                    'The overlay WebSocket is read-only',
                  ),
                );
              }
            },
            onError: (_) => _clients.remove(socket),
            onDone: () => _clients.remove(socket),
            cancelOnError: true,
          );
          final latest = _latestJson;
          if (latest != null) {
            socket.add(latest);
          }
        case '/favicon.ico':
          request.response.statusCode = HttpStatus.noContent;
          await request.response.close();
        default:
          request.response.statusCode = HttpStatus.notFound;
          request.response.headers.contentType = ContentType.text;
          request.response.write('Not found');
          await request.response.close();
      }
    } on Object {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } on Object {
        // The connection may already belong to a WebSocket or be closed.
      }
    }
  }

  void _applyNoCacheHeaders(HttpResponse response) {
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Referrer-Policy', 'no-referrer');
    response.headers.set('Cross-Origin-Resource-Policy', 'same-origin');
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; style-src 'unsafe-inline'; "
          "script-src 'unsafe-inline'; img-src 'self' data:; "
          "connect-src 'self' ${webSocketUri ?? ''}; base-uri 'none'; "
          "form-action 'none'",
    );
  }

  static Future<void> _methodNotAllowed(
    HttpResponse response, {
    required String allow,
  }) async {
    response.statusCode = HttpStatus.methodNotAllowed;
    response.headers.set(HttpHeaders.allowHeader, allow);
    await response.close();
  }

  bool _isAllowedWebSocketOrigin(HttpRequest request) {
    final values = request.headers['origin'];
    if (values == null) {
      return true;
    }
    if (values.length != 1 || values.single.trim().isEmpty) {
      return false;
    }
    final value = values.single.trim();
    final origin = Uri.tryParse(value);
    final localPort = request.connectionInfo?.localPort ?? boundPort ?? port;
    if (origin == null ||
        origin.scheme.toLowerCase() != 'http' ||
        origin.host.toLowerCase() != host.toLowerCase() ||
        origin.port != localPort ||
        origin.hasQuery ||
        origin.hasFragment ||
        origin.userInfo.isNotEmpty) {
      return false;
    }
    return origin.path.isEmpty || origin.path == '/';
  }

  bool _isAllowedHost(HttpRequest request) {
    final values = request.headers[HttpHeaders.hostHeader];
    if (values == null || values.length != 1) return false;
    final value = values.single.trim();
    if (value.isEmpty) return false;
    final authority = Uri.tryParse('http://$value');
    final localPort = request.connectionInfo?.localPort ?? boundPort ?? port;
    return authority != null &&
        authority.scheme == 'http' &&
        authority.host.toLowerCase() == host.toLowerCase() &&
        authority.port == localPort &&
        authority.userInfo.isEmpty &&
        !authority.hasQuery &&
        !authority.hasFragment &&
        (authority.path.isEmpty || authority.path == '/');
  }

  static bool _isLoopbackRequest(HttpRequest request) {
    final remoteAddress = request.connectionInfo?.remoteAddress;
    return remoteAddress != null && remoteAddress.isLoopback;
  }

  static Future<void> _serviceUnavailable(HttpResponse response) async {
    response.statusCode = HttpStatus.serviceUnavailable;
    response.headers.set(HttpHeaders.retryAfterHeader, '1');
    await response.close();
  }

  static Future<void> _closeSocket(
    WebSocket socket,
    int code,
    String reason,
  ) async {
    try {
      await socket.close(code, reason).timeout(const Duration(seconds: 2));
    } on Object {
      // Closing is best-effort; the listening server is closed forcefully too.
    }
  }

  /// Closes clients and the listening socket. It is safe to call repeatedly.
  Future<void> stop() {
    final active = _stopOperation;
    if (active != null) {
      return active;
    }

    final operation = _stopInternal();
    _stopOperation = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_stopOperation, operation)) {
            _stopOperation = null;
          }
        },
        onError: (_, _) {
          if (identical(_stopOperation, operation)) {
            _stopOperation = null;
          }
        },
      ),
    );
    return operation;
  }

  Future<void> _stopInternal() async {
    _stopping = true;
    try {
      final pending = _starting;
      if (pending != null) {
        try {
          await pending;
        } on Object {
          // Startup already reports its own error to the original caller.
        }
      }

      final subscription = _requestSubscription;
      _requestSubscription = null;
      final server = _server;
      _server = null;

      // Invoke both before the first await so no new HTTP request or WebSocket
      // upgrade can enter while existing clients are being drained.
      final cancelRequests = subscription?.cancel();
      final closeServer = server?.close(force: true);
      Object? listenerCloseError;
      StackTrace? listenerCloseStackTrace;
      if (cancelRequests != null || closeServer != null) {
        final cancelResult = cancelRequests ?? Future<void>.value();
        final closeResult =
            closeServer?.then<void>((_) {}) ?? Future<void>.value();
        try {
          await Future.wait<void>(<Future<void>>[
            cancelResult,
            closeResult,
          ], eagerError: false);
        } on Object catch (error, stackTrace) {
          listenerCloseError = error;
          listenerCloseStackTrace = stackTrace;
        }
      }

      // A request accepted just before close may finish its upgrade. The
      // handler rechecks `_stopping`; looping also makes the drain defensive.
      while (_clients.isNotEmpty) {
        final clients = List<WebSocket>.of(_clients);
        _clients.removeAll(clients);
        await Future.wait<void>(
          clients.map(
            (client) => _closeSocket(
              client,
              WebSocketStatus.goingAway,
              'BStream LIVE overlay stopped',
            ),
          ),
        );
      }
      if (listenerCloseError != null) {
        Error.throwWithStackTrace(
          listenerCloseError,
          listenerCloseStackTrace ?? StackTrace.current,
        );
      }
    } finally {
      _stopping = false;
    }
  }

  static Future<HttpServer> _bind(InternetAddress address, int port) {
    return HttpServer.bind(address, port, shared: false);
  }
}
