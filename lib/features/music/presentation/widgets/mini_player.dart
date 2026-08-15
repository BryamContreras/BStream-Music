import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../services/downloader/audio_stream_resolver.dart';
import '../../../../services/player/player_service.dart';
import '../providers/music_providers.dart';
import 'favorite_star_badge.dart';
import 'playback_progress_line.dart';
import 'source_image.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({this.onOpenPlayer, super.key});

  final VoidCallback? onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presentation = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        final rawError = player.error ?? snapshot?.errorMessage;
        return (
          status: snapshot?.status,
          title: snapshot?.title,
          artist: snapshot?.artist,
          trackId: snapshot?.trackId,
          thumbnailUrl: snapshot?.thumbnailUrl,
          hasError:
              player.hasError ||
              snapshot?.status == PlayerStatus.failed ||
              snapshot?.errorMessage?.trim().isNotEmpty == true,
          errorText: rawError == null
              ? null
              : readableAudioStreamError(rawError),
        );
      }),
    );
    final strings = ref.watch(appStringsProvider);
    final isFavorite = ref.watch(
      favoriteTrackIdsProvider.select(
        (ids) => ids.contains(presentation.trackId),
      ),
    );
    final theme = Theme.of(context);
    final compactAndroid = theme.platform == TargetPlatform.android;
    final windowsLayout =
        AppPlatform.isWindows &&
        !compactAndroid &&
        MediaQuery.sizeOf(context).width >= 360;
    final horizontalPadding = compactAndroid ? 12.0 : 20.0;
    final artworkSize = compactAndroid ? 40.0 : 48.0;
    final playButtonSize = compactAndroid ? 48.0 : 54.0;
    final minimumHeight = compactAndroid ? 62.0 : 76.0;
    final isDark = theme.brightness == Brightness.dark;
    final metadata = Row(
      key: const ValueKey('mini-player-metadata'),
      children: [
        _MiniArtwork(
          url: presentation.thumbnailUrl,
          size: artworkSize,
          isFavorite: isFavorite,
        ),
        SizedBox(width: compactAndroid ? 8 : 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                presentation.title ?? strings.noPlayback,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.playbackTitleFor(context),
                  shadows: isDark
                      ? const [Shadow(color: Color(0xAA000000), blurRadius: 8)]
                      : null,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                presentation.artist ?? 'BStream Music',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.contentSubtitleFor(context),
                  shadows: isDark
                      ? const [Shadow(color: Color(0x99000000), blurRadius: 7)]
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final primaryControl = SizedBox.square(
      dimension: playButtonSize,
      child: DecoratedBox(
        key: const ValueKey('mini-player-primary-gradient'),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: AppColors.downloadGradientFor(context),
          ),
        ),
        child: IconButton(
          key: const ValueKey('mini-player-primary-control'),
          tooltip: presentation.status == PlayerStatus.playing
              ? strings.pause
              : strings.play,
          style: IconButton.styleFrom(
            backgroundColor: Colors.transparent,
            foregroundColor: AppColors.playIconForegroundFor(context),
            disabledBackgroundColor: Colors.transparent,
            disabledForegroundColor: AppColors.playIconDisabledForegroundFor(
              context,
            ),
            shape: const CircleBorder(),
          ),
          iconSize: compactAndroid ? 24 : null,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tight(Size.square(playButtonSize)),
          icon: Icon(
            presentation.status == PlayerStatus.playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
          ),
          onPressed: () =>
              ref.read(playerControllerProvider.notifier).togglePlayPause(),
        ),
      ),
    );

    return Container(
      key: const ValueKey('mini-player-container'),
      margin: EdgeInsets.symmetric(horizontal: compactAndroid ? 8 : 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(compactAndroid ? 10 : 0),
      ),
      child: Material(
        key: const ValueKey('mini-player-frame'),
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: _MiniBlurBackground(url: presentation.thumbnailUrl),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: isDark
                        ? const [
                            Color(0xDA0A100C),
                            Color(0x99112816),
                            Color(0xE407100A),
                          ]
                        : const [
                            Color(0xEAF5F8F6),
                            Color(0xDDEAF3ED),
                            Color(0xEEF5F8F6),
                          ],
                  ),
                ),
              ),
            ),
            Positioned(top: 0, left: 0, right: 0, child: const _MiniProgress()),
            InkWell(
              onTap: onOpenPlayer,
              child: ConstrainedBox(
                key: const ValueKey('mini-player-surface'),
                constraints: BoxConstraints(minHeight: minimumHeight),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalPadding,
                    vertical: 4,
                  ),
                  child: windowsLayout
                      ? Row(
                          children: [
                            Expanded(child: metadata),
                            SizedBox(
                              width: 160,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _MiniTransportButton(
                                    key: const ValueKey(
                                      'mini-player-previous-control',
                                    ),
                                    tooltip: strings.previous,
                                    icon: Icons.skip_previous_rounded,
                                    onPressed: () => ref
                                        .read(playerControllerProvider.notifier)
                                        .playPrevious(),
                                  ),
                                  const SizedBox(width: 5),
                                  primaryControl,
                                  const SizedBox(width: 5),
                                  _MiniTransportButton(
                                    key: const ValueKey(
                                      'mini-player-next-control',
                                    ),
                                    tooltip: strings.next,
                                    icon: Icons.skip_next_rounded,
                                    onPressed: () => ref
                                        .read(playerControllerProvider.notifier)
                                        .playNext(),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (presentation.hasError)
                                    Flexible(
                                      child: Text(
                                        presentation.errorText ??
                                            strings.playbackError,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.right,
                                        style: TextStyle(
                                          color: theme.colorScheme.error,
                                        ),
                                      ),
                                    ),
                                  if (presentation.hasError)
                                    const SizedBox(width: 12),
                                  const SizedBox(
                                    width: 54,
                                    child: _MiniPositionText(),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(child: metadata),
                            if (presentation.hasError)
                              Flexible(
                                child: Text(
                                  presentation.errorText ??
                                      strings.playbackError,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            SizedBox(width: compactAndroid ? 8 : 14),
                            SizedBox(
                              width: compactAndroid ? 46 : 54,
                              child: const _MiniPositionText(),
                            ),
                            SizedBox(width: compactAndroid ? 8 : 12),
                            primaryControl,
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniTransportButton extends StatelessWidget {
  const _MiniTransportButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 48,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        color: AppColors.playbackControlForegroundFor(context),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        onPressed: onPressed,
      ),
    );
  }
}

class _MiniBlurBackground extends StatelessWidget {
  const _MiniBlurBackground({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final source = url?.trim();
    if (source == null || source.isEmpty) {
      return const _MiniFallbackBackground();
    }

    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
      child: Transform.scale(
        scale: 1.28,
        child: SourceImage(
          source: source,
          fit: BoxFit.cover,
          cacheWidth: 320,
          fallback: const _MiniFallbackBackground(),
        ),
      ),
    );
  }
}

class _MiniProgress extends ConsumerWidget {
  const _MiniProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timeline = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        return (
          position: snapshot?.position ?? Duration.zero,
          duration: snapshot?.duration,
        );
      }),
    );
    final progressColor = AppColors.downloadAccentFor(context);
    final strings = ref.watch(appStringsProvider);
    final duration = timeline.duration;
    final position = timeline.position;
    final progress = duration == null || duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();

    return PlaybackProgressLine(
      value: progress,
      color: progressColor,
      colorAnimationKey: const ValueKey('mini-progress-color-animation'),
      fillKey: const ValueKey('mini-progress-fill'),
      semanticsLabel: strings.choose(
        'Progreso de reproducción',
        'Playback progress',
      ),
    );
  }
}

class _MiniPositionText extends ConsumerWidget {
  const _MiniPositionText();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seconds = ref.watch(
      playerControllerProvider.select(
        (player) => player.value?.position.inSeconds ?? 0,
      ),
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(
        formatDuration(Duration(seconds: seconds)),
        maxLines: 1,
        softWrap: false,
        textAlign: TextAlign.right,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: AppColors.contentSubtitleFor(context),
        ),
      ),
    );
  }
}

class _MiniFallbackBackground extends StatelessWidget {
  const _MiniFallbackBackground();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: isDark
              ? const [Color(0xFF0B0E0B), Color(0xFF050605)]
              : const [Color(0xFFE9F3EC), Color(0xFFF5F8F6)],
        ),
      ),
    );
  }
}

class _MiniArtwork extends StatelessWidget {
  const _MiniArtwork({
    required this.url,
    required this.size,
    required this.isFavorite,
  });

  final String? url;
  final double size;
  final bool isFavorite;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
              ),
              child: url == null
                  ? const Icon(Icons.graphic_eq_rounded)
                  : ProportionalArtwork(
                      source: url,
                      cacheWidth: 256,
                      fallback: const Icon(Icons.graphic_eq_rounded),
                    ),
            ),
            if (isFavorite)
              const Positioned(
                top: 1,
                right: 1,
                child: FavoriteStarBadge(iconSize: 11),
              ),
          ],
        ),
      ),
    );
  }
}
