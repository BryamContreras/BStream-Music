import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/app_menu_bottom_sheet.dart';
import '../providers/playback_artwork_provider.dart';
import '../providers/playback_visual_cache_provider.dart';
import 'playback_gradient_background.dart';

final playbackMenuArtworkColorProvider = playbackArtworkColorProvider;

/// The artwork-derived surface shared by playback menus and the queue header.
class PlaybackMenuArtworkBackground extends ConsumerWidget {
  const PlaybackMenuArtworkBackground({this.backdropKey, super.key});

  final Key? backdropKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artwork = ref.watch(playbackArtworkProvider);
    final cache = ref.watch(playbackVisualCacheProvider);
    final source = artwork.source;
    final cachedSource = source == null ? null : cache.coverPathFor(source);
    return PlaybackArtworkBackdrop(
      key: backdropKey,
      source: cachedSource ?? source,
      fallbackSource: artwork.fallback,
      cacheWidth: 256,
      cacheSmallBlur: Theme.of(context).platform == TargetPlatform.android,
      additionalScrimAlpha: Theme.of(context).brightness == Brightness.dark
          ? .20
          : 0,
    );
  }
}

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
      return AppMenuSheetSurface(
        artworkColor: ref.watch(playbackMenuArtworkColorProvider),
        background: const PlaybackMenuArtworkBackground(
          backdropKey: ValueKey('playback-menu-artwork-background'),
        ),
        child: child,
      );
    },
  ),
);
