import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/marquee_text.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/sharing/track_share_service.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
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
      'player-share-control',
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
    final share = tester.getRect(
      find.byKey(const ValueKey('player-share-control')),
    );
    final favorite = tester.getRect(
      find.byKey(const ValueKey('player-favorite-control')),
    );
    expect(share.right, closeTo(favorite.left, 0.1));
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
    'short Android viewports gently reduce artwork without resizing controls',
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
      expect(errorArtworkWidth - artworkWidth, closeTo(20, 0.1));
      expect(tester.getSize(volume).width, greaterThanOrEqualTo(112));
      expect(tester.getSize(volume).height, 48);
      expect(scroll.position.pixels, closeTo(0, 0.1));
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
      final longShadow = artworkShadow();
      expect(tester.getRect(header).top, closeTo(10, 0.1));
      expect(longShadow.blurRadius, 42);
      expect(longShadow.spreadRadius, 6);
      expect(longShadow.offset.dy, 18);

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
      expect(shortShadow.blurRadius / shortArtworkWidth, closeTo(0.095, 0.001));
      expect(
        shortShadow.spreadRadius / shortArtworkWidth,
        closeTo(0.006, 0.001),
      );
      expect(shortShadow.offset.dy / shortArtworkWidth, closeTo(0.036, 0.001));
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
      expect(shadow.blurRadius / artworkWidth, lessThanOrEqualTo(0.102));
      expect(shadow.spreadRadius / artworkWidth, lessThanOrEqualTo(0.009));
      expect(shadow.offset.dy / artworkWidth, lessThanOrEqualTo(0.041));
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
      expect(artworkTransition.duration, const Duration(milliseconds: 420));
      expect(metadataTransition.duration, const Duration(milliseconds: 420));

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
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('player-content-scroll')),
        matching: find.byType(Scrollable),
      ),
      findsOneWidget,
    );
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
          final shareRect = tester.getRect(
            find.byKey(const ValueKey('player-share-control')),
          );

          expect(titleWidget.text, title);
          expect(artistRect.right, lessThanOrEqualTo(shareRect.left));
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
          final expectedArtworkTitleGap = 22 + (4 * compactness);
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

  testWidgets('title share control sits before favorite and shares snapshot', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final shareService = _TestTrackShareService();
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

    await tester.pumpWidget(
      _playerHarness(
        platform: TargetPlatform.android,
        snapshot: shareSnapshot,
        localTrack: localTrack,
        playlists: _TestPlaylistsController(),
        shareService: shareService,
        canonicalRemoteTrack: canonicalTrack,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final share = find.byKey(const ValueKey('player-share-control'));
    final favorite = find.byKey(const ValueKey('player-favorite-control'));
    expect(tester.getSize(share), const Size.square(48));
    expect(tester.getSize(favorite), const Size.square(48));
    expect(
      tester.getRect(share).right,
      closeTo(tester.getRect(favorite).left, 0.1),
    );
    expect(
      find.descendant(of: share, matching: find.byIcon(Icons.share_rounded)),
      findsOneWidget,
    );
    expect(
      tester.getCenter(share).dy,
      closeTo(tester.getCenter(favorite).dy, 0.1),
    );
    final shareIcon = find.descendant(
      of: share,
      matching: find.byIcon(Icons.share_rounded),
    );
    final favoriteIcon = find.descendant(
      of: favorite,
      matching: find.byIcon(Icons.favorite_border_rounded),
    );
    expect(
      tester.getCenter(shareIcon).dy,
      closeTo(tester.getCenter(favoriteIcon).dy, 0.1),
    );

    final expectedOrigin = tester.getRect(share);
    await tester.tap(share);
    await tester.pump();

    expect(shareService.shareCalls, 1);
    expect(shareService.sharedTrack, isNotNull);
    expect(shareService.sharedTrack, canonicalTrack);
    expect(shareService.sharedTrack!.album, 'Album canonico');
    expect(shareService.title, 'Compartir canción');
    expect(
      shareService.message,
      'Escucha "Cancion para compartir" de Artista de prueba.',
    );
    expect(shareService.sharePositionOrigin, expectedOrigin);
    expect(tester.takeException(), isNull);
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

      await tester.tap(find.byKey(const ValueKey('player-share-control')));
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

  testWidgets('unshareable playback keeps the title share control disabled', (
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

    final share = find.byKey(const ValueKey('player-share-control'));
    expect(tester.widget<IconButton>(share).onPressed, isNull);
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

    await tester.tap(find.byKey(const ValueKey('player-share-control')));
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
        extensions: const [AppAccentTheme(accent: accent)],
      ),
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: Scaffold(
        body: PlayerPanel(drawBackground: false, onOpenSearch: onOpenSearch),
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
