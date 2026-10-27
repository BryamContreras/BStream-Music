import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/domain/usecases/search_tracks.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/storage/library_csv_service.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('preview parses off-thread and publishes the detected document', () async {
    final directory = await Directory.systemTemp.createTemp(
      'bstream-csv-preview-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/songs.csv');
    await file.writeAsString(
      'Title,Artist,Album,YouTube Video ID\r\nSong,Artist,Album,dQw4w9WgXcQ\r\n',
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final document = await container
        .read(libraryCsvTransferControllerProvider.notifier)
        .preview(file.path);

    expect(document.detectedFormat, LibraryCsvDetectedFormat.metroList);
    expect(document.tracks.single.youtubeVideoId, 'dQw4w9WgXcQ');
    final state = container.read(libraryCsvTransferControllerProvider);
    expect(state.phase, LibraryCsvTransferPhase.completed);
    expect(state.document, same(document));
    expect(state.isBusy, isFalse);
  });

  test(
    'export snapshots downloaded and streaming favorites without losing membership',
    () async {
      final harness = await _Harness.create();
      final database = harness.database;
      final now = DateTime.utc(2025, 1, 2);
      await database.saveLocalTrack(
        LocalTrack(
          id: 'track-1',
          title: 'Downloaded',
          artist: 'Artist',
          filePath: 'C:/music/song.m4a',
          addedAt: now,
          sourceId: 'dQw4w9WgXcQ',
          sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
      );
      await database.createCatalogPlaylist(
        id: 'playlist-1',
        name: 'Road trip',
        now: now,
      );
      await database.appendCatalogEntry(
        playlistId: 'playlist-1',
        entryId: 'entry-1',
        now: now,
        localTrackId: 'track-1',
        track: CatalogTrack.youtube(
          videoId: 'dQw4w9WgXcQ',
          title: 'Downloaded',
        ),
      );
      await database.createCatalogPlaylist(
        id: Playlist.favoritesId,
        name: 'Favoritos',
        now: now,
      );
      await database.appendCatalogEntry(
        playlistId: Playlist.favoritesId,
        entryId: 'entry-2',
        now: now,
        track: CatalogTrack.youtube(videoId: '9bZkp7q19f0', title: 'Streaming'),
      );

      final document = await harness.controller.prepareExport();

      expect(document.tracks, hasLength(2));
      final downloaded = document.tracks.singleWhere(
        (track) => track.youtubeVideoId == 'dQw4w9WgXcQ',
      );
      final streaming = document.tracks.singleWhere(
        (track) => track.youtubeVideoId == '9bZkp7q19f0',
      );
      expect(downloaded.memberships.single.id, 'playlist-1');
      expect(streaming.memberships.single.id, Playlist.favoritesId);
      expect(
        harness.container.read(libraryCsvTransferControllerProvider).phase,
        LibraryCsvTransferPhase.completed,
      );
    },
  );

  test(
    'default CSV provider imports favorites without accessing downloader and refreshes catalog',
    () async {
      final harness = await _Harness.create();
      final initial = await harness.container.read(
        catalogPlaylistProvider(Playlist.favoritesId).future,
      );
      expect(initial, isNull);
      const document = LibraryCsvDocument(
        tracks: [
          LibraryCsvTrack(
            rowNumber: 2,
            title: 'Song',
            artist: 'Artist',
            youtubeVideoId: 'dQw4w9WgXcQ',
            memberships: [
              LibraryCsvMembership(
                name: 'Favoritos',
                id: Playlist.favoritesId,
                position: 1,
              ),
            ],
          ),
        ],
        detectedFormat: LibraryCsvDetectedFormat.bstream,
        defaultPlaylistName: 'songs',
        hasPlaylistColumn: true,
      );

      final result = await harness.controller.importDocument(document);

      expect(result.imported, 1);
      expect(await harness.database.getLocalTracks(), isEmpty);
      final favorites = await harness.container.read(
        catalogPlaylistProvider(Playlist.favoritesId).future,
      );
      expect(favorites!.entries.single.videoId, 'dQw4w9WgXcQ');
      expect(favorites.entries.single.localTrackId, isNull);
      await harness.container.read(playlistsControllerProvider.future);
      expect(
        harness.container.read(favoriteTrackIdsProvider),
        contains('dQw4w9WgXcQ'),
      );
      expect(harness.sync.automaticRequests, 1);

      await harness.controller.importDocument(document);
      expect(
        (await harness.database.getCatalogPlaylist(
          Playlist.favoritesId,
        ))!.entries,
        hasLength(1),
      );
      expect(await harness.database.getLocalTracks(), isEmpty);
    },
  );

  test(
    'requestCancel finishes active metadata searches and preserves completed entries',
    () async {
      final release = Completer<void>();
      final queries = <String>[];
      const ids = {
        'First': 'dQw4w9WgXcQ',
        'Second': '9bZkp7q19f0',
        'Third': 'J---aiyznGQ',
        'Fourth': 'M7lc1UVf-VE',
      };
      final harness = await _Harness.create(
        search: (query) async {
          queries.add(query);
          await release.future;
          final title = query.split(' ').first;
          return [
            TrackInfo(
              id: ids[title]!,
              title: title,
              artist: 'Artist',
              url: 'https://www.youtube.com/watch?v=${ids[title]}',
            ),
          ];
        },
      );
      final document = LibraryCsvDocument(
        tracks: [
          for (final title in ids.keys)
            LibraryCsvTrack(
              rowNumber: ids.keys.toList().indexOf(title) + 2,
              title: title,
              artist: 'Artist',
            ),
        ],
        detectedFormat: LibraryCsvDetectedFormat.generic,
        defaultPlaylistName: 'songs',
        hasPlaylistColumn: false,
      );

      final operation = harness.controller.importDocument(document);
      await _waitUntil(() => queries.length == 3);
      harness.controller.requestCancel();
      expect(
        harness.container
            .read(libraryCsvTransferControllerProvider)
            .cancelRequested,
        isTrue,
      );
      release.complete();
      final result = await operation;

      expect(queries.length, 3);
      expect(result.processed, 3);
      expect(result.imported, 3);
      expect(result.failed, 0);
      expect(result.cancelled, isTrue);
      expect(await harness.database.getLocalTracks(), isEmpty);
      final playlists = await harness.database.getCatalogPlaylists();
      expect(
        (await harness.database.getCatalogPlaylist(
          playlists.single.id,
        ))!.entries.map((entry) => entry.videoId),
        ids.values.take(3),
      );
      final state = harness.container.read(
        libraryCsvTransferControllerProvider,
      );
      expect(state.phase, LibraryCsvTransferPhase.completed);
      expect(state.result, same(result));
      expect(state.isBusy, isFalse);
    },
  );
}

class _Harness {
  _Harness(this.container, this.database, this.sync);
  final ProviderContainer container;
  final LocalDatabaseService database;
  final _SyncSpy sync;
  LibraryCsvTransferController get controller =>
      container.read(libraryCsvTransferControllerProvider.notifier);

  static Future<_Harness> create({
    Future<List<TrackInfo>> Function(String)? search,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'bstream-csv-controller-',
    );
    final database = _TestDatabase('${directory.path}/library.db');
    final sync = _SyncSpy();
    final container = ProviderContainer(
      overrides: [
        databaseServiceProvider.overrideWithValue(database),
        youtubeMusicPlaylistSyncControllerProvider.overrideWith(() => sync),
        searchTracksProvider.overrideWithValue(
          SearchTracks(_SearchRepository(search ?? (_) async => const [])),
        ),
        localTrackDownloadHelperProvider.overrideWith(
          (ref) =>
              throw StateError('CSV import must not access the downloader.'),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
      await directory.delete(recursive: true);
    });
    return _Harness(container, database, sync);
  }
}

class _TestDatabase extends LocalDatabaseService {
  _TestDatabase(this.path);
  final String path;
  @override
  Future<String> databasePath() async => path;
}

class _SyncSpy extends YouTubeMusicPlaylistSyncController {
  int automaticRequests = 0;
  @override
  YouTubeMusicPlaylistSyncState build() =>
      const YouTubeMusicPlaylistSyncState();
  @override
  void requestAutomaticSync() => automaticRequests++;
}

class _SearchRepository implements MusicRepository {
  _SearchRepository(this.onSearch);
  final Future<List<TrackInfo>> Function(String) onSearch;
  @override
  Future<List<TrackInfo>> search(String query) => onSearch(query);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('The expected asynchronous operation did not start.');
}
