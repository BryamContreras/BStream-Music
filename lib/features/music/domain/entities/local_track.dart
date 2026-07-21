class LocalTrack {
  const LocalTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.filePath,
    required this.addedAt,
    this.sourceUrl,
    this.thumbnailUrl,
    this.thumbnailPath,
    this.duration,
    this.lastPlayedAt,
  });

  final String id;
  final String title;
  final String artist;
  final String filePath;
  final DateTime addedAt;
  final String? sourceUrl;
  final String? thumbnailUrl;
  final String? thumbnailPath;
  final Duration? duration;
  final DateTime? lastPlayedAt;

  LocalTrack copyWith({
    String? id,
    String? title,
    String? artist,
    String? filePath,
    DateTime? addedAt,
    String? sourceUrl,
    String? thumbnailUrl,
    String? thumbnailPath,
    Duration? duration,
    DateTime? lastPlayedAt,
  }) {
    return LocalTrack(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      filePath: filePath ?? this.filePath,
      addedAt: addedAt ?? this.addedAt,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      duration: duration ?? this.duration,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
    );
  }
}
