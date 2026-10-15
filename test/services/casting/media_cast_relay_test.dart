import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/casting/media_cast_relay.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;
  late File media;
  late MediaCastRelay relay;
  late HttpClient client;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'bstream_cast_relay_test_',
    );
    media = File('${temporary.path}/audio.m4a');
    await media.writeAsBytes(List.generate(100, (i) => i));
    relay = MediaCastRelay(
      addressResolver: (_) async => InternetAddress.loopbackIPv4,
    );
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await relay.dispose();
    await temporary.delete(recursive: true);
  });

  Future<Uri> fileUrl() =>
      relay.startForFile(path: media.path, contentType: 'audio/mp4');
  Future<({int status, List<int> bytes, HttpHeaders headers})> get(
    Uri uri, {
    String? range,
    String method = 'GET',
  }) async {
    final request = await client.openUrl(method, uri);
    if (range != null) request.headers.set('Range', range);
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      [],
      (all, chunk) => all..addAll(chunk),
    );
    return (
      status: response.statusCode,
      bytes: bytes,
      headers: response.headers,
    );
  }

  test('starts only on demand and returns a single capability URL', () async {
    expect(relay.isRunning, isFalse);
    final uri = await fileUrl();
    expect(uri.host, '127.0.0.1');
    expect(uri.path.split('/').last.length, 43);
    final response = await get(uri);
    expect(response.status, 200);
    expect(response.bytes, List.generate(100, (i) => i));
    expect(response.headers.value('content-type'), 'audio/mp4');
    expect(response.headers.value('cache-control'), 'no-store');
    expect(response.headers.value('access-control-allow-origin'), '*');
    expect((await get(uri.replace(path: '/'))).status, 404);
    expect((await get(uri.replace(query: 'file=${media.path}'))).status, 404);
    expect((await get(uri, method: 'POST')).status, 405);
  });

  test('supports HEAD without downloading the body', () async {
    final response = await get(await fileUrl(), method: 'HEAD');
    expect(response.status, 200);
    expect(response.bytes, isEmpty);
    expect(response.headers.value('content-length'), '100');
  });

  test('supports exact open-ended and suffix ranges', () async {
    final uri = await fileUrl();
    final bounded = await get(uri, range: 'bytes=10-19');
    expect(bounded.status, 206);
    expect(bounded.bytes, List.generate(10, (i) => i + 10));
    expect(bounded.headers.value('content-range'), 'bytes 10-19/100');
    expect((await get(uri, range: 'bytes=95-')).bytes, [95, 96, 97, 98, 99]);
    expect((await get(uri, range: 'bytes=-3')).bytes, [97, 98, 99]);
    expect(
      (await get(uri, range: 'bytes=90-500')).headers.value('content-range'),
      'bytes 90-99/100',
    );
  });

  test('rejects malformed multi-ranges and unsatisfiable ranges', () async {
    final uri = await fileUrl();
    for (final range in [
      'bytes=100-',
      'bytes=50-20',
      'bytes=-0',
      'bytes=-',
      'bytes=0-1,3-4',
      'items=0-5',
    ]) {
      final response = await get(uri, range: range);
      expect(response.status, 416, reason: range);
      expect(response.headers.value('content-range'), 'bytes */100');
    }
  });

  test(
    'keeps current and previous capabilities but retires older paths',
    () async {
      final first = await fileUrl();
      final second = await fileUrl();
      expect(first, isNot(second));
      expect(first.port, second.port);
      expect((await get(first)).status, 200);
      final third = await fileUrl();
      expect(third.port, first.port);
      expect((await get(first)).status, 404);
      expect((await get(second)).status, 200);
      expect((await get(third)).status, 200);
    },
  );

  test('simultaneous initial preparations share one server', () async {
    final urls = await Future.wait([fileUrl(), fileUrl()]);
    expect(urls[0].port, urls[1].port);
    expect((await get(urls[0])).status, 200);
    expect((await get(urls[1])).status, 200);
    await relay.stop();
    expect(relay.isRunning, isFalse);
    await expectLater(
      get(urls[0]),
      throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
    );
  });

  test(
    'stop cancels a late pending server bind without exposing media',
    () async {
      await relay.dispose();
      final gate = Completer<InternetAddress>();
      relay = MediaCastRelay(addressResolver: (_) => gate.future);
      final preparing = fileUrl();
      await Future<void>.delayed(Duration.zero);
      final failed = expectLater(preparing, throwsA(isA<StateError>()));
      await relay.stop();
      gate.complete(InternetAddress.loopbackIPv4);
      await failed;
      expect(relay.isRunning, isFalse);
    },
  );

  test(
    'forwards a remote byte range and private upstream headers only to source',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      upstream.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer private');
        expect(request.headers.value('range'), 'bytes=10-12');
        expect(request.headers.value('host'), '127.0.0.1:${upstream.port}');
        request.response.statusCode = 206;
        request.response.headers.set('content-type', 'audio/webm');
        request.response.headers.set('content-range', 'bytes 10-12/100');
        request.response.contentLength = 3;
        request.response.add([10, 11, 12]);
        await request.response.close();
      });
      final url = await relay.startForRemote(
        source: Uri.parse('http://127.0.0.1:${upstream.port}/signed'),
        headers: {'Authorization': 'Bearer private', 'Host': 'bad.invalid'},
        contentType: 'audio/webm',
      );
      final response = await get(url, range: 'bytes=10-12');
      expect(response.status, 206);
      expect(response.bytes, [10, 11, 12]);
      expect(response.headers.value('content-range'), 'bytes 10-12/100');
      expect(response.headers.value('authorization'), isNull);
    },
  );

  test('strips credentials on cross-origin media redirects', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => target.close(force: true));
    addTearDown(() => upstream.close(force: true));
    target.listen((request) async {
      expect(request.headers.value('authorization'), isNull);
      expect(request.headers.value('cookie'), isNull);
      expect(request.headers.value('user-agent'), 'BStream-test');
      request.response.add(utf8.encode('ok'));
      await request.response.close();
    });
    upstream.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers.set(
        'location',
        'http://127.0.0.1:${target.port}/final',
      );
      await request.response.close();
    });
    final url = await relay.startForRemote(
      source: Uri.parse('http://127.0.0.1:${upstream.port}/start'),
      headers: {
        'Authorization': 'secret',
        'Cookie': 'secret',
        'User-Agent': 'BStream-test',
      },
      contentType: 'audio/mp4',
    );
    final response = await get(url);
    expect(utf8.decode(response.bytes), 'ok');
  });

  test(
    'stop cancels a streaming upstream download instead of finishing it',
    () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      final disconnected = Completer<void>();
      Timer? pump;
      upstream.listen((request) async {
        // Observe the TCP read half closing: HttpResponse.done only completes
        // when a server explicitly closes its own response.
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.listen(
          (_) {},
          onDone: () {
            pump?.cancel();
            if (!disconnected.isCompleted) disconnected.complete();
            socket.destroy();
          },
          onError: (Object _) {
            pump?.cancel();
            if (!disconnected.isCompleted) disconnected.complete();
          },
        );
        socket.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\nContent-Type: audio/mp4\r\nTransfer-Encoding: chunked\r\n\r\n',
          ),
        );
        void chunk() {
          socket.add(utf8.encode('800\r\n'));
          socket.add(List.filled(2048, 7));
          socket.add(utf8.encode('\r\n'));
          unawaited(socket.flush().catchError((_) {}));
        }

        chunk();
        pump = Timer.periodic(const Duration(milliseconds: 30), (_) => chunk());
      });
      addTearDown(() => pump?.cancel());
      final url = await relay.startForRemote(
        source: Uri.parse('http://127.0.0.1:${upstream.port}/endless'),
        contentType: 'audio/mp4',
      );
      final request = await client.getUrl(url);
      final response = await request.close();
      final download = response.drain<void>().catchError((_) {});
      await relay.stop();
      await download.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw StateError('receiver not cancelled'),
      );
      await disconnected.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw StateError('upstream not cancelled'),
      );
      expect(relay.isRunning, isFalse);
    },
  );

  test(
    'does not expose arbitrary source schemes or nonexistent files',
    () async {
      await expectLater(
        relay.startForRemote(
          source: Uri.parse('file:///secret'),
          contentType: 'audio/mp4',
        ),
        throwsArgumentError,
      );
      await expectLater(
        relay.startForFile(
          path: '${temporary.path}/missing',
          contentType: 'audio/mp4',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(relay.isRunning, isFalse);
    },
  );
}
