import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_page.dart';
import 'package:bstream_music/services/lyrics/lyrics_service.dart';
import 'package:bstream_music/services/lyrics/lyrics_translation_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Opt-in live network test: flutter drive --driver=test_driver/lyrics_options_driver.dart
/// --target=integration_test/lyrics_options_native_test.dart -d emulator-5554 --keep-app-running
/// Uses original fixture text and in-memory settings, never the user's library.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('BSTREAM_NATIVE_SCREENSHOTS');
  testWidgets(
    'native lyrics menu, live translation, cache, language and romanization',
    (tester) async {
      final player = _FixturePlayerController();
      final settings = _FixtureSettingsController();
      final sessions = <_TrackingSession>[];
      final translations = LyricsTranslationService(
        sessionFactory: () {
          final session = _TrackingSession();
          sessions.add(session);
          return session;
        },
      );
      final container = ProviderContainer(
        overrides: [
          playerControllerProvider.overrideWith(() => player),
          settingsControllerProvider.overrideWith(() => settings),
          favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
          lyricsServiceProvider.overrideWithValue(_FixtureLyricsService()),
          lyricsTranslationServiceProvider.overrideWithValue(translations),
        ],
      );
      addTearDown(() {
        container.dispose();
        translations.dispose();
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              fontFamily: 'Roboto',
              colorSchemeSeed: AppAccent.purple.seedColor,
              extensions: [AppAccentTheme.fromAccent(AppAccent.purple)],
            ),
            home: const LyricsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lyrics-offset-control')), findsNothing);
      expect(
        find.byKey(const ValueKey('lyrics-settings-button')),
        findsOneWidget,
      );
      if (capture) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
        await binding.takeScreenshot('lyrics-gear-original');
      }

      await _openMenu(tester);
      expect(
        find.byKey(const ValueKey('lyrics-offset-control')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('lyrics-offset-increase')));
      await tester.pumpAndSettle();
      expect(find.text('+0.50 s'), findsOneWidget);
      if (capture) await binding.takeScreenshot('lyrics-options-menu');

      await _tap(tester, 'lyrics-menu-translation-toggle');
      await _waitUntil(
        tester,
        () =>
            container.read(currentLyricsTranslationProvider).asData?.value !=
            null,
      );
      final translated = container
          .read(currentLyricsTranslationProvider)
          .requireValue!;
      expect(translated.alreadyInTargetLanguage, isFalse);
      expect(translated.sourceLanguage, 'en');
      expect(translated.syncedLines, hasLength(_english.lines.length));
      expect(translated.syncedLines[0], isNot(_english.lines[0].text));
      final originalCallCount = sessions.fold<int>(
        0,
        (count, session) => count + session.calls,
      );
      await _tap(tester, 'lyrics-settings-close');
      expect(
        find.byKey(const ValueKey('lyrics-line-translation-0')),
        findsOneWidget,
      );
      if (capture) {
        await binding.takeScreenshot('lyrics-live-translation-spanish');
      }

      await _openMenu(tester);
      await _tap(tester, 'lyrics-menu-translation-toggle');
      await _tap(tester, 'lyrics-menu-translation-toggle');
      await _waitUntil(
        tester,
        () =>
            container.read(currentLyricsTranslationProvider).asData?.value !=
            null,
      );
      expect(
        sessions.fold<int>(0, (count, session) => count + session.calls),
        originalCallCount,
        reason: 'Toggling back on must reuse the completed memory cache.',
      );

      settings.setLanguageForTest(AppLanguage.english);
      await _waitUntil(
        tester,
        () =>
            container
                .read(currentLyricsTranslationProvider)
                .asData
                ?.value
                ?.alreadyInTargetLanguage ==
            true,
      );
      expect(
        find.text('The lyrics are already in the app language.'),
        findsOneWidget,
      );
      expect(
        sessions.last.calls,
        1,
        reason: 'Same-language lyrics only need detection, not translation.',
      );
      if (capture) {
        await binding.takeScreenshot('lyrics-already-in-app-language');
      }

      settings.setLanguageForTest(AppLanguage.spanish);
      player.changeTrack('korean');
      await _waitUntil(
        tester,
        () =>
            container
                .read(currentLyricsTranslationProvider)
                .asData
                ?.value
                ?.sourceLanguage ==
            'ko',
      );
      await _tap(tester, 'lyrics-menu-romanization-toggle');
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .lyricsTranslationEnabled,
        isFalse,
      );
      await _tap(tester, 'lyrics-settings-close');
      await _waitUntil(
        tester,
        () => find
            .byKey(const ValueKey('lyrics-line-romanization-0'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('lyrics-line-translation-0')),
        findsNothing,
      );
      if (capture) await binding.takeScreenshot('lyrics-korean-romanization');
      expect(tester.takeException(), isNull);
      // Settings overrides stay in memory; no preferences or library are changed.
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<void> _openMenu(WidgetTester tester) =>
    _tap(tester, 'lyrics-settings-button');
Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 550));
}

