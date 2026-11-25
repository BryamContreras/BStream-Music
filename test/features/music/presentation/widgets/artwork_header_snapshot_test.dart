import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/artwork_header_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'header snapshots wait for a decoded frame and clear for a fallback',
    (tester) async {
      final frame = ValueNotifier<ui.Image?>(null);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(Colors.red, ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(4, 4);
      picture.dispose();
      addTearDown(frame.dispose);
      addTearDown(image.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Center(
            child: SizedBox.square(
              dimension: 100,
              child: ArtworkHeaderSnapshot(
                revision: 'album',
                builder: (context, onFrame) =>
                    ValueListenableBuilder<ui.Image?>(
                      valueListenable: frame,
                      builder: (context, current, child) {
                        onFrame(current);
                        return RawImage(image: current);
                      },
                    ),
              ),
            ),
          ),
        ),
      );
      final snapshot = tester.widget<SnapshotWidget>(
        find.byType(SnapshotWidget),
      );
      expect(snapshot.controller.allowSnapshotting, isFalse);

      frame.value = image;
      await tester.pump();
      expect(snapshot.controller.allowSnapshotting, isFalse);
      await tester.pump(const Duration(milliseconds: 230));
      expect(snapshot.controller.allowSnapshotting, isTrue);

      frame.value = null;
      await tester.pump();
      expect(snapshot.controller.allowSnapshotting, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('composite waits for every tile and invalidates on change', (
    tester,
  ) async {
    ui.Image cover(Color color) {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(4, 4);
      picture.dispose();
      addTearDown(image.dispose);
      return image;
    }

    final first = cover(Colors.red);
    final second = cover(Colors.blue);
    final replacement = cover(Colors.green);
    final frames = ValueNotifier<List<ui.Image?>>([first, null]);
    addTearDown(frames.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Center(
          child: SizedBox.square(
            dimension: 100,
            child: ArtworkHeaderSnapshot(
              revision: 'mosaic',
              frameCount: 2,
              builder: (_, onFrame) => ValueListenableBuilder<List<ui.Image?>>(
                valueListenable: frames,
                builder: (_, current, _) {
                  for (var index = 0; index < current.length; index++) {
                    onFrame(current[index], index: index);
                  }
                  return Row(
                    children: [
                      for (final image in current)
                        Expanded(child: RawImage(image: image)),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    final controller = tester
        .widget<SnapshotWidget>(find.byType(SnapshotWidget))
        .controller;
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.allowSnapshotting, isFalse);

    frames.value = [first, second];
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 230));
    expect(controller.allowSnapshotting, isTrue);

    frames.value = [replacement, second];
    await tester.pump();
    expect(controller.allowSnapshotting, isFalse);
    await tester.pump(const Duration(milliseconds: 230));
    expect(controller.allowSnapshotting, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late artwork defers capture until scroll settles', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(Colors.red, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(4, 4);
    picture.dispose();
    final frames = ValueNotifier<ui.Image?>(null);
    addTearDown(frames.dispose);
    addTearDown(image.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: SingleChildScrollView(
          child: Column(
            children: [
              SizedBox(
                height: 200,
                child: ArtworkHeaderSnapshot(
                  revision: 'header',
                  builder: (_, onFrame) => ValueListenableBuilder<ui.Image?>(
                    valueListenable: frames,
                    builder: (_, current, _) {
                      onFrame(current);
                      return RawImage(image: current);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 1200),
            ],
          ),
        ),
      ),
    );
    final controller = tester
        .widget<SnapshotWidget>(find.byType(SnapshotWidget))
        .controller;
    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    frames.value = image;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.allowSnapshotting, isFalse);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.allowSnapshotting, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained blur and mask match the live painted artwork', (
    tester,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(Colors.blue, ui.BlendMode.src);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 17, 35),
      Paint()..color = Colors.red,
    );
    final picture = recorder.endRecording();
    final cover = picture.toImageSync(35, 35);
    picture.dispose();
    addTearDown(cover.dispose);

    const captureKey = ValueKey('snapshot-pixel-capture');
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: captureKey,
            child: SizedBox(
              width: 150,
              height: 180,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.black),
                  ArtworkHeaderSnapshot(
                    revision: cover,
                    builder: (_, onFrame) {
                      onFrame(cover);
                      return ClipRect(
                        child: ShaderMask(
                          blendMode: BlendMode.dstIn,
                          shaderCallback: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.white, Colors.transparent],
                          ).createShader,
                          child: ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(
                              sigmaX: 30,
                              sigmaY: 30,
                            ),
                            child: Transform.scale(
                              scale: 1.16,
                              child: RawImage(image: cover, fit: BoxFit.cover),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    Future<List<int>> capture() async {
      final data = await tester.runAsync(() async {
        final image = await boundary.toImage(
          pixelRatio: tester.view.devicePixelRatio,
        );
        try {
          return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      });
      return data!.buffer.asUint8List();
    }

    final live = await capture();
    await tester.pump(const Duration(milliseconds: 230));
    expect(
      tester
          .widget<SnapshotWidget>(find.byType(SnapshotWidget))
          .controller
          .allowSnapshotting,
      isTrue,
    );
    final retained = await capture();
    expect(retained.length, live.length);
    var maximumDifference = 0;
    for (var offset = 0; offset < live.length; offset++) {
      final difference = (live[offset] - retained[offset]).abs();
      if (difference > maximumDifference) maximumDifference = difference;
    }
    // Compositing the premultiplied retained mask can differ by one
    // rounding step compared with replaying the original layer sequence.
    expect(maximumDifference, lessThanOrEqualTo(2));
    expect(tester.takeException(), isNull);
  });
}
