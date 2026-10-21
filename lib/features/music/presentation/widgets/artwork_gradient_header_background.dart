import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/artwork_progress_color_provider.dart';
import 'source_image.dart';

/// Artwork-derived, softly blurred background shared by collection and artist
/// headers. Place it inside the header so its photo cannot cover the song list.
class ArtworkGradientHeaderBackground extends ConsumerWidget {
  const ArtworkGradientHeaderBackground({
    required this.artworkSource,
    required this.cacheWidth,
    required this.keyPrefix,
    super.key,
  });

  final String? artworkSource;
  final int cacheWidth;
  final String keyPrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = artworkSource?.trim();
    final colors = Theme.of(context).colorScheme;
    final isDark = colors.brightness == Brightness.dark;
    final surfaceColors = _artworkSurfaceColors(context, ref, source);
    return ClipRect(
      key: ValueKey('$keyPrefix-background-photo'),
      // Reveal the existing page gradient instead of ending on a fixed color.
      // This stays continuous at every header height and while it scrolls.
      // Only the bounded, cached header background needs the static mask.
      child: ShaderMask(
        key: ValueKey('$keyPrefix-background-fade'),
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white,
            Colors.white,
            Color(0xE8FFFFFF),
            Color(0xA6FFFFFF),
            Color(0x47FFFFFF),
            Color(0x0FFFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: [0, 0.28, 0.5, 0.68, 0.84, 0.96, 1],
        ).createShader(bounds),
        // Keep painted pixels inside the mask even when the physical bottom
        // falls between device pixels. Filtered content can otherwise leave a
        // one-pixel fringe outside the mask on mobile renderers.
        child: Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  key: ValueKey('$keyPrefix-background-fallback'),
                  color: surfaceColors.top,
                ),
                if (source != null && source.isNotEmpty)
                  ExcludeSemantics(
                    child: ImageFiltered(
                      key: ValueKey('$keyPrefix-background-blur'),
                      imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                      child: Transform.scale(
                        scale: 1.16,
                        child: SourceImage(
                          key: ValueKey('$keyPrefix-background-image'),
                          source: source,
                          fit: BoxFit.cover,
                          // Foreground and background share the bounded image cache.
                          cacheWidth: cacheWidth,
                          fallback: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                DecoratedBox(
                  key: ValueKey('$keyPrefix-background-overlay'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        colors.surface.withValues(alpha: isDark ? 0.58 : 0.64),
                        colors.surface.withValues(alpha: isDark ? 0.76 : 0.82),
                        surfaceColors.top,
                      ],
                      stops: const [0, 0.54, 1],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The detail body inherits a subtle color, without a full-page cover decode or
/// blur. Both consumers share one cached, 32 px artwork-color lookup.
class ArtworkColorPageBackground extends ConsumerWidget {
  const ArtworkColorPageBackground({
    required this.artworkSource,
    required this.keyPrefix,
    super.key,
  });

  final String? artworkSource;
  final String keyPrefix;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final surfaceColors = _artworkSurfaceColors(context, ref, artworkSource);
    return DecoratedBox(
      key: ValueKey('$keyPrefix-background-color'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            surfaceColors.top,
            surfaceColors.middle,
            surfaceColors.deep,
            surfaceColors.bottom,
          ],
          stops: const [0, 0.36, 0.72, 1],
        ),
      ),
    );
  }
}

({Color top, Color middle, Color deep, Color bottom}) _artworkSurfaceColors(
  BuildContext context,
  WidgetRef ref,
  String? artworkSource,
) {
  final colors = Theme.of(context).colorScheme;
  final source = artworkSource?.trim();
  final tint = source == null || source.isEmpty
      ? null
      : ref.watch(artworkSurfaceColorProvider(source)).asData?.value;
  if (tint == null || tint == ArtworkProgressColor.fallback) {
    return (
      top: colors.surface,
      middle: colors.surface,
      deep: colors.surface,
      bottom: colors.surface,
    );
  }
  final isDark = colors.brightness == Brightness.dark;
  final artworkTone = HSLColor.fromColor(tint);
  Color mixTone(double lightness, double opacity) {
    final tone = artworkTone.withLightness(lightness).toColor();
    return Color.alphaBlend(tone.withValues(alpha: opacity), colors.surface);
  }

  return (
    // Separate lightness and opacity steps make the artwork hue visible as a
    // real tonal gradient against both OLED dark surfaces and light surfaces.
    top: mixTone(isDark ? 0.66 : 0.88, isDark ? 0.58 : 0.32),
    middle: mixTone(isDark ? 0.52 : 0.72, isDark ? 0.44 : 0.24),
    deep: mixTone(isDark ? 0.38 : 0.56, isDark ? 0.31 : 0.16),
    bottom: mixTone(isDark ? 0.26 : 0.40, isDark ? 0.22 : 0.09),
  );
}