Future<void> _waitUntil(WidgetTester tester, bool Function() ready) async {
  final limit = DateTime.now().add(const Duration(seconds: 45));
  while (!ready() && DateTime.now().isBefore(limit)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: 'Native lyrics operation did not complete.');
  await tester.pump(const Duration(milliseconds: 550));
}

const _english = LyricsDocument(
  provider: 'Fixture',
  trackName: 'Lyrics options test',
  artistName: 'BStream Music',
  lines: [
    LyricLine(timestamp: Duration.zero, text: 'Music brings us together.'),
    LyricLine(
      timestamp: Duration(seconds: 2),
      text: 'We can read these words.',
    ),
    LyricLine(
      timestamp: Duration(seconds: 4),
      text: 'This is an original test sentence.',
    ),
  ],
);
const _korean = LyricsDocument(
  provider: 'Fixture',
  trackName: 'Korean test',
  artistName: 'BStream Music',
  lines: [
    LyricLine(timestamp: Duration.zero, text: '오늘은 좋은 날입니다'),
    LyricLine(timestamp: Duration(seconds: 2), text: '우리는 함께 음악을 들어요'),
  ],
);

class _FixturePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => const PlayerSnapshot(
    status: PlayerStatus.paused,
    title: 'Lyrics options test',
    artist: 'BStream Music',
    trackId: 'english',
    duration: Duration(minutes: 3),
  );
  void changeTrack(String id) => state = AsyncData(
    state.requireValue.copyWith(
      trackId: id,
      title: 'Korean test',
      position: Duration.zero,
    ),
  );
  @override
  Future<void> seek(Duration position) async =>
      state = AsyncData(state.requireValue.copyWith(position: position));
}

class _FixtureSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: 'BStream-Music',
    language: AppLanguage.spanish,
    lyricsRomanizationLanguages: {LyricsRomanizationLanguage.korean},
  );
  void setLanguageForTest(AppLanguage language) =>
      state = AsyncData(state.requireValue.copyWith(language: language));
  @override
  Future<void> setLyricsRomanizationEnabled(bool enabled) async =>
      state = AsyncData(
        state.requireValue.copyWith(
          lyricsRomanizationEnabled: enabled,
          lyricsTranslationEnabled: enabled
              ? false
              : state.requireValue.lyricsTranslationEnabled,
        ),
      );
  @override
  Future<void> setLyricsTranslationEnabled(bool enabled) async =>
      state = AsyncData(
        state.requireValue.copyWith(
          lyricsTranslationEnabled: enabled,
          lyricsRomanizationEnabled: enabled
              ? false
              : state.requireValue.lyricsRomanizationEnabled,
        ),
      );
}

class _FixtureLyricsService implements LyricsService {
  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) async =>
      lookup.sourceId == 'korean' ? _korean : _english;
  @override
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  }) async => const [];
  @override
  Future<List<LyricsCandidate>> searchLyricsByTitle(
    String title, {
    required LyricsLookup context,
    int limit = 8,
  }) async => const [];
  @override
  void dispose() {}
}

class _TrackingSession extends GoogleLyricsTranslationSession {
  int calls = 0;
  @override
  Future<Map<String, dynamic>> request(
    String text,
    String targetLanguage, {
    bool detectOnly = false,
  }) {
    calls++;
    return super.request(text, targetLanguage, detectOnly: detectOnly);
  }
}
