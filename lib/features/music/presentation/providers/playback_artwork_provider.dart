import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/local_track.dart';
import '../widgets/playlist_artwork.dart';
import 'artwork_progress_color_provider.dart';
import 'local_track_index_provider.dart';
import 'music_providers.dart';

/// Resolves the saved track once for the player, mini player and playback menus.
/// ID takes priority over URL when multiple saved tracks share the same source.
final playbackLocalTrackProvider = Provider.autoDispose<LocalTrack?>((ref) {
  final identity = ref.watch(
    playerControllerProvider.select(
      (player) => (
        trackId: player.value?.trackId?.trim(),
        sourceUrl: player.value?.sourceUrl?.trim(),
      ),
    ),
  );
  final tracks = ref.watch(localTrackIndexProvider);
  final id = identity.trackId;
  if (id != null && id.isNotEmpty) {
    final track = tracks.firstById(id);
    if (track != null) return track;
  }
  final source = identity.sourceUrl;
  if (source == null || source.isEmpty) return null;
  return tracks.firstBySourceUrl(source);
});

/// All playback surfaces use the same cover and offline fallback, while each
/// surface keeps its own image size, blur and transition settings.
final playbackArtworkProvider =
    Provider.autoDispose<({String? source, String? fallback})>((ref) {
      final track = ref.watch(playbackLocalTrackProvider);
      final thumbnail = ref.watch(
        playerControllerProvider.select((player) => player.value?.thumbnailUrl),
      );
      final artwork = track == null
          ? null
          : preferredLocalTrackArtworkSource(track);
      return (
        source: (artwork?.source ?? thumbnail)?.trim(),
        fallback: artwork?.fallbackSource,
      );
    });

/// Playback waves, menus and lyrics share one palette request/cache for the cover.
/// Position updates do not invalidate this provider or resample the image.
final playbackArtworkColorProvider = Provider.autoDispose<Color?>((ref) {
  final source = ref.watch(playbackArtworkProvider).source;
  if (source == null || source.isEmpty) return null;
  final color = ref.watch(artworkSurfaceColorProvider(source)).asData?.value;
  return color == ArtworkProgressColor.fallback ? null : color;
});
