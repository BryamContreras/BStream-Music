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
}
