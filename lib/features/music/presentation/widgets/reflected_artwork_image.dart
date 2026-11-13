import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Extends a cover below its lower edge by reflecting the same decoded image.
///
/// [artworkRect] matches the unreflected foreground cover. Narrow photos extend
/// their edge colors sideways and reflect below their lower edge.
/// The caller owns [image] and the surrounding backdrop supplies its blur;
/// painting the reflection performs no image loading.
class ReflectedArtworkImage extends StatelessWidget {
  const ReflectedArtworkImage({
    required this.image,
    required this.artworkRect,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.medium,
    super.key,
  });

  final ui.Image image;
  final Rect artworkRect;

  /// Matches the foreground image's cover crop before reflecting its edge.
  final Alignment alignment;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.infinite,
    painter: _ReflectedArtworkPainter(
      image: image,
      artworkRect: artworkRect,
      alignment: alignment,
      filterQuality: filterQuality,
    ),
  );
}

/// A retained, small raster with a soft reflection that blurs further below
/// the cover. The two blur passes run only when the image or geometry changes;
/// ordinary paints draw the resulting bitmap once.
class ProgressiveReflectedArtworkImage extends StatefulWidget {
  const ProgressiveReflectedArtworkImage({
    required this.image,
    required this.artworkRect,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.medium,
    super.key,
  });

  final ui.Image image;
  final Rect artworkRect;

  /// Matches the foreground image's cover crop before reflecting its edge.
  final Alignment alignment;
  final FilterQuality filterQuality;

  @override
  State<ProgressiveReflectedArtworkImage> createState() =>
      _ProgressiveReflectedArtworkImageState();
}

class _ProgressiveReflectedArtworkImageState
    extends State<ProgressiveReflectedArtworkImage> {
  ui.Image? _raster;
  ui.Image? _source;
  Rect? _artworkRect;
  Alignment? _alignment;
  Size? _viewport;
  FilterQuality? _filterQuality;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = constraints.biggest;
      if (!viewport.isFinite ||
          viewport.isEmpty ||
          !widget.artworkRect.isFinite ||
          widget.artworkRect.isEmpty) {
        return const SizedBox.shrink();
      }
      if (_raster == null ||
          !identical(_source, widget.image) ||
          _artworkRect != widget.artworkRect ||
          _alignment != widget.alignment ||
          _viewport != viewport ||
          _filterQuality != widget.filterQuality) {
        final raster = _rasterizeProgressiveReflection(
          image: widget.image,
          artworkRect: widget.artworkRect,
          alignment: widget.alignment,
          viewport: viewport,
          filterQuality: widget.filterQuality,
        );
        final previous = _raster;
        _raster = raster;
        _source = widget.image;
        _artworkRect = widget.artworkRect;
        _alignment = widget.alignment;
        _viewport = viewport;
        _filterQuality = widget.filterQuality;
        previous?.dispose();
      }
      return RawImage(
        key: const ValueKey('progressive-reflected-artwork-raster'),
        image: _raster,
        fit: BoxFit.fill,
        filterQuality: widget.filterQuality,
      );
    },
  );

  @override
  void dispose() {
    _raster?.dispose();
    super.dispose();
  }
}

