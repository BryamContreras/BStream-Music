import 'package:flutter/material.dart';

import '../../../../core/utils/image_source.dart';

/// Renders local paths, file URIs, and HTTP(S) artwork through one shared
/// fallback policy.
class SourceImage extends StatefulWidget {
  const SourceImage({
    required this.source,
    required this.fallback,
    this.fit = BoxFit.cover,
    this.cacheWidth = _maximumDecodedDimension,
    super.key,
  });

  final String? source;
  final BoxFit fit;
  final int cacheWidth;
  final Widget fallback;

  // Artwork is displayed in bounded cards and player surfaces. Keep the
  // decoder bounded for long listening sessions, while matching YouTube's
  // hq720 width so the large player surface does not upscale a soft image.
  static const _maximumDecodedDimension = 1280;

  @override
  State<SourceImage> createState() => _SourceImageState();
}

class _SourceImageState extends State<SourceImage> {
  String? _localSource;
  Future<bool>? _localExists;

  @override
  void initState() {
    super.initState();
    _prepareLocalSource();
  }

  @override
  void didUpdateWidget(covariant SourceImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _prepareLocalSource();
    }
  }

  void _prepareLocalSource() {
    final normalized = widget.source?.trim();
    if (normalized == null ||
        normalized.isEmpty ||
        isNetworkImageSource(normalized)) {
      _localSource = null;
      _localExists = null;
      return;
    }

    final file = imageFileFromSource(normalized);
    _localSource = normalized;
    _localExists = file?.exists() ?? Future<bool>.value(false);
  }

  @override
  Widget build(BuildContext context) {
    final normalized = widget.source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return widget.fallback;
    }
    if (isNetworkImageSource(normalized)) {
      return _networkArtwork(
        candidates: youtubeThumbnailCandidates(normalized),
        fit: widget.fit,
        fallback: widget.fallback,
      );
    }

    final file = imageFileFromSource(normalized);
    if (file == null) {
      return widget.fallback;
    }

    if (_localSource != normalized || _localExists == null) {
      _prepareLocalSource();
    }
    return FutureBuilder<bool>(
      future: _localExists,
      initialData: false,
      builder: (context, snapshot) {
        if (snapshot.data != true) {
          return widget.fallback;
        }
        return Image.file(
          file,
          fit: widget.fit,
          gaplessPlayback: true,
          cacheWidth: widget.cacheWidth,
          errorBuilder: (_, _, _) => widget.fallback,
        );
      },
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
        cacheWidth: widget.cacheWidth,
        errorBuilder: (_, _, _) => buildCandidate(index + 1),
      );
    }

    return buildCandidate(0);
  }
}

/// Shows artwork without distorting its native proportions.
///
/// `BoxFit.cover` already preserves the source aspect ratio. Keeping a second,
/// blurred copy underneath an opaque cover produces the same pixels while
/// doubling image work on every list row, which is particularly expensive on
/// low-memory Android devices.
class ProportionalArtwork extends StatelessWidget {
  const ProportionalArtwork({
    required this.source,
    required this.fallback,
    this.cacheWidth = SourceImage._maximumDecodedDimension,
    super.key,
  });

  final String? source;
  final Widget fallback;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return fallback;
    }

    return SourceImage(
      source: normalized,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      fallback: fallback,
    );
  }
}
