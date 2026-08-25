import 'package:bstream_music/core/utils/image_source.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_artwork.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('local playlist artwork prefers the canonical catalog cover', () {
    final track = LocalTrack(
      id: 'local-track',
      title: 'Song',
      artist: 'Artist',
      filePath: '/music/song.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/video-thumbnail.jpg',
      thumbnailUrl: 'https://i.ytimg.com/vi/video000001/hqdefault.jpg',
      catalogThumbnailUrl: 'https://img.test/real-album-cover.jpg',
    );

    final artwork = preferredLocalPlaylistArtworkSource(track);
    expect(artwork?.source, 'https://img.test/real-album-cover.jpg');
    expect(artwork?.fallbackSource, endsWith('video-thumbnail.jpg'));
  });

  test('individual local track keeps its saved cover as offline fallback', () {
    final track = LocalTrack(
      id: 'local-track',
      title: 'Song',
      artist: 'Artist',
      filePath: '/music/song.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/soft-saved-thumbnail.jpg',
      thumbnailUrl: 'https://i.ytimg.com/vi/video000001/hqdefault.jpg',
      catalogThumbnailUrl:
          'https://lh3.googleusercontent.com/catalog-cover=w120-h120-l90-rj',
    );

    final artwork = preferredLocalTrackArtworkSource(track);
    expect(
      artwork?.source,
      'https://lh3.googleusercontent.com/catalog-cover=w1280-h1280-l90-rj',
    );
    expect(artwork?.fallbackSource, '/music/soft-saved-thumbnail.jpg');
  });

  test('individual local track prefers its remote video over a soft file', () {
    final track = LocalTrack(
      id: 'legacy-local-track',
      title: 'Song',
      artist: 'Artist',
      filePath: '/music/song.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/soft-saved-thumbnail.jpg',
      thumbnailUrl: 'https://i.ytimg.com/vi/video000001/hqdefault.jpg',
    );

    final artwork = preferredLocalTrackArtworkSource(track);
    expect(artwork?.source, 'https://i.ytimg.com/vi/video000001/hqdefault.jpg');
    expect(artwork?.fallbackSource, '/music/soft-saved-thumbnail.jpg');
  });

  test('individual legacy track upgrades its old small Google artwork URL', () {
    final track = LocalTrack(
      id: 'legacy-google-track',
      title: 'Bonsai',
      artist: 'Artist',
      filePath: '/music/bonsai.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/soft-bonsai.jpg',
      thumbnailUrl: 'https://lh3.googleusercontent.com/bonsai=w120-h120-l90-rj',
    );

    final artwork = preferredLocalTrackArtworkSource(track);
    expect(
      artwork?.source,
      'https://lh3.googleusercontent.com/bonsai=w1280-h1280-l90-rj',
    );
    expect(artwork?.fallbackSource, '/music/soft-bonsai.jpg');
  });

  test(
    'individual device track preserves its lazy embedded artwork source',
    () {
      final source = deviceAudioArtworkSourceForUri(
        'content://media/external/audio/media/42',
      );
      final track = LocalTrack(
        id: 'external-track',
        title: 'Song',
        artist: 'Artist',
        filePath: 'content://media/external/audio/media/42',
        addedAt: DateTime.utc(2026),
        thumbnailUrl: source,
        isExternal: true,
      );

      final artwork = preferredLocalTrackArtworkSource(track);

      expect(artwork?.source, source);
      expect(artwork?.fallbackSource, isNull);
    },
  );

  test('catalog playlist artwork stays canonical before local fallbacks', () {
    final local = LocalTrack(
      id: 'local-track',
      title: 'Song',
      artist: 'Artist',
      filePath: '/music/song.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/video-thumbnail.jpg',
      catalogThumbnailUrl: 'https://img.test/local-catalog-cover.jpg',
    );
    final catalog = CatalogTrack.youtube(
      videoId: 'video000001',
      title: 'Song',
      thumbnailUrl: 'https://img.test/playlist-catalog-cover.jpg',
    );

    final artwork = preferredCatalogPlaylistArtworkSource(
      catalog,
      localTrack: local,
    );
    expect(artwork?.source, 'https://img.test/local-catalog-cover.jpg');
    expect(artwork?.fallbackSource, endsWith('video-thumbnail.jpg'));
  });

  test(
    'individual catalog row upgrades artwork and keeps offline fallback',
    () {
      final local = LocalTrack(
        id: 'local-track',
        title: 'Song',
        artist: 'Artist',
        filePath: '/music/song.m4a',
        addedAt: DateTime.utc(2026),
        thumbnailPath: '/music/video-thumbnail.jpg',
      );
      final catalog = CatalogTrack.youtube(
        videoId: 'video000001',
        title: 'Song',
        thumbnailUrl:
            'https://lh3.googleusercontent.com/catalog-cover=w226-h226-l90-rj',
      );

      final artwork = preferredCatalogTrackArtworkSource(
        catalog,
        localTrack: local,
      );
      expect(
        artwork?.source,
        'https://lh3.googleusercontent.com/catalog-cover=w1280-h1280-l90-rj',
      );
      expect(artwork?.fallbackSource, '/music/video-thumbnail.jpg');
    },
  );

  test('playlist rotation is stable within a day and changes later', () {
    final candidates = List<PlaylistArtworkSource>.generate(
      11,
      (index) =>
          PlaylistArtworkSource(source: 'https://img.test/cover-$index.jpg'),
    );
    final morning = DateTime(2026, 8, 23, 8);
    final evening = DateTime(2026, 8, 23, 22);
    final tomorrow = DateTime(2026, 8, 24, 8);

    final first = rotatingPlaylistArtworkSources(
      playlistId: 'playlist-a',
      candidates: candidates,
      now: morning,
    );
    final sameDay = rotatingPlaylistArtworkSources(
      playlistId: 'playlist-a',
      candidates: candidates,
      now: evening,
    );
    final nextDay = rotatingPlaylistArtworkSources(
      playlistId: 'playlist-a',
      candidates: candidates,
      now: tomorrow,
    );

    expect(first, hasLength(playlistArtworkSourceLimit));
    expect(first.toSet(), hasLength(playlistArtworkSourceLimit));
    expect(sameDay, first);
    expect(nextDay, isNot(first));
  });
}
