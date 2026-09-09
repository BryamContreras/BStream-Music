import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Paints a layered field of artwork-tinted particles above an animated cover.
///
/// The field is deterministic for [identity], so ordinary widget rebuilds do
/// not make particles jump. Animation is paint-only and follows the same
/// playback, accessibility, ticker, and application lifecycle rules as the
/// cover motion itself.
class AnimatedArtworkParticles extends StatefulWidget {
  const AnimatedArtworkParticles({
    required this.color,
    required this.identity,
    this.enabled = true,
    this.isPlaying = true,
    this.borderRadius = BorderRadius.zero,
    this.cycleDuration = defaultCycleDuration,
    this.particleCount = defaultParticleCount,
    this.bottomFadeStart = 1,
    super.key,
  });

  static const defaultCycleDuration = Duration(seconds: 12);
  static const defaultParticleCount = 52;
  static const expandedParticleCount = 64;

  final Color color;
  final String identity;
  final bool enabled;
  final bool isPlaying;
  final BorderRadiusGeometry borderRadius;
  final Duration cycleDuration;
  final int particleCount;

  /// Normalized vertical position where an optional bottom edge fade begins.
  ///
  /// Classic covers use the default and receive only a narrow safety fade at
  /// the physical edge. In-flow expanded covers use an earlier value so
  /// particles disappear with the artwork blend.
  final double bottomFadeStart;

  @override
  State<AnimatedArtworkParticles> createState() =>
      _AnimatedArtworkParticlesState();
}

