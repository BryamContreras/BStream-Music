import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/duration_formatter.dart';
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
        return (
          status: snapshot?.status,
          title: snapshot?.title,
          artist: snapshot?.artist,
          trackId: snapshot?.trackId,
          thumbnailUrl: snapshot?.thumbnailUrl,
          hasError: player.hasError || snapshot?.status == PlayerStatus.failed,
          errorText: player.error?.toString() ?? snapshot?.errorMessage,
        );
      }),
    );
    final strings = ref.watch(appStringsProvider);
    final isFavorite = ref.watch(
      favoriteTrackIdsProvider.select(
        (ids) => ids.contains(presentation.trackId),
      ),
    );
    final compactAndroid = AppPlatform.isAndroid;
    final height = compactAndroid ? 66.0 : 76.0;
    final horizontalPadding = compactAndroid ? 14.0 : 20.0;
    final artworkSize = compactAndroid ? 44.0 : 48.0;
    final playButtonSize = compactAndroid ? 48.0 : 54.0;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: ClipRect(
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
              child: SizedBox(
                height: height,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                  child: Row(
                    children: [
                      _MiniArtwork(
                        url: presentation.thumbnailUrl,
                        size: artworkSize,
                        isFavorite: isFavorite,
                      ),
                      SizedBox(width: compactAndroid ? 10 : 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              presentation.title ?? strings.noPlayback,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                shadows: isDark
                                    ? const [
                                        Shadow(
                                          color: Color(0xAA000000),
                                          blurRadius: 8,
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              presentation.artist ?? 'BStream Music',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                                shadows: isDark
                                    ? const [
                                        Shadow(
                                          color: Color(0x99000000),
                                          blurRadius: 7,
                                        ),
                                      ]
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (presentation.hasError)
                        Flexible(
                          child: Text(
                            presentation.errorText ?? strings.playbackError,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      SizedBox(width: compactAndroid ? 10 : 14),
                      SizedBox(
                        width: compactAndroid ? 46 : 54,
                        child: const _MiniPositionText(),
                      ),
                      SizedBox(width: compactAndroid ? 8 : 12),
                      SizedBox.square(
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
                              foregroundColor: AppColors.playIconForegroundFor(
                                context,
                              ),
                              disabledBackgroundColor: Colors.transparent,
                              disabledForegroundColor:
                                  AppColors.playIconDisabledForegroundFor(
                                    context,
                                  ),
                              shape: const CircleBorder(),
                            ),
                            iconSize: compactAndroid ? 24 : null,
                            padding: EdgeInsets.zero,
                            constraints: BoxConstraints.tight(
                              Size.square(playButtonSize),
                            ),
                            icon: Icon(
                              presentation.status == PlayerStatus.playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                            onPressed: () => ref
                                .read(playerControllerProvider.notifier)
                                .togglePlayPause(),
                          ),
                        ),
                      ),
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
    return Text(
      formatDuration(Duration(seconds: seconds)),
      textAlign: TextAlign.right,
      style: Theme.of(context).textTheme.labelMedium,
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
