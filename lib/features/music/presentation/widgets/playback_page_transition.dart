import 'package:flutter/material.dart';

const playbackPageTransitionDuration = Duration(milliseconds: 420);
const playbackPageReverseTransitionDuration = Duration(milliseconds: 360);
const playbackPageTransitionBeginOffset = Offset(0, 0.035);

/// The shared page motion used when moving into a playback-focused surface.
///
/// Lyrics and the full player intentionally use this same composition so
/// their fade, vertical travel, curves, and raster boundary cannot drift.
class PlaybackPageTransition extends StatelessWidget {
  const PlaybackPageTransition({
    required this.animation,
    required this.child,
    this.fadeKey,
    this.slideKey,
    this.repaintBoundaryKey,
    super.key,
  });

  final Animation<double> animation;
  final Widget child;
  final Key? fadeKey;
  final Key? slideKey;
  final Key? repaintBoundaryKey;

  @override
  Widget build(BuildContext context) {
    final motion = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
    final opacity = animation.drive(CurveTween(curve: Curves.easeInOut));

    return FadeTransition(
      key: fadeKey,
      opacity: opacity,
      child: SlideTransition(
        key: slideKey,
        position: Tween<Offset>(
          begin: playbackPageTransitionBeginOffset,
          end: Offset.zero,
        ).animate(motion),
        child: RepaintBoundary(key: repaintBoundaryKey, child: child),
      ),
    );
  }
}

/// Drives [PlaybackPageTransition] while keeping its child mounted between
/// visits. This mirrors a maintained page route without rebuilding playback.
class PlaybackPageVisibilityTransition extends StatefulWidget {
  const PlaybackPageVisibilityTransition({
    required this.visible,
    required this.child,
    this.duration = playbackPageTransitionDuration,
    this.reverseDuration = playbackPageReverseTransitionDuration,
    this.animateInitialEntry = true,
    this.fadeKey,
    this.slideKey,
    this.repaintBoundaryKey,
    super.key,
  });

  final bool visible;
  final Widget child;
  final Duration duration;
  final Duration reverseDuration;
  final bool animateInitialEntry;
  final Key? fadeKey;
  final Key? slideKey;
  final Key? repaintBoundaryKey;

  @override
  State<PlaybackPageVisibilityTransition> createState() =>
      _PlaybackPageVisibilityTransitionState();
}

class _PlaybackPageVisibilityTransitionState
    extends State<PlaybackPageVisibilityTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    final startsVisible = widget.visible && !widget.animateInitialEntry;
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      reverseDuration: widget.reverseDuration,
      value: startsVisible ? 1 : 0,
    );
    if (widget.visible && !startsVisible) {
      _show();
    }
  }

  @override
  void didUpdateWidget(covariant PlaybackPageVisibilityTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.reverseDuration != oldWidget.reverseDuration) {
      _controller.reverseDuration = widget.reverseDuration;
    }
    if (widget.visible != oldWidget.visible) {
      widget.visible ? _show() : _hide();
    }
  }

  void _show() {
    if (widget.duration == Duration.zero) {
      _controller.value = 1;
      return;
    }
    _controller.forward();
  }

  void _hide() {
    if (widget.reverseDuration == Duration.zero) {
      _controller.value = 0;
      return;
    }
    _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PlaybackPageTransition(
      animation: _controller,
      fadeKey: widget.fadeKey,
      slideKey: widget.slideKey,
      repaintBoundaryKey: widget.repaintBoundaryKey,
      child: widget.child,
    );
  }
}
