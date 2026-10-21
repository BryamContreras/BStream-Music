import 'package:bstream_music/core/widgets/marquee_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stops text clipped by a nested horizontal viewport', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 140,
            height: 80,
            child: ScrollNotificationObserver(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    SizedBox(width: 250),
                    SizedBox(
                      width: 80,
                      child: MarqueeText(
                        'A very long hidden title',
                        pause: Duration(milliseconds: 200),
                        travel: Duration(seconds: 1),
                      ),
                    ),
                    SizedBox(width: 400),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(_marqueeAnimating(tester), isFalse);
    expect(_marqueeTranslation(tester), 0);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-250, 0),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_marqueeTranslation(tester), lessThan(0));
  });
  testWidgets('keeps short labels static and scrolls overflowing labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            child: MarqueeText(
              'A very long playlist title',
              style: TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('marquee-text-animation')),
      findsOneWidget,
    );
    expect(find.text('A very long playlist title'), findsOneWidget);
    expect(find.byType(ClipRect), findsOneWidget);
    expect(tester.getSize(find.byType(ClipRect)).width, 120);

    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            child: MarqueeText('Short', style: TextStyle(fontSize: 14)),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('marquee-text-animation')), findsNothing);
    expect(
      find.byKey(const ValueKey('marquee-text-viewport-cache')),
      findsNothing,
    );
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('does not overflow at narrow widths and disposes its ticker', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 48,
          child: MarqueeText('Título muy largo para una tarjeta pequeña'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('stays at rest when reduced motion is requested', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(800, 600), disableAnimations: true),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 120,
              child: MarqueeText(
                'A very long playlist title',
                pause: Duration(milliseconds: 1),
                travel: Duration(seconds: 1),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(_marqueeTranslation(tester), 0);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('does not tick while waiting at either end', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 80,
            child: MarqueeText(
              'A very long playlist title',
              style: TextStyle(fontSize: 14),
              pause: Duration(milliseconds: 200),
              travel: Duration(milliseconds: 400),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(_marqueeTranslation(tester), 0);
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_marqueeTranslation(tester), lessThan(0));
    expect(_marqueeAnimating(tester), isTrue);

    await tester.pump(_marqueeTravelDuration(tester));
    final endPosition = _marqueeTranslation(tester);
    expect(endPosition, lessThan(0));
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pump(const Duration(milliseconds: 150));
    expect(_marqueeTranslation(tester), endPosition);
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pump(const Duration(milliseconds: 70));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_marqueeTranslation(tester), greaterThan(endPosition));
    expect(_marqueeAnimating(tester), isTrue);
  });

  testWidgets('stops offscreen and resumes after scrolling into view', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ScrollNotificationObserver(
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(height: 800),
                SizedBox(
                  width: 80,
                  child: MarqueeText(
                    'A very long playlist title',
                    style: TextStyle(fontSize: 14),
                    pause: Duration(milliseconds: 200),
                    travel: Duration(seconds: 1),
                  ),
                ),
                SizedBox(height: 800),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(_marqueeTranslation(tester), 0);
    expect(tester.hasRunningAnimations, isFalse);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -700),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_marqueeTranslation(tester), lessThan(0));

    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 700));
    await tester.pump();
    await tester.pump();
    expect(_marqueeTranslation(tester), 0);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('stops outside TickerMode and resumes from the start', (
    tester,
  ) async {
    var tickerEnabled = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Align(
              alignment: Alignment.topLeft,
              child: TickerMode(
                enabled: tickerEnabled,
                child: const SizedBox(
                  width: 120,
                  child: MarqueeText(
                    'A very long playlist title',
                    pause: Duration(milliseconds: 1),
                    travel: Duration(seconds: 1),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_marqueeTranslation(tester), 0);

    update(() => tickerEnabled = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_marqueeTranslation(tester), lessThan(0));

    update(() => tickerEnabled = false);
    await tester.pump();
    expect(_marqueeTranslation(tester), 0);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_marqueeTranslation(tester), 0);
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
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            child: MarqueeText(
              'A very long playlist title',
              pause: Duration(milliseconds: 1),
              travel: Duration(seconds: 1),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_marqueeTranslation(tester), lessThan(0));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // A bounded clock no longer leaves a pending frame when backgrounded.
    // Force this test-only paint to inspect the reset pose while suspended.
    tester.binding.scheduleForcedFrame();
    await tester.pump();
    expect(_marqueeTranslation(tester), 0);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_marqueeTranslation(tester), 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_marqueeTranslation(tester), lessThan(0));
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      '$platform long titles and artists have the same bounded speed',
      (tester) async {
        final titles = [
          List.filled(
            8,
            'A long song title with a remix and featured artists',
          ).join(' - '),
          List.filled(24, 'Artist one, Artist two, Artist three').join(', '),
          List.filled(20, '長い曲のタイトルとアーティスト 🎵').join(' / '),
        ];
        for (final text in titles) {
          await _pumpMovingLabel(tester, text: text, platform: platform);
          final initial = _marqueeTranslation(tester);
          await tester.pump(const Duration(milliseconds: 500));
          expect(_marqueeTranslation(tester) - initial, closeTo(-12, 0.01));
        }
      },
    );
  }

  testWidgets('keeps gentle minimum travel for a small overflow', (
    tester,
  ) async {
    await _pumpMovingLabel(tester, text: 'Small overflow', width: 180);
    final labelWidth = tester
        .getSize(find.byKey(const ValueKey('marquee-text-label-cache')))
        .width;
    final distance = labelWidth - 180;
    await tester.pump(const Duration(milliseconds: 2600));
    expect(_marqueeTranslation(tester), closeTo(-distance / 2, 0.01));
  });

  testWidgets('paint-only style updates do not restart the moving title', (
    tester,
  ) async {
    const text =
        'A very long title that is moving steadily instead of restarting';
    await _pumpMovingLabel(tester, text: text, color: Colors.white);
    await tester.pump(const Duration(milliseconds: 500));
    final position = _marqueeTranslation(tester);
    expect(position, lessThan(0));
    await _pumpMovingLabel(
      tester,
      text: text,
      color: Colors.blue,
      start: false,
    );
    expect(_marqueeTranslation(tester), position);
    expect(_marqueeAnimating(tester), isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_marqueeTranslation(tester), closeTo(position - 12, 0.01));
  });

  testWidgets(
    'measures the inherited font and remeasures accessibility scale',
    (tester) async {
      const text = 'Inherited font metrics with long artist names';
      Future<void> pump(double scale) => tester.pumpWidget(
        MaterialApp(
          home: DefaultTextStyle(
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 160,
                child: MarqueeText(
                  text,
                  style: const TextStyle(color: Colors.white),
                  textScaler: TextScaler.linear(scale),
                ),
              ),
            ),
          ),
        ),
      );
      await pump(1);
      await tester.pump();
      final label = find.byKey(const ValueKey('marquee-text-label-cache'));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byType(RichText).last,
      );
      final width = tester.getSize(label).width;
      expect(
        width,
        closeTo(paragraph.getMaxIntrinsicWidth(double.infinity), 0.01),
      );
      await pump(2);
      await tester.pump();
      expect(tester.getSize(label).width, greaterThan(width * 1.9));
      expect(tester.takeException(), isNull);
    },
  );

  for (final hertz in [60.0, 120.0]) {
    testWidgets('smooth bounded cadence on a $hertz Hz display', (
      tester,
    ) async {
      tester.view.display.refreshRate = hertz;
      addTearDown(tester.view.display.resetRefreshRate);
      await _pumpMovingLabel(
        tester,
        text: 'A long song title with many featured artists',
      );
      var position = _marqueeTranslation(tester);
      var updates = 0;
      final frame = Duration(microseconds: (1000000 / hertz).round());
      for (var index = 0; index < hertz.toInt(); index++) {
        await tester.pump(frame);
        final next = _marqueeTranslation(tester);
        if (next != position) updates++;
        position = next;
      }
      expect(updates, inInclusiveRange(59, 61));
      expect(position, closeTo(-24, 0.5));
    });
  }

  testWidgets(
    'moving retained text does not repaint the label or its surroundings',
    (tester) async {
      var paints = 0;
      var layouts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: CustomPaint(
              painter: _CountingPainter(() => paints++),
              child: _CountingLayout(
                onLayout: () => layouts++,
                child: const SizedBox(
                  width: 160,
                  child: MarqueeText(
                    'A long title whose paint is retained throughout the movement',
                    pause: Duration(milliseconds: 1),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2));
      final label = find.byKey(const ValueKey('marquee-text-label-cache'));
      final pictures = tester
          .layerListOf(label)
          .whereType<PictureLayer>()
          .toList();
      final initialPaints = paints;
      final initialLayouts = layouts;
      final textWidget = tester.widget<Text>(
        find.text(
          'A long title whose paint is retained throughout the movement',
        ),
      );
      expect(pictures, isNotEmpty);
      for (var index = 0; index < 60; index++) {
        await tester.pump(const Duration(microseconds: 16667));
      }
      expect(_marqueeTranslation(tester), lessThan(0));
      expect(paints, initialPaints);
      expect(layouts, initialLayouts);
      expect(
        tester.layerListOf(label).whereType<PictureLayer>().toList(),
        pictures,
      );
      expect(
        identical(tester.widget<Text>(find.text(textWidget.data!)), textWidget),
        isTrue,
      );
    },
  );

  testWidgets(
    'resizing recomputes distance without increasing the speed limit',
    (tester) async {
      const text =
          'A long title with lots of extra words and many featured artists';
      await _pumpMovingLabel(tester, text: text, width: 160);
      await _pumpMovingLabel(tester, text: text, width: 320);
      final initial = _marqueeTranslation(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(_marqueeTranslation(tester), closeTo(initial - 12, 0.01));
    },
  );
}

Future<void> _pumpMovingLabel(
  WidgetTester tester, {
  required String text,
  double width = 160,
  TargetPlatform platform = TargetPlatform.windows,
  Color color = Colors.white,
  bool start = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: MarqueeText(
            text,
            style: TextStyle(fontSize: 14, color: color),
            pause: const Duration(milliseconds: 1),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  if (start) {
    await tester.pump(const Duration(milliseconds: 2));
  }
}

class _CountingPainter extends CustomPainter {
  _CountingPainter(this.onPaint);

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(_CountingPainter oldDelegate) => false;
}

class _CountingLayout extends SingleChildRenderObjectWidget {
  const _CountingLayout({required this.onLayout, required super.child});

  final VoidCallback onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCountingLayout(onLayout);
}

class _RenderCountingLayout extends RenderProxyBox {
  _RenderCountingLayout(this.onLayout);

  final VoidCallback onLayout;

  @override
  void performLayout() {
    onLayout();
    super.performLayout();
  }
}

Duration _marqueeTravelDuration(WidgetTester tester) {
  final widget = tester.widget<MarqueeText>(find.byType(MarqueeText));
  final label = tester.getSize(
    find.byKey(const ValueKey('marquee-text-label-cache')),
  );
  final viewport = tester.getSize(
    find.byKey(const ValueKey('marquee-text-viewport-cache')),
  );
  final duration = Duration(
    microseconds:
        ((label.width - viewport.width) / widget.pixelsPerSecond * 1000000)
            .ceil(),
  );
  return duration < widget.travel ? widget.travel : duration;
}

double _marqueeTranslation(WidgetTester tester) {
  final flow = tester.renderObject<RenderFlow>(
    find.byKey(const ValueKey('marquee-text-animation')),
  );
  final transform = Matrix4.identity();
  flow.applyPaintTransform(flow.firstChild!, transform);
  return transform.getTranslation().x;
}

bool _marqueeAnimating(WidgetTester tester) => tester.hasRunningAnimations;
