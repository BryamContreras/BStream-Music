import 'dart:io';

import 'package:bstream_music/services/downloader/atomic_audio_metadata_rewrite.dart';
import 'package:bstream_music/services/downloader/audio_metadata_fields.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late File source;
  const original = [1, 2, 3, 4, 5];
  setUp(() {
    directory = Directory.systemTemp.createTempSync('bstream-tag-transaction-');
    source = File(p.join(directory.path, 'audio.bin'))
      ..writeAsBytesSync(original);
  });
  tearDown(() => directory.deleteSync(recursive: true));

  void expectClean() =>
      expect(directory.listSync().map((entry) => entry.path), [source.path]);

  test('validates a closed candidate before replacing the original', () {
    expect(
      rewriteAudioMetadataFile(
        source,
        rewrite: (input, output) {
          output.writeByteSync(9);
          copyAudioMetadataRange(input, output, start: 0, length: 5);
          return AudioMetadataWriteResult.written;
        },
        validate: (candidate) {
          expect(source.readAsBytesSync(), original);
          expect(candidate.readAsBytesSync(), [9, ...original]);
          return true;
        },
      ),
      AudioMetadataWriteResult.written,
    );
    expect(source.readAsBytesSync(), [9, ...original]);
    expectClean();
  });

  for (final result in [
    AudioMetadataWriteResult.unchanged,
    AudioMetadataWriteResult.unsupported,
    AudioMetadataWriteResult.failed,
  ]) {
    test('discards incomplete candidates on $result', () {
      final before = source.statSync();
      expect(
        rewriteAudioMetadataFile(
          source,
          rewrite: (input, output) {
            output.writeByteSync(9);
            return result;
          },
          validate: (_) => throw StateError('Unexpected validation'),
        ),
        result,
      );
      expect(source.readAsBytesSync(), original);
      expect(source.statSync().modified, before.modified);
      expectClean();
    });
  }

  for (final throws in [false, true]) {
    test('keeps the original if validation fails (throws=$throws)', () {
      expect(
        rewriteAudioMetadataFile(
          source,
          rewrite: (input, output) {
            output.writeByteSync(9);
            return AudioMetadataWriteResult.written;
          },
          validate: (_) => throws ? throw StateError('Rejected') : false,
        ),
        AudioMetadataWriteResult.failed,
      );
      expect(source.readAsBytesSync(), original);
      expectClean();
    });
  }

  test('does not overwrite an edit made while preparing metadata', () {
    expect(
      rewriteAudioMetadataFile(
        source,
        rewrite: (input, output) {
          output.writeByteSync(9);
          return AudioMetadataWriteResult.written;
        },
        validate: (_) {
          source.writeAsBytesSync([8, 7]);
          return true;
        },
      ),
      AudioMetadataWriteResult.failed,
    );
    expect(source.readAsBytesSync(), [8, 7]);
    expectClean();
  });

  test('a truncated copy leaves no partial original or temporary file', () {
    expect(
      rewriteAudioMetadataFile(
        source,
        rewrite: (input, output) {
          output.writeByteSync(9);
          copyAudioMetadataRange(input, output, start: 0, length: 6);
          return AudioMetadataWriteResult.written;
        },
        validate: (_) => true,
      ),
      AudioMetadataWriteResult.unsupported,
    );
    expect(source.readAsBytesSync(), original);
    expectClean();
  });
}
