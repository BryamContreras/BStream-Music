part of '../music_providers.dart';

/// Maps a verified logical queue item to recommendation-history metadata.
///
/// Snapshot matching is kept here so history never attributes a late backend
/// event to the newly selected item. Persistence and qualification timing stay
/// in [QualifiedPlaybackHistoryTracker].
abstract final class PlaybackHistoryTrackFactory {
  static PlaybackHistoryTrack? remote({
    required PlayerSnapshot snapshot,
    required TrackInfo track,
    required String? expectedQueueEntryId,
  }) {
    final snapshotQueueEntryId = snapshot.queueEntryId?.trim();
    if (snapshotQueueEntryId != null &&
        snapshotQueueEntryId.isNotEmpty &&
        snapshotQueueEntryId != expectedQueueEntryId) {
      return null;
    }
    final remoteId = track.id.trim();
    final trackId = remoteId.isNotEmpty ? remoteId : track.url.trim();
    if (trackId.isEmpty) {
      return null;
    }
    final snapshotTrackId = snapshot.trackId?.trim();
    if ((snapshotQueueEntryId == null || snapshotQueueEntryId.isEmpty) &&
        snapshotTrackId != null &&
        snapshotTrackId.isNotEmpty &&
        snapshotTrackId != trackId &&
        snapshot.sourceUrl?.trim() != track.url.trim()) {
      return null;
    }
    return PlaybackHistoryTrack(
      logicalKey: expectedQueueEntryId ?? 'remote:$trackId',
      trackId: trackId,
      videoId: PlaybackIdentity.canonicalYoutubeVideoId(
        id: remoteId,
        url: track.url,
      ),
      title: PlaybackIdentity.nonEmpty(
        track.title,
        fallback: snapshot.title ?? trackId,
      ),
      artists: PlaybackIdentity.canonicalArtists(track.artists, track.artist),
      artistBrowseIds: List<String?>.unmodifiable(track.artistBrowseIds),
      album: PlaybackIdentity.optionalText(track.album ?? snapshot.album),
      thumbnailUrl:
          PlaybackIdentity.optionalText(track.catalogThumbnailUrl) ??
          PlaybackIdentity.optionalText(track.thumbnailUrl) ??
          PlaybackIdentity.optionalText(snapshot.thumbnailUrl),
      duration: track.duration ?? snapshot.duration,
      source: PlaybackEventSource.streaming,
    );
  }

  static PlaybackHistoryTrack? local({
    required PlayerSnapshot snapshot,
    required LocalTrack track,
    required int playRequestId,
    required int queueIndex,
    required String? queueSourceId,
    required String? playlistId,
    required bool isFavorite,
  }) {
    if (track.isExternal || snapshot.isRemote) {
      return null;
    }
    final snapshotTrackId = snapshot.trackId?.trim();
    if (snapshotTrackId == null ||
        snapshotTrackId.isEmpty ||
        snapshotTrackId != track.id) {
      return null;
    }
    final sourceId = PlaybackIdentity.optionalText(track.sourceId);
    final sourceUrl = PlaybackIdentity.optionalText(track.sourceUrl);
    return PlaybackHistoryTrack(
      logicalKey:
          'local:$playRequestId:${queueSourceId ?? ''}:$queueIndex:${track.id}',
      trackId: track.id,
      videoId: PlaybackIdentity.canonicalYoutubeVideoId(
        id: sourceId,
        url: sourceUrl,
      ),
      title: PlaybackIdentity.nonEmpty(
        track.title,
        fallback: snapshot.title ?? track.id,
      ),
      artists: PlaybackIdentity.canonicalArtists(track.artists, track.artist),
      artistBrowseIds: List<String?>.unmodifiable(track.artistBrowseIds),
      album: PlaybackIdentity.optionalText(track.album ?? snapshot.album),
      thumbnailUrl:
          PlaybackIdentity.optionalText(track.catalogThumbnailUrl) ??
          PlaybackIdentity.optionalText(track.thumbnailUrl) ??
          PlaybackIdentity.optionalText(track.thumbnailPath) ??
          PlaybackIdentity.optionalText(snapshot.thumbnailUrl),
      duration: track.duration ?? snapshot.duration,
      source: sourceId != null || sourceUrl != null
          ? PlaybackEventSource.downloaded
          : PlaybackEventSource.local,
      localTrackId: track.id,
      playlistId: playlistId,
      isFavorite: isFavorite,
    );
  }
}
