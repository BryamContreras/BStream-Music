import 'dart:io';

import 'package:bstream_music/services/youtube_music/playback/innertube_stream_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validates a ranged response beyond the cold-start allowance', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.rangeHeader),
        'bytes=3145728-3178495',
      );
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.contentType = ContentType('audio', 'mp4')
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 3145728-3178495/5242880',
        )
        ..add(List<int>.filled(32 * 1024, 1));
      await request.response.close();
    });

    final validator = IoInnerTubeStreamValidator();
    final probe = await validator.validate(
      Uri.parse('http://127.0.0.1:${server.port}/audio'),
      headers: const {'User-Agent': 'BStream test'},
      contentLength: 5 * 1024 * 1024,
    );

    expect(probe.statusCode, HttpStatus.partialContent);
    expect(probe.probedOffset, 3 * 1024 * 1024);
    expect(probe.contentLength, 5 * 1024 * 1024);
    expect(probe.receivedBytes, greaterThan(0));
  });

  test('does not sniff arbitrary deep 206 bytes as a text prefix', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.contentType = ContentType('audio', 'mp4')
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 3145728-3145738/5242880',
        )
        // These are media bytes at a random offset, not a file prefix.
        ..add('<not-text>'.codeUnits);
      await request.response.close();
    });

    final probe = await IoInnerTubeStreamValidator(probeBytes: 11).validate(
      Uri.parse('http://127.0.0.1:${server.port}/audio'),
      headers: const {},
      contentLength: 5 * 1024 * 1024,
    );

    expect(probe.statusCode, HttpStatus.partialContent);
    expect(probe.probedOffset, 3 * 1024 * 1024);
  });

  test(
    'reprobes the last byte when an unknown short stream returns 416',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final ranges = <String?>[];
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        if (ranges.length == 1) {
          request.response
            ..statusCode = HttpStatus.requestedRangeNotSatisfiable
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */128');
        } else {
          request.response
            ..statusCode = HttpStatus.partialContent
            ..headers.contentType = ContentType('audio', 'mp4')
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 127-127/128')
            ..add(const <int>[0x3c]);
        }
        await request.response.close();
      });

      final probe = await IoInnerTubeStreamValidator().validate(
        Uri.parse('http://127.0.0.1:${server.port}/short-audio'),
        headers: const {},
      );

      expect(ranges, <String?>['bytes=3145728-3178495', 'bytes=127-127']);
      expect(probe.statusCode, HttpStatus.partialContent);
      expect(probe.probedOffset, 127);
      expect(probe.contentLength, 128);
      expect(probe.receivedBytes, 1);
    },
  );

  test('marks an HTTP 403 as requiring a fresh URL', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    });

    final validator = IoInnerTubeStreamValidator(deepProbeOffset: 64);
    final future = validator.validate(
      Uri.parse('http://127.0.0.1:${server.port}/audio'),
      headers: const {},
    );

    await expectLater(
      future,
      throwsA(
        isA<InnerTubeStreamValidationException>()
            .having((error) => error.statusCode, 'statusCode', 403)
            .having((error) => error.shouldRefreshUrl, 'shouldRefreshUrl', true)
            .having(
              (error) => error.isPoTokenRejection,
              'isPoTokenRejection',
              true,
            ),
      ),
    );
  });

  test('does not treat rate limiting as a PO-token binding rejection', () {
    const error = InnerTubeStreamValidationException(
      'rate limited',
      statusCode: HttpStatus.tooManyRequests,
    );

    expect(error.shouldRefreshUrl, isTrue);
    expect(error.isPoTokenRejection, isFalse);
  });

  test('consumes through the deep offset when Range is ignored', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('audio', 'webm')
        ..add(List<int>.filled(2048, 1));
      await request.response.close();
    });

    final validator = IoInnerTubeStreamValidator(deepProbeOffset: 1024);
    final probe = await validator.validate(
      Uri.parse('http://127.0.0.1:${server.port}/audio'),
      headers: const {},
    );

    expect(probe.statusCode, HttpStatus.ok);
    expect(probe.probedOffset, 1024);
    expect(probe.receivedBytes, greaterThanOrEqualTo(1025));
  });
}
