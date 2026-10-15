import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/services/lyrics/lyrics_translation_service.dart';
import 'package:flutter_test/flutter_test.dart';

LyricsDocument _document(List<String> texts) => LyricsDocument(
  provider: 'Test',
  trackName: 'Test',
  artistName: 'Test',
  lines: [
    for (var index = 0; index < texts.length; index++)
      LyricLine(
        timestamp: Duration(seconds: index * 2),
        text: texts[index],
      ),
  ],
);

void main() {
  test('same language only detects and does not translate', () async {
    final session = _Session(source: 'es');
    final service = LyricsTranslationService(sessionFactory: () => session);
    addTearDown(service.dispose);
    final result = await service
        .translateDocument(
          _document(['Una prueba', 'Música']),
          targetLanguage: 'es',
        )
        .result;
    expect(result.alreadyInTargetLanguage, isTrue);
    expect(session.calls, hasLength(1));
    expect(session.calls.single.detectOnly, isTrue);
    expect(session.closed, isTrue);
  });

  test(
    'deduplicates choruses and preserves blanks and line alignment',
    () async {
      final session = _Session();
      final service = LyricsTranslationService(sessionFactory: () => session);
      addTearDown(service.dispose);
      final document = _document(['One', '', 'Two', 'One', '  Two  ']);
      final result = await service
          .translateDocument(document, targetLanguage: 'es')
          .result;
      expect(result.syncedLines, ['es:One', '', 'es:Two', 'es:One', 'es:Two']);
      expect(
        session.calls.where((call) => !call.detectOnly).single.text,
        'One\nTwo',
      );
      expect(document.lines[3].timestamp, const Duration(seconds: 6));
      expect(document.lines[3].text, 'One');
      expect(result.alreadyInTargetLanguage, isFalse);
    },
  );

  test('merging a batch triggers safe serial per-line fallback', () async {
    final session = _Session(mergeBatches: true);
    final service = LyricsTranslationService(sessionFactory: () => session);
    addTearDown(service.dispose);
    final result = await service
        .translateDocument(_document(['One', 'Two']), targetLanguage: 'es')
        .result;
    expect(result.syncedLines, ['es:One', 'es:Two']);
    expect(
      session.calls.where((call) => !call.detectOnly).map((call) => call.text),
      ['One\nTwo', 'One', 'Two'],
    );
    expect(session.maximumConcurrent, 1);
  });

  test('small batches run serially and keep every line', () async {
    final session = _Session();
    final service = LyricsTranslationService(
      sessionFactory: () => session,
      maximumBatchBytes: 8,
    );
    addTearDown(service.dispose);
    final result = await service
        .translateDocument(
          _document(['First', 'Second', 'Third']),
          targetLanguage: 'es',
        )
        .result;
    expect(result.syncedLines, ['es:First', 'es:Second', 'es:Third']);
    expect(session.calls.where((call) => !call.detectOnly), hasLength(3));
    expect(session.maximumConcurrent, 1);
  });

  test(
    'completed cache is keyed by text and target, not track title',
    () async {
      final sessions = <_Session>[];
      final service = LyricsTranslationService(
        sessionFactory: () {
          final session = _Session();
          sessions.add(session);
          return session;
        },
      );
      addTearDown(service.dispose);
      final first = await service
          .translateDocument(_document(['One']), targetLanguage: 'es')
          .result;
      final second = await service
          .translateDocument(_document(['One']), targetLanguage: 'es')
          .result;
      expect(second.syncedLines, first.syncedLines);
      expect(sessions, hasLength(1));
      await service
          .translateDocument(_document(['One']), targetLanguage: 'en')
          .result;
      expect(sessions, hasLength(2));
    },
  );

  test('cache has a bounded LRU working set', () async {
    var sessions = 0;
    final service = LyricsTranslationService(
      maximumCacheEntries: 2,
      sessionFactory: () {
        sessions++;
        return _Session();
      },
    );
    addTearDown(service.dispose);
    for (final line in ['One', 'Two', 'One', 'Three', 'One', 'Two']) {
      await service
          .translateDocument(_document([line]), targetLanguage: 'es')
          .result;
    }
    expect(sessions, 4);
  });

  test(
    'plain lyrics preserve line breaks and never replace source text',
    () async {
      final service = LyricsTranslationService(sessionFactory: _Session.new);
      addTearDown(service.dispose);
      const document = LyricsDocument(
        provider: 'Test',
        trackName: 'Test',
        artistName: 'Test',
        plainLyrics: 'One\n\nTwo',
      );
      final result = await service
          .translateDocument(document, targetLanguage: 'es')
          .result;
      expect(result.plainLyrics, 'es:One\n\nes:Two');
      expect(result.syncedLines, isEmpty);
      expect(document.plainLyrics, 'One\n\nTwo');
      // The same cache entry can serve a synced version without losing its map.
      final synced = await service
          .translateDocument(
            _document(['One', '', 'Two']),
            targetLanguage: 'es',
          )
          .result;
      expect(synced.syncedLines, ['es:One', '', 'es:Two']);
    },
  );

  test(
    'cancelling closes the connection and cannot cache a late result',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      final first = _Session(pending: pending);
      var count = 0;
      final service = LyricsTranslationService(
        sessionFactory: () => count++ == 0 ? first : _Session(),
      );
      addTearDown(service.dispose);
      final request = service.translateDocument(
        _document(['One']),
        targetLanguage: 'es',
      );
      final cancelled = expectLater(
        request.result,
        throwsA(isA<LyricsTranslationCancelled>()),
      );
      request.cancel();
      await cancelled;
      expect(first.closed, isTrue);
      pending.complete({'src': 'en'});
      await Future<void>.delayed(Duration.zero);
      expect(first.calls, hasLength(1));
      await service
          .translateDocument(_document(['One']), targetLanguage: 'es')
          .result;
      expect(count, 2);
    },
  );

  test('failures are not cached or automatically retried', () async {
    var count = 0;
    final service = LyricsTranslationService(
      sessionFactory: () {
        count++;
        return _Session(fail: count == 1);
      },
    );
    addTearDown(service.dispose);
    await expectLater(
      service
          .translateDocument(_document(['One']), targetLanguage: 'es')
          .result,
      throwsA(isA<LyricsTranslationException>()),
    );
    expect(count, 1);
    final result = await service
        .translateDocument(_document(['One']), targetLanguage: 'es')
        .result;
    expect(result.syncedLines, ['es:One']);
    expect(count, 2);
  });

  test('disposal cancels pending work', () async {
    final pending = Completer<Map<String, dynamic>>();
    final session = _Session(pending: pending);
    final service = LyricsTranslationService(sessionFactory: () => session);
    final request = service.translateDocument(
      _document(['One']),
      targetLanguage: 'es',
    );
    final cancelled = expectLater(
      request.result,
      throwsA(isA<LyricsTranslationCancelled>()),
    );
    service.dispose();
    await cancelled;
    expect(session.closed, isTrue);
    pending.complete({'src': 'en'});
  });
}

