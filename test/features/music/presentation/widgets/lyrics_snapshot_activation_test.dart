import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/lyrics_glyph_snapshot.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_text_style_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const original = '曖昧な言葉なんかじゃ何一つ叶わない';
  const secondary =
      'aimai na kotoba nanka ja nani hitotsu kanawanai '
      'haruka mirai e ima kakedashitan da';
  const boundaryKey = ValueKey('row-pixels');
  const activeStyle = TextStyle(
    inherit: false,
    color: Colors.white,
    fontSize: 28,
    height: 1.16,
    fontWeight: FontWeight.w900,
    shadows: [
      Shadow(color: Colors.cyan, blurRadius: 10),
      Shadow(color: Color(0x3D00FFFF), blurRadius: 26),
    ],
  );

  Widget app({
    required bool active,
    bool compatibleCompanion = true,
    double width = 336,
  }) => MaterialApp(
    home: Center(
      child: RepaintBoundary(
        key: boundaryKey,
        child: ColoredBox(
          color: Colors.black,
          child: SizedBox(
            width: 400,
            height: 320,
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
                  inactiveStyle: activeStyle.copyWith(
                    color: (compatibleCompanion ? Colors.white : Colors.orange)
                        .withValues(alpha: 0.38),
                    fontSize: 27,
                    shadows: const [],
                  ),
                  secondaryFontSize: 16.8,
                  textAlign: TextAlign.start,
                  contentKey: const ValueKey('pair'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  LyricsGlyphSnapshot snapshot(WidgetTester tester) =>
      tester.widget<LyricsGlyphSnapshot>(find.byType(LyricsGlyphSnapshot));

  SnapshotController snapshotController(WidgetTester tester) =>
      tester.widget<SnapshotWidget>(find.byType(SnapshotWidget)).controller;

  List<RenderParagraph> paragraphs(WidgetTester tester) => tester
      .renderObjectList<RenderParagraph>(find.byType(RichText))
      .toList(growable: false);

  Future<Uint8List> pixels(WidgetTester tester) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    return (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        return Uint8List.fromList(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    }))!;
  }

  for (final compatible in [true, false]) {
    testWidgets(
      '${compatible ? 'shared' : 'fallback'} companion captures at zero alpha and retains its raster throughout selection',
      (tester) async {
        await tester.pumpWidget(
          app(active: false, compatibleCompanion: compatible),
        );
        final retainedParagraphs = paragraphs(tester);
        final rowRect = tester.getRect(find.byKey(const ValueKey('pair')));
        final before = await pixels(tester);

        await tester.pumpWidget(
          app(active: true, compatibleCompanion: compatible),
        );
        expect(snapshot(tester).enabled, isTrue);
        expect(snapshot(tester).opacity!.value, 0);
        expect(snapshotController(tester).allowSnapshotting, isTrue);
        expect(tester.getRect(find.byKey(const ValueKey('pair'))), rowRect);
        expect(paragraphs(tester), unorderedEquals(retainedParagraphs));
        expect(await pixels(tester), orderedEquals(before));

        final controller = snapshotController(tester);
        var snapshotInvalidations = 0;
        void invalidated() => snapshotInvalidations++;
        controller.addListener(invalidated);
        final previousCallback = debugOnProfilePaint;
        var paragraphPaints = 0;
        debugOnProfilePaint = (renderObject) {
          if (renderObject is RenderParagraph &&
              renderObject.text.toPlainText() == original &&
              renderObject.text.style!.fontSize == 28) {
            paragraphPaints++;
          }
        };
        try {
          // A rebuild before the controller advances from zero must not
          // clear the bitmap that selection has just captured.
          await tester.pumpWidget(
            app(active: true, compatibleCompanion: compatible),
          );
          expect(snapshot(tester).enabled, isTrue);
          expect(snapshot(tester).opacity!.value, 0);
          expect(controller.allowSnapshotting, isTrue);
          expect(snapshotInvalidations, 0);
          await tester.pumpAndSettle();
          expect(snapshotInvalidations, 0);
          expect(paragraphPaints, 0);
          expect(paragraphs(tester), unorderedEquals(retainedParagraphs));

          await tester.pumpWidget(
            app(active: false, compatibleCompanion: compatible),
          );
          await tester.pumpAndSettle();
          expect(snapshot(tester).enabled, isFalse);
          expect(controller.allowSnapshotting, isFalse);
          expect(snapshotInvalidations, 1);
          expect(paragraphs(tester), unorderedEquals(retainedParagraphs));
        } finally {
          debugOnProfilePaint = previousCallback;
          controller.removeListener(invalidated);
        }
        expect(tester.getRect(find.byKey(const ValueKey('pair'))), rowRect);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('canceling a zero-alpha entrance releases its bitmap', (
    tester,
  ) async {
    await tester.pumpWidget(app(active: false));
    await tester.pumpWidget(app(active: true));
    final controller = snapshotController(tester);
    expect(controller.allowSnapshotting, isTrue);
    expect(snapshot(tester).opacity!.value, 0);
    await tester.pumpWidget(app(active: false));
    expect(snapshot(tester).opacity!.value, 0);
    expect(controller.allowSnapshotting, isFalse);
    expect(tester.takeException(), isNull);
  });
}
