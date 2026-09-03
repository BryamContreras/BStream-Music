import 'package:flutter/material.dart';

/// Returns a current, non-empty anchor for platform share sheets.
///
/// iPad requires a valid popover origin. Other platforms retain the previous
/// nullable behavior when the triggering render object is unavailable.
Rect? sharePositionOriginForContext(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is RenderBox &&
      renderObject.attached &&
      renderObject.hasSize &&
      renderObject.size.width > 0 &&
      renderObject.size.height > 0) {
    final origin = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    if (origin.left.isFinite &&
        origin.top.isFinite &&
        origin.width.isFinite &&
        origin.height.isFinite) {
      return origin;
    }
  }

  if (Theme.of(context).platform != TargetPlatform.iOS) {
    return null;
  }
  final viewport = MediaQuery.sizeOf(context);
  final width = viewport.width.isFinite && viewport.width > 0
      ? viewport.width
      : 1.0;
  final height = viewport.height.isFinite && viewport.height > 0
      ? viewport.height
      : 1.0;
  return Rect.fromLTWH(width / 2, height / 2, 1, 1);
}
