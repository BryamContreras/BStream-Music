import 'package:bstream_music/features/music/presentation/widgets/playback_progress_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
