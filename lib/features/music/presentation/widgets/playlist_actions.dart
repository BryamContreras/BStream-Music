import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dialog.dart';
import '../../domain/entities/catalog_playlist.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import 'playlist_picker_dialog.dart';

Future<bool> addCollectionToPlaylist(
  BuildContext context,
  WidgetRef ref,
  List<TrackInfo> tracks, {
  String? initialPlaylistName,
}) async {
  if (tracks.isEmpty || !context.mounted) return false;
  final strings = ref.read(appStringsProvider);
  try {
    final (playlists, localTracks, catalogs) = await (
      ref.read(playlistsControllerProvider.future),
      ref.read(libraryTracksProvider.future),
      ref.read(catalogPlaylistsProvider.future),
    ).wait;
    if (!context.mounted) return false;
    final playlistId = await showAppDialog<String>(
      context: context,
      builder: (_) => _CollectionPlaylistPicker(
        playlists: playlists,
        tracks: localTracks,
        catalogs: catalogs,
        initialName: initialPlaylistName ?? '',
      ),
    );
    if (playlistId == null || !context.mounted) return false;
    final added = await ref
        .read(playlistsControllerProvider.notifier)
        .addRemoteTracksToPlaylist(playlistId, tracks, download: false);
    if (!context.mounted) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? strings.songsAlreadyInPlaylist
              : strings.songsAddedToPlaylist(added),
        ),
      ),
    );
    return true;
  } catch (error) {
    debugPrint('Could not add collection to playlist: $error');
    if (!context.mounted) return false;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.playlistAddFailed)));
    return false;
  }
}

class _CollectionPlaylistPicker extends ConsumerStatefulWidget {
  const _CollectionPlaylistPicker({
    required this.playlists,
    required this.tracks,
    required this.catalogs,
    required this.initialName,
  });

  final List<Playlist> playlists;
  final List<LocalTrack> tracks;
  final List<CatalogPlaylist> catalogs;
  final String initialName;

  @override
  ConsumerState<_CollectionPlaylistPicker> createState() =>
      _CollectionPlaylistPickerState();
}

class _CollectionPlaylistPickerState
    extends ConsumerState<_CollectionPlaylistPicker> {
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    return PlaylistPickerDialog(
      title: strings.choosePlaylist,
      playlists: widget.playlists,
      tracks: widget.tracks,
      catalogPlaylists: widget.catalogs,
      showCreateButton: true,
      createTooltip: strings.newPlaylist,
      emptyMessage: strings.noLocalPlaylists,
      onCreatePlaylist: _creating ? null : _createPlaylist,
    );
  }

  Future<void> _createPlaylist() async {
    if (_creating) return;
    setState(() => _creating = true);
    final strings = ref.read(appStringsProvider);
    try {
      final name = await showAppDialog<String>(
        context: context,
        builder: (_) => CreatePlaylistDialog(
          strings: strings,
          initialName: widget.initialName,
        ),
      );
      if (!mounted || name == null || name.trim().isEmpty) return;
      final playlist = await ref
          .read(playlistsControllerProvider.notifier)
          .create(name);
      if (!mounted || playlist == null) return;
      Navigator.of(context).pop(playlist.id);
    } catch (error) {
      debugPrint('Could not create collection playlist: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.playlistAddFailed)));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }
}
