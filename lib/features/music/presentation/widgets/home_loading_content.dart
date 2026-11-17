import 'package:flutter/material.dart';

import '../../../../core/animation/frame_rate_ticker_provider.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';

/// Initial-feed placeholders share one paint-only shimmer clock. They never
/// fetch artwork, and the real shelves replace them as a unit.
class HomeLoadingContent extends StatefulWidget {
  const HomeLoadingContent({required this.label, super.key});

  final String label;

  @override
  State<HomeLoadingContent> createState() => _HomeLoadingContentState();
}

class _HomeLoadingContentState extends State<HomeLoadingContent>
    with WidgetsBindingObserver {
  final _vsync = FrameRateTickerProvider(maxFramesPerSecond: 30);
  late final AnimationController _shimmer;
  bool _reducedMotion = false;
  bool _tickerEnabled = true;
  bool _appIsActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appIsActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _shimmer = AnimationController(
      vsync: _vsync,
      duration: const Duration(milliseconds: 1600),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _vsync.setDisplayRefreshRate(View.of(context).display.refreshRate);
    _syncMotion();
  }

  void _syncMotion() {
    _vsync.enabled = _tickerEnabled && _appIsActive && !_reducedMotion;
    if (_tickerEnabled && _appIsActive && !_reducedMotion) {
      if (!_shimmer.isAnimating) _shimmer.repeat();
    } else {
      _shimmer.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsActive = state == AppLifecycleState.resumed;
    _syncMotion();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shimmer.dispose();
    _vsync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expanded = MediaQuery.sizeOf(context).width >= 700;
    final shimmer = _reducedMotion ? null : _shimmer.view;
    return Semantics(
      container: true,
      liveRegion: true,
      label: widget.label,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var section = 0; section < 3; section++)
                  _LoadingShelf(
                    shimmer: shimmer,
                    artists: section == 1,
                    cardWidth: section == 1
                        ? (expanded ? 156 : 132)
                        : (expanded ? 196 : 164),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingShelf extends StatelessWidget {
  const _LoadingShelf({
    required this.cardWidth,
    required this.artists,
    required this.shimmer,
  });

  final double cardWidth;
  final bool artists;
  final Animation<double>? shimmer;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return Padding(
      padding: const EdgeInsets.only(top: appTabFirstSectionTopGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: appTabTitleHorizontalPadding,
            ),
            child: _LoadingBlock(
              shimmer: shimmer,
              width: artists ? 164 : 192,
              height: scaler.scale(20),
            ),
          ),
          const SizedBox(height: appSectionTitleGap),
          LayoutBuilder(
            builder: (context, constraints) {
              final count =
                  (constraints.maxWidth / (cardWidth + 10)).ceil() + 1;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var card = 0; card < count; card++) ...[
                      if (card > 0) const SizedBox(width: 10),
                      SizedBox(
                        width: cardWidth,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: artists
                                ? Colors.transparent
                                : AppColors.homeCardSurfaceFor(context),
                            borderRadius: BorderRadius.circular(appCardRadius),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              crossAxisAlignment: artists
                                  ? CrossAxisAlignment.center
                                  : CrossAxisAlignment.start,
                              children: [
                                _LoadingBlock(
                                  shimmer: shimmer,
                                  width: cardWidth - 16,
                                  height: cardWidth - 16,
                                  radius: artists ? cardWidth : 8,
                                ),
                                const SizedBox(height: 8),
                                _LoadingBlock(
                                  shimmer: shimmer,
                                  width: (cardWidth - 16) * 0.78,
                                  height: scaler.scale(14),
                                ),
                                const SizedBox(height: 6),
                                _LoadingBlock(
                                  shimmer: shimmer,
                                  width: (cardWidth - 16) * 0.52,
                                  height: scaler.scale(10),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock({
    required this.width,
    required this.height,
    required this.shimmer,
    this.radius = 5,
  });

  final double width;
  final double height;
  final double radius;
  final Animation<double>? shimmer;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final base = Color.alphaBlend(
      colors.onSurface.withValues(alpha: 0.045),
      colors.surfaceContainerHighest,
    );
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _LoadingBlockPainter(
          shimmer: shimmer,
          base: base,
          highlight: Color.alphaBlend(
            colors.onSurface.withValues(
              alpha: colors.brightness == Brightness.dark ? 0.12 : 0.075,
            ),
            base,
          ),
          radius: radius,
        ),
      ),
    );
  }
}

/// Animation ticks repaint the shapes without rebuilding or laying out shelves.
class _LoadingBlockPainter extends CustomPainter {
  _LoadingBlockPainter({
    required this.shimmer,
    required this.base,
    required this.highlight,
    required this.radius,
  }) : _gradient = LinearGradient(colors: [base, highlight, base]),
       super(repaint: shimmer);

  final Animation<double>? shimmer;
  final Color base;
  final Color highlight;
  final double radius;
  final LinearGradient _gradient;
  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final animation = shimmer;
    _paint.color = base;
    _paint.shader = animation == null
        ? null
        : _gradient.createShader(
            Rect.fromLTWH(
              size.width * (animation.value * 2 - 1),
              0,
              size.width,
              size.height,
            ),
          );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      _paint,
    );
  }

  @override
  bool shouldRepaint(covariant _LoadingBlockPainter oldDelegate) =>
      shimmer != oldDelegate.shimmer ||
      base != oldDelegate.base ||
      highlight != oldDelegate.highlight ||
      radius != oldDelegate.radius;
}
