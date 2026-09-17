import 'package:flutter/material.dart';

import '../providers/lyrics_animation_style.dart';

// Keep lyric changes long enough to read as one continuous movement, while
// finishing quickly enough that a short line does not lag behind playback.
const _kLyricsSmoothDuration = Duration(milliseconds: 580);
const _kLyricsSlideDuration = Duration(milliseconds: 550);
const _kLyricsHighlightDuration = Duration(milliseconds: 570);
const _kLyricsExitDuration = Duration(milliseconds: 460);

const _kLyricsSmoothInactiveScale = 0.98;
const _kLyricsSmoothInactiveOpacity = 0.62;

const _kLyricsSlideOffsetPx = 34.0;
const _kLyricsSlideInactiveOpacity = 0.70;

const _kLyricsHighlightActiveBackgroundAlpha = 0.10;
const _kLyricsHighlightActiveShadowAlpha = 0.16;
const _kLyricsHighlightActiveScale = 1.01;
const _kLyricsHighlightInactiveScale = 0.98;

class LyricsAnimationTransition extends StatefulWidget {
  const LyricsAnimationTransition({
    required this.style,
    required this.active,
    required this.accent,
    required this.child,
    this.alignment = Alignment.centerLeft,
    super.key,
  });

  final LyricsAnimationStyle style;
  final bool active;
  final Color accent;
  final Widget child;
  final Alignment alignment;

  @override
  State<LyricsAnimationTransition> createState() =>
      _LyricsAnimationTransitionState();
}

