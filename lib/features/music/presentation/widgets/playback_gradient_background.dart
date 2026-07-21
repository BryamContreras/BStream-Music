import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/image_source.dart';
import '../providers/music_providers.dart';

class PlaybackGradientBackground extends ConsumerWidget {
  const PlaybackGradientBackground({super.key});

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
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 520),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: SizedBox.expand(
              key: ValueKey(source),
              child: source == null || source.isEmpty
                  ? const _PlaybackBackgroundFallback()
                  : ClipRect(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 44, sigmaY: 44),
                        child: Transform.scale(
                          scale: 1.24,
                          child: _PlaybackBackgroundImage(
                            source: source,
                            fallback: const _PlaybackBackgroundFallback(),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xED080B09),
                  Color(0xF0040604),
                  Color(0xF2020403),
                  Color(0xF4020403),
                ],
                stops: [0, 0.38, 0.72, 1],
              ),
            ),
          ),
        ],
      ),
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
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 520),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: SizedBox.expand(
              key: ValueKey(source),
              child: source == null || source.isEmpty
                  ? const _PlayerBackgroundFallback()
                  : ClipRect(
                      child: ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 44, sigmaY: 44),
                        child: Transform.scale(
                          scale: 1.28,
                          child: _PlaybackBackgroundImage(
                            source: source,
                            fallback: const _PlayerBackgroundFallback(),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xC0101712),
                  Color(0xC8080D0A),
                  Color(0xD0070B08),
                  Color(0xD8080C09),
                ],
                stops: [0, 0.38, 0.72, 1],
              ),
            ),
          ),
        ],
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
    if (isNetworkImageSource(source)) {
      return Image.network(
        source,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    }

    final file = imageFileFromSource(source);
    if (file == null || !file.existsSync()) {
      return fallback;
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback,
    );
  }
}

class _PlayerBackgroundFallback extends StatelessWidget {
  const _PlayerBackgroundFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF111611), Color(0xFF070907), Color(0xFF030403)],
        ),
      ),
    );
  }
}

class _PlaybackBackgroundFallback extends StatelessWidget {
  const _PlaybackBackgroundFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D2115), Color(0xFF050805), Color(0xFF020302)],
        ),
      ),
    );
  }
}
