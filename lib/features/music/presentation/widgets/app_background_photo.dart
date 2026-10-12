import 'dart:io';

import 'package:flutter/material.dart';

/// A static, bounded photo layer. The saved file has its orientation baked in;
/// cover recalculates its crop whenever the viewport changes shape.
class AppBackgroundPhoto extends StatelessWidget {
  const AppBackgroundPhoto({
    required this.path,
    this.scrim = Colors.transparent,
    super.key,
  });

  final String path;
  final Color scrim;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(path),
            fit: BoxFit.cover,
            alignment: Alignment.center,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          ),
          if (scrim.a > 0) ColoredBox(color: scrim),
        ],
      ),
    );
  }
}
