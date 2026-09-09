import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bstream_music/services/live/local_overlay_hosts.dart';
import 'package:bstream_music/services/live/local_overlay_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'serves injected HTML and health from a loopback ephemeral port',
    () async {
      late HttpServer boundServer;
      final server = LocalLiveOverlayServer(
        hostProvisioner: _FakeHostProvisioner(),
        htmlDocument: '<!doctype html><body>overlay-test</body>',
        dnsResolver: _loopbackDnsResolver,
        healthProbe: _successfulHealthProbe,
        brandIconBytes: Uint8List.fromList(<int>[137, 80, 78, 71]),
        port: 0,
        serverBinder: (address, port) async {
          expect(address.address, InternetAddress.loopbackIPv4.address);
          expect(port, 0);
          boundServer = await HttpServer.bind(address, port);
          return boundServer;
        },
      );
      addTearDown(server.stop);

      final uri = await server.start();
      final secondUri = await server.start();

      expect(uri, secondUri);
      expect(uri.scheme, 'http');
      expect(uri.host, localLiveOverlayHost);
      expect(uri.port, boundServer.port);
      expect(uri.path, localLiveOverlayPath);
      expect(server.isRunning, isTrue);

      final overlay = await _request(boundServer.port, '/');
      expect(overlay.statusCode, HttpStatus.ok);
      expect(overlay.body, contains('overlay-test'));
      expect(overlay.contentType?.mimeType, 'text/html');
      expect(overlay.cacheControl, 'no-store');
      expect(overlay.contentSecurityPolicy, contains("default-src 'none'"));
      expect(
        overlay.contentSecurityPolicy,
        contains("connect-src 'self' ws://$localLiveOverlayHost:"),
      );
      expect(overlay.contentSecurityPolicy, contains("img-src 'self' data:"));

      final icon = await _request(boundServer.port, '/bstream-icon.png');
      expect(icon.statusCode, HttpStatus.ok);
      expect(icon.contentType?.mimeType, 'image/png');
      expect(icon.bytes, <int>[137, 80, 78, 71]);

      final health = await _request(boundServer.port, '/health');
      expect(health.statusCode, HttpStatus.ok);
      expect(jsonDecode(health.body), <String, Object>{
        'ok': true,
        'clients': 0,
      });

      final missing = await _request(boundServer.port, '/missing');
      expect(missing.statusCode, HttpStatus.notFound);
    },
  );

  test('WebSocket receives the latest JSON and future broadcasts', () async {
    late HttpServer boundServer;
    final server = LocalLiveOverlayServer(
      hostProvisioner: _FakeHostProvisioner(),
      htmlDocument: '<html></html>',
      dnsResolver: _loopbackDnsResolver,
      healthProbe: _successfulHealthProbe,
      port: 0,
      serverBinder: (address, port) async {
        boundServer = await HttpServer.bind(address, port);
        return boundServer;
      },
    );
    addTearDown(server.stop);
    server.publishJson(<String, Object>{'type': 'snapshot', 'title': 'One'});
    await server.start();

    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${boundServer.port}/ws',
      headers: _localHeaders(boundServer.port),
    );
    final messages = StreamIterator<dynamic>(socket);
    addTearDown(() async {
      await messages.cancel();
      await socket.close();
    });

    expect(await messages.moveNext(), isTrue);
    expect(jsonDecode(messages.current as String), <String, Object>{
      'type': 'snapshot',
      'title': 'One',
    });

    server.publishJson(<String, Object>{'type': 'snapshot', 'title': 'Two'});
    expect(await messages.moveNext(), isTrue);
    expect(jsonDecode(messages.current as String), <String, Object>{
      'type': 'snapshot',
      'title': 'Two',
    });

    final health = await _request(boundServer.port, '/health');
    expect((jsonDecode(health.body) as Map<String, dynamic>)['clients'], 1);

    await server.stop();
    expect(server.isRunning, isFalse);
    expect(server.boundPort, isNull);
    await server.stop();
  });

  test('rejects a regular HTTP request to the WebSocket endpoint', () async {
    late HttpServer boundServer;
    final server = LocalLiveOverlayServer(
      hostProvisioner: _FakeHostProvisioner(),
      htmlDocument: '<html></html>',
      dnsResolver: _loopbackDnsResolver,
      healthProbe: _successfulHealthProbe,
      port: 0,
      serverBinder: (address, port) async {
        boundServer = await HttpServer.bind(address, port);
        return boundServer;
      },
    );
    addTearDown(server.stop);
    await server.start();

    final response = await _request(boundServer.port, '/ws');

    expect(response.statusCode, HttpStatus.upgradeRequired);
  });

  test('rejects requests addressed to an IP or a foreign Host', () async {
    late HttpServer boundServer;
    final server = LocalLiveOverlayServer(
      hostProvisioner: _FakeHostProvisioner(),
      htmlDocument: '<html></html>',
      dnsResolver: _loopbackDnsResolver,
      healthProbe: _successfulHealthProbe,
      port: 0,
      serverBinder: (address, port) async {
        boundServer = await HttpServer.bind(address, port);
        return boundServer;
      },
    );
    addTearDown(server.stop);
    await server.start();

    final ipHost = await _request(
      boundServer.port,
      '/health',
      hostHeader: '127.0.0.1:${boundServer.port}',
    );
    final foreignHost = await _request(
      boundServer.port,
      '/health',
      hostHeader: 'example.test:${boundServer.port}',
    );

    expect(ipHost.statusCode, 421);
    expect(foreignHost.statusCode, 421);
  });

  test(
    'accepts the local domain or absent Origin and rejects foreign origins',
    () async {
      late HttpServer boundServer;
      final server = LocalLiveOverlayServer(
        hostProvisioner: _FakeHostProvisioner(),
        htmlDocument: '<html></html>',
        dnsResolver: _loopbackDnsResolver,
        healthProbe: _successfulHealthProbe,
        port: 0,
        serverBinder: (address, port) async {
          boundServer = await HttpServer.bind(address, port);
          return boundServer;
        },
      );
      addTearDown(server.stop);
      await server.start();
      final url = 'ws://127.0.0.1:${boundServer.port}/ws';

      final withoutOrigin = await WebSocket.connect(
        url,
        headers: _localHeaders(boundServer.port),
      );
      withoutOrigin.listen((_) {});
      await withoutOrigin.close();

      final localDomainOrigin = await WebSocket.connect(
        url,
        headers: <String, Object>{
          ..._localHeaders(boundServer.port),
          'Origin': 'http://$localLiveOverlayHost:${boundServer.port}',
        },
      );
      localDomainOrigin.listen((_) {});
      await localDomainOrigin.close();

      await expectLater(
        WebSocket.connect(
          url,
          headers: <String, Object>{
            ..._localHeaders(boundServer.port),
            'Origin': 'http://example.test',
          },
        ),
        throwsA(isA<WebSocketException>()),
      );
    },
  );

  test(
    'limits WebSocket clients and closes clients that send messages',
    () async {
      late HttpServer boundServer;
      final server = LocalLiveOverlayServer(
        hostProvisioner: _FakeHostProvisioner(),
        htmlDocument: '<html></html>',
        dnsResolver: _loopbackDnsResolver,
        healthProbe: _successfulHealthProbe,
        port: 0,
        maxWebSocketClients: 1,
        serverBinder: (address, port) async {
          boundServer = await HttpServer.bind(address, port);
          return boundServer;
        },
      );
      addTearDown(server.stop);
      await server.start();
      final url = 'ws://127.0.0.1:${boundServer.port}/ws';
      final first = await WebSocket.connect(
        url,
        headers: _localHeaders(boundServer.port),
      );
      first.listen((_) {});

      await expectLater(
        WebSocket.connect(url, headers: _localHeaders(boundServer.port)),
        throwsA(isA<WebSocketException>()),
      );

      first.add('clients may not publish to the overlay');
      await first.done.timeout(const Duration(seconds: 3));
      expect(first.closeCode, WebSocketStatus.policyViolation);

      final replacement = await WebSocket.connect(
        url,
        headers: _localHeaders(boundServer.port),
      );
      replacement.listen((_) {});
      await replacement.close();
    },
  );

  test(
    'stop closes clients and prevents a new WebSocket during shutdown',
    () async {
      late HttpServer boundServer;
      final server = LocalLiveOverlayServer(
        hostProvisioner: _FakeHostProvisioner(),
        htmlDocument: '<html></html>',
        dnsResolver: _loopbackDnsResolver,
        healthProbe: _successfulHealthProbe,
        port: 0,
        serverBinder: (address, port) async {
          boundServer = await HttpServer.bind(address, port);
          return boundServer;
        },
      );
      addTearDown(server.stop);
      await server.start();
      final url = 'ws://127.0.0.1:${boundServer.port}/ws';
      final headers = _localHeaders(boundServer.port);
      final existing = await WebSocket.connect(url, headers: headers);
      final existingClosed = Completer<void>();
      existing.listen((_) {}, onDone: existingClosed.complete);

      final stopping = server.stop();
      await expectLater(
        WebSocket.connect(url, headers: headers),
        throwsA(anyOf(isA<WebSocketException>(), isA<SocketException>())),
      );
      await stopping;
      await existingClosed.future.timeout(const Duration(seconds: 6));

      expect(server.isRunning, isFalse);
      expect(existing.closeCode, WebSocketStatus.goingAway);
    },
  );

  test('requires a positive WebSocket client limit', () {
    expect(
      () => LocalLiveOverlayServer(
        hostProvisioner: _FakeHostProvisioner(),
        htmlDocument: '<html></html>',
        maxWebSocketClients: 0,
      ),
      throwsArgumentError,
    );
  });

  test('defaults to eight WebSocket clients', () {
    final server = LocalLiveOverlayServer(
      hostProvisioner: _FakeHostProvisioner(),
      htmlDocument: '<html></html>',
    );

    expect(server.maxWebSocketClients, 8);
  });

  test('requires bounded positive verification settings', () {
    LocalLiveOverlayServer create({
      int attempts = 1,
      Duration timeout = const Duration(seconds: 1),
      Duration retryDelay = Duration.zero,
    }) => LocalLiveOverlayServer(
      hostProvisioner: _FakeHostProvisioner(),
      htmlDocument: '<html></html>',
      verificationAttempts: attempts,
      verificationTimeout: timeout,
      verificationRetryDelay: retryDelay,
    );

    expect(() => create(attempts: 0), throwsArgumentError);
    expect(() => create(timeout: Duration.zero), throwsArgumentError);
    expect(
      () => create(retryDelay: const Duration(milliseconds: -1)),
      throwsArgumentError,
    );
  });

  test('never binds or provisions a non-loopback address', () async {
    final provisioner = _FakeHostProvisioner();
    final server = LocalLiveOverlayServer(
      hostProvisioner: provisioner,
      htmlDocument: '<html></html>',
      dnsResolver: _loopbackDnsResolver,
      healthProbe: _successfulHealthProbe,
      address: InternetAddress.anyIPv4,
      serverBinder: (_, _) async => fail('A public address must not be bound.'),
    );

    await expectLater(server.start(), throwsArgumentError);
    expect(provisioner.calls, 0);
  });

  test('classifies an occupied port before requesting UAC', () async {
    final provisioner = _FakeHostProvisioner();
    final server = LocalLiveOverlayServer(
      hostProvisioner: provisioner,
      htmlDocument: '<html></html>',
      dnsResolver: _loopbackDnsResolver,
      healthProbe: _successfulHealthProbe,
      serverBinder: (_, _) async => throw const SocketException(
        'Address already in use',
        osError: OSError('WSAEADDRINUSE', 10048),
      ),
    );

    await expectLater(
      server.start(),
      throwsA(
        isA<LocalLiveOverlayPortInUseException>()
            .having(
              (error) => error.message,
              'message',
              allOf(contains('puerto 80'), contains(localLiveOverlayUrl)),
            )
            .having((error) => error.cause, 'cause', isA<SocketException>()),
      ),
    );
    expect(provisioner.calls, 0);
  });

  test('classifies a denied or reserved port separately', () async {
    final provisioner = _FakeHostProvisioner();
    final server = LocalLiveOverlayServer(
      hostProvisioner: provisioner,
      htmlDocument: '<html></html>',
      dnsResolver: _loopbackDnsResolver,
      healthProbe: _successfulHealthProbe,
      serverBinder: (_, _) async => throw const SocketException(
        'Permission denied',
        osError: OSError('WSAEACCES', 10013),
      ),
    );

    await expectLater(
      server.start(),
      throwsA(
        isA<LocalLiveOverlayPortAccessException>()
            .having(
              (error) => error.message,
              'message',
              allOf(contains('puerto 80'), contains('reserv')),
            )
            .having((error) => error.cause, 'cause', isA<SocketException>()),
      ),
    );
    expect(provisioner.calls, 0);
  });

  test(
    'retries unsafe DNS and probes health only after exact IPv4 loopback',
    () async {
      late HttpServer boundServer;
      var dnsCalls = 0;
      var healthCalls = 0;
      final delays = <Duration>[];
      final server = LocalLiveOverlayServer(
        hostProvisioner: _FakeHostProvisioner(),
        htmlDocument: '<html></html>',
        port: 0,
        verificationAttempts: 2,
        verificationRetryDelay: const Duration(milliseconds: 17),
        dnsResolver: (_) async {
          dnsCalls++;
          return dnsCalls == 1
              ? <InternetAddress>[InternetAddress('192.0.2.8')]
              : <InternetAddress>[InternetAddress.loopbackIPv4];
        },
        healthProbe: (uri, timeout) async {
          healthCalls++;
          expect(uri.host, localLiveOverlayHost);
          expect(uri.port, boundServer.port);
          expect(uri.path, '/health');
          expect(timeout, const Duration(seconds: 2));
        },
        retryDelay: (duration) async => delays.add(duration),
        serverBinder: (address, port) async {
          boundServer = await HttpServer.bind(address, port);
          return boundServer;
        },
      );
      addTearDown(server.stop);

      await server.start();

      expect(dnsCalls, 2);
      expect(healthCalls, 1);
      expect(delays, <Duration>[const Duration(milliseconds: 17)]);
      expect(server.isRunning, isTrue);
    },
  );

  test('rejects mixed DNS results and closes the failed listener', () async {
    late HttpServer boundServer;
    late int boundPort;
    var healthCalls = 0;
    final server = LocalLiveOverlayServer(
      hostProvisioner: _FakeHostProvisioner(),
      htmlDocument: '<html></html>',
      port: 0,
      verificationAttempts: 1,
      dnsResolver: (_) async => <InternetAddress>[
        InternetAddress.loopbackIPv4,
        InternetAddress('192.0.2.9'),
      ],
      healthProbe: (_, _) async {
        healthCalls++;
      },
      serverBinder: (address, port) async {
        boundServer = await HttpServer.bind(address, port);
        boundPort = boundServer.port;
        return boundServer;
      },
    );

    await expectLater(
      server.start(),
      throwsA(
        isA<LocalLiveOverlayVerificationException>().having(
          (error) => error.cause.toString(),
          'cause',
          allOf(contains('127.0.0.1'), contains('192.0.2.9')),
        ),
      ),
    );

    expect(healthCalls, 0);
    expect(server.isRunning, isFalse);
    expect(server.boundPort, isNull);
    final rebound = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      boundPort,
    );
    await rebound.close(force: true);
  });

  test('closes the bound socket when host provisioning fails', () async {
    late int boundPort;
    final server = LocalLiveOverlayServer(
      hostProvisioner: _FakeHostProvisioner(StateError('hosts unavailable')),
      htmlDocument: '<html></html>',
      port: 0,
      dnsResolver: _loopbackDnsResolver,
      healthProbe: _successfulHealthProbe,
      serverBinder: (address, port) async {
        final bound = await HttpServer.bind(address, port);
        boundPort = bound.port;
        return bound;
      },
    );

    await expectLater(
      server.start(),
      throwsA(
        isA<LocalLiveOverlayServerException>().having(
          (error) => error.cause,
          'cause',
          isA<StateError>(),
        ),
      ),
    );
    expect(server.isRunning, isFalse);
    expect(server.boundPort, isNull);

    final rebound = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      boundPort,
    );
    await rebound.close(force: true);
  });

  test('concurrent starts wait for the same endpoint verification', () async {
    final probeStarted = Completer<void>();
    final allowProbe = Completer<void>();
    var bindCalls = 0;
    final server = LocalLiveOverlayServer(
      hostProvisioner: _FakeHostProvisioner(),
      htmlDocument: '<html></html>',
      port: 0,
      dnsResolver: _loopbackDnsResolver,
      healthProbe: (_, _) async {
        probeStarted.complete();
        await allowProbe.future;
      },
      serverBinder: (address, port) async {
        bindCalls++;
        return HttpServer.bind(address, port);
      },
    );
    addTearDown(server.stop);

    final first = server.start();
    await probeStarted.future;
    final second = server.start();
    expect(bindCalls, 1);

    allowProbe.complete();
    final uris = await Future.wait<Uri>(<Future<Uri>>[first, second]);
    expect(uris[0], uris[1]);
    expect(bindCalls, 1);
  });

  test(
    'times out local verification and can start cleanly afterward',
    () async {
      late int firstPort;
      var bindCalls = 0;
      var shouldResolve = false;
      final never = Completer<List<InternetAddress>>();
      final server = LocalLiveOverlayServer(
        hostProvisioner: _FakeHostProvisioner(),
        htmlDocument: '<html></html>',
        port: 0,
        verificationAttempts: 1,
        verificationTimeout: const Duration(milliseconds: 25),
        dnsResolver: (_) => shouldResolve
            ? Future<List<InternetAddress>>.value(<InternetAddress>[
                InternetAddress.loopbackIPv4,
              ])
            : never.future,
        healthProbe: _successfulHealthProbe,
        serverBinder: (address, port) async {
          bindCalls++;
          final bound = await HttpServer.bind(address, port);
          if (bindCalls == 1) firstPort = bound.port;
          return bound;
        },
      );
      addTearDown(server.stop);

      await expectLater(
        server.start(),
        throwsA(
          isA<LocalLiveOverlayVerificationException>().having(
            (error) => error.cause,
            'cause',
            isA<TimeoutException>(),
          ),
        ),
      );
      expect(server.isRunning, isFalse);

      final rebound = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        firstPort,
      );
      await rebound.close(force: true);

      shouldResolve = true;
      final uri = await server.start();
      expect(uri.host, localLiveOverlayHost);
      expect(server.isRunning, isTrue);
      expect(bindCalls, 2);
    },
  );

  test('the default verifier performs a direct real health GET', () async {
    final server = LocalLiveOverlayServer(
      hostProvisioner: _FakeHostProvisioner(),
      htmlDocument: '<html></html>',
      host: 'localhost',
      port: 0,
      verificationAttempts: 1,
    );
    addTearDown(server.stop);

    final uri = await server.start();

    expect(uri.host, 'localhost');
    expect(server.isRunning, isTrue);
  });
}

