import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/services/storage/library_csv_import_service.dart';
import 'package:bstream_music/services/storage/library_csv_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LibraryCsvImportService resolution', () {
    test(
      'a direct YouTube id bypasses search and preserves metadata',
      () async {
        var searchCalls = 0;
        TrackInfo? downloadedTrack;
        final harness = _ImportHarness(
          search: (query) async {
            searchCalls++;
            return const [];
          },
          download: (track, {required taskId, onResolved}) async {
            downloadedTrack = track;
            return _downloaded(track, localId: 'local-direct');
          },
        );

        final result = await harness.service.import(
          _document([
            _track(
              rowNumber: 2,
              title: 'Direct song',
              artist: 'Direct artist',
              album: 'Direct album',
              videoId: 'abcdefghijk',
              duration: const Duration(minutes: 3),
            ),
          ]),
          isCancellationRequested: () => false,
        );

        expect(searchCalls, 0);
        expect(downloadedTrack?.id, 'abcdefghijk');
        expect(
          downloadedTrack?.url,
          'https://www.youtube.com/watch?v=abcdefghijk',
        );
        expect(downloadedTrack?.title, 'Direct song');
        expect(downloadedTrack?.artist, 'Direct artist');
        expect(downloadedTrack?.album, 'Direct album');
        expect(result.downloaded, 1);
        expect(result.failed, 0);
      },
    );

    test('an exact metadata search match is accepted', () async {
      final queries = <String>[];
      const candidate = TrackInfo(
        id: 'searched001',
        title: 'Dreams',
        artist: 'Fleetwood Mac',
        album: 'Rumours',
        duration: Duration(minutes: 4, seconds: 17),
        url: 'https://www.youtube.com/watch?v=searched001',
      );
      TrackInfo? downloadedTrack;
      final harness = _ImportHarness(
        search: (query) async {
          queries.add(query);
          return const [candidate];
        },
        download: (track, {required taskId, onResolved}) async {
          downloadedTrack = track;
          return _downloaded(track, localId: 'local-searched');
        },
      );

      final result = await harness.service.import(
        _document([
          _track(
            rowNumber: 2,
            title: 'Dreams',
            artist: 'Fleetwood Mac',
            album: 'Rumours',
            duration: const Duration(minutes: 4, seconds: 17),
          ),
        ]),
        isCancellationRequested: () => false,
      );

      expect(queries, ['Dreams Fleetwood Mac Rumours']);
      expect(downloadedTrack, candidate);
      expect(result.downloaded, 1);
      expect(result.failed, 0);
    });

    test('a low-confidence mismatch is rejected without downloading', () async {
      var downloadCalls = 0;
      final harness = _ImportHarness(
        search: (_) async => const [
          TrackInfo(
            id: 'mismatch001',
            title: 'Bohemian Rhapsody',
            artist: 'Queen',
            url: 'https://www.youtube.com/watch?v=mismatch001',
          ),
        ],
        download: (track, {required taskId, onResolved}) async {
          downloadCalls++;
          return _downloaded(track);
        },
      );

      final result = await harness.service.import(
        _document([_track(rowNumber: 7, title: 'Golden Hour', artist: 'JVKE')]),
        isCancellationRequested: () => false,
      );

      expect(downloadCalls, 0);
      expect(result.processed, 1);
      expect(result.failed, 1);
      expect(result.failures.single.rowNumber, 7);
      expect(result.failures.single.ambiguous, isTrue);
    });

    test(
      'two similarly ranked version matches are treated as ambiguous',
      () async {
        var downloadCalls = 0;
        final harness = _ImportHarness(
          search: (_) async => const [
            TrackInfo(
              id: 'ambiguous01',
              title: 'Midnight City Live',
              artist: 'M83',
              duration: Duration(minutes: 4),
              url: 'https://www.youtube.com/watch?v=ambiguous01',
            ),
            TrackInfo(
              id: 'ambiguous02',
              title: 'Midnight City Remix',
              artist: 'M83',
              duration: Duration(minutes: 4),
              url: 'https://www.youtube.com/watch?v=ambiguous02',
            ),
          ],
          download: (track, {required taskId, onResolved}) async {
            downloadCalls++;
            return _downloaded(track);
          },
        );

        final result = await harness.service.import(
          _document([
            _track(
              rowNumber: 2,
              title: 'Midnight City',
              artist: 'M83',
              duration: const Duration(minutes: 4),
            ),
          ]),
          isCancellationRequested: () => false,
        );

        expect(downloadCalls, 0);
        expect(result.failed, 1);
        expect(result.failures.single.ambiguous, isTrue);
      },
    );

    test(
      'duplicate copies of one search candidate do not create ambiguity',
      () async {
        var downloadCalls = 0;
        const duplicate = TrackInfo(
          id: 'duplicate01',
          title: 'Midnight City Live',
          artist: 'M83',
          duration: Duration(minutes: 4),
          url: 'https://www.youtube.com/watch?v=duplicate01',
        );
        final harness = _ImportHarness(
          search: (_) async => const [duplicate, duplicate],
          download: (track, {required taskId, onResolved}) async {
            downloadCalls++;
            return _downloaded(track);
          },
        );

        final result = await harness.service.import(
          _document([
            _track(
              rowNumber: 2,
              title: 'Midnight City',
              artist: 'M83',
              duration: const Duration(minutes: 4),
            ),
          ]),
          isCancellationRequested: () => false,
        );

        expect(downloadCalls, 1);
        expect(result.downloaded, 1);
        expect(result.failed, 0);
      },
    );
  });

  group('LibraryCsvImportService queue behavior', () {
    test(
      'downloads a bounded batch in parallel and continues after a failure',
      () async {
        var activeDownloads = 0;
        var maximumActiveDownloads = 0;
        final downloadOrder = <String>[];
        final harness = _ImportHarness(
          search: (_) async => const [],
          download: (track, {required taskId, onResolved}) async {
            downloadOrder.add(track.id);
            activeDownloads++;
            if (activeDownloads > maximumActiveDownloads) {
              maximumActiveDownloads = activeDownloads;
            }
            await Future<void>.delayed(const Duration(milliseconds: 2));
            activeDownloads--;
            if (track.id == 'bbbbbbbbbbb') {
              throw StateError('simulated download failure');
            }
            return _downloaded(track, localId: 'local-${track.id}');
          },
        );

        final result = await harness.service.import(
          _document([
            _directTrack(2, 'First', 'aaaaaaaaaaa'),
            _directTrack(3, 'Second', 'bbbbbbbbbbb'),
            _directTrack(4, 'Third', 'ccccccccccc'),
            _directTrack(5, 'Fourth', 'ddddddddddd'),
          ]),
          isCancellationRequested: () => false,
        );

        expect(downloadOrder, [
          'aaaaaaaaaaa',
          'bbbbbbbbbbb',
          'ccccccccccc',
          'ddddddddddd',
        ]);
        expect(maximumActiveDownloads, 3);
        expect(result.processed, 4);
        expect(result.downloaded, 3);
        expect(result.failed, 1);
        expect(result.failures.single.title, 'Second');
        expect(result.successful + result.failed, result.processed);
      },
    );

    test(
      'cancellation waits for the active download and stops before the next',
      () async {
        var cancellationRequested = false;
        final firstDownloadStarted = Completer<void>();
        final releaseFirstDownload = Completer<void>();
        final downloadOrder = <String>[];
        final progress = <LibraryCsvImportProgress>[];
        final harness = _ImportHarness(
          maxConcurrentTracks: 1,
          search: (_) async => const [],
          download: (track, {required taskId, onResolved}) async {
            downloadOrder.add(track.id);
            firstDownloadStarted.complete();
            await releaseFirstDownload.future;
            return _downloaded(track, localId: 'local-${track.id}');
          },
        );

        final operation = harness.service.import(
          _document([
            _directTrack(2, 'First', 'aaaaaaaaaaa'),
            _directTrack(3, 'Second', 'bbbbbbbbbbb'),
          ]),
          isCancellationRequested: () => cancellationRequested,
          onProgress: progress.add,
        );
        await firstDownloadStarted.future;
        cancellationRequested = true;
        releaseFirstDownload.complete();
        final result = await operation;

        expect(downloadOrder, ['aaaaaaaaaaa']);
        expect(result.cancelled, isTrue);
        expect(result.processed, 1);
        expect(result.downloaded, 1);
        expect(result.failed, 0);
        expect(progress.last.cancelRequested, isTrue);
        expect(progress.last.processed, 1);
      },
    );

    test(
      'cancellation during active search still finishes that track before stopping',
      () async {
        var cancellationRequested = false;
        var searchCalls = 0;
        var downloadCalls = 0;
        final searchStarted = Completer<void>();
        final releaseSearch = Completer<List<TrackInfo>>();
        final harness = _ImportHarness(
          maxConcurrentTracks: 1,
          search: (_) async {
            searchCalls++;
            searchStarted.complete();
            return releaseSearch.future;
          },
          download: (track, {required taskId, onResolved}) async {
            downloadCalls++;
            return _downloaded(track, localId: 'local-searched');
          },
        );

        final operation = harness.service.import(
          _document([
            _track(rowNumber: 2, title: 'Dreams', artist: 'Fleetwood Mac'),
            _directTrack(3, 'Second', 'bbbbbbbbbbb'),
          ]),
          isCancellationRequested: () => cancellationRequested,
        );
        await searchStarted.future;
        cancellationRequested = true;
        releaseSearch.complete(const [
          TrackInfo(
            id: 'searched001',
            title: 'Dreams',
            artist: 'Fleetwood Mac',
            url: 'https://www.youtube.com/watch?v=searched001',
          ),
        ]);
        final result = await operation;

        expect(searchCalls, 1);
        expect(downloadCalls, 1);
        expect(result.cancelled, isTrue);
        expect(result.processed, 1);
        expect(result.downloaded, 1);
        expect(result.failed, 0);
      },
    );

    test(
      'a reused local track is counted separately from a download',
      () async {
        final harness = _ImportHarness(
          search: (_) async => const [],
          download: (track, {required taskId, onResolved}) async =>
              _downloaded(track, localId: 'already-local', reused: true),
        );

        final result = await harness.service.import(
          _document([_directTrack(2, 'Existing', 'aaaaaaaaaaa')]),
          isCancellationRequested: () => false,
        );

        expect(result.reused, 1);
        expect(result.downloaded, 0);
        expect(result.successful, 1);
        expect(result.failed, 0);
      },
    );
  });

  test(
    'playlist memberships are ordered, deduplicated, merged by normalized name, and gated',
    () async {
      final repository = _MemoryLibraryRepository(
        playlists: [
          Playlist(
            id: 'road-trip-id',
            name: '  road trip  ',
            trackIds: const ['old-track', 'local-b'],
            createdAt: DateTime.utc(2020),
            updatedAt: DateTime.utc(2020),
          ),
        ],
      );
      final harness = _ImportHarness(
        repository: repository,
        search: (_) async => const [],
        download: (track, {required taskId, onResolved}) async => _downloaded(
          track,
          localId: track.id == 'aaaaaaaaaaa' ? 'local-a' : 'local-b',
        ),
      );
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

      final result = await harness.service.import(
        document,
        isCancellationRequested: () => false,
      );

      expect(result.playlistsUpdated, 2);
      expect(harness.gateCalls, 2);
      expect(repository.playlists, hasLength(2));
      final existing = repository.playlists.singleWhere(
        (playlist) => playlist.id == 'road-trip-id',
      );
      expect(existing.name, '  road trip  ');
      expect(existing.trackIds, ['old-track', 'local-b', 'local-a']);
      final created = repository.playlists.singleWhere(
        (playlist) => playlist.id != 'road-trip-id',
      );
      expect(created.id, startsWith('csv-'));
      expect(created.name, 'New Mix');
      expect(created.trackIds, ['local-b', 'local-a']);
    },
  );

  test(
    'BStream playlist IDs preserve distinct playlists with one name',
    () async {
      final repository = _MemoryLibraryRepository();
      final harness = _ImportHarness(
        repository: repository,
        search: (_) async => const [],
        download: (track, {required taskId, onResolved}) async =>
            _downloaded(track, localId: 'local-a'),
      );
      final document = _document([
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
      ]);

      final result = await harness.service.import(
        document,
        isCancellationRequested: () => false,
      );

      expect(result.playlistsUpdated, 2);
      expect(repository.playlists.map((playlist) => playlist.id).toSet(), {
        'playlist-one',
        'playlist-two',
      });
      expect(
        repository.playlists.map((playlist) => playlist.trackIds),
        everyElement(['local-a']),
      );
    },
  );
}

