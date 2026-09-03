import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Gives album artwork a restrained, continuously moving presentation.
///
/// Zoom, pan, and depth use independent, closed loops so their movement does
/// not look mechanically synchronized. All animation remains paint-only: the
/// artwork is isolated in a repaint boundary and its layout is never recomputed
/// while the controllers tick.
///
/// [identity] is optional, but passing the current playback identity makes
/// different covers drift in slightly different directions and restarts a new
/// cover from its neutral pose. Setting [isPlaying] to false freezes every
/// loop at its current phase; playback can then resume without a visual jump.
/// The widget becomes completely static when
/// [enabled] is false, reduced motion is requested, or its [TickerMode] is
/// disabled.
class AnimatedArtworkMotion extends StatefulWidget {
  const AnimatedArtworkMotion({
    required this.child,
    this.enabled = true,
    this.isPlaying = true,
    this.identity,
    this.borderRadius = BorderRadius.zero,
    this.zoomDuration = defaultZoomDuration,
    this.panDuration = defaultPanDuration,
    this.depthDuration = defaultDepthDuration,
    super.key,
  });

  static const defaultZoomDuration = Duration(seconds: 28);
  static const defaultPanDuration = Duration(seconds: 31);
  static const defaultDepthDuration = Duration(seconds: 35);
  static const maxHorizontalPan = 7.0;
  static const maxVerticalPan = 4.0;
  static const maxTiltXDegrees = 0.3;
  static const maxTiltYDegrees = 0.4;
  static const maxTiltZDegrees = 0.12;
  static const perspectiveDepth = 0.00085;
  static const zoomAmount = 0.046;

  final Widget child;
  final bool enabled;
  final bool isPlaying;
  final String? identity;
  final BorderRadiusGeometry borderRadius;
  final Duration zoomDuration;
  final Duration panDuration;
  final Duration depthDuration;

  @override
  State<AnimatedArtworkMotion> createState() => _AnimatedArtworkMotionState();
}

