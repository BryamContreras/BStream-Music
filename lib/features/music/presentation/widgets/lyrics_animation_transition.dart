import 'package:flutter/material.dart';

import '../providers/lyrics_animation_style.dart';

const _kLyricsSmoothDuration = Duration(milliseconds: 520);
const _kLyricsSlideDuration = Duration(milliseconds: 460);
const _kLyricsHighlightDuration = Duration(milliseconds: 500);

const _kLyricsSmoothInactiveScale = 0.94;
const _kLyricsSmoothInactiveOpacity = 0.62;

const _kLyricsSlideOffsetPx = 34.0;
const _kLyricsSlideInactiveOpacity = 0.70;

const _kLyricsHighlightActiveBackgroundAlpha = 0.20;
const _kLyricsHighlightActiveShadowAlpha = 0.22;
const _kLyricsHighlightActiveScale = 1.04;
const _kLyricsHighlightInactiveScale = 0.94;

class LyricsAnimationTransition extends StatefulWidget {
  const LyricsAnimationTransition({
    required this.style,
    required this.active,
    required this.accent,
    required this.child,
    this.alignment = Alignment.centerLeft,
    this.revision = 0,
    super.key,
  });

  final LyricsAnimationStyle style;
  final bool active;
  final Color accent;
  final Widget child;
  final Alignment alignment;
  final int revision;

  @override
  State<LyricsAnimationTransition> createState() =>
      _LyricsAnimationTransitionState();
}

class _LyricsAnimationTransitionState extends State<LyricsAnimationTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _durationFor(widget.style),
    );
    _animation = _buildTween(widget.style);
    if (widget.active) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant LyricsAnimationTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    final styleChanged = oldWidget.style != widget.style;
    final revisionChanged = oldWidget.revision != widget.revision;
    if (styleChanged) {
      _controller.duration = _durationFor(widget.style);
      _animation = _buildTween(widget.style);
    }
    if (widget.active != oldWidget.active || styleChanged || revisionChanged) {
      _controller.stop();
      if (widget.active) {
        _controller.forward(from: 0);
      } else {
        _controller.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  static Duration _durationFor(LyricsAnimationStyle style) {
    return switch (style) {
      LyricsAnimationStyle.smooth => _kLyricsSmoothDuration,
      LyricsAnimationStyle.slide => _kLyricsSlideDuration,
      LyricsAnimationStyle.highlight => _kLyricsHighlightDuration,
      LyricsAnimationStyle.none => Duration.zero,
    };
  }

  Animation<double> _buildTween(LyricsAnimationStyle style) {
    return CurvedAnimation(
      parent: _controller,
      curve: switch (style) {
        LyricsAnimationStyle.highlight => Curves.easeOutBack,
        _ => Curves.easeOutCubic,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.style == LyricsAnimationStyle.none) {
      return widget.child;
    }
    final alignment = widget.alignment;
    final accent = widget.accent;
    return AnimatedBuilder(
      animation: _animation,
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
                widget.active ? _kLyricsSlideOffsetPx * (1 - value) : 0,
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
          LyricsAnimationStyle.none => child!,
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
    if (style == LyricsAnimationStyle.none) {
      return child;
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: _kDurationForPreview(style),
      curve: switch (style) {
        LyricsAnimationStyle.highlight => Curves.easeOutBack,
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
          LyricsAnimationStyle.none => child!,
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
      LyricsAnimationStyle.none => Duration.zero,
    };
  }
}
