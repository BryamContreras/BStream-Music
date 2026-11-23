import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart' show immutable, listEquals;

/// Edge colors and a small spatial map from the visible video frame.
@immutable
final class ArtworkVideoPalette {
  const ArtworkVideoPalette({required this.top, required this.bottom})
    : cells = null;

  ArtworkVideoPalette.withCells({
    required this.top,
    required this.bottom,
    required List<Color> cells,
  }) : assert(cells.length == _cellCount),
       cells = List.unmodifiable(cells);

  static const meshExtent = 4;
  static const _cellCount = meshExtent * meshExtent;
  static const _maxSamplesPerSide = 8;

  final Color top;
  final Color bottom;

  /// Row-major from the top left to the bottom right of the sampled crop.
  final List<Color>? cells;

  Color colorForCell(int index) {
    RangeError.checkValueInInterval(index, 0, _cellCount - 1, 'index');
    return cells?[index] ?? _toneForRow(top, bottom, index ~/ meshExtent);
  }

  static Color _toneForRow(Color top, Color bottom, int row) =>
      Color.lerp(top, bottom, row / (meshExtent - 1))!;

  /// Reads a small premultiplied RGBA image. [crop] is the visible rectangle
  /// in normalized image coordinates, before the backdrop fades are painted.
  static ArtworkVideoPalette? fromRgba(
    Uint8List rgba,
    int width,
    int height, {
    Rect? crop,
  }) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      return null;
    }
    final visible = crop ?? const Rect.fromLTWH(0, 0, 1, 1);
    if (!visible.isFinite || visible.isEmpty) return null;
    final left = (visible.left.clamp(0.0, 1.0) * width).floor();
    final right = (visible.right.clamp(0.0, 1.0) * width).ceil();
    final top = (visible.top.clamp(0.0, 1.0) * height).floor();
    final bottom = (visible.bottom.clamp(0.0, 1.0) * height).ceil();
    if (left >= right || top >= bottom) return null;

    // Discard transparent texture reads and near-black letterboxing before
    // choosing the bands. A single opaque color across the frame is valid.
    bool isContent(int pixel) =>
        rgba[pixel + 3] >= 240 &&
        (rgba[pixel] > 12 || rgba[pixel + 1] > 12 || rgba[pixel + 2] > 12);

    bool hasContent(int row) {
      final start = (row * width + left) * 4;
      final end = (row * width + right) * 4;
      for (var pixel = start; pixel < end; pixel += 4) {
        if (isContent(pixel)) return true;
      }
      return false;
    }

    var contentTop = top;
    while (contentTop < bottom && !hasContent(contentTop)) {
      contentTop++;
    }
    if (contentTop == bottom) return null;
    var contentBottom = bottom - 1;
    while (contentBottom > contentTop && !hasContent(contentBottom)) {
      contentBottom--;
    }

    final rows = contentBottom - contentTop + 1;
    final bandSize = math.max(1, (rows * .28).ceil());

    Color? edgeColor(int edge, int direction) {
      var red = 0.0;
      var green = 0.0;
      var blue = 0.0;
      var totalWeight = 0.0;
      for (var offset = 0; offset < bandSize; offset++) {
        final row = edge + offset * direction;
        final weight = 1.0 - offset / (bandSize * 2);
        final start = (row * width + left) * 4;
        final end = (row * width + right) * 4;
        for (var pixel = start; pixel < end; pixel += 4) {
          if (!isContent(pixel)) continue;
          final alpha = rgba[pixel + 3];
          red += rgba[pixel] / alpha * weight;
          green += rgba[pixel + 1] / alpha * weight;
          blue += rgba[pixel + 2] / alpha * weight;
          totalWeight += weight;
        }
      }
      if (totalWeight == 0) return null;
      return Color.from(
        alpha: 1,
        red: (red / totalWeight).clamp(0.0, 1.0),
        green: (green / totalWeight).clamp(0.0, 1.0),
        blue: (blue / totalWeight).clamp(0.0, 1.0),
      );
    }

    final upper = edgeColor(contentTop, 1);
    final lower = edgeColor(contentBottom, -1);
    if (upper == null || lower == null) return null;

    final columns = right - left;
    final measured = List<Color?>.generate(_cellCount, (index) {
      final row = index ~/ meshExtent;
      final column = index % meshExtent;
      final localLeft = columns * column ~/ meshExtent;
      final localTop = rows * row ~/ meshExtent;
      final cellWidth = math.max(
        1,
        columns * (column + 1) ~/ meshExtent - localLeft,
      );
      final cellHeight = math.max(1, rows * (row + 1) ~/ meshExtent - localTop);
      final sampleWidth = math.min(cellWidth, _maxSamplesPerSide);
      final sampleHeight = math.min(cellHeight, _maxSamplesPerSide);
      var red = 0.0;
      var green = 0.0;
      var blue = 0.0;
      var count = 0;
      for (var sampleY = 0; sampleY < sampleHeight; sampleY++) {
        final y =
            contentTop +
            localTop +
            (2 * sampleY + 1) * cellHeight ~/ (2 * sampleHeight);
        for (var sampleX = 0; sampleX < sampleWidth; sampleX++) {
          final x =
              left +
              localLeft +
              (2 * sampleX + 1) * cellWidth ~/ (2 * sampleWidth);
          final pixel = (y * width + x) * 4;
          if (!isContent(pixel)) continue;
          final alpha = rgba[pixel + 3];
          red += rgba[pixel] / alpha;
          green += rgba[pixel + 1] / alpha;
          blue += rgba[pixel + 2] / alpha;
          count++;
        }
      }
      if (count == 0) return null;
      return Color.from(
        alpha: 1,
        red: (red / count).clamp(0.0, 1.0),
        green: (green / count).clamp(0.0, 1.0),
        blue: (blue / count).clamp(0.0, 1.0),
      );
    }, growable: false);

    Color neighboringColor(int index) {
      final row = index ~/ meshExtent;
      final column = index % meshExtent;
      var distance = meshExtent * 2;
      Color? closest;
      for (var candidate = 0; candidate < measured.length; candidate++) {
        final color = measured[candidate];
        if (color == null) continue;
        final candidateDistance =
            (candidate ~/ meshExtent - row).abs() +
            (candidate % meshExtent - column).abs();
        if (candidateDistance < distance) {
          closest = color;
          distance = candidateDistance;
        }
      }
      return closest ?? _toneForRow(upper, lower, row);
    }

    return ArtworkVideoPalette.withCells(
      top: upper,
      bottom: lower,
      cells: [
        for (var index = 0; index < _cellCount; index++)
          measured[index] ?? neighboringColor(index),
      ],
    );
  }

  static ArtworkVideoPalette lerp(
    ArtworkVideoPalette a,
    ArtworkVideoPalette b,
    double t,
  ) {
    if (t == 0) return a;
    if (t == 1) return b;
    final top = Color.lerp(a.top, b.top, t)!;
    final bottom = Color.lerp(a.bottom, b.bottom, t)!;
    if (a.cells == null && b.cells == null) {
      return ArtworkVideoPalette(top: top, bottom: bottom);
    }
    return ArtworkVideoPalette.withCells(
      top: top,
      bottom: bottom,
      cells: [
        for (var index = 0; index < _cellCount; index++)
          Color.lerp(a.colorForCell(index), b.colorForCell(index), t)!,
      ],
    );
  }

  bool isCloseTo(ArtworkVideoPalette other, [double threshold = .012]) {
    bool colorsClose(Color a, Color b) =>
        (a.a - b.a).abs() < threshold &&
        (a.r - b.r).abs() < threshold &&
        (a.g - b.g).abs() < threshold &&
        (a.b - b.b).abs() < threshold;

    if (!colorsClose(top, other.top) || !colorsClose(bottom, other.bottom)) {
      return false;
    }
    if (cells == null && other.cells == null) return true;
    for (var index = 0; index < _cellCount; index++) {
      if (!colorsClose(colorForCell(index), other.colorForCell(index))) {
        return false;
      }
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is ArtworkVideoPalette &&
      top == other.top &&
      bottom == other.bottom &&
      listEquals(cells, other.cells);

  @override
  int get hashCode =>
      Object.hash(top, bottom, cells == null ? null : Object.hashAll(cells!));
}

@immutable
final class ArtworkVideoPaletteSample {
  const ArtworkVideoPaletteSample(this.position, this.palette);

  final Duration position;
  final ArtworkVideoPalette palette;
}

/// A few small color samples from a single video loop; holds no frame pixels.
@immutable
final class ArtworkVideoPaletteTimeline {
  ArtworkVideoPaletteTimeline(
    Iterable<ArtworkVideoPaletteSample> samples, {
    required this.loopStart,
    this.loopEnd,
  }) : samples = List.unmodifiable(
         <Duration, ArtworkVideoPaletteSample>{
           for (final sample in samples) sample.position: sample,
         }.values.toList()..sort((a, b) => a.position.compareTo(b.position)),
       );

  final List<ArtworkVideoPaletteSample> samples;
  final Duration loopStart;

  /// Supply the end once sampling is complete to blend across the loop cut.
  final Duration? loopEnd;

  ArtworkVideoPalette? paletteAt(Duration position) {
    if (samples.isEmpty) return null;
    final first = samples.first;
    if (samples.length == 1) return first.palette;
    final last = samples.last;
    final end = loopEnd;
    final span = end == null ? Duration.zero : end - loopStart;
    final wrap =
        end != null &&
        span > last.position - first.position &&
        loopStart <= first.position &&
        last.position <= end;
    if (wrap) {
      final offset =
          (position - loopStart).inMicroseconds % span.inMicroseconds;
      position = loopStart + Duration(microseconds: offset);
    }
    if (position < first.position) {
      return wrap
          ? _blend(last.palette, last.position - span, first, position)
          : first.palette;
    }
    for (var index = 1; index < samples.length; index++) {
      final next = samples[index];
      if (position <= next.position) {
        final previous = samples[index - 1];
        return _blend(previous.palette, previous.position, next, position);
      }
    }
    return wrap
        ? _blend(
            last.palette,
            last.position,
            ArtworkVideoPaletteSample(first.position + span, first.palette),
            position,
          )
        : last.palette;
  }

  static ArtworkVideoPalette _blend(
    ArtworkVideoPalette from,
    Duration start,
    ArtworkVideoPaletteSample to,
    Duration position,
  ) {
    final t =
        (position - start).inMicroseconds /
        (to.position - start).inMicroseconds;
    return ArtworkVideoPalette.lerp(from, to.palette, t * t * (3 - 2 * t));
  }
}
