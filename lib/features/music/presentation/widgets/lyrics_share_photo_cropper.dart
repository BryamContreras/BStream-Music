import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/music_providers.dart';

/// Returns the selected source area in normalized image coordinates.
///
/// The caller owns [image] and must keep it alive until this route closes.
/// Pass [initialCrop] to continue editing an existing selection. Dismissing the
/// route returns null and leaves the caller's previous selection intact.
Future<Rect?> showLyricsSharePhotoCropper({
  required BuildContext context,
  required ui.Image image,
  required double aspectRatio,
  Rect? initialCrop,
}) async {
  if (!aspectRatio.isFinite || aspectRatio <= 0) {
    throw ArgumentError.value(aspectRatio, 'aspectRatio');
  }
  final route = MaterialPageRoute<Rect>(
    fullscreenDialog: true,
    builder: (_) => LyricsSharePhotoCropper(
      image: image,
      aspectRatio: aspectRatio,
      initialCrop: initialCrop,
    ),
  );
  final result = await Navigator.of(context, rootNavigator: true).push(route);
  // The pop result arrives before the reverse transition finishes. The caller
  // may dispose a cancelled image as soon as this future completes, so wait
  // until the departing cropper has finished painting it.
  await route.completed;
  return result;
}

/// An event-driven crop editor: it repaints only while the user adjusts a photo.
class LyricsSharePhotoCropper extends ConsumerStatefulWidget {
  const LyricsSharePhotoCropper({
    required this.image,
    required this.aspectRatio,
    this.initialCrop,
    super.key,
  }) : assert(aspectRatio > 0 && aspectRatio < double.infinity);

  final ui.Image image;
  final double aspectRatio;
  final Rect? initialCrop;

  @override
  ConsumerState<LyricsSharePhotoCropper> createState() =>
      _LyricsSharePhotoCropperState();
}

