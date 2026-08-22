import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/presentation/providers/local_audio_availability.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/library_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_track_subtitle.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'audio availability ignores artwork and rejects empty audio files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bstream-playlist-cloud-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      final artwork = File('${directory.path}/cover.jpg');
      await artwork.writeAsBytes(const <int>[1, 2, 3]);
      final emptyAudio = File('${directory.path}/empty.m4a');
      await emptyAudio.create();
      final usableAudio = File('${directory.path}/usable.m4a');
      await usableAudio.writeAsBytes(const <int>[4, 5, 6]);

      expect(
        await probeUsableLocalAudio('${directory.path}/missing.m4a'),
        isFalse,
      );
      expect(await probeUsableLocalAudio(emptyAudio.path), isFalse);
      expect(await probeUsableLocalAudio(usableAudio.path), isTrue);

      final thumbnailOnlyTrack = LocalTrack(
        id: 'thumbnail-only',
        title: 'Remote song',
        artist: 'Artist',
        filePath: '${directory.path}/missing.m4a',
        thumbnailPath: artwork.path,
        addedAt: DateTime(2026),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        await container.read(
          localTrackAudioAvailabilityProvider(thumbnailOnlyTrack).future,
        ),
        isFalse,
      );
    },
  );

  testWidgets('stream-only subtitle exposes a tiny accessible cloud', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlaylistTrackSubtitle(
            artist: 'Artista remoto',
            duration: '3:21',
            isDownloaded: false,
            streamOnlyLabel: 'No descargada; requiere conexión',
            cloudKey: ValueKey('stream-only-cloud'),
          ),
        ),
      ),
    );

    final cloud = find.byKey(const ValueKey('stream-only-cloud'));
    expect(cloud, findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.byTooltip('No descargada; requiere conexión'), findsOneWidget);
    expect(
      find.bySemanticsLabel('No descargada; requiere conexión'),
      findsOneWidget,
    );
    expect(tester.getSize(find.byIcon(Icons.cloud_outlined)).width, 13);
    semantics.dispose();
  });

  testWidgets('downloaded subtitle has no cloud and stays compact', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 150,
              child: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(3)),
                child: PlaylistTrackSubtitle(
                  artist:
                      'Un nombre de artista extremadamente largo para probar',
                  duration: '59:59',
                  isDownloaded: true,
                  streamOnlyLabel: 'No descargada; requiere conexión',
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.cloud_outlined), findsNothing);
    expect(
      find.bySemanticsLabel('No descargada; requiere conexión'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'catalog playlist marks remote and unusable hybrid occurrences only',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final now = DateTime(2026);
      final playlist = Playlist(
        id: 'synced',
        name: 'Sincronizada',
        trackIds: const <String>[],
        createdAt: now,
        updatedAt: now,
      );
      final downloaded = LocalTrack(
        id: 'downloaded',
        title: 'Descargada',
        artist: 'Artista local',
        filePath: 'usable-audio',
        sourceId: 'video-downloaded',
        addedAt: now,
      );
      final stale = LocalTrack(
        id: 'stale',
        title: 'Archivo ausente',
        artist: 'Artista híbrido',
        filePath: 'missing-audio',
        sourceId: 'video-stale',
        thumbnailPath: 'cached-cover.jpg',
        addedAt: now,
      );
      final catalog = CatalogPlaylist(
        playlist: playlist,
        entries: <PlaylistEntry>[
          _entry(
            id: 'remote',
            playlistId: playlist.id,
            videoId: 'video-remote',
            title: 'Sólo streaming',
            artist: 'Artista remoto',
            position: 0,
            now: now,
          ),
          _entry(
            id: 'downloaded',
            playlistId: playlist.id,
            videoId: 'video-downloaded',
            title: downloaded.title,
            artist: downloaded.artist,
            localTrackId: downloaded.id,
            position: 1,
            now: now,
          ),
          _entry(
            id: 'stale',
            playlistId: playlist.id,
            videoId: 'video-stale',
            title: stale.title,
            artist: stale.artist,
            localTrackId: stale.id,
            position: 2,
            now: now,
          ),
        ],
      );

      await tester.pumpWidget(
        _playlistHarness(
          playlist: playlist,
          catalog: catalog,
          tracks: <LocalTrack>[downloaded, stale],
          audioProbe: (path) async => path == downloaded.filePath,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-catalog-cloud-remote')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-catalog-cloud-stale')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-catalog-cloud-downloaded')),
        findsNothing,
      );
      expect(find.byIcon(Icons.cloud_outlined), findsNWidgets(2));
      expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('legacy playlist checks its local audio payload', (tester) async {
    final now = DateTime(2026);
    final playlist = Playlist(
      id: 'legacy',
      name: 'Antigua',
      trackIds: const <String>['legacy-ok', 'legacy-missing'],
      createdAt: now,
      updatedAt: now,
    );
    final usable = LocalTrack(
      id: 'legacy-ok',
      title: 'Local disponible',
      artist: 'Artista A',
      filePath: 'usable-legacy',
      addedAt: now,
    );
    final missing = LocalTrack(
      id: 'legacy-missing',
      title: 'Local ausente',
      artist: 'Artista B',
      filePath: 'missing-legacy',
      thumbnailPath: 'cover-only.jpg',
      addedAt: now,
    );
    final catalog = CatalogPlaylist(
      playlist: playlist,
      entries: const <PlaylistEntry>[],
    );

    await tester.pumpWidget(
      _playlistHarness(
        playlist: playlist,
        catalog: catalog,
        tracks: <LocalTrack>[usable, missing],
        audioProbe: (path) async => path == usable.filePath,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('library-legacy-cloud-legacy-ok')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('library-legacy-cloud-legacy-missing')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

PlaylistEntry _entry({
  required String id,
  required String playlistId,
  required String videoId,
  required String title,
  required String artist,
  required int position,
  required DateTime now,
  String? localTrackId,
}) {
  return PlaylistEntry(
    id: id,
    playlistId: playlistId,
    localTrackId: localTrackId,
    remoteVideoId: videoId,
    track: CatalogTrack.youtube(
      videoId: videoId,
      title: title,
      artists: <String>[artist],
    ),
    position: position,
    createdAt: now,
    updatedAt: now,
  );
}

Widget _playlistHarness({
  required Playlist playlist,
  required CatalogPlaylist catalog,
  required List<LocalTrack> tracks,
  required LocalAudioUsabilityProbe audioProbe,
}) {
  final navigation = LibraryNavigationController()..openPlaylist(playlist.id);
  return ProviderScope(
    overrides: [
      playlistsControllerProvider.overrideWith(
        () => _FixedPlaylistsController(<Playlist>[playlist]),
      ),
      catalogPlaylistsProvider.overrideWith(
        (ref) async => <CatalogPlaylist>[catalog],
      ),
      catalogPlaylistProvider.overrideWith(
        (ref, playlistId) async => playlistId == playlist.id ? catalog : null,
      ),
      libraryTracksProvider.overrideWith((ref) async => tracks),
      playerControllerProvider.overrideWith(_IdlePlayerController.new),
      localAudioUsabilityProbeProvider.overrideWithValue(audioProbe),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: LibraryPanel(
          navigationController: navigation,
          onOpenPlayer: _noop,
        ),
      ),
    ),
  );
}

void _noop() {}

class _FixedPlaylistsController extends PlaylistsController {
  _FixedPlaylistsController(this.playlists);

  final List<Playlist> playlists;

  @override
  Future<List<Playlist>> build() async => playlists;
}

class _IdlePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async {
    return const PlayerSnapshot(status: PlayerStatus.stopped);
  }
}
