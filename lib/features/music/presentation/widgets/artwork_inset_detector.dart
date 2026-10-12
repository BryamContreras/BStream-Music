import 'dart:math' as math;
import 'dart:typed_data';

/// A small RGBA snapshot. The caller owns image decoding and disposal.
class ArtworkInsetFrame {
  const ArtworkInsetFrame(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;

  bool get isValid =>
      width > 0 && height > 0 && rgba.length >= width * height * 4;
}

/// Detects a square album cover embedded in a portrait artwork video.
///
/// A cached still cover can provide a strong visual match. A conservative
/// four-edge check also handles videos whose embedded cover differs from the
/// still image. Neither path depends on title, artist or provider URL.
double detectArtworkInsetZoom({
  required ArtworkInsetFrame video,
  ArtworkInsetFrame? cover,
}) {
  if (!video.isValid || video.height <= video.width) return 1;
  if (cover != null &&
      (!cover.isValid || cover.width < 16 || cover.height < 16)) {
    cover = null;
  }
  if (cover != null && cover.isValid) {
    final matchedZoom = _matchCachedCover(video, cover);
    if (matchedZoom != null) return matchedZoom;
  }
  return _detectSquareEdges(video);
}

double? _matchCachedCover(ArtworkInsetFrame video, ArtworkInsetFrame cover) {
  const sampleSide = 10;
  final coverSamples = _samples(
    cover,
    0,
    0,
    cover.width.toDouble(),
    cover.height.toDouble(),
    sampleSide,
  );
  if (_variance(coverSamples) < 90) return null;

  final fullWidth = video.width.toDouble();
  var fullMatch = -1.0;
  for (var step = 0; step <= 8; step++) {
    final top = (video.height - video.width) * step / 8;
    fullMatch = math.max(
      fullMatch,
      _correlation(
        coverSamples,
        _samples(video, 0, top, fullWidth, fullWidth, sampleSide),
      ),
    );
  }

  var bestMatch = -1.0;
  var bestFraction = 1.0;
  for (final fraction in <double>[0.54, 0.59, 0.64, 0.69, 0.74, 0.79]) {
    final side = video.width * fraction;
    for (final horizontalOffset in <double>[-0.035, 0, 0.035]) {
      final left = (video.width - side) / 2 + video.width * horizontalOffset;
      if (left < 0 || left + side > video.width) continue;
      for (var step = 0; step <= 12; step++) {
        final top = video.height * (0.06 + step * 0.025);
        if (top + side > video.height) continue;
        final match = _correlation(
          coverSamples,
          _samples(video, left, top, side, side, sampleSide),
        );
        if (match > bestMatch) {
          bestMatch = match;
          bestFraction = fraction;
        }
      }
    }
  }

  // A confidently matching full-width crop vetoes the geometric fallback;
  // otherwise a rectangular object inside a full-bleed video could be
  // mistaken for an inset album cover.
  if (fullMatch >= 0.78 && fullMatch > bestMatch + 0.08) return 1;
  if (bestMatch < 0.70 || bestMatch - fullMatch < 0.18) return null;
  return (0.88 / bestFraction).clamp(1.0, 1.45);
}

double _detectSquareEdges(ArtworkInsetFrame video) {
  final width = video.width;
  final height = video.height;
  final scale = height / 192;
  final searchStep = math.max(1, scale.round());
  final alignment = math.max(1, scale.round());
  final baselineOffset = math.max(3, (6 * scale).round());
  final vertical = Float64List((height + 1) * width);
  final horizontal = Float64List(height * (width + 1));

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var verticalGradient = 0.0;
      var horizontalGradient = 0.0;
      if (x > 0 && x < width - 1 && y > 0 && y < height - 1) {
        final offset = (y * width + x) * 4;
        for (var channel = 0; channel < 3; channel++) {
          verticalGradient +=
              (video.rgba[offset - 4 + channel] -
                      video.rgba[offset + 4 + channel])
                  .abs() /
              3;
          horizontalGradient +=
              (video.rgba[offset - width * 4 + channel] -
                      video.rgba[offset + width * 4 + channel])
                  .abs() /
              3;
        }
      }
      vertical[(y + 1) * width + x] =
          vertical[y * width + x] + verticalGradient;
      horizontal[y * (width + 1) + x + 1] =
          horizontal[y * (width + 1) + x] + horizontalGradient;
    }
  }

  double verticalLine(int x, int first, int last) {
    if (x < 1 || x >= width - 1) return 0;
    return (vertical[(last + 1) * width + x] - vertical[first * width + x]) /
        (last - first + 1);
  }

  double horizontalLine(int y, int first, int last) {
    if (y < 1 || y >= height - 1) return 0;
    return (horizontal[y * (width + 1) + last + 1] -
            horizontal[y * (width + 1) + first]) /
        (last - first + 1);
  }

  double verticalEdge(int x, int first, int last) {
    var strongest = 0.0;
    for (var offset = -alignment; offset <= alignment; offset += alignment) {
      strongest = math.max(strongest, verticalLine(x + offset, first, last));
    }
    final nearby =
        (verticalLine(x - baselineOffset, first, last) +
            verticalLine(x + baselineOffset, first, last)) /
        2;
    return strongest / math.max(nearby, 0.1);
  }

  double horizontalEdge(int y, int first, int last) {
    var strongest = 0.0;
    for (var offset = -alignment; offset <= alignment; offset += alignment) {
      strongest = math.max(strongest, horizontalLine(y + offset, first, last));
    }
    final nearby =
        (horizontalLine(y - baselineOffset, first, last) +
            horizontalLine(y + baselineOffset, first, last)) /
        2;
    return strongest / math.max(nearby, 0.1);
  }

  var bestScore = 0.0;
  var bestSide = width;
  for (
    var side = (width * 0.52).round();
    side <= (width * 0.79).round();
    side += searchStep
  ) {
    final margin = math.max(1, (side * 0.05).round());
    final centeredLeft = (width - side) ~/ 2;
    final maxShift = (width * 0.035).round();
    for (var shift = -maxShift; shift <= maxShift; shift += searchStep) {
      final left = centeredLeft + shift;
      final right = left + side;
      if (left - baselineOffset < 1 || right + baselineOffset >= width - 1) {
        continue;
      }
      for (
        var top = (height * 0.06).round();
        top <= (height * 0.32).round() && top + side < height - 1;
        top += searchStep
      ) {
        final bottom = top + side;
        if (top - baselineOffset < 1 || bottom + baselineOffset >= height - 1) {
          continue;
        }
        final firstY = top + margin;
        final lastY = bottom - margin;
        final firstX = left + margin;
        final lastX = right - margin;
        final score = math.min(
          math.min(
            verticalEdge(left, firstY, lastY),
            verticalEdge(right, firstY, lastY),
          ),
          math.min(
            horizontalEdge(top, firstX, lastX),
            horizontalEdge(bottom, firstX, lastX),
          ),
        );
        if (score > bestScore) {
          bestScore = score;
          bestSide = side;
        }
      }
    }
  }
  if (bestScore < 2.65) return 1;
  return (0.88 * width / bestSide).clamp(1.0, 1.45);
}

