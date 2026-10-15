import 'package:flutter/material.dart';

import '../providers/artwork_progress_color_provider.dart';
import 'decorative_progress_transition.dart';

/// Thin artwork-tinted playback progress shared by compact player surfaces.
class PlaybackProgressLine extends StatefulWidget {
  const PlaybackProgressLine({
    required this.value,
    required this.color,
    this.height = 3,
    this.backgroundColor = const Color(0x33000000),
    this.progressAnimationKey,
    this.colorAnimationKey,
    this.fillKey,
    this.semanticsLabel,
    this.animateProgress = true,
    super.key,
  });

  final double value;
  final Color color;
  final double height;
  final Color backgroundColor;
  final Key? progressAnimationKey;
  final Key? colorAnimationKey;
  final Key? fillKey;
  final String? semanticsLabel;
  final bool animateProgress;

  @override
  State<PlaybackProgressLine> createState() => _PlaybackProgressLineState();
}

class _PlaybackProgressLineState extends State<PlaybackProgressLine>
    with WidgetsBindingObserver {
  bool _tickerEnabled = true;
  bool _appActive = true;
  bool _reducedMotion = false;

  double get _targetProgress => widget.value.clamp(0.0, 1.0).toDouble();
  bool get _presentationActive => _tickerEnabled && _appActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (_appActive == active) return;
    setState(() {
      _appActive = active;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _targetProgress;
    final line = RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        child: ColoredBox(
          color: widget.backgroundColor,
          child: Align(
            alignment: Alignment.centerLeft,
            child: DecorativeProgressTransition(
              animationKey: widget.progressAnimationKey,
              value: progress,
              animateProgress: widget.animateProgress,
              // Scaling the already laid-out fill changes only its paint
              // transform. FractionallySizedBox would relayout this high-traffic
              // progress line on every animation tick while playback advances.
              builder: (context, paintedProgress, child) => Transform.scale(
                scaleX: paintedProgress,
                alignment: Alignment.centerLeft,
                transformHitTests: false,
                child: child,
              ),
              // Keep the slower artwork-color tween outside the progress builder
              // so position ticks do not update its element every frame.
              child: TickerMode(
                enabled: _presentationActive && !_reducedMotion,
                child: TweenAnimationBuilder<Color?>(
                  key: widget.colorAnimationKey,
                  tween: ColorTween(end: widget.color),
                  duration: _reducedMotion || !_presentationActive
                      ? Duration.zero
                      : const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  builder: (context, animatedColor, child) => ColoredBox(
                    key: widget.fillKey,
                    color:
                        (_reducedMotion || !_presentationActive
                                ? widget.color
                                : animatedColor ??
                                      ArtworkProgressColor.fallback)
                            .withAlpha(220),
                    child: child,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final label = widget.semanticsLabel;
    if (label == null) {
      return line;
    }
    return Semantics(
      label: label,
      value: '${(progress * 100).round()}%',
      child: line,
    );
  }
}
