import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Keeps a static header's existing photo, blur and fades in a single texture.
/// The caller reports the decoded frame that is actually being displayed.
class ArtworkHeaderSnapshot extends StatefulWidget {
  const ArtworkHeaderSnapshot({
    required this.revision,
    required this.builder,
    super.key,
  });

  final Object revision;
  final Widget Function(BuildContext context, ValueChanged<ui.Image?> onFrame)
  builder;

  @override
  State<ArtworkHeaderSnapshot> createState() => _ArtworkHeaderSnapshotState();
}

class _ArtworkHeaderSnapshotState extends State<ArtworkHeaderSnapshot> {
  // Limit the additional RGBA texture to 16 MiB per mounted header.
  static const _maxPixels = 4 * 1024 * 1024;
  static const _settleTime = Duration(milliseconds: 160);

  final _snapshot = SnapshotController();
  ui.Image? _frame;
  Size? _physicalSize;
  Timer? _captureTimer;
  bool _canCapture = false;

  @override
  void didUpdateWidget(covariant ArtworkHeaderSnapshot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision) {
      _frame = null;
      _scheduleCapture();
    }
  }

  void _onFrame(ui.Image? frame) {
    if (identical(_frame, frame) ||
        (frame != null && _frame?.isCloneOf(frame) == true)) {
      return;
    }
    _frame = frame;
    _scheduleCapture();
  }

  void _scheduleCapture() {
    _captureTimer?.cancel();
    _snapshot.allowSnapshotting = false;
    // A placeholder or changing frames stay live. Start only after the
    // decoded image and its layout have settled.
    if (_frame != null && _canCapture) {
      _captureTimer = Timer(_settleTime, () {
        _snapshot.allowSnapshotting = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final supported =
        !kIsWeb &&
        Theme.of(context).platform == TargetPlatform.android &&
        (ModalRoute.isCurrentOf(context) ?? true);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest * ratio;
        final canCapture =
            supported &&
            size.isFinite &&
            !size.isEmpty &&
            size.width.ceil() * size.height.ceil() <= _maxPixels;
        if (_physicalSize != size || _canCapture != canCapture) {
          _physicalSize = size;
          _canCapture = canCapture;
          _scheduleCapture();
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
    _captureTimer?.cancel();
    _snapshot.dispose();
    super.dispose();
  }
}
