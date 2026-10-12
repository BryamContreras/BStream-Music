import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/player/recommendation_playback_item.dart';
import 'package:bstream_music/features/music/presentation/providers/player/related_radio_queue_extender.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
