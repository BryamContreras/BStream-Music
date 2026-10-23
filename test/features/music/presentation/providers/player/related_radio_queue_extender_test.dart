import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/presentation/providers/player/recommendation_playback_item.dart';
import 'package:bstream_music/features/music/presentation/providers/player/related_radio_queue_extender.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'local-only radio looks up its seed lazily once and shares pending work',
    () async {
      final service = _MetadataRelatedFake();
      final selected = RecommendationPlaybackItem(
        track: const TrackInfo(
          id: 'local-import',
          title: 'Local song',
          artist: 'Local artist',
          url: '',
        ),
        localTrack: LocalTrack(
          id: 'local-import',
          title: 'Local song',
          artist: 'Local artist',
          filePath: '/music/local-song.mp3',
          addedAt: DateTime.utc(2026),
        ),
      );
      final extend = buildMetadataRelatedRadioQueueExtender(
        search: service,
        related: service,
        selected: selected,
        initialQueue: [selected],
      );
      expect(service.queries, isEmpty);
      expect(service.radioRequests, isEmpty);

      final first = extend();
      final duplicate = extend();
      final firstPage = await first;
      expect(await duplicate, same(firstPage));
      expect(service.queries, ['Local song Local artist']);
      expect(service.radioRequests, ['SeedVideo01']);
      expect(firstPage.first, same(selected));
      expect(firstPage.map((item) => item.track.id), [
        'local-import',
        'Related0001',
      ]);

      final nextPage = await extend();
      expect(nextPage.map((item) => item.track.id), [
        'local-import',
        'Related0001',
        'Related0002',
      ]);
      expect(service.queries, hasLength(1));
      expect(service.radioRequests, hasLength(1));
      expect(service.continuationRequests, ['page-two']);
    },
  );

  test(
    'an unmatched local-only lookup keeps the original queue and is not repeated',
    () async {
      final service = _MetadataRelatedFake(results: const []);
      const selected = RecommendationPlaybackItem(
        track: TrackInfo(
          id: 'unmatched-import',
          title: 'Unknown song',
          artist: 'Artist',
          url: '',
        ),
      );
      final extend = buildMetadataRelatedRadioQueueExtender(
        search: service,
        related: service,
        selected: selected,
        initialQueue: [selected],
      );

      expect(await extend(), [selected]);
      expect(await extend(), [selected]);
      expect(service.queries, ['Unknown song Artist']);
      expect(service.radioRequests, isEmpty);
    },
  );

  test(
    'does not append a downloaded seed missing from old catalog metadata',
    () async {
      final related = _RelatedRadioFake();
      final selected = RecommendationPlaybackItem(
        track: const TrackInfo(
          id: 'downloaded-entry',
          title: 'Downloaded song',
          artist: 'Artist',
          url: '',
        ),
        localTrack: LocalTrack(
          id: 'downloaded-entry',
          title: 'Downloaded song',
          artist: 'Artist',
          filePath: '/music/seed.mp3',
          sourceId: 'SeedVideo01',
          addedAt: DateTime.utc(2026),
        ),
      );
      final extend = buildRelatedRadioQueueExtender(
        related: related,
        seedVideoId: relatedRadioVideoId(selected)!,
        initialQueue: [selected],
      );

      final expanded = await extend();

      expect(expanded.map((item) => item.track.id), [
        'downloaded-entry',
        'Related0001',
      ]);
      expect(expanded.first, same(selected));
      expect(related.radioRequests, ['SeedVideo01']);
    },
  );

  test('keeps the seed and deduplicates related radio across pages', () async {
    final related = _RelatedRadioFake();
    final selected = RecommendationPlaybackItem(
      track: const TrackInfo(
        id: 'SeedVideo01',
        title: 'Selected result',
        artist: 'Artist',
        url: 'https://www.youtube.com/watch?v=SeedVideo01',
      ),
    );
    final extend = buildRelatedRadioQueueExtender(
      related: related,
      seedVideoId: 'SeedVideo01',
      initialQueue: [selected],
    );

    final firstPage = await extend();
    expect(firstPage.map((item) => item.track.id), [
      'SeedVideo01',
      'Related0001',
    ]);
    expect(identical(firstPage.first, selected), isTrue);
    expect(related.radioRequests, ['SeedVideo01']);
    expect(related.continuationRequests, isEmpty);

    final secondPage = await extend();
    expect(secondPage.map((item) => item.track.id), [
      'SeedVideo01',
      'Related0001',
      'Related0002',
    ]);
    expect(related.continuationRequests, ['page-two']);

    expect((await extend()).length, 3);
    expect(related.radioRequests, hasLength(1));
    expect(related.continuationRequests, hasLength(1));
  });
}

final class _RelatedRadioFake implements YouTubeMusicRelated {
  final radioRequests = <String>[];
  final continuationRequests = <String>[];

  @override
  Future<InnerTubeNextPage> getNext(
    String videoId, {
    bool radio = false,
    int limit = innerTubeDetailResultLimit,
  }) async {
    expect(radio, isTrue);
    expect(limit, 30);
    radioRequests.add(videoId);
    return InnerTubeNextPage(
      songs: [_song('SeedVideo01'), _song('Related0001')],
      continuation: 'page-two',
    );
  }

  @override
  Future<InnerTubeNextPage> getNextContinuation(
    String continuation, {
    int limit = innerTubeDetailResultLimit,
  }) async {
    expect(limit, 30);
    continuationRequests.add(continuation);
    return InnerTubeNextPage(
      songs: [_song('Related0001'), _song('Related0002')],
    );
  }

  @override
  Future<InnerTubeRelatedPage> getRelated(
    String browseId, {
    int limit = 20,
  }) async => InnerTubeRelatedPage(
    songs: const [],
    albums: const [],
    artists: const [],
    collections: const [],
  );

  @override
  Future<InnerTubeRelatedPage> getRelatedContinuation(
    String continuation, {
    int limit = 20,
  }) async => InnerTubeRelatedPage(
    songs: const [],
    albums: const [],
    artists: const [],
    collections: const [],
  );

  InnerTubeSong _song(String videoId) => InnerTubeSong(
    videoId: videoId,
    title: videoId,
    artists: const ['Artist'],
  );
}

final class _MetadataRelatedFake extends _RelatedRadioFake
    implements YouTubeMusicSearch {
  _MetadataRelatedFake({this.results});

  final List<InnerTubeSong>? results;
  final queries = <String>[];

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async {
    expect(limit, 5);
    queries.add(query);
    return results ??
        [
          InnerTubeSong(
            videoId: 'SeedVideo01',
            title: 'Local song',
            artists: ['Local artist'],
          ),
        ];
  }
}
