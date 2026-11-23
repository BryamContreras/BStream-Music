import 'package:flutter/material.dart';

import '../../../../services/player/player_equalizer.dart';

class EqualizerPresetIcon extends StatelessWidget {
  const EqualizerPresetIcon({
    required this.preset,
    required this.color,
    super.key,
  });

  final EqualizerPreset preset;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final icon = switch (preset) {
      EqualizerPreset.vocal => Icons.mic_none_rounded,
      EqualizerPreset.spokenWord => Icons.interpreter_mode_outlined,
      EqualizerPreset.classical => Icons.piano_outlined,
      EqualizerPreset.smallSpeakers => Icons.speaker_outlined,
      EqualizerPreset.lateNight => Icons.dark_mode_outlined,
      EqualizerPreset.custom => Icons.tune_rounded,
      _ => null,
    };
    return icon == null
        ? CustomPaint(
            size: const Size.square(22),
            painter: _PresetIconPainter(preset, color),
          )
        : Icon(icon, size: 22, color: color);
  }
}

class _PresetIconPainter extends CustomPainter {
  const _PresetIconPainter(this.preset, this.color);

  final EqualizerPreset preset;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 22, size.height / 22);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.55
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final instrument = switch (preset) {
      EqualizerPreset.acoustic => _acousticGuitar,
      EqualizerPreset.electronic => _synthesizer,
      EqualizerPreset.rock => _electricGuitar,
      EqualizerPreset.hipHop => _turntable,
      EqualizerPreset.jazz => _saxophone,
      _ => null,
    };
    if (instrument == null) {
      // Plot the actual saved tuning on the same scale for each tonal preset.
      pen.color = color.withValues(alpha: color.a * .34);
      canvas.drawLine(const Offset(2, 11), const Offset(20, 11), pen);
      pen.color = color;
      final gains = preset.gainsDb;
      final response = Path();
      for (var i = 0; i < gains.length; i++) {
        final x = 2 + 18 * i / (gains.length - 1);
        final y = 11 - gains[i].clamp(-6.0, 6.0) * 1.35;
        if (i == 0) {
          response.moveTo(x, y);
        } else {
          response.lineTo(x, y);
        }
      }
      canvas.drawPath(response, pen);
    } else {
      canvas.drawPath(instrument, pen);
    }
    canvas.restore();
  }

  static final _acousticGuitar = _guitar(
    Path()
      ..moveTo(9.65, 9.75)
      ..cubicTo(6.6, 8.8, 6, 11.5, 6.7, 13)
      ..cubicTo(7.2, 14.1, 5.4, 14.8, 5.4, 17)
      ..cubicTo(5.4, 22.3, 16.6, 22.3, 16.6, 17)
      ..cubicTo(16.6, 14.8, 14.8, 14.1, 15.3, 13)
      ..cubicTo(16, 11.5, 15.4, 8.8, 12.35, 9.75)
      ..addOval(Rect.fromCircle(center: const Offset(11, 14), radius: 1.45))
      ..moveTo(9, 17.6)
      ..lineTo(13, 17.6),
  );

  static final _electricGuitar = _guitar(
    Path()
      ..moveTo(9.65, 11.2)
      ..cubicTo(8.1, 11.5, 8.3, 9.1, 6.5, 9.05)
      ..lineTo(6.3, 14)
      ..cubicTo(6.3, 15.4, 5.3, 15.7, 5.6, 17.7)
      ..cubicTo(6, 22.2, 15.7, 22.4, 16.4, 17.7)
      ..cubicTo(16.9, 14.8, 14.8, 15, 15.7, 10.7)
      ..cubicTo(14.1, 10.55, 14, 12.7, 12.35, 12.25)
      ..moveTo(9, 15)
      ..lineTo(13, 15)
      ..moveTo(9, 18)
      ..lineTo(13, 18),
  );

  static Path _guitar(Path body) {
    body
      ..moveTo(9.65, 12)
      ..lineTo(9.65, 4.6)
      ..lineTo(9.2, 2)
      ..lineTo(12.8, 1.5)
      ..lineTo(12.35, 4.6)
      ..lineTo(12.35, 12);
    return body.transform(
      (Matrix4.identity()
            ..translateByDouble(11, 11, 0, 1)
            ..rotateZ(.72)
            ..translateByDouble(-11, -11, 0, 1))
          .storage,
    );
  }

  static final _synthesizer = Path()
    ..addRRect(_case)
    ..moveTo(2, 10)
    ..lineTo(20, 10)
    ..moveTo(6, 13.5)
    ..lineTo(6, 18)
    ..moveTo(11, 10)
    ..lineTo(11, 18)
    ..moveTo(16, 13.5)
    ..lineTo(16, 18)
    ..moveTo(5, 7)
    ..lineTo(8, 7)
    ..moveTo(11, 7)
    ..lineTo(13, 7)
    ..addOval(Rect.fromCircle(center: const Offset(17, 7), radius: .55));

  static final _turntable = Path()
    ..addRRect(_case)
    ..addOval(Rect.fromCircle(center: const Offset(9, 11), radius: 4.5))
    ..addOval(Rect.fromCircle(center: const Offset(9, 11), radius: .95))
    ..moveTo(17.25, 7)
    ..lineTo(17.25, 11.4)
    ..lineTo(14.1, 15)
    ..addOval(Rect.fromCircle(center: const Offset(17.25, 6.3), radius: .7));

  static final _saxophone = Path()
    ..moveTo(10, 4)
    ..lineTo(7, 4)
    ..quadraticBezierTo(4.2, 4, 4.2, 6.8)
    ..lineTo(4.2, 14.1)
    ..cubicTo(4.2, 21.15, 15.2, 21.85, 16.75, 14.7)
    ..lineTo(17.8, 10.3)
    ..moveTo(10, 6.45)
    ..lineTo(7.5, 6.45)
    ..lineTo(7.5, 13.95)
    ..cubicTo(7.5, 16.75, 11.45, 17.2, 12.4, 14.25)
    ..lineTo(13.9, 9.15)
    ..lineTo(18.95, 10.55)
    ..moveTo(14, 6.8)
    ..lineTo(19.8, 8.45)
    ..lineTo(18.95, 10.55)
    ..moveTo(9.7, 9.4)
    ..lineTo(10, 9.4)
    ..moveTo(9.7, 12.25)
    ..lineTo(10, 12.25);

  static final _case = RRect.fromRectAndRadius(
    const Rect.fromLTRB(2, 4, 20, 18),
    const Radius.circular(2.4),
  );

  @override
  bool shouldRepaint(covariant _PresetIconPainter oldDelegate) =>
      preset != oldDelegate.preset || color != oldDelegate.color;
}
