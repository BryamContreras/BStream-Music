import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../animation/frame_rate_ticker_provider.dart';

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
    this.pixelsPerSecond = 24,
    this.gap = 32,
  }) : assert(pixelsPerSecond > 0 && pixelsPerSecond < double.infinity);

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final TextScaler? textScaler;
  final Duration pause;

  /// Minimum duration for one direction. Small overflows keep their gentle
  /// motion; longer labels take longer instead of crossing faster.
  final Duration travel;
  final double pixelsPerSecond;
  final double gap;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> with WidgetsBindingObserver {
  // Slow, readable movement still looks uneven at 30 Hz. Only the retained
  // label transform ticks at up to 60 Hz, never the full player or a 120 Hz loop.
  final _vsync = FrameRateTickerProvider();
  AnimationController? _controller;
  Timer? _startTimer;
  ScrollNotificationObserverState? _scrollNotificationObserver;
  bool _observingScroll = false;

  double _overflow = 0;
  double _pendingOverflow = 0;
  bool _metricsPending = false;
  bool _restartPending = false;
  bool _visibilityCheckPending = false;
  bool _viewportVisible = true;
  bool _appActive = true;
  bool _tickerEnabled = true;
  bool _reducedMotion = false;
  _MarqueeLabelMetrics? _labelMetrics;

  _MarqueeMotionPhase _phase = _MarqueeMotionPhase.atStart;

  AnimationController get _animationController => _controller ??=
      AnimationController(vsync: _vsync, duration: _travelDuration);

  Duration get _travelDuration {
    final duration = Duration(
      microseconds:
          (_overflow / widget.pixelsPerSecond * Duration.microsecondsPerSecond)
              .ceil(),
    );
    return duration < widget.travel ? widget.travel : duration;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appActive =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ScrollNotificationObserver.maybeOf(context);
    if (observer != _scrollNotificationObserver) {
      if (_observingScroll) {
        _scrollNotificationObserver?.removeListener(_handleScrollNotification);
        _observingScroll = false;
      }
      _scrollNotificationObserver = observer;
    }
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _vsync.setDisplayRefreshRate(View.of(context).display.refreshRate);
    _vsync.enabled = _tickerEnabled && _appActive;
    _syncScrollObservation();
    _updateAnimationAvailability();
    if (_overflow > 0) _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.pause != widget.pause ||
        oldWidget.travel != widget.travel ||
        oldWidget.pixelsPerSecond != widget.pixelsPerSecond ||
        oldWidget.textDirection != widget.textDirection ||
        oldWidget.gap != widget.gap) {
      // The next build measures the new label. Keep the previous layout until
      // then instead of briefly drawing a static/ellipsized title.
      _restartPending = true;
      _scheduleMetrics(_overflow);
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    if (_observingScroll) {
      _scrollNotificationObserver?.removeListener(_handleScrollNotification);
    }
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _vsync.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _vsync.enabled = _tickerEnabled && _appActive;
    _syncScrollObservation();
    _updateAnimationAvailability();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final direction = widget.textDirection ?? Directionality.of(context);
        final scaler = widget.textScaler ?? MediaQuery.textScalerOf(context);
        final textSize = _measureLabel(context, direction, scaler);
        final available = constraints.maxWidth;
        // Move only the part that does not fit. Including an extra gap here
        // would move the sole copy past the viewport and leave empty space at
        // the right edge when it reaches the end.
        final overflow = available.isFinite ? textSize.width - available : 0.0;
        final measuredOverflow = overflow > 0 ? overflow : 0.0;
        final textWidth = textSize.width;
        final textHeight = textSize.height;
        _scheduleMetrics(measuredOverflow);
        if (measuredOverflow > 0) _scheduleVisibilityCheck();

        if (measuredOverflow <= 0 || !available.isFinite) {
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

        final controller = _animationController;
        // Keep a fixed viewport at the width offered by the card.  The text
        // itself keeps its measured width, while the viewport clips only the
        // horizontal movement.  Giving the viewport the measured text height
        // is important: an unconstrained overflow box can inherit the full
        // screen height and make every card overflow vertically.
        return SizedBox(
          key: const ValueKey('marquee-text-viewport-cache'),
          width: available,
          height: textHeight,
          // Flow listens at paint time: no per-frame widget rebuild, text
          // layout, or LayoutBuilder invalidation propagates up the player.
          // It also retains each child in its own repaint boundary.
          child: ClipRect(
            child: Flow(
              key: const ValueKey('marquee-text-animation'),
              clipBehavior: Clip.none,
              delegate: _MarqueeFlowDelegate(
                animation: controller,
                overflow: _overflow,
                labelSize: textSize,
              ),
              children: [_buildLabel(textWidth, textHeight)],
            ),
          ),
        );
      },
    );
  }

  Size _measureLabel(
    BuildContext context,
    TextDirection direction,
    TextScaler scaler,
  ) {
    final defaults = DefaultTextStyle.of(context);
    var style = widget.style;
    // Match Text's actual inherited font, not a second, fallback-font layout.
    if (style == null || style.inherit) style = defaults.style.merge(style);
    if (MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final locale = Localizations.maybeLocaleOf(context);
    final heightBehavior =
        defaults.textHeightBehavior ??
        DefaultTextHeightBehavior.maybeOf(context);
    final previous = _labelMetrics;
    if (previous != null &&
        previous.text == widget.text &&
        previous.style.compareTo(style) != RenderComparison.layout &&
        previous.direction == direction &&
        previous.scaler == scaler &&
        previous.locale == locale &&
        previous.heightBehavior == heightBehavior) {
      // Playback position and color updates must not reshape long labels.
      return previous.size;
    }
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
      textHeightBehavior: heightBehavior,
      maxLines: 1,
    )..layout();
    final size = painter.size;
    painter.dispose();
    _labelMetrics = _MarqueeLabelMetrics(
      text: widget.text,
      style: style,
      direction: direction,
      scaler: scaler,
      locale: locale,
      heightBehavior: heightBehavior,
      size: size,
    );
    return size;
  }

  Widget _buildLabel(double width, double height) {
    return SizedBox(
      key: const ValueKey('marquee-text-label-cache'),
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
    _pendingOverflow = overflow;
    if (_metricsPending) {
      return;
    }
    if ((_overflow - overflow).abs() <= 0.5 && !_restartPending) {
      return;
    }
    _metricsPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsPending = false;
      if (!mounted) {
        return;
      }
      final changed = (_overflow - _pendingOverflow).abs() > 0.5;
      if (!changed && !_restartPending) {
        return;
      }
      _restartPending = false;
      if (changed) {
        setState(() {
          _overflow = _pendingOverflow;
        });
      }
      _startTimer?.cancel();
      _startTimer = null;
      _phase = _MarqueeMotionPhase.atStart;
      final controller = _controller;
      if (controller != null) {
        controller
          ..stop()
          ..duration = _travelDuration
          ..value = 0;
      }
      _syncScrollObservation();
      _updateAnimationAvailability();
      if (_overflow > 0) _scheduleVisibilityCheck();
    });
  }

  void _syncScrollObservation() {
    // Short labels and inactive routes have no animation to reveal. They do
    // not need one geometry check per scroll frame from the global observer.
    final shouldObserve =
        _scrollNotificationObserver != null &&
        _overflow > 0 &&
        _appActive &&
        _tickerEnabled &&
        !_reducedMotion;
    if (shouldObserve == _observingScroll) return;
    if (shouldObserve) {
      _scrollNotificationObserver!.addListener(_handleScrollNotification);
    } else {
      _scrollNotificationObserver?.removeListener(_handleScrollNotification);
    }
    _observingScroll = shouldObserve;
  }

  bool get _animationEnabled =>
      mounted &&
      _overflow > 0 &&
      _viewportVisible &&
      _appActive &&
      _tickerEnabled &&
      !_reducedMotion;

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
      var bounds = MatrixUtils.transformRect(
        renderObject.getTransformTo(null),
        Offset.zero & renderObject.size,
      ).intersect(Offset.zero & MediaQuery.sizeOf(context));
      RenderObject child = renderObject;
      var ancestor = child.parent;
      while (ancestor != null && !bounds.isEmpty) {
        if ((ancestor is RenderOffstage && ancestor.offstage) ||
            (ancestor is RenderOpacity && ancestor.opacity == 0)) {
          bounds = Rect.zero;
          break;
        }
        final clip = ancestor.describeApproximatePaintClip(child);
        if (clip != null) {
          bounds = bounds.intersect(
            MatrixUtils.transformRect(ancestor.getTransformTo(null), clip),
          );
        }
        child = ancestor;
        ancestor = ancestor.parent;
      }
      final visible = !bounds.isEmpty && bounds.width > 0 && bounds.height > 0;
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
      _phase = _MarqueeMotionPhase.atStart;
      final controller = _controller;
      controller?.stop();
      if (controller != null && controller.value != 0) {
        controller.value = 0;
      }
      return;
    }
    if (_phase == _MarqueeMotionPhase.atStart &&
        !_animationController.isAnimating &&
        _startTimer == null) {
      _queueForward();
    }
  }

  void _queueForward() {
    if (!_animationEnabled) return;
    _startTimer?.cancel();
    // The old cycle paused once between cycles and once at the start of the
    // next cycle. Keep that reading time, without ticking stationary frames.
    _startTimer = Timer(widget.pause + widget.pause, () {
      _startTimer = null;
      if (!mounted || !_animationEnabled) return;
      _phase = _MarqueeMotionPhase.forward;
      _animationController
        ..duration = _travelDuration
        ..forward(from: 0).whenCompleteOrCancel(() {
          if (!mounted ||
              !_animationEnabled ||
              _phase != _MarqueeMotionPhase.forward) {
            return;
          }
          _phase = _MarqueeMotionPhase.atEnd;
          _startTimer = Timer(widget.pause, () {
            _startTimer = null;
            if (!mounted || !_animationEnabled) return;
            _phase = _MarqueeMotionPhase.reverse;
            _animationController.reverse(from: 1).whenCompleteOrCancel(() {
              if (!mounted ||
                  !_animationEnabled ||
                  _phase != _MarqueeMotionPhase.reverse) {
                return;
              }
              _phase = _MarqueeMotionPhase.atStart;
              _queueForward();
            });
          });
        });
    });
  }
}

