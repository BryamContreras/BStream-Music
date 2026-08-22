import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'catalog queue prefers downloads and preserves duplicate occurrences',
    () {
      final now = DateTime.utc(2026, 8, 22);
      final track = CatalogTrack.youtube(
        videoId: 'video-1',
        title: 'Track',
        artists: const ['Artist'],
      );
      final playlist = CatalogPlaylist(
        playlist: Playlist(
          id: 'playlist-1',
          name: 'Synced',
          trackIds: const [],
          createdAt: now,
          updatedAt: now,
        ),
        entries: [
          PlaylistEntry(
            id: 'entry-2',
            playlistId: 'playlist-1',
            track: track,
            localTrackId: 'local-1',
            position: 1,
            createdAt: now,
            updatedAt: now,
          ),
          PlaylistEntry(
            id: 'entry-1',
            playlistId: 'playlist-1',
            track: track,
            localTrackId: 'local-1',
            position: 0,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      final local = LocalTrack(
        id: 'local-1',
        title: 'Track',
        artist: 'Artist',
        filePath: r'C:\music\track.m4a',
        sourceId: 'video-1',
        addedAt: now,
      );

      final queue = catalogPlaylistPlaybackItems(playlist, [local]);

      expect(queue.map((item) => item.entryId), ['entry-1', 'entry-2']);
      expect(queue.every((item) => identical(item.localTrack, local)), isTrue);
      expect(queue.every((item) => item.remoteTrack?.id == 'video-1'), isTrue);
    },
  );

  test('catalog queue keeps a remote entry when no download exists', () {
    final now = DateTime.utc(2026, 8, 22);
    final playlist = CatalogPlaylist(
      playlist: Playlist(
        id: 'playlist-1',
        name: 'Remote',
        trackIds: const [],
        createdAt: now,
        updatedAt: now,
      ),
      entries: [
        PlaylistEntry(
          id: 'remote-entry',
          playlistId: 'playlist-1',
          track: CatalogTrack.youtube(videoId: 'remote-1', title: 'Remote'),
          position: 0,
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );

    final queue = catalogPlaylistPlaybackItems(playlist, const []);

    expect(queue.single.localTrack, isNull);
    expect(queue.single.remoteTrack?.id, 'remote-1');
  });
}
