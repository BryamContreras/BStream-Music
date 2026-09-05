import 'dart:async';
import 'dart:ui';

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/widgets/marquee_text.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/artwork_progress_color_provider.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_animation_transition.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_page.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_page_route.dart';
import 'package:bstream_music/features/music/presentation/widgets/uniform_playback_slider_track_shape.dart';
import 'package:bstream_music/features/music/presentation/widgets/wavy_playback_seek_bar.dart';
import 'package:bstream_music/platform_channels/lyrics_presentation_chrome.dart';
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

  testWidgets('lyrics transitions keep active scaling subtle', (tester) async {
    const accent = Color(0xFF00BCD4);

    Future<void> pumpTransition({
      required LyricsAnimationStyle style,
      required bool active,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricsAnimationTransition(
              key: const ValueKey('tested-lyrics-transition'),
              style: style,
              active: active,
              accent: accent,
              child: const Text('Line'),
            ),
          ),
        ),
      );
    }

    await pumpTransition(style: LyricsAnimationStyle.smooth, active: false);
    expect(_lyricsTransitionScale(tester), closeTo(0.98, 0.001));
    await pumpTransition(style: LyricsAnimationStyle.smooth, active: true);
    await _settleLyricsAnimations(tester);
    expect(_lyricsTransitionScale(tester), closeTo(1, 0.001));

    await pumpTransition(style: LyricsAnimationStyle.highlight, active: false);
    expect(_lyricsTransitionScale(tester), closeTo(0.98, 0.001));
    await pumpTransition(style: LyricsAnimationStyle.highlight, active: true);
    await _settleLyricsAnimations(tester);
    expect(_lyricsTransitionScale(tester), closeTo(1.01, 0.001));

    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byKey(const ValueKey('tested-lyrics-transition')),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(decoration.color, accent.withValues(alpha: 0.10));
    expect(decoration.boxShadow, hasLength(1));
    expect(decoration.boxShadow?.single.color, accent.withValues(alpha: 0.16));
  });

  testWidgets('synced lyrics follow the current playback position', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(360, 800)
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
    );

    expect(_activeLine('First line'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-playback-control')),
      findsOneWidget,
    );

    player.emit(
      lookupSnapshot.copyWith(position: const Duration(milliseconds: 4250)),
    );
    await _settleLyricsAnimations(tester);

    expect(_activeLine('Third line'), findsOneWidget);
    expect(_activeLine('First line'), findsNothing);
  });

  testWidgets(
    'long synchronized lyrics virtualize rows and follow a distant seek',
    (tester) async {
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });
      final lines = List<LyricLine>.generate(
        240,
        (index) => LyricLine(
          timestamp: Duration(seconds: index),
          text: index % 7 == 0
              ? 'Virtual lyric line $index with enough text to wrap on a '
                    'narrow Android screen without clipping'
              : 'Virtual lyric line $index',
        ),
      );
      final player = _FakePlayerService(
        lookupSnapshot.copyWith(duration: const Duration(minutes: 4)),
      );
      await _pumpLyricsPage(
        tester,
        player: player,
        lyrics: _FakeLyricsService(
          LyricsDocument(
            provider: 'Test provider',
            trackName: 'Test song',
            artistName: 'Test artist',
            lines: lines,
          ),
        ),
        lyricsRomanizationEnabled: true,
        lyricsRomanizationService: _FakeLyricsRomanizationService(),
        platform: TargetPlatform.android,
      );

      expect(
        find.byKey(const ValueKey('synced-lyrics-virtual-list')),
        findsOneWidget,
      );
      expect(
        find.byType(LyricsAnimationTransition).evaluate().length,
        lessThan(40),
      );
      expect(find.byKey(const ValueKey('lyrics-line-tile-239')), findsNothing);

      player.emit(
        lookupSnapshot.copyWith(
          position: const Duration(seconds: 210),
          duration: const Duration(minutes: 4),
        ),
      );
      await _settleLyricsAnimations(tester);

      expect(
        _activeLine(
          'Virtual lyric line 210 with enough text to wrap on a narrow '
          'Android screen without clipping',
        ),
        findsOneWidget,
      );
      expect(
        find.byType(LyricsAnimationTransition).evaluate().length,
        lessThan(40),
      );
      expect(find.byKey(const ValueKey('lyrics-line-tile-0')), findsNothing);
      final viewport = tester.getRect(
        find.byKey(const ValueKey('synced-lyrics-scroll')),
      );
      final active = tester.getRect(
        find.byKey(const ValueKey('active-lyric-line')),
      );
      expect(active.center.dy, inInclusiveRange(viewport.top, viewport.bottom));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion jumps directly to a distant active lyric', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(360, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final lines = List<LyricLine>.generate(
      180,
      (index) => LyricLine(
        timestamp: Duration(seconds: index),
        text: 'Reduced motion lyric $index',
      ),
    );
    final player = _FakePlayerService(
      lookupSnapshot.copyWith(duration: const Duration(minutes: 3)),
    );
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(
        LyricsDocument(
          provider: 'Test provider',
          trackName: 'Test song',
          artistName: 'Test artist',
          lines: lines,
        ),
      ),
      disableAnimations: true,
      platform: TargetPlatform.android,
    );

    player.emit(
      lookupSnapshot.copyWith(
        position: const Duration(seconds: 160),
        duration: const Duration(minutes: 3),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(_activeLine('Reduced motion lyric 160'), findsOneWidget);
    final viewport = tester.getRect(
      find.byKey(const ValueKey('synced-lyrics-scroll')),
    );
    final active = tester.getRect(
      find.byKey(const ValueKey('active-lyric-line')),
    );
    expect(active.center.dy, inInclusiveRange(viewport.top, viewport.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('active lyric recenters after a height-only viewport resize', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(360, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final lines = List<LyricLine>.generate(
      180,
      (index) => LyricLine(
        timestamp: Duration(seconds: index),
        text: 'Height resize lyric $index',
      ),
    );
    final player = _FakePlayerService(
      lookupSnapshot.copyWith(
        position: const Duration(seconds: 100),
        duration: const Duration(minutes: 3),
      ),
    );
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(
        LyricsDocument(
          provider: 'Test provider',
          trackName: 'Test song',
          artistName: 'Test artist',
          lines: lines,
        ),
      ),
      platform: TargetPlatform.android,
    );

    double alignmentError() {
      final viewport = tester.getRect(
        find.byKey(const ValueKey('synced-lyrics-scroll')),
      );
      final active = tester.getRect(
        find.byKey(const ValueKey('active-lyric-line')),
      );
      final expectedTop =
          viewport.top + ((viewport.height - active.height) * 0.43);
      return (active.top - expectedTop).abs();
    }

    expect(alignmentError(), lessThan(2));

    // Keep width and line metrics stable while both the viewport height and
    // its leading timeline geometry change.
    tester.view.physicalSize = const Size(360, 600);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(_activeLine('Height resize lyric 100'), findsOneWidget);
    expect(alignmentError(), lessThan(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('active lyric recenters when guidance height changes', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(240, 600)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final lines = List<LyricLine>.generate(
      160,
      (index) => LyricLine(
        timestamp: Duration(seconds: index),
        text: 'Guidance resize lyric $index',
      ),
    );
    final player = _FakePlayerService(
      lookupSnapshot.copyWith(
        position: const Duration(seconds: 90),
        duration: const Duration(minutes: 3),
      ),
    );
    final container = await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(
        LyricsDocument(
          provider: 'Test provider',
          trackName: 'Test song',
          artistName: 'Test artist',
          lines: lines,
        ),
      ),
      language: AppLanguage.english,
      deriveAppStringsFromSettings: true,
      platform: TargetPlatform.android,
      textScale: 2.4,
    );

    double alignmentError() {
      final viewport = tester.getRect(
        find.byKey(const ValueKey('synced-lyrics-scroll')),
      );
      final active = tester.getRect(
        find.byKey(const ValueKey('active-lyric-line')),
      );
      final expectedTop =
          viewport.top + ((viewport.height - active.height) * 0.43);
      return (active.top - expectedTop).abs();
    }

    expect(alignmentError(), lessThan(2));
    final scrollable = find
        .descendant(
          of: find.byKey(const ValueKey('synced-lyrics-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final initialScrollOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;
    final settings =
        container.read(settingsControllerProvider.notifier)
            as _FakeLyricsSettingsController;
    settings.emitLanguage(AppLanguage.spanish);
    expect(container.read(appStringsProvider).appLanguage, AppLanguage.spanish);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final updatedScrollOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;
    expect((updatedScrollOffset - initialScrollOffset).abs(), greaterThan(5));
    expect(_activeLine('Guidance resize lyric 90'), findsOneWidget);
    expect(alignmentError(), lessThan(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('synced lyrics credit LRCLIB before and after the timeline', (
    tester,
  ) async {
    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.android,
    );

    final topSource = find.byKey(const ValueKey('lyrics-source-top'));
    final bottomSource = find.byKey(const ValueKey('lyrics-source-bottom'));
    expect(find.text('Lyrics provided by LRCLIB'), findsNWidgets(2));
    expect(topSource, findsOneWidget);
    expect(bottomSource, findsOneWidget);
    final topHint = find.byKey(const ValueKey('lyrics-seek-hint-top'));
    final bottomHint = find.byKey(const ValueKey('lyrics-seek-hint-bottom'));
    expect(topHint, findsOneWidget);
    expect(bottomHint, findsOneWidget);
    expect(find.text('Tap a line to seek to that moment.'), findsNWidgets(2));
    expect(
      tester.getTopLeft(topSource).dy,
      lessThan(tester.getTopLeft(topHint).dy),
    );
    expect(
      tester.getTopLeft(topHint).dy,
      lessThan(tester.getTopLeft(find.text('First line')).dy),
    );
    expect(
      tester.getTopLeft(bottomSource).dy,
      greaterThan(tester.getBottomLeft(find.text('Third line')).dy),
    );
    expect(
      tester.getTopLeft(bottomSource).dy,
      lessThan(tester.getTopLeft(bottomHint).dy),
    );
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
      await _settleLyricsAnimations(tester);
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
      await _settleLyricsAnimations(tester);
      expect(_activeLine('Second line'), findsOneWidget);
      expect(find.text('Romanized: Second line'), findsNothing);

      await container
          .read(settingsControllerProvider.notifier)
          .setLyricsRomanizationEnabled(true);
      await _settleLyricsAnimations(tester);
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
    const longHeaderTitle =
        'A very long song title that must slide across the lyrics header';
    final player = _FakePlayerService(
      lookupSnapshot.copyWith(title: longHeaderTitle),
    );
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
    expect(find.byKey(const ValueKey('lyrics-exit-button')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-player-dock')), findsNothing);
    final headerTrackTitle = find.byKey(
      const ValueKey('lyrics-header-track-title'),
    );
    expect(
      tester.widget<MarqueeText>(headerTrackTitle).text,
      '$longHeaderTitle - Test artist',
    );
    expect(
      find.descendant(
        of: headerTrackTitle,
        matching: find.byKey(const ValueKey('marquee-text-animation')),
      ),
      findsOneWidget,
    );

    final semantics = tester.ensureSemantics();
    final artworkSemantics = tester.getSemantics(artwork).getSemanticsData();
    expect(artworkSemantics.hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();

    await tester.tap(playback);
    await tester.pump();
    expect(player.togglePlayPauseCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop lyrics open with the side player by default', (
    tester,
  ) async {
    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.windows,
    );

    expect(find.byKey(const ValueKey('lyrics-header')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-back-button')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-header-artwork')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-playback-control')), findsNothing);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('lyrics-exit-button')), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-player-dock')), findsNothing);
    expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Windows opens the companion and keeps exit beside the offset capsule',
    (tester) async {
      tester.view
        ..physicalSize = const Size(1280, 800)
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });

      final player = _FakePlayerService(lookupSnapshot);
      final chrome = _FakeLyricsPresentationChrome();
      await _pumpLyricsPage(
        tester,
        player: player,
        lyrics: _FakeLyricsService(syncedDocument),
        platform: TargetPlatform.windows,
        presentationChrome: chrome,
      );

      final exit = find.byKey(const ValueKey('lyrics-exit-button'));
      final toolbar = find.byKey(const ValueKey('lyrics-overlay-toolbar'));
      final offsetControl = find.byKey(const ValueKey('lyrics-offset-control'));
      final companion = find.byKey(const ValueKey('lyrics-playback-companion'));
      final companionWidth = find.byKey(
        const ValueKey('lyrics-companion-width'),
      );
      final companionGap = find.byKey(
        const ValueKey('lyrics-desktop-companion-gap'),
      );

      expect(exit, findsOneWidget);
      expect(tester.widget<IconButton>(exit).tooltip, 'Exit Lyrics');
      expect(
        find.descendant(of: exit, matching: find.byIcon(Icons.close_rounded)),
        findsOneWidget,
      );
      expect(toolbar, findsOneWidget);
      expect(offsetControl, findsOneWidget);
      expect(find.descendant(of: toolbar, matching: exit), findsOneWidget);
      expect(
        find.descendant(of: toolbar, matching: offsetControl),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('lyrics-header')), findsNothing);
      expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);
      expect(find.byKey(const ValueKey('lyrics-player-dock')), findsNothing);
      expect(companion, findsOneWidget);
      expect(companionWidth, findsOneWidget);
      expect(companionGap, findsOneWidget);
      expect(chrome.calls, isEmpty);

      final exitRect = tester.getRect(exit);
      final offsetRect = tester.getRect(offsetControl);
      expect(offsetRect.left - exitRect.right, inInclusiveRange(8, 10));
      expect(exitRect.center.dy, closeTo(offsetRect.center.dy, 0.1));
      expect(_iconButtonBackground(tester, exit), Colors.transparent);
      final expandedCompanionWidth = tester.getSize(companionWidth).width;
      expect(expandedCompanionWidth, closeTo(1280 * 0.34, 0.1));
      expect(expandedCompanionWidth, greaterThan(1280 * 0.30));
      expect(tester.getSize(companionGap).width, closeTo(0, 0.1));
      expect(
        tester
                .getRect(find.byKey(const ValueKey('lyrics-content-region')))
                .left -
            tester.getRect(companionWidth).right,
        closeTo(0, 0.1),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('lyrics-content-region')))
            .bottom,
        closeTo(800, 0.1),
      );
      expect(
        find.byKey(const ValueKey('lyrics-companion-artwork')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<MarqueeText>(
              find.byKey(const ValueKey('lyrics-companion-title')),
            )
            .text,
        'Test song',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('lyrics-companion-artist')))
            .data,
        'Test artist',
      );
      expect(
        find.byKey(const ValueKey('lyrics-companion-glass-blur')),
        findsNothing,
      );
      final companionSurface = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('lyrics-companion-glass-surface')),
      );
      final companionDecoration = companionSurface.decoration as BoxDecoration;
      expect(companionDecoration.color, Colors.transparent);
      expect(companionDecoration.gradient, isNull);
      expect(
        (companionDecoration.border! as Border).top.color,
        Colors.transparent,
      );
      final companionFrame = tester.widget<Container>(companion);
      final companionFrameDecoration =
          companionFrame.decoration! as BoxDecoration;
      expect(companionFrameDecoration.color, Colors.transparent);
      expect(
        (companionFrameDecoration.border! as Border).top.color,
        Colors.transparent,
      );
      expect(companionFrameDecoration.boxShadow, isNull);

      final previousControl = find.byKey(
        const ValueKey('lyrics-companion-previous-control'),
      );
      final primaryControl = find.byKey(
        const ValueKey('lyrics-companion-primary-control'),
      );
      final nextControl = find.byKey(
        const ValueKey('lyrics-companion-next-control'),
      );
      final controls = find.byKey(
        const ValueKey('lyrics-companion-transport-controls'),
      );
      expect(previousControl, findsOneWidget);
      expect(primaryControl, findsOneWidget);
      expect(nextControl, findsOneWidget);
      for (final control in [previousControl, primaryControl, nextControl]) {
        expect(_iconButtonBackground(tester, control), Colors.transparent);
        expect(
          _iconButtonBackground(tester, control, disabled: true),
          Colors.transparent,
        );
      }
      expect(
        find.descendant(
          of: primaryControl,
          matching: find.byIcon(Icons.pause_rounded),
        ),
        findsOneWidget,
      );
      expect(tester.widget<IconButton>(previousControl).onPressed, isNotNull);
      expect(tester.widget<IconButton>(nextControl).onPressed, isNotNull);

      final timeline = find.byKey(const ValueKey('lyrics-companion-timeline'));
      expect(
        tester.widget<UniformPlaybackSeekBar>(timeline).position,
        const Duration(milliseconds: 1800),
      );
      expect(
        tester.widget<UniformPlaybackSeekBar>(timeline).duration,
        const Duration(minutes: 3),
      );
      expect(tester.getSize(timeline).height, closeTo(48, 0.1));
      expect(
        tester.getRect(controls).top,
        closeTo(tester.getRect(timeline).bottom - 6, 0.1),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('lyrics-companion-position-label')),
            )
            .data,
        '0:01',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('lyrics-companion-duration-label')),
            )
            .data,
        '3:00',
      );
      expect(
        find.descendant(of: companion, matching: find.byType(Slider)),
        findsOneWidget,
      );

      final semantics = tester.ensureSemantics();
      final timelineSemanticsFinder = find.bySemanticsLabel(
        'Playback timeline',
      );
      expect(timelineSemanticsFinder, findsOneWidget);
      final timelineSemantics = tester
          .getSemantics(timelineSemanticsFinder)
          .getSemanticsData();
      expect(timelineSemantics.flagsCollection.isSlider, isTrue);
      expect(timelineSemantics.label, 'Playback timeline');
      expect(timelineSemantics.hasAction(SemanticsAction.increase), isTrue);
      expect(timelineSemantics.hasAction(SemanticsAction.decrease), isTrue);
      semantics.dispose();

      await tester.tapAt(tester.getCenter(timeline));
      await tester.pump();
      expect(player.seekPositions, hasLength(1));
      expect(
        player.seekPositions.single.inMilliseconds,
        closeTo(const Duration(seconds: 90).inMilliseconds, 1000),
      );
      await tester.tap(primaryControl);
      await tester.pump();
      expect(player.togglePlayPauseCalls, 1);

      player.emit(lookupSnapshot.copyWith(status: PlayerStatus.paused));
      await tester.pump();
      expect(
        find.descendant(
          of: primaryControl,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );
      final scrollRect = tester.getRect(
        find.byKey(const ValueKey('synced-lyrics-scroll')),
      );
      final activeLineRect = tester.getRect(
        find.byKey(const ValueKey('active-lyric-line')),
      );
      expect(
        activeLineRect.center.dy,
        inInclusiveRange(scrollRect.top, scrollRect.bottom),
      );
      expect(chrome.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows side layout keeps track metadata attached to the artwork',
    (tester) async {
      tester.view
        ..physicalSize = const Size(1920, 1000)
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

      final frame = find.byKey(const ValueKey('lyrics-side-layout-frame'));
      final companionWidth = find.byKey(
        const ValueKey('lyrics-companion-width'),
      );
      final companionGap = find.byKey(
        const ValueKey('lyrics-desktop-companion-gap'),
      );
      final contentRegion = find.byKey(const ValueKey('lyrics-content-region'));
      final artwork = find.byKey(const ValueKey('lyrics-companion-artwork'));
      final title = find.byKey(const ValueKey('lyrics-companion-title'));
      final artist = find.byKey(const ValueKey('lyrics-companion-artist'));

      final frameRect = tester.getRect(frame);
      expect(frameRect.width, closeTo(1800, 0.1));
      expect(frameRect.left, closeTo(60, 0.1));
      expect(frameRect.right, closeTo(1860, 0.1));
      expect(tester.getSize(companionWidth).width, closeTo(580, 0.1));
      expect(tester.getSize(companionGap).width, closeTo(80, 0.1));
      expect(tester.getSize(contentRegion).width, closeTo(1140, 0.1));
      expect(
        tester.getRect(contentRegion).left -
            tester.getRect(companionWidth).right,
        closeTo(80, 0.1),
      );

      final artworkRect = tester.getRect(artwork);
      final titleRect = tester.getRect(title);
      final artistRect = tester.getRect(artist);
      expect(titleRect.top - artworkRect.bottom, inInclusiveRange(0, 12));
      expect(artistRect.top - titleRect.bottom, inInclusiveRange(0, 4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Windows side mode never changes the native title bar', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final chrome = _FakeLyricsPresentationChrome();
    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.windows,
      presentationChrome: chrome,
    );

    expect(chrome.calls, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await _settleLyricsAnimations(tester);

    expect(chrome.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows lyrics route animates both ways and reopens cleanly', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final container = await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.windows,
    );
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const Scaffold(
            body: Center(
              child: Text('Lyrics route host', key: ValueKey('lyrics-host')),
            ),
          ),
        ),
      ),
    );
    await _settleLyricsAnimations(tester);

    late PageRoute<void> route;

    void openLyrics() {
      route = buildLyricsPageRoute(navigatorKey.currentContext!);
      unawaited(navigatorKey.currentState!.push<void>(route));
    }

    openLyrics();
    await tester.pump();
    await tester.pump();
    expect(route.settings.name, lyricsPageRouteName);
    expect(route.transitionDuration, const Duration(milliseconds: 420));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 360));
    expect(
      find.byKey(const ValueKey('lyrics-route-fade-transition')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 210));
    final enteringOpacity = tester
        .widget<FadeTransition>(
          find.byKey(const ValueKey('lyrics-route-fade-transition')),
        )
        .opacity
        .value;
    final enteringOffset = tester
        .widget<SlideTransition>(
          find.byKey(const ValueKey('lyrics-route-slide-transition')),
        )
        .position
        .value;
    expect(enteringOpacity, inExclusiveRange(0, 1));
    expect(enteringOffset.dy, inExclusiveRange(0, 0.035));

    await _pumpAnimatedLyrics(tester);
    expect(route.delegatedTransition, isNull);
    expect(route.popGestureEnabled, isTrue);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('lyrics-header')), findsNothing);
    expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-player-dock')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-exit-button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-exit-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    final leavingOpacity = tester
        .widget<FadeTransition>(
          find.byKey(const ValueKey('lyrics-route-fade-transition')),
        )
        .opacity
        .value;
    expect(leavingOpacity, inExclusiveRange(0, 1));

    await _settleLyricsAnimations(tester);
    expect(find.byKey(const ValueKey('lyrics-host')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsNothing,
    );

    openLyrics();
    await _pumpAnimatedLyrics(tester);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('lyrics-header')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-exit-button')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-exit-button')));
    await _settleLyricsAnimations(tester);
    expect(find.byKey(const ValueKey('lyrics-host')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics route disables all motion when reduced motion is set', (
    tester,
  ) async {
    late BuildContext routeContext;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Builder(
          builder: (context) {
            routeContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    final route = buildLyricsPageRoute(routeContext);
    expect(route.transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    expect(route.settings.name, lyricsPageRouteName);
    expect(route.delegatedTransition, isNull);
  });

  testWidgets('Android landscape automatically shows the minimal side player', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(800, 400)
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(left: 34, right: 18);
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

    expect(find.byKey(const ValueKey('lyrics-header')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-exit-button')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-player-dock')), findsNothing);
    expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-offset-control')), findsNothing);
    final companion = find.byKey(const ValueKey('lyrics-playback-companion'));
    expect(companion, findsOneWidget);
    final companionDecoration =
        tester
                .widget<DecoratedBox>(
                  find.byKey(const ValueKey('lyrics-companion-glass-surface')),
                )
                .decoration
            as BoxDecoration;
    expect(companionDecoration.color, Colors.transparent);
    expect(companionDecoration.gradient, isNull);
    expect(
      (companionDecoration.border! as Border).top.color,
      Colors.transparent,
    );
    expect(
      find.byKey(const ValueKey('lyrics-companion-artwork')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('lyrics-companion-title')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-companion-artist')), findsNothing);
    expect(
      find.byKey(const ValueKey('lyrics-companion-timeline')),
      findsOneWidget,
    );
    final companionRect = tester.getRect(companion);
    final artworkRect = tester.getRect(
      find.byKey(const ValueKey('lyrics-companion-artwork')),
    );
    final timelineRect = tester.getRect(
      find.byKey(const ValueKey('lyrics-companion-timeline')),
    );
    final positionRect = tester.getRect(
      find.byKey(const ValueKey('lyrics-companion-position-label')),
    );
    final durationRect = tester.getRect(
      find.byKey(const ValueKey('lyrics-companion-duration-label')),
    );
    expect(artworkRect.left, closeTo(timelineRect.left, 0.1));
    expect(artworkRect.right, closeTo(timelineRect.right, 0.1));
    expect(artworkRect.width, closeTo(timelineRect.width, 0.1));
    expect(positionRect.left, closeTo(artworkRect.left, 0.1));
    expect(durationRect.right, closeTo(artworkRect.right, 0.1));
    final lyricsRect = tester.getRect(
      find.byKey(const ValueKey('lyrics-content-region')),
    );
    expect(companionRect.left, greaterThanOrEqualTo(34));
    expect(companionRect.right, lessThanOrEqualTo(lyricsRect.left));
    expect(companionRect.right, lessThanOrEqualTo(800 - 18));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics companion transport controls drive playback', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(800, 400)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final controller = _LyricsTransportPlayerController(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      playerController: controller,
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.android,
    );

    final controls = find.byKey(
      const ValueKey('lyrics-companion-transport-controls'),
    );
    final previous = find.byKey(
      const ValueKey('lyrics-companion-previous-control'),
    );
    final primary = find.byKey(
      const ValueKey('lyrics-companion-primary-control'),
    );
    final next = find.byKey(const ValueKey('lyrics-companion-next-control'));
    final timeline = find.byKey(const ValueKey('lyrics-companion-timeline'));
    final companion = find.byKey(const ValueKey('lyrics-playback-companion'));

    expect(controls, findsOneWidget);
    expect(previous, findsOneWidget);
    expect(primary, findsOneWidget);
    expect(next, findsOneWidget);
    final timelineRect = tester.getRect(timeline);
    final controlsRect = tester.getRect(controls);
    expect(tester.widget<UniformPlaybackSeekBar>(timeline), isNotNull);
    expect(timelineRect.height, closeTo(48, 0.1));
    expect(controlsRect.top, closeTo(timelineRect.bottom - 6, 0.1));
    expect(
      tester.getRect(controls).bottom,
      lessThanOrEqualTo(tester.getRect(companion).bottom),
    );
    expect(
      tester.getCenter(previous).dx,
      lessThan(tester.getCenter(primary).dx),
    );
    expect(tester.getCenter(primary).dx, lessThan(tester.getCenter(next).dx));
    expect(tester.widget<IconButton>(previous).tooltip, 'Previous');
    expect(tester.widget<IconButton>(primary).tooltip, 'Pause');
    expect(tester.widget<IconButton>(next).tooltip, 'Next');
    expect(tester.getSize(previous), const Size.square(44));
    expect(tester.getSize(primary), const Size.square(48));
    expect(tester.getSize(next), const Size.square(44));
    expect(
      tester.getRect(previous).right,
      closeTo(tester.getRect(primary).left, 0.1),
    );
    expect(
      tester.getRect(primary).right,
      closeTo(tester.getRect(next).left, 0.1),
    );
    for (final control in [previous, primary, next]) {
      expect(_iconButtonBackground(tester, control), Colors.transparent);
      expect(
        _iconButtonBackground(tester, control, disabled: true),
        Colors.transparent,
      );
    }
    expect(
      find.descendant(of: primary, matching: find.byIcon(Icons.pause_rounded)),
      findsOneWidget,
    );

    await tester.tap(previous);
    await tester.tap(primary);
    await tester.tap(next);
    await tester.pump();

    expect(controller.previousCalls, 1);
    expect(controller.toggleCalls, 1);
    expect(controller.nextCalls, 1);
    expect(controller.nextAutomaticValues, [false]);

    controller.emit(lookupSnapshot.copyWith(status: PlayerStatus.paused));
    await tester.pump();

    expect(tester.widget<IconButton>(primary).tooltip, 'Play');
    expect(
      find.descendant(
        of: primary,
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsOneWidget,
    );
    await tester.tap(primary);
    await tester.pump();
    expect(controller.toggleCalls, 2);

    controller.emit(lookupSnapshot.copyWith(status: PlayerStatus.failed));
    await tester.pump();
    expect(tester.widget<IconButton>(previous).onPressed, isNull);
    expect(tester.widget<IconButton>(primary).onPressed, isNull);
    expect(tester.widget<IconButton>(next).onPressed, isNull);

    controller.emit(
      const PlayerSnapshot(
        status: PlayerStatus.paused,
        trackId: 'identity-only-track',
      ),
    );
    await tester.pump();
    expect(tester.widget<IconButton>(previous).onPressed, isNotNull);
    expect(tester.widget<IconButton>(primary).onPressed, isNotNull);
    expect(tester.widget<IconButton>(next).onPressed, isNotNull);

    tester.view.physicalSize = const Size(300, 200);
    await _pumpAnimatedLyrics(tester);
    expect(tester.getSize(previous), const Size.square(44));
    expect(tester.getSize(primary), const Size.square(48));
    expect(tester.getSize(next), const Size.square(44));
    expect(tester.getSize(timeline).height, closeTo(48, 0.1));
    expect(
      tester.getRect(controls).top,
      closeTo(tester.getRect(timeline).bottom - 6, 0.1),
    );
    expect(
      tester.getRect(previous).right,
      closeTo(tester.getRect(primary).left, 0.1),
    );
    expect(
      tester.getRect(primary).right,
      closeTo(tester.getRect(next).left, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lyrics companion keeps the Apple timeline across player styles',
    (tester) async {
      tester.view
        ..physicalSize = const Size(800, 400)
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });

      final player = _FakePlayerService(lookupSnapshot);
      final container = await _pumpLyricsPage(
        tester,
        player: player,
        lyrics: _FakeLyricsService(syncedDocument),
        platform: TargetPlatform.android,
        playerStyle: PlayerStyle.appleMusic,
      );

      final timeline = find.byKey(const ValueKey('lyrics-companion-timeline'));
      final linearTimeline = find.byKey(
        const ValueKey('lyrics-companion-linear-timeline'),
      );
      final linearSlider = find.byKey(
        const ValueKey('lyrics-companion-linear-seek'),
      );
      final sliderThemeFinder = find.byKey(
        const ValueKey('lyrics-companion-slider-theme'),
      );
      expect(timeline, findsOneWidget);
      expect(linearTimeline, findsOneWidget);
      expect(linearSlider, findsOneWidget);
      expect(tester.getSize(timeline).height, closeTo(48, 0.1));

      final appleTheme = tester.widget<SliderTheme>(sliderThemeFinder).data;
      const foreground = Colors.white;
      expect(appleTheme.trackHeight, 8);
      expect(appleTheme.activeTrackColor, foreground.withValues(alpha: 0.88));
      expect(appleTheme.inactiveTrackColor, foreground.withValues(alpha: 0.28));
      expect(appleTheme.thumbShape, same(SliderComponentShape.noThumb));
      expect(appleTheme.overlayShape, same(SliderComponentShape.noOverlay));
      expect(appleTheme.trackShape, isA<UniformPlaybackSliderTrackShape>());
      final slider = tester.widget<Slider>(linearSlider);
      expect(slider.value, lookupSnapshot.position.inMilliseconds);
      expect(slider.max, lookupSnapshot.duration!.inMilliseconds);

      final sliderRect = tester.getRect(linearSlider);
      final gesture = await tester.startGesture(
        Offset(sliderRect.left + sliderRect.width * 0.20, sliderRect.center.dy),
      );
      await tester.pump();
      await gesture.moveTo(
        Offset(sliderRect.left + sliderRect.width * 0.75, sliderRect.center.dy),
      );
      await tester.pump();
      expect(player.seekPositions, isEmpty);
      await gesture.up();
      await tester.pump();
      expect(player.seekPositions, hasLength(1));
      expect(
        player.seekPositions.single.inMilliseconds,
        closeTo(lookupSnapshot.duration!.inMilliseconds * 0.75, 3000),
      );

      await container
          .read(settingsControllerProvider.notifier)
          .setPlayerStyle(PlayerStyle.bstreamMusic);
      await tester.pump();

      expect(linearTimeline, findsOneWidget);
      expect(linearSlider, findsOneWidget);
      expect(find.byType(WavyPlaybackSeekBar), findsNothing);
      final bstreamTheme = tester.widget<SliderTheme>(sliderThemeFinder).data;
      expect(bstreamTheme.trackHeight, 8);
      expect(bstreamTheme.trackShape, isA<UniformPlaybackSliderTrackShape>());
      expect(bstreamTheme.thumbShape, same(SliderComponentShape.noThumb));
      expect(bstreamTheme.overlayShape, same(SliderComponentShape.noOverlay));
      expect(
        tester.widget<UniformPlaybackSeekBar>(timeline).position,
        lookupSnapshot.position,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android portrait adds no player chrome below lyrics', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(360, 800)
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
      platform: TargetPlatform.android,
    );

    expect(find.byKey(const ValueKey('lyrics-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-exit-button')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-player-dock')), findsNothing);
    expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('lyrics-companion-timeline')),
      findsNothing,
    );
    expect(
      tester
          .getRect(find.byKey(const ValueKey('lyrics-content-region')))
          .bottom,
      closeTo(800, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android rotation automatically switches the player layout', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(360, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final chrome = _FakeLyricsPresentationChrome();
    await _pumpLyricsPage(
      tester,
      player: _FakePlayerService(lookupSnapshot),
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.android,
      presentationChrome: chrome,
    );

    expect(find.byKey(const ValueKey('lyrics-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-exit-button')), findsNothing);
    expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsNothing,
    );
    expect(chrome.calls, isEmpty);
    final timelineElement = tester.element(
      find.byKey(const ValueKey('synced-lyrics-scroll')),
    );

    double opacityOf(String key) =>
        tester.widget<Opacity>(find.byKey(ValueKey(key))).opacity;
    double horizontalTranslationOf(String key) => tester
        .widget<Transform>(find.byKey(ValueKey(key)))
        .transform
        .getTranslation()
        .x;
    Size contentRegionSize() =>
        tester.getSize(find.byKey(const ValueKey('lyrics-content-region')));

    tester.view.physicalSize = const Size(800, 360);
    await tester.pump();

    // The first rotated frame already uses the final geometry exactly once,
    // but preserves the outgoing header as a composited overlay. The player
    // is laid out in its final slot at zero opacity.
    expect(find.byKey(const ValueKey('lyrics-header')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    expect(opacityOf('lyrics-mobile-header-layout-opacity'), 1);
    expect(opacityOf('lyrics-mobile-companion-layout-opacity'), 0);
    expect(opacityOf('lyrics-mobile-content-opacity'), closeTo(0.72, 0.001));
    expect(
      horizontalTranslationOf('lyrics-mobile-content-slide'),
      closeTo(18, 0.001),
    );
    final landscapeContentSize = contentRegionSize();
    expect(landscapeContentSize.width, closeTo(500, 0.1));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const ValueKey('lyrics-header')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    final enteringHeaderOpacity = opacityOf(
      'lyrics-mobile-header-layout-opacity',
    );
    final enteringCompanionOpacity = opacityOf(
      'lyrics-mobile-companion-layout-opacity',
    );
    expect(enteringHeaderOpacity, inExclusiveRange(0, 1));
    expect(enteringCompanionOpacity, inExclusiveRange(0, 1));
    expect(enteringHeaderOpacity + enteringCompanionOpacity, closeTo(1, 0.001));
    expect(
      horizontalTranslationOf('lyrics-mobile-companion-layout-slide'),
      inExclusiveRange(-24, 0),
    );
    expect(
      horizontalTranslationOf('lyrics-mobile-content-slide'),
      inExclusiveRange(0, 18),
    );
    expect(
      opacityOf('lyrics-mobile-content-opacity'),
      inExclusiveRange(0.72, 1),
    );
    expect(
      contentRegionSize(),
      landscapeContentSize,
      reason: 'The transition must not relayout every lyric line per frame.',
    );
    expect(
      identical(
        timelineElement,
        tester.element(find.byKey(const ValueKey('synced-lyrics-scroll'))),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 260));

    expect(find.byKey(const ValueKey('lyrics-header')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-exit-button')), findsNothing);
    expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    expect(opacityOf('lyrics-mobile-companion-layout-opacity'), 1);
    expect(opacityOf('lyrics-mobile-content-opacity'), 1);
    expect(contentRegionSize(), landscapeContentSize);
    expect(chrome.calls, [(platform: TargetPlatform.android, active: true)]);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();

    expect(find.byKey(const ValueKey('lyrics-header')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    expect(opacityOf('lyrics-mobile-header-layout-opacity'), 0);
    expect(opacityOf('lyrics-mobile-companion-layout-opacity'), 1);
    expect(opacityOf('lyrics-mobile-content-opacity'), closeTo(0.72, 0.001));
    expect(
      horizontalTranslationOf('lyrics-mobile-content-slide'),
      closeTo(-18, 0.001),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('lyrics-companion-width')))
          .width,
      closeTo(300, 0.1),
    );
    final portraitContentSize = contentRegionSize();
    expect(tester.takeException(), isNull);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byKey(const ValueKey('lyrics-header')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    final leavingHeaderOpacity = opacityOf(
      'lyrics-mobile-header-layout-opacity',
    );
    final leavingCompanionOpacity = opacityOf(
      'lyrics-mobile-companion-layout-opacity',
    );
    expect(leavingHeaderOpacity, inExclusiveRange(0, 1));
    expect(leavingCompanionOpacity, inExclusiveRange(0, 1));
    expect(leavingHeaderOpacity + leavingCompanionOpacity, closeTo(1, 0.001));
    expect(
      horizontalTranslationOf('lyrics-mobile-companion-layout-slide'),
      inExclusiveRange(-24, 0),
    );
    expect(contentRegionSize(), portraitContentSize);
    expect(
      identical(
        timelineElement,
        tester.element(find.byKey(const ValueKey('synced-lyrics-scroll'))),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 260));

    expect(find.byKey(const ValueKey('lyrics-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('lyrics-exit-button')), findsNothing);
    expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsNothing,
    );
    expect(opacityOf('lyrics-mobile-header-layout-opacity'), 1);
    expect(opacityOf('lyrics-mobile-content-opacity'), 1);
    expect(contentRegionSize(), portraitContentSize);
    expect(chrome.calls, [
      (platform: TargetPlatform.android, active: true),
      (platform: TargetPlatform.android, active: false),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rapid Android rotations cancel stale callbacks with long synced lyrics',
    (tester) async {
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });
      final longDocument = LyricsDocument(
        provider: 'Stress provider',
        trackName: 'Long song',
        artistName: 'Test artist',
        lines: List<LyricLine>.generate(
          180,
          (index) => LyricLine(
            timestamp: Duration(seconds: index * 2),
            text: 'Long synchronized lyric $index with enough words to wrap',
          ),
        ),
      );

      await _pumpLyricsPage(
        tester,
        player: _FakePlayerService(lookupSnapshot),
        lyrics: _FakeLyricsService(longDocument),
        platform: TargetPlatform.android,
      );
      final timelineElement = tester.element(
        find.byKey(const ValueKey('synced-lyrics-scroll')),
      );

      tester.view.physicalSize = const Size(800, 360);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(
                const ValueKey('lyrics-mobile-companion-layout-opacity'),
              ),
            )
            .opacity,
        inExclusiveRange(0, 1),
      );

      tester.view.physicalSize = const Size(360, 800);
      await tester.pump();
      tester.view.physicalSize = const Size(800, 360);
      await tester.pump();
      final finalGeometry = tester.getSize(
        find.byKey(const ValueKey('lyrics-content-region')),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester.getSize(find.byKey(const ValueKey('lyrics-content-region'))),
        finalGeometry,
        reason: 'Long lyrics must not be remeasured at every animation tick.',
      );
      await tester.pump(const Duration(milliseconds: 260));

      expect(find.byKey(const ValueKey('lyrics-header')), findsNothing);
      expect(
        find.byKey(const ValueKey('lyrics-playback-companion')),
        findsOneWidget,
      );
      expect(
        identical(
          timelineElement,
          tester.element(find.byKey(const ValueKey('synced-lyrics-scroll'))),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android rotation skips layout motion when animations are off', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(360, 800)
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
      platform: TargetPlatform.android,
      disableAnimations: true,
    );
    expect(find.byKey(const ValueKey('lyrics-header')), findsOneWidget);

    tester.view.physicalSize = const Size(800, 360);
    await tester.pump();

    expect(find.byKey(const ValueKey('lyrics-header')), findsNothing);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Opacity>(
            find.byKey(
              const ValueKey('lyrics-mobile-companion-layout-opacity'),
            ),
          )
          .opacity,
      1,
    );
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const ValueKey('lyrics-mobile-content-opacity')),
          )
          .opacity,
      1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics keep the default capsule visible below the content', (
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

    final toolbar = find.byKey(const ValueKey('lyrics-overlay-toolbar'));
    final exit = find.byKey(const ValueKey('lyrics-exit-button'));
    final offset = find.byKey(const ValueKey('lyrics-offset-control'));
    expect(find.byKey(const ValueKey('mini-player-frame')), findsNothing);
    expect(find.byKey(const ValueKey('lyrics-player-dock')), findsNothing);
    expect(
      find.byKey(const ValueKey('lyrics-playback-companion')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lyrics-companion-timeline')),
      findsOneWidget,
    );
    expect(toolbar, findsOneWidget);
    expect(find.descendant(of: toolbar, matching: exit), findsOneWidget);
    expect(find.descendant(of: toolbar, matching: offset), findsOneWidget);
    expect(
      tester.getRect(offset).left - tester.getRect(exit).right,
      inInclusiveRange(8, 10),
    );
    expect(find.byKey(const ValueKey('lyrics-playback-control')), findsNothing);
    expect(tester.getRect(toolbar).bottom, lessThanOrEqualTo(800 - 8 + 0.1));
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

    await _settleLyricsAnimations(tester);
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

    await _settleLyricsAnimations(tester);
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
      await _settleLyricsAnimations(tester);

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

  testWidgets('lyrics background does not add a theme accent wash', (
    tester,
  ) async {
    final player = _FakePlayerService(lookupSnapshot);
    await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
      platform: TargetPlatform.windows,
    );

    expect(find.byKey(const ValueKey('lyrics-accent-tint')), findsNothing);
  });

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
    await _settleLyricsAnimations(tester);

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
      await _settleLyricsAnimations(tester);

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

      await _settleLyricsAnimations(tester);
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

      await _settleLyricsAnimations(tester);

      final container = tester.element(
        find.byKey(const ValueKey('synced-lyrics-scroll')),
      );
      final provider = ProviderScope.containerOf(container);
      await provider
          .read(settingsControllerProvider.notifier)
          .setLyricsAnimationStyle(LyricsAnimationStyle.highlight);
      await _settleLyricsAnimations(tester);

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
      await _settleLyricsAnimations(tester);
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

    final padding = _syncedLyricsHorizontalPadding(tester);

    expect(padding.left, 12);
    expect(padding.right, 12);
    expect(_lyricLineFontSize(tester, 'active-lyric-line'), 28);
    expect(_lyricLineFontSize(tester, 'lyric-line-1'), 27);
    expect(
      _lyricLineFontSize(tester, 'active-lyric-line') -
          _lyricLineFontSize(tester, 'lyric-line-1'),
      1,
    );
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

    final padding = _syncedLyricsHorizontalPadding(tester);

    expect(padding.left, 24);
    expect(padding.right, 24);
    expect(_lyricLineFontSize(tester, 'active-lyric-line'), 34);
    expect(_lyricLineFontSize(tester, 'lyric-line-1'), 33);

    tester.view.physicalSize = const Size(1280, 800);
    await _pumpAnimatedLyrics(tester);

    expect(_lyricLineFontSize(tester, 'active-lyric-line'), 37);
    expect(_lyricLineFontSize(tester, 'lyric-line-1'), 36);
    expect(
      _lyricLineFontSize(tester, 'active-lyric-line') -
          _lyricLineFontSize(tester, 'lyric-line-1'),
      1,
    );
    expect(_activeLine('First line'), findsOneWidget);
    final activeRect = tester.getRect(
      find.byKey(const ValueKey('active-lyric-line')),
    );
    expect(activeRect.center.dy, inInclusiveRange(0, 800));
  });

  testWidgets('header progress follows the current playback fraction', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(360, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
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
      platform: TargetPlatform.android,
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
    await _settleLyricsAnimations(tester);

    expect(_renderedFraction(tester, progress, fill), closeTo(0.75, 0.01));
  });

  testWidgets('offset controls use the compact button-only layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 720);
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
      platform: TargetPlatform.windows,
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
    expect(activeLineStyle.shadows, hasLength(3));
    final haloColor = accent.computeLuminance() < 0.40
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.10), accent)
        : accent;
    expect(
      activeLineStyle.shadows?[0].color,
      haloColor.withValues(alpha: 0.30),
    );
    expect(activeLineStyle.shadows?[0].blurRadius, 10);
    expect(
      activeLineStyle.shadows?[1].color,
      haloColor.withValues(alpha: 0.14),
    );
    expect(activeLineStyle.shadows?[1].blurRadius, 24);
    expect(_lyricLineStyle(tester, 'lyric-line-1').shadows, isNull);
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

  testWidgets(
    'mobile active lyrics strengthen the outer halo without glyph tint',
    (tester) async {
      tester.view
        ..physicalSize = const Size(360, 800)
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
        platform: TargetPlatform.android,
      );

      final style = _lyricLineStyle(tester, 'active-lyric-line');
      final lineContext = tester.element(
        find.byKey(const ValueKey('active-lyric-line')),
      );
      final accent = AppColors.downloadAccentFor(lineContext);
      final haloColor = accent.computeLuminance() < 0.40
          ? Color.alphaBlend(Colors.white.withValues(alpha: 0.18), accent)
          : accent;
      expect(style.shadows, hasLength(3));
      expect(style.shadows?[0].color, haloColor.withValues(alpha: 0.48));
      expect(style.shadows?[0].blurRadius, 10);
      expect(style.shadows?[1].color, haloColor.withValues(alpha: 0.24));
      expect(style.shadows?[1].blurRadius, 26);
      expect(style.color, Colors.white);
      final activeText = tester.widget<Text>(_activeLine('First line'));
      expect(activeText.style?.foreground, isNull);
      expect(
        find.byKey(const ValueKey('mobile-active-lyric-gradient')),
        findsNothing,
      );
      if (accent.computeLuminance() < 0.40) {
        expect(
          haloColor.computeLuminance(),
          greaterThan(accent.computeLuminance()),
        );
      }
      expect(_lyricLineStyle(tester, 'lyric-line-1').shadows, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('advancing lyrics by 0.50 seconds updates the active line', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(600, 800)
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
    );

    expect(_activeLine('First line'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-offset-increase')));
    await _settleLyricsAnimations(tester);

    expect(find.textContaining('+0.50 s'), findsOneWidget);
    expect(_activeLine('Second line'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lyrics-offset-reset')));
    await _settleLyricsAnimations(tester);

    expect(find.text('+0.00 s'), findsOneWidget);
    final reset = tester.widget<TextButton>(
      find.byKey(const ValueKey('lyrics-offset-reset')),
    );
    expect(reset.onPressed, isNull);
  });

  testWidgets('lyrics offset is limited to minus and plus ten seconds', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(600, 800)
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
    tester.view
      ..physicalSize = const Size(600, 800)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final player = _FakePlayerService(lookupSnapshot);
    final container = await _pumpLyricsPage(
      tester,
      player: player,
      lyrics: _FakeLyricsService(syncedDocument),
    );

    await tester.tap(find.byKey(const ValueKey('lyrics-offset-increase')));
    await _settleLyricsAnimations(tester);
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
    await _settleLyricsAnimations(tester);
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
    await _settleLyricsAnimations(tester);
    expect(find.text('+0.00 s'), findsOneWidget);
  });

  testWidgets('tapping a synced line seeks with the selected offset', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(600, 800)
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
    );

    await tester.tap(find.byKey(const ValueKey('lyrics-offset-increase')));
    await _settleLyricsAnimations(tester);
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
    final topSource = find.byKey(const ValueKey('lyrics-source-top'));
    final bottomSource = find.byKey(const ValueKey('lyrics-source-bottom'));
    expect(find.text('Lyrics provided by LRCLIB'), findsNWidgets(2));
    expect(topSource, findsOneWidget);
    expect(bottomSource, findsOneWidget);
    expect(find.byKey(const ValueKey('synced-lyrics-scroll')), findsNothing);
    final plainText = find.byKey(const ValueKey('plain-lyrics-original'));
    expect(tester.widget<Text>(plainText).style?.fontSize, 25);
    expect(tester.widget<Text>(plainText).style?.shadows, hasLength(2));
    expect(
      tester.widget<Text>(plainText).style?.shadows?.first.color,
      AppColors.downloadAccentFor(
        tester.element(plainText),
      ).withValues(alpha: 0.16),
    );
    expect(tester.widget<Text>(plainText).textAlign, TextAlign.start);
    expect(
      tester.widget<Text>(plainText).data,
      'Plain first line\n   Plain second line',
    );
    expect(
      tester.getTopLeft(topSource).dy,
      lessThan(tester.getTopLeft(plainText).dy),
    );
    expect(
      tester.getTopLeft(bottomSource).dy,
      greaterThan(tester.getBottomLeft(plainText).dy),
    );

    await container
        .read(settingsControllerProvider.notifier)
        .setLyricsTextAlignment(LyricsTextAlignment.centered);
    await _settleLyricsAnimations(tester);

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
    await _pumpLyricsUntilVisible(tester, message);
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
      await _settleLyricsAnimations(tester);

      expect(find.byKey(const ValueKey('similar-lyrics-list')), findsOneWidget);
      expect(find.text('Libre Soy'), findsOneWidget);
      expect(find.text('Barak, Alex Campos'), findsOneWidget);
      expect(find.textContaining('3:45'), findsOneWidget);
      expect(find.textContaining('Sincronizada'), findsOneWidget);
      expect(service.similarLookups, hasLength(1));

      await tester.tap(
        find.byKey(const ValueKey('similar-lyrics-candidate-manual-1')),
      );
      await _settleLyricsAnimations(tester);

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
      await _settleLyricsAnimations(tester);
      expect(find.text('Selected first line'), findsOneWidget);

      // A remote refresh can temporarily expose no snapshot value. That is
      // not a song change and must not discard the manual selection.
      player.emit(const PlayerSnapshot(status: PlayerStatus.loading));
      await _settleLyricsAnimations(tester);
      expect(container.read(selectedLyricsControllerProvider), alternative);
      player.emit(lookupSnapshot);
      await _settleLyricsAnimations(tester);
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
      await _settleLyricsAnimations(tester);

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
    await _settleLyricsAnimations(tester);
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
    await _settleLyricsAnimations(tester);

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
    await _settleLyricsAnimations(tester);
    final field = find.byKey(const ValueKey('manual-lyrics-search-field'));
    expect(field, findsOneWidget);
    expect(service.manualLookups, isEmpty);

    await tester.enterText(field, 'Canonical alternate title');
    await tester.pump();
    expect(service.manualLookups, isEmpty);

    await tester.tap(find.byKey(const ValueKey('manual-lyrics-search-submit')));
    await _settleLyricsAnimations(tester);

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
  return _lyricLineStyle(tester, key).fontSize!;
}

TextStyle _lyricLineStyle(WidgetTester tester, String key) {
  return tester
      .widget<AnimatedDefaultTextStyle>(
        find
            .ancestor(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(AnimatedDefaultTextStyle),
            )
            .first,
      )
      .style;
}

EdgeInsets _syncedLyricsHorizontalPadding(WidgetTester tester) {
  final lineList = find.byKey(const ValueKey('synced-lyrics-virtual-list'));
  final padding = tester.widget<SliverPadding>(
    find.ancestor(of: lineList, matching: find.byType(SliverPadding)).first,
  );
  return padding.padding.resolve(TextDirection.ltr);
}

double _activeSlidePixelOffset(WidgetTester tester) {
  return _lineSlidePixelOffset(tester, 'active-lyric-line');
}

double _lyricsTransitionScale(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find.descendant(
      of: find.byKey(const ValueKey('tested-lyrics-transition')),
      matching: find.byType(Transform),
    ),
  );
  return transform.transform.entry(0, 0);
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
  final fillBox = tester.renderObject<RenderBox>(fill);
  final renderedLeft = fillBox.localToGlobal(Offset.zero).dx;
  final renderedRight = fillBox.localToGlobal(Offset(fillBox.size.width, 0)).dx;
  return (renderedRight - renderedLeft).abs() / progressWidth;
}

Color? _iconButtonBackground(
  WidgetTester tester,
  Finder finder, {
  bool disabled = false,
}) {
  final states = <WidgetState>{if (disabled) WidgetState.disabled};
  return tester
      .widget<IconButton>(finder)
      .style
      ?.backgroundColor
      ?.resolve(states);
}

Future<void> _pumpAnimatedLyrics(WidgetTester tester) async {
  await tester.pump();
  // Advance a bounded simulated window so Riverpod can finish its retry
  // schedule in error-state tests without relying on wall-clock time.
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<void> _settleLyricsAnimations(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

Future<void> _pumpLyricsUntilVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames && finder.evaluate().isEmpty; frame++) {
    await tester.pump(const Duration(seconds: 1));
  }
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
  PlayerController? playerController,
  LyricsPresentationChrome presentationChrome =
      const LyricsPresentationChrome(),
  bool disableAnimations = false,
  TargetPlatform? platform,
  double textScale = 1,
  bool deriveAppStringsFromSettings = false,
  PlayerStyle playerStyle = defaultPlayerStyle,
}) async {
  final settingsController = _FakeLyricsSettingsController(
    lyricsTextAlignment,
    lyricsAnimationStyle,
    initialLanguage: language,
    initialPlayerStyle: playerStyle,
    lyricsRomanizationEnabled: lyricsRomanizationEnabled,
    lyricsRomanizationLanguages: lyricsRomanizationLanguages,
  );
  final container = ProviderContainer(
    overrides: [
      playerServiceProvider.overrideWithValue(player),
      if (playerController != null)
        playerControllerProvider.overrideWith(() => playerController),
      favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
      lyricsServiceProvider.overrideWithValue(lyrics),
      if (!deriveAppStringsFromSettings)
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
        home: LyricsPage(presentationChrome: presentationChrome),
      ),
    ),
  );
  await _settleLyricsAnimations(tester);
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
    this.initialLanguage = AppLanguage.english,
    this.initialPlayerStyle = defaultPlayerStyle,
    this.lyricsRomanizationEnabled = false,
    this.lyricsRomanizationLanguages = defaultLyricsRomanizationLanguages,
  });

  final LyricsTextAlignment initialLyricsTextAlignment;
  final LyricsAnimationStyle initialLyricsAnimationStyle;
  final AppLanguage initialLanguage;
  final PlayerStyle initialPlayerStyle;
  final bool lyricsRomanizationEnabled;
  final Set<LyricsRomanizationLanguage> lyricsRomanizationLanguages;

  @override
  Future<SettingsState> build() async => SettingsState(
    downloadDirectory: '/tmp/bstream-lyrics-test',
    language: initialLanguage,
    playerStyle: initialPlayerStyle,
    lyricsTextAlignment: initialLyricsTextAlignment,
    lyricsAnimationStyle: initialLyricsAnimationStyle,
    lyricsRomanizationEnabled: lyricsRomanizationEnabled,
    lyricsRomanizationLanguages: lyricsRomanizationLanguages,
  );

  void emitLanguage(AppLanguage language) {
    final current = state.value;
    if (current != null) {
      state = AsyncData(current.copyWith(language: language));
    }
  }

  @override
  Future<void> setPlayerStyle(PlayerStyle style) async {
    final current = await future;
    state = AsyncData(current.copyWith(playerStyle: style));
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

class _FakeLyricsPresentationChrome extends LyricsPresentationChrome {
  final List<({TargetPlatform platform, bool active})> calls = [];

  @override
  Future<void> setSideModeActive({
    required TargetPlatform platform,
    required bool active,
  }) async {
    calls.add((platform: platform, active: active));
  }
}

class _LyricsTransportPlayerController extends PlayerController {
  _LyricsTransportPlayerController(this._snapshot);

  PlayerSnapshot _snapshot;
  int toggleCalls = 0;
  int previousCalls = 0;
  int nextCalls = 0;
  final List<bool> nextAutomaticValues = [];

  @override
  Future<PlayerSnapshot> build() async => _snapshot;

  void emit(PlayerSnapshot snapshot) {
    _snapshot = snapshot;
    state = AsyncData(snapshot);
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
    nextAutomaticValues.add(automatic);
  }
}
