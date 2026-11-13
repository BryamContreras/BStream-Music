import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/reflected_artwork_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'extends edge colors beside a narrow photo without repeating its subject',
    (tester) async {
      final source = (await tester.runAsync(_createQuadrantImage))!;
      try {
        final pixels = await _capture(
          tester,
          source,
          const Rect.fromLTWH(80, 20, 80, 80),
          const Size(240, 180),
        );

        // Side extensions hold the adjacent edge; only the lower continuation
        // reflects the photo. Duplicated faces cannot enter from a side tile.
        expect(pixels.argbAt(0, 40), Colors.red.toARGB32());
        expect(pixels.argbAt(79, 40), Colors.red.toARGB32());
        expect(pixels.argbAt(80, 40), Colors.red.toARGB32());
        expect(pixels.argbAt(159, 40), Colors.yellow.toARGB32());
        expect(pixels.argbAt(160, 40), Colors.yellow.toARGB32());
        expect(pixels.argbAt(239, 40), Colors.yellow.toARGB32());
        for (final y in [0, 40, 80, 99, 100, 140, 179]) {
          expect(pixels.argbAt(79, y), pixels.argbAt(80, y));
          expect(pixels.argbAt(159, y), pixels.argbAt(160, y));
        }
        for (final x in [0, 40, 80, 100, 140, 159, 160, 200, 239]) {
          expect(pixels.argbAt(x, 99), pixels.argbAt(x, 100));
        }
        expect(pixels.argbAt(100, 99), Colors.cyan.toARGB32());
        expect(pixels.argbAt(100, 100), Colors.cyan.toARGB32());
        expect(pixels.argbAt(100, 179), Colors.red.toARGB32());
        pixels.expectOpaque();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        source.dispose();
      }
    },
  );

  testWidgets('retained blur stays opaque beside a narrow centered portrait', (
    tester,
  ) async {
    final source = (await tester.runAsync(_createWhiteImage))!;
    try {
      final pixels = await _capture(
        tester,
        source,
        const Rect.fromLTWH(120, 16, 80, 160),
        const Size(320, 420),
        progressive: true,
      );
      for (var y = 0; y < pixels.height; y += 1) {
        for (final x in [0, 50, 119, 120, 160, 199, 200, 269, 319]) {
          final argb = pixels.argbAt(x, y);
          expect((argb >> 24) & 255, greaterThanOrEqualTo(254));
          expect((argb >> 16) & 255, greaterThanOrEqualTo(250));
          expect((argb >> 8) & 255, greaterThanOrEqualTo(250));
          expect(argb & 255, greaterThanOrEqualTo(250));
        }
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      source.dispose();
    }
  });

  for (final rect in [
    const Rect.fromLTWH(159.9995, 0, 0.001, 160),
    const Rect.fromLTWH(0, 0, 320, 0.001),
  ]) {
    testWidgets('fills extreme proportions without unbounded tiling: $rect', (
      tester,
    ) async {
      final source = (await tester.runAsync(_createWhiteImage))!;
      try {
        final pixels = await _capture(
          tester,
          source,
          rect,
          const Size(320, 420),
        );
        pixels.expectOpaque();
        for (final position in [
          const Offset(0, 0),
          const Offset(160, 210),
          const Offset(319, 419),
        ]) {
          expect(
            pixels.argbAt(position.dx.toInt(), position.dy.toInt()),
            Colors.white.toARGB32(),
          );
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        source.dispose();
      }
    });
  }

  testWidgets('continues the bottom edge in reverse order without a seam', (
    tester,
  ) async {
    final source = (await tester.runAsync(_createBandedImage))!;
    try {
      final pixels = await _capture(
        tester,
        source,
        const Rect.fromLTWH(-4, -8, 80, 80),
        const Size(72, 180),
      );

      expect(pixels.argbAt(36, 2), Colors.red.toARGB32());
      expect(pixels.argbAt(36, 22), Colors.yellow.toARGB32());
      expect(pixels.argbAt(36, 42), Colors.cyan.toARGB32());
      expect(pixels.argbAt(36, 62), Colors.blue.toARGB32());
      expect(pixels.argbAt(36, 71), Colors.blue.toARGB32());
      expect(pixels.argbAt(36, 72), Colors.blue.toARGB32());
      expect(pixels.argbAt(36, 82), Colors.blue.toARGB32());
      expect(pixels.argbAt(36, 102), Colors.cyan.toARGB32());
      expect(pixels.argbAt(36, 122), Colors.yellow.toARGB32());
      expect(pixels.argbAt(36, 142), Colors.red.toARGB32());
      expect(pixels.argbAt(36, 152), Colors.red.toARGB32());
      expect(pixels.argbAt(36, 162), Colors.red.toARGB32());
      pixels.expectOpaque();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      source.dispose();
    }
  });

  testWidgets('fills above the cover and through tall viewports', (
    tester,
  ) async {
    final source = (await tester.runAsync(_createBandedImage))!;
    try {
      final pixels = await _capture(
        tester,
        source,
        const Rect.fromLTWH(0, 20, 80, 80),
        const Size(80, 350),
      );

      expect(pixels.argbAt(40, 5), Colors.red.toARGB32());
      expect(pixels.argbAt(40, 19), Colors.red.toARGB32());
      expect(pixels.argbAt(40, 20), Colors.red.toARGB32());
      expect(pixels.argbAt(40, 25), Colors.red.toARGB32());
      expect(pixels.argbAt(40, 99), Colors.blue.toARGB32());
      expect(pixels.argbAt(40, 100), Colors.blue.toARGB32());
      expect(pixels.argbAt(40, 179), Colors.red.toARGB32());
      expect(pixels.argbAt(40, 180), Colors.red.toARGB32());
      expect(pixels.argbAt(40, 259), Colors.blue.toARGB32());
      expect(pixels.argbAt(40, 260), Colors.blue.toARGB32());
      pixels.expectOpaque();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      source.dispose();
    }
  });

  testWidgets('reflects the centered cover crop of a landscape source', (
    tester,
  ) async {
    final source = (await tester.runAsync(_createLandscapeImage))!;
    try {
      final pixels = await _capture(
        tester,
        source,
        const Rect.fromLTWH(0, 0, 90, 90),
        const Size(90, 200),
      );

      for (final x in [0, 10, 45, 79, 89]) {
        // The green/yellow side bands lie outside the visible square crop.
        expect(pixels.argbAt(x, 10), Colors.red.toARGB32());
        expect(pixels.argbAt(x, 80), Colors.blue.toARGB32());
        expect(pixels.argbAt(x, 100), Colors.blue.toARGB32());
        expect(pixels.argbAt(x, 170), Colors.red.toARGB32());
      }
      expect(pixels.argbAt(45, 89), pixels.argbAt(45, 90));
      pixels.expectOpaque();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      source.dispose();
    }
  });

  testWidgets('reflects the same upper crop when portrait alignment changes', (
    tester,
  ) async {
    final source = (await tester.runAsync(_createBandedImage))!;
    try {
      const rect = Rect.fromLTWH(0, 0, 80, 40);
      const viewport = Size(80, 90);
      final centered = await _capture(tester, source, rect, viewport);
      final aligned = await _capture(
        tester,
        source,
        rect,
        viewport,
        alignment: const Alignment(0, -0.5),
      );

      // A wide hero crops the square source vertically. Moving the crop
      // upward restores its red upper band instead of beginning in yellow.
      expect(centered.argbAt(40, 5), Colors.yellow.toARGB32());
      expect(aligned.argbAt(40, 5), Colors.red.toARGB32());
      expect(aligned.argbAt(40, 20), Colors.yellow.toARGB32());
      expect(aligned.argbAt(40, 35), Colors.cyan.toARGB32());
      expect(aligned.argbAt(40, 39), aligned.argbAt(40, 40));
      expect(aligned.argbAt(40, 45), Colors.cyan.toARGB32());
      expect(aligned.argbAt(40, 60), Colors.yellow.toARGB32());
      expect(aligned.argbAt(40, 75), Colors.red.toARGB32());
      aligned.expectOpaque();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      source.dispose();
    }
  });

  testWidgets('retained reflection keeps near detail and diffuses it below', (
    tester,
  ) async {
    final source = (await tester.runAsync(_createStripedImage))!;
    try {
      final pixels = await _capture(
        tester,
        source,
        const Rect.fromLTWH(0, 0, 400, 400),
        const Size(400, 590),
        progressive: true,
      );
      final nearContrast = pixels.redRange(60, fromX: 100, toX: 300);
      final lowerContrast = pixels.redRange(575, fromX: 100, toX: 300);
      expect(nearContrast, greaterThan(70));
      expect(lowerContrast, lessThan(nearContrast * 0.45));
      pixels.expectOpaque();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      source.dispose();
    }
  });

  testWidgets('progressive blur has no luminance or opacity dip at the join', (
    tester,
  ) async {
    final source = (await tester.runAsync(_createWhiteImage))!;
    try {
      final pixels = await _capture(
        tester,
        source,
        const Rect.fromLTWH(-12, -18, 344, 344),
        const Size(320, 580),
        progressive: true,
      );
      for (var y = 0; y < pixels.height; y += 1) {
        for (final x in [0, 80, 160, 239, 319]) {
          final argb = pixels.argbAt(x, y);
          // Filtered layers can round alpha down by one channel step.
          expect((argb >> 24) & 255, greaterThanOrEqualTo(254));
          expect((argb >> 16) & 255, greaterThanOrEqualTo(250));
          expect((argb >> 8) & 255, greaterThanOrEqualTo(250));
          expect(argb & 255, greaterThanOrEqualTo(250));
        }
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      source.dispose();
    }
  });

  testWidgets(
    'retains its raster until image or geometry changes and disposes it',
    (tester) async {
      final source = (await tester.runAsync(_createBandedImage))!;
      final nextSource = (await tester.runAsync(_createWhiteImage))!;
      const rasterKey = ValueKey('progressive-reflected-artwork-raster');
      Widget artwork(
        ui.Image image,
        Rect rect,
        Size viewport, {
        Alignment alignment = Alignment.center,
      }) => Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: viewport,
            child: ProgressiveReflectedArtworkImage(
              image: image,
              artworkRect: rect,
              alignment: alignment,
            ),
          ),
        ),
      );
      ui.Image raster() =>
          tester.widget<RawImage>(find.byKey(rasterKey)).image!;
      try {
        const rect = Rect.fromLTWH(-12, -18, 344, 344);
        const viewport = Size(320, 540);
        await tester.pumpWidget(artwork(source, rect, viewport));
        final first = raster();
        expect(first.width, lessThanOrEqualTo(240));
        expect(first.height, lessThanOrEqualTo(2048));

        await tester.pumpWidget(artwork(source, rect, viewport));
        expect(raster(), same(first));
        expect(first.debugDisposed, isFalse);

        final shifted = rect.shift(const Offset(0, -4));
        await tester.pumpWidget(artwork(source, shifted, viewport));
        final second = raster();
        expect(second, isNot(same(first)));
        expect(first.debugDisposed, isTrue);

        await tester.pumpWidget(artwork(source, shifted, const Size(320, 580)));
        final resized = raster();
        expect(resized, isNot(same(second)));
        expect(second.debugDisposed, isTrue);

        await tester.pumpWidget(
          artwork(
            source,
            shifted,
            const Size(320, 580),
            alignment: const Alignment(0, -0.5),
          ),
        );
        final aligned = raster();
        expect(aligned, isNot(same(resized)));
        expect(resized.debugDisposed, isTrue);
        await tester.pumpWidget(
          artwork(
            source,
            shifted,
            const Size(320, 580),
            alignment: const Alignment(0, -0.5),
          ),
        );
        expect(raster(), same(aligned));

        await tester.pumpWidget(
          artwork(
            nextSource,
            shifted,
            const Size(320, 580),
            alignment: const Alignment(0, -0.5),
          ),
        );
        final replaced = raster();
        expect(replaced, isNot(same(aligned)));
        expect(aligned.debugDisposed, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(replaced.debugDisposed, isTrue);
        expect(source.debugDisposed, isFalse);
        expect(nextSource.debugDisposed, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        source.dispose();
        nextSource.dispose();
      }
    },
  );
}

Future<ui.Image> _createStripedImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var index = 0; index < 8; index += 1) {
    canvas.drawRect(
      Rect.fromLTWH(index * 64, 0, 64, 512),
      Paint()..color = index.isEven ? Colors.black : Colors.white,
    );
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(512, 512);
  } finally {
    picture.dispose();
  }
}

