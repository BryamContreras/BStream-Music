import 'package:flutter/material.dart';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_ui.dart';
import 'package:bstream_music/core/widgets/painted_glass_button_style.dart';
import 'package:bstream_music/features/music/presentation/providers/player_style.dart';
import 'package:bstream_music/features/music/presentation/widgets/playback_gradient_background.dart';
import 'package:bstream_music/features/music/presentation/widgets/playback_dark_theme.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_controls_capsule.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_lyrics_icon.dart';

const _previewCoverAsset = 'assets/icons/4.0x/bstream_icon.png';

/// Portrait illustrations keep each layout's artwork, spacing and controls at
/// the same relative scale as the full player, without starting playback.
class PlayerStyleIllustration extends StatelessWidget {
  const PlayerStyleIllustration({required this.style, super.key});
  final PlayerStyle style;

  @override
  Widget build(BuildContext context) {
    if (AppPlatform.isMobileTargetPlatform(Theme.of(context).platform)) {
      return Theme(
        data: alwaysDarkPlaybackTheme(Theme.of(context)),
        child: Builder(builder: _buildPreview),
      );
    }
    return _buildPreview(context);
  }

  Widget _buildPreview(BuildContext context) {
    final foreground = AppColors.playbackControlForegroundFor(context);
    final apple = style == PlayerStyle.appleMusic;
    final spotify = style == PlayerStyle.spotifyMusic;
    final vinyl = style == PlayerStyle.classicVinyl;
    final utilities = _PreviewUtilityRow(apple: apple);
    return AspectRatio(
      key: ValueKey('player-style-preview-${style.code}'),
      aspectRatio: 380 / 800,
      child: RepaintBoundary(
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The sample cover is fixed. Illustrate its soft green/blue
              // backdrop directly instead of filtering an image in every card.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-.5, -.3),
                    radius: 1.2,
                    colors: [
                      Color(0xFF00D98B),
                      Color(0xFF007B73),
                      Color(0xFF040917),
                    ],
                    stops: [0, .4, 1],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: playerPlaybackOverlayGradient(context),
                ),
              ),
              FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: 380,
                  height: 800,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                    child: IconTheme(
                      data: IconThemeData(color: foreground, size: 28),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Container(
                              width: 32,
                              height: 4,
                              decoration: BoxDecoration(
                                color: foreground.withValues(alpha: .4),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 332,
                            child: vinyl
                                ? const _VinylPreview()
                                : _PreviewCover(
                                    radius: spotify ? 6 : appArtworkRadius,
                                  ),
                          ),
                          _PreviewMetadata(style: style),
                          _PreviewProgress(showThumb: spotify),
                          _PreviewTransport(style: style),
                          if (apple) const _PreviewVolume(),
                          if (spotify)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: utilities,
                            )
                          else
                            PlayerControlsCapsule(child: utilities),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewMetadata extends StatelessWidget {
  const _PreviewMetadata({required this.style});
  final PlayerStyle style;

  @override
  Widget build(BuildContext context) {
    final circular =
        style == PlayerStyle.appleMusic || style == PlayerStyle.classicVinyl;
    return SizedBox(
      height: 70,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'BStream Music',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: Theme.of(
                      context,
                    ).textTheme.titleLarge?.fontFamily,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.playbackTitleFor(context),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'BStream Music',
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: Theme.of(
                      context,
                    ).textTheme.titleMedium?.fontFamily,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.contentSubtitleFor(context),
                  ),
                ),
              ],
            ),
          ),
          _PreviewAction(
            icon: Icons.favorite_border_rounded,
            circular: circular,
          ),
          const SizedBox(width: 8),
          _PreviewAction(
            icon: circular ? Icons.more_horiz_rounded : Icons.more_vert_rounded,
            circular: circular,
          ),
        ],
      ),
    );
  }
}

class _PreviewAction extends StatelessWidget {
  const _PreviewAction({required this.icon, required this.circular});
  final IconData icon;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    final action = SizedBox.square(
      dimension: 40,
      child: Icon(icon, size: circular ? 22 : 28),
    );
    if (!circular) return action;
    // Reuse the painted glass recipe: miniatures have no moving content to
    // sample, so live backdrop blur/refraction would only add raster work.
    final surface = paintedGlassButtonStyle(context, circular: true);
    const states = <WidgetState>{};
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: surface.shape!
            .resolve(states)!
            .copyWith(side: surface.side!.resolve(states)),
      ),
      child: surface.backgroundBuilder!(context, states, action),
    );
  }
}

