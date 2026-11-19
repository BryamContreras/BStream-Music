import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Draws gain outward from zero rather than filling the entire negative range.
class EqualizerFaderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const EqualizerFaderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final inactive = Color.lerp(
      sliderTheme.disabledInactiveTrackColor,
      sliderTheme.inactiveTrackColor,
      enableAnimation.value,
    )!;
    final active = Color.lerp(
      sliderTheme.disabledActiveTrackColor,
      sliderTheme.activeTrackColor,
      enableAnimation.value,
    )!;
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = inactive,
    );
    final gainRect = Rect.fromLTRB(
      math.min(rect.center.dx, thumbCenter.dx),
      rect.top,
      math.max(rect.center.dx, thumbCenter.dx),
      rect.bottom,
    );
    if (gainRect.width > .1) {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(gainRect, const Radius.circular(4)),
        Paint()..color = active,
      );
    }
  }
}

/// A compact fader cap. Its axes are swapped by the vertical slider's rotation.
class EqualizerFaderThumbShape extends SliderComponentShape {
  const EqualizerFaderThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(8, 16);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final color = Color.lerp(
      sliderTheme.disabledThumbColor,
      sliderTheme.thumbColor,
      enableAnimation.value,
    )!;
    final scale = 1 + activationAnimation.value * .06;
    final rect = Rect.fromCenter(
      center: center,
      width: 8 * scale,
      height: 16 * scale,
    );
    final cap = RRect.fromRectAndRadius(rect, const Radius.circular(3));
    final canvas = context.canvas;
    canvas.drawShadow(
      Path()..addRRect(cap),
      Colors.black.withValues(alpha: .22),
      1,
      false,
    );
    canvas.drawRRect(
      cap,
      Paint()
        ..shader = LinearGradient(
          colors: [Color.lerp(color, Colors.white, .2)!, color],
        ).createShader(rect),
    );
    canvas.drawRRect(
      cap.deflate(.5),
      Paint()
        ..color = Colors.white.withValues(alpha: .25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      center.translate(0, -3.5),
      center.translate(0, 3.5),
      Paint()
        ..color = Colors.white.withValues(alpha: .65)
        ..strokeWidth = 1
        ..strokeCap = StrokeCap.round,
    );
  }
}

/// Static lane and scale marks share the slider's 12 px endpoint padding.
class EqualizerFaderScale extends StatelessWidget {
  const EqualizerFaderScale({required this.color, super.key});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      SizedBox.expand(child: CustomPaint(painter: _FaderScalePainter(color)));
}

class _FaderScalePainter extends CustomPainter {
  const _FaderScalePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.width / 2;
    final lane = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: size.center(Offset.zero),
        width: 4,
        height: math.max(0, size.height - 8),
      ),
      const Radius.circular(2),
    );
    canvas.drawRRect(lane, Paint()..color = color.withValues(alpha: .035));
    final paint = Paint()
      ..strokeWidth = .7
      ..strokeCap = StrokeCap.round;
    for (var step = 0; step <= 8; step++) {
      final zero = step == 4;
      final y = 12 + (size.height - 24) * step / 8;
      paint.color = color.withValues(alpha: zero ? .28 : .1);
      final length = zero ? 4.0 : 2.0;
      canvas.drawLine(
        Offset(center - 3.5 - length, y),
        Offset(center - 3.5, y),
        paint,
      );
      canvas.drawLine(
        Offset(center + 3.5, y),
        Offset(center + 3.5 + length, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FaderScalePainter oldDelegate) =>
      color != oldDelegate.color;
}
