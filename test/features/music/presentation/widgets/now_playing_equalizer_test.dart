import 'package:bstream_music/features/music/presentation/widgets/now_playing_equalizer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paints all segments without an animated widget subtree', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: NowPlayingEqualizer(isPlaying: true)),
      ),
    );

    final equalizer = find.byType(NowPlayingEqualizer);
    expect(equalizer, findsOneWidget);
    expect(tester.getSize(equalizer), const Size(48, 18));
    expect(
      find.descendant(of: equalizer, matching: find.byType(RepaintBoundary)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: equalizer, matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: equalizer, matching: find.byType(AnimatedBuilder)),
      findsNothing,
    );
    expect(
      find.descendant(of: equalizer, matching: find.byType(Container)),
      findsNothing,
    );

    final paintFinder = find.descendant(
      of: equalizer,
      matching: find.byType(CustomPaint),
    );
    final paintBefore = tester.widget<CustomPaint>(paintFinder);
    await tester.pump(const Duration(milliseconds: 400));
    final paintAfter = tester.widget<CustomPaint>(paintFinder);

    // The controller invalidates the painter directly. No widget rebuild is
    // needed for an animation frame.
    expect(identical(paintBefore, paintAfter), isTrue);
  });

  testWidgets('stops direct painter ticks while paused and resumes them', (
    tester,
  ) async {
    late StateSetter update;
    var isPlaying = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return NowPlayingEqualizer(isPlaying: isPlaying);
            },
          ),
        ),
      ),
    );

    final paintFinder = find.descendant(
      of: find.byType(NowPlayingEqualizer),
      matching: find.byType(CustomPaint),
    );
    var pausedTicks = 0;
    void countPausedTick() => pausedTicks++;
    final pausedPainter = tester.widget<CustomPaint>(paintFinder).painter!;
    pausedPainter.addListener(countPausedTick);
    await tester.pump(const Duration(seconds: 2));
    pausedPainter.removeListener(countPausedTick);
    expect(pausedTicks, 0);

    update(() => isPlaying = true);
    await tester.pump();
    var playingTicks = 0;
    void countPlayingTick() => playingTicks++;
    final playingPainter = tester.widget<CustomPaint>(paintFinder).painter!;
    playingPainter.addListener(countPlayingTick);
    await tester.pump(const Duration(milliseconds: 400));
    playingPainter.removeListener(countPlayingTick);
    expect(playingTicks, greaterThan(0));

    update(() => isPlaying = false);
    await tester.pump();
    var secondPauseTicks = 0;
    void countSecondPauseTick() => secondPauseTicks++;
    final secondPausedPainter = tester
        .widget<CustomPaint>(paintFinder)
        .painter!;
    secondPausedPainter.addListener(countSecondPauseTick);
    await tester.pump(const Duration(seconds: 2));
    secondPausedPainter.removeListener(countSecondPauseTick);
    expect(secondPauseTicks, 0);
  });

  testWidgets('preserves playing and paused semantic labels', (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: NowPlayingEqualizer(isPlaying: true)),
      ),
    );
    expect(find.bySemanticsLabel('Reproduciendo'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: NowPlayingEqualizer(isPlaying: false)),
      ),
    );
    expect(find.bySemanticsLabel('Reproducción pausada'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('does not tick with reduced motion and resumes when allowed', (
    tester,
  ) async {
    var reduceMotion = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reduceMotion),
              child: const Center(child: NowPlayingEqualizer(isPlaying: true)),
            );
          },
        ),
      ),
    );

    expect(await _countPainterTicks(tester), 0);

    update(() => reduceMotion = false);
    await tester.pump();
    expect(await _countPainterTicks(tester), greaterThan(0));
  });

  testWidgets('does not tick outside TickerMode and resumes when enabled', (
    tester,
  ) async {
    var tickerEnabled = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TickerMode(
              enabled: tickerEnabled,
              child: const Center(child: NowPlayingEqualizer(isPlaying: true)),
            );
          },
        ),
      ),
    );

    expect(await _countPainterTicks(tester), 0);

    update(() => tickerEnabled = true);
    await tester.pump();
    expect(await _countPainterTicks(tester), greaterThan(0));

    update(() => tickerEnabled = false);
    await tester.pump();
    expect(await _countPainterTicks(tester), 0);
  });

  testWidgets('stops while the application is not active and resumes', (
    tester,
  ) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: NowPlayingEqualizer(isPlaying: true)),
      ),
    );
    expect(await _countPainterTicks(tester), greaterThan(0));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(await _countPainterTicks(tester), 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(await _countPainterTicks(tester), greaterThan(0));
  });
}

Future<int> _countPainterTicks(WidgetTester tester) async {
  final paintFinder = find.descendant(
    of: find.byType(NowPlayingEqualizer),
    matching: find.byType(CustomPaint),
  );
  final painter = tester.widget<CustomPaint>(paintFinder).painter!;
  var ticks = 0;
  void countTick() => ticks++;
  painter.addListener(countTick);
  await tester.pump(const Duration(milliseconds: 400));
  painter.removeListener(countTick);
  return ticks;
}
