import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Compact segmented equalizer shared by artwork cards and playback queues.
class NowPlayingEqualizer extends StatefulWidget {
  const NowPlayingEqualizer({
    required this.isPlaying,
    this.width = 48,
    this.height = 18,
    super.key,
  });

  final bool isPlaying;
  final double width;
  final double height;

  @override
  State<NowPlayingEqualizer> createState() => _NowPlayingEqualizerState();
}

/// Bottom-aligned artwork overlay used by track cards.
///
/// This widget is intentionally a [Positioned] so every card uses the same
/// placement and the equalizer never changes the artwork's layout size.
class NowPlayingEqualizerOverlay extends StatelessWidget {
  const NowPlayingEqualizerOverlay({
    required this.isPlaying,
    this.width = 48,
    this.height = 18,
    this.bottom = 0,
    super.key,
  });

  final bool isPlaying;
  final double width;
  final double height;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: Center(
        child: NowPlayingEqualizer(
          isPlaying: isPlaying,
          width: width,
          height: height,
        ),
      ),
    );
  }
}

/// Adds the paused equalizer treatment to collection artwork while it is
/// hovered, without taking part in the card's layout.
class HoverEqualizerArtwork extends StatefulWidget {
  const HoverEqualizerArtwork({
    required this.child,
    this.width = 48,
    this.height = 18,
    super.key,
  });

  final Widget child;
  final double width;
  final double height;

  @override
  State<HoverEqualizerArtwork> createState() => _HoverEqualizerArtworkState();
}

class _HoverEqualizerArtworkState extends State<HoverEqualizerArtwork> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        children: [
          widget.child,
          if (_hovered)
            NowPlayingEqualizerOverlay(
              isPlaying: false,
              width: widget.width,
              height: widget.height,
            ),
        ],
      ),
    );
  }
}

class _NowPlayingEqualizerState extends State<NowPlayingEqualizer>
    with SingleTickerProviderStateMixin {
  static const _barCount = 13;
  static const _segmentCount = 4;
  static const _primaryFrequencies = <double>[
    17,
    23,
    19,
    29,
    13,
    31,
    21,
    27,
    15,
    25,
    33,
    18,
    35,
  ];
  static const _detailFrequencies = <double>[
    31,
    17,
    37,
    19,
    29,
    23,
    35,
    25,
    33,
    21,
    39,
    27,
    15,
  ];
  static const _offsets = <double>[
    0.2,
    1.7,
    3.1,
    4.6,
    2.4,
    5.5,
    0.9,
    3.8,
    5.9,
    2.9,
    4.1,
    1.2,
    5.1,
  ];
  static const _pausedLevels = <int>[2, 3, 2, 4, 3, 2, 3, 2, 4, 2, 3, 2, 2];

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
      value: 0.18,
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant NowPlayingEqualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.isPlaying) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final indicatorColor = Theme.of(context).colorScheme.primary;
    return Semantics(
      label: widget.isPlaying ? 'Reproduciendo' : 'Reproducción pausada',
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final phase = _controller.value * math.pi * 2;
            final levels = widget.isPlaying
                ? List<int>.generate(_barCount, (index) {
                    final primary =
                        0.5 +
                        0.5 *
                            math.sin(
                              phase * _primaryFrequencies[index] +
                                  _offsets[index],
                            );
                    final detail =
                        0.5 +
                        0.5 *
                            math.sin(
                              phase * _detailFrequencies[index] +
                                  _offsets[(index + 3) % _offsets.length],
                            );
                    return 1 + ((primary * 0.68 + detail * 0.32) * 3).round();
                  })
                : _pausedLevels;

            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (var column = 0; column < levels.length; column++)
                  SizedBox(
                    width: 2.4,
                    height: widget.height,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (
                          var segment = 0;
                          segment < _segmentCount;
                          segment++
                        )
                          Container(
                            width: 2.4,
                            height: 2.7,
                            decoration: BoxDecoration(
                              color: indicatorColor.withValues(
                                alpha: _segmentCount - segment <= levels[column]
                                    ? 0.94
                                    : 0.18,
                              ),
                              borderRadius: BorderRadius.circular(0.65),
                              boxShadow:
                                  _segmentCount - segment <= levels[column]
                                  ? const [
                                      BoxShadow(
                                        color: Color(0x78000000),
                                        blurRadius: 1.2,
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
