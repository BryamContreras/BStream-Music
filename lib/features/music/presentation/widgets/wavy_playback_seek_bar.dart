import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Interactive playback seek bar with the animated wave used by the player.
class WavyPlaybackSeekBar extends StatefulWidget {
  const WavyPlaybackSeekBar({
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.waveColor,
    required this.onSeek,
    this.colorAnimationKey,
    this.semanticsLabel,
    super.key,
  });

  final Duration position;
  final Duration? duration;
  final bool isPlaying;
  final Color waveColor;
  final ValueChanged<Duration> onSeek;
  final Key? colorAnimationKey;
  final String? semanticsLabel;

  @override
  State<WavyPlaybackSeekBar> createState() => _WavyPlaybackSeekBarState();
}

class _WavyPlaybackSeekBarState extends State<WavyPlaybackSeekBar>
    with SingleTickerProviderStateMixin {
  static const _trackInset = 10.0;
  late final AnimationController _wavePhase;
  double? _dragFraction;

  @override
  void initState() {
    super.initState();
    _wavePhase = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant WavyPlaybackSeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _wavePhase.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.isPlaying) {
      _wavePhase.repeat();
    } else {
      _wavePhase.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration?.inMilliseconds ?? 0;
    final currentMs = widget.position.inMilliseconds.clamp(0, totalMs);
    final timelineFraction = totalMs <= 0 ? 0.0 : currentMs / totalMs;
    final fraction = _dragFraction ?? timelineFraction;
    final canSeek = totalMs > 0;

    String percentageFor(int milliseconds) {
      final seekFraction = milliseconds / totalMs;
      return '${(seekFraction * 100).round()}%';
    }

    final currentValue = '${(fraction * 100).round()}%';
    final increasedValue = canSeek
        ? percentageFor(
            (currentMs + const Duration(seconds: 10).inMilliseconds).clamp(
              0,
              totalMs,
            ),
          )
        : null;
    final decreasedValue = canSeek
        ? percentageFor(
            (currentMs - const Duration(seconds: 10).inMilliseconds).clamp(
              0,
              totalMs,
            ),
          )
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        double fractionFromDx(double dx) {
          if (totalMs <= 0) {
            return 0;
          }
          final trackWidth = constraints.maxWidth - (_trackInset * 2);
          if (trackWidth <= 0) {
            return 0;
          }
          return ((dx - _trackInset) / trackWidth).clamp(0.0, 1.0).toDouble();
        }

        void commitFraction(double nextFraction) {
          if (totalMs <= 0) {
            return;
          }
          widget.onSeek(
            Duration(milliseconds: (totalMs * nextFraction).round()),
          );
        }

        void seekBy(Duration delta) {
          final target = (currentMs + delta.inMilliseconds).clamp(0, totalMs);
          widget.onSeek(Duration(milliseconds: target));
        }

        return Semantics(
          label: widget.semanticsLabel,
          slider: true,
          enabled: canSeek,
          value: currentValue,
          increasedValue: increasedValue,
          decreasedValue: decreasedValue,
          onIncrease: canSeek
              ? () => seekBy(const Duration(seconds: 10))
              : null,
          onDecrease: canSeek
              ? () => seekBy(const Duration(seconds: -10))
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) =>
                commitFraction(fractionFromDx(details.localPosition.dx)),
            onHorizontalDragStart: (details) => setState(
              () => _dragFraction = fractionFromDx(details.localPosition.dx),
            ),
            onHorizontalDragUpdate: (details) => setState(
              () => _dragFraction = fractionFromDx(details.localPosition.dx),
            ),
            onHorizontalDragEnd: (_) {
              final committed = _dragFraction;
              setState(() => _dragFraction = null);
              if (committed != null) {
                commitFraction(committed);
              }
            },
            onHorizontalDragCancel: () => setState(() => _dragFraction = null),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: TweenAnimationBuilder<Color?>(
                key: widget.colorAnimationKey,
                tween: ColorTween(end: widget.waveColor),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                builder: (context, color, _) => CustomPaint(
                  painter: _WavyPlaybackSeekBarPainter(
                    fraction: fraction,
                    phase: _wavePhase,
                    enabled: totalMs > 0,
                    waveColor: color ?? AppColors.downloadAccentFor(context),
                    isDark: Theme.of(context).brightness == Brightness.dark,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WavyPlaybackSeekBarPainter extends CustomPainter {
  _WavyPlaybackSeekBarPainter({
    required this.fraction,
    required this.phase,
    required this.enabled,
    required this.waveColor,
    required this.isDark,
  }) : super(repaint: phase);

  static const _trackInset = 10.0;
  static const _trackHalfHeight = 3.0;
  static const _maxWaveHeight = 15.5;

  final double fraction;
  final Animation<double> phase;
  final bool enabled;
  final Color waveColor;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final trackStart = _trackInset;
    final trackEnd = size.width - _trackInset;
    final trackWidth = math.max(0.0, trackEnd - trackStart);
    final activeEnd = trackStart + (trackWidth * fraction.clamp(0.0, 1.0));
    final inactivePaint = Paint()
      ..color = enabled
          ? (isDark ? const Color(0x66E7ECE8) : const Color(0x665E6A62))
          : (isDark ? const Color(0x526B756E) : const Color(0x523B463F))
      ..strokeWidth = _trackHalfHeight * 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(trackStart, centerY),
      Offset(trackEnd, centerY),
      inactivePaint,
    );

    final activeLength = activeEnd - trackStart;
    if (activeLength > 0.5) {
      final waveBaseY = centerY - _trackHalfHeight;
      final earlyProgress = (fraction / 0.5).clamp(0.0, 1.0);
      final easedProgress =
          earlyProgress * earlyProgress * (3 - (2 * earlyProgress));
      final progressHeightScale = 0.78 + (0.22 * easedProgress);
      final heightScale =
          (activeLength / 90).clamp(0.0, 1.0) * progressHeightScale;
      final activeBasePaint = Paint()
        ..color = waveColor.withAlpha(220)
        ..strokeWidth = _trackHalfHeight * 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(trackStart, centerY),
        Offset(activeEnd, centerY),
        activeBasePaint,
      );

      ({
        double center,
        double radius,
        double heightFactor,
        double skew,
        double shape,
      })
      movingCrest({
        required double offset,
        required double speedVariation,
        required double secondVariation,
        required double radiusFactor,
        required double heightFactor,
        required double pulseOffset,
        required double skew,
        required double shape,
      }) {
        final rawTravel = (phase.value + offset) % 1.0;
        final travel =
            rawTravel -
            ((speedVariation / (math.pi * 2)) *
                math.sin(math.pi * 2 * rawTravel)) -
            ((secondVariation / (math.pi * 4)) *
                math.sin(math.pi * 4 * rawTravel));
        final pulse =
            0.82 + (0.18 * math.sin((math.pi * 2 * rawTravel) + pulseOffset));
        final radiusPulse =
            0.9 + (0.1 * math.cos((math.pi * 2 * rawTravel) + pulseOffset));
        return (
          center: trackStart + (activeLength * travel),
          radius: radiusFactor * radiusPulse,
          heightFactor: heightFactor * pulse,
          skew: skew,
          shape: shape,
        );
      }

      final broadRadius = math
          .min(112.0, math.max(32.0, activeLength * 0.3))
          .toDouble();

      Path waveLayerPath(
        List<
          ({
            double center,
            double radius,
            double heightFactor,
            double skew,
            double shape,
          })
        >
        crests,
      ) {
        final path = Path()..moveTo(trackStart, waveBaseY);
        for (var x = trackStart; x <= activeEnd; x += 1.5) {
          var combinedHeight = 0.0;
          for (final crest in crests) {
            final normalized = (x - crest.center) / crest.radius;
            if (normalized <= -1 || normalized >= 1) {
              continue;
            }
            final localProgress = (normalized + 1) / 2;
            final profile = math
                .pow(math.sin(math.pi * localProgress), crest.shape)
                .toDouble();
            final rawVisibility = math.min(
              ((crest.center - trackStart) / crest.radius).clamp(0.0, 1.0),
              ((activeEnd - crest.center) / crest.radius).clamp(0.0, 1.0),
            );
            final crestVisibility =
                rawVisibility * rawVisibility * (3 - (2 * rawVisibility));
            final edgeDistance = math.min(x - trackStart, activeEnd - x);
            final edgeProgress = (edgeDistance / 24).clamp(0.0, 1.0);
            final edgeVisibility =
                edgeProgress * edgeProgress * (3 - (2 * edgeProgress));
            final asymmetricProfile =
                profile * (1 + (crest.skew * (localProgress - 0.5)));
            final crestHeight =
                _maxWaveHeight *
                crest.heightFactor *
                heightScale *
                crestVisibility *
                edgeVisibility *
                asymmetricProfile;
            combinedHeight = math.max(combinedHeight, crestHeight);
          }
          path.lineTo(x, waveBaseY - combinedHeight);
        }
        return path
          ..lineTo(activeEnd, waveBaseY)
          ..close();
      }

      final backWave = waveLayerPath([
        movingCrest(
          offset: 0.02,
          speedVariation: 0.38,
          secondVariation: -0.16,
          radiusFactor: broadRadius * 1.02,
          heightFactor: 0.72,
          pulseOffset: 0.4,
          skew: -0.28,
          shape: 1.05,
        ),
        movingCrest(
          offset: 0.5,
          speedVariation: -0.24,
          secondVariation: 0.18,
          radiusFactor: broadRadius * 0.7,
          heightFactor: 0.64,
          pulseOffset: 2.1,
          skew: 0.34,
          shape: 1.55,
        ),
      ]);
      final backPaint = Paint()
        ..color = waveColor.withAlpha(188)
        ..style = PaintingStyle.fill;
      canvas.drawPath(backWave, backPaint);

      final frontWave = waveLayerPath([
        movingCrest(
          offset: 0.25,
          speedVariation: -0.34,
          secondVariation: -0.14,
          radiusFactor: broadRadius * 0.82,
          heightFactor: 1,
          pulseOffset: 1.25,
          skew: 0.22,
          shape: 1.25,
        ),
        movingCrest(
          offset: 0.74,
          speedVariation: 0.3,
          secondVariation: 0.12,
          radiusFactor: broadRadius * 0.58,
          heightFactor: 0.86,
          pulseOffset: 3.4,
          skew: -0.38,
          shape: 1.8,
        ),
      ]);
      final frontPaint = Paint()
        ..color = waveColor.withAlpha(220)
        ..style = PaintingStyle.fill;
      canvas.drawPath(frontWave, frontPaint);
      canvas.drawCircle(
        Offset(trackStart, centerY),
        _trackHalfHeight,
        Paint()..color = waveColor.withAlpha(225),
      );
    }

    final thumbCenter = Offset(activeEnd, centerY);
    canvas.drawCircle(
      thumbCenter,
      12.5,
      Paint()..color = Colors.black.withValues(alpha: isDark ? 0.15 : 0.1),
    );
    canvas.drawCircle(
      thumbCenter,
      10.5,
      Paint()
        ..color = enabled
            ? Color.lerp(
                waveColor,
                isDark ? Colors.white : Colors.black,
                0.18,
              )!.withAlpha(236)
            : (isDark ? const Color(0xFF747D76) : const Color(0xFF9AA59D)),
    );
    canvas.drawCircle(
      thumbCenter,
      10.5,
      Paint()
        ..color = isDark ? const Color(0x704A544C) : const Color(0x705B665E)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _WavyPlaybackSeekBarPainter oldDelegate) {
    return fraction != oldDelegate.fraction ||
        enabled != oldDelegate.enabled ||
        waveColor != oldDelegate.waveColor ||
        isDark != oldDelegate.isDark;
  }
}
