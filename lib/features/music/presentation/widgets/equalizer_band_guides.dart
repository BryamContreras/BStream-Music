import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../../../services/player/player_equalizer.dart';

/// Quiet reference lines behind the controls, painted from saved gains only.
class EqualizerBandGuides extends StatelessWidget {
  const EqualizerBandGuides({
    required this.gainsDb,
    required this.active,
    super.key,
  });

  final List<double> gainsDb;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IgnorePointer(
      key: const ValueKey('equalizer-band-guides'),
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _BandGuidesPainter(
              gainsDb: gainsDb,
              gridColor: colors.onSurface.withValues(alpha: .055),
              zeroColor: colors.onSurface.withValues(alpha: .13),
              curveColor: (active ? colors.primary : colors.onSurfaceVariant)
                  .withValues(alpha: active ? .28 : .12),
            ),
          ),
        ),
      ),
    );
  }
}

class _BandGuidesPainter extends CustomPainter {
  const _BandGuidesPainter({
    required this.gainsDb,
    required this.gridColor,
    required this.zeroColor,
    required this.curveColor,
  });

  final List<double> gainsDb;
  final Color gridColor;
  final Color zeroColor;
  final Color curveColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Match the rotated sliders' endpoint padding and evenly spaced columns.
    final trackHeight = size.height - 24;
    if (size.width <= 16 || trackHeight <= 0 || gainsDb.isEmpty) return;
    final grid = Paint()..strokeWidth = .7;
    for (var step = 0; step <= 8; step++) {
      final y = 12 + trackHeight * step / 8;
      grid.color = step == 4 ? zeroColor : gridColor;
      canvas.drawLine(Offset(8, y), Offset(size.width - 8, y), grid);
    }

    Offset point(int index) => Offset(
      size.width * (index + .5) / gainsDb.length,
      12 +
          trackHeight *
              (equalizerMaxGainDb - gainsDb[index]) /
              (equalizerMaxGainDb - equalizerMinGainDb),
    );
    final first = point(0);
    final curve = Path()..moveTo(first.dx, first.dy);
    for (var index = 1; index < gainsDb.length; index++) {
      final previous = point(index - 1);
      final current = point(index);
      final middleX = (previous.dx + current.dx) / 2;
      curve.cubicTo(
        middleX,
        previous.dy,
        middleX,
        current.dy,
        current.dx,
        current.dy,
      );
    }
    canvas.drawPath(
      curve,
      Paint()
        ..color = curveColor
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _BandGuidesPainter oldDelegate) =>
      gridColor != oldDelegate.gridColor ||
      zeroColor != oldDelegate.zeroColor ||
      curveColor != oldDelegate.curveColor ||
      !listEquals(gainsDb, oldDelegate.gainsDb);
}
