import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/library_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_picker_dialog.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'playlist picker uses imported remote artwork and returns the local id',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      String? selectedPlaylistId;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  selectedPlaylistId = await showDialog<String>(
                    context: context,
                    builder: (_) => PlaylistPickerDialog(
                      title: 'Elegir playlist',
                      playlists: <Playlist>[
                        fixture.playlist,
                        Playlist(
                          id: Playlist.favoritesId,
                          name: 'Favoritos',
                          trackIds: const <String>[],
                          createdAt: fixture.now,
                          updatedAt: fixture.now,
                        ),
                      ],
                      tracks: const <LocalTrack>[],
                      catalogPlaylists: <CatalogPlaylist>[fixture.catalog],
                    ),
                  );
                },
                child: const Text('Abrir selector'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir selector'));
      await tester.pumpAndSettle();

      expect(find.text('Viaje importado'), findsOneWidget);
      expect(find.text('Favoritos'), findsNothing);
      expect(
        tester
            .widgetList<SourceImage>(find.byType(SourceImage))
            .map((image) => image.source),
        contains(_remoteThumbnail),
      );

      await tester.tap(find.text('Viaje importado'));
      await tester.pumpAndSettle();

      expect(selectedPlaylistId, fixture.playlist.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library counts duplicate remote occurrences and uses their imported cover',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );

      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);

      expect(fixture.playlist.trackIds, isEmpty);
      expect(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
        findsOneWidget,
      );
      expect(find.text('2 canciones · 6:14 min'), findsOneWidget);

      final artwork = find.descendant(
        of: find.byKey(
          ValueKey('library-playlist-artwork-${fixture.playlist.id}'),
        ),
        matching: find.byType(SourceImage),
      );
      expect(artwork, findsOneWidget);
      expect(tester.widget<SourceImage>(artwork).source, _remoteThumbnail);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('library collage uses nine catalog covers in two rows of four', (
    tester,
  ) async {
    final fixture = _multiArtworkCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );

    await tester.pumpWidget(
      _libraryHarness(fixture: fixture, controller: controller),
    );
    await _pumpLibrary(tester);

    final cover = find.byKey(
      ValueKey('library-playlist-artwork-${fixture.playlist.id}'),
    );
    final artwork = find.descendant(
      of: cover,
      matching: find.byType(SourceImage),
    );
    final images = tester
        .widgetList<SourceImage>(artwork)
        .where(
          (image) =>
              image.source?.startsWith('https://img.test/local-album-cover-') ??
              false,
        )
        .toList(growable: false);
    final sources = images.map((image) => image.source).toList(growable: false);

    expect(sources, hasLength(9));
    expect(
      sources.every(
        (source) =>
            source?.startsWith('https://img.test/local-album-cover-') ?? false,
      ),
      isTrue,
    );
    expect(
      sources.any((source) => source?.contains('ytimg.com') ?? false),
      isFalse,
    );
    expect(
      images.every(
        (image) =>
            image.fallbackSource?.endsWith('.jpg') == true &&
            image.fallbackSource!.contains('video-thumbnail-'),
      ),
      isTrue,
    );
    for (var row = 0; row < 2; row++) {
      final secondaryRow = find.descendant(
        of: cover,
        matching: find.byKey(ValueKey('playlist-cover-secondary-row-$row')),
      );
      expect(secondaryRow, findsOneWidget);
      expect(
        tester
            .widgetList<SourceImage>(
              find.descendant(
                of: secondaryRow,
                matching: find.byType(SourceImage),
              ),
            )
            .where(
              (image) =>
                  image.source?.startsWith(
                    'https://img.test/local-album-cover-',
                  ) ??
                  false,
            ),
        hasLength(4),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'remote playlist song menu offers download and add-to-playlist actions',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);

      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);
      await tester.tap(
        find.byKey(const ValueKey('library-catalog-menu-occurrence-a')),
      );
      await tester.pump();

      expect(find.text('Descargar'), findsOneWidget);
      expect(find.text('Añadir a playlist'), findsOneWidget);
      expect(find.text('Quitar de playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'linked playlist local-only action never requests YouTube deletion',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
        deleteOptions: const PlaylistDeleteOptions(
          isYouTubeMusicLinked: true,
          canDeleteFromYouTubeMusic: true,
          remoteAccountKey: 'account-a',
        ),
      );
      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);

      await _openDeleteDialog(tester, fixture.playlist.id);
      expect(
        find.byKey(const Key('playlist-delete-youtube-too')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('playlist-delete-local-only')));
      await tester.pump(const Duration(milliseconds: 350));

      expect(controller.deleteScopes, <PlaylistDeleteScope>[
        PlaylistDeleteScope.localOnly,
      ]);
      expect(find.text('Playlist eliminada.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'YouTube deletion is requested only from its explicit destructive action',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
        deleteOptions: const PlaylistDeleteOptions(
          isYouTubeMusicLinked: true,
          canDeleteFromYouTubeMusic: true,
          remoteAccountKey: 'account-a',
        ),
      );
      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);

      await _openDeleteDialog(tester, fixture.playlist.id);
      await tester.tap(find.byKey(const Key('playlist-delete-youtube-too')));
      await tester.pump(const Duration(milliseconds: 350));

      expect(controller.deleteScopes, <PlaylistDeleteScope>[
        PlaylistDeleteScope.youtubeMusicToo,
      ]);
      expect(
        find.textContaining('eliminación en YouTube Music quedó programada'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _openDeleteDialog(WidgetTester tester, String playlistId) async {
  await tester.tap(find.byKey(ValueKey('library-playlist-$playlistId')));
  await _pumpLibrary(tester);
  final header = find.byKey(const ValueKey('library-detail-header'));
  expect(header, findsOneWidget);
  final playlistMenu = find.descendant(
    of: header,
    matching: find.byIcon(Icons.more_vert_rounded),
  );
  expect(playlistMenu, findsOneWidget);
  await tester.tap(playlistMenu);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  final deleteLabel = find.text('Eliminar playlist');
  final deleteMenuItem = find.ancestor(
    of: deleteLabel,
    matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
  );
  expect(deleteMenuItem, findsOneWidget);
  await tester.tap(deleteMenuItem);
  await tester.pump(const Duration(milliseconds: 300));

  expect(
    find.byWidgetPredicate((widget) => widget is AlertDialog),
    findsOneWidget,
  );
  expect(
    find.textContaining('Esta playlist está sincronizada'),
    findsOneWidget,
  );
}

Future<void> _pumpLibrary(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

Widget _libraryHarness({
  required _RemoteCatalogFixture fixture,
  required _RecordingPlaylistsController controller,
}) {
  return ProviderScope(
    overrides: [
      libraryTracksProvider.overrideWith((ref) async => fixture.libraryTracks),
      playlistsControllerProvider.overrideWith(() => controller),
      catalogPlaylistsProvider.overrideWith(
        (ref) async => <CatalogPlaylist>[fixture.catalog],
      ),
      catalogPlaylistProvider.overrideWith(
        (ref, playlistId) async =>
            playlistId == fixture.playlist.id ? fixture.catalog : null,
      ),
      playerControllerProvider.overrideWith(_IdlePlayerController.new),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      home: Scaffold(body: LibraryPanel(onOpenPlayer: () {})),
    ),
  );
}

class _RecordingPlaylistsController extends PlaylistsController {
  _RecordingPlaylistsController({
    required this.playlist,
    this.deleteOptions = const PlaylistDeleteOptions(
      isYouTubeMusicLinked: false,
      canDeleteFromYouTubeMusic: false,
    ),
  });

  final Playlist playlist;
  final PlaylistDeleteOptions deleteOptions;
  final List<PlaylistDeleteScope> deleteScopes = <PlaylistDeleteScope>[];

  @override
  Future<List<Playlist>> build() async => <Playlist>[playlist];

  @override
  Future<PlaylistDeleteOptions> playlistDeleteOptions(String playlistId) async {
    expect(playlistId, playlist.id);
    return deleteOptions;
  }

  @override
  Future<void> deletePlaylist(
    String playlistId, {
    PlaylistDeleteScope scope = PlaylistDeleteScope.localOnly,
  }) async {
    expect(playlistId, playlist.id);
    deleteScopes.add(scope);
  }
}

class _IdlePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);
}

class _RemoteCatalogFixture {
  const _RemoteCatalogFixture({
    required this.now,
    required this.playlist,
    required this.catalog,
    this.libraryTracks = const <LocalTrack>[],
  });

  final DateTime now;
  final Playlist playlist;
  final CatalogPlaylist catalog;
  final List<LocalTrack> libraryTracks;
}

const _remoteThumbnail = 'https://i.ytimg.com/vi/duplicate-video/hqdefault.jpg';

_RemoteCatalogFixture _remoteCatalogFixture() {
  final now = DateTime.utc(2026, 8, 22);
  final playlist = Playlist(
    id: 'imported-playlist',
    name: 'Viaje importado',
    trackIds: const <String>[],
    createdAt: now,
    updatedAt: now,
    localRevision: 1,
  );
  CatalogTrack duplicateTrack() => CatalogTrack.youtube(
    videoId: 'duplicate-video',
    title: 'Canción repetida',
    artists: const <String>['Artista remoto'],
    duration: const Duration(minutes: 3, seconds: 7),
    thumbnailUrl: _remoteThumbnail,
  );
  PlaylistEntry entry({
    required String id,
    required String setVideoId,
    required int position,
    DateTime? deletedAt,
  }) => PlaylistEntry(
    id: id,
    playlistId: playlist.id,
    track: duplicateTrack(),
    remoteVideoId: 'duplicate-video',
    setVideoId: setVideoId,
    position: position,
    origin: PlaylistEntryOrigin.remote,
    createdAt: now,
    updatedAt: now,
    deletedAt: deletedAt,
  );

  return _RemoteCatalogFixture(
    now: now,
    playlist: playlist,
    catalog: CatalogPlaylist(
      playlist: playlist,
      entries: <PlaylistEntry>[
        entry(id: 'occurrence-a', setVideoId: 'set-a', position: 0),
        entry(id: 'occurrence-b', setVideoId: 'set-b', position: 1),
        entry(
          id: 'deleted-occurrence',
          setVideoId: 'set-deleted',
          position: 2,
          deletedAt: now.add(const Duration(minutes: 1)),
        ),
      ],
    ),
  );
}

_RemoteCatalogFixture _multiArtworkCatalogFixture() {
  final now = DateTime.utc(2026, 8, 23);
  final localTracks = List<LocalTrack>.generate(9, (index) {
    final videoId = 'video${index.toString().padLeft(6, '0')}';
    return LocalTrack(
      id: 'local-$index',
      title: 'Canción $index',
      artist: 'Artista $index',
      filePath: '/music/song-$index.m4a',
      sourceId: videoId,
      addedAt: now,
      thumbnailPath: '/music/video-thumbnail-$index.jpg',
      thumbnailUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      catalogThumbnailUrl: 'https://img.test/local-album-cover-$index.jpg',
    );
  });
  final playlist = Playlist(
    id: 'multi-artwork-playlist',
    name: 'Muchas portadas',
    trackIds: localTracks.map((track) => track.id).toList(growable: false),
    createdAt: now,
    updatedAt: now,
  );
  final entries = List<PlaylistEntry>.generate(9, (index) {
    final videoId = localTracks[index].sourceId!;
    return PlaylistEntry(
      id: 'entry-$index',
      playlistId: playlist.id,
      track: CatalogTrack.youtube(
        videoId: videoId,
        title: localTracks[index].title,
        thumbnailUrl: 'https://img.test/album-cover-$index.jpg',
      ),
      localTrackId: localTracks[index].id,
      remoteVideoId: videoId,
      position: index,
      createdAt: now,
      updatedAt: now,
    );
  });
  return _RemoteCatalogFixture(
    now: now,
    playlist: playlist,
    catalog: CatalogPlaylist(playlist: playlist, entries: entries),
    libraryTracks: localTracks,
  );
}
