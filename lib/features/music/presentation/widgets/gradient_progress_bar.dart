import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

class GradientProgressBar extends StatefulWidget {
  const GradientProgressBar({
    required this.value,
    this.height = 4,
    this.backgroundColor = const Color(0x6636463A),
    this.colors = AppColors.downloadGradient,
    this.indeterminate = false,
    super.key,
  });

  final double? value;
  final double height;
  final Color backgroundColor;
  final List<Color> colors;
  final bool indeterminate;

  @override
  State<GradientProgressBar> createState() => _GradientProgressBarState();
}

class _GradientProgressBarState extends State<GradientProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant GradientProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: SizedBox(
          height: widget.height,
          child: widget.indeterminate
              ? _IndeterminateTrack(
                  animation: _controller,
                  backgroundColor: widget.backgroundColor,
                  colors: widget.colors,
                )
              : _DeterminateTrack(
                  value: widget.value,
                  backgroundColor: widget.backgroundColor,
                  colors: widget.colors,
                  disableAnimations: disableAnimations,
                ),
        ),
      ),
    );
  }

  void _syncAnimation() {
    if (!widget.indeterminate) {
      _controller.stop();
      return;
    }

    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (disableAnimations) {
      _controller.stop();
      _controller.value = 0.5;
      return;
    }

    if (TickerMode.valuesOf(context).enabled) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
      return;
    }

    _controller.stop();
  }
}

class _DeterminateTrack extends StatelessWidget {
  const _DeterminateTrack({
    required this.value,
    required this.backgroundColor,
    required this.colors,
    required this.disableAnimations,
  });

  final double? value;
  final Color backgroundColor;
  final List<Color> colors;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    final progress = (value ?? 0).clamp(0.0, 1.0).toDouble();

    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: backgroundColor)),
        Positioned.fill(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: progress),
            duration: disableAnimations
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, animatedProgress, child) {
              return Transform.scale(
                alignment: Alignment.centerLeft,
                scaleX: animatedProgress,
                scaleY: 1,
                transformHitTests: false,
                child: child,
              );
            },
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: colors),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _IndeterminateTrack extends StatelessWidget {
  const _IndeterminateTrack({
    required this.animation,
    required this.backgroundColor,
    required this.colors,
  });

  final Animation<double> animation;
  final Color backgroundColor;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final segmentWidth = width * 0.34;

        return Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: backgroundColor)),
            Positioned(
              left: 0,
              width: segmentWidth,
              top: 0,
              bottom: 0,
              child: AnimatedBuilder(
                animation: animation,
                builder: (context, child) {
                  final offset =
                      (width + segmentWidth) * animation.value - segmentWidth;
                  return Transform.translate(
                    offset: Offset(offset, 0),
                    transformHitTests: false,
                    child: child,
                  );
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: colors),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
