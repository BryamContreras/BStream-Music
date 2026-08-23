import 'dart:async';

import 'package:flutter/material.dart';

/// A single-line title that scrolls only when it does not fit its bounds.
///
/// The animation pauses at both ends and reverses direction, so long names
/// remain readable without an abrupt continuous ticker. Short labels stay a
/// normal [Text] and do not allocate an animation ticker.
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.textScaler,
    this.pause = const Duration(milliseconds: 1300),
    this.travel = const Duration(milliseconds: 5200),
    this.gap = 32,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final TextScaler? textScaler;
  final Duration pause;
  final Duration travel;
  final double gap;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  Timer? _startTimer;
  ScrollNotificationObserverState? _scrollNotificationObserver;

  double _overflow = 0;
  bool _metricsPending = false;
  bool _visibilityCheckPending = false;
  bool _viewportVisible = true;
  bool _appActive = true;

  Duration get _cycleDuration =>
      widget.pause + widget.travel + widget.pause + widget.travel;

  @override
  void initState() {
    super.initState();
    // Initialize while the State is mounted. Short labels never build the
    // animated branch, so lazy initialization would otherwise happen during
    // dispose after the element tree has already been deactivated.
    _controller = AnimationController(vsync: this, duration: _cycleDuration);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ScrollNotificationObserver.maybeOf(context);
    if (observer != _scrollNotificationObserver) {
      _scrollNotificationObserver?.removeListener(_handleScrollNotification);
      _scrollNotificationObserver = observer;
      observer?.addListener(_handleScrollNotification);
    }
    _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.pause != widget.pause ||
        oldWidget.travel != widget.travel ||
        oldWidget.gap != widget.gap) {
      _scheduleMetrics(0);
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _scrollNotificationObserver?.removeListener(_handleScrollNotification);
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _updateAnimationAvailability();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final direction = widget.textDirection ?? Directionality.of(context);
        final scaler = widget.textScaler ?? MediaQuery.textScalerOf(context);
        final textStyle = widget.style ?? DefaultTextStyle.of(context).style;
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: textStyle),
          textDirection: direction,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final available = constraints.maxWidth;
        // Move only the part that does not fit. Including an extra gap here
        // would move the sole copy past the viewport and leave empty space at
        // the right edge when it reaches the end.
        final overflow = available.isFinite
            ? painter.width - available
            : 0.0;
        _scheduleMetrics(overflow > 0 ? overflow : 0);
        _scheduleVisibilityCheck();

        if (_overflow <= 0 || !available.isFinite) {
          return Text(
            widget.text,
            style: widget.style,
            textAlign: widget.textAlign,
            textDirection: widget.textDirection,
            textScaler: widget.textScaler,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }

        final sequence = TweenSequence<double>([
          TweenSequenceItem(
            tween: ConstantTween<double>(0),
            weight: widget.pause.inMilliseconds.toDouble(),
          ),
          TweenSequenceItem(
            tween: Tween<double>(begin: 0, end: -_overflow),
            weight: widget.travel.inMilliseconds.toDouble(),
          ),
          TweenSequenceItem(
            tween: ConstantTween<double>(-_overflow),
            weight: widget.pause.inMilliseconds.toDouble(),
          ),
          TweenSequenceItem(
            tween: Tween<double>(begin: -_overflow, end: 0),
            weight: widget.travel.inMilliseconds.toDouble(),
          ),
        ]);
        // Keep a fixed viewport at the width offered by the card.  The text
        // itself keeps its measured width, while the Stack clips only the
        // horizontal movement.  Giving the viewport the measured text height
        // is important: an unconstrained overflow box can inherit the full
        // screen height and make every card overflow vertically.
        return SizedBox(
          width: available,
          height: painter.height,
          child: ClipRect(
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  child: AnimatedBuilder(
                    key: const ValueKey('marquee-text-animation'),
                    animation: _controller,
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(sequence.evaluate(_controller), 0),
                        child: child,
                      );
                    },
                    child: _buildLabel(
                      painter.width,
                      painter.height,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLabel(double width, double height) {
    return SizedBox(
      width: width,
      height: height,
      child: Text(
        widget.text,
        style: widget.style,
        textAlign: widget.textAlign,
        textDirection: widget.textDirection,
        textScaler: widget.textScaler,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }

  void _scheduleMetrics(double overflow) {
    if (_metricsPending) {
      return;
    }
    _metricsPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsPending = false;
      if (!mounted) {
        return;
      }
      final changed = (_overflow - overflow).abs() > 0.5;
      if (!changed) {
        return;
      }
      setState(() {
        _overflow = overflow;
      });
      _controller
        ..duration = _cycleDuration
        ..stop();
      _startTimer?.cancel();
      _updateAnimationAvailability();
    });
  }

  bool get _animationEnabled =>
      mounted && _overflow > 0 && _viewportVisible && _appActive;

  void _handleScrollNotification(ScrollNotification notification) {
    _scheduleVisibilityCheck();
  }

  void _scheduleVisibilityCheck() {
    if (_visibilityCheckPending) return;
    _visibilityCheckPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckPending = false;
      if (!mounted) return;
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize) {
        return;
      }
      final topLeft = renderObject.localToGlobal(Offset.zero);
      final bounds = topLeft & renderObject.size;
      final viewport = Offset.zero & MediaQuery.sizeOf(context);
      final visible = bounds.overlaps(viewport);
      if (_viewportVisible != visible) {
        _viewportVisible = visible;
        _updateAnimationAvailability();
      }
    });
  }

  void _updateAnimationAvailability() {
    if (!_animationEnabled) {
      _startTimer?.cancel();
      _startTimer = null;
      _controller.stop();
      return;
    }
    if (!_controller.isAnimating && _startTimer == null) {
      _queueCycleStart();
    }
  }

  void _queueCycleStart() {
    if (!_animationEnabled) return;
    _startTimer?.cancel();
    _startTimer = Timer(widget.pause, () {
      _startTimer = null;
      if (!mounted || !_animationEnabled) return;
      _controller
        ..duration = _cycleDuration
        ..forward(from: 0).whenComplete(() {
          if (mounted && _animationEnabled) _queueCycleStart();
        });
    });
  }
}
