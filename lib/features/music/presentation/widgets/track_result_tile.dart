import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../services/player/player_service.dart';
import '../../domain/entities/download_result.dart';
import '../../domain/entities/track_info.dart';
import 'gradient_progress_bar.dart';
import 'playlist_picker_dialog.dart';
import 'source_image.dart';
import 'track_play_button.dart';
import '../providers/music_providers.dart';

enum _TrackResultAction { download, addToPlaylist }

class TrackResultTile extends ConsumerStatefulWidget {
  const TrackResultTile({
    required this.track,
    required this.onOpenPlayer,
    super.key,
  });

  final TrackInfo track;
  final VoidCallback onOpenPlayer;

  @override
  ConsumerState<TrackResultTile> createState() => _TrackResultTileState();
}

class _TrackResultTileState extends ConsumerState<TrackResultTile> {
  bool _hovered = false;

  TrackInfo get track => widget.track;
  VoidCallback get onOpenPlayer => widget.onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final downloadState = ref.watch(
      downloadControllerProvider.select((tasks) => tasks[track.url]),
    );
    final strings = ref.watch(appStringsProvider);
    final playback = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        return (
          trackId: snapshot?.trackId,
          sourceUrl: snapshot?.sourceUrl,
          status: snapshot?.status,
        );
      }),
    );
    final matchesCurrent =
        playback.trackId == track.id || playback.sourceUrl == track.url;
    final isCurrent =
        matchesCurrent &&
        (playback.status == PlayerStatus.loading ||
            playback.status == PlayerStatus.playing ||
            playback.status == PlayerStatus.paused);
    final isPlaying = isCurrent && playback.status == PlayerStatus.playing;
    final colors = Theme.of(context).colorScheme;
    final borderRadius = BorderRadius.circular(8);
    final baseColor = AppColors.cardSurfaceFor(context);
    final surfaceColor = isCurrent || _hovered
        ? Color.alphaBlend(
            colors.onSurface.withValues(alpha: _hovered ? 0.09 : 0.075),
            baseColor,
          )
        : baseColor;
    final borderColor = isCurrent || _hovered
        ? colors.primary
        : AppColors.cardBorderFor(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        key: ValueKey(
          'track-result-surface-${track.id.isNotEmpty ? track.id : track.url}',
        ),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: borderRadius,
          border: Border.all(color: borderColor, width: _hovered ? 1.4 : 1),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: () => _play(ref, openPlayer: true),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  _Thumbnail(url: track.thumbnailUrl),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                fontWeight: isCurrent
                                    ? FontWeight.w800
                                    : FontWeight.w700,
                                color: AppColors.contentTitleFor(context),
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${track.artist}  -  ${formatDuration(track.duration)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: AppColors.contentSubtitleFor(context),
                              ),
                        ),
                        if (downloadState != null) ...[
                          const SizedBox(height: 5),
                          GradientProgressBar(
                            value: _visibleProgress(downloadState),
                            indeterminate: _isIndeterminate(downloadState),
                            height: 4,
                            colors: _progressColors(
                              context,
                              downloadState.status,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TrackPlayButton(
                    tooltip: isPlaying ? strings.pause : strings.play,
                    isPlaying: isPlaying,
                    onPressed: () => _togglePlayback(ref),
                  ),
                  _TrackResultMenu(track: track, strings: strings),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _play(WidgetRef ref, {bool openPlayer = false}) async {
    final queue = ref.read(searchControllerProvider).value ?? [track];
    final playFuture = ref
        .read(playerControllerProvider.notifier)
        .playRemote(track, queue: queue);
    if (openPlayer) {
      onOpenPlayer();
    }
    await playFuture;
  }

  Future<void> _togglePlayback(WidgetRef ref) async {
    final snapshot = ref.read(playerControllerProvider).value;
    final isCurrent =
        snapshot?.trackId == track.id || snapshot?.sourceUrl == track.url;
    final player = ref.read(playerControllerProvider.notifier);
    if (isCurrent && snapshot?.status == PlayerStatus.playing) {
      await player.pause();
      return;
    }
    if (isCurrent && snapshot?.status == PlayerStatus.paused) {
      await player.resume();
      return;
    }
    await _play(ref);
  }

  List<Color> _progressColors(
    BuildContext context,
    DownloadProgressStatus status,
  ) {
    return switch (status) {
      DownloadProgressStatus.failed => [
        Theme.of(context).colorScheme.error,
        const Color(0xFFFFA2A2),
      ],
      DownloadProgressStatus.completed => AppColors.downloadGradientFor(
        context,
      ),
      _ => AppColors.downloadGradientFor(context),
    };
  }

  double _visibleProgress(DownloadTaskState state) {
    return switch (state.status) {
      DownloadProgressStatus.queued => 0,
      DownloadProgressStatus.running => (state.progress ?? 0).clamp(0, 0.98),
      DownloadProgressStatus.completed => 1,
      DownloadProgressStatus.failed => (state.progress ?? 0).clamp(0, 1),
    };
  }

  bool _isIndeterminate(DownloadTaskState state) {
    return state.status == DownloadProgressStatus.queued ||
        (state.status == DownloadProgressStatus.running &&
            state.progress == null);
  }
}

class _TrackResultMenu extends ConsumerWidget {
  const _TrackResultMenu({required this.track, required this.strings});

  final TrackInfo track;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compactAndroid = AppPlatform.isAndroid;
    final buttonSize = compactAndroid ? 42.0 : 52.0;
    final iconSize = compactAndroid ? 32.0 : 24.0;
    final menuIconColor = AppColors.menuIconFor(context);

    return SizedBox.square(
      dimension: buttonSize,
      child: PopupMenuButton<_TrackResultAction>(
        tooltip: strings.moreOptions,
        padding: EdgeInsets.zero,
        iconSize: iconSize,
        child: Center(child: Icon(Icons.more_vert_rounded, size: iconSize)),
        onSelected: (action) {
          switch (action) {
            case _TrackResultAction.download:
              _download(ref);
            case _TrackResultAction.addToPlaylist:
              unawaited(_addToPlaylist(context, ref));
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: _TrackResultAction.download,
            child: Row(
              children: [
                Icon(Icons.download_rounded, color: menuIconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.download,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: _TrackResultAction.addToPlaylist,
            child: Row(
              children: [
                Icon(Icons.playlist_add_rounded, color: menuIconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.addToPlaylist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _download(WidgetRef ref) {
    ref.read(downloadControllerProvider.notifier).downloadAudio(track);
  }

  Future<void> _addToPlaylist(BuildContext context, WidgetRef ref) async {
    final playlists = (await ref.read(
      playlistsControllerProvider.future,
    )).where((playlist) => !playlist.isFavorites).toList(growable: false);
    if (!context.mounted) {
      return;
    }
    if (playlists.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.createPlaylistFirst)));
      return;
    }

    final localTracks = await ref
        .read(libraryRepositoryProvider)
        .getLocalTracks();
    if (!context.mounted) {
      return;
    }

    final playlistId = await showDialog<String>(
      context: context,
      builder: (context) {
        return PlaylistPickerDialog(
          title: strings.choosePlaylist,
          playlists: playlists,
          tracks: localTracks,
        );
      },
    );
    if (playlistId == null || !context.mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(strings.downloading)));
    try {
      final localTrack = await ref
          .read(downloadControllerProvider.notifier)
          .downloadAudioForLibrary(track);
      await ref
          .read(playlistsControllerProvider.notifier)
          .addTrackToPlaylist(playlistId, localTrack.id);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(strings.songAddedToPlaylist)));
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 56,
        height: 56,
        child: ProportionalArtwork(
          source: url,
          cacheWidth: 512,
          fallback: const ColoredBox(
            color: Color(0xFF202520),
            child: Icon(Icons.music_note_rounded),
          ),
        ),
      ),
    );
  }
}
