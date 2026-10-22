import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A short-lived, full-resolution glyph raster for an expensive lyric halo.
///
/// Scaling a retained image does not re-run the paragraph's Gaussian shadows
/// every frame. The paragraph remains mounted with its original constraints,
/// hit testing and semantics; only its paint is replaced while [enabled].
/// Callers must include every visual dependency in [revision] and enable this
/// only for the current/transitioning line, not for all cached list children.
class LyricsGlyphSnapshot extends StatefulWidget {
  const LyricsGlyphSnapshot({
    required this.enabled,
    required this.width,
    required this.height,
    required this.revision,
    required this.child,
    this.opacity,
    super.key,
  }) : assert(width >= 0),
       assert(height >= 0);

  /// Transparent capture padding, in logical pixels, for the original halo.
  static const overflowPadding = 48.0;

  /// At most 12 MiB of uncompressed RGBA per visible/transitioning paragraph.
  /// Oversized text still renders normally; it is never downsampled or clipped.
  static const maximumSnapshotPixels = 3 * 1024 * 1024;
  static const maximumSnapshotEdge = 4096;

  final bool enabled;
  final double width;
  final double height;
  final Object? revision;
  final Widget child;

  /// Composite opacity without changing or invalidating the captured glyphs.
  /// A zero value still permits a capture while [enabled], so the current
  /// lyric can retain its glyphs from the start of its entering transition.
  final Animation<double>? opacity;

  @override
  State<LyricsGlyphSnapshot> createState() => _LyricsGlyphSnapshotState();
}

class _LyricsGlyphSnapshotState extends State<LyricsGlyphSnapshot>
    with WidgetsBindingObserver {
  final SnapshotController _controller = SnapshotController();
  late final _GlyphSnapshotPainter _painter;
  double? _devicePixelRatio;
  bool _tickerModeEnabled = true;
  bool _reducedMotion = false;
  bool _appActive = true;
  bool _attached = true;

  @override
  void initState() {
    super.initState();
    _painter = _GlyphSnapshotPainter(widget.opacity);
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final ratioChanged =
        _devicePixelRatio != null && _devicePixelRatio != pixelRatio;
    _devicePixelRatio = pixelRatio;
    _tickerModeEnabled = TickerMode.valuesOf(context).enabled;
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (ratioChanged) _controller.clear();
    _syncSnapshotPolicy();
  }

  @override
  void didUpdateWidget(covariant LyricsGlyphSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _painter.opacity = widget.opacity;
    if (oldWidget.revision != widget.revision ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _controller.clear();
    }
    _syncSnapshotPolicy();
  }

  bool get _withinImageBudget {
    final ratio = _devicePixelRatio;
    if (!widget.width.isFinite ||
        !widget.height.isFinite ||
        widget.width <= 0 ||
        widget.height <= 0 ||
        ratio == null ||
        !ratio.isFinite ||
        ratio <= 0) {
      return false;
    }
    final physicalWidth =
        (widget.width + LyricsGlyphSnapshot.overflowPadding * 2) * ratio;
    final physicalHeight =
        (widget.height + LyricsGlyphSnapshot.overflowPadding * 2) * ratio;
    return physicalWidth <= LyricsGlyphSnapshot.maximumSnapshotEdge &&
        physicalHeight <= LyricsGlyphSnapshot.maximumSnapshotEdge &&
        physicalWidth.ceil() * physicalHeight.ceil() <=
            LyricsGlyphSnapshot.maximumSnapshotPixels;
  }

  void _syncSnapshotPolicy() {
    _controller.allowSnapshotting =
        !kIsWeb &&
        widget.enabled &&
        _attached &&
        _appActive &&
        _tickerModeEnabled &&
        !_reducedMotion &&
        _withinImageBudget;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _syncSnapshotPolicy();
  }

  @override
  void didHaveMemoryPressure() {
    // Release the optional raster immediately. An active line can capture the
    // unchanged paragraph again on its next paint; detached/hidden lines stay
    // uncaptured under the existing policy.
    _controller.clear();
  }

  @override
  void deactivate() {
    _attached = false;
    // The controller synchronously releases a retained raster, even if the
    // detached list child will not receive another paint before disposal.
    _syncSnapshotPolicy();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _attached = true;
    _syncSnapshotPolicy();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _painter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Invalid/unbounded geometry cannot be captured. Leave ordinary layout in
    // charge instead of creating infinite OverflowBox or image constraints.
    if (!widget.width.isFinite || !widget.height.isFinite) {
      return SizedBox(
        width: widget.width.isFinite ? widget.width : null,
        height: widget.height.isFinite ? widget.height : null,
        child: widget.child,
      );
    }
    final paddedWidth = widget.width + LyricsGlyphSnapshot.overflowPadding * 2;
    final paddedHeight =
        widget.height + LyricsGlyphSnapshot.overflowPadding * 2;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: paddedWidth,
        maxWidth: paddedWidth,
        minHeight: paddedHeight,
        maxHeight: paddedHeight,
        child: Transform.translate(
          offset: const Offset(
            -LyricsGlyphSnapshot.overflowPadding,
            -LyricsGlyphSnapshot.overflowPadding,
          ),
          child: SnapshotWidget(
            controller: _controller,
            painter: _painter,
            autoresize: true,
            mode: SnapshotMode.permissive,
            child: Padding(
              padding: const EdgeInsets.all(
                LyricsGlyphSnapshot.overflowPadding,
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: widget.width,
                  height: widget.height,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Changes only how the existing raster is composited. Unlike an outer
/// FadeTransition at zero opacity, this does not skip the entering glyph capture.
class _GlyphSnapshotPainter extends SnapshotPainter {
  _GlyphSnapshotPainter(this._opacity) {
    _lastNotifiedAlpha = _alpha;
    _opacity?.addListener(_onOpacityChanged);
  }

  Animation<double>? _opacity;
  late int _lastNotifiedAlpha;

  set opacity(Animation<double>? value) {
    if (identical(value, _opacity)) return;
    _opacity?.removeListener(_onOpacityChanged);
    _opacity = value;
    _opacity?.addListener(_onOpacityChanged);
    _onOpacityChanged();
  }

  void _onOpacityChanged() {
    final alpha = _alpha;
    // Both the captured and live paint paths use this same 8-bit alpha. A
    // curved animation can emit several endpoint ticks with identical pixels.
    if (alpha == _lastNotifiedAlpha) return;
    _lastNotifiedAlpha = alpha;
    notifyListeners();
  }

  int get _alpha {
    final value = _opacity?.value ?? 1.0;
    return ((value.isFinite ? value.clamp(0.0, 1.0) : 1.0) * 255).round();
  }

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final alpha = _alpha;
    if (alpha == 0) return;
    context.canvas.drawImageRect(
      image,
      Offset.zero & sourceSize,
      offset & size,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromARGB(alpha, 255, 255, 255),
    );
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset,
    Size size,
    PaintingContextCallback painter,
  ) {
    final alpha = _alpha;
    if (alpha == 255) {
      painter(context, offset);
    } else if (alpha > 0) {
      context.pushOpacity(offset, alpha, painter);
    }
  }

  @override
  bool shouldRepaint(covariant _GlyphSnapshotPainter oldPainter) =>
      !identical(oldPainter._opacity, _opacity);

  @override
  void dispose() {
    _opacity?.removeListener(_onOpacityChanged);
    super.dispose();
  }
}
