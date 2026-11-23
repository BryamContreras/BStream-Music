import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui show Image;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../providers/music_providers.dart';
import '../providers/playback_artwork_provider.dart';
import 'app_background_photo.dart';
import 'reflected_artwork_image.dart';
import 'source_image.dart';
import 'track_change_transition.dart';

/// Neutral background used by the browsing tabs. Artwork belongs to the player
/// surface and should not tint navigation screens behind their content cards.
class BrowsingTabBackground extends ConsumerWidget {
  const BrowsingTabBackground({required this.showCustomPhoto, super.key});

  final bool showCustomPhoto;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photoPath = showCustomPhoto
        ? ref.watch(
            settingsControllerProvider.select(
              (settings) => settings.value?.appBackgroundPath,
            ),
          )
        : null;
    final colors = AppColors.tabBackgroundGradientFor(context);
    if (photoPath != null) {
      return Stack(
        key: const ValueKey('browsing-tab-background-photo'),
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [colors.top, colors.bottom],
              ),
            ),
          ),
          AppBackgroundPhoto(
            path: photoPath,
            scrim: Theme.brightnessOf(context) == Brightness.dark
                ? const Color(0x7A000000)
                : const Color(0xA6FFFFFF),
          ),
        ],
      );
    }
    return DecoratedBox(
      key: const ValueKey('browsing-tab-background-surface'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.top, colors.bottom],
        ),
      ),
      child: ColoredBox(color: AppColors.tabBackgroundOverlayFor(context)),
    );
  }
}

class PlayerPlaybackGradientBackground extends ConsumerWidget {
  const PlayerPlaybackGradientBackground({
    this.additionalScrimAlpha = 0,
    this.panelBlurSigma = 0,
    super.key,
  });

  final double additionalScrimAlpha;
  final double panelBlurSigma;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artwork = ref.watch(playbackArtworkProvider);
    return PlaybackArtworkBackdrop(
      source: artwork.source,
      fallbackSource: artwork.fallback,
      cacheWidth: panelBlurSigma > 0 ? 384 : 1280,
      cacheSmallBlur: panelBlurSigma > 0,
      // Adjacent Gaussian passes on the known artwork combine by adding
      // their variances. The controls and the header still paint separately.
      blurSigma: math.sqrt(
        _artworkBlurSigma * _artworkBlurSigma + panelBlurSigma * panelBlurSigma,
      ),
      additionalScrimAlpha: additionalScrimAlpha,
    );
  }
}

/// Shared artwork background for playback surfaces. Full-bleed covers use a
/// retained reflection with progressive blur; other surfaces use the same
/// photographic blur, with a small decode available to menus.
class PlaybackArtworkBackdrop extends StatelessWidget {
  const PlaybackArtworkBackdrop({
    required this.source,
    this.fallbackSource,
    this.cacheWidth = 1280,
    this.additionalScrimAlpha = 0,
    this.animateTrackChanges = true,
    this.cacheSmallBlur = false,
    this.blurSigma = _artworkBlurSigma,
    this.reflectionArtworkRect,
    super.key,
  });

  final String? source;
  final String? fallbackSource;
  final int cacheWidth;
  final double additionalScrimAlpha;
  final bool animateTrackChanges;
  final bool cacheSmallBlur;
  final double blurSigma;

  /// The foreground cover's unanimated square, in this backdrop's coordinates.
  /// Matching its crop lets the lower edge continue into a vertical reflection.
  final Rect? reflectionArtworkRect;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _AnimatedPlaybackArtwork(
            source: source,
            fallbackSource: fallbackSource,
            cacheWidth: cacheSmallBlur && reflectionArtworkRect == null
                ? math.min(cacheWidth, 384)
                : cacheWidth,
            scale: 1.28,
            fallback: const _PlayerBackgroundFallback(),
            animateTrackChanges: animateTrackChanges,
            cacheSmallBlur: cacheSmallBlur,
            blurSigma: blurSigma,
            reflectionArtworkRect: reflectionArtworkRect,
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: playerPlaybackOverlayGradient(
                context,
                reflected: reflectionArtworkRect != null,
              ),
            ),
          ),
          if (additionalScrimAlpha > 0)
            ColoredBox(
              color: Colors.black.withValues(alpha: additionalScrimAlpha),
            ),
        ],
      ),
    );
  }
}

/// Shared overlay for playback surfaces. Keep the artwork visible beneath the
/// controls; the foreground artwork handles its own transparent edge fade.
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

LinearGradient playerPlaybackOverlayGradient(
  BuildContext context, {
  bool reflected = false,
}) {
  final colors = playerPlaybackOverlayColors(context);
  final opacity = Theme.of(context).brightness == Brightness.dark ? 0.82 : 0.94;
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: reflected
        ? colors
              .map((color) => color.withValues(alpha: color.a * opacity))
              .toList(growable: false)
        : colors,
    stops: const [0, 0.38, 0.72, 1],
  );
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
    required this.fallbackSource,
    required this.cacheWidth,
    required this.animateTrackChanges,
    required this.cacheSmallBlur,
    required this.blurSigma,
    required this.reflectionArtworkRect,
  });

  final String? source;
  final String? fallbackSource;
  final int cacheWidth;
  final double scale;
  final Widget fallback;
  final bool animateTrackChanges;
  final bool cacheSmallBlur;
  final double blurSigma;
  final Rect? reflectionArtworkRect;

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
    Widget background = widget.fallback;
    if (source != null && source.isNotEmpty) {
      final image = _PlaybackBackgroundImage(
        source: source,
        fallbackSource: widget.fallbackSource,
        cacheWidth: widget.cacheWidth,
        fallback: widget.fallback,
        scale: widget.scale,
        cacheSmallBlur: widget.cacheSmallBlur,
        blurSigma: widget.blurSigma,
        reflectionArtworkRect: widget.reflectionArtworkRect,
      );
      background = ClipRect(
        child: widget.reflectionArtworkRect != null || widget.cacheSmallBlur
            ? image
            : _liveArtworkBlur(image, widget.scale, sigma: widget.blurSigma),
      );
    }
    final artwork = SizedBox.expand(
      // The id changes only when the source changes, but remains unique if
      // the same source is selected again before the previous animation
      // has completed.
      key: ValueKey(_transitionId),
      child: background,
    );
    if (!widget.animateTrackChanges) {
      return artwork;
    }

    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 520);
    return AnimatedSwitcher(
      key: const ValueKey('player-background-track-transition'),
      duration: duration,
      reverseDuration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: <Widget>[...previousChildren, ?currentChild],
      ),
      transitionBuilder: noDimmingFadeTransitionBuilder,
      child: artwork,
    );
  }
}

