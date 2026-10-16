import 'package:bstream_music/features/music/presentation/widgets/lyrics_text_style_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const original = '曖昧な言葉なんかじゃ何一つ叶わない';
  const romanized =
      'aimai na kotoba nanka ja nani hitotsu kanawanai '
      'haruka mirai e ima kakedashitan da';
  const translated =
      'Con palabras ambiguas no conseguiré nada; '
      'ahora he empezado a correr hacia un futuro lejano.';
  const activeStyle = TextStyle(
    fontSize: 28,
    height: 1.16,
    fontWeight: FontWeight.w900,
    color: Colors.white,
    shadows: [Shadow(color: Colors.cyan, blurRadius: 10)],
  );
  const inactiveStyle = TextStyle(
    fontSize: 27,
    height: 1.16,
    fontWeight: FontWeight.w900,
    color: Color(0x61FFFFFF),
  );

  Widget app({required bool active, required String secondary}) => MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 336,
        child: LyricsTextStyleTransition(
          key: const ValueKey('transition'),
          active: active,
          originalText: original,
          secondaryText: secondary,
          secondaryKey: const ValueKey('secondary'),
          activeStyle: activeStyle,
          inactiveStyle: inactiveStyle,
          secondaryFontSize: 16.8,
          textAlign: TextAlign.start,
          // Match the timeline: the discoverable content key changes on the
          // active boundary, but must not dispose retained glyph paragraphs.
          contentKey: ValueKey(active ? 'active-lyric-line' : 'lyric-line-0'),
        ),
      ),
    ),
  );

  List<RenderParagraph> paragraphs(WidgetTester tester) => tester
      .renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.byKey(const ValueKey('transition')),
          matching: find.byType(RichText),
        ),
      )
      .toList(growable: false);

  for (final sample in [
    (name: 'romanization', text: romanized),
    (name: 'translation', text: translated),
  ]) {
    testWidgets(
      '${sample.name} paragraphs survive active content key changes',
      (tester) async {
        await tester.pumpWidget(app(active: false, secondary: sample.text));
        final retained = paragraphs(tester);
        expect(retained, isNotEmpty);
        final contentRect = tester.getRect(
          find.byKey(const ValueKey('lyric-line-0')),
        );

        // Include retargeting an unfinished transition in both directions.
        for (final active in [true, false, true, false]) {
          await tester.pumpWidget(app(active: active, secondary: sample.text));
          expect(
            paragraphs(tester),
            unorderedEquals(retained),
            reason:
                'Selecting a lyric must reuse its shaped paragraphs, not '
                'replace the keyed subtree or swap Text/RichText endpoints.',
          );
          expect(
            tester.getRect(
              find.byKey(
                ValueKey(active ? 'active-lyric-line' : 'lyric-line-0'),
              ),
            ),
            contentRect,
          );
          await tester.pump(const Duration(milliseconds: 110));
          expect(paragraphs(tester), unorderedEquals(retained));
          expect(tester.takeException(), isNull);
        }
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);

        // Both appearances have now been painted at least once. Subsequent
        // boundary changes must composite those retained pictures, including
        // the very first frame (not just frames halfway through a fade).
        final previousCallback = debugOnProfilePaint;
        var paragraphPaints = 0;
        debugOnProfilePaint = (renderObject) {
          if (renderObject is RenderParagraph) paragraphPaints++;
        };
        try {
          for (final active in [true, false]) {
            await tester.pumpWidget(
              app(active: active, secondary: sample.text),
            );
            await tester.pumpAndSettle();
            expect(paragraphs(tester), unorderedEquals(retained));
          }
        } finally {
          debugOnProfilePaint = previousCallback;
        }
        expect(
          paragraphPaints,
          0,
          reason:
              'Already-painted lyric glyphs must survive activation itself, '
              'not only remain cached after its initial expensive frame.',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
