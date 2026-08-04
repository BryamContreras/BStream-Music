class LyricsLookup {
  const LyricsLookup({
    required this.title,
    required this.artist,
    this.duration,
    this.album,
    this.sourceId,
  });

  final String title;
  final String artist;
  final Duration? duration;
  final String? album;
  final String? sourceId;

  bool get isValid => title.trim().isNotEmpty;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LyricsLookup &&
            runtimeType == other.runtimeType &&
            title == other.title &&
            artist == other.artist &&
            duration == other.duration &&
            album == other.album &&
            sourceId == other.sourceId;
  }

  @override
  int get hashCode => Object.hash(title, artist, duration, album, sourceId);
}
