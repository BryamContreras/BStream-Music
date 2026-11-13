import 'package:flutter/material.dart';

import 'artwork_fade_gradients.dart';
import 'reflected_artwork_image.dart';
import 'source_image.dart';

/// An artist photo that continues into its own softly blurred reflection.
/// The photo and reflection share one decoded image; only the small retained
/// reflection raster is generated when the source or header geometry changes.
class ExpandedArtworkHeaderBackground extends StatelessWidget {
  const ExpandedArtworkHeaderBackground({
    required this.artworkSource,
    required this.artworkHeight,
    required this.keyPrefix,
    this.cacheWidth = 1024,
    this.artworkTopInset = 0,
    this.alignment,
    this.preserveArtworkAspectRatio = false,
    super.key,
  });

  final String? artworkSource;
  final double artworkHeight;
  final String keyPrefix;
  final int cacheWidth;
  final double artworkTopInset;

  /// The same cover crop is applied to the focused photo and its reflection.
  /// Null retains the responsive portrait crop.
  final Alignment? alignment;

  /// Gives narrower photos a larger crop without stretching them. The same
  /// geometry drives the existing reflection.
  final bool preserveArtworkAspectRatio;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: ClipRect(
          key: ValueKey('$keyPrefix-background-photo'),
          child: ShaderMask(
            key: ValueKey('$keyPrefix-background-fade'),
            blendMode: BlendMode.dstIn,
            shaderCallback: expandedArtworkHeroBlurFadeGradient.createShader,
            // Keep fractional physical edges inside the transparent mask.
            child: Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: SourceImage(
                key: ValueKey('$keyPrefix-background-image'),
                source: artworkSource,
                cacheWidth: cacheWidth,
                fallback: _fallback(colors),
                imageBuilder: (context, image) => LayoutBuilder(
                  builder: (context, constraints) {
                    final availableSize = Size(
                      constraints.maxWidth,
                      artworkHeight,
                    );
                    final imageSize = Size(
                      image.image!.width.toDouble(),
                      image.image!.height.toDouble(),
                    );
                    var photoSize = availableSize;
                    if (preserveArtworkAspectRatio) {
                      final containedSize = applyBoxFit(
                        BoxFit.contain,
                        imageSize,
                        availableSize,
                      ).destination;
                      photoSize = Size(
                        (containedSize.width * 1.80).clamp(
                          0.0,
                          availableSize.width,
                        ),
                        containedSize.height,
                      );
                    }
                    final photoRect = Rect.fromLTWH(
                      (constraints.maxWidth - photoSize.width) / 2,
                      artworkTopInset,
                      photoSize.width,
                      photoSize.height,
                    );
                    final headerHeight = constraints.maxHeight;
                    final photoAlignment =
                        alignment ??
                        (preserveArtworkAspectRatio
                            // Keep most of the vertical crop below the
                            // face instead of taking equally from the top.
                            ? const Alignment(0, -0.75)
                            : constraints.maxWidth >= 700
                            ? const Alignment(0, -0.5)
                            : Alignment.center);
                    final focusFade = artworkTopInset > 0
                        ? _artistFocusFadeGradient(artworkHeight)
                        : expandedArtworkBoundedFocusFadeGradient;
                    Widget focusedPhoto = RawImage(
                      key: ValueKey('$keyPrefix-artwork-image'),
                      image: image.image,
                      scale: image.scale,
                      fit: BoxFit.cover,
                      alignment: photoAlignment,
                      filterQuality: image.filterQuality,
                    );
                    if (preserveArtworkAspectRatio &&
                        photoRect.width < constraints.maxWidth - 1) {
                      focusedPhoto = ShaderMask(
                        key: ValueKey('$keyPrefix-artwork-side-fade'),
                        blendMode: BlendMode.dstIn,
                        shaderCallback: const LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                          ],
                          stops: [0, 0.08, 0.92, 1],
                        ).createShader,
                        child: focusedPhoto,
                      );
                    }
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ProgressiveReflectedArtworkImage(
                          key: ValueKey('$keyPrefix-background-reflection'),
                          image: image.image!,
                          artworkRect: photoRect,
                          alignment: photoAlignment,
                          filterQuality: image.filterQuality,
                        ),
                        Positioned.fromRect(
                          rect: photoRect,
                          child: ShaderMask(
                            key: ValueKey('$keyPrefix-artwork-focus-fade'),
                            blendMode: BlendMode.dstIn,
                            shaderCallback: focusFade.createShader,
                            child: focusedPhoto,
                          ),
                        ),
                        DecoratedBox(
                          key: ValueKey('$keyPrefix-background-overlay'),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                colors.surface.withValues(alpha: 0.08),
                                colors.surface.withValues(alpha: 0.08),
                                colors.surface.withValues(
                                  alpha: dark ? 0.72 : 0.82,
                                ),
                                colors.surface.withValues(alpha: 0.94),
                              ],
                              stops: [
                                0,
                                ((artworkTopInset + artworkHeight * 0.55) /
                                        headerHeight)
                                    .clamp(0.0, 0.55),
                                ((artworkTopInset + artworkHeight * 0.96) /
                                        headerHeight)
                                    .clamp(0.56, 0.96),
                                1,
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback(ColorScheme colors) => Align(
    alignment: Alignment.topCenter,
    child: Padding(
      padding: EdgeInsets.only(top: artworkTopInset),
      child: SizedBox(
        height: artworkHeight,
        child: Center(
          child: Icon(
            Icons.person_rounded,
            size: 88,
            color: colors.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
    ),
  );
}

LinearGradient _artistFocusFadeGradient(double artworkHeight) {
  const playerFade = expandedArtworkHeroFocusFadeGradient;
  final playerStops = playerFade.stops!;
  final firstOpaque = playerFade.colors.indexOf(Colors.white);
  final lastTransparent = playerFade.colors.lastIndexOf(
    Colors.transparent,
    firstOpaque,
  );
  final blendStart = playerStops[lastTransparent];
  final blendLength = playerStops[firstOpaque] - blendStart;
  final upperEnd = (3 / artworkHeight).clamp(0.0, playerStops[firstOpaque]);
  return LinearGradient(
    begin: playerFade.begin,
    end: playerFade.end,
    colors: playerFade.colors.sublist(lastTransparent),
    // Static artist photos need only a short join below the status bar. Keep
    // the player's lower fade while removing its motion-safe upper margin.
    stops: [
      for (var index = lastTransparent; index < playerStops.length; index++)
        index <= firstOpaque
            ? (playerStops[index] - blendStart) / blendLength * upperEnd
            : playerStops[index],
    ],
  );
}
