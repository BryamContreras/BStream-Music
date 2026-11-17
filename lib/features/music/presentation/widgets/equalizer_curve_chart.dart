import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../services/player/player_equalizer.dart';

String formatEqualizerGain(double gain) {
  final digits = gain == gain.roundToDouble() ? 0 : 1;
  return '${gain > 0 ? '+' : ''}${gain.toStringAsFixed(digits)} dB';
}

/// A compact response curve with a control point for each equalizer band.
class EqualizerCurveIcon extends StatelessWidget {
  const EqualizerCurveIcon({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final effectiveColor =
        color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox.square(
      dimension: size ?? theme.size ?? 24,
      child: CustomPaint(
        painter: _EqualizerCurveIconPainter(
          effectiveColor.withValues(
            alpha: effectiveColor.a * (theme.opacity ?? 1),
          ),
        ),
      ),
    );
  }
}

class _EqualizerCurveIconPainter extends CustomPainter {
  const _EqualizerCurveIconPainter(this.color);

  final Color color;
  static const _points = [
    Offset(2.5, 14.5),
    Offset(7, 7.5),
    Offset(12, 16),
    Offset(17, 8.5),
    Offset(21.5, 11.5),
  ];
  static final _curve = Path()
    ..moveTo(2.5, 14.5)
    ..cubicTo(4.75, 14.5, 4.75, 7.5, 7, 7.5)
    ..cubicTo(9.5, 7.5, 9.5, 16, 12, 16)
    ..cubicTo(14.5, 16, 14.5, 8.5, 17, 8.5)
    ..cubicTo(19.25, 8.5, 19.25, 11.5, 21.5, 11.5);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(
      _curve,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final marker = Paint()..color = color;
    for (final point in _points) {
      canvas.drawCircle(point, 1.45, marker);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EqualizerCurveIconPainter oldDelegate) =>
      color != oldDelegate.color;
}

/// A view of the five stored controls, rather than an audio sampling task.
class EqualizerCurveChart extends StatelessWidget {
  const EqualizerCurveChart({
    super.key,
    required this.settings,
    required this.bandLabels,
    required this.active,
  });

  final EqualizerSettings settings;
  final List<String> bandLabels;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final curve = settings.normalized;
    return Semantics(
      key: const ValueKey('equalizer-curve-chart'),
      image: true,
      label: List.generate(
        equalizerBandFrequencies.length,
        (index) =>
            '${bandLabels[index]}: ${formatEqualizerGain(curve.gainsDb[index])}',
      ).join('; '),
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox(
            height: 164 + textScaler.scale(12),
            width: double.infinity,
            child: CustomPaint(
              painter: _EqualizerCurvePainter(
                settings: curve,
                bandLabels: bandLabels,
                color: active ? colors.primary : colors.onSurfaceVariant,
                surface: AppColors.cardSurfaceFor(context),
                gridColor: colors.onSurface.withValues(alpha: .08),
                zeroColor: colors.onSurface.withValues(alpha: .25),
                textStyle:
                    (Theme.of(context).textTheme.labelSmall ??
                            const TextStyle())
                        .copyWith(
                          color: colors.onSurfaceVariant,
                          fontSize: 11,
                          height: 1,
                        ),
                textScaler: textScaler,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EqualizerCurvePainter extends CustomPainter {
  const _EqualizerCurvePainter({
    required this.settings,
    required this.bandLabels,
    required this.color,
    required this.surface,
    required this.gridColor,
    required this.zeroColor,
    required this.textStyle,
    required this.textScaler,
  });

  final EqualizerSettings settings;
  final List<String> bandLabels;
  final Color color;
  final Color surface;
  final Color gridColor;
  final Color zeroColor;
  final TextStyle textStyle;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final text = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    );
    void prepare(String label) {
      text.text = TextSpan(text: label, style: textStyle);
      text.layout();
    }

    prepare('−12 dB');
    final axisWidth = text.width + 10;
    final labelHeight = text.height;
    final plot = Rect.fromLTRB(
      axisWidth,
      labelHeight / 2 + 4,
      size.width - 6,
      size.height - labelHeight - 14,
    );
    if (plot.width <= 0 || plot.height <= 0) {
      text.dispose();
      return;
    }
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final zero = Paint()
      ..color = zeroColor
      ..strokeWidth = 1;
    double y(double gain) =>
        plot.bottom -
        (gain - equalizerMinGainDb) /
            (equalizerMaxGainDb - equalizerMinGainDb) *
            plot.height;
    final logStart = math.log(equalizerBandFrequencies.first);
    final logRange = math.log(equalizerBandFrequencies.last) - logStart;
    double x(int index) =>
        plot.left +
        (math.log(equalizerBandFrequencies[index]) - logStart) /
            logRange *
            plot.width;

    for (final gain in [-12.0, -6.0, 0.0, 6.0, 12.0]) {
      canvas.drawLine(
        Offset(plot.left, y(gain)),
        Offset(plot.right, y(gain)),
        gain == 0 ? zero : grid,
      );
    }
    for (var index = 0; index < equalizerBandFrequencies.length; index++) {
      canvas.drawLine(
        Offset(x(index), plot.top),
        Offset(x(index), plot.bottom),
        grid,
      );
    }
    for (final gain in [12.0, 0.0, -12.0]) {
      prepare(formatEqualizerGain(gain));
      text.paint(
        canvas,
        Offset(axisWidth - text.width - 10, y(gain) - text.height / 2),
      );
    }

    // Drop intermediate labels for enlarged text instead of shrinking it.
    var totalLabelWidth = 0.0;
    for (final label in bandLabels) {
      prepare(label);
      totalLabelWidth += text.width + 8;
    }
    final labelIndices = totalLabelWidth <= plot.width
        ? List.generate(bandLabels.length, (index) => index)
        : [0, bandLabels.length - 1];
    for (final index in labelIndices) {
      prepare(bandLabels[index]);
      final left = (x(index) - text.width / 2).clamp(
        plot.left,
        math.max(plot.left, size.width - text.width),
      );
      text.paint(canvas, Offset(left.toDouble(), plot.bottom + 12));
    }

    final points = [
      for (var index = 0; index < settings.gainsDb.length; index++)
        Offset(x(index), y(settings.gainsDb[index])),
    ];
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index++) {
      final previous = points[index - 1];
      final next = points[index];
      final middleX = (previous.dx + next.dx) / 2;
      path.cubicTo(middleX, previous.dy, middleX, next.dy, next.dx, next.dy);
    }
    final fill = Path.from(path)
      ..lineTo(plot.right, y(0))
      ..lineTo(plot.left, y(0))
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .16), color.withValues(alpha: .02)],
        ).createShader(plot),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: .09)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round,
    );
    for (final point in points) {
      canvas.drawCircle(point, 4, Paint()..color = surface);
      canvas.drawCircle(point, 2.8, Paint()..color = color);
    }
    text.dispose();
  }

  @override
  bool shouldRepaint(covariant _EqualizerCurvePainter oldDelegate) =>
      settings != oldDelegate.settings ||
      !listEquals(bandLabels, oldDelegate.bandLabels) ||
      color != oldDelegate.color ||
      surface != oldDelegate.surface ||
      gridColor != oldDelegate.gridColor ||
      zeroColor != oldDelegate.zeroColor ||
      textStyle != oldDelegate.textStyle ||
      textScaler != oldDelegate.textScaler;
}
