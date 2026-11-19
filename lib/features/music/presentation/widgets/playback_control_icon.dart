import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One loading presentation for player styles, mini players and queue controls.
/// The surrounding button keeps its dimensions and action while loading.
class PlaybackControlIcon extends StatelessWidget {
  const PlaybackControlIcon({
    required this.isLoading,
    required this.isPlaying,
    this.size,
    this.color,
    this.playOffset = Offset.zero,
    this.loadingLabel,
    super.key,
  });

  final bool isLoading;
  final bool isPlaying;
  final double? size;
  final Color? color;
  final Offset playOffset;
  final String? loadingLabel;

  @override
  Widget build(BuildContext context) {
    if (!isLoading) {
      return Transform.translate(
        offset: isPlaying ? Offset.zero : playOffset,
        transformHitTests: false,
        child: Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: size,
          color: color,
        ),
      );
    }
    final icons = IconTheme.of(context);
    final dimension = size ?? icons.size ?? 24;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox.square(
      dimension: dimension,
      child: Center(
        child: SizedBox.square(
          dimension: (dimension * .68).clamp(14.0, 40.0),
          child: CircularProgressIndicator(
            key: const ValueKey('playback-loading-indicator'),
            value: reducedMotion ? .75 : null,
            strokeWidth: math.min(3, dimension / 12),
            strokeCap: StrokeCap.round,
            color:
                color ?? icons.color ?? Theme.of(context).colorScheme.onSurface,
            semanticsLabel: loadingLabel,
          ),
        ),
      ),
    );
  }
}
