import 'dart:math' as math;

import 'package:bstream_music/features/music/presentation/widgets/animated_artwork_particles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses restrained defaults for a decorative particle field', () {
    const particles = AnimatedArtworkParticles(
      color: Colors.blue,
      identity: 'song-a',
    );

    expect(
      particles.cycleDuration,
      AnimatedArtworkParticles.defaultCycleDuration,
    );
    expect(
      particles.particleCount,
      AnimatedArtworkParticles.defaultParticleCount,
    );
    expect(
      AnimatedArtworkParticles.defaultParticleCount,
      greaterThanOrEqualTo(28),
    );
    expect(particles.enabled, isTrue);
    expect(particles.isPlaying, isTrue);
    expect(particles.borderRadius, BorderRadius.zero);
  });

  testWidgets('derives the same particle field from the same identity', (
    tester,
  ) async {
    Future<List<Object?>> specsFor(String identity, Key key) async {
      await tester.pumpWidget(
        _TestHost(
          child: AnimatedArtworkParticles(
            key: key,
            color: Colors.blue,
            identity: identity,
            isPlaying: false,
          ),
        ),
      );
      await tester.pump();
      return List<Object?>.of(_painter(tester).particleSpecs);
    }

    final first = await specsFor('song-a', const ValueKey('first-field'));
    final repeated = await specsFor('song-a', const ValueKey('repeated-field'));
    final different = await specsFor(
      'song-b',
      const ValueKey('different-field'),
    );

    expect(first, hasLength(AnimatedArtworkParticles.defaultParticleCount));
    expect(repeated, orderedEquals(first));
    expect(different, isNot(orderedEquals(first)));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'default field is dense, fine-grained, and mixes depth treatments',
    (tester) async {
      await tester.pumpWidget(
        const _TestHost(
          child: AnimatedArtworkParticles(
            color: Colors.blue,
            identity: 'dense-depth-field',
            isPlaying: false,
          ),
        ),
      );
      final specs = _painter(tester).particleSpecs;

      expect(specs, hasLength(AnimatedArtworkParticles.defaultParticleCount));
      expect(specs.length, greaterThanOrEqualTo(28));
      expect(
        specs.every(
          (particle) => particle.radius >= 0.002 && particle.radius <= 0.0075,
        ),
        isTrue,
        reason: 'Particles should remain small even on a full-width cover.',
      );

      final blurTiers = specs.map((particle) => particle.blurTier).toSet();
      expect(blurTiers, contains(ArtworkParticleBlurTier.sharp));
      expect(
        blurTiers.any((tier) => tier != ArtworkParticleBlurTier.sharp),
        isTrue,
        reason: 'Sharp particles must be mixed with softly defocused ones.',
      );
      expect(blurTiers.length, greaterThanOrEqualTo(2));

      final activeCounts = <int>[
        for (var sample = 1; sample < 20; sample += 1)
          specs.where((particle) {
            final progress = sample / 20;
            var elapsed = progress - particle.start;
            if (elapsed < 0) {
              elapsed += 1;
            }
            return elapsed > 0 && elapsed < particle.lifetime;
          }).length,
      ];
      final meanActiveCount =
          activeCounts.reduce((first, second) => first + second) /
          activeCounts.length;
      expect(
        meanActiveCount,
        greaterThanOrEqualTo(5),
        reason: 'The denser field should not be only a larger dormant pool.',
      );
      expect(
        activeCounts.reduce((a, b) => a > b ? a : b),
        greaterThanOrEqualTo(7),
      );
    },
  );

  testWidgets('varies the sampled motion field across particles', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkParticles(
          color: Colors.blue,
          identity: 'varied-wind-field',
          isPlaying: false,
        ),
      ),
    );
    final specs = _painter(tester).particleSpecs;
    final motionSpeeds = specs.map((particle) => particle.motionSpeed).toSet();
    final windInfluences = specs
        .map((particle) => particle.windInfluence)
        .toSet();
    final turbulence = specs.map((particle) => particle.turbulence).toSet();
    final verticalLift = specs.map((particle) => particle.verticalLift).toSet();

    expect(motionSpeeds.length, greaterThan(6));
    expect(windInfluences.length, greaterThan(6));
    expect(turbulence.length, greaterThan(6));
    expect(verticalLift.length, greaterThan(6));
    expect(
      specs.every(
        (particle) =>
            particle.motionSpeed > 0 &&
            particle.windInfluence > 0 &&
            particle.turbulence > 0 &&
            particle.verticalLift > 0 &&
            particle.motionPath.length >= 12 &&
            particle.motionPath.first == Offset.zero &&
            particle.motionPath.last != Offset.zero,
      ),
      isTrue,
      reason: 'Each mote needs a real, independently sampled motion path.',
    );
  });

  testWidgets('sampled paths travel visibly far and quickly', (tester) async {
    final fields = await _motionFields(tester);
    final trajectories = <_TrajectoryMetrics>[
      for (final field in fields)
        for (final particle in field.particleSpecs)
          _measureTrajectory(field, particle),
    ];
    final medianPath = _median(
      trajectories.map((trajectory) => trajectory.pathLength),
    );
    final medianSpan = _median(
      trajectories.map((trajectory) => trajectory.spatialSpan),
    );
    final medianSpeed = _median(
      trajectories.map((trajectory) => trajectory.meanSpeed),
    );
    final path95 = _percentile(
      trajectories.map((trajectory) => trajectory.pathLength),
      0.95,
    );
    final span95 = _percentile(
      trajectories.map((trajectory) => trajectory.spatialSpan),
      0.95,
    );
    final speed95 = _percentile(
      trajectories.map((trajectory) => trajectory.meanSpeed),
      0.95,
    );
    expect(medianPath, greaterThanOrEqualTo(0.215));
    expect(medianSpan, greaterThanOrEqualTo(0.14));
    expect(medianSpeed, greaterThanOrEqualTo(0.07));
    expect(path95, lessThan(0.52));
    expect(span95, lessThan(0.34));
    expect(speed95, lessThan(0.22));
    expect(
      _fractionWhere(
        trajectories,
        (trajectory) => trajectory.meanSpeed >= 0.055,
      ),
      greaterThanOrEqualTo(0.75),
      reason: 'The aggregate must not hide a mostly static particle tail.',
    );
  });

  testWidgets('most paths make several meaningful turns and speed changes', (
    tester,
  ) async {
    final trajectories = <_TrajectoryMetrics>[
      for (final field in await _motionFields(tester))
        for (final particle in field.particleSpecs)
          _measureTrajectory(field, particle),
    ];
    expect(
      _fractionWhere(
        trajectories,
        (trajectory) => trajectory.directionChanges >= 3,
      ),
      greaterThanOrEqualTo(0.70),
      reason:
          'Tiny sinusoidal wiggles do not count as useful direction changes.',
    );
    expect(
      _fractionWhere(
        trajectories,
        (trajectory) => trajectory.accelerationChanges >= 4,
      ),
      greaterThanOrEqualTo(0.60),
      reason: 'Particles should repeatedly accelerate and decelerate visibly.',
    );
  });

  testWidgets('local disorder stays coupled to a coherent global wind field', (
    tester,
  ) async {
    for (final field in await _motionFields(tester)) {
      final trajectories = [
        for (final particle in field.particleSpecs)
          _measureTrajectory(field, particle),
      ];
      final uniqueSignatures = trajectories
          .map((trajectory) => trajectory.directionSignature)
          .toSet();
      final correlations = <double>[];
      for (var first = 0; first < trajectories.length; first += 1) {
        for (
          var second = first + 1;
          second < trajectories.length;
          second += 1
        ) {
          correlations.add(
            _correlation(
              trajectories[first].horizontalVelocities,
              trajectories[second].horizontalVelocities,
            ).abs(),
          );
        }
      }
      final coherence = [
        for (var sample = 1; sample < 48; sample += 1)
          _coherenceAtProgress(field, sample / 48),
      ].where((value) => value != null).cast<double>().toList();
      expect(
        uniqueSignatures.length / trajectories.length,
        greaterThanOrEqualTo(0.85),
        reason: 'Particles must not reuse a synchronized direction script.',
      );
      expect(_median(correlations), lessThan(0.55));
      expect(coherence.length, greaterThanOrEqualTo(32));
      expect(
        _median(coherence),
        inInclusiveRange(0.48, 0.82),
        reason: 'There should be shared wind without lockstep motion.',
      );
      expect(
        _fractionWhere(coherence, (value) => value >= 0.24),
        greaterThanOrEqualTo(0.85),
        reason: 'The common wind should be legible through most of the cycle.',
      );
      expect(
        _fractionWhere(coherence, (value) => value > 0.94),
        lessThanOrEqualTo(0.08),
        reason: 'Independent turbulence must remain visible.',
      );
    }
  });

  testWidgets('a particle stays position and velocity continuous at wrap', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkParticles(
          color: Colors.blue,
          identity: 'wrap-continuity-field',
          isPlaying: false,
        ),
      ),
    );
    final painter = _painter(tester);
    const progressDelta = 0.0002;
    final particle = painter.particleSpecs.firstWhere(
      (candidate) =>
          candidate.start + candidate.lifetime > 1 + (progressDelta * 3),
    );

    final ageBefore2 = _circularAge(particle, 1 - (progressDelta * 2));
    final ageBefore = _circularAge(particle, 1 - progressDelta);
    final ageAfter = _circularAge(particle, progressDelta);
    final ageAfter2 = _circularAge(particle, progressDelta * 2);
    expect(ageAfter, greaterThan(ageBefore));
    expect(
      ageAfter - ageBefore,
      closeTo((progressDelta * 2) / particle.lifetime, 0.000000001),
    );

    Offset position(double age) =>
        painter.positionForAge(particle, age, _trajectoryCanvasSize);
    final before2 = position(ageBefore2);
    final before = position(ageBefore);
    final after = position(ageAfter);
    final after2 = position(ageAfter2);
    final velocityBefore = (before - before2) / progressDelta;
    final velocityAcrossWrap = (after - before) / (progressDelta * 2);
    final velocityAfter = (after2 - after) / progressDelta;
    final neighborVelocity = (velocityBefore + velocityAfter) / 2;
    final velocityScale = math.max(neighborVelocity.distance, 1);

    expect(
      (after - before).distance / _trajectoryCanvasSize.shortestSide,
      lessThan(0.002),
      reason: 'The cycle boundary must not teleport a living particle.',
    );
    expect(
      (velocityAcrossWrap - neighborVelocity).distance / velocityScale,
      lessThan(0.035),
      reason: 'Velocity must cross the cycle seam without a visible kink.',
    );
    expect(
      (velocityAfter - velocityBefore).distance / velocityScale,
      lessThan(0.08),
    );
  });

  testWidgets('advances on deterministic pumped time while playing', (
    tester,
  ) async {
    const cycle = Duration(seconds: 8);
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkParticles(
          color: Colors.blue,
          identity: 'song-a',
          cycleDuration: cycle,
        ),
      ),
    );

    expect(_progress(tester), 0);

    await tester.pump(const Duration(seconds: 2));

    expect(_progress(tester), closeTo(0.25, 0.000001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback pause freezes the field and resumes its same phase', (
    tester,
  ) async {
    var isPlaying = true;
    late StateSetter update;
    await tester.pumpWidget(
      _TestHost(
        child: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AnimatedArtworkParticles(
              color: Colors.blue,
              identity: 'song-a',
              isPlaying: isPlaying,
              cycleDuration: const Duration(seconds: 8),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    final pausedPhase = _progress(tester);
    expect(pausedPhase, closeTo(0.25, 0.000001));

    update(() => isPlaying = false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 12));

    expect(_progress(tester), closeTo(pausedPhase, 0.000001));

    update(() => isPlaying = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(_progress(tester), closeTo(0.375, 0.000001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled particles reset to neutral and stop ticking', (
    tester,
  ) async {
    var enabled = true;
    late StateSetter update;
    await tester.pumpWidget(
      _TestHost(
        child: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AnimatedArtworkParticles(
              color: Colors.blue,
              identity: 'song-a',
              enabled: enabled,
              cycleDuration: const Duration(seconds: 8),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(_progress(tester), closeTo(0.25, 0.000001));

    update(() => enabled = false);
    await tester.pump();

    expect(_particleRoot, findsNothing);
    expect(_particlePaint, findsNothing);
    await tester.pump(const Duration(seconds: 12));
    expect(_particleRoot, findsNothing);
    expect(_particlePaint, findsNothing);

    update(() => enabled = true);
    await tester.pump();
    expect(_progress(tester), 0);
    await tester.pump(const Duration(seconds: 1));
    expect(_progress(tester), closeTo(0.125, 0.000001));
  });

  testWidgets('reduced motion resets and suppresses the particle cycle', (
    tester,
  ) async {
    const particles = AnimatedArtworkParticles(
      color: Colors.blue,
      identity: 'song-a',
      cycleDuration: Duration(seconds: 8),
    );

    await tester.pumpWidget(const _TestHost(child: particles));
    await tester.pump(const Duration(seconds: 2));
    expect(_progress(tester), closeTo(0.25, 0.000001));

    await tester.pumpWidget(
      const _TestHost(disableAnimations: true, child: particles),
    );
    await tester.pump();

    expect(_particleRoot, findsNothing);
    expect(_particlePaint, findsNothing);
    await tester.pump(const Duration(seconds: 12));
    expect(_particleRoot, findsNothing);
    expect(_particlePaint, findsNothing);

    await tester.pumpWidget(const _TestHost(child: particles));
    await tester.pump();
    expect(_progress(tester), 0);
    await tester.pump(const Duration(seconds: 1));
    expect(_progress(tester), closeTo(0.125, 0.000001));
  });

  testWidgets('pauses at neutral outside an enabled TickerMode', (
    tester,
  ) async {
    var tickerEnabled = false;
    late StateSetter update;
    await tester.pumpWidget(
      _TestHost(
        child: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TickerMode(
              enabled: tickerEnabled,
              child: const AnimatedArtworkParticles(
                color: Colors.blue,
                identity: 'song-a',
                cycleDuration: Duration(seconds: 8),
              ),
            );
          },
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 4));
    expect(_particleRoot, findsNothing);
    expect(_particlePaint, findsNothing);

    update(() => tickerEnabled = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(_progress(tester), closeTo(0.25, 0.000001));

    update(() => tickerEnabled = false);
    await tester.pump();
    expect(_particleRoot, findsNothing);
    expect(_particlePaint, findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(_particleRoot, findsNothing);
    expect(_particlePaint, findsNothing);
  });

  testWidgets('stops while the application is not active', (tester) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkParticles(
          color: Colors.blue,
          identity: 'song-a',
          cycleDuration: Duration(seconds: 8),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(_progress(tester), closeTo(0.25, 0.000001));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(_particleRoot, findsNothing);
    expect(_particlePaint, findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(_particleRoot, findsNothing);
    expect(_particlePaint, findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(_progress(tester), 0);
    await tester.pump(const Duration(seconds: 1));
    expect(_progress(tester), closeTo(0.125, 0.000001));
  });

  testWidgets('a new identity regenerates the field and restarts its cycle', (
    tester,
  ) async {
    var identity = 'song-a';
    late StateSetter update;
    await tester.pumpWidget(
      _TestHost(
        child: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AnimatedArtworkParticles(
              color: Colors.blue,
              identity: identity,
              cycleDuration: const Duration(seconds: 8),
            );
          },
        ),
      ),
    );
    final firstSpecs = List<Object?>.of(_painter(tester).particleSpecs);
    await tester.pump(const Duration(seconds: 2));
    expect(_progress(tester), closeTo(0.25, 0.000001));

    update(() => identity = 'song-b');
    await tester.pump();

    expect(_progress(tester), 0);
    expect(
      List<Object?>.of(_painter(tester).particleSpecs),
      isNot(orderedEquals(firstSpecs)),
    );

    await tester.pump(const Duration(seconds: 1));
    expect(_progress(tester), closeTo(0.125, 0.000001));
  });

  testWidgets('changing particle count regenerates the field from phase zero', (
    tester,
  ) async {
    var particleCount = AnimatedArtworkParticles.defaultParticleCount;
    late StateSetter update;
    await tester.pumpWidget(
      _TestHost(
        child: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AnimatedArtworkParticles(
              color: Colors.blue,
              identity: 'particle-count-field',
              particleCount: particleCount,
              cycleDuration: const Duration(seconds: 8),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(_progress(tester), closeTo(0.25, 0.000001));
    expect(_painter(tester).particleSpecs, hasLength(particleCount));

    update(() => particleCount += 7);
    await tester.pump();

    expect(_progress(tester), 0);
    expect(_painter(tester).particleSpecs, hasLength(particleCount));
    await tester.pump(const Duration(seconds: 1));
    expect(_progress(tester), closeTo(0.125, 0.000001));
  });

  testWidgets('particles fade in and out over their normalized lifetime', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkParticles(
          color: Colors.blue,
          identity: 'song-a',
          isPlaying: false,
        ),
      ),
    );
    final painter = _painter(tester);

    expect(painter.opacityForAge(-0.01), 0);
    expect(painter.opacityForAge(0), 0);
    expect(painter.opacityForAge(0.08), greaterThan(0));
    expect(painter.opacityForAge(0.08), lessThan(painter.opacityForAge(0.30)));
    expect(painter.opacityForAge(0.50), greaterThan(0));
    expect(painter.opacityForAge(0.92), lessThan(painter.opacityForAge(0.70)));
    expect(painter.opacityForAge(1), 0);
    expect(painter.opacityForAge(1.01), 0);
  });

  testWidgets('is clipped, non-interactive, and excluded from semantics', (
    tester,
  ) async {
    const radius = BorderRadius.all(Radius.circular(28));
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkParticles(
          color: Colors.blue,
          identity: 'song-a',
          isPlaying: false,
          borderRadius: radius,
        ),
      ),
    );

    final root = find.byKey(const ValueKey('animated-artwork-particles'));
    final paint = find.byKey(
      const ValueKey('animated-artwork-particles-paint'),
    );
    expect(root, findsOneWidget);
    expect(paint, findsOneWidget);
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(of: paint, matching: find.byType(IgnorePointer))
                .first,
          )
          .ignoring,
      isTrue,
    );
    expect(
      tester
          .widget<ExcludeSemantics>(
            find
                .ancestor(of: paint, matching: find.byType(ExcludeSemantics))
                .first,
          )
          .excluding,
      isTrue,
    );
    expect(
      tester
          .widget<ClipRRect>(
            find.ancestor(of: paint, matching: find.byType(ClipRRect)).first,
          )
          .borderRadius,
      radius,
    );
    expect(
      _painter(tester).particleSpecs,
      hasLength(AnimatedArtworkParticles.defaultParticleCount),
    );
    expect(tester.takeException(), isNull);
  });
}

const _trajectoryCanvasSize = Size(320, 480);
const _trajectorySampleCount = 96;

Future<List<ArtworkParticlePainter>> _motionFields(WidgetTester tester) async {
  final fields = <ArtworkParticlePainter>[];
  for (final identity in const [
    'motion-field-alpha',
    'motion-field-beta',
    'motion-field-gamma',
  ]) {
    await tester.pumpWidget(
      _TestHost(
        child: AnimatedArtworkParticles(
          key: ValueKey(identity),
          color: Colors.blue,
          identity: identity,
          isPlaying: false,
        ),
      ),
    );
    await tester.pump();
    fields.add(_painter(tester));
  }
  return fields;
}

_TrajectoryMetrics _measureTrajectory(
  ArtworkParticlePainter painter,
  ArtworkParticleSpec particle,
) {
  final positions = [
    for (var sample = 0; sample <= _trajectorySampleCount; sample += 1)
      painter.positionForAge(
        particle,
        sample / _trajectorySampleCount,
        _trajectoryCanvasSize,
      ),
  ];
  final shortestSide = _trajectoryCanvasSize.shortestSide;
  final lifetimeSeconds =
      (AnimatedArtworkParticles.defaultCycleDuration.inMicroseconds /
          Duration.microsecondsPerSecond) *
      particle.lifetime;
  final stepSeconds = lifetimeSeconds / _trajectorySampleCount;
  final speeds = <double>[];
  final horizontalVelocities = <double>[];
  var pathLength = 0.0;
  for (var index = 1; index < positions.length; index += 1) {
    final delta = positions[index] - positions[index - 1];
    final normalizedDistance = delta.distance / shortestSide;
    pathLength += normalizedDistance;
    speeds.add(normalizedDistance / stepSeconds);
    horizontalVelocities.add((delta.dx / shortestSide) / stepSeconds);
  }

  final minX = positions.map((position) => position.dx).reduce(math.min);
  final maxX = positions.map((position) => position.dx).reduce(math.max);
  final minY = positions.map((position) => position.dy).reduce(math.min);
  final maxY = positions.map((position) => position.dy).reduce(math.max);
  final directionChanges = _meaningfulCourseChanges(
    positions,
    shortestSide: shortestSide,
    minimumTravel: 0.025,
    minimumTurn: math.pi / 5,
  );
  final accelerationChanges = _coarseAccelerationChanges(
    positions,
    shortestSide: shortestSide,
    lifetimeSeconds: lifetimeSeconds,
    minimumVelocityChange: 0.057,
  );
  final signature = <String>[];
  const signatureBuckets = 24;
  final samplesPerBucket = _trajectorySampleCount ~/ signatureBuckets;
  for (var bucket = 0; bucket < signatureBuckets; bucket += 1) {
    final start = positions[bucket * samplesPerBucket];
    final end = positions[(bucket + 1) * samplesPerBucket];
    final normalizedDelta = (end.dx - start.dx) / shortestSide;
    signature.add(
      normalizedDelta.abs() < 0.003
          ? '0'
          : normalizedDelta.isNegative
          ? '-'
          : '+',
    );
  }

  return _TrajectoryMetrics(
    pathLength: pathLength,
    spatialSpan:
        math.sqrt(math.pow(maxX - minX, 2) + math.pow(maxY - minY, 2)) /
        shortestSide,
    meanSpeed: pathLength / lifetimeSeconds,
    directionChanges: directionChanges,
    accelerationChanges: accelerationChanges,
    directionSignature: signature.join(),
    horizontalVelocities: horizontalVelocities,
  );
}

int _meaningfulCourseChanges(
  List<Offset> positions, {
  required double shortestSide,
  required double minimumTravel,
  required double minimumTurn,
}) {
  Offset? referenceDirection;
  var travelSinceTurn = 0.0;
  var changes = 0;
  for (var index = 1; index < positions.length; index += 1) {
    final delta = positions[index] - positions[index - 1];
    final distance = delta.distance / shortestSide;
    if (distance <= 0.000001) {
      continue;
    }
    final direction = delta / delta.distance;
    referenceDirection ??= direction;
    travelSinceTurn += distance;
    final cosine =
        (referenceDirection.dx * direction.dx) +
        (referenceDirection.dy * direction.dy);
    final angle = math.acos(cosine.clamp(-1.0, 1.0));
    if (travelSinceTurn >= minimumTravel && angle >= minimumTurn) {
      changes += 1;
      referenceDirection = direction;
      travelSinceTurn = 0;
    }
  }
  return changes;
}

int _coarseAccelerationChanges(
  List<Offset> positions, {
  required double shortestSide,
  required double lifetimeSeconds,
  required double minimumVelocityChange,
}) {
  const buckets = 12;
  final samplesPerBucket = _trajectorySampleCount ~/ buckets;
  final bucketSeconds = lifetimeSeconds / buckets;
  final velocities = <Offset>[];
  for (var bucket = 0; bucket < buckets; bucket += 1) {
    final start = positions[bucket * samplesPerBucket];
    final end = positions[(bucket + 1) * samplesPerBucket];
    velocities.add((end - start) / shortestSide / bucketSeconds);
  }
  var changes = 0;
  for (var index = 1; index < velocities.length; index += 1) {
    if ((velocities[index] - velocities[index - 1]).distance >=
        minimumVelocityChange) {
      changes += 1;
    }
  }
  return changes;
}

double? _coherenceAtProgress(ArtworkParticlePainter painter, double progress) {
  const ageDelta = 0.006;
  final directions = <Offset>[];
  for (final particle in painter.particleSpecs) {
    var elapsed = progress - particle.start;
    if (elapsed < 0) {
      elapsed += 1;
    }
    if (elapsed <= 0 || elapsed >= particle.lifetime) {
      continue;
    }
    final age = elapsed / particle.lifetime;
    if (age <= ageDelta || age >= 1 - ageDelta) {
      continue;
    }
    final before = painter.positionForAge(
      particle,
      age - ageDelta,
      _trajectoryCanvasSize,
    );
    final after = painter.positionForAge(
      particle,
      age + ageDelta,
      _trajectoryCanvasSize,
    );
    final velocity = after - before;
    if (velocity.distance <= 0.0001) {
      continue;
    }
    directions.add(velocity / velocity.distance);
  }
  if (directions.length < 5) {
    return null;
  }
  final resultant = directions.fold(Offset.zero, (sum, item) => sum + item);
  return resultant.distance / directions.length;
}

double _circularAge(ArtworkParticleSpec particle, double progress) {
  var elapsed = progress - particle.start;
  if (elapsed < 0) {
    elapsed += 1;
  }
  assert(elapsed >= 0 && elapsed <= particle.lifetime);
  return elapsed / particle.lifetime;
}

double _correlation(List<double> first, List<double> second) {
  assert(first.length == second.length);
  final firstMean = first.reduce((a, b) => a + b) / first.length;
  final secondMean = second.reduce((a, b) => a + b) / second.length;
  var numerator = 0.0;
  var firstVariance = 0.0;
  var secondVariance = 0.0;
  for (var index = 0; index < first.length; index += 1) {
    final firstDelta = first[index] - firstMean;
    final secondDelta = second[index] - secondMean;
    numerator += firstDelta * secondDelta;
    firstVariance += firstDelta * firstDelta;
    secondVariance += secondDelta * secondDelta;
  }
  final denominator = math.sqrt(firstVariance * secondVariance);
  return denominator <= 0.000000001 ? 0 : numerator / denominator;
}

double _median(Iterable<double> values) {
  final sorted = values.toList(growable: false)..sort();
  assert(sorted.isNotEmpty);
  final midpoint = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[midpoint]
      : (sorted[midpoint - 1] + sorted[midpoint]) / 2;
}

double _percentile(Iterable<double> values, double percentile) {
  assert(percentile >= 0 && percentile <= 1);
  final sorted = values.toList(growable: false)..sort();
  assert(sorted.isNotEmpty);
  final index = (sorted.length - 1) * percentile;
  final lower = index.floor();
  final upper = index.ceil();
  if (lower == upper) {
    return sorted[lower];
  }
  return sorted[lower] + ((sorted[upper] - sorted[lower]) * (index - lower));
}

double _fractionWhere<T>(Iterable<T> values, bool Function(T value) predicate) {
  final materialized = values.toList(growable: false);
  assert(materialized.isNotEmpty);
  return materialized.where(predicate).length / materialized.length;
}

class _TrajectoryMetrics {
  const _TrajectoryMetrics({
    required this.pathLength,
    required this.spatialSpan,
    required this.meanSpeed,
    required this.directionChanges,
    required this.accelerationChanges,
    required this.directionSignature,
    required this.horizontalVelocities,
  });

  final double pathLength;
  final double spatialSpan;
  final double meanSpeed;
  final int directionChanges;
  final int accelerationChanges;
  final String directionSignature;
  final List<double> horizontalVelocities;
}

ArtworkParticlePainter _painter(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.byKey(const ValueKey('animated-artwork-particles-paint')),
  );
  return paint.painter! as ArtworkParticlePainter;
}

double _progress(WidgetTester tester) => _painter(tester).progress.value;

final Finder _particleRoot = find.byKey(
  const ValueKey('animated-artwork-particles'),
);

final Finder _particlePaint = find.byKey(
  const ValueKey('animated-artwork-particles-paint'),
);

class _TestHost extends StatelessWidget {
  const _TestHost({required this.child, this.disableAnimations = false});

  final Widget child;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: Center(child: SizedBox.square(dimension: 320, child: child)),
        ),
      ),
    );
  }
}
