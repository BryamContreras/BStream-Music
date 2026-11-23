import 'dart:typed_data';
import 'dart:ui';

import 'package:bstream_music/features/music/presentation/widgets/artwork_video_palette.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const blue = Color(0xff27628c);
  const gold = Color(0xff625741);
  const alphaZero = Color(0x00000000);
  const black = Color(0xff080808);

  test(
    'preserves both source edges while discarding bars and blank pixels',
    () {
      final rgba = _frame(8, 12, (x, y) {
        if (y < 2 || y >= 10 || x == 0 || x == 7) return black;
        if (x == 1) return alphaZero;
        return y < 6 ? blue : gold;
      });
      final palette = ArtworkVideoPalette.fromRgba(rgba, 8, 12)!;
      expect(palette.top.toARGB32(), blue.toARGB32());
      expect(palette.bottom.toARGB32(), gold.toARGB32());
      expect(palette.colorForCell(0).toARGB32(), blue.toARGB32());
      expect(palette.colorForCell(15).toARGB32(), gold.toARGB32());
    },
  );

  test('samples the displayed crop and accepts a flat color', () {
    final rgba = _frame(10, 10, (x, y) {
      if (x < 2 || x >= 8 || y < 2 || y >= 8) return gold;
      return blue;
    });
    final palette = ArtworkVideoPalette.fromRgba(
      rgba,
      10,
      10,
      crop: const Rect.fromLTRB(.2, .2, .8, .8),
    )!;
    expect(palette.top.toARGB32(), blue.toARGB32());
    expect(palette.bottom.toARGB32(), blue.toARGB32());
    expect(
      palette.cells!.map((color) => color.toARGB32()),
      everyElement(blue.toARGB32()),
    );
  });

  test('retains local colors within each row and column', () {
    const green = Color(0xff208c32);
    const red = Color(0xffb52835);
    final rgba = _frame(20, 16, (x, y) {
      if (x < 2 || x >= 18) return blue;
      if (y < 8) return x < 10 ? red : green;
      return x < 10 ? green : gold;
    });
    final palette = ArtworkVideoPalette.fromRgba(
      rgba,
      20,
      16,
      crop: const Rect.fromLTRB(.1, 0, .9, 1),
    )!;
    expect(palette.cells!.length, ArtworkVideoPalette.meshExtent * 4);
    expect(palette.colorForCell(0).toARGB32(), red.toARGB32());
    expect(palette.colorForCell(3).toARGB32(), green.toARGB32());
    expect(palette.colorForCell(12).toARGB32(), green.toARGB32());
    expect(palette.colorForCell(15).toARGB32(), gold.toARGB32());
  });

  test('rejects empty textures, decoder black and out-of-bounds crops', () {
    expect(ArtworkVideoPalette.fromRgba(Uint8List(8), 10, 10), isNull);
    expect(
      ArtworkVideoPalette.fromRgba(_frame(2, 2, (_, _) => alphaZero), 2, 2),
      isNull,
    );
    expect(
      ArtworkVideoPalette.fromRgba(_frame(2, 2, (_, _) => black), 2, 2),
      isNull,
    );
    expect(
      ArtworkVideoPalette.fromRgba(
        _frame(2, 2, (_, _) => blue),
        2,
        2,
        crop: const Rect.fromLTRB(2, 2, 3, 3),
      ),
      isNull,
    );
  });

  const first = ArtworkVideoPalette(top: blue, bottom: gold);
  const last = ArtworkVideoPalette(top: gold, bottom: blue);

  test('blends and compares spatial changes even with matching edges', () {
    final mutable = List.filled(16, blue);
    final frameA = ArtworkVideoPalette.withCells(
      top: first.top,
      bottom: first.bottom,
      cells: mutable,
    );
    mutable[9] = gold;
    final frameB = ArtworkVideoPalette.withCells(
      top: first.top,
      bottom: first.bottom,
      cells: mutable,
    );
    expect(frameA.cells![9], blue);
    expect(frameB.cells!.removeLast, throwsUnsupportedError);
    expect(frameA, isNot(frameB));
    expect(frameA.isCloseTo(frameB), isFalse);
    expect(frameA.isCloseTo(frameB, .5), isTrue);
    expect(first.colorForCell(0), blue);
    expect(first.colorForCell(15), gold);

    final middle = ArtworkVideoPalette.lerp(frameA, frameB, .5);
    expect(middle.colorForCell(9), Color.lerp(blue, gold, .5));
    expect(middle.colorForCell(8), blue);
    expect(
      ArtworkVideoPalette.lerp(first, frameB, .5).colorForCell(9),
      Color.lerp(first.colorForCell(9), gold, .5),
    );
  });

  test(
    'sorts samples, blends each edge, and keeps the loop seam continuous',
    () {
      final timeline = ArtworkVideoPaletteTimeline(
        const [
          ArtworkVideoPaletteSample(Duration(seconds: 6), last),
          ArtworkVideoPaletteSample(Duration(seconds: 4), first),
        ],
        loopStart: const Duration(seconds: 3),
        loopEnd: const Duration(seconds: 7),
      );

      const firstFrame = Duration(seconds: 4);
      const midpoint = Duration(seconds: 5);
      const lastFrame = Duration(seconds: 6);
      expect(timeline.paletteAt(firstFrame), first);
      expect(timeline.paletteAt(lastFrame), last);
      final mixed = ArtworkVideoPalette.lerp(first, last, .5);
      expect(timeline.paletteAt(midpoint), mixed);
      expect(timeline.paletteAt(const Duration(seconds: 3)), mixed);
      expect(timeline.paletteAt(const Duration(seconds: 7)), mixed);
      expect(timeline.paletteAt(const Duration(seconds: 8)), first);
    },
  );

  test(
    'partial timeline preserves boundary colors until a loop is available',
    () {
      const start = Duration.zero;
      const at2 = Duration(seconds: 2);
      const at4 = Duration(seconds: 4);
      const at6 = Duration(seconds: 6);
      final timeline = ArtworkVideoPaletteTimeline(const [
        ArtworkVideoPaletteSample(at2, last),
        ArtworkVideoPaletteSample(at2, first),
        ArtworkVideoPaletteSample(at4, last),
      ], loopStart: start);
      expect(timeline.samples.length, 2);
      expect(timeline.paletteAt(start), first);
      expect(timeline.paletteAt(at6), last);
      expect(
        ArtworkVideoPaletteTimeline(const [], loopStart: start).paletteAt(at2),
        isNull,
      );
    },
  );
}

Uint8List _frame(int width, int height, Color Function(int, int) pixelColor) {
  final bytes = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final rgba = pixelColor(x, y).toARGB32();
      final index = (y * width + x) * 4;
      bytes[index] = (rgba >> 16) & 255;
      bytes[index + 1] = (rgba >> 8) & 255;
      bytes[index + 2] = rgba & 255;
      bytes[index + 3] = rgba >> 24;
    }
  }
  return bytes;
}
