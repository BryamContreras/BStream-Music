import 'dart:ui' as ui;

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mini-player blur decodes a bounded background image', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(_TestPlayerController.new),
          favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const Scaffold(body: SizedBox(height: 80, child: MiniPlayer())),
        ),
      ),
    );
    await tester.pump();

    final blur = find.byType(ImageFiltered);
    expect(blur, findsOneWidget);
    expect(
      find.byKey(const ValueKey('mini-player-artwork-background')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mini-player-desktop-background')),
      findsNothing,
    );

    final backgroundImage = find.descendant(
      of: blur,
      matching: find.byType(Image),
    );
    expect(backgroundImage, findsOneWidget);
    final image = tester.widget<Image>(backgroundImage);
    final provider = image.image as ResizeImage;
    expect(provider.width, 320);
  });

  for (final size in const [Size(320, 640), Size(360, 800)]) {
    testWidgets(
      'Android ${size.width.toInt()} px mini-player fills width with only top corners rounded',
      (tester) async {
        _configureView(tester, size, textScaleFactor: 3);
        final controller = _TestPlayerController();
        await tester.pumpWidget(
          _miniPlayerHarness(playerController: controller),
        );
        await tester.pump();

        final frame = find.byKey(const ValueKey('mini-player-frame'));
        final containerFinder = find.byKey(
          const ValueKey('mini-player-container'),
        );
        final surface = find.byKey(const ValueKey('mini-player-surface'));
        final play = find.byKey(const ValueKey('mini-player-primary-control'));
        final previous = find.byKey(
          const ValueKey('mini-player-previous-control'),
        );
        final next = find.byKey(const ValueKey('mini-player-next-control'));
        final metadata = find.byKey(const ValueKey('mini-player-metadata'));
        final progress = find.byKey(const ValueKey('mini-player-progress'));
        final frameRect = tester.getRect(frame);
        final surfaceRect = tester.getRect(surface);
        final playRect = tester.getRect(play);
        final metadataRect = tester.getRect(metadata);
        final progressRect = tester.getRect(progress);

        expect(frameRect.left, closeTo(0, 0.1));
        expect(frameRect.right, closeTo(size.width, 0.1));
        expect(surfaceRect, frameRect);
        expect(progressRect.left, closeTo(frameRect.left, 0.1));
        expect(progressRect.right, closeTo(frameRect.right, 0.1));
        expect(progressRect.bottom, closeTo(frameRect.bottom, 0.1));
        expect(progressRect.height, 3);
        expect(progressRect.top, greaterThanOrEqualTo(playRect.bottom));
        expect(progressRect.top, greaterThanOrEqualTo(metadataRect.bottom));
        expect(frameRect.intersect(progressRect), progressRect);
        expect(tester.getSize(play), const Size.square(48));
        expect(previous, findsNothing);
        expect(next, findsNothing);
        expect(playRect.right, lessThanOrEqualTo(frameRect.right));
        expect(metadataRect.right, lessThanOrEqualTo(playRect.left));
        expect(
          find.byKey(const ValueKey('mini-player-primary-gradient')),
          findsNothing,
        );
        final playButton = tester.widget<IconButton>(play);
        expect(playButton.iconSize, 44);
        expect(
          playButton.style?.foregroundColor?.resolve(<WidgetState>{}),
          AppColors.playbackControlForegroundFor(tester.element(play)),
        );
        expect(
          playButton.style?.backgroundColor?.resolve(<WidgetState>{}),
          Colors.transparent,
        );
        expect(tester.getSize(surface).height, greaterThanOrEqualTo(60));
        final accentBorder = find.byKey(
          const ValueKey('mini-player-accent-top-border'),
        );
        expect(tester.getSize(accentBorder).height, 11);
        expect(
          tester.getRect(accentBorder).width,
          closeTo(frameRect.width, 0.1),
        );
        final accentPaint = tester.widget<CustomPaint>(accentBorder);
        expect(accentPaint.painter, isNotNull);
        final dynamic accentPainter = accentPaint.painter;
        expect(accentPainter.cornerRadius, 10);
        expect(accentPainter.strokeWidth, 1);
        expect(
          accentPainter.color,
          AppColors.downloadAccentFor(
            tester.element(accentBorder),
          ).withValues(alpha: 0.45),
        );
        final container = tester.widget<Container>(containerFinder);
        final decoration = container.decoration! as BoxDecoration;
        expect(container.clipBehavior, Clip.antiAlias);
        expect(
          decoration.borderRadius,
          const BorderRadius.vertical(top: Radius.circular(10)),
        );
        expect(
          find.byKey(const ValueKey('mini-player-current-time')),
          findsNothing,
        );
        expect(find.text('0:00'), findsOneWidget);
        await tester.tap(play);
        await tester.pump();
        expect(controller.toggleCalls, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Android mini-player keeps the playback fallback notice visible',
    (tester) async {
      _configureView(tester, const Size(320, 640));
      await tester.pumpWidget(
        _miniPlayerHarness(
          playerController: _TestPlayerController(
            errorMessage: 'Reproducción alternativa activa.',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Reproducción alternativa activa.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mini-player-previous-control')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mini-player-next-control')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('mini-player-primary-control')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop mini-player exposes an interactive progress control', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 200));
    final controller = _TestPlayerController();
    await tester.pumpWidget(
      _miniPlayerHarness(
        platform: TargetPlatform.windows,
        playerController: controller,
      ),
    );
    await tester.pump();

    final frameRect = tester.getRect(
      find.byKey(const ValueKey('mini-player-frame')),
    );
    final progress = find.byKey(const ValueKey('mini-player-progress'));
    final progressRect = tester.getRect(progress);
    final progressSlider = find.byKey(
      const ValueKey('mini-player-progress-control'),
    );
    final currentTime = find.byKey(const ValueKey('mini-player-current-time'));
    final totalTime = find.byKey(const ValueKey('mini-player-total-time'));
    final playRect = tester.getRect(
      find.byKey(const ValueKey('mini-player-primary-control')),
    );
    final previous = find.byKey(const ValueKey('mini-player-previous-control'));
    final next = find.byKey(const ValueKey('mini-player-next-control'));
    final shuffle = find.byKey(const ValueKey('mini-player-shuffle-control'));
    final repeat = find.byKey(const ValueKey('mini-player-repeat-control'));
    final lyrics = find.byKey(const ValueKey('mini-player-lyrics-control'));
    final volume = find.byKey(const ValueKey('mini-player-volume-control'));
    final previousRect = tester.getRect(previous);
    final surface = find.byKey(const ValueKey('mini-player-surface'));
    final surfaceRect = tester.getRect(surface);
    final artwork = find.descendant(
      of: find.byKey(const ValueKey('mini-player-metadata')),
      matching: find.byType(ClipRRect),
    );
    expect(progressRect.center.dx, closeTo(frameRect.center.dx, 0.1));
    expect(progressRect.width, lessThan(frameRect.width));
    expect(progressRect.width, closeTo(480, 0.1));
    expect(progressRect.bottom, lessThan(frameRect.bottom));
    expect(progressRect.height, 32);
    expect(progressRect.top, greaterThanOrEqualTo(playRect.bottom));
    expect(progressRect.top - previousRect.bottom, closeTo(2, 0.1));
    expect(
      (previousRect.top + progressRect.bottom) / 2,
      closeTo(surfaceRect.center.dy + 4, 0.1),
    );
    expect(frameRect.contains(progressRect.topLeft), isTrue);
    expect(frameRect.contains(progressRect.bottomRight), isTrue);
    expect(progressSlider, findsOneWidget);
    expect(
      find.descendant(of: progress, matching: currentTime),
      findsOneWidget,
    );
    expect(find.descendant(of: progress, matching: totalTime), findsOneWidget);
    final currentTimeRect = tester.getRect(currentTime);
    final progressSliderRect = tester.getRect(progressSlider);
    final totalTimeRect = tester.getRect(totalTime);
    expect(progressSliderRect.left - currentTimeRect.right, closeTo(4, 0.1));
    expect(totalTimeRect.left - progressSliderRect.right, closeTo(4, 0.1));
    final currentTimeTextRect = tester.getRect(
      find.descendant(of: currentTime, matching: find.byType(Text)),
    );
    final totalTimeTextRect = tester.getRect(
      find.descendant(of: totalTime, matching: find.byType(Text)),
    );
    expect(
      progressSliderRect.left - currentTimeTextRect.right,
      closeTo(4, 0.1),
    );
    expect(totalTimeTextRect.left - progressSliderRect.right, closeTo(4, 0.1));
    final progressDecorationFinder = find.descendant(
      of: progressSlider,
      matching: find.byType(DecoratedBox),
    );
    final progressDecorationHeights = List<double>.generate(
      progressDecorationFinder.evaluate().length,
      (index) => tester.getSize(progressDecorationFinder.at(index)).height,
    );
    expect(
      progressDecorationHeights.where((height) => height == 3),
      hasLength(2),
    );
    expect(
      progressDecorationHeights.where((height) => height == 14),
      hasLength(1),
    );
    expect(find.text('0:00'), findsOneWidget);
    expect(find.text('3:00'), findsOneWidget);
    expect(tester.getSize(artwork), const Size.square(60));
    expect(
      tester.widget<Text>(find.text('Canción de prueba')).style?.fontSize,
      16,
    );
    expect(
      find.descendant(of: progress, matching: find.byType(Slider)),
      findsNothing,
    );
    final previousButton = tester.widget<IconButton>(
      find.descendant(of: previous, matching: find.byType(IconButton)),
    );
    final nextButton = tester.widget<IconButton>(
      find.descendant(of: next, matching: find.byType(IconButton)),
    );
    final shuffleButton = tester.widget<IconButton>(
      find.descendant(of: shuffle, matching: find.byType(IconButton)),
    );
    final repeatButton = tester.widget<IconButton>(
      find.descendant(of: repeat, matching: find.byType(IconButton)),
    );
    final lyricsButton = tester.widget<IconButton>(
      find.descendant(of: lyrics, matching: find.byType(IconButton)),
    );
    final playButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('mini-player-primary-control')),
    );
    expect(shuffleButton.iconSize, 26);
    expect(previousButton.iconSize, 30);
    expect(playButton.iconSize, 44);
    final playIconTranslation = tester.widget<Transform>(
      find.descendant(
        of: find.byKey(const ValueKey('mini-player-primary-control')),
        matching: find.byType(Transform),
      ),
    );
    expect(playIconTranslation.transform.getTranslation().x, 1);
    expect(playIconTranslation.transform.getTranslation().y, 0);
    expect(nextButton.iconSize, 30);
    expect(repeatButton.iconSize, 26);
    expect(lyricsButton.iconSize, isNull);
    expect(
      playButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      previousButton.color,
    );
    expect(
      playButton.style?.backgroundColor?.resolve(<WidgetState>{}),
      Colors.transparent,
    );
    expect(
      find.byKey(const ValueKey('mini-player-primary-gradient')),
      findsNothing,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-primary-control'))),
      const Size.square(52),
    );
    expect(miniPlayerHeightFor(tester.element(surface)), 94);
    expect(tester.getSize(previous), const Size.square(48));
    expect(tester.getSize(lyrics), const Size.square(48));
    expect(tester.getSize(volume), const Size(152, 44));
    expect(
      tester
          .widget<Icon>(
            find.descendant(of: volume, matching: find.byType(Icon)),
          )
          .size,
      22,
    );
    await tester.tap(find.byKey(const ValueKey('mini-player-primary-control')));
    await tester.pump();
    expect(controller.toggleCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop mini-player progress seeks the current track', (
    tester,
  ) async {
    _configureView(tester, const Size(960, 200));
    final controller = _TestPlayerController();
    await tester.pumpWidget(
      _miniPlayerHarness(
        platform: TargetPlatform.windows,
        playerController: controller,
      ),
    );
    await tester.pump();

    final slider = find.byKey(const ValueKey('mini-player-progress-control'));
    expect(slider, findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    await tester.tapAt(tester.getCenter(slider));
    await tester.pump();

    expect(controller.lastSeek, isNotNull);
    expect(controller.lastSeek!.inSeconds, closeTo(90, 2));
    expect(controller.seekCalls, 1);

    final sliderRect = tester.getRect(slider);
    final gesture = await tester.startGesture(sliderRect.center);
    await gesture.moveTo(Offset(sliderRect.right - 4, sliderRect.center.dy));
    await gesture.moveTo(Offset(sliderRect.left + 4, sliderRect.center.dy));
    await gesture.moveTo(Offset(sliderRect.left - 20, sliderRect.center.dy));
    await tester.pump();
    expect(controller.seekCalls, 1);
    await gesture.up();
    await tester.pump();

    expect(controller.seekCalls, 2);
    expect(controller.lastSeek, Duration.zero);
  });

  testWidgets('desktop pause icon keeps the larger size centered', (
    tester,
  ) async {
    _configureView(tester, const Size(960, 200));
    await tester.pumpWidget(
      _miniPlayerHarness(
        platform: TargetPlatform.windows,
        playerController: _TestPlayerController(
          initialStatus: PlayerStatus.playing,
        ),
      ),
    );
    await tester.pump();

    final primaryControl = find.byKey(
      const ValueKey('mini-player-primary-control'),
    );
    final button = tester.widget<IconButton>(primaryControl);
    final translation = tester.widget<Transform>(
      find.descendant(of: primaryControl, matching: find.byType(Transform)),
    );

    expect(tester.getSize(primaryControl), const Size.square(52));
    expect(button.iconSize, 40);
    expect(
      find.descendant(
        of: primaryControl,
        matching: find.byIcon(Icons.pause_rounded),
      ),
      findsOneWidget,
    );
    expect(translation.transform.getTranslation().x, 0);
    expect(translation.transform.getTranslation().y, 0);
    expect(tester.takeException(), isNull);
  });

  for (final variant in const [
    (
      brightness: Brightness.dark,
      size: Size(320, 200),
      base: Color(0xFF0C0D0D),
      edgeStrength: 0.025,
      centerStrength: 0.055,
    ),
    (
      brightness: Brightness.light,
      size: Size(960, 200),
      base: Color(0xFFF4F5F4),
      edgeStrength: 0.018,
      centerStrength: 0.038,
    ),
  ]) {
    testWidgets(
      'desktop ${variant.brightness.name} mini-player uses its own opaque accent-tinted surface',
      (tester) async {
        _configureView(tester, variant.size);
        await tester.pumpWidget(
          _miniPlayerHarness(
            platform: TargetPlatform.windows,
            brightness: variant.brightness,
            accent: AppAccent.blue,
          ),
        );
        await tester.pump();

        final frame = find.byKey(const ValueKey('mini-player-frame'));
        final background = find.byKey(
          const ValueKey('mini-player-desktop-background'),
        );
        final decoration = tester.widget<DecoratedBox>(background).decoration;
        final colors = (decoration as BoxDecoration).gradient!.colors;
        Color tinted(double strength) => Color.alphaBlend(
          AppAccent.blue.seedColor.withValues(alpha: strength),
          variant.base,
        );

        expect(colors, <Color>[
          tinted(variant.edgeStrength),
          tinted(variant.centerStrength),
          tinted(variant.edgeStrength),
        ]);
        expect(colors.every((color) => color.a == 1), isTrue);
        expect(colors, isNot(contains(variant.base)));
        expect(tester.getRect(background), tester.getRect(frame));
        expect(
          find.byKey(const ValueKey('mini-player-artwork-background')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('mini-player-background-overlay')),
          findsNothing,
        );
        expect(find.byType(ImageFiltered), findsNothing);
        expect(
          find.descendant(of: background, matching: find.byType(SourceImage)),
          findsNothing,
        );
        expect(
          find.byType(SourceImage),
          findsOneWidget,
          reason: 'Only the visible artwork may decode the cover on desktop.',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'desktop idle mini-player keeps the same independent background path',
    (tester) async {
      _configureView(tester, const Size(960, 200));
      await tester.pumpWidget(
        _miniPlayerHarness(
          platform: TargetPlatform.windows,
          brightness: Brightness.dark,
          playerController: _TestPlayerController(withTrack: false),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('mini-player-desktop-background')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('mini-player-neutral-background')),
        findsNothing,
      );
      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.byType(SourceImage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop mini-player volume bar remains interactive', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 200));
    final controller = _TestPlayerController();
    await tester.pumpWidget(
      _miniPlayerHarness(
        platform: TargetPlatform.windows,
        playerController: controller,
      ),
    );
    await tester.pump();

    final volume = find.byKey(const ValueKey('mini-player-volume-control'));
    final volumeSlider = find.descendant(
      of: volume,
      matching: find.byKey(const ValueKey('mini-player-volume-slider')),
    );
    expect(volumeSlider, findsOneWidget);
    expect(
      find.descendant(of: volume, matching: find.byType(Slider)),
      findsNothing,
    );
    expect(find.byType(Slider), findsNothing);

    await tester.tapAt(tester.getCenter(volumeSlider));
    await tester.pump();

    expect(controller.lastVolume, closeTo(0.5, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop progress keeps slider semantics without Material Slider',
    (tester) async {
      _configureView(tester, const Size(1280, 200));
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _miniPlayerHarness(platform: TargetPlatform.windows),
      );
      await tester.pump();

      final control = find.byKey(
        const ValueKey('mini-player-progress-control'),
      );
      final data = tester.getSemantics(control).getSemanticsData();
      expect(find.byType(Slider), findsNothing);
      expect(data.flagsCollection.isSlider, isTrue);
      expect(data.label, 'Progreso de reproducción');
      expect(data.value, '0:00');
      expect(data.hasAction(ui.SemanticsAction.increase), isTrue);
      expect(data.hasAction(ui.SemanticsAction.decrease), isFalse);
      semantics.dispose();
    },
  );
}

Widget _miniPlayerHarness({
  TargetPlatform platform = TargetPlatform.android,
  Brightness brightness = Brightness.light,
  AppAccent accent = AppAccent.blue,
  _TestPlayerController? playerController,
}) {
  final controller = playerController ?? _TestPlayerController();
  return ProviderScope(
    overrides: [
      playerControllerProvider.overrideWith(() => controller),
      favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        platform: platform,
        brightness: brightness,
        extensions: [AppAccentTheme(accent: accent)],
      ),
      home: const Scaffold(
        body: Align(alignment: Alignment.topCenter, child: MiniPlayer()),
      ),
    ),
  );
}

void _configureView(
  WidgetTester tester,
  Size size, {
  double textScaleFactor = 1,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
  addTearDown(() {
    tester.view
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

class _TestPlayerController extends PlayerController {
  _TestPlayerController({
    this.initialStatus = PlayerStatus.paused,
    this.withTrack = true,
    this.errorMessage,
  });

  final PlayerStatus initialStatus;
  final bool withTrack;
  final String? errorMessage;
  Duration? lastSeek;
  double? lastVolume;
  int seekCalls = 0;
  int toggleCalls = 0;
  int previousCalls = 0;
  int nextCalls = 0;

  @override
  Future<PlayerSnapshot> build() async => PlayerSnapshot(
    status: initialStatus,
    title: 'Canción de prueba',
    artist: 'BStream Music',
    trackId: withTrack ? 'mini-player-test-track' : null,
    thumbnailUrl: withTrack
        ? 'https://example.invalid/mini-player-artwork.jpg'
        : null,
    duration: Duration(minutes: 3),
    errorMessage: errorMessage,
  );

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    lastSeek = position;
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
  }

  @override
  Future<void> togglePlayPause() async {
    toggleCalls++;
  }

  @override
  Future<void> playPrevious() async {
    previousCalls++;
  }

  @override
  Future<void> playNext({bool automatic = false}) async {
    nextCalls++;
  }
}