class _AnimatedArtworkMotionState extends State<AnimatedArtworkMotion>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _zoomController;
  late final AnimationController _panController;
  late final AnimationController _depthController;
  late final Listenable _motion;
  bool _motionAllowed = false;
  bool _reducedMotion = false;
  bool _tickerEnabled = true;
  bool _appIsActive = true;

  List<AnimationController> get _controllers => [
    _zoomController,
    _panController,
    _depthController,
  ];

  @override
  void initState() {
    super.initState();
    assert(widget.zoomDuration > Duration.zero);
    assert(widget.panDuration > Duration.zero);
    assert(widget.depthDuration > Duration.zero);
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appIsActive =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _zoomController = AnimationController(
      vsync: this,
      duration: widget.zoomDuration,
      debugLabel: 'animated-artwork-zoom',
    );
    _panController = AnimationController(
      vsync: this,
      duration: widget.panDuration,
      debugLabel: 'animated-artwork-pan',
    );
    _depthController = AnimationController(
      vsync: this,
      duration: widget.depthDuration,
      debugLabel: 'animated-artwork-depth',
    );
    _motion = Listenable.merge(_controllers);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _synchronizeMotion();
  }

  @override
  void didUpdateWidget(covariant AnimatedArtworkMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zoomDuration != widget.zoomDuration) {
      assert(widget.zoomDuration > Duration.zero);
      _zoomController.duration = widget.zoomDuration;
    }
    if (oldWidget.panDuration != widget.panDuration) {
      assert(widget.panDuration > Duration.zero);
      _panController.duration = widget.panDuration;
    }
    if (oldWidget.depthDuration != widget.depthDuration) {
      assert(widget.depthDuration > Duration.zero);
      _depthController.duration = widget.depthDuration;
    }
    _synchronizeMotion(restart: oldWidget.identity != widget.identity);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsActive = state == AppLifecycleState.resumed;
    _synchronizeMotion();
  }

  void _synchronizeMotion({bool restart = false}) {
    final canRenderMotion =
        widget.enabled && !_reducedMotion && _tickerEnabled && _appIsActive;
    _motionAllowed = canRenderMotion;

    if (!canRenderMotion) {
      for (final controller in _controllers) {
        controller.stop();
        if (controller.value != 0) {
          controller.value = 0;
        }
      }
      return;
    }

    if (restart) {
      for (final controller in _controllers) {
        controller.stop();
        controller.value = 0;
      }
    }
    if (!widget.isPlaying) {
      for (final controller in _controllers) {
        controller.stop();
      }
      return;
    }
    for (final controller in _controllers) {
      if (!controller.isAnimating) {
        controller.repeat();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final variant = _ArtworkMotionVariant.fromIdentity(widget.identity);
    return ClipRRect(
      borderRadius: widget.borderRadius,
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportSize =
              constraints.hasBoundedWidth && constraints.hasBoundedHeight
              ? constraints.biggest
              : null;
          return RepaintBoundary(
            child: AnimatedBuilder(
              animation: _motion,
              // The image is retained as its own layer. Only the inexpensive
              // transforms above it change on animation ticks.
              child: RepaintBoundary(child: widget.child),
              builder: (context, child) {
                final frame = _motionAllowed
                    ? _ArtworkMotionFrame.at(
                        zoomProgress: _zoomController.value,
                        panProgress: _panController.value,
                        depthProgress: _depthController.value,
                        variant: variant,
                        viewportSize: viewportSize,
                      )
                    : _ArtworkMotionFrame.neutral;
                return Transform(
                  key: const ValueKey('animated-artwork-translation'),
                  transform: Matrix4.translationValues(
                    frame.translation.dx,
                    frame.translation.dy,
                    0,
                  ),
                  transformHitTests: false,
                  child: Transform(
                    key: const ValueKey('animated-artwork-depth-transform'),
                    alignment: Alignment.center,
                    transform: frame.depthTransform,
                    transformHitTests: false,
                    child: Transform.scale(
                      key: const ValueKey('animated-artwork-coverage-scale'),
                      alignment: Alignment.center,
                      scale: frame.coverageScale,
                      transformHitTests: false,
                      child: Transform.scale(
                        key: const ValueKey('animated-artwork-zoom-scale'),
                        alignment: Alignment.center,
                        scale: frame.zoomScale,
                        transformHitTests: false,
                        child: child,
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _ArtworkMotionFrame {
  const _ArtworkMotionFrame({
    required this.translation,
    required this.depthTransform,
    required this.coverageScale,
    required this.zoomScale,
  });

  static final neutral = _ArtworkMotionFrame(
    translation: Offset.zero,
    depthTransform: Matrix4.identity(),
    coverageScale: 1,
    zoomScale: 1,
  );

  final Offset translation;
  final Matrix4 depthTransform;
  final double coverageScale;
  final double zoomScale;

  factory _ArtworkMotionFrame.at({
    required double zoomProgress,
    required double panProgress,
    required double depthProgress,
    required _ArtworkMotionVariant variant,
    required Size? viewportSize,
  }) {
    final zoom = zoomProgress.clamp(0.0, 1.0).toDouble();
    final pan = panProgress.clamp(0.0, 1.0).toDouble();
    final depth = depthProgress.clamp(0.0, 1.0).toDouble();
    if (zoom == 0 && pan == 0 && depth == 0) {
      return neutral;
    }

    final intensity = math.min(variant.intensity, 1.0);
    final zoomPhase = zoom * math.pi * 2;
    final panPhase = pan * math.pi * 2;
    final depthPhase = depth * math.pi * 2;

    // A smooth push-in starts and ends at exactly 1.0. Its 4.6% amplitude is
    // kept from the previous treatment; only the independently timed pan and
    // depth movement become more legible.
    final zoomEnvelope = (1 - math.cos(zoomPhase)) / 2;
    final designedScale =
        1 + (AnimatedArtworkMotion.zoomAmount * zoomEnvelope * intensity);

    // Pixel offsets make the strength consistent across phones and desktop.
    // Harmonics keep both axes neutral at a loop boundary without making them
    // peak together.
    final translation = Offset(
      variant.horizontalDirection *
          math.sin(panPhase) *
          AnimatedArtworkMotion.maxHorizontalPan *
          intensity,
      variant.verticalDirection *
          math.sin(panPhase * 2) *
          AnimatedArtworkMotion.maxVerticalPan *
          intensity,
    );

    final tiltX =
        variant.verticalDirection *
        math.sin(depthPhase) *
        _degreesToRadians(AnimatedArtworkMotion.maxTiltXDegrees) *
        intensity;
    final tiltY =
        -variant.horizontalDirection *
        math.sin(depthPhase * 2) *
        _degreesToRadians(AnimatedArtworkMotion.maxTiltYDegrees) *
        intensity;
    final tiltZ =
        variant.horizontalDirection *
        math.sin(depthPhase * 3) *
        _degreesToRadians(AnimatedArtworkMotion.maxTiltZDegrees) *
        intensity;

    // Fade the matrix perspective smoothly to identity at the loop seam. It
    // reaches 0.00085 for most of the visible depth movement.
    final depthEnvelope = (1 - math.cos(depthPhase)) / 2;
    final perspectivePresence = 1 - math.pow(1 - depthEnvelope, 4).toDouble();
    final perspective =
        AnimatedArtworkMotion.perspectiveDepth * perspectivePresence;

    // Translation and rotation need a little crop reserve even when their
    // independent cycles do not coincide with the zoom peak. Compute only the
    // additional scale required to keep every clipped edge covered. On normal
    // player artwork the designed 4.6% zoom remains the larger value.
    final coverageScale = _coverageScale(
      viewportSize: viewportSize,
      translation: translation,
      tiltX: tiltX,
      tiltY: tiltY,
      tiltZ: tiltZ,
      perspective: perspective,
    );
    final cropGuardScale = math.max(1.0, coverageScale / designedScale);

    final depthTransform = Matrix4.identity()
      ..setEntry(3, 2, perspective)
      ..rotateX(tiltX)
      ..rotateY(tiltY)
      ..rotateZ(tiltZ);

    return _ArtworkMotionFrame(
      translation: translation,
      depthTransform: depthTransform,
      coverageScale: cropGuardScale,
      zoomScale: designedScale,
    );
  }

  static double _coverageScale({
    required Size? viewportSize,
    required Offset translation,
    required double tiltX,
    required double tiltY,
    required double tiltZ,
    required double perspective,
  }) {
    if (viewportSize == null ||
        viewportSize.width <= 0 ||
        viewportSize.height <= 0) {
      return 1;
    }

    final width = viewportSize.width;
    final height = viewportSize.height;
    final sineZ = math.sin(tiltZ).abs();
    final cosineZ = math.cos(tiltZ).abs();
    final horizontalCoverage =
        cosineZ + (sineZ * height / width) + (2 * translation.dx.abs() / width);
    final verticalCoverage =
        cosineZ +
        (sineZ * width / height) +
        (2 * translation.dy.abs() / height);

    // X/Y perspective changes the projected edge by a fraction of a percent.
    // Reserve that projection plus a small anti-aliasing margin proportional
    // to actual motion; there is no permanent crop at the neutral pose.
    final depthReserve =
        (perspective * math.max(width, height) * (tiltX.abs() + tiltY.abs())) +
        ((1 - math.cos(tiltX).abs()) + (1 - math.cos(tiltY).abs()));
    final motionPresence = math.min(
      1.0,
      (translation.distance / AnimatedArtworkMotion.maxHorizontalPan) +
          (tiltX.abs() /
              _degreesToRadians(AnimatedArtworkMotion.maxTiltXDegrees)) +
          (tiltY.abs() /
              _degreesToRadians(AnimatedArtworkMotion.maxTiltYDegrees)) +
          (tiltZ.abs() /
              _degreesToRadians(AnimatedArtworkMotion.maxTiltZDegrees)),
    );
    return math.max(horizontalCoverage, verticalCoverage) +
        depthReserve +
        (0.0015 * motionPresence);
  }

  static double _degreesToRadians(double degrees) => degrees * math.pi / 180;
}

class _ArtworkMotionVariant {
  const _ArtworkMotionVariant({
    required this.horizontalDirection,
    required this.verticalDirection,
    required this.intensity,
  });

  final double horizontalDirection;
  final double verticalDirection;
  final double intensity;

  factory _ArtworkMotionVariant.fromIdentity(String? identity) {
    final seed = _stableStringHash(identity ?? 'bstream-artwork');
    return _ArtworkMotionVariant(
      horizontalDirection: seed.isEven ? 1 : -1,
      verticalDirection: (seed & 2) == 0 ? 1 : -1,
      // A very small deterministic variation keeps consecutive covers from
      // looking mechanically synchronized without exceeding the motion caps.
      intensity: 0.94 + (((seed >> 2) & 7) / 100),
    );
  }
}

int _stableStringHash(String value) {
  // FNV-1a provides a stable seed across processes, unlike Object.hash.
  var hash = 0x811C9DC5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7FFFFFFF;
  }
  return hash;
}
