import 'dart:async';
import 'dart:ui';

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/artwork_progress_color_provider.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_animation_transition.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_page.dart';
import 'package:bstream_music/services/lyrics/lyrics_service.dart';
import 'package:bstream_music/services/lyrics/lyrics_romanization_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const lookupSnapshot = PlayerSnapshot(
    status: PlayerStatus.playing,
    title: 'Test song',
    artist: 'Test artist',
    trackId: 'test-track',
    sourceUrl: 'https://example.com/test-track',
    position: Duration(milliseconds: 1800),
    duration: Duration(minutes: 3),
  );
  const syncedDocument = LyricsDocument(
    provider: 'Test provider',
    trackName: 'Test song',
    artistName: 'Test artist',
    lines: [
      LyricLine(timestamp: Duration.zero, text: 'First line'),
      LyricLine(timestamp: Duration(seconds: 2), text: 'Second line'),
      LyricLine(timestamp: Duration(seconds: 4), text: 'Third line'),
    ],
  );
  const plainDocument = LyricsDocument(
    provider: 'LRCLIB',
    trackName: 'Test song',
    artistName: 'Test artist',
    plainLyrics: 'Plain first line\n   Plain second line',
  );

  test('lyrics alignment codes preserve a safe normal default', () {
    expect(
      LyricsTextAlignment.fromCode('centered'),
      LyricsTextAlignment.centered,
    );
    expect(
      LyricsTextAlignment.fromCode('future-value'),
      LyricsTextAlignment.normal,
    );
    expect(LyricsTextAlignment.fromCode(null), LyricsTextAlignment.normal);
  });

  test('lyrics alignment persists the last rapid selection', () async {
    SharedPreferences.setMockInitialValues({});
    final settingsController = _PersistingLyricsSettingsController();
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(() => settingsController),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsControllerProvider.future);
    final notifier = container.read(settingsControllerProvider.notifier);

    await Future.wait([
      notifier.toggleLyricsTextAlignment(),
      notifier.toggleLyricsTextAlignment(),
    ]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.lyricsAlignment'), 'normal');
    expect(
      container.read(settingsControllerProvider).value?.lyricsTextAlignment,
      LyricsTextAlignment.normal,
    );
  });

  test('lyrics animation style persists the last rapid selection', () async {
    SharedPreferences.setMockInitialValues({});
    final settingsController = _PersistingLyricsSettingsController();
    final container = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(() => settingsController),
      ],
    );
    addTearDown(container.dispose);
    await container.read(settingsControllerProvider.future);
    final notifier = container.read(settingsControllerProvider.notifier);

    await Future.wait([
      notifier.setLyricsAnimationStyle(LyricsAnimationStyle.slide),
      notifier.setLyricsAnimationStyle(LyricsAnimationStyle.highlight),
      notifier.setLyricsAnimationStyle(LyricsAnimationStyle.smooth),
    ]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.lyricsAnimation'), 'smooth');
    expect(
      container.read(settingsControllerProvider).value?.lyricsAnimationStyle,
      LyricsAnimationStyle.smooth,
    );
  });

  test('legacy no-animation setting migrates to smooth', () {
    expect(LyricsAnimationStyle.fromCode('none'), LyricsAnimationStyle.smooth);
  });

  testWidgets('synced lyrics follow the current playback position', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.android,
    );

    expect(_activeLine('First line'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-playback-control')),
      findsOneWidget,
    );

    player.emit(
      lookupSnapshot.copyWith(position: const Duration(milliseconds: 4250)),
    );
    await tester.pumpAndSettle();

    expect(_activeLine('Third line'), findsOneWidget);
    expect(_activeLine('First line'), findsNothing);
  });

  testWidgets(
    'romanized synced lyrics keep playback timing, seek, and live toggle',
    (tester) async {
      final player = _FakePlayerService(lookupSnapshot);
      final container = await _pumpLyricsPage(
        tester,
        player: player,
        lyrics: _FakeLyricsService(syncedDocument),
        lyricsRomanizationEnabled: true,
        lyricsRomanizationLanguages: const {LyricsRomanizationLanguage.korean},
        lyricsRomanizationService: _FakeLyricsRomanizationService(),
      );

      expect(_activeLine('First line'), findsOneWidget);
      expect(_activeLine('Romanized: First line'), findsOneWidget);
      expect(find.text('First line'), findsOneWidget);
      final originalFontSize = _lyricLineFontSize(tester, 'active-lyric-line');
      final romanizedStyle = tester.widget<AnimatedDefaultTextStyle>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('lyrics-line-romanization-0')),
              matching: find.byType(AnimatedDefaultTextStyle),
            )
            .first,
      );
      expect(romanizedStyle.style.fontSize, lessThan(originalFontSize));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('lyrics-line-romanization-0')))
            .top,
        greaterThan(tester.getRect(find.text('First line')).bottom),
      );
      final semantics = tester.ensureSemantics();
      final semanticsData = tester
          .getSemantics(find.byKey(const ValueKey('active-lyric-line')))
          .getSemanticsData();
      expect(semanticsData.label, 'First line\nRomanized: First line');
      expect(semanticsData.hasAction(SemanticsAction.tap), isTrue);
      expect(semanticsData.flagsCollection.isButton, isTrue);
      semantics.dispose();

      player.emit(
        lookupSnapshot.copyWith(position: const Duration(milliseconds: 2500)),
      );
      await tester.pumpAndSettle();
      expect(_activeLine('Second line'), findsOneWidget);
      expect(_activeLine('Romanized: Second line'), findsOneWidget);
      final retainedTile = tester.element(
        find.byKey(const ValueKey('lyrics-line-tile-1')),
      );

      await tester.ensureVisible(find.text('Romanized: Third line'));
      await tester.tap(find.text('Romanized: Third line'));
      await tester.pump();
      expect(player.seekPositions, [const Duration(seconds: 4)]);

      await container
          .read(settingsControllerProvider.notifier)
          .setLyricsRomanizationEnabled(false);
      await tester.pumpAndSettle();
      expect(_activeLine('Second line'), findsOneWidget);
      expect(find.text('Romanized: Second line'), findsNothing);

      await container
          .read(settingsControllerProvider.notifier)
          .setLyricsRomanizationEnabled(true);
      await tester.pumpAndSettle();
      expect(_activeLine('Second line'), findsOneWidget);
      expect(_activeLine('Romanized: Second line'), findsOneWidget);
      expect(
        identical(
          retainedTile,
          tester.element(find.byKey(const ValueKey('lyrics-line-tile-1'))),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unchanged romanization is not rendered twice', (tester) async {
    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      lyricsRomanizationEnabled: true,
      lyricsRomanizationService: _IdentityLyricsRomanizationService(),
    );

    expect(find.text('First line'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-line-romanization-0')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile lyrics move playback and artwork into the header', (
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
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.android,
      textScale: 1.6,
    );

    final artwork = find.byKey(const ValueKey('lyrics-header-artwork'));
    final playback = find.byKey(const ValueKey('lyrics-playback-control'));
    expect(find.byKey(const ValueKey('lyrics-back-button')), findsNothing);
    expect(artwork, findsOneWidget);
    expect(tester.getRect(artwork).left, greaterThanOrEqualTo(8));
    expect(
      find.byKey(const ValueKey('lyrics-header-artwork-fallback')),
      findsOneWidget,
    );
    expect(playback, findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    final playbackButton = tester.widget<IconButton>(playback);
    expect(playbackButton.iconSize, 36);
    expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);

    final semantics = tester.ensureSemantics();
    final artworkSemantics = tester.getSemantics(artwork).getSemanticsData();
    expect(artworkSemantics.hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();

    await tester.tap(playback);
    await tester.pump();
    expect(player.togglePlayPauseCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop lyrics retain the bottom mini player and lean header', (
    tester,
  ) async {
    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.windows,
    );

    expect(find.byKey(const ValueKey('lyrics-back-button')), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-header-artwork')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-playback-control')), findsNothing);
    expect(find.byKey(const ValueKey('mini-player-frame')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics keep the mini player visible below the content', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(960, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.windows,
    );

    expect(find.byKey(const ValueKey('mini-player-frame')), findsOneWidget);
    expect(find.byKey(const ValueKey('mini-player-progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-playback-control')), findsNothing);
    expect(
      tester.getRect(find.byKey(const ValueKey('mini-player-frame'))).bottom,
      closeTo(800, 0.1),
    );
  });

  testWidgets('slide animation interpolates when the active line changes', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
      lyricsAnimationStyle: LyricsAnimationStyle.slide,
    );

    player.emit(
      lookupSnapshot.copyWith(position: const Duration(milliseconds: 2500)),
    );
    await tester.pump();

    expect(_activeLine('Second line'), findsOneWidget);
    final start = _activeSlidePixelOffset(tester);
    expect(start, closeTo(34.0, 0.5));
    expect(_lineSlidePixelOffset(tester, 'lyric-line-0'), closeTo(0.0, 0.01));

    await tester.pump(const Duration(milliseconds: 120));

    final middle = _activeSlidePixelOffset(tester);
    expect(middle, greaterThan(0));
    expect(middle, lessThan(start));
    expect(_lineSlidePixelOffset(tester, 'lyric-line-0'), closeTo(0.0, 0.01));

    await tester.pumpAndSettle();
    expect(_activeSlidePixelOffset(tester), closeTo(0.0, 0.01));
    expect(_lineSlidePixelOffset(tester, 'lyric-line-0'), closeTo(0.0, 0.01));
  });

  testWidgets('smooth animation fades the active line in from dimmer state', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
      lyricsAnimationStyle: LyricsAnimationStyle.smooth,
    );

    player.emit(
      lookupSnapshot.copyWith(position: const Duration(milliseconds: 2500)),
    );
    await tester.pump();

    final transitions = tester
        .widgetList<LyricsAnimationTransition>(
          find.byType(LyricsAnimationTransition),
        )
        .toList(growable: false);
    final activeTransition = transitions.firstWhere(
      (t) => t.active,
      orElse: () => transitions.first,
    );
    final builder = tester
        .widgetList<AnimatedBuilder>(
          find.descendant(
            of: find.byWidget(activeTransition),
            matching: find.byType(AnimatedBuilder),
          ),
        )
        .toList(growable: false);
    expect(builder, isNotEmpty);

    await tester.pumpAndSettle();
    final opacityWidgets = tester
        .widgetList<Opacity>(
          find.descendant(
            of: find.byWidget(activeTransition),
            matching: find.byType(Opacity),
          ),
        )
        .toList(growable: false);
    expect(opacityWidgets, isNotEmpty);
    expect(opacityWidgets.first.opacity, closeTo(1.0, 0.01));
  });

  testWidgets(
    'highlight animation shows a visible accent background while active',
    (tester) async {
      final player = _FakePlayerService(lookupSnapshot);
      await _pumpLyricsPage(
        tester,
        player: player,
        lyrics: _FakeLyricsService(syncedDocument),
        lyricsAnimationStyle: LyricsAnimationStyle.highlight,
      );

      player.emit(
        lookupSnapshot.copyWith(position: const Duration(milliseconds: 2500)),
      );
      await tester.pumpAndSettle();

      final transitions = tester
          .widgetList<LyricsAnimationTransition>(
            find.byType(LyricsAnimationTransition),
          )
          .toList(growable: false);
      final activeTransition = transitions.firstWhere(
        (t) => t.active,
        orElse: () => transitions.first,
      );
      final builder = tester
          .widgetList<AnimatedBuilder>(
            find.descendant(
              of: find.byWidget(activeTransition),
              matching: find.byType(AnimatedBuilder),
            ),
          )
          .toList(growable: false);
      expect(builder, isNotEmpty);

      final decorated = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byWidget(activeTransition),
              matching: find.byType(DecoratedBox),
            ),
          )
          .toList(growable: false);
      expect(decorated, isNotEmpty);
      final hasAccent = decorated.any((box) {
        final decoration = box.decoration;
        if (decoration is! BoxDecoration) return false;
        final color = decoration.color;
        if (color == null) return false;
        return (color.a * 255).round() > 8;
      });
      expect(hasAccent, isTrue);
    },
  );

  testWidgets('reduced motion skips lyrics animation builders', (tester) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
      disableAnimations: true,
    );

    player.emit(
      lookupSnapshot.copyWith(position: const Duration(milliseconds: 2500)),
    );
    await tester.pumpAndSettle();

    final transitions = tester
        .widgetList<LyricsAnimationTransition>(
          find.byType(LyricsAnimationTransition),
        )
        .toList(growable: false);
    expect(transitions, isNotEmpty);
    for (final transition in transitions) {
      final builders = find.descendant(
        of: find.byWidget(transition),
        matching: find.byType(AnimatedBuilder),
      );
      expect(builders, findsNothing);
    }
  });

  testWidgets(
    'changing the animation style triggers a replay for the active line',
    (tester) async {
      final player = _FakePlayerService(lookupSnapshot);
      await _pumpLyricsPage(
        tester,
        player: player,
        lyrics: _FakeLyricsService(syncedDocument),
        lyricsAnimationStyle: LyricsAnimationStyle.smooth,
      );

      player.emit(
        lookupSnapshot.copyWith(position: const Duration(milliseconds: 2500)),
      );
      await tester.pumpAndSettle();

      final container = tester.element(
        find.byKey(const ValueKey('synced-lyrics-scroll')),
      );
      final provider = ProviderScope.containerOf(container);

      await provider
          .read(settingsControllerProvider.notifier)
          .setLyricsAnimationStyle(LyricsAnimationStyle.slide);

      await tester.pump();

      final slideTransforms = tester
          .widgetList<Transform>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('active-lyric-line')),
                  matching: find.byType(Transform),
                )
                .first,
          )
          .toList(growable: false);
      final hasSlide = slideTransforms
          .map((t) => t.transform.getTranslation().y)
          .any((dy) => dy.abs() > 0.5);
      expect(hasSlide, isTrue);

      await tester.pumpAndSettle();
      final settled = tester
          .widgetList<Transform>(
            find
                .ancestor(
                  of: find.byKey(const ValueKey('active-lyric-line')),
                  matching: find.byType(Transform),
                )
                .first,
          )
          .toList(growable: false);
      final settledSlide = settled
          .map((t) => t.transform.getTranslation().y)
          .any((dy) => dy.abs() > 0.5);
      expect(settledSlide, isFalse);
    },
  );

  testWidgets(
    'changing the animation style mid playback replays the upcoming line',
    (tester) async {
      final player = _FakePlayerService(lookupSnapshot);
      await _pumpLyricsPage(
        tester,
        player: player,
        lyrics: _FakeLyricsService(syncedDocument),
        lyricsAnimationStyle: LyricsAnimationStyle.slide,
      );

      await tester.pumpAndSettle();

      final container = tester.element(
        find.byKey(const ValueKey('synced-lyrics-scroll')),
      );
      final provider = ProviderScope.containerOf(container);
      await provider
          .read(settingsControllerProvider.notifier)
          .setLyricsAnimationStyle(LyricsAnimationStyle.highlight);
      await tester.pumpAndSettle();

      player.emit(
        lookupSnapshot.copyWith(position: const Duration(milliseconds: 4250)),
      );
      await tester.pump();

      final transitions = tester
          .widgetList<LyricsAnimationTransition>(
            find.byType(LyricsAnimationTransition),
          )
          .toList(growable: false);
      final activeTransition = transitions.firstWhere(
        (t) => t.active,
        orElse: () => transitions.first,
      );
      final builder = tester
          .widgetList<AnimatedBuilder>(
            find.descendant(
              of: find.byWidget(activeTransition),
              matching: find.byType(AnimatedBuilder),
            ),
          )
          .toList(growable: false);
      expect(builder, isNotEmpty);
    },
  );

  testWidgets(
    'stored preference centers synchronized lyrics without a toggle',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final player = _FakePlayerService(lookupSnapshot);
      await _pumpLyricsPage(
        tester,
        player: player,
        lyrics: _FakeLyricsService(syncedDocument),
        lyricsTextAlignment: LyricsTextAlignment.centered,
        platform: TargetPlatform.android,
      );

      for (final line in const ['First line', 'Second line', 'Third line']) {
        expect(
          tester.widget<Text>(find.text(line)).textAlign,
          TextAlign.center,
        );
      }
      final pageRect = tester.getRect(find.byType(Scaffold));
      final activeLineRect = tester.getRect(
        find.byKey(const ValueKey('active-lyric-line')),
      );
      expect(
        activeLineRect.left - pageRect.left,
        closeTo(pageRect.right - activeLineRect.right, 0.01),
      );
      for (final line in const ['First line', 'Second line', 'Third line']) {
        expect(
          tester.getRect(find.text(line)).center.dx,
          closeTo(pageRect.center.dx, 0.01),
        );
      }
      expect(_activeLine('First line'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('lyrics-alignment-toggle')),
        findsNothing,
      );

      await tester.tap(find.text('Second line'));
      await tester.pump();
      expect(player.seekPositions.last, const Duration(seconds: 2));

      player.emit(
        lookupSnapshot.copyWith(
          trackId: 'next-track',
          sourceUrl: 'https://example.com/next-track',
          title: 'Next song',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('First line')).textAlign,
        TextAlign.center,
      );
    },
  );

  testWidgets('Android lyrics use reduced horizontal content margins', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.android,
    );

    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('synced-lyrics-scroll')),
    );
    final padding = scroll.padding! as EdgeInsets;

    expect(padding.left, 12);
    expect(padding.right, 12);
    expect(_lyricLineFontSize(tester, 'active-lyric-line'), 30);
    expect(_lyricLineFontSize(tester, 'lyric-line-1'), 27);
  });

  testWidgets('Android lyrics keep offset controls above system navigation', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 720)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(bottom: 24);
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio()
        ..resetPadding();
    });

    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.android,
    );

    final offsetControls = find.byKey(const ValueKey('lyrics-offset-control'));
    expect(
      tester.getRect(offsetControls).bottom,
      lessThanOrEqualTo(720 - 24.0 + 0.1),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('synced-lyrics-scroll'))).bottom,
      lessThanOrEqualTo(720 - 24.0 + 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop lyrics retain their existing horizontal margins', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.windows,
    );

    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('synced-lyrics-scroll')),
    );
    final padding = scroll.padding! as EdgeInsets;

    expect(padding.left, 24);
    expect(padding.right, 24);
    expect(_lyricLineFontSize(tester, 'active-lyric-line'), 36);
    expect(_lyricLineFontSize(tester, 'lyric-line-1'), 33);

    tester.view.physicalSize = const Size(1280, 800);
    await tester.pumpAndSettle();

    expect(_lyricLineFontSize(tester, 'active-lyric-line'), 39);
    expect(_lyricLineFontSize(tester, 'lyric-line-1'), 36);
    expect(_activeLine('First line'), findsOneWidget);
    final activeRect = tester.getRect(
      find.byKey(const ValueKey('active-lyric-line')),
    );
    expect(activeRect.center.dy, inInclusiveRange(0, 800));
  });

  testWidgets('header progress follows the current playback fraction', (
    tester,
  ) async {
    const expectedColor = Color(0xFF7B8DFF);
    final player = _FakePlayerService(
      lookupSnapshot.copyWith(
        position: const Duration(seconds: 45),
        thumbnailUrl: 'test-artwork.invalid',
      ),
    );
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
      artworkProgressColorService: _FakeArtworkProgressColorService(
        expectedColor,
      ),
    );

    final progress = find.byKey(const ValueKey('lyrics-header-progress'));
    final fill = find.byKey(const ValueKey('lyrics-header-progress-fill'));
    expect(progress, findsOneWidget);
    expect(fill, findsOneWidget);
    expect(_renderedFraction(tester, progress, fill), closeTo(0.25, 0.01));
    final colorAnimation = tester.widget<TweenAnimationBuilder<Color?>>(
      find.byKey(const ValueKey('lyrics-header-progress-color-animation')),
    );
    final progressContext = tester.element(progress);
    expect(
      colorAnimation.tween.end,
      AppColors.downloadAccentFor(progressContext),
    );

    player.emit(
      lookupSnapshot.copyWith(position: const Duration(seconds: 135)),
    );
    await tester.pumpAndSettle();

    expect(_renderedFraction(tester, progress, fill), closeTo(0.75, 0.01));
  });

  testWidgets('offset controls use the compact button-only layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
    );

    final controls = find.byKey(const ValueKey('lyrics-offset-control'));
    expect(controls, findsOneWidget);
    expect(
      find.descendant(of: controls, matching: find.byType(Slider)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: controls,
        matching: find.byKey(const ValueKey('lyrics-offset-decrease')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: controls,
        matching: find.byKey(const ValueKey('lyrics-offset-increase')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: controls,
        matching: find.byKey(const ValueKey('lyrics-offset-reset')),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(controls).height, lessThanOrEqualTo(64));
    expect(tester.getSize(controls).width, lessThan(320));
    final decoration =
        tester.widget<Container>(controls).decoration! as BoxDecoration;
    final controlsContext = tester.element(controls);
    final surfaceAlpha = Theme.of(controlsContext).brightness == Brightness.dark
        ? 0.62
        : 0.72;
    expect(
      decoration.color,
      AppColors.menuBackgroundFor(
        controlsContext,
      ).withValues(alpha: surfaceAlpha),
    );
    expect(
      (decoration.border! as Border).top.color,
      AppColors.menuBorderFor(controlsContext),
    );
    final accent = AppColors.downloadAccentFor(controlsContext);
    final activeLineStyle = tester
        .widget<AnimatedDefaultTextStyle>(
          find
              .ancestor(
                of: find.byKey(const ValueKey('active-lyric-line')),
                matching: find.byType(AnimatedDefaultTextStyle),
              )
              .first,
        )
        .style;
    expect(
      activeLineStyle.color,
      Color.alphaBlend(accent.withValues(alpha: 0.08), Colors.white),
    );
    expect(
      activeLineStyle.shadows?.first.color,
      accent.withValues(alpha: 0.04),
    );
    final offsetText = tester.widget<Text>(
      find.byKey(const ValueKey('lyrics-offset-value')),
    );
    expect(
      offsetText.style?.color,
      Color.alphaBlend(
        accent.withValues(alpha: 0.08),
        AppColors.menuForegroundFor(controlsContext),
      ).withValues(alpha: 0.72),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('advancing lyrics by 0.50 seconds updates the active line', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
    );

    expect(_activeLine('First line'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-offset-increase')));
    await tester.pumpAndSettle();

    expect(find.textContaining('+0.50 s'), findsOneWidget);
    expect(_activeLine('Second line'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-offset-reset')));
    await tester.pumpAndSettle();

    expect(find.text('+0.00 s'), findsOneWidget);
    final reset = tester.widget<TextButton>(
      find.byKey(const ValueKey('lyrics-offset-reset')),
    );
    expect(reset.onPressed, isNull);
  });

  testWidgets('lyrics offset is limited to minus and plus ten seconds', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
    );

    final increase = find.byKey(const ValueKey('lyrics-offset-increase'));
    final decrease = find.byKey(const ValueKey('lyrics-offset-decrease'));

    for (var step = 0; step < 20; step++) {
      await tester.tap(increase);
      await tester.pump();
    }
    expect(find.text('+10.00 s'), findsOneWidget);
    expect(tester.widget<IconButton>(increase).onPressed, isNull);

    for (var step = 0; step < 40; step++) {
      await tester.tap(decrease);
      await tester.pump();
    }
    expect(find.text('-10.00 s'), findsOneWidget);
    expect(tester.widget<IconButton>(decrease).onPressed, isNull);
  });

  testWidgets('lyrics offset survives navigation and resets for a new track', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    final container = await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
    );

    await tester.tap(find.byKey(const ValueKey('lyrics-offset-increase')));
    await tester.pumpAndSettle();
    expect(find.text('+0.50 s'), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold()),
      ),
    );
    player.emit(
      lookupSnapshot.copyWith(
        position: const Duration(seconds: 40),
        duration: const Duration(minutes: 4),
        album: 'Updated album metadata',
        trackId: 'remote-cache:changed-id',
        isRemote: true,
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LyricsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('+0.50 s'), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold()),
      ),
    );
    player.emit(
      const PlayerSnapshot(
        status: PlayerStatus.playing,
        title: 'Different song',
        artist: 'Different artist',
        trackId: 'different-track',
        sourceUrl: 'https://example.com/different-track',
        duration: Duration(minutes: 3),
      ),
    );
    await tester.pump();
    player.emit(lookupSnapshot);
    await tester.pump();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: LyricsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('+0.00 s'), findsOneWidget);
  });

  testWidgets('tapping a synced line seeks with the selected offset', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
    );

    await tester.tap(find.byKey(const ValueKey('lyrics-offset-increase')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Third line'));
    await tester.tap(find.text('Third line'));
    await tester.pump();

    expect(player.seekPositions, [const Duration(milliseconds: 3500)]);
  });

  testWidgets('plain lyrics are used when synchronized lines are unavailable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = _FakePlayerService(lookupSnapshot);
    final container = await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(plainDocument),
      platform: TargetPlatform.android,
    );

    expect(find.byKey(const ValueKey('plain-lyrics-scroll')), findsOneWidget);
    expect(find.textContaining('Plain first line'), findsOneWidget);
    expect(
      find.text('These lyrics do not include synchronized timing.'),
      findsOneWidget,
    );
    expect(find.text('Lyrics provided by LRCLIB'), findsOneWidget);
    expect(find.byKey(const ValueKey('synced-lyrics-scroll')), findsNothing);
    final plainText = find.byKey(const ValueKey('plain-lyrics-original'));
    expect(tester.widget<Text>(plainText).style?.fontSize, 25);
    expect(tester.widget<Text>(plainText).textAlign, TextAlign.start);
    expect(
      tester.widget<Text>(plainText).data,
      'Plain first line\n   Plain second line',
    );

    await container
        .read(settingsControllerProvider.notifier)
        .setLyricsTextAlignment(LyricsTextAlignment.centered);
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(plainText).textAlign, TextAlign.center);
    expect(
      tester.widget<Text>(plainText).data,
      'Plain first line\nPlain second line',
    );
    final pageRect = tester.getRect(find.byType(Scaffold));
    final plainTextRect = tester.getRect(plainText);
    expect(plainTextRect.center.dx, closeTo(pageRect.center.dx, 0.01));
    expect(
      plainTextRect.left - pageRect.left,
      closeTo(pageRect.right - plainTextRect.right, 0.01),
    );
    expect(
      tester
          .widget<Text>(
            find.text('These lyrics do not include synchronized timing.'),
          )
          .textAlign,
      isNot(TextAlign.center),
    );
    expect(find.byKey(const ValueKey('lyrics-alignment-toggle')), findsNothing);
  });

  testWidgets('plain lyrics can be romanized without losing line breaks', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(plainDocument),
      lyricsRomanizationEnabled: true,
      lyricsRomanizationLanguages: const {LyricsRomanizationLanguage.japanese},
      lyricsRomanizationService: _FakeLyricsRomanizationService(),
    );

    final firstOriginal = tester.widget<Text>(
      find.byKey(const ValueKey('plain-lyrics-original-0')),
    );
    final secondOriginal = tester.widget<Text>(
      find.byKey(const ValueKey('plain-lyrics-original-1')),
    );
    final firstRomanization = tester.widget<Text>(
      find.byKey(const ValueKey('plain-lyrics-romanization-0')),
    );
    expect(firstOriginal.data, 'Plain first line');
    expect(secondOriginal.data, '   Plain second line');
    expect(firstRomanization.data, 'Romanized: Plain first line');
    expect(
      find.byKey(const ValueKey('plain-lyrics-romanization-1')),
      findsNothing,
    );
    expect(
      firstRomanization.style?.fontSize,
      lessThan(firstOriginal.style!.fontSize!),
    );
    expect(
      tester
          .getRect(find.byKey(const ValueKey('plain-lyrics-romanization-0')))
          .top,
      greaterThan(
        tester
            .getRect(find.byKey(const ValueKey('plain-lyrics-original-0')))
            .bottom,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('romanized lyric pairs remain scrollable at text scale 3', (
    tester,
  ) async {
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

    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      lyricsRomanizationEnabled: true,
      lyricsRomanizationLanguages: const {LyricsRomanizationLanguage.japanese},
      lyricsRomanizationService: _FakeLyricsRomanizationService(),
      platform: TargetPlatform.android,
    );

    expect(_activeLine('First line'), findsOneWidget);
    expect(_activeLine('Romanized: First line'), findsOneWidget);
    await tester.ensureVisible(find.text('Romanized: Third line'));
    await tester.pump();
    expect(find.text('Third line'), findsOneWidget);
    expect(find.text('Romanized: Third line'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide desktop plain lyrics use the available space', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(plainDocument),
      lyricsTextAlignment: LyricsTextAlignment.centered,
      platform: TargetPlatform.windows,
    );

    final plainText = tester.widget<Text>(
      find.byKey(const ValueKey('plain-lyrics-original')),
    );
    expect(plainText.style?.fontSize, 33);
    expect(plainText.textAlign, TextAlign.center);
    expect(find.byKey(const ValueKey('lyrics-alignment-toggle')), findsNothing);
  });

  testWidgets('connection failures show a centered offline message', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService.error(const LyricsConnectionException()),
      language: AppLanguage.spanish,
    );

    const offlineMessage = 'No hay conexión a Internet.';
    final message = find.text(offlineMessage);
    expect(message, findsOneWidget);
    expect(
      find.ancestor(of: message, matching: find.byType(Center)),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
    expect(
      find.text('No encontramos una letra para esta canción.'),
      findsNothing,
    );
  });

  testWidgets('a missing lyric has a distinct centered not-found message', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(null),
      language: AppLanguage.spanish,
    );

    const notFoundMessage = 'No encontramos una letra para esta canción.';
    final message = find.text(notFoundMessage);
    expect(message, findsOneWidget);
    expect(
      find.ancestor(of: message, matching: find.byType(Center)),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.search_off_rounded), findsOneWidget);
    expect(find.text('No hay conexión a Internet.'), findsNothing);
  });

  testWidgets(
    'missing lyrics offer safe alternatives and display the chosen result',
    (tester) async {
      const alternative = LyricsDocument(
        provider: 'LRCLIB',
        providerId: 'manual-1',
        trackName: 'Libre Soy',
        artistName: 'Barak, Alex Campos',
        duration: Duration(seconds: 225),
        lines: [
          LyricLine(timestamp: Duration.zero, text: 'Selected first line'),
          LyricLine(
            timestamp: Duration(seconds: 2),
            text: 'Selected second line',
          ),
        ],
      );
      final player = _FakePlayerService(lookupSnapshot);
      final service = _FakeLyricsService(
        null,
        similar: const [
          LyricsCandidate(document: alternative, similarity: 0.78),
        ],
      );
      final container = await _pumpLyricsPage(
        tester,
        player: player,
        lyrics: service,
        language: AppLanguage.spanish,
      );

      final action = find.text('Letras similares');
      expect(action, findsOneWidget);
      await tester.tap(action);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('similar-lyrics-list')), findsOneWidget);
      expect(find.text('Libre Soy'), findsOneWidget);
      expect(find.text('Barak, Alex Campos'), findsOneWidget);
      expect(find.textContaining('3:45'), findsOneWidget);
      expect(find.textContaining('Sincronizada'), findsOneWidget);
      expect(service.similarLookups, hasLength(1));

      await tester.tap(
        find.byKey(const ValueKey('similar-lyrics-candidate-manual-1')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('synced-lyrics-scroll')),
        findsOneWidget,
      );
      expect(find.text('Selected first line'), findsOneWidget);
      expect(container.read(selectedLyricsControllerProvider), alternative);

      // This choice is memory-only but survives closing and reopening the
      // lyrics route while the same song remains active.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold()),
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LyricsPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Selected first line'), findsOneWidget);

      // A remote refresh can temporarily expose no snapshot value. That is
      // not a song change and must not discard the manual selection.
      player.emit(const PlayerSnapshot(status: PlayerStatus.loading));
      await tester.pumpAndSettle();
      expect(container.read(selectedLyricsControllerProvider), alternative);
      player.emit(lookupSnapshot);
      await tester.pumpAndSettle();
      expect(find.text('Selected first line'), findsOneWidget);

      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          title: 'Another song',
          artist: 'Another artist',
          trackId: 'another-track',
          duration: Duration(minutes: 4),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(selectedLyricsControllerProvider), isNull);
      expect(find.text('Letras similares'), findsOneWidget);
    },
  );

  testWidgets('similar lyrics have clear empty and offline states', (
    tester,
  ) async {
    final emptyPlayer = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: emptyPlayer,
      lyrics: _FakeLyricsService(null),
      language: AppLanguage.spanish,
    );

    await tester.tap(find.text('Letras similares'));
    await tester.pumpAndSettle();
    expect(
      find.text('No encontramos letras similares seguras.'),
      findsOneWidget,
    );

    // A fresh provider container makes the failure belong to the alternatives
    // request, rather than to automatic matching.
    final offlinePlayer = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: offlinePlayer,
      lyrics: _FakeLyricsService(
        null,
        similarError: const LyricsConnectionException(),
      ),
      language: AppLanguage.spanish,
    );
    await tester.tap(find.text('Letras similares'));
    await tester.pumpAndSettle();

    expect(find.text('No hay conexión a Internet.'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);

    // This test replaces one external ProviderContainer with another. Unmount
    // the second scope explicitly so Riverpod can complete the zero-delay
    // auto-dispose task before Flutter checks for pending test timers.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('manual title search runs only after explicit submission', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const manualDocument = LyricsDocument(
      provider: 'LRCLIB',
      providerId: 'manual-search-1',
      trackName: 'Canonical alternate title',
      artistName: 'Test artist',
      plainLyrics: 'First line\nSecond line\nThird line',
    );
    final player = _FakePlayerService(lookupSnapshot);
    final service = _FakeLyricsService(
      null,
      manual: const [
        LyricsCandidate(document: manualDocument, similarity: 0.82),
      ],
    );
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: service,
      language: AppLanguage.spanish,
    );

    await tester.tap(find.text('Letras similares'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('manual-lyrics-search-field'));
    expect(field, findsOneWidget);
    expect(service.manualLookups, isEmpty);

    await tester.enterText(field, 'Canonical alternate title');
    await tester.pump();
    expect(service.manualLookups, isEmpty);

    await tester.tap(find.byKey(const ValueKey('manual-lyrics-search-submit')));
    await tester.pumpAndSettle();

    expect(service.manualLookups, hasLength(1));
    expect(service.manualLookups.single.title, 'Canonical alternate title');
    expect(
      service.manualLookups.single.context.sourceId,
      lookupSnapshot.trackId,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('similar-lyrics-list')),
        matching: find.text('Canonical alternate title'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('instrumental tracks show the instrumental fallback', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(
        const LyricsDocument(
          provider: 'Test provider',
          trackName: 'Test song',
          artistName: 'Test artist',
          instrumental: true,
        ),
      ),
    );

    expect(find.text('This track is marked as instrumental.'), findsOneWidget);
    expect(find.byIcon(Icons.piano_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('synced-lyrics-scroll')), findsNothing);
    expect(find.byKey(const ValueKey('plain-lyrics-scroll')), findsNothing);
  });
}

