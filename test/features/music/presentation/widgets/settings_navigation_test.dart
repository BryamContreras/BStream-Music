import 'dart:ui';

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/presentation/pages/home_page.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/lyrics/lyrics_romanization_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/sharing/incoming_track_link_service.dart';
import 'package:bstream_music/services/storage/library_csv_import_service.dart';
import 'package:bstream_music/services/storage/library_csv_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_account_client.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('lyrics romanization preferences persist enabled languages', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(
          _PersistingCrossfadeSettingsController.new,
        ),
      ],
    );
    addTearDown(container.dispose);

    final initial = await container.read(settingsControllerProvider.future);
    expect(initial.lyricsRomanizationEnabled, isFalse);
    expect(
      initial.lyricsRomanizationLanguages,
      defaultLyricsRomanizationLanguages,
    );

    final controller = container.read(settingsControllerProvider.notifier);
    await Future.wait([
      controller.setLyricsRomanizationEnabled(true),
      controller.setLyricsRomanizationLanguages(const {
        LyricsRomanizationLanguage.korean,
        LyricsRomanizationLanguage.chinese,
      }),
    ]);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('settings.lyricsRomanizationEnabled'), isTrue);
    expect(preferences.getStringList('settings.lyricsRomanizationLanguages'), [
      'korean',
      'chinese',
    ]);
    expect(
      container
          .read(settingsControllerProvider)
          .value
          ?.lyricsRomanizationLanguages,
      const {
        LyricsRomanizationLanguage.korean,
        LyricsRomanizationLanguage.chinese,
      },
    );

    await controller.setLyricsRomanizationLanguages(const {});
    expect(preferences.getStringList('settings.lyricsRomanizationLanguages'), [
      'korean',
      'chinese',
    ]);
  });

  test('crossfade preferences accept and persist every whole second', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(
          _PersistingCrossfadeSettingsController.new,
        ),
      ],
    );
    addTearDown(container.dispose);

    final initial = await container.read(settingsControllerProvider.future);
    expect(initial.crossfadeEnabled, isFalse);
    expect(initial.crossfadeDuration, const Duration(seconds: 5));
    expect(
      supportedCrossfadeDurations.map((duration) => duration.inSeconds),
      orderedEquals(List<int>.generate(15, (index) => index + 1)),
    );

    final controller = container.read(settingsControllerProvider.notifier);
    await Future.wait([
      controller.setCrossfadeEnabled(true),
      controller.setCrossfadeDuration(const Duration(seconds: 2)),
      controller.setCrossfadeDuration(const Duration(seconds: 7)),
      controller.setCrossfadeDuration(const Duration(seconds: 14)),
    ]);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('settings.crossfadeEnabled'), isTrue);
    expect(preferences.getInt('settings.crossfadeSeconds'), 14);
    expect(
      container.read(settingsControllerProvider).value?.crossfadeDuration,
      const Duration(seconds: 14),
    );

    await controller.setCrossfadeDuration(const Duration(seconds: 1));
    expect(preferences.getInt('settings.crossfadeSeconds'), 1);
    await controller.setCrossfadeDuration(const Duration(seconds: 15));
    expect(preferences.getInt('settings.crossfadeSeconds'), 15);

    expect(
      () => controller.setCrossfadeDuration(Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => controller.setCrossfadeDuration(const Duration(seconds: 16)),
      throwsArgumentError,
    );
    expect(
      () => controller.setCrossfadeDuration(const Duration(milliseconds: 1500)),
      throwsArgumentError,
    );
  });

  test('missing or invalid stored crossfade seconds keep the 5 s default', () {
    expect(crossfadeDurationFromStoredSeconds(null), defaultCrossfadeDuration);
    expect(crossfadeDurationFromStoredSeconds(0), defaultCrossfadeDuration);
    expect(crossfadeDurationFromStoredSeconds(16), defaultCrossfadeDuration);
    expect(crossfadeDurationFromStoredSeconds(7), const Duration(seconds: 7));
  });

  test('mini player mode defaults safely and persists capsule', () async {
    expect(SurfaceBackgroundMode.fromCode(null), SurfaceBackgroundMode.accent);
    expect(
      SurfaceBackgroundMode.fromCode('unknown'),
      SurfaceBackgroundMode.accent,
    );
    expect(
      SurfaceBackgroundMode.fromCode('transparent'),
      SurfaceBackgroundMode.transparent,
    );
    expect(MiniPlayerMode.fromCode(null), MiniPlayerMode.capsule);
    expect(MiniPlayerMode.fromCode('unknown'), MiniPlayerMode.capsule);
    expect(MiniPlayerMode.fromCode('default'), MiniPlayerMode.standard);
    expect(MiniPlayerMode.fromCode('capsule'), MiniPlayerMode.capsule);
    expect(
      MiniPlayerBackgroundMode.fromCode(null),
      MiniPlayerBackgroundMode.accent,
    );
    expect(
      MiniPlayerBackgroundMode.fromCode('unknown'),
      MiniPlayerBackgroundMode.accent,
    );
    expect(
      MiniPlayerBackgroundMode.fromCode('artwork'),
      MiniPlayerBackgroundMode.artwork,
    );
    expect(
      MiniPlayerBackgroundMode.fromCode('transparent'),
      MiniPlayerBackgroundMode.transparent,
    );
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(
          _PersistingCrossfadeSettingsController.new,
        ),
      ],
    );
    addTearDown(container.dispose);

    final initial = await container.read(settingsControllerProvider.future);
    expect(initial.surfaceBackgroundMode, SurfaceBackgroundMode.accent);
    expect(initial.miniPlayerMode, MiniPlayerMode.capsule);
    expect(initial.miniPlayerBackgroundMode, MiniPlayerBackgroundMode.accent);

    await container
        .read(settingsControllerProvider.notifier)
        .setSurfaceBackgroundMode(SurfaceBackgroundMode.transparent);
    await container
        .read(settingsControllerProvider.notifier)
        .setMiniPlayerMode(MiniPlayerMode.capsule);
    await container
        .read(settingsControllerProvider.notifier)
        .setMiniPlayerBackgroundMode(MiniPlayerBackgroundMode.transparent);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('settings.surfaceBackgroundMode'),
      'transparent',
    );
    expect(preferences.getString('settings.miniPlayerMode'), 'capsule');
    expect(
      preferences.getString('settings.miniPlayerBackgroundMode'),
      'transparent',
    );
    expect(
      container.read(settingsControllerProvider).value?.surfaceBackgroundMode,
      SurfaceBackgroundMode.transparent,
    );
    expect(
      container.read(settingsControllerProvider).value?.miniPlayerMode,
      MiniPlayerMode.capsule,
    );
    expect(
      container
          .read(settingsControllerProvider)
          .value
          ?.miniPlayerBackgroundMode,
      MiniPlayerBackgroundMode.transparent,
    );
  });

  test('recommendation history preference defaults on and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(
          _PersistingCrossfadeSettingsController.new,
        ),
      ],
    );
    addTearDown(container.dispose);

    final initial = await container.read(settingsControllerProvider.future);
    expect(initial.recommendationHistoryEnabled, isTrue);

    await container
        .read(settingsControllerProvider.notifier)
        .setRecommendationHistoryEnabled(false);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool('settings.recommendationHistoryEnabled'),
      isFalse,
    );
    expect(
      container
          .read(settingsControllerProvider)
          .value
          ?.recommendationHistoryEnabled,
      isFalse,
    );
  });

  testWidgets(
    'privacy controls toggle learning and confirm clearing personalized data',
    (tester) async {
      _configureView(tester, const Size(430, 900));
      final navigationController = SettingsNavigationController();
      final controller = _TrackingSettingsController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(
          navigationController: navigationController,
          settingsControllerBuilder: () => controller,
        ),
      );
      await tester.pumpAndSettle();

      final historyCard = find.byKey(
        const ValueKey('settings-card-recommendation-history'),
      );
      final clearCard = find.byKey(
        const ValueKey('settings-card-clear-recommendations'),
      );
      expect(historyCard, findsOneWidget);
      expect(clearCard, findsOneWidget);

      await tester.ensureVisible(historyCard);
      await tester.tap(
        find.byKey(const ValueKey('recommendation-history-switch')),
      );
      await tester.pump();
      expect(controller.recommendationEnabledChanges, [false]);

      await tester.ensureVisible(clearCard);
      await tester.tap(clearCard);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recommendation-history-clear-confirmation')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('recommendation-history-clear-cancel')),
      );
      await tester.pumpAndSettle();
      expect(controller.clearCalls, 0);

      await tester.tap(clearCard);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recommendation-history-clear-confirm')),
      );
      await tester.pumpAndSettle();
      expect(controller.clearCalls, 1);
      expect(find.text('Historial y recomendaciones eliminados.'), findsOne);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'appearance opens as a detail page and returns to settings root',
    (tester) async {
      _configureView(tester, const Size(760, 1100));
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(navigationController: navigationController),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-tab-header-surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('settings-card-appearance')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('accent-palette-grid')), findsNothing);
      expect(navigationController.canPop, isFalse);

      await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
      await tester.pump();

      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-detail-appearance')),
        findsOneWidget,
      );
      final rootHeaderFade = find
          .ancestor(
            of: find.byKey(const ValueKey('settings-tab-title')),
            matching: find.byType(FadeTransition),
          )
          .first;
      final rootBodyFade = find
          .ancestor(
            of: find.byKey(const ValueKey('settings-root')),
            matching: find.byType(FadeTransition),
          )
          .first;
      final detailHeaderFade = find
          .ancestor(
            of: find.byKey(const ValueKey('settings-detail-title')),
            matching: find.byType(FadeTransition),
          )
          .first;
      final detailBodyFade = find
          .ancestor(
            of: find.byKey(const ValueKey('accent-palette-grid')),
            matching: find.byType(FadeTransition),
          )
          .first;
      expect(tester.element(rootHeaderFade), tester.element(rootBodyFade));
      expect(tester.element(detailHeaderFade), tester.element(detailBodyFade));

      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.widget<FadeTransition>(rootHeaderFade).opacity.value,
        lessThan(1),
      );
      expect(
        tester.widget<FadeTransition>(detailHeaderFade).opacity.value,
        greaterThan(0),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-detail-appearance')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('settings-root')), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-tab-header-surface')),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> &&
              key.value.startsWith('settings-detail-header-surface-');
        }),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('accent-palette-grid')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-detail-back')),
        findsOneWidget,
      );
      expect(navigationController.canPop, isTrue);

      await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-detail-appearance')),
        findsNothing,
      );
      expect(navigationController.canPop, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('appearance selects mini player style and background', (
    tester,
  ) async {
    _configureView(tester, const Size(430, 1000));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    final selector = find.byKey(const ValueKey('mini-player-mode-selector'));
    final surfaceBackgroundSelector = find.byKey(
      const ValueKey('surface-background-selector'),
    );
    final backgroundSelector = find.byKey(
      const ValueKey('mini-player-background-selector'),
    );
    expect(selector, findsOneWidget);
    expect(surfaceBackgroundSelector, findsOneWidget);
    expect(backgroundSelector, findsOneWidget);
    expect(find.text('Efectos de superficie'), findsOneWidget);
    expect(find.text('Mini reproductor'), findsOneWidget);
    expect(
      find.descendant(of: selector, matching: find.text('Estilo')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: selector, matching: find.text('Cápsula')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: surfaceBackgroundSelector,
        matching: find.text('Fondo de las superficies'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: surfaceBackgroundSelector,
        matching: find.text('Acento'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: backgroundSelector,
        matching: find.text('Fondo del Mini reproductor'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: backgroundSelector, matching: find.text('Acento')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(selector).dy,
      greaterThan(tester.getTopLeft(surfaceBackgroundSelector).dy),
    );
    expect(
      tester.getTopLeft(backgroundSelector).dy,
      greaterThan(tester.getTopLeft(selector).dy),
    );

    await tester.ensureVisible(surfaceBackgroundSelector);
    await tester.tap(surfaceBackgroundSelector);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-surface-background-dialog')),
      findsOneWidget,
    );
    expect(find.text('Fondo de las superficies'), findsWidgets);
    expect(
      find.byKey(const ValueKey('settings-surface-background-option-accent')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        const ValueKey('settings-surface-background-option-transparent'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: surfaceBackgroundSelector,
        matching: find.text('Transparente'),
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-mini-player-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-mini-player-option-default')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-mini-player-icon-default')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-mini-player-icon-capsule')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-mini-player-option-capsule')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-mini-player-dialog')),
      findsNothing,
    );
    expect(
      find.descendant(of: selector, matching: find.text('Cápsula')),
      findsOneWidget,
    );

    await tester.ensureVisible(backgroundSelector);
    await tester.tap(backgroundSelector);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-mini-player-background-dialog')),
      findsOneWidget,
    );
    expect(find.text('Fondo del Mini reproductor'), findsWidgets);
    expect(
      find.byKey(
        const ValueKey('settings-mini-player-background-option-accent'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('settings-mini-player-background-option-artwork'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        const ValueKey('settings-mini-player-background-option-transparent'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-mini-player-background-dialog')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: backgroundSelector,
        matching: find.text('Transparente'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving a settings detail resets only when the tab returns', (
    tester,
  ) async {
    _configureView(tester, const Size(760, 1100));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        active: false,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('settings-detail-appearance')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-root')), findsNothing);
    expect(navigationController.canPop, isTrue);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-detail-appearance')),
      findsNothing,
    );
    expect(navigationController.canPop, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings detail transition respects reduced motion', (
    tester,
  ) async {
    _configureView(tester, const Size(760, 1100));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    AnimatedSwitcher switcher() => tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey('settings-route-switcher')),
    );

    expect(switcher().duration, Duration.zero);
    expect(switcher().reverseDuration, Duration.zero);
    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('settings-detail-appearance')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-tab-title')), findsNothing);
    expect(find.byKey(const ValueKey('settings-detail-title')), findsOneWidget);
    expect(switcher().duration, Duration.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'language uses a selected modal option without opening a settings page',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      _configureView(tester, const Size(320, 720));
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(navigationController: navigationController),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('settings-card-language')));
      await tester.pumpAndSettle();

      final dialog = find.byKey(const ValueKey('settings-language-dialog'));
      final spanish = find.byKey(
        const ValueKey('settings-language-option-spanish'),
      );
      final english = find.byKey(
        const ValueKey('settings-language-option-english'),
      );
      expect(dialog, findsOneWidget);
      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-detail-back')), findsNothing);
      expect(navigationController.canPop, isFalse);
      expect(
        find.descendant(
          of: spanish,
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: english,
          matching: find.byIcon(Icons.radio_button_unchecked_rounded),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(english);
      await tester.pumpAndSettle();
      await tester.tap(english);
      await tester.pumpAndSettle();

      expect(dialog, findsNothing);
      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(navigationController.canPop, isFalse);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-card-language')),
          matching: find.text('English'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('settings cards use compact corners and spacing', (tester) async {
    _configureView(tester, const Size(760, 1100));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();

    final appearanceCard = find.byKey(
      const ValueKey('settings-card-appearance'),
    );
    final lyricsCard = find.byKey(
      const ValueKey('settings-card-lyrics-appearance'),
    );
    final timerCard = find.byKey(const ValueKey('settings-inline-timer'));
    final crossfadeCard = find.byKey(
      const ValueKey('settings-inline-crossfade'),
    );

    final cardMaterial = _outerMaterial(tester, appearanceCard);
    final timerMaterial = _outerMaterial(tester, timerCard);
    final crossfadeMaterial = _outerMaterial(tester, crossfadeCard);
    final cardShape = cardMaterial.shape! as RoundedRectangleBorder;
    final timerShape = timerMaterial.shape! as RoundedRectangleBorder;
    final crossfadeShape = crossfadeMaterial.shape! as RoundedRectangleBorder;
    expect(cardShape.borderRadius, BorderRadius.circular(6));
    expect(timerShape.borderRadius, BorderRadius.circular(6));
    expect(crossfadeShape.borderRadius, BorderRadius.circular(6));
    expect(timerMaterial.color, cardMaterial.color);
    expect(crossfadeMaterial.color, cardMaterial.color);
    expect(timerShape.side.color, cardShape.side.color);
    expect(timerShape.side.width, cardShape.side.width);
    expect(crossfadeShape.side.color, cardShape.side.color);
    expect(crossfadeShape.side.width, cardShape.side.width);

    final cardGap =
        tester.getTopLeft(lyricsCard).dy -
        tester.getBottomLeft(appearanceCard).dy;
    expect(cardGap, closeTo(6, 0.1));
    final playbackCardGap =
        tester.getTopLeft(crossfadeCard).dy -
        tester.getBottomLeft(timerCard).dy;
    expect(playbackCardGap, closeTo(6, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop crossfade matches the LIVE request storage card width', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _configureView(tester, const Size(1100, 1600));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();

    final crossfadeRect = tester.getRect(
      find.byKey(const ValueKey('settings-inline-crossfade')),
    );
    final liveStorageRect = tester.getRect(
      find.byKey(const ValueKey('settings-card-live-request-storage')),
    );

    expect(crossfadeRect.width, closeTo(760, 0.1));
    expect(crossfadeRect.width, closeTo(liveStorageRect.width, 0.1));
    expect(crossfadeRect.left, closeTo(liveStorageRect.left, 0.1));
    expect(crossfadeRect.right, closeTo(liveStorageRect.right, 0.1));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('wide Android keeps the compact crossfade card width', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _configureView(tester, const Size(760, 1100));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .getSize(find.byKey(const ValueKey('settings-inline-crossfade')))
          .width,
      closeTo(520, 0.1),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('lyrics appearance offers animation, alignment, and preview', (
    tester,
  ) async {
    _configureView(tester, const Size(430, 900));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        overrides: [
          lyricsRomanizationServiceProvider.overrideWithValue(
            _PreviewLyricsRomanizationService(),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('settings-card-lyrics-appearance'));
    expect(card, findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-detail-lyrics')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lyrics-animation-options')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lyrics-alignment-options')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lyrics-animation-preview')),
      findsOneWidget,
    );
    final initialActivePreview = tester.widget<Text>(
      find.byKey(const ValueKey('lyrics-preview-active-line')),
    );
    final initialPreviousPreview = tester.widget<Text>(
      find.byKey(const ValueKey('lyrics-preview-previous-line')),
    );
    expect(initialActivePreview.style?.fontSize, 16);
    expect(initialPreviousPreview.style?.fontSize, 15);
    expect(
      initialActivePreview.style!.fontSize! -
          initialPreviousPreview.style!.fontSize!,
      1,
    );
    final previewAccent = Theme.of(
      tester.element(find.byKey(const ValueKey('lyrics-preview-active-line'))),
    ).colorScheme.primary;
    expect(initialActivePreview.style?.shadows, hasLength(2));
    expect(
      initialActivePreview.style?.shadows?[0].color,
      previewAccent.withValues(alpha: 0.30),
    );
    expect(
      initialActivePreview.style?.shadows?[1].color,
      previewAccent.withValues(alpha: 0.14),
    );
    expect(
      find.byKey(const ValueKey('lyrics-animation-option-none')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('lyrics-romanization-toggle')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lyrics-romanization-languages')),
      findsNothing,
    );
    for (final slot in const ['previous', 'active', 'next']) {
      expect(
        find.byKey(ValueKey('lyrics-preview-$slot-romanized-line')),
        findsNothing,
      );
    }

    await tester.tap(
      find.byKey(const ValueKey('lyrics-animation-option-slide')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('lyrics-animation-option-slide')),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.text('Centrada'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('lyrics-preview-active-line')),
          )
          .textAlign,
      TextAlign.center,
    );
    expect(
      find.byKey(const ValueKey('lyrics-preview-slide-centered-2')),
      findsOneWidget,
    );

    final romanizationToggle = find.byKey(
      const ValueKey('lyrics-romanization-toggle'),
    );
    await tester.ensureVisible(romanizationToggle);
    await tester.tap(romanizationToggle);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('lyrics-romanization-languages')),
      findsOneWidget,
    );
    for (final language in LyricsRomanizationLanguage.values) {
      expect(
        find.byKey(ValueKey('lyrics-romanization-language-${language.code}')),
        findsOneWidget,
      );
    }
    final originalPreviewLine = find.byKey(
      const ValueKey('lyrics-preview-active-line'),
    );
    final romanizedPreviewLine = find.byKey(
      const ValueKey('lyrics-preview-active-romanized-line'),
    );
    await tester.ensureVisible(originalPreviewLine);
    await tester.pumpAndSettle();
    final originalText = tester.widget<Text>(originalPreviewLine);
    final romanizedText = tester.widget<Text>(romanizedPreviewLine);
    expect(originalText.data, isNot(startsWith('Romanized: ')));
    expect(romanizedText.data, 'Romanized: ${originalText.data}');
    expect(
      romanizedText.style!.fontSize,
      lessThan(originalText.style!.fontSize!),
    );
    expect(
      tester.getTopLeft(romanizedPreviewLine).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(originalPreviewLine).dy),
    );
    for (final slot in const ['previous', 'active', 'next']) {
      expect(find.byKey(ValueKey('lyrics-preview-$slot-pair')), findsOneWidget);
      expect(
        find.byKey(ValueKey('lyrics-preview-$slot-romanized-line')),
        findsOneWidget,
      );
    }

    await tester.tap(find.byKey(const ValueKey('lyrics-preview-replay')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(navigationController.maybePop(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
  });

  testWidgets(
    'romanization preview pairs fit compact and wide settings layouts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = null;
      });

      for (final layout in const [
        (size: Size(320, 720), platform: TargetPlatform.android),
        (size: Size(760, 1100), platform: TargetPlatform.windows),
      ]) {
        tester.view.physicalSize = layout.size;
        debugDefaultTargetPlatformOverride = layout.platform;
        final navigationController = SettingsNavigationController();
        addTearDown(navigationController.dispose);

        await tester.pumpWidget(
          _settingsHarness(
            navigationController: navigationController,
            overrides: [
              lyricsRomanizationServiceProvider.overrideWithValue(
                _PreviewLyricsRomanizationService(),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final card = find.byKey(
          const ValueKey('settings-card-lyrics-appearance'),
        );
        await tester.ensureVisible(card);
        await tester.tap(card);
        await tester.pumpAndSettle();

        final toggle = find.byKey(const ValueKey('lyrics-romanization-toggle'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();

        final preview = find.byKey(const ValueKey('lyrics-animation-preview'));
        await tester.ensureVisible(preview);
        await tester.pumpAndSettle();
        final previewRect = tester.getRect(preview);
        final expectedWidth = layout.size.width == 320 ? 296.0 : 520.0;
        expect(previewRect.width, closeTo(expectedWidth, 0.1));

        for (final slot in const ['previous', 'active', 'next']) {
          final original = find.byKey(ValueKey('lyrics-preview-$slot-line'));
          final romanized = find.byKey(
            ValueKey('lyrics-preview-$slot-romanized-line'),
          );
          expect(original, findsOneWidget);
          expect(romanized, findsOneWidget);

          final originalText = tester.widget<Text>(original);
          final romanizedText = tester.widget<Text>(romanized);
          expect(
            romanizedText.style!.fontSize,
            lessThan(originalText.style!.fontSize!),
          );
          expect(
            tester.getTopLeft(romanized).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(original).dy),
          );

          final originalRect = tester.getRect(original);
          final romanizedRect = tester.getRect(romanized);
          for (final lineRect in [originalRect, romanizedRect]) {
            expect(lineRect.left, greaterThanOrEqualTo(previewRect.left));
            expect(lineRect.right, lessThanOrEqualTo(previewRect.right));
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('timer and crossfade stay inline while storage opens detail', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _configureView(tester, const Size(760, 1600));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reproducción'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-inline-timer')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-inline-timer')),
        matching: find.byType(SwitchListTile),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-inline-crossfade')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-inline-crossfade')),
        matching: find.byType(SwitchListTile),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('settings-crossfade-switch')));
    await tester.pumpAndSettle();
    final desktopCrossfadeCard = tester.getRect(
      find.byKey(const ValueKey('settings-inline-crossfade')),
    );
    final desktopDurationSlider = find.byKey(
      const ValueKey('settings-crossfade-duration-slider'),
    );
    expect(desktopDurationSlider, findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-crossfade-current-5s')),
      findsOneWidget,
    );
    for (var seconds = 1; seconds <= 15; seconds++) {
      expect(
        find.byKey(ValueKey('settings-crossfade-tick-${seconds}s')),
        findsOneWidget,
      );
    }
    for (final seconds in const [1, 5, 10, 15]) {
      final labelTarget = find.byKey(
        ValueKey('settings-crossfade-${seconds}s'),
      );
      final labelText = find.descendant(
        of: labelTarget,
        matching: find.byType(Text),
      );
      final tick = find.byKey(ValueKey('settings-crossfade-tick-${seconds}s'));
      expect(labelTarget, findsOneWidget);
      expect(tester.getSize(labelTarget).height, greaterThanOrEqualTo(48));
      expect(
        tester.getCenter(labelText).dx,
        closeTo(tester.getCenter(tick).dx, 1.0),
        reason: '$seconds s label must line up with its actual tick.',
      );
    }
    expect(
      desktopCrossfadeCard.contains(
        tester.getRect(desktopDurationSlider).center,
      ),
      isTrue,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-inline-crossfade')),
        matching: find.byType(Slider),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('settings-card-timer')), findsNothing);
    expect(find.byKey(const ValueKey('settings-inline-tools')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-card-tools')), findsNothing);
    expect(find.byKey(const ValueKey('storage-import-backup')), findsNothing);
    expect(navigationController.canPop, isFalse);
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-card-storage')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-detail-storage')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('storage-import-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-import-csv')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-csv')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('storage-local-music-filters')),
      findsNothing,
    );
    expect(find.text('Importar'), findsOneWidget);
    expect(find.text('Exportar'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('download-directory-field')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('music-import-start')), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(navigationController.canPop, isTrue);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'storage configures local music filters with a multi-select card',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      _configureView(tester, const Size(430, 1000));
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(navigationController: navigationController),
      );
      await tester.pumpAndSettle();
      final storageSettings = find.byKey(
        const ValueKey('settings-card-storage'),
      );
      await tester.ensureVisible(storageSettings);
      await tester.pumpAndSettle();

      final filtersCard = find.byKey(
        const ValueKey('storage-local-music-filters'),
      );
      expect(filtersCard, findsOneWidget);
      expect(
        find.descendant(
          of: storageSettings,
          matching: find.text('Respaldo y Restauración'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(filtersCard).dy,
        greaterThan(tester.getBottomLeft(storageSettings).dy),
      );
      expect(
        find.descendant(
          of: filtersCard,
          matching: find.text('4 filtros activos'),
        ),
        findsOneWidget,
      );
      await tester.tap(filtersCard);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-local-music-filters-dialog')),
        findsOneWidget,
      );
      final whatsAppOption = find.byKey(
        const ValueKey('local-music-filter-whatsapp'),
      );
      final shortTrackOption = find.byKey(
        const ValueKey('local-music-filter-short-tracks'),
      );
      final telegramOption = find.byKey(
        const ValueKey('local-music-filter-telegram'),
      );
      final recordingsOption = find.byKey(
        const ValueKey('local-music-filter-recordings'),
      );
      for (final option in [
        whatsAppOption,
        telegramOption,
        recordingsOption,
        shortTrackOption,
      ]) {
        expect(
          tester
              .widget<CheckboxListTile>(
                find.descendant(
                  of: option,
                  matching: find.byType(CheckboxListTile),
                ),
              )
              .value,
          isTrue,
        );
      }

      await tester.tap(whatsAppOption);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('local-music-filters-apply')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: filtersCard,
          matching: find.text('3 filtros activos'),
        ),
        findsOneWidget,
      );
      final container = ProviderScope.containerOf(tester.element(filtersCard));
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .localMusicFilters,
        const {
          LocalMusicFilter.hideTelegramAudio,
          LocalMusicFilter.hideAudioRecordings,
          LocalMusicFilter.hideTracksUnder30Seconds,
        },
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('playback settings and storage fit a 320 px Android phone', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _configureView(tester, const Size(320, 720));
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('accent-palette-grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-ocean')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('accent-ocean'))).width,
      greaterThanOrEqualTo(48),
    );
    expect(find.byKey(const ValueKey('accent-expand-button')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-inline-timer')), findsOneWidget);
    final timerSwitch = find.descendant(
      of: find.byKey(const ValueKey('settings-inline-timer')),
      matching: find.byType(SwitchListTile),
    );
    final crossfadeCard = find.byKey(
      const ValueKey('settings-inline-crossfade'),
    );
    final crossfadeSwitch = find.byKey(
      const ValueKey('settings-crossfade-switch'),
    );
    expect(timerSwitch, findsOneWidget);
    expect(crossfadeCard, findsOneWidget);
    expect(crossfadeSwitch, findsOneWidget);
    expect(
      find.descendant(
        of: crossfadeCard,
        matching: find.text(
          'Superpone suavemente el final de una canción con el inicio de la siguiente.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: crossfadeCard, matching: find.text('Desactivado')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('settings-crossfade-5s')), findsNothing);
    expect(find.byKey(const ValueKey('settings-crossfade-10s')), findsNothing);
    expect(find.byKey(const ValueKey('settings-crossfade-15s')), findsNothing);
    expect(find.byKey(const ValueKey('settings-crossfade-1s')), findsNothing);
    expect(find.byKey(const ValueKey('settings-card-timer')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(crossfadeSwitch);
    await tester.pumpAndSettle();
    await tester.tap(crossfadeSwitch);
    await tester.pumpAndSettle();

    final durationSlider = find.byKey(
      const ValueKey('settings-crossfade-duration-slider'),
    );
    final optionsTransition = find.byKey(
      const ValueKey('settings-crossfade-options-transition'),
    );
    final fiveSeconds = find.byKey(const ValueKey('settings-crossfade-5s'));
    final tenSeconds = find.byKey(const ValueKey('settings-crossfade-10s'));
    final fifteenSeconds = find.byKey(const ValueKey('settings-crossfade-15s'));
    final oneSecond = find.byKey(const ValueKey('settings-crossfade-1s'));
    expect(durationSlider, findsOneWidget);
    expect(optionsTransition, findsOneWidget);
    expect(oneSecond, findsOneWidget);
    expect(fiveSeconds, findsOneWidget);
    expect(tenSeconds, findsOneWidget);
    expect(fifteenSeconds, findsOneWidget);
    for (var seconds = 1; seconds <= 15; seconds++) {
      expect(
        find.byKey(ValueKey('settings-crossfade-tick-${seconds}s')),
        findsOneWidget,
      );
    }
    expect(
      tester.widget<AnimatedSwitcher>(optionsTransition).duration,
      const Duration(milliseconds: 180),
    );
    expect(
      find.descendant(of: crossfadeCard, matching: find.byType(Slider)),
      findsNothing,
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: fiveSeconds, matching: find.byType(Text)),
          )
          .style
          ?.fontWeight,
      FontWeight.w900,
    );

    await tester.tap(tenSeconds);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: crossfadeCard,
        matching: find.text(
          'Superpone suavemente el final de una canción con el inicio de la siguiente.',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('Duración: 10 s'), findsNothing);
    expect(
      tester
          .widget<Text>(
            find.descendant(of: tenSeconds, matching: find.byType(Text)),
          )
          .style
          ?.fontWeight,
      FontWeight.w900,
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: fiveSeconds, matching: find.byType(Text)),
          )
          .style
          ?.fontWeight,
      FontWeight.w700,
    );

    final sliderRect = tester.getRect(durationSlider);
    const thumbDiameter = 18.0;
    final sevenSecondX =
        sliderRect.left +
        thumbDiameter / 2 +
        (sliderRect.width - thumbDiameter) * (6 / 14);
    await tester.tapAt(Offset(sevenSecondX, sliderRect.center.dy));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-crossfade-current-7s')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-crossfade-current-8s')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-crossfade-current-7s')),
      findsOneWidget,
    );

    final providerContainer = ProviderScope.containerOf(
      tester.element(durationSlider),
    );
    expect(
      providerContainer
          .read(settingsControllerProvider)
          .value
          ?.crossfadeDuration,
      const Duration(seconds: 7),
    );
    final twelveSecondX =
        sliderRect.left +
        thumbDiameter / 2 +
        (sliderRect.width - thumbDiameter) * (11 / 14);
    final drag = await tester.startGesture(
      Offset(sevenSecondX, sliderRect.center.dy),
    );
    await drag.moveTo(Offset(twelveSecondX, sliderRect.center.dy));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('settings-crossfade-current-12s')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<AnimatedPositioned>(
            find.byKey(const ValueKey('settings-crossfade-duration-thumb')),
          )
          .duration,
      Duration.zero,
      reason: 'The thumb must track the pointer without animation lag.',
    );
    expect(
      tester
          .widget<AnimatedPositioned>(
            find.byKey(const ValueKey('settings-crossfade-duration-fill')),
          )
          .duration,
      Duration.zero,
      reason: 'The selected fill must track the pointer without animation lag.',
    );
    expect(
      providerContainer
          .read(settingsControllerProvider)
          .value
          ?.crossfadeDuration,
      const Duration(seconds: 7),
      reason: 'Dragging previews locally without reconfiguring playback.',
    );
    await drag.up();
    await tester.pumpAndSettle();
    expect(
      providerContainer
          .read(settingsControllerProvider)
          .value
          ?.crossfadeDuration,
      const Duration(seconds: 12),
    );

    await tester.dragFrom(
      tester.getRect(durationSlider).center,
      Offset(tester.getRect(durationSlider).width / 2, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.descendant(of: fifteenSeconds, matching: find.byType(Text)),
          )
          .style
          ?.fontWeight,
      FontWeight.w900,
    );
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-card-storage')),
      240,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('settings-root')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('download-directory-field')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('download-directory-browse')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('storage-import-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-import-csv')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-csv')), findsOneWidget);
    expect(find.text('Respaldo'), findsNothing);
    expect(find.byKey(const ValueKey('music-import-start')), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('crossfade slider keeps semantics and honors reduced motion', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _configureView(tester, const Size(360, 900));
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    final crossfadeSwitch = find.byKey(
      const ValueKey('settings-crossfade-switch'),
    );
    await tester.ensureVisible(crossfadeSwitch);
    await tester.tap(crossfadeSwitch);
    await tester.pump();

    final transition = find.byKey(
      const ValueKey('settings-crossfade-options-transition'),
    );
    final slider = find.byKey(
      const ValueKey('settings-crossfade-duration-slider'),
    );
    expect(tester.widget<AnimatedSwitcher>(transition).duration, Duration.zero);
    expect(slider, findsOneWidget);
    final semanticsData = tester.getSemantics(slider).getSemanticsData();
    expect(semanticsData.flagsCollection.isSlider, isTrue);
    expect(semanticsData.label, 'Duración del crossfade');
    expect(semanticsData.value, '5 s');
    expect(semanticsData.increasedValue, '6 s');
    expect(semanticsData.decreasedValue, '4 s');
    expect(semanticsData.hasAction(SemanticsAction.increase), isTrue);
    expect(semanticsData.hasAction(SemanticsAction.decrease), isTrue);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'storage confirms destructive ZIP import and offers CSV profiles',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      _configureView(tester, const Size(760, 1000));
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(navigationController: navigationController),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('settings-card-storage')),
      );
      await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
      await tester.pumpAndSettle();

      final importBackup = find.byKey(const ValueKey('storage-import-backup'));
      await tester.ensureVisible(importBackup);
      await tester.tap(importBackup);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('backup-import-confirmation')),
        findsOneWidget,
      );
      expect(find.textContaining('reemplaz'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('backup-import-cancel')));
      await tester.pumpAndSettle();

      final exportCsv = find.byKey(const ValueKey('storage-export-csv'));
      await tester.ensureVisible(exportCsv);
      await tester.tap(exportCsv);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('csv-export-profile-dialog')),
        findsOneWidget,
      );
      for (final profile in const <(String, String)>[
        ('bstream', 'BStream Music'),
        ('metroList', 'MetroList'),
        ('harmony', 'Harmony / RiMusic'),
        ('soundiiz', 'Soundiiz'),
      ]) {
        final tileFinder = find.byKey(ValueKey('csv-profile-${profile.$1}'));
        expect(tileFinder, findsOneWidget);
        expect(
          find.descendant(of: tileFinder, matching: find.text(profile.$2)),
          findsOneWidget,
        );
        expect(tester.widget<ListTile>(tileFinder).subtitle, isNull);
        expect(
          tester
              .widget<Material>(
                find.byKey(ValueKey('csv-profile-surface-${profile.$1}')),
              )
              .color,
          AppColors.neutralSurfaceFor(tester.element(tileFinder)),
        );
      }
      await tester.tap(find.byKey(const ValueKey('csv-export-profile-cancel')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('CSV import previews before downloading and reports completion', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    _configureView(tester, const Size(760, 1000));
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);
    final transferController = _ImmediateCsvTransferController();

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        overrides: [
          storageImportFilePickerProvider.overrideWithValue(
            ({required dialogTitle, required allowedExtensions}) async =>
                FilePickerResult([
                  PlatformFile(name: 'MetroList.csv', size: 42, path: 'x.csv'),
                ]),
          ),
          libraryCsvTransferControllerProvider.overrideWith(
            () => transferController,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-card-storage')),
    );
    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    final importCsv = find.byKey(const ValueKey('storage-import-csv'));
    await tester.ensureVisible(importCsv);
    await tester.tap(importCsv);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('csv-import-preview')), findsOneWidget);
    expect(find.textContaining('1 canciones'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('csv-import-preview-confirm')));
    await tester.pumpAndSettle();
    expect(transferController.importCalls, 1);
    expect(
      find.byKey(const ValueKey('csv-import-progress-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('1 descargadas'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('csv-import-close')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'storage transfer cards fit a small phone with large accessible text',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      _configureView(tester, const Size(320, 568));
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(navigationController: navigationController),
      );
      await tester.pumpAndSettle();
      final storageCard = find.byKey(const ValueKey('settings-card-storage'));
      await tester.scrollUntilVisible(
        storageCard,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(storageCard);
      await tester.pumpAndSettle();

      const transferKeys = [
        'storage-import-backup',
        'storage-import-csv',
        'storage-export-backup',
        'storage-export-csv',
      ];
      for (final key in transferKeys) {
        final card = find.byKey(ValueKey(key));
        expect(card, findsOneWidget);
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        expect(tester.getSize(card).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      }
      final exportCsv = find.byKey(const ValueKey('storage-export-csv'));
      await tester.ensureVisible(exportCsv);
      await tester.tap(exportCsv);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('csv-export-profile-dialog')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('csv-export-profile-cancel')));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('system Back closes settings detail before leaving the tab', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _configureView(tester, const Size(430, 900));
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(_homeHarness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ajustes').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-detail-appearance')),
      findsOneWidget,
    );
    expect(
      _navigationIcon(tester, Icons.settings_rounded).color,
      _activeColor(tester),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-detail-appearance')),
      findsNothing,
    );
    expect(
      _navigationIcon(tester, Icons.settings_rounded).color,
      _activeColor(tester),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      _navigationIcon(tester, Icons.home_rounded).color,
      _activeColor(tester),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('main tab transition respects reduced motion', (tester) async {
    await tester.pumpWidget(_homeHarness(disableAnimations: true));
    await tester.pumpAndSettle();

    AnimatedOpacity slotOpacity(Finder slot) => tester.widget<AnimatedOpacity>(
      find.descendant(of: slot, matching: find.byType(AnimatedOpacity)).first,
    );

    final home = find.byKey(const ValueKey('home-view'));
    expect(slotOpacity(home).duration, Duration.zero);
    expect(slotOpacity(home).opacity, 1);

    await tester.tap(find.text('Ajustes').last);
    await tester.pump();

    final settings = find.byKey(const ValueKey('settings-view'));
    expect(settings, findsOneWidget);
    expect(slotOpacity(settings).duration, Duration.zero);
    expect(slotOpacity(settings).opacity, 1);
    expect(tester.takeException(), isNull);
  });
}

void _configureView(WidgetTester tester, Size size) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(() {
    tester.view
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });
}

Widget _settingsHarness({
  required SettingsNavigationController navigationController,
  List<Override> overrides = const [],
  bool disableAnimations = false,
  bool active = true,
  SettingsController Function()? settingsControllerBuilder,
}) {
  return ProviderScope(
    overrides: [
      ..._providerOverrides(
        settingsControllerBuilder: settingsControllerBuilder,
      ),
      ...overrides,
    ],
    child: MaterialApp(
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: Scaffold(
        body: SettingsPanel(
          active: active,
          navigationController: navigationController,
        ),
      ),
    ),
  );
}

Widget _homeHarness({bool disableAnimations = false}) {
  return ProviderScope(
    overrides: [
      ..._providerOverrides(),
      downloaderWarmupProvider.overrideWith((ref) async {}),
      localLibraryReconciliationProvider.overrideWith(
        (ref) async => LocalLibraryReconciliationResult.empty,
      ),
      historyProvider.overrideWith((ref) async => const <LocalTrack>[]),
      libraryTracksProvider.overrideWith((ref) async => const <LocalTrack>[]),
      personalizedHomeFeedSourceProvider.overrideWithValue(null),
      homeArtistRecommendationSourceProvider.overrideWithValue(null),
      youtubeMusicHomeRecommendationsProvider.overrideWith(
        (ref) async => const <HomeRecommendationSection>[],
      ),
      playlistsControllerProvider.overrideWith(_EmptyPlaylistsController.new),
      playerControllerProvider.overrideWith(_IdlePlayerController.new),
      desktopMediaSessionProvider.overrideWithValue(null),
      incomingTrackLinkServiceProvider.overrideWithValue(
        const _EmptyIncomingTrackLinkService(),
      ),
    ],
    child: MaterialApp(
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: const HomePage(),
    ),
  );
}

final class _EmptyIncomingTrackLinkService implements IncomingTrackLinkService {
  const _EmptyIncomingTrackLinkService();

  @override
  Stream<Uri> get links => const Stream<Uri>.empty();
}

List<Override> _providerOverrides({
  SettingsController Function()? settingsControllerBuilder,
}) {
  return [
    settingsControllerProvider.overrideWith(
      settingsControllerBuilder ?? _FixedSettingsController.new,
    ),
    appStringsProvider.overrideWithValue(const AppStrings(AppLanguage.spanish)),
    tiktokLiveControllerProvider.overrideWith(_IdleTikTokLiveController.new),
    youtubeMusicSessionStoreProvider.overrideWithValue(
      const _AnonymousYouTubeMusicSessionStore(),
    ),
    youtubeMusicAccountClientProvider.overrideWithValue(
      const UnconfiguredYouTubeMusicAccountClient(),
    ),
  ];
}

Icon _navigationIcon(WidgetTester tester, IconData icon) {
  final navigation = find.byKey(const ValueKey('bottom-navigation-content'));
  return tester.widget<Icon>(
    find.descendant(of: navigation, matching: find.byIcon(icon)),
  );
}

Color _activeColor(WidgetTester tester) {
  final context = tester.element(
    find.byKey(const ValueKey('bottom-navigation-content')),
  );
  return Theme.of(context).colorScheme.primary;
}

Material _outerMaterial(WidgetTester tester, Finder surface) {
  return tester.widget<Material>(
    find.descendant(of: surface, matching: find.byType(Material)).first,
  );
}

class _FixedSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.spanish,
  );

  @override
  Future<void> setLanguage(AppLanguage language) async {
    final current = await future;
    state = AsyncData(current.copyWith(language: language));
  }

  @override
  Future<void> setMiniPlayerMode(MiniPlayerMode mode) async {
    final current = await future;
    state = AsyncData(current.copyWith(miniPlayerMode: mode));
  }

  @override
  Future<void> setSurfaceBackgroundMode(SurfaceBackgroundMode mode) async {
    final current = await future;
    state = AsyncData(current.copyWith(surfaceBackgroundMode: mode));
  }

  @override
  Future<void> setMiniPlayerBackgroundMode(
    MiniPlayerBackgroundMode mode,
  ) async {
    final current = await future;
    state = AsyncData(current.copyWith(miniPlayerBackgroundMode: mode));
  }

  @override
  Future<void> setLyricsAnimationStyle(
    LyricsAnimationStyle lyricsAnimationStyle,
  ) async {
    final current = await future;
    state = AsyncData(
      current.copyWith(lyricsAnimationStyle: lyricsAnimationStyle),
    );
  }

  @override
  Future<void> setLyricsTextAlignment(
    LyricsTextAlignment lyricsTextAlignment,
  ) async {
    final current = await future;
    state = AsyncData(
      current.copyWith(lyricsTextAlignment: lyricsTextAlignment),
    );
  }

  @override
  Future<void> setLocalMusicFilters(Set<LocalMusicFilter> filters) async {
    final current = await future;
    state = AsyncData(
      current.copyWith(
        localMusicFilters: Set<LocalMusicFilter>.unmodifiable(filters),
      ),
    );
  }

  @override
  Future<void> setCrossfadeEnabled(bool enabled) async {
    final current = await future;
    state = AsyncData(current.copyWith(crossfadeEnabled: enabled));
  }

  @override
  Future<void> setCrossfadeDuration(Duration duration) async {
    final current = await future;
    state = AsyncData(current.copyWith(crossfadeDuration: duration));
  }
}

class _PersistingCrossfadeSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.spanish,
  );
}

class _TrackingSettingsController extends _FixedSettingsController {
  final List<bool> recommendationEnabledChanges = <bool>[];
  int clearCalls = 0;

  @override
  Future<void> setRecommendationHistoryEnabled(bool enabled) async {
    recommendationEnabledChanges.add(enabled);
    final current = await future;
    state = AsyncData(current.copyWith(recommendationHistoryEnabled: enabled));
  }

  @override
  Future<void> clearRecommendationHistory() async {
    clearCalls += 1;
  }
}

class _PreviewLyricsRomanizationService extends LyricsRomanizationService {
  @override
  Future<List<String>> romanizePreview(
    List<String> lines,
    Set<LyricsRomanizationLanguage> languages,
  ) async => [for (final line in lines) 'Romanized: $line'];
}

class _IdleTikTokLiveController extends TikTokLiveController {
  @override
  Future<TikTokLiveState> build() async => const TikTokLiveState(
    creatorInput: '',
    status: TikTokLiveStatus.idle,
    message: 'Listo para conectar.',
  );
}

class _AnonymousYouTubeMusicSessionStore implements YouTubeMusicSessionStore {
  const _AnonymousYouTubeMusicSessionStore();

  @override
  Future<void> delete() async {}

  @override
  Future<YouTubeMusicSessionCredential?> read() async => null;

  @override
  Future<void> write(YouTubeMusicSessionCredential credential) async {}
}

class _EmptyPlaylistsController extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => const <Playlist>[];
}

class _IdlePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);
}

class _ImmediateCsvTransferController extends LibraryCsvTransferController {
  int importCalls = 0;

  static const document = LibraryCsvDocument(
    tracks: [
      LibraryCsvTrack(
        rowNumber: 2,
        title: 'Song',
        artist: 'Artist',
        youtubeVideoId: 'dQw4w9WgXcQ',
      ),
    ],
    detectedFormat: LibraryCsvDetectedFormat.metroList,
    defaultPlaylistName: 'MetroList',
    hasPlaylistColumn: false,
  );

  @override
  Future<LibraryCsvDocument> preview(String path) async {
    state = const LibraryCsvTransferState(
      phase: LibraryCsvTransferPhase.completed,
      document: document,
    );
    return document;
  }

  @override
  Future<LibraryCsvImportResult> importDocument(
    LibraryCsvDocument document,
  ) async {
    importCalls++;
    const result = LibraryCsvImportResult(
      total: 1,
      processed: 1,
      downloaded: 1,
      reused: 0,
      failed: 0,
      playlistsUpdated: 1,
      cancelled: false,
      failures: [],
    );
    state = const LibraryCsvTransferState(
      phase: LibraryCsvTransferPhase.completed,
      document: _ImmediateCsvTransferController.document,
      result: result,
    );
    return result;
  }
}
