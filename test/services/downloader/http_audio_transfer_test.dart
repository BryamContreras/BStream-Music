import 'dart:async';
import 'dart:io';

import 'package:bstream_music/services/downloader/http_audio_transfer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryDirectory;
  late File destination;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'http_audio_transfer_test_',
    );
    destination = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}track.mp3',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('downloads with caller headers and reports progress', () async {
    final payload = <int>[0x49, 0x44, 0x33, 1, 2, 3, 4, 5];
    String? receivedHeader;
    String? receivedMethod;
    final server = await _startServer((request) async {
      receivedHeader = request.headers.value('x-audio-token');
      receivedMethod = request.method;
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(payload);
      await request.response.close();
    });
    addTearDown(server.close);
    final progress = <HttpAudioTransferProgress>[];

    final result = await HttpAudioTransfer().download(
      uri: server.uri,
      destination: destination,
      headers: const <String, String>{'X-Audio-Token': 'secret'},
      onProgress: progress.add,
    );

    expect(receivedMethod, 'GET');
    expect(receivedHeader, 'secret');
    expect(await destination.readAsBytes(), payload);
    expect(
      await HttpAudioTransfer.partialFileFor(destination).exists(),
      isFalse,
    );
    expect(result.file.path, destination.path);
    expect(result.length, payload.length);
    expect(result.attempts, 1);
    expect(result.resumed, isFalse);
    expect(progress.first.transferredBytes, 0);
    expect(progress.first.totalBytes, payload.length);
    expect(progress.last.transferredBytes, payload.length);
    expect(progress.last.fraction, 1);
  });

  test('resumes a .part file with a validated byte range', () async {
    final payload = <int>[0x49, 0x44, 0x33, 10, 11, 12, 13, 14, 15, 16];
    const partialLength = 4;
    final partFile = HttpAudioTransfer.partialFileFor(destination);
    await partFile.writeAsBytes(payload.take(partialLength).toList());
    String? rangeHeader;
    final server = await _startServer((request) async {
      rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final remaining = payload.sublist(partialLength);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = remaining.length
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $partialLength-${payload.length - 1}/${payload.length}',
        )
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(remaining);
      await request.response.close();
    });
    addTearDown(server.close);
    final progress = <HttpAudioTransferProgress>[];

    final result = await HttpAudioTransfer().download(
      uri: server.uri,
      destination: destination,
      headers: const <String, String>{HttpHeaders.ifRangeHeader: '"entity-v1"'},
      onProgress: progress.add,
    );

    expect(rangeHeader, 'bytes=$partialLength-');
    expect(await destination.readAsBytes(), payload);
    expect(result.resumed, isTrue);
    expect(progress.first.transferredBytes, partialLength);
    expect(progress.first.totalBytes, payload.length);
    expect(progress.first.resumed, isTrue);
  });

  test(
    'restarts safely when the server ignores Range and returns 200',
    () async {
      final payload = <int>[0x49, 0x44, 0x33, 20, 21, 22, 23];
      final partFile = HttpAudioTransfer.partialFileFor(destination);
      await partFile.writeAsBytes(<int>[0x49, 0x44, 0x33, 99]);
      String? rangeHeader;
      final server = await _startServer((request) async {
        rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = payload.length
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..add(payload);
        await request.response.close();
      });
      addTearDown(server.close);

      final result = await HttpAudioTransfer().download(
        uri: server.uri,
        destination: destination,
        headers: const <String, String>{
          HttpHeaders.ifRangeHeader: '"entity-v1"',
        },
      );

      expect(rangeHeader, 'bytes=4-');
      expect(await destination.readAsBytes(), payload);
      expect(result.resumed, isFalse);
    },
  );

  test('restarts safely when a legacy part has no validator', () async {
    final payload = <int>[0x49, 0x44, 0x33, 31, 32, 33, 34];
    final partFile = HttpAudioTransfer.partialFileFor(destination);
    await partFile.writeAsBytes(<int>[0x49, 0x44, 0x33, 99]);
    String? rangeHeader;
    final server = await _startServer((request) async {
      rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(payload);
      await request.response.close();
    });
    addTearDown(server.close);

    final result = await HttpAudioTransfer().download(
      uri: server.uri,
      destination: destination,
    );

    expect(rangeHeader, isNull);
    expect(await destination.readAsBytes(), payload);
    expect(result.resumed, isFalse);
  });

  test(
    'rejects a mismatched Content-Range without changing partial data',
    () async {
      final partFile = HttpAudioTransfer.partialFileFor(destination);
      final partial = <int>[0x49, 0x44, 0x33, 1];
      await partFile.writeAsBytes(partial);
      final server = await _startServer((request) async {
        final body = <int>[2, 3, 4, 5];
        request.response
          ..statusCode = HttpStatus.partialContent
          ..contentLength = body.length
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 3-6/7')
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..add(body);
        await request.response.close();
      });
      addTearDown(server.close);

      await expectLater(
        HttpAudioTransfer(maxRetries: 0).download(
          uri: server.uri,
          destination: destination,
          headers: const <String, String>{
            HttpHeaders.ifRangeHeader: '"entity-v1"',
          },
        ),
        throwsA(
          isA<HttpAudioTransferException>().having(
            (error) => error.kind,
            'kind',
            HttpAudioTransferFailureKind.invalidRange,
          ),
        ),
      );

      expect(await partFile.readAsBytes(), partial);
      expect(await destination.exists(), isFalse);
    },
  );

  test('rejects a 206 range whose total length is unknown', () async {
    final partFile = HttpAudioTransfer.partialFileFor(destination);
    final partial = <int>[0x49, 0x44, 0x33];
    await partFile.writeAsBytes(partial);
    final server = await _startServer((request) async {
      final body = <int>[1, 2, 3];
      request.response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = body.length
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 3-5/*')
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(body);
      await request.response.close();
    });
    addTearDown(server.close);

    await expectLater(
      HttpAudioTransfer(maxRetries: 0).download(
        uri: server.uri,
        destination: destination,
        headers: const <String, String>{
          HttpHeaders.ifRangeHeader: '"entity-v1"',
        },
      ),
      throwsA(
        isA<HttpAudioTransferException>().having(
          (error) => error.kind,
          'kind',
          HttpAudioTransferFailureKind.invalidRange,
        ),
      ),
    );

    expect(await partFile.readAsBytes(), partial);
  });

  test('does not append bytes beyond the declared Content-Range', () async {
    final partFile = HttpAudioTransfer.partialFileFor(destination);
    final partial = <int>[0x49, 0x44, 0x33];
    await partFile.writeAsBytes(partial);
    final server = await _startServer((request) async {
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 3-5/6')
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(<int>[1, 2, 3, 4]);
      await request.response.close();
    });
    addTearDown(server.close);

    await expectLater(
      HttpAudioTransfer(maxRetries: 0).download(
        uri: server.uri,
        destination: destination,
        headers: const <String, String>{
          HttpHeaders.ifRangeHeader: '"entity-v1"',
        },
      ),
      throwsA(
        isA<HttpAudioTransferException>().having(
          (error) => error.kind,
          'kind',
          HttpAudioTransferFailureKind.invalidResponse,
        ),
      ),
    );

    expect(await partFile.readAsBytes(), partial);
  });

  test('promotes an already complete part confirmed by HTTP 416', () async {
    final payload = <int>[0x49, 0x44, 0x33, 1, 2, 3];
    final partFile = HttpAudioTransfer.partialFileFor(destination);
    await partFile.writeAsBytes(payload);
    String? rangeHeader;
    final server = await _startServer((request) async {
      rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      request.response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.etagHeader, '"entity-v1"')
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${payload.length}',
        );
      await request.response.close();
    });
    addTearDown(server.close);

    final result = await HttpAudioTransfer(maxRetries: 0).download(
      uri: server.uri,
      destination: destination,
      headers: const <String, String>{HttpHeaders.ifRangeHeader: '"entity-v1"'},
    );

    expect(rangeHeader, 'bytes=${payload.length}-');
    expect(await destination.readAsBytes(), payload);
    expect(await partFile.exists(), isFalse);
    expect(result.resumed, isTrue);
  });

  test(
    'does not promote a same-length part after 416 without a strong ETag',
    () async {
      final stale = <int>[0x49, 0x44, 0x33, 9, 9, 9];
      final current = <int>[0x49, 0x44, 0x33, 1, 2, 3];
      final partFile = HttpAudioTransfer.partialFileFor(destination);
      await partFile.writeAsBytes(stale);
      final ranges = <String?>[];
      final server = await _startServer((request) async {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        if (ranges.length == 1) {
          request.response
            ..statusCode = HttpStatus.requestedRangeNotSatisfiable
            ..headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */${current.length}',
            );
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..contentLength = current.length
            ..headers.contentType = ContentType('audio', 'mpeg')
            ..add(current);
        }
        await request.response.close();
      });
      addTearDown(server.close);

      final result =
          await HttpAudioTransfer(
            maxRetries: 1,
            retryDelay: Duration.zero,
          ).download(
            uri: server.uri,
            destination: destination,
            headers: const <String, String>{
              HttpHeaders.ifRangeHeader: 'W/"entity-v1"',
            },
          );

      expect(ranges, <String?>['bytes=${stale.length}-', null]);
      expect(await destination.readAsBytes(), current);
      expect(result.attempts, 2);
      expect(result.resumed, isFalse);
    },
  );

  test(
    'restarts a same-length part when 416 omits the expected strong ETag',
    () async {
      final stale = <int>[0x49, 0x44, 0x33, 9, 9, 9];
      final current = <int>[0x49, 0x44, 0x33, 1, 2, 3];
      final partFile = HttpAudioTransfer.partialFileFor(destination);
      await partFile.writeAsBytes(stale);
      final ranges = <String?>[];
      final server = await _startServer((request) async {
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        if (ranges.length == 1) {
          request.response
            ..statusCode = HttpStatus.requestedRangeNotSatisfiable
            ..headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */${current.length}',
            );
        } else {
          request.response
            ..statusCode = HttpStatus.ok
            ..contentLength = current.length
            ..headers.contentType = ContentType('audio', 'mpeg')
            ..headers.set(HttpHeaders.etagHeader, '"entity-v2"')
            ..add(current);
        }
        await request.response.close();
      });
      addTearDown(server.close);

      final result =
          await HttpAudioTransfer(
            maxRetries: 1,
            retryDelay: Duration.zero,
          ).download(
            uri: server.uri,
            destination: destination,
            headers: const <String, String>{
              HttpHeaders.ifRangeHeader: '"entity-v1"',
            },
          );

      expect(ranges, <String?>['bytes=${stale.length}-', null]);
      expect(await destination.readAsBytes(), current);
      expect(result.attempts, 2);
      expect(result.resumed, isFalse);
    },
  );

  test('restarts when the remote entity is shorter than the partial', () async {
    final stale = <int>[0x49, 0x44, 0x33, 9, 9, 9, 9, 9];
    final current = <int>[0x49, 0x44, 0x33, 1, 2, 3];
    final partFile = HttpAudioTransfer.partialFileFor(destination);
    await partFile.writeAsBytes(stale);
    final ranges = <String?>[];
    final server = await _startServer((request) async {
      ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      if (ranges.length == 1) {
        request.response
          ..statusCode = HttpStatus.requestedRangeNotSatisfiable
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${current.length}',
          );
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = current.length
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..headers.set(HttpHeaders.etagHeader, '"entity-v2"')
          ..add(current);
      }
      await request.response.close();
    });
    addTearDown(server.close);

    final result =
        await HttpAudioTransfer(
          maxRetries: 1,
          retryDelay: Duration.zero,
        ).download(
          uri: server.uri,
          destination: destination,
          headers: const <String, String>{
            HttpHeaders.ifRangeHeader: '"entity-v1"',
          },
        );

    expect(ranges, <String?>['bytes=${stale.length}-', null]);
    expect(await destination.readAsBytes(), current);
    expect(result.attempts, 2);
    expect(result.resumed, isFalse);
  });

  test('exposes status and URL refresh policy for HTTP failures', () async {
    final statuses = <int>[
      HttpStatus.forbidden,
      HttpStatus.gone,
      HttpStatus.notFound,
    ];
    var requestIndex = 0;
    final server = await _startServer((request) async {
      request.response.statusCode = statuses[requestIndex++];
      await request.response.close();
    });
    addTearDown(server.close);
    final transfer = HttpAudioTransfer(maxRetries: 0);

    for (var index = 0; index < statuses.length; index++) {
      final currentDestination = File(
        '${temporaryDirectory.path}${Platform.pathSeparator}status-$index.mp3',
      );
      final partFile = HttpAudioTransfer.partialFileFor(currentDestination);
      await partFile.writeAsBytes(<int>[0x49, 0x44, 0x33]);

      Object? caught;
      try {
        await transfer.download(
          uri: server.uri,
          destination: currentDestination,
        );
      } catch (error) {
        caught = error;
      }

      expect(caught, isA<HttpAudioTransferException>());
      final exception = caught! as HttpAudioTransferException;
      expect(exception.statusCode, statuses[index]);
      expect(
        exception.shouldRefreshUrl,
        statuses[index] == HttpStatus.forbidden ||
            statuses[index] == HttpStatus.gone,
      );
      expect(await partFile.readAsBytes(), <int>[0x49, 0x44, 0x33]);
    }
  });

  test('retries rate limits and transient server responses', () async {
    final payload = <int>[
      0x49,
      0x44,
      0x33,
      ...List<int>.generate(32, (i) => i),
    ];
    var requestCount = 0;
    final server = await _startServer((request) async {
      requestCount += 1;
      if (requestCount == 1) {
        request.response.statusCode = HttpStatus.tooManyRequests;
      } else if (requestCount == 2) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
      } else {
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = payload.length
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..add(payload);
      }
      await request.response.close();
    });
    addTearDown(server.close);

    final result = await HttpAudioTransfer(
      maxRetries: 2,
      retryDelay: Duration.zero,
    ).download(uri: server.uri, destination: destination);

    expect(result.attempts, 3);
    expect(requestCount, 3);
    expect(await destination.readAsBytes(), payload);
  });

  test('preserves transient HTTP status after retry exhaustion', () async {
    var requestCount = 0;
    final server = await _startServer((request) async {
      requestCount += 1;
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    });
    addTearDown(server.close);

    Object? caught;
    try {
      await HttpAudioTransfer(
        maxRetries: 1,
        retryDelay: Duration.zero,
      ).download(uri: server.uri, destination: destination);
    } catch (error) {
      caught = error;
    }

    expect(caught, isA<HttpAudioTransferException>());
    expect(
      (caught! as HttpAudioTransferException).statusCode,
      HttpStatus.serviceUnavailable,
    );
    expect(requestCount, 2);
  });

  test('rejects HTML by content type and preserves an existing part', () async {
    final partFile = HttpAudioTransfer.partialFileFor(destination);
    final partial = <int>[0x49, 0x44, 0x33, 1];
    await partFile.writeAsBytes(partial);
    final server = await _startServer((request) async {
      final body = '<html>expired</html>'.codeUnits;
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = body.length
        ..headers.contentType = ContentType.html
        ..add(body);
      await request.response.close();
    });
    addTearDown(server.close);

    await expectLater(
      HttpAudioTransfer(
        maxRetries: 0,
      ).download(uri: server.uri, destination: destination),
      throwsA(
        isA<HttpAudioTransferException>().having(
          (error) => error.kind,
          'kind',
          HttpAudioTransferFailureKind.invalidContent,
        ),
      ),
    );

    expect(await partFile.readAsBytes(), partial);
  });

  test('sniffs and rejects JSON disguised as audio', () async {
    final server = await _startServer((request) async {
      final body = ' \r\n {"error":"expired"}'.codeUnits;
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = body.length
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(body);
      await request.response.close();
    });
    addTearDown(server.close);

    await expectLater(
      HttpAudioTransfer(
        maxRetries: 0,
      ).download(uri: server.uri, destination: destination),
      throwsA(
        isA<HttpAudioTransferException>().having(
          (error) => error.kind,
          'kind',
          HttpAudioTransferFailureKind.invalidContent,
        ),
      ),
    );

    expect(await destination.exists(), isFalse);
    expect(
      await HttpAudioTransfer.partialFileFor(destination).exists(),
      isFalse,
    );
  });

  test('retries an idle network response and resumes the saved bytes', () async {
    final payload = List<int>.generate(32 * 1024, (index) => index & 0xff)
      ..setRange(0, 3, <int>[0x49, 0x44, 0x33]);
    const firstChunkLength = 16 * 1024;
    var requests = 0;
    final ranges = <String?>[];
    final ifRanges = <String?>[];
    final server = await _startServer((request) async {
      requests++;
      ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      ifRanges.add(request.headers.value(HttpHeaders.ifRangeHeader));
      if (requests == 1) {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..headers.set(HttpHeaders.etagHeader, '"entity-v1"')
          ..add(payload.take(firstChunkLength).toList());
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          await request.response.close();
        } on Object {
          // The client is expected to abort this deliberately stalled request.
        }
        return;
      }

      final remaining = payload.sublist(firstChunkLength);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = remaining.length
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $firstChunkLength-${payload.length - 1}/${payload.length}',
        )
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..headers.set(HttpHeaders.etagHeader, '"entity-v1"')
        ..add(remaining);
      await request.response.close();
    });
    addTearDown(server.close);
    var clientsCreated = 0;

    final result = await HttpAudioTransfer(
      clientFactory: () {
        clientsCreated++;
        return HttpClient();
      },
      idleTimeout: const Duration(milliseconds: 100),
      totalTimeout: const Duration(seconds: 3),
      retryDelay: Duration.zero,
      maxRetries: 1,
    ).download(uri: server.uri, destination: destination);

    expect(await destination.readAsBytes(), payload);
    expect(requests, 2);
    expect(clientsCreated, 2);
    expect(ranges, <String?>[null, 'bytes=$firstChunkLength-']);
    expect(ifRanges, <String?>[null, '"entity-v1"']);
    expect(result.attempts, 2);
    expect(result.resumed, isTrue);
    expect(await File('${destination.path}.part.if-range').exists(), isFalse);
  });

  test('persists If-Range metadata across transfer instances', () async {
    final payload = List<int>.generate(32 * 1024, (index) => index & 0xff)
      ..setRange(0, 3, <int>[0x49, 0x44, 0x33]);
    const firstChunkLength = 16 * 1024;
    var requests = 0;
    String? resumedRange;
    String? resumedIfRange;
    final server = await _startServer((request) async {
      requests++;
      if (requests == 1) {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..headers.set(HttpHeaders.etagHeader, '"persisted-v1"')
          ..add(payload.take(firstChunkLength).toList());
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          await request.response.close();
        } on Object {
          // The first transfer intentionally times out with a saved partial.
        }
        return;
      }

      resumedRange = request.headers.value(HttpHeaders.rangeHeader);
      resumedIfRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final remaining = payload.sublist(firstChunkLength);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..contentLength = remaining.length
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $firstChunkLength-${payload.length - 1}/${payload.length}',
        )
        ..headers.set(HttpHeaders.etagHeader, '"persisted-v1"')
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(remaining);
      await request.response.close();
    });
    addTearDown(server.close);

    await expectLater(
      HttpAudioTransfer(
        maxRetries: 0,
        idleTimeout: const Duration(milliseconds: 100),
        totalTimeout: const Duration(seconds: 2),
      ).download(uri: server.uri, destination: destination),
      throwsA(
        isA<HttpAudioTransferException>().having(
          (error) => error.kind,
          'kind',
          HttpAudioTransferFailureKind.idleTimeout,
        ),
      ),
    );
    expect(
      await HttpAudioTransfer.partialFileFor(destination).length(),
      firstChunkLength,
    );

    final result = await HttpAudioTransfer(
      maxRetries: 0,
    ).download(uri: server.uri, destination: destination);

    expect(resumedRange, 'bytes=$firstChunkLength-');
    expect(resumedIfRange, '"persisted-v1"');
    expect(await destination.readAsBytes(), payload);
    expect(result.resumed, isTrue);
    expect(await File('${destination.path}.part.if-range').exists(), isFalse);
  });

  test('applies the connection timeout while waiting for headers', () async {
    final server = await _startServer((request) async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..add(<int>[0x49, 0x44, 0x33]);
        await request.response.close();
      } on Object {
        // The connection-phase watchdog closes the request before this point.
      }
    });
    addTearDown(server.close);

    await expectLater(
      HttpAudioTransfer(
        maxRetries: 0,
        connectionTimeout: const Duration(milliseconds: 100),
        totalTimeout: const Duration(seconds: 2),
      ).download(uri: server.uri, destination: destination),
      throwsA(
        isA<HttpAudioTransferException>().having(
          (error) => error.kind,
          'kind',
          HttpAudioTransferFailureKind.connectionTimeout,
        ),
      ),
    );

    expect(await destination.exists(), isFalse);
  });

  test('does not retry exceptions thrown by the progress callback', () async {
    final payload = <int>[0x49, 0x44, 0x33, 1, 2, 3];
    final server = await _startServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(payload);
      await request.response.close();
    });
    addTearDown(server.close);
    final callbackError = TimeoutException('consumer stopped');
    var clientsCreated = 0;

    await expectLater(
      HttpAudioTransfer(
        clientFactory: () {
          clientsCreated++;
          return HttpClient();
        },
        maxRetries: 2,
      ).download(
        uri: server.uri,
        destination: destination,
        onProgress: (_) => throw callbackError,
      ),
      throwsA(same(callbackError)),
    );

    expect(clientsCreated, 1);
  });

  test('rejects concurrent writers for the same destination', () async {
    final payload = <int>[0x49, 0x44, 0x33, 1, 2, 3];
    final requestStarted = Completer<void>();
    final releaseResponse = Completer<void>();
    var requests = 0;
    final server = await _startServer((request) async {
      requests++;
      if (!requestStarted.isCompleted) {
        requestStarted.complete();
      }
      await releaseResponse.future;
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(payload);
      await request.response.close();
    });
    addTearDown(server.close);
    final firstTransfer = HttpAudioTransfer().download(
      uri: server.uri,
      destination: destination,
    );
    await requestStarted.future;

    await expectLater(
      HttpAudioTransfer().download(uri: server.uri, destination: destination),
      throwsA(
        isA<HttpAudioTransferException>().having(
          (error) => error.kind,
          'kind',
          HttpAudioTransferFailureKind.destinationBusy,
        ),
      ),
    );

    releaseResponse.complete();
    await firstTransfer;
    expect(requests, 1);
    expect(await destination.readAsBytes(), payload);
  });

  test('cancellation keeps the partial file for a later call', () async {
    final firstChunk = <int>[0x49, 0x44, 0x33, 1, 2, 3];
    final secondChunk = <int>[4, 5, 6, 7, 8, 9];
    final server = await _startServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(firstChunk);
      await request.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        request.response.add(secondChunk);
        await request.response.close();
      } on Object {
        // Cancellation intentionally closes the connection.
      }
    });
    addTearDown(server.close);
    var cancelled = false;

    await expectLater(
      HttpAudioTransfer(
        maxRetries: 0,
        totalTimeout: const Duration(seconds: 3),
        cancellationPollInterval: const Duration(milliseconds: 10),
      ).download(
        uri: server.uri,
        destination: destination,
        isCancelled: () => cancelled,
        onProgress: (progress) {
          if (progress.transferredBytes >= firstChunk.length) {
            cancelled = true;
          }
        },
      ),
      throwsA(
        isA<HttpAudioTransferException>().having(
          (error) => error.kind,
          'kind',
          HttpAudioTransferFailureKind.cancelled,
        ),
      ),
    );

    expect(
      await HttpAudioTransfer.partialFileFor(destination).readAsBytes(),
      firstChunk,
    );
    expect(await destination.exists(), isFalse);
  });

  test('checks cancellation again before promoting a complete part', () async {
    final payload = <int>[0x49, 0x44, 0x33, 1, 2, 3];
    final server = await _startServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(payload);
      await request.response.close();
    });
    addTearDown(server.close);
    var cancelled = false;

    await expectLater(
      HttpAudioTransfer(maxRetries: 0).download(
        uri: server.uri,
        destination: destination,
        isCancelled: () => cancelled,
        onProgress: (progress) {
          if (progress.transferredBytes == payload.length) {
            cancelled = true;
          }
        },
      ),
      throwsA(
        isA<HttpAudioTransferException>().having(
          (error) => error.kind,
          'kind',
          HttpAudioTransferFailureKind.cancelled,
        ),
      ),
    );

    expect(
      await HttpAudioTransfer.partialFileFor(destination).readAsBytes(),
      payload,
    );
    expect(await destination.exists(), isFalse);
  });

  test(
    'total timeout aborts an active stream and keeps partial bytes',
    () async {
      final initialChunk = List<int>.filled(16 * 1024, 1)
        ..setRange(0, 3, <int>[0x49, 0x44, 0x33]);
      final server = await _startServer((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('audio', 'mpeg');
        try {
          request.response.add(initialChunk);
          await request.response.flush();
          for (var index = 0; index < 20; index++) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            request.response.add(<int>[index]);
            await request.response.flush();
          }
          await request.response.close();
        } on Object {
          // The total-time watchdog is expected to close this response early.
        }
      });
      addTearDown(server.close);

      await expectLater(
        HttpAudioTransfer(
          maxRetries: 0,
          idleTimeout: const Duration(seconds: 2),
          totalTimeout: const Duration(milliseconds: 300),
        ).download(uri: server.uri, destination: destination),
        throwsA(
          isA<HttpAudioTransferException>().having(
            (error) => error.kind,
            'kind',
            HttpAudioTransferFailureKind.totalTimeout,
          ),
        ),
      );

      final partFile = HttpAudioTransfer.partialFileFor(destination);
      expect(await partFile.exists(), isTrue);
      expect(
        await partFile.length(),
        greaterThanOrEqualTo(initialChunk.length),
      );
      expect(await destination.exists(), isFalse);
    },
  );

  test('does not wrap FileSystemException', () async {
    final blockingFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}not-a-directory',
    );
    await blockingFile.writeAsString('blocking');
    final invalidDestination = File(
      '${blockingFile.path}${Platform.pathSeparator}track.mp3',
    );

    await expectLater(
      HttpAudioTransfer(maxRetries: 0).download(
        uri: Uri.parse('http://127.0.0.1:1/audio'),
        destination: invalidDestination,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'does not wrap FileSystemException while opening the part file',
    () async {
      final partPath = HttpAudioTransfer.partialFileFor(destination).path;
      await Directory(partPath).create();
      final payload = <int>[0x49, 0x44, 0x33, 1];
      final server = await _startServer((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = payload.length
          ..headers.contentType = ContentType('audio', 'mpeg')
          ..add(payload);
        await request.response.close();
      });
      addTearDown(server.close);

      await expectLater(
        HttpAudioTransfer(
          maxRetries: 0,
        ).download(uri: server.uri, destination: destination),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('does not wrap FileSystemException from final promotion', () async {
    await Directory(destination.path).create();
    final payload = <int>[0x49, 0x44, 0x33, 1];
    final server = await _startServer((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..contentLength = payload.length
        ..headers.contentType = ContentType('audio', 'mpeg')
        ..add(payload);
      await request.response.close();
    });
    addTearDown(server.close);

    await expectLater(
      HttpAudioTransfer(
        maxRetries: 0,
      ).download(uri: server.uri, destination: destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await HttpAudioTransfer.partialFileFor(destination).exists(),
      isTrue,
    );
  });
}

class _LocalAudioServer {
  _LocalAudioServer(this._server);

  final HttpServer _server;

  Uri get uri =>
      Uri.parse('http://${_server.address.address}:${_server.port}/audio');

  Future<void> close() => _server.close(force: true);
}

Future<_LocalAudioServer> _startServer(
  FutureOr<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    await handler(request);
  });
  return _LocalAudioServer(server);
}
