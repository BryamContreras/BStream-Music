import 'package:bstream_music/services/recommendations/recommendations.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'caps related browse enrichment without shrinking the next queue',
    () async {
      final related = _RecordingRelated();
      final catalog = InnerTubeRecommendationCatalog(
        related: related,
        artists: _EmptyArtistLookup(),
      );
      final seed = RecommendationSeed(
        trackKey: 'AbCdEfGhIj1',
        trackId: 'AbCdEfGhIj1',
        videoId: 'AbCdEfGhIj1',
        title: 'Seed',
        artists: const <String>['Artist'],
        source: PlaybackEventSource.streaming,
        playCount: 1,
        totalListenedMs: 30000,
        completedCount: 0,
        lastPlayedAt: DateTime.utc(2026, 8, 21),
      );

      final result = await catalog.getCandidates(seed, limit: 30);

      expect(related.nextLimit, 30);
      expect(related.relatedLimit, InnerTubeSearchService.maxResults);
      expect(result.tracks.map((track) => track.videoId), <String?>[
        'NextVideo01',
        'Related0001',
      ]);
    },
  );
}

class _RecordingRelated implements YouTubeMusicRelated {
  int? nextLimit;
  int? relatedLimit;

  @override
  Future<InnerTubeNextPage> getNext(
    String videoId, {
    bool radio = false,
    int limit = innerTubeDetailResultLimit,
  }) async {
    nextLimit = limit;
    return InnerTubeNextPage(
      songs: <InnerTubeSong>[
        InnerTubeSong(
          videoId: videoId,
          title: 'Seed',
          artists: const <String>['Artist'],
        ),
        InnerTubeSong(
          videoId: 'NextVideo01',
          title: 'Next',
          artists: <String>['Artist'],
        ),
      ],
      relatedBrowseId: 'MPTRrelated001',
    );
  }

  @override
  Future<InnerTubeRelatedPage> getRelated(
    String browseId, {
    int limit = 20,
  }) async {
    relatedLimit = limit;
    return InnerTubeRelatedPage(
      songs: <InnerTubeSong>[
        InnerTubeSong(
          videoId: 'Related0001',
          title: 'Related',
          artists: <String>['Artist'],
        ),
      ],
      albums: const <InnerTubeAlbum>[],
      artists: const <InnerTubeArtist>[],
      collections: const <InnerTubeHomeCollection>[],
    );
  }

  @override
  Future<InnerTubeNextPage> getNextContinuation(
    String continuation, {
    int limit = innerTubeDetailResultLimit,
  }) => throw UnimplementedError();

  @override
  Future<InnerTubeRelatedPage> getRelatedContinuation(
    String continuation, {
    int limit = 20,
  }) => throw UnimplementedError();
}

class _EmptyArtistLookup implements YouTubeMusicArtistLookup {
  @override
  Future<List<InnerTubeAlbum>> getArtistReleases(
    String artistBrowseId, {
    int limit = 20,
  }) async => const <InnerTubeAlbum>[];
}