enum _MarqueeMotionPhase { atStart, forward, atEnd, reverse }

class _MarqueeFlowDelegate extends FlowDelegate {
  _MarqueeFlowDelegate({
    required this.animation,
    required this.overflow,
    required this.labelSize,
  }) : super(repaint: animation);

  final Animation<double> animation;
  final double overflow;
  final Size labelSize;

  @override
  BoxConstraints getConstraintsForChild(
    int index,
    BoxConstraints constraints,
  ) => BoxConstraints.tight(labelSize);

  @override
  void paintChildren(FlowPaintingContext context) {
    context.paintChild(
      0,
      transform: Matrix4.translationValues(-overflow * animation.value, 0, 0),
    );
  }

  @override
  bool shouldRelayout(_MarqueeFlowDelegate oldDelegate) =>
      oldDelegate.labelSize != labelSize;

  @override
  bool shouldRepaint(_MarqueeFlowDelegate oldDelegate) =>
      oldDelegate.animation != animation || oldDelegate.overflow != overflow;
}

class _MarqueeLabelMetrics {
  const _MarqueeLabelMetrics({
    required this.text,
    required this.style,
    required this.direction,
    required this.scaler,
    required this.locale,
    required this.heightBehavior,
    required this.size,
  });

  final String text;
  final TextStyle style;
  final TextDirection direction;
  final TextScaler scaler;
  final Locale? locale;
  final TextHeightBehavior? heightBehavior;
  final Size size;
}
