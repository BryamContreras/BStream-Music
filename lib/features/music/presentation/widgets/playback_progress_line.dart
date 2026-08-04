import 'package:flutter/material.dart';

import '../providers/artwork_progress_color_provider.dart';

/// Thin artwork-tinted playback progress shared by compact player surfaces.
class PlaybackProgressLine extends StatelessWidget {
  const PlaybackProgressLine({
    required this.value,
    required this.color,
    this.height = 3,
    this.backgroundColor = const Color(0x33000000),
    this.progressAnimationKey,
    this.colorAnimationKey,
    this.fillKey,
    this.semanticsLabel,
    super.key,
  });

  final double value;
  final Color color;
  final double height;
  final Color backgroundColor;
  final Key? progressAnimationKey;
  final Key? colorAnimationKey;
  final Key? fillKey;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final progress = value.clamp(0.0, 1.0).toDouble();
    final line = SizedBox(
      height: height,
      child: ColoredBox(
        color: backgroundColor,
        child: Align(
          alignment: Alignment.centerLeft,
          child: TweenAnimationBuilder<double>(
            key: progressAnimationKey,
            tween: Tween(end: progress),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, animatedProgress, _) {
              return FractionallySizedBox(
                widthFactor: animatedProgress,
                child: TweenAnimationBuilder<Color?>(
                  key: colorAnimationKey,
                  tween: ColorTween(end: color),
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  builder: (context, animatedColor, child) => ColoredBox(
                    key: fillKey,
                    color: (animatedColor ?? ArtworkProgressColor.fallback)
                        .withAlpha(220),
                    child: child,
                  ),
                  child: const SizedBox.expand(),
                ),
              );
            },
          ),
        ),
      ),
    );

    final label = semanticsLabel;
    if (label == null) {
      return line;
    }
    return Semantics(
      label: label,
      value: '${(progress * 100).round()}%',
      child: line,
    );
  }
}
