import 'dart:async';
import 'dart:convert';

import 'package:bstream_music/services/app_update/github_release_checker.dart';
import 'package:bstream_music/services/app_update/release_notes_service.dart';
import 'package:bstream_music/services/lyrics/lyrics_translation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppReleaseCheckResult _release(String body, {String tag = 'v1.3.0'}) =>
    AppReleaseCheckResult(
      currentVersion: '1.2.9',
      latestVersion: '1.3.0',
      releaseTag: tag,
      releaseNotes: body,
    );

void main() {
  test('normalizes Markdown into plain notes without duplicate headings', () {
    final service = ReleaseNotesService(cache: _Cache());
    addTearDown(service.dispose);

    final result = service.original(
      _release('''
# BStream Music
## v1.3.0
**What's New**

![Release artwork](https://example.com/art.jpg)
[![Build badge](https://example.com/badge.svg)](https://example.com/build)
<!-- Never show hidden content. -->
<script>alert('hidden')</script>
<style>.hidden { color: red; }</style>

- **New widgets** and [playback](https://example.com/features).
  Keeps a wrapped bullet together.
- [x] Smoother `lyrics` &amp; animations.

A standalone paragraph
with a wrapped line.

```shell
do not show installation commands
```
'''),
      languageCode: 'es',
    );

    expect(result.items, [
      'New widgets and playback. Keeps a wrapped bullet together.',
      'Smoother lyrics & animations.',
      'A standalone paragraph with a wrapped line.',
    ]);
    expect(result.translationFailed, isFalse);
    expect(result.translated, isFalse);
  });

  test(
    'uses a published locale section without any translation request',
    () async {
      final service = ReleaseNotesService(
        cache: _Cache(),
        sessionFactory: () => throw StateError('No translation is needed.'),
      );
      addTearDown(service.dispose);
      final release = _release('''
# Release notes
## English
- Better playback.
## 🇪🇸 Español
- Mejor reproducción.
### Interfaz
- Nuevos widgets.
## 日本語
- 再生を改善しました。
''');

      final original = service.original(release, languageCode: 'es-MX');
      final result = await service.load(release, languageCode: 'es-MX');

      expect(original.items, ['Mejor reproducción.', 'Nuevos widgets.']);
      expect(result.items, original.items);
      expect(result.translationFailed, isFalse);
      expect(result.translated, isFalse);
    },
  );

  test(
    'translates one source section instead of combining languages',
    () async {
      final session = _Session();
      final service = ReleaseNotesService(
        cache: _Cache(),
        sessionFactory: () => session,
      );
      addTearDown(service.dispose);

      final result = await service.load(
        _release(
          '## English\n- Better playback.\n## Español\n- Mejor reproducción.',
        ),
        languageCode: 'fr',
      );

      expect(result.items, ['fr:Better playback.']);
      expect(result.translated, isTrue);
      expect(session.calls, hasLength(1));
      expect(session.calls.single.detectOnly, isFalse);
    },
  );

  for (final language in ['en', 'es', 'pt-BR', 'fr', 'ko', 'zh-CN', 'ja']) {
    test(
      'supports the app language $language and preserves bullet alignment',
      () async {
        final session = _Session(source: 'de');
        final service = ReleaseNotesService(
          cache: _Cache(),
          sessionFactory: () => session,
        );
        addTearDown(service.dispose);
        final target = language.split('-').first;

        final result = await service.load(
          _release('- Better playback.\n- Smoother scrolling.'),
          languageCode: language,
        );

        expect(result.items, [
          '$target:Better playback.',
          '$target:Smoother scrolling.',
        ]);
        expect(result.translated, isTrue);
        expect(result.translationFailed, isFalse);
        expect(session.calls.map((call) => call.target).toSet(), {target});
        expect(session.maximumConcurrent, 1);
        expect(session.closed, isTrue);
      },
    );
  }

  test('same language only detects and preserves the GitHub text', () async {
    final session = _Session(source: 'es');
    final service = ReleaseNotesService(
      cache: _Cache(),
      sessionFactory: () => session,
    );
    addTearDown(service.dispose);

    final result = await service.load(
      _release('- Mejor reproducción.\n- Nuevos widgets.'),
      languageCode: 'es',
    );

    expect(result.items, ['Mejor reproducción.', 'Nuevos widgets.']);
    expect(result.translated, isFalse);
    expect(result.translationFailed, isFalse);
    expect(session.calls, hasLength(1));
    expect(session.calls.single.detectOnly, isTrue);
  });

  test(
    'shares in-flight work and memory cache for the same release/language',
    () async {
      final gate = Completer<void>();
      var sessions = 0;
      final service = ReleaseNotesService(
        cache: _Cache(),
        sessionFactory: () {
          sessions++;
          return _Session(gate: gate.future);
        },
      );
      addTearDown(service.dispose);
      final release = _release('- Better playback.');

      final first = service.load(release, languageCode: 'es');
      final second = service.load(release, languageCode: 'es');
      expect(identical(first, second), isTrue);
      gate.complete();
      final result = await first;
      expect((await second).items, result.items);
      expect(
        (await service.load(release, languageCode: 'es')).items,
        result.items,
      );
      expect(sessions, 1);
    },
  );

  test(
    'persistent cache survives service recreation and keys body/tag/locale',
    () async {
      final cache = _Cache();
      var sessions = 0;
      ReleaseNotesService service() => ReleaseNotesService(
        cache: cache,
        sessionFactory: () {
          sessions++;
          return _Session();
        },
      );
      final first = service();
      final release = _release('- Better playback.');
      await first.load(release, languageCode: 'es');
      first.dispose();
      final next = service();
      addTearDown(next.dispose);

      expect((await next.load(release, languageCode: 'es')).items, [
        'es:Better playback.',
      ]);
      expect(sessions, 1);
      await next.load(release, languageCode: 'fr');
      await next.load(_release('- New widgets.'), languageCode: 'es');
      await next.load(
        _release('- Better playback.', tag: 'v1.3.1'),
        languageCode: 'es',
      );
      expect(sessions, 4);
      expect(cache.values, hasLength(4));
    },
  );

  test(
    'merged translated bullets fall back serially without losing alignment',
    () async {
      final session = _Session(mergeBatches: true);
      final service = ReleaseNotesService(
        cache: _Cache(),
        sessionFactory: () => session,
      );
      addTearDown(service.dispose);

      final result = await service.load(
        _release('- Better playback.\n- New widgets.'),
        languageCode: 'es',
      );

      expect(result.items, ['es:Better playback.', 'es:New widgets.']);
      expect(
        session.calls
            .where((call) => !call.detectOnly)
            .map((call) => call.text),
        ['Better playback.\nNew widgets.', 'Better playback.', 'New widgets.'],
      );
      expect(session.maximumConcurrent, 1);
    },
  );

  test(
    'partial failure returns all original notes and does not persist them',
    () async {
      final cache = _Cache();
      var sessionCount = 0;
      final service = ReleaseNotesService(
        cache: cache,
        maximumBatchBytes: 20,
        sessionFactory: () =>
            _Session(failTranslation: ++sessionCount == 1 ? 2 : null),
      );
      addTearDown(service.dispose);
      final release = _release('- Better playback.\n- New widgets.');

      final result = await service.load(release, languageCode: 'es');

      expect(result.items, ['Better playback.', 'New widgets.']);
      expect(result.translationFailed, isTrue);
      expect(result.translated, isFalse);
      expect(cache.values, isEmpty);
      final retry = await service.load(release, languageCode: 'es');
      expect(retry.items, ['es:Better playback.', 'es:New widgets.']);
      expect(retry.translationFailed, isFalse);
      expect(sessionCount, 2);
    },
  );

  test('unavailable cache does not prevent a fresh translation', () async {
    final service = ReleaseNotesService(
      cache: _BrokenCache(),
      sessionFactory: _Session.new,
    );
    addTearDown(service.dispose);

    final result = await service.load(
      _release('- Better playback.'),
      languageCode: 'es',
    );

    expect(result.items, ['es:Better playback.']);
    expect(result.translationFailed, isFalse);
  });

  test(
    'UTF-8 batches remain bounded with CJK and supplementary characters',
    () async {
      final session = _Session(source: 'ja');
      final service = ReleaseNotesService(
        cache: _Cache(),
        sessionFactory: () => session,
        maximumBatchBytes: 20,
      );
      addTearDown(service.dispose);

      final result = await service.load(
        _release('- 日本語の歌詞とウィジェット🎵を改善しました。\n- 音楽を楽しみましょう。'),
        languageCode: 'es',
      );

      expect(result.translationFailed, isFalse);
      expect(result.items, hasLength(2));
      expect(result.items.join(' '), contains('🎵'));
      expect(result.items.join(' '), isNot(contains('�')));
      expect(
        session.calls.every((call) => utf8.encode(call.text).length <= 20),
        isTrue,
      );
    },
  );

  test(
    'request timeout and request budget retain originals and close sessions',
    () async {
      final session = _Session(gate: Completer<void>().future);
      final service = ReleaseNotesService(
        cache: _Cache(),
        sessionFactory: () => session,
        requestTimeout: const Duration(milliseconds: 5),
      );
      addTearDown(service.dispose);

      final timedOut = await service.load(
        _release('- Better playback.'),
        languageCode: 'es',
      );

      expect(timedOut.translationFailed, isTrue);
      expect(timedOut.items, ['Better playback.']);
      expect(session.closed, isTrue);

      final limited = ReleaseNotesService(
        cache: _Cache(),
        sessionFactory: _Session.new,
        maximumRequests: 1,
      );
      addTearDown(limited.dispose);
      final overBudget = await limited.load(
        _release('- Better playback.'),
        languageCode: 'es',
      );
      expect(overBudget.translationFailed, isTrue);
      expect(overBudget.items, ['Better playback.']);
    },
  );

  test(
    'oversized notes and unsupported locales never start network requests',
    () async {
      final service = ReleaseNotesService(
        cache: _Cache(),
        maximumSourceCharacters: 8,
        sessionFactory: () => throw StateError('Must not create a session.'),
      );
      addTearDown(service.dispose);

      final oversized = await service.load(
        _release('- Better playback.'),
        languageCode: 'es',
      );
      final unsupported = await service.load(
        _release('- Hi.'),
        languageCode: 'de',
      );
      expect(oversized.items, ['Better playback.']);
      expect(oversized.translationFailed, isTrue);
      expect(unsupported.items, ['Hi.']);
      expect(unsupported.translationFailed, isTrue);
    },
  );

  test('disposing stops work before another translation request', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final session = _Session(gate: gate.future, started: started);
    final service = ReleaseNotesService(
      cache: _Cache(),
      sessionFactory: () => session,
    );

    final pending = service.load(
      _release('- Better playback.'),
      languageCode: 'es',
    );
    await started.future;
    service.dispose();
    gate.complete();
    final result = await pending;

    expect(result.translationFailed, isTrue);
    expect(result.items, ['Better playback.']);
    expect(session.calls, hasLength(1));
    expect(session.closed, isTrue);
  });

  test('empty notes need no network', () async {
    final service = ReleaseNotesService(
      cache: _Cache(),
      sessionFactory: () => throw StateError('Must not create a session.'),
    );
    addTearDown(service.dispose);

    final result = await service.load(
      _release('## v1.3.0\n![image](https://example.com/img)'),
      languageCode: 'es',
    );

    expect(result.items, isEmpty);
    expect(result.translationFailed, isFalse);
  });

  test(
    'persistent cache bounds entries and tolerates corrupt stored data',
    () async {
      SharedPreferences.setMockInitialValues({
        SharedPreferencesReleaseNotesCache.preferenceKey: '{broken',
      });
      final cache = SharedPreferencesReleaseNotesCache(maximumEntries: 2);
      String key(String character) => List.filled(64, character).join();

      expect(await cache.read(key('a')), isNull);
      await cache.write(key('a'), ['Uno']);
      await cache.write(key('b'), ['Dos']);
      await cache.write(key('c'), ['Tres']);

      expect(await cache.read(key('a')), isNull);
      expect(await cache.read(key('b')), ['Dos']);
      expect(await cache.read(key('c')), ['Tres']);
      final encoded = (await SharedPreferences.getInstance()).getString(
        SharedPreferencesReleaseNotesCache.preferenceKey,
      )!;
      expect(jsonDecode(encoded), hasLength(2));
    },
  );

  test('persistent cache limits total stored characters', () async {
    SharedPreferences.setMockInitialValues({});
    final cache = SharedPreferencesReleaseNotesCache(maximumCharacters: 150);
    final longNote = List.filled(300, 'X').join();

    await cache.write(List.filled(64, 'a').join(), [longNote]);

    final encoded = (await SharedPreferences.getInstance()).getString(
      SharedPreferencesReleaseNotesCache.preferenceKey,
    )!;
    expect(encoded.length, lessThanOrEqualTo(150));
    expect(await cache.read(List.filled(64, 'a').join()), isNull);
  });
}

