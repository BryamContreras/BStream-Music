import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Adds primary-button mouse dragging to a horizontal shelf on desktop.
///
/// Apply this to the horizontal scroll view itself, not a whole page: vertical
/// lists, text selection and reorderable queues must keep their normal input
/// handling. Keeping the inherited behavior also preserves touch/trackpad
/// support, physics, scrollbars and the platform's wheel-axis modifiers.
class HorizontalShelfScroll extends StatelessWidget {
  const HorizontalShelfScroll({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final inherited = ScrollConfiguration.of(context);
    final desktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    if (!desktop || inherited.dragDevices.contains(PointerDeviceKind.mouse)) {
      return child;
    }
    return ScrollConfiguration(
      behavior: inherited.copyWith(
        dragDevices: {...inherited.dragDevices, PointerDeviceKind.mouse},
      ),
      child: child,
    );
  }
}
