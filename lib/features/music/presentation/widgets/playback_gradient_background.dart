import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/music_providers.dart';
import 'source_image.dart';

/// Neutral background used by the browsing tabs. Artwork belongs to the player
/// surface and should not tint navigation screens behind their content cards.
class BrowsingTabBackground extends StatelessWidget {
  const BrowsingTabBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey('browsing-tab-background-surface'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.surface, colors.surfaceContainerLowest],
        ),
      ),
      child: ColoredBox(color: AppColors.tabBackgroundOverlayFor(context)),
    );
  }
}

class PlayerPlaybackGradientBackground extends ConsumerWidget {
  const PlayerPlaybackGradientBackground({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(
      playerControllerProvider.select(
        (player) => player.value?.thumbnailUrl?.trim(),
      ),
    );
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AnimatedPlaybackArtwork(
            source: source,
            scale: 1.28,
            fallback: const _PlayerBackgroundFallback(),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: playerPlaybackOverlayColors(context),
                stops: const [0, 0.38, 0.72, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Overlay used by the full player and its mobile queue. Both themes keep the
/// same blur/opacity rhythm, while the light theme uses a light surface so the
/// player remains visually light instead of becoming a dark screen.
List<Color> playerPlaybackOverlayColors(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  if (isDark) {
    return AppPlatform.isDesktop
        ? const [
            Color(0xC0101712),
            Color(0xC8080D0A),
            Color(0xD0070B08),
            Color(0xD8080C09),
          ]
        : const [
            Color(0x78101712),
            Color(0x84080D0A),
            Color(0x90070B08),
            Color(0x9C080C09),
          ];
  }

  return AppPlatform.isDesktop
      ? const [
          Color(0xC8FFFFFF),
          Color(0xD8F5F8F6),
          Color(0xEAF5F8F6),
          Color(0xF4F5F8F6),
        ]
      : const [
          Color(0xAFFFFFFF),
          Color(0xC8F5F8F6),
          Color(0xE2F5F8F6),
          Color(0xEEF5F8F6),
        ];
}

/// Keeps each AnimatedSwitcher child unique even when a song is selected again
/// while the previous artwork transition is still running. Reusing the raw
/// thumbnail URL as the key can leave an outgoing and incoming child with the
/// same key, which triggers Flutter's duplicate-key assertion during rapid
/// playback changes.
class _AnimatedPlaybackArtwork extends StatefulWidget {
  const _AnimatedPlaybackArtwork({
    required this.source,
    required this.scale,
    required this.fallback,
  });

  final String? source;
  final double scale;
  final Widget fallback;

  @override
  State<_AnimatedPlaybackArtwork> createState() =>
      _AnimatedPlaybackArtworkState();
}

class _AnimatedPlaybackArtworkState extends State<_AnimatedPlaybackArtwork> {
  String? _lastSource;
  int _transitionId = 0;

  @override
  void initState() {
    super.initState();
    _lastSource = widget.source;
  }

  @override
  void didUpdateWidget(covariant _AnimatedPlaybackArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_lastSource != widget.source) {
      _lastSource = widget.source;
      _transitionId += 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 520),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: SizedBox.expand(
        // The id changes only when the source changes, but remains unique if
        // the same source is selected again before the previous animation
        // has completed.
        key: ValueKey(_transitionId),
        child: source == null || source.isEmpty
            ? widget.fallback
            : ClipRect(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 44, sigmaY: 44),
                  child: Transform.scale(
                    scale: widget.scale,
                    child: _PlaybackBackgroundImage(
                      source: source,
                      fallback: widget.fallback,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _PlaybackBackgroundImage extends StatelessWidget {
  const _PlaybackBackgroundImage({
    required this.source,
    required this.fallback,
  });

  final String source;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return SourceImage(source: source, fit: BoxFit.cover, fallback: fallback);
  }
}

class _PlayerBackgroundFallback extends StatelessWidget {
  const _PlayerBackgroundFallback();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF111611), Color(0xFF070907), Color(0xFF030403)]
              : const [Color(0xFFE5F2E9), Color(0xFFF5F8F6), Colors.white],
        ),
      ),
    );
  }
}
