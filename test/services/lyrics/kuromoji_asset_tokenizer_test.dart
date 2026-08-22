import 'dart:io';

import 'package:bstream_music/services/lyrics/kuromoji_asset_tokenizer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('private Kuromoji API remains protected by an exact dependency pin', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();

    expect(
      RegExp(
        r'^\s{2}kuromoji:\s+1\.0\.5\s*$',
        multiLine: true,
      ).hasMatch(pubspec),
      isTrue,
      reason:
          'kuromoji_asset_tokenizer.dart imports package:kuromoji/src APIs; '
          'upgrade only together with its compatibility tests.',
    );
  });

  test(
    'bundled Kuromoji asset remains compatible with the pinned tokenizer',
    () async {
      final data = await rootBundle.load(
        'assets/dictionaries/kuromoji-ipadic.bin.bz2',
      );
      final tokenize = buildKuromojiTokenizer(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );

      final tokens = tokenize(
        '\u79c1\u306f\u97f3\u697d\u304c\u597d\u304d\u3067\u3059',
      );

      expect(tokens, isNotEmpty);
      expect(tokens.first['reading'], '\u30ef\u30bf\u30b7');
    },
  );
}