class _PlaybackBackgroundImage extends StatelessWidget {
  const _PlaybackBackgroundImage({
    required this.source,
    required this.fallback,
    required this.fallbackSource,
    required this.cacheWidth,
    required this.scale,
    required this.cacheSmallBlur,
    required this.blurSigma,
    required this.reflectionArtworkRect,
  });

  final String source;
  final String? fallbackSource;
  final int cacheWidth;
  final double scale;
  final bool cacheSmallBlur;
  final double blurSigma;
  final Widget fallback;
  final Rect? reflectionArtworkRect;

  @override
  Widget build(BuildContext context) {
    final reflectionRect = reflectionArtworkRect;
    return SourceImage(
      source: source,
      fallbackSource: fallbackSource,
      cacheWidth: cacheWidth,
      fit: BoxFit.cover,
      fallback: cacheSmallBlur && reflectionRect == null
          ? _liveArtworkBlur(fallback, scale)
          : fallback,
      imageBuilder: reflectionRect != null
          ? (context, image) => ProgressiveReflectedArtworkImage(
              image: image.image!,
              artworkRect: reflectionRect,
              filterQuality: image.filterQuality,
            )
          : cacheSmallBlur
          ? _buildSmallBlur
          : null,
    );
  }

  Widget _buildSmallBlur(BuildContext context, RawImage sourceImage) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final live = _liveArtworkBlur(sourceImage, scale, sigma: blurSigma);
        if (!size.isFinite || size.isEmpty) return live;
        return Image(
          image: _SmallArtworkBlurProvider(
            _SmallArtworkBlurKey(sourceImage.image!, size, scale, blurSigma),
          ),
          excludeFromSemantics: true,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.medium,
          frameBuilder: (context, child, frame, synchronous) =>
              synchronous || frame != null ? child : live,
          errorBuilder: (context, error, stack) => live,
        );
      },
    );
  }
}

const _artworkBlurSigma = 44.0;

Widget _liveArtworkBlur(
  Widget image,
  double scale, {
  double sigma = _artworkBlurSigma,
}) => ImageFiltered(
  imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
  child: Transform.scale(scale: scale, child: image),
);

@immutable
class _SmallArtworkBlurKey {
  const _SmallArtworkBlurKey(this.cover, this.size, this.scale, this.sigma);

  final ui.Image cover;
  final Size size;
  final double scale;
  final double sigma;

  @override
  bool operator ==(Object other) =>
      other is _SmallArtworkBlurKey &&
      size == other.size &&
      scale == other.scale &&
      sigma == other.sigma &&
      cover.isCloneOf(other.cover);

  @override
  int get hashCode => Object.hash(size, scale, sigma);
}

/// Shares the filtered pixels through Flutter's existing bounded image cache.
/// The menu and queue keep their own crops. Matching crops use one image,
/// including across route openings. Tint, fades and controls stay live.
class _SmallArtworkBlurProvider extends ImageProvider<_SmallArtworkBlurKey> {
  const _SmallArtworkBlurProvider(this.key);

  final _SmallArtworkBlurKey key;
  static const _maxSide = 256;

  @override
  Future<_SmallArtworkBlurKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(key);

  @override
  ImageStreamCompleter loadImage(
    _SmallArtworkBlurKey key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_render(key));

  Future<ImageInfo> _render(_SmallArtworkBlurKey key) async {
    final rect = Offset.zero & key.size;
    final artworkBounds = Rect.fromCenter(
      center: rect.center,
      width: rect.width * key.scale,
      height: rect.height * key.scale,
    );
    final ratio = math.min(1.0, _maxSide / key.size.longestSide);
    final width = (key.size.width * ratio).ceil();
    final height = (key.size.height * ratio).ceil();
    final recorder = PictureRecorder();
    // The expanded photo supplies the blur beyond the menu's edges. Let
    // toImage crop the finished result, after that padding has been sampled.
    final canvas = Canvas(recorder)
      ..scale(width / key.size.width, height / key.size.height)
      ..saveLayer(
        artworkBounds,
        Paint()
          ..imageFilter = ImageFilter.blur(
            sigmaX: key.sigma,
            sigmaY: key.sigma,
          ),
      );
    final cover = key.cover.clone();
    try {
      paintImage(
        canvas: canvas,
        rect: artworkBounds,
        image: cover,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
      );
      canvas.restore();
      final picture = recorder.endRecording();
      try {
        return ImageInfo(image: await picture.toImage(width, height));
      } finally {
        picture.dispose();
      }
    } finally {
      cover.dispose();
    }
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
