import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/playlist.dart';
import '../providers/playlist_artwork_providers.dart';
import 'artwork_header_snapshot.dart';
import 'playlist_artwork.dart';
import 'source_image.dart';

/// The same saved cover is used in the library, header, backdrop and picker.
/// Missing files fall back to the existing rotation without extra image loads.
List<PlaylistArtworkSource> playlistArtworkSourcesFor(
  WidgetRef ref,
  Playlist playlist,
  List<PlaylistArtworkSource> Function() automaticSources,
) {
  final fileName = playlist.customArtworkFileName;
  if (fileName == null) return automaticSources();
  final path = ref.watch(playlistArtworkPathProvider(fileName)).asData?.value;
  return path == null
      ? automaticSources()
      : [PlaylistArtworkSource(source: path)];
}

/// A bounded, shared cover for library rows, the picker and playlist headers.
///
/// A single cover fills the square. Two or three covers repeat existing cells
/// to complete the same four-cell grid without empty areas or extra requests.
/// Image decoding uses each cell's physical display size and the shared cache.
class PlaylistArtworkMosaic extends StatelessWidget {
  const PlaylistArtworkMosaic({
    required this.sources,
    required this.size,
    this.borderRadius = 8,
    this.cacheWidth,
    this.onFrame,
    super.key,
  }) : assert(size > 0),
       assert(borderRadius >= 0),
       assert(cacheWidth == null || cacheWidth > 0);

  final List<PlaylistArtworkSource> sources;
  final double size;
  final double borderRadius;

  /// The physical decode width for each individual cover, when specified.
  final int? cacheWidth;
  final ArtworkSnapshotFrame? onFrame;

  @override
  Widget build(BuildContext context) {
    final covers = sources
        .take(playlistArtworkSourceLimit)
        .toList(growable: false);
    final cellSize = covers.length > 1 ? size / 2 : size;
    final decodeWidth =
        cacheWidth ??
        (cellSize * MediaQuery.devicePixelRatioOf(context)).ceil().clamp(
          1,
          1280,
        );

    Widget imageAt(int index) {
      final artwork = covers[index % covers.length];
      return SourceImage(
        source: artwork.source,
        fallbackSource: artwork.fallbackSource,
        cacheWidth: decodeWidth,
        fallback: onFrame == null
            ? const _PlaylistArtworkFallback()
            : Builder(
                builder: (context) {
                  onFrame!(null, index: index);
                  return const _PlaylistArtworkFallback();
                },
              ),
        imageBuilder: onFrame == null
            ? null
            : (context, image) {
                onFrame!(image.image, index: index);
                return image;
              },
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox.square(
        dimension: size,
        child: covers.isEmpty
            ? const _PlaylistArtworkFallback()
            : covers.length == 1
            ? imageAt(0)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var row = 0; row < 2; row++)
                    Expanded(
                      child: Row(
                        // Cover needs tight square bounds: otherwise a wide
                        // image keeps its intrinsic height and leaves gaps.
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var column = 0; column < 2; column++)
                            Expanded(child: imageAt(row * 2 + column)),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _PlaylistArtworkFallback extends StatelessWidget {
  const _PlaylistArtworkFallback();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF202520),
      child: Center(child: Icon(Icons.queue_music_rounded, size: 24)),
    );
  }
}