class _LyricsAnimationTransitionState extends State<LyricsAnimationTransition>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _slideController;
  late Animation<double> _animation;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _durationFor(widget.style),
      reverseDuration: _kLyricsExitDuration,
    );
    _slideController = AnimationController(
      vsync: this,
      duration: _kLyricsSlideDuration,
      value: 1,
    );
    _animation = _buildTween(widget.style);
    if (widget.active) {
      _controller.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disableAnimations) {
      return;
    }
    _disableAnimations = disableAnimations;
    _controller.stop();
    _slideController.stop();
    _controller.value = widget.active ? 1 : 0;
    _slideController.value = 1;
  }

  @override
  void didUpdateWidget(covariant LyricsAnimationTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final styleChanged = oldWidget.style != widget.style;
    final wasPartiallyVisible = _controller.value > 0;
    if (styleChanged) {
      _controller.duration = _durationFor(widget.style);
      _controller.reverseDuration = _kLyricsExitDuration;
      _animation = _buildTween(widget.style);
    }
    if (_disableAnimations) {
      _controller.stop();
      _slideController.stop();
      _controller.value = widget.active ? 1 : 0;
      _slideController.value = 1;
      return;
    }
    if (widget.active != oldWidget.active || styleChanged) {
      _controller.stop();
      if (widget.active) {
        if (styleChanged) {
          _controller.forward(from: 0);
        } else {
          // Preserve the current value when playback quickly crosses a line
          // boundary in either direction. Retargeting the animation avoids a
          // visible opacity/scale snap during seeks and short lyric lines.
          _controller.forward();
        }
      } else if (styleChanged) {
        _controller.value = 0;
      } else {
        _controller.reverse();
      }
    }
    if (widget.style == LyricsAnimationStyle.slide) {
      if (widget.active && (!oldWidget.active || styleChanged)) {
        if (wasPartiallyVisible && !styleChanged) {
          _slideController.forward();
        } else {
          _slideController.forward(from: 0);
        }
      } else if (!widget.active) {
        // If a short line deactivates before finishing its entrance, keep
        // moving toward the resting position instead of snapping to it.
        _slideController.forward();
      }
    } else {
      _slideController
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _slideController.dispose();
    super.dispose();
  }

  static Duration _durationFor(LyricsAnimationStyle style) {
    return switch (style) {
      LyricsAnimationStyle.smooth => _kLyricsSmoothDuration,
      LyricsAnimationStyle.slide => _kLyricsSlideDuration,
      LyricsAnimationStyle.highlight => _kLyricsHighlightDuration,
    };
  }

  Animation<double> _buildTween(LyricsAnimationStyle style) {
    return CurvedAnimation(
      parent: _controller,
      curve: switch (style) {
        // Avoid the overshoot from easeOutBack: it made the highlight land
        // with a small visual bump when two short lines changed quickly.
        _ => Curves.easeOutCubic,
      },
      reverseCurve: Curves.easeInOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    final alignment = widget.alignment;
    final accent = widget.accent;
    return AnimatedBuilder(
      animation: Listenable.merge([_animation, _slideController]),
      builder: (context, child) {
        final value = _animation.value;
        return switch (widget.style) {
          LyricsAnimationStyle.smooth => Opacity(
            opacity: lerpDouble(_kLyricsSmoothInactiveOpacity, 1, value),
            child: Transform.scale(
              scale: lerpDouble(_kLyricsSmoothInactiveScale, 1, value),
              alignment: alignment,
              child: child,
            ),
          ),
          LyricsAnimationStyle.slide => Opacity(
            opacity: lerpDouble(_kLyricsSlideInactiveOpacity, 1, value),
            child: Transform.translate(
              offset: Offset(
                0,
                _kLyricsSlideOffsetPx * (1 - _slideController.value),
              ),
              child: child,
            ),
          ),
          LyricsAnimationStyle.highlight => DecoratedBox(
            decoration: BoxDecoration(
              color: accent.withValues(
                alpha: _kLyricsHighlightActiveBackgroundAlpha * value,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: value == 0
                  ? null
                  : [
                      BoxShadow(
                        color: accent.withValues(
                          alpha: _kLyricsHighlightActiveShadowAlpha * value,
                        ),
                        blurRadius: 18 * value,
                        spreadRadius: value,
                      ),
                    ],
            ),
            child: Transform.scale(
              scale: lerpDouble(
                _kLyricsHighlightInactiveScale,
                _kLyricsHighlightActiveScale,
                value,
              ),
              alignment: alignment,
              child: child,
            ),
          ),
        };
      },
      child: widget.child,
    );
  }
}

double lerpDouble(double begin, double end, double t) {
  return begin + (end - begin) * t;
}

class LyricsAnimationPreviewTransition extends StatelessWidget {
  const LyricsAnimationPreviewTransition({
    required this.style,
    required this.accent,
    required this.child,
    this.alignment = Alignment.centerLeft,
    super.key,
  });

  final LyricsAnimationStyle style;
  final Color accent;
  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: _kDurationForPreview(style),
      curve: switch (style) {
        _ => Curves.easeOutCubic,
      },
      builder: (context, value, child) {
        return switch (style) {
          LyricsAnimationStyle.smooth => Opacity(
            opacity: value,
            child: Transform.scale(
              scale:
                  _kLyricsSmoothInactiveScale +
                  ((1 - _kLyricsSmoothInactiveScale) * value),
              alignment: alignment,
              child: child,
            ),
          ),
          LyricsAnimationStyle.slide => Opacity(
            opacity: lerpDouble(_kLyricsSlideInactiveOpacity, 1, value),
            child: Transform.translate(
              offset: Offset(0, _kLyricsSlideOffsetPx * (1 - value)),
              child: child,
            ),
          ),
          LyricsAnimationStyle.highlight => DecoratedBox(
            decoration: BoxDecoration(
              color: accent.withValues(
                alpha: _kLyricsHighlightActiveBackgroundAlpha * value,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: value == 0
                  ? null
                  : [
                      BoxShadow(
                        color: accent.withValues(
                          alpha: _kLyricsHighlightActiveShadowAlpha * value,
                        ),
                        blurRadius: 18 * value,
                        spreadRadius: value,
                      ),
                    ],
            ),
            child: Transform.scale(
              scale:
                  _kLyricsHighlightInactiveScale +
                  ((_kLyricsHighlightActiveScale -
                          _kLyricsHighlightInactiveScale) *
                      value),
              alignment: alignment,
              child: child,
            ),
          ),
        };
      },
      child: child,
    );
  }

  static Duration _kDurationForPreview(LyricsAnimationStyle style) {
    return switch (style) {
      LyricsAnimationStyle.smooth => _kLyricsSmoothDuration,
      LyricsAnimationStyle.slide => _kLyricsSlideDuration,
      LyricsAnimationStyle.highlight => _kLyricsHighlightDuration,
    };
  }
}
