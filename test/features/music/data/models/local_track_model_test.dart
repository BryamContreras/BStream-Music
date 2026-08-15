import 'dart:convert';

import 'package:bstream_music/features/music/data/models/local_track_model.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalTrackModel metadata persistence', () {
    test('round-trips complete InnerTube metadata', () {
      final addedAt = DateTime.utc(2026, 8, 13, 12, 30);
      final playedAt = DateTime.utc(2026, 8, 13, 13, 45);
      final original = LocalTrackModel(
        id: 'local-track-1',
        title: 'Die With A Smile',
        artist: 'Lady Gaga, Bruno Mars',
        artists: const ['Lady Gaga', 'Bruno Mars'],
        album: 'Die With A Smile',
        filePath: r'C:\Music\die-with-a-smile.m4a',
        addedAt: addedAt,
        sourceUrl: 'https://www.youtube.com/watch?v=kPa7bsKwL-c',
        sourceId: 'kPa7bsKwL-c',
        thumbnailUrl: 'https://i.ytimg.com/vi/kPa7bsKwL-c/hq720.jpg',
        catalogThumbnailUrl:
            'https://lh3.googleusercontent.com/innertube-artwork',
        thumbnailPath: r'C:\Music\artwork\die-with-a-smile.jpg',
        duration: const Duration(minutes: 4, seconds: 12),
        metadataSource: TrackMetadataSource.youtubeMusic,
        lastPlayedAt: playedAt,
        lastPlayedPlaylistId: 'playlist-1',
      );

      final map = original.toMap();
      final restored = LocalTrackModel.fromMap(map);

      expect(map['artists_json'], jsonEncode(original.artists));
      expect(map['metadata_source'], TrackMetadataSource.youtubeMusic.name);
      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.artist, original.artist);
      expect(restored.artists, original.artists);
      expect(restored.album, original.album);
      expect(restored.filePath, original.filePath);
      expect(restored.addedAt, addedAt);
      expect(restored.sourceUrl, original.sourceUrl);
      expect(restored.sourceId, original.sourceId);
      expect(restored.thumbnailUrl, original.thumbnailUrl);
      expect(restored.catalogThumbnailUrl, original.catalogThumbnailUrl);
      expect(restored.thumbnailPath, original.thumbnailPath);
      expect(restored.duration, original.duration);
      expect(restored.metadataSource, TrackMetadataSource.youtubeMusic);
      expect(restored.lastPlayedAt, playedAt);
      expect(restored.lastPlayedPlaylistId, original.lastPlayedPlaylistId);
    });

    test('reads a legacy row without metadata columns', () {
      final track = LocalTrackModel.fromMap({
        'id': 'legacy-track',
        'title': 'Legacy song',
        'artist': 'Legacy artist',
        'file_path': '/music/legacy.m4a',
        'source_url': 'https://www.youtube.com/watch?v=legacy12345',
        'thumbnail_url': 'https://i.ytimg.com/vi/legacy12345/hq720.jpg',
        'thumbnail_path': null,
        'duration_seconds': 180,
        'added_at': DateTime.utc(2025).toIso8601String(),
        'last_played_at': null,
        'last_played_playlist_id': null,
      });

      expect(track.album, isNull);
      expect(track.artists, const ['Legacy artist']);
      expect(track.metadataSource, TrackMetadataSource.youtube);
      expect(track.sourceId, isNull);
      expect(track.catalogThumbnailUrl, isNull);
    });

    test('ignores malformed artists JSON and unknown metadata sources', () {
      final track = LocalTrackModel.fromMap({
        'id': 'damaged-metadata',
        'title': 'Still playable',
        'artist': 'Fallback artist',
        'artists_json': '{not valid json',
        'album': 'Fallback album',
        'metadata_source': 'unknown-catalog',
        'source_id': 'video-id',
        'catalog_thumbnail_url': 'https://example.com/catalog.jpg',
        'file_path': '/music/still-playable.m4a',
        'added_at': DateTime.utc(2026).toIso8601String(),
      });

      expect(track.artists, const ['Fallback artist']);
      expect(track.metadataSource, TrackMetadataSource.youtube);
      expect(track.album, 'Fallback album');
      expect(track.sourceId, 'video-id');
      expect(track.catalogThumbnailUrl, 'https://example.com/catalog.jpg');
    });
  });
}