class _Session implements LyricsTranslationSession {
  _Session({
    this.source = 'en',
    this.mergeBatches = false,
    this.fail = false,
    this.pending,
  });
  final String source;
  final bool mergeBatches;
  final bool fail;
  final Completer<Map<String, dynamic>>? pending;
  final calls = <({String text, String target, bool detectOnly})>[];
  bool closed = false;
  int _concurrent = 0;
  int maximumConcurrent = 0;

  @override
  Future<Map<String, dynamic>> request(
    String text,
    String targetLanguage, {
    bool detectOnly = false,
  }) async {
    calls.add((text: text, target: targetLanguage, detectOnly: detectOnly));
    _concurrent++;
    if (_concurrent > maximumConcurrent) maximumConcurrent = _concurrent;
    try {
      if (pending != null) return await pending!.future;
      if (fail) throw const LyricsTranslationException();
      await Future<void>.delayed(Duration.zero);
      return {
        'src': source,
        if (!detectOnly)
          'sentences': [
            {
              'trans': mergeBatches && text.contains('\n')
                  ? 'Merged'
                  : text
                        .split('\n')
                        .map((line) => '$targetLanguage:$line')
                        .join('\n'),
            },
          ],
      };
    } finally {
      _concurrent--;
    }
  }

  @override
  void close() => closed = true;
}
