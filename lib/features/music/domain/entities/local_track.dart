import 'track_info.dart';

class LocalTrack {
  const LocalTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.filePath,
    required this.addedAt,
    this.sourceUrl,
    this.thumbnailUrl,
    this.catalogThumbnailUrl,
    this.thumbnailPath,
    this.duration,
    this.album,
    this.artists = const [],
    this.artistBrowseIds = const [],
    this.metadataSource = TrackMetadataSource.youtube,
    this.sourceId,
    this.lastPlayedAt,
    this.lastPlayedPlaylistId,
    this.isExternal = false,
  });

  final String id;
  final String title;
  final String artist;
  final String filePath;
  final DateTime addedAt;
  final String? sourceUrl;
  final String? thumbnailUrl;
  final String? catalogThumbnailUrl;
  final String? thumbnailPath;
  final Duration? duration;
  final String? album;
  final List<String> artists;
  final List<String?> artistBrowseIds;
  final TrackMetadataSource metadataSource;
  final String? sourceId;
  final DateTime? lastPlayedAt;
  final String? lastPlayedPlaylistId;

  /// True for a transient track opened from Android outside BStream's library.
  final bool isExternal;

  LocalTrack copyWith({
    String? id,
    String? title,
    String? artist,
    String? filePath,
    DateTime? addedAt,
    String? sourceUrl,
    String? thumbnailUrl,
    String? catalogThumbnailUrl,
    String? thumbnailPath,
    Duration? duration,
    String? album,
    List<String>? artists,
    List<String?>? artistBrowseIds,
    TrackMetadataSource? metadataSource,
    String? sourceId,
    DateTime? lastPlayedAt,
    String? lastPlayedPlaylistId,
    bool? isExternal,
  }) {
    return LocalTrack(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      filePath: filePath ?? this.filePath,
      addedAt: addedAt ?? this.addedAt,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      catalogThumbnailUrl: catalogThumbnailUrl ?? this.catalogThumbnailUrl,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      duration: duration ?? this.duration,
      album: album ?? this.album,
      artists: artists ?? this.artists,
      artistBrowseIds: artistBrowseIds ?? this.artistBrowseIds,
      metadataSource: metadataSource ?? this.metadataSource,
      sourceId: sourceId ?? this.sourceId,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      lastPlayedPlaylistId: lastPlayedPlaylistId ?? this.lastPlayedPlaylistId,
      isExternal: isExternal ?? this.isExternal,
    );
  }
}
