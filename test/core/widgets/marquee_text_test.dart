import 'package:bstream_music/core/widgets/marquee_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps short labels static and scrolls overflowing labels', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 120,
            child: MarqueeText('A very long playlist title'),
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
          child: SizedBox(width: 120, child: MarqueeText('Short')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('marquee-text-animation')), findsNothing);
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
}

double _marqueeTranslation(WidgetTester tester) {
  final transform = find.descendant(
    of: find.byKey(const ValueKey('marquee-text-animation')),
    matching: find.byType(Transform),
  );
  return tester.widget<Transform>(transform).transform.getTranslation().x;
}