double _lyricLineFontSize(WidgetTester tester, String key) {
  final style = tester.widget<AnimatedDefaultTextStyle>(
    find
        .ancestor(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(AnimatedDefaultTextStyle),
        )
        .first,
  );
  return style.style.fontSize!;
}

double _activeSlidePixelOffset(WidgetTester tester) {
  return _lineSlidePixelOffset(tester, 'active-lyric-line');
}

double _lineSlidePixelOffset(WidgetTester tester, String key) {
  final transforms = tester
      .widgetList<Transform>(
        find
            .ancestor(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Transform),
            )
            .first,
      )
      .toList(growable: false);
  for (final transform in transforms) {
    final offset = transform.transform.getTranslation();
    if (offset.y.abs() > 0.5) {
      return offset.y;
    }
  }
  return 0.0;
}

Finder _activeLine(String text) {
  return find.descendant(
    of: find.byKey(const ValueKey('active-lyric-line')),
    matching: find.text(text),
  );
}

double _renderedFraction(WidgetTester tester, Finder progress, Finder fill) {
  final progressWidth = tester.getSize(progress).width;
  expect(progressWidth, greaterThan(0));
  return tester.getSize(fill).width / progressWidth;
}

Future<ProviderContainer> _pumpLyricsPage(
  WidgetTester tester, {
  required _FakePlayerService player,
  required _FakeLyricsService lyrics,
  ArtworkProgressColorService? artworkProgressColorService,
  AppLanguage language = AppLanguage.english,
  LyricsTextAlignment lyricsTextAlignment = LyricsTextAlignment.normal,
  LyricsAnimationStyle lyricsAnimationStyle = LyricsAnimationStyle.smooth,
  bool lyricsRomanizationEnabled = false,
  Set<LyricsRomanizationLanguage> lyricsRomanizationLanguages =
      defaultLyricsRomanizationLanguages,
  LyricsRomanizationService? lyricsRomanizationService,
  bool disableAnimations = false,
  TargetPlatform? platform,
  double textScale = 1,
}) async {
  final settingsController = _FakeLyricsSettingsController(
    lyricsTextAlignment,
    lyricsAnimationStyle,
    lyricsRomanizationEnabled: lyricsRomanizationEnabled,
    lyricsRomanizationLanguages: lyricsRomanizationLanguages,
  );
  final container = ProviderContainer(
    overrides: [
      playerServiceProvider.overrideWithValue(player),
      favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
      lyricsServiceProvider.overrideWithValue(lyrics),
      appStringsProvider.overrideWithValue(AppStrings(language)),
      settingsControllerProvider.overrideWith(() => settingsController),
      if (lyricsRomanizationService != null)
        lyricsRomanizationServiceProvider.overrideWithValue(
          lyricsRomanizationService,
        ),
      if (artworkProgressColorService != null)
        artworkProgressColorServiceProvider.overrideWithValue(
          artworkProgressColorService,
        ),
    ],
  );
  final offsetSubscription = container.listen<Duration>(
    lyricsOffsetControllerProvider,
    (_, _) {},
  );
  addTearDown(() async {
    offsetSubscription.close();
    container.dispose();
    await player.close();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: platform == null ? null : ThemeData(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: const LyricsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

class _FakeArtworkProgressColorService extends ArtworkProgressColorService {
  _FakeArtworkProgressColorService(this.color);

  final Color color;

  @override
  Future<Color> resolve(String? rawSource) async => color;
}

class _FakeLyricsSettingsController extends SettingsController {
  _FakeLyricsSettingsController(
    this.initialLyricsTextAlignment,
    this.initialLyricsAnimationStyle, {
    this.lyricsRomanizationEnabled = false,
    this.lyricsRomanizationLanguages = defaultLyricsRomanizationLanguages,
  });

  final LyricsTextAlignment initialLyricsTextAlignment;
  final LyricsAnimationStyle initialLyricsAnimationStyle;
  final bool lyricsRomanizationEnabled;
  final Set<LyricsRomanizationLanguage> lyricsRomanizationLanguages;

  @override
  Future<SettingsState> build() async => SettingsState(
    downloadDirectory: '/tmp/bstream-lyrics-test',
    language: AppLanguage.english,
    lyricsTextAlignment: initialLyricsTextAlignment,
    lyricsAnimationStyle: initialLyricsAnimationStyle,
    lyricsRomanizationEnabled: lyricsRomanizationEnabled,
    lyricsRomanizationLanguages: lyricsRomanizationLanguages,
  );

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
  Future<void> setLyricsAnimationStyle(
    LyricsAnimationStyle lyricsAnimationStyle,
  ) async {
    final current = await future;
    state = AsyncData(
      current.copyWith(lyricsAnimationStyle: lyricsAnimationStyle),
    );
  }

  @override
  Future<void> setLyricsRomanizationEnabled(bool enabled) async {
    final current = await future;
    state = AsyncData(current.copyWith(lyricsRomanizationEnabled: enabled));
  }

  @override
  Future<void> setLyricsRomanizationLanguages(
    Set<LyricsRomanizationLanguage> languages,
  ) async {
    final current = await future;
    state = AsyncData(
      current.copyWith(
        lyricsRomanizationLanguages: Set.unmodifiable(languages),
      ),
    );
  }
}

class _PersistingLyricsSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/bstream-lyrics-test',
    language: AppLanguage.english,
  );
}

class _FakeLyricsRomanizationService extends LyricsRomanizationService {
  @override
  Future<RomanizedLyricsView> romanizeDocument(
    LyricsDocument document,
    Set<LyricsRomanizationLanguage> languages,
  ) async {
    return RomanizedLyricsView(
      syncedLines: [
        for (final line in document.lines) 'Romanized: ${line.text}',
      ],
      plainLyrics: document.plainLyrics == null
          ? null
          : 'Romanized: ${document.plainLyrics}',
    );
  }

  @override
  Future<List<String>> romanizePreview(
    List<String> lines,
    Set<LyricsRomanizationLanguage> languages,
  ) async => [for (final line in lines) 'Romanized: $line'];
}

class _IdentityLyricsRomanizationService extends LyricsRomanizationService {
  @override
  Future<RomanizedLyricsView> romanizeDocument(
    LyricsDocument document,
    Set<LyricsRomanizationLanguage> languages,
  ) async {
    return RomanizedLyricsView(
      syncedLines: [for (final line in document.lines) line.text],
      plainLyrics: document.plainLyrics,
    );
  }
}

class _FakeLyricsService implements LyricsService {
  _FakeLyricsService(
    this.document, {
    this.similar = const [],
    this.manual = const [],
    this.similarError,
  }) : error = null;

  _FakeLyricsService.error(this.error)
    : document = null,
      similar = const [],
      manual = const [],
      similarError = null;

  final LyricsDocument? document;
  final Object? error;
  final List<LyricsCandidate> similar;
  final List<LyricsCandidate> manual;
  final Object? similarError;
  final List<LyricsLookup> lookups = [];
  final List<LyricsLookup> similarLookups = [];
  final List<({String title, LyricsLookup context})> manualLookups = [];

  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) async {
    lookups.add(lookup);
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    return document;
  }

  @override
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  }) async {
    similarLookups.add(lookup);
    final failure = similarError;
    if (failure != null) {
      throw failure;
    }
    return similar.take(limit).toList(growable: false);
  }

  @override
  Future<List<LyricsCandidate>> searchLyricsByTitle(
    String title, {
    required LyricsLookup context,
    int limit = 8,
  }) async {
    manualLookups.add((title: title, context: context));
    return manual.take(limit).toList(growable: false);
  }

  @override
  void dispose() {}
}

class _FakePlayerService implements PlayerService {
  _FakePlayerService(this._snapshot);

  final StreamController<PlayerSnapshot> _snapshots =
      StreamController<PlayerSnapshot>.broadcast(sync: true);
  final List<Duration> seekPositions = [];
  int togglePlayPauseCalls = 0;
  PlayerSnapshot _snapshot;

  void emit(PlayerSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  Future<void> close() => _snapshots.close();

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  bool get supportsLocalQueueReplacement => false;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshots.stream;

  @override
  Future<void> dispose() => close();

  @override
  Future<void> pause() async {}

  @override
  Future<void> playLocal(LocalTrack track) async {}

  @override
  Future<void> playLocalQueue(
    List<LocalTrack> tracks,
    int initialIndex,
  ) async {}

  @override
  Future<void> playRemote(TrackInfo track) async {}

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> seek(Duration position) async {
    seekPositions.add(position);
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {}

  @override
  Future<void> setShuffleEnabled(bool enabled) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> togglePlayPause() async {
    togglePlayPauseCalls++;
  }
}
