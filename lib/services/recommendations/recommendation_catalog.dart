import '../youtube_music/innertube_search_service.dart';
import 'recommendation_storage_models.dart';

class SeedRecommendationCandidates {
  SeedRecommendationCandidates({
    required List<RelatedTrackCandidate> tracks,
    this.automixPlaylistId,
  }) : tracks = List<RelatedTrackCandidate>.unmodifiable(tracks);

  final List<RelatedTrackCandidate> tracks;
  final String? automixPlaylistId;
}

class RecommendationRelease {
  RecommendationRelease({
    required this.browseId,
    required this.title,
    required List<String> artists,
    List<String?> artistBrowseIds = const <String?>[],
    this.year,
    this.type,
    this.thumbnailUrl,
    this.playlistId,
  }) : artists = List<String>.unmodifiable(artists),
       artistBrowseIds = List<String?>.unmodifiable(artistBrowseIds);

  final String browseId;
  final String title;
  final List<String> artists;
  final List<String?> artistBrowseIds;
  final String? year;
  final String? type;
  final String? thumbnailUrl;
  final String? playlistId;
}

/// Network boundary for YouTube-supplied candidate pools.
abstract interface class RecommendationCatalog {
  Future<SeedRecommendationCandidates> getCandidates(
    RecommendationSeed seed, {
    required int limit,
  });

  Future<List<RecommendationRelease>> getArtistReleases(
    String artistBrowseId, {
    required int limit,
  });
}

/// Maps the low-level InnerTube `/next` and related browse responses to the
/// storage-neutral recommendation domain.
class InnerTubeRecommendationCatalog implements RecommendationCatalog {
  const InnerTubeRecommendationCatalog({
    required this.related,
    required this.artists,
  });

  final YouTubeMusicRelated related;
  final YouTubeMusicArtistLookup artists;

  @override
  Future<SeedRecommendationCandidates> getCandidates(
    RecommendationSeed seed, {
    required int limit,
  }) async {
    final videoId = seed.videoId?.trim();
    if (videoId == null || videoId.isEmpty) {
      return SeedRecommendationCandidates(
        tracks: const <RelatedTrackCandidate>[],
      );
    }

    final next = await related.getNext(videoId, radio: true, limit: limit);
    var songs = next.songs;
    final relatedBrowseId = next.relatedBrowseId?.trim();
    if (relatedBrowseId != null && relatedBrowseId.isNotEmpty) {
      try {
        // `/next` supports the larger detail-page limit, while `/browse`
        // related shelves intentionally cap one page at [maxResults]. Keep
        // enriching a 30-item radio request instead of turning the range
        // mismatch into a swallowed RangeError.
        final relatedLimit = limit > InnerTubeSearchService.maxResults
            ? InnerTubeSearchService.maxResults
            : limit;
        final page = await related.getRelated(
          relatedBrowseId,
          limit: relatedLimit,
        );
        songs = <InnerTubeSong>[...songs, ...page.songs];
      } on Object {
        // `/next` is already a valid candidate pool. Related shelves enrich it
        // but must never make a successful radio request unusable.
      }
    }

    final unique = <String, RelatedTrackCandidate>{};
    for (var index = 0; index < songs.length; index += 1) {
      final song = songs[index];
      if (song.videoId == videoId) {
        continue;
      }
      final candidate = _candidateFromSong(song, index);
      unique.putIfAbsent(candidate.trackKey, () => candidate);
      if (unique.length >= limit) {
        break;
      }
    }
    return SeedRecommendationCandidates(
      tracks: unique.values.toList(growable: false),
      automixPlaylistId: _nonEmpty(next.automixPlaylistId),
    );
  }

  @override
  Future<List<RecommendationRelease>> getArtistReleases(
    String artistBrowseId, {
    required int limit,
  }) async {
    final albums = await artists.getArtistReleases(
      artistBrowseId,
      limit: limit,
    );
    return List<RecommendationRelease>.unmodifiable(
      albums.map(
        (album) => RecommendationRelease(
          browseId: album.browseId,
          title: album.title,
          artists: album.artists,
          artistBrowseIds: album.artistBrowseIds,
          year: album.year,
          type: album.type,
          thumbnailUrl: album.thumbnailUrl,
          playlistId: album.playlistId,
        ),
      ),
    );
  }
}

RelatedTrackCandidate _candidateFromSong(InnerTubeSong song, int rank) {
  return RelatedTrackCandidate(
    trackId: song.videoId,
    videoId: song.videoId,
    title: song.title,
    artists: song.artists,
    artistBrowseIds: song.artistBrowseIds,
    album: song.album,
    thumbnailUrl: song.thumbnailUrl,
    durationMs: song.duration?.inMilliseconds,
    rank: rank,
  );
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
