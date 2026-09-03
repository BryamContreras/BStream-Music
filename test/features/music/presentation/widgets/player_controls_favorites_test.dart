import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/core/widgets/marquee_text.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/animated_artwork_motion.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/features/music/presentation/widgets/uniform_playback_slider_track_shape.dart';
import 'package:bstream_music/features/music/presentation/widgets/wavy_playback_seek_bar.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/sharing/track_share_service.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const trackId = 'player-controls-track';
  final localTrack = LocalTrack(
    id: trackId,
    title: 'Cancion de prueba',
    artist: 'BStream Music',
    filePath: '/tmp/player-controls-track.m4a',
    addedAt: DateTime(2026),
  );
  const snapshot = PlayerSnapshot(
    status: PlayerStatus.paused,
    title: 'Cancion de prueba',
    artist: 'BStream Music',
    trackId: trackId,
    duration: Duration(minutes: 3),
    volume: 0.72,
  );

  for (final style in PlayerStyle.values) {
    testWidgets(
      '${style.name} applies the animated artwork preference to the large cover',
      (tester) async {
        _configureView(tester, const Size(390, 820));
        final trackWithArtwork = LocalTrack(
          id: trackId,
          title: 'Cancion de prueba',
          artist: 'BStream Music',
          filePath: '/tmp/player-controls-track.m4a',
          thumbnailPath: '/tmp/player-controls-cover.jpg',
          addedAt: DateTime(2026),
        );

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
            animatedArtworkEnabled: true,
          ),
        );
        await tester.pump();

        final artwork = find.byKey(const ValueKey('player-large-artwork'));
        final motion = find.descendant(
          of: artwork,
          matching: find.byType(AnimatedArtworkMotion),
        );
        expect(motion, findsOneWidget);
        expect(tester.widget<AnimatedArtworkMotion>(motion).enabled, isTrue);
        expect(tester.widget<AnimatedArtworkMotion>(motion).isPlaying, isFalse);

        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('${style.name}-playing-artwork-disabled'),
            platform: TargetPlatform.android,
            snapshot: snapshot.copyWith(status: PlayerStatus.playing),
            localTrack: trackWithArtwork,
            playlists: _TestPlaylistsController(),
            style: style,
            animatedArtworkEnabled: false,
          ),
        );
        await tester.pump();

        expect(
          tester
              .widget<AnimatedArtworkMotion>(
                find.descendant(
                  of: find.byKey(const ValueKey('player-large-artwork')),
                  matching: find.byType(AnimatedArtworkMotion),
                ),
              )
              .enabled,
          isFalse,
        );
        expect(
          tester
              .widget<AnimatedArtworkMotion>(
                find.descendant(
                  of: find.byKey(const ValueKey('player-large-artwork')),
                  matching: find.byType(AnimatedArtworkMotion),
                ),
              )
              .isPlaying,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('downloaded playback replaces a soft file with catalog artwork', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final sharpLocalTrack = LocalTrack(
      id: trackId,
      title: 'Cancion de prueba',
      artist: 'BStream Music',
      filePath: '/tmp/player-controls-track.m4a',
      thumbnailPath: '/tmp/soft-player-cover.jpg',
      catalogThumbnailUrl:
          'https://lh3.googleusercontent.com/player-cover=w120-h120-l90-rj',
      addedAt: DateTime(2026),
    );

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: sharpLocalTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump();

    final artwork = find.byKey(const ValueKey('player-large-artwork'));
    final image = tester.widget<ProportionalArtwork>(
      find.descendant(of: artwork, matching: find.byType(ProportionalArtwork)),
    );
    expect(
      image.source,
      'https://lh3.googleusercontent.com/player-cover=w1280-h1280-l90-rj',
    );
    expect(image.fallbackSource, sharpLocalTrack.thumbnailPath);
  });

  for (final size in const [Size(320, 720), Size(360, 800)]) {
    testWidgets(
      'Android ${size.width.toInt()} px stacks labeled secondary controls',
      (tester) async {
        _configureView(tester, size);
        final playlists = _TestPlaylistsController();

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: playlists,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final lyrics = find.byKey(const ValueKey('player-lyrics-control'));
        final shuffle = find.byKey(const ValueKey('player-shuffle-control'));
        final volume = find.byKey(const ValueKey('player-volume-control'));
        final repeat = find.byKey(const ValueKey('player-repeat-control'));
        final primary = find.byKey(const ValueKey('player-primary-control'));
        final previous = find.byKey(const ValueKey('player-previous-control'));
        final next = find.byKey(const ValueKey('player-next-control'));
        final artwork = find.byKey(const ValueKey('player-large-artwork'));
        final header = find.byKey(const ValueKey('player-header'));

        expect(
          find.descendant(of: lyrics, matching: find.text('Letras')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: volume, matching: find.text('Volumen')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: lyrics,
            matching: find.byIcon(Icons.lyrics_rounded),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: volume,
            matching: find.byIcon(Icons.volume_up_rounded),
          ),
          findsOneWidget,
        );
        expect(
          tester.getCenter(lyrics).dy,
          greaterThan(tester.getCenter(shuffle).dy),
        );
        expect(
          tester.getCenter(volume).dy,
          greaterThan(tester.getCenter(repeat).dy),
        );
        expect(
          tester.getCenter(lyrics).dx,
          lessThan(tester.getCenter(primary).dx),
        );
        expect(
          tester.getCenter(shuffle).dx,
          lessThan(tester.getCenter(primary).dx),
        );
        expect(
          tester.getCenter(volume).dx,
          greaterThan(tester.getCenter(primary).dx),
        );
        expect(
          tester.getCenter(repeat).dx,
          greaterThan(tester.getCenter(primary).dx),
        );
        expect(
          tester.getSize(lyrics).width,
          greaterThan(tester.getSize(shuffle).width),
        );
        expect(
          tester.getSize(volume).width,
          greaterThan(tester.getSize(repeat).width),
        );
        final expectedLabelWidth = ((size.width - 40) * 0.36).clamp(
          112.0,
          132.0,
        );
        expect(tester.getSize(lyrics), Size(expectedLabelWidth, 48));
        expect(tester.getSize(volume), Size(expectedLabelWidth, 48));
        expect(tester.getSize(lyrics).width, lessThan(128));
        expect(tester.getRect(lyrics).left, closeTo(20, 0.1));
        expect(tester.getRect(volume).right, closeTo(size.width - 20, 0.1));
        final artworkSize = tester.getSize(artwork);
        expect(artworkSize.width, lessThanOrEqualTo(size.width - 48));
        expect(artworkSize.width, greaterThanOrEqualTo(180));
        expect(artworkSize.height, closeTo(artworkSize.width, 0.1));
        final artworkTopGap =
            tester.getRect(artwork).top - tester.getRect(header).bottom;
        expect(artworkTopGap, lessThanOrEqualTo(size.width == 320 ? 100 : 112));
        final lyricsIcon = tester.widget<Icon>(
          find.descendant(
            of: lyrics,
            matching: find.byIcon(Icons.lyrics_rounded),
          ),
        );
        final lyricsLabel = tester.widget<Text>(
          find.descendant(of: lyrics, matching: find.text('Letras')),
        );
        final lyricsButton = tester.widget<TextButton>(
          find.descendant(of: lyrics, matching: find.byType(TextButton)),
        );
        final volumeButton = tester.widget<TextButton>(
          find.descendant(of: volume, matching: find.byType(TextButton)),
        );
        expect(lyricsIcon.size, 24);
        expect(lyricsLabel.style?.fontSize, 14);
        expect(
          lyricsButton.style?.backgroundColor?.resolve(<WidgetState>{}),
          Colors.transparent,
        );
        expect(
          volumeButton.style?.backgroundColor?.resolve(<WidgetState>{}),
          Colors.transparent,
        );
        expect(
          lyricsButton.style?.backgroundColor?.resolve(<WidgetState>{
            WidgetState.disabled,
          }),
          Colors.transparent,
        );
        expect(
          volumeButton.style?.backgroundColor?.resolve(<WidgetState>{
            WidgetState.disabled,
          }),
          Colors.transparent,
        );
        expect(
          lyricsButton.style?.shape?.resolve(<WidgetState>{}),
          isA<RoundedRectangleBorder>(),
        );

        final contentWidth = size.width - 40;
        final originalRegularPlaySize = (contentWidth * 0.22).clamp(64.0, 88.0);
        final originalPlaySize = (originalRegularPlaySize + 6).clamp(
          76.0,
          94.0,
        );
        expect(
          tester.getSize(primary),
          Size.square(originalPlaySize.toDouble()),
        );
        _expectTransparentPrimaryControl(tester, mobile: true);
        expect(tester.getSize(previous).shortestSide, greaterThanOrEqualTo(52));
        expect(tester.getSize(next).shortestSide, greaterThanOrEqualTo(52));

        if (size.width == 360) {
          final shuffleRect = tester.getRect(shuffle);
          final previousRect = tester.getRect(previous);
          final primaryRect = tester.getRect(primary);
          final nextRect = tester.getRect(next);
          final repeatRect = tester.getRect(repeat);
          expect(
            previousRect.left - shuffleRect.right,
            greaterThanOrEqualTo(6),
          );
          expect(
            primaryRect.left - previousRect.right,
            greaterThanOrEqualTo(6),
          );
          expect(nextRect.left - primaryRect.right, greaterThanOrEqualTo(6));
          expect(repeatRect.left - nextRect.right, greaterThanOrEqualTo(6));
        }
        await tester.ensureVisible(volume);
        expect(size.height - tester.getRect(volume).bottom, closeTo(16, 0.1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final variant in const [
    (
      name: 'Android 390 playing',
      size: Size(390, 820),
      status: PlayerStatus.playing,
    ),
    (
      name: 'Android 430 paused',
      size: Size(430, 900),
      status: PlayerStatus.paused,
    ),
  ]) {
    testWidgets('${variant.name} keeps a visually dominant primary glyph', (
      tester,
    ) async {
      _configureView(tester, variant.size);
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot.copyWith(status: variant.status),
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      _expectTransparentPrimaryControl(tester, mobile: true);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('player-primary-control')),
          matching: find.byIcon(
            variant.status == PlayerStatus.playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final variant in const [
    (name: 'Android', size: Size(360, 800), platform: TargetPlatform.android),
    (name: 'Windows', size: Size(1280, 720), platform: TargetPlatform.windows),
  ]) {
    testWidgets('${variant.name} progress drag commits only its final seek', (
      tester,
    ) async {
      _configureView(tester, variant.size);
      final controller = _TestPlayerController(snapshot);
      await tester.pumpWidget(
        _playerHarness(
          platform: variant.platform,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final progress = find.byKey(
        const ValueKey('player-progress-color-animation'),
      );
      final rect = tester.getRect(progress);
      final gesture = await tester.startGesture(
        Offset(rect.right - 12, rect.center.dy),
      );
      await gesture.moveTo(Offset(rect.center.dx, rect.center.dy));
      await gesture.moveTo(Offset(rect.left + 12, rect.center.dy));
      await gesture.moveTo(Offset(rect.left - 20, rect.center.dy));
      await tester.pump();
      expect(controller.seekCalls, 0);

      await gesture.up();
      await tester.pump();
      expect(controller.seekCalls, 1);
      expect(controller.lastSeek, Duration.zero);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'BStream player keeps its wave progress and compact volume thumb',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.byType(WavyPlaybackSeekBar), findsOneWidget);
      expect(find.byKey(const ValueKey('player-linear-seek')), findsNothing);
      final progressAnimation = find.byKey(
        const ValueKey('player-progress-color-animation'),
      );
      expect(
        tester
            .widget<TweenAnimationBuilder<Color?>>(progressAnimation)
            .tween
            .end,
        AppColors.downloadAccentFor(tester.element(progressAnimation)),
      );

      await tester.tap(find.byKey(const ValueKey('player-volume-control')));
      await tester.pump(const Duration(milliseconds: 300));

      final popover = find.byKey(const ValueKey('volume-popover'));
      final volumeTheme = tester
          .widget<SliderTheme>(
            find.descendant(of: popover, matching: find.byType(SliderTheme)),
          )
          .data;
      expect(volumeTheme.trackHeight, 2.5);
      expect(
        volumeTheme.trackShape,
        isNot(isA<UniformPlaybackSliderTrackShape>()),
      );
      expect(
        volumeTheme.thumbShape,
        isA<RoundSliderThumbShape>().having(
          (shape) => shape.enabledThumbRadius,
          'enabledThumbRadius',
          7,
        ),
      );
      expect(
        volumeTheme.overlayShape,
        isA<RoundSliderOverlayShape>().having(
          (shape) => shape.overlayRadius,
          'overlayRadius',
          13,
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('liquid volume popover delegates its complete material paint', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        backgroundMode: SurfaceBackgroundMode.liquidGlass,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('player-volume-control')));
    await tester.pump(const Duration(milliseconds: 300));

    final popover = tester.widget<Container>(
      find.byKey(const ValueKey('volume-popover')),
    );
    final decoration = popover.decoration! as BoxDecoration;
    expect(decoration.color, isNull);
    expect(decoration.gradient, isNull);
    expect(decoration.border, isNull);

    final glass = find.byKey(const ValueKey('volume-popover-liquid-glass'));
    expect(glass, findsOneWidget);
    expect(
      find.descendant(
        of: glass,
        matching: find.byKey(LiquidGlassSurface.opticsKey),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Apple Music Style orders artwork, metadata, timeline and controls',
    (tester) async {
      _configureView(tester, const Size(390, 820));

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot.copyWith(position: const Duration(minutes: 1)),
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      for (final key in const [
        'apple-player-layout',
        'apple-player-grabber',
        'apple-player-adaptive-stack',
        'player-large-artwork',
        'apple-player-metadata',
        'player-track-title',
        'player-track-artist',
        'player-favorite-control',
        'player-menu-control',
        'apple-player-menu-surface',
        'apple-player-timeline',
        'apple-player-linear-seek',
        'apple-player-position',
        'apple-player-remaining',
        'apple-player-transport',
        'player-previous-control',
        'player-primary-control',
        'player-next-control',
        'player-volume-control',
        'apple-player-volume-row',
        'apple-player-volume-slider',
        'apple-player-utility-row',
        'player-lyrics-control',
        'player-shuffle-control',
        'player-repeat-control',
        'player-queue-toggle',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }

      final orderedBlocks = [
        find.byKey(const ValueKey('player-large-artwork')),
        find.byKey(const ValueKey('apple-player-metadata')),
        find.byKey(const ValueKey('apple-player-timeline')),
        find.byKey(const ValueKey('apple-player-transport')),
        find.byKey(const ValueKey('apple-player-volume-row')),
        find.byKey(const ValueKey('apple-player-utility-row')),
      ];
      for (var index = 1; index < orderedBlocks.length; index += 1) {
        expect(
          tester.getRect(orderedBlocks[index]).top,
          greaterThanOrEqualTo(tester.getRect(orderedBlocks[index - 1]).bottom),
          reason: 'block $index must follow block ${index - 1}',
        );
      }
      expect(find.byKey(const ValueKey('player-header')), findsNothing);
      expect(find.byKey(const ValueKey('player-content-scroll')), findsNothing);
      expect(find.byKey(const ValueKey('apple-player-scroll')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Apple Music Style fits standard phones without a scrolling player',
    (tester) async {
      const viewports = [
        Size(320, 568),
        Size(360, 640),
        Size(390, 820),
        Size(820, 390),
      ];
      _configureView(tester, viewports.first);

      for (final viewport in viewports) {
        tester.view.physicalSize = viewport;
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey('apple-${viewport.width}x${viewport.height}'),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            style: PlayerStyle.appleMusic,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('apple-player-scroll')),
          findsNothing,
          reason: '$viewport',
        );
        expect(
          find.byKey(
            ValueKey(
              viewport.width > viewport.height
                  ? 'apple-player-adaptive-two-column'
                  : 'apple-player-adaptive-stack',
            ),
          ),
          findsOneWidget,
          reason: '$viewport',
        );
        for (final key in const [
          'player-large-artwork',
          'apple-player-metadata',
          'apple-player-timeline',
          'apple-player-transport',
          'apple-player-volume-row',
          'apple-player-utility-row',
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          expect(rect.top, greaterThanOrEqualTo(0), reason: '$viewport $key');
          expect(
            rect.bottom,
            lessThanOrEqualTo(viewport.height),
            reason: '$viewport $key',
          );
        }
        final artworkSize = tester.getSize(
          find.byKey(const ValueKey('player-large-artwork')),
        );
        expect(artworkSize.width, closeTo(artworkSize.height, 0.1));
        expect(artworkSize.shortestSide, greaterThanOrEqualTo(120));
        if (viewport == const Size(320, 568)) {
          expect(
            artworkSize.shortestSide,
            greaterThanOrEqualTo(205),
            reason:
                'compact Apple layout should give the cover reclaimed height',
          );
        }
        expect(tester.takeException(), isNull, reason: '$viewport');
      }
    },
  );

  testWidgets(
    'Apple Music Style uses the safe area and stays continuous near 760 px',
    (tester) async {
      const cases = <({Size size, double bottomInset})>[
        (size: Size(390, 770), bottomInset: 0),
        (size: Size(360, 720), bottomInset: 24),
        (size: Size(360, 770), bottomInset: 34),
        (size: Size(360, 759), bottomInset: 0),
        (size: Size(360, 760), bottomInset: 0),
        (size: Size(360, 761), bottomInset: 0),
      ];
      _configureView(
        tester,
        cases.first.size,
        bottomPadding: cases.first.bottomInset,
      );
      final extents = <double>[];

      for (final testCase in cases) {
        tester.view
          ..physicalSize = testCase.size
          ..padding = FakeViewPadding(bottom: testCase.bottomInset);
        await tester.pumpWidget(
          _playerHarness(
            key: ValueKey(
              'apple-safe-${testCase.size.height}-${testCase.bottomInset}',
            ),
            platform: TargetPlatform.android,
            snapshot: snapshot,
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
            style: PlayerStyle.appleMusic,
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        expect(
          find.byKey(const ValueKey('apple-player-scroll')),
          findsNothing,
          reason: '$testCase',
        );
        final grabber = tester.getRect(
          find.byKey(const ValueKey('apple-player-grabber')),
        );
        final artwork = tester.getRect(
          find.byKey(const ValueKey('player-large-artwork')),
        );
        final utility = tester.getRect(
          find.byKey(const ValueKey('apple-player-utility-row')),
        );
        expect(
          artwork.top - grabber.bottom,
          lessThanOrEqualTo(12.1),
          reason: '$testCase',
        );
        expect(
          utility.bottom,
          lessThanOrEqualTo(testCase.size.height - testCase.bottomInset),
          reason: '$testCase',
        );
        expect(tester.takeException(), isNull, reason: '$testCase');
        if (testCase.bottomInset == 0 &&
            testCase.size.width == 360 &&
            testCase.size.height >= 759) {
          extents.add(artwork.width);
        }
      }

      expect(extents, hasLength(3));
      expect((extents[1] - extents[0]).abs(), lessThanOrEqualTo(1));
      expect((extents[2] - extents[1]).abs(), lessThanOrEqualTo(1));
    },
  );

  testWidgets(
    'Apple Music Style aligns compact artist actions and enlarges transport',
    (tester) async {
      _configureView(tester, const Size(390, 820));

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final metadata = tester.getRect(
        find.byKey(const ValueKey('apple-player-metadata')),
      );
      final artist = tester.getRect(
        find.byKey(const ValueKey('player-track-artist')),
      );
      final favoriteSurface = tester.getRect(
        find.byKey(const ValueKey('apple-player-favorite-surface')),
      );
      final menuSurface = tester.getRect(
        find.byKey(const ValueKey('apple-player-menu-surface')),
      );

      expect(favoriteSurface.size, const Size.square(40));
      expect(menuSurface.size, const Size.square(40));
      expect(favoriteSurface.center.dy, closeTo(artist.center.dy, 1));
      expect(menuSurface.center.dy, closeTo(artist.center.dy, 1));

      for (final key in const [
        'player-favorite-control',
        'player-menu-control',
      ]) {
        final target = tester.getSize(find.byKey(ValueKey(key)));
        expect(target.width, greaterThanOrEqualTo(48), reason: '$key width');
        expect(target.height, greaterThanOrEqualTo(48), reason: '$key height');
      }

      final favoriteButton = tester.widget<IconButton>(
        find.byKey(const ValueKey('player-favorite-control')),
      );
      final menuIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('apple-player-menu-surface')),
          matching: find.byType(Icon),
        ),
      );
      expect(favoriteButton.iconSize, inInclusiveRange(20, 24));
      expect(menuIcon.size, inInclusiveRange(20, 24));

      final previous = find.byKey(const ValueKey('player-previous-control'));
      final primary = find.byKey(const ValueKey('player-primary-control'));
      final next = find.byKey(const ValueKey('player-next-control'));
      expect(tester.getSize(previous), const Size.square(80));
      expect(tester.getSize(primary), const Size.square(96));
      expect(tester.getSize(next), const Size.square(80));
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: previous, matching: find.byType(IconButton)),
            )
            .iconSize,
        52,
      );
      expect(tester.widget<IconButton>(primary).iconSize, 76);
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: next, matching: find.byType(IconButton)),
            )
            .iconSize,
        52,
      );

      final position = tester.getRect(
        find.byKey(const ValueKey('apple-player-position')),
      );
      final remaining = tester.getRect(
        find.byKey(const ValueKey('apple-player-remaining')),
      );
      expect(position.left, greaterThanOrEqualTo(metadata.left + 11.5));
      expect(remaining.right, lessThanOrEqualTo(metadata.right - 11.5));

      SliderThemeData localSliderTheme(String sliderKey) {
        final themes = find.ancestor(
          of: find.byKey(ValueKey(sliderKey)),
          matching: find.byType(SliderTheme),
        );
        expect(themes, findsWidgets, reason: sliderKey);
        return tester.widget<SliderTheme>(themes.first).data;
      }

      final seekTheme = localSliderTheme('apple-player-linear-seek');
      final volumeTheme = localSliderTheme('apple-player-volume-slider');
      expect(seekTheme.trackHeight, 7);
      expect(volumeTheme.trackHeight, 7);
      expect(
        seekTheme.trackShape.runtimeType,
        volumeTheme.trackShape.runtimeType,
      );
      expect(
        seekTheme.trackShape.runtimeType,
        isNot(RoundedRectSliderTrackShape),
      );
      expect(seekTheme.trackShape.runtimeType, isNot(GappedSliderTrackShape));
      expect(seekTheme.thumbShape, same(SliderComponentShape.noThumb));
      expect(volumeTheme.thumbShape, same(SliderComponentShape.noThumb));
      expect(seekTheme.overlayShape, same(SliderComponentShape.noOverlay));
      expect(volumeTheme.overlayShape, same(SliderComponentShape.noOverlay));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Apple Music Style keeps text scale 3 utility controls reachable',
    (tester) async {
      _configureView(tester, const Size(320, 568), textScaleFactor: 3);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(find.byKey(const ValueKey('apple-player-scroll')), findsOneWidget);

      for (final key in const [
        'player-lyrics-control',
        'player-queue-toggle',
      ]) {
        final control = find.byKey(ValueKey(key));
        await tester.ensureVisible(control);
        await tester.pump();
        expect(control, findsOneWidget, reason: key);
        expect(
          tester.getRect(control).top,
          greaterThanOrEqualTo(0),
          reason: key,
        );
        expect(
          tester.getRect(control).bottom,
          lessThanOrEqualTo(568),
          reason: key,
        );
      }

      for (final key in const [
        'player-favorite-control',
        'player-menu-control',
        'player-previous-control',
        'player-primary-control',
        'player-next-control',
        'player-volume-control',
        'player-lyrics-control',
        'player-shuffle-control',
        'player-repeat-control',
        'player-queue-toggle',
      ]) {
        final size = tester.getSize(find.byKey(ValueKey(key)));
        expect(size.width, greaterThanOrEqualTo(48), reason: key);
        expect(size.height, greaterThanOrEqualTo(48), reason: key);
      }
      expect(
        tester.getSize(
          find.byKey(const ValueKey('apple-player-favorite-surface')),
        ),
        const Size.square(40),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('apple-player-menu-surface'))),
        const Size.square(40),
      );

      final previous = find.byKey(const ValueKey('player-previous-control'));
      final primary = find.byKey(const ValueKey('player-primary-control'));
      final next = find.byKey(const ValueKey('player-next-control'));
      expect(tester.getSize(previous).shortestSide, greaterThanOrEqualTo(68));
      expect(tester.getSize(primary).shortestSide, greaterThanOrEqualTo(82));
      expect(tester.getSize(next).shortestSide, greaterThanOrEqualTo(68));
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: previous, matching: find.byType(IconButton)),
            )
            .iconSize,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.widget<IconButton>(primary).iconSize,
        greaterThanOrEqualTo(66),
      );
      expect(
        tester
            .widget<IconButton>(
              find.descendant(of: next, matching: find.byType(IconButton)),
            )
            .iconSize,
        greaterThanOrEqualTo(44),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Apple Music Style timeline commits one final seek and shows remaining time',
    (tester) async {
      _configureView(tester, const Size(390, 820));
      final controller = _TestPlayerController(
        snapshot.copyWith(position: const Duration(minutes: 1, seconds: 41)),
      );

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: controller.snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
          style: PlayerStyle.appleMusic,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('apple-player-remaining')))
            .data,
        '\u22121:19',
      );

      final seek = find.byKey(const ValueKey('apple-player-linear-seek'));
      final rect = tester.getRect(seek);
      final gesture = await tester.startGesture(
        Offset(rect.right - 20, rect.center.dy),
      );
      await gesture.moveTo(Offset(rect.center.dx, rect.center.dy));
      await gesture.moveTo(Offset(rect.left + 20, rect.center.dy));
      await tester.pump();
      expect(controller.seekCalls, 0);

      await gesture.up();
      await tester.pump();
      expect(controller.seekCalls, 1);
      expect(controller.lastSeek, isNotNull);
      expect(controller.lastSeek!, lessThan(const Duration(minutes: 1)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Apple Music Style volume slider invokes setVolume', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));
    final controller = _TestPlayerController(snapshot);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: controller,
        style: PlayerStyle.appleMusic,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final volume = find.byKey(const ValueKey('apple-player-volume-slider'));
    await tester.ensureVisible(volume);
    await tester.pump();
    final rect = tester.getRect(volume);
    await tester.tapAt(Offset(rect.left + (rect.width * 0.25), rect.center.dy));
    await tester.pump();

    expect(controller.volumeCalls, greaterThan(0));
    expect(controller.lastVolume, isNotNull);
    expect(controller.lastVolume!, inInclusiveRange(0.0, 1.0));
    expect(controller.lastVolume!, isNot(closeTo(snapshot.volume, 0.01)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Apple Music Style opens and closes the mobile playback queue', (
    tester,
  ) async {
    _configureView(tester, const Size(390, 820));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        style: PlayerStyle.appleMusic,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.textContaining('Cola de'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final queueTitle = find.textContaining('Cola de');
    expect(queueTitle, findsOneWidget);
    expect(find.byTooltip('Cerrar'), findsOneWidget);
    expect(ModalRoute.of(tester.element(queueTitle))?.isCurrent, isTrue);
    expect(
      find.byKey(const ValueKey('apple-player-layout'), skipOffstage: false),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Cerrar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.textContaining('Cola de'), findsNothing);
    final appleLayout = find.byKey(const ValueKey('apple-player-layout'));
    expect(appleLayout, findsOneWidget);
    expect(ModalRoute.of(tester.element(appleLayout))?.isCurrent, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Apple Music Style toggles the desktop playback queue rail', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 720));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        style: PlayerStyle.appleMusic,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final toggle = find.byKey(const ValueKey('player-queue-toggle'));
    final rail = find.byKey(const ValueKey('desktop-playback-queue-rail'));
    final switcher = find.byKey(
      const ValueKey('desktop-playback-queue-switcher'),
    );
    expect(rail, findsNothing);
    expect(tester.getSize(switcher).width, closeTo(0, 0.1));

    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(rail, findsOneWidget);
    expect(tester.getSize(rail).width, closeTo(400, 0.1));
    expect(tester.getRect(rail).right, lessThanOrEqualTo(1280));
    expect(tester.getRect(rail).bottom, lessThanOrEqualTo(720));
    expect(tester.takeException(), isNull);

    await tester.tap(toggle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(rail, findsNothing);
    expect(tester.getSize(switcher).width, closeTo(0, 0.1));
    expect(find.byKey(const ValueKey('apple-player-layout')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows keeps secondary controls in one row', (tester) async {
    _configureView(tester, const Size(1280, 720));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final lyrics = find.byKey(const ValueKey('player-lyrics-control'));
    final shuffle = find.byKey(const ValueKey('player-shuffle-control'));
    final volume = find.byKey(const ValueKey('player-volume-control'));
    final repeat = find.byKey(const ValueKey('player-repeat-control'));

    expect(
      tester.getCenter(lyrics).dy,
      closeTo(tester.getCenter(shuffle).dy, 0.1),
    );
    expect(
      tester.getCenter(volume).dy,
      closeTo(tester.getCenter(repeat).dy, 0.1),
    );
    expect(
      find.descendant(of: lyrics, matching: find.text('Letras')),
      findsNothing,
    );
    expect(
      find.descendant(of: volume, matching: find.text('Volumen')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('player-favorite-control')),
      findsOneWidget,
    );
    _expectTransparentPrimaryControl(tester, mobile: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320x568 player keeps text scale 3 controls reachable', (
    tester,
  ) async {
    _configureView(tester, const Size(320, 568), textScaleFactor: 3);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    for (final key in const [
      'player-favorite-control',
      'player-lyrics-control',
      'player-shuffle-control',
      'player-primary-control',
      'player-repeat-control',
      'player-volume-control',
    ]) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      expect(rect.width, greaterThanOrEqualTo(48), reason: key);
      expect(rect.height, greaterThanOrEqualTo(48), reason: key);
    }
    expect(
      tester.getSize(find.byKey(const ValueKey('player-primary-control'))),
      const Size.square(76),
    );
    _expectTransparentPrimaryControl(tester, mobile: true);
    final volume = find.byKey(const ValueKey('player-volume-control'));
    await tester.ensureVisible(volume);
    await tester.pump();
    expect(tester.getRect(volume).bottom, lessThanOrEqualTo(568));
    expect(tester.takeException(), isNull);
  });

  for (final variant in const [
    (size: Size(320, 720), textScale: 1.0),
    (size: Size(390, 820), textScale: 1.6),
  ]) {
    testWidgets(
      '${variant.size.width.toInt()} px Android contains multiline CJK metadata',
      (tester) async {
        _configureView(
          tester,
          variant.size,
          textScaleFactor: variant.textScale,
        );

        await tester.pumpWidget(
          _playerHarness(
            platform: TargetPlatform.android,
            snapshot: snapshot.copyWith(
              title: '夜空に輝く星を見上げながら一緒に歌う長い日本語の曲名',
              artist: 'とても長い日本語のアーティスト名',
            ),
            localTrack: localTrack,
            playlists: _TestPlaylistsController(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();

        final metadata = tester.getRect(
          find.byKey(const ValueKey('player-stable-metadata')),
        );
        final title = find.byKey(const ValueKey('player-track-title'));
        final artist = find.byKey(const ValueKey('player-track-artist'));
        final titleText = tester.widget<MarqueeText>(title);
        expect(titleText.text, contains('夜空'));
        expect(
          find.ancestor(of: title, matching: find.byType(Positioned)),
          findsNothing,
        );
        expect(tester.getRect(title).top, greaterThanOrEqualTo(metadata.top));
        expect(
          tester.getRect(artist).bottom,
          lessThanOrEqualTo(metadata.bottom + 0.1),
        );

        final volume = find.byKey(const ValueKey('player-volume-control'));
        await tester.ensureVisible(volume);
        await tester.pump();
        expect(tester.getSize(volume).height, 48);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'short Android viewports preserve artwork and compact only spacing',
    (tester) async {
      _configureView(tester, const Size(360, 720), bottomPadding: 24);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          key: const ValueKey('error-artwork-baseline'),
          snapshot: snapshot.copyWith(
            status: PlayerStatus.failed,
            errorMessage: 'No se pudo abrir la pista.',
          ),
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final errorArtworkWidth = tester
          .getSize(find.byKey(const ValueKey('player-large-artwork')))
          .width;

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          key: const ValueKey('normal-artwork-short-viewport'),
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final artwork = find.byKey(const ValueKey('player-large-artwork'));
      final volume = find.byKey(const ValueKey('player-volume-control'));
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('player-content-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      final artworkWidth = tester.getSize(artwork).width;
      expect(errorArtworkWidth, closeTo(artworkWidth, 0.1));
      expect(tester.getSize(volume).width, greaterThanOrEqualTo(112));
      expect(tester.getSize(volume).height, 48);
      expect(scroll.position.pixels, closeTo(0, 0.1));
      expect(scroll.position.maxScrollExtent, closeTo(0, 0.1));
      expect(
        tester.getRect(volume).bottom,
        lessThanOrEqualTo(720 - 24.0 + 0.1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short Android frames compact the artwork shadow and balance the header',
    (tester) async {
      _configureView(tester, const Size(430, 900));

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      BoxShadow artworkShadow() {
        final surface = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('player-artwork-surface')),
        );
        return (surface.decoration as BoxDecoration).boxShadow!.single;
      }

      final artwork = find.byKey(const ValueKey('player-large-artwork'));
      final header = find.byKey(const ValueKey('player-header'));
      final contentScroll = find.byKey(const ValueKey('player-content-scroll'));
      final metadata = find.byKey(const ValueKey('player-stable-metadata'));
      final timeline = find.byKey(const ValueKey('player-timeline'));
      final playbackControls = find.byKey(
        const ValueKey('player-playback-controls'),
      );
      final longShadow = artworkShadow();
      expect(tester.getRect(header).top, closeTo(10, 0.1));
      expect(
        tester.getRect(find.byKey(const ValueKey('player-track-title'))).top -
            tester.getRect(artwork).bottom,
        closeTo(22, 0.1),
      );
      expect(
        tester.getRect(timeline).top - tester.getRect(metadata).bottom,
        closeTo(22, 0.1),
      );
      expect(
        tester.getRect(playbackControls).top - tester.getRect(timeline).bottom,
        closeTo(18, 0.1),
      );
      expect(longShadow.blurRadius, 42);
      expect(longShadow.spreadRadius, 6);
      expect(longShadow.offset.dy, 18);
      expect(longShadow.color.a, closeTo(0.67, 0.001));
      expect(
        tester.widget<SingleChildScrollView>(contentScroll).clipBehavior,
        Clip.hardEdge,
      );
      expect(
        find.byKey(const ValueKey('player-content-shadow-clip')),
        findsNothing,
      );
      final roomyScroll = tester.state<ScrollableState>(
        find.descendant(of: contentScroll, matching: find.byType(Scrollable)),
      );
      expect(roomyScroll.position.maxScrollExtent, closeTo(0, 0.1));

      tester.view
        ..physicalSize = const Size(360, 720)
        ..padding = const FakeViewPadding(bottom: 24);
      await tester.pump();

      final shortArtworkWidth = tester.getSize(artwork).width;
      final shortShadow = artworkShadow();
      expect(tester.getRect(header).top, closeTo(12, 0.1));
      expect(
        tester.getRect(find.byKey(const ValueKey('player-tab-title'))).top,
        greaterThan(tester.getRect(header).top),
      );
      expect(
        shortShadow.blurRadius / shortArtworkWidth,
        lessThanOrEqualTo(0.035),
      );
      expect(shortShadow.blurRadius, greaterThan(0));
      expect(shortShadow.spreadRadius, closeTo(0, 0.001));
      expect(shortShadow.offset.dy / shortArtworkWidth, closeTo(0.018, 0.001));
      expect(shortShadow.color.a, closeTo(0.3, 0.001));
      expect(shortShadow.color.a, lessThan(longShadow.color.a));
      expect(
        tester.widget<SingleChildScrollView>(contentScroll).clipBehavior,
        Clip.hardEdge,
      );
      final compactScroll = tester.state<ScrollableState>(
        find.descendant(of: contentScroll, matching: find.byType(Scrollable)),
      );
      expect(compactScroll.position.maxScrollExtent, closeTo(0, 0.1));
      final scrollRect = tester.getRect(contentScroll);
      final artworkRect = tester.getRect(artwork);
      final horizontalShadowExtent = _visibleGaussianShadowExtent(shortShadow);
      expect(
        horizontalShadowExtent,
        lessThanOrEqualTo(artworkRect.left - scrollRect.left + 0.1),
      );
      expect(
        horizontalShadowExtent,
        lessThanOrEqualTo(scrollRect.right - artworkRect.right + 0.1),
      );
      expect(
        shortShadow.blurRadius +
            shortShadow.spreadRadius +
            shortShadow.offset.dy,
        lessThan(
          longShadow.blurRadius +
              longShadow.spreadRadius +
              longShadow.offset.dy,
        ),
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('player-volume-control')))
            .bottom,
        lessThanOrEqualTo(720 - 24.0 + 0.1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('S22 display zoom keeps the compact shadow inside its viewport', (
    tester,
  ) async {
    // The connected SM-S908U exposes a 1440x2808 app area at 600 dpi.
    _configureView(tester, const Size(384, 748.8));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final artwork = find.byKey(const ValueKey('player-large-artwork'));
    final contentScroll = find.byKey(const ValueKey('player-content-scroll'));
    final metadata = find.byKey(const ValueKey('player-stable-metadata'));
    final timeline = find.byKey(const ValueKey('player-timeline'));
    final playbackControls = find.byKey(
      const ValueKey('player-playback-controls'),
    );
    final surface = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('player-artwork-surface')),
    );
    final shadow = (surface.decoration as BoxDecoration).boxShadow!.single;
    final artworkRect = tester.getRect(artwork);
    final visibleShadowExtent = _visibleGaussianShadowExtent(shadow);
    final compactness = ((820 - 748.8) / 100).clamp(0.0, 1.0);
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: contentScroll, matching: find.byType(Scrollable)),
    );

    expect(tester.getSize(artwork).width, greaterThan(320));
    expect(scroll.position.pixels, closeTo(0, 0.1));
    expect(scroll.position.maxScrollExtent, closeTo(0, 0.1));
    expect(
      tester.getRect(find.byKey(const ValueKey('player-track-title'))).top -
          artworkRect.bottom,
      closeTo(22 - (14 * compactness), 0.2),
    );
    expect(
      tester.getRect(timeline).top - tester.getRect(metadata).bottom,
      closeTo(22 - (15 * compactness), 0.2),
    );
    expect(
      tester.getRect(playbackControls).top - tester.getRect(timeline).bottom,
      closeTo(18 - (16 * compactness), 0.2),
    );
    expect(shadow.color.a, lessThanOrEqualTo(0.32));
    expect(shadow.spreadRadius, lessThan(0.3));
    // With no vertical overflow RenderSingleChildViewport does not install a
    // clip, so the compact halo may use the outer 20 dp content padding too.
    expect(visibleShadowExtent, lessThanOrEqualTo(artworkRect.left + 0.1));
    expect(
      visibleShadowExtent,
      lessThanOrEqualTo(384 - artworkRect.right + 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'width-compacted artwork also compacts its shadow on a short phone',
    (tester) async {
      _configureView(tester, const Size(360, 800), bottomPadding: 24);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: snapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final artworkWidth = tester
          .getSize(find.byKey(const ValueKey('player-large-artwork')))
          .width;
      final surface = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('player-artwork-surface')),
      );
      final shadow = (surface.decoration as BoxDecoration).boxShadow!.single;

      expect(artworkWidth, lessThan(400));
      expect(shadow.blurRadius / artworkWidth, lessThanOrEqualTo(0.095));
      expect(shadow.spreadRadius / artworkWidth, lessThanOrEqualTo(0.007));
      expect(shadow.offset.dy / artworkWidth, lessThanOrEqualTo(0.035));
      expect(shadow.color.a, lessThan(0.67));
      expect(
        tester
            .widget<SingleChildScrollView>(
              find.byKey(const ValueKey('player-content-scroll')),
            )
            .clipBehavior,
        Clip.hardEdge,
      );
      expect(
        tester
            .getRect(find.byKey(const ValueKey('player-volume-control')))
            .bottom,
        lessThanOrEqualTo(800 - 24.0 + 0.1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('short desktop frames compact the shadow with the artwork', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 900));

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    BoxShadow artworkShadow() {
      final surface = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('player-artwork-surface')),
      );
      return (surface.decoration as BoxDecoration).boxShadow!.single;
    }

    final artwork = find.byKey(const ValueKey('player-large-artwork'));
    final roomyArtworkWidth = tester.getSize(artwork).width;
    final roomyShadow = artworkShadow();
    expect(roomyShadow.blurRadius, 42);
    expect(roomyShadow.spreadRadius, 6);
    expect(roomyShadow.offset.dy, 18);

    tester.view.physicalSize = const Size(960, 600);
    await tester.pump();

    final compactArtworkWidth = tester.getSize(artwork).width;
    final compactShadow = artworkShadow();
    expect(compactArtworkWidth, lessThan(roomyArtworkWidth));
    expect(compactShadow.blurRadius, lessThan(roomyShadow.blurRadius));
    expect(compactShadow.spreadRadius, lessThan(roomyShadow.spreadRadius));
    expect(compactShadow.offset.dy, lessThan(roomyShadow.offset.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'full player transitions metadata and artwork without a luminance dip',
    (tester) async {
      _configureView(tester, const Size(960, 600));
      const first = PlayerSnapshot(
        status: PlayerStatus.playing,
        title: 'Primera transicion',
        artist: 'Primer artista',
        trackId: 'player-transition-first',
        duration: Duration(minutes: 3),
      );
      const second = PlayerSnapshot(
        status: PlayerStatus.playing,
        title: 'Segunda transicion',
        artist: 'Segundo artista',
        trackId: 'player-transition-second',
        duration: Duration(minutes: 4),
      );
      final controller = _TestPlayerController(first);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.windows,
          snapshot: first,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final artworkTransition = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('player-artwork-track-transition')),
      );
      final metadataTransition = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('player-metadata-track-transition')),
      );
      final headerTransition = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('player-header-track-transition')),
      );
      expect(artworkTransition.duration, const Duration(milliseconds: 420));
      expect(metadataTransition.duration, const Duration(milliseconds: 420));
      expect(headerTransition.duration, const Duration(milliseconds: 420));

      controller.emit(second);
      await tester.pump();

      final transitioningTitles = tester
          .widgetList<MarqueeText>(
            find.byKey(const ValueKey('player-track-title')),
          )
          .map((widget) => widget.text);
      expect(transitioningTitles, containsAll([first.title, second.title]));
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsNWidgets(2),
        reason: 'The track id must animate even when both covers are absent.',
      );
      expect(
        find.byKey(const ValueKey('player-header-artist-action')),
        findsNWidgets(2),
      );

      await tester.pump(const Duration(milliseconds: 210));
      final artworkOpacities = tester
          .widgetList<Opacity>(
            find.descendant(
              of: find.byKey(const ValueKey('player-artwork-track-transition')),
              matching: find.byType(Opacity),
            ),
          )
          .map((widget) => widget.opacity)
          .toList(growable: false);
      expect(artworkOpacities, contains(1));
      expect(
        artworkOpacities.any((opacity) => opacity > 0 && opacity < 1),
        isTrue,
      );

      await tester.pump(const Duration(milliseconds: 220));
      final settledTitle = tester.widget<MarqueeText>(
        find.byKey(const ValueKey('player-track-title')),
      );
      expect(settledTitle.text, second.title);
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('full player track transitions honor reduced motion', (
    tester,
  ) async {
    _configureView(tester, const Size(960, 600));
    const first = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Primera sin movimiento',
      trackId: 'player-reduced-first',
    );
    const second = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Segunda sin movimiento',
      trackId: 'player-reduced-second',
    );
    final controller = _TestPlayerController(first);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: first,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        playerController: controller,
        disableAnimations: true,
      ),
    );
    await tester.pump();
    await tester.pump();

    for (final key in const [
      'player-artwork-track-transition',
      'player-metadata-track-transition',
      'player-header-track-transition',
    ]) {
      final switcher = tester.widget<AnimatedSwitcher>(
        find.byKey(ValueKey(key)),
      );
      expect(switcher.duration, Duration.zero);
      expect(switcher.reverseDuration, Duration.zero);
    }

    controller.emit(second);
    await tester.pump();
    await tester.pump();

    final title = tester.widget<MarqueeText>(
      find.byKey(const ValueKey('player-track-title')),
    );
    expect(title.text, second.title);
    expect(
      find.byKey(const ValueKey('player-artwork-surface')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hidden full player replaces track surfaces without retaining outgoing trees',
    (tester) async {
      _configureView(tester, const Size(960, 600));
      const first = PlayerSnapshot(
        status: PlayerStatus.playing,
        title: 'Cancion visible inicial',
        artist: 'Artista inicial',
        trackId: 'hidden-transition-0',
      );
      final controller = _TestPlayerController(first);
      final transitionsEnabled = ValueNotifier<bool>(true);
      addTearDown(transitionsEnabled.dispose);

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.windows,
          snapshot: first,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          playerController: controller,
          trackTransitionsEnabledListenable: transitionsEnabled,
        ),
      );
      await tester.pump();
      await tester.pump();

      controller.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          title: 'Cancion al comenzar a ocultar',
          artist: 'Artista al comenzar a ocultar',
          trackId: 'hidden-transition-1',
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsNWidgets(2),
      );

      transitionsEnabled.value = false;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsOneWidget,
      );

      for (var index = 2; index <= 12; index++) {
        controller.emit(
          PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion oculta $index',
            artist: 'Artista oculto $index',
            trackId: 'hidden-transition-$index',
          ),
        );
        await tester.pump();
      }

      for (final key in const [
        'player-artwork-track-transition',
        'player-metadata-track-transition',
        'player-header-track-transition',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing);
      }
      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('player-header-artist-action')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<MarqueeText>(
              find.byKey(const ValueKey('player-track-title')),
            )
            .text,
        'Cancion oculta 12',
      );

      transitionsEnabled.value = true;
      await tester.pump();
      for (final key in const [
        'player-artwork-track-transition',
        'player-metadata-track-transition',
        'player-header-track-transition',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.text('Cancion oculta 12'), findsOneWidget);

      controller.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          title: 'Cancion visible siguiente',
          artist: 'Artista visible siguiente',
          trackId: 'visible-transition-next',
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('player-artwork-surface')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('player-header-artist-action')),
        findsNWidgets(2),
      );
      expect(find.text('Cancion oculta 12'), findsOneWidget);
      expect(find.text('Cancion visible siguiente'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('player errors keep normal artwork and use scroll as fallback', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 720), bottomPadding: 24);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot.copyWith(
          status: PlayerStatus.failed,
          errorMessage: 'No se pudo abrir la pista.',
        ),
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.byKey(const ValueKey('player-error-message')), findsOneWidget);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey('player-content-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('960x600 desktop player fits text scale 2', (tester) async {
    _configureView(tester, const Size(960, 600), textScaleFactor: 2);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.windows,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('player-primary-control')),
      findsOneWidget,
    );
    _expectTransparentPrimaryControl(tester, mobile: false);
    expect(
      find.byKey(const ValueKey('player-progress-color-animation')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final variant in const [
    (
      name: 'Android 320',
      size: Size(320, 720),
      platform: TargetPlatform.android,
      textScale: 1.0,
    ),
    (
      name: 'Android 360',
      size: Size(360, 800),
      platform: TargetPlatform.android,
      textScale: 1.0,
    ),
    (
      name: 'Android 320 text scale 3',
      size: Size(320, 568),
      platform: TargetPlatform.android,
      textScale: 3.0,
    ),
    (
      name: 'Windows desktop text scale 2',
      size: Size(960, 600),
      platform: TargetPlatform.windows,
      textScale: 2.0,
    ),
  ]) {
    testWidgets(
      '${variant.name} keeps the title-to-artist gap independent of title lines',
      (tester) async {
        _configureView(
          tester,
          variant.size,
          textScaleFactor: variant.textScale,
        );

        Future<
          ({
            Rect artwork,
            double artworkTitleGap,
            double gap,
            double titleHeight,
          })
        >
        renderTitle(String title) async {
          await tester.pumpWidget(
            _playerHarness(
              platform: variant.platform,
              snapshot: snapshot.copyWith(
                title: title,
                artist:
                    'Un nombre de artista deliberadamente largo para validar '
                    'el espacio reservado a las acciones',
              ),
              localTrack: localTrack,
              playlists: _TestPlaylistsController(),
            ),
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();

          final titleFinder = find.byKey(const ValueKey('player-track-title'));
          final artistFinder = find.byKey(
            const ValueKey('player-track-artist'),
          );
          final titleWidget = tester.widget<MarqueeText>(titleFinder);
          final titleRect = tester.getRect(titleFinder);
          final artistRect = tester.getRect(artistFinder);
          final favoriteRect = tester.getRect(
            find.byKey(const ValueKey('player-favorite-control')),
          );

          expect(titleWidget.text, title);
          expect(artistRect.right, lessThanOrEqualTo(favoriteRect.left));
          expect(
            tester
                .getRect(find.byKey(const ValueKey('player-favorite-control')))
                .center
                .dy,
            closeTo(artistRect.center.dy, 0.1),
          );
          expect(tester.takeException(), isNull);
          final artworkRect = tester.getRect(
            find.byKey(const ValueKey('player-large-artwork')),
          );
          return (
            artwork: artworkRect,
            artworkTitleGap: titleRect.top - artworkRect.bottom,
            gap: artistRect.top - titleRect.bottom,
            titleHeight: titleRect.height,
          );
        }

        final shortTitle = await renderTitle('A');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        final longTitle = await renderTitle(
          'Un titulo deliberadamente largo que necesita dos lineas en el '
          'reproductor sin separar de forma artificial el nombre del artista',
        );

        expect(longTitle.titleHeight, closeTo(shortTitle.titleHeight, 0.1));
        expect(longTitle.gap, closeTo(shortTitle.gap, 0.1));
        if (variant.platform == TargetPlatform.android) {
          expect(longTitle.artwork, shortTitle.artwork);
          final compactness = ((820 - variant.size.height) / 100).clamp(
            0.0,
            1.0,
          );
          final expectedArtworkTitleGap = 22 - (14 * compactness);
          expect(
            shortTitle.artworkTitleGap,
            closeTo(expectedArtworkTitleGap, 0.1),
          );
          expect(
            longTitle.artworkTitleGap,
            closeTo(expectedArtworkTitleGap, 0.1),
          );
          expect(
            longTitle.artworkTitleGap,
            closeTo(shortTitle.artworkTitleGap, 0.1),
          );
        }
      },
    );
  }

  testWidgets('share stays direct in BStream and in both overflow menus', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const shareSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Titulo resumido del reproductor',
      artist: 'Artista resumido',
      trackId: 'dQw4w9WgXcQ',
      sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      duration: Duration(minutes: 3),
    );
    const canonicalTrack = TrackInfo(
      id: 'dQw4w9WgXcQ',
      title: 'Cancion para compartir',
      artist: 'Artista de prueba',
      url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      album: 'Album canonico',
    );

    for (final style in PlayerStyle.values) {
      final shareService = _TestTrackShareService();
      await tester.pumpWidget(
        _playerHarness(
          key: ValueKey('share-menu-$style'),
          platform: TargetPlatform.android,
          snapshot: shareSnapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          shareService: shareService,
          canonicalRemoteTrack: canonicalTrack,
          style: style,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final directShare = find.byKey(const ValueKey('player-share-control'));
      if (style == PlayerStyle.bstreamMusic) {
        expect(directShare, findsOneWidget);
        await tester.tap(directShare);
        await tester.pump();
        expect(shareService.shareCalls, 1);
      } else {
        expect(
          directShare,
          findsNothing,
          reason: 'Apple keeps Share exclusively in the overflow menu',
        );
      }
      final menu = find.byKey(const ValueKey('player-menu-control'));
      expect(menu, findsOneWidget);

      await tester.tap(menu);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        shareService.shareCalls,
        style == PlayerStyle.bstreamMusic ? 1 : 0,
        reason: 'opening the $style menu must not start sharing',
      );
      final popupSurface = find.byKey(
        const ValueKey('glass-popup-menu-surface'),
      );
      expect(popupSurface, findsOneWidget);
      expect(tester.getSize(popupSurface).width, greaterThan(48));
      expect(tester.getSize(popupSurface).height, greaterThan(48));
      expect(
        find.byKey(const ValueKey('player-menu-go-to-artist')),
        findsOneWidget,
      );
      final shareAction = find.byKey(const ValueKey('player-menu-share'));
      expect(shareAction, findsOneWidget);

      await tester.tap(shareAction);
      await tester.pump();

      expect(
        shareService.shareCalls,
        style == PlayerStyle.bstreamMusic ? 2 : 1,
      );
      expect(shareService.sharedTrack, canonicalTrack);
      expect(shareService.sharedTrack!.album, 'Album canonico');
      expect(shareService.title, 'Compartir canción');
      expect(
        shareService.message,
        'Escucha "Cancion para compartir" de Artista de prueba.',
      );
      expect(shareService.sharePositionOrigin, isNotNull);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets(
    'downloaded track shares its YouTube origin, not its local path',
    (tester) async {
      _configureView(tester, const Size(360, 800));
      final shareService = _TestTrackShareService();
      final downloadedTrack = LocalTrack(
        id: 'local-download',
        title: 'Cancion descargada',
        artist: 'Artista local',
        filePath: r'C:\music\private-track.m4a',
        sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        sourceId: 'dQw4w9WgXcQ',
        addedAt: DateTime(2026),
      );
      const localSnapshot = PlayerSnapshot(
        status: PlayerStatus.paused,
        title: 'Cancion descargada',
        artist: 'Artista local',
        trackId: 'local-download',
        sourceUrl: r'C:\music\private-track.m4a',
      );

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: localSnapshot,
          localTrack: downloadedTrack,
          playlists: _TestPlaylistsController(),
          shareService: shareService,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      await tester.tap(find.byKey(const ValueKey('player-menu-control')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('player-menu-share')));
      await tester.pump();

      expect(shareService.shareCalls, 1);
      expect(shareService.sharedTrack?.id, 'dQw4w9WgXcQ');
      expect(
        shareService.sharedTrack?.url,
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      expect(shareService.sharedTrack?.url, isNot(contains('private-track')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('external playback exposes transport but no library actions', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final shareService = _TestTrackShareService();
    final artistService = _TestArtistService();

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot.copyWith(
          sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          isExternal: true,
        ),
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        shareService: shareService,
        youtubeMusicSearch: artistService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.byKey(const ValueKey('player-share-control')), findsNothing);
    expect(find.byKey(const ValueKey('player-menu-control')), findsNothing);
    expect(find.byKey(const ValueKey('player-favorite-control')), findsNothing);
    expect(find.byIcon(Icons.more_vert_rounded), findsNothing);
    expect(
      find.byKey(const ValueKey('player-menu-go-to-artist')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('player-menu-go-to-album')), findsNothing);

    final headerArtist = tester.widget<InkWell>(
      find.byKey(const ValueKey('player-header-artist-action')),
    );
    final trackArtist = tester.widget<InkWell>(
      find.byKey(const ValueKey('player-track-artist-action')),
    );
    expect(headerArtist.onTap, isNull);
    expect(trackArtist.onTap, isNull);
    expect(artistService.profileCalls, 0);

    expect(find.byKey(const ValueKey('player-lyrics-control')), findsOneWidget);
    expect(find.byKey(const ValueKey('player-volume-control')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('player-primary-control')),
      findsOneWidget,
    );
    expect(shareService.shareCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unshareable playback keeps the menu share action disabled', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final shareService = _TestTrackShareService(canShareResult: false);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        shareService: shareService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final directShare = tester.widget<IconButton>(
      find.byKey(const ValueKey('player-share-control')),
    );
    expect(directShare.onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('player-menu-control')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final share = find.byKey(const ValueKey('player-menu-share'));
    expect(tester.widget<PopupMenuItem<String>>(share).enabled, isFalse);
    await tester.tap(share);
    await tester.pump();
    expect(shareService.shareCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('share failure is reported with the localized message', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final shareService = _TestTrackShareService(throwsOnShare: true);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        shareService: shareService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey('player-menu-control')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('player-menu-share')));
    await tester.pump();

    expect(find.text('No se pudo compartir la canción.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('download from player stays open and confirms the queue', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción remota',
      artist: 'Artista remoto',
      trackId: 'remote-download-1',
      sourceUrl: 'https://www.youtube.com/watch?v=remote-download-1',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'remote-download-1',
      title: 'Canción remota',
      artist: 'Artista remoto',
      url: 'https://www.youtube.com/watch?v=remote-download-1',
    );
    final downloads = _RecordingDownloadController();
    var searchOpenCalls = 0;

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        downloadController: downloads,
        onOpenSearch: () => searchOpenCalls += 1,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-menu-download')));
    await tester.pump(const Duration(milliseconds: 600));

    expect(downloads.downloadCalls, 1);
    expect(downloads.downloadedTrack?.id, 'remote-download-1');
    expect(searchOpenCalls, 0);
    expect(find.byType(PlayerPanel), findsOneWidget);
    expect(
      find.text('Canción añadida a la cola de descargas.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('download enqueue failure is reported without leaving player', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción remota',
      artist: 'Artista remoto',
      trackId: 'remote-download-error',
      sourceUrl: 'https://www.youtube.com/watch?v=remote-download-error',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    final downloads = _RecordingDownloadController(fail: true);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        downloadController: downloads,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-menu-download')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(downloads.downloadCalls, 1);
    expect(find.byType(PlayerPanel), findsOneWidget);
    expect(
      find.text('No se pudo añadir la canción a la cola de descargas.'),
      findsOneWidget,
    );
    expect(find.text('Canción añadida a la cola de descargas.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final entryPoint in <String>['artist-name', 'menu']) {
    testWidgets('$entryPoint opens the first artist profile', (tester) async {
      _configureView(tester, const Size(360, 800));
      const remoteSnapshot = PlayerSnapshot(
        status: PlayerStatus.paused,
        title: 'Colaboración',
        artist: 'Artista Primero, Artista Segundo',
        trackId: 'popular0001',
        sourceUrl: 'https://www.youtube.com/watch?v=popular0001',
        duration: Duration(minutes: 3),
        isRemote: true,
      );
      const canonicalTrack = TrackInfo(
        id: 'popular0001',
        title: 'Colaboración',
        artist: 'Artista Primero, Artista Segundo',
        artists: <String>['Artista Primero', 'Artista Segundo'],
        artistBrowseIds: <String?>['UCartistFirst', 'UCartistSecond'],
        url: 'https://www.youtube.com/watch?v=popular0001',
      );
      final artistService = _TestArtistService();

      await tester.pumpWidget(
        _playerHarness(
          platform: TargetPlatform.android,
          snapshot: remoteSnapshot,
          localTrack: localTrack,
          playlists: _TestPlaylistsController(),
          canonicalRemoteTrack: canonicalTrack,
          youtubeMusicSearch: artistService,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      if (entryPoint == 'artist-name') {
        final artistAction = tester.widget<InkWell>(
          find.byKey(const ValueKey('player-track-artist-action')),
        );
        artistAction.onTap!();
        artistAction.onTap!();
      } else {
        await tester.tap(find.byIcon(Icons.more_vert_rounded));
        await tester.pumpAndSettle();
        expect(find.text('Ir al artista'), findsOneWidget);
        await tester.tap(find.text('Ir al artista'));
      }
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('artist-profile-page')), findsOneWidget);
      expect(find.text('Artista Primero'), findsOneWidget);
      expect(artistService.lastBrowseId, 'UCartistFirst');
      expect(artistService.profileCalls, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('player menu opens the resolved YouTube Music album', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      album: 'Álbum correcto',
      trackId: 'albumtrk001',
      sourceUrl: 'https://www.youtube.com/watch?v=albumtrk001',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'albumtrk001',
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      artists: <String>['Artista del álbum'],
      artistBrowseIds: <String?>['UCalbumArtist'],
      album: 'Álbum correcto',
      url: 'https://www.youtube.com/watch?v=albumtrk001',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    final albumService = _TestAlbumService();

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        youtubeMusicSearch: albumService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(albumService.searchCalls, 0);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('player-menu-go-to-album')),
      findsOneWidget,
    );
    expect(find.text('Ir al álbum'), findsOneWidget);
    await tester.tap(find.text('Ir al álbum'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsOneWidget,
    );
    expect(find.text('Álbum correcto'), findsWidgets);
    expect(albumService.lastAlbumBrowseId, 'MPREalbumCorrect');
    expect(albumService.searchCalls, 1);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ir al álbum'));
    await tester.pumpAndSettle();
    expect(albumService.searchCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player resolves a missing album name from the song catalog', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Cancion sin album',
      artist: 'Artista del album',
      trackId: 'songalbum01',
      sourceUrl: 'https://www.youtube.com/watch?v=songalbum01',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'songalbum01',
      title: 'Cancion sin album',
      artist: 'Artista del album',
      artists: <String>['Artista del album'],
      artistBrowseIds: <String?>['UCalbumArtist'],
      url: 'https://www.youtube.com/watch?v=songalbum01',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    final albumService = _TestRelatedAlbumService(
      nextSongs: <InnerTubeSong>[
        InnerTubeSong(
          videoId: 'different01',
          title: 'Otro resultado',
          artists: const <String>['Otro artista'],
          album: 'Álbum incorrecto',
          albumBrowseId: 'MPREalbumWrong',
        ),
        InnerTubeSong(
          videoId: 'songalbum01',
          title: 'Cancion sin album',
          artists: const <String>['Artista del album'],
          album: 'Álbum correcto',
          albumBrowseId: 'MPREalbumCorrect',
        ),
      ],
    );

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        youtubeMusicSearch: albumService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(albumService.nextCalls, 0);
    expect(albumService.searchCalls, 0);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('player-menu-go-to-album')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('player-menu-go-to-album')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsOneWidget,
    );
    expect(albumService.nextCalls, 1);
    expect(albumService.searchCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid album lookup reports unavailable without navigating', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      album: 'Álbum correcto',
      trackId: 'albumtrk001',
      sourceUrl: 'https://www.youtube.com/watch?v=albumtrk001',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'albumtrk001',
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      artists: <String>['Artista del álbum'],
      album: 'Álbum correcto',
      url: 'https://www.youtube.com/watch?v=albumtrk001',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    final albumService = _TestAlbumService(albumBrowseId: 'VLnot-an-album');

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        youtubeMusicSearch: albumService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump();

    expect(albumService.searchCalls, 0);
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('player-menu-go-to-album')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('player-menu-go-to-album')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsNothing,
    );
    expect(
      find.text('No se pudo encontrar el álbum de esta canción.'),
      findsOneWidget,
    );
    expect(albumService.searchCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('album lookup failure does not block the normal player menu', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    const remoteSnapshot = PlayerSnapshot(
      status: PlayerStatus.paused,
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      album: 'Álbum correcto',
      trackId: 'albumtrk001',
      sourceUrl: 'https://www.youtube.com/watch?v=albumtrk001',
      duration: Duration(minutes: 3),
      isRemote: true,
    );
    const canonicalTrack = TrackInfo(
      id: 'albumtrk001',
      title: 'Canción del álbum',
      artist: 'Artista del álbum',
      artists: <String>['Artista del álbum'],
      album: 'Álbum correcto',
      url: 'https://www.youtube.com/watch?v=albumtrk001',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    final albumService = _TestAlbumService(throwOnSearch: true);

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: remoteSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        canonicalRemoteTrack: canonicalTrack,
        youtubeMusicSearch: albumService,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Añadir a playlist'), findsOneWidget);
    expect(find.text('Añadir a favoritos'), findsOneWidget);
    expect(find.text('Ir al álbum'), findsOneWidget);
    expect(albumService.searchCalls, 0);
    await tester.tap(find.byKey(const ValueKey('player-menu-go-to-album')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('No se pudo encontrar el álbum de esta canción.'),
      findsOneWidget,
    );
    expect(albumService.searchCalls, 1);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-menu-go-to-album')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(albumService.searchCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('title heart toggles Favorites and uses the app accent', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final playlists = _TestPlaylistsController();

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: snapshot,
        localTrack: localTrack,
        playlists: playlists,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final favorite = find.byKey(const ValueKey('player-favorite-control'));
    final title = find.byKey(const ValueKey('player-track-title'));
    expect(favorite, findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(
      tester.getCenter(favorite).dx,
      greaterThan(tester.getCenter(title).dx),
    );

    await tester.tap(favorite);
    await tester.pump();

    expect(playlists.favoriteIds, contains(trackId));
    final filledHeart = tester.widget<Icon>(
      find.descendant(
        of: favorite,
        matching: find.byIcon(Icons.favorite_rounded),
      ),
    );
    final favoriteButton = tester.widget<IconButton>(favorite);
    final context = tester.element(favorite);
    expect(favoriteButton.color, Theme.of(context).colorScheme.primary);
    expect(filledHeart.icon, Icons.favorite_rounded);

    await tester.tap(favorite);
    await tester.pump();

    expect(playlists.favoriteIds, isNot(contains(trackId)));
    expect(
      find.descendant(
        of: favorite,
        matching: find.byIcon(Icons.favorite_border_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

void _expectTransparentPrimaryControl(
  WidgetTester tester, {
  required bool mobile,
}) {
  final primaryFinder = find.byKey(const ValueKey('player-primary-control'));
  final primary = tester.widget<IconButton>(primaryFinder);
  final previous = tester.widget<IconButton>(
    find.descendant(
      of: find.byKey(const ValueKey('player-previous-control')),
      matching: find.byType(IconButton),
    ),
  );
  final next = tester.widget<IconButton>(
    find.descendant(
      of: find.byKey(const ValueKey('player-next-control')),
      matching: find.byType(IconButton),
    ),
  );

  expect(
    primary.style?.backgroundColor?.resolve(<WidgetState>{}),
    Colors.transparent,
  );
  expect(
    primary.style?.backgroundColor?.resolve(<WidgetState>{
      WidgetState.disabled,
    }),
    Colors.transparent,
  );
  expect(primary.color, previous.color);
  expect(primary.color, next.color);

  final buttonSize = tester.getSize(primaryFinder).shortestSide;
  final isShowingPause = find
      .descendant(of: primaryFinder, matching: find.byIcon(Icons.pause_rounded))
      .evaluate()
      .isNotEmpty;
  final expectedIconSize = mobile
      ? isShowingPause
            ? (buttonSize * 0.80).clamp(58.0, 76.0)
            : (buttonSize * 0.92).clamp(68.0, 88.0)
      : isShowingPause
      ? (buttonSize * 0.76).clamp(56.0, 88.0)
      : (buttonSize * 0.88).clamp(64.0, 104.0);
  expect(primary.iconSize, closeTo(expectedIconSize, 0.01));
  expect(
    primary.iconSize!,
    greaterThan(previous.iconSize! * (isShowingPause ? 1.20 : 1.40)),
  );
  expect(
    primary.iconSize!,
    greaterThan(next.iconSize! * (isShowingPause ? 1.20 : 1.40)),
  );
  final iconTranslation = tester.widget<Transform>(
    find.descendant(of: primaryFinder, matching: find.byType(Transform)),
  );
  expect(
    iconTranslation.transform.getTranslation().x,
    isShowingPause
        ? 0
        : mobile
        ? 1.25
        : 1.5,
  );
  expect(iconTranslation.transform.getTranslation().y, 0);
}

double _visibleGaussianShadowExtent(BoxShadow shadow) {
  const blurRadiusToSigma = 0.57735;
  return shadow.spreadRadius +
      (3 * ((shadow.blurRadius * blurRadiusToSigma) + 0.5));
}

void _configureView(
  WidgetTester tester,
  Size size, {
  double textScaleFactor = 1,
  double bottomPadding = 0,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..padding = FakeViewPadding(bottom: bottomPadding);
  tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
  addTearDown(() {
    tester.view
      ..resetPhysicalSize()
      ..resetDevicePixelRatio()
      ..resetPadding();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

Widget _playerHarness({
  Key? key,
  required TargetPlatform platform,
  required PlayerSnapshot snapshot,
  required LocalTrack localTrack,
  required _TestPlaylistsController playlists,
  TrackShareService? shareService,
  TrackInfo? canonicalRemoteTrack,
  _TestPlayerController? playerController,
  YouTubeMusicSearch? youtubeMusicSearch,
  DownloadController? downloadController,
  VoidCallback? onOpenSearch,
  bool disableAnimations = false,
  ValueListenable<bool>? trackTransitionsEnabledListenable,
  PlayerStyle style = defaultPlayerStyle,
  bool animatedArtworkEnabled = false,
  SurfaceBackgroundMode backgroundMode = SurfaceBackgroundMode.accent,
}) {
  const accent = AppAccent.blue;
  final scheme = ColorScheme.fromSeed(
    seedColor: accent.seedColor,
    brightness: Brightness.dark,
  ).copyWith(primary: accent.seedColor);

  return ProviderScope(
    key: key,
    overrides: [
      playerControllerProvider.overrideWith(
        () =>
            playerController ??
            _TestPlayerController(
              snapshot,
              canonicalRemoteTrack: canonicalRemoteTrack,
            ),
      ),
      playlistsControllerProvider.overrideWith(() => playlists),
      libraryTracksProvider.overrideWith((ref) async => [localTrack]),
      trackShareServiceProvider.overrideWithValue(
        shareService ?? _TestTrackShareService(),
      ),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
      if (youtubeMusicSearch != null)
        youtubeMusicSearchProvider.overrideWithValue(youtubeMusicSearch),
      if (downloadController != null)
        downloadControllerProvider.overrideWith(() => downloadController),
    ],
    child: MaterialApp(
      theme: ThemeData(
        platform: platform,
        colorScheme: scheme,
        extensions: <ThemeExtension<dynamic>>[
          const AppAccentTheme(accent: accent),
          AppSurfaceTheme(backgroundMode: backgroundMode),
        ],
      ),
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: Scaffold(
        body: trackTransitionsEnabledListenable == null
            ? PlayerPanel(
                drawBackground: false,
                onOpenSearch: onOpenSearch,
                style: style,
                animatedArtworkEnabled: animatedArtworkEnabled,
              )
            : ValueListenableBuilder<bool>(
                valueListenable: trackTransitionsEnabledListenable,
                builder: (context, enabled, _) => PlayerPanel(
                  drawBackground: false,
                  onOpenSearch: onOpenSearch,
                  trackTransitionsEnabled: enabled,
                  style: style,
                  animatedArtworkEnabled: animatedArtworkEnabled,
                ),
              ),
      ),
    ),
  );
}

class _RecordingDownloadController extends DownloadController {
  _RecordingDownloadController({this.fail = false});

  final bool fail;
  int downloadCalls = 0;
  TrackInfo? downloadedTrack;

  @override
  Map<String, DownloadTaskState> build() => const {};

  @override
  Future<void> downloadAudio(TrackInfo track) async {
    downloadCalls += 1;
    downloadedTrack = track;
    if (fail) {
      throw StateError('enqueue failed');
    }
  }
}

class _TestArtistService
    implements YouTubeMusicSearch, YouTubeMusicArtistProfileLookup {
  String? lastBrowseId;
  int profileCalls = 0;

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async => const <InnerTubeSong>[];

  @override
  Future<InnerTubeArtistProfile> getArtistProfile(
    String artistBrowseId, {
    String? fallbackName,
    String? fallbackThumbnailUrl,
    int songLimit = 20,
    int releaseLimit = 20,
  }) async {
    profileCalls += 1;
    lastBrowseId = artistBrowseId;
    return InnerTubeArtistProfile(
      artist: InnerTubeArtist(
        browseId: artistBrowseId,
        name: fallbackName ?? 'Artista',
        thumbnailUrl: fallbackThumbnailUrl,
      ),
      popularSongs: const <InnerTubeSong>[],
      albums: const <InnerTubeAlbum>[],
      singles: const <InnerTubeAlbum>[],
    );
  }
}

class _TestAlbumService
    implements
        YouTubeMusicSearch,
        YouTubeMusicCatalogSearch,
        YouTubeMusicAlbumLookup {
  _TestAlbumService({
    this.albumBrowseId = 'MPREalbumCorrect',
    this.throwOnSearch = false,
  });

  final String albumBrowseId;
  final bool throwOnSearch;
  int searchCalls = 0;
  int songSearchCalls = 0;
  String? lastAlbumBrowseId;

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async {
    songSearchCalls += 1;
    return const <InnerTubeSong>[];
  }

  @override
  Future<List<InnerTubeSong>> searchVideos(
    String query, {
    int limit = 20,
  }) async => const <InnerTubeSong>[];

  @override
  Future<List<InnerTubeAlbum>> searchAlbums(
    String query, {
    int limit = 20,
  }) async {
    searchCalls += 1;
    if (throwOnSearch) {
      throw StateError('album search failed');
    }
    return <InnerTubeAlbum>[
      InnerTubeAlbum(
        browseId: albumBrowseId,
        title: 'Álbum correcto',
        artists: const <String>['Artista del álbum'],
        year: '2026',
        type: 'Álbum',
        thumbnailUrl: 'https://example.invalid/album.jpg',
      ),
    ];
  }

  @override
  Future<List<InnerTubeSong>> getAlbumSongs(
    String browseId, {
    int limit = innerTubeDetailResultLimit,
  }) async {
    lastAlbumBrowseId = browseId;
    return <InnerTubeSong>[
      InnerTubeSong(
        videoId: 'albumtrk001',
        title: 'Canción del álbum',
        artists: const <String>['Artista del álbum'],
        album: 'Álbum correcto',
      ),
    ];
  }
}

class _TestRelatedAlbumService extends _TestAlbumService
    implements YouTubeMusicRelated {
  _TestRelatedAlbumService({required this.nextSongs});

  final List<InnerTubeSong> nextSongs;
  int nextCalls = 0;

  @override
  Future<InnerTubeNextPage> getNext(
    String videoId, {
    bool radio = false,
    int limit = innerTubeDetailResultLimit,
  }) async {
    nextCalls += 1;
    return InnerTubeNextPage(songs: nextSongs.take(limit).toList());
  }

  @override
  Future<InnerTubeNextPage> getNextContinuation(
    String continuation, {
    int limit = innerTubeDetailResultLimit,
  }) async => InnerTubeNextPage(songs: const <InnerTubeSong>[]);

  @override
  Future<InnerTubeRelatedPage> getRelated(
    String browseId, {
    int limit = 20,
  }) async => InnerTubeRelatedPage(
    songs: const <InnerTubeSong>[],
    albums: const <InnerTubeAlbum>[],
    artists: const <InnerTubeArtist>[],
    collections: const <InnerTubeHomeCollection>[],
  );

  @override
  Future<InnerTubeRelatedPage> getRelatedContinuation(
    String continuation, {
    int limit = 20,
  }) => getRelated(continuation, limit: limit);
}

class _TestTrackShareService implements TrackShareService {
  _TestTrackShareService({
    this.canShareResult = true,
    this.throwsOnShare = false,
  });

  final bool canShareResult;
  final bool throwsOnShare;
  int shareCalls = 0;
  TrackInfo? sharedTrack;
  String? message;
  String? title;
  String? subject;
  Rect? sharePositionOrigin;

  @override
  bool canShare(TrackInfo track) => canShareResult;

  @override
  Future<void> shareTrack(
    TrackInfo track, {
    required String message,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    shareCalls += 1;
    sharedTrack = track;
    this.message = message;
    this.title = title;
    this.subject = subject;
    this.sharePositionOrigin = sharePositionOrigin;
    if (throwsOnShare) {
      throw StateError('share failed');
    }
  }
}

class _TestPlayerController extends PlayerController {
  _TestPlayerController(this.snapshot, {this.canonicalRemoteTrack});

  final PlayerSnapshot snapshot;
  final TrackInfo? canonicalRemoteTrack;
  int seekCalls = 0;
  Duration? lastSeek;
  int volumeCalls = 0;
  double? lastVolume;

  @override
  Future<PlayerSnapshot> build() async => snapshot;

  void emit(PlayerSnapshot nextSnapshot) {
    state = AsyncData(nextSnapshot);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    lastSeek = position;
  }

  @override
  Future<void> setVolume(double volume) async {
    volumeCalls++;
    lastVolume = volume;
  }

  @override
  TrackInfo? currentRemoteTrackFor(String sourceUrl) {
    final track = canonicalRemoteTrack;
    return track?.url == sourceUrl ? track : null;
  }
}

class _TestPlaylistsController extends PlaylistsController {
  final now = DateTime(2026);

  Set<String> get favoriteIds {
    final playlists = state.value ?? const <Playlist>[];
    return playlists
        .where((playlist) => playlist.isFavorites)
        .expand((playlist) => playlist.trackIds)
        .toSet();
  }

  @override
  Future<List<Playlist>> build() async => const <Playlist>[];

  @override
  Future<bool> toggleFavorite(String trackId) async {
    final normalized = trackId.trim();
    final playlists = state.value ?? await future;
    final index = playlists.indexWhere((playlist) => playlist.isFavorites);
    final current = index < 0
        ? Playlist(
            id: Playlist.favoritesId,
            name: 'Favoritos',
            trackIds: const [],
            createdAt: now,
            updatedAt: now,
          )
        : playlists[index];
    final wasFavorite = current.trackIds.contains(normalized);
    final updated = current.copyWith(
      trackIds: wasFavorite
          ? current.trackIds.where((id) => id != normalized).toList()
          : [...current.trackIds, normalized],
      updatedAt: now,
    );
    final next = [...playlists];
    if (index < 0) {
      next.add(updated);
    } else {
      next[index] = updated;
    }
    state = AsyncData(next);
    return !wasFavorite;
  }
}
