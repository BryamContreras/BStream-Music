import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import '../widgets/artwork_gradient_header_background.dart';
import '../widgets/mini_player.dart';
import '../widgets/source_image.dart';
import '../widgets/surface_detail_app_bar.dart';
import '../widgets/track_result_tile.dart';

typedef AddRemoteTracksToPlaylist =
    Future<void> Function(
      BuildContext context,
      List<TrackInfo> tracks, {
      String? initialPlaylistName,
    });

class RemoteCollectionDetailPage extends ConsumerWidget {
  const RemoteCollectionDetailPage({
    required this.title,
    required this.subtitle,
    required this.artworkSource,
    required this.queueSourceId,
    required this.tracksProvider,
    required this.emptyMessage,
    required this.errorMessage,
    required this.onOpenPlayer,
    this.onAddToPlaylist,
    this.metadata = const [],
    this.fallbackIcon = Icons.queue_music_rounded,
    super.key,
  });

  final String title;
  final String subtitle;
  final String? artworkSource;
  final String queueSourceId;
  final FutureProvider<List<TrackInfo>> tracksProvider;
  final String emptyMessage;
  final String errorMessage;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;
  final List<String> metadata;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final tracksState = ref.watch(tracksProvider);
    final tracks = switch (tracksState) {
      AsyncData(:final value) => value,
      _ => const <TrackInfo>[],
    };
    final resolvedArtworkSource =
        artworkSource ?? (tracks.isEmpty ? null : tracks.first.thumbnailUrl);
    final miniPlayerAppearance = ref.watch(
      settingsControllerProvider.select(
        (settings) => (
          mode: settings.value?.miniPlayerMode ?? defaultMiniPlayerMode,
          backgroundMode:
              settings.value?.miniPlayerBackgroundMode ??
              defaultMiniPlayerBackgroundMode,
        ),
      ),
    );
    final miniPlayerMode = miniPlayerAppearance.mode;
    final underlayMiniPlayer =
        miniPlayerMode == MiniPlayerMode.capsule ||
        miniPlayerAppearance.backgroundMode ==
            MiniPlayerBackgroundMode.transparent;
    final miniPlayerHeight = miniPlayerHeightFor(context, mode: miniPlayerMode);

    return Scaffold(
      key: const ValueKey('remote-collection-detail'),
      extendBody: underlayMiniPlayer,
      extendBodyBehindAppBar: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: SurfaceDetailAppBar(
        appBarKey: const ValueKey('remote-collection-app-bar'),
        surfaceKey: const ValueKey('remote-collection-app-bar-surface'),
        blurKey: const ValueKey('remote-collection-app-bar-blur'),
        leading: IconButton(
          key: const ValueKey('remote-collection-back'),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: CustomScrollView(
        scrollCacheExtent: const ScrollCacheExtent.pixels(800),
        slivers: [
          SliverToBoxAdapter(
            child: SizedBox(
              key: const ValueKey('remote-collection-app-bar-spacer'),
              height: surfaceDetailAppBarBodyInset(context),
            ),
          ),
          SliverToBoxAdapter(
            child: _CollectionHeader(
              title: title,
              subtitle: subtitle,
              artworkSource: resolvedArtworkSource,
              metadata: metadata,
              fallbackIcon: fallbackIcon,
              trackCount: tracksState is AsyncData<List<TrackInfo>>
                  ? tracks.length
                  : null,
              playLabel: strings.play,
              addToPlaylistLabel: strings.addToPlaylist,
              songsLabel: strings.collectionSongCount,
              canPlay: tracks.isNotEmpty,
              onPlay: () => _play(context, ref, tracks.first, tracks),
              onAddToPlaylist: onAddToPlaylist == null || tracks.isEmpty
                  ? null
                  : () => onAddToPlaylist!(
                      context,
                      tracks,
                      initialPlaylistName: title,
                    ),
            ),
          ),
          switch (tracksState) {
            AsyncData(:final value) when value.isEmpty => SliverToBoxAdapter(
              child: _CollectionStatus(
                key: const ValueKey('remote-collection-empty'),
                icon: Icons.music_off_rounded,
                message: emptyMessage,
              ),
            ),
            AsyncData(:final value) => SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 32),
              sliver: SliverList.separated(
                itemCount: value.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final track = value[index];
                  final identity = track.id.trim().isEmpty
                      ? track.url
                      : track.id;
                  return KeyedSubtree(
                    key: ValueKey('remote-collection-track-$identity'),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1080),
                        child: TrackResultTile(
                          track: track,
                          queue: value,
                          queueSourceId: queueSourceId,
                          onOpenPlayer: () => _openPlayer(context),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            AsyncError() => SliverToBoxAdapter(
              child: _CollectionStatus(
                key: const ValueKey('remote-collection-error'),
                icon: Icons.cloud_off_rounded,
                message: errorMessage,
                action: FilledButton.tonalIcon(
                  key: const ValueKey('remote-collection-retry'),
                  onPressed: () => ref.invalidate(tracksProvider),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(strings.retry),
                ),
              ),
            ),
            _ => const SliverToBoxAdapter(
              child: _CollectionStatus(
                key: ValueKey('remote-collection-loading'),
                child: CircularProgressIndicator(),
              ),
            ),
          },
        ],
      ),
      // This route has its own Scaffold, outside HomePage's shell. Reserve
      // the gesture/three-button navigation area here without duplicating it
      // while the keyboard is visible.
      bottomNavigationBar: ColoredBox(
        key: const ValueKey('remote-collection-mini-player'),
        color: underlayMiniPlayer
            ? Colors.transparent
            : Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: miniPlayerHeight,
            child: MiniPlayer(
              mode: miniPlayerMode,
              backgroundMode: miniPlayerAppearance.backgroundMode,
              onOpenPlayer: () => _openPlayer(context),
            ),
          ),
        ),
      ),
    );
  }

