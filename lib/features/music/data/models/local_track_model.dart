import 'dart:convert';

import '../../domain/entities/local_track.dart';
import '../../domain/entities/track_info.dart';

class LocalTrackModel extends LocalTrack {
  const LocalTrackModel({
    required super.id,
    required super.title,
    required super.artist,
    required super.filePath,
    required super.addedAt,
    super.sourceUrl,
    super.thumbnailUrl,
    super.catalogThumbnailUrl,
    super.thumbnailPath,
    super.duration,
    super.album,
    super.artists,
    super.metadataSource,
    super.sourceId,
    super.lastPlayedAt,
    super.lastPlayedPlaylistId,
  });

  factory LocalTrackModel.fromMap(Map<String, Object?> map) {
    return LocalTrackModel(
      id: map['id']! as String,
      title: map['title']! as String,
      artist: map['artist']! as String,
      filePath: map['file_path']! as String,
      addedAt: DateTime.parse(map['added_at']! as String),
      sourceUrl: map['source_url'] as String?,
      thumbnailUrl: map['thumbnail_url'] as String?,
      catalogThumbnailUrl: map['catalog_thumbnail_url'] as String?,
      thumbnailPath: map['thumbnail_path'] as String?,
      duration: _duration(map['duration_seconds']),
      album: map['album'] as String?,
      artists: _artists(map['artists_json'], map['artist'] as String),
      metadataSource: _metadataSource(map['metadata_source']),
      sourceId: map['source_id'] as String?,
      lastPlayedAt: _date(map['last_played_at']),
      lastPlayedPlaylistId: map['last_played_playlist_id'] as String?,
    );
  }

  factory LocalTrackModel.fromEntity(LocalTrack track) {
    return LocalTrackModel(
      id: track.id,
      title: track.title,
      artist: track.artist,
      filePath: track.filePath,
      addedAt: track.addedAt,
      sourceUrl: track.sourceUrl,
      thumbnailUrl: track.thumbnailUrl,
      catalogThumbnailUrl: track.catalogThumbnailUrl,
      thumbnailPath: track.thumbnailPath,
      duration: track.duration,
      album: track.album,
      artists: track.artists,
      metadataSource: track.metadataSource,
      sourceId: track.sourceId,
      lastPlayedAt: track.lastPlayedAt,
      lastPlayedPlaylistId: track.lastPlayedPlaylistId,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'file_path': filePath,
      'source_url': sourceUrl,
      'thumbnail_url': thumbnailUrl,
      'catalog_thumbnail_url': catalogThumbnailUrl,
      'thumbnail_path': thumbnailPath,
      'duration_seconds': duration?.inSeconds,
      'album': album,
      'artists_json': jsonEncode(artists),
      'metadata_source': metadataSource.name,
      'source_id': sourceId,
      'added_at': addedAt.toIso8601String(),
      'last_played_at': lastPlayedAt?.toIso8601String(),
      'last_played_playlist_id': lastPlayedPlaylistId,
    };
  }

  static Duration? _duration(Object? value) {
    if (value == null) {
      return null;
    }
    final seconds = value is num
        ? value.toInt()
        : int.tryParse(value.toString());
    return seconds == null ? null : Duration(seconds: seconds);
  }

  static DateTime? _date(Object? value) {
    if (value == null) {
      return null;
    }
    return DateTime.tryParse(value.toString());
  }

  static List<String> _artists(Object? value, String fallbackArtist) {
    try {
      final decoded = value is String ? jsonDecode(value) : value;
      if (decoded is List) {
        final artists = <String>[];
        for (final entry in decoded) {
          final artist = entry?.toString().trim();
          if (artist != null &&
              artist.isNotEmpty &&
              !artists.contains(artist)) {
            artists.add(artist);
          }
        }
        if (artists.isNotEmpty) {
          return List.unmodifiable(artists);
        }
      }
    } catch (_) {
      // Older or externally edited backups may contain malformed JSON. The
      // scalar artist below keeps those rows useful instead of rejecting the
      // whole library.
    }

    final fallback = fallbackArtist.trim();
    return fallback.isEmpty || _isPlaceholderArtist(fallback)
        ? const []
        : [fallback];
  }

  static TrackMetadataSource _metadataSource(Object? value) {
    final name = value?.toString().trim();
    return TrackMetadataSource.values.firstWhere(
      (source) => source.name == name,
      orElse: () => TrackMetadataSource.youtube,
    );
  }

  static bool _isPlaceholderArtist(String value) {
    return const {
      'desconocido',
      'unknown',
      'unknown artist',
      'sin artista',
    }.contains(value.toLowerCase());
  }
}
