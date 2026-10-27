import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/data/repositories/catalog_playlist_repository_impl.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/services/storage/library_csv_import_service.dart';
import 'package:bstream_music/services/storage/library_csv_service.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory sandbox;
  late _ImportHarness harness;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('bstream-csv-import-');
    harness = _ImportHarness(_TestDatabase(p.join(sandbox.path, 'library.db')));
  });

  tearDown(() async {
    // Metadata import must not save audio or use the legacy playlist API.
    expect(harness.library.unexpectedCalls, isEmpty);
    await harness.database.close();
    await sandbox.delete(recursive: true);
  });

  group('resolution', () {
    test(
      'a direct YouTube id bypasses search and preserves metadata',
      () async {
        var searchCalls = 0;
        harness.search = (_) async {
          searchCalls++;
          return const [];
        };
        final result = await harness.import(
          _document([
            const LibraryCsvTrack(
              rowNumber: 2,
              title: 'Direct song',
              artist: 'Direct artist',
              artists: ['Direct artist', 'Guest'],
              album: 'Direct album',
              youtubeVideoId: 'abcdefghijk',
              duration: Duration(minutes: 3),
              thumbnailUrl: 'https://img.example/direct.jpg',
            ),
          ]),
        );

        expect(searchCalls, 0);
        final saved = (await harness.onlyPlaylist()).entries.single;
        expect(saved.videoId, 'abcdefghijk');
        expect(
          saved.track.sourceUrl,
          'https://www.youtube.com/watch?v=abcdefghijk',
        );
        expect(saved.track.title, 'Direct song');
        expect(saved.track.artists, ['Direct artist', 'Guest']);
        expect(saved.track.album, 'Direct album');
        expect(saved.track.duration, const Duration(minutes: 3));
        expect(saved.track.thumbnailUrl, 'https://img.example/direct.jpg');
        expect(saved.localTrackId, isNull);
        expect(await harness.database.getLocalTracks(), isEmpty);
        expect(result.imported, 1);
        expect(result.reused, 0);
        expect(result.failed, 0);
      },
    );

    test('an exact metadata search match is accepted', () async {
      final queries = <String>[];
      const candidate = TrackInfo(
        id: 'searched001',
        title: 'Dreams',
        artist: 'Fleetwood Mac',
        artists: ['Fleetwood Mac'],
        album: 'Rumours',
        duration: Duration(minutes: 4, seconds: 17),
        url: 'https://www.youtube.com/watch?v=searched001',
      );
      harness.search = (query) async {
        queries.add(query);
        return const [candidate];
      };
      final result = await harness.import(
        _document([
          _track(
            rowNumber: 2,
            title: 'Dreams',
            artist: 'Fleetwood Mac',
            album: 'Rumours',
            duration: const Duration(minutes: 4, seconds: 17),
          ),
        ]),
      );

      expect(queries, ['Dreams Fleetwood Mac Rumours']);
      final saved = (await harness.onlyPlaylist()).entries.single.track;
      expect(saved.youtubeVideoId, candidate.id);
      expect(saved.title, candidate.title);
      expect(saved.artists, candidate.artists);
      expect(saved.album, candidate.album);
      expect(result.imported, 1);
      expect(result.failed, 0);
    });

    test(
      'a low-confidence mismatch is rejected without catalog writes',
      () async {
        harness.search = (_) async => [
          _candidate('mismatch001', 'Bohemian Rhapsody', artist: 'Queen'),
        ];
        final result = await harness.import(
          _document([
            _track(rowNumber: 7, title: 'Golden Hour', artist: 'JVKE'),
          ]),
        );

        expect(result.processed, 1);
        expect(result.failed, 1);
        expect(result.failures.single.rowNumber, 7);
        expect(result.failures.single.ambiguous, isTrue);
        expect(await harness.catalog.getCatalogPlaylists(), isEmpty);
        expect(harness.gateCalls, 0);
      },
    );

    test('similarly ranked live and remix versions remain ambiguous', () async {
      harness.search = (_) async => [
        _candidate('ambiguous01', 'Midnight City Live', artist: 'M83'),
        _candidate('ambiguous02', 'Midnight City Remix', artist: 'M83'),
      ];
      final result = await harness.import(_document([_midnightCity()]));
      expect(result.failed, 1);
      expect(result.failures.single.ambiguous, isTrue);
      expect(await harness.catalog.getCatalogPlaylists(), isEmpty);
    });

    test(
      'the studio match wins over unrequested live and remix versions',
      () async {
        harness.search = (_) async => [
          _candidate('ambiguous01', 'Midnight City Live', artist: 'M83'),
          _candidate('ambiguous02', 'Midnight City Remix', artist: 'M83'),
          _candidate('studio00001', 'Midnight City', artist: 'M83'),
        ];
        final result = await harness.import(_document([_midnightCity()]));
        expect(result.imported, 1);
        expect(
          (await harness.onlyPlaylist()).entries.single.videoId,
          'studio00001',
        );
      },
    );

    test('duplicate search candidates do not create ambiguity', () async {
      final candidate = _candidate(
        'duplicate01',
        'Midnight City Live',
        artist: 'M83',
      );
      harness.search = (_) async => [candidate, candidate];
      final result = await harness.import(_document([_midnightCity()]));
      expect(result.imported, 1);
      expect(result.failed, 0);
      expect((await harness.onlyPlaylist()).entries, hasLength(1));
    });

    test('case-sensitive candidate IDs remain distinct when scoring', () async {
      harness.search = (_) async => [
        _candidate('Abcdefghijk', 'Midnight City Live', artist: 'M83'),
        _candidate('abcdefghijk', 'Midnight City Live', artist: 'M83'),
      ];
      final result = await harness.import(_document([_midnightCity()]));
      expect(result.failed, 1);
      expect(result.failures.single.ambiguous, isTrue);
    });

    test(
      'a search result without a valid YouTube identity is rejected',
      () async {
        harness.search = (_) async => [
          const TrackInfo(
            id: 'invalid',
            title: 'Song',
            artist: 'Artist',
            url: '',
          ),
        ];
        final result = await harness.import(
          _document([_track(rowNumber: 9, title: 'Song', artist: 'Artist')]),
        );
        expect(result.failed, 1);
        expect(result.failures.single.rowNumber, 9);
        expect(result.failures.single.ambiguous, isFalse);
        expect(await harness.catalog.getCatalogPlaylists(), isEmpty);
      },
    );
  });

  group('queue behavior', () {
    test(
      'searches a bounded batch concurrently and preserves source order',
      () async {
        final firstBatchStarted = Completer<void>();
        final fourthStarted = Completer<void>();
        final releases = List.generate(4, (_) => Completer<void>());
        final searched = <String>[];
        var active = 0;
        var maximumActive = 0;
        harness.search = (query) async {
          final index = searched.length;
          searched.add(query);
          active++;
          if (active > maximumActive) maximumActive = active;
          if (searched.length == 3) firstBatchStarted.complete();
          if (searched.length == 4) fourthStarted.complete();
          await releases[index].future;
          active--;
          if (index == 1) throw StateError('simulated search failure');
          return [_candidate('aaaaaaaaaa$index', query.split(' ').first)];
        };

        final operation = harness.import(
          _document([
            for (final title in ['First', 'Second', 'Third', 'Fourth'])
              _track(rowNumber: 2, title: title, artist: 'Artist'),
          ]),
        );
        await firstBatchStarted.future;
        expect(searched, ['First Artist', 'Second Artist', 'Third Artist']);
        releases[2].complete();
        await fourthStarted.future;
        releases[3].complete();
        releases[0].complete();
        releases[1].complete();
        final result = await operation;

        expect(maximumActive, 3);
        expect(result.processed, 4);
        expect(result.imported, 3);
        expect(result.failed, 1);
        expect(result.failures.single.title, 'Second');
        expect(result.successful + result.failed, result.processed);
        expect(
          (await harness.onlyPlaylist()).entries.map(
            (entry) => entry.track.title,
          ),
          ['First', 'Third', 'Fourth'],
        );
      },
    );

    test(
      'cancellation finishes the active search and stops before the next',
      () async {
        var cancellationRequested = false;
        var searchCalls = 0;
        final searchStarted = Completer<void>();
        final releaseSearch = Completer<List<TrackInfo>>();
        final progress = <LibraryCsvImportProgress>[];
        harness.maxConcurrentTracks = 1;
        harness.search = (_) async {
          searchCalls++;
          searchStarted.complete();
          return releaseSearch.future;
        };

        final operation = harness.service.import(
          _document([
            _track(rowNumber: 2, title: 'Dreams', artist: 'Fleetwood Mac'),
            _directTrack(3, 'Second', 'bbbbbbbbbbb'),
          ]),
          isCancellationRequested: () => cancellationRequested,
          onProgress: progress.add,
        );
        await searchStarted.future;
        cancellationRequested = true;
        releaseSearch.complete([
          _candidate('searched001', 'Dreams', artist: 'Fleetwood Mac'),
        ]);
        final result = await operation;

        expect(searchCalls, 1);
        expect(result.cancelled, isTrue);
        expect(result.processed, 1);
        expect(result.imported, 1);
        expect(result.failed, 0);
        expect(progress.last.cancelRequested, isTrue);
        expect(progress.last.processed, 1);
        expect(progress.last.imported, 1);
        expect(
          (await harness.onlyPlaylist()).entries.single.videoId,
          'searched001',
        );
      },
    );

    test(
      'cancelling before work starts avoids searches and catalog writes',
      () async {
        final result = await harness.service.import(
          _document([_directTrack(2, 'Song', 'aaaaaaaaaaa')]),
          isCancellationRequested: () => true,
        );
        expect(result.cancelled, isTrue);
        expect(result.processed, 0);
        expect(result.successful, 0);
        expect(harness.gateCalls, 0);
        expect(await harness.catalog.getCatalogPlaylists(), isEmpty);
      },
    );
  });

  group('catalog persistence', () {
    test(
      'CSV catalog export reimports favorites without downloading or duplicating',
      () async {
        const csv = LibraryCsvService();
        final firstDocument = _document([
          const LibraryCsvTrack(
            rowNumber: 2,
            title: 'Favorite metadata',
            artist: 'Singer',
            artists: ['Singer', 'Guest'],
            album: 'Album',
            duration: Duration(minutes: 3, seconds: 15),
            thumbnailUrl: 'https://img.example/favorite.jpg',
            youtubeVideoId: 'aaaaaaaaaaa',
            memberships: [
              LibraryCsvMembership(
                id: Playlist.favoritesId,
                name: 'Favoritas',
                position: 2,
              ),
            ],
          ),
          _directTrack(
            3,
            'First favorite',
            'bbbbbbbbbbb',
            memberships: const [
              LibraryCsvMembership(
                id: Playlist.favoritesId,
                name: 'Favoritas',
                position: 1,
              ),
            ],
          ),
        ]);
        await harness.import(firstDocument);
        final before = await harness.onlyPlaylist();
        final exported = LibraryCsvDocument.fromLibrary(
          tracks: await harness.database.getLocalTracks(),
          playlists: await harness.database.getPlaylists(),
          catalogPlaylists: [before],
        );
        final restored = csv.importBytes(
          LibraryCsvInput(
            bytes: csv.exportDocument(exported, LibraryCsvProfile.bstream),
            fileName: 'favorites-roundtrip.csv',
          ),
        );
        final result = await harness.import(restored);
        final after = await harness.onlyPlaylist();

        expect(after.playlist.id, Playlist.favoritesId);
        expect(
          after.entries.map((entry) => entry.id),
          before.entries.map((entry) => entry.id),
        );
        expect(after.entries.map((entry) => entry.videoId), [
          'bbbbbbbbbbb',
          'aaaaaaaaaaa',
        ]);
        final metadata = after.entries.last.track;
        expect(metadata.title, 'Favorite metadata');
        expect(metadata.artists, ['Singer', 'Guest']);
        expect(metadata.album, 'Album');
        expect(metadata.duration, const Duration(minutes: 3, seconds: 15));
        expect(metadata.thumbnailUrl, 'https://img.example/favorite.jpg');
        expect(result.imported, 0);
        expect(result.reused, 2);
        expect(await harness.database.getLocalTracks(), isEmpty);
      },
    );

    test(
      'merges ordered memberships by name and reimport preserves occurrences',
      () async {
        await harness.seedPlaylist('road-trip-id', '  road trip  ', [
          'oldoldold01',
          'bbbbbbbbbbb',
        ]);
        final document = _document([
          _directTrack(
            2,
            'Second position',
            'aaaaaaaaaaa',
            memberships: const [
              LibraryCsvMembership(name: 'Road Trip', position: 2),
              LibraryCsvMembership(name: 'New Mix', position: 2),
              LibraryCsvMembership(name: 'New Mix', position: 3),
            ],
          ),
          _directTrack(
            3,
            'First position',
            'bbbbbbbbbbb',
            memberships: const [
              LibraryCsvMembership(name: '  road trip ', position: 1),
              LibraryCsvMembership(name: ' new mix  ', position: 1),
            ],
          ),
        ]);

        final first = await harness.import(document);
        expect(first.playlistsUpdated, 2);
        expect(first.successful, 2);
        expect(first.imported, 1);
        expect(first.reused, 1);
        expect(harness.gateCalls, 1);
        final road = (await harness.catalog.getCatalogPlaylist(
          'road-trip-id',
        ))!;
        expect(road.playlist.name, 'road trip');
        expect(road.entries.map((entry) => entry.videoId), [
          'oldoldold01',
          'bbbbbbbbbbb',
          'aaaaaaaaaaa',
        ]);
        final created = (await harness.catalog.getCatalogPlaylists())
            .singleWhere((playlist) => playlist.id != 'road-trip-id');
        expect(created.id, startsWith('csv-'));
        expect(created.name, 'New Mix');
        final mix = (await harness.catalog.getCatalogPlaylist(created.id))!;
        expect(mix.entries.map((entry) => entry.videoId), [
          'bbbbbbbbbbb',
          'aaaaaaaaaaa',
        ]);
        final second = await harness.import(document);
        expect(second.imported, 0);
        expect(second.reused, 2);
        final roadAgain = (await harness.catalog.getCatalogPlaylist(
          'road-trip-id',
        ))!;
        final mixAgain = (await harness.catalog.getCatalogPlaylist(
          created.id,
        ))!;
        expect(
          roadAgain.entries.map((entry) => entry.id),
          road.entries.map((entry) => entry.id),
        );
        expect(
          mixAgain.entries.map((entry) => entry.id),
          mix.entries.map((entry) => entry.id),
        );
        expect(roadAgain.playlist.localRevision, road.playlist.localRevision);
        expect(mixAgain.playlist.localRevision, mix.playlist.localRevision);
        expect(await harness.database.getLocalTracks(), isEmpty);
      },
    );

    test('playlist IDs preserve distinct playlists sharing one name', () async {
      final result = await harness.import(
        _document([
          _directTrack(
            2,
            'Shared song',
            'aaaaaaaaaaa',
            memberships: const [
              LibraryCsvMembership(
                id: 'playlist-one',
                name: 'Same name',
                position: 1,
              ),
              LibraryCsvMembership(
                id: 'playlist-two',
                name: 'Same name',
                position: 1,
              ),
            ],
          ),
        ]),
      );
      expect(result.playlistsUpdated, 2);
      expect(result.imported, 1);
      expect(result.reused, 0);
      expect(
        (await harness.catalog.getCatalogPlaylists())
            .map((playlist) => playlist.id)
            .toSet(),
        {'playlist-one', 'playlist-two'},
      );
      for (final id in ['playlist-one', 'playlist-two']) {
        final playlist = (await harness.catalog.getCatalogPlaylist(id))!;
        expect(playlist.entries.single.videoId, 'aaaaaaaaaaa');
        expect(playlist.entries.single.localTrackId, isNull);
      }
    });

    test(
      'case-sensitive YouTube identities persist as different songs',
      () async {
        final result = await harness.import(
          _document([
            _directTrack(2, 'Upper', 'Abcdefghijk'),
            _directTrack(3, 'Lower', 'abcdefghijk'),
          ]),
        );
        expect(result.imported, 2);
        expect(
          (await harness.onlyPlaylist()).entries.map((entry) => entry.videoId),
          ['Abcdefghijk', 'abcdefghijk'],
        );
      },
    );

    test(
      'links existing local audio without creating or updating local tracks',
      () async {
        final local = _localTrack('already-local', 'aaaaaaaaaaa');
        await harness.database.saveLocalTrack(local);
        final result = await harness.import(
          _document([_directTrack(2, 'Existing', 'aaaaaaaaaaa')]),
        );
        expect(result.reused, 1);
        expect(result.imported, 0);
        final saved = (await harness.onlyPlaylist()).entries.single;
        expect(saved.localTrackId, local.id);
        expect(saved.videoId, 'aaaaaaaaaaa');
        final locals = await harness.database.getLocalTracks();
        expect(locals.single.id, local.id);
        expect(locals.single.filePath, local.filePath);
        expect(locals.single.title, local.title);
      },
    );

    test(
      'upgrades a local catalog occurrence while preserving its ID',
      () async {
        final local = _localTrack('already-local', 'aaaaaaaaaaa');
        await harness.database.saveLocalTrack(local);
        final now = DateTime.utc(2026);
        await harness.catalog.createCatalogPlaylist(
          id: 'road',
          name: 'Road',
          now: now,
        );
        await harness.catalog.appendCatalogEntry(
          playlistId: 'road',
          entryId: 'original-occurrence',
          track: CatalogTrack.local(
            localTrackId: local.id,
            title: 'Local song',
          ),
          localTrackId: local.id,
          now: now,
        );
        final result = await harness.import(
          _document([
            _directTrack(
              2,
              'Matched song',
              'aaaaaaaaaaa',
              memberships: const [
                LibraryCsvMembership(id: 'road', name: 'Road', position: 1),
              ],
            ),
          ]),
        );
        final saved = (await harness.onlyPlaylist()).entries.single;
        expect(saved.id, 'original-occurrence');
        expect(saved.track.key, 'youtube:aaaaaaaaaaa');
        expect(saved.localTrackId, local.id);
        expect(result.reused, 1);
      },
    );

    test(
      'maps favorite aliases while preserving an ordinary explicit Favorites ID',
      () async {
        final document = _document([
          _directTrack(
            2,
            'Favorite song',
            'aaaaaaaaaaa',
            memberships: const [
              LibraryCsvMembership(
                id: Playlist.favoritesId,
                name: 'Favoritas',
                position: 1,
              ),
              LibraryCsvMembership(id: 'LM', name: 'Remote likes', position: 1),
              LibraryCsvMembership(
                id: 'VLLM',
                name: 'Remote likes',
                position: 2,
              ),
              LibraryCsvMembership(name: 'Liked songs', position: 3),
              LibraryCsvMembership(name: 'Favoritos', position: 4),
              LibraryCsvMembership(
                id: 'ordinary-favorites',
                name: 'Favorites',
                position: 1,
              ),
            ],
          ),
        ]);
        final first = await harness.import(document);
        final second = await harness.import(document);
        final playlists = await harness.catalog.getCatalogPlaylists();
        expect(playlists.map((playlist) => playlist.id).toSet(), {
          Playlist.favoritesId,
          'ordinary-favorites',
        });
        for (final playlist in playlists) {
          final saved = (await harness.catalog.getCatalogPlaylist(
            playlist.id,
          ))!;
          expect(saved.entries.single.videoId, 'aaaaaaaaaaa');
        }
        expect(first.imported, 1);
        expect(second.reused, 1);
        expect(second.imported, 0);
      },
    );

    test('rows without membership get a visible default playlist', () async {
      final result = await harness.import(
        _document([
          _directTrack(2, 'No membership', 'aaaaaaaaaaa'),
          _directTrack(
            3,
            'Blank membership',
            'bbbbbbbbbbb',
            memberships: const [LibraryCsvMembership(name: '  ', position: 1)],
          ),
        ]),
      );
      final playlist = await harness.onlyPlaylist();
      expect(playlist.playlist.name, 'Imported');
      expect(playlist.entries.map((entry) => entry.videoId), [
        'aaaaaaaaaaa',
        'bbbbbbbbbbb',
      ]);
      expect(result.imported, 2);
      expect(await harness.database.getLocalTracks(), isEmpty);
    });

    test(
      'a concurrent edit is retained when a revision conflict retries',
      () async {
        await harness.seedPlaylist('road', 'Road', []);
        final initialRevision =
            (await harness.onlyPlaylist()).playlist.localRevision;
        harness.catalog.beforeReplace = (playlistId) async {
          harness.catalog.beforeReplace = null;
          await harness.catalog.appendCatalogEntry(
            playlistId: playlistId,
            entryId: 'concurrent-occurrence',
            track: CatalogTrack.youtube(
              videoId: 'bbbbbbbbbbb',
              title: 'Concurrent song',
            ),
            now: DateTime.now(),
          );
        };
        final result = await harness.import(
          _document([
            _directTrack(
              2,
              'Imported song',
              'aaaaaaaaaaa',
              memberships: const [
                LibraryCsvMembership(id: 'road', name: 'Road', position: 1),
              ],
            ),
          ]),
        );
        expect(harness.catalog.expectedRevisions, [
          initialRevision,
          initialRevision + 1,
        ]);
        final saved = await harness.onlyPlaylist();
        expect(saved.entries.map((entry) => entry.videoId), [
          'bbbbbbbbbbb',
          'aaaaaaaaaaa',
        ]);
        expect(saved.entries.first.id, 'concurrent-occurrence');
        expect(saved.playlist.localRevision, initialRevision + 2);
        expect(result.imported, 1);
        expect(result.failed, 0);
      },
    );

    test(
      'a transactional write failure leaves the existing playlist intact',
      () async {
        await harness.seedPlaylist('road', 'Road', ['oldoldold01']);
        final before = await harness.onlyPlaylist();
        harness.catalog.rejectReplacement = true;
        final result = await harness.import(
          _document([
            _directTrack(
              2,
              'Imported song',
              'aaaaaaaaaaa',
              memberships: const [
                LibraryCsvMembership(id: 'road', name: 'Road', position: 1),
              ],
            ),
          ]),
        );
        final after = await harness.onlyPlaylist();
        expect(
          after.entries.map((entry) => entry.id),
          before.entries.map((entry) => entry.id),
        );
        expect(after.playlist.localRevision, before.playlist.localRevision);
        final db = await harness.database.database;
        expect(
          await db.query(
            'catalog_tracks',
            where: 'track_key = ?',
            whereArgs: ['youtube:aaaaaaaaaaa'],
          ),
          isEmpty,
        );
        expect(result.imported, 0);
        expect(result.failed, 1);
        expect(result.playlistsUpdated, 0);
        expect(result.failures.single.title, 'Road');
      },
    );
  });
}

