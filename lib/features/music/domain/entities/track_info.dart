class TrackInfo {
  const TrackInfo({
    required this.id,
    required this.title,
    required this.artist,
    required this.url,
    this.thumbnailUrl,
    this.duration,
    this.streamUrl,
    this.extractor,
    this.album,
    this.viewCount,
    this.httpHeaders,
  });

  final String id;
  final String title;
  final String artist;
  final String url;
  final String? thumbnailUrl;
  final Duration? duration;
  final String? streamUrl;
  final String? extractor;
  final String? album;
  final int? viewCount;
  final Map<String, String>? httpHeaders;

  TrackInfo copyWith({
    String? id,
    String? title,
    String? artist,
    String? url,
    String? thumbnailUrl,
    Duration? duration,
    String? streamUrl,
    String? extractor,
    String? album,
    int? viewCount,
    Map<String, String>? httpHeaders,
  }) {
    return TrackInfo(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      url: url ?? this.url,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      duration: duration ?? this.duration,
      streamUrl: streamUrl ?? this.streamUrl,
      extractor: extractor ?? this.extractor,
      album: album ?? this.album,
      viewCount: viewCount ?? this.viewCount,
      httpHeaders: httpHeaders ?? this.httpHeaders,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is TrackInfo &&
            runtimeType == other.runtimeType &&
            id == other.id &&
            title == other.title &&
            artist == other.artist &&
            url == other.url;
  }

  @override
  int get hashCode => Object.hash(id, title, artist, url);
}
