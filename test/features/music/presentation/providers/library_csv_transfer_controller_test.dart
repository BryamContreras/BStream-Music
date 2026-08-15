import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/storage/library_csv_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'preview parses off-thread and publishes the detected document',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bstream-csv-controller-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}songs.csv');
      await file.writeAsString(
        'Title,Artist,Album,YouTube Video ID\r\n'
        'Song,Artist,Album,dQw4w9WgXcQ\r\n',
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
    },
  );

  test(
    'prepareExport snapshots tracks and playlists through the repository',
    () async {
      final now = DateTime.utc(2025, 1, 2);
      final repository = _MemoryLibraryRepository(
        tracks: [
          LocalTrack(
            id: 'track-1',
            title: 'Song',
            artist: 'Artist',
            filePath: r'C:\music\song.m4a',
            addedAt: now,
            sourceId: 'dQw4w9WgXcQ',
            sourceUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          ),
        ],
        playlists: [
          Playlist(
            id: 'playlist-1',
            name: 'Road trip',
            trackIds: const ['track-1'],
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [libraryRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final document = await container
          .read(libraryCsvTransferControllerProvider.notifier)
          .prepareExport();

      expect(repository.localTrackReads, 1);
      expect(repository.playlistReads, 1);
      expect(document.tracks.single.youtubeVideoId, 'dQw4w9WgXcQ');
      expect(document.playlistNames, {'Road trip'});
      expect(document.tracks.single.memberships.single.id, 'playlist-1');
      expect(
        container.read(libraryCsvTransferControllerProvider).phase,
        LibraryCsvTransferPhase.completed,
      );
    },
  );

  test(
    'requestCancel finishes the active song and cancels the remainder',
    () async {
      final repository = _MemoryLibraryRepository();
      final download = Completer<LocalTrackDownloadResult>();
      _ControlledDownloadHelper? helper;
      final container = ProviderContainer(
        overrides: [
          libraryRepositoryProvider.overrideWithValue(repository),
          localTrackDownloadHelperProvider.overrideWith((ref) {
            final next = _ControlledDownloadHelper(ref, download.future);
            helper = next;
            return next;
          }),
        ],
      );
      addTearDown(container.dispose);
      final document = LibraryCsvDocument(
        tracks: const [
          LibraryCsvTrack(
            rowNumber: 2,
            title: 'First',
            artist: 'Artist',
            youtubeVideoId: 'dQw4w9WgXcQ',
          ),
          LibraryCsvTrack(
            rowNumber: 3,
            title: 'Second',
            artist: 'Artist',
            youtubeVideoId: '9bZkp7q19f0',
          ),
        ],
        detectedFormat: LibraryCsvDetectedFormat.metroList,
        defaultPlaylistName: 'songs',
        hasPlaylistColumn: false,
      );
      final controller = container.read(
        libraryCsvTransferControllerProvider.notifier,
      );

      final operation = controller.importDocument(document);
      await _waitUntil(() => helper?.calls == 1);
      controller.requestCancel();
      expect(
        container.read(libraryCsvTransferControllerProvider).cancelRequested,
        isTrue,
      );
      download.complete(
        LocalTrackDownloadResult(
          track: LocalTrack(
            id: 'local-1',
            title: 'First',
            artist: 'Artist',
            filePath: r'C:\music\first.webm',
            addedAt: DateTime.utc(2025),
          ),
          remoteTrack: const TrackInfo(
            id: 'dQw4w9WgXcQ',
            title: 'First',
            artist: 'Artist',
            url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          ),
          reusedExisting: false,
        ),
      );

      final result = await operation;

      expect(helper!.calls, 1);
      expect(result.processed, 1);
      expect(result.downloaded, 1);
      expect(result.cancelled, isTrue);
      final state = container.read(libraryCsvTransferControllerProvider);
      expect(state.phase, LibraryCsvTransferPhase.completed);
      expect(state.result, same(result));
      expect(state.isBusy, isFalse);
    },
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('The expected asynchronous operation did not start.');
}

class _ControlledDownloadHelper extends LocalTrackDownloadHelper {
  _ControlledDownloadHelper(super.ref, this.result);

  final Future<LocalTrackDownloadResult> result;
  int calls = 0;

  @override
  Future<LocalTrackDownloadResult> resolveForLibrary(
    TrackInfo track, {
    String? taskId,
    void Function(TrackInfo track)? onResolved,
    void Function()? onDownloadStarted,
  }) {
    calls++;
    onResolved?.call(track);
    return result;
  }
}

class _MemoryLibraryRepository implements LibraryRepository {
  _MemoryLibraryRepository({
    List<LocalTrack> tracks = const [],
    List<Playlist> playlists = const [],
  }) : tracks = List.of(tracks),
       playlists = List.of(playlists);

  final List<LocalTrack> tracks;
  final List<Playlist> playlists;
  int localTrackReads = 0;
  int playlistReads = 0;

  @override
  Future<List<LocalTrack>> getLocalTracks() async {
    localTrackReads++;
    return List.unmodifiable(tracks);
  }

  @override
  Future<List<Playlist>> getPlaylists() async {
    playlistReads++;
    return List.unmodifiable(playlists);
  }

  @override
  Future<void> saveLocalTrack(LocalTrack track) async {
    tracks.removeWhere((item) => item.id == track.id);
    tracks.add(track);
  }

  @override
  Future<void> savePlaylist(Playlist playlist) async {
    playlists.removeWhere((item) => item.id == playlist.id);
    playlists.add(playlist);
  }

  @override
  Future<void> deleteLocalTrack(String trackId) async {
    tracks.removeWhere((track) => track.id == trackId);
  }

  @override
  Future<void> deletePlaylist(String playlistId) async {
    playlists.removeWhere((playlist) => playlist.id == playlistId);
  }

  @override
  Future<List<LocalTrack>> getHistory() async => const [];

  @override
  Future<void> markPlayed(
    String trackId,
    DateTime playedAt, {
    String? playlistId,
  }) async {}

  @override
  Future<Set<String>> purgeMissingLocalTracks(List<LocalTrack> tracks) async =>
      const {};
}
