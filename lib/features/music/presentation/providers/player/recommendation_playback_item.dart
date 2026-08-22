import '../../../domain/entities/local_track.dart';
import '../../../domain/entities/track_info.dart';

/// One logical recommendation that may already exist in the local library.
///
/// Keeping both representations lets Home build a single navigable queue:
/// downloaded entries play from disk, while the remaining recommendations
/// continue through their canonical YouTube source.
class RecommendationPlaybackItem {
  const RecommendationPlaybackItem({
    required this.track,
    this.localTrack,
    this.logicalEntryId,
  });

  final TrackInfo track;
  final LocalTrack? localTrack;

  /// Stable identity for an occurrence in a synchronized playlist.
  ///
  /// Two occurrences may point at the same YouTube video while still being
  /// independently movable/removable. Ordinary recommendation shelves leave
  /// this null and continue to use the catalog identity.
  final String? logicalEntryId;
}

/// Loads another page for the active personalized recommendation queue.
///
/// The callback owns the remote continuation token and returns the complete
/// queue accumulated so far. PlayerController decides when to request the
/// next page and rejects late results after the user starts another queue.
typedef RecommendationQueueExtender =
    Future<List<RecommendationPlaybackItem>> Function();
