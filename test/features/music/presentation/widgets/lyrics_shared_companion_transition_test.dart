import 'package:bstream_music/features/music/presentation/widgets/lyrics_glyph_snapshot.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_line_layout.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_text_style_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const original = '曖昧な言葉なんかじゃ何一つ叶わない';
  const secondary =
      'aimai na kotoba nanka ja nani hitotsu kanawanai '
      'haruka mirai e ima kakedashitan da';
  const activeStyle = TextStyle(
    inherit: false,
    fontSize: 28,
    height: 1.16,
    fontWeight: FontWeight.w900,
    color: Colors.white,
    shadows: [Shadow(color: Colors.cyan, blurRadius: 10)],
  );
  final inactiveStyle = activeStyle.copyWith(
    color: Colors.white.withValues(alpha: 0.38),
    fontSize: 27,
    shadows: const [],
  );

  Widget app({
    required bool active,
    double width = 336,
    double scale = 1,
    TextStyle? inactive,
    bool reducedMotion = false,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(720, 1000),
        textScaler: TextScaler.linear(scale),
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
              inactiveStyle: inactive ?? inactiveStyle,
              secondaryFontSize: 16.8,
              textAlign: TextAlign.start,
              contentKey: const ValueKey('pair'),
            ),
          ),
        ),
      ),
    ),
  );

  List<RenderParagraph> paragraphs(WidgetTester tester) => tester
      .renderObjectList<RenderParagraph>(find.byType(RichText))
      .toList(growable: false);

  testWidgets('matching companions use one retained paragraph, not two', (
    tester,
  ) async {
    await tester.pumpWidget(app(active: false));
    final retained = paragraphs(tester);
    expect(retained, hasLength(3));
    expect(find.text(original), findsOneWidget);
    expect(find.text(secondary), findsOneWidget);

    await tester.pumpWidget(app(active: true));
    await tester.pump(const Duration(milliseconds: 32));
    final previousCallback = debugOnProfilePaint;
    var paragraphPaints = 0;
    debugOnProfilePaint = (renderObject) {
      if (renderObject is RenderParagraph) paragraphPaints++;
    };
    try {
      for (var frame = 0; frame < 32; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(paragraphs(tester), unorderedEquals(retained));
      }
    } finally {
      debugOnProfilePaint = previousCallback;
    }
    expect(paragraphPaints, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared companion preserves baseline gap at both endpoints', (
    tester,
  ) async {
    RenderParagraph originalParagraph(WidgetTester tester, double fontSize) =>
        paragraphs(tester).singleWhere(
          (paragraph) =>
              paragraph.text.toPlainText() == original &&
              paragraph.text.style!.fontSize == fontSize,
        );

    double originalBottom(WidgetTester tester, double fontSize) {
      final paragraph = originalParagraph(tester, fontSize);
      return paragraph.localToGlobal(Offset(0, paragraph.size.height)).dy;
    }

    await tester.pumpWidget(app(active: false));
    final inactiveTop = tester
        .getRect(find.byKey(const ValueKey('secondary')))
        .top;
    expect(inactiveTop - originalBottom(tester, 27), closeTo(4, 0.001));

    await tester.pumpWidget(app(active: true));
    await tester.pump(const Duration(milliseconds: 260));
    final progress = tester
        .widget<LyricsGlyphSnapshot>(find.byType(LyricsGlyphSnapshot))
        .opacity!
        .value;
    final sharedOpacity = tester.widget<Opacity>(
      find.ancestor(
        of: find.byKey(const ValueKey('secondary')),
        matching: find.byType(Opacity),
      ),
    );
    final inactiveAlpha = inactiveStyle.color!.a;
    expect(
      sharedOpacity.opacity,
      closeTo(progress + inactiveAlpha * (1 - progress) * (1 - progress), 1e-9),
    );
    await tester.pumpAndSettle();
    final activeTop = tester
        .getRect(find.byKey(const ValueKey('secondary')))
        .top;
    expect(activeTop - originalBottom(tester, 28), closeTo(4, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('different companion colors retain the full endpoint fallback', (
    tester,
  ) async {
    final differentColor = inactiveStyle.copyWith(
      color: Colors.orange.withValues(alpha: 0.38),
    );
    await tester.pumpWidget(app(active: false, inactive: differentColor));
    expect(paragraphs(tester), hasLength(4));
    await tester.pumpWidget(app(active: true, inactive: differentColor));
    await tester.pumpAndSettle();
    expect(paragraphs(tester), hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('different companion metrics retain the full endpoint fallback', (
    tester,
  ) async {
    final differentFont = inactiveStyle.copyWith(fontFamily: 'monospace');
    await tester.pumpWidget(app(active: false, inactive: differentFont));
    expect(paragraphs(tester), hasLength(4));
    await tester.pumpWidget(app(active: true, inactive: differentFont));
    await tester.pumpAndSettle();
    expect(paragraphs(tester), hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing and large text keep the complete reserved row height', (
    tester,
  ) async {
    for (final width in [336.0, 280.0, 620.0, 220.0]) {
      for (final scale in [1.0, 1.6, 2.0]) {
        final reserved = measureLyricsLineExtent(
          originalText: original,
          secondaryText: secondary,
          contentWidth: width,
          activeStyle: activeStyle,
          inactiveStyle: inactiveStyle,
          secondaryFontSize: 16.8,
          textScaler: TextScaler.linear(scale),
          textDirection: TextDirection.ltr,
          locale: const Locale('en', 'US'),
        );
        for (final active in [false, true]) {
          await tester.pumpWidget(
            app(active: active, width: width, scale: scale),
          );
          await tester.pumpAndSettle();
          expect(paragraphs(tester), hasLength(3));
          final actual = tester.getSize(find.byKey(const ValueKey('pair')));
          expect(actual.height, lessThanOrEqualTo(reserved + 0.001));
          expect(actual.height, greaterThan(reserved - 1.001));
          expect(tester.takeException(), isNull);
        }
      }
    }
  });

  testWidgets(
    'reduced motion still paints one final pair without transitions',
    (tester) async {
      await tester.pumpWidget(app(active: true, reducedMotion: true));
      await tester.pumpAndSettle();
      expect(paragraphs(tester), hasLength(2));
      expect(
        find.descendant(
          of: find.byType(LyricsTextStyleTransition),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
