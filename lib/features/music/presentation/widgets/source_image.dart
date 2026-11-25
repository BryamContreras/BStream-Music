import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/utils/cached_artwork_image_provider.dart';
import '../../../../core/utils/image_source.dart';
import 'device_audio_artwork_image_provider.dart';

/// Intercepts only artwork belonging to the player's three-song visual cache.
/// Other images (search, queue, profiles) keep their normal shared cache.
class PlaybackArtworkCacheScope extends InheritedWidget {
  const PlaybackArtworkCacheScope({
    required this.revision,
    required this.tracksSource,
    required this.localPathFor,
    this.allowNetworkPreviews = true,
    this.useMiniArtworkPreview = false,
    required super.child,
    super.key,
  });

  final int revision;
  final bool Function(String) tracksSource;
  final String? Function(String) localPathFor;
  final bool allowNetworkPreviews;
  final bool useMiniArtworkPreview;

  static PlaybackArtworkCacheScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlaybackArtworkCacheScope>();

  @override
  bool updateShouldNotify(PlaybackArtworkCacheScope oldWidget) =>
      revision != oldWidget.revision ||
      allowNetworkPreviews != oldWidget.allowNetworkPreviews ||
      useMiniArtworkPreview != oldWidget.useMiniArtworkPreview;
}

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
    this.opacity = 1,
    this.imageBuilder,
    super.key,
  }) : assert(opacity >= 0 && opacity <= 1);

  final String? source;
  final String? fallbackSource;
  final BoxFit fit;
  final int cacheWidth;
  final FilterQuality filterQuality;

  /// Applied by the image paint itself, without an offscreen Opacity layer.
  final double opacity;
  final Widget fallback;

  /// Custom painting of the already decoded native image. Loading, fallbacks
  /// and ImageCache remain owned here; the builder must not dispose the image.
  /// Browser images without a RawImage keep their normal rendering.
  final Widget Function(BuildContext context, RawImage image)? imageBuilder;

  // Artwork is displayed in bounded cards and player surfaces. Keep the
  // decoder bounded for long listening sessions, while matching YouTube's
  // hq720 width so the large player surface does not upscale a soft image.
  static const _maximumDecodedDimension = 1280;

  @override
  State<SourceImage> createState() => _SourceImageState();
}

class _SourceImageState extends State<SourceImage> {
  static const _youtubeUpgradeMinimumDecodeWidth = 640;

  String? _localSource;
  Future<bool>? _localExists;
  Animation<double>? _imageOpacity;
  String? _decodedPlaybackSource;

  @override
  void initState() {
    super.initState();
    _updateImageOpacity();
    _prepareLocalSource();
  }

