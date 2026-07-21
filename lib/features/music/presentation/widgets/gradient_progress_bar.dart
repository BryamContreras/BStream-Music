import 'package:flutter/material.dart';

class GradientProgressBar extends StatefulWidget {
  const GradientProgressBar({
    required this.value,
    this.height = 4,
    this.backgroundColor = const Color(0x6636463A),
    this.colors = const [Color(0xFF18C75A), Color(0xFF0E9F4D)],
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
    return ClipRRect(
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
              ),
      ),
    );
  }

  void _syncAnimation() {
    if (widget.indeterminate) {
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
  });

  final double? value;
  final Color backgroundColor;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final progress = (value ?? 0).clamp(0.0, 1.0).toDouble();

    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: backgroundColor)),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: progress),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          builder: (context, animatedProgress, child) {
            return Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: animatedProgress,
                child: child,
              ),
            );
          },
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(colors: colors)),
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

        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final left =
                (width + segmentWidth) * animation.value - segmentWidth;
            return Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: backgroundColor)),
                Positioned(
                  left: left,
                  width: segmentWidth,
                  top: 0,
                  bottom: 0,
                  child: child!,
                ),
              ],
            );
          },
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(colors: colors)),
          ),
        );
      },
    );
  }
}
