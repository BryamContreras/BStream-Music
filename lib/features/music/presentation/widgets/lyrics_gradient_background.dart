import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import '../../../../core/animation/frame_rate_ticker_provider.dart';

/// Both gradient modes share the same three inexpensive canvas fills.
/// Motion repaints only this boundary, without rebuilding the lyrics or
/// extracting the artwork palette again.
class LyricsGradientBackground extends StatelessWidget {
  const LyricsGradientBackground({
    required this.color,
    this.animated = false,
    this.motionEnabled = true,
    this.scrimOpacity = 0,
    super.key,
  }) : assert(scrimOpacity >= 0 && scrimOpacity <= 1);

  final Color color;
  final bool animated;
  final bool motionEnabled;
  final double scrimOpacity;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: animated && !MediaQuery.disableAnimationsOf(context)
        ? _AnimatedLyricsGradient(
            color: color,
            motionEnabled: motionEnabled,
            scrimOpacity: scrimOpacity,
          )
        : CustomPaint(
            painter: _LyricsGradientPainter(
              color: color,
              scrimOpacity: scrimOpacity,
            ),
            child: const SizedBox.expand(),
          ),
  );
}

typedef _GradientPose = ({
  Alignment upperCenter,
  Alignment lowerCenter,
  double upperHue,
  double lowerHue,
  double upperLightness,
  double lowerLightness,
  double radius,
});

const _restPose = (
  upperCenter: Alignment.topLeft,
  lowerCenter: Alignment.bottomRight,
  upperHue: 0.0,
  lowerHue: 0.0,
  upperLightness: .58,
  lowerLightness: .56,
  radius: .95,
);

const _animatedStartPose = (
  upperCenter: Alignment(-.7, -.55),
  lowerCenter: Alignment(.7, .55),
  upperHue: 0.0,
  lowerHue: 0.0,
  upperLightness: .63,
  lowerLightness: .51,
  radius: .78,
);

class _AnimatedLyricsGradient extends StatefulWidget {
  const _AnimatedLyricsGradient({
    required this.color,
    required this.motionEnabled,
    required this.scrimOpacity,
  });

  final Color color;
  final bool motionEnabled;
  final double scrimOpacity;

  @override
  State<_AnimatedLyricsGradient> createState() =>
      _AnimatedLyricsGradientState();
}

