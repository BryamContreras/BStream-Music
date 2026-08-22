import 'dart:io';

import '../../../../../services/player/player_service.dart';
import '../../../domain/entities/local_track.dart';
import '../../../domain/entities/track_info.dart';
import 'playback_identity.dart';

typedef CachedRemoteFileLookup = Future<File?> Function(TrackInfo track);

/// Creates backend sources and local cache projections from one TrackInfo.
///
/// All cache-file validation lives here so initial playback, recovery and
/// prefetch agree on when a partial/evicted file is usable.
abstract final class RemotePlaybackSourceFactory {
  static Future<RemotePlaybackSource?> cachedSource({
    required TrackInfo track,
    required CachedRemoteFileLookup cachedFile,
    required String queueEntryId,
    required bool isOnlyLogicalQueueItem,
  }) async {
    final file = await cachedFile(track);
    if (!await _usable(file)) {
      return null;
    }
    return RemotePlaybackSource(
      track: track,
      uri: file!.uri,
      queueEntryId: queueEntryId,
      isOnlyLogicalQueueItem: isOnlyLogicalQueueItem,
    );
  }

  static RemotePlaybackSource network({
    required TrackInfo track,
    required String queueEntryId,
    required bool isOnlyLogicalQueueItem,
  }) {
    return RemotePlaybackSource(
      track: track,
      uri: Uri.parse(track.streamUrl!),
      queueEntryId: queueEntryId,
      httpHeaders: track.httpHeaders,
      isOnlyLogicalQueueItem: isOnlyLogicalQueueItem,
    );
  }

  static Future<LocalTrack?> cachedLocal({
    required TrackInfo track,
    required CachedRemoteFileLookup cachedFile,
  }) async {
    final file = await cachedFile(track);
    if (!await _usable(file)) {
      return null;
    }
    try {
      final identity = track.id.isEmpty ? track.url : track.id;
      return LocalTrack(
        id: '${PlaybackIdentity.remoteCacheTrackIdPrefix}${identity.hashCode}',
        title: track.title,
        artist: track.artist,
        filePath: file!.path,
        addedAt: await file.lastModified(),
        sourceUrl: track.url,
        thumbnailUrl: track.thumbnailUrl,
        catalogThumbnailUrl: track.catalogThumbnailUrl,
        duration: track.duration,
        album: track.album,
        artists: track.artists,
        artistBrowseIds: track.artistBrowseIds,
        metadataSource: track.metadataSource,
        sourceId: track.id.trim().isEmpty ? null : track.id,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _usable(File? file) async {
    if (file == null) {
      return false;
    }
    try {
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }
}