  void _play(
    BuildContext context,
    WidgetRef ref,
    TrackInfo selected,
    List<TrackInfo> tracks,
  ) {
    if (tracks.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final playbackError = ref.read(appStringsProvider).playbackError;
    final playback = ref
        .read(playerControllerProvider.notifier)
        .playRemote(selected, queue: tracks, queueSourceId: queueSourceId);
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    onOpenPlayer();
    unawaited(
      playback.catchError((Object error, StackTrace stackTrace) {
        messenger
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(playbackError)));
      }),
    );
  }

  void _openPlayer(BuildContext context) {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    onOpenPlayer();
  }
}

class _CollectionHeader extends StatelessWidget {
  const _CollectionHeader({
    required this.title,
    required this.subtitle,
    required this.artworkSource,
    required this.metadata,
    required this.fallbackIcon,
    required this.trackCount,
    required this.playLabel,
    required this.addToPlaylistLabel,
    required this.songsLabel,
    required this.canPlay,
    required this.onPlay,
    required this.onAddToPlaylist,
  });

  final String title;
  final String subtitle;
  final String? artworkSource;
  final List<String> metadata;
  final IconData fallbackIcon;
  final int? trackCount;
  final String playLabel;
  final String addToPlaylistLabel;
  final String Function(int count) songsLabel;
  final bool canPlay;
  final VoidCallback onPlay;
  final VoidCallback? onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    final validMetadata = metadata
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final details = [
      ...validMetadata,
      if (trackCount != null) songsLabel(trackCount!),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final artworkSize = wide ? 224.0 : 196.0;
        final artworkCacheWidth = wide ? 640 : 512;
        final artwork = ClipRRect(
          key: const ValueKey('remote-collection-artwork'),
          borderRadius: BorderRadius.circular(12),
          child: SizedBox.square(
            dimension: artworkSize,
            child: ProportionalArtwork(
              source: artworkSource,
              cacheWidth: artworkCacheWidth,
              fallback: ColoredBox(
                color: const Color(0xFF202520),
                child: Icon(fallbackIcon, size: 64),
              ),
            ),
          ),
        );
        final description = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: wide
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Text(
              key: const ValueKey('remote-collection-title'),
              title,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: wide ? TextAlign.start : TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                color: AppColors.contentTitleFor(context),
                fontWeight: FontWeight.w900,
              ),
            ),
            if (subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 7),
              Text(
                subtitle.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: wide ? TextAlign.start : TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.contentSubtitleFor(context),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (details.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                details.join(' \u2022 '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: wide ? TextAlign.start : TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.contentSubtitleFor(context),
                ),
              ),
            ],
            const SizedBox(height: 18),
            Wrap(
              alignment: wide ? WrapAlignment.start : WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('remote-collection-play'),
                  onPressed: canPlay ? onPlay : null,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(playLabel),
                ),
                if (onAddToPlaylist != null)
                  FilledButton.tonalIcon(
                    key: const ValueKey('remote-collection-add-to-playlist'),
                    onPressed: onAddToPlaylist,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    icon: const Icon(Icons.playlist_add_rounded),
                    label: Text(addToPlaylistLabel),
                  ),
              ],
            ),
          ],
        );

        return RepaintBoundary(
          key: const ValueKey('remote-collection-header'),
          child: Stack(
            children: [
              Positioned.fill(
                child: ArtworkGradientHeaderBackground(
                  artworkSource: artworkSource,
                  cacheWidth: artworkCacheWidth,
                  keyPrefix: 'remote-collection',
                ),
              ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      wide ? 28 : 20,
                      wide ? 24 : 12,
                      wide ? 28 : 20,
                      20,
                    ),
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              artwork,
                              const SizedBox(width: 28),
                              Expanded(child: description),
                            ],
                          )
                        : Column(
                            children: [
                              artwork,
                              const SizedBox(height: 18),
                              description,
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CollectionStatus extends StatelessWidget {
  const _CollectionStatus({
    super.key,
    this.icon,
    this.message,
    this.action,
    this.child,
  });

  final IconData? icon;
  final String? message;
  final Widget? action;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 220),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child:
              child ??
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null)
                    Icon(
                      icon,
                      size: 42,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  if (message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      message!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppColors.contentSubtitleFor(context),
                      ),
                    ),
                  ],
                  if (action != null) ...[const SizedBox(height: 16), action!],
                ],
              ),
        ),
      ),
    );
  }
}
