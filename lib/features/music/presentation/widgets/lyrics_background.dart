import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/player/player_service.dart';
import '../providers/music_providers.dart';
import '../providers/playback_artwork_provider.dart';
import 'lyrics_gradient_background.dart';
import 'playback_gradient_background.dart';

class LyricsBackground extends ConsumerWidget {
  const LyricsBackground({this.motionEnabled = true, super.key});

  static const _scrimOpacity = 82 / 255;
  final bool motionEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(
      settingsControllerProvider.select(
        (settings) =>
            settings.value?.lyricsBackgroundStyle ??
            defaultLyricsBackgroundStyle,
      ),
    );
    if (style == LyricsBackgroundStyle.blur) {
      return const PlayerPlaybackGradientBackground(
        key: ValueKey('lyrics-background-blur'),
        additionalScrimAlpha: _scrimOpacity,
      );
    }

    // This is the same cached sample as the BStream progress wave and menus.
    // The gradient needs no full-size cover decode or image blur of its own.
    final color = ref.watch(playbackArtworkColorProvider);
    final animated = style == LyricsBackgroundStyle.animatedGradient;
    final playing =
        animated &&
        motionEnabled &&
        ref.watch(
          playerControllerProvider.select(
            (player) => player.value?.status == PlayerStatus.playing,
          ),
        );
    return LyricsGradientBackground(
      key: ValueKey(
        animated
            ? 'lyrics-background-animated-gradient'
            : 'lyrics-background-gradient',
      ),
      color: color ?? const Color(0xFF242424),
      animated: animated,
      motionEnabled: playing,
      scrimOpacity: _scrimOpacity,
    );
  }
}