class _Cache implements ReleaseNotesCache {
  final values = <String, List<String>>{};

  @override
  Future<List<String>?> read(String key) async => values[key];

  @override
  Future<void> write(String key, List<String> items) async {
    values[key] = List.of(items);
  }
}

class _BrokenCache implements ReleaseNotesCache {
  @override
  Future<List<String>?> read(String key) async =>
      throw StateError('Unavailable');

  @override
  Future<void> write(String key, List<String> items) async =>
      throw StateError('Full');
}

class _Session implements LyricsTranslationSession {
  _Session({
    this.source = 'en',
    this.mergeBatches = false,
    this.failTranslation,
    this.gate,
    this.started,
  });

  final String source;
  final bool mergeBatches;
  final int? failTranslation;
  final Future<void>? gate;
  final Completer<void>? started;
  final calls = <({String text, String target, bool detectOnly})>[];
  var translations = 0;
  var maximumConcurrent = 0;
  var concurrent = 0;
  var closed = false;

  @override
  Future<Map<String, dynamic>> request(
    String text,
    String targetLanguage, {
    bool detectOnly = false,
  }) async {
    calls.add((text: text, target: targetLanguage, detectOnly: detectOnly));
    concurrent++;
    if (concurrent > maximumConcurrent) maximumConcurrent = concurrent;
    if (started != null && !started!.isCompleted) started!.complete();
    try {
      if (gate != null) await gate;
      if (detectOnly) return {'src': source};
      translations++;
      if (translations == failTranslation) {
        throw const LyricsTranslationException();
      }
      return {
        'src': source,
        'sentences': [
          {
            'trans': mergeBatches
                ? '$targetLanguage:${text.replaceAll('\n', ' ')}'
                : text
                      .split('\n')
                      .map((line) => '$targetLanguage:$line')
                      .join('\n'),
          },
        ],
      };
    } finally {
      concurrent--;
    }
  }

  @override
  void close() => closed = true;
}
