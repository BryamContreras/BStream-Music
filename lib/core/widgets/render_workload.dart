import 'package:flutter/widgets.dart';

/// Selects rendering paths that trade a little setup work for less GPU fill
/// and render-target churn. The Android measurements at 2.53 and 4.49 million
/// physical viewport pixels favored different paths. Use the current view
/// area so the selection follows window size, density and display changes.
bool hasHighPixelCount(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final scale = MediaQuery.devicePixelRatioOf(context);
  return size.width * size.height * scale * scale >= 3200000;
}
