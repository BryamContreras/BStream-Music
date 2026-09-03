import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Compact segmented equalizer shared by artwork cards and playback queues.
class NowPlayingEqualizer extends StatefulWidget {
  const NowPlayingEqualizer({
    required this.isPlaying,
    this.width = 48,
    this.height = 18,
    super.key,
  });

  final bool isPlaying;
  final double width;
  final double height;

  @override
  State<NowPlayingEqualizer> createState() => _NowPlayingEqualizerState();
}

/// Bottom-aligned artwork overlay used by track cards.
///
/// This widget is intentionally a [Positioned] so every card uses the same
/// placement and the equalizer never changes the artwork's layout size.
class NowPlayingEqualizerOverlay extends StatelessWidget {
  const NowPlayingEqualizerOverlay({
    required this.isPlaying,
    this.width = 48,
    this.height = 18,
    this.bottom = 0,
    super.key,
  });

  final bool isPlaying;
  final double width;
  final double height;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: Center(
        child: NowPlayingEqualizer(
          isPlaying: isPlaying,
          width: width,
          height: height,
        ),
      ),
    );
  }
}

/// Adds the paused equalizer treatment to collection artwork while it is
/// hovered, without taking part in the card's layout.
class HoverEqualizerArtwork extends StatefulWidget {
  const HoverEqualizerArtwork({
    required this.child,
    this.width = 48,
    this.height = 18,
    super.key,
  });

  final Widget child;
  final double width;
  final double height;

  @override
  State<HoverEqualizerArtwork> createState() => _HoverEqualizerArtworkState();
}

class _HoverEqualizerArtworkState extends State<HoverEqualizerArtwork> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        children: [
          widget.child,
          if (_hovered)
            NowPlayingEqualizerOverlay(
              isPlaying: false,
              width: widget.width,
              height: widget.height,
            ),
        ],
      ),
    );
  }
}

class _NowPlayingEqualizerState extends State<NowPlayingEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
      value: 0.18,
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant NowPlayingEqualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.isPlaying) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final indicatorColor = Theme.of(context).colorScheme.primary;
    return Semantics(
      label: widget.isPlaying ? 'Reproduciendo' : 'Reproducción pausada',
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _NowPlayingEqualizerPainter(
              phase: _controller,
              isPlaying: widget.isPlaying,
              indicatorColor: indicatorColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the complete segmented equalizer without rebuilding its widget tree.
///
/// The controller is wired to [CustomPainter.repaint], so an animation tick
/// invalidates only this small render layer. Integer-frequency harmonics are
/// derived from one sine/cosine pair per frame, avoiding the 26 trigonometric
/// calls previously needed to calculate all bar levels.
class _NowPlayingEqualizerPainter extends CustomPainter {
  _NowPlayingEqualizerPainter({
    required this.phase,
    required this.isPlaying,
    required this.indicatorColor,
  }) : _activePaint = Paint()
         ..color = indicatorColor.withValues(alpha: _activeAlpha),
       _inactivePaint = Paint()
         ..color = indicatorColor.withValues(alpha: _inactiveAlpha),
       _shadowPaint = _activeShadow.toPaint(),
       super(repaint: phase);

  static const _barCount = 13;
  static const _segmentCount = 4;
  static const _barWidth = 2.4;
  static const _segmentHeight = 2.7;
  static const _segmentRadius = Radius.circular(0.65);
  static const _activeAlpha = 0.94;
  static const _inactiveAlpha = 0.18;
  static const _maximumFrequency = 39;
  static const _activeShadow = BoxShadow(
    color: Color(0x78000000),
    blurRadius: 1.2,
  );
  static const _primaryFrequencies = <int>[
    17,
    23,
    19,
    29,
    13,
    31,
    21,
    27,
    15,
    25,
    33,
    18,
    35,
  ];
  static const _detailFrequencies = <int>[
    31,
    17,
    37,
    19,
    29,
    23,
    35,
    25,
    33,
    21,
    39,
    27,
    15,
  ];
  static const _offsets = <double>[
    0.2,
    1.7,
    3.1,
    4.6,
    2.4,
    5.5,
    0.9,
    3.8,
    5.9,
    2.9,
    4.1,
    1.2,
    5.1,
  ];
  static final _offsetSines = Float64List.fromList(
    _offsets.map(math.sin).toList(growable: false),
  );
  static final _offsetCosines = Float64List.fromList(
    _offsets.map(math.cos).toList(growable: false),
  );
  static const _pausedLevels = <int>[2, 3, 2, 4, 3, 2, 3, 2, 4, 2, 3, 2, 2];

  final Animation<double> phase;
  final bool isPlaying;
  final Color indicatorColor;
  final Paint _activePaint;
  final Paint _inactivePaint;
  final Paint _shadowPaint;
  final Float64List _harmonicSines = Float64List(_maximumFrequency + 1);
  final Float64List _harmonicCosines = Float64List(_maximumFrequency + 1);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    if (isPlaying) {
      _updateHarmonics(phase.value * math.pi * 2);
    }

    final horizontalSpace = math.max(
      0.0,
      (size.width - (_barWidth * _barCount)) / (_barCount - 1),
    );
    final verticalSpace = math.max(
      0.0,
      (size.height - (_segmentHeight * _segmentCount)) / (_segmentCount - 1),
    );
    final horizontalStride = _barWidth + horizontalSpace;
    final verticalStride = _segmentHeight + verticalSpace;

    for (var column = 0; column < _barCount; column++) {
      final level = isPlaying ? _animatedLevel(column) : _pausedLevels[column];
      final left = horizontalStride * column;
      for (var segment = 0; segment < _segmentCount; segment++) {
        final top = verticalStride * segment;
        final bounds = Rect.fromLTWH(left, top, _barWidth, _segmentHeight);
        final shape = RRect.fromRectAndRadius(bounds, _segmentRadius);
        final active = _segmentCount - segment <= level;
        if (active) {
          canvas.drawRRect(shape, _shadowPaint);
        }
        canvas.drawRRect(shape, active ? _activePaint : _inactivePaint);
      }
    }
  }

  void _updateHarmonics(double angle) {
    final sine = math.sin(angle);
    final cosine = math.cos(angle);
    _harmonicSines[0] = 0;
    _harmonicCosines[0] = 1;
    for (var frequency = 1; frequency <= _maximumFrequency; frequency++) {
      final previousSine = _harmonicSines[frequency - 1];
      final previousCosine = _harmonicCosines[frequency - 1];
      _harmonicSines[frequency] =
          (previousSine * cosine) + (previousCosine * sine);
      _harmonicCosines[frequency] =
          (previousCosine * cosine) - (previousSine * sine);
    }
  }

  int _animatedLevel(int index) {
    final primary =
        0.5 + (0.5 * _offsetSine(_primaryFrequencies[index], index));
    final detailOffset = (index + 3) % _offsets.length;
    final detail =
        0.5 + (0.5 * _offsetSine(_detailFrequencies[index], detailOffset));
    return 1 + ((primary * 0.68 + detail * 0.32) * 3).round();
  }

  double _offsetSine(int frequency, int offsetIndex) {
    return (_harmonicSines[frequency] * _offsetCosines[offsetIndex]) +
        (_harmonicCosines[frequency] * _offsetSines[offsetIndex]);
  }

  @override
  bool shouldRepaint(covariant _NowPlayingEqualizerPainter oldDelegate) {
    return phase != oldDelegate.phase ||
        isPlaying != oldDelegate.isPlaying ||
        indicatorColor != oldDelegate.indicatorColor;
  }
}
