import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/theme/app_ui.dart';
import 'package:bstream_music/core/widgets/marquee_text.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/domain/entities/search_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/artwork_progress_color_provider.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/pages/artist_profile_page.dart';
import 'package:bstream_music/features/music/presentation/pages/home_page.dart';
import 'package:bstream_music/features/music/presentation/pages/search_view.dart';
import 'package:bstream_music/features/music/presentation/widgets/library_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/download_progress_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/gradient_progress_bar.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/features/music/presentation/widgets/track_result_tile.dart';
import 'package:bstream_music/main.dart';
import 'package:bstream_music/platform_channels/android_app_activation_channel.dart';
import 'package:bstream_music/platform_channels/android_external_audio_channel.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/lyrics/lyrics_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/recommendations/recommendations.dart';
import 'package:bstream_music/services/sharing/incoming_track_link_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final keyboardNavigationInsets = ValueVariant<double>(<double>{0, 24});

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return switch (call.method) {
            'getApplicationDocumentsDirectory' => 'C:\\bstream_music_test',
            'getTemporaryDirectory' => 'C:\\bstream_music_test\\temp',
            'getApplicationSupportDirectory' =>
              'C:\\bstream_music_test\\support',
            'getApplicationCacheDirectory' => 'C:\\bstream_music_test\\cache',
            _ => null,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
    });
  });

  testWidgets('renders BStream Music shell', (tester) async {
    await tester.pumpWidget(_testApp());

    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Inicio'), findsWidgets);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('home-tab-title'))).data,
      'Buenos días',
    );
    expect(find.byIcon(Icons.search_rounded), findsWidgets);
    expect(find.text('Reproductor'), findsNothing);
  });

  testWidgets('home greeting does not include the authenticated account name', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        homeGreetingTime: DateTime(2026, 8, 24, 15),
        youtubeMusicAuthState: const YouTubeMusicAuthState(
          phase: YouTubeMusicAuthPhase.authenticated,
          generation: 1,
          profile: YouTubeMusicAccountProfile(
            channelId: 'UC-greeting-test',
            displayName: '  Ana   Maria Lopez  ',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('home-tab-title'))).data,
      'Buenas tardes',
    );
    expect(find.text('Inicio'), findsWidgets);
  });

  testWidgets('browsing tabs keep playback artwork out of their background', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..physicalSize = const Size(360, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _testApp(
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Portada activa',
            artist: 'BStream Music',
            trackId: 'browsing-background-track',
            thumbnailUrl: 'https://example.com/cover.jpg',
            duration: Duration(minutes: 3),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final background = find.byKey(
      const ValueKey('browsing-tab-background-surface'),
    );
    expect(background, findsOneWidget);
    expect(
      find.descendant(of: background, matching: find.byType(ImageFiltered)),
      findsNothing,
    );
    expect(
      find.descendant(of: background, matching: find.byType(SourceImage)),
      findsNothing,
    );
    expect(
      (tester.widget<DecoratedBox>(background).decoration as BoxDecoration)
          .gradient,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'windows mini player fills content and centers transport controls',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpWidget(
        _testApp(
          settingsController: _FakeSettingsController(
            const SettingsState(
              downloadDirectory: '/tmp/BStream-Music',
              language: AppLanguage.spanish,
              miniPlayerMode: MiniPlayerMode.standard,
              miniPlayerBackgroundMode: MiniPlayerBackgroundMode.accent,
            ),
          ),
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: 'Cancion de escritorio',
              artist: 'BStream Music',
              trackId: 'desktop-mini-player-track',
              duration: Duration(minutes: 3),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      for (final viewport in const [Size(1280, 720), Size(960, 600)]) {
        tester.view.physicalSize = viewport;
        await tester.pump();

        final surface = find.byKey(const ValueKey('mini-player-surface'));
        final previous = find.byKey(
          const ValueKey('mini-player-previous-control'),
        );
        final play = find.byKey(const ValueKey('mini-player-primary-control'));
        final next = find.byKey(const ValueKey('mini-player-next-control'));
        final shuffle = find.byKey(
          const ValueKey('mini-player-shuffle-control'),
        );
        final repeat = find.byKey(const ValueKey('mini-player-repeat-control'));
        final lyrics = find.byKey(const ValueKey('mini-player-lyrics-control'));
        final volume = find.byKey(const ValueKey('mini-player-volume-control'));
        final progress = find.byKey(const ValueKey('mini-player-progress'));
        final surfaceRect = tester.getRect(surface);
        final previousRect = tester.getRect(previous);
        final progressRect = tester.getRect(progress);
        final shuffleCenter = tester.getCenter(shuffle);
        final previousCenter = tester.getCenter(previous);
        final playCenter = tester.getCenter(play);
        final nextCenter = tester.getCenter(next);
        final repeatCenter = tester.getCenter(repeat);

        expect(surfaceRect.left, closeTo(0, 0.1));
        expect(surfaceRect.width, closeTo(viewport.width, 0.1));
        expect(surfaceRect.height, 98);
        expect(playCenter.dx, closeTo(surfaceRect.center.dx, 0.1));
        expect(tester.getSize(play), const Size.square(54));
        expect(
          find.byKey(const ValueKey('mini-player-primary-gradient')),
          findsNothing,
        );
        final playButton = tester.widget<IconButton>(play);
        final previousButton = tester.widget<IconButton>(
          find.descendant(of: previous, matching: find.byType(IconButton)),
        );
        expect(playButton.iconSize, 41);
        expect(
          playButton.style?.foregroundColor?.resolve(<WidgetState>{}),
          previousButton.color,
        );
        expect(tester.getSize(shuffle), const Size.square(48));
        expect(tester.getSize(previous), const Size.square(48));
        expect(tester.getSize(next), const Size.square(48));
        expect(
          tester
              .widget<IconButton>(
                find.descendant(
                  of: previous,
                  matching: find.byType(IconButton),
                ),
              )
              .iconSize,
          30,
        );
        expect(
          tester
              .widget<IconButton>(
                find.descendant(of: next, matching: find.byType(IconButton)),
              )
              .iconSize,
          30,
        );
        expect(
          tester
              .widget<IconButton>(
                find.descendant(of: shuffle, matching: find.byType(IconButton)),
              )
              .iconSize,
          26,
        );
        expect(
          tester
              .widget<IconButton>(
                find.descendant(of: repeat, matching: find.byType(IconButton)),
              )
              .iconSize,
          26,
        );
        expect(tester.getSize(repeat), const Size.square(48));
        expect(tester.getSize(lyrics), const Size.square(48));
        expect(tester.getSize(volume), const Size(152, 44));
        expect(previousCenter.dx - shuffleCenter.dx, closeTo(48, 0.1));
        expect(playCenter.dx - previousCenter.dx, closeTo(51, 0.1));
        expect(nextCenter.dx - playCenter.dx, closeTo(51, 0.1));
        expect(repeatCenter.dx - nextCenter.dx, closeTo(48, 0.1));
        expect(previousCenter.dy, closeTo(playCenter.dy, 0.1));
        expect(nextCenter.dy, closeTo(playCenter.dy, 0.1));
        expect(progressRect.top - previousRect.bottom, closeTo(3, 0.1));
        expect(
          (previousRect.top + progressRect.bottom) / 2,
          closeTo(surfaceRect.center.dy + 4.5, 0.1),
        );
        expect(
          find.byKey(const ValueKey('mini-player-current-time')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('mini-player-total-time')),
          findsOneWidget,
        );
        expect(find.text('0:00'), findsOneWidget);
        expect(find.text('3:00'), findsOneWidget);
        expect(tester.getRect(shuffle).right, lessThan(previousCenter.dx));
        expect(tester.getRect(repeat).left, greaterThan(nextCenter.dx));
        expect(
          tester.getRect(volume).right,
          closeTo(surfaceRect.right - 20, 0.1),
        );
        expect(
          find.descendant(
            of: volume,
            matching: find.byKey(const ValueKey('mini-player-volume-slider')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: volume, matching: find.byType(Slider)),
          findsNothing,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(previous);
        await tester.pump();
        expect(find.byKey(const ValueKey('player-tab-title')), findsNothing);
        await tester.tap(next);
        await tester.pump();
        expect(find.byKey(const ValueKey('player-tab-title')), findsNothing);
        expect(tester.takeException(), isNull);
      }
      debugDefaultTargetPlatformOverride = null;
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'desktop player survives navigation layout resize without rebuilding playback',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view
        ..physicalSize = const Size(900, 720)
        ..devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });

      final playerService = _FakePlayerService(
        snapshot: const PlayerSnapshot(
          status: PlayerStatus.playing,
          title: 'Pista persistente',
          artist: 'Artista persistente',
          trackId: 'responsive-player-track',
          thumbnailUrl: 'https://example.com/responsive-artwork.jpg',
          position: Duration(seconds: 37),
          duration: Duration(minutes: 3, seconds: 47),
        ),
      );
      await tester.pumpWidget(_testApp(playerService: playerService));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(const ValueKey('side-navigation-surface')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('bottom-navigation-shell-transition')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bottom-navigation-item-3')),
        findsOneWidget,
      );
      expect(find.byType(MiniPlayer), findsOneWidget);
      final miniPlayerClip = find.byKey(
        const ValueKey('mini-player-shell-clip'),
      );
      final bottomNavigationClip = find.byKey(
        const ValueKey('bottom-navigation-shell-clip'),
      );
      expect(
        tester.getBottomLeft(miniPlayerClip).dy,
        closeTo(tester.getTopLeft(bottomNavigationClip).dy, 0.1),
      );
      final retainedMiniPlayer = tester.element(find.byType(MiniPlayer));

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final playerView = find.byKey(const ValueKey('player-view'));
      final playerPanel = find.byType(PlayerPanel);
      final playerTitle = find.descendant(
        of: playerView,
        matching: find.byKey(const ValueKey('player-track-title')),
      );
      final playerArtist = find.descendant(
        of: playerView,
        matching: find.byKey(const ValueKey('player-track-artist')),
      );
      final playerTrack = find.descendant(
        of: playerView,
        matching: find.byKey(const ValueKey('player-progress-color-animation')),
      );
      final playerArtwork = find.descendant(
        of: playerView,
        matching: find.byType(ProportionalArtwork),
      );
      expect(playerView, findsOneWidget);
      expect(playerPanel, findsOneWidget);
      expect(playerTitle, findsOneWidget);
      expect(playerArtist, findsOneWidget);
      expect(playerTrack, findsOneWidget);
      expect(playerArtwork, findsOneWidget);
      expect(tester.widget<MarqueeText>(playerTitle).text, 'Pista persistente');
      expect(tester.widget<Text>(playerArtist).data, 'Artista persistente');
      expect(
        tester.widget<ProportionalArtwork>(playerArtwork).source,
        'https://example.com/responsive-artwork.jpg',
      );
      final retainedPlayerPanel = tester.element(playerPanel);
      final retainedPlayerTitle = tester.element(playerTitle);
      final retainedPlayerTrack = tester.element(playerTrack);
      final retainedPlayerArtwork = tester.element(playerArtwork);
      final playerMiniOpacity = tester.widget<Opacity>(
        find.byKey(const ValueKey('mini-player-shell-opacity')),
      );
      final bottomNavigationOpacity = tester.widget<Opacity>(
        find.byKey(const ValueKey('bottom-navigation-shell-opacity')),
      );
      expect(playerMiniOpacity.opacity, 0);
      expect(bottomNavigationOpacity.opacity, 0);

      expect(playerService.stopCalls, 0);
      expect(playerService.disposeCalls, 0);
      tester.view.physicalSize = const Size(1280, 720);
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.byKey(const ValueKey('side-navigation-surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bottom-navigation-shell-transition')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('side-navigation-item-3')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bottom-navigation-item-3')),
        findsNothing,
      );
      expect(tester.getBottomLeft(miniPlayerClip).dy, closeTo(720, 0.1));
      expect(playerView, findsOneWidget);
      expect(
        identical(
          retainedPlayerPanel,
          tester.element(find.byType(PlayerPanel)),
        ),
        isTrue,
      );
      expect(
        identical(retainedMiniPlayer, tester.element(find.byType(MiniPlayer))),
        isTrue,
      );
      expect(
        identical(retainedPlayerTitle, tester.element(playerTitle)),
        isTrue,
      );
      expect(
        identical(retainedPlayerTrack, tester.element(playerTrack)),
        isTrue,
      );
      expect(
        identical(retainedPlayerArtwork, tester.element(playerArtwork)),
        isTrue,
      );
      expect(tester.widget<MarqueeText>(playerTitle).text, 'Pista persistente');
      expect(tester.widget<Text>(playerArtist).data, 'Artista persistente');
      expect(
        tester.widget<ProportionalArtwork>(playerArtwork).source,
        'https://example.com/responsive-artwork.jpg',
      );
      expect(playerTrack, findsOneWidget);
      expect(playerService.stopCalls, 0);
      expect(playerService.disposeCalls, 0);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets('android mini player is shorter without shrinking play target', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _testApp(
        settingsController: _FakeSettingsController(
          const SettingsState(
            downloadDirectory: '/tmp/BStream-Music',
            language: AppLanguage.spanish,
            miniPlayerMode: MiniPlayerMode.standard,
            miniPlayerBackgroundMode: MiniPlayerBackgroundMode.artwork,
          ),
        ),
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion movil',
            artist: 'BStream Music',
            trackId: 'android-mini-player-track',
            duration: Duration(minutes: 3),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-surface'))).height,
      65,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-primary-control'))),
      const Size.square(50),
    );
    expect(
      find.byKey(const ValueKey('mini-player-primary-gradient')),
      findsNothing,
    );
    final playButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('mini-player-primary-control')),
    );
    expect(playButton.iconSize, 37);
    expect(
      playButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      AppColors.playbackControlForegroundFor(
        tester.element(
          find.byKey(const ValueKey('mini-player-primary-control')),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android bottom navigation is glassy and meets mini player', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
    });

    await tester.pumpWidget(
      _testApp(
        settingsController: _FakeSettingsController(
          const SettingsState(
            downloadDirectory: '/tmp/BStream-Music',
            language: AppLanguage.spanish,
            miniPlayerMode: MiniPlayerMode.standard,
            miniPlayerBackgroundMode: MiniPlayerBackgroundMode.artwork,
          ),
        ),
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion movil',
            artist: 'BStream Music',
            trackId: 'android-bottom-navigation-track',
            duration: Duration(minutes: 3),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final glass = find.byKey(const ValueKey('bottom-navigation-glass'));
    final content = find.byKey(const ValueKey('bottom-navigation-content'));
    final miniPlayer = find.byKey(const ValueKey('mini-player-surface'));
    final miniPlayerContainer = find.byKey(
      const ValueKey('mini-player-container'),
    );
    final glassDecorationFinder = find.descendant(
      of: glass,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox && widget.decoration is BoxDecoration,
      ),
    );
    final glassDecoration = tester
        .widgetList<DecoratedBox>(glassDecorationFinder)
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((decoration) => decoration.border != null);
    final context = tester.element(glass);

    expect(scaffold.extendBody, isTrue);
    expect(tester.getSize(content).height, 72);
    expect(
      find.descendant(of: glass, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    expect(
      glassDecoration.color,
      AppColors.surfaceChromeFor(
        context,
        accentModeAlpha: 0.86,
        transparentDarkAlpha: 0.42,
        transparentLightAlpha: 0.5,
        accentTintAlpha: 0.06,
      ),
    );
    expect(
      tester.getBottomLeft(miniPlayer).dy,
      closeTo(tester.getTopLeft(glass).dy, 0.1),
    );
    expect(tester.getTopLeft(miniPlayerContainer).dx, closeTo(0, 0.1));
    expect(tester.getTopRight(miniPlayerContainer).dx, closeTo(360, 0.1));
    final miniContainerWidget = tester.widget<Container>(miniPlayerContainer);
    final miniDecoration = miniContainerWidget.decoration! as BoxDecoration;
    expect(
      miniDecoration.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(10)),
    );
    expect(tester.getBottomLeft(glass).dy, closeTo(800, 0.1));
    expect(
      tester.getSize(glass).height,
      closeTo(72 + MediaQuery.paddingOf(context).bottom, 0.1),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'capsule glass keeps browsing content visible behind the player and gap',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1
        ..padding = const FakeViewPadding(bottom: 24);
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetPadding();
      });

      await tester.pumpWidget(
        _testApp(
          settingsController: _FakeSettingsController(
            const SettingsState(
              downloadDirectory: '/tmp/BStream-Music',
              language: AppLanguage.spanish,
              miniPlayerMode: MiniPlayerMode.capsule,
              miniPlayerBackgroundMode: MiniPlayerBackgroundMode.transparent,
            ),
          ),
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: 'Glass real',
              artist: 'BStream Music',
              trackId: 'glass-layout-track',
              duration: Duration(minutes: 3),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final homeScroll = find.descendant(
        of: find.byKey(const ValueKey('home-view')),
        matching: find.byType(CustomScrollView),
      );
      final capsuleSurface = find.byKey(const ValueKey('mini-player-surface'));
      final navigation = find.byKey(const ValueKey('bottom-navigation-glass'));
      final scrollRect = tester.getRect(homeScroll);
      final capsuleRect = tester.getRect(capsuleSurface);
      final navigationRect = tester.getRect(navigation);

      expect(scrollRect.bottom, closeTo(navigationRect.top, 0.1));
      expect(scrollRect.bottom, greaterThan(capsuleRect.bottom));
      expect(capsuleRect.top, lessThan(scrollRect.bottom));
      expect(
        scrollRect.bottom - capsuleRect.bottom,
        closeTo(8, 0.1),
        reason: 'The capsule gap must reveal the scrolling tab beneath it.',
      );
      final reserve = tester.widget<SizedBox>(
        find.byKey(const ValueKey('home-scroll-bottom-reserve')),
      );
      expect(reserve.height, greaterThanOrEqualTo(80));
      expect(
        find.byKey(const ValueKey('mini-player-glass-blur')),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'transparent surface effects reveal content behind headers and menu',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final glassTrack = LocalTrack(
        id: 'glass-surface-track',
        title: 'Cancion de cristal',
        artist: 'BStream Music',
        filePath: r'C:\Music\glass-surface-track.mp3',
        duration: const Duration(minutes: 3),
        addedAt: DateTime(2026),
      );
      final libraryRepository = _FakeLibraryRepository()
        ..localTracks.add(glassTrack)
        ..playlists.add(
          Playlist(
            id: Playlist.favoritesId,
            name: 'Favoritos',
            trackIds: <String>[glassTrack.id],
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        );
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1
        ..padding = const FakeViewPadding(bottom: 24);
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetPadding();
      });

      await tester.pumpWidget(
        _testApp(
          settingsController: _FakeSettingsController(
            const SettingsState(
              downloadDirectory: '/tmp/BStream-Music',
              language: AppLanguage.spanish,
              surfaceBackgroundMode: SurfaceBackgroundMode.transparent,
            ),
          ),
          libraryRepository: libraryRepository,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 300));

      final homeScroll = find.descendant(
        of: find.byKey(const ValueKey('home-view')),
        matching: find.byType(CustomScrollView),
      );
      final navigation = find.byKey(const ValueKey('bottom-navigation-glass'));
      final navigationSurface = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('bottom-navigation-surface')),
      );
      final navigationColor =
          (navigationSurface.decoration as BoxDecoration).color!;
      final header = find.byKey(const ValueKey('home-tab-header-surface'));
      final headerMaterial = tester.widget<Material>(header);
      final surfaceTheme = Theme.of(
        tester.element(header),
      ).extension<AppSurfaceTheme>();
      final storedSurfaceMode = ProviderScope.containerOf(
        tester.element(header),
      ).read(settingsControllerProvider).value?.surfaceBackgroundMode;

      expect(storedSurfaceMode, SurfaceBackgroundMode.transparent);
      expect(surfaceTheme?.backgroundMode, SurfaceBackgroundMode.transparent);
      expect(
        tester.getRect(homeScroll).bottom,
        tester.getRect(navigation).bottom,
      );
      expect(navigationColor.a, greaterThan(0.5));
      expect(navigationColor.a, lessThan(0.6));
      expect(headerMaterial.color?.a, greaterThan(0.45));
      expect(headerMaterial.color?.a, lessThan(0.55));
      expect(
        find.ancestor(of: header, matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );
      final reserve = tester.widget<SizedBox>(
        find.byKey(const ValueKey('home-scroll-bottom-reserve')),
      );
      expect(reserve.height, greaterThanOrEqualTo(170));

      await tester.tap(find.byKey(const ValueKey('bottom-navigation-item-1')));
      await tester.pump(const Duration(milliseconds: 500));

      final searchInputSurface = find.byKey(
        const ValueKey('search-input-surface'),
      );
      expect(searchInputSurface, findsOneWidget);
      expect(
        find.descendant(
          of: searchInputSurface,
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      final searchFieldContext = tester.element(find.byType(TextField));
      final inputFill = Theme.of(
        searchFieldContext,
      ).inputDecorationTheme.fillColor;
      expect(inputFill, AppColors.inputSurfaceFor(searchFieldContext));
      expect(
        inputFill!.a,
        greaterThan(AppColors.menuBackgroundFor(searchFieldContext).a),
      );
      expect(inputFill.a, greaterThan(headerMaterial.color!.a));

      await tester.tap(find.byKey(const ValueKey('bottom-navigation-item-3')));
      await tester.pump(const Duration(milliseconds: 500));
      final libraryTabHeaderRect = tester.getRect(
        find.byKey(const ValueKey('library-tab-header-surface')),
      );
      await tester.tap(find.byKey(const ValueKey('library-downloads-entry')));
      await tester.pump(const Duration(milliseconds: 300));

      final detailHeaderSurface = find.byKey(
        const ValueKey('library-detail-header-surface'),
      );
      final libraryFilterSurface = find.byKey(
        const ValueKey('library-filter-surface'),
      );
      final libraryFilterRegion = find.byKey(
        const ValueKey('library-filter-region-surface'),
      );
      expect(
        find.byKey(const ValueKey('library-detail-header')),
        findsOneWidget,
      );
      expect(detailHeaderSurface, findsOneWidget);
      expect(libraryFilterSurface, findsOneWidget);
      expect(libraryFilterRegion, findsOneWidget);
      final detailHeaderRect = tester.getRect(detailHeaderSurface);
      expect(detailHeaderRect.width, tester.view.physicalSize.width);
      expect(detailHeaderRect.size, libraryTabHeaderRect.size);
      expect(
        tester.getRect(libraryFilterRegion).width,
        tester.view.physicalSize.width,
      );
      expect(tester.getRect(libraryFilterRegion).height, lessThanOrEqualTo(60));
      expect(
        find.ancestor(
          of: detailHeaderSurface,
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: libraryFilterRegion,
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: libraryFilterSurface,
          matching: find.byType(BackdropFilter),
        ),
        findsNothing,
      );
      final libraryFilterRegionDecoration =
          tester
                  .widget<DecoratedBox>(
                    find.byKey(
                      const ValueKey('tab-pinned-footer-accent-gradient'),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(libraryFilterRegionDecoration.borderRadius, isNull);
      expect(libraryFilterRegionDecoration.gradient, isA<LinearGradient>());
      final libraryFilterFieldContext = tester.element(
        find.descendant(
          of: libraryFilterSurface,
          matching: find.byType(TextField),
        ),
      );
      final libraryFilterFill = Theme.of(
        libraryFilterFieldContext,
      ).inputDecorationTheme.fillColor!;
      expect(
        libraryFilterFill.a,
        greaterThan(AppColors.menuBackgroundFor(libraryFilterFieldContext).a),
      );
      final detailHeaderDecoration =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: detailHeaderSurface,
                      matching: find.byKey(
                        const ValueKey('tab-header-accent-gradient'),
                      ),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(detailHeaderDecoration.borderRadius, isNull);
      final detailHeaderGradient = detailHeaderDecoration.gradient!;
      final expectedHeaderGradient = AppColors.glassAccentGradientFor(
        tester.element(detailHeaderSurface),
        intensity: 0.76,
      );
      expect(
        (detailHeaderGradient as LinearGradient).colors,
        expectedHeaderGradient.colors,
      );
      final downloadedTile = find.byKey(
        const ValueKey('library-track-glass-surface-track'),
      );
      expect(downloadedTile, findsOneWidget);
      final downloadedDecoration =
          tester
                  .widget<AnimatedContainer>(
                    find
                        .descendant(
                          of: downloadedTile,
                          matching: find.byType(AnimatedContainer),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      final downloadedContext = tester.element(downloadedTile);
      expect(
        downloadedDecoration.color,
        AppColors.cardSurfaceFor(downloadedContext),
      );
      expect(downloadedDecoration.gradient, isNull);
      expect(
        (downloadedDecoration.border! as Border).top.color,
        AppColors.cardBorderFor(downloadedContext),
      );

      await tester.tap(find.byIcon(Icons.arrow_back_rounded).first);
      await tester.pump(const Duration(milliseconds: 300));
      final favoritesEntry = find.byKey(
        const ValueKey('library-playlist-bstream:favorites'),
      );
      await tester.ensureVisible(favoritesEntry);
      await tester.tap(favoritesEntry);
      await tester.pump(const Duration(milliseconds: 300));

      final favoriteTile = find.byKey(
        const ValueKey('library-track-glass-surface-track'),
      );
      expect(favoriteTile, findsOneWidget);
      final favoriteDecoration =
          tester
                  .widget<AnimatedContainer>(
                    find
                        .descendant(
                          of: favoriteTile,
                          matching: find.byType(AnimatedContainer),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      final favoriteContext = tester.element(favoriteTile);
      expect(
        favoriteDecoration.color,
        AppColors.cardSurfaceFor(favoriteContext),
      );
      expect(favoriteDecoration.gradient, isNull);
      expect(
        (favoriteDecoration.border! as Border).top.color,
        AppColors.cardBorderFor(favoriteContext),
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'android keyboard keeps mini player attached to bottom navigation',
    (tester) async {
      final navigationInset = keyboardNavigationInsets.currentValue!;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1
        ..padding = FakeViewPadding(bottom: navigationInset);
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetPadding()
          ..resetViewInsets();
      });

      await tester.pumpWidget(
        _testApp(
          settingsController: _FakeSettingsController(
            const SettingsState(
              downloadDirectory: '/tmp/BStream-Music',
              language: AppLanguage.spanish,
              miniPlayerMode: MiniPlayerMode.standard,
              miniPlayerBackgroundMode: MiniPlayerBackgroundMode.artwork,
            ),
          ),
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: 'Cancion durante busqueda',
              artist: 'BStream Music',
              trackId: 'android-keyboard-mini-player-track',
              duration: Duration(minutes: 3),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('bottom-navigation-item-1')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(TextField));
      await tester.pump();

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();

      final glass = find.byKey(const ValueKey('bottom-navigation-glass'));
      final content = find.byKey(const ValueKey('bottom-navigation-content'));
      final miniPlayer = find.byKey(const ValueKey('mini-player-surface'));
      expect(tester.getSize(content).height, 72);
      expect(
        tester.getBottomLeft(miniPlayer).dy,
        closeTo(tester.getTopLeft(glass).dy, 0.1),
      );
      expect(tester.getSize(glass).height, closeTo(72, 0.1));
      expect(tester.getBottomLeft(glass).dy, closeTo(500, 0.1));
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
    variant: keyboardNavigationInsets,
  );

  testWidgets(
    'android player shell opens and closes as one continuous transition',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPadding();
      });

      await tester.pumpWidget(
        _testApp(
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: 'Cancion para transicion coordinada',
              artist: 'BStream Music',
              trackId: 'coordinated-shell-track',
              duration: Duration(minutes: 3),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      double slotOpacity(Finder slot) {
        final nearestOpacity = find
            .descendant(of: slot, matching: find.byType(AnimatedOpacity))
            .evaluate()
            .reduce((nearest, candidate) {
              return candidate.depth < nearest.depth ? candidate : nearest;
            });
        return (nearestOpacity.renderObject! as RenderAnimatedOpacity)
            .opacity
            .value;
      }

      double shellOpacity(String key) =>
          tester.widget<Opacity>(find.byKey(ValueKey(key))).opacity;

      final home = find.byKey(const ValueKey('home-view'));
      final miniClip = find.byKey(const ValueKey('mini-player-shell-clip'));
      final bottomClip = find.byKey(
        const ValueKey('bottom-navigation-shell-clip'),
      );
      final initialMiniHeight = tester.getSize(miniClip).height;
      final initialBottomHeight = tester.getSize(bottomClip).height;
      expect(initialMiniHeight, greaterThan(0));
      expect(initialBottomHeight, greaterThan(0));
      expect(find.byKey(const ValueKey('player-view')), findsNothing);

      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
      );
      await tester.pump();
      await tester.pump();

      final player = find.byKey(const ValueKey('player-view'));
      expect(player, findsOneWidget);
      expect(
        find.byKey(const ValueKey('shell-background-browsing')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('shell-background-player')),
        findsOneWidget,
      );
      final retainedPlayerElement = tester.element(find.byType(PlayerPanel));

      await tester.pump(const Duration(milliseconds: 160));

      expect(shellOpacity('mini-player-shell-opacity'), inExclusiveRange(0, 1));
      expect(
        shellOpacity('bottom-navigation-shell-opacity'),
        inExclusiveRange(0, 1),
      );
      expect(slotOpacity(home), inExclusiveRange(0, 1));
      expect(slotOpacity(player), inExclusiveRange(0, 1));
      expect(tester.getSize(miniClip).height, closeTo(initialMiniHeight, 0.1));
      expect(
        tester.getSize(bottomClip).height,
        closeTo(initialBottomHeight, 0.1),
      );
      expect(
        tester.getBottomLeft(miniClip).dy,
        closeTo(tester.getTopLeft(bottomClip).dy, 0.1),
      );
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 200));

      expect(shellOpacity('mini-player-shell-opacity'), 0);
      expect(shellOpacity('bottom-navigation-shell-opacity'), 0);
      expect(tester.getSize(miniClip).height, closeTo(initialMiniHeight, 0.1));
      expect(
        tester.getSize(bottomClip).height,
        closeTo(initialBottomHeight, 0.1),
      );
      expect(slotOpacity(home), 0);
      expect(slotOpacity(player), 1);
      expect(
        find.byKey(const ValueKey('shell-background-browsing')),
        findsNothing,
      );

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 160));

      expect(shellOpacity('mini-player-shell-opacity'), inExclusiveRange(0, 1));
      expect(
        shellOpacity('bottom-navigation-shell-opacity'),
        inExclusiveRange(0, 1),
      );
      expect(slotOpacity(home), inExclusiveRange(0, 1));
      expect(slotOpacity(player), inExclusiveRange(0, 1));
      expect(
        tester.getBottomLeft(miniClip).dy,
        closeTo(tester.getTopLeft(bottomClip).dy, 0.1),
      );

      await tester.pump(const Duration(milliseconds: 200));

      expect(shellOpacity('mini-player-shell-opacity'), 1);
      expect(shellOpacity('bottom-navigation-shell-opacity'), 1);
      expect(tester.getSize(miniClip).height, closeTo(initialMiniHeight, 0.1));
      expect(
        tester.getSize(bottomClip).height,
        closeTo(initialBottomHeight, 0.1),
      );
      expect(slotOpacity(home), 1);
      expect(slotOpacity(player), 0);
      expect(find.byKey(const ValueKey('player-view')), findsOneWidget);
      expect(
        identical(
          retainedPlayerElement,
          tester.element(find.byType(PlayerPanel)),
        ),
        isTrue,
      );
      expect(
        find.byKey(const ValueKey('shell-background-player')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'android Back from an initially restored player falls back to Home',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        _testApp(
          testHome: const HomePage(
            initialDestination: HomeInitialDestination.player,
          ),
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: 'Reentrada desde notificacion',
              artist: 'BStream Music',
              trackId: 'notification-reentry-track',
              duration: Duration(minutes: 3),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final player = find.byKey(const ValueKey('player-view'));
      expect(player, findsOneWidget);
      // The restored player starts without HomePage's tab history, but it must
      // still expose one safe local route entry to Android Back.
      expect(Navigator.of(tester.element(player)).canPop(), isTrue);

      final handled = await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(handled, isTrue);
      expect(
        find.byKey(const ValueKey('shell-background-browsing')),
        findsOneWidget,
      );
      expect(find.text('Inicio'), findsWidgets);
      expect(find.byType(HomePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'android direct player pop consumes local history instead of app root',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await tester.pumpWidget(
        _testApp(
          testHome: const HomePage(
            initialDestination: HomeInitialDestination.player,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final player = find.byKey(const ValueKey('player-view'));
      Navigator.of(tester.element(player)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.text('Inicio'), findsWidgets);
      expect(
        find.byKey(const ValueKey('shell-background-browsing')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'android queue Back is consumed before restored player falls back Home',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        _testApp(
          testHome: const HomePage(
            initialDestination: HomeInitialDestination.player,
          ),
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: 'Reentrada con cola',
              artist: 'BStream Music',
              trackId: 'notification-queue-track',
              duration: Duration(minutes: 3),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.textContaining('Cola de'), findsOneWidget);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.textContaining('Cola de'), findsNothing);
      expect(find.byKey(const ValueKey('player-view')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('shell-background-player')),
        findsOneWidget,
      );

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Inicio'), findsWidgets);
      expect(
        find.byKey(const ValueKey('shell-background-browsing')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'android external entries and repeated launcher activations return Home',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1;
      final externalAudio = StreamController<ExternalAudioRequest>.broadcast(
        sync: true,
      );
      final appActivations =
          StreamController<AndroidAppActivationEvent>.broadcast(sync: true);
      final player = _RecordingHomePlayerController();
      addTearDown(() async {
        debugDefaultTargetPlatformOverride = null;
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
        await externalAudio.close();
        await appActivations.close();
      });

      await tester.pumpWidget(
        _testApp(
          playerController: player,
          externalAudioRequests: externalAudio.stream,
          androidAppActivations: appActivations.stream,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      for (var index = 0; index < 3; index++) {
        final externalGeneration = (index * 2) + 1;
        externalAudio.add(
          ExternalAudioRequest(
            requestId: 'external-cycle-$index',
            selectedIndex: 0,
            tracks: [
              ExternalAudioTrack(
                id: 'external-track-$index',
                uri: 'content://media/external/audio/$index',
                title: 'Audio externo $index',
                artist: 'Artista local',
                duration: const Duration(minutes: 2),
              ),
            ],
            folderQueueComplete: true,
            permissionPending: false,
            permissionDenied: false,
            entryGeneration: externalGeneration,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          find.byKey(const ValueKey('shell-background-player')),
          findsOneWidget,
        );
        expect(player.localPlayCalls, index + 1);

        // This is the event sent by the dedicated launcher entry point. It
        // must reset the same retained HomePage/FlutterEngine every time.
        appActivations.add(
          AndroidAppActivationEvent(
            activation: AndroidAppActivation.home,
            entryGeneration: externalGeneration + 1,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          find.byKey(const ValueKey('shell-background-browsing')),
          findsOneWidget,
        );
        expect(find.text('Inicio'), findsWidgets);
      }

      externalAudio.add(
        const ExternalAudioRequest(
          requestId: 'external-resolved-after-launcher',
          selectedIndex: 0,
          tracks: [
            ExternalAudioTrack(
              id: 'external-track-after-launcher',
              uri: 'content://media/external/audio/after-launcher',
              title: 'Audio resuelto tarde',
            ),
          ],
          folderQueueComplete: true,
          permissionPending: false,
          permissionDenied: false,
          entryGeneration: 5,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('shell-background-browsing')),
        findsOneWidget,
      );
      expect(player.localPlayCalls, 4);

      // A media-notification activation remains distinct: it opens Player,
      // while Back still consumes local history and returns safely to Home.
      appActivations.add(
        const AndroidAppActivationEvent(
          activation: AndroidAppActivation.player,
          entryGeneration: 7,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('shell-background-player')),
        findsOneWidget,
      );

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('shell-background-browsing')),
        findsOneWidget,
      );
      expect(player.localPlayCalls, 4);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('android player content stays above three-button navigation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..physicalSize = const Size(360, 800)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(bottom: 24);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio()
        ..resetPadding();
    });

    await tester.pumpWidget(
      _testApp(
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.failed,
            title: 'Pista con error',
            artist: 'BStream Music',
            trackId: 'navigation-inset-error-track',
            duration: Duration(minutes: 3),
            errorMessage: 'No se pudo abrir la pista.',
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final error = find.byKey(const ValueKey('player-error-message'));
    final control = find.byKey(const ValueKey('player-volume-control'));
    expect(error, findsOneWidget);
    expect(control, findsOneWidget);
    await tester.ensureVisible(error);
    expect(tester.getRect(error).bottom, lessThanOrEqualTo(800 - 24.0 + 0.1));
    expect(tester.getRect(control).bottom, lessThanOrEqualTo(800 - 24.0 + 0.1));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('bottom navigation selection interpolates without layout snap', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(_testApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    double slotOpacity(Finder slot) {
      final nearestOpacity = find
          .descendant(of: slot, matching: find.byType(AnimatedOpacity))
          .evaluate()
          .reduce((nearest, candidate) {
            return candidate.depth < nearest.depth ? candidate : nearest;
          });
      return (nearestOpacity.renderObject! as RenderAnimatedOpacity)
          .opacity
          .value;
    }

    const searchIndex = 1;
    final searchItem = find.byKey(
      const ValueKey('bottom-navigation-item-$searchIndex'),
    );
    final searchScale = find.byKey(
      const ValueKey('bottom-navigation-icon-scale-$searchIndex'),
    );
    Finder searchIcon() => find.descendant(
      of: searchItem,
      matching: find.byIcon(Icons.search_rounded),
    );
    double scale() =>
        tester.widget<Transform>(searchScale).transform.getMaxScaleOnAxis();
    final colors = Theme.of(tester.element(searchItem)).colorScheme;

    expect(tester.widget<Icon>(searchIcon()).size, 28);
    expect(tester.widget<Icon>(searchIcon()).color, colors.onSurfaceVariant);
    expect(scale(), closeTo(1, 0.001));

    await tester.tap(searchItem);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));

    final midColor = tester.widget<Icon>(searchIcon()).color!;
    expect(tester.widget<Icon>(searchIcon()).size, 28);
    expect(scale(), inExclusiveRange(1, 1.12));
    expect(midColor, isNot(colors.onSurfaceVariant));
    expect(midColor, isNot(colors.primary));
    expect(
      slotOpacity(find.byKey(const ValueKey('home-view'))),
      greaterThan(0.45),
      reason: 'The outgoing tab must not fade to a dark flash too early.',
    );
    expect(find.byKey(const ValueKey('search-view')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 160));

    expect(tester.widget<Icon>(searchIcon()).size, 28);
    expect(tester.widget<Icon>(searchIcon()).color, colors.primary);
    expect(scale(), closeTo(1.12, 0.001));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shell and navigation indicators honor reduced motion', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _testApp(
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Movimiento reducido',
            artist: 'BStream Music',
            trackId: 'reduced-motion-shell-track',
            duration: Duration(minutes: 3),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      tester
          .widget<TweenAnimationBuilder<double>>(
            find.byKey(const ValueKey('bottom-navigation-selection-1')),
          )
          .duration,
      Duration.zero,
    );
    expect(
      tester
          .widget<TweenAnimationBuilder<double>>(
            find
                .descendant(
                  of: find.byKey(
                    const ValueKey('mini-player-shell-transition'),
                  ),
                  matching: find.byType(TweenAnimationBuilder<double>),
                )
                .first,
          )
          .duration,
      Duration.zero,
    );
    expect(
      tester
          .widget<AnimatedSwitcher>(
            find.byKey(const ValueKey('shell-background-transition')),
          )
          .duration,
      Duration.zero,
    );

    await tester.tap(find.byKey(const ValueKey('bottom-navigation-item-1')));
    await tester.pump();
    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('bottom-navigation-icon-scale-1')),
          )
          .transform
          .getMaxScaleOnAxis(),
      closeTo(1.12, 0.001),
    );

    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
    );
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const ValueKey('mini-player-shell-opacity')),
          )
          .opacity,
      0,
    );
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const ValueKey('bottom-navigation-shell-opacity')),
          )
          .opacity,
      0,
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1280, 720);
    await tester.pumpWidget(_testApp());
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      tester
          .widget<TweenAnimationBuilder<double>>(
            find.byKey(const ValueKey('side-navigation-selection-1')),
          )
          .duration,
      Duration.zero,
    );
    expect(
      tester
          .widget<AnimatedContainer>(
            find.byKey(const ValueKey('side-navigation-surface')),
          )
          .duration,
      Duration.zero,
    );
    await tester.tap(find.byKey(const ValueKey('side-navigation-item-1')));
    await tester.pump();
    expect(
      tester
          .widget<Transform>(
            find.byKey(const ValueKey('side-navigation-icon-scale-1')),
          )
          .transform
          .getMaxScaleOnAxis(),
      closeTo(1.12, 0.001),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('home recent cards use larger mobile dimensions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final repository = _homeCardsRepository();

    await tester.pumpWidget(_testApp(libraryRepository: repository));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const ValueKey('home-recent-card'))).width,
      148,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('home-recent-shelf'))).height,
      200,
    );
    expect(find.byKey(const ValueKey('home-playlist-shelf')), findsNothing);
    final recentCard = find.byKey(const ValueKey('home-recent-card'));
    final recentMaterial = find
        .descendant(of: recentCard, matching: find.byType(Material))
        .first;
    expect(
      tester.widget<Material>(recentMaterial).color,
      AppColors.homeCardSurfaceFor(tester.element(recentCard)),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('home does not show the local playlist section', (tester) async {
    _configureMobileHomeViewport(tester);
    final repository = _homeCardsRepository();

    await tester.pumpWidget(_testApp(libraryRepository: repository));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Inicio'), findsWidgets);
    expect(find.text('Cancion reciente'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-recent-card')), findsOneWidget);
    expect(find.text('Mis playlists'), findsNothing);
    expect(find.text('Todavía no hay playlists locales.'), findsNothing);
    expect(find.byKey(const ValueKey('home-playlist-shelf')), findsNothing);
    expect(find.byKey(const ValueKey('home-playlist-card')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home keeps synchronized catalog playlists out of the start screen',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final now = DateTime.utc(2026, 8, 22);
      final playlist = Playlist(
        id: 'synced-playlist',
        name: 'Viaje sincronizado',
        trackIds: const <String>[],
        createdAt: now,
        updatedAt: now,
        localRevision: 1,
      );
      final catalog = CatalogPlaylist(
        playlist: playlist,
        entries: <PlaylistEntry>[
          PlaylistEntry(
            id: 'remote-entry',
            playlistId: playlist.id,
            track: CatalogTrack.youtube(
              videoId: 'video-remote',
              title: 'Canción remota',
              artists: const <String>['Artista'],
              duration: const Duration(minutes: 3, seconds: 7),
              thumbnailUrl: 'https://i.ytimg.com/vi/video-remote/hqdefault.jpg',
            ),
            remoteVideoId: 'video-remote',
            setVideoId: 'set-remote',
            position: 0,
            origin: PlaylistEntryOrigin.remote,
            createdAt: now,
            updatedAt: now,
          ),
          PlaylistEntry(
            id: 'unavailable-entry',
            playlistId: playlist.id,
            track: const CatalogTrack(
              key: 'youtube-unavailable:set-missing',
              provider: CatalogProvider.legacy,
              providerId: 'set-missing',
              title: 'Contenido no disponible',
            ),
            setVideoId: 'set-missing',
            position: 1,
            origin: PlaylistEntryOrigin.remote,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          catalogPlaylists: <CatalogPlaylist>[catalog],
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Mis playlists'), findsNothing);
      expect(find.text('Viaje sincronizado'), findsNothing);
      expect(find.byKey(const ValueKey('home-playlist-card')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('home hides the complete recent section when history is empty', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final repository = _homeCardsRepository()..history.clear();

    await tester.pumpWidget(_testApp(libraryRepository: repository));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Inicio'), findsWidgets);
    expect(find.text('Escuchado recientemente'), findsNothing);
    expect(find.text('Aún no has escuchado canciones.'), findsNothing);
    expect(find.byKey(const ValueKey('home-recent-shelf')), findsNothing);
    expect(find.byKey(const ValueKey('home-recent-card')), findsNothing);
    expect(find.text('Mis playlists'), findsNothing);
    expect(find.byKey(const ValueKey('home-playlist-card')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home recent cards use larger desktop dimensions',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repository = _homeCardsRepository();

      await tester.pumpWidget(_testApp(libraryRepository: repository));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(
        tester.getSize(find.byKey(const ValueKey('home-recent-card'))).width,
        176,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('home-recent-shelf'))).height,
        228,
      );
      expect(find.byKey(const ValueKey('home-playlist-shelf')), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets('home shelves fit text scale 3 on a 320x568 phone', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(
      _testApp(
        libraryRepository: _homeCardsRepository(),
        homeRecommendations: [
          HomeRecommendationSection(
            title: 'Para ti',
            tracks: const [
              TrackInfo(
                id: 'scaled-recommendation',
                title: 'Recomendacion de titulo largo',
                artist: 'Artista de nombre largo',
                url: 'https://www.youtube.com/watch?v=scaled',
                thumbnailUrl: '',
              ),
            ],
          ),
        ],
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-surface'))).height,
      greaterThan(62),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-primary-control'))),
      const Size.square(50),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('bottom-navigation-content')))
          .height,
      greaterThan(72),
    );
    final navigationItems = find.descendant(
      of: find.byKey(const ValueKey('bottom-navigation-content')),
      matching: find.byType(InkWell),
    );
    expect(navigationItems, findsNWidgets(5));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('bottom-navigation-content')),
        matching: find.byIcon(Icons.folder_rounded),
      ),
      findsOneWidget,
    );
    for (var index = 0; index < 5; index++) {
      final size = tester.getSize(navigationItems.at(index));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    final homeScroll = find.descendant(
      of: find.byKey(const ValueKey('home-view')),
      matching: find.byType(CustomScrollView),
    );
    final homeHeading = find.byKey(const ValueKey('home-tab-title'));
    final homeHeadingTop = tester.getTopLeft(homeHeading).dy;
    final homeHeaderSurface = find.byKey(
      const ValueKey('home-tab-header-surface'),
    );
    expect(
      tester.widget<Material>(homeHeaderSurface).color,
      AppColors.tabHeaderSurfaceFor(
        tester.element(homeHeaderSurface),
        scrolledUnder: false,
      ),
    );
    expect(tester.widget<Material>(homeHeaderSurface).elevation, 0);
    expect(tester.getSize(homeHeaderSurface).height, greaterThanOrEqualTo(64));
    // At a 3x text scale, the accessible title can legitimately move the
    // lazily-built shelves below the first viewport. Scroll to the shelf
    // before inspecting its adaptive height.
    await tester.drag(homeScroll, const Offset(0, -360));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(homeHeading).dy, closeTo(homeHeadingTop, 0.01));
    expect(
      tester.widget<Material>(homeHeaderSurface).color,
      AppColors.tabHeaderSurfaceFor(
        tester.element(homeHeaderSurface),
        scrolledUnder: true,
      ),
    );
    expect(tester.widget<Material>(homeHeaderSurface).elevation, 1);
    expect(
      tester.widget<Material>(homeHeaderSurface).surfaceTintColor,
      Colors.transparent,
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('home-recent-shelf'))).height,
      greaterThan(200),
    );

    await tester.drag(homeScroll, const Offset(0, -900));
    // Advance the Android stretching overscroll one frame at a time. A single
    // long pump only ticks the spring once and leaves the pinned sliver
    // temporarily transformed in widget tests.
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(tester.getTopLeft(homeHeading).dy, closeTo(homeHeadingTop, 0.01));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('home shows circular artists and hides Tus mixes', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    const artistArtwork = 'https://example.invalid/artist-one.jpg';
    final sections = [
      HomeRecommendationSection.items(
        title: 'Artistas populares',
        items: const [
          HomeRecommendationArtistItem(
            HomeRecommendationArtist(
              name: 'Artista Uno',
              browseId: 'UCartist-one',
              thumbnailUrl: artistArtwork,
            ),
          ),
          HomeRecommendationArtistItem(
            HomeRecommendationArtist(
              name: 'Artista Dos',
              browseId: 'UCartist-two',
              thumbnailUrl: 'https://example.invalid/artist-two.jpg',
            ),
          ),
          HomeRecommendationArtistItem(
            HomeRecommendationArtist(
              name: 'Artista Tres',
              browseId: 'UCartist-three',
              thumbnailUrl: 'https://example.invalid/artist-three.jpg',
            ),
          ),
        ],
      ),
      HomeRecommendationSection.items(
        title: 'Tus mixes',
        personalizedKind: PersonalizedSectionKind.mixes,
        items: const [
          HomeRecommendationCollectionItem(
            HomeRecommendationCollection(
              title: 'Mix oculto',
              browseId: 'VLRDhidden-mix',
              playlistId: 'RDhidden-mix',
              kind: HomeRecommendationCollectionKind.mix,
            ),
          ),
        ],
      ),
      HomeRecommendationSection.items(
        title: 'Mixes para entrenar',
        items: const [
          HomeRecommendationCollectionItem(
            HomeRecommendationCollection(
              title: 'Energía diaria',
              browseId: 'VLRDtraining-mix',
              playlistId: 'RDtraining-mix',
              kind: HomeRecommendationCollectionKind.mix,
            ),
          ),
        ],
      ),
    ];

    await tester.pumpWidget(_testApp(homeRecommendations: sections));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Artistas populares'), findsOneWidget);
    expect(find.text('Artista Uno'), findsOneWidget);
    expect(find.text('Tus mixes'), findsNothing);
    expect(find.text('Mix oculto'), findsNothing);
    expect(find.text('Mixes para entrenar'), findsOneWidget);
    expect(find.text('Energía diaria'), findsOneWidget);
    expect(
      tester
          .getTopLeft(
            find.byKey(
              const ValueKey(
                'home-recommendations-section-Mixes para entrenar',
              ),
            ),
          )
          .dy,
      greaterThan(
        tester
            .getTopLeft(
              find.byKey(
                const ValueKey(
                  'home-recommendations-section-Artistas populares',
                ),
              ),
            )
            .dy,
      ),
    );
    expect(
      find.byKey(const ValueKey('home-artist-artwork-UCartist-one')),
      findsOneWidget,
    );
    expect(
      tester.widget(
        find.byKey(const ValueKey('home-artist-artwork-UCartist-one')),
      ),
      isA<ClipOval>(),
    );
    final artwork = find.descendant(
      of: find.byKey(const ValueKey('home-artist-UCartist-one')),
      matching: find.byType(SourceImage),
    );
    expect(artwork, findsOneWidget);
    expect(tester.widget<SourceImage>(artwork).source, artistArtwork);

    final artistOpen = find.byKey(
      const ValueKey('home-artist-open-UCartist-one'),
    );
    expect(tester.widget<InkWell>(artistOpen).onTap, isNotNull);
    tester.widget<InkWell>(artistOpen).onTap!();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(ArtistProfilePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home progressively fills a missing artist portrait', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final service = _ArtistPortraitSearch();
    final sections = [
      HomeRecommendationSection.items(
        title: 'Artistas recomendados',
        items: const [
          HomeRecommendationArtistItem(
            HomeRecommendationArtist(
              name: 'Artista sin retrato inicial',
              browseId: 'UCartist-missing-photo',
            ),
          ),
        ],
      ),
    ];

    await tester.pumpWidget(
      _testApp(homeRecommendations: sections, youtubeMusicSearch: service),
    );
    final artwork = find.descendant(
      of: find.byKey(const ValueKey('home-artist-UCartist-missing-photo')),
      matching: find.byType(SourceImage),
    );
    await _pumpUntil(
      tester,
      () =>
          artwork.evaluate().isNotEmpty &&
          tester.widget<SourceImage>(artwork).source ==
              _ArtistPortraitSearch.portraitUrl,
      reason: 'the progressively loaded artist portrait',
    );
    expect(artwork, findsOneWidget);
    expect(
      tester.widget<SourceImage>(artwork).source,
      _ArtistPortraitSearch.portraitUrl,
    );
    expect(service.profileCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home shows online recommendation shelves and plays the selected shelf queue',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final player = _RecordingHomePlayerController();
      final sections = [
        HomeRecommendationSection(
          title: 'Para ti',
          tracks: const [
            TrackInfo(
              id: 'recommended-1',
              title: 'Recomendacion uno',
              artist: 'Artista uno',
              url: 'https://www.youtube.com/watch?v=recommend1',
              thumbnailUrl: '',
            ),
            TrackInfo(
              id: 'recommended-2',
              title: 'Recomendacion dos',
              artist: 'Artista dos',
              url: 'https://www.youtube.com/watch?v=recommend2',
              thumbnailUrl: '',
            ),
            TrackInfo(
              id: 'recommended-3',
              title: 'Recomendacion tres',
              artist: 'Artista tres',
              url: 'https://www.youtube.com/watch?v=recommend3',
              thumbnailUrl: '',
            ),
          ],
        ),
        HomeRecommendationSection(
          title: 'Novedades',
          tracks: const [
            TrackInfo(
              id: 'recommended-4',
              title: 'Recomendacion cuatro',
              artist: 'Artista cuatro',
              url: 'https://www.youtube.com/watch?v=recommend4',
              thumbnailUrl: '',
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          playerController: player,
          homeRecommendations: sections,
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(const ValueKey('home-recommendations-section-Para ti')),
        findsOneWidget,
      );
      for (final id in const [
        'recommended-1',
        'recommended-2',
        'recommended-3',
      ]) {
        expect(find.byKey(ValueKey('home-recommendation-$id')), findsOneWidget);
      }
      expect(find.text('Cancion reciente'), findsOneWidget);
      expect(find.text('Mis playlists'), findsNothing);

      final homeScroll = find.byType(CustomScrollView);
      await tester.drag(homeScroll, const Offset(0, -600));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('home-recommendations-section-Novedades'))
            .evaluate()
            .isNotEmpty,
        reason: 'the Novedades shelf to enter the viewport',
      );
      expect(
        find.byKey(const ValueKey('home-recommendations-section-Novedades')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-recommendation-recommended-4')),
        findsOneWidget,
      );

      await tester.drag(homeScroll, const Offset(0, 600));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('home-recommendation-recommended-2'))
            .evaluate()
            .isNotEmpty,
        reason: 'the selected recommendation to return to the viewport',
      );

      final selected = find.byKey(
        const ValueKey('home-recommendation-recommended-2'),
      );
      await tester.drag(homeScroll, const Offset(0, -250));
      await _pumpUntil(
        tester,
        () => selected.evaluate().isNotEmpty,
        reason: 'the selected recommendation to remain mounted',
      );
      await tester.tap(selected);
      await tester.pump();

      expect(player.remotePlayCalls, 1);
      expect(player.lastRemoteTrack?.id, 'recommended-2');
      expect(player.lastRemoteQueue?.map((track) => track.id), const [
        'recommended-1',
        'recommended-2',
        'recommended-3',
      ]);
      expect(
        player.lastRemoteQueue,
        isNot(contains(sections.last.tracks.single)),
      );
    },
  );

  testWidgets(
    'personalized Continue replaces legacy recent and plays its local section queue',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final player = _RecordingHomePlayerController();
      final repository = _homeCardsRepository();
      final feed = PersonalizedRecommendationFeed(
        generatedAt: DateTime.utc(2026),
        sections: [
          PersonalizedRecommendationSection(
            kind: PersonalizedSectionKind.continueListening,
            title: 'Engine title',
            items: [
              PersonalizedTrackItem(
                trackId: 'home-card-track',
                videoId: 'LocalVideo01',
                title: 'Cancion reciente',
                artists: const ['Artista reciente'],
                source: PlaybackEventSource.downloaded,
              ),
              PersonalizedTrackItem(
                trackId: 'RemoteNext1',
                videoId: 'RemoteNext1',
                title: 'Siguiente recomendada',
                artists: const ['Artista remoto'],
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        _testApp(
          libraryRepository: repository,
          playerController: player,
          personalizedHomeFeedSource: _StaticPersonalizedHomeFeedSource(feed),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Seguir escuchando'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-recent-shelf')), findsNothing);

      final homeScroll = find.byType(CustomScrollView);
      await tester.drag(homeScroll, const Offset(0, -500));
      final localRecommendation = find.byKey(
        const ValueKey('home-recommendation-LocalVideo01'),
      );
      await _pumpUntil(
        tester,
        () => localRecommendation.evaluate().isNotEmpty,
        reason: 'the local recommendation to enter the viewport',
      );
      await tester.tap(localRecommendation);
      await tester.pump();

      expect(player.localPlayCalls, 1);
      expect(player.lastLocalTrack?.id, 'home-card-track');
      expect(player.lastLocalQueue?.map((track) => track.id), [
        'home-card-track',
      ]);
      expect(
        player.lastLocalQueueSourceId,
        'personalized-home:continueListening',
      );
      expect(player.lastRecommendationQueue?.map((item) => item.track.id), [
        'LocalVideo01',
        'RemoteNext1',
      ]);
      expect(
        player.lastRecommendationQueue?.first.localTrack?.id,
        'home-card-track',
      );
      expect(player.lastRecommendationQueue?[1].localTrack, isNull);
      expect(player.remotePlayCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'personalized home prefers downloaded artwork for a streaming recommendation',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final directory = io.Directory.systemTemp.createTempSync(
        'bstream-home-offline-artwork-',
      );
      final artwork = io.File(p.join(directory.path, 'downloaded-cover.png'));
      artwork.writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        flush: true,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        if (directory.existsSync()) {
          directory.deleteSync(recursive: true);
        }
      });
      final repository = _homeCardsRepository();
      final downloaded = repository.localTracks.single.copyWith(
        sourceId: 'OfflineVid1',
        thumbnailPath: artwork.path,
      );
      repository.localTracks[0] = downloaded;
      repository.history[0] = downloaded;
      final feed = PersonalizedRecommendationFeed(
        generatedAt: DateTime.utc(2026),
        sections: [
          PersonalizedRecommendationSection(
            kind: PersonalizedSectionKind.becauseYouListened,
            title: 'Offline artwork',
            items: [
              PersonalizedTrackItem(
                trackId: 'streaming-event-id',
                videoId: 'OfflineVid1',
                title: 'Disponible sin conexion',
                artists: const ['Artista local'],
                thumbnailUrl: 'https://offline.invalid/remote-cover.jpg',
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        _testApp(
          libraryRepository: repository,
          personalizedHomeFeedSource: _StaticPersonalizedHomeFeedSource(feed),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
      await tester.pump();

      final artworkSurface = find.byKey(
        const ValueKey('home-recommendation-artwork-OfflineVid1'),
      );
      expect(artworkSurface, findsOneWidget);
      final proportionalArtwork = tester.widget<ProportionalArtwork>(
        find.descendant(
          of: artworkSurface,
          matching: find.byType(ProportionalArtwork),
        ),
      );
      expect(proportionalArtwork.source, artwork.path);
      expect(
        proportionalArtwork.fallbackSource,
        'https://i.ytimg.com/vi/OfflineVid1/hq720.jpg',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a one-song personalized shelf grows a related queue for Next', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final player = _RecordingHomePlayerController();
    final related = _FakeRecommendationRelatedSearch();
    final feed = PersonalizedRecommendationFeed(
      generatedAt: DateTime.utc(2026),
      sections: [
        PersonalizedRecommendationSection(
          kind: PersonalizedSectionKind.discovery,
          title: 'Discovery',
          items: [
            PersonalizedTrackItem(
              trackId: 'VideoSeed01',
              videoId: 'VideoSeed01',
              title: 'Semilla',
              artists: const ['Artista'],
            ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      _testApp(
        playerController: player,
        personalizedHomeFeedSource: _StaticPersonalizedHomeFeedSource(feed),
        youtubeMusicSearch: related,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final homeScroll = find.byType(CustomScrollView);
    await tester.drag(homeScroll, const Offset(0, -500));
    final seedRecommendation = find.byKey(
      const ValueKey('home-recommendation-VideoSeed01'),
    );
    await _pumpUntil(
      tester,
      () => seedRecommendation.evaluate().isNotEmpty,
      reason: 'the discovery seed to enter the viewport',
    );
    await tester.tap(seedRecommendation);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(related.nextVideoIds, ['VideoSeed01']);
    expect(player.recommendationSyncCalls, 1);
    expect(player.lastSyncedRecommendationQueue?.map((item) => item.track.id), [
      'VideoSeed01',
      'NextSong001',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a seven-song Because shelf also receives a related continuation queue',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final player = _RecordingHomePlayerController();
      final related = _FakeRecommendationRelatedSearch();
      final feed = PersonalizedRecommendationFeed(
        generatedAt: DateTime.utc(2026),
        sections: [
          PersonalizedRecommendationSection(
            kind: PersonalizedSectionKind.becauseYouListened,
            title: 'Because',
            seedTitle: 'Semilla',
            items: [
              for (var index = 0; index < 7; index++)
                PersonalizedTrackItem(
                  trackId: index == 0 ? 'VideoSeed01' : 'VisibleSong0$index',
                  videoId: index == 0 ? 'VideoSeed01' : 'VisibleSong0$index',
                  title: 'Visible $index',
                  artists: const ['Artista'],
                ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        _testApp(
          playerController: player,
          personalizedHomeFeedSource: _StaticPersonalizedHomeFeedSource(feed),
          youtubeMusicSearch: related,
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final homeScroll = find.byType(CustomScrollView);
      await tester.drag(homeScroll, const Offset(0, -500));
      final seedRecommendation = find.byKey(
        const ValueKey('home-recommendation-VideoSeed01'),
      );
      await _pumpUntil(
        tester,
        () => seedRecommendation.evaluate().isNotEmpty,
        reason: 'the Because seed to enter the viewport',
      );
      await tester.tap(seedRecommendation);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(related.nextVideoIds, ['VideoSeed01']);
      expect(player.recommendationSyncCalls, 1);
      expect(player.lastSyncedRecommendationQueue, hasLength(8));
      expect(
        player.lastSyncedRecommendationQueue?.last.track.id,
        'NextSong001',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared app link opens the player once with resolved InnerTube metadata',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final incomingLinks = _FakeIncomingTrackLinkService();
      final lookup = _FakeYouTubeMusicTrackLookup();
      final player = _RecordingHomePlayerController();
      addTearDown(incomingLinks.close);

      await tester.pumpWidget(
        _testApp(
          playerController: player,
          incomingTrackLinkService: incomingLinks,
          youtubeMusicSearch: lookup,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final uri = Uri.parse('bstreammusic://track/dQw4w9WgXcQ');
      incomingLinks.add(uri);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byKey(const ValueKey('player-tab-title')), findsOneWidget);
      expect(player.remotePlayCalls, 1);
      expect(player.lastRemoteTrack?.id, 'dQw4w9WgXcQ');
      expect(player.lastRemoteTrack?.title, 'Never Gonna Give You Up');
      expect(player.lastRemoteTrack?.artist, 'Rick Astley');
      expect(player.lastRemoteTrack?.album, 'Whenever You Need Somebody');
      expect(player.lastRemoteTrack?.duration, const Duration(minutes: 3));
      expect(
        player.lastRemoteTrack?.metadataSource,
        TrackMetadataSource.youtubeMusic,
      );
      expect(
        player.lastRemoteTrack?.url,
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      expect(player.lastRemoteQueueSourceId, 'shared-link:dQw4w9WgXcQ');
      expect(lookup.requestedVideoIds, ['dQw4w9WgXcQ']);

      incomingLinks.add(uri);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(player.remotePlayCalls, 1);
      expect(lookup.requestedVideoIds, ['dQw4w9WgXcQ']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('public YouTube Music track link opens the player once', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final incomingLinks = _FakeIncomingTrackLinkService();
    final lookup = _FakeYouTubeMusicTrackLookup();
    final player = _RecordingHomePlayerController();
    addTearDown(incomingLinks.close);

    await tester.pumpWidget(
      _testApp(
        playerController: player,
        incomingTrackLinkService: incomingLinks,
        youtubeMusicSearch: lookup,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final uri = Uri.parse(
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=bstream-test',
    );
    incomingLinks.add(uri);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('player-tab-title')), findsOneWidget);
    expect(player.remotePlayCalls, 1);
    expect(player.lastRemoteTrack?.id, 'dQw4w9WgXcQ');
    expect(player.lastRemoteTrack?.title, 'Never Gonna Give You Up');
    expect(player.lastRemoteTrack?.artist, 'Rick Astley');
    expect(player.lastRemoteQueueSourceId, 'shared-link:dQw4w9WgXcQ');
    expect(lookup.requestedVideoIds, ['dQw4w9WgXcQ']);

    incomingLinks.add(uri);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(player.remotePlayCalls, 1);
    expect(lookup.requestedVideoIds, ['dQw4w9WgXcQ']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'public YouTube Music playlist link opens its complete collection',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final incomingLinks = _FakeIncomingTrackLinkService();
      final player = _RecordingHomePlayerController();
      addTearDown(incomingLinks.close);
      const playlistId = 'PL1234567890abcdef';
      const browseId = 'VL$playlistId';
      const playlistTracks = <TrackInfo>[
        TrackInfo(
          id: 'linked-song-1',
          title: 'Cancion enlazada uno',
          artist: 'Artista uno',
          url: 'https://www.youtube.com/watch?v=LinkedSong1',
        ),
        TrackInfo(
          id: 'linked-song-2',
          title: 'Cancion enlazada dos',
          artist: 'Artista dos',
          url: 'https://www.youtube.com/watch?v=LinkedSong2',
        ),
      ];
      final requestedBrowseIds = <String>[];

      await tester.pumpWidget(
        _testApp(
          playerController: player,
          incomingTrackLinkService: incomingLinks,
          homeCollectionDetailLoader: (requestedBrowseId) async {
            requestedBrowseIds.add(requestedBrowseId);
            return RemoteCollectionData(
              title: 'Favoritas para viajar',
              subtitle: 'Cuenta de prueba',
              artworkSource: 'https://img.test/playlist-real.jpg',
              tracks: playlistTracks,
            );
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      incomingLinks.add(
        Uri.parse(
          'https://music.youtube.com/playlist?list=$playlistId&si=test-share',
        ),
      );
      await tester.pump();
      await _pumpUntil(
        tester,
        () =>
            requestedBrowseIds.isNotEmpty &&
            find
                .byKey(const ValueKey('remote-collection-detail'))
                .evaluate()
                .isNotEmpty &&
            find.text('Cancion enlazada dos').evaluate().isNotEmpty,
        reason: 'the linked playlist detail to load',
      );

      expect(requestedBrowseIds, [browseId]);
      expect(find.text('Favoritas para viajar'), findsNWidgets(2));
      expect(find.text('Cuenta de prueba'), findsOneWidget);
      expect(find.text('Playlist'), findsNothing);
      expect(find.text('Cancion enlazada uno'), findsOneWidget);
      expect(find.text('Cancion enlazada dos'), findsOneWidget);
      expect(player.remotePlayCalls, 0);

      await tester.tap(find.byKey(const ValueKey('remote-collection-play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(player.remotePlayCalls, 1);
      expect(player.lastRemoteTrack?.id, 'linked-song-1');
      expect(player.lastRemoteQueue?.map((track) => track.id), const [
        'linked-song-1',
        'linked-song-2',
      ]);
      expect(
        player.lastRemoteQueueSourceId,
        'incoming-youtube:playlist:$browseId',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a public track link replaces an already open playlist detail', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final incomingLinks = _FakeIncomingTrackLinkService();
    final lookup = _FakeYouTubeMusicTrackLookup();
    final player = _RecordingHomePlayerController();
    addTearDown(incomingLinks.close);

    await tester.pumpWidget(
      _testApp(
        playerController: player,
        incomingTrackLinkService: incomingLinks,
        youtubeMusicSearch: lookup,
        homeCollectionLoader: (_) async => const <TrackInfo>[
          TrackInfo(
            id: 'linked-song-1',
            title: 'Cancion de playlist abierta',
            artist: 'Artista',
            url: 'https://www.youtube.com/watch?v=LinkedSong1',
          ),
        ],
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    incomingLinks.add(
      Uri.parse('https://music.youtube.com/playlist?list=PL1234567890abcdef'),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('remote-collection-detail'))
          .evaluate()
          .isNotEmpty,
      reason: 'the linked playlist detail to open',
    );

    incomingLinks.add(
      Uri.parse('https://music.youtube.com/watch?v=dQw4w9WgXcQ'),
    );
    await _pumpUntil(
      tester,
      () =>
          player.remotePlayCalls == 1 &&
          find.byKey(const ValueKey('player-tab-title')).evaluate().isNotEmpty,
      reason: 'the newer linked track to replace the playlist detail',
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsNothing,
    );
    expect(player.lastRemoteTrack?.id, 'dQw4w9WgXcQ');
    expect(lookup.requestedVideoIds, ['dQw4w9WgXcQ']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared app link does not wait indefinitely for metadata', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final incomingLinks = _FakeIncomingTrackLinkService();
    final lookup = _StalledYouTubeMusicTrackLookup();
    final player = _RecordingHomePlayerController();
    addTearDown(incomingLinks.close);

    await tester.pumpWidget(
      _testApp(
        playerController: player,
        incomingTrackLinkService: incomingLinks,
        youtubeMusicSearch: lookup,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    incomingLinks.add(Uri.parse('bstreammusic://track/M7lc1UVf-VE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3100));
    await tester.pump();

    expect(player.remotePlayCalls, 1);
    expect(player.lastRemoteTrack?.id, 'M7lc1UVf-VE');
    expect(player.lastRemoteTrack?.title, 'Canción compartida');
    expect(
      player.lastRemoteTrack?.url,
      'https://www.youtube.com/watch?v=M7lc1UVf-VE',
    );
    expect(player.lastRemoteQueueSourceId, 'shared-link:M7lc1UVf-VE');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home opens a playlist detail and Play starts the complete queue',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final player = _RecordingHomePlayerController();
      var collectionCalls = 0;
      const browseId = 'VLPLrelaxing-playlist';
      final playlistTracks = const [
        TrackInfo(
          id: 'playlist-track-1',
          title: 'Playlist uno',
          artist: 'Artista uno',
          url: 'https://www.youtube.com/watch?v=playlist01',
          thumbnailUrl: '',
        ),
        TrackInfo(
          id: 'playlist-track-2',
          title: 'Playlist dos',
          artist: 'Artista dos',
          url: 'https://www.youtube.com/watch?v=playlist02',
          thumbnailUrl: '',
        ),
      ];
      final sections = [
        HomeRecommendationSection.items(
          title: 'Melodias relajantes',
          items: const [
            HomeRecommendationCollectionItem(
              HomeRecommendationCollection(
                title: 'Playlist para relajarse',
                subtitle: 'YouTube Music',
                thumbnailUrl: '',
                browseId: browseId,
                playlistId: 'PLrelaxing-playlist',
                kind: HomeRecommendationCollectionKind.playlist,
              ),
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          playerController: player,
          homeRecommendations: sections,
          homeCollectionLoader: (requestedBrowseId) async {
            collectionCalls++;
            expect(requestedBrowseId, browseId);
            return playlistTracks;
          },
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(collectionCalls, 0);
      expect(player.remotePlayCalls, 0);

      final playlistCard = find.byKey(
        const ValueKey('home-collection-open-$browseId'),
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await _pumpUntil(
        tester,
        () => playlistCard.evaluate().isNotEmpty,
        reason: 'the playlist card to enter the viewport',
      );
      expect(playlistCard, findsOneWidget);
      expect(find.text('Playlist para relajarse'), findsOneWidget);

      await tester.tap(playlistCard);
      await _pumpUntil(
        tester,
        () =>
            collectionCalls == 1 &&
            find
                .byKey(const ValueKey('remote-collection-detail'))
                .evaluate()
                .isNotEmpty &&
            find.text('Playlist para relajarse').evaluate().length == 2,
        reason: 'the loaded playlist detail to be rendered',
      );

      expect(collectionCalls, 1);
      expect(player.remotePlayCalls, 0);
      expect(
        find.byKey(const ValueKey('remote-collection-detail')),
        findsOneWidget,
      );
      expect(find.text('Playlist para relajarse'), findsNWidgets(2));
      expect(find.text('YouTube Music'), findsOneWidget);
      expect(find.text('Playlist uno'), findsOneWidget);
      expect(find.text('Playlist dos'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('remote-collection-play')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(player.remotePlayCalls, 1);
      expect(player.lastRemoteTrack?.id, 'playlist-track-1');
      expect(player.lastRemoteQueue?.map((track) => track.id), const [
        'playlist-track-1',
        'playlist-track-2',
      ]);
      expect(player.lastRemoteQueueSourceId, 'home-collection:$browseId');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home refresh keeps recommendations visible while loading and replaces them',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final pending = Completer<List<HomeRecommendationSection>>();
      addTearDown(() {
        if (!pending.isCompleted) {
          pending.complete(const <HomeRecommendationSection>[]);
        }
      });
      var calls = 0;
      final initialSections = [
        HomeRecommendationSection(
          title: 'Antes de refrescar',
          tracks: const [
            TrackInfo(
              id: 'refresh-old-track',
              title: 'Recomendacion anterior',
              artist: 'Artista anterior',
              url: 'https://www.youtube.com/watch?v=refreshold1',
            ),
          ],
        ),
      ];
      final refreshedSections = [
        HomeRecommendationSection(
          title: 'Despues de refrescar',
          tracks: const [
            TrackInfo(
              id: 'refresh-new-track',
              title: 'Recomendacion nueva',
              artist: 'Artista nuevo',
              url: 'https://www.youtube.com/watch?v=refreshnew1',
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          homeRecommendationsLoader: () {
            calls++;
            return calls == 1 ? initialSections : pending.future;
          },
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      final refresh = find.byKey(
        const ValueKey('home-recommendations-refresh'),
      );
      expect(calls, 1);
      expect(refresh, findsOneWidget);
      expect(tester.getSize(refresh), const Size.square(48));
      expect(
        tester.widget<IconButton>(refresh).tooltip,
        'Refrescar recomendaciones',
      );
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Antes de refrescar'),
        ),
        findsOneWidget,
      );

      await tester.tap(refresh);
      await tester.pump();

      expect(calls, 2);
      expect(tester.widget<IconButton>(refresh).onPressed, isNull);
      expect(
        find.descendant(
          of: refresh,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Antes de refrescar'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-recent-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-playlist-card')), findsNothing);

      pending.complete(refreshedSections);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Despues de refrescar'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Antes de refrescar'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home refresh keeps the previous feed when the network request fails',
    (tester) async {
      _configureMobileHomeViewport(tester);
      var calls = 0;
      final initialSections = [
        HomeRecommendationSection(
          title: 'Feed conservado',
          tracks: const [
            TrackInfo(
              id: 'refresh-preserved-track',
              title: 'Recomendacion conservada',
              artist: 'Artista local',
              url: 'https://www.youtube.com/watch?v=preserved1',
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          homeRecommendationsLoader: () async {
            calls++;
            if (calls == 1) {
              return initialSections;
            }
            throw const io.SocketException('offline');
          },
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      final refresh = find.byKey(
        const ValueKey('home-recommendations-refresh'),
      );
      await tester.tap(refresh);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(calls, 2);
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Feed conservado'),
        ),
        findsOneWidget,
      );
      expect(find.text('offline'), findsNothing);
      expect(find.byKey(const ValueKey('home-recent-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-playlist-card')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('home hides recommendations while loading and keeps local data', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final pending = Completer<List<HomeRecommendationSection>>();
    addTearDown(() {
      if (!pending.isCompleted) {
        pending.complete(const <HomeRecommendationSection>[]);
      }
    });

    await tester.pumpWidget(
      _testApp(
        libraryRepository: _homeCardsRepository(),
        homeRecommendations: pending.future,
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    _expectLocalOnlyHome(tester);
  });

  testWidgets(
    'home hides failed recommendations and local playback still works',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final player = _RecordingHomePlayerController();

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          playerController: player,
          homeRecommendationsError: const io.SocketException('offline'),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      _expectLocalOnlyHome(tester);

      await tester.tap(find.byKey(const ValueKey('home-recent-card')));
      await tester.pump();

      expect(player.historyPlayCalls, 1);
      expect(player.lastHistoryTrack?.id, 'home-card-track');
      expect(player.lastHistoryQueue?.map((track) => track.id), const [
        'home-card-track',
      ]);
      expect(player.remotePlayCalls, 0);
    },
  );

  testWidgets('home hides empty recommendations and keeps local data', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);

    await tester.pumpWidget(
      _testApp(
        libraryRepository: _homeCardsRepository(),
        homeRecommendations: const <HomeRecommendationSection>[],
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    _expectLocalOnlyHome(tester);
  });

  testWidgets('visible tab headings share the same themed foreground', (
    tester,
  ) async {
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
        themeMode: AppThemeMode.dark,
        accent: AppAccent.blue,
      ),
    );
    await tester.pumpWidget(_testApp(settingsController: settingsController));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final homeColor = tester
        .widget<Text>(find.byKey(const ValueKey('home-tab-title')))
        .style
        ?.color;

    await tester.tap(find.text('Buscar').last);
    await tester.pump(const Duration(milliseconds: 300));
    final searchColor = tester
        .widget<Text>(find.byKey(const ValueKey('search-tab-title')))
        .style
        ?.color;

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 300));
    final libraryColor = tester
        .widget<Text>(find.byKey(const ValueKey('library-tab-title')))
        .style
        ?.color;

    await tester.tap(find.text('Ajustes').last);
    await tester.pump(const Duration(milliseconds: 300));
    final settingsColor = tester
        .widget<Text>(find.byKey(const ValueKey('settings-tab-title')))
        .style
        ?.color;

    expect(homeColor, isNotNull);
    expect(searchColor, homeColor);
    expect(libraryColor, homeColor);
    expect(settingsColor, homeColor);
  });

  testWidgets('tab titles and first root content share page insets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _testApp(
        libraryRepository: _homeCardsRepository(),
        settingsController: _FakeSettingsController(
          const SettingsState(
            downloadDirectory: '/tmp/bstream',
            language: AppLanguage.spanish,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    void expectSharedInsets({
      required Finder header,
      required Finder title,
      required Finder firstSection,
    }) {
      expect(
        tester.getTopLeft(firstSection).dx,
        closeTo(tester.getTopLeft(title).dx, 0.01),
      );
      expect(
        tester.getTopLeft(firstSection).dy - tester.getBottomLeft(header).dy,
        closeTo(appTabFirstSectionTopGap, 0.01),
      );
    }

    expectSharedInsets(
      header: find.byKey(const ValueKey('home-tab-header-surface')),
      title: find.byKey(const ValueKey('home-tab-title')),
      firstSection: find.byKey(
        const ValueKey('home-section-title-Escuchado recientemente'),
      ),
    );

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 300));
    final libraryHeader = find.byKey(
      const ValueKey('library-tab-header-surface'),
    );
    final downloadsEntry = find.byKey(
      const ValueKey('library-downloads-entry'),
    );
    expect(
      find.byKey(const ValueKey('library-first-section-title')),
      findsNothing,
    );
    expect(
      tester.getTopLeft(downloadsEntry).dy -
          tester.getBottomLeft(libraryHeader).dy,
      closeTo(appTabFirstSectionTopGap, 0.01),
    );

    await tester.tap(find.text('Ajustes').last);
    await tester.pump(const Duration(milliseconds: 300));
    expectSharedInsets(
      header: find.byKey(const ValueKey('settings-tab-header-surface')),
      title: find.byKey(const ValueKey('settings-tab-title')),
      firstSection: find.byKey(const ValueKey('settings-first-section-title')),
    );
    final settingsCardLeft = tester
        .getTopLeft(find.byKey(const ValueKey('settings-card-language')))
        .dx;
    final settingsSectionLeft = tester
        .getTopLeft(find.byKey(const ValueKey('settings-first-section-title')))
        .dx;
    expect(settingsSectionLeft - settingsCardLeft, closeTo(10, 0.01));
    final settingsRootPadding =
        tester
                .widget<SliverPadding>(
                  find
                      .descendant(
                        of: find.byKey(const ValueKey('settings-root')),
                        matching: find.byType(SliverPadding),
                      )
                      .first,
                )
                .padding
            as EdgeInsets;
    expect(settingsRootPadding.left, 6);
    expect(settingsRootPadding.right, 6);
    expect(settingsRootPadding.top, appTabFirstSectionTopGap);
  });

  testWidgets('settings heading stays fixed at text scale 3', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );

    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async => null,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final heading = find.byKey(const ValueKey('settings-tab-title'));
    final headingTop = tester.getTopLeft(heading).dy;
    final settingsHeaderSurface = find.byKey(
      const ValueKey('settings-tab-header-surface'),
    );
    expect(
      tester.widget<Material>(settingsHeaderSurface).color,
      AppColors.tabHeaderSurfaceFor(
        tester.element(settingsHeaderSurface),
        scrolledUnder: false,
      ),
    );
    final settingsRoot = find.byKey(const ValueKey('settings-root'));
    await tester.drag(settingsRoot, const Offset(0, -420));
    await tester.pumpAndSettle();

    final settingsScrollable = tester.state<ScrollableState>(
      find.descendant(of: settingsRoot, matching: find.byType(Scrollable)),
    );
    expect(settingsScrollable.position.pixels, greaterThan(0));
    expect(tester.getTopLeft(heading).dy, closeTo(headingTop, 0.01));
    expect(
      tester.widget<Material>(settingsHeaderSurface).color,
      AppColors.tabHeaderSurfaceFor(
        tester.element(settingsHeaderSurface),
        scrolledUnder: true,
      ),
    );
    expect(tester.widget<Material>(settingsHeaderSurface).elevation, 1);
    expect(
      tester.widget<Material>(settingsHeaderSurface).surfaceTintColor,
      Colors.transparent,
    );
    expect(tester.takeException(), isNull);
  });

  for (final popupCase in const [
    (
      label: 'light accent',
      themeMode: AppThemeMode.light,
      brightness: Brightness.light,
      surfaceMode: SurfaceBackgroundMode.accent,
      borderAlpha: 0.72,
    ),
    (
      label: 'dark accent',
      themeMode: AppThemeMode.dark,
      brightness: Brightness.dark,
      surfaceMode: SurfaceBackgroundMode.accent,
      borderAlpha: 0.22,
    ),
    (
      label: 'light transparent',
      themeMode: AppThemeMode.light,
      brightness: Brightness.light,
      surfaceMode: SurfaceBackgroundMode.transparent,
      borderAlpha: 0.52,
    ),
    (
      label: 'dark transparent',
      themeMode: AppThemeMode.dark,
      brightness: Brightness.dark,
      surfaceMode: SurfaceBackgroundMode.transparent,
      borderAlpha: 0.34,
    ),
  ]) {
    testWidgets('${popupCase.label} popup follows the surface palette', (
      tester,
    ) async {
      final settingsController = _FakeSettingsController(
        SettingsState(
          downloadDirectory: '/tmp/bstream',
          language: AppLanguage.spanish,
          themeMode: popupCase.themeMode,
          accent: AppAccent.blue,
          surfaceBackgroundMode: popupCase.surfaceMode,
        ),
      );
      await tester.pumpWidget(_testApp(settingsController: settingsController));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));

      final context = tester.element(find.byType(Scaffold).first);
      final settings = ProviderScope.containerOf(
        context,
      ).read(settingsControllerProvider).value;
      final theme = Theme.of(context);
      final popupTheme = theme.popupMenuTheme;
      final shape = popupTheme.shape! as RoundedRectangleBorder;
      final dialogTheme = theme.dialogTheme;
      final dialogShape = dialogTheme.shape! as RoundedRectangleBorder;

      expect(settings?.themeMode, popupCase.themeMode);
      expect(settings?.surfaceBackgroundMode, popupCase.surfaceMode);
      expect(theme.brightness, popupCase.brightness);
      expect(
        popupTheme.color,
        AppColors.menuBackgroundForTheme(
          AppAccent.blue,
          theme.colorScheme,
          backgroundMode: popupCase.surfaceMode,
        ),
      );
      expect(popupTheme.color, AppColors.menuBackgroundFor(context));
      expect(popupTheme.textStyle?.color, AppColors.menuForegroundFor(context));
      expect(popupTheme.iconColor, AppColors.menuIconFor(context));
      expect(popupTheme.surfaceTintColor, Colors.transparent);
      expect(
        shape.side.color,
        AppColors.menuBorderForTheme(
          AppAccent.blue,
          theme.colorScheme,
          backgroundMode: popupCase.surfaceMode,
        ),
      );
      expect(shape.side.color, AppColors.menuBorderFor(context));
      expect(shape.side.color.a, closeTo(popupCase.borderAlpha, 0.001));
      expect(
        popupTheme.color!.a,
        popupCase.surfaceMode == SurfaceBackgroundMode.transparent
            ? lessThan(0.75)
            : greaterThan(0.9),
      );
      expect(
        dialogTheme.backgroundColor,
        AppColors.dialogSurfaceForTheme(
          AppAccent.blue,
          theme.colorScheme,
          backgroundMode: popupCase.surfaceMode,
        ),
      );
      expect(
        dialogShape.side.color,
        AppColors.dialogBorderForTheme(
          AppAccent.blue,
          theme.colorScheme,
          backgroundMode: popupCase.surfaceMode,
        ),
      );
      expect(
        dialogTheme.barrierColor,
        AppColors.dialogBarrierForTheme(
          theme.colorScheme,
          backgroundMode: popupCase.surfaceMode,
        ),
      );
      expect(dialogTheme.surfaceTintColor, Colors.transparent);
    });
  }

  testWidgets('desktop Downloads and Backup share the Storage settings page', (
    tester,
  ) async {
    if (!io.Platform.isWindows &&
        !io.Platform.isLinux &&
        !io.Platform.isMacOS) {
      return;
    }
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final initialPath = io.Platform.isWindows
        ? r'C:\Music\Initial'
        : '/tmp/music/initial';
    final selectedPath = io.Platform.isWindows
        ? r'D:\Music\Selected'
        : '/tmp/music/selected';
    final settingsController = _FakeSettingsController(
      SettingsState(
        downloadDirectory: initialPath,
        language: AppLanguage.spanish,
      ),
    );
    var pickerCalls = 0;
    String? receivedTitle;
    String? receivedInitialDirectory;

    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async {
              pickerCalls++;
              receivedTitle = dialogTitle;
              receivedInitialDirectory = initialDirectory;
              return selectedPath;
            },
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('settings-card-storage')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-card-downloads')), findsNothing);
    expect(find.byKey(const ValueKey('settings-card-backup')), findsNothing);
    expect(
      find.byKey(const ValueKey('download-directory-field')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('backup-actions')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    final directoryField = find.byKey(
      const ValueKey('download-directory-field'),
    );
    expect(directoryField, findsOneWidget);
    expect(find.byKey(const ValueKey('backup-actions')), findsNothing);
    expect(find.byKey(const ValueKey('storage-import-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-import-csv')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-csv')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-import-start')), findsNothing);
    expect(find.text('Respaldo'), findsNothing);
    expect(tester.widget<TextField>(directoryField).readOnly, isTrue);

    final firstTransferCard = find.byKey(
      const ValueKey('storage-import-backup'),
    );
    expect(
      tester.getBottomLeft(directoryField).dy,
      lessThan(tester.getTopLeft(firstTransferCard).dy),
    );

    await tester.tap(find.byKey(const ValueKey('download-directory-browse')));
    await tester.pump(const Duration(milliseconds: 800));

    expect(pickerCalls, 1);
    expect(receivedTitle, 'Selecciona carpeta de descargas');
    expect(receivedInitialDirectory, initialPath);
    expect(settingsController.savedDirectories, [selectedPath]);
    expect(
      tester.widget<TextField>(directoryField).controller?.text,
      selectedPath,
    );

    expect(firstTransferCard, findsOneWidget);
    expect(find.text('Exportar'), findsOneWidget);
    expect(find.text('Importar'), findsOneWidget);
    expect(directoryField, findsOneWidget);
  });

  testWidgets('cancelling the desktop folder picker keeps the current folder', (
    tester,
  ) async {
    if (!io.Platform.isWindows &&
        !io.Platform.isLinux &&
        !io.Platform.isMacOS) {
      return;
    }
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final initialPath = io.Platform.isWindows
        ? r'C:\Music\Initial'
        : '/tmp/music/initial';
    final settingsController = _FakeSettingsController(
      SettingsState(
        downloadDirectory: initialPath,
        language: AppLanguage.spanish,
      ),
    );
    var pickerCalls = 0;
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async {
              pickerCalls++;
              return null;
            },
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    final directoryField = find.byKey(
      const ValueKey('download-directory-field'),
    );
    final before = tester.widget<TextField>(directoryField).controller!.text;

    await tester.tap(find.byKey(const ValueKey('download-directory-browse')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(pickerCalls, 1);
    expect(tester.widget<TextField>(directoryField).controller?.text, before);
    expect(before, initialPath);
    expect(settingsController.savedDirectories, isEmpty);
  });

  testWidgets('cancelling custom sleep timer closes safely', (tester) async {
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async => null,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final timerSwitch = find.descendant(
      of: find.byKey(const ValueKey('settings-inline-timer')),
      matching: find.byType(SwitchListTile),
    );
    await tester.ensureVisible(timerSwitch);
    await tester.tap(timerSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personalizar'));
    await tester.pumpAndSettle();
    expect(find.text('Duración del temporizador'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('accent palette always shows every color row', (tester) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(() => settingsController),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, isActive, _) => SettingsPanel(active: isActive),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('accent-white')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-orange')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-expand-button')), findsNothing);
    expect(find.byKey(const ValueKey('accent-red')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-cyan')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-indigo')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-lime')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-brown')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-lavender')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-ocean')), findsOneWidget);

    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-card-appearance')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('accent-expand-button')), findsNothing);
    expect(find.byKey(const ValueKey('accent-red')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('accent-expand-button')), findsNothing);
    expect(find.byKey(const ValueKey('accent-red')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-ocean')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('about card groups version, support, and GitHub in order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );
    final launchedUrls = <Uri>[];
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async => null,
        externalLauncher: (url) async {
          launchedUrls.add(url);
          return true;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final card = find.byKey(const ValueKey('settings-card-about'));
    await tester.scrollUntilVisible(
      card,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    expect(find.text('Información de la aplicación'), findsOneWidget);
    expect(find.text('Acerca de la aplicación'), findsOneWidget);
    expect(find.text('Versión, apoyo y repositorio'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-about-version')), findsNothing);
    final cardMaterial = find
        .descendant(of: card, matching: find.byType(Material))
        .first;
    final shape =
        tester.widget<Material>(cardMaterial).shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(6));

    await tester.tap(card);
    await tester.pumpAndSettle();

    final detail = find.byKey(const ValueKey('settings-detail-about'));
    final version = find.byKey(const ValueKey('settings-about-version'));
    final whatsNew = find.byKey(const ValueKey('settings-about-whats-new'));
    final support = find.byKey(const ValueKey('settings-about-support'));
    final github = find.byKey(const ValueKey('settings-about-github'));
    expect(detail, findsOneWidget);
    expect(card, findsNothing);
    expect(find.byKey(const ValueKey('settings-detail-back')), findsOneWidget);
    expect(find.text('Acerca de la aplicación'), findsOneWidget);
    expect(find.text('Versión'), findsOneWidget);
    expect(find.text(AppConstants.appVersion), findsOneWidget);
    expect(
      find.text('Novedades de ${AppConstants.appVersion}'),
      findsOneWidget,
    );
    expect(find.text('Apoyar el desarrollo'), findsOneWidget);
    expect(find.text('Repositorio de GitHub'), findsOneWidget);
    expect(find.text('Código fuente y contribuciones'), findsOneWidget);
    for (final row in [version, whatsNew, support, github]) {
      expect(find.descendant(of: detail, matching: row), findsOneWidget);
    }
    expect(
      tester.getTopLeft(version).dy,
      lessThan(tester.getTopLeft(whatsNew).dy),
    );
    expect(
      tester.getTopLeft(whatsNew).dy,
      lessThan(tester.getTopLeft(support).dy),
    );
    expect(
      tester.getTopLeft(support).dy,
      lessThan(tester.getTopLeft(github).dy),
    );
    await tester.ensureVisible(whatsNew);
    await tester.tap(whatsNew);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-about-whats-new-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('Playlists bidireccionales'), findsOneWidget);
    expect(
      find.text(
        'Personaliza las superficies de la app y el mini reproductor con estilos, colores de acento y transparencias.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Convierte letras de otros alfabetos a caracteres latinos para que sean m\u00e1s f\u00e1ciles de seguir.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Explora y reproduce la m\u00fasica guardada en tu dispositivo, con filtros para ocultar audios no deseados.',
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-about-whats-new-close')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(support);
    await tester.tap(support);
    await tester.pump();
    await tester.ensureVisible(github);
    await tester.tap(github);
    await tester.pump();

    expect(launchedUrls, [
      Uri.parse(AppConstants.supportDevelopmentUrl),
      Uri.parse(AppConstants.githubRepositoryUrl),
    ]);
    await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
    await tester.scrollUntilVisible(
      card,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('settings-card-about')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-about-version')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('support section reports when the browser cannot open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async => null,
        externalLauncher: (_) async => false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final about = find.byKey(const ValueKey('settings-card-about'));
    await tester.scrollUntilVisible(
      about,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(about);
    await tester.pumpAndSettle();
    await tester.tap(about);
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('settings-about-support'));
    await tester.scrollUntilVisible(
      button,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();

    expect(find.text('No se pudo abrir la página de apoyo.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('about card reports when GitHub cannot be opened', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async => null,
        externalLauncher: (_) async => false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final about = find.byKey(const ValueKey('settings-card-about'));
    await tester.scrollUntilVisible(
      about,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(about);
    await tester.pumpAndSettle();
    await tester.tap(about);
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('settings-about-github'));
    await tester.scrollUntilVisible(
      button,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();

    expect(
      find.text('No se pudo abrir el repositorio de GitHub.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('about card remains usable on a small phone at text scale 3', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async => null,
        platform: TargetPlatform.android,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final card = find.byKey(const ValueKey('settings-card-about'));
    await tester.scrollUntilVisible(
      card,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    final cardRect = tester.getRect(card);
    expect(cardRect.left, closeTo(6, 0.1));
    expect(cardRect.right, closeTo(314, 0.1));
    expect(find.text('Información de la aplicación'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-detail-about')), findsOneWidget);
    const rowKeys = [
      'settings-about-version',
      'settings-about-whats-new',
      'settings-about-support',
      'settings-about-github',
    ];
    for (final key in rowKeys) {
      final row = find.byKey(ValueKey(key));
      await tester.scrollUntilVisible(
        row,
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull, reason: key);
    }
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('system back remembers only the last two visited tabs', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(_testApp());
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Buscar').last);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Ajustes').last);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Biblioteca'), findsWidgets);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey('search-tab-title')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Inicio'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('track result actions live under a three dot menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(_FakePlayerService()),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TrackResultTile(
              track: const TrackInfo(
                id: 'track-result',
                title: 'Resultado',
                artist: 'BStream Music',
                url: 'https://example.com/result',
              ),
              onOpenPlayer: () {},
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Descargar'), findsOneWidget);
    expect(find.text('Añadir a playlist'), findsOneWidget);
  });

  testWidgets('library lazily builds large playlist collections', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final repository = _FakeLibraryRepository();
    repository.playlists.addAll(
      List.generate(
        1000,
        (index) => Playlist(
          id: 'lazy-$index',
          name: 'Playlist $index',
          trackIds: const [],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ),
    );

    await tester.pumpWidget(_libraryPanelTestApp(repository: repository));
    await tester.pumpAndSettle();

    final builtPlaylists = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('library-playlist-lazy-');
    });
    expect(builtPlaylists, findsWidgets);
    expect(
      builtPlaylists.evaluate().length,
      lessThan(40),
      reason: 'Only viewport-adjacent playlist rows should be mounted.',
    );
    final libraryHeading = find.byKey(const ValueKey('library-tab-title'));
    final libraryHeadingTop = tester.getTopLeft(libraryHeading).dy;
    final libraryHeaderSurface = find.byKey(
      const ValueKey('library-tab-header-surface'),
    );
    expect(
      tester.widget<Material>(libraryHeaderSurface).color,
      AppColors.tabHeaderSurfaceFor(
        tester.element(libraryHeaderSurface),
        scrolledUnder: false,
      ),
    );
    final libraryScroll = find.byKey(const ValueKey('library-root-scroll'));
    await tester.drag(libraryScroll, const Offset(0, -420));
    await tester.pumpAndSettle();

    final libraryScrollable = tester.state<ScrollableState>(
      find.descendant(of: libraryScroll, matching: find.byType(Scrollable)),
    );
    expect(libraryScrollable.position.pixels, greaterThan(0));
    expect(
      tester.getTopLeft(libraryHeading).dy,
      closeTo(libraryHeadingTop, 0.01),
    );
    expect(
      tester.widget<Material>(libraryHeaderSurface).color,
      AppColors.tabHeaderSurfaceFor(
        tester.element(libraryHeaderSurface),
        scrolledUnder: true,
      ),
    );
    expect(tester.widget<Material>(libraryHeaderSurface).elevation, 1);
    expect(
      tester.widget<Material>(libraryHeaderSurface).surfaceTintColor,
      Colors.transparent,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('current search result retains visible hover feedback', (
    tester,
  ) async {
    const track = TrackInfo(
      id: 'playing-result',
      title: 'Resultado activo',
      artist: 'BStream Music',
      url: 'https://example.com/playing-result',
      thumbnailUrl: '',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(
            _FakePlayerService(
              snapshot: PlayerSnapshot(
                status: PlayerStatus.playing,
                trackId: track.id,
                sourceUrl: track.url,
                isRemote: true,
              ),
            ),
          ),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: TrackResultTile(track: track, onOpenPlayer: _noop),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final surface = find.byKey(
      const ValueKey('track-result-surface-playing-result'),
    );
    var decoration =
        tester.widget<AnimatedContainer>(surface).decoration! as BoxDecoration;
    expect((decoration.border! as Border).top.width, 1);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 300));

    decoration =
        tester.widget<AnimatedContainer>(surface).decoration! as BoxDecoration;
    expect((decoration.border! as Border).top.width, 1.4);
  });

  testWidgets('search eagerly keeps all capped result thumbnails mounted', (
    tester,
  ) async {
    final tracks = List.generate(
      20,
      (index) => TrackInfo(
        id: 'search-$index',
        title: 'Resultado $index',
        artist: 'BStream Music',
        url: 'https://example.com/search-$index',
        thumbnailUrl: '',
      ),
    );
    tester.view.physicalSize = const Size(430, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchControllerProvider.overrideWith(
            () => _FakeSearchController(tracks),
          ),
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(_FakePlayerService()),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SearchView(onOpenPlayer: _noop)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(TrackResultTile), findsNWidgets(20));
    final artwork = tester
        .widgetList<ProportionalArtwork>(find.byType(ProportionalArtwork))
        .toList(growable: false);
    expect(artwork, hasLength(20));
    expect(artwork.every((image) => image.cacheWidth == 256), isTrue);
  });

  testWidgets('download bars show realtime progress from the active task id', (
    tester,
  ) async {
    const track = TrackInfo(
      id: 'progress-track',
      title: 'Progreso visible',
      artist: 'BStream Music',
      url: 'https://example.com/watch?v=progress-track',
      thumbnailUrl: '',
      duration: Duration(minutes: 3),
    );
    final downloader = _ControllableDownloaderService();
    final container = ProviderContainer(
      overrides: [
        downloaderServiceProvider.overrideWithValue(downloader),
        localTrackDownloadHelperProvider.overrideWith(
          (ref) => _ControllableLocalTrackDownloadHelper(ref, downloader),
        ),
        desktopMediaSessionFactoryProvider.overrideWithValue(() => null),
        playerServiceProvider.overrideWithValue(_FakePlayerService()),
        libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await downloader.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: TrackResultTile(track: track, onOpenPlayer: () {}),
                ),
                const DownloadProgressPanel(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.runAsync(() async {
      await container
          .read(downloadControllerProvider.notifier)
          .downloadAudio(track);
      await downloader.started.future.timeout(const Duration(seconds: 5));
    });
    await tester.pump();
    final taskId = container
        .read(downloadControllerProvider)[track.url]!
        .taskId;

    downloader.emitProgress(
      taskId: taskId,
      progress: 0.01,
      url: 'https://canonical.example/progress-track',
    );
    await tester.pump();

    var bars = tester
        .widgetList<GradientProgressBar>(find.byType(GradientProgressBar))
        .toList();
    expect(bars, hasLength(2));
    expect(bars.every((bar) => !bar.indeterminate), isTrue);
    expect(bars.every((bar) => bar.value == 0.01), isTrue);
    expect(
      bars.every((bar) => listEquals(bar.colors, AppColors.downloadGradient)),
      isTrue,
    );
    final downloadNote = tester.widget<Icon>(
      find.descendant(
        of: find.byType(DownloadProgressPanel),
        matching: find.byIcon(Icons.music_note_rounded),
      ),
    );
    expect(downloadNote.color, AppColors.downloadAccent);
    expect(find.textContaining('1%'), findsOneWidget);

    downloader.emitProgress(taskId: taskId, progress: 0.62);
    await tester.pump();
    bars = tester
        .widgetList<GradientProgressBar>(find.byType(GradientProgressBar))
        .toList();
    expect(bars.every((bar) => bar.value == 0.62), isTrue);

    final surface = find.byKey(
      const ValueKey('track-result-surface-progress-track'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 300));
    final decoration =
        tester.widget<AnimatedContainer>(surface).decoration! as BoxDecoration;
    expect((decoration.border! as Border).top.width, 1.4);

    downloader.emitProgress(taskId: taskId, progress: 0.30);
    await tester.pump();
    expect(
      container.read(downloadControllerProvider)[track.url]?.progress,
      0.62,
    );

    await tester.runAsync(() async {
      downloader.complete();
      for (var attempt = 0; attempt < 100; attempt++) {
        if (container.read(downloadControllerProvider)[track.url]?.status ==
            DownloadProgressStatus.completed) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(
      container.read(downloadControllerProvider)[track.url]?.status,
      DownloadProgressStatus.completed,
    );
  });

  test('downloadAudioForLibrary returns the saved local track', () async {
    final tempDirectory = await io.Directory.systemTemp.createTemp(
      'bstream-library-download-test-',
    );
    final libraryRepository = _FakeLibraryRepository();
    final container = ProviderContainer(
      overrides: [
        downloaderServiceProvider.overrideWithValue(
          _FakeDownloaderService(
            emitCompletedBeforeResult: true,
            resultDelay: const Duration(milliseconds: 350),
          ),
        ),
        playerServiceProvider.overrideWithValue(_FakePlayerService()),
        libraryRepositoryProvider.overrideWithValue(libraryRepository),
        settingsControllerProvider.overrideWith(
          () => _FakeSettingsController(
            SettingsState(
              downloadDirectory: tempDirectory.path,
              language: AppLanguage.spanish,
            ),
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final localTrack = await container
        .read(downloadControllerProvider.notifier)
        .downloadAudioForLibrary(
          const TrackInfo(
            id: 'remote-track',
            title: 'Cancion remota',
            artist: 'BStream Music',
            url: 'https://example.com/remote-track',
            thumbnailUrl: '',
            duration: Duration(minutes: 3),
          ),
        );

    expect(localTrack.id, startsWith('remote-'));
    expect(localTrack.title, 'Cancion remota');
    expect(libraryRepository.localTracks, hasLength(1));
    expect(libraryRepository.localTracks.single.id, localTrack.id);
  });

  testWidgets('highlights the active track in downloaded songs', (
    tester,
  ) async {
    final libraryRepository = _FakeLibraryRepository();
    final playerService = _FakePlayerService(
      snapshot: const PlayerSnapshot(
        status: PlayerStatus.playing,
        trackId: 'active-library-track',
        title: 'Cancion que esta sonando',
        artist: 'BStream Music',
      ),
    );
    libraryRepository.localTracks.add(
      LocalTrack(
        id: 'active-library-track',
        title: 'Cancion que esta sonando',
        artist: 'BStream Music',
        filePath: r'C:\Music\active.mp3',
        addedAt: DateTime(2026),
        duration: const Duration(minutes: 3, seconds: 24),
      ),
    );

    await tester.pumpWidget(
      _testApp(
        playerService: playerService,
        libraryRepository: libraryRepository,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Canciones descargadas'));
    await tester.pump(const Duration(milliseconds: 500));

    final indicator = find.byKey(
      const ValueKey('now-playing-active-library-track'),
    );
    final activeTile = find.ancestor(
      of: indicator,
      matching: find.byType(ListTile),
    );
    expect(indicator, findsOneWidget);
    expect(
      find.descendant(
        of: activeTile,
        matching: find.byIcon(Icons.pause_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: activeTile,
        matching: find.byIcon(Icons.pause_rounded),
      ),
    );
    await tester.pump();
    expect(playerService.pauseCalls, 1);
  });

  testWidgets('library route transition respects reduced motion', (
    tester,
  ) async {
    final repository = _FakeLibraryRepository();

    await tester.pumpWidget(
      _libraryPanelTestApp(repository: repository, disableAnimations: true),
    );
    await tester.pumpAndSettle();

    AnimatedSwitcher switcher() => tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey('library-route-switcher')),
    );

    expect(switcher().duration, Duration.zero);
    expect(switcher().reverseDuration, Duration.zero);
    await tester.tap(find.byKey(const ValueKey('library-downloads-entry')));
    await tester.pump();

    expect(find.byKey(const ValueKey('library-detail-header')), findsOneWidget);
    expect(switcher().duration, Duration.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('returning from player keeps the opened playlist', (
    tester,
  ) async {
    final libraryRepository = _FakeLibraryRepository();
    final navigationController = LibraryNavigationController();
    addTearDown(() => _disposeLibraryHarness(tester, navigationController));
    final track = LocalTrack(
      id: 'playlist-route-track',
      title: 'Cancion de playlist',
      artist: 'BStream Music',
      filePath: r'C:\Music\playlist.mp3',
      addedAt: DateTime(2026),
    );
    libraryRepository.localTracks.add(track);
    libraryRepository.playlists.add(
      Playlist(
        id: 'persistent-playlist',
        name: 'Playlist persistente',
        trackIds: [track.id],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );

    Widget libraryView() {
      return ProviderScope(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(_FakePlayerService()),
          playlistsControllerProvider.overrideWith(
            () => _RepositoryPlaylistsController(libraryRepository),
          ),
          catalogPlaylistsProvider.overrideWith(
            (ref) async => _testCatalogPlaylists(libraryRepository),
          ),
          catalogPlaylistProvider.overrideWith(
            (ref, playlistId) async => _testCatalogPlaylist(
              libraryRepository,
              playlistId,
              useLegacyDetailFallback: true,
            ),
          ),
          libraryRepositoryProvider.overrideWithValue(libraryRepository),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LibraryPanel(
              onOpenPlayer: () {},
              navigationController: navigationController,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(libraryView());
    await tester.pump(const Duration(milliseconds: 500));
    navigationController.openPlaylist('persistent-playlist');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('Filtrar canciones'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(libraryView());
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.text('Filtrar canciones'), findsOneWidget);
    expect(find.text('Cancion de playlist'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-track-play-playlist-route-track')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('library-track-menu-playlist-route-track')),
      findsOneWidget,
    );
  });

  testWidgets(
    'android back closes two-track selection without leaving downloads',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repository = _FakeLibraryRepository()
        ..localTracks.addAll([
          _librarySelectionTrack('selection-a', 'Cancion A'),
          _librarySelectionTrack('selection-b', 'Cancion B'),
          _librarySelectionTrack('selection-c', 'Cancion C'),
        ]);
      final navigationController = LibraryNavigationController();
      addTearDown(() => _disposeLibraryHarness(tester, navigationController));

      await tester.pumpWidget(
        _libraryPanelTestApp(
          repository: repository,
          navigationController: navigationController,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Canciones descargadas'));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.longPress(
        find.byKey(const ValueKey('library-track-selection-a')),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('library-track-selection-b')));
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.byKey(const ValueKey('library-selection-toolbar')),
        findsOneWidget,
      );
      final selectionHeader = find.byKey(
        const ValueKey('library-selection-toolbar-padding'),
      );
      final selectionHeaderRect = tester.getRect(selectionHeader);
      expect(selectionHeaderRect.left, 0);
      expect(selectionHeaderRect.right, tester.view.physicalSize.width);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('library-selection-count')))
            .data,
        '2 canciones seleccionadas',
      );
      expect(
        find.byKey(const ValueKey('selection-check-selection-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selection-check-selection-b')),
        findsOneWidget,
      );

      expect(navigationController.canPop, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-selection-toolbar')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-detail-header')),
        findsOneWidget,
      );
      expect(find.text('Canciones descargadas'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('library-track-selection-a')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('android adds two selected tracks without duplicating playlist', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final first = _librarySelectionTrack('add-a', 'Cancion A');
    final second = _librarySelectionTrack('add-b', 'Cancion B');
    final repository = _FakeLibraryRepository()
      ..localTracks.addAll([first, second])
      ..playlists.add(
        Playlist(
          id: 'destination-playlist',
          name: 'Playlist destino',
          trackIds: [first.id],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );

    await tester.pumpWidget(_libraryPanelTestApp(repository: repository));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Canciones descargadas'));
    await tester.pump(const Duration(milliseconds: 500));
    await _selectLibraryTracks(tester, ['add-a', 'add-b']);

    await tester.tap(
      find.byKey(const ValueKey('library-selection-add-to-playlist')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Elegir playlist'), findsOneWidget);
    await tester.tap(find.text('Playlist destino'));
    await tester.pumpAndSettle();

    final playlist = repository.playlists.singleWhere(
      (entry) => entry.id == 'destination-playlist',
    );
    expect(playlist.trackIds, ['add-a', 'add-b']);
    expect(playlist.trackIds.where((id) => id == 'add-a'), hasLength(1));
    expect(repository.playlists, hasLength(1));
    expect(repository.localTracks, [first, second]);
    expect(
      find.byKey(const ValueKey('library-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android removes two playlist tracks but preserves library', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final first = _librarySelectionTrack('remove-a', 'Cancion A');
    final second = _librarySelectionTrack('remove-b', 'Cancion B');
    final third = _librarySelectionTrack('remove-c', 'Cancion C');
    final repository = _FakeLibraryRepository()
      ..localTracks.addAll([first, second, third])
      ..playlists.add(
        Playlist(
          id: 'source-playlist',
          name: 'Playlist origen',
          trackIds: [first.id, second.id, third.id],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
    final navigationController = LibraryNavigationController()
      ..openPlaylist('source-playlist');
    addTearDown(() => _disposeLibraryHarness(tester, navigationController));

    await tester.pumpWidget(
      _libraryPanelTestApp(
        repository: repository,
        navigationController: navigationController,
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await _selectLibraryTracks(tester, ['remove-a', 'remove-c']);

    await tester.tap(
      find.byKey(const ValueKey('library-selection-remove-from-playlist')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((widget) => widget is AlertDialog),
      findsOneWidget,
    );
    expect(repository.localTracks, [first, second, third]);
    await tester.tap(find.widgetWithText(FilledButton, 'Quitar de playlist'));
    await tester.pumpAndSettle();

    final playlist = repository.playlists.singleWhere(
      (entry) => entry.id == 'source-playlist',
    );
    expect(playlist.trackIds, ['remove-b']);
    expect(repository.localTracks, [first, second, third]);
    expect(find.byKey(const ValueKey('library-track-remove-a')), findsNothing);
    expect(
      find.byKey(const ValueKey('library-track-remove-b')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('library-track-remove-c')), findsNothing);
    expect(
      find.byKey(const ValueKey('library-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android batch delete cleans library and preserves shared files', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    final directory = io.Directory.systemTemp.createTempSync(
      'bstream-library-selection-',
    );
    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      for (var attempt = 0; attempt < 5 && directory.existsSync(); attempt++) {
        try {
          directory.deleteSync(recursive: true);
        } on io.FileSystemException {
          if (attempt == 4) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    });
    final sharedAudio = io.File(p.join(directory.path, 'shared.m4a'));
    final sharedThumbnail = io.File(p.join(directory.path, 'shared.jpg'));
    final uniqueAudio = io.File(p.join(directory.path, 'unique.m4a'));
    final uniqueThumbnailPath = p.join(directory.path, 'unique-not-loaded.jpg');
    for (final file in [sharedAudio, uniqueAudio]) {
      file.writeAsBytesSync(const [1, 2, 3], flush: true);
    }
    sharedThumbnail.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      flush: true,
    );
    final first = _librarySelectionTrack(
      'delete-a',
      'Cancion A',
      filePath: sharedAudio.path,
      thumbnailPath: sharedThumbnail.path,
    );
    final second = _librarySelectionTrack(
      'delete-b',
      'Cancion B',
      filePath: uniqueAudio.path,
      thumbnailPath: uniqueThumbnailPath,
    );
    final survivor = _librarySelectionTrack(
      'delete-c',
      'Cancion C',
      filePath: sharedAudio.path,
      thumbnailPath: sharedThumbnail.path,
    );
    final repository = _FakeLibraryRepository()
      ..localTracks.addAll([first, second, survivor])
      ..history.addAll([first, second, survivor])
      ..playlists.addAll([
        Playlist(
          id: 'delete-playlist',
          name: 'Playlist para borrar',
          trackIds: [first.id, second.id, survivor.id],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        Playlist(
          id: Playlist.favoritesId,
          name: 'Favoritos',
          trackIds: [first.id, second.id, survivor.id],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ]);

    await tester.pumpWidget(_libraryPanelTestApp(repository: repository));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Canciones descargadas'));
    await tester.pump(const Duration(milliseconds: 500));
    await _selectLibraryTracks(tester, ['delete-a', 'delete-b']);

    await tester.tap(find.byKey(const ValueKey('library-selection-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byWidgetPredicate((widget) => widget is AlertDialog),
      findsOneWidget,
    );
    expect(repository.localTracks, [first, second, survivor]);
    expect(sharedAudio.existsSync(), isTrue);
    expect(uniqueAudio.existsSync(), isTrue);

    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    await tester.pump();
    // The delete helper deliberately waits for a frame so FileImage listeners
    // are released before Windows unlinks local artwork.
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 100 &&
          find
              .byKey(const ValueKey('library-selection-toolbar'))
              .evaluate()
              .isNotEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
    }
    await tester.pumpAndSettle();

    expect(repository.localTracks, [survivor]);
    expect(repository.history, [survivor]);
    for (final playlist in repository.playlists) {
      expect(playlist.trackIds, ['delete-c']);
    }
    expect(sharedAudio.existsSync(), isTrue);
    expect(sharedThumbnail.existsSync(), isTrue);
    expect(uniqueAudio.existsSync(), isFalse);
    expect(io.File(uniqueThumbnailPath).existsSync(), isFalse);
    expect(
      find.byKey(const ValueKey('library-track-delete-c')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('library-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('player controls fit on narrow mobile viewports', (tester) async {
    const expectedProgressColor = Color(0xFF7B8DFF);
    const selectedAccent = Color(0xFF3D8BFF);
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
        themeMode: AppThemeMode.light,
        accent: AppAccent.blue,
        surfaceBackgroundMode: SurfaceBackgroundMode.accent,
      ),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _testApp(
        settingsController: settingsController,
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion larga para probar controles',
            artist: 'BStream Music',
            trackId: 'test-track',
            thumbnailUrl: 'test-artwork.invalid',
            duration: Duration(minutes: 4),
          ),
        ),
        artworkProgressColorService: _FakeArtworkProgressColorService(
          expectedProgressColor,
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(tester.takeException(), isNull);

    final miniPlayerControl = tester.widget<IconButton>(
      find.byKey(const ValueKey('mini-player-primary-control')),
    );
    final miniPlayerContext = tester.element(find.byType(MiniPlayer));
    final miniProgressAccent = AppColors.downloadAccentFor(miniPlayerContext);
    final miniForeground = AppColors.playbackControlForegroundFor(
      miniPlayerContext,
    );
    expect(
      miniPlayerControl.style?.foregroundColor?.resolve(<WidgetState>{}),
      miniForeground,
    );
    expect(
      find.byKey(const ValueKey('mini-player-primary-gradient')),
      findsNothing,
    );
    expect(
      miniPlayerControl.style?.backgroundColor?.resolve(<WidgetState>{}),
      Colors.transparent,
    );
    expect(
      miniPlayerControl.style?.foregroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      miniForeground.withValues(alpha: 0.62),
    );
    expect(
      miniPlayerControl.style?.backgroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      Colors.transparent,
    );
    final miniProgressAnimation = tester.widget<TweenAnimationBuilder<Color?>>(
      find.byKey(const ValueKey('mini-progress-color-animation')),
    );
    final miniProgressColor = miniProgressAnimation.tween.end;
    expect(miniProgressColor, miniProgressAccent);

    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(tester.takeException(), isNull);

    expect(find.text('En reproducción'), findsOneWidget);
    final largeArtwork = tester.getSize(
      find.byKey(const ValueKey('player-large-artwork')),
    );
    expect(
      largeArtwork.width,
      greaterThan(tester.view.physicalSize.width * 0.55),
    );
    expect(largeArtwork.height, closeTo(largeArtwork.width, 0.1));
    final playerControl = tester.widget<IconButton>(
      find.byKey(const ValueKey('player-primary-control')),
    );
    final playerContext = tester.element(
      find.byKey(const ValueKey('player-primary-control')),
    );
    final playerTheme = Theme.of(playerContext);
    final playerTabTitle = tester.widget<Text>(
      find.byKey(const ValueKey('player-tab-title')),
    );
    expect(playerTabTitle.style?.color, playerTheme.colorScheme.onSurface);
    final trackTitle = tester.widget<MarqueeText>(
      find.byKey(const ValueKey('player-track-title')),
    );
    expect(trackTitle.style?.color, AppColors.playbackTitleFor(playerContext));
    expect(trackTitle.style?.color, isNot(playerTheme.colorScheme.onSurface));
    final trackArtist = tester.widget<Text>(
      find.byKey(const ValueKey('player-track-artist')),
    );
    expect(
      trackArtist.style?.color,
      AppColors.contentSubtitleFor(playerContext),
    );
    expect(
      trackArtist.style?.color,
      isNot(playerTheme.colorScheme.onSurfaceVariant),
    );
    expect(
      playerControl.color,
      AppColors.playbackControlForegroundFor(playerContext),
    );
    expect(
      playerControl.style?.backgroundColor?.resolve(<WidgetState>{}),
      Colors.transparent,
    );
    expect(
      playerControl.disabledColor,
      AppColors.playbackControlForegroundFor(
        playerContext,
      ).withValues(alpha: 0.38),
    );
    expect(
      playerControl.style?.backgroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      Colors.transparent,
    );
    final playerProgressAnimation = tester
        .widget<TweenAnimationBuilder<Color?>>(
          find.byKey(const ValueKey('player-progress-color-animation')),
        );
    final playerProgressContext = tester.element(
      find.byKey(const ValueKey('player-progress-color-animation')),
    );
    expect(
      playerProgressAnimation.tween.end,
      AppColors.downloadAccentFor(playerProgressContext),
    );
    expect(find.byTooltip('Letras'), findsOneWidget);
    expect(find.byTooltip('Volumen'), findsOneWidget);
    final lyricsControl = find.byKey(const ValueKey('player-lyrics-control'));
    final shuffleControl = find.byKey(const ValueKey('player-shuffle-control'));
    final volumeControl = find.byKey(const ValueKey('player-volume-control'));
    final repeatControl = find.byKey(const ValueKey('player-repeat-control'));
    final lyricsButton = tester.widget<TextButton>(
      find.descendant(of: lyricsControl, matching: find.byType(TextButton)),
    );
    expect(
      lyricsButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      AppColors.playbackControlForegroundFor(playerContext),
    );
    expect(
      lyricsButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      isNot(playerTheme.colorScheme.onSurface),
    );
    expect(
      tester.getCenter(lyricsControl).dx,
      lessThan(
        tester
            .getCenter(find.byKey(const ValueKey('player-primary-control')))
            .dx,
      ),
    );
    expect(
      tester.getCenter(lyricsControl).dy,
      greaterThan(tester.getCenter(shuffleControl).dy),
    );
    expect(
      tester.getSize(lyricsControl).width,
      greaterThan(tester.getSize(shuffleControl).width),
    );
    expect(
      tester.getCenter(shuffleControl).dx,
      lessThan(tester.getCenter(repeatControl).dx),
    );
    expect(
      tester.getCenter(volumeControl).dx,
      greaterThan(
        tester
            .getCenter(find.byKey(const ValueKey('player-primary-control')))
            .dx,
      ),
    );
    expect(
      tester.getCenter(volumeControl).dy,
      greaterThan(tester.getCenter(repeatControl).dy),
    );
    expect(
      tester.getSize(volumeControl).width,
      greaterThan(tester.getSize(repeatControl).width),
    );
    expect(
      find.descendant(of: lyricsControl, matching: find.text('Letras')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: volumeControl, matching: find.text('Volumen')),
      findsOneWidget,
    );
    expect(
      tester.getRect(volumeControl).bottom,
      lessThanOrEqualTo(tester.view.physicalSize.height + 0.1),
    );

    await tester.tap(find.byTooltip('Volumen'));
    await tester.pump(const Duration(milliseconds: 300));
    final popover = find.byKey(const ValueKey('volume-popover'));
    expect(popover, findsOneWidget);
    expect(
      find.ancestor(of: popover, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    final popoverContext = tester.element(popover);
    final popoverDecoration =
        tester.widget<Container>(popover).decoration! as BoxDecoration;
    final expectedPopoverGradient = AppColors.glassSurfaceGradientFor(
      popoverContext,
      baseColor: AppColors.menuBackgroundFor(popoverContext),
      intensity: 0.82,
    );
    expect(popoverDecoration.color, isNull);
    expect(
      (popoverDecoration.gradient! as LinearGradient).colors,
      expectedPopoverGradient.colors,
    );
    expect(
      (popoverDecoration.border! as Border).top.color,
      AppColors.menuBorderFor(popoverContext),
    );
    expect(popoverDecoration.boxShadow, isNull);
    final shadowDecoration =
        tester
                .widget<DecoratedBox>(
                  find.byKey(const ValueKey('volume-popover-shadow')),
                )
                .decoration
            as BoxDecoration;
    expect(shadowDecoration.boxShadow, hasLength(1));
    expect(shadowDecoration.boxShadow!.single.color.a, lessThan(0.4));
    final popoverRect = tester.getRect(popover);
    final volumeRect = tester.getRect(volumeControl);
    expect(popoverRect.width, lessThanOrEqualTo(244));
    expect(popoverRect.height, lessThanOrEqualTo(60));
    expect(popoverRect.right, closeTo(volumeRect.right - 4, 0.01));
    expect(popoverRect.center.dy, closeTo(volumeRect.center.dy, 0.01));
    expect(
      popoverRect.overlaps(
        tester.getRect(find.byKey(const ValueKey('player-primary-control'))),
      ),
      isFalse,
      reason:
          'The compact volume surface must not cover the primary transport '
          'control. popover=$popoverRect, primary=${tester.getRect(find.byKey(const ValueKey('player-primary-control')))}',
    );
    final sliderSize = tester.getSize(
      find.descendant(of: popover, matching: find.byType(Slider)),
    );
    expect(sliderSize.width, greaterThan(100));
    expect(sliderSize.height, greaterThanOrEqualTo(48));
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('volume-popover-percentage')),
        matching: find.byType(FittedBox),
      ),
      findsOneWidget,
    );

    final sliderTheme = tester.widget<SliderTheme>(
      find.descendant(of: popover, matching: find.byType(SliderTheme)),
    );
    expect(sliderTheme.data.activeTrackColor, selectedAccent);
    expect(sliderTheme.data.thumbColor, selectedAccent);
    expect(
      sliderTheme.data.overlayColor,
      selectedAccent.withValues(alpha: 0.14),
    );
    expect(
      sliderTheme.data.inactiveTrackColor,
      AppColors.menuInactiveSliderFor(popoverContext),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('transparent volume popover uses a blurred surface', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
        themeMode: AppThemeMode.light,
        accent: AppAccent.blue,
        surfaceBackgroundMode: SurfaceBackgroundMode.transparent,
      ),
    );

    await tester.pumpWidget(
      _testApp(
        settingsController: settingsController,
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion con volumen transparente',
            artist: 'BStream Music',
            trackId: 'transparent-volume-track',
            duration: Duration(minutes: 3),
            volume: 0.64,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byTooltip('Volumen'));
    await tester.pump(const Duration(milliseconds: 300));

    final popover = find.byKey(const ValueKey('volume-popover'));
    expect(popover, findsOneWidget);
    expect(
      find.ancestor(of: popover, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    final popoverContext = tester.element(popover);
    final decoration =
        tester.widget<Container>(popover).decoration! as BoxDecoration;
    expect(
      AppColors.surfaceBackgroundModeFor(popoverContext),
      SurfaceBackgroundMode.transparent,
    );
    final expectedGradient = AppColors.glassSurfaceGradientFor(
      popoverContext,
      baseColor: AppColors.menuBackgroundFor(popoverContext),
      intensity: 0.82,
    );
    final gradient = decoration.gradient! as LinearGradient;
    expect(decoration.color, isNull);
    expect(gradient.colors, expectedGradient.colors);
    expect(gradient.colors.every((color) => color.a < 0.75), isTrue);
    expect(
      (decoration.border! as Border).top.color,
      AppColors.menuBorderFor(popoverContext),
    );
    expect(
      tester
          .getSize(find.descendant(of: popover, matching: find.byType(Slider)))
          .width,
      greaterThan(100),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('lyrics control opens the synchronized lyrics page', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion con letra',
            artist: 'Artista de prueba',
            trackId: 'lyrics-track',
            sourceUrl: 'https://example.com/lyrics-track',
            position: Duration(seconds: 12),
            duration: Duration(minutes: 3),
          ),
        ),
        lyricsService: _FakeLyricsService(
          const LyricsDocument(
            provider: 'LRCLIB',
            trackName: 'Cancion con letra',
            artistName: 'Artista de prueba',
            lines: [
              LyricLine(timestamp: Duration(seconds: 10), text: 'Linea activa'),
              LyricLine(
                timestamp: Duration(seconds: 20),
                text: 'Linea siguiente',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final lyricsControl = find.byKey(const ValueKey('player-lyrics-control'));
    final lyricsButton = find.descendant(
      of: lyricsControl,
      matching: find.byType(TextButton),
    );
    await tester.ensureVisible(lyricsControl);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<TextButton>(lyricsButton).onPressed, isNotNull);
    await tester.tap(lyricsButton);
    // The synchronized lyrics page intentionally keeps an animation/ticker
    // alive while playback advances, so pumpAndSettle would never be a valid
    // completion signal here.
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find
          .byKey(const ValueKey('synced-lyrics-scroll'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

    expect(find.byKey(const ValueKey('synced-lyrics-scroll')), findsOneWidget);
    expect(find.text('Linea activa'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('active-lyric-line')),
        matching: find.text('Linea activa'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('player title heart toggles the current local track favorite', (
    tester,
  ) async {
    final repository = _FakeLibraryRepository();
    repository.localTracks.add(
      LocalTrack(
        id: 'favorite-player-track',
        title: 'Cancion favorita',
        artist: 'BStream Music',
        filePath: r'C:\Music\favorite-player-track.m4a',
        addedAt: DateTime(2026),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(
            _FakePlayerService(
              snapshot: const PlayerSnapshot(
                status: PlayerStatus.playing,
                title: 'Cancion favorita',
                artist: 'BStream Music',
                trackId: 'favorite-player-track',
                duration: Duration(minutes: 3),
              ),
            ),
          ),
          playlistsControllerProvider.overrideWith(
            () => _RepositoryPlaylistsController(repository),
          ),
          catalogPlaylistsProvider.overrideWith(
            (ref) async => _testCatalogPlaylists(repository),
          ),
          catalogPlaylistProvider.overrideWith(
            (ref, playlistId) async => _testCatalogPlaylist(
              repository,
              playlistId,
              useLegacyDetailFallback: true,
            ),
          ),
          libraryRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ExcludeSemantics(child: PlayerPanel())),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final favoriteControl = find.byKey(
      const ValueKey('player-favorite-control'),
    );
    expect(favoriteControl, findsOneWidget);
    expect(
      find.descendant(
        of: favoriteControl,
        matching: find.byIcon(Icons.favorite_border_rounded),
      ),
      findsOneWidget,
    );
    expect(
      tester.getCenter(favoriteControl).dx,
      greaterThan(
        tester.getCenter(find.byKey(const ValueKey('player-track-title'))).dx,
      ),
    );

    await tester.tap(favoriteControl);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      repository.playlists.last.trackIds,
      contains('favorite-player-track'),
    );
    final filledHeart = tester.widget<Icon>(
      find.descendant(
        of: favoriteControl,
        matching: find.byIcon(Icons.favorite_rounded),
      ),
    );
    final favoriteButton = tester.widget<IconButton>(favoriteControl);
    expect(
      favoriteButton.color,
      Theme.of(tester.element(favoriteControl)).colorScheme.primary,
    );
    expect(filledHeart.icon, Icons.favorite_rounded);

    await tester.tap(favoriteControl);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      repository.playlists.last.trackIds,
      isNot(contains('favorite-player-track')),
    );
  });

  testWidgets(
    'windows desktop player stacks artwork and exposes volume control',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const title = 'Cancion de escritorio para probar layout';

      await tester.pumpWidget(
        _testApp(
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: title,
              artist: 'BStream Music',
              trackId: 'desktop-track',
              duration: Duration(minutes: 4, seconds: 11),
              volume: 0.72,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final artwork = find.byIcon(Icons.music_note_rounded);
      final titleText = find.byKey(const ValueKey('player-track-title'));

      expect(find.text('En reproducción'), findsOneWidget);
      expect(artwork, findsOneWidget);
      expect(titleText, findsOneWidget);
      expect(
        tester.getBottomLeft(artwork).dy,
        lessThan(tester.getTopLeft(titleText).dy),
      );
      expect(find.byTooltip('Volumen'), findsOneWidget);
      expect(find.byTooltip('Cola de reproducción'), findsOneWidget);
      final lyricsControl = find.byKey(const ValueKey('player-lyrics-control'));
      expect(
        find.descendant(of: lyricsControl, matching: find.byTooltip('Letras')),
        findsOneWidget,
      );
      final shuffleControl = find.byKey(
        const ValueKey('player-shuffle-control'),
      );
      final volumeControl = find.byKey(const ValueKey('player-volume-control'));
      final repeatControl = find.byKey(const ValueKey('player-repeat-control'));
      expect(
        tester.getCenter(lyricsControl).dx,
        lessThan(tester.getCenter(shuffleControl).dx),
      );
      expect(
        tester.getCenter(volumeControl).dx,
        greaterThan(tester.getCenter(repeatControl).dx),
      );
      expect(
        tester.getCenter(lyricsControl).dy,
        closeTo(tester.getCenter(shuffleControl).dy, 0.1),
      );
      expect(
        tester.getCenter(volumeControl).dy,
        closeTo(tester.getCenter(repeatControl).dy, 0.1),
      );

      await tester.tap(find.byTooltip('Cola de reproducción'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 340));
      await tester.pump();
      expect(find.text('No hay canciones en la cola actual.'), findsOneWidget);

      await tester.tap(find.byTooltip('Cola de reproducción'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 340));
      await tester.pump();
      expect(find.text('No hay canciones en la cola actual.'), findsNothing);

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Control de Volumen'), findsNothing);
      Navigator.of(
        tester.element(find.byType(PopupMenuItem<String>).first),
      ).pop();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('Volumen'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('volume-popover')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('volume-popover')),
          matching: find.byType(Slider),
        ),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'desktop playback queue fits minimum window and changes selected song',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 600);
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final player = _FakePlayerService(
        snapshot: const PlayerSnapshot(
          status: PlayerStatus.playing,
          title: 'Primera cancion',
          artist: 'BStream Music',
          trackId: 'desktop-queue-1',
          duration: Duration(minutes: 3),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(player),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
          localTrackFileProbeProvider.overrideWithValue(
            (_) async => LocalTrackFileAvailability.present,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(playerControllerProvider.future);

      final tracks = [
        LocalTrack(
          id: 'desktop-queue-1',
          title: 'Primera cancion',
          artist: 'BStream Music',
          filePath: r'C:\Music\desktop-queue-1.m4a',
          addedAt: DateTime(2026),
        ),
        LocalTrack(
          id: 'desktop-queue-2',
          title: 'Segunda cancion',
          artist: 'BStream Music',
          filePath: r'C:\Music\desktop-queue-2.m4a',
          addedAt: DateTime(2026),
        ),
      ];
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(tracks.first, queue: tracks, useNativeQueue: false);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ExcludeSemantics(child: PlayerPanel())),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byTooltip('Cola de reproducción'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 340));
      await tester.pump();
      expect(find.text('Cola de Reproducción - 2 Canciones'), findsOneWidget);
      expect(find.text('Primera cancion'), findsWidgets);
      expect(find.text('Segunda cancion'), findsOneWidget);
      final playerSurface = tester.getRect(
        find.byKey(const ValueKey('desktop-player-surface')),
      );
      final queueRail = tester.getRect(
        find.byKey(const ValueKey('desktop-playback-queue-rail')),
      );
      expect(queueRail.left, playerSurface.right);
      expect(queueRail.width, closeTo(352, 0.1));
      expect(queueRail.top, 0);
      expect(queueRail.bottom, 600);
      expect(
        tester.getRect(find.byTooltip('Pausar')).bottom,
        lessThanOrEqualTo(600),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Segunda cancion'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.playedLocalIds.last, 'desktop-queue-2');
      expect(container.read(playbackQueueProvider).currentIndex, 1);
      debugDefaultTargetPlatformOverride = null;
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'player controls resize through intermediate widths without overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(520, 720);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        _testApp(
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: 'Cancion para redimensionar controles',
              artist: 'BStream Music',
              trackId: 'resize-track',
              duration: Duration(minutes: 3, seconds: 47),
              volume: 0.8,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
      );
      await tester.pump(const Duration(milliseconds: 500));

      tester.view.physicalSize = const Size(839, 720);
      await tester.pump(const Duration(milliseconds: 200));

      final playerPanel = find.byType(PlayerPanel);
      final title = find.byKey(const ValueKey('player-track-title'));
      final track = find.byKey(
        const ValueKey('player-progress-color-animation'),
      );
      final artwork = find.byKey(const ValueKey('player-large-artwork'));
      final retainedPlayerPanel = tester.element(playerPanel);
      final retainedTitle = tester.element(title);
      final retainedTrack = tester.element(track);
      final retainedArtwork = tester.element(artwork);
      final artworkAt839 = tester.getSize(artwork);

      expect(
        find.byKey(const ValueKey('player-content-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-previous-control')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-primary-control')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-next-control')), findsOneWidget);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(840, 720);
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        identical(retainedPlayerPanel, tester.element(playerPanel)),
        isTrue,
      );
      expect(identical(retainedTitle, tester.element(title)), isTrue);
      expect(identical(retainedTrack, tester.element(track)), isTrue);
      expect(identical(retainedArtwork, tester.element(artwork)), isTrue);
      expect(tester.getSize(artwork).width, lessThan(artworkAt839.width));
      expect(
        find.byKey(const ValueKey('player-content-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-previous-control')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-primary-control')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-next-control')), findsOneWidget);
      expect(tester.takeException(), isNull);

      for (final width in const [
        900.0,
        1280.0,
        500.0,
        460.0,
        430.0,
        390.0,
        520.0,
      ]) {
        tester.view.physicalSize = Size(width, 720);
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          identical(retainedPlayerPanel, tester.element(playerPanel)),
          isTrue,
        );
        expect(title, findsOneWidget);
        expect(track, findsOneWidget);
        expect(artwork, findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'El reproductor no debe desbordar a ${width.toInt()} px.',
        );
      }
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'desktop Space toggles mini and full player without stealing focused input',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view
        ..physicalSize = const Size(1280, 720)
        ..devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });

      final playerService = _FakePlayerService(
        snapshot: const PlayerSnapshot(
          status: PlayerStatus.playing,
          title: 'Atajo de escritorio',
          artist: 'BStream Music',
          trackId: 'desktop-space-shortcut',
          duration: Duration(minutes: 3),
        ),
      );
      await tester.pumpWidget(_testApp(playerService: playerService));
      await tester.pump(const Duration(milliseconds: 500));

      final shortcut = find.byKey(
        const ValueKey('desktop-playback-keyboard-shortcut'),
      );
      expect(shortcut, findsOneWidget);
      expect(tester.widget<Focus>(shortcut).includeSemantics, isFalse);
      expect(tester.widget<Focus>(shortcut).focusNode?.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(playerService.togglePlayPauseCalls, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(playerService.togglePlayPauseCalls, 1);

      await tester.tap(find.byKey(const ValueKey('mini-player-volume-slider')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(playerService.togglePlayPauseCalls, 1);

      await tester.tap(find.byKey(const ValueKey('side-navigation-item-3')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PlayerPanel), findsOneWidget);
      expect(tester.widget<Focus>(shortcut).focusNode?.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(playerService.togglePlayPauseCalls, 2);

      await tester.tap(find.byKey(const ValueKey('side-navigation-item-1')));
      await tester.pump(const Duration(milliseconds: 500));
      final searchField = find.byType(TextField);
      expect(searchField, findsOneWidget);
      await tester.tap(searchField);
      await tester.enterText(searchField, 'consulta');
      await tester.pump();
      final editableText = tester.widget<EditableText>(
        find.descendant(of: searchField, matching: find.byType(EditableText)),
      );
      expect(editableText.focusNode.hasFocus, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space, character: ' ');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(playerService.togglePlayPauseCalls, 2);
      expect(editableText.controller.text, 'consulta');
      expect(editableText.focusNode.hasFocus, isTrue);

      await tester.tap(find.byKey(const ValueKey('side-navigation-item-3')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(editableText.focusNode.hasFocus, isFalse);
      expect(tester.widget<Focus>(shortcut).focusNode?.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(playerService.togglePlayPauseCalls, 3);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('library keeps only the header action for creating playlists', (
    tester,
  ) async {
    final libraryRepository = _FakeLibraryRepository();
    libraryRepository.playlists.add(
      Playlist(
        id: 'test-playlist-height',
        name: 'Playlist de prueba',
        trackIds: const [],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );

    await tester.pumpWidget(_testApp(libraryRepository: libraryRepository));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 500));

    final downloadsEntry = find.byKey(
      const ValueKey('library-downloads-entry'),
    );
    final createPlaylistButton = find.byKey(
      const ValueKey('library-create-playlist-button'),
    );
    final playlistEntry = find.byKey(
      const ValueKey('library-playlist-test-playlist-height'),
    );

    expect(downloadsEntry, findsOneWidget);
    expect(createPlaylistButton, findsOneWidget);
    expect(find.byKey(const ValueKey('create-playlist')), findsNothing);
    expect(find.text('Crear playlist'), findsNothing);
    expect(playlistEntry, findsOneWidget);

    final downloadsHeight = tester.getSize(downloadsEntry).height;
    final playlistHeight = tester.getSize(playlistEntry).height;

    expect(downloadsHeight, playlistHeight);
    expect(downloadsHeight, greaterThanOrEqualTo(56));
    expect(downloadsHeight, lessThanOrEqualTo(72));
  });

  testWidgets('cancelling create playlist dialog returns to library safely', (
    tester,
  ) async {
    await _pumpTestApp(tester);

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(
      find.byKey(const ValueKey('library-create-playlist-button')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Nueva playlist'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Biblioteca'), findsWidgets);
    expect(find.text('Nueva playlist'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back closes create playlist dialog safely', (
    tester,
  ) async {
    await _pumpTestApp(tester);

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(
      find.byKey(const ValueKey('library-create-playlist-button')),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Nueva playlist'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Biblioteca'), findsWidgets);
    expect(find.text('Nueva playlist'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpTestApp(WidgetTester tester) {
  return tester.pumpWidget(_testApp());
}

void _noop() {}

void _configureMobileHomeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void _expectLocalOnlyHome(WidgetTester tester) {
  expect(
    find.byWidgetPredicate((widget) {
      final key = widget.key;
      if (key is! ValueKey<String>) {
        return false;
      }
      return key.value.startsWith('home-recommendation-') ||
          key.value.startsWith('home-recommendations-section-') ||
          key.value.startsWith('home-recommendations-shelf-') ||
          key.value.startsWith('home-collection-');
    }),
    findsNothing,
  );
  expect(find.text('Cancion reciente'), findsOneWidget);
  expect(find.text('Mis playlists'), findsNothing);
  expect(find.byKey(const ValueKey('home-recent-card')), findsOneWidget);
  expect(find.byKey(const ValueKey('home-playlist-card')), findsNothing);
}

LocalTrack _librarySelectionTrack(
  String id,
  String title, {
  String? filePath,
  String? thumbnailPath,
}) {
  return LocalTrack(
    id: id,
    title: title,
    artist: 'BStream Music',
    filePath: filePath ?? p.join(io.Directory.systemTemp.path, '$id.m4a'),
    thumbnailPath: thumbnailPath,
    addedAt: DateTime(2026),
    duration: const Duration(minutes: 3),
  );
}

Future<void> _selectLibraryTracks(
  WidgetTester tester,
  List<String> trackIds,
) async {
  assert(trackIds.isNotEmpty);
  await tester.longPress(
    find.byKey(ValueKey('library-track-${trackIds.first}')),
  );
  await tester.pump(const Duration(milliseconds: 250));
  for (final trackId in trackIds.skip(1)) {
    await tester.tap(find.byKey(ValueKey('library-track-$trackId')));
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _disposeLibraryHarness(
  WidgetTester tester,
  LibraryNavigationController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  controller.dispose();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  int maxPumps = 20,
  Duration interval = const Duration(milliseconds: 50),
}) async {
  for (var pump = 0; pump < maxPumps; pump++) {
    await tester.pump(interval);
    if (condition()) return;
  }
  fail('Timed out waiting for $reason.');
}

Widget _libraryPanelTestApp({
  required _FakeLibraryRepository repository,
  LibraryNavigationController? navigationController,
  VoidCallback? onOpenPlayer,
  bool disableAnimations = false,
}) {
  final panel = Scaffold(
    body: LibraryPanel(
      onOpenPlayer: onOpenPlayer ?? _noop,
      navigationController: navigationController,
    ),
  );
  return ProviderScope(
    overrides: [
      downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
      playerServiceProvider.overrideWithValue(_FakePlayerService()),
      playlistsControllerProvider.overrideWith(
        () => _RepositoryPlaylistsController(repository),
      ),
      catalogPlaylistsProvider.overrideWith(
        (ref) async => _testCatalogPlaylists(repository),
      ),
      catalogPlaylistProvider.overrideWith(
        (ref, playlistId) async => _testCatalogPlaylist(
          repository,
          playlistId,
          useLegacyDetailFallback: true,
        ),
      ),
      libraryRepositoryProvider.overrideWithValue(repository),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: navigationController == null
          ? panel
          : PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) {
                  navigationController.maybePop();
                }
              },
              child: panel,
            ),
    ),
  );
}

_FakeLibraryRepository _homeCardsRepository({String? thumbnailUrl}) {
  final repository = _FakeLibraryRepository();
  final track = LocalTrack(
    id: 'home-card-track',
    title: 'Cancion reciente',
    artist: 'BStream Music',
    filePath: r'C:\Music\home-card-track.mp3',
    thumbnailUrl: thumbnailUrl,
    addedAt: DateTime(2026),
  );
  repository.history.add(track);
  repository.localTracks.add(track);
  repository.playlists.add(
    Playlist(
      id: 'home-card-playlist',
      name: 'Playlist de Inicio',
      trackIds: [track.id],
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  );
  return repository;
}

Widget _settingsTestApp({
  required _FakeSettingsController settingsController,
  required DownloadDirectoryPicker directoryPicker,
  SettingsExternalLauncher? externalLauncher,
  TargetPlatform platform = TargetPlatform.windows,
}) {
  return ProviderScope(
    overrides: [
      settingsControllerProvider.overrideWith(() => settingsController),
      downloadDirectoryPickerProvider.overrideWithValue(directoryPicker),
      if (externalLauncher != null)
        settingsExternalLauncherProvider.overrideWithValue(externalLauncher),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: platform),
      home: const Scaffold(body: SettingsPanel()),
    ),
  );
}

Widget _testApp({
  SettingsController? settingsController,
  PlayerService? playerService,
  PlayerController? playerController,
  LibraryRepository? libraryRepository,
  LyricsService? lyricsService,
  ArtworkProgressColorService? artworkProgressColorService,
  DownloadDirectoryPicker? directoryPicker,
  FutureOr<List<HomeRecommendationSection>>? homeRecommendations,
  Object? homeRecommendationsError,
  FutureOr<List<HomeRecommendationSection>> Function()?
  homeRecommendationsLoader,
  Future<List<TrackInfo>> Function(String browseId)? homeCollectionLoader,
  Future<RemoteCollectionData> Function(String browseId)?
  homeCollectionDetailLoader,
  PersonalizedHomeFeedSource? personalizedHomeFeedSource,
  IncomingTrackLinkService? incomingTrackLinkService,
  YouTubeMusicSearch? youtubeMusicSearch,
  YouTubeMusicAuthState? youtubeMusicAuthState,
  DateTime? homeGreetingTime,
  List<CatalogPlaylist>? catalogPlaylists,
  Stream<ExternalAudioRequest>? externalAudioRequests,
  Stream<AndroidAppActivationEvent>? androidAppActivations,
  Widget? testHome,
}) {
  final resolvedLibraryRepository =
      libraryRepository ?? _FakeLibraryRepository();
  final testCatalogRepository =
      resolvedLibraryRepository is _FakeLibraryRepository
      ? resolvedLibraryRepository
      : null;
  return ProviderScope(
    overrides: [
      homeGreetingClockProvider.overrideWithValue(
        () => homeGreetingTime ?? DateTime(2026, 8, 24, 9),
      ),
      if (externalAudioRequests != null)
        androidExternalAudioRequestsProvider.overrideWithValue(
          externalAudioRequests,
        ),
      if (androidAppActivations != null)
        androidAppActivationsProvider.overrideWithValue(androidAppActivations),
      if (settingsController != null)
        settingsControllerProvider.overrideWith(() => settingsController),
      downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
      desktopMediaSessionFactoryProvider.overrideWithValue(() => null),
      playerServiceProvider.overrideWithValue(
        playerService ?? _FakePlayerService(),
      ),
      if (playerController != null)
        playerControllerProvider.overrideWith(() => playerController),
      if (youtubeMusicAuthState != null)
        youtubeMusicAuthControllerProvider.overrideWith(
          () => _StaticYouTubeMusicAuthController(youtubeMusicAuthState),
        ),
      if (youtubeMusicAuthState != null)
        youtubeMusicPlaylistSyncControllerProvider.overrideWith(
          _IdleYouTubeMusicPlaylistSyncController.new,
        ),
      personalizedHomeFeedSourceProvider.overrideWithValue(
        personalizedHomeFeedSource,
      ),
      homeArtistRecommendationSourceProvider.overrideWithValue(null),
      youtubeMusicHomeRecommendationsProvider.overrideWith((ref) {
        final loader = homeRecommendationsLoader;
        if (loader != null) {
          return loader();
        }
        final error = homeRecommendationsError;
        if (error != null) {
          throw error;
        }
        return homeRecommendations ?? const <HomeRecommendationSection>[];
      }),
      if (homeCollectionLoader != null)
        homeCollectionTracksProvider.overrideWith(
          (ref, browseId) => homeCollectionLoader(browseId),
        ),
      if (homeCollectionDetailLoader != null)
        homeCollectionDetailProvider.overrideWith(
          (ref, browseId) => homeCollectionDetailLoader(browseId),
        )
      else if (homeCollectionLoader != null)
        homeCollectionDetailProvider.overrideWith((ref, browseId) async {
          final tracks = await homeCollectionLoader(browseId);
          return RemoteCollectionData(tracks: tracks);
        }),
      if (lyricsService != null)
        lyricsServiceProvider.overrideWithValue(lyricsService),
      if (artworkProgressColorService != null)
        artworkProgressColorServiceProvider.overrideWithValue(
          artworkProgressColorService,
        ),
      if (directoryPicker != null)
        downloadDirectoryPickerProvider.overrideWithValue(directoryPicker),
      incomingTrackLinkServiceProvider.overrideWithValue(
        incomingTrackLinkService ?? const _EmptyIncomingTrackLinkService(),
      ),
      if (youtubeMusicSearch != null)
        youtubeMusicSearchProvider.overrideWithValue(youtubeMusicSearch),
      if (testCatalogRepository != null)
        playlistsControllerProvider.overrideWith(
          () => _RepositoryPlaylistsController(testCatalogRepository),
        ),
      if (testCatalogRepository != null)
        catalogPlaylistsProvider.overrideWith(
          (ref) async => _testCatalogPlaylists(
            testCatalogRepository,
            additionalCatalogs: catalogPlaylists,
          ),
        )
      else if (catalogPlaylists != null)
        catalogPlaylistsProvider.overrideWith((ref) async => catalogPlaylists),
      if (testCatalogRepository != null)
        catalogPlaylistProvider.overrideWith(
          (ref, playlistId) async => _testCatalogPlaylist(
            testCatalogRepository,
            playlistId,
            additionalCatalogs: catalogPlaylists,
            useLegacyDetailFallback: true,
          ),
        )
      else if (catalogPlaylists != null)
        catalogPlaylistProvider.overrideWith(
          (ref, playlistId) async => catalogPlaylists
              .where((catalog) => catalog.playlist.id == playlistId)
              .firstOrNull,
        ),
      libraryRepositoryProvider.overrideWithValue(resolvedLibraryRepository),
    ],
    child: testHome == null
        ? const BStreamMusicApp()
        : MaterialApp(
            theme: ThemeData(
              useMaterial3: true,
              platform: TargetPlatform.android,
              extensions: const [AppAccentTheme(accent: AppAccent.green)],
            ),
            home: testHome,
          ),
  );
}

class _ArtistPortraitSearch
    implements YouTubeMusicSearch, YouTubeMusicArtistProfileLookup {
  static const portraitUrl =
      'https://example.invalid/resolved-artist-portrait.jpg';

  int profileCalls = 0;

  @override
  Future<InnerTubeArtistProfile> getArtistProfile(
    String artistBrowseId, {
    String? fallbackName,
    String? fallbackThumbnailUrl,
    int songLimit = 20,
    int releaseLimit = 20,
  }) async {
    profileCalls++;
    return InnerTubeArtistProfile(
      artist: InnerTubeArtist(
        browseId: artistBrowseId,
        name: fallbackName ?? 'Artista',
        thumbnailUrl: portraitUrl,
      ),
      popularSongs: const [],
      albums: const [],
      singles: const [],
    );
  }

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async => const [];
}

class _StaticYouTubeMusicAuthController extends YouTubeMusicAuthController {
  _StaticYouTubeMusicAuthController(this.fixedState);

  final YouTubeMusicAuthState fixedState;

  @override
  YouTubeMusicAuthState build() => fixedState;
}

class _IdleYouTubeMusicPlaylistSyncController
    extends YouTubeMusicPlaylistSyncController {
  @override
  YouTubeMusicPlaylistSyncState build() =>
      const YouTubeMusicPlaylistSyncState();
}

class _FakeSettingsController extends SettingsController {
  _FakeSettingsController(this.initialState);

  final SettingsState initialState;
  final List<String> savedDirectories = [];

  @override
  Future<SettingsState> build() async => initialState;

  @override
  Future<void> setDownloadDirectory(String path) async {
    savedDirectories.add(path);
    final current = await future;
    state = AsyncData(current.copyWith(downloadDirectory: path));
  }
}

class _FakeSearchController extends SearchController {
  _FakeSearchController(this.tracks);

  final List<TrackInfo> tracks;

  @override
  Future<SearchState> build() async => SearchState(
    query: 'resultados',
    pages: <SearchCategory, SearchPage>{
      SearchCategory.songs: SearchPage(
        category: SearchCategory.songs,
        backend: SearchBackend.innerTube,
        tracks: tracks,
      ),
    },
  );
}

class _FakeDownloaderService implements DownloaderService {
  _FakeDownloaderService({
    this.emitCompletedBeforeResult = false,
    this.resultDelay = Duration.zero,
  });

  final bool emitCompletedBeforeResult;
  final Duration resultDelay;
  final _progressController = StreamController<DownloadProgress>.broadcast();

  @override
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  @override
  Future<DownloadResult> downloadAudio(
    String url,
    DownloadOptions options,
  ) async {
    if (emitCompletedBeforeResult) {
      _progressController.add(
        DownloadProgress(
          taskId: url,
          url: url,
          status: DownloadProgressStatus.completed,
          progress: 1,
        ),
      );
    }
    if (resultDelay > Duration.zero) {
      await Future<void>.delayed(resultDelay);
    }

    final id = url.split('/').last;
    final fileName = '${options.fileName ?? id}.m4a';
    final file = io.File(p.join(options.outputDirectory, fileName));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(const [1, 2, 3], flush: true);
    return DownloadResult(
      id: 'downloaded-$id',
      sourceUrl: url,
      filePath: file.path,
      fileName: fileName,
      mediaType: DownloadMediaType.audio,
      completedAt: DateTime(2026),
    );
  }

  @override
  Future<TrackInfo> getInfo(String url) {
    throw UnimplementedError();
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) {
    throw UnimplementedError();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TrackInfo>> search(String query) async {
    return const [];
  }
}

class _FakeLyricsService implements LyricsService {
  const _FakeLyricsService(this.document);

  final LyricsDocument? document;

  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) async => document;

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

class _FakeArtworkProgressColorService extends ArtworkProgressColorService {
  _FakeArtworkProgressColorService(this.color);

  final Color color;

  @override
  Future<Color> resolve(String? rawSource) async => color;
}

class _ControllableLocalTrackDownloadHelper extends LocalTrackDownloadHelper {
  _ControllableLocalTrackDownloadHelper(super.ref, this.downloader);

  final _ControllableDownloaderService downloader;

  @override
  Future<LocalTrackDownloadResult> resolveForLibrary(
    TrackInfo track, {
    String? taskId,
    void Function(TrackInfo track)? onResolved,
    void Function()? onDownloadStarted,
    bool allowConcurrentDownload = false,
  }) async {
    onResolved?.call(track);
    onDownloadStarted?.call();
    final result = await downloader.downloadAudio(
      track.url,
      DownloadOptions(
        outputDirectory: io.Directory.systemTemp.path,
        fileName: 'progress-track',
        taskId: taskId,
      ),
    );
    final localTrack = LocalTrack(
      id: 'progress-track',
      title: track.title,
      artist: track.artist,
      filePath: result.filePath,
      addedAt: result.completedAt,
      sourceUrl: track.url,
      duration: track.duration,
    );
    return LocalTrackDownloadResult(
      track: localTrack,
      remoteTrack: track,
      reusedExisting: false,
      downloadResult: result,
    );
  }
}

class _ControllableDownloaderService implements DownloaderService {
  final _progressController = StreamController<DownloadProgress>.broadcast();
  final _completion = Completer<DownloadResult>();
  final started = Completer<void>();

  String? _url;
  DownloadOptions? _options;

  @override
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    _url = url;
    _options = options;
    if (!started.isCompleted) {
      started.complete();
    }
    return _completion.future;
  }

  void emitProgress({
    required String taskId,
    required double progress,
    String? url,
  }) {
    _progressController.add(
      DownloadProgress(
        taskId: taskId,
        url: url ?? _url ?? '',
        status: DownloadProgressStatus.running,
        progress: progress,
      ),
    );
  }

  void complete() {
    if (_completion.isCompleted) {
      return;
    }
    final url = _url!;
    final options = _options!;
    final fileName = '${options.fileName ?? 'track'}.m4a';
    final file = io.File(p.join(options.outputDirectory, fileName));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(const [1, 2, 3], flush: true);
    _completion.complete(
      DownloadResult(
        id: 'completed-progress-track',
        sourceUrl: url,
        filePath: file.path,
        fileName: fileName,
        mediaType: DownloadMediaType.audio,
        completedAt: DateTime(2026),
      ),
    );
  }

  Future<void> close() async {
    if (_url != null && _options != null) {
      complete();
    }
    await _progressController.close();
  }

  @override
  Future<TrackInfo> getInfo(String url) {
    throw UnimplementedError();
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) {
    throw UnimplementedError();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TrackInfo>> search(String query) async => const [];
}

class _FakePlayerService implements PlayerService {
  _FakePlayerService({
    this.snapshot = const PlayerSnapshot(status: PlayerStatus.idle),
  });

  final _snapshotController = StreamController<PlayerSnapshot>.broadcast();
  final PlayerSnapshot snapshot;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int togglePlayPauseCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  final List<String> playedLocalIds = [];

  @override
  PlayerSnapshot get currentSnapshot => snapshot;

  @override
  bool get supportsLocalQueueReplacement => false;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _snapshotController.close();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    playedLocalIds.add(track.id);
  }

  @override
  Future<void> playLocalQueue(
    List<LocalTrack> tracks,
    int initialIndex,
  ) async {}

  @override
  Future<void> playRemote(track) async {}

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {}

  @override
  Future<void> resume() async {
    resumeCalls++;
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setShuffleEnabled(bool enabled) async {}

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {}

  @override
  Future<void> togglePlayPause() async {
    togglePlayPauseCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _RecordingHomePlayerController extends PlayerController {
  int remotePlayCalls = 0;
  int historyPlayCalls = 0;
  int localPlayCalls = 0;
  TrackInfo? lastRemoteTrack;
  List<TrackInfo>? lastRemoteQueue;
  String? lastRemoteQueueSourceId;
  LocalTrack? lastHistoryTrack;
  List<LocalTrack>? lastHistoryQueue;
  LocalTrack? lastLocalTrack;
  List<LocalTrack>? lastLocalQueue;
  String? lastLocalQueueSourceId;
  List<RecommendationPlaybackItem>? lastRecommendationQueue;
  String? lastRecommendationQueueSourceId;
  int recommendationSyncCalls = 0;
  List<RecommendationPlaybackItem>? lastSyncedRecommendationQueue;

  @override
  Future<PlayerSnapshot> build() async {
    return const PlayerSnapshot(status: PlayerStatus.idle);
  }

  @override
  Future<void> playRemote(
    TrackInfo track, {
    List<TrackInfo>? queue,
    String? queueSourceId,
  }) async {
    remotePlayCalls++;
    lastRemoteTrack = track;
    lastRemoteQueue = queue == null ? null : List.unmodifiable(queue);
    lastRemoteQueueSourceId = queueSourceId;
    state = AsyncData(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.url,
        duration: track.duration,
        isRemote: true,
      ),
    );
  }

  @override
  bool enrichCurrentRemoteTrackMetadata(TrackInfo metadata) {
    final current = lastRemoteTrack;
    if (current == null ||
        (current.id != metadata.id && current.url != metadata.url)) {
      return false;
    }
    lastRemoteTrack = metadata;
    state = AsyncData(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album,
        trackId: metadata.id,
        sourceUrl: metadata.url,
        thumbnailUrl: metadata.thumbnailUrl,
        duration: metadata.duration,
        isRemote: true,
      ),
    );
    return true;
  }

  @override
  Future<void> playLocal(
    LocalTrack track, {
    List<LocalTrack>? queue,
    bool useNativeQueue = true,
    String? queueSourceId,
  }) async {
    localPlayCalls++;
    lastLocalTrack = track;
    lastLocalQueue = queue == null ? null : List.unmodifiable(queue);
    lastLocalQueueSourceId = queueSourceId;
    state = AsyncData(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.filePath,
        duration: track.duration,
      ),
    );
  }

  @override
  Future<void> playRecommendation(
    RecommendationPlaybackItem selected, {
    required List<RecommendationPlaybackItem> queue,
    String? queueSourceId,
    RecommendationQueueExtender? queueExtender,
  }) async {
    lastRecommendationQueue = List.unmodifiable(queue);
    lastRecommendationQueueSourceId = queueSourceId;
    final local = selected.localTrack;
    if (local != null) {
      await playLocal(
        local,
        queue: queue
            .map((item) => item.localTrack)
            .whereType<LocalTrack>()
            .toList(),
        useNativeQueue: false,
        queueSourceId: queueSourceId,
      );
    } else {
      await playRemote(
        selected.track,
        queue: queue.map((item) => item.track).toList(growable: false),
        queueSourceId: queueSourceId,
      );
    }
    if (queueExtender != null) {
      final expanded = await queueExtender();
      if (expanded.length > queue.length) {
        await syncRecommendationQueueSource(queueSourceId ?? '', expanded);
      }
    }
  }

  @override
  Future<bool> syncRecommendationQueueSource(
    String sourceId,
    List<RecommendationPlaybackItem> items,
  ) async {
    recommendationSyncCalls++;
    lastSyncedRecommendationQueue = List.unmodifiable(items);
    return true;
  }

  @override
  Future<void> playFromHistory(
    LocalTrack track, {
    List<LocalTrack>? fallbackQueue,
  }) async {
    historyPlayCalls++;
    lastHistoryTrack = track;
    lastHistoryQueue = fallbackQueue == null
        ? null
        : List.unmodifiable(fallbackQueue);
    state = AsyncData(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.filePath,
        duration: track.duration,
      ),
    );
  }
}

class _StaticPersonalizedHomeFeedSource implements PersonalizedHomeFeedSource {
  const _StaticPersonalizedHomeFeedSource(this.feed);

  final PersonalizedRecommendationFeed feed;

  @override
  Future<CachedPersonalizedRecommendationFeed?> loadCachedFeed() async {
    return CachedPersonalizedRecommendationFeed(feed: feed, isExpired: false);
  }

  @override
  Future<PersonalizedRecommendationFeed> refresh({
    bool forceNetwork = false,
  }) async {
    return feed;
  }
}

final class _FakeIncomingTrackLinkService implements IncomingTrackLinkService {
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  @override
  Stream<Uri> get links => _controller.stream;

  void add(Uri uri) => _controller.add(uri);

  Future<void> close() => _controller.close();
}

final class _EmptyIncomingTrackLinkService implements IncomingTrackLinkService {
  const _EmptyIncomingTrackLinkService();

  @override
  Stream<Uri> get links => const Stream<Uri>.empty();
}

final class _FakeYouTubeMusicTrackLookup
    implements YouTubeMusicSearch, YouTubeMusicTrackLookup {
  final List<String> requestedVideoIds = <String>[];

  @override
  Future<InnerTubeSong?> getSong(String videoId) async {
    requestedVideoIds.add(videoId);
    return InnerTubeSong(
      videoId: videoId,
      title: 'Never Gonna Give You Up',
      artists: const ['Rick Astley'],
      album: 'Whenever You Need Somebody',
      duration: const Duration(minutes: 3),
      thumbnailUrl: 'https://img.test/rick-astley.jpg',
    );
  }

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async => const <InnerTubeSong>[];
}

final class _FakeRecommendationRelatedSearch
    implements YouTubeMusicSearch, YouTubeMusicRelated {
  final List<String> nextVideoIds = <String>[];

  @override
  Future<InnerTubeNextPage> getNext(
    String videoId, {
    bool radio = false,
    int limit = innerTubeDetailResultLimit,
  }) async {
    nextVideoIds.add(videoId);
    return InnerTubeNextPage(
      songs: [
        InnerTubeSong(
          videoId: videoId,
          title: 'Semilla',
          artists: const ['Artista'],
        ),
        InnerTubeSong(
          videoId: 'NextSong001',
          title: 'Siguiente',
          artists: const ['Otro artista'],
        ),
      ],
    );
  }

  @override
  Future<InnerTubeNextPage> getNextContinuation(
    String continuation, {
    int limit = innerTubeDetailResultLimit,
  }) async => InnerTubeNextPage(songs: const []);

  @override
  Future<InnerTubeRelatedPage> getRelated(
    String browseId, {
    int limit = 20,
  }) async => InnerTubeRelatedPage(
    songs: const [],
    albums: const [],
    artists: const [],
    collections: const [],
  );

  @override
  Future<InnerTubeRelatedPage> getRelatedContinuation(
    String continuation, {
    int limit = 20,
  }) async => InnerTubeRelatedPage(
    songs: const [],
    albums: const [],
    artists: const [],
    collections: const [],
  );

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async => const [];
}

final class _StalledYouTubeMusicTrackLookup
    implements YouTubeMusicSearch, YouTubeMusicTrackLookup {
  @override
  Future<InnerTubeSong?> getSong(String videoId) =>
      Completer<InnerTubeSong?>().future;

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async => const <InnerTubeSong>[];
}

/// Test-only bridge for legacy fixtures created before playlists moved to the
/// occurrence-based catalog. It keeps widget tests deterministic and prevents
/// them from opening the process-wide SQLite database.
class _RepositoryPlaylistsController extends PlaylistsController {
  _RepositoryPlaylistsController(this.repository);

  final _FakeLibraryRepository repository;
  var _createdPlaylistCount = 0;

  @override
  Future<List<Playlist>> build() async =>
      List<Playlist>.unmodifiable(repository.playlists);

  @override
  Future<Playlist?> create(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) return null;
    final now = DateTime(
      2026,
      1,
      1,
    ).add(Duration(seconds: _createdPlaylistCount));
    _createdPlaylistCount += 1;
    final playlist = Playlist(
      id: 'test-created-${_createdPlaylistCount - 1}',
      name: normalized,
      trackIds: const <String>[],
      createdAt: now,
      updatedAt: now,
    );
    await repository.savePlaylist(playlist);
    _publish();
    return playlist;
  }

  @override
  Future<int> addTracksToPlaylist(
    String playlistId,
    Iterable<String> trackIds,
  ) async {
    final index = repository.playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );
    if (index < 0) return 0;
    final availableIds = repository.localTracks
        .map((track) => track.id)
        .toSet();
    final current = repository.playlists[index];
    final nextIds = current.trackIds.toList(growable: true);
    final additions = trackIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && availableIds.contains(id))
        .where((id) => !nextIds.contains(id))
        .toList(growable: false);
    if (additions.isEmpty) return 0;
    nextIds.addAll(additions);
    repository.playlists[index] = current.copyWith(
      trackIds: nextIds,
      updatedAt: DateTime(2026, 1, 2),
    );
    _publish();
    return additions.length;
  }

  @override
  Future<int> removeTracksFromPlaylist(
    String playlistId,
    Iterable<String> trackIds,
  ) async {
    final index = repository.playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );
    if (index < 0) return 0;
    final removedIds = trackIds.map((id) => id.trim()).toSet();
    final current = repository.playlists[index];
    final nextIds = current.trackIds
        .where((id) => !removedIds.contains(id))
        .toList(growable: false);
    final removedCount = current.trackIds.length - nextIds.length;
    if (removedCount == 0) return 0;
    repository.playlists[index] = current.copyWith(
      trackIds: nextIds,
      updatedAt: DateTime(2026, 1, 2),
    );
    _publish();
    return removedCount;
  }

  @override
  Future<void> removeTracksFromAllPlaylists(Iterable<String> trackIds) async {
    final removedIds = trackIds.map((id) => id.trim()).toSet();
    var changed = false;
    for (var index = 0; index < repository.playlists.length; index++) {
      final current = repository.playlists[index];
      final nextIds = current.trackIds
          .where((id) => !removedIds.contains(id))
          .toList(growable: false);
      if (nextIds.length == current.trackIds.length) continue;
      repository.playlists[index] = current.copyWith(
        trackIds: nextIds,
        updatedAt: DateTime(2026, 1, 2),
      );
      changed = true;
    }
    if (changed) _publish();
  }

  @override
  Future<void> renamePlaylist(String playlistId, String name) async {
    final normalized = name.trim();
    final index = repository.playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );
    if (index < 0 || normalized.isEmpty) return;
    final current = repository.playlists[index];
    repository.playlists[index] = current.copyWith(
      name: normalized,
      updatedAt: DateTime(2026, 1, 2),
    );
    _publish();
  }

  @override
  Future<PlaylistDeleteOptions> playlistDeleteOptions(String playlistId) async {
    return const PlaylistDeleteOptions(
      isYouTubeMusicLinked: false,
      canDeleteFromYouTubeMusic: false,
    );
  }

  @override
  Future<void> deletePlaylist(
    String playlistId, {
    PlaylistDeleteScope scope = PlaylistDeleteScope.localOnly,
  }) async {
    await repository.deletePlaylist(playlistId);
    _publish();
  }

  @override
  Future<bool> toggleFavorite(String trackId) async {
    final normalized = trackId.trim();
    if (normalized.isEmpty) return false;
    var index = repository.playlists.indexWhere(
      (playlist) => playlist.isFavorites,
    );
    if (index < 0) {
      repository.playlists.add(
        Playlist(
          id: Playlist.favoritesId,
          name: 'Favoritos',
          trackIds: const <String>[],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
      index = repository.playlists.length - 1;
    }
    final current = repository.playlists[index];
    final wasFavorite = current.trackIds.contains(normalized);
    repository.playlists[index] = current.copyWith(
      trackIds: wasFavorite
          ? current.trackIds
                .where((id) => id != normalized)
                .toList(growable: false)
          : <String>[...current.trackIds, normalized],
      updatedAt: DateTime(2026, 1, 2),
    );
    _publish();
    return !wasFavorite;
  }

  @override
  Future<void> reloadFromRepository({bool syncActiveQueue = true}) async {
    _publish();
  }

  void _publish() {
    state = AsyncData(List<Playlist>.unmodifiable(repository.playlists));
    ref
      ..invalidate(catalogPlaylistsProvider)
      ..invalidate(catalogPlaylistProvider);
  }
}

List<CatalogPlaylist> _testCatalogPlaylists(
  _FakeLibraryRepository repository, {
  List<CatalogPlaylist>? additionalCatalogs,
}) {
  final byId = <String, CatalogPlaylist>{
    for (final catalog in additionalCatalogs ?? const <CatalogPlaylist>[])
      catalog.playlist.id: catalog,
  };
  for (final playlist in repository.playlists) {
    byId.putIfAbsent(
      playlist.id,
      () => _legacyCatalogPlaylist(repository, playlist),
    );
  }
  return List<CatalogPlaylist>.unmodifiable(byId.values);
}

CatalogPlaylist? _testCatalogPlaylist(
  _FakeLibraryRepository repository,
  String playlistId, {
  List<CatalogPlaylist>? additionalCatalogs,
  bool useLegacyDetailFallback = false,
}) {
  for (final catalog in additionalCatalogs ?? const <CatalogPlaylist>[]) {
    if (catalog.playlist.id == playlistId) return catalog;
  }
  final playlist = repository.playlists
      .where((candidate) => candidate.id == playlistId)
      .firstOrNull;
  if (playlist == null) return null;
  return useLegacyDetailFallback
      ? CatalogPlaylist(playlist: playlist, entries: const <PlaylistEntry>[])
      : _legacyCatalogPlaylist(repository, playlist);
}

CatalogPlaylist _legacyCatalogPlaylist(
  _FakeLibraryRepository repository,
  Playlist playlist,
) {
  final tracksById = <String, LocalTrack>{
    for (final track in repository.localTracks) track.id: track,
  };
  final entries = <PlaylistEntry>[];
  for (var index = 0; index < playlist.trackIds.length; index++) {
    final trackId = playlist.trackIds[index];
    final local = tracksById[trackId];
    final sourceId = local?.sourceId?.trim();
    final artists = local == null
        ? const <String>[]
        : local.artists.isEmpty
        ? <String>[local.artist]
        : local.artists;
    final catalogTrack = local == null
        ? CatalogTrack(
            key: 'legacy:$trackId',
            provider: CatalogProvider.legacy,
            providerId: trackId,
            title: trackId,
          )
        : sourceId != null && sourceId.isNotEmpty
        ? CatalogTrack.youtube(
            videoId: sourceId,
            title: local.title,
            artists: artists,
            artistBrowseIds: local.artistBrowseIds,
            album: local.album,
            duration: local.duration,
            thumbnailUrl: local.catalogThumbnailUrl ?? local.thumbnailUrl,
            sourceUrl: local.sourceUrl,
          )
        : CatalogTrack.local(
            localTrackId: local.id,
            title: local.title,
            artists: artists,
            artistBrowseIds: local.artistBrowseIds,
            album: local.album,
            duration: local.duration,
            thumbnailUrl: local.catalogThumbnailUrl ?? local.thumbnailUrl,
            sourceUrl: local.sourceUrl,
          );
    entries.add(
      PlaylistEntry(
        id: 'test-legacy-${playlist.id}-$index-$trackId',
        playlistId: playlist.id,
        track: catalogTrack,
        localTrackId: local?.id,
        remoteVideoId: sourceId == null || sourceId.isEmpty ? null : sourceId,
        position: index,
        origin: PlaylistEntryOrigin.legacy,
        createdAt: playlist.createdAt,
        updatedAt: playlist.updatedAt,
      ),
    );
  }
  return CatalogPlaylist(playlist: playlist, entries: entries);
}

class _FakeLibraryRepository implements LibraryRepository {
  final List<LocalTrack> history = [];
  final List<LocalTrack> localTracks = [];
  final List<Playlist> playlists = [];

  @override
  Future<void> deleteLocalTrack(String trackId) async {
    localTracks.removeWhere((track) => track.id == trackId);
    history.removeWhere((track) => track.id == trackId);
  }

  @override
  Future<Set<String>> purgeMissingLocalTracks(List<LocalTrack> tracks) async {
    final removedIds = <String>{};
    for (final candidate in tracks) {
      final matches = localTracks.any(
        (track) =>
            track.id == candidate.id && track.filePath == candidate.filePath,
      );
      if (matches) {
        removedIds.add(candidate.id);
      }
    }
    if (removedIds.isEmpty) {
      return const <String>{};
    }

    localTracks.removeWhere((track) => removedIds.contains(track.id));
    history.removeWhere((track) => removedIds.contains(track.id));
    for (var index = 0; index < playlists.length; index++) {
      final playlist = playlists[index];
      playlists[index] = playlist.copyWith(
        trackIds: playlist.trackIds
            .where((id) => !removedIds.contains(id))
            .toList(growable: false),
      );
    }
    return Set.unmodifiable(removedIds);
  }

  @override
  Future<void> deletePlaylist(String playlistId) async {
    playlists.removeWhere((playlist) => playlist.id == playlistId);
  }

  @override
  Future<List<LocalTrack>> getHistory() async => List.unmodifiable(history);

  @override
  Future<List<LocalTrack>> getLocalTracks() async =>
      List.unmodifiable(localTracks);

  @override
  Future<List<Playlist>> getPlaylists() async => List.unmodifiable(playlists);

  @override
  Future<void> markPlayed(
    String trackId,
    DateTime playedAt, {
    String? playlistId,
  }) async {}

  @override
  Future<void> saveLocalTrack(LocalTrack track) async {
    localTracks.removeWhere((localTrack) => localTrack.id == track.id);
    localTracks.add(track);
  }

  @override
  Future<void> savePlaylist(Playlist playlist) async {
    final index = playlists.indexWhere((entry) => entry.id == playlist.id);
    if (index < 0) {
      playlists.add(playlist);
    } else {
      playlists[index] = playlist;
    }
  }
}