class _PreviewTransport extends StatelessWidget {
  const _PreviewTransport({required this.style});
  final PlayerStyle style;

  @override
  Widget build(BuildContext context) {
    final apple = style == PlayerStyle.appleMusic;
    final spotify = style == PlayerStyle.spotifyMusic;
    final foreground = AppColors.playbackControlForegroundFor(context);
    return SizedBox(
      height: spotify ? 72 : 92,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (!apple) const Icon(Icons.shuffle_rounded, size: 26),
          Icon(
            apple ? Icons.fast_rewind_rounded : Icons.skip_previous_rounded,
            size: apple ? 48 : 42,
          ),
          if (spotify)
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: foreground,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                color: Theme.of(context).colorScheme.surface,
                size: 42,
              ),
            )
          else
            const Icon(Icons.play_arrow_rounded, size: 82),
          Icon(
            apple ? Icons.fast_forward_rounded : Icons.skip_next_rounded,
            size: apple ? 48 : 42,
          ),
          if (!apple) const Icon(Icons.repeat_rounded, size: 26),
        ],
      ),
    );
  }
}

class _PreviewUtilityRow extends StatelessWidget {
  const _PreviewUtilityRow({required this.apple});
  final bool apple;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        SizedBox.square(
          dimension: 28,
          child: IconTheme.merge(
            data: const IconThemeData(size: 28),
            child: const PlayerLyricsIcon(),
          ),
        ),
        Icon(apple ? Icons.shuffle_rounded : Icons.volume_up_rounded, size: 28),
        Icon(apple ? Icons.repeat_rounded : Icons.speaker_rounded, size: 28),
        const Icon(Icons.format_list_bulleted_rounded, size: 28),
      ],
    ),
  );
}

class _PreviewProgress extends StatelessWidget {
  const _PreviewProgress({this.showThumb = false});
  final bool showThumb;
  @override
  Widget build(BuildContext context) {
    final foreground = AppColors.playbackControlForegroundFor(context);
    final active = showThumb
        ? foreground
        : AppColors.downloadAccentFor(context);
    return SizedBox(
      height: 38,
      child: Column(
        children: [
          SizedBox(
            height: 12,
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                alignment: Alignment.centerLeft,
                clipBehavior: Clip.none,
                children: [
                  Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: foreground.withValues(alpha: .2),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: .38,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: active,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  if (showThumb)
                    Positioned(
                      left: constraints.maxWidth * .38 - 3.5,
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: active,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final text in ['1:24', '3:42'])
                Text(
                  text,
                  style: TextStyle(
                    color: AppColors.contentSubtitleFor(context),
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewVolume extends StatelessWidget {
  const _PreviewVolume();
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 28,
    child: Row(
      children: [
        const Icon(Icons.volume_mute_rounded, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 3,
            decoration: BoxDecoration(
              color: AppColors.playbackControlForegroundFor(
                context,
              ).withValues(alpha: .25),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.volume_up_rounded, size: 24),
      ],
    ),
  );
}

class _PreviewCover extends StatelessWidget {
  const _PreviewCover({this.radius = appArtworkRadius});
  final double radius;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: Image.asset(_previewCoverAsset, fit: BoxFit.cover, cacheWidth: 512),
  );
}

class _VinylPreview extends StatelessWidget {
  const _VinylPreview();
  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        left: 0,
        top: 9,
        width: 306,
        height: 306,
        child: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              colors: [
                Color(0xFF101010),
                Color(0xFF424242),
                Color(0xFF171717),
                Color(0xFF333333),
                Color(0xFF101010),
              ],
            ),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (final extent in [288.0, 266.0, 244.0, 222.0, 200.0])
                Container(
                  width: extent,
                  height: extent,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .035),
                    ),
                  ),
                ),
              Container(
                width: 116,
                height: 116,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black, width: 3),
                ),
                clipBehavior: Clip.antiAlias,
                child: const _PreviewCover(radius: 0),
              ),
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF999999),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      ),
      Positioned(
        top: 20,
        right: 14,
        child: Transform.rotate(
          angle: .26,
          alignment: Alignment.topCenter,
          child: Column(
            children: [
              Container(
                width: 7,
                height: 174,
                decoration: BoxDecoration(
                  color: const Color(0xFFBABABA),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Transform.rotate(
                angle: -.5,
                child: Container(
                  width: 14,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6D6D6D),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      Positioned(
        top: 12,
        right: 9,
        child: Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(
            color: Color(0xFF999999),
            shape: BoxShape.circle,
          ),
        ),
      ),
    ],
  );
}