Future<ui.Image> _createWhiteImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 64, 64),
    Paint()..color = Colors.white,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(64, 64);
  } finally {
    picture.dispose();
  }
}

Future<ui.Image> _createBandedImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const colors = [Colors.red, Colors.yellow, Colors.cyan, Colors.blue];
  for (var index = 0; index < colors.length; index += 1) {
    canvas.drawRect(
      Rect.fromLTWH(0, index * 16, 64, 16),
      Paint()..color = colors[index],
    );
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(64, 64);
  } finally {
    picture.dispose();
  }
}

Future<ui.Image> _createQuadrantImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const colors = [Colors.red, Colors.yellow, Colors.cyan, Colors.blue];
  for (var index = 0; index < colors.length; index += 1) {
    canvas.drawRect(
      Rect.fromLTWH((index % 2) * 32, (index ~/ 2) * 32, 32, 32),
      Paint()..color = colors[index],
    );
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(64, 64);
  } finally {
    picture.dispose();
  }
}

Future<ui.Image> _createLandscapeImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 160, 45),
    Paint()..color = Colors.red,
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 45, 160, 45),
    Paint()..color = Colors.blue,
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 32, 90),
    Paint()..color = Colors.green,
  );
  canvas.drawRect(
    const Rect.fromLTWH(128, 0, 32, 90),
    Paint()..color = Colors.yellow,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(160, 90);
  } finally {
    picture.dispose();
  }
}

