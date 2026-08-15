import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'maps a mixed 5 by 12 Home feed without resolving collections',
    () async {
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Para ti',
          items: [
            InnerTubeHomeSongItem(_song()),
            const InnerTubeHomeCollection(
              title: 'Mix diario',
              subtitle: 'Artista, Invitado',
              thumbnailUrl: 'https://img.test/mix.jpg',
              browseId: 'RDTMAK5uy_mix',
              playlistId: 'RDTMAK5uy_mix',
              kind: InnerTubeHomeCollectionKind.mix,
            ),
            const InnerTubeHomeCollection(
              title: 'Novedades latinas',
              subtitle: 'Playlist',
              thumbnailUrl: 'https://img.test/playlist.jpg',
              browseId: 'VLPL_playlist',
              playlistId: 'PL_playlist',
              kind: InnerTubeHomeCollectionKind.playlist,
            ),
          ],
        ),
      ]);
      final container = _containerFor(source);

      final sections = await container.read(homeRecommendationsProvider.future);

      expect(source.homeCalls, 1);
      expect(source.searchCalls, 0);
      expect(source.collectionCalls, 0);
      expect(source.lastMaxSections, 5);
      expect(source.lastMaxItemsPerSection, 12);

      final section = sections.single;
      expect(section.title, 'Para ti');
      expect(section.items, hasLength(3));
      expect(section.items[0], isA<HomeRecommendationTrackItem>());
      expect(section.items[1], isA<HomeRecommendationCollectionItem>());
      expect(section.items[2], isA<HomeRecommendationCollectionItem>());

      final track = (section.items[0] as HomeRecommendationTrackItem).track;
      _expectMappedTrack(track);
      expect(section.tracks, [track]);

      final mix =
          (section.items[1] as HomeRecommendationCollectionItem).collection;
      expect(mix.title, 'Mix diario');
      expect(mix.subtitle, 'Artista, Invitado');
      expect(mix.thumbnailUrl, 'https://img.test/mix.jpg');
      expect(mix.browseId, 'RDTMAK5uy_mix');
      expect(mix.playlistId, 'RDTMAK5uy_mix');
      expect(mix.kind, HomeRecommendationCollectionKind.mix);
      expect(mix.isMix, isTrue);

      final playlist =
          (section.items[2] as HomeRecommendationCollectionItem).collection;
      expect(playlist.title, 'Novedades latinas');
      expect(playlist.browseId, 'VLPL_playlist');
      expect(playlist.playlistId, 'PL_playlist');
      expect(playlist.kind, HomeRecommendationCollectionKind.playlist);
      expect(playlist.isMix, isFalse);
    },
  );

  test('keeps the legacy tracks constructor and filters mixed items', () {
    const first = TrackInfo(
      id: 'first-track',
      title: 'First',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=first-track',
    );
    const second = TrackInfo(
      id: 'second-track',
      title: 'Second',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=second-track',
    );
    final legacy = HomeRecommendationSection(
      title: 'Legacy',
      tracks: [first, second],
    );
    final mixed = HomeRecommendationSection.items(
      title: 'Mixed',
      items: [
        HomeRecommendationTrackItem(first),
        const HomeRecommendationCollectionItem(
          HomeRecommendationCollection(
            title: 'Mix',
            browseId: 'RD_mix',
            kind: HomeRecommendationCollectionKind.mix,
          ),
        ),
        HomeRecommendationTrackItem(second),
      ],
    );

    expect(legacy.items, everyElement(isA<HomeRecommendationTrackItem>()));
    expect(legacy.tracks, [first, second]);
    expect(mixed.tracks, [first, second]);
  });

  test('resolves and caches collection tracks by browse ID', () async {
    final source = _FakeHomeSearch(const [])
      ..collectionSongs['VLPL_collection'] = [
        _song(videoId: 'collection-song', title: 'Collection song'),
      ];
    final container = _containerFor(source);

    final first = await container.read(
      homeCollectionTracksProvider('VLPL_collection').future,
    );
    final second = await container.read(
      homeCollectionTracksProvider('VLPL_collection').future,
    );

    expect(source.collectionCalls, 1);
    expect(source.lastCollectionBrowseId, 'VLPL_collection');
    expect(source.lastCollectionLimit, innerTubeDetailResultLimit);
    expect(identical(first, second), isTrue);
    expect(first, hasLength(1));
    expect(first.single.id, 'collection-song');
    expect(first.single.title, 'Collection song');
    expect(first.single.metadataSource, TrackMetadataSource.youtubeMusic);
  });

  test('propagates collection resolution errors for the UI', () async {
    final failure = StateError('collection unavailable');
    final source = _FakeHomeSearch(const [])..collectionError = failure;
    final container = _containerFor(source);

    await expectLater(
      container.read(homeCollectionTracksProvider('VLPL_broken').future),
      throwsA(same(failure)),
    );

    expect(source.collectionCalls, 1);
  });

  test('propagates a Home failure without automatically retrying', () async {
    final failure = StateError('offline');
    final source = _FakeHomeSearch(const [])..homeError = failure;
    final container = _containerFor(source);

    await expectLater(
      container.read(homeRecommendationsProvider.future),
      throwsA(same(failure)),
    );

    expect(source.homeCalls, 1);
    expect(source.collectionCalls, 0);
  });

  test('returns no Home sections for a search-only implementation', () async {
    final source = _SearchOnly();
    final container = ProviderContainer(
      overrides: [youtubeMusicSearchProvider.overrideWithValue(source)],
    );
    addTearDown(container.dispose);

    final sections = await container.read(homeRecommendationsProvider.future);

    expect(sections, isEmpty);
    expect(source.searchCalls, 0);
  });
}