class _ImportHarness {
  _ImportHarness(this.database) {
    library = _ReadOnlyLibraryRepository(database);
    catalog = _RecordingCatalogRepository(database);
  }

  final _TestDatabase database;
  late final _ReadOnlyLibraryRepository library;
  late final _RecordingCatalogRepository catalog;
  LibraryCsvTrackSearch search = (_) async => const [];
  var maxConcurrentTracks = 3;
  var gateCalls = 0;

  LibraryCsvImportService get service => LibraryCsvImportService(
    library,
    catalog,
    search,
    _gate,
    maxConcurrentTracks: maxConcurrentTracks,
  );

  Future<LibraryCsvImportResult> import(LibraryCsvDocument document) =>
      service.import(document, isCancellationRequested: () => false);

  Future<T> _gate<T>(Future<T> Function() operation) async {
    gateCalls++;
    return operation();
  }

  Future<CatalogPlaylist> onlyPlaylist() async {
    final playlists = await catalog.getCatalogPlaylists();
    expect(playlists, hasLength(1));
    return (await catalog.getCatalogPlaylist(playlists.single.id))!;
  }

  Future<void> seedPlaylist(String id, String name, List<String> videos) async {
    final now = DateTime.utc(2026);
    await catalog.createCatalogPlaylist(id: id, name: name, now: now);
    for (var index = 0; index < videos.length; index++) {
      await catalog.appendCatalogEntry(
        playlistId: id,
        entryId: '$id-entry-$index',
        track: CatalogTrack.youtube(
          videoId: videos[index],
          title: videos[index],
        ),
        now: now,
      );
    }
  }
}