class _AnimatedArtworkParticlesState extends State<AnimatedArtworkParticles>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  late List<ArtworkParticleSpec> _particleSpecs;
  bool _renderAllowed = false;
  bool _reducedMotion = false;
  bool _tickerEnabled = true;
  bool _appIsActive = true;

  @override
  void initState() {
    super.initState();
    assert(widget.cycleDuration > Duration.zero);
    assert(widget.particleCount > 0);
    assert(widget.bottomFadeStart >= 0 && widget.bottomFadeStart <= 1);
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appIsActive =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _controller = AnimationController(
      vsync: this,
      duration: widget.cycleDuration,
      debugLabel: 'animated-artwork-particles',
    );
    _particleSpecs = List<ArtworkParticleSpec>.unmodifiable(
      _createParticleSpecs(widget.identity, widget.particleCount),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _synchronize();
  }

  @override
  void didUpdateWidget(covariant AnimatedArtworkParticles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cycleDuration != widget.cycleDuration) {
      assert(widget.cycleDuration > Duration.zero);
      _controller.duration = widget.cycleDuration;
    }
    assert(widget.particleCount > 0);
    assert(widget.bottomFadeStart >= 0 && widget.bottomFadeStart <= 1);
    if (oldWidget.identity != widget.identity ||
        oldWidget.particleCount != widget.particleCount) {
      _particleSpecs = List<ArtworkParticleSpec>.unmodifiable(
        _createParticleSpecs(widget.identity, widget.particleCount),
      );
    }
    _synchronize(
      restart:
          oldWidget.identity != widget.identity ||
          oldWidget.particleCount != widget.particleCount,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) {
      return;
    }
    setState(() {
      _appIsActive = state == AppLifecycleState.resumed;
      _synchronize();
    });
  }

  void _synchronize({bool restart = false}) {
    _renderAllowed =
        widget.enabled && !_reducedMotion && _tickerEnabled && _appIsActive;
    if (!_renderAllowed) {
      _controller.stop();
      if (_controller.value != 0) {
        _controller.value = 0;
      }
      return;
    }

    if (restart) {
      _controller.stop();
      _controller.value = 0;
    }
    if (!widget.isPlaying) {
      _controller.stop();
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_renderAllowed) {
      return const SizedBox.shrink();
    }

    return IgnorePointer(
      key: const ValueKey('animated-artwork-particles'),
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: widget.borderRadius,
          clipBehavior: Clip.antiAlias,
          child: RepaintBoundary(
            key: const ValueKey('animated-artwork-particles-boundary'),
            child: CustomPaint(
              key: const ValueKey('animated-artwork-particles-paint'),
              painter: ArtworkParticlePainter(
                progress: _controller,
                identity: widget.identity,
                color: widget.color,
                brightness: Theme.of(context).brightness,
                particleCount: widget.particleCount,
                particleSpecs: _particleSpecs,
                bottomFadeStart: widget.bottomFadeStart,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Optical depth used to mix crisp embers with out-of-focus particles.
enum ArtworkParticleBlurTier { sharp, soft, diffuse }

/// Immutable, normalized description of one particle in a cover's field.
@immutable
class ArtworkParticleSpec {
  const ArtworkParticleSpec({
    required this.x,
    required this.y,
    required this.start,
    required this.lifetime,
    required this.radius,
    required this.motionSpeed,
    required this.windInfluence,
    required this.turbulence,
    required this.verticalLift,
    required this.motionPath,
    required this.flickerFrequency,
    required this.flickerPhase,
    required this.maxOpacity,
    required this.toneIndex,
    required this.blurTier,
  }) : assert(motionPath.length >= 2);

  final double x;
  final double y;
  final double start;
  final double lifetime;
  final double radius;
  final double motionSpeed;
  final double windInfluence;
  final double turbulence;
  final double verticalLift;
  final List<Offset> motionPath;
  final double flickerFrequency;
  final double flickerPhase;
  final double maxOpacity;
  final int toneIndex;
  final ArtworkParticleBlurTier blurTier;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArtworkParticleSpec &&
          other.x == x &&
          other.y == y &&
          other.start == start &&
          other.lifetime == lifetime &&
          other.radius == radius &&
          other.motionSpeed == motionSpeed &&
          other.windInfluence == windInfluence &&
          other.turbulence == turbulence &&
          other.verticalLift == verticalLift &&
          _offsetListsEqual(other.motionPath, motionPath) &&
          other.flickerFrequency == flickerFrequency &&
          other.flickerPhase == flickerPhase &&
          other.maxOpacity == maxOpacity &&
          other.toneIndex == toneIndex &&
          other.blurTier == blurTier;

  @override
  int get hashCode => Object.hash(
    x,
    y,
    start,
    lifetime,
    radius,
    motionSpeed,
    windInfluence,
    turbulence,
    verticalLift,
    Object.hashAll(motionPath),
    flickerFrequency,
    flickerPhase,
    maxOpacity,
    toneIndex,
    blurTier,
  );
}

/// Repaint-only renderer used by [AnimatedArtworkParticles].
///
/// The public immutable configuration doubles as a deterministic test seam;
/// no random values are generated from inside [paint].
class ArtworkParticlePainter extends CustomPainter {
  ArtworkParticlePainter({
    required this.progress,
    required this.identity,
    required this.color,
    required this.brightness,
    required this.particleCount,
    required this.particleSpecs,
    required this.bottomFadeStart,
  }) : assert(particleCount > 0),
       assert(particleSpecs.length == particleCount),
       assert(bottomFadeStart >= 0 && bottomFadeStart <= 1),
       _palette = _createParticlePalette(color, brightness),
       super(repaint: progress);

  final Animation<double> progress;
  final String identity;
  final Color color;
  final Brightness brightness;
  final int particleCount;
  final double bottomFadeStart;
  final List<ArtworkParticleSpec> particleSpecs;
  final List<Color> _palette;
  final Paint _sharpPaint = Paint()..isAntiAlias = true;
  final Paint _softPaint = Paint()
    ..isAntiAlias = true
    ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 2);
  final Paint _diffusePaint = Paint()
    ..isAntiAlias = true
    ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4);

  @visibleForTesting
  double opacityForAge(double age) {
    if (age <= 0 || age >= 1) {
      return 0;
    }
    final fadeIn = _smootherUnit(age / 0.18);
    final fadeOut = 1 - _smootherUnit((age - 0.62) / 0.38);
    return fadeIn * fadeOut;
  }

  /// Resolves the precalculated turbulent trajectory at a normalized age.
  ///
  /// The path combines a cover-wide wind field with independent eddies. It is
  /// sampled up front, so every paint only interpolates four nearby points.
  @visibleForTesting
  Offset positionForAge(ArtworkParticleSpec particle, double age, Size size) {
    final normalizedAge = age.clamp(0.0, 1.0).toDouble();
    final shortestSide = size.shortestSide;
    final windOffset = _sampleOpenVectorCurve(
      particle.motionPath,
      normalizedAge,
    );
    return Offset(
      (particle.x * size.width) + (windOffset.dx * shortestSide),
      (particle.y * size.height) + (windOffset.dy * shortestSide),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }

    final shortestSide = size.shortestSide;
    final cycleProgress = progress.value.clamp(0.0, 1.0).toDouble();

    for (final particle in particleSpecs) {
      var elapsed = cycleProgress - particle.start;
      if (elapsed < 0) {
        elapsed += 1;
      }
      if (elapsed <= 0 || elapsed >= particle.lifetime) {
        continue;
      }
      final age = elapsed / particle.lifetime;
      final opacityEnvelope = opacityForAge(age);
      if (opacityEnvelope <= 0.001) {
        continue;
      }

      final center = positionForAge(particle, age, size);
      final edgeOpacity = _fieldEdgeOpacity(center, size);
      final shimmer =
          0.95 +
          (math.sin(
                (age * math.pi * 2 * particle.flickerFrequency) +
                    particle.flickerPhase,
              ) *
              0.05);
      final opacity =
          particle.maxOpacity * opacityEnvelope * edgeOpacity * shimmer;
      if (opacity <= 0.001) {
        continue;
      }

      final radius = (particle.radius * shortestSide).clamp(0.55, 2.25);
      final pulse = 0.84 + (math.sin(age * math.pi) * 0.16);
      final renderedRadius = radius * pulse;
      final tone = _palette[particle.toneIndex];
      switch (particle.blurTier) {
        case ArtworkParticleBlurTier.sharp:
          _sharpPaint.color = tone.withValues(alpha: tone.a * opacity);
          canvas.drawCircle(center, renderedRadius, _sharpPaint);
        case ArtworkParticleBlurTier.soft:
          _softPaint.color = tone.withValues(alpha: tone.a * opacity * 0.88);
          canvas.drawCircle(center, renderedRadius * 1.28, _softPaint);
        case ArtworkParticleBlurTier.diffuse:
          _diffusePaint.color = tone.withValues(alpha: tone.a * opacity * 0.72);
          canvas.drawCircle(center, renderedRadius * 1.62, _diffusePaint);
      }
    }
  }

  double _fieldEdgeOpacity(Offset center, Size size) {
    final normalizedX = center.dx / size.width;
    final normalizedY = center.dy / size.height;
    final left = _smoothUnit(normalizedX / 0.085);
    final right = _smoothUnit((1 - normalizedX) / 0.085);
    final top = _smoothUnit(normalizedY / 0.065);
    return left * right * top * _bottomEdgeOpacity(normalizedY);
  }

  double _bottomEdgeOpacity(double normalizedY) {
    final effectiveFadeStart = math.min(bottomFadeStart, 0.94);
    if (normalizedY <= effectiveFadeStart) {
      return 1;
    }
    final remaining = ((1 - normalizedY) / (1 - effectiveFadeStart))
        .clamp(0.0, 1.0)
        .toDouble();
    return _smoothUnit(remaining);
  }

  @override
  bool shouldRepaint(covariant ArtworkParticlePainter oldDelegate) =>
      oldDelegate.identity != identity ||
      oldDelegate.color != color ||
      oldDelegate.brightness != brightness ||
      oldDelegate.particleCount != particleCount ||
      !identical(oldDelegate.particleSpecs, particleSpecs) ||
      oldDelegate.bottomFadeStart != bottomFadeStart ||
      oldDelegate.progress != progress;
}

List<ArtworkParticleSpec> _createParticleSpecs(
  String identity,
  int particleCount,
) {
  final random = math.Random(_stableParticleHash('$identity|particles'));
  final globalWind = _createGlobalWindKnots(identity);
  return List<ArtworkParticleSpec>.generate(particleCount, (index) {
    final lifetime = 0.17 + (random.nextDouble() * 0.1);
    final radiusRoll = random.nextDouble();
    final blurRoll = random.nextDouble();
    final blurTier = switch (index) {
      0 => ArtworkParticleBlurTier.sharp,
      1 => ArtworkParticleBlurTier.soft,
      2 => ArtworkParticleBlurTier.diffuse,
      _ when blurRoll < 0.55 => ArtworkParticleBlurTier.sharp,
      _ when blurRoll < 0.85 => ArtworkParticleBlurTier.soft,
      _ => ArtworkParticleBlurTier.diffuse,
    };
    final start = (index + random.nextDouble()) / particleCount;
    final motionSpeed = 0.2 + (random.nextDouble() * 0.17);
    final windInfluence = 0.5 + (random.nextDouble() * 0.5);
    final turbulence = 0.58 + (random.nextDouble() * 0.55);
    final verticalLift = 0.008 + (random.nextDouble() * 0.027);
    final localEddies = _createLocalEddyKnots(random);
    final motionPath = _createMotionPath(
      start: start,
      lifetime: lifetime,
      motionSpeed: motionSpeed,
      windInfluence: windInfluence,
      turbulence: turbulence,
      verticalLift: verticalLift,
      globalWind: globalWind,
      localEddies: localEddies,
    );
    return ArtworkParticleSpec(
      x: 0.1 + (random.nextDouble() * 0.8),
      // Most motes start above the outer artwork blend. Their turbulent path
      // can still carry them through its lower edge naturally.
      y: 0.08 + (math.pow(random.nextDouble(), 1.08).toDouble() * 0.76),
      start: start,
      lifetime: lifetime,
      radius: 0.002 + (math.pow(radiusRoll, 2.35).toDouble() * 0.0045),
      motionSpeed: motionSpeed,
      windInfluence: windInfluence,
      turbulence: turbulence,
      verticalLift: verticalLift,
      motionPath: motionPath,
      flickerFrequency: 1.9 + (random.nextDouble() * 3.4),
      flickerPhase: random.nextDouble() * math.pi * 2,
      maxOpacity: 0.38 + (random.nextDouble() * 0.48),
      toneIndex: random.nextInt(4),
      blurTier: blurTier,
    );
  });
}

const int _globalWindKnotCount = 12;
const int _localEddyKnotCount = 9;
const int _motionSampleCount = 28;
const double _trajectorySpeedScale = 0.95;

List<Offset> _createGlobalWindKnots(String identity) {
  final random = math.Random(_stableParticleHash('$identity|global-wind-v2'));
  var angle = random.nextDouble() * math.pi * 2;
  final raw = List<Offset>.generate(_globalWindKnotCount, (index) {
    final abruptTurn = random.nextDouble() < 0.24;
    if (abruptTurn) {
      final direction = random.nextBool() ? 1.0 : -1.0;
      angle += direction * (0.62 + (random.nextDouble() * 0.5)) * math.pi;
    } else {
      angle += (random.nextDouble() - 0.5) * math.pi * 1.1;
    }
    final magnitude = 0.56 + (random.nextDouble() * 0.62);
    return Offset(math.cos(angle) * magnitude, math.sin(angle) * magnitude);
  });
  final smoothed = List<Offset>.generate(_globalWindKnotCount, (index) {
    final previous = raw[(index - 1 + raw.length) % raw.length];
    final next = raw[(index + 1) % raw.length];
    return (previous * 0.18) + (raw[index] * 0.64) + (next * 0.18);
  });
  final mean =
      smoothed.fold<Offset>(Offset.zero, (sum, knot) => sum + knot) /
      smoothed.length.toDouble();
  final centered = [for (final knot in smoothed) knot - mean];
  final rms = math.sqrt(
    centered.fold<double>(0, (sum, knot) => sum + knot.distanceSquared) /
        centered.length,
  );
  final scale = rms <= 0.0001 ? 1.0 : 0.9 / rms;
  return List<Offset>.unmodifiable(
    centered.map((knot) => _limitVector(knot * scale, 1.35)),
  );
}

List<Offset> _createLocalEddyKnots(math.Random random) {
  var angle = random.nextDouble() * math.pi * 2;
  return List<Offset>.unmodifiable(
    List<Offset>.generate(_localEddyKnotCount, (index) {
      final reversal = index > 0 && random.nextDouble() < 0.28;
      angle += reversal
          ? (random.nextBool() ? 1 : -1) *
                (0.55 + (random.nextDouble() * 0.38)) *
                math.pi
          : (random.nextDouble() - 0.5) * math.pi * 1.45;
      final magnitude = 0.36 + (random.nextDouble() * 0.88);
      return Offset(math.cos(angle) * magnitude, math.sin(angle) * magnitude);
    }),
  );
}

List<Offset> _createMotionPath({
  required double start,
  required double lifetime,
  required double motionSpeed,
  required double windInfluence,
  required double turbulence,
  required double verticalLift,
  required List<Offset> globalWind,
  required List<Offset> localEddies,
}) {
  final points = <Offset>[Offset.zero];
  var position = Offset.zero;
  for (var index = 0; index < _motionSampleCount; index += 1) {
    final age = (index + 0.5) / _motionSampleCount;
    final globalPhase = _wrapUnit(start + (age * lifetime));
    final sharedWind = _samplePeriodicVectorCurve(globalWind, globalPhase);
    final localWind = _sampleOpenVectorCurve(localEddies, age);
    var velocity = (sharedWind * windInfluence) + (localWind * turbulence);
    velocity = _limitVector(velocity, 1.65);
    position +=
        ((velocity * (motionSpeed / _motionSampleCount)) +
            Offset(0, -verticalLift / _motionSampleCount)) *
        _trajectorySpeedScale;
    points.add(position);
  }
  return List<Offset>.unmodifiable(points);
}

Offset _samplePeriodicVectorCurve(List<Offset> points, double progress) {
  final wrapped = _wrapUnit(progress);
  final scaled = wrapped * points.length;
  final index = scaled.floor() % points.length;
  return _catmullRomOffset(
    points[(index - 1 + points.length) % points.length],
    points[index],
    points[(index + 1) % points.length],
    points[(index + 2) % points.length],
    scaled - scaled.floor(),
  );
}

Offset _sampleOpenVectorCurve(List<Offset> points, double progress) {
  if (points.length == 1) {
    return points.single;
  }
  final normalized = progress.clamp(0.0, 1.0).toDouble();
  final scaled = normalized * (points.length - 1);
  final index = scaled.floor().clamp(0, points.length - 1);
  final nextIndex = (index + 1).clamp(0, points.length - 1);
  return _catmullRomOffset(
    points[(index - 1).clamp(0, points.length - 1)],
    points[index],
    points[nextIndex],
    points[(index + 2).clamp(0, points.length - 1)],
    scaled - scaled.floor(),
  );
}

Offset _catmullRomOffset(
  Offset first,
  Offset second,
  Offset third,
  Offset fourth,
  double amount,
) {
  final squared = amount * amount;
  final cubed = squared * amount;
  const tangentScale = 0.42;
  final firstWeight = (2 * cubed) - (3 * squared) + 1;
  final firstTangentWeight = cubed - (2 * squared) + amount;
  final secondWeight = (-2 * cubed) + (3 * squared);
  final secondTangentWeight = cubed - squared;
  double interpolate(double a, double b, double c, double d) {
    final firstTangent = (c - a) * tangentScale;
    final secondTangent = (d - b) * tangentScale;
    return (b * firstWeight) +
        (firstTangent * firstTangentWeight) +
        (c * secondWeight) +
        (secondTangent * secondTangentWeight);
  }

  return Offset(
    interpolate(first.dx, second.dx, third.dx, fourth.dx),
    interpolate(first.dy, second.dy, third.dy, fourth.dy),
  );
}

Offset _limitVector(Offset vector, double maximumLength) {
  final length = vector.distance;
  if (length <= maximumLength || length == 0) {
    return vector;
  }
  return vector * (maximumLength / length);
}

double _wrapUnit(double value) => value - value.floorToDouble();

double _smoothUnit(double value) {
  final normalized = value.clamp(0.0, 1.0).toDouble();
  return normalized * normalized * (3 - (2 * normalized));
}

double _smootherUnit(double value) {
  final normalized = value.clamp(0.0, 1.0).toDouble();
  return normalized *
      normalized *
      normalized *
      ((normalized * ((normalized * 6) - 15)) + 10);
}

bool _offsetListsEqual(List<Offset> first, List<Offset> second) {
  if (identical(first, second)) {
    return true;
  }
  if (first.length != second.length) {
    return false;
  }
  for (var index = 0; index < first.length; index += 1) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}

List<Color> _createParticlePalette(Color color, Brightness brightness) {
  final source = HSLColor.fromColor(color);
  final saturation = source.saturation.clamp(0.58, 0.92).toDouble();
  final baseLightness = brightness == Brightness.dark
      ? source.lightness.clamp(0.68, 0.84).toDouble()
      : source.lightness.clamp(0.32, 0.52).toDouble();
  Color tone(double lightnessDelta, double saturationDelta) {
    return source
        .withSaturation(
          (saturation + saturationDelta).clamp(0.32, 0.86).toDouble(),
        )
        .withLightness(
          (baseLightness + lightnessDelta).clamp(0.22, 0.9).toDouble(),
        )
        .withAlpha(1)
        .toColor();
  }

  return [tone(0, 0), tone(0.1, -0.04), tone(-0.1, 0.08), tone(0.035, -0.12)];
}

int _stableParticleHash(String value) {
  var hash = 0x811C9DC5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0x7FFFFFFF;
  }
  return hash;
}
