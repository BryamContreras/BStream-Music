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
        expect(tester.getSize(lyrics), const Size(128, 52));
        expect(tester.getSize(volume), const Size(128, 52));
        expect(tester.getRect(lyrics).left, closeTo(20, 0.1));
        expect(tester.getRect(volume).right, closeTo(size.width - 20, 0.1));
        expect(tester.getSize(artwork), Size.square(size.width - 48));
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
        expect(lyricsIcon.size, 24);
        expect(lyricsLabel.style?.fontSize, 14);
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
        expect(size.height - tester.getRect(volume).bottom, closeTo(8, 0.1));
        expect(tester.takeException(), isNull);
      },
    );
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
    final volume = find.byKey(const ValueKey('player-volume-control'));
    await tester.ensureVisible(volume);
    await tester.pump();
    expect(tester.getRect(volume).bottom, lessThanOrEqualTo(568));
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
    expect(
      find.byKey(const ValueKey('player-progress-color-animation')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

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
    expect(
      tester.getRect(share).right,
      closeTo(tester.getRect(favorite).left, 0.1),
    );
    expect(
      find.descendant(of: share, matching: find.byIcon(Icons.share_rounded)),
      findsOneWidget,
    );

    final expectedOrigin = tester.getRect(share);
    await tester.tap(share);
    await tester.pump();

    expect(shareService.shareCalls, 1);
    expect(shareService.sharedTrack, isNotNull);
    expect(shareService.sharedTrack, canonicalTrack);
    expect(shareService.sharedTrack!.album, 'Album canonico');
    expect(shareService.title, 'Compartir con BStream Music');
    expect(
      shareService.message,
      'Escucha "Cancion para compartir" de Artista de prueba en BStream Music.',
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

Widget _playerHarness({
  required TargetPlatform platform,
  required PlayerSnapshot snapshot,
  required LocalTrack localTrack,
  required _TestPlaylistsController playlists,
  TrackShareService? shareService,
  TrackInfo? canonicalRemoteTrack,
}) {
  const accent = AppAccent.blue;
  final scheme = ColorScheme.fromSeed(
    seedColor: accent.seedColor,
    brightness: Brightness.dark,
  ).copyWith(primary: accent.seedColor);

  return ProviderScope(
    overrides: [
      playerControllerProvider.overrideWith(
        () => _TestPlayerController(
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

  @override
  Future<PlayerSnapshot> build() async => snapshot;

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