List<double> _samples(
  ArtworkInsetFrame frame,
  double left,
  double top,
  double width,
  double height,
  int sampleSide,
) {
  final result = List<double>.filled(sampleSide * sampleSide * 3, 0);
  var index = 0;
  for (var y = 0; y < sampleSide; y++) {
    final py = (top + height * (y + 0.5) / sampleSide).floor().clamp(
      0,
      frame.height - 1,
    );
    for (var x = 0; x < sampleSide; x++) {
      final px = (left + width * (x + 0.5) / sampleSide).floor().clamp(
        0,
        frame.width - 1,
      );
      final offset = (py * frame.width + px) * 4;
      result[index++] = frame.rgba[offset].toDouble();
      result[index++] = frame.rgba[offset + 1].toDouble();
      result[index++] = frame.rgba[offset + 2].toDouble();
    }
  }
  return result;
}

double _variance(List<double> samples) {
  final mean = samples.reduce((a, b) => a + b) / samples.length;
  var variance = 0.0;
  for (final sample in samples) {
    final delta = sample - mean;
    variance += delta * delta;
  }
  return variance / samples.length;
}

double _correlation(List<double> first, List<double> second) {
  var correlation = 0.0;
  for (var channel = 0; channel < 3; channel++) {
    var firstMean = 0.0;
    var secondMean = 0.0;
    for (var index = channel; index < first.length; index += 3) {
      firstMean += first[index];
      secondMean += second[index];
    }
    firstMean /= first.length / 3;
    secondMean /= second.length / 3;
    var covariance = 0.0;
    var firstEnergy = 0.0;
    var secondEnergy = 0.0;
    for (var index = channel; index < first.length; index += 3) {
      final a = first[index] - firstMean;
      final b = second[index] - secondMean;
      covariance += a * b;
      firstEnergy += a * a;
      secondEnergy += b * b;
    }
    if (firstEnergy < 1 || secondEnergy < 1) return -1;
    correlation += covariance / math.sqrt(firstEnergy * secondEnergy);
  }
  return correlation / 3;
}