class _ImportHarness {
  _ImportHarness({
    _MemoryLibraryRepository? repository,
    this.maxConcurrentTracks = 3,
    required this.search,
    required this.download,
  }) : repository = repository ?? _MemoryLibraryRepository();

  final _MemoryLibraryRepository repository;
  final int maxConcurrentTracks;
  final LibraryCsvTrackSearch search;
  final LibraryCsvTrackDownload download;
  var gateCalls = 0;

  LibraryCsvImportService get service => LibraryCsvImportService(
    repository,
    search,
    download,
    _gate,
    maxConcurrentTracks: maxConcurrentTracks,
  );

  Future<T> _gate<T>(Future<T> Function() operation) async {
    gateCalls++;
    return operation();
  }
}

class _MemoryLibraryRepository implements LibraryRepository {
  _MemoryLibraryRepository({List<Playlist> playlists = const []})
    : playlists = List.of(playlists);

  final List<Playlist> playlists;
  final List<LocalTrack> localTracks = [];

  @override
  Future<List<LocalTrack>> getLocalTracks() async => List.of(localTracks);

  @override
  Future<void> saveLocalTrack(LocalTrack track) async {
    localTracks.removeWhere((candidate) => candidate.id == track.id);
    localTracks.add(track);
  }

  @override
  Future<void> deleteLocalTrack(String trackId) async {
    localTracks.removeWhere((track) => track.id == trackId);
  }

