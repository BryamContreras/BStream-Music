import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class ByteStreamLimitException implements Exception {
  const ByteStreamLimitException({
    required this.maximumBytes,
    required this.receivedBytes,
  });

  final int maximumBytes;
  final int receivedBytes;

  @override
  String toString() {
    return 'La respuesta remota excede el límite de $maximumBytes bytes '
        '(recibidos: $receivedBytes).';
  }
}

Future<Uint8List> collectBoundedByteStream(
  Stream<List<int>> stream, {
  required int maximumBytes,
  int? declaredLength,
  required Duration idleTimeout,
  required Duration totalTimeout,
}) async {
  final bytes = BytesBuilder(copy: false);
  await consumeBoundedByteStream(
    stream,
    maximumBytes: maximumBytes,
    declaredLength: declaredLength,
    idleTimeout: idleTimeout,
    totalTimeout: totalTimeout,
    onChunk: (chunk) {
      bytes.add(chunk);
    },
  );
  return bytes.takeBytes();
}

Future<int> writeBoundedByteStreamToFile(
  Stream<List<int>> stream,
  File destination, {
  required int maximumBytes,
  int? declaredLength,
  required Duration idleTimeout,
  required Duration totalTimeout,
}) async {
  await destination.parent.create(recursive: true);
  final output = await destination.open(mode: FileMode.write);
  try {
    return await consumeBoundedByteStream(
      stream,
      maximumBytes: maximumBytes,
      declaredLength: declaredLength,
      idleTimeout: idleTimeout,
      totalTimeout: totalTimeout,
      onChunk: output.writeFrom,
    );
  } finally {
    await output.close();
  }
}

Future<int> consumeBoundedByteStream(
  Stream<List<int>> stream, {
  required int maximumBytes,
  int? declaredLength,
  required Duration idleTimeout,
  required Duration totalTimeout,
  required FutureOr<void> Function(List<int> chunk) onChunk,
}) async {
  if (maximumBytes <= 0) {
    throw ArgumentError.value(
      maximumBytes,
      'maximumBytes',
      'Must be positive.',
    );
  }
  if (idleTimeout <= Duration.zero) {
    throw ArgumentError.value(idleTimeout, 'idleTimeout', 'Must be positive.');
  }
  if (totalTimeout <= Duration.zero) {
    throw ArgumentError.value(
      totalTimeout,
      'totalTimeout',
      'Must be positive.',
    );
  }
  if (declaredLength != null && declaredLength > maximumBytes) {
    throw ByteStreamLimitException(
      maximumBytes: maximumBytes,
      receivedBytes: declaredLength,
    );
  }

  final watch = Stopwatch()..start();
  final iterator = StreamIterator<List<int>>(stream);
  var receivedBytes = 0;
  try {
    while (true) {
      final remaining = totalTimeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'La transferencia excedió su tiempo total.',
          totalTimeout,
        );
      }
      final nextTimeout = remaining < idleTimeout ? remaining : idleTimeout;
      final hasNext = await iterator.moveNext().timeout(
        nextTimeout,
        onTimeout: () {
          throw TimeoutException(
            'La transferencia dejó de recibir datos.',
            nextTimeout,
          );
        },
      );
      if (!hasNext) {
        return receivedBytes;
      }

      final chunk = iterator.current;
      receivedBytes += chunk.length;
      if (receivedBytes > maximumBytes) {
        throw ByteStreamLimitException(
          maximumBytes: maximumBytes,
          receivedBytes: receivedBytes,
        );
      }
      await onChunk(chunk);
    }
  } finally {
    await iterator.cancel();
  }
}
