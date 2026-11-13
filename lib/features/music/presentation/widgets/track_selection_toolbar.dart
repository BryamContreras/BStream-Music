import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import '../providers/track_selection_controller.dart';
import 'playlist_actions.dart';

class TrackSelectionToolbar extends ConsumerWidget {
  const TrackSelectionToolbar({
    required this.scope,
    required this.tracks,
    required this.keyPrefix,
    this.initialPlaylistName,
    this.showCloseButton = true,
    super.key,
  });

  final Object scope;
  final List<TrackInfo> tracks;
  final String keyPrefix;
  final String? initialPlaylistName;
  final bool showCloseButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(trackSelectionProvider(scope));
    final strings = ref.watch(appStringsProvider);
    final theme = Theme.of(context);
    return Row(
      key: ValueKey('$keyPrefix-toolbar'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showCloseButton)
          IconButton(
            key: ValueKey('$keyPrefix-close'),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: strings.cancel,
            onPressed: selection.clear,
            icon: const Icon(Icons.close_rounded),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 12, end: 8),
            child: Text(
              strings.selectedSongs(selection.count),
              key: ValueKey('$keyPrefix-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textHeightBehavior: const TextHeightBehavior(
                leadingDistribution: TextLeadingDistribution.even,
              ),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
        ),
        IconButton(
          key: ValueKey('$keyPrefix-add-to-playlist'),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: strings.addToPlaylist,
          onPressed: selection.busy
              ? null
              : () => _addToPlaylist(context, ref, selection),
          icon: const Icon(Icons.playlist_add_rounded),
        ),
        IconButton(
          key: ValueKey('$keyPrefix-download'),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: strings.downloadAudio,
          onPressed: selection.busy
              ? null
              : () => _download(context, ref, selection),
          icon: const Icon(Icons.download_rounded),
        ),
      ],
    );
  }

  Future<void> _addToPlaylist(
    BuildContext context,
    WidgetRef ref,
    TrackSelectionController selection,
  ) async {
    final selected = selection.selectedTracks(tracks);
    if (selection.busy || selected.isEmpty) return;
    selection.setBusy(true);
    try {
      final added = await addCollectionToPlaylist(
        context,
        ref,
        selected,
        initialPlaylistName: initialPlaylistName,
      );
      if (added) selection.clear();
    } finally {
      selection.setBusy(false);
    }
  }

  Future<void> _download(
    BuildContext context,
    WidgetRef ref,
    TrackSelectionController selection,
  ) async {
    final selected = selection.selectedTracks(tracks);
    if (selection.busy || selected.isEmpty) return;
    final strings = ref.read(appStringsProvider);
    selection.setBusy(true);
    try {
      final queued = await ref
          .read(downloadControllerProvider.notifier)
          .downloadTracks(selected);
      selection.clear();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            queued == 0
                ? strings.noPendingPlaylistDownloads
                : strings.songsQueuedForDownload(queued),
          ),
        ),
      );
    } catch (error) {
      debugPrint('Could not prepare selected downloads: $error');
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.bulkDownloadFailed)));
    } finally {
      selection.setBusy(false);
    }
  }
}
