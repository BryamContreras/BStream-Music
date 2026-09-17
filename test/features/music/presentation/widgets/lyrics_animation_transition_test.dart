import 'package:bstream_music/features/music/presentation/providers/lyrics_animation_style.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_animation_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('rapid smooth retargeting preserves visual continuity', (
    tester,
  ) async {
    const transitionKey = ValueKey('transition');

    Widget app({required bool active}) {
      return MaterialApp(
        home: LyricsAnimationTransition(
          key: transitionKey,
          style: LyricsAnimationStyle.smooth,
          active: active,
          accent: Colors.cyan,
          child: const Text('Line'),
        ),
      );
    }

    double opacity() => tester
        .widget<Opacity>(
          find.descendant(
            of: find.byKey(transitionKey),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;

    await tester.pumpWidget(app(active: false));
    await tester.pumpWidget(app(active: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    final enteringOpacity = opacity();
    expect(enteringOpacity, inExclusiveRange(0.62, 1));

    await tester.pumpWidget(app(active: false));
    await tester.pump();
    expect(opacity(), closeTo(enteringOpacity, 0.001));

    await tester.pump(const Duration(milliseconds: 90));
    final exitingOpacity = opacity();
    expect(exitingOpacity, lessThan(enteringOpacity));

    await tester.pumpWidget(app(active: true));
    await tester.pump();
    expect(opacity(), closeTo(exitingOpacity, 0.001));

    await tester.pump(const Duration(milliseconds: 90));
    expect(opacity(), greaterThan(exitingOpacity));
    await tester.pumpAndSettle();
    expect(opacity(), closeTo(1, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('highlight reaches its resting scale without overshoot', (
    tester,
  ) async {
    const transitionKey = ValueKey('highlight-transition');
    await tester.pumpWidget(
      const MaterialApp(
        home: LyricsAnimationTransition(
          key: transitionKey,
          style: LyricsAnimationStyle.highlight,
          active: false,
          accent: Colors.cyan,
          child: Text('Line'),
        ),
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: LyricsAnimationTransition(
          key: transitionKey,
          style: LyricsAnimationStyle.highlight,
          active: true,
          accent: Colors.cyan,
          child: Text('Line'),
        ),
      ),
    );
    await tester.pump();

    var previousScale = 0.98;
    for (var frame = 0; frame < 45; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final transform = tester.widget<Transform>(
        find.descendant(
          of: find.byKey(transitionKey),
          matching: find.byType(Transform),
        ),
      );
      final scale = transform.transform.entry(0, 0);
      expect(scale, greaterThanOrEqualTo(previousScale - 0.000001));
      expect(scale, lessThanOrEqualTo(1.010001));
      previousScale = scale;
    }

    expect(previousScale, closeTo(1.01, 0.001));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slide completes on the shorter smooth cadence', (tester) async {
    const transitionKey = ValueKey('slide-transition');
    await tester.pumpWidget(
      const MaterialApp(
        home: LyricsAnimationTransition(
          key: transitionKey,
          style: LyricsAnimationStyle.slide,
          active: false,
          accent: Colors.cyan,
          child: Text('Line'),
        ),
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: LyricsAnimationTransition(
          key: transitionKey,
          style: LyricsAnimationStyle.slide,
          active: true,
          accent: Colors.cyan,
          child: Text('Line'),
        ),
      ),
    );
    await tester.pump();

    Transform transform() => tester.widget<Transform>(
      find.descendant(
        of: find.byKey(transitionKey),
        matching: find.byType(Transform),
      ),
    );

    expect(transform().transform.getTranslation().y, closeTo(34, 0.01));
    await tester.pump(const Duration(milliseconds: 550));
    expect(transform().transform.getTranslation().y, closeTo(0, 0.01));
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