ProviderContainer _containerFor(_FakeHomeSearch source) {
  final container = ProviderContainer(
    overrides: [youtubeMusicSearchProvider.overrideWithValue(source)],
  );
  addTearDown(container.dispose);
  return container;
}

InnerTubeSong _song({
  String videoId = 'AbCdEfGhIj1',
  String title = 'Una cancion',
}) {
  return InnerTubeSong(
    videoId: videoId,
    title: title,
    artists: const ['Artista', 'Invitado'],
    album: 'Un album',
    duration: const Duration(minutes: 3, seconds: 12),
    thumbnailUrl: 'https://img.test/catalog.jpg',
  );
}

void _expectMappedTrack(TrackInfo track) {
  expect(track.id, 'AbCdEfGhIj1');
  expect(track.title, 'Una cancion');
  expect(track.artist, 'Artista, Invitado');
  expect(track.artists, const ['Artista', 'Invitado']);
  expect(track.album, 'Un album');
  expect(track.catalogThumbnailUrl, 'https://img.test/catalog.jpg');
  expect(track.thumbnailUrl, contains('AbCdEfGhIj1'));
  expect(track.url, 'https://www.youtube.com/watch?v=AbCdEfGhIj1');
  expect(track.metadataSource, TrackMetadataSource.youtubeMusic);
}

class _FakeHomeSearch
    implements
        YouTubeMusicSearch,
        YouTubeMusicHome,
        YouTubeMusicCollectionLookup {
  _FakeHomeSearch(this.sections);

  final List<InnerTubeHomeSection> sections;
  final Map<String, List<InnerTubeSong>> collectionSongs = {};
  Object? homeError;
  Object? collectionError;
  int homeCalls = 0;
  int searchCalls = 0;
  int collectionCalls = 0;
  int? lastMaxSections;
  int? lastMaxItemsPerSection;
  int? lastCollectionLimit;
  String? lastCollectionBrowseId;

  @override
  Future<List<InnerTubeHomeSection>> getHome({
    int maxSections = 2,
    int maxItemsPerSection = 8,
  }) async {
    homeCalls++;
    lastMaxSections = maxSections;
    lastMaxItemsPerSection = maxItemsPerSection;
    final failure = homeError;
    if (failure != null) {
      throw failure;
    }
    return sections;
  }

  @override
  Future<List<InnerTubeSong>> getCollectionSongs(
    String browseId, {
    int limit = 20,
  }) async {
    collectionCalls++;
    lastCollectionBrowseId = browseId;
    lastCollectionLimit = limit;
    final failure = collectionError;
    if (failure != null) {
      throw failure;
    }
    return collectionSongs[browseId] ?? const [];
  }

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async {
    searchCalls++;
    return const [];
  }
}

class _SearchOnly implements YouTubeMusicSearch {
  int searchCalls = 0;

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async {
    searchCalls++;
    return const [];
  }
}