  @override
  void didUpdateWidget(covariant SourceImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.opacity != widget.opacity) _updateImageOpacity();
    if (oldWidget.source != widget.source) {
      _decodedPlaybackSource = null;
      _prepareLocalSource();
    }
  }

  void _updateImageOpacity() {
    _imageOpacity = widget.opacity == 1
        ? null
        : AlwaysStoppedAnimation<double>(widget.opacity);
  }

  Widget _paintImage(BuildContext context, Widget child) {
    final builder = widget.imageBuilder;
    if (builder == null || child is! RawImage || child.image == null) {
      return child;
    }
    return builder(context, child);
  }

  ImageFrameBuilder? get _customFrameBuilder => widget.imageBuilder == null
      ? null
      : (context, child, frame, synchronouslyLoaded) =>
            _paintImage(context, child);

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
    final playbackCache = PlaybackArtworkCacheScope.maybeOf(context);
    if (normalized == null || normalized.isEmpty) {
      _decodedPlaybackSource = null;
      return fallback;
    }
    if (isNetworkImageSource(normalized)) {
      if (playbackCache?.tracksSource(normalized) == true) {
        if (!playbackCache!.allowNetworkPreviews) {
          _decodedPlaybackSource = null;
          return fallback;
        }
        final cachedPath = playbackCache.localPathFor(normalized);
        // The mini player has already requested this small preview. Reusing
        // the same image-provider key keeps it visible while the full-sized,
        // cancellable player download is looked up or decoded. In particular,
        // do not replace it with the placeholder for one frame on entry.
        final preview = _networkArtworkForSource(
          source: sizedGoogleArtworkSource(normalized, 256) ?? normalized,
          fallbackSource: widget.fallbackSource,
          fit: widget.fit,
          fallback: fallback,
          cacheWidth: 256,
        );
        if (cachedPath == null) {
          _decodedPlaybackSource = null;
          return preview;
        }
        return Image.file(
          File(cachedPath),
          excludeFromSemantics: widget.imageBuilder != null,
          fit: widget.fit,
          filterQuality: widget.filterQuality,
          opacity: _imageOpacity,
          cacheWidth: widget.cacheWidth,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            final paintedImage = _paintImage(context, child);
            if (wasSynchronouslyLoaded || frame != null) {
              _decodedPlaybackSource = normalized;
              return paintedImage;
            }
            // A better rendition changes the file-provider key, but gapless
            // playback still has the previous decoded rendition of this same
            // cover. Keep those pixels rather than briefly downgrading to the
            // mini player's 256 px preview while the new file decodes.
            return _decodedPlaybackSource == normalized
                ? paintedImage
                : preview;
          },
          errorBuilder: (_, _, _) {
            _decodedPlaybackSource = null;
            return preview;
          },
        );
      }
      _decodedPlaybackSource = null;
      final sizedSource =
          sizedGoogleArtworkSource(normalized, widget.cacheWidth) ?? normalized;
      return _networkArtworkForSource(
        source: sizedSource,
        fallbackSource: widget.fallbackSource,
        fit: widget.fit,
        fallback: fallback,
      );
    }

    final deviceAudioUri = deviceAudioUriFromArtworkSource(normalized);
    if (deviceAudioUri != null) {
      if (playbackCache?.useMiniArtworkPreview == true &&
          widget.cacheWidth > 256) {
        final preview = Image(
          excludeFromSemantics: widget.imageBuilder != null,
          image: DeviceAudioArtworkImageProvider(
            audioUri: deviceAudioUri,
            targetWidth: 256,
          ),
          fit: widget.fit,
          filterQuality: widget.filterQuality,
          opacity: _imageOpacity,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
              wasSynchronouslyLoaded || frame != null
              ? _paintImage(context, child)
              : fallback,
          errorBuilder: (_, _, _) => fallback,
        );
        return Image(
          excludeFromSemantics: widget.imageBuilder != null,
          image: DeviceAudioArtworkImageProvider(
            audioUri: deviceAudioUri,
            targetWidth: widget.cacheWidth,
          ),
          fit: widget.fit,
          filterQuality: widget.filterQuality,
          opacity: _imageOpacity,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
              wasSynchronouslyLoaded || frame != null
              ? _paintImage(context, child)
              : preview,
          errorBuilder: (_, _, _) => preview,
        );
      }
      return Image(
        excludeFromSemantics: widget.imageBuilder != null,
        image: DeviceAudioArtworkImageProvider(
          audioUri: deviceAudioUri,
          targetWidth: widget.cacheWidth,
        ),
        fit: widget.fit,
        filterQuality: widget.filterQuality,
        opacity: _imageOpacity,
        gaplessPlayback: true,
        frameBuilder: _customFrameBuilder,
        errorBuilder: (_, _, _) => fallback,
      );
    }

    final file = imageFileFromSource(normalized);
    if (file == null) {
      return fallback;
    }

    if (playbackCache?.useMiniArtworkPreview == true &&
        widget.cacheWidth > 256) {
      final preview = Image.file(
        file,
        excludeFromSemantics: widget.imageBuilder != null,
        fit: widget.fit,
        filterQuality: widget.filterQuality,
        opacity: _imageOpacity,
        gaplessPlayback: true,
        cacheWidth: 256,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
            wasSynchronouslyLoaded || frame != null
            ? _paintImage(context, child)
            : fallback,
        errorBuilder: (_, _, _) => fallback,
      );
      return Image.file(
        file,
        excludeFromSemantics: widget.imageBuilder != null,
        fit: widget.fit,
        filterQuality: widget.filterQuality,
        opacity: _imageOpacity,
        gaplessPlayback: true,
        cacheWidth: widget.cacheWidth,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
            wasSynchronouslyLoaded || frame != null
            ? _paintImage(context, child)
            : preview,
        errorBuilder: (_, _, _) => preview,
      );
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
          excludeFromSemantics: widget.imageBuilder != null,
          fit: widget.fit,
          filterQuality: widget.filterQuality,
          opacity: _imageOpacity,
          gaplessPlayback: true,
          cacheWidth: widget.cacheWidth,
          frameBuilder: _customFrameBuilder,
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
    final playbackCache = PlaybackArtworkCacheScope.maybeOf(context);
    if (primarySource != null &&
        playbackCache?.tracksSource(primarySource) == true &&
        isNetworkImageSource(normalizedFallback)) {
      // The playback cache tries remote fallback candidates itself. Starting
      // another image-provider request here would outlive a track switch.
      return widget.fallback;
    }
    return SourceImage(
      source: normalizedFallback,
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      filterQuality: widget.filterQuality,
      opacity: widget.opacity,
      imageBuilder: widget.imageBuilder,
      fallback: widget.fallback,
    );
  }

  Widget _networkArtwork({
    required List<String> candidates,
    required BoxFit fit,
    required Widget fallback,
    int? cacheWidth,
    bool fadeIn = false,
  }) {
    Widget buildCandidate(int index) {
      if (index >= candidates.length) {
        return fallback;
      }
      return Image(
        excludeFromSemantics: widget.imageBuilder != null,
        image: ResizeImage(
          CachedArtworkImageProvider(candidates[index]),
          width: cacheWidth ?? widget.cacheWidth,
        ),
        fit: fit,
        filterQuality: widget.filterQuality,
        opacity: _imageOpacity,
        gaplessPlayback: true,
        frameBuilder: fadeIn
            ? (context, child, frame, wasSynchronouslyLoaded) {
                return AnimatedOpacity(
                  opacity: wasSynchronouslyLoaded || frame != null ? 1 : 0,
                  duration: wasSynchronouslyLoaded
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: _paintImage(context, child),
                );
              }
            : _customFrameBuilder,
        errorBuilder: (_, _, _) => buildCandidate(index + 1),
      );
    }

    return buildCandidate(0);
  }

  Widget _networkArtworkForSource({
    required String source,
    required String? fallbackSource,
    required BoxFit fit,
    required Widget fallback,
    int? cacheWidth,
  }) {
    final decodeWidth = cacheWidth ?? widget.cacheWidth;
    final youtubeVideoId = youtubeVideoIdFromThumbnailSource(source);
    final eagerLocalFallback = _isLocalFallbackSource(fallbackSource);
    if (youtubeVideoId == null) {
      final network = _networkArtwork(
        candidates: <String>[source],
        fit: fit,
        fallback: eagerLocalFallback ? const SizedBox.shrink() : fallback,
        cacheWidth: decodeWidth,
      );
      return eagerLocalFallback
          ? _layerArtwork(base: fallback, overlay: network)
          : network;
    }

    // Search mounts a bounded page of rows eagerly. A single known-good
    // preview per small row avoids both the old 404 waterfall and a second
    // high-resolution request that cannot improve a 56 px surface.
    final preview = _networkArtwork(
      candidates: youtubeThumbnailPreviewCandidates(
        source,
        preferredSource: fallbackSource,
      ),
      fit: fit,
      fallback: eagerLocalFallback ? const SizedBox.shrink() : fallback,
      cacheWidth: decodeWidth,
    );
    final visiblePreview = eagerLocalFallback
        ? _layerArtwork(base: fallback, overlay: preview)
        : preview;
    if (decodeWidth < _youtubeUpgradeMinimumDecodeWidth) {
      return visiblePreview;
    }

    // Large player artwork keeps the preview visible while the sharper
    // rendition resolves. Missing variants therefore never leave a blank
    // cover, and a successful upgrade does not change layout geometry.
    final upgradeCandidates = youtubeThumbnailUpgradeCandidates(source);
    if (upgradeCandidates.isEmpty) {
      return visiblePreview;
    }
    // The high-resolution network rendition has a single upgrade candidate.
    // Only ordinary, fully opaque image paint can cover its preview. Custom
    // painters and translucent covers keep the original layered composition.
    if (upgradeCandidates.length == 1 &&
        widget.imageBuilder == null &&
        widget.opacity == 1 &&
        (fit == BoxFit.cover || fit == BoxFit.fill)) {
      return _OpaqueThumbnailUpgrade(
        preview: visiblePreview,
        provider: CachedArtworkImageProvider(upgradeCandidates.single),
        decodeWidth: decodeWidth,
        fit: fit,
        filterQuality: widget.filterQuality,
      );
    }
    final upgrade = _networkArtwork(
      candidates: upgradeCandidates,
      fit: fit,
      fallback: const SizedBox.shrink(),
      cacheWidth: decodeWidth,
      fadeIn: true,
    );
    return _layerArtwork(base: visiblePreview, overlay: upgrade);
  }

  bool _isLocalFallbackSource(String? source) {
    final normalized = source?.trim();
    return normalized != null &&
        normalized.isNotEmpty &&
        !isNetworkImageSource(normalized) &&
        normalized != widget.source?.trim();
  }

  Widget _layerArtwork({required Widget base, required Widget overlay}) {
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        base,
        Positioned.fill(child: overlay),
      ],
    );
  }
}

