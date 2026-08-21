import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/services/lyrics/lyrics_romanization_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'romanizes every supported script without changing lyric structure',
    () async {
      const sourceTexts = <String>[
        'こんにちは',
        '안녕하세요',
        '你好世界',
        'Привет',
        'مرحبا',
        'שלום',
      ];
      final document = LyricsDocument(
        provider: 'test',
        trackName: 'Scripts',
        artistName: 'BStream',
        lines: [
          for (var index = 0; index < sourceTexts.length; index++)
            LyricLine(
              timestamp: Duration(seconds: index * 3),
              text: sourceTexts[index],
            ),
        ],
        plainLyrics: '${sourceTexts[2]}\n${sourceTexts[1]}',
      );
      final service = LyricsRomanizationService();
      addTearDown(service.dispose);

      final result = await service.romanizeDocument(
        document,
        defaultLyricsRomanizationLanguages,
      );

      expect(result.syncedLines, hasLength(sourceTexts.length));
      for (var index = 0; index < sourceTexts.length; index++) {
        expect(
          result.syncedLines[index],
          isNot(sourceTexts[index]),
          reason: LyricsRomanizationLanguage.values[index].code,
        );
        expect(document.lines[index].text, sourceTexts[index]);
        expect(document.lines[index].timestamp, Duration(seconds: index * 3));
      }
      expect(result.plainLyrics, isNot(document.plainLyrics));
      expect('\n'.allMatches(result.plainLyrics!).length, 1);
    },
  );

  test('only selected languages are replaced in mixed lyrics', () async {
    const lines = <String>['Hello 안녕', 'Привет', '你好'];
    final service = LyricsRomanizationService();
    addTearDown(service.dispose);

    final result = await service.romanizePreview(lines, const {
      LyricsRomanizationLanguage.korean,
    });

    expect(result, hasLength(lines.length));
    expect(result[0], startsWith('Hello '));
    expect(result[0], isNot(lines[0]));
    expect(result[1], lines[1]);
    expect(result[2], lines[2]);
  });

  test(
    'reuses the cached conversion for identical content and selection',
    () async {
      final service = LyricsRomanizationService();
      addTearDown(service.dispose);
      const source = <String>['안녕하세요', 'BStream'];
      const languages = <LyricsRomanizationLanguage>{
        LyricsRomanizationLanguage.korean,
      };

      final first = service.romanizePreview(source, languages);
      final second = service.romanizePreview(
        List<String>.of(source),
        languages,
      );

      expect(identical(first, second), isTrue);
      expect(await first, await second);
    },
  );

  test(
    'uses Japanese readings for Han when the document contains kana',
    () async {
      const document = LyricsDocument(
        provider: 'test',
        trackName: 'Japanese context',
        artistName: 'BStream',
        lines: [LyricLine(timestamp: Duration.zero, text: '君 は好き')],
      );
      final service = LyricsRomanizationService();
      addTearDown(service.dispose);

      final japaneseAndChinese = await service.romanizeDocument(
        document,
        const {
          LyricsRomanizationLanguage.japanese,
          LyricsRomanizationLanguage.chinese,
        },
      );
      final japaneseOnly = await service.romanizeDocument(document, const {
        LyricsRomanizationLanguage.japanese,
      });
      final chineseOnly = await service.romanizeDocument(document, const {
        LyricsRomanizationLanguage.chinese,
      });

      expect(japaneseAndChinese.syncedLines, japaneseOnly.syncedLines);
      expect(japaneseAndChinese.syncedLines.first, isNot('君 は好き'));
      expect(
        japaneseAndChinese.syncedLines.first,
        isNot(chineseOnly.syncedLines.first),
      );
    },
  );

  test('uses Kuromoji word boundaries for readable Japanese romaji', () async {
    final service = LyricsRomanizationService();
    addTearDown(service.dispose);

    final result = await service.romanizePreview(
      const [
        '\u79c1\u306f\u97f3\u697d\u304c\u597d\u304d\u3067\u3059\u3002'
            '\u541b\u3082\uff1f',
      ],
      const {LyricsRomanizationLanguage.japanese},
    );

    expect(result.single, 'watashi ha ongaku ga suki desu\u3002 kimi mo\uff1f');
  });

  test('keeps Chinese context after a Japanese phrase on one line', () async {
    final service = LyricsRomanizationService();
    addTearDown(service.dispose);

    final result = await service.romanizePreview(
      const [
        '\u3053\u3093\u306b\u3061\u306f / '
            '\u4f60\u597d\u4e16\u754c',
      ],
      const {
        LyricsRomanizationLanguage.japanese,
        LyricsRomanizationLanguage.chinese,
      },
    );

    expect(result.single, 'konnichiha / n\u01d0 h\u01ceo sh\u00ec ji\u00e8');
  });

  test('does not mistake a CJK middle dot for Japanese kana', () async {
    final service = LyricsRomanizationService();
    addTearDown(service.dispose);

    final result = await service.romanizePreview(
      const ['\u4f60\u597d\u30fb\u4e16\u754c'],
      const {
        LyricsRomanizationLanguage.japanese,
        LyricsRomanizationLanguage.chinese,
      },
    );

    expect(result.single, 'n\u01d0 h\u01ceo\u30fbsh\u00ec ji\u00e8');
  });

  test('keeps Pinyin syllables and separates phrase punctuation', () async {
    final service = LyricsRomanizationService();
    addTearDown(service.dispose);

    final result = await service.romanizePreview(
      const ['\u4f60\u597d\uff0c\u4e16\u754c\uff01'],
      const {LyricsRomanizationLanguage.chinese},
    );

    expect(result.single, 'n\u01d0 h\u01ceo\uff0c sh\u00ec ji\u00e8\uff01');
  });

  test('preserves Korean word spaces without splitting syllables', () async {
    final service = LyricsRomanizationService();
    addTearDown(service.dispose);

    final result = await service.romanizePreview(
      const ['\uc548\ub155\ud558\uc138\uc694,\uc138\uacc4!'],
      const {LyricsRomanizationLanguage.korean},
    );

    expect(result.single, 'annyeonghaseyo, segye!');
  });

  test('does not apply Japanese context to a separate Chinese line', () async {
    final service = LyricsRomanizationService();
    addTearDown(service.dispose);
    const source = <String>['こんにちは', '你好世界'];

    final both = await service.romanizePreview(source, const {
      LyricsRomanizationLanguage.japanese,
      LyricsRomanizationLanguage.chinese,
    });
    final chinese = await service.romanizePreview(
      const ['你好世界'],
      const {LyricsRomanizationLanguage.chinese},
    );

    expect(both.first, isNot(source.first));
    expect(both.last, chinese.single);
  });

  test('restarts safely after its worker isolate terminates', () async {
    final service = LyricsRomanizationService(
      workerRequestTimeout: const Duration(milliseconds: 250),
    );
    addTearDown(service.dispose);
    const languages = <LyricsRomanizationLanguage>{
      LyricsRomanizationLanguage.korean,
    };
    await service
        .romanizePreview(const ['안녕'], languages)
        .timeout(const Duration(seconds: 2));

    service.debugTerminateWorker();
    try {
      await service
          .romanizePreview(const ['사랑'], languages)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // A request racing the exit may fail, but it must never remain pending.
    }

    final recovered = await service
        .romanizePreview(const ['음악'], languages)
        .timeout(const Duration(seconds: 2));
    expect(recovered.single, isNot('음악'));
  });

  test('dispose completes work in flight and rejects later requests', () async {
    final service = LyricsRomanizationService();
    final inFlight = service.romanizePreview(
      const ['東京は好き'],
      const {LyricsRomanizationLanguage.japanese},
    );

    service.dispose();

    await expectLater(
      inFlight.timeout(const Duration(seconds: 2)),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      service.romanizePreview(
        const ['안녕'],
        const {LyricsRomanizationLanguage.korean},
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('bounds unique work queued behind the active conversion', () async {
    final service = LyricsRomanizationService(maximumPendingRequests: 1);
    addTearDown(service.dispose);
    const languages = <LyricsRomanizationLanguage>{
      LyricsRomanizationLanguage.korean,
    };

    final first = service.romanizePreview(const ['안녕하세요'], languages);
    final overflow = service.romanizePreview(const ['사랑해요'], languages);

    await expectLater(overflow, throwsA(isA<StateError>()));
    expect((await first).single, isNot('안녕하세요'));
  });
}
