import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dialog.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../domain/entities/catalog_playlist.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';
import '../providers/app_strings.dart';
import 'playlist_artwork.dart';
import 'playlist_artwork_mosaic.dart';

/// The shared playlist-name form used by the Library and collection actions.
/// An optional initial name is only a suggestion; the user can edit or clear
/// it before confirming.
class CreatePlaylistDialog extends StatefulWidget {
  const CreatePlaylistDialog({
    required this.strings,
    this.initialName = '',
    super.key,
  });

  final AppStrings strings;
  final String initialName;

  @override
  State<CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<CreatePlaylistDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppAlertDialog(
      title: Text(widget.strings.newPlaylist),
      content: TextField(
        key: const ValueKey('create-playlist-name'),
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.strings.name),
        onSubmitted: _closeWithName,
      ),
      actions: [
        TextButton(
          key: const ValueKey('create-playlist-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.strings.cancel),
        ),
        FilledButton.icon(
          key: const ValueKey('create-playlist-confirm'),
          icon: const Icon(Icons.check_rounded),
          label: Text(widget.strings.create),
          onPressed: () => _closeWithName(_controller.text),
        ),
      ],
    );
  }

  void _closeWithName(String value) {
    Navigator.of(context).pop(value.trim());
  }
}

class PlaylistPickerDialog extends StatelessWidget {
  const PlaylistPickerDialog({
    required this.title,
    required this.playlists,
    required this.tracks,
    this.catalogPlaylists = const <CatalogPlaylist>[],
    this.showCreateButton = false,
    this.onCreatePlaylist,
    this.createTooltip,
    this.emptyMessage,
    this.artworkRotationSeed,
    super.key,
  });

  final String title;
  final List<Playlist> playlists;
  final List<LocalTrack> tracks;
  final List<CatalogPlaylist> catalogPlaylists;
  final bool showCreateButton;
  final VoidCallback? onCreatePlaylist;
  final String? createTooltip;
  final String? emptyMessage;
  final int? artworkRotationSeed;

  @override
  Widget build(BuildContext context) {
    final tracksById = {for (final track in tracks) track.id: track};
    final catalogsById = <String, CatalogPlaylist>{
      for (final catalog in catalogPlaylists) catalog.playlist.id: catalog,
    };
    final selectablePlaylists = playlists
        .where((playlist) => !playlist.isFavorites)
        .toList(growable: false);

    return AppAlertDialog(
      key: const ValueKey('playlist-picker-dialog'),
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(color: AppColors.contentHeadingFor(context)),
            ),
          ),
          if (showCreateButton)
            IconButton(
              key: const ValueKey('playlist-picker-create'),
              tooltip: createTooltip,
              icon: const Icon(Icons.add_rounded),
              onPressed: onCreatePlaylist,
            ),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 420,
          maxHeight: math.min(480, MediaQuery.sizeOf(context).height * 0.65),
        ),
        child: SizedBox(
          // AlertDialog measures its content intrinsically. A viewport cannot
          // provide intrinsic dimensions, so give the lazy list a finite width
          // while still allowing the dialog constraints to shrink it on mobile.
          width: 420,
          child: selectablePlaylists.isEmpty && emptyMessage != null
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(emptyMessage!),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: selectablePlaylists.length,
                  itemBuilder: (context, index) {
                    final playlist = selectablePlaylists[index];
                    return SimpleDialogOption(
                      key: ValueKey('playlist-picker-option-${playlist.id}'),
                      onPressed: () => Navigator.of(context).pop(playlist.id),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: _PlaylistOption(
                        playlist: playlist,
                        thumbnailSources: _playlistThumbnailSources(
                          playlist,
                          tracksById,
                          catalog: catalogsById[playlist.id],
                          rotationSeed: artworkRotationSeed,
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

class _PlaylistOption extends StatelessWidget {
  const _PlaylistOption({
    required this.playlist,
    required this.thumbnailSources,
  });

  final Playlist playlist;
  final List<PlaylistArtworkSource> thumbnailSources;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        PlaylistArtworkMosaic(sources: thumbnailSources, size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: MarqueeText(
            playlist.name,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.contentTitleFor(context),
            ),
          ),
        ),
      ],
    );
  }
}

List<PlaylistArtworkSource> _playlistThumbnailSources(
  Playlist playlist,
  Map<String, LocalTrack> tracksById, {
  CatalogPlaylist? catalog,
  int? rotationSeed,
}) {
  final candidates = catalog == null
      ? playlist.trackIds
            .map((id) => tracksById[id])
            .whereType<LocalTrack>()
            .map(preferredLocalPlaylistArtworkSource)
      : catalog.entries.where((entry) => !entry.isDeleted).map((entry) {
          return preferredCatalogPlaylistArtworkSource(
            entry.track,
            localTrack: tracksById[entry.localTrackId],
          );
        });
  return rotatingPlaylistArtworkSources(
    playlistId: playlist.id,
    candidates: candidates,
    rotationSeed: rotationSeed,
  );
}
