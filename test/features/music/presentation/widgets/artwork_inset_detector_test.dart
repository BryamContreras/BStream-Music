import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bstream_music/features/music/presentation/widgets/artwork_inset_detector.dart';
import 'package:flutter_test/flutter_test.dart';

ArtworkInsetFrame _frame(
  int width,
  int height,
  List<int> Function(int, int) rgb,
) {
  final bytes = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final color = rgb(x, y);
      final offset = (y * width + x) * 4;
      bytes[offset] = color[0];
      bytes[offset + 1] = color[1];
      bytes[offset + 2] = color[2];
      bytes[offset + 3] = 255;
    }
  }
  return ArtworkInsetFrame(bytes, width, height);
}

List<int> _coverPixel(int x, int y) => [
  (128 + 65 * math.sin(x / 9) + 50 * math.cos(y / 13)).round().clamp(0, 255),
  (128 + 70 * math.sin((x + y) / 12)).round().clamp(0, 255),
  (128 + 65 * math.cos((x - y) / 11)).round().clamp(0, 255),
];

void main() {
  test('fits a square cover embedded in a portrait video', () {
    final cover = _frame(80, 80, _coverPixel);
    final video = _frame(160, 220, (x, y) {
      if (x >= 29 && x < 131 && y >= 35 && y < 137) {
        return _coverPixel((x - 29) * 80 ~/ 102, (y - 35) * 80 ~/ 102);
      }
      final tone = (105 + x / 8 + y / 12).round();
      return [tone, tone + 6, tone + 11];
    });

    expect(
      detectArtworkInsetZoom(video: video, cover: cover),
      greaterThan(1.2),
    );
    expect(detectArtworkInsetZoom(video: video), greaterThan(1.2));
    final unrelatedCover = _frame(80, 80, (x, y) => _coverPixel(y + 31, x + 8));
    expect(
      detectArtworkInsetZoom(video: video, cover: unrelatedCover),
      greaterThan(1.2),
    );
  });

  test('does not crop a full-bleed portrait video', () {
    final video = _frame(160, 220, (x, y) => _coverPixel(x, y));
    final cover = _frame(160, 160, (x, y) => _coverPixel(x, y + 30));

    expect(detectArtworkInsetZoom(video: video, cover: cover), 1);
    expect(detectArtworkInsetZoom(video: video), 1);
  });

  test('keeps original framing when the still cover does not match', () {
    final video = _frame(160, 220, (x, y) => _coverPixel(x, y));
    final cover = _frame(80, 80, (x, y) => _coverPixel(y + 31, x + 8));

    expect(detectArtworkInsetZoom(video: video, cover: cover), 1);
  });
}
