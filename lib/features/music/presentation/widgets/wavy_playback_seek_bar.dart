import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

const _wavyPlaybackTrackInset = 3.0;

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

class _WavyPlaybackSeekBarState extends State<WavyPlaybackSeekBar> {
  double? _dragFraction;

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
          final trackWidth =
              constraints.maxWidth - (_wavyPlaybackTrackInset * 2);
          if (trackWidth <= 0) {
            return 0;
          }
          return ((dx - _wavyPlaybackTrackInset) / trackWidth)
              .clamp(0.0, 1.0)
              .toDouble();
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
            child: WavyPlaybackProgressLine(
              value: fraction,
              isPlaying: widget.isPlaying,
              waveColor: widget.waveColor,
              enabled: canSeek,
              showThumb: true,
              colorAnimationKey: widget.colorAnimationKey,
            ),
          ),
        );
      },
    );
  }
}

/// Paint-only form of the player's animated wave.
///
/// Unlike [WavyPlaybackSeekBar], this widget has no gestures and does not
/// expose slider semantics. It can therefore be reused as a passive playback
/// indicator without coupling its host to seeking controls.
class WavyPlaybackProgressLine extends StatefulWidget {
  const WavyPlaybackProgressLine({
    required this.value,
    required this.isPlaying,
    required this.waveColor,
    this.surfaceBrightness,
    this.showThumb = false,
    this.height = 48,
    this.waveAmplitude = 15.5,
    this.enabled = true,
    this.colorAnimationKey,
    super.key,
  });

  final double value;
  final bool isPlaying;
  final Color waveColor;
  final Brightness? surfaceBrightness;
  final bool showThumb;
  final double height;
  final double waveAmplitude;
  final bool enabled;
  final Key? colorAnimationKey;

  @override
  State<WavyPlaybackProgressLine> createState() =>
      _WavyPlaybackProgressLineState();
}

class _WavyPlaybackProgressLineState extends State<WavyPlaybackProgressLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wavePhase;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _wavePhase = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations != disableAnimations) {
      _disableAnimations = disableAnimations;
    }
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant WavyPlaybackProgressLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying ||
        oldWidget.enabled != widget.enabled) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _wavePhase.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.isPlaying && widget.enabled && !_disableAnimations) {
      if (!_wavePhase.isAnimating) {
        _wavePhase.repeat();
      }
    } else {
      _wavePhase.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final height = math.max(0.0, widget.height).toDouble();
    final availableWaveHeight = math.max(
      0.0,
      (height / 2) - _WavyPlaybackTrackPainter.trackHalfHeight - 1,
    );
    final waveAmplitude = widget.waveAmplitude
        .clamp(0.0, availableWaveHeight)
        .toDouble();
    final brightness = widget.surfaceBrightness ?? Theme.of(context).brightness;
    final fraction = widget.enabled
        ? widget.value.clamp(0.0, 1.0).toDouble()
        : 0.0;

    return RepaintBoundary(
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: TweenAnimationBuilder<Color?>(
          key: widget.colorAnimationKey,
          tween: ColorTween(end: widget.waveColor),
          duration: _disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, color, _) => CustomPaint(
            painter: _WavyPlaybackTrackPainter(
              fraction: fraction,
              phase: _wavePhase,
              enabled: widget.enabled,
              waveColor: color ?? AppColors.downloadAccentFor(context),
              isDark: brightness == Brightness.dark,
              showThumb: widget.showThumb,
              maxWaveHeight: waveAmplitude,
            ),
          ),
        ),
      ),
    );
  }
}

class _WavyPlaybackTrackPainter extends CustomPainter {
  _WavyPlaybackTrackPainter({
    required this.fraction,
    required this.phase,
    required this.enabled,
    required this.waveColor,
    required this.isDark,
    required this.showThumb,
    required this.maxWaveHeight,
  }) : _inactivePaint = (Paint()
         ..color = enabled
             ? (isDark ? const Color(0x66E7ECE8) : const Color(0x665E6A62))
             : (isDark ? const Color(0x526B756E) : const Color(0x523B463F))
         ..strokeWidth = trackHalfHeight * 2
         ..strokeCap = StrokeCap.round
         ..style = PaintingStyle.stroke),
       _activeBasePaint = (Paint()
         ..color = waveColor.withAlpha(220)
         ..strokeWidth = trackHalfHeight * 2
         ..strokeCap = StrokeCap.round
         ..style = PaintingStyle.stroke),
       _backPaint = (Paint()
         ..color = waveColor.withAlpha(188)
         ..style = PaintingStyle.fill),
       _frontPaint = (Paint()
         ..color = waveColor.withAlpha(220)
         ..style = PaintingStyle.fill),
       _activeStartPaint = Paint()..color = waveColor.withAlpha(225),
       _thumbShadowPaint = Paint()
         ..color = Colors.black.withValues(alpha: isDark ? 0.15 : 0.1),
       _thumbFillPaint = Paint()
         ..color = enabled
             ? Color.lerp(
                 waveColor,
                 isDark ? Colors.white : Colors.black,
                 0.18,
               )!.withAlpha(236)
             : (isDark ? const Color(0xFF747D76) : const Color(0xFF9AA59D)),
       _thumbStrokePaint = (Paint()
         ..color = isDark ? const Color(0x704A544C) : const Color(0x705B665E)
         ..strokeWidth = 1
         ..style = PaintingStyle.stroke),
       super(repaint: phase);

