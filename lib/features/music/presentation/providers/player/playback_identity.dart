import '../../../../../core/utils/image_source.dart';
import '../../../../../services/player/player_service.dart';
import '../../../domain/entities/track_info.dart';

/// Canonical identity and snapshot matching rules shared by playback flows.
///
/// These helpers are intentionally side-effect free. Resolver, cache and
/// queue components can therefore agree on logical identity without each
/// encoding subtly different URL/ID precedence rules.
abstract final class PlaybackIdentity {
  static const String remoteCacheTrackIdPrefix = 'remote-cache:';

  static String remoteTrack(TrackInfo track) {
    final source = track.url.trim();
    return source.isNotEmpty ? source : track.id;
  }

  static bool sameRemoteTrack(TrackInfo first, TrackInfo second) {
    final firstId = first.id.trim();
    final secondId = second.id.trim();
    if (firstId.isNotEmpty && secondId.isNotEmpty) {
      return firstId == secondId;
    }
    return first.url.trim() == second.url.trim();
  }

  static String remoteQueueEntry(int generation, int index) {
    return 'remote:$generation:$index';
  }

  static bool snapshotBelongsToTrack(PlayerSnapshot snapshot, TrackInfo track) {
    if (snapshot.sourceUrl == track.url) {
      return true;
    }
    final trackId = track.id.isEmpty ? track.url : track.id;
    final snapshotTrackId = snapshot.trackId?.trim();
    return snapshotTrackId != null &&
        snapshotTrackId.isNotEmpty &&
        snapshotTrackId == trackId;
  }

  static bool snapshotMatchesPending(
    PlayerSnapshot snapshot,
    PlayerSnapshot pending,
  ) {
    final pendingQueueEntryId = pending.queueEntryId;
    if (pendingQueueEntryId != null && pendingQueueEntryId.isNotEmpty) {
      final snapshotQueueEntryId = snapshot.queueEntryId;
      if (snapshotQueueEntryId != null && snapshotQueueEntryId.isNotEmpty) {
        return snapshotQueueEntryId == pendingQueueEntryId;
      }
    }
    final pendingTrackId = pending.trackId;
    if (pendingTrackId != null && pendingTrackId.isNotEmpty) {
      final snapshotTrackId = snapshot.trackId?.trim();
      if (snapshotTrackId != null && snapshotTrackId.isNotEmpty) {
        return snapshotTrackId == pendingTrackId;
      }
    }
    final pendingSourceUrl = pending.sourceUrl;
    return pendingSourceUrl != null &&
        pendingSourceUrl.isNotEmpty &&
        snapshot.sourceUrl == pendingSourceUrl;
  }

  static bool cachedRemoteSnapshot(PlayerSnapshot snapshot, TrackInfo remote) {
    final trackId = snapshot.trackId;
    return !snapshot.isRemote &&
        trackId != null &&
        trackId.startsWith(remoteCacheTrackIdPrefix) &&
        snapshot.sourceUrl == remote.url;
  }

  static bool resolvedSourceWasReplaced(
    TrackInfo? current,
    TrackInfo attempted,
  ) {
    if (current == null || remoteTrack(current) != remoteTrack(attempted)) {
      return false;
    }
    final attemptedSource = attempted.streamSource?.trim();
    final currentSource = current.streamSource?.trim();
    if (attemptedSource != null &&
        attemptedSource.isNotEmpty &&
        currentSource != null &&
        currentSource.isNotEmpty &&
        attemptedSource != currentSource) {
      return true;
    }
    final attemptedUrl = attempted.streamUrl?.trim();
    final currentUrl = current.streamUrl?.trim();
    return attemptedUrl != null &&
        attemptedUrl.isNotEmpty &&
        currentUrl != null &&
        currentUrl.isNotEmpty &&
        attemptedUrl != currentUrl;
  }

  static String? stableRemoteThumbnail(TrackInfo track, [String? fallback]) {
    final fromTrack = canonicalYouTubeThumbnailSource(track.thumbnailUrl);
    if (fromTrack != null) {
      return fromTrack;
    }
    final fromId = youtubeThumbnailSourceForVideoId(track.id);
    if (fromId != null) {
      return fromId;
    }
    return canonicalYouTubeThumbnailSource(fallback) ?? fallback;
  }

  static List<String> canonicalArtists(List<String> artists, String fallback) {
    final normalized = <String>[];
    final seen = <String>{};
    for (final artist in artists) {
      final value = artist.trim();
      if (value.isNotEmpty && seen.add(value)) {
        normalized.add(value);
      }
    }
    final fallbackValue = fallback.trim();
    if (normalized.isEmpty && fallbackValue.isNotEmpty) {
      normalized.add(fallbackValue);
    }
    return List<String>.unmodifiable(normalized);
  }

  static String nonEmpty(String value, {required String fallback}) {
    final normalized = value.trim();
    return normalized.isEmpty ? fallback.trim() : normalized;
  }

  static String? optionalText(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? canonicalYoutubeVideoId({String? id, String? url}) {
    final normalizedId = id?.trim();
    if (normalizedId != null && _youtubeId.hasMatch(normalizedId)) {
      return normalizedId;
    }
    final uri = Uri.tryParse(url?.trim() ?? '');
    if (uri == null) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be') {
      final candidate = uri.pathSegments.isEmpty
          ? null
          : uri.pathSegments.first;
      return candidate != null && _youtubeId.hasMatch(candidate)
          ? candidate
          : null;
    }
    if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
      final queryCandidate = uri.queryParameters['v'];
      if (queryCandidate != null && _youtubeId.hasMatch(queryCandidate)) {
        return queryCandidate;
      }
      if (uri.pathSegments.length >= 2 &&
          (uri.pathSegments.first == 'shorts' ||
              uri.pathSegments.first == 'embed')) {
        final pathCandidate = uri.pathSegments[1];
        if (_youtubeId.hasMatch(pathCandidate)) {
          return pathCandidate;
        }
      }
    }
    return null;
  }

  static final RegExp _youtubeId = RegExp(r'^[A-Za-z0-9_-]{11}$');
}
