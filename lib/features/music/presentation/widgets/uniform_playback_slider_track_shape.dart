import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shared geometry for Apple Music Style seek and volume tracks.
const appleMusicSliderTrackHeight = 7.0;

/// Keeps the active and inactive portions at exactly the same thickness.
///
/// Material's rounded track adds height to the active segment by default,
/// which creates a visible step when no thumb is painted.
class UniformPlaybackSliderTrackShape extends RoundedRectSliderTrackShape {
  const UniformPlaybackSliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: 0,
    );
  }
}

/// Apple-style playback seek bar shared by every full-player presentation.
///
/// The control deliberately has no thumb or Material overlay and commits a
/// drag only when it ends, avoiding repeated player seeks while scrubbing.
class UniformPlaybackSeekBar extends StatefulWidget {
  const UniformPlaybackSeekBar({
    required this.position,
    required this.duration,
    required this.activeTrackColor,
    required this.inactiveTrackColor,
    required this.onSeek,
    this.disabledActiveTrackColor,
    this.disabledInactiveTrackColor,
    this.semanticsLabel,
    this.sliderKey,
    this.sliderThemeKey,
    this.height = 48,
    super.key,
  });

  final Duration position;
  final Duration? duration;
  final Color activeTrackColor;
  final Color inactiveTrackColor;
  final Color? disabledActiveTrackColor;
  final Color? disabledInactiveTrackColor;
  final ValueChanged<Duration> onSeek;
  final String? semanticsLabel;
  final Key? sliderKey;
  final Key? sliderThemeKey;
  final double height;

  @override
  State<UniformPlaybackSeekBar> createState() => _UniformPlaybackSeekBarState();
}

class _UniformPlaybackSeekBarState extends State<UniformPlaybackSeekBar> {
  double? _dragMilliseconds;

  @override
  Widget build(BuildContext context) {
    final durationMilliseconds = math.max(
      0,
      widget.duration?.inMilliseconds ?? 0,
    );
    final positionMilliseconds = widget.position.inMilliseconds.clamp(
      0,
      durationMilliseconds,
    );
    final shownMilliseconds = (_dragMilliseconds ?? positionMilliseconds)
        .clamp(0.0, durationMilliseconds.toDouble())
        .toDouble();
    final canSeek = durationMilliseconds > 0;

    Duration durationAt(double milliseconds) => Duration(
      milliseconds: milliseconds
          .clamp(0.0, durationMilliseconds.toDouble())
          .round(),
    );

    void seekBy(Duration delta) {
      widget.onSeek(durationAt(shownMilliseconds + delta.inMilliseconds));
    }

    String percentageAt(double milliseconds) {
      if (!canSeek) {
        return '0%';
      }
      final fraction =
          durationAt(milliseconds).inMilliseconds / durationMilliseconds;
      return '${(fraction * 100).round()}%';
    }

    return Semantics(
      slider: true,
      enabled: canSeek,
      label: widget.semanticsLabel,
      value: percentageAt(shownMilliseconds),
      increasedValue: canSeek ? percentageAt(shownMilliseconds + 10000) : null,
      decreasedValue: canSeek ? percentageAt(shownMilliseconds - 10000) : null,
      onIncrease: canSeek ? () => seekBy(const Duration(seconds: 10)) : null,
      onDecrease: canSeek ? () => seekBy(const Duration(seconds: -10)) : null,
      child: ExcludeSemantics(
        child: SizedBox(
          height: widget.height,
          child: SliderTheme(
            key: widget.sliderThemeKey,
            data: SliderTheme.of(context).copyWith(
              trackHeight: appleMusicSliderTrackHeight,
              trackShape: const UniformPlaybackSliderTrackShape(),
              activeTrackColor: widget.activeTrackColor,
              inactiveTrackColor: widget.inactiveTrackColor,
              disabledActiveTrackColor:
                  widget.disabledActiveTrackColor ?? widget.activeTrackColor,
              disabledInactiveTrackColor:
                  widget.disabledInactiveTrackColor ??
                  widget.inactiveTrackColor,
              thumbShape: SliderComponentShape.noThumb,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              key: widget.sliderKey,
              min: 0,
              max: math.max(1, durationMilliseconds).toDouble(),
              value: canSeek ? shownMilliseconds : 0,
              onChangeStart: canSeek
                  ? (value) => setState(() => _dragMilliseconds = value)
                  : null,
              onChanged: canSeek
                  ? (value) => setState(() => _dragMilliseconds = value)
                  : null,
              onChangeEnd: canSeek
                  ? (value) {
                      setState(() => _dragMilliseconds = null);
                      widget.onSeek(durationAt(value));
                    }
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
