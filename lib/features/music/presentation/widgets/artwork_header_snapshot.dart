import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

typedef ArtworkSnapshotFrame = void Function(ui.Image? frame, {int index});

/// Keeps a static header's existing photo, blur and fades in a single texture.
/// The caller reports the decoded frames that are actually being displayed.
class ArtworkHeaderSnapshot extends StatefulWidget {
  const ArtworkHeaderSnapshot({
    required this.revision,
    required this.builder,
    this.frameCount = 1,
    this.maximumPixels = 4 * 1024 * 1024,
    this.settleTime = const Duration(milliseconds: 220),
    super.key,
  }) : assert(frameCount > 0),
       assert(maximumPixels > 0);

  final Object revision;
  final int frameCount;
  final int maximumPixels;

  /// Includes any fade inside the captured artwork.
  final Duration settleTime;
  final Widget Function(BuildContext context, ArtworkSnapshotFrame onFrame)
  builder;

  @override
  State<ArtworkHeaderSnapshot> createState() => _ArtworkHeaderSnapshotState();
}

class _ArtworkHeaderSnapshotState extends State<ArtworkHeaderSnapshot>
    with WidgetsBindingObserver {
  // Keep the combined additional RGBA textures bounded, including outgoing
  // player covers and headers still mounted behind the current route.
  static const _totalPixelBudget = 6 * 1024 * 1024;
  static int _reservedPixels = 0;
  static final _waiting = <_ArtworkHeaderSnapshotState>{};

  final _snapshot = SnapshotController();
  final _frames = <int, ui.Image>{};
  Size? _physicalSize;
  Timer? _captureTimer;
  bool _canCapture = false;
  bool _underMemoryPressure = false;
  int _reservation = 0;
  ScrollPosition? _scrollPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (_scrollPosition != position) {
      _scrollPosition?.isScrollingNotifier.removeListener(_onScrollChanged);
      _scrollPosition = position;
      position?.isScrollingNotifier.addListener(_onScrollChanged);
      _onScrollChanged();
    }
  }

  @override
  void didUpdateWidget(covariant ArtworkHeaderSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision ||
        widget.frameCount != oldWidget.frameCount) {
      _frames.clear();
      _underMemoryPressure = false;
      _invalidate();
    }
  }

  void _onFrame(ui.Image? frame, {int index = 0}) {
    assert(index >= 0 && index < widget.frameCount);
    final previous = _frames[index];
    if (identical(previous, frame) ||
        (frame != null && previous?.isCloneOf(frame) == true)) {
      return;
    }
    if (frame == null) {
      _frames.remove(index);
    } else {
      _frames[index] = frame;
    }
    _invalidate();
  }

  void _onScrollChanged() {
    if (_scrollPosition?.isScrollingNotifier.value == true) {
      // Keep an existing static texture during scrolling. Defer new captures
      // so that late artwork does not introduce a raster allocation mid-drag.
      _captureTimer?.cancel();
      _captureTimer = null;
      _waiting.remove(this);
    } else {
      _scheduleCapture();
    }
  }

  bool get _ready =>
      mounted &&
      _canCapture &&
      !_underMemoryPressure &&
      _frames.length == widget.frameCount &&
      _scrollPosition?.isScrollingNotifier.value != true;

  void _releaseReservation() {
    if (_reservation == 0) return;
    _reservedPixels -= _reservation;
    _reservation = 0;
    for (final waiting in _waiting.toList(growable: false)) {
      waiting._scheduleCapture();
    }
  }

  void _invalidate() {
    _captureTimer?.cancel();
    _captureTimer = null;
    _waiting.remove(this);
    _snapshot.allowSnapshotting = false;
    _releaseReservation();
    _scheduleCapture();
  }

  void _scheduleCapture() {
    // A placeholder or changing frames stay live. Start only after the
    // decoded images, layout and scrolling have settled.
    if (!_ready || _reservation != 0 || _captureTimer != null) return;
    _waiting.remove(this);
    _captureTimer = Timer(widget.settleTime, () {
      _captureTimer = null;
      if (!_ready) return;
      final size = _physicalSize!;
      final pixels = size.width.ceil() * size.height.ceil();
      if (_reservedPixels + pixels > _totalPixelBudget) {
        // Try again only when another mounted snapshot frees its reservation.
        _waiting.add(this);
        return;
      }
      _reservedPixels += pixels;
      _reservation = pixels;
      _snapshot.allowSnapshotting = true;
    });
  }

  @override
  void didHaveMemoryPressure() {
    _underMemoryPressure = true;
    _invalidate();
  }

  @override
  Widget build(BuildContext context) {
    final supported =
        !kIsWeb &&
        Theme.of(context).platform == TargetPlatform.android &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest * ratio;
        final canCapture =
            supported &&
            size.isFinite &&
            !size.isEmpty &&
            size.width.ceil() * size.height.ceil() <= widget.maximumPixels &&
            size.width.ceil() * size.height.ceil() <= _totalPixelBudget;
        if (_physicalSize != size || _canCapture != canCapture) {
          if (_physicalSize != size) _underMemoryPressure = false;
          _physicalSize = size;
          _canCapture = canCapture;
          _invalidate();
        }
        return SnapshotWidget(
          controller: _snapshot,
          mode: SnapshotMode.permissive,
          autoresize: true,
          child: widget.builder(context, _onFrame),
        );
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollPosition?.isScrollingNotifier.removeListener(_onScrollChanged);
    _captureTimer?.cancel();
    _waiting.remove(this);
    _releaseReservation();
    _snapshot.dispose();
    super.dispose();
  }
}
