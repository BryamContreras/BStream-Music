import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bulk remote playlist import is catalog-only and deduplicates video ids',
    () async {
      final database = _MemoryCatalogDatabase();
      final downloads = _RecordingDownloadController();
      final sync = _RecordingPlaylistSyncController();
      final container = ProviderContainer(
        overrides: [
          databaseServiceProvider.overrideWithValue(database),
          downloadControllerProvider.overrideWith(() => downloads),
          playerControllerProvider.overrideWith(_InactivePlayerController.new),
          youtubeMusicPlaylistSyncControllerProvider.overrideWith(() => sync),
        ],
      );
      addTearDown(container.dispose);
      await container.read(playlistsControllerProvider.future);

      final added = await container
          .read(playlistsControllerProvider.notifier)
          .addRemoteTracksToPlaylist(database.playlist.id, const [
            TrackInfo(
              id: 'abcdefghijk',
              title: 'First',
              artist: 'Artist',
              url: 'https://www.youtube.com/watch?v=abcdefghijk',
            ),
            TrackInfo(
              id: 'lmnopqrstuv',
              title: 'Second',
              artist: 'Artist',
              url: 'https://youtu.be/lmnopqrstuv',
            ),
            TrackInfo(
              id: 'abcdefghijk',
              title: 'Duplicate',
              artist: 'Artist',
              url: 'https://youtu.be/abcdefghijk',
            ),
          ], download: false);

      expect(added, 2);
      expect(database.entries.map((entry) => entry.videoId), [
        'abcdefghijk',
        'lmnopqrstuv',
      ]);
      expect(
        database.entries.every((entry) => entry.localTrackId == null),
        isTrue,
      );
      expect(downloads.tracks, isEmpty);
      expect(sync.requests, 1);

      final repeated = await container
          .read(playlistsControllerProvider.notifier)
          .addRemoteTracksToPlaylist(database.playlist.id, const [
            TrackInfo(
              id: 'abcdefghijk',
              title: 'First',
              artist: 'Artist',
              url: 'https://www.youtube.com/watch?v=abcdefghijk',
            ),
          ], download: false);

      expect(repeated, 0);
      expect(database.entries, hasLength(2));
      expect(downloads.tracks, isEmpty);
      expect(sync.requests, 1);
    },
  );
}

class _MemoryCatalogDatabase extends LocalDatabaseService {
  _MemoryCatalogDatabase()
    : playlist = Playlist(
        id: 'destination',
        name: 'Destination',
        trackIds: const [],
        createdAt: DateTime.utc(2026, 8, 24),
        updatedAt: DateTime.utc(2026, 8, 24),
      );

  final Playlist playlist;
  final List<PlaylistEntry> entries = [];

  @override
  Future<List<Playlist>> getCatalogPlaylists({
    bool includeDeleted = false,
  }) async => [playlist];

  @override
  Future<CatalogPlaylist?> getCatalogPlaylist(
    String playlistId, {
    bool includeDeletedEntries = false,
  }) async {
    if (playlistId != playlist.id) {
      return null;
    }
    return CatalogPlaylist(playlist: playlist, entries: entries);
  }

  @override
  Future<PlaylistEntry> appendCatalogEntry({
    required String playlistId,
    required String entryId,
    required CatalogTrack track,
    required DateTime now,
    String? localTrackId,
    PlaylistEntryOrigin origin = PlaylistEntryOrigin.local,
  }) async {
    final entry = PlaylistEntry(
      id: entryId,
      playlistId: playlistId,
      track: track,
      localTrackId: localTrackId,
      position: entries.length,
      origin: origin,
      createdAt: now,
      updatedAt: now,
    );
    entries.add(entry);
    return entry;
  }
}

class _RecordingDownloadController extends DownloadController {
  final List<TrackInfo> tracks = [];

  @override
  Map<String, DownloadTaskState> build() => const {};

  @override
  Future<void> downloadAudio(TrackInfo track) async {
    tracks.add(track);
  }
}

class _InactivePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);

  @override
  bool isLocalQueueSourceActive(String sourceId) => false;
}

class _RecordingPlaylistSyncController
    extends YouTubeMusicPlaylistSyncController {
  int requests = 0;

  @override
  YouTubeMusicPlaylistSyncState build() =>
      const YouTubeMusicPlaylistSyncState();

  @override
  void requestAutomaticSync() {
    requests += 1;
  }
}