Future<_Pixels> _capture(
  WidgetTester tester,
  ui.Image source,
  Rect artworkRect,
  Size viewport, {
  bool progressive = false,
  Alignment alignment = Alignment.center,
}) async {
  const captureKey = ValueKey('reflection-capture');
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: captureKey,
          child: SizedBox.fromSize(
            size: viewport,
            child: progressive
                ? ProgressiveReflectedArtworkImage(
                    image: source,
                    artworkRect: artworkRect,
                    alignment: alignment,
                    filterQuality: FilterQuality.none,
                  )
                : ReflectedArtworkImage(
                    image: source,
                    artworkRect: artworkRect,
                    alignment: alignment,
                    filterQuality: FilterQuality.none,
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureKey),
  );
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
  try {
    final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    return _Pixels(image.width, image.height, data.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

class _Pixels {
  const _Pixels(this.width, this.height, this.bytes);

  final int width;
  final int height;
  final Uint8List bytes;

  int argbAt(int x, int y) {
    final offset = (y * width + x) * 4;
    return (bytes[offset + 3] << 24) |
        (bytes[offset] << 16) |
        (bytes[offset + 1] << 8) |
        bytes[offset + 2];
  }

  int redRange(int y, {required int fromX, required int toX}) {
    var minimum = 255;
    var maximum = 0;
    for (var x = fromX; x <= toX; x += 1) {
      final red = (argbAt(x, y) >> 16) & 255;
      if (red < minimum) minimum = red;
      if (red > maximum) maximum = red;
    }
    return maximum - minimum;
  }

  void expectOpaque() {
    for (var offset = 3; offset < bytes.length; offset += 4) {
      expect(bytes[offset], 255, reason: 'Transparent pixel at ${offset ~/ 4}');
    }
  }
}
