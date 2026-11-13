import 'dart:io';
import 'dart:typed_data';

import 'audio_metadata_fields.dart';

int _temporarySequence = 0;

/// Publishes a prepared metadata edit only after validation, without overwriting
/// an original that changed while the edit was being prepared.
///
/// Runs synchronously inside the shared background runner. The callback must
/// preserve audio samples and return [AudioMetadataWriteResult.written] only
/// when it has written the complete candidate. Other results discard that file.
AudioMetadataWriteResult rewriteAudioMetadataFile(
  File source, {
  required AudioMetadataWriteResult Function(
    RandomAccessFile input,
    RandomAccessFile output,
  )
  rewrite,
  required bool Function(File candidate) validate,
}) {
  File? temporary;
  RandomAccessFile? input;
  RandomAccessFile? output;
  try {
    if (FileSystemEntity.typeSync(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return AudioMetadataWriteResult.unsupported;
    }
    final before = source.statSync();
    input = source.openSync();
    temporary = File(
      '${source.path}.tags-$pid-${DateTime.now().microsecondsSinceEpoch}-'
      '${_temporarySequence++}.tmp',
    );
    temporary.createSync(exclusive: true);
    output = temporary.openSync(mode: FileMode.writeOnly);
    final result = rewrite(input, output);
    if (result != AudioMetadataWriteResult.written) return result;
    output.flushSync();
    output.closeSync();
    output = null;
    input.closeSync();
    input = null;

    if (!validate(temporary)) return AudioMetadataWriteResult.failed;
    final after = source.statSync();
    if (after.type != FileSystemEntityType.file ||
        after.size != before.size ||
        after.modified != before.modified ||
        after.changed != before.changed ||
        FileSystemEntity.typeSync(source.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return AudioMetadataWriteResult.failed;
    }
    // Never remove the original as a fallback if atomic replacement fails.
    temporary.renameSync(source.path);
    temporary = null;
    return AudioMetadataWriteResult.written;
  } on FormatException {
    return AudioMetadataWriteResult.unsupported;
  } on RangeError {
    return AudioMetadataWriteResult.unsupported;
  } on Object {
    return AudioMetadataWriteResult.failed;
  } finally {
    _close(output);
    _close(input);
    try {
      temporary?.deleteSync();
    } on FileSystemException {
      // Cleanup errors must not turn an optional tag edit into a lost download.
    }
  }
}

/// Copies a file range with constant memory; metadata writers never load the
/// complete audio into memory just to replace its tags.
void copyAudioMetadataRange(
  RandomAccessFile input,
  RandomAccessFile output, {
  required int start,
  required int length,
}) {
  if (start < 0 || length < 0 || start + length > input.lengthSync()) {
    throw const FormatException('Invalid audio copy range');
  }
  if (length == 0) return;
  input.setPositionSync(start);
  final buffer = Uint8List(length < 256 * 1024 ? length : 256 * 1024);
  var remaining = length;
  while (remaining > 0) {
    final count = input.readIntoSync(
      buffer,
      0,
      remaining < buffer.length ? remaining : buffer.length,
    );
    if (count == 0) throw const FormatException('Truncated audio');
    output.writeFromSync(buffer, 0, count);
    remaining -= count;
  }
}

void _close(RandomAccessFile? handle) {
  try {
    handle?.closeSync();
  } on FileSystemException {
    // Preserve the result and still attempt the remaining cleanup.
  }
}
