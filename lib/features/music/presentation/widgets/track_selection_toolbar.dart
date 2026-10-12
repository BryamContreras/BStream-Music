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
    return Row(
      key: ValueKey('$keyPrefix-toolbar'),
      children: [
        if (showCloseButton)
          IconButton(
            key: ValueKey('$keyPrefix-close'),
            tooltip: strings.cancel,
            onPressed: selection.clear,
            icon: const Icon(Icons.close_rounded),
          ),
        Expanded(
          child: Text(
            strings.selectedSongs(selection.count),
            key: ValueKey('$keyPrefix-count'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          key: ValueKey('$keyPrefix-add-to-playlist'),
          tooltip: strings.addToPlaylist,
          onPressed: selection.busy
              ? null
              : () => _addToPlaylist(context, ref, selection),
          icon: const Icon(Icons.playlist_add_rounded),
        ),
        IconButton(
          key: ValueKey('$keyPrefix-download'),
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
