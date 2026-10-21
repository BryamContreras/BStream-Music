import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/app_menu_bottom_sheet.dart';
import '../providers/artwork_progress_color_provider.dart';
import '../providers/music_providers.dart';
import '../providers/playback_visual_cache_provider.dart';
import 'playback_gradient_background.dart';
import 'playlist_artwork.dart';

final playbackMenuColorServiceProvider = Provider<ArtworkProgressColorService>((
  ref,
) {
  final service = ArtworkProgressColorService(preserveSourceSaturation: true);
  ref.onDispose(service.dispose);
  return service;
});

final _menuColorForSourceProvider = FutureProvider.autoDispose
    .family<Color, String>((ref, source) {
      final lease = ref.watch(playbackMenuColorServiceProvider).acquire(source);
      ref.onDispose(lease.release);
      return lease.future;
    });

/// Cover lookup is subscribed only while a menu is open. Position updates do
/// not rebuild it, and both menus share one small artwork-color cache.
final playbackMenuArtworkProvider =
    Provider.autoDispose<({String? source, String? fallback})>((ref) {
      final playback = ref.watch(
        playerControllerProvider.select(
          (player) => (
            trackId: player.value?.trackId,
            sourceUrl: player.value?.sourceUrl,
            thumbnail: player.value?.thumbnailUrl,
          ),
        ),
      );
      var source = playback.thumbnail;
      String? fallback;
      final tracks = ref.watch(libraryTracksProvider).value;
      if (tracks != null) {
        for (final track in tracks) {
          if (track.id == playback.trackId ||
              (playback.sourceUrl != null &&
                  track.sourceUrl == playback.sourceUrl)) {
            final artwork = preferredLocalTrackArtworkSource(track);
            source = artwork?.source ?? source;
            fallback = artwork?.fallbackSource;
            break;
          }
        }
      }
      return (source: source?.trim(), fallback: fallback);
    });

final playbackMenuArtworkColorProvider = Provider.autoDispose<Color?>((ref) {
  final source = ref.watch(playbackMenuArtworkProvider).source;
  if (source == null || source.isEmpty) return null;
  final color = ref.watch(_menuColorForSourceProvider(source)).asData?.value;
  return color == ArtworkProgressColor.fallback ? null : color;
});

Future<T?> showPlaybackMenuBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = false,
}) => showAppMenuBottomSheet<T>(
  context: context,
  builder: builder,
  useRootNavigator: useRootNavigator,
  surfaceBuilder: (_, child) => Consumer(
    builder: (context, ref, _) {
      final artwork = ref.watch(playbackMenuArtworkProvider);
      final cache = ref.watch(playbackVisualCacheProvider);
      final source = artwork.source;
      final cachedSource = source == null ? null : cache.coverPathFor(source);
      return AppMenuSheetSurface(
        artworkColor: ref.watch(playbackMenuArtworkColorProvider),
        background: PlaybackArtworkBackdrop(
          key: const ValueKey('playback-menu-artwork-background'),
          source: cachedSource ?? source,
          fallbackSource: artwork.fallback,
          cacheWidth: 256,
          additionalScrimAlpha: Theme.of(context).brightness == Brightness.dark
              ? .20
              : 0,
        ),
        child: child,
      );
    },
  ),
);