class _LyricsSharePhotoCropperState
    extends ConsumerState<LyricsSharePhotoCropper> {
  static const _maxZoom = 6.0;
  final _focusNode = FocusNode();
  Offset _center = const Offset(.5, .5);
  double _zoom = 1;
  double _gestureStartZoom = 1;
  Offset _gestureAnchor = const Offset(.5, .5);
  Size _frameSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _restoreInitialCrop();
  }

  void _restoreInitialCrop() {
    _zoom = 1;
    _center = const Offset(.5, .5);
    final crop = widget.initialCrop;
    if (crop == null || !crop.isFinite || crop.width <= 0 || crop.height <= 0) {
      return;
    }
    final base = _normalizedSize(1);
    _zoom = math
        .max(base.width / crop.width, base.height / crop.height)
        .clamp(1.0, _maxZoom);
    _center = _boundedCenter(crop.center, _zoom);
  }

  Size get _baseCrop {
    final imageSize = Size(
      widget.image.width.toDouble(),
      widget.image.height.toDouble(),
    );
    return imageSize.aspectRatio > widget.aspectRatio
        ? Size(imageSize.height * widget.aspectRatio, imageSize.height)
        : Size(imageSize.width, imageSize.width / widget.aspectRatio);
  }

  Size _normalizedSize(double zoom) {
    final base = _baseCrop;
    return Size(
      base.width / widget.image.width / zoom,
      base.height / widget.image.height / zoom,
    );
  }

  Offset _boundedCenter(Offset center, double zoom) {
    final size = _normalizedSize(zoom);
    return Offset(
      center.dx.clamp(size.width / 2, 1 - size.width / 2),
      center.dy.clamp(size.height / 2, 1 - size.height / 2),
    );
  }

  Rect get _crop {
    final size = _normalizedSize(_zoom);
    final center = _boundedCenter(_center, _zoom);
    return Rect.fromLTWH(
      center.dx - size.width / 2,
      center.dy - size.height / 2,
      size.width,
      size.height,
    );
  }

  Offset _normalizedPoint(Offset localPoint) {
    final crop = _crop;
    return Offset(
      crop.left + localPoint.dx / _frameSize.width * crop.width,
      crop.top + localPoint.dy / _frameSize.height * crop.height,
    );
  }

  void _zoomAround(double zoom, Offset localPoint, {Offset? anchor}) {
    if (_frameSize.isEmpty) return;
    final nextZoom = zoom.clamp(1.0, _maxZoom);
    final point = anchor ?? _normalizedPoint(localPoint);
    final size = _normalizedSize(nextZoom);
    final center = _boundedCenter(
      point -
          Offset(
            (localPoint.dx / _frameSize.width - .5) * size.width,
            (localPoint.dy / _frameSize.height - .5) * size.height,
          ),
      nextZoom,
    );
    if (nextZoom == _zoom && center == _center) return;
    setState(() {
      _zoom = nextZoom;
      _center = center;
    });
  }

  void _setZoom(double zoom) {
    _zoomAround(zoom, _frameSize.center(Offset.zero));
  }

  void _reset() {
    setState(() {
      _zoom = 1;
      _center = const Offset(.5, .5);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      _setZoom(_zoom * 1.1);
    } else if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _setZoom(_zoom / 1.1);
    } else {
      final delta = switch (key) {
        LogicalKeyboardKey.arrowLeft => const Offset(-1, 0),
        LogicalKeyboardKey.arrowRight => const Offset(1, 0),
        LogicalKeyboardKey.arrowUp => const Offset(0, -1),
        LogicalKeyboardKey.arrowDown => const Offset(0, 1),
        _ => null,
      };
      if (delta == null) return KeyEventResult.ignored;
      final crop = _crop;
      setState(() {
        _center = _boundedCenter(
          _center + Offset(delta.dx * crop.width, delta.dy * crop.height) * .04,
          _zoom,
        );
      });
    }
    return KeyEventResult.handled;
  }

  @override
  void didUpdateWidget(covariant LyricsSharePhotoCropper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image ||
        oldWidget.aspectRatio != widget.aspectRatio ||
        oldWidget.initialCrop != widget.initialCrop) {
      _restoreInitialCrop();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Widget _frame(AppStrings strings) {
    return Center(
      child: AspectRatio(
        aspectRatio: widget.aspectRatio,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _frameSize = constraints.biggest;
            return Focus(
              focusNode: _focusNode,
              autofocus: true,
              onKeyEvent: _onKey,
              child: Semantics(
                label: strings.lyricsShareCropHint,
                image: true,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Listener(
                    onPointerSignal: (event) {
                      if (event is! PointerScrollEvent) return;
                      GestureBinding.instance.pointerSignalResolver.register(
                        event,
                        (_) => _zoomAround(
                          _zoom * math.exp(-event.scrollDelta.dy * .002),
                          event.localPosition,
                        ),
                      );
                    },
                    child: GestureDetector(
                      key: const ValueKey('lyrics-photo-crop-frame'),
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: (details) {
                        _focusNode.requestFocus();
                        _gestureStartZoom = _zoom;
                        _gestureAnchor = _normalizedPoint(
                          details.localFocalPoint,
                        );
                      },
                      onScaleUpdate: (details) => _zoomAround(
                        _gestureStartZoom * details.scale,
                        details.localFocalPoint,
                        anchor: _gestureAnchor,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _CropPainter(widget.image, _crop),
                            foregroundPainter: const _CropGuidesPainter(),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _controls(AppStrings strings) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          strings.lyricsShareCropHint,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.zoom_out_rounded, size: 22),
            Expanded(
              child: Slider(
                key: const ValueKey('lyrics-photo-crop-zoom'),
                value: _zoom,
                min: 1,
                max: _maxZoom,
                label: '${(_zoom * 100).round()}%',
                semanticFormatterCallback: (value) =>
                    '${(value * 100).round()}%',
                onChanged: _setZoom,
              ),
            ),
            const Icon(Icons.zoom_in_rounded, size: 22),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            TextButton.icon(
              key: const ValueKey('lyrics-photo-crop-reset'),
              onPressed: _reset,
              icon: const Icon(Icons.restart_alt_rounded),
              label: Text(strings.lyricsShareResetCrop),
            ),
            FilledButton.icon(
              key: const ValueKey('lyrics-photo-crop-confirm'),
              onPressed: () => Navigator.of(context).pop(_crop),
              icon: const Icon(Icons.check_rounded),
              label: Text(strings.lyricsShareUsePhoto),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(strings.lyricsShareCropTitle)),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final horizontal =
                  (constraints.maxHeight < 300 &&
                      constraints.maxWidth >= 280) ||
                  (constraints.maxWidth >= 600 &&
                      constraints.maxWidth > constraints.maxHeight * 1.5);
              if (horizontal) {
                return Row(
                  children: [
                    Expanded(child: _frame(strings)),
                    const SizedBox(width: 24),
                    SizedBox(
                      width: math.min(280, constraints.maxWidth * .34),
                      child: SingleChildScrollView(child: _controls(strings)),
                    ),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: _frame(strings)),
                  const SizedBox(height: 20),
                  _controls(strings),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.crop);

  final ui.Image image;
  final Rect crop;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        crop.left * image.width,
        crop.top * image.height,
        crop.width * image.width,
        crop.height * image.height,
      ),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.crop != crop;
}

class _CropGuidesPainter extends CustomPainter {
  const _CropGuidesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .30)
      ..strokeWidth = 1;
    for (var division = 1; division < 3; division++) {
      final x = size.width * division / 3;
      final y = size.height * division / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(.5),
        const Radius.circular(18),
      ),
      paint
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withValues(alpha: .7),
    );
  }

  @override
  bool shouldRepaint(covariant _CropGuidesPainter oldDelegate) => false;
}