  static const trackHalfHeight = 3.0;
  static const _thumbOuterRadius = 12.5;
  static const _maximumWaveSamples = 180;

  final double fraction;
  final Animation<double> phase;
  final bool enabled;
  final Color waveColor;
  final bool isDark;
  final bool showThumb;
  final double maxWaveHeight;
  final Paint _inactivePaint;
  final Paint _activeBasePaint;
  final Paint _backPaint;
  final Paint _frontPaint;
  final Paint _activeStartPaint;
  final Paint _thumbShadowPaint;
  final Paint _thumbFillPaint;
  final Paint _thumbStrokePaint;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final trackStart = _wavyPlaybackTrackInset;
    final trackEnd = size.width - _wavyPlaybackTrackInset;
    final trackWidth = math.max(0.0, trackEnd - trackStart);
    final activeEnd = trackStart + (trackWidth * fraction.clamp(0.0, 1.0));
    canvas.drawLine(
      Offset(trackStart, centerY),
      Offset(trackEnd, centerY),
      _inactivePaint,
    );

    final activeLength = activeEnd - trackStart;
    if (activeLength > 0.5) {
      final waveBaseY = centerY - trackHalfHeight;
      final earlyProgress = (fraction / 0.5).clamp(0.0, 1.0);
      final easedProgress =
          earlyProgress * earlyProgress * (3 - (2 * earlyProgress));
      final progressHeightScale = 0.78 + (0.22 * easedProgress);
      final heightScale =
          (activeLength / 90).clamp(0.0, 1.0) * progressHeightScale;
      canvas.drawLine(
        Offset(trackStart, centerY),
        Offset(activeEnd, centerY),
        _activeBasePaint,
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
        final crestVisibilities = <double>[
          for (final crest in crests)
            () {
              final rawVisibility = math.min(
                ((crest.center - trackStart) / crest.radius).clamp(0.0, 1.0),
                ((activeEnd - crest.center) / crest.radius).clamp(0.0, 1.0),
              );
              return rawVisibility * rawVisibility * (3 - (2 * rawVisibility));
            }(),
        ];
        final sampleStep = math.max(1.5, activeLength / _maximumWaveSamples);
        for (var x = trackStart; x <= activeEnd; x += sampleStep) {
          var combinedHeight = 0.0;
          final edgeDistance = math.min(x - trackStart, activeEnd - x);
          final edgeProgress = (edgeDistance / 24).clamp(0.0, 1.0);
          final edgeVisibility =
              edgeProgress * edgeProgress * (3 - (2 * edgeProgress));
          for (var index = 0; index < crests.length; index += 1) {
            final crest = crests[index];
            final normalized = (x - crest.center) / crest.radius;
            if (normalized <= -1 || normalized >= 1) {
              continue;
            }
            final localProgress = (normalized + 1) / 2;
            final profile = math
                .pow(math.sin(math.pi * localProgress), crest.shape)
                .toDouble();
            final asymmetricProfile =
                profile * (1 + (crest.skew * (localProgress - 0.5)));
            final crestHeight =
                maxWaveHeight *
                crest.heightFactor *
                heightScale *
                crestVisibilities[index] *
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
      canvas.drawPath(backWave, _backPaint);

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
      canvas.drawPath(frontWave, _frontPaint);
      canvas.drawCircle(
        Offset(trackStart, centerY),
        trackHalfHeight,
        _activeStartPaint,
      );
    }

    if (showThumb) {
      final outerRadius = math.min(_thumbOuterRadius, size.height / 2);
      final innerRadius = math.max(0.0, outerRadius - 2);
      final thumbInset = math.min(outerRadius, size.width / 2);
      final thumbCenter = Offset(
        activeEnd.clamp(thumbInset, size.width - thumbInset).toDouble(),
        centerY,
      );
      canvas.drawCircle(thumbCenter, outerRadius, _thumbShadowPaint);
      canvas.drawCircle(thumbCenter, innerRadius, _thumbFillPaint);
      canvas.drawCircle(thumbCenter, innerRadius, _thumbStrokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavyPlaybackTrackPainter oldDelegate) {
    return fraction != oldDelegate.fraction ||
        enabled != oldDelegate.enabled ||
        waveColor != oldDelegate.waveColor ||
        isDark != oldDelegate.isDark ||
        showThumb != oldDelegate.showThumb ||
        maxWaveHeight != oldDelegate.maxWaveHeight;
  }
}
