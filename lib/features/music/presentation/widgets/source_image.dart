import 'package:flutter/material.dart';

import '../../../../core/utils/cached_artwork_image_provider.dart';
import '../../../../core/utils/image_source.dart';
import 'device_audio_artwork_image_provider.dart';

/// Renders local paths, file URIs, and HTTP(S) artwork through one shared
/// fallback policy.
class SourceImage extends StatefulWidget {
  const SourceImage({
    required this.source,
    required this.fallback,
    this.fallbackSource,
    this.fit = BoxFit.cover,
    this.cacheWidth = _maximumDecodedDimension,
    this.filterQuality = FilterQuality.medium,
    super.key,
  });

  final String? source;
  final String? fallbackSource;
  final BoxFit fit;
  final int cacheWidth;
  final FilterQuality filterQuality;
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
        isNetworkImageSource(normalized) ||
        isDeviceAudioArtworkSource(normalized)) {
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
    final fallback = _resolvedFallback(normalized);
    if (normalized == null || normalized.isEmpty) {
      return fallback;
    }
    if (isNetworkImageSource(normalized)) {
      final sizedSource =
          sizedGoogleArtworkSource(normalized, widget.cacheWidth) ?? normalized;
      return _networkArtwork(
        candidates: youtubeThumbnailCandidates(sizedSource),
        fit: widget.fit,
        fallback: fallback,
      );
    }

    final deviceAudioUri = deviceAudioUriFromArtworkSource(normalized);
    if (deviceAudioUri != null) {
      return Image(
        image: DeviceAudioArtworkImageProvider(
          audioUri: deviceAudioUri,
          targetWidth: widget.cacheWidth,
        ),
        fit: widget.fit,
        filterQuality: widget.filterQuality,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => fallback,
      );
    }

    final file = imageFileFromSource(normalized);
    if (file == null) {
      return fallback;
    }

    if (_localSource != normalized || _localExists == null) {
      _prepareLocalSource();
    }
    return FutureBuilder<bool>(
      future: _localExists,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.fallback;
        }
        if (snapshot.data != true) {
          return fallback;
        }
        return Image.file(
          file,
          fit: widget.fit,
          filterQuality: widget.filterQuality,
          gaplessPlayback: true,
          cacheWidth: widget.cacheWidth,
          errorBuilder: (_, _, _) => fallback,
        );
      },
    );
  }

  Widget _resolvedFallback(String? primarySource) {
    final normalizedFallback = widget.fallbackSource?.trim();
    if (normalizedFallback == null ||
        normalizedFallback.isEmpty ||
        normalizedFallback == primarySource) {
      return widget.fallback;
    }
    return SourceImage(
      source: normalizedFallback,
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      filterQuality: widget.filterQuality,
      fallback: widget.fallback,
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
      return Image(
        image: ResizeImage(
          CachedArtworkImageProvider(candidates[index]),
          width: widget.cacheWidth,
        ),
        fit: fit,
        filterQuality: widget.filterQuality,
        gaplessPlayback: true,
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
    this.fallbackSource,
    this.cacheWidth = SourceImage._maximumDecodedDimension,
    this.filterQuality = FilterQuality.medium,
    super.key,
  });

  final String? source;
  final String? fallbackSource;
  final Widget fallback;
  final int cacheWidth;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    final normalized = source?.trim();
    return SourceImage(
      source: normalized,
      fallbackSource: fallbackSource,
      fit: BoxFit.cover,
      cacheWidth: cacheWidth,
      filterQuality: filterQuality,
      fallback: fallback,
    );
  }
}
