import 'package:flutter/material.dart';

import '../../../../core/animation/frame_rate_ticker_provider.dart';

/// A finite decorative progress tween that leaves unused display frames idle.
/// Interactive sliders and lyric scrolling keep their ordinary full-rate clocks.
class DecorativeProgressTransition extends StatefulWidget {
  const DecorativeProgressTransition({
    required this.value,
    required this.builder,
    this.duration = const Duration(milliseconds: 220),
    this.curve = Curves.easeOutCubic,
    this.animateProgress = true,
    this.animationKey,
    this.child,
    super.key,
  });

  final double value;
  final Duration duration;
  final Curve curve;
  final bool animateProgress;
  final Key? animationKey;
  final Widget Function(BuildContext context, double progress, Widget? child)
  builder;
  final Widget? child;

  @override
  State<DecorativeProgressTransition> createState() =>
      _DecorativeProgressTransitionState();
}

class _DecorativeProgressTransitionState
    extends State<DecorativeProgressTransition>
    with WidgetsBindingObserver {
  final _vsync = FrameRateTickerProvider(maxFramesPerSecond: 30);
  late final AnimationController _controller;
  late Tween<double> _tween;
  bool _tickerEnabled = true;
  bool _appActive = true;
  bool _reducedMotion = false;
  bool _snapNextUpdate = false;

  double get _target => widget.value.clamp(0.0, 1.0).toDouble();
  bool get _presentationActive => _tickerEnabled && _appActive;
  bool get _animate =>
      widget.animateProgress && _presentationActive && !_reducedMotion;
  double get _paintedProgress =>
      _tween.transform(widget.curve.transform(_controller.value));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _tween = Tween(begin: _target, end: _target);
    _controller = AnimationController(
      vsync: _vsync,
      duration: widget.duration,
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _vsync.setDisplayRefreshRate(View.of(context).display.refreshRate);
    _syncAvailability();
  }

  @override
  void didUpdateWidget(covariant DecorativeProgressTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    _syncAvailability();
    if (oldWidget.value.clamp(0.0, 1.0) == _target) return;
    if (_animate && !_snapNextUpdate) {
      // Native samples and seeks retarget from the fraction actually displayed.
      _tween = Tween(begin: _paintedProgress, end: _target);
      _controller.forward(from: 0);
    } else {
      _snapToTarget();
    }
    if (_presentationActive) _snapNextUpdate = false;
  }

  void _snapToTarget() {
    if (!_controller.isAnimating &&
        _tween.begin == _target &&
        _tween.end == _target) {
      return;
    }
    _controller.stop();
    _tween = Tween(begin: _target, end: _target);
    _controller.value = 1;
  }

  void _syncAvailability() {
    _vsync.enabled = _presentationActive && !_reducedMotion;
    if (!_presentationActive) _snapNextUpdate = true;
    if (!_animate) _snapToTarget();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    setState(() {
      _appActive = active;
      _syncAvailability();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _vsync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    key: widget.animationKey,
    animation: _controller,
    builder: (context, child) =>
        widget.builder(context, _paintedProgress, child),
    child: widget.child,
  );
}
