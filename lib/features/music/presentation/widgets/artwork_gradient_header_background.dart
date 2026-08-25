import 'dart:ui';

import 'package:flutter/material.dart';

import 'source_image.dart';

/// Artwork-derived, softly blurred background shared by collection and artist
/// headers. The foreground content is expected to paint above this widget.
class ArtworkGradientHeaderBackground extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final source = artworkSource?.trim();
    final colors = Theme.of(context).colorScheme;
    final isDark = colors.brightness == Brightness.dark;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _ArtworkHeaderFallback(
            key: ValueKey('$keyPrefix-background-fallback'),
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
                    // Foreground and background can share the same bounded
                    // decoded image through Flutter's image cache.
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
                  colors.surface.withValues(alpha: 0.96),
                ],
                stops: const [0, 0.54, 1],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtworkHeaderFallback extends StatelessWidget {
  const _ArtworkHeaderFallback({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              colors.primary.withValues(alpha: 0.10),
              colors.surface,
            ),
            colors.surface,
          ],
        ),
      ),
    );
  }
}
