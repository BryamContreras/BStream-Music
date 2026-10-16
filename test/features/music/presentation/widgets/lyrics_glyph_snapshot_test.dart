import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/lyrics_glyph_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app({
    required Widget child,
    double pixelRatio = 1,
    bool reducedMotion = false,
    bool tickerEnabled = true,
  }) => Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: MediaQueryData(
        devicePixelRatio: pixelRatio,
        disableAnimations: reducedMotion,
      ),
      child: TickerMode(
        enabled: tickerEnabled,
        child: Center(child: child),
      ),
    ),
  );

  SnapshotController controller(WidgetTester tester) =>
      tester.widget<SnapshotWidget>(find.byType(SnapshotWidget)).controller;

  testWidgets(
    'snapshot preserves paragraph size, position, object and semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      Widget sample(bool enabled) => app(
        child: LyricsGlyphSnapshot(
          key: const ValueKey('glyph'),
          enabled: enabled,
          width: 180,
          height: 44,
          revision: 'same-text',
          child: const Text('A lyric', key: ValueKey('paragraph')),
        ),
      );
      await tester.pumpWidget(sample(false));
      final rect = tester.getRect(find.byKey(const ValueKey('glyph')));
      final paragraph = tester.renderObject(
        find.byKey(const ValueKey('paragraph')),
      );
      expect(rect.size, const Size(180, 44));
      expect(tester.getRect(find.byKey(const ValueKey('paragraph'))), rect);
      await tester.pumpWidget(sample(true));
      expect(controller(tester).allowSnapshotting, isTrue);
      expect(
        tester.renderObject(find.byKey(const ValueKey('paragraph'))),
        same(paragraph),
      );
      expect(tester.getRect(find.byKey(const ValueKey('glyph'))), rect);
      expect(find.bySemanticsLabel('A lyric'), findsOneWidget);
      expect(
        tester.widget<SnapshotWidget>(find.byType(SnapshotWidget)).autoresize,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('retains glyph paint and refreshes only for revision/size/DPR', (
    tester,
  ) async {
    final painter = _RecordingPainter();
    Widget sample({
      bool enabled = true,
      int revision = 0,
      double width = 180,
      double ratio = 1,
      double scale = 1,
    }) => app(
      pixelRatio: ratio,
      child: Transform.scale(
        scale: scale,
        child: LyricsGlyphSnapshot(
          enabled: enabled,
          width: width,
          height: 44,
          revision: revision,
          child: CustomPaint(painter: painter),
        ),
      ),
    );
    await tester.pumpWidget(sample());
    final initialPaints = painter.paintCount;
    expect(initialPaints, greaterThan(0));
    for (var frame = 1; frame <= 20; frame++) {
      await tester.pumpWidget(sample(scale: 1 - frame * 0.001));
    }
    expect(painter.paintCount, initialPaints);

    await tester.pumpWidget(sample(revision: 1));
    expect(painter.paintCount, initialPaints + 1);
    await tester.pumpWidget(sample(revision: 1, width: 181));
    expect(painter.paintCount, initialPaints + 2);
    await tester.pumpWidget(sample(revision: 1, width: 181, ratio: 2));
    expect(painter.paintCount, initialPaints + 3);
    await tester.pumpWidget(sample(enabled: false));
    expect(controller(tester).allowSnapshotting, isFalse);
    expect(painter.paintCount, greaterThan(initialPaints + 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'oversized glyphs render live instead of allocating huge images',
    (tester) async {
      final painter = _RecordingPainter();
      await tester.pumpWidget(
        app(
          pixelRatio: 4,
          child: LyricsGlyphSnapshot(
            enabled: true,
            width: 700,
            height: 700,
            revision: 0,
            child: CustomPaint(painter: painter),
          ),
        ),
      );
      expect(controller(tester).allowSnapshotting, isFalse);
      expect(painter.paintCount, greaterThan(0));
      expect(
        tester.getSize(find.byType(LyricsGlyphSnapshot)),
        const Size(700, 600),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'releases capture for reduced motion, hidden subtree and lifecycle',
    (tester) async {
      Widget sample({bool reducedMotion = false, bool tickerEnabled = true}) =>
          app(
            reducedMotion: reducedMotion,
            tickerEnabled: tickerEnabled,
            child: const LyricsGlyphSnapshot(
              enabled: true,
              width: 100,
              height: 30,
              revision: 0,
              child: Text('Line'),
            ),
          );
      await tester.pumpWidget(sample());
      final snapshotController = controller(tester);
      expect(snapshotController.allowSnapshotting, isTrue);
      await tester.pumpWidget(sample(reducedMotion: true));
      expect(snapshotController.allowSnapshotting, isFalse);
      await tester.pumpWidget(sample(tickerEnabled: false));
      expect(snapshotController.allowSnapshotting, isFalse);
      await tester.pumpWidget(sample());
      expect(snapshotController.allowSnapshotting, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(snapshotController.allowSnapshotting, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(snapshotController.allowSnapshotting, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(snapshotController.allowSnapshotting, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('transparent overflow capture preserves glow outside paragraph', (
    tester,
  ) async {
    const boundaryKey = ValueKey('halo-boundary');
    Widget sample(bool enabled) => app(
      child: RepaintBoundary(
        key: boundaryKey,
        child: SizedBox(
          width: 300,
          height: 180,
          child: ColoredBox(
            color: Colors.black,
            child: Center(
              child: LyricsGlyphSnapshot(
                enabled: enabled,
                width: 80,
                height: 40,
                revision: 0,
                child: CustomPaint(painter: _GlowPainter()),
              ),
            ),
          ),
        ),
      ),
    );
    Future<Uint8List> capture() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      return (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          return Uint8List.fromList(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      }))!;
    }

    await tester.pumpWidget(sample(false));
    final live = await capture();
    await tester.pumpWidget(sample(true));
    final cached = await capture();
    // The paragraph is x110..190. This pixel belongs solely to its outer halo.
    expect(live[(90 * 300 + 100) * 4 + 1], greaterThan(0));
    var maximumDifference = 0;
    for (var index = 0; index < live.length; index++) {
      final difference = (live[index] - cached[index]).abs();
      if (difference > maximumDifference) maximumDifference = difference;
    }
    expect(maximumDifference, lessThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'zero-opacity prewarm captures once and fades the retained image',
    (tester) async {
      const boundaryKey = ValueKey('prewarm-boundary');
      final opacity = AnimationController(vsync: tester, value: 0);
      addTearDown(opacity.dispose);
      final painter = _RecordingPainter();
      await tester.pumpWidget(
        app(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 120,
              height: 100,
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: LyricsGlyphSnapshot(
                    enabled: true,
                    width: 80,
                    height: 40,
                    revision: 0,
                    opacity: opacity,
                    child: CustomPaint(painter: painter),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final initialPaints = painter.paintCount;
      expect(initialPaints, 1);
      expect(controller(tester).allowSnapshotting, isTrue);
      Future<int> centerGreen() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        return (await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            return data!.getUint8((50 * 120 + 60) * 4 + 1);
          } finally {
            image.dispose();
          }
        }))!;
      }

      expect(await centerGreen(), 0);
      opacity.value = 0.5;
      await tester.pump();
      expect(await centerGreen(), inInclusiveRange(86, 89));
      expect(painter.paintCount, initialPaints);
      opacity.value = 1;
      await tester.pump();
      expect(await centerGreen(), 175);
      expect(painter.paintCount, initialPaints);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opacity replacement and glyph revision invalidate independently',
    (tester) async {
      final firstOpacity = AnimationController(vsync: tester, value: 0);
      final secondOpacity = AnimationController(vsync: tester, value: 0);
      addTearDown(firstOpacity.dispose);
      addTearDown(secondOpacity.dispose);
      final painter = _RecordingPainter();
      Widget sample(Animation<double> opacity, {int revision = 0}) => app(
        child: LyricsGlyphSnapshot(
          enabled: true,
          width: 80,
          height: 40,
          revision: revision,
          opacity: opacity,
          child: CustomPaint(painter: painter),
        ),
      );
      await tester.pumpWidget(sample(firstOpacity));
      expect(painter.paintCount, 1);
      await tester.pumpWidget(sample(secondOpacity));
      expect(painter.paintCount, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      firstOpacity.value = 0.5;
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(sample(secondOpacity, revision: 1));
      expect(painter.paintCount, 2);
      secondOpacity.value = 1;
      await tester.pump();
      expect(painter.paintCount, 2);
      await tester.pumpWidget(const SizedBox());
      secondOpacity.value = 0.5;
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

class _RecordingPainter extends CustomPainter {
  int paintCount = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paintCount++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.green);
  }

  @override
  bool shouldRepaint(covariant _RecordingPainter oldDelegate) => false;
}

class _GlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.green
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _GlowPainter oldDelegate) => false;
}
