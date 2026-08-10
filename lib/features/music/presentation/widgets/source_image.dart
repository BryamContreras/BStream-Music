import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/utils/image_source.dart';

/// Renders local paths, file URIs, and HTTP(S) artwork through one shared
/// fallback policy.
class SourceImage extends StatelessWidget {
  const SourceImage({
    required this.source,
    required this.fallback,
    this.fit = BoxFit.cover,
    super.key,
  });

  final String? source;
  final BoxFit fit;
  final Widget fallback;

  // Artwork is displayed in bounded cards and player surfaces. Keep the
  // decoder bounded for long listening sessions, while matching YouTube's
  // hq720 width so the large player surface does not upscale a soft image.
  static const _maximumDecodedDimension = 1280;

  @override
  Widget build(BuildContext context) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return fallback;
    }
    if (isNetworkImageSource(normalized)) {
      return _networkArtwork(
        candidates: youtubeThumbnailCandidates(normalized),
        fit: fit,
        fallback: fallback,
      );
    }

    final file = imageFileFromSource(normalized);
    if (file == null || !file.existsSync()) {
      return fallback;
    }
    return Image.file(
      file,
      fit: fit,
      gaplessPlayback: true,
      cacheWidth: _maximumDecodedDimension,
      errorBuilder: (_, _, _) => fallback,
    );
  }

  Widget _networkArtwork({
    required List<String> candidates,
    required BoxFit fit,
    required Widget fallback,
  }) {
    Widget buildCandidate(int index) {
      if (index >= candidates.length) {
        return fallback;
      }
      return Image.network(
        candidates[index],
        fit: fit,
        gaplessPlayback: true,
        cacheWidth: _maximumDecodedDimension,
        errorBuilder: (_, _, _) => buildCandidate(index + 1),
      );
    }

    return buildCandidate(0);
  }
}

/// Shows artwork without changing its native proportions. A softly blurred
/// cover copy fills the frame so landscape thumbnails do not become vertically
/// stretched just to occupy a square surface.
class ProportionalArtwork extends StatelessWidget {
  const ProportionalArtwork({
    required this.source,
    required this.fallback,
    super.key,
  });

  final String? source;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return fallback;
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Transform.scale(
              scale: 1.12,
              child: SourceImage(
                source: normalized,
                fit: BoxFit.cover,
                fallback: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        const ColoredBox(color: Color(0x72000000)),
        // Keep the image under the stack's tight constraints so `cover` can
        // zoom it to the frame and crop only the overflowing sides. Using a
        // loose `Center` here would make the image keep its small intrinsic
        // size and leave large empty margins.
        SourceImage(source: normalized, fit: BoxFit.cover, fallback: fallback),
      ],
    );
  }
}
