import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/recommendations/recommendations.dart';
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

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

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

  test('does not invent a duration omitted by a Home recommendation', () async {
    final source = _FakeHomeSearch([
      InnerTubeHomeSection(
        title: 'Seleccion rapida',
        songs: [
          InnerTubeSong(
            videoId: 'AbCdEfGhIj1',
            title: 'Sin duracion en el feed',
            artists: const ['Artista'],
          ),
        ],
      ),
    ]);
    final container = _containerFor(source);

    final sections = await container.read(
      youtubeMusicHomeRecommendationsProvider.future,
    );

    expect(sections.single.tracks.single.duration, isNull);
    expect(source.homeCalls, 1);
    expect(source.searchCalls, 0);
    expect(source.collectionCalls, 0);
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

  test(
    'resolves personalized AutoMix through its watch-next radio queue',
    () async {
      final source = _FakeHomeSearch(const [])
        ..nextPages['AbCdEfGhIj1'] = InnerTubeNextPage(
          songs: [
            _song(videoId: 'NextSong001', title: 'Next song'),
            _song(videoId: 'NextSong002', title: 'Another song'),
          ],
        );
      final container = _containerFor(source);

      final tracks = await container.read(
        homeCollectionTracksProvider('VLRDAMVMAbCdEfGhIj1').future,
      );

      expect(source.nextCalls, 1);
      expect(source.lastNextVideoId, 'AbCdEfGhIj1');
      expect(source.lastNextRadio, isTrue);
      expect(source.collectionCalls, 0);
      expect(tracks.map((track) => track.id), ['NextSong001', 'NextSong002']);
    },
  );

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
      container.read(youtubeMusicHomeRecommendationsProvider.future),
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

    final sections = await container.read(
      youtubeMusicHomeRecommendationsProvider.future,
    );

    expect(sections, isEmpty);
    expect(source.searchCalls, 0);
  });

  test(
    'combined Home publishes fresh cache first then refreshes and appends generic Home',
    () async {
      final cachedFeed = _personalizedFeed(includeAllKinds: true);
      final refreshedFeed = _personalizedFeed(includeAllKinds: true);
      final refreshCompleter = Completer<PersonalizedRecommendationFeed>();
      final genericCompleter = Completer<List<HomeRecommendationSection>>();
      final source = _FakePersonalizedHomeFeedSource(
        CachedPersonalizedRecommendationFeed(
          feed: cachedFeed,
          isExpired: false,
        ),
      )..refreshCompleter = refreshCompleter;
      final container = ProviderContainer(
        overrides: [
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
          personalizedHomeFeedSourceProvider.overrideWithValue(source),
          youtubeMusicHomeRecommendationsProvider.overrideWith(
            (ref) => genericCompleter.future,
          ),
        ],
      );
      addTearDown(container.dispose);

      final cached = await container.read(homeRecommendationsProvider.future);

      expect(cached.map((section) => section.title), [
        'Seguir escuchando',
        'Porque escuchaste Semilla favorita',
        'Tus mixes',
        'Nuevos para ti',
        'Descubrimiento',
      ]);
      expect(cached.first.isContinueListening, isTrue);
      final downloaded =
          cached.first.items.single as HomeRecommendationTrackItem;
      expect(downloaded.localTrackId, 'download-row-id');
      expect(downloaded.track.id, 'AbCdEfGhIj1');
      expect(
        downloaded.track.url,
        'https://www.youtube.com/watch?v=AbCdEfGhIj1',
      );
      final mix = (cached[2].items.single as HomeRecommendationCollectionItem)
          .collection;
      final release =
          (cached[3].items.single as HomeRecommendationCollectionItem)
              .collection;
      expect(mix.kind, HomeRecommendationCollectionKind.mix);
      expect(release.kind, HomeRecommendationCollectionKind.album);

      await _eventually(() => source.refreshCalls == 1);
      expect(source.forceNetworkCalls, [false]);
      genericCompleter.complete([
        HomeRecommendationSection(
          title: 'YouTube Music',
          tracks: const [
            TrackInfo(
              id: 'AbCdEfGhIj1',
              title: 'Duplicada exacta',
              artist: 'YouTube',
              url: 'https://www.youtube.com/watch?v=AbCdEfGhIj1',
            ),
            TrackInfo(
              id: 'aBcDeFgHiJ1',
              title: 'ID con mayusculas distintas',
              artist: 'YouTube',
              url: 'https://www.youtube.com/watch?v=aBcDeFgHiJ1',
            ),
          ],
        ),
      ]);
      refreshCompleter.complete(refreshedFeed);
      await _eventually(
        () =>
            container.read(homeRecommendationsProvider).asData?.value.length ==
            6,
      );

      final combined = container.read(homeRecommendationsProvider).requireValue;
      expect(combined.last.title, 'YouTube Music');
      expect(combined.last.tracks.map((track) => track.id), ['aBcDeFgHiJ1']);
    },
  );

  test('empty cached feed still triggers background personalization', () async {
    final refreshed = _personalizedFeed();
    final source = _FakePersonalizedHomeFeedSource(
      CachedPersonalizedRecommendationFeed(
        feed: PersonalizedRecommendationFeed(
          generatedAt: DateTime.utc(2026),
          sections: const [],
        ),
        isExpired: false,
      ),
    )..refreshedFeed = refreshed;
    final container = _combinedContainer(source);

    final initial = await container.read(homeRecommendationsProvider.future);

    expect(initial, isEmpty);
    await _eventually(
      () =>
          container
              .read(homeRecommendationsProvider)
              .asData
              ?.value
              .isNotEmpty ??
          false,
    );
    expect(source.refreshCalls, 1);
    expect(source.forceNetworkCalls, [false]);
  });

  test('invalidating combined Home starts a new background refresh', () async {
    final source = _FakePersonalizedHomeFeedSource(
      CachedPersonalizedRecommendationFeed(
        feed: _personalizedFeed(),
        isExpired: false,
      ),
    );
    final container = _combinedContainer(source);
    await container.read(homeRecommendationsProvider.future);
    await _eventually(() => source.refreshCalls == 1);

    container.invalidate(homeRecommendationsProvider);
    final rebuilt = await container.read(homeRecommendationsProvider.future);

    expect(rebuilt.single.title, 'Seguir escuchando');
    await _eventually(() => source.refreshCalls == 2);
    expect(source.forceNetworkCalls, [false, false]);
  });

  test(
    'manual refresh queues a forced full pass behind startup refresh',
    () async {
      final startupGate = Completer<PersonalizedRecommendationFeed>();
      final source = _FakePersonalizedHomeFeedSource(
        CachedPersonalizedRecommendationFeed(
          feed: _personalizedFeed(),
          isExpired: false,
        ),
      )..refreshCompleter = startupGate;
      var youtubeHomeCalls = 0;
      final container = ProviderContainer(
        overrides: [
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
          personalizedHomeFeedSourceProvider.overrideWithValue(source),
          youtubeMusicHomeRecommendationsProvider.overrideWith((ref) async {
            youtubeHomeCalls += 1;
            return const <HomeRecommendationSection>[];
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(homeRecommendationsProvider.future);
      await _eventually(() => source.refreshCalls == 1);
      expect(source.forceNetworkCalls, const <bool>[false]);
      expect(youtubeHomeCalls, 1);

      final manualRefresh = container
          .read(homeRecommendationsProvider.notifier)
          .refresh();
      await Future<void>.delayed(Duration.zero);
      expect(source.refreshCalls, 1);

      startupGate.complete(_personalizedFeed());
      await manualRefresh;

      expect(source.forceNetworkCalls, const <bool>[false, true]);
      expect(youtubeHomeCalls, 2);
    },
  );

  test(
    'manual refresh forces network and retains combined feed on error',
    () async {
      final source = _FakePersonalizedHomeFeedSource(
        CachedPersonalizedRecommendationFeed(
          feed: _personalizedFeed(),
          isExpired: false,
        ),
      );
      final container = _combinedContainer(
        source,
        generic: [
          HomeRecommendationSection(
            title: 'Generico',
            tracks: const [
              TrackInfo(
                id: 'generic-id',
                title: 'Generica',
                artist: 'Artist',
                url: 'https://www.youtube.com/watch?v=generic0001',
              ),
            ],
          ),
        ],
      );
      await container.read(homeRecommendationsProvider.future);
      await _eventually(
        () =>
            container.read(homeRecommendationsProvider).asData?.value.length ==
            2,
      );
      final previous = container.read(homeRecommendationsProvider).requireValue;
      source.refreshError = StateError('offline');

      final refresh = container
          .read(homeRecommendationsProvider.notifier)
          .refresh();
      expect(container.read(homeRecommendationsProvider).isLoading, isTrue);
      expect(
        container
            .read(homeRecommendationsProvider)
            .value
            ?.map((section) => section.title),
        previous.map((section) => section.title),
      );
      await refresh;

      final failed = container.read(homeRecommendationsProvider);
      expect(failed.hasError, isTrue);
      expect(
        failed.value?.map((section) => section.title),
        previous.map((section) => section.title),
      );
      expect(source.forceNetworkCalls.last, isTrue);
    },
  );
}

ProviderContainer _combinedContainer(
  _FakePersonalizedHomeFeedSource source, {
  List<HomeRecommendationSection> generic = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
      personalizedHomeFeedSourceProvider.overrideWithValue(source),
      youtubeMusicHomeRecommendationsProvider.overrideWith(
        (ref) async => generic,
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

PersonalizedRecommendationFeed _personalizedFeed({
  bool includeAllKinds = false,
}) {
  final sections = <PersonalizedRecommendationSection>[
    PersonalizedRecommendationSection(
      kind: PersonalizedSectionKind.continueListening,
      title: 'Engine title must not leak',
      items: [
        PersonalizedTrackItem(
          trackId: 'download-row-id',
          videoId: 'AbCdEfGhIj1',
          title: 'Descargada',
          artists: const ['Artista'],
          artistBrowseIds: const ['UCartist00001'],
          durationMs: 123000,
          source: PlaybackEventSource.downloaded,
        ),
      ],
    ),
  ];
  if (includeAllKinds) {
    sections.addAll([
      PersonalizedRecommendationSection(
        kind: PersonalizedSectionKind.becauseYouListened,
        title: 'Engine because title must not leak',
        seedTitle: 'Semilla favorita',
        items: [
          PersonalizedTrackItem(
            trackId: 'because-track',
            videoId: 'Because0001',
            title: 'Relacionada',
            artists: const ['Artista B'],
          ),
        ],
      ),
      PersonalizedRecommendationSection(
        kind: PersonalizedSectionKind.mixes,
        title: 'Engine mixes title must not leak',
        items: [
          PersonalizedCollectionItem(
            id: 'mix:RDAMVMAbCdEfGhIj1',
            title: 'Mix personal',
            browseId: 'VLRDAMVMAbCdEfGhIj1',
            playlistId: 'RDAMVMAbCdEfGhIj1',
            kind: PersonalizedCollectionKind.mix,
          ),
        ],
      ),
      PersonalizedRecommendationSection(
        kind: PersonalizedSectionKind.newForYou,
        title: 'Engine releases title must not leak',
        items: [
          PersonalizedCollectionItem(
            id: 'release:MPRErelease001',
            title: 'Lanzamiento',
            browseId: 'MPRErelease001',
            kind: PersonalizedCollectionKind.release,
          ),
        ],
      ),
      PersonalizedRecommendationSection(
        kind: PersonalizedSectionKind.discovery,
        title: 'Engine discovery title must not leak',
        items: [
          PersonalizedTrackItem(
            trackId: 'discover-id',
            videoId: 'Discover001',
            title: 'Descubrimiento uno',
            artists: const ['Artista D'],
          ),
        ],
      ),
    ]);
  }
  return PersonalizedRecommendationFeed(
    generatedAt: DateTime.utc(2026),
    sections: sections,
  );
}

Future<void> _eventually(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Condition was not met before the timeout.');
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
        YouTubeMusicCollectionLookup,
        YouTubeMusicRelated {
  _FakeHomeSearch(this.sections);

  final List<InnerTubeHomeSection> sections;
  final Map<String, List<InnerTubeSong>> collectionSongs = {};
  final Map<String, InnerTubeNextPage> nextPages = {};
  Object? homeError;
  Object? collectionError;
  int homeCalls = 0;
  int searchCalls = 0;
  int collectionCalls = 0;
  int nextCalls = 0;
  String? lastNextVideoId;
  bool? lastNextRadio;
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

  @override
  Future<InnerTubeNextPage> getNext(
    String videoId, {
    bool radio = false,
    int limit = innerTubeDetailResultLimit,
  }) async {
    nextCalls++;
    lastNextVideoId = videoId;
    lastNextRadio = radio;
    return nextPages[videoId] ?? InnerTubeNextPage(songs: const []);
  }

  @override
  Future<InnerTubeNextPage> getNextContinuation(
    String continuation, {
    int limit = innerTubeDetailResultLimit,
  }) async => InnerTubeNextPage(songs: const []);

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

class _FakePersonalizedHomeFeedSource implements PersonalizedHomeFeedSource {
  _FakePersonalizedHomeFeedSource(this.cached);

  final CachedPersonalizedRecommendationFeed? cached;
  PersonalizedRecommendationFeed? refreshedFeed;
  Completer<PersonalizedRecommendationFeed>? refreshCompleter;
  Object? refreshError;
  int refreshCalls = 0;
  final List<bool> forceNetworkCalls = [];

  @override
  Future<CachedPersonalizedRecommendationFeed?> loadCachedFeed() async {
    return cached;
  }

  @override
  Future<PersonalizedRecommendationFeed> refresh({
    bool forceNetwork = false,
  }) async {
    refreshCalls += 1;
    forceNetworkCalls.add(forceNetwork);
    final error = refreshError;
    if (error != null) {
      throw error;
    }
    final pending = refreshCompleter;
    if (pending != null) {
      return pending.future;
    }
    return refreshedFeed ??
        cached?.feed ??
        PersonalizedRecommendationFeed(
          generatedAt: DateTime.utc(2026),
          sections: const [],
        );
  }
}
