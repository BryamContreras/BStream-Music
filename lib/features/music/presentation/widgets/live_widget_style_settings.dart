import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../providers/app_strings.dart';
import '../providers/live_widget_style.dart';

class LiveWidgetStyleSettings extends StatelessWidget {
  const LiveWidgetStyleSettings({
    required this.style,
    required this.accent,
    required this.strings,
    required this.onChanged,
    super.key,
  });

  final LiveWidgetStyle style;
  final AppAccent accent;
  final AppStrings strings;
  final Future<void> Function(LiveWidgetStyle) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(strings.liveWidgetDescription),
        const SizedBox(height: 20),
        Text(
          strings.liveWidgetPreview,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: CustomPaint(
            painter: const _TransparencyGridPainter(),
            child: LiveWidgetPreview(
              key: const ValueKey('live-widget-preview'),
              style: style,
              accent: accent,
              strings: strings,
            ),
          ),
        ),
        const SizedBox(height: 20),
        for (final option in LiveWidgetStyle.values) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: AppColors.cardSurfaceFor(context),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                key: ValueKey('live-widget-style-${option.code}'),
                selected: style == option,
                minVerticalPadding: 12,
                leading: Icon(
                  option == LiveWidgetStyle.wave
                      ? Icons.graphic_eq_rounded
                      : Icons.view_agenda_rounded,
                ),
                title: Text(strings.liveWidgetStyleLabel(option)),
                subtitle: Text(strings.liveWidgetStyleDescription(option)),
                trailing: Icon(
                  style == option
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: style == option ? accent.seedColor : null,
                ),
                onTap: () => onChanged(option),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Scales the browser-source layout as a whole so the sample stays legible
/// without inventing a different layout at narrow Settings widths.
class LiveWidgetPreview extends StatelessWidget {
  const LiveWidgetPreview({
    required this.style,
    required this.accent,
    required this.strings,
    super.key,
  });

  final LiveWidgetStyle style;
  final AppAccent accent;
  final AppStrings strings;

  bool get _wave => style == LiveWidgetStyle.wave;

  double get _upcomingCoverSize => _wave ? 56 : 82;

  // Match the browser's content-driven cards: 11px padding and a 1px border
  // on each side. Its 78/104px CSS min-height does not include a smaller cover.
  double get _upcomingCardHeight => _upcomingCoverSize + 24;

  @override
  Widget build(BuildContext context) {
    final height = (_wave ? 326 : 124) + _upcomingCardHeight * 2 + 22 + 56;
    return AspectRatio(
      aspectRatio: 1192 / height,
      child: IgnorePointer(
        // This is a scaled browser scene, not app text. Accessibility scaling
        // still applies to the Settings labels, but must not change its fixed
        // CSS-sized geometry independently of the covers and panels.
        child: MediaQuery.withNoTextScaling(
          child: FittedBox(
            child: SizedBox(
              width: 1192,
              height: height,
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'Roboto',
                  height: 1.2,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 28,
                  ),
                  child: Column(
                    children: [
                      if (_wave) _waveCard() else _classicCard(current: true),
                      const SizedBox(height: 11),
                      _classicCard(current: false),
                      const SizedBox(height: 11),
                      _classicCard(current: false, pending: true),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _artwork(double size) => ClipRRect(
    borderRadius: BorderRadius.circular(size > 120 ? 14 : 10),
    child: Image.asset(
      'assets/icons/bstream_icon.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.low,
    ),
  );

  Widget _metadata({
    required double titleSize,
    required double artistSize,
    double artistGap = 5,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          strings.choose('Tu canción favorita', 'Your favorite song'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: titleSize, fontWeight: FontWeight.w800),
        ),
        SizedBox(height: artistGap),
        Text(
          'BStream Music',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: artistSize, color: Colors.white70),
        ),
      ],
    );
  }

  Widget _progress(double height) => ClipRRect(
    borderRadius: BorderRadius.circular(height / 2),
    child: Container(
      height: height,
      color: accent.darkColor.withValues(alpha: .42),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: .58,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(height / 2),
            gradient: LinearGradient(
              colors: [accent.darkColor, accent.seedColor],
            ),
          ),
          child: SizedBox(height: height),
        ),
      ),
    ),
  );

  Widget _waveCard() => Column(
    children: [
      Row(
        children: [
          _artwork(290),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: SizedBox(
                    height: 180,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const ColoredBox(color: Color(0xDC131820)),
                        ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                          child: Opacity(opacity: .32, child: _artwork(180)),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 28),
                          child: _metadata(
                            titleSize: 46,
                            artistSize: 32,
                            artistGap: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  height: 92,
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  decoration: BoxDecoration(
                    color: const Color(0xDC131820),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Text(
                        '02:42',
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          color: accent.seedColor,
                        ),
                      ),
                      const SizedBox(width: 28),
                      Expanded(
                        child: CustomPaint(
                          size: const Size(double.infinity, 58),
                          painter: _WavePreviewPainter(accent.seedColor),
                        ),
                      ),
                      const SizedBox(width: 28),
                      Text(
                        '04:38',
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          color: accent.seedColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      _progress(18),
    ],
  );

  Widget _classicCard({required bool current, bool pending = false}) {
    final coverSize = current ? 100.0 : _upcomingCoverSize;
    final height = current ? 124.0 : _upcomingCardHeight;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(current ? 14 : 12),
        border: Border.all(color: accent.seedColor.withValues(alpha: .30)),
        gradient: LinearGradient(
          colors: [
            Color.lerp(const Color(0xE8131820), accent.darkColor, .4)!,
            const Color(0xE8161B24),
          ],
        ),
      ),
      child: Row(
        children: [
          _artwork(coverSize),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _metadata(
                  titleSize: current ? 26 : (_wave ? 22 : 25),
                  artistSize: current ? 18 : (_wave ? 16 : 19),
                  artistGap: current ? 3 : 5,
                ),
                if (current) ...[
                  const SizedBox(height: 9),
                  _progress(7),
                  const SizedBox(height: 4),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('02:42', style: TextStyle(fontSize: 14, height: 1)),
                      Text('04:38', style: TextStyle(fontSize: 14, height: 1)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (pending) ...[
            const SizedBox(width: 16),
            Text(
              strings.liveOverlayLoading,
              style: TextStyle(
                color: accent.seedColor,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _WavePreviewPainter extends CustomPainter {
  const _WavePreviewPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const heights = [
      .32,
      .22,
      .55,
      .84,
      .62,
      .94,
      .46,
      .7,
      .88,
      .98,
      .4,
      .7,
      .8,
      .36,
      .5,
      .62,
      .3,
    ];
    final cell = size.width / heights.length;
    final paint = Paint()..color = color;
    for (var index = 0; index < heights.length; index++) {
      final height = size.height * heights[index];
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            cell * index + cell * .3,
            (size.height - height) / 2,
            cell * .4,
            height,
          ),
          const Radius.circular(6),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePreviewPainter oldDelegate) =>
      color != oldDelegate.color;
}

class _TransparencyGridPainter extends CustomPainter {
  const _TransparencyGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 12.0;
    final paint = Paint();
    for (var row = 0; row < (size.height / cell).ceil(); row++) {
      for (var column = 0; column < (size.width / cell).ceil(); column++) {
        paint.color = (row + column).isEven
            ? const Color(0xFF25282E)
            : const Color(0xFF30333B);
        canvas.drawRect(
          Rect.fromLTWH(column * cell, row * cell, cell, cell),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TransparencyGridPainter oldDelegate) => false;
}