ui.Image _rasterizeProgressiveReflection({
  required ui.Image image,
  required Rect artworkRect,
  required Alignment alignment,
  required Size viewport,
  required FilterQuality filterQuality,
}) {
  final ratio = math.min(
    1.0,
    math.min(240 / viewport.width, 2048 / viewport.height),
  );
  final width = math.max(1, (viewport.width * ratio).round());
  final height = math.max(1, (viewport.height * ratio).round());
  final scaleX = width / viewport.width;
  final scaleY = height / viewport.height;
  final rasterSize = Size(width.toDouble(), height.toDouble());
  final rasterBounds = Offset.zero & rasterSize;
  final rasterRect = Rect.fromLTRB(
    artworkRect.left * scaleX,
    artworkRect.top * scaleY,
    artworkRect.right * scaleX,
    artworkRect.bottom * scaleY,
  );
  final painter = _ReflectedArtworkPainter(
    image: image,
    artworkRect: rasterRect,
    alignment: alignment,
    filterQuality: filterQuality,
  );
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  void paintBlur(double sigma) {
    canvas.saveLayer(
      rasterBounds,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma * scaleX,
          sigmaY: sigma * scaleY,
          tileMode: TileMode.clamp,
          bounds: rasterBounds,
        ),
    );
    painter.paint(canvas, rasterSize);
    canvas.restore();
  }

  paintBlur(18);

  final start = (rasterRect.top + rasterRect.height * 0.62).clamp(
    0.0,
    rasterSize.height,
  );
  final end = (rasterRect.bottom + rasterRect.height * 0.42).clamp(
    0.0,
    rasterSize.height,
  );
  if (start < rasterSize.height) {
    canvas.saveLayer(rasterBounds, Paint());
    paintBlur(64);
    if (end > start) {
      const intervals = 16;
      final stops = <double>[];
      final colors = <Color>[];
      for (var index = 0; index <= intervals; index += 1) {
        final t = index / intervals;
        stops.add(t);
        colors.add(Colors.white.withValues(alpha: t * t * (3 - 2 * t)));
      }
      final mask = ui.Gradient.linear(
        Offset(0, start),
        Offset(0, end),
        colors,
        stops,
      );
      canvas.drawRect(
        rasterBounds,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = mask,
      );
      mask.dispose();
    }
    canvas.restore();
  }

  final picture = recorder.endRecording();
  try {
    // The handle is immediate; the engine rasterizes this small picture on its
    // raster thread. No asynchronous listener or per-frame blur is needed.
    return picture.toImageSync(width, height);
  } finally {
    picture.dispose();
  }
}

class _ReflectedArtworkPainter extends CustomPainter {
  const _ReflectedArtworkPainter({
    required this.image,
    required this.artworkRect,
    required this.alignment,
    required this.filterQuality,
  });

  final ui.Image image;
  final Rect artworkRect;
  final Alignment alignment;
  final FilterQuality filterQuality;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty ||
        artworkRect.isEmpty ||
        !artworkRect.left.isFinite ||
        !artworkRect.top.isFinite ||
        !artworkRect.width.isFinite ||
        !artworkRect.height.isFinite) {
      return;
    }

    // Extreme proportions use a single cover for the blurred background.
    // Ordinary photos retain their exact reflected lower edge.
    final repeatedRect =
        size.width / artworkRect.width > 31 ||
            size.height / artworkRect.height > 31
        ? Offset.zero & size
        : artworkRect;
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitted = applyBoxFit(BoxFit.cover, imageSize, repeatedRect.size);
    final source = alignment.inscribe(fitted.source, Offset.zero & imageSize);
    final destination = Offset.zero & repeatedRect.size;
    final tileWidth = repeatedRect.width;
    final tileHeight = repeatedRect.height;
    final firstTile = (-repeatedRect.top / tileHeight).floor();
    final lastTile = ((size.height - repeatedRect.top) / tileHeight).ceil() - 1;
    final paint = Paint()..filterQuality = filterQuality;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var tile = firstTile; tile <= lastTile; tile += 1) {
      final top = repeatedRect.top + tile * tileHeight;
      canvas.save();
      canvas.translate(repeatedRect.left, tile.isOdd ? top + tileHeight : top);
      if (tile.isOdd) canvas.scale(1, -1);
      canvas.drawImageRect(image, source, destination, paint);
      // Extend only edge colors into the blurred sides. Repeating the whole
      // portrait would introduce extra faces beside the focused artist.
      final edgeWidth = math.min(1.0, source.width);
      if (repeatedRect.left > 0) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(source.left, source.top, edgeWidth, source.height),
          Rect.fromLTWH(-repeatedRect.left, 0, repeatedRect.left, tileHeight),
          paint,
        );
      }
      if (repeatedRect.right < size.width) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(
            source.right - edgeWidth,
            source.top,
            edgeWidth,
            source.height,
          ),
          Rect.fromLTWH(
            tileWidth,
            0,
            size.width - repeatedRect.right,
            tileHeight,
          ),
          paint,
        );
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReflectedArtworkPainter oldDelegate) =>
      !identical(image, oldDelegate.image) ||
      artworkRect != oldDelegate.artworkRect ||
      alignment != oldDelegate.alignment ||
      filterQuality != oldDelegate.filterQuality;
}