Future<List<InternetAddress>> _loopbackDnsResolver(String _) async =>
    <InternetAddress>[InternetAddress.loopbackIPv4];

Future<void> _successfulHealthProbe(Uri _, Duration _) async {}

Map<String, Object> _localHeaders(int port) => <String, Object>{
  HttpHeaders.hostHeader: '$localLiveOverlayHost:$port',
};

Future<_TestResponse> _request(
  int port,
  String path, {
  String? hostHeader,
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    request.headers.set(
      HttpHeaders.hostHeader,
      hostHeader ?? '$localLiveOverlayHost:$port',
    );
    final response = await request.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    return _TestResponse(
      statusCode: response.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      bytes: bytes,
      contentType: response.headers.contentType,
      cacheControl: response.headers.value(HttpHeaders.cacheControlHeader),
      contentSecurityPolicy: response.headers.value('content-security-policy'),
    );
  } finally {
    client.close(force: true);
  }
}

final class _TestResponse {
  const _TestResponse({
    required this.statusCode,
    required this.body,
    required this.bytes,
    required this.contentType,
    required this.cacheControl,
    required this.contentSecurityPolicy,
  });

  final int statusCode;
  final String body;
  final Uint8List bytes;
  final ContentType? contentType;
  final String? cacheControl;
  final String? contentSecurityPolicy;
}

final class _FakeHostProvisioner implements LocalOverlayHostProvisioner {
  _FakeHostProvisioner([this.error]);

  final Object? error;
  int calls = 0;

  @override
  Future<void> ensureConfigured() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
  }
}
