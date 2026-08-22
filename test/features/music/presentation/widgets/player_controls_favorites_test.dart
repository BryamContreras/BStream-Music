import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/sharing/track_share_service.dart';
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
        final titleText = tester.widget<Text>(title);
        expect(titleText.maxLines, 2);
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
    'short Android frames compact the artwork shadow and pad the header',
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
      expect(tester.getRect(header).top, closeTo(14, 0.1));
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
          final titleWidget = tester.widget<Text>(titleFinder);
          final titleRect = tester.getRect(titleFinder);
          final artistRect = tester.getRect(artistFinder);
          final shareRect = tester.getRect(
            find.byKey(const ValueKey('player-share-control')),
          );

          expect(titleWidget.maxLines, 2);
          expect(titleRect.right, lessThanOrEqualTo(shareRect.left));
          expect(artistRect.right, lessThanOrEqualTo(shareRect.left));
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

        expect(longTitle.titleHeight, greaterThan(shortTitle.titleHeight));
        expect(longTitle.gap, closeTo(shortTitle.gap, 0.1));
        if (variant.platform == TargetPlatform.android) {
          expect(longTitle.artwork, shortTitle.artwork);
          expect(shortTitle.artworkTitleGap, closeTo(22, 0.1));
          expect(longTitle.artworkTitleGap, closeTo(22, 0.1));
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

  testWidgets('external playback keeps the title share control disabled', (
    tester,
  ) async {
    _configureView(tester, const Size(360, 800));
    final shareService = _TestTrackShareService();

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
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final share = find.byKey(const ValueKey('player-share-control'));
    expect(tester.widget<IconButton>(share).onPressed, isNull);
    await tester.tap(share);
    await tester.pump();
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
    ],
    child: MaterialApp(
      theme: ThemeData(
        platform: platform,
        colorScheme: scheme,
        extensions: const [AppAccentTheme(accent: accent)],
      ),
      home: const Scaffold(body: PlayerPanel(drawBackground: false)),
    ),
  );
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