/// Keeps the preview until the verified opaque upgrade has finished its fade.
/// Releasing the hidden child also releases its live image-stream reference.
class _OpaqueThumbnailUpgrade extends StatefulWidget {
  const _OpaqueThumbnailUpgrade({
    required this.preview,
    required this.provider,
    required this.decodeWidth,
    required this.fit,
    required this.filterQuality,
  });

  final Widget preview;
  final CachedArtworkImageProvider provider;
  final int decodeWidth;
  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  State<_OpaqueThumbnailUpgrade> createState() =>
      _OpaqueThumbnailUpgradeState();
}

class _OpaqueThumbnailUpgradeState extends State<_OpaqueThumbnailUpgrade> {
  bool _previewHidden = false;
  bool? _scheduledVisibility;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant _OpaqueThumbnailUpgrade oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider ||
        oldWidget.decodeWidth != widget.decodeWidth) {
      _generation++;
      _scheduledVisibility = null;
      _previewHidden = false;
    }
  }

  void _setPreviewHiddenAfterFrame(bool hidden, int generation) {
    if (generation != _generation) return;
    if (_scheduledVisibility != null) {
      _scheduledVisibility = hidden;
      return;
    }
    if (_previewHidden == hidden) return;
    _scheduledVisibility = hidden;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _generation) return;
      final next = _scheduledVisibility!;
      _scheduledVisibility = null;
      if (_previewHidden != next) {
        setState(() => _previewHidden = next);
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Under loose constraints the preview determines the Stack's size.
      // Keep it mounted so a successful upgrade cannot change the layout.
      final mayHide = constraints.isTight && constraints.biggest.isFinite;
      final hidden = mayHide && _previewHidden;
      final generation = _generation;
      final provider = widget.provider;
      return Stack(
        fit: StackFit.passthrough,
        children: [
          if (hidden) const SizedBox.expand() else widget.preview,
          Positioned.fill(
            child: Image(
              image: ResizeImage(provider, width: widget.decodeWidth),
              fit: widget.fit,
              filterQuality: widget.filterQuality,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, synchronous) {
                final loaded = synchronous || frame != null;
                final opaque = loaded && provider.hasVerifiedOpaqueJpeg;
                if (!opaque) {
                  _setPreviewHiddenAfterFrame(false, generation);
                  if (hidden && !loaded) return widget.preview;
                } else if (mayHide && synchronous) {
                  _setPreviewHiddenAfterFrame(true, generation);
                }
                return AnimatedOpacity(
                  opacity: loaded ? 1 : 0,
                  duration: synchronous
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  onEnd: () {
                    if (mayHide && opaque && provider.hasVerifiedOpaqueJpeg) {
                      _setPreviewHiddenAfterFrame(true, generation);
                    }
                  },
                  child: child,
                );
              },
              errorBuilder: (_, _, _) {
                _setPreviewHiddenAfterFrame(false, generation);
                return hidden ? widget.preview : const SizedBox.shrink();
              },
            ),
          ),
        ],
      );
    },
  );
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
