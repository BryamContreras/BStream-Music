import 'package:bstream_music/features/music/presentation/widgets/lyrics_glyph_snapshot.dart';
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
    shadows: [
      Shadow(color: Colors.cyan, blurRadius: 10),
      Shadow(color: Color(0x3D00FFFF), blurRadius: 26),
      Shadow(color: Color(0x7A000000), blurRadius: 10, offset: Offset(0, 2)),
    ],
  );
  final inactiveStyle = activeStyle.copyWith(
    fontSize: 27,
    color: Colors.white.withValues(alpha: 0.38),
    shadows: const [],
  );

  Widget app({
    required bool active,
    required String secondary,
    double width = 336,
    double textScale = 1,
    bool reducedMotion = false,
    TextAlign textAlign = TextAlign.start,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(360, 800),
        textScaler: TextScaler.linear(textScale),
        disableAnimations: reducedMotion,
      ),
      child: SingleChildScrollView(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: LyricsTextStyleTransition(
              active: active,
              originalText: original,
              secondaryText: secondary,
              secondaryKey: const ValueKey('secondary'),
              activeStyle: activeStyle,
              inactiveStyle: inactiveStyle,
              secondaryFontSize: 16.8,
              textAlign: textAlign,
              contentKey: const ValueKey('pair'),
            ),
          ),
        ),
      ),
    ),
  );

  for (final active in [false, true]) {
    testWidgets(
      'alignment refreshes hit testing for retained ${active ? 'active' : 'inactive'} paragraphs',
      (tester) async {
        await tester.pumpWidget(app(active: active, secondary: romanized));
        for (final alignment in [TextAlign.center, TextAlign.start]) {
          await tester.pumpWidget(
            app(active: active, secondary: romanized, textAlign: alignment),
          );
          final paragraphs = tester
              .renderObjectList<RenderParagraph>(find.byType(RichText))
              .where(
                (paragraph) =>
                    paragraph.text.toPlainText() == original ||
                    paragraph.text.toPlainText() == romanized,
              )
              .toList();
          expect(paragraphs, isNotEmpty);
          // Probe even the zero-opacity endpoint: paint may legitimately skip
          // it, but a cached paragraph must never break pointer dispatch.
          for (final paragraph in paragraphs) {
            expect(paragraph.textAlign, alignment);
            expect(
              () => paragraph.hitTest(
                BoxHitTestResult(),
                position: paragraph.size.center(Offset.zero),
              ),
              returnsNormally,
            );
          }
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  for (final sample in [
    (name: 'romanization', text: romanized),
    (name: 'translation', text: translated),
  ]) {
    testWidgets(
      'long ${sample.name} retains glyph pictures throughout the fade',
      (tester) async {
        await tester.pumpWidget(app(active: false, secondary: sample.text));
        await tester.pumpWidget(app(active: true, secondary: sample.text));
        await tester.pump(const Duration(milliseconds: 32));

        final previousCallback = debugOnProfilePaint;
        var paragraphPaints = 0;
        debugOnProfilePaint = (renderObject) {
          if (renderObject is RenderParagraph) paragraphPaints++;
        };
        final paragraphs = tester
            .renderObjectList<RenderParagraph>(find.byType(RichText))
            .toList(growable: false);
        final glyphStyles = [
          for (final paragraph in paragraphs) paragraph.text,
        ];
        final lineHeights = [
          for (final paragraph in paragraphs) paragraph.size,
        ];

        // Exercise an entire entering fade, including the wrapped companion
        // text, rather than checking only a settled endpoint.
        try {
          for (var frame = 0; frame < 32; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            for (var index = 0; index < paragraphs.length; index++) {
              expect(paragraphs[index].text, same(glyphStyles[index]));
              expect(paragraphs[index].size, lineHeights[index]);
            }
          }
        } finally {
          debugOnProfilePaint = previousCallback;
        }
        expect(
          paragraphPaints,
          0,
          reason: 'Animation frames must reuse already-painted glyph pictures.',
        );
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(find.text(original), findsOneWidget);
        expect(find.text(sample.text), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('rapid changes preserve opacity instead of restarting the fade', (
    tester,
  ) async {
    double opacity() => tester
        .widget<LyricsGlyphSnapshot>(find.byType(LyricsGlyphSnapshot))
        .opacity!
        .value;

    await tester.pumpWidget(app(active: false, secondary: romanized));
    await tester.pumpWidget(app(active: true, secondary: romanized));
    await tester.pump(const Duration(milliseconds: 180));
    final entering = opacity();
    expect(entering, inExclusiveRange(0, 1));
    await tester.pumpWidget(app(active: false, secondary: romanized));
    expect(opacity(), closeTo(entering, 0.0001));
    await tester.pump(const Duration(milliseconds: 90));
    final exiting = opacity();
    await tester.pumpWidget(app(active: true, secondary: romanized));
    expect(opacity(), closeTo(exiting, 0.0001));
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text wraps without truncating either lyric appearance', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(active: false, secondary: translated, width: 280, textScale: 2),
    );
    final inactivePair = tester.getRect(find.byKey(const ValueKey('pair')));
    await tester.pumpWidget(
      app(active: true, secondary: translated, width: 280, textScale: 2),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('pair'))),
      inactivePair,
      reason:
          'The larger endpoint reserves the row height throughout the fade.',
    );
    expect(find.text(original), findsOneWidget);
    expect(find.text(translated), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion has one paragraph pair and no fade ticker', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(active: false, secondary: romanized, reducedMotion: true),
    );
    await tester.pumpWidget(
      app(active: true, secondary: romanized, reducedMotion: true),
    );
    expect(
      find.descendant(
        of: find.byType(LyricsTextStyleTransition),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    expect(find.byType(RichText), findsNWidgets(2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('crossfade announces each lyric only once in both directions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(app(active: false, secondary: romanized));

      void expectOnePair() {
        expect(find.bySemanticsLabel('$original\n$romanized'), findsOneWidget);
        expect(find.bySemanticsLabel(original), findsNothing);
        expect(find.bySemanticsLabel(romanized), findsNothing);
      }

      expectOnePair();
      await tester.pumpWidget(app(active: true, secondary: romanized));
      // Accessibility belongs to one stable row, independent of the cached
      // paragraphs' opacity and of which glyph appearance is currently shown.
      expectOnePair();
      await tester.pump(const Duration(milliseconds: 260));
      expectOnePair();
      await tester.pumpWidget(app(active: false, secondary: romanized));
      expectOnePair();
      await tester.pump(const Duration(milliseconds: 260));
      expectOnePair();
      await tester.pumpAndSettle();
      expectOnePair();
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });
}
