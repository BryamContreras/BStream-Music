import 'package:bstream_music/features/music/presentation/widgets/playback_progress_line.dart';
import 'package:bstream_music/features/music/presentation/widgets/decorative_progress_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('instrumental progress can retain its linear 540 ms tween', (
    tester,
  ) async {
    var painted = 0.0;
    Widget progress(double value) => MaterialApp(
      home: DecorativeProgressTransition(
        value: value,
        duration: const Duration(milliseconds: 540),
        curve: Curves.linear,
        builder: (context, value, _) {
          painted = value;
          return const SizedBox();
        },
      ),
    );

    await tester.pumpWidget(progress(0.2));
    expect(painted, 0.2);
    await tester.pumpWidget(progress(0.8));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 270));
    expect(painted, closeTo(0.5, 0.001));
    // The throttled clock deliberately parks between vsyncs, so advance real
    // display intervals instead of treating an idle frame as tween completion.
    for (var frame = 0; frame < 18; frame++) {
      await tester.pump(const Duration(microseconds: 16667));
    }
    expect(painted, closeTo(0.8, 0.001));
  });

  testWidgets('animates progress with a paint transform instead of relayout', (
    tester,
  ) async {
    Future<void> pumpLine(double value) {
      return tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 200,
              child: PlaybackProgressLine(
                value: value,
                color: const Color(0xFF35C76F),
                height: 6,
                progressAnimationKey: const ValueKey('progress-animation'),
                fillKey: const ValueKey('progress-fill'),
              ),
            ),
          ),
        ),
      );
    }

    await pumpLine(0.2);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(FractionallySizedBox), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('progress-fill'))),
      const Size(200, 6),
    );
    var transform = tester.widget<Transform>(find.byType(Transform));
    expect(transform.alignment, Alignment.centerLeft);
    expect(transform.transformHitTests, isFalse);
    expect(transform.transform.storage[0], closeTo(0.2, 0.0001));

    await pumpLine(0.8);
    await tester.pump(const Duration(milliseconds: 110));

    transform = tester.widget<Transform>(find.byType(Transform));
    expect(transform.transform.storage[0], inInclusiveRange(0.2, 0.8));
    expect(
      tester.getSize(find.byKey(const ValueKey('progress-fill'))),
      const Size(200, 6),
    );

    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    transform = tester.widget<Transform>(find.byType(Transform));
    expect(transform.transform.storage[0], closeTo(0.8, 0.0001));
  });

  testWidgets('keeps fill color and progress semantics unchanged', (
    tester,
  ) async {
    const fillColor = Color(0xFF4CA7FF);
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 160,
            child: PlaybackProgressLine(
              value: 0.375,
              color: fillColor,
              fillKey: ValueKey('progress-fill'),
              semanticsLabel: 'Playback progress',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fill = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('progress-fill')),
    );
    expect(fill.color, fillColor.withAlpha(220));

    final semantics = tester.getSemantics(find.byType(PlaybackProgressLine));
    expect(semantics.label, 'Playback progress');
    expect(semantics.value, '38%');
  });

  Widget lineApp(
    double value, {
    bool animateProgress = true,
    bool tickerEnabled = true,
    bool reducedMotion = false,
    Color color = const Color(0xFF35C76F),
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: TickerMode(
        enabled: tickerEnabled,
        child: Center(
          child: SizedBox(
            width: 200,
            child: PlaybackProgressLine(
              value: value,
              color: color,
              animateProgress: animateProgress,
              progressAnimationKey: const ValueKey('progress-animation'),
              colorAnimationKey: const ValueKey('color-animation'),
              fillKey: const ValueKey('progress-fill'),
            ),
          ),
        ),
      ),
    ),
  );

  AnimationController progressController(WidgetTester tester) =>
      tester
              .widget<AnimatedBuilder>(
                find.byKey(const ValueKey('progress-animation')),
              )
              .animation
          as AnimationController;

  double paintedProgress(WidgetTester tester) =>
      tester.widget<Transform>(find.byType(Transform)).transform.storage[0];

  testWidgets('120 Hz decorative progress parks unused vsync callbacks', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    await tester.pumpWidget(lineApp(0.2));
    await tester.pumpAndSettle();
    await tester.pumpWidget(lineApp(0.8));
    await tester.pump();
    final controller = progressController(tester);
    expect(controller.duration, const Duration(milliseconds: 220));
    expect(controller.isAnimating, isTrue);
    expect(tester.binding.transientCallbackCount, 0);

    var ticks = 0;
    controller.addListener(() => ticks++);
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
      expect(ticks, 0);
      expect(tester.binding.transientCallbackCount, 0);
    }
    await tester.pump(const Duration(microseconds: 8333));
    expect(ticks, 1);
    expect(paintedProgress(tester), inExclusiveRange(0.2, 0.8));
    // Pump genuine 120 Hz display intervals. Only every fourth one should
    // change this narrow decorative fill; gestures and lyric motion are free
    // to use the intervening display frames.
    for (var frame = 0; frame < 26; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
    }
    expect(ticks, lessThanOrEqualTo(8));
    expect(controller.isAnimating, isFalse);
    expect(paintedProgress(tester), closeTo(0.8, 0.0001));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('160 ms artwork ring uses the same parked 30 Hz clock', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    Widget ringApp(double value) => MaterialApp(
      home: Center(
        child: SizedBox.square(
          dimension: 48,
          child: DecorativeProgressTransition(
            value: value,
            duration: const Duration(milliseconds: 160),
            animationKey: const ValueKey('progress-animation'),
            builder: (context, progress, _) => CircularProgressIndicator(
              value: progress,
              strokeWidth: 2,
              strokeCap: StrokeCap.round,
              color: Colors.cyan,
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(ringApp(0.25));
    await tester.pumpWidget(ringApp(0.75));
    await tester.pump();
    final controller = progressController(tester);
    var ticks = 0;
    controller.addListener(() => ticks++);
    for (var frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
    }
    expect(ticks, lessThanOrEqualTo(6));
    expect(controller.duration, const Duration(milliseconds: 160));
    expect(controller.isAnimating, isFalse);
    final ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ring.value, closeTo(0.75, 0.0001));
    expect(ring.strokeWidth, 2);
    expect(ring.strokeCap, StrokeCap.round);
    expect(ring.color, Colors.cyan);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('frequent identical snapshots leave paused progress static', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    await tester.pumpWidget(lineApp(0.2));
    await tester.pumpWidget(lineApp(0.8));
    await tester.pump(const Duration(milliseconds: 67));
    await tester.pumpWidget(lineApp(0.8, animateProgress: false));
    expect(progressController(tester).isAnimating, isFalse);
    expect(paintedProgress(tester), closeTo(0.8, 0.0001));
    for (var sample = 0; sample < 8; sample++) {
      await tester.pumpWidget(lineApp(0.8, animateProgress: false));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
    }
    // A seek while paused updates immediately, without a new decorative clock.
    await tester.pumpWidget(lineApp(0.1, animateProgress: false));
    expect(paintedProgress(tester), closeTo(0.1, 0.0001));
    expect(progressController(tester).isAnimating, isFalse);
  });

  testWidgets('seek retargets from the displayed fraction without snapping', (
    tester,
  ) async {
    await tester.pumpWidget(lineApp(0.2));
    await tester.pumpWidget(lineApp(0.8));
    await tester.pump(const Duration(milliseconds: 90));
    final entering = paintedProgress(tester);
    expect(entering, inExclusiveRange(0.2, 0.8));
    await tester.pumpWidget(lineApp(0.1));
    expect(paintedProgress(tester), closeTo(entering, 0.0001));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(paintedProgress(tester), closeTo(0.1, 0.0001));
  });

  testWidgets('offscreen and reduced-motion progress cancel pending clocks', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    for (final hidden in [true, false]) {
      await tester.pumpWidget(lineApp(0.2));
      await tester.pumpWidget(lineApp(0.8, color: Colors.cyan));
      await tester.pump(const Duration(milliseconds: 67));
      await tester.pumpWidget(
        lineApp(
          0.8,
          tickerEnabled: !hidden,
          reducedMotion: !hidden,
          color: Colors.cyan,
        ),
      );
      expect(progressController(tester).isAnimating, isFalse);
      expect(paintedProgress(tester), closeTo(0.8, 0.0001));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      final fill = tester.widget<ColoredBox>(
        find.byKey(const ValueKey('progress-fill')),
      );
      expect(fill.color, Colors.cyan.withAlpha(220));
    }
  });

  testWidgets(
    'background progress stops clocks and resumes at the last sample',
    (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      await tester.pumpWidget(lineApp(0.2));
      await tester.pumpWidget(lineApp(0.8, color: Colors.cyan));
      await tester.pump(const Duration(milliseconds: 67));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(progressController(tester).isAnimating, isFalse);
      expect(paintedProgress(tester), closeTo(0.8, 0.0001));
      await tester.pumpWidget(lineApp(0.9, color: Colors.cyan));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(paintedProgress(tester), closeTo(0.9, 0.0001));
      expect(progressController(tester).isAnimating, isFalse);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
