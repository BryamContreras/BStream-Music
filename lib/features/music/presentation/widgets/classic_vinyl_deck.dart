import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'source_image.dart';

/// A responsive turntable surface used by the Classic Vinyl player style.
///
/// The record animation is paint-only and follows playback. It freezes at its
/// current angle while paused and becomes fully static when animations are
/// disabled, reduced motion is requested, the app is backgrounded, or its
/// [TickerMode] is disabled.
class ClassicVinylDeck extends StatefulWidget {
  const ClassicVinylDeck({
    required this.artworkSource,
    required this.artworkFallbackSource,
    required this.identity,
    required this.isPlaying,
    required this.animationEnabled,
    required this.progress,
    this.trackTransitionsEnabled = true,
    this.expanded = false,
    super.key,
  });

  static const rotationDuration = Duration(milliseconds: 5400);

  final String? artworkSource;
  final String? artworkFallbackSource;
  final String identity;
  final bool isPlaying;
  final bool animationEnabled;
  final double progress;
  final bool trackTransitionsEnabled;
  final bool expanded;

  @override
  State<ClassicVinylDeck> createState() => _ClassicVinylDeckState();
}

class _ClassicVinylDeckState extends State<ClassicVinylDeck>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _rotationController;
  late final AnimationController _tonearmController;
  bool _reducedMotion = false;
  bool _tickerEnabled = true;
  bool _appIsActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appIsActive =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _rotationController = AnimationController(
      vsync: this,
      duration: ClassicVinylDeck.rotationDuration,
      debugLabel: 'classic-vinyl-record-rotation',
    );
    _tonearmController = AnimationController(
      vsync: this,
      value: _normalizedProgress(widget.progress),
      debugLabel: 'classic-vinyl-tonearm-progress',
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _synchronizeRotation();
    _synchronizeTonearm();
  }

  @override
  void didUpdateWidget(covariant ClassicVinylDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    final trackChanged = oldWidget.identity != widget.identity;
    _synchronizeRotation(restart: trackChanged);
    _synchronizeTonearm(trackChanged: trackChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsActive = state == AppLifecycleState.resumed;
    _synchronizeRotation();
    _synchronizeTonearm();
  }

  static double _normalizedProgress(double progress) {
    if (!progress.isFinite) {
      return 0;
    }
    return progress.clamp(0.0, 1.0).toDouble();
  }

  bool get _canAnimate =>
      widget.animationEnabled &&
      !_reducedMotion &&
      _tickerEnabled &&
      _appIsActive;

  void _synchronizeRotation({bool restart = false}) {
    if (!_canAnimate) {
      _rotationController.stop();
      if (_rotationController.value != 0) {
        _rotationController.value = 0;
      }
      return;
    }
    if (restart) {
      _rotationController
        ..stop()
        ..value = 0;
    }
    if (!widget.isPlaying) {
      _rotationController.stop();
      return;
    }
    if (!_rotationController.isAnimating) {
      _rotationController.repeat();
    }
  }

  void _synchronizeTonearm({bool trackChanged = false}) {
    final target = _normalizedProgress(widget.progress);
    final distance = (target - _tonearmController.value).abs();
    if (trackChanged || !_canAnimate) {
      _tonearmController
        ..stop()
        ..value = target;
      return;
    }
    // Player position events may arrive several times per second. Ignoring
    // sub-pixel changes prevents restarting the interpolation continuously,
    // while a seek still glides the physical arm to its new groove.
    if (distance < 0.0004) {
      return;
    }
    _tonearmController.animateTo(
      target,
      duration: distance > 0.018
          ? const Duration(milliseconds: 560)
          : const Duration(milliseconds: 820),
      curve: distance > 0.018 ? Curves.easeOutCubic : Curves.linear,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rotationController.dispose();
    _tonearmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final geometry = _VinylDeckGeometry.fromSize(
          constraints.biggest,
          expanded: widget.expanded,
        );
        final extent = geometry.extent;
        final recordExtent = geometry.recordDiameter;
        final labelExtent = recordExtent * 0.42;
        final fallback = ColoredBox(
          color: colors.primaryContainer,
          child: Center(
            child: Icon(
              Icons.music_note_rounded,
              size: labelExtent * 0.34,
              color: colors.onPrimaryContainer.withValues(alpha: 0.78),
            ),
          ),
        );
        final artwork = AnimatedSwitcher(
          duration: widget.trackTransitionsEnabled
              ? const Duration(milliseconds: 360)
              : Duration.zero,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(animation),
              child: child,
            ),
          ),
          child: SizedBox.square(
            key: ValueKey('classic-vinyl-label-${widget.identity}'),
            dimension: labelExtent,
            child: ClipOval(
              child: SourceImage(
                source: widget.artworkSource,
                fallbackSource: widget.artworkFallbackSource,
                fit: BoxFit.cover,
                cacheWidth: 640,
                fallback: fallback,
              ),
            ),
          ),
        );

        return RepaintBoundary(
          key: const ValueKey('classic-vinyl-deck'),
          child: SizedBox.expand(
            key: const ValueKey('classic-vinyl-deck-surface'),
            child: Stack(
              key: const ValueKey('classic-vinyl-deck-stack'),
              clipBehavior: Clip.none,
              children: [
                Positioned.fromRect(
                  rect: geometry.recordRect,
                  child: RepaintBoundary(
                    key: const ValueKey('classic-vinyl-record-layer'),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(
                              alpha: dark ? 0.42 : 0.25,
                            ),
                            blurRadius: extent * 0.055,
                            spreadRadius: extent * 0.007,
                            offset: Offset(0, extent * 0.026),
                          ),
                        ],
                      ),
                      child: RotationTransition(
                        key: const ValueKey('classic-vinyl-record-rotation'),
                        turns: _rotationController,
                        child: CustomPaint(
                          key: const ValueKey('classic-vinyl-record'),
                          painter: _VinylRecordPainter(
                            highlightColor: colors.onSurface,
                            accent: colors.primary,
                          ),
                          child: Center(
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                artwork,
                                Container(
                                  key: const ValueKey('classic-vinyl-spindle'),
                                  width: recordExtent * 0.026,
                                  height: recordExtent * 0.026,
                                  decoration: BoxDecoration(
                                    color: dark
                                        ? const Color(0xFFE8E8E8)
                                        : const Color(0xFF242424),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: dark
                                          ? const Color(0xFF767676)
                                          : const Color(0xFFD4D4D4),
                                      width: 1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: RepaintBoundary(
                    key: const ValueKey('classic-vinyl-tonearm-layer'),
                    child: IgnorePointer(
                      child: CustomPaint(
                        key: const ValueKey('classic-vinyl-tonearm'),
                        painter: ClassicVinylTonearmPainter(
                          progress: _tonearmController,
                          expanded: widget.expanded,
                          dark: dark,
                          accent: colors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _VinylDeckGeometry {
  const _VinylDeckGeometry({
    required this.extent,
    required this.recordRect,
    required this.pivot,
    required this.pivotRadius,
    required this.armLength,
  });

  factory _VinylDeckGeometry.fromSize(Size size, {required bool expanded}) {
    final extent = math.min(size.width, size.height);
    final recordDiameter = extent * (expanded ? 1.06 : 0.98);
    final recordCenter = Offset(
      extent * (expanded ? 0.395 : 0.415),
      extent * (expanded ? 0.545 : 0.535),
    );
    return _VinylDeckGeometry(
      extent: extent,
      recordRect: Rect.fromCircle(
        center: recordCenter,
        radius: recordDiameter / 2,
      ),
      pivot: Offset(extent * 0.845, extent * 0.18),
      pivotRadius: extent * 0.091,
      armLength: extent * (expanded ? 0.69 : 0.655),
    );
  }

  final double extent;
  final Rect recordRect;
  final Offset pivot;
  final double pivotRadius;
  final double armLength;

  double get recordDiameter => recordRect.width;
}

class _VinylRecordPainter extends CustomPainter {
  const _VinylRecordPainter({
    required this.highlightColor,
    required this.accent,
  });

  final Color highlightColor;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(center, radius, Paint()..color = const Color(0xFF080A0B));

    canvas.drawCircle(
      center,
      radius * 0.988,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, radius * 0.012)
        ..color = const Color(0xFF22272A),
    );

    final groovePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.45, radius * 0.0032)
      ..color = const Color(0xFF485057).withValues(alpha: 0.48);
    for (var index = 0; index < 24; index += 1) {
      final fraction = 0.49 + (index * 0.0205);
      canvas.drawCircle(center, radius * fraction, groovePaint);
    }

    final bandPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, radius * 0.006)
      ..color = highlightColor.withValues(alpha: 0.055);
    for (final fraction in const [0.59, 0.735, 0.88]) {
      canvas.drawCircle(center, radius * fraction, bandPaint);
    }

    final sheen = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.transparent,
          highlightColor.withValues(alpha: 0.075),
          Colors.transparent,
          highlightColor.withValues(alpha: 0.035),
          Colors.transparent,
        ],
        stops: const [0, 0.18, 0.34, 0.64, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, sheen);

    final warmSheen = Paint()
      ..shader = SweepGradient(
        transform: const GradientRotation(math.pi * 0.32),
        colors: [
          Colors.transparent,
          accent.withValues(alpha: 0.032),
          Colors.transparent,
          Colors.white.withValues(alpha: 0.035),
          Colors.transparent,
        ],
        stops: const [0, 0.16, 0.31, 0.53, 1],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius * 0.985, warmSheen);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, radius * 0.008)
        ..color = Colors.black.withValues(alpha: 0.72),
    );
  }

  @override
  bool shouldRepaint(covariant _VinylRecordPainter oldDelegate) =>
      oldDelegate.highlightColor != highlightColor ||
      oldDelegate.accent != accent;
}

/// Paints the tonearm at the interpolated playback [progress].
///
/// The public type and progress animation make the rendered position
/// observable in widget tests without exposing the deck's state object.
class ClassicVinylTonearmPainter extends CustomPainter {
  ClassicVinylTonearmPainter({
    required this.progress,
    required this.expanded,
    required this.dark,
    required this.accent,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final bool expanded;
  final bool dark;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = _VinylDeckGeometry.fromSize(size, expanded: expanded);
    final shortest = geometry.extent;
    final pivot = geometry.pivot;
    final pivotRadius = geometry.pivotRadius;
    final armLength = geometry.armLength;
    final rodWidth = (shortest * 0.022).clamp(5.5, 10.0).toDouble();
    final startAngle = -0.035;
    final endAngle = -0.18;
    final armAngle =
        startAngle + ((endAngle - startAngle) * progress.value.clamp(0.0, 1.0));

    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(armAngle);

    final tubeStart = -pivotRadius * 0.30;
    final headshellLength = shortest * 0.105;
    final tubeEnd = -armLength + headshellLength * 0.72;
    final tubePath = Path()
      ..moveTo(tubeStart, 0)
      ..cubicTo(
        -armLength * 0.30,
        -rodWidth * 0.12,
        -armLength * 0.68,
        rodWidth * 0.10,
        tubeEnd,
        0,
      );
    canvas.drawPath(
      tubePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = rodWidth + shortest * 0.013
        ..color = Colors.black.withValues(alpha: 0.28)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(2.0, shortest * 0.012),
        ),
    );
    canvas.drawPath(
      tubePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = rodWidth + shortest * 0.005
        ..color = const Color(0xFF646A6E),
    );
    canvas.drawPath(
      tubePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = rodWidth
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFFF8F9F9), Color(0xFFC8CCCF), Color(0xFF858B8F)]
              : const [Color(0xFFFFFFFF), Color(0xFFD6D9DB), Color(0xFF969C9F)],
          stops: const [0, 0.42, 1],
        ).createShader(Rect.fromLTRB(-armLength, -rodWidth, 0, rodWidth)),
    );
    canvas.drawPath(
      tubePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(0.7, rodWidth * 0.13)
        ..color = Colors.white.withValues(alpha: dark ? 0.70 : 0.86),
    );

    final counterweightStemEnd = pivotRadius * 1.22;
    canvas.drawLine(
      Offset(pivotRadius * 0.28, 0),
      Offset(counterweightStemEnd, 0),
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = rodWidth * 0.55
        ..color = const Color(0xFF83898D),
    );
    final counterweightRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(counterweightStemEnd, 0),
        width: shortest * 0.075,
        height: shortest * 0.058,
      ),
      Radius.circular(shortest * 0.018),
    );
    canvas.drawRRect(
      counterweightRect.shift(Offset(0, shortest * 0.008)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(1.5, shortest * 0.008),
        ),
    );
    canvas.drawRRect(
      counterweightRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFFB8BDC0), Color(0xFF676D71)]
              : const [Color(0xFFD9DCDE), Color(0xFF858B8E)],
        ).createShader(counterweightRect.outerRect),
    );
    canvas.drawLine(
      Offset(counterweightStemEnd, -shortest * 0.024),
      Offset(counterweightStemEnd, shortest * 0.024),
      Paint()
        ..strokeWidth = math.max(0.7, shortest * 0.003)
        ..color = Colors.black.withValues(alpha: 0.28),
    );

    final headshellTip = -armLength;
    final headshellBack = tubeEnd + shortest * 0.008;
    final headshellHalfHeight = shortest * 0.026;
    final headshellPath = Path()
      ..moveTo(headshellBack, -headshellHalfHeight * 0.72)
      ..lineTo(headshellTip + shortest * 0.010, -headshellHalfHeight)
      ..lineTo(headshellTip - shortest * 0.008, headshellHalfHeight * 0.56)
      ..lineTo(headshellBack, headshellHalfHeight)
      ..close();
    canvas.drawPath(
      headshellPath.shift(Offset(0, shortest * 0.008)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.24)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(1.2, shortest * 0.006),
        ),
    );
    canvas.drawPath(
      headshellPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFF4B5155), Color(0xFF202427)]
              : const [Color(0xFF62686C), Color(0xFF292D30)],
        ).createShader(headshellPath.getBounds()),
    );
    canvas.drawCircle(
      Offset(headshellBack - shortest * 0.025, 0),
      shortest * 0.009,
      Paint()..color = accent.withValues(alpha: 0.90),
    );
    canvas.drawCircle(
      Offset(headshellTip + shortest * 0.032, 0),
      shortest * 0.006,
      Paint()..color = const Color(0xFFC8CCCF),
    );

    final cantileverStart = Offset(
      headshellTip + shortest * 0.014,
      headshellHalfHeight * 0.44,
    );
    final stylusTip = Offset(
      headshellTip - shortest * 0.006,
      headshellHalfHeight * 1.36,
    );
    canvas.drawLine(
      cantileverStart,
      stylusTip,
      Paint()
        ..strokeWidth = math.max(0.8, shortest * 0.0035)
        ..strokeCap = StrokeCap.round
        ..color = dark ? const Color(0xFFD9DCDE) : const Color(0xFF61676B),
    );
    canvas.drawCircle(
      stylusTip,
      math.max(1.2, shortest * 0.005),
      Paint()..color = const Color(0xFF151719),
    );
    canvas.restore();

    canvas.drawCircle(
      pivot.translate(2, 4),
      pivotRadius,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          math.max(3.0, shortest * 0.020),
        ),
    );
    canvas.drawCircle(
      pivot,
      pivotRadius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.34, -0.42),
          radius: 0.92,
          colors: dark
              ? const [Color(0xFFF0F1F2), Color(0xFFB2B7BA), Color(0xFF73797D)]
              : const [Color(0xFFFFFFFF), Color(0xFFD8DBDD), Color(0xFF9BA0A3)],
          stops: const [0, 0.62, 1],
        ).createShader(Rect.fromCircle(center: pivot, radius: pivotRadius)),
    );
    canvas.drawCircle(
      pivot,
      pivotRadius * 0.76,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, shortest * 0.006)
        ..color = Colors.black.withValues(alpha: 0.28),
    );
    canvas.drawCircle(
      pivot,
      pivotRadius * 0.49,
      Paint()
        ..shader =
            RadialGradient(
              center: const Alignment(-0.32, -0.38),
              colors: dark
                  ? const [Color(0xFFAEB3B6), Color(0xFF646A6E)]
                  : const [Color(0xFFD0D3D5), Color(0xFF8B9093)],
            ).createShader(
              Rect.fromCircle(center: pivot, radius: pivotRadius * 0.49),
            ),
    );
    canvas.drawCircle(
      pivot,
      pivotRadius * 0.49,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, shortest * 0.003)
        ..color = Colors.black.withValues(alpha: 0.36),
    );

    final screwPaint = Paint()..color = const Color(0xFF4D5357);
    for (final angle in const [-math.pi / 2, math.pi / 6, math.pi * 5 / 6]) {
      canvas.drawCircle(
        pivot + Offset.fromDirection(angle, pivotRadius * 0.68),
        math.max(1.2, shortest * 0.006),
        screwPaint,
      );
    }
    canvas.drawCircle(
      pivot.translate(-pivotRadius * 0.12, -pivotRadius * 0.14),
      pivotRadius * 0.12,
      Paint()..color = Colors.white.withValues(alpha: 0.20),
    );
  }

  @override
  bool shouldRepaint(covariant ClassicVinylTonearmPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.expanded != expanded ||
      oldDelegate.dark != dark ||
      oldDelegate.accent != accent;
}
