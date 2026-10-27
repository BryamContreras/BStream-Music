import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/core/widgets/app_shared_widgets.dart';
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
import 'package:bstream_music/services/sharing/incoming_csv_file_service.dart';
import 'package:bstream_music/services/storage/library_csv_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_account_client.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('remote artwork toggles persist and are mutually exclusive', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(
          _PersistingCrossfadeSettingsController.new,
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      (await container.read(
        settingsControllerProvider.future,
      )).spotifyCanvasEnabled,
      isFalse,
    );
    expect(
      container
          .read(settingsControllerProvider)
          .value!
          .appleAnimatedArtworkEnabled,
      isFalse,
    );
    await container
        .read(settingsControllerProvider.notifier)
        .setAppleAnimatedArtworkEnabled(true);
    expect(
      container
          .read(settingsControllerProvider)
          .value!
          .appleAnimatedArtworkEnabled,
      isTrue,
    );
    await container
        .read(settingsControllerProvider.notifier)
        .setSpotifyCanvasEnabled(true);
    expect(
      container.read(settingsControllerProvider).value?.spotifyCanvasEnabled,
      isTrue,
    );
    expect(
      container
          .read(settingsControllerProvider)
          .value!
          .appleAnimatedArtworkEnabled,
      isFalse,
    );
    await container
        .read(settingsControllerProvider.notifier)
        .setAppleAnimatedArtworkEnabled(true);
    expect(
      container.read(settingsControllerProvider).value!.spotifyCanvasEnabled,
      isFalse,
    );
    expect(
      container
          .read(settingsControllerProvider)
          .value!
          .appleAnimatedArtworkEnabled,
      isTrue,
    );
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'settings.spotifyCanvasEnabled',
      ),
      isFalse,
    );
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'settings.appleAnimatedArtworkEnabled',
      ),
      isTrue,
    );
  });

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

  test('skip silence defaults off and persists the latest toggle', () async {
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
    expect(initial.skipSilenceEnabled, isFalse);

    final controller = container.read(settingsControllerProvider.notifier);
    await Future.wait([
      controller.setSkipSilenceEnabled(true),
      controller.setSkipSilenceEnabled(false),
      controller.setSkipSilenceEnabled(true),
    ]);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool('settings.skipSilenceEnabled'), isTrue);
    expect(
      container.read(settingsControllerProvider).value?.skipSilenceEnabled,
      isTrue,
    );
  });

  test('missing or invalid stored crossfade seconds keep the 5 s default', () {
    expect(crossfadeDurationFromStoredSeconds(null), defaultCrossfadeDuration);
    expect(crossfadeDurationFromStoredSeconds(0), defaultCrossfadeDuration);
    expect(crossfadeDurationFromStoredSeconds(16), defaultCrossfadeDuration);
    expect(crossfadeDurationFromStoredSeconds(7), const Duration(seconds: 7));
  });

  test('mini player mode decodes safely and persists capsule', () async {
    expect(SurfaceBackgroundMode.fromCode(null), SurfaceBackgroundMode.accent);
    expect(
      SurfaceBackgroundMode.fromCode('unknown'),
      SurfaceBackgroundMode.accent,
    );
    expect(
      SurfaceBackgroundMode.fromCode('transparent'),
      SurfaceBackgroundMode.transparent,
    );
    expect(
      SurfaceBackgroundMode.fromCode('liquidGlass'),
      SurfaceBackgroundMode.liquidGlass,
    );
    expect(
      MiniPlayerMode.fromCode(null, platform: TargetPlatform.android),
      MiniPlayerMode.capsule,
    );
    expect(
      MiniPlayerMode.fromCode('unknown', platform: TargetPlatform.android),
      MiniPlayerMode.capsule,
    );
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
    expect(
      MiniPlayerBackgroundMode.fromCode('liquidGlass'),
      MiniPlayerBackgroundMode.liquidGlass,
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

    await container
        .read(settingsControllerProvider.notifier)
        .setSurfaceBackgroundMode(SurfaceBackgroundMode.liquidGlass);
    await container
        .read(settingsControllerProvider.notifier)
        .setMiniPlayerBackgroundMode(MiniPlayerBackgroundMode.liquidGlass);

    expect(
      preferences.getString('settings.surfaceBackgroundMode'),
      'liquidGlass',
    );
    expect(
      preferences.getString('settings.miniPlayerBackgroundMode'),
      'liquidGlass',
    );
    expect(
      container.read(settingsControllerProvider).value?.surfaceBackgroundMode,
      SurfaceBackgroundMode.liquidGlass,
    );
    expect(
      container
          .read(settingsControllerProvider)
          .value
          ?.miniPlayerBackgroundMode,
      MiniPlayerBackgroundMode.liquidGlass,
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
      await _ensureSettingsVisible(tester, historyCard);
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
      final rootHeaderRect = tester.getRect(
        find.byKey(const ValueKey('settings-tab-header-surface')),
      );
      expect(
        find.byKey(const ValueKey('settings-card-appearance')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('accent-palette-grid')), findsNothing);
      expect(navigationController.canPop, isFalse);

      await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('show-audio-quality-toggle')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('show-audio-quality-switch')),
        findsOneWidget,
      );

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
        find.byKey(const ValueKey('settings-detail-header-surface-appearance')),
        findsOneWidget,
      );
      final detailHeader = find.byKey(
        const ValueKey('settings-detail-header-surface-appearance'),
      );
      expect(tester.getRect(detailHeader), rootHeaderRect);
      expect(
        tester.widget<Material>(detailHeader).color,
        AppColors.tabHeaderSurfaceFor(
          tester.element(detailHeader),
          scrolledUnder: false,
        ),
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

  for (final width in [360.0, 1600.0]) {
    testWidgets('audio quality appears below player style at width $width', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      _configureView(tester, Size(width, 1100));
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);
      await tester.pumpWidget(
        _settingsHarness(
          navigationController: navigationController,
          platform: width >= 1200 ? TargetPlatform.windows : null,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
      await tester.pumpAndSettle();

      final style = find.byKey(const ValueKey('player-style-selector'));
      final quality = find.byKey(const ValueKey('show-audio-quality-toggle'));
      final qualitySwitch = find.byKey(
        const ValueKey('show-audio-quality-switch'),
      );
      final artwork = find.byKey(const ValueKey('animated-artwork-toggle'));
      if (width >= 1200) {
        expect(tester.getSize(quality).width, greaterThan(1200));
      }
      expect(tester.widget<Switch>(qualitySwitch).value, isFalse);
      expect(
        tester.getTopLeft(quality).dy,
        greaterThan(tester.getBottomLeft(style).dy),
      );
      expect(
        tester.getBottomLeft(quality).dy,
        lessThan(tester.getTopLeft(artwork).dy),
      );

      await tester.ensureVisible(quality);
      await tester.tap(
        find.descendant(
          of: quality,
          matching: find.text('Mostrar códec y calidad'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(qualitySwitch).value, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('settings.showAudioQuality'), isTrue);
      await tester.tap(qualitySwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(qualitySwitch).value, isFalse);
      expect(prefs.getBool('settings.showAudioQuality'), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('appearance selects and applies a player font', (tester) async {
    _configureView(tester, const Size(430, 1000));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    final surfaceSelector = find.byKey(
      const ValueKey('surface-background-selector'),
    );
    final fontSelector = find.byKey(const ValueKey('player-font-selector'));
    final styleSelector = find.byKey(const ValueKey('player-style-selector'));
    expect(fontSelector, findsOneWidget);
    expect(
      find.descendant(
        of: fontSelector,
        matching: find.text('Fuente de la app'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: fontSelector,
        matching: find.text(
          const AppStrings(AppLanguage.spanish).playerFontCurrent,
        ),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(fontSelector).dy,
      greaterThan(tester.getTopLeft(surfaceSelector).dy),
    );
    expect(
      tester.getTopLeft(fontSelector).dy,
      lessThan(tester.getTopLeft(styleSelector).dy),
    );

    await tester.ensureVisible(fontSelector);
    await tester.tap(fontSelector);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-player-font-preview-title')),
      findsNothing,
    );
    for (final font in <PlayerFont>[
      PlayerFont.fredoka,
      PlayerFont.nunito,
      PlayerFont.spaceMono,
      PlayerFont.lora,
    ]) {
      final option = find.byKey(
        ValueKey('settings-player-font-option-${font.code}'),
      );
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      final label = find.descendant(
        of: option,
        matching: find.text(
          const AppStrings(AppLanguage.spanish).playerFontLabel(font),
        ),
      );
      expect(tester.widget<Text>(label).style?.fontFamily, font.fontFamily);
    }

    expect(
      find.descendant(
        of: fontSelector,
        matching: find.text(
          const AppStrings(AppLanguage.spanish).playerFontCurrent,
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Aplicar'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: fontSelector, matching: find.text('Lora')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('app background picker preserves the current photo on cancel', (
    tester,
  ) async {
    _configureView(tester, const Size(430, 1000));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);
    var pickCount = 0;

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        overrides: [
          appBackgroundPhotoPickerProvider.overrideWithValue(() async {
            pickCount += 1;
            return pickCount == 1 ? File('selected-photo.jpg') : null;
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    final selector = find.byKey(const ValueKey('app-background-selector'));
    expect(selector, findsOneWidget);
    expect(
      find.descendant(of: selector, matching: find.text('Sin Fondo')),
      findsOneWidget,
    );
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-app-background-option-custom')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-app-background-option-custom')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: selector, matching: find.text('Personalizado')),
      findsOneWidget,
    );

    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-app-background-option-custom')),
    );
    await tester.pumpAndSettle();
    expect(pickCount, 2);
    expect(
      find.descendant(of: selector, matching: find.text('Personalizado')),
      findsOneWidget,
    );

    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-app-background-option-none')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: selector, matching: find.text('Sin Fondo')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance selects player, surface, and mini player modes', (
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
    final playerStyleSelector = find.byKey(
      const ValueKey('player-style-selector'),
    );
    final animatedArtworkToggle = find.byKey(
      const ValueKey('animated-artwork-toggle'),
    );
    final animatedArtworkSwitch = find.byKey(
      const ValueKey('animated-artwork-switch'),
    );
    final playerArtworkStyleSelector = find.byKey(
      const ValueKey('player-artwork-style-selector'),
    );
    final spotifyCanvasToggle = find.byKey(
      const ValueKey('spotify-canvas-toggle'),
    );
    final appleAnimatedArtworkToggle = find.byKey(
      const ValueKey('apple-animated-artwork-toggle'),
    );
    final surfaceBackgroundSelector = find.byKey(
      const ValueKey('surface-background-selector'),
    );
    final backgroundSelector = find.byKey(
      const ValueKey('mini-player-background-selector'),
    );
    expect(selector, findsOneWidget);
    expect(playerStyleSelector, findsOneWidget);
    expect(animatedArtworkToggle, findsOneWidget);
    expect(animatedArtworkSwitch, findsOneWidget);
    expect(playerArtworkStyleSelector, findsOneWidget);
    expect(spotifyCanvasToggle, findsOneWidget);
    expect(appleAnimatedArtworkToggle, findsOneWidget);
    expect(
      tester
          .widget<Switch>(find.byKey(const ValueKey('spotify-canvas-switch')))
          .value,
      isFalse,
    );
    expect(surfaceBackgroundSelector, findsOneWidget);
    expect(backgroundSelector, findsOneWidget);
    expect(find.text('Efectos de superficie'), findsOneWidget);
    expect(find.text('Reproductor'), findsOneWidget);
    expect(find.text('Mini reproductor'), findsOneWidget);
    expect(
      find.descendant(
        of: playerStyleSelector,
        matching: find.text('BStream Music'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: animatedArtworkToggle,
        matching: find.text('Portadas en Movimiento'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<Switch>(animatedArtworkSwitch).value, isTrue);
    expect(
      find.descendant(
        of: playerArtworkStyleSelector,
        matching: find.text('Estilo de las portadas'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: playerArtworkStyleSelector,
        matching: find.text('Clásico'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: selector, matching: find.text('Estilo')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: selector, matching: find.text('Flotante')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: surfaceBackgroundSelector,
        matching: find.text('Estilo de las superficies'),
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
      tester.getTopLeft(playerStyleSelector).dy,
      greaterThan(tester.getTopLeft(surfaceBackgroundSelector).dy),
    );
    expect(
      tester.getTopLeft(selector).dy,
      greaterThan(tester.getTopLeft(playerArtworkStyleSelector).dy),
    );
    expect(
      tester.getTopLeft(spotifyCanvasToggle).dy,
      greaterThan(tester.getTopLeft(appleAnimatedArtworkToggle).dy),
    );
    expect(
      tester.getTopLeft(animatedArtworkToggle).dy,
      greaterThan(tester.getTopLeft(playerStyleSelector).dy),
    );
    expect(
      tester.getTopLeft(playerArtworkStyleSelector).dy,
      greaterThan(tester.getTopLeft(animatedArtworkToggle).dy),
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
    expect(find.text('Estilo de las superficies'), findsWidgets);
    expect(
      find.byKey(const ValueKey('settings-surface-background-option-accent')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('settings-surface-background-option-transparent'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('settings-surface-background-option-liquid-glass'),
      ),
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

    await tester.tap(surfaceBackgroundSelector);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('settings-surface-background-option-liquid-glass'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: surfaceBackgroundSelector,
        matching: find.text('Liquid Glass Style'),
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(playerStyleSelector);
    await tester.tap(playerStyleSelector);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-player-style-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-player-style-option-bstream-music')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-player-style-option-apple-music')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('settings-player-style-option-classic-vinyl')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-player-style-option-apple-music')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: playerStyleSelector,
        matching: find.text('Apple Music Style'),
      ),
      findsOneWidget,
    );

    await tester.tap(playerStyleSelector);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-player-style-option-classic-vinyl')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: playerStyleSelector,
        matching: find.text('Vinilo Clásico'),
      ),
      findsOneWidget,
    );

    await tester.ensureVisible(animatedArtworkToggle);
    await tester.tap(animatedArtworkToggle);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(animatedArtworkSwitch).value, isFalse);

    await tester.ensureVisible(playerArtworkStyleSelector);
    await tester.tap(playerArtworkStyleSelector);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-player-artwork-style-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('settings-player-artwork-style-option-classic'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('settings-player-artwork-style-option-expanded'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        const ValueKey('settings-player-artwork-style-option-expanded'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-player-artwork-style-dialog')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: playerArtworkStyleSelector,
        matching: find.text('Expandido'),
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
      find.descendant(of: selector, matching: find.text('Flotante')),
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
    expect(
      find.byKey(
        const ValueKey('settings-mini-player-background-option-transparent'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('settings-mini-player-background-option-liquid-glass'),
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

    await tester.tap(backgroundSelector);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('settings-mini-player-background-option-liquid-glass'),
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
        matching: find.text('Liquid Glass Style'),
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

      final languageCard = find.byKey(const ValueKey('settings-card-language'));
      await _ensureSettingsVisible(tester, languageCard);
      await tester.tap(languageCard);
      await tester.pumpAndSettle();

      final dialog = find.byKey(const ValueKey('settings-language-dialog'));
      final spanish = find.byKey(
        const ValueKey('settings-language-option-spanish'),
      );
      final english = find.byKey(
        const ValueKey('settings-language-option-english'),
      );
      for (final language in AppLanguage.values) {
        expect(
          find.byKey(ValueKey('settings-language-option-${language.name}')),
          findsOneWidget,
        );
      }
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
      await tester.ensureVisible(languageCard);
      await tester.tap(languageCard);
      await tester.pumpAndSettle();
      final portuguese = find.byKey(
        const ValueKey('settings-language-option-portuguese'),
      );
      await tester.ensureVisible(portuguese);
      await tester.tap(portuguese);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-card-language')),
          matching: find.text('Português'),
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
    expect(
      find.descendant(
        of: appearanceCard,
        matching: find.byType(AppCardGradientBorder),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: timerCard,
        matching: find.byType(AppCardGradientBorder),
      ),
      findsOneWidget,
    );
    final gradient = AppColors.cardBorderGradientFor(
      tester.element(appearanceCard),
      solidInLiquidGlass: true,
    );
    expect(gradient.colors.first, isNot(gradient.colors[1]));
    expect(gradient.colors.last, isNot(gradient.colors[1]));

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

  testWidgets(
    'desktop settings cards fill content width except the sleep timer',
    (tester) async {
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
      final languageRect = tester.getRect(
        find.byKey(const ValueKey('settings-card-language')),
      );
      final timerRect = tester.getRect(
        find.byKey(const ValueKey('settings-inline-timer')),
      );

      expect(languageRect.width, greaterThan(760));
      expect(crossfadeRect.width, greaterThan(760));
      expect(crossfadeRect.width, closeTo(languageRect.width, 0.1));
      expect(crossfadeRect.width, closeTo(liveStorageRect.width, 0.1));
      expect(crossfadeRect.left, closeTo(liveStorageRect.left, 0.1));
      expect(crossfadeRect.right, closeTo(liveStorageRect.right, 0.1));
      expect(timerRect.width, closeTo(520, 0.1));
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

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

  testWidgets('Android shows skip silence directly below crossfade', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _configureView(tester, const Size(760, 1400));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        overrides: [skipSilenceSupportedProvider.overrideWithValue(true)],
      ),
    );
    await tester.pumpAndSettle();

    final crossfadeCard = find.byKey(
      const ValueKey('settings-inline-crossfade'),
    );
    final skipSilenceCard = find.byKey(
      const ValueKey('settings-inline-skip-silence'),
    );
    final skipSilenceSwitch = find.byKey(
      const ValueKey('settings-skip-silence-switch'),
    );
    expect(skipSilenceCard, findsOneWidget);
    expect(skipSilenceSwitch, findsOneWidget);
    expect(
      tester.getTopLeft(skipSilenceCard).dy -
          tester.getBottomLeft(crossfadeCard).dy,
      closeTo(6, 0.1),
    );
    expect(tester.getSize(skipSilenceCard).width, closeTo(520, 0.1));

    await tester.tap(skipSilenceSwitch);
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(skipSilenceCard),
    );
    expect(
      container
          .read(settingsControllerProvider)
          .requireValue
          .skipSilenceEnabled,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('skip silence is not presented as supported on iOS', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _configureView(tester, const Size(760, 1400));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        overrides: [skipSilenceSupportedProvider.overrideWithValue(false)],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-inline-skip-silence')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('skip silence fits a compact Android view at large text', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    _configureView(tester, const Size(320, 568));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        overrides: [skipSilenceSupportedProvider.overrideWithValue(true)],
      ),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('settings-inline-skip-silence'));
    await tester.scrollUntilVisible(
      card,
      180,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('settings-root')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();

    final rect = tester.getRect(card);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(320));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });

  test('lyrics provider settings have translations in every app language', () {
    const english = AppStrings(AppLanguage.english);
    for (final language in AppLanguage.values) {
      final strings = AppStrings(language);
      final values = [
        strings.lyricsProviders,
        strings.lyricsProvidersHint,
        strings.lyricsProvidersFallbackHint,
        strings.noLyricsProvidersEnabled,
        strings.lyricsProvidersDisabledHint,
        strings.betterLyricsAvailabilityHint,
      ];
      expect(values.every((value) => value.trim().isNotEmpty), isTrue);
      expect(
        strings.lyricsProvidersHint,
        contains('Better Lyrics → LyricsPlus → LRCLIB'),
      );
      for (final provider in LyricsProvider.values) {
        final attribution = strings.lyricsSourceForProvider(provider.label);
        expect(attribution, contains(provider.label));
        expect(
          attribution,
          strings.lyricsSource.replaceAll('LRCLIB', provider.label),
        );
      }
      if (language != AppLanguage.english) {
        expect(strings.lyricsProviders, isNot(english.lyricsProviders));
        expect(strings.lyricsProvidersHint, isNot(english.lyricsProvidersHint));
        expect(
          strings.lyricsProvidersFallbackHint,
          isNot(english.lyricsProvidersFallbackHint),
        );
        expect(
          strings.noLyricsProvidersEnabled,
          isNot(english.noLyricsProvidersEnabled),
        );
        expect(
          strings.lyricsProvidersDisabledHint,
          isNot(english.lyricsProvidersDisabledHint),
        );
        expect(
          strings.betterLyricsAvailabilityHint,
          isNot(english.betterLyricsAvailabilityHint),
        );
      }
    }
  });

  testWidgets(
    'lyrics providers are first, persist independent toggles, and return to lyrics',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      _configureView(tester, const Size(430, 900));
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);
      await tester.pumpWidget(
        _settingsHarness(
          navigationController: navigationController,
          settingsControllerBuilder: _PersistingCrossfadeSettingsController.new,
        ),
      );
      await tester.pumpAndSettle();

      final lyricsCard = find.byKey(
        const ValueKey('settings-card-lyrics-appearance'),
      );
      await _ensureSettingsVisible(tester, lyricsCard);
      await tester.tap(lyricsCard);
      await tester.pumpAndSettle();

      final providersCard = find.byKey(
        const ValueKey('settings-card-lyrics-providers'),
      );
      final animation = find.byKey(const ValueKey('lyrics-animation-options'));
      expect(providersCard, findsOneWidget);
      expect(
        tester.getBottomLeft(providersCard).dy,
        lessThan(tester.getTopLeft(animation).dy),
      );
      expect(find.text('Better Lyrics · LyricsPlus · LRCLIB'), findsOneWidget);

      await tester.tap(providersCard);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-detail-lyricsProviders')),
        findsOneWidget,
      );
      expect(find.text('Proveedores de letras'), findsOneWidget);
      final providerToggles = find.byType(SwitchListTile);
      expect(
        tester
            .widgetList<SwitchListTile>(providerToggles)
            .map((toggle) => (toggle.title! as Text).data),
        ['Better Lyrics', 'LyricsPlus', 'LRCLIB'],
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('lyrics-provider-toggle-betterLyrics')),
          matching: find.text(
            const AppStrings(AppLanguage.spanish).betterLyricsAvailabilityHint,
          ),
        ),
        findsOneWidget,
      );
      for (final provider in LyricsProvider.values) {
        final toggle = find.byKey(
          ValueKey('lyrics-provider-toggle-${provider.name}'),
        );
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      }

      const strings = AppStrings(AppLanguage.spanish);
      expect(find.text(strings.lyricsProvidersDisabledHint), findsOneWidget);
      expect(find.text(strings.lyricsProvidersFallbackHint), findsNothing);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getStringList('settings.enabledLyricsProviders'), []);

      final youLyPlus = find.byKey(
        const ValueKey('lyrics-provider-toggle-youLyPlus'),
      );
      await tester.tap(youLyPlus);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(youLyPlus).value, isTrue);
      expect(preferences.getStringList('settings.enabledLyricsProviders'), [
        'youLyPlus',
      ]);
      expect(find.text(strings.lyricsProvidersFallbackHint), findsOneWidget);

      expect(navigationController.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-detail-lyrics')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: providersCard, matching: find.text('LyricsPlus')),
        findsOneWidget,
      );
      await tester.tap(providersCard);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(youLyPlus).value, isTrue);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('lyrics-provider-toggle-lrclib')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-detail-lyrics')),
        findsOneWidget,
      );
      expect(navigationController.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'lyrics providers fit compact text scaling and full desktop width',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        debugDefaultTargetPlatformOverride = null;
      });

      for (final layout in const [
        (
          size: Size(320, 720),
          platform: TargetPlatform.android,
          textScale: 2.0,
        ),
        (
          size: Size(1400, 900),
          platform: TargetPlatform.windows,
          textScale: 1.0,
        ),
      ]) {
        tester.view.physicalSize = layout.size;
        tester.platformDispatcher.textScaleFactorTestValue = layout.textScale;
        debugDefaultTargetPlatformOverride = layout.platform;
        final navigationController = SettingsNavigationController();
        addTearDown(navigationController.dispose);
        await tester.pumpWidget(
          _settingsHarness(
            navigationController: navigationController,
            platform: layout.platform,
            language: AppLanguage.french,
          ),
        );
        await tester.pumpAndSettle();
        final lyricsCard = find.byKey(
          const ValueKey('settings-card-lyrics-appearance'),
        );
        await _ensureSettingsVisible(tester, lyricsCard);
        await tester.tap(lyricsCard);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('settings-card-lyrics-providers')),
        );
        await tester.pumpAndSettle();

        final providersCard = find.byKey(
          const ValueKey('lyrics-providers-card'),
        );
        await tester.ensureVisible(providersCard);
        await tester.pumpAndSettle();
        final cardRect = tester.getRect(providersCard);
        expect(cardRect.left, closeTo(12, 0.1));
        expect(cardRect.width, closeTo(layout.size.width - 24, 0.1));
        for (final provider in LyricsProvider.values) {
          expect(
            find.byKey(ValueKey('lyrics-provider-toggle-${provider.name}')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
      debugDefaultTargetPlatformOverride = null;
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    },
  );

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
        final expectedWidth = layout.size.width - 24;
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

  testWidgets('sleep timer updates stay scoped to the inline timer card', (
    tester,
  ) async {
    _configureView(tester, const Size(760, 1600));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();

    final languageCard = find.byKey(const ValueKey('settings-card-language'));
    final crossfadeCard = find.byKey(
      const ValueKey('settings-inline-crossfade'),
    );
    final timerCard = find.byKey(const ValueKey('settings-inline-timer'));
    final languageBefore = tester.widget<Widget>(languageCard);
    final crossfadeBefore = tester.widget<Widget>(crossfadeCard);
    final container = ProviderScope.containerOf(tester.element(timerCard));

    container
        .read(sleepTimerControllerProvider.notifier)
        .start(const Duration(minutes: 3));
    await tester.pump();

    expect(
      identical(tester.widget<Widget>(languageCard), languageBefore),
      isTrue,
    );
    expect(
      identical(tester.widget<Widget>(crossfadeCard), crossfadeBefore),
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.descendant(
              of: timerCard,
              matching: find.byType(SwitchListTile),
            ),
          )
          .value,
      isTrue,
    );

    final languageAfterStart = tester.widget<Widget>(languageCard);
    final crossfadeAfterStart = tester.widget<Widget>(crossfadeCard);
    await tester.pump(const Duration(seconds: 1));

    expect(
      identical(tester.widget<Widget>(languageCard), languageAfterStart),
      isTrue,
      reason: 'the one-second timer tick must not rebuild Settings root',
    );
    expect(
      identical(tester.widget<Widget>(crossfadeCard), crossfadeAfterStart),
      isTrue,
    );
    expect(
      container.read(sleepTimerControllerProvider).remaining,
      lessThan(const Duration(minutes: 3)),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('CSV progress does not rebuild the Settings root', (
    tester,
  ) async {
    _configureView(tester, const Size(760, 1600));
    final navigationController = SettingsNavigationController();
    final transferController = _PublishingCsvTransferController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        overrides: [
          libraryCsvTransferControllerProvider.overrideWith(
            () => transferController,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final languageCard = find.byKey(const ValueKey('settings-card-language'));
    final languageBefore = tester.widget<Widget>(languageCard);
    final container = ProviderScope.containerOf(tester.element(languageCard));
    container.read(libraryCsvTransferControllerProvider);

    transferController.publishImportProgress(1);
    await tester.pump();
    transferController.publishImportProgress(2);
    await tester.pump();

    expect(
      identical(tester.widget<Widget>(languageCard), languageBefore),
      isTrue,
      reason: 'detailed CSV progress belongs to its dialog, not Settings root',
    );
    expect(tester.takeException(), isNull);
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
      await _ensureSettingsVisible(tester, storageSettings);
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

    await _ensureSettingsVisible(
      tester,
      find.byKey(const ValueKey('settings-inline-timer')),
    );
    await _ensureSettingsVisible(
      tester,
      find.byKey(const ValueKey('settings-inline-crossfade')),
    );
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
    await _ensureSettingsVisible(tester, crossfadeSwitch);
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
      await _ensureSettingsVisible(
        tester,
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
          AppColors.cardSurfaceFor(tester.element(tileFinder)),
        );
      }
      await tester.tap(find.byKey(const ValueKey('csv-export-profile-cancel')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('CSV import previews metadata merge and reports completion', (
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
                'x.csv',
          ),
          libraryCsvTransferControllerProvider.overrideWith(
            () => transferController,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await _ensureSettingsVisible(
      tester,
      find.byKey(const ValueKey('settings-card-storage')),
    );
    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    final importCsv = find.byKey(const ValueKey('storage-import-csv'));
    await tester.ensureVisible(importCsv);
    await tester.tap(importCsv);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('csv-import-preview')), findsOneWidget);
    expect(find.text('Importar canciones'), findsOneWidget);
    expect(find.textContaining('1 canciones'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('csv-import-preview')),
        matching: find.textContaining('sin descargar audio'),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('descargar las canciones más adelante'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('csv-import-preview-confirm')));
    await tester.pumpAndSettle();
    expect(transferController.importCalls, 1);
    expect(
      find.byKey(const ValueKey('csv-import-progress-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('1 importadas'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('csv-import-close')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'cold-start CSV open asks permission and cancellation imports nothing',
    (tester) async {
      _configureView(tester, const Size(430, 900));
      final incoming = _FakeIncomingCsvFileService();
      addTearDown(incoming.close);
      final transfer = _ImmediateCsvTransferController();
      const file = IncomingCsvFile(
        path: '/cache/import/Mi playlist.csv',
        name: 'Mi playlist.csv',
        source: 'content://files/first',
        temporary: true,
      );
      incoming.controller.add(file);
      await tester.pumpWidget(
        _homeHarness(
          overrides: [
            incomingCsvFileServiceProvider.overrideWithValue(incoming),
            libraryCsvTransferControllerProvider.overrideWith(() => transfer),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('csv-import-preview')), findsOneWidget);
      expect(find.text('Mi playlist.csv'), findsOneWidget);
      expect(transfer.previewPaths, [file.path]);
      expect(transfer.importCalls, 0);
      expect(incoming.released, isEmpty);

      await tester.tap(find.byKey(const ValueKey('csv-import-preview-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('csv-import-preview')), findsNothing);
      expect(transfer.importCalls, 0);
      expect(incoming.released, [file]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'warm CSV open imports only after confirmation and ignores duplicate opens',
    (tester) async {
      _configureView(tester, const Size(430, 900));
      final incoming = _FakeIncomingCsvFileService();
      addTearDown(incoming.close);
      final transfer = _ImmediateCsvTransferController();
      await tester.pumpWidget(
        _homeHarness(
          overrides: [
            incomingCsvFileServiceProvider.overrideWithValue(incoming),
            libraryCsvTransferControllerProvider.overrideWith(() => transfer),
          ],
        ),
      );
      await tester.pumpAndSettle();
      const file = IncomingCsvFile(
        path: '/cache/import/Favoritas.csv',
        name: 'Favoritas.csv',
        source: 'content://files/favorites',
        temporary: true,
      );
      incoming.controller.add(file);
      incoming.controller.add(
        IncomingCsvFile(
          path: file.path,
          name: file.name,
          source: file.source,
          temporary: true,
          id: 'same-path-duplicate',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('csv-import-preview')), findsOneWidget);
      expect(transfer.previewPaths, [file.path]);
      expect(transfer.importCalls, 0);
      expect(incoming.released, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('csv-import-preview-confirm')),
      );
      await tester.pumpAndSettle();
      expect(transfer.importCalls, 1);
      expect(
        find.byKey(const ValueKey('csv-import-progress-dialog')),
        findsOneWidget,
      );
      expect(incoming.released, isEmpty);
      await tester.tap(find.byKey(const ValueKey('csv-import-close')));
      await tester.pumpAndSettle();
      expect(incoming.released, [file]);
      expect(find.byKey(const ValueKey('csv-import-preview')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets('IME frames resize the viewport without rebuilding the shell', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _configureView(tester, const Size(400, 900));
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(_homeHarness());
    await tester.pumpAndSettle();
    final content = find.byKey(const ValueKey('shell-content-stack'));
    final fullHeight = tester.getSize(content).height;
    var shellBuilds = 0;
    final previousObserver = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previousObserver?.call(element, builtOnce);
      if (element.widget is HomePage) shellBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previousObserver);

    tester.view.viewInsets = const FakeViewPadding(bottom: 30);
    await tester.pump();
    final openingBuilds = shellBuilds;
    expect(openingBuilds, greaterThan(0));
    for (final bottom in [100.0, 200.0, 300.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: bottom);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(shellBuilds, openingBuilds);
    expect(tester.getSize(content).height, fullHeight - 300);

    for (final bottom in [200.0, 100.0, 30.0]) {
      tester.view.viewInsets = FakeViewPadding(bottom: bottom);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(shellBuilds, openingBuilds);
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(shellBuilds, openingBuilds + 1);
    expect(tester.getSize(content).height, fullHeight);
    expect(tester.takeException(), isNull);
    debugOnRebuildDirtyWidget = previousObserver;
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

  testWidgets('Liquid Glass stays off every Settings card surface', (
    tester,
  ) async {
    _configureView(tester, const Size(430, 1600));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const ValueKey('settings-card-language'));
    final timer = find.byKey(const ValueKey('settings-inline-timer'));
    final crossfade = find.byKey(const ValueKey('settings-inline-crossfade'));
    for (final card in <Finder>[entry, timer, crossfade]) {
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.byType(LiquidGlassSurface)),
        findsNothing,
      );
      expect(_outerMaterial(tester, card).color?.a, 0.68);
    }
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

Future<void> _ensureSettingsVisible(WidgetTester tester, Finder target) async {
  final scrollable = find
      .descendant(
        of: find.byKey(const ValueKey('settings-root')),
        matching: find.byType(Scrollable),
      )
      .first;
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(target, 220, scrollable: scrollable);
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Widget _settingsHarness({
  required SettingsNavigationController navigationController,
  List<Override> overrides = const [],
  bool disableAnimations = false,
  bool active = true,
  SurfaceBackgroundMode surfaceBackgroundMode = SurfaceBackgroundMode.accent,
  SettingsController Function()? settingsControllerBuilder,
  TargetPlatform? platform,
  AppLanguage language = AppLanguage.spanish,
}) {
  return ProviderScope(
    overrides: [
      ..._providerOverrides(
        settingsControllerBuilder: settingsControllerBuilder,
        language: language,
      ),
      ...overrides,
    ],
    child: MaterialApp(
      theme: ThemeData(
        platform: platform,
        extensions: [AppSurfaceTheme(backgroundMode: surfaceBackgroundMode)],
      ),
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

Widget _homeHarness({
  bool disableAnimations = false,
  List<Override> overrides = const [],
}) {
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
      ...overrides,
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
  AppLanguage language = AppLanguage.spanish,
}) {
  return [
    settingsControllerProvider.overrideWith(
      settingsControllerBuilder ?? _FixedSettingsController.new,
    ),
    appStringsProvider.overrideWithValue(AppStrings(language)),
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
  Future<void> setAppBackgroundPhoto(File file) async {
    final current = await future;
    state = AsyncData(
      current.copyWith(
        appBackgroundFileName: 'background_1_1.jpg',
        appBackgroundPath: file.path,
      ),
    );
  }

  @override
  Future<void> clearAppBackgroundPhoto() async {
    final current = await future;
    state = AsyncData(
      current.copyWith(appBackgroundFileName: null, appBackgroundPath: null),
    );
  }

  @override
  Future<void> setPlayerStyle(PlayerStyle style) async {
    final current = await future;
    state = AsyncData(current.copyWith(playerStyle: style));
  }

  @override
  Future<void> setPlayerFont(PlayerFont font) async {
    final current = await future;
    state = AsyncData(current.copyWith(playerFont: font));
  }

  @override
  Future<void> setAnimatedArtworkEnabled(bool enabled) async {
    final current = await future;
    state = AsyncData(current.copyWith(animatedArtworkEnabled: enabled));
  }

  @override
  Future<void> setPlayerArtworkStyle(PlayerArtworkStyle style) async {
    final current = await future;
    state = AsyncData(current.copyWith(playerArtworkStyle: style));
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

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {
    final current = await future;
    state = AsyncData(current.copyWith(skipSilenceEnabled: enabled));
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
  final List<String> previewPaths = [];

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
    previewPaths.add(path);
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
      imported: 1,
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

class _FakeIncomingCsvFileService implements IncomingCsvFileService {
  final controller = StreamController<IncomingCsvFile>();
  final List<IncomingCsvFile> released = [];

  @override
  Stream<IncomingCsvFile> get files => controller.stream;

  @override
  Future<void> release(IncomingCsvFile file) async => released.add(file);

  @override
  void dispose() {}

  Future<void> close() => controller.close();
}

class _PublishingCsvTransferController extends LibraryCsvTransferController {
  void publishImportProgress(int marker) {
    state = LibraryCsvTransferState(
      phase: LibraryCsvTransferPhase.importing,
      // A distinct object guarantees a provider notification while isBusy
      // remains true across progress frames.
      error: marker,
    );
  }
}
