enum CatalogProvider { youtube, local, legacy }

/// Stable catalog identity shared by downloaded and streamed representations.
///
/// A YouTube Music entry normally uses `youtube:<videoId>`. A track that has
/// never been matched with YouTube uses `local:<localTrackId>` instead. The
/// local file is deliberately not part of this entity: downloads can disappear
/// while playlist membership remains intact.
class CatalogTrack {
  const CatalogTrack({
    required this.key,
    required this.provider,
    required this.providerId,
    required this.title,
    this.artists = const <String>[],
    this.artistBrowseIds = const <String?>[],
    this.album,
    this.duration,
    this.thumbnailUrl,
    this.sourceUrl,
  });

  factory CatalogTrack.youtube({
    required String videoId,
    required String title,
    List<String> artists = const <String>[],
    List<String?> artistBrowseIds = const <String?>[],
    String? album,
    Duration? duration,
    String? thumbnailUrl,
    String? sourceUrl,
  }) {
    final normalizedId = videoId.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(videoId, 'videoId', 'Must not be empty.');
    }
    return CatalogTrack(
      key: 'youtube:$normalizedId',
      provider: CatalogProvider.youtube,
      providerId: normalizedId,
      title: title,
      artists: artists,
      artistBrowseIds: artistBrowseIds,
      album: album,
      duration: duration,
      thumbnailUrl: thumbnailUrl,
      sourceUrl: sourceUrl,
    );
  }

  factory CatalogTrack.local({
    required String localTrackId,
    required String title,
    List<String> artists = const <String>[],
    List<String?> artistBrowseIds = const <String?>[],
    String? album,
    Duration? duration,
    String? thumbnailUrl,
    String? sourceUrl,
  }) {
    final normalizedId = localTrackId.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(
        localTrackId,
        'localTrackId',
        'Must not be empty.',
      );
    }
    return CatalogTrack(
      key: 'local:$normalizedId',
      provider: CatalogProvider.local,
      providerId: normalizedId,
      title: title,
      artists: artists,
      artistBrowseIds: artistBrowseIds,
      album: album,
      duration: duration,
      thumbnailUrl: thumbnailUrl,
      sourceUrl: sourceUrl,
    );
  }

  final String key;
  final CatalogProvider provider;
  final String providerId;
  final String title;
  final List<String> artists;
  final List<String?> artistBrowseIds;
  final String? album;
  final Duration? duration;
  final String? thumbnailUrl;
  final String? sourceUrl;

  String? get youtubeVideoId =>
      provider == CatalogProvider.youtube ? providerId : null;
}