class _TestDatabase extends LocalDatabaseService {
  _TestDatabase(this.path);
  final String path;
  @override
  Future<String> databasePath() async => path;
}

class _ReadOnlyLibraryRepository implements LibraryRepository {
  _ReadOnlyLibraryRepository(this.database);
  final LocalDatabaseService database;
  final unexpectedCalls = <Symbol>[];
  @override
  Future<List<LocalTrack>> getLocalTracks() => database.getLocalTracks();
  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls.add(invocation.memberName);
    throw StateError('Unexpected library operation: ${invocation.memberName}');
  }
}

class _RecordingCatalogRepository extends CatalogPlaylistRepositoryImpl {
  _RecordingCatalogRepository(super.database);
  Future<void> Function(String playlistId)? beforeReplace;
  bool rejectReplacement = false;
  final expectedRevisions = <int?>[];

  @override
  Future<void> replaceCatalogEntries({
    required String playlistId,
    required List<PlaylistEntry> entries,
    required DateTime now,
    int? expectedRevision,
  }) async {
    expectedRevisions.add(expectedRevision);
    await beforeReplace?.call(playlistId);
    return super.replaceCatalogEntries(
      playlistId: playlistId,
      entries: [
        ...entries,
        // Fail inside the SQLite transaction after valid incoming rows.
        if (rejectReplacement)
          entries.last.copyWith(
            id: 'invalid-occurrence',
            playlistId: 'wrong-playlist',
          ),
      ],
      now: now,
      expectedRevision: expectedRevision,
    );
  }
}

