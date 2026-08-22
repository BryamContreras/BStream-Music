import '../../../domain/entities/local_track.dart';
import '../../../domain/entities/track_info.dart';

/// One occurrence from a catalog-backed playlist.
///
/// A synchronized entry may have both a downloaded representation and a
/// YouTube representation. Playback prefers [localTrack] and falls back to
/// [remoteTrack] without changing [entryId] or the logical queue position.
class CatalogPlaybackItem {
  const CatalogPlaybackItem({
    required this.entryId,
    this.localTrack,
    this.remoteTrack,
  }) : assert(localTrack != null || remoteTrack != null);

  final String entryId;
  final LocalTrack? localTrack;
  final TrackInfo? remoteTrack;
}
