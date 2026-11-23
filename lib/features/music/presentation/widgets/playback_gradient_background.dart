import 'dart:math' as math;
import 'dart:typed_data';
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
import 'artwork_video_palette.dart';
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

/// Connects the mounted clip to the full player without rebuilding its controls.
class ArtworkVideoPaletteBinding extends ValueNotifier<ArtworkVideoPalette?> {
  ArtworkVideoPaletteBinding({required this.url, required this.identity})
    : super(null);

  final Uri url;
  final String identity;
  var _closed = false;

  void publish(ArtworkVideoPalette? palette) {
    if (!_closed) value = palette;
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

class ArtworkVideoPaletteScope extends InheritedWidget {
  const ArtworkVideoPaletteScope({
    required this.binding,
    required super.child,
    super.key,
  });

  final ArtworkVideoPaletteBinding? binding;

  static ArtworkVideoPaletteBinding? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ArtworkVideoPaletteScope>()
      ?.binding;

  static ValueChanged<ArtworkVideoPalette?>? callbackFor(
    BuildContext context,
    Uri url,
    String identity,
  ) {
    final binding = maybeOf(context);
    return binding != null && binding.url == url && binding.identity == identity
        ? binding.publish
        : null;
  }

  @override
  bool updateShouldNotify(ArtworkVideoPaletteScope oldWidget) =>
      binding != oldWidget.binding;
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
    this.followArtworkVideo = false,
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
  final bool followArtworkVideo;
  final bool cacheSmallBlur;
  final double blurSigma;

  /// The foreground cover's unanimated square, in this backdrop's coordinates.
  /// Matching its crop lets the lower edge continue into a vertical reflection.
  final Rect? reflectionArtworkRect;

  @override
  Widget build(BuildContext context) {
    final artwork = _AnimatedPlaybackArtwork(
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
    );
    final videoColor = followArtworkVideo
        ? ArtworkVideoPaletteScope.maybeOf(context)
        : null;
    final overlayGradient = playerPlaybackOverlayGradient(
      context,
      reflected: reflectionArtworkRect != null,
    );
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (videoColor == null)
            artwork
          else
            _VideoArtworkBackground(colors: videoColor, fallback: artwork),
          DecoratedBox(decoration: BoxDecoration(gradient: overlayGradient)),
          if (additionalScrimAlpha > 0)
            ColoredBox(
              color: Colors.black.withValues(alpha: additionalScrimAlpha),
            ),
        ],
      ),
    );
  }
}

class _VideoArtworkBackground extends StatelessWidget {
  const _VideoArtworkBackground({required this.colors, required this.fallback});

  final ValueListenable<ArtworkVideoPalette?> colors;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return ValueListenableBuilder<ArtworkVideoPalette?>(
      valueListenable: colors,
      child: fallback,
      builder: (context, palette, fallback) => AnimatedSwitcher(
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 500),
        layoutBuilder: (current, previous) =>
            Stack(fit: StackFit.expand, children: [...previous, ?current]),
        transitionBuilder: noDimmingFadeTransitionBuilder,
        child: palette == null
            ? fallback!
            : TweenAnimationBuilder<ArtworkVideoPalette>(
                key: const ValueKey('player-video-palette-mesh'),
                tween: _ArtworkVideoPaletteTween(palette),
                duration: reduceMotion
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                builder: (context, palette, _) =>
                    CustomPaint(painter: _ArtworkVideoMeshPainter(palette)),
              ),
      ),
    );
  }
}

class _ArtworkVideoPaletteTween extends Tween<ArtworkVideoPalette> {
  _ArtworkVideoPaletteTween(ArtworkVideoPalette palette)
    : super(begin: palette, end: palette);

  @override
  ArtworkVideoPalette lerp(double t) =>
      ArtworkVideoPalette.lerp(begin!, end!, t);
}

/// A single draw using colors already captured for the clip's timeline.
class _ArtworkVideoMeshPainter extends CustomPainter {
  const _ArtworkVideoMeshPainter(this.palette);

  static const _segments = 12;
  static const _stride = _segments + 1;
  static const _artworkEdge = .58;

  static final _positions = Float32List.fromList([
    for (var y = 0; y <= _segments; y++)
      for (var x = 0; x <= _segments; x++) ...[x / _segments, y / _segments],
  ]);

  static final _indices = Uint16List.fromList([
    for (var y = 0; y < _segments; y++)
      for (var x = 0; x < _segments; x++) ...[
        y * _stride + x,
        y * _stride + x + 1,
        (y + 1) * _stride + x,
        (y + 1) * _stride + x,
        y * _stride + x + 1,
        (y + 1) * _stride + x + 1,
      ],
  ]);

  static final _columns = [
    for (var x = 0; x <= _segments; x++) _sampleAt(x / _segments),
  ];
  static final _rows = [
    for (var y = 0; y <= _segments; y++) _sampleAt(_reflect(y / _segments)),
  ];

  final ArtworkVideoPalette palette;

  // Extend the lower part of the artwork softly below its faded edge.
  static double _reflect(double y) => y <= _artworkEdge
      ? y / _artworkEdge
      : 1 - .63 * (y - _artworkEdge) / (1 - _artworkEdge);

  static ({int index, double weight}) _sampleAt(double fraction) {
    const extent = ArtworkVideoPalette.meshExtent;
    final position = (fraction * extent - .5).clamp(0.0, extent - 1.0);
    final index = math.min(position.floor(), extent - 2);
    final t = position - index;
    return (index: index, weight: t * t * (3 - 2 * t));
  }

  @override
  void paint(Canvas canvas, Size size) {
    const extent = ArtworkVideoPalette.meshExtent;
    final cells =
        palette.cells ?? List.generate(extent * extent, palette.colorForCell);
    final across = [
      for (var row = 0; row < extent; row++)
        for (final column in _columns)
          Color.lerp(
            cells[row * extent + column.index],
            cells[row * extent + column.index + 1],
            column.weight,
          ),
    ];
    final colors = Int32List(_stride * _stride);
    var index = 0;
    for (final row in _rows) {
      for (var column = 0; column < _stride; column++) {
        final upper = row.index * _stride + column;
        colors[index++] = Color.lerp(
          across[upper],
          across[upper + _stride],
          row.weight,
        )!.toARGB32();
      }
    }
    final vertices = Vertices.raw(
      VertexMode.triangles,
      _positions,
      colors: colors,
      indices: _indices,
    );
    canvas.save();
    canvas.scale(size.width, size.height);
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    canvas.restore();
    vertices.dispose();
  }

  @override
  bool shouldRepaint(covariant _ArtworkVideoMeshPainter oldDelegate) =>
      oldDelegate.palette != palette;
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
