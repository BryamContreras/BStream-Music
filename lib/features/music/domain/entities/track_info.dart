enum TrackMetadataSource { youtube, youtubeMusic }

class TrackInfo {
  const TrackInfo({
    required this.id,
    required this.title,
    required this.artist,
    required this.url,
    this.thumbnailUrl,
    this.catalogThumbnailUrl,
    this.duration,
    this.streamUrl,
    this.streamExtension,
    this.streamMimeType,
    this.streamSource,
    this.streamFormatId,
    this.streamCodec,
    this.extractor,
    this.album,
    this.viewCount,
    this.httpHeaders,
    this.artists = const [],
    this.metadataSource = TrackMetadataSource.youtube,
  });

  final String id;
  final String title;
  final String artist;
  final String url;
  final String? thumbnailUrl;
  final String? catalogThumbnailUrl;
  final Duration? duration;
  final String? streamUrl;
  final String? streamExtension;
  final String? streamMimeType;

  /// Resolver that produced [streamUrl]. Values currently match
  /// `AudioStreamSource.name` without coupling this domain entity to a service.
  final String? streamSource;
  final String? streamFormatId;
  final String? streamCodec;
  final String? extractor;
  final String? album;
  final int? viewCount;
  final Map<String, String>? httpHeaders;
  final List<String> artists;
  final TrackMetadataSource metadataSource;

  TrackInfo copyWith({
    String? id,
    String? title,
    String? artist,
    String? url,
    String? thumbnailUrl,
    String? catalogThumbnailUrl,
    Duration? duration,
    String? streamUrl,
    String? streamExtension,
    String? streamMimeType,
    String? streamSource,
    String? streamFormatId,
    String? streamCodec,
    String? extractor,
    String? album,
    int? viewCount,
    Map<String, String>? httpHeaders,
    List<String>? artists,
    TrackMetadataSource? metadataSource,
  }) {
    return TrackInfo(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      url: url ?? this.url,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      catalogThumbnailUrl: catalogThumbnailUrl ?? this.catalogThumbnailUrl,
      duration: duration ?? this.duration,
      streamUrl: streamUrl ?? this.streamUrl,
      streamExtension: streamExtension ?? this.streamExtension,
      streamMimeType: streamMimeType ?? this.streamMimeType,
      streamSource: streamSource ?? this.streamSource,
      streamFormatId: streamFormatId ?? this.streamFormatId,
      streamCodec: streamCodec ?? this.streamCodec,
      extractor: extractor ?? this.extractor,
      album: album ?? this.album,
      viewCount: viewCount ?? this.viewCount,
      httpHeaders: httpHeaders ?? this.httpHeaders,
      artists: artists ?? this.artists,
      metadataSource: metadataSource ?? this.metadataSource,
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
