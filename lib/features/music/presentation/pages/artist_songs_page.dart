import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../data/datasources/remote_music_datasource.dart';
import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import 'remote_collection_detail_page.dart';

final artistSongsProvider = FutureProvider.autoDispose
    .family<InnerTubeArtistSongsDetail, InnerTubeBrowseTarget>((ref, target) {
      final service = ref.watch(youtubeMusicSearchProvider);
      if (service is! YouTubeMusicArtistSongsLookup) {
        throw UnsupportedError('Artist songs are not available.');
      }
      return (service as YouTubeMusicArtistSongsLookup).getArtistSongs(target);
    });

final _artistSongTracksProvider = Provider.autoDispose
    .family<AsyncValue<List<TrackInfo>>, InnerTubeBrowseTarget>((ref, target) {
      return ref
          .watch(artistSongsProvider(target))
          .whenData(
            (detail) => detail.songs
                .map(trackInfoFromInnerTubeSong)
                .toList(growable: false),
          );
    });

class ArtistSongsPage extends ConsumerWidget {
  const ArtistSongsPage({
    required this.artistBrowseId,
    required this.artistName,
    required this.target,
    required this.onOpenPlayer,
    this.artistThumbnailUrl,
    super.key,
  });

  final String artistBrowseId;
  final String artistName;
  final String? artistThumbnailUrl;
  final InnerTubeBrowseTarget target;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final detail = ref.watch(artistSongsProvider(target)).value;
    final String? songCountLabel;
    if (detail == null) {
      songCountLabel = null;
    } else if (detail.isComplete) {
      songCountLabel = strings.collectionSongCount(
        detail.totalSongCount ?? detail.songs.length,
      );
    } else if (detail.totalSongCount case final int total) {
      songCountLabel = strings.artistSongsLoadedCount(
        detail.songs.length,
        total,
      );
    } else {
      songCountLabel = strings.artistSongsPartialCount(detail.songs.length);
    }

    return RemoteCollectionDetailPage(
      key: const ValueKey('artist-songs-page'),
      title: artistName,
      subtitle: strings.artistSongs,
      artworkSource: artistThumbnailUrl,
      fallbackIcon: Icons.person_rounded,
      queueSourceId: 'artist:$artistBrowseId:songs',
      tracksProvider: _artistSongTracksProvider(target),
      songCountLabel: songCountLabel,
      emptyMessage: strings.artistWithoutSongs,
      errorMessage: strings.artistSongsLoadError,
      onRetry: () => ref.invalidate(artistSongsProvider(target)),
      onOpenPlayer: onOpenPlayer,
    );
  }
}
