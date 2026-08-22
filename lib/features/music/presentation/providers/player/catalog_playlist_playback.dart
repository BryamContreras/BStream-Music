import '../../../domain/entities/catalog_playlist.dart';
import '../../../domain/entities/catalog_track.dart';
import '../../../domain/entities/local_track.dart';
import '../../../domain/entities/track_info.dart';
import 'catalog_playback_item.dart';

List<CatalogPlaybackItem> catalogPlaylistPlaybackItems(
  CatalogPlaylist playlist,
  Iterable<LocalTrack> libraryTracks,
) {
  final localsById = <String, LocalTrack>{};
  final localsByVideoId = <String, LocalTrack>{};
  for (final track in libraryTracks) {
    localsById[track.id] = track;
    final videoId = track.sourceId?.trim();
    if (videoId != null && videoId.isNotEmpty) {
      localsByVideoId.putIfAbsent(videoId, () => track);
    }
  }

  final entries = playlist.entries.where((entry) => !entry.isDeleted).toList()
    ..sort((left, right) {
      final byPosition = left.position.compareTo(right.position);
      return byPosition != 0 ? byPosition : left.id.compareTo(right.id);
    });
  final result = <CatalogPlaybackItem>[];
  for (final entry in entries) {
    final catalog = entry.track;
    final rawVideoId = entry.videoId?.trim();
    final videoId = rawVideoId == null || rawVideoId.isEmpty
        ? catalog.youtubeVideoId
        : rawVideoId;
    final localId = entry.localTrackId?.trim();
    final local = localId != null && localId.isNotEmpty
        ? localsById[localId]
        : videoId == null
        ? null
        : localsByVideoId[videoId];
    final remote = videoId == null
        ? null
        : trackInfoFromCatalogTrack(catalog, videoId: videoId);
    if (local == null && remote == null) {
      continue;
    }
    result.add(
      CatalogPlaybackItem(
        entryId: entry.id,
        localTrack: local,
        remoteTrack: remote,
      ),
    );
  }
  return List<CatalogPlaybackItem>.unmodifiable(result);
}

TrackInfo trackInfoFromCatalogTrack(CatalogTrack track, {String? videoId}) {
  videoId ??= track.youtubeVideoId;
  if (videoId == null || videoId.isEmpty) {
    throw ArgumentError.value(
      track.key,
      'track',
      'A remote playback item requires a YouTube video id.',
    );
  }
  final sourceUrl = track.sourceUrl?.trim();
  final artists = track.artists
      .map((artist) => artist.trim())
      .where((artist) => artist.isNotEmpty)
      .toList(growable: false);
  return TrackInfo(
    id: videoId,
    title: track.title,
    artist: artists.isEmpty ? '' : artists.join(', '),
    artists: artists,
    artistBrowseIds: track.artistBrowseIds,
    album: track.album,
    duration: track.duration,
    thumbnailUrl: track.thumbnailUrl,
    catalogThumbnailUrl: track.thumbnailUrl,
    url: sourceUrl == null || sourceUrl.isEmpty
        ? 'https://www.youtube.com/watch?v=$videoId'
        : sourceUrl,
    metadataSource: TrackMetadataSource.youtubeMusic,
  );
}
