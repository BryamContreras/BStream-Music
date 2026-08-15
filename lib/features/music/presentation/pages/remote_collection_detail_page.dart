import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import '../widgets/source_image.dart';

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

    return Scaffold(
      key: const ValueKey('remote-collection-detail'),
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('remote-collection-back'),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _CollectionHeader(
              title: title,
              subtitle: subtitle,
              artworkSource: artworkSource,
              metadata: metadata,
              fallbackIcon: fallbackIcon,
              trackCount: tracksState is AsyncData<List<TrackInfo>>
                  ? tracks.length
                  : null,
              playLabel: strings.play,
              songsLabel: strings.collectionSongCount,
              canPlay: tracks.isNotEmpty,
              onPlay: () => _play(context, ref, tracks.first, tracks),
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
                  return _CollectionTrackTile(
                    track: track,
                    index: index,
                    onTap: () => _play(context, ref, track, value),
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
    required this.songsLabel,
    required this.canPlay,
    required this.onPlay,
  });

  final String title;
  final String subtitle;
  final String? artworkSource;
  final List<String> metadata;
  final IconData fallbackIcon;
  final int? trackCount;
  final String playLabel;
  final String Function(int count) songsLabel;
  final bool canPlay;
  final VoidCallback onPlay;

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
        final artwork = ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox.square(
            dimension: artworkSize,
            child: ProportionalArtwork(
              source: artworkSource,
              cacheWidth: wide ? 640 : 512,
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
            FilledButton.icon(
              key: const ValueKey('remote-collection-play'),
              onPressed: canPlay ? onPlay : null,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(playLabel),
            ),
          ],
        );

        return Center(
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
        );
      },
    );
  }
}

class _CollectionTrackTile extends StatelessWidget {
  const _CollectionTrackTile({
    required this.track,
    required this.index,
    required this.onTap,
  });

  final TrackInfo track;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final identity = track.id.trim().isEmpty ? track.url : track.id;
    final radius = BorderRadius.circular(8);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Material(
          color: AppColors.cardSurfaceFor(context),
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: AppColors.cardBorderFor(context)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('remote-collection-track-$identity'),
            borderRadius: radius,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 66),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.contentSubtitleFor(context),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: SizedBox.square(
                        dimension: 48,
                        child: ProportionalArtwork(
                          source:
                              track.thumbnailUrl ?? track.catalogThumbnailUrl,
                          cacheWidth: 192,
                          fallback: const ColoredBox(
                            color: Color(0xFF202520),
                            child: Icon(Icons.music_note_rounded),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: AppColors.contentTitleFor(context),
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${track.artist}  \u2022  ${formatDuration(track.duration)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: AppColors.contentSubtitleFor(context),
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.play_arrow_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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