LibraryCsvDocument _document(List<LibraryCsvTrack> tracks) =>
    LibraryCsvDocument(
      tracks: tracks,
      detectedFormat: LibraryCsvDetectedFormat.generic,
      defaultPlaylistName: 'Imported',
      hasPlaylistColumn: true,
    );

LibraryCsvTrack _directTrack(
  int rowNumber,
  String title,
  String videoId, {
  List<LibraryCsvMembership> memberships = const [],
}) => _track(
  rowNumber: rowNumber,
  title: title,
  artist: 'Artist',
  videoId: videoId,
  memberships: memberships,
);

LibraryCsvTrack _track({
  required int rowNumber,
  required String title,
  required String artist,
  String? album,
  String? videoId,
  Duration? duration,
  List<LibraryCsvMembership> memberships = const [],
}) => LibraryCsvTrack(
  rowNumber: rowNumber,
  title: title,
  artist: artist,
  album: album,
  youtubeVideoId: videoId,
  duration: duration,
  memberships: memberships,
);

LibraryCsvTrack _midnightCity() => _track(
  rowNumber: 2,
  title: 'Midnight City',
  artist: 'M83',
  duration: const Duration(minutes: 4),
);

TrackInfo _candidate(
  String videoId,
  String title, {
  String artist = 'Artist',
}) => TrackInfo(
  id: videoId,
  title: title,
  artist: artist,
  url: 'https://www.youtube.com/watch?v=$videoId',
  duration: const Duration(minutes: 4),
);

LocalTrack _localTrack(String id, String videoId) => LocalTrack(
  id: id,
  title: 'Existing local song',
  artist: 'Artist',
  filePath: 'C:/music/$id.m4a',
  addedAt: DateTime.utc(2024),
  sourceUrl: 'https://www.youtube.com/watch?v=$videoId',
  sourceId: videoId,
);
