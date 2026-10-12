import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/local_audio_availability.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'playlist cancellation also blocks matching selection downloads awaiting file checks',
    () async {
      final playlist = _playlist();
      final pendingProbe = Completer<bool>();
      final probeStarted = Completer<void>();
      final downloads = _QueuedDownloads();
      final container = ProviderContainer(
        overrides: [
          libraryTracksProvider.overrideWith(
            (ref) async => [_local('stale', 'aaaaaaaaaaa', '/pending')],
          ),
          catalogPlaylistProvider.overrideWith(
            (ref, id) async => CatalogPlaylist(
              playlist: playlist,
              entries: [_entry('matching', 'aaaaaaaaaaa', 0)],
            ),
          ),
          localAudioUsabilityProbeProvider.overrideWithValue((path) {
            probeStarted.complete();
            return pendingProbe.future;
          }),
          downloadControllerProvider.overrideWith(() => downloads),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(downloadControllerProvider.notifier);
      final selectedBatch = controller.downloadTracks([
        for (final id in ['aaaaaaaaaaa', 'bbbbbbbbbbb'])
          TrackInfo(id: id, title: id, artist: '', url: 'https://youtu.be/$id'),
      ]);
      await probeStarted.future;
      expect(await controller.cancelPlaylistDownloads(playlist), 0);
      pendingProbe.complete(false);
      expect(await selectedBatch, 1);
      expect(downloads.tracks.single.id, 'bbbbbbbbbbb');
    },
  );

  test(
    'cancel playlist stops running and queued audio but preserves other tasks',
    () async {
      final playlist = _playlist();
      final downloader = _CancellableDownloads();
      final downloads = _QueuedDownloads({
        for (final (id, status) in [
          ('aaaaaaaaaaa', DownloadProgressStatus.running),
          ('bbbbbbbbbbb', DownloadProgressStatus.queued),
          ('ccccccccccc', DownloadProgressStatus.completed),
          ('ddddddddddd', DownloadProgressStatus.queued),
        ])
          'https://youtu.be/$id': DownloadTaskState(
            url: 'https://youtu.be/$id',
            taskId: 'task-$id',
            mediaType: DownloadMediaType.audio,
            status: status,
          ),
      });
      final container = ProviderContainer(
        overrides: [
          libraryTracksProvider.overrideWith((ref) async => []),
          catalogPlaylistProvider.overrideWith(
            (ref, id) async => CatalogPlaylist(
              playlist: playlist,
              entries: [
                _entry('running', 'aaaaaaaaaaa', 0),
                _entry('queued', 'bbbbbbbbbbb', 1),
                _entry('finished', 'ccccccccccc', 2),
              ],
            ),
          ),
          downloaderServiceProvider.overrideWithValue(downloader),
          downloadControllerProvider.overrideWith(() => downloads),
        ],
      );
      addTearDown(container.dispose);
      expect(
        await container
            .read(downloadControllerProvider.notifier)
            .cancelPlaylistDownloads(playlist),
        2,
      );
      expect(downloader.cancelledTasks, ['task-aaaaaaaaaaa']);
      expect(container.read(downloadControllerProvider).keys, [
        'https://youtu.be/ccccccccccc',
        'https://youtu.be/ddddddddddd',
      ]);
      expect(await downloads.cancelPlaylistDownloads(playlist), 0);
    },
  );

  test(
    'cancelling during preparation prevents later songs from being queued',
    () async {
      final playlist = _playlist();
      final secondProbe = Completer<bool>();
      final probeStarted = Completer<void>();
      final downloads = _QueuedDownloads();
      final container = ProviderContainer(
        overrides: [
          libraryTracksProvider.overrideWith(
            (ref) async => [_local('missing', 'bbbbbbbbbbb', '/pending-audio')],
          ),
          catalogPlaylistProvider.overrideWith(
            (ref, id) async => CatalogPlaylist(
              playlist: playlist,
              entries: [
                _entry('first', 'aaaaaaaaaaa', 0),
                _entry('second', 'bbbbbbbbbbb', 1, localId: 'missing'),
                _entry('third', 'ccccccccccc', 2),
              ],
            ),
          ),
          localAudioUsabilityProbeProvider.overrideWithValue((path) {
            if (!probeStarted.isCompleted) probeStarted.complete();
            return secondProbe.future;
          }),
          downloadControllerProvider.overrideWith(() => downloads),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(downloadControllerProvider.notifier);
      final batch = controller.downloadPlaylist(playlist);
      expect(
        container.read(playlistDownloadPreparationsProvider),
        contains(playlist.id),
      );
      await probeStarted.future;
      expect(await controller.cancelPlaylistDownloads(playlist), 1);
      expect(container.read(playlistDownloadPreparationsProvider), isEmpty);
      secondProbe.complete(false);
      expect(await batch, 1);
      expect(downloads.tracks.map((t) => t.id), ['aaaaaaaaaaa']);
      expect(container.read(downloadControllerProvider), isEmpty);
      expect(await controller.downloadPlaylist(playlist), 3);
    },
  );

  test(
    'cancelling while library loads cancels the entire playlist batch',
    () async {
      final playlist = _playlist();
      final library = Completer<List<LocalTrack>>();
      final downloads = _QueuedDownloads();
      final container = ProviderContainer(
        overrides: [
          libraryTracksProvider.overrideWith((ref) => library.future),
          catalogPlaylistProvider.overrideWith(
            (ref, id) async => CatalogPlaylist(
              playlist: playlist,
              entries: [_entry('first', 'aaaaaaaaaaa', 0)],
            ),
          ),
          downloadControllerProvider.overrideWith(() => downloads),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(downloadControllerProvider.notifier);
      final batch = controller.downloadPlaylist(playlist);
      final cancellation = controller.cancelPlaylistDownloads(playlist);
      library.complete([]);
      expect(await batch, 0);
      expect(await cancellation, 0);
      expect(downloads.tracks, isEmpty);
    },
  );

  test(
    'selected downloads reuse saved audio and skip duplicates and active tasks',
    () async {
      final downloads = _QueuedDownloads({
        'https://youtu.be/bbbbbbbbbbb': const DownloadTaskState(
          url: 'https://youtu.be/bbbbbbbbbbb',
          taskId: 'active',
          mediaType: DownloadMediaType.audio,
          status: DownloadProgressStatus.queued,
        ),
      });
      final container = ProviderContainer(
        overrides: [
          libraryTracksProvider.overrideWith(
            (ref) async => [_local('saved', 'aaaaaaaaaaa', '/saved')],
          ),
          localAudioUsabilityProbeProvider.overrideWithValue(
            (path) async => true,
          ),
          downloadControllerProvider.overrideWith(() => downloads),
        ],
      );
      addTearDown(container.dispose);
      final tracks = [
        for (final id in [
          'aaaaaaaaaaa',
          'bbbbbbbbbbb',
          'ccccccccccc',
          'ccccccccccc',
        ])
          TrackInfo(
            id: id,
            title: id,
            artist: 'Artist',
            url: 'https://www.youtube.com/watch?v=$id',
          ),
      ];
      expect(
        await container
            .read(downloadControllerProvider.notifier)
            .downloadTracks(tracks),
        1,
      );
      expect(downloads.tracks.single.id, 'ccccccccccc');
    },
  );

  test(
    'bulk download queues only missing unique active playlist songs',
    () async {
      final directory = await Directory.systemTemp.createTemp('bstream-bulk-');
      addTearDown(() => directory.delete(recursive: true));
      final saved = File('${directory.path}/saved.m4a');
      await saved.writeAsBytes([1, 2, 3]);
      final empty = File('${directory.path}/empty.m4a');
      await empty.create();
      final locals = [
        _local('linked', 'aaaaaaaaaaa', saved.path),
        _local('elsewhere', 'bbbbbbbbbbb', saved.path),
        _local('stale', 'ccccccccccc', empty.path),
      ];
      final playlist = _playlist();
      final catalog = CatalogPlaylist(
        playlist: playlist,
        entries: [
          _entry('linked', 'aaaaaaaaaaa', 0, localId: 'linked'),
          _entry('global', 'bbbbbbbbbbb', 1),
          _entry('stale', 'ccccccccccc', 2, localId: 'stale'),
          _entry('missing', 'ddddddddddd', 3),
          _entry('duplicate', 'ddddddddddd', 4),
          _entry('active', 'fffffffffff', 5),
          _entry('deleted', 'eeeeeeeeeee', 6, deleted: true),
        ],
      );
      final downloads = _QueuedDownloads({
        'https://youtu.be/fffffffffff': const DownloadTaskState(
          url: 'https://youtu.be/fffffffffff',
          taskId: 'already-running',
          mediaType: DownloadMediaType.audio,
          status: DownloadProgressStatus.running,
        ),
      });
      final container = ProviderContainer(
        overrides: [
          libraryTracksProvider.overrideWith((ref) async => locals),
          catalogPlaylistProvider.overrideWith((ref, id) async => catalog),
          downloadControllerProvider.overrideWith(() => downloads),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(downloadControllerProvider.notifier);

      expect(await controller.downloadPlaylist(playlist), 2);
      expect(downloads.tracks.map((track) => track.id), [
        'ccccccccccc',
        'ddddddddddd',
      ]);
      expect(await controller.downloadPlaylist(playlist), 0);
      expect(downloads.tracks, hasLength(2));
      expect(await saved.readAsBytes(), [1, 2, 3]);
      expect(await empty.length(), 0);
    },
  );

  test('simultaneous bulk requests share the same queue preparation', () async {
    final playlist = _playlist();
    final pendingLibrary = Completer<List<LocalTrack>>();
    final downloads = _QueuedDownloads();
    final container = ProviderContainer(
      overrides: [
        libraryTracksProvider.overrideWith((ref) => pendingLibrary.future),
        catalogPlaylistProvider.overrideWith(
          (ref, id) async => CatalogPlaylist(
            playlist: playlist,
            entries: [_entry('one', 'aaaaaaaaaaa', 0)],
          ),
        ),
        downloadControllerProvider.overrideWith(() => downloads),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(downloadControllerProvider.notifier);
    final first = controller.downloadPlaylist(playlist);
    final second = controller.downloadPlaylist(playlist);
    pendingLibrary.complete([]);

    expect(await Future.wait([first, second]), [1, 1]);
    expect(downloads.tracks, hasLength(1));
  });

  test(
    'legacy playlists reuse saved audio and recover missing source files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bstream-legacy-bulk-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final saved = File('${directory.path}/saved.m4a');
      await saved.writeAsBytes([1]);
      final playlist = _playlist().copyWith(trackIds: ['saved', 'missing']);
      final downloads = _QueuedDownloads();
      final container = ProviderContainer(
        overrides: [
          libraryTracksProvider.overrideWith(
            (ref) async => [
              _local('saved', 'aaaaaaaaaaa', saved.path),
              _local('missing', 'bbbbbbbbbbb', '${directory.path}/missing.m4a'),
            ],
          ),
          catalogPlaylistProvider.overrideWith((ref, id) async => null),
          downloadControllerProvider.overrideWith(() => downloads),
        ],
      );
      addTearDown(container.dispose);
      expect(
        await container
            .read(downloadControllerProvider.notifier)
            .downloadPlaylist(playlist),
        1,
      );
      expect(downloads.tracks.single.id, 'bbbbbbbbbbb');
      expect(
        downloads.tracks.single.url,
        'https://www.youtube.com/watch?v=bbbbbbbbbbb',
      );
    },
  );
}

Playlist _playlist() => Playlist(
  id: 'bulk-playlist',
  name: 'Bulk playlist',
  trackIds: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

LocalTrack _local(String id, String videoId, String path) => LocalTrack(
  id: id,
  title: id,
  artist: 'Artist',
  filePath: path,
  sourceId: videoId,
  addedAt: DateTime.utc(2026),
);

PlaylistEntry _entry(
  String id,
  String videoId,
  int position, {
  String? localId,
  bool deleted = false,
}) => PlaylistEntry(
  id: id,
  playlistId: 'bulk-playlist',
  track: CatalogTrack.youtube(
    videoId: videoId,
    title: id,
    artists: const ['Artist'],
  ),
  localTrackId: localId,
  position: position,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  deletedAt: deleted ? DateTime.utc(2026) : null,
);

class _QueuedDownloads extends DownloadController {
  _QueuedDownloads([this.initial = const {}]);

  final Map<String, DownloadTaskState> initial;
  final tracks = <TrackInfo>[];

  @override
  Map<String, DownloadTaskState> build() => initial;

  @override
  Future<void> downloadAudio(TrackInfo track) async {
    tracks.add(track);
    state = {
      ...state,
      track.url: DownloadTaskState(
        url: track.url,
        taskId: 'queued-${tracks.length}',
        mediaType: DownloadMediaType.audio,
        status: DownloadProgressStatus.queued,
      ),
    };
  }
}

class _CancellableDownloads
    implements DownloaderService, CancellableDownloaderService {
  final cancelledTasks = <String>[];

  @override
  Future<void> cancelDownload(String taskId) async =>
      cancelledTasks.add(taskId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