class _AnimatedLyricsGradientState extends State<_AnimatedLyricsGradient>
    with WidgetsBindingObserver {
  // The ambient fields travel over seconds. Keep a lower budget than the
  // word highlight, which follows the audio clock.
  final _vsync = FrameRateTickerProvider(maxFramesPerSecond: 15);
  final _random = math.Random();
  late final AnimationController _controller;
  _GradientPose _from = _animatedStartPose;
  late _GradientPose _to;
  bool _visible = true;
  bool _appActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _to = _nextPose(_from);
    _controller =
        AnimationController(
          vsync: _vsync,
          duration: _nextDuration(),
          debugLabel: 'lyrics-gradient-drift',
        )..addStatusListener((status) {
          if (status != AnimationStatus.completed) return;
          _from = _to;
          _to = _nextPose(_from);
          _controller.duration = _nextDuration();
          _controller.forward(from: 0);
        });
  }

  Duration _nextDuration() => Duration(seconds: 3 + _random.nextInt(2));

  Alignment _nextFieldCenter(Alignment previous, {required bool upper}) {
    var x = -.9 + _random.nextDouble() * 1.8;
    final y = (upper ? -.8 : -.2) + _random.nextDouble();
    // Travel across the visible canvas. Restricting broad glows to their
    // original corners only changed the tint of an almost uniform surface.
    if ((Offset(x, y) - Offset(previous.x, previous.y)).distance < .9) {
      x = previous.x < 0 ? .9 : -.9;
    }
    return Alignment(x, y);
  }

  _GradientPose _nextPose(_GradientPose previous) => (
    upperCenter: _nextFieldCenter(previous.upperCenter, upper: true),
    lowerCenter: _nextFieldCenter(previous.lowerCenter, upper: false),
    // Four degrees keeps each corner within the artwork's original hue.
    upperHue: -4 + _random.nextDouble() * 8,
    lowerHue: -4 + _random.nextDouble() * 8,
    upperLightness: .58 + _random.nextDouble() * .08,
    lowerLightness: .45 + _random.nextDouble() * .1,
    radius: .68 + _random.nextDouble() * .22,
  );

  _GradientPose _pose() {
    final t = Curves.easeInOutSine.transform(_controller.value);
    return (
      upperCenter: Alignment.lerp(_from.upperCenter, _to.upperCenter, t)!,
      lowerCenter: Alignment.lerp(_from.lowerCenter, _to.lowerCenter, t)!,
      upperHue: lerpDouble(_from.upperHue, _to.upperHue, t)!,
      lowerHue: lerpDouble(_from.lowerHue, _to.lowerHue, t)!,
      upperLightness: lerpDouble(_from.upperLightness, _to.upperLightness, t)!,
      lowerLightness: lerpDouble(_from.lowerLightness, _to.lowerLightness, t)!,
      radius: lerpDouble(_from.radius, _to.radius, t)!,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _vsync.setDisplayRefreshRate(View.of(context).display.refreshRate);
    _synchronizeMotion();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _synchronizeMotion();
  }

  @override
  void didUpdateWidget(covariant _AnimatedLyricsGradient oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.motionEnabled != oldWidget.motionEnabled) _synchronizeMotion();
  }

  void _synchronizeMotion() {
    final animate = _visible && _appActive && widget.motionEnabled;
    _vsync.enabled = animate;
    if (animate) {
      if (!_controller.isAnimating) _controller.forward();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _vsync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _LyricsGradientPainter(
      color: widget.color,
      scrimOpacity: widget.scrimOpacity,
      animation: _controller,
      pose: _pose,
    ),
    willChange: widget.motionEnabled && _visible,
    child: const SizedBox.expand(),
  );
}

class _LyricsGradientPainter extends CustomPainter {
  _LyricsGradientPainter({
    required this.color,
    required this.scrimOpacity,
    this.animation,
    this.pose,
  }) : tone = HSLColor.fromColor(color),
       super(repaint: animation);

  final Color color;
  final HSLColor tone;
  final double scrimOpacity;
  final Listenable? animation;
  final _GradientPose Function()? pose;
  final Paint _paint = Paint();

  // Applying the black scrim to the gradient stops preserves the color of
  // the composite and avoids a separate full-screen blend on every frame.
  Color _shade(Color color) {
    final amount = 1 - scrimOpacity;
    return color.withValues(
      red: color.r * amount,
      green: color.g * amount,
      blue: color.b * amount,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final frame = pose?.call() ?? _restPose;
    final moving = animation != null;
    canvas.drawRect(
      rect,
      _paint
        ..shader = null
        ..color = _shade(tone.withLightness(moving ? .31 : .34).toColor()),
    );
    void corner(Alignment center, double hue, double lightness) {
      final color = _shade(
        tone.withHue((tone.hue + hue) % 360).withLightness(lightness).toColor(),
      );
      canvas.drawRect(
        rect,
        _paint
          ..color = Colors.white
          ..shader = RadialGradient(
            center: center,
            radius: frame.radius,
            colors: moving
                ? [
                    color.withValues(alpha: .98),
                    color.withValues(alpha: .78),
                    color.withValues(alpha: 0),
                  ]
                : [color.withValues(alpha: .9), color.withValues(alpha: 0)],
            stops: moving ? const [0, .25, 1] : null,
          ).createShader(rect),
      );
    }

    corner(frame.upperCenter, frame.upperHue, frame.upperLightness);
    corner(frame.lowerCenter, frame.lowerHue, frame.lowerLightness);
  }

  @override
  bool shouldRepaint(covariant _LyricsGradientPainter oldDelegate) =>
      color != oldDelegate.color ||
      scrimOpacity != oldDelegate.scrimOpacity ||
      animation != oldDelegate.animation ||
      pose != oldDelegate.pose;
}