  @override
  Future<Set<String>> purgeMissingLocalTracks(List<LocalTrack> tracks) async =>
      const {};

  @override
  Future<void> markPlayed(
    String trackId,
    DateTime playedAt, {
    String? playlistId,
  }) async {}

  @override
  Future<List<LocalTrack>> getHistory() async => const [];

  @override
  Future<List<Playlist>> getPlaylists() async => List.of(playlists);

  @override
  Future<void> savePlaylist(Playlist playlist) async {
    playlists.removeWhere((candidate) => candidate.id == playlist.id);
    playlists.add(playlist);
  }

  @override
  Future<void> deletePlaylist(String playlistId) async {
    playlists.removeWhere((playlist) => playlist.id == playlistId);
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

LibraryCsvDownloadedTrack _downloaded(
  TrackInfo track, {
  String? localId,
  bool reused = false,
}) => LibraryCsvDownloadedTrack(
  track: LocalTrack(
    id: localId ?? 'local-${track.id}',
    title: track.title,
    artist: track.artist,
    filePath: 'C:/music/${track.id}.m4a',
    addedAt: DateTime.utc(2024),
    sourceUrl: track.url,
    sourceId: track.id,
    duration: track.duration,
    album: track.album,
    artists: track.artists,
  ),
  reusedExisting: reused,
);
