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
import 'source_image.dart';

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
    super.key,
  });

  final String title;
  final List<Playlist> playlists;
  final List<LocalTrack> tracks;
  final List<CatalogPlaylist> catalogPlaylists;

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
      title: Text(
        title,
        style: TextStyle(color: AppColors.contentHeadingFor(context)),
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
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: selectablePlaylists.length,
            itemBuilder: (context, index) {
              final playlist = selectablePlaylists[index];
              return SimpleDialogOption(
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
        _PlaylistOptionCover(sources: thumbnailSources),
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

class _PlaylistOptionCover extends StatelessWidget {
  const _PlaylistOptionCover({required this.sources});

  final List<PlaylistArtworkSource> sources;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return const _PlaylistOptionFallback();
    }

    final underlay = sources.skip(1).take(3).toList(growable: false);

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _PlaylistOptionImage(artwork: sources.first, cacheWidth: 96),
            if (underlay.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 16,
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xAA000000)),
                  child: Row(
                    children: [
                      for (final artwork in underlay)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(1),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: _PlaylistOptionImage(
                                artwork: artwork,
                                cacheWidth: 64,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistOptionImage extends StatelessWidget {
  const _PlaylistOptionImage({required this.artwork, required this.cacheWidth});

  final PlaylistArtworkSource artwork;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    return SourceImage(
      source: artwork.source,
      fallbackSource: artwork.fallbackSource,
      cacheWidth: cacheWidth,
      fallback: const _PlaylistOptionFallback(),
    );
  }
}

class _PlaylistOptionFallback extends StatelessWidget {
  const _PlaylistOptionFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(color: Color(0xFF202520)),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Icon(Icons.queue_music_rounded, size: 22),
      ),
    );
  }
}

List<PlaylistArtworkSource> _playlistThumbnailSources(
  Playlist playlist,
  Map<String, LocalTrack> tracksById, {
  CatalogPlaylist? catalog,
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
  );
}
