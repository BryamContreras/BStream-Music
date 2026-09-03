import 'dart:math' as math;

import 'package:bstream_music/features/music/presentation/widgets/animated_artwork_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses independent durations within the requested ranges', () {
    const motion = AnimatedArtworkMotion(child: ColoredBox(color: Colors.blue));

    expect(motion.zoomDuration, const Duration(seconds: 28));
    expect(motion.panDuration, const Duration(seconds: 31));
    expect(motion.depthDuration, const Duration(seconds: 35));
    expect(AnimatedArtworkMotion.maxHorizontalPan, 7.0);
    expect(AnimatedArtworkMotion.maxVerticalPan, 4.0);
    expect(AnimatedArtworkMotion.maxTiltXDegrees, 0.3);
    expect(AnimatedArtworkMotion.maxTiltYDegrees, 0.4);
    expect(AnimatedArtworkMotion.maxTiltZDegrees, 0.12);
    expect(AnimatedArtworkMotion.perspectiveDepth, 0.00085);
    expect(AnimatedArtworkMotion.zoomAmount, 0.046);
  });

  testWidgets('uses restrained pixel pan, zoom, and perspective depth', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkMotion(
          identity: 'song-a',
          child: ColoredBox(key: ValueKey('artwork'), color: Colors.blue),
        ),
      ),
    );

    expect(_translationOffset(tester), Offset.zero);
    expect(_transform(tester).transform, Matrix4.identity());

    await tester.pump(const Duration(seconds: 6));

    final translation = _translationOffset(tester);
    final transform = _transform(tester);
    expect(translation.dx.abs(), inInclusiveRange(6.0, 7.0));
    expect(translation.dy.abs(), inInclusiveRange(2.0, 3.0));
    expect(_combinedScale(tester), greaterThan(1.035));
    expect(transform.transform.entry(3, 2), inInclusiveRange(0.0005, 0.0007));
    expect(transform.transform.entry(0, 2).abs(), greaterThan(0.004));
    expect(find.byKey(const ValueKey('artwork')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('each component closes its loop without a seam', (tester) async {
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkMotion(
          identity: 'song-a',
          zoomDuration: Duration(seconds: 8),
          panDuration: Duration(seconds: 8),
          depthDuration: Duration(seconds: 8),
          child: ColoredBox(color: Colors.blue),
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 4));

    final midpointTransform = _transform(tester).transform;
    expect(_combinedScale(tester), inInclusiveRange(1.04, 1.05));
    expect(_translationOffset(tester).distance, lessThan(0.000001));
    expect(midpointTransform.entry(3, 2), closeTo(0.00085, 0.000001));

    await tester.pump(const Duration(seconds: 4));

    _expectNeutral(tester);
  });

  testWidgets('default loops close independently and remain unsynchronized', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkMotion(
          key: ValueKey('zoom-loop'),
          identity: 'song-a',
          child: ColoredBox(color: Colors.blue),
        ),
      ),
    );

    await tester.pump(AnimatedArtworkMotion.defaultZoomDuration);

    // The zoom loop has returned to its seam, while the 31 s pan and 35 s
    // depth loops continue smoothly at their own phases.
    expect(_zoomScale(tester), 1);
    expect(_translationOffset(tester), isNot(Offset.zero));
    expect(_transform(tester).transform, isNot(Matrix4.identity()));

    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkMotion(
          key: ValueKey('pan-loop'),
          identity: 'song-a',
          child: ColoredBox(color: Colors.blue),
        ),
      ),
    );
    await tester.pump(AnimatedArtworkMotion.defaultPanDuration);
    expect(_translationOffset(tester).distance, lessThan(0.000001));
    expect(_zoomScale(tester), greaterThan(1));
    expect(_transform(tester).transform, isNot(Matrix4.identity()));

    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkMotion(
          key: ValueKey('depth-loop'),
          identity: 'song-a',
          child: ColoredBox(color: Colors.blue),
        ),
      ),
    );
    await tester.pump(AnimatedArtworkMotion.defaultDepthDuration);
    expect(_transform(tester).transform, Matrix4.identity());
    expect(_translationOffset(tester), isNot(Offset.zero));
    expect(_zoomScale(tester), greaterThan(1));
  });

  testWidgets('motion caps and crop guard hold on compact artwork', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _TestHost(
        extent: 120,
        child: AnimatedArtworkMotion(
          zoomDuration: Duration(seconds: 8),
          panDuration: Duration(seconds: 8),
          depthDuration: Duration(seconds: 8),
          child: ColoredBox(color: Colors.blue),
        ),
      ),
    );

    // At one eighth of each loop the vertical pan and Y rotation peak.
    await tester.pump(const Duration(seconds: 1));
    var translation = _translationOffset(tester);
    var rotation = _rotationDegrees(_transform(tester).transform);
    expect(translation.dx.abs(), inInclusiveRange(4.6, 5.0));
    expect(translation.dy.abs(), inInclusiveRange(3.75, 4.0));
    expect(rotation.x.abs(), lessThanOrEqualTo(0.3));
    expect(rotation.y.abs(), inInclusiveRange(0.375, 0.4));
    expect(rotation.z.abs(), lessThanOrEqualTo(0.12));

    // At one quarter the horizontal pan, X rotation, and tiny Z rotation peak.
    await tester.pump(const Duration(seconds: 1));
    translation = _translationOffset(tester);
    rotation = _rotationDegrees(_transform(tester).transform);
    expect(translation.dx.abs(), inInclusiveRange(6.58, 7.0));
    expect(translation.dy.abs(), lessThan(0.000001));
    expect(rotation.x.abs(), inInclusiveRange(0.282, 0.3));
    expect(rotation.y.abs(), lessThan(0.000001));
    expect(rotation.z.abs(), inInclusiveRange(0.112, 0.12));
    expect(_coverageScale(tester), greaterThan(1.08));
    expect(
      _combinedScale(tester),
      greaterThanOrEqualTo(1 + (2 * translation.dx.abs() / 120)),
    );
  });

  testWidgets('is static when disabled', (tester) async {
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkMotion(
          enabled: false,
          child: ColoredBox(color: Colors.blue),
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 12));

    _expectNeutral(tester);
  });

  testWidgets('playback pause freezes every loop and resumes its same phase', (
    tester,
  ) async {
    var isPlaying = true;
    late StateSetter update;
    await tester.pumpWidget(
      _TestHost(
        child: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AnimatedArtworkMotion(
              isPlaying: isPlaying,
              identity: 'song-a',
              child: const ColoredBox(color: Colors.blue),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 6));

    final phaseTranslation = _translationOffset(tester);
    final phaseDepth = List<double>.of(_transform(tester).transform.storage);
    final phaseCoverage = _coverageScale(tester);
    final phaseZoom = _zoomScale(tester);
    expect(phaseTranslation, isNot(Offset.zero));

    update(() => isPlaying = false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 12));

    expect(_translationOffset(tester), phaseTranslation);
    expect(_transform(tester).transform.storage, orderedEquals(phaseDepth));
    expect(_coverageScale(tester), phaseCoverage);
    expect(_zoomScale(tester), phaseZoom);

    update(() => isPlaying = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(_translationOffset(tester), isNot(phaseTranslation));
    expect(
      _transform(tester).transform.storage,
      isNot(orderedEquals(phaseDepth)),
    );
  });

  testWidgets('respects the reduced motion accessibility preference', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _TestHost(
        disableAnimations: true,
        child: AnimatedArtworkMotion(child: ColoredBox(color: Colors.blue)),
      ),
    );

    await tester.pump(const Duration(seconds: 12));

    _expectNeutral(tester);
  });

  testWidgets('pauses at the neutral pose outside an enabled TickerMode', (
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
              child: const AnimatedArtworkMotion(
                child: ColoredBox(color: Colors.blue),
              ),
            );
          },
        ),
      ),
    );

    await tester.pump(const Duration(seconds: 6));
    expect(_translationOffset(tester), Offset.zero);
    expect(_transform(tester).transform, Matrix4.identity());

    update(() => tickerEnabled = true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(_translationOffset(tester), isNot(Offset.zero));

    update(() => tickerEnabled = false);
    await tester.pump();
    _expectNeutral(tester);
  });

  testWidgets('stops while the application is not active', (tester) async {
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkMotion(child: ColoredBox(color: Colors.blue)),
      ),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(_translationOffset(tester), isNot(Offset.zero));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    _expectNeutral(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(_translationOffset(tester), isNot(Offset.zero));
  });

  testWidgets('keeps child interaction in the original layout coordinates', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _TestHost(
        child: SizedBox(
          width: 160,
          height: 160,
          child: AnimatedArtworkMotion(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => taps += 1,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 6));

    expect(_translation(tester).transformHitTests, isFalse);
    expect(_transform(tester).transformHitTests, isFalse);
    await tester.tapAt(tester.getCenter(find.byType(AnimatedArtworkMotion)));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('does not rebuild artwork on animation ticks', (tester) async {
    var artworkBuilds = 0;
    await tester.pumpWidget(
      _TestHost(
        child: AnimatedArtworkMotion(
          child: Builder(
            builder: (context) {
              artworkBuilds += 1;
              return const ColoredBox(color: Colors.blue);
            },
          ),
        ),
      ),
    );

    expect(artworkBuilds, 1);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));
    expect(artworkBuilds, 1);
    expect(
      find.descendant(
        of: find.byType(AnimatedArtworkMotion),
        matching: find.byType(RepaintBoundary),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('a new identity restarts from a neutral pose', (tester) async {
    var identity = 'song-a';
    late StateSetter update;
    await tester.pumpWidget(
      _TestHost(
        child: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AnimatedArtworkMotion(
              identity: identity,
              child: const ColoredBox(color: Colors.blue),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(_translationOffset(tester), isNot(Offset.zero));

    update(() => identity = 'song-b');
    await tester.pump();

    _expectNeutral(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(_translationOffset(tester), isNot(Offset.zero));
  });

  testWidgets('clips the moving cover to the requested corner radius', (
    tester,
  ) async {
    const radius = BorderRadius.all(Radius.circular(28));
    await tester.pumpWidget(
      const _TestHost(
        child: AnimatedArtworkMotion(
          borderRadius: radius,
          child: ColoredBox(color: Colors.blue),
        ),
      ),
    );

    expect(
      tester.widget<ClipRRect>(find.byType(ClipRRect)).borderRadius,
      radius,
    );
  });
}

Transform _translation(WidgetTester tester) => tester.widget<Transform>(
  find.byKey(const ValueKey('animated-artwork-translation')),
);

Offset _translationOffset(WidgetTester tester) {
  final matrix = _translation(tester).transform;
  return Offset(matrix.entry(0, 3), matrix.entry(1, 3));
}

Transform _transform(WidgetTester tester) => tester.widget<Transform>(
  find.byKey(const ValueKey('animated-artwork-depth-transform')),
);

double _coverageScale(WidgetTester tester) => tester
    .widget<Transform>(
      find.byKey(const ValueKey('animated-artwork-coverage-scale')),
    )
    .transform
    .entry(0, 0);

double _zoomScale(WidgetTester tester) => tester
    .widget<Transform>(
      find.byKey(const ValueKey('animated-artwork-zoom-scale')),
    )
    .transform
    .entry(0, 0);

double _combinedScale(WidgetTester tester) =>
    _coverageScale(tester) * _zoomScale(tester);

({double x, double y, double z}) _rotationDegrees(Matrix4 matrix) {
  const radiansToDegrees = 180 / 3.1415926535897932;
  final y = math.asin(matrix.entry(0, 2).clamp(-1.0, 1.0));
  final x = math.atan2(-matrix.entry(1, 2), matrix.entry(2, 2));
  final z = math.atan2(-matrix.entry(0, 1), matrix.entry(0, 0));
  return (
    x: x * radiansToDegrees,
    y: y * radiansToDegrees,
    z: z * radiansToDegrees,
  );
}

void _expectNeutral(WidgetTester tester) {
  expect(_translationOffset(tester), Offset.zero);
  expect(_transform(tester).transform, Matrix4.identity());
  expect(_coverageScale(tester), 1);
  expect(_zoomScale(tester), 1);
}

class _TestHost extends StatelessWidget {
  const _TestHost({
    required this.child,
    this.disableAnimations = false,
    this.extent = 320,
  });

  final Widget child;
  final bool disableAnimations;
  final double extent;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Scaffold(
          body: Center(
            child: SizedBox.square(dimension: extent, child: child),
          ),
        ),
      ),
    );
  }
}
