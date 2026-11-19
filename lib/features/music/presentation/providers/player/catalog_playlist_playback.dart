import '../../../domain/entities/catalog_playlist.dart';
import '../../../domain/entities/catalog_track.dart';
import '../../../domain/entities/local_track.dart';
import '../../../domain/entities/playlist_entry.dart';
import '../../../domain/entities/track_info.dart';
import '../local_track_index_provider.dart';
import 'catalog_playback_item.dart';

/// Shared resolution for playlist presentation and playback. Unavailable
/// occurrences stay visible, but do not become playable queue items.
class CatalogPlaylistResolvedEntry {
  const CatalogPlaylistResolvedEntry({required this.entry, this.playback});

  final PlaylistEntry entry;
  final CatalogPlaybackItem? playback;
}

List<CatalogPlaylistResolvedEntry> catalogPlaylistResolvedEntries(
  CatalogPlaylist playlist,
  Iterable<LocalTrack> libraryTracks, {
  LocalTrackIndex? libraryIndex,
}) {
  final resolver = _CatalogPlaylistResolver(
    playlist,
    libraryIndex ?? LocalTrackIndex(libraryTracks, indexSourceUrls: false),
  );
  return List<CatalogPlaylistResolvedEntry>.unmodifiable([
    for (final entry in resolver.entries)
      CatalogPlaylistResolvedEntry(
        entry: entry,
        playback: resolver.resolve(entry),
      ),
  ]);
}

List<CatalogPlaybackItem> catalogPlaylistPlaybackItems(
  CatalogPlaylist playlist,
  Iterable<LocalTrack> libraryTracks,
) {
  final resolver = _CatalogPlaylistResolver(
    playlist,
    LocalTrackIndex(libraryTracks, indexSourceUrls: false),
  );
  final result = <CatalogPlaybackItem>[];
  for (final entry in resolver.entries) {
    final item = resolver.resolve(entry);
    if (item != null) result.add(item);
  }
  return List<CatalogPlaybackItem>.unmodifiable(result);
}

class _CatalogPlaylistResolver {
  _CatalogPlaylistResolver(CatalogPlaylist playlist, this.libraryIndex) {
    entries = playlist.entries.where((entry) => !entry.isDeleted).toList()
      ..sort((left, right) {
        final byPosition = left.position.compareTo(right.position);
        return byPosition != 0 ? byPosition : left.id.compareTo(right.id);
      });
  }

  final LocalTrackIndex libraryIndex;
  late final List<PlaylistEntry> entries;

  CatalogPlaybackItem? resolve(PlaylistEntry entry) {
    final catalog = entry.track;
    final rawVideoId = entry.videoId?.trim();
    final videoId = rawVideoId == null || rawVideoId.isEmpty
        ? catalog.youtubeVideoId
        : rawVideoId;
    final local = libraryIndex.forPlaylist(
      localId: entry.localTrackId,
      sourceId: videoId,
    );
    final remote = videoId == null
        ? null
        : trackInfoFromCatalogTrack(catalog, videoId: videoId);
    if (local == null && remote == null) {
      return null;
    }
    return CatalogPlaybackItem(
      entryId: entry.id,
      localTrack: local,
      remoteTrack: remote,
    );
  }
}

TrackInfo trackInfoFromCatalogTrack(CatalogTrack track, {String? videoId}) {
  videoId ??= track.youtubeVideoId;
  if (videoId == null || videoId.isEmpty) {
    throw ArgumentError.value(
      track.key,
      'track',
      'A remote playback item requires a YouTube video id.',
    );
  }
  final sourceUrl = track.sourceUrl?.trim();
  final artists = track.artists
      .map((artist) => artist.trim())
      .where((artist) => artist.isNotEmpty)
      .toList(growable: false);
  return TrackInfo(
    id: videoId,
    title: track.title,
    artist: artists.isEmpty ? '' : artists.join(', '),
    artists: artists,
    artistBrowseIds: track.artistBrowseIds,
    album: track.album,
    duration: track.duration,
    thumbnailUrl: track.thumbnailUrl,
    catalogThumbnailUrl: track.thumbnailUrl,
    url: sourceUrl == null || sourceUrl.isEmpty
        ? 'https://www.youtube.com/watch?v=$videoId'
        : sourceUrl,
    metadataSource: TrackMetadataSource.youtubeMusic,
  );
}
