import 'package:flutter/material.dart';

import '../../../../core/utils/image_source.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';

class PlaylistPickerDialog extends StatelessWidget {
  const PlaylistPickerDialog({
    required this.title,
    required this.playlists,
    required this.tracks,
    super.key,
  });

  final String title;
  final List<Playlist> playlists;
  final List<LocalTrack> tracks;

  @override
  Widget build(BuildContext context) {
    final tracksById = {for (final track in tracks) track.id: track};
    final selectablePlaylists = playlists
        .where((playlist) => !playlist.isFavorites)
        .toList(growable: false);

    return SimpleDialog(
      title: Text(title),
      children: selectablePlaylists
          .map(
            (playlist) => SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(playlist.id),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: _PlaylistOption(
                playlist: playlist,
                thumbnailSources: _playlistThumbnailSources(
                  playlist,
                  tracksById,
                ),
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _PlaylistOption extends StatelessWidget {
  const _PlaylistOption({
    required this.playlist,
    required this.thumbnailSources,
  });

  final Playlist playlist;
  final List<String> thumbnailSources;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _PlaylistOptionCover(sources: thumbnailSources),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

class _PlaylistOptionCover extends StatelessWidget {
  const _PlaylistOptionCover({required this.sources});

  final List<String> sources;

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
            _PlaylistOptionImage(source: sources.first),
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
                      for (final source in underlay)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(1),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: _PlaylistOptionImage(source: source),
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
  const _PlaylistOptionImage({required this.source});

  final String source;

  @override
  Widget build(BuildContext context) {
    if (isNetworkImageSource(source)) {
      return Image.network(
        source,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const _PlaylistOptionFallback(),
      );
    }

    final file = imageFileFromSource(source);
    if (file == null || !file.existsSync()) {
      return const _PlaylistOptionFallback();
    }

    return Image.file(
      file,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const _PlaylistOptionFallback(),
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

List<String> _playlistThumbnailSources(
  Playlist playlist,
  Map<String, LocalTrack> tracksById,
) {
  final sources = playlist.trackIds
      .map((id) => tracksById[id])
      .whereType<LocalTrack>()
      .map(_trackThumbnailSource)
      .whereType<String>()
      .toSet()
      .toList(growable: false);

  if (sources.length <= 1) {
    return sources;
  }

  final start = playlist.id.hashCode.abs() % sources.length;
  return [
    ...sources.skip(start),
    ...sources.take(start),
  ].take(4).toList(growable: false);
}

String? _trackThumbnailSource(LocalTrack track) {
  final source = track.thumbnailPath ?? track.thumbnailUrl;
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }

  if (isNetworkImageSource(normalized)) {
    return normalized;
  }

  final file = imageFileFromSource(normalized);
  if (file == null || !file.existsSync()) {
    return null;
  }
  return file.path;
}
