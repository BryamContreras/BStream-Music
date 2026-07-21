import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/utils/image_source.dart';
import '../../../../services/player/player_service.dart';
import '../providers/music_providers.dart';
import 'favorite_star_badge.dart';

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
          hasError: player.hasError,
          errorText: player.error?.toString(),
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

    return Material(
      color: Colors.transparent,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: _MiniBlurBackground(url: presentation.thumbnailUrl),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Color(0xDA0A100C),
                      Color(0x99112816),
                      Color(0xE407100A),
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
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                shadows: [
                                  Shadow(
                                    color: Color(0xAA000000),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              presentation.artist ?? 'BStream Music',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                shadows: const [
                                  Shadow(
                                    color: Color(0x99000000),
                                    blurRadius: 7,
                                  ),
                                ],
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
                        child: IconButton.filled(
                          tooltip: presentation.status == PlayerStatus.playing
                              ? strings.pause
                              : strings.play,
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
        child: _MiniImage(
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
    final duration = timeline.duration;
    final position = timeline.position;
    final progress = duration == null || duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();

    return SizedBox(
      height: 3,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.2),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: progress),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) {
              return FractionallySizedBox(
                widthFactor: value,
                child: const SizedBox.expand(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF0E9F4D), Color(0xFF18C75A)],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
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
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [Color(0xFF0B0E0B), Color(0xFF050605)],
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
                  : _MiniImage(source: url!, fit: BoxFit.cover),
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

class _MiniImage extends StatelessWidget {
  const _MiniImage({
    required this.source,
    required this.fit,
    this.fallback = const Icon(Icons.graphic_eq_rounded),
  });

  final String source;
  final BoxFit fit;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final normalized = source.trim();
    if (isNetworkImageSource(normalized)) {
      return Image.network(
        normalized,
        fit: fit,
        errorBuilder: (_, _, _) => fallback,
      );
    }

    final file = imageFileFromSource(normalized);
    if (file == null) {
      return fallback;
    }
    if (!file.existsSync()) {
      return fallback;
    }
    return Image.file(file, fit: fit, errorBuilder: (_, _, _) => fallback);
  }
}
