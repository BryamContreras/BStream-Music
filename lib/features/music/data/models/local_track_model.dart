import '../../domain/entities/local_track.dart';

class LocalTrackModel extends LocalTrack {
  const LocalTrackModel({
    required super.id,
    required super.title,
    required super.artist,
    required super.filePath,
    required super.addedAt,
    super.sourceUrl,
    super.thumbnailUrl,
    super.thumbnailPath,
    super.duration,
    super.lastPlayedAt,
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
      thumbnailPath: map['thumbnail_path'] as String?,
      duration: _duration(map['duration_seconds']),
      lastPlayedAt: _date(map['last_played_at']),
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
      thumbnailPath: track.thumbnailPath,
      duration: track.duration,
      lastPlayedAt: track.lastPlayedAt,
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
      'thumbnail_path': thumbnailPath,
      'duration_seconds': duration?.inSeconds,
      'added_at': addedAt.toIso8601String(),
      'last_played_at': lastPlayedAt?.toIso8601String(),
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
}
