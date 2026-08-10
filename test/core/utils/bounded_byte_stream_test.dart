import 'dart:async';
import 'dart:io';

import 'package:bstream_music/core/utils/bounded_byte_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('collects a response that stays within its byte limit', () async {
    final bytes = await collectBoundedByteStream(
      Stream.fromIterable(const [
        [1, 2],
        [3, 4],
      ]),
      maximumBytes: 4,
      declaredLength: 4,
      idleTimeout: const Duration(seconds: 1),
      totalTimeout: const Duration(seconds: 2),
    );

    expect(bytes, [1, 2, 3, 4]);
  });

  test('rejects declared and streamed bodies above the byte limit', () async {
    await expectLater(
      collectBoundedByteStream(
        const Stream<List<int>>.empty(),
        maximumBytes: 4,
        declaredLength: 5,
        idleTimeout: const Duration(seconds: 1),
        totalTimeout: const Duration(seconds: 2),
      ),
      throwsA(isA<ByteStreamLimitException>()),
    );

    await expectLater(
      collectBoundedByteStream(
        Stream.value(const [1, 2, 3, 4, 5]),
        maximumBytes: 4,
        idleTimeout: const Duration(seconds: 1),
        totalTimeout: const Duration(seconds: 2),
      ),
      throwsA(isA<ByteStreamLimitException>()),
    );
  });

  test('writes bounded streams incrementally to a file', () async {
    final directory = await Directory.systemTemp.createTemp(
      'bstream-bounded-stream-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final output = File('${directory.path}/response.bin');

    final written = await writeBoundedByteStreamToFile(
      Stream.fromIterable(const [
        [1, 2],
        [3, 4],
      ]),
      output,
      maximumBytes: 4,
      idleTimeout: const Duration(seconds: 1),
      totalTimeout: const Duration(seconds: 2),
    );

    expect(written, 4);
    expect(await output.readAsBytes(), [1, 2, 3, 4]);
  });

  test('enforces the idle timeout', () async {
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);

    await expectLater(
      collectBoundedByteStream(
        controller.stream,
        maximumBytes: 4,
        idleTimeout: const Duration(milliseconds: 20),
        totalTimeout: const Duration(seconds: 1),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });
}
