import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:bstream_music/services/youtube_music/search_browse_catalog_cache.dart';
import 'package:bstream_music/services/youtube_music/search_browse_artwork_cache.dart';

void main() {
  test('keeps the complete advertised catalog beyond 24 cards', () async {
    final source = _FakeMoodGenreSearch(
      sections: [
        InnerTubeMoodGenreSection(
          title: 'Géneros',
          categories: [
            for (var i = 0; i < 40; i++)
              InnerTubeMoodGenreCategory(
                title: 'Género $i',
                target: InnerTubeBrowseTarget(
                  browseId: 'FEmusic_moods_and_genres_category',
                  params: 'genre-$i',
                ),
              ),
          ],
        ),
      ],
    );
    final catalog = await _container(
      source,
    ).read(searchBrowseCatalogProvider.future);
    expect(catalog.categories, hasLength(40));
    expect(catalog.categories.last.title, 'Género 39');
  });

  test(
    'bounds category lookups and skips disposed requests in the queue',
    () async {
      final release = Completer<void>();
      var active = 0;
      var maximumActive = 0;
      final source = _FakeMoodGenreSearch(
        sections: [],
        moodLookup: (_) async {
          active++;
          if (active > maximumActive) maximumActive = active;
          await release.future;
          active--;
          return InnerTubeMoodGenrePage(sections: []);
        },
      );
      final container = _container(source);
      final categories = [
        for (var i = 0; i < 6; i++)
          SearchBrowseCategory(
            id: 'q$i',
            title: '$i',
            searchQuery: '$i',
            target: InnerTubeBrowseTarget(
              browseId: 'FEmusic_moods_and_genres_category',
              params: 'q$i',
            ),
          ),
      ];
      final subscriptions = [
        for (final category in categories)
          container.listen(
            searchBrowseCategoryPageProvider(category),
            (_, _) {},
          ),
      ];
      for (final subscription in subscriptions) {
        addTearDown(subscription.close);
      }
      await Future<void>.delayed(Duration.zero);
      expect(source.moodCalls, 2);
      subscriptions[3].close();
      await container.pump();
      release.complete();
      await Future.wait([
        for (final i in [0, 1, 2, 4, 5])
          container.read(
            searchBrowseCategoryPageProvider(categories[i]).future,
          ),
      ]);
      expect(source.moodCalls, 5);
      expect(maximumActive, 2);
    },
  );

  test('shares an in-flight category page across offscreen visits', () async {
    final pending = Completer<InnerTubeMoodGenrePage>();
    final page = InnerTubeMoodGenrePage(sections: []);
    final source = _FakeMoodGenreSearch(
      sections: [],
      moodLookup: (_) => pending.future,
    );
    final container = _container(source);
    final provider = searchBrowseCategoryPageProvider(_category('pending'));
    final first = container.listen(provider, (_, _) {});
    await container.pump();
    expect(source.moodCalls, 1);

    first.close();
    await container.pump();
    final next = container.listen(provider, (_, _) {});
    addTearDown(next.close);
    await container.pump();
    expect(source.moodCalls, 1);

    pending.complete(page);
    expect(await container.read(provider.future), same(page));
    next.close();
    await container.pump();
    expect(await container.read(provider.future), same(page));
    expect(
      source.moodCalls,
      1,
      reason: 'successful pages keep the timed cache',
    );
  });

  test(
    'the temporary page hold ends when its successful cache expires',
    () async {
      final page = InnerTubeMoodGenrePage(sections: []);
      final source = _FakeMoodGenreSearch(sections: [], moodPage: page);
      final container = _container(
        source,
        remoteCacheDuration: const Duration(milliseconds: 5),
      );
      final provider = searchBrowseCategoryPageProvider(_category('expires'));
      final first = container.listen(provider, (_, _) {});
      expect(await container.read(provider.future), same(page));
      first.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await container.pump();

      final next = container.listen(provider, (_, _) {});
      addTearDown(next.close);
      expect(await container.read(provider.future), same(page));
      expect(source.moodCalls, 2);
    },
  );

  test('a failed in-flight page is not retained after leaving', () async {
    final pending = Completer<InnerTubeMoodGenrePage>();
    final page = InnerTubeMoodGenrePage(sections: []);
    var attempts = 0;
    final source = _FakeMoodGenreSearch(
      sections: [],
      moodLookup: (_) => ++attempts == 1 ? pending.future : Future.value(page),
    );
    final container = _container(source);
    final provider = searchBrowseCategoryPageProvider(_category('retry'));
    final first = container.listen(provider, (_, _) {});
    final failed = expectLater(
      container.read(provider.future),
      throwsA(isA<StateError>()),
    );
    await container.pump();
    first.close();
    await container.pump();
    pending.completeError(StateError('temporary network failure'));
    await failed;
    await container.pump();

    final next = container.listen(provider, (_, _) {});
    addTearDown(next.close);
    expect(await container.read(provider.future), same(page));
    expect(source.moodCalls, 2);
  });

  test('leaving a pending page does not start its cover lookup', () async {
    final pending = Completer<InnerTubeMoodGenrePage>();
    final source = _FakeMoodGenreSearch(
      sections: [],
      moodLookup: (_) => pending.future,
      collectionSongs: {
        'VLpending': [_song('pending0001', 'Pending')],
      },
    );
    final container = _container(source);
    final category = _category('pending-cover');
    final provider = searchBrowseCategoryArtworkProvider(category);
    final first = container.listen(provider, (_, _) {});
    await container.pump();
    expect(source.moodCalls, 1);
    first.close();
    await container.pump();

    pending.complete(_collectionPage('VLpending'));
    await container.read(searchBrowseCategoryPageProvider(category).future);
    await container.pump();
    expect(source.collectionCalls, isEmpty);

    final next = container.listen(provider, (_, _) {});
    addTearDown(next.close);
    expect(
      await container.read(provider.future),
      'https://img.test/pending0001.jpg',
    );
    expect(source.moodCalls, 1);
    expect(source.collectionCalls, ['VLpending']);
  });

  test(
    'shares an in-flight cover collection across offscreen visits',
    () async {
      final pending = Completer<List<InnerTubeSong>>();
      final started = Completer<void>();
      final source = _FakeMoodGenreSearch(
        sections: [],
        moodPage: _collectionPage('VLcover'),
        collectionLookup: (_) {
          if (!started.isCompleted) started.complete();
          return pending.future;
        },
      );
      final container = _container(source);
      final provider = searchBrowseCategoryArtworkProvider(_category('cover'));
      final first = container.listen(provider, (_, _) {});
      await started.future.timeout(const Duration(seconds: 5));
      expect(source.collectionCalls, ['VLcover']);
      first.close();
      await container.pump();
      final next = container.listen(provider, (_, _) {});
      addTearDown(next.close);
      await container.pump();
      expect(source.collectionCalls, ['VLcover']);

      pending.complete([_song('cover000001', 'Cover')]);
      expect(
        await container.read(provider.future),
        'https://img.test/cover000001.jpg',
      );
      next.close();
      await container.pump();
      expect(
        await container.read(provider.future),
        'https://img.test/cover000001.jpg',
      );
      expect(source.moodCalls, 1);
      expect(source.collectionCalls, ['VLcover']);
    },
  );

  test(
    'drops an offscreen cover while its collection is still queued',
    () async {
      final pending = Completer<InnerTubeMoodGenrePage>();
      final source = _FakeMoodGenreSearch(
        sections: [],
        moodLookup: (target) => target.params == 'queued-cover'
            ? Future.value(_collectionPage('VLqueued'))
            : pending.future,
      );
      final container = _container(source);
      final category = _category('queued-cover');
      await container.read(searchBrowseCategoryPageProvider(category).future);
      final blockers = [
        for (final id in ['block-a', 'block-b'])
          container.listen(
            searchBrowseCategoryPageProvider(_category(id)),
            (_, _) {},
          ),
      ];
      for (final blocker in blockers) {
        addTearDown(blocker.close);
      }
      await container.pump();
      expect(source.moodCalls, 3);

      final cover = container.listen(
        searchBrowseCategoryArtworkProvider(category),
        (_, _) {},
      );
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      expect(source.collectionCalls, isEmpty);
      cover.close();
      await container.pump();
      pending.complete(InnerTubeMoodGenrePage(sections: []));
      await container.pump();
      await Future<void>.delayed(Duration.zero);
      expect(source.collectionCalls, isEmpty);
    },
  );

  test(
    'a failed cover lookup falls back but can retry on the next visit',
    () async {
      final pending = Completer<List<InnerTubeSong>>();
      final started = Completer<void>();
      var attempts = 0;
      final source = _FakeMoodGenreSearch(
        sections: [],
        moodPage: _collectionPage('VLretry'),
        collectionLookup: (_) {
          if (!started.isCompleted) started.complete();
          return ++attempts == 1
              ? pending.future
              : Future.value([_song('retry000001', 'Recovered')]);
        },
      );
      final container = _container(source);
      final category = _category('retry-cover');
      final provider = searchBrowseCategoryArtworkProvider(category);
      final first = container.listen(provider, (_, _) {});
      final initial = container.read(provider.future);
      await started.future.timeout(const Duration(seconds: 5));
      expect(source.collectionCalls, ['VLretry']);
      first.close();
      await container.pump();
      pending.completeError(StateError('temporary collection failure'));
      expect(await initial, 'https://img.test/VLretry.jpg');
      await container.pump();

      final next = container.listen(provider, (_, _) {});
      addTearDown(next.close);
      expect(
        await container.read(provider.future),
        'https://img.test/retry000001.jpg',
      );
      expect(source.moodCalls, 1, reason: 'the successful page stays cached');
      expect(source.collectionCalls, ['VLretry', 'VLretry']);
    },
  );

  test('keeps localized YouTube categories and their opaque targets', () async {
    final source = _FakeMoodGenreSearch(
      sections: <InnerTubeMoodGenreSection>[
        InnerTubeMoodGenreSection(
          title: 'Estados de ánimo',
          categories: const <InnerTubeMoodGenreCategory>[
            InnerTubeMoodGenreCategory(
              title: 'Energía',
              target: InnerTubeBrowseTarget(
                browseId: 'FEmusic_moods_and_genres_category',
                params: 'opaque-energy',
              ),
            ),
            InnerTubeMoodGenreCategory(
              title: 'Energía duplicada',
              target: InnerTubeBrowseTarget(
                browseId: 'FEmusic_moods_and_genres_category',
                params: 'opaque-energy',
              ),
            ),
          ],
        ),
        InnerTubeMoodGenreSection(
          title: 'Géneros',
          categories: const <InnerTubeMoodGenreCategory>[
            InnerTubeMoodGenreCategory(
              title: 'Alternativa',
              target: InnerTubeBrowseTarget(
                browseId: 'FEmusic_moods_and_genres_category',
                params: 'opaque-alternative',
              ),
            ),
          ],
        ),
      ],
    );
    final container = _container(source);

    final catalog = await container.read(searchBrowseCatalogProvider.future);

    expect(catalog.usesLiveYouTubeMusicCategories, isTrue);
    expect(catalog.categories.first.title, 'Energía');
    expect(
      catalog.categories.first.target,
      const InnerTubeBrowseTarget(
        browseId: 'FEmusic_moods_and_genres_category',
        params: 'opaque-energy',
      ),
    );
    expect(
      catalog.categories.where(
        (item) => item.target?.params == 'opaque-energy',
      ),
      hasLength(1),
    );
    expect(
      catalog.categories.any((item) => item.title == 'Alternativa'),
      isTrue,
    );
    expect(
      catalog.categories.any((item) => item.id == 'party'),
      isFalse,
      reason: 'a valid YouTube catalog does not mix in generic search cards',
    );
    expect(
      await (container.read(searchBrowseCatalogCacheProvider)
              as _MemorySearchBrowseCatalogCache)
          .read('es'),
      isNotNull,
    );
  });

  test(
    'restores the last live category catalog without network discovery',
    () async {
      const cachedCategory = SearchBrowseCategorySnapshot(
        id: 'yt:focus',
        title: 'ConcentraciÃ³n',
        searchQuery: 'ConcentraciÃ³n',
        browseId: 'FEmusic_moods_and_genres_category',
        params: 'focus-target',
      );
      final catalogCache = _MemorySearchBrowseCatalogCache(
        SearchBrowseCatalogSnapshot(
          categories: [cachedCategory],
          usesLiveYouTubeMusicCategories: true,
        ),
      );
      final source = _FakeMoodGenreSearch(
        sections: [],
        moodsError: StateError('should not be called'),
      );
      final container = _container(source, catalogCache: catalogCache);

      final catalog = await container.read(
        searchBrowseCachedCatalogProvider.future,
      );

      expect(catalog?.categories.single.title, 'ConcentraciÃ³n');
      expect(catalog?.categories.single.target?.params, 'focus-target');
      expect(source.moodCalls, 0);
    },
  );

  test(
    'category page preserves shelves and shares one lookup with its cover',
    () async {
      const category = SearchBrowseCategory(
        id: 'focus',
        title: 'Concentración',
        searchQuery: 'focus',
        target: InnerTubeBrowseTarget(
          browseId: 'FEmusic_moods_and_genres_category',
          params: 'focus',
        ),
      );
      const playlist = InnerTubeHomeCollection(
        title: 'Lo-fi Loft',
        browseId: 'VLlofi',
        kind: InnerTubeHomeCollectionKind.playlist,
        thumbnailUrl: 'https://img.test/lofi.jpg',
      );
      final page = InnerTubeMoodGenrePage(
        sections: [
          InnerTubeHomeSection(title: 'Flotando', items: [playlist]),
          InnerTubeHomeSection(
            title: 'Música clásica',
            songs: [_song('classical01', 'Piano')],
          ),
        ],
        continuation: 'more-focus',
      );
      final source = _FakeMoodGenreSearch(
        sections: [],
        moodPage: page,
        collectionSongs: {
          'VLlofi': [_song('firstsong01', 'Primera canción')],
        },
      );
      final container = _container(source);
      final artworkCache =
          container.read(searchBrowseCategoryArtworkCacheProvider)
              as _MemorySearchBrowseCategoryArtworkCache;
      final detail = container.listen(
        searchBrowseCategoryPageProvider(category),
        (_, _) {},
      );
      addTearDown(detail.close);
      expect(
        await container.read(searchBrowseCategoryPageProvider(category).future),
        same(page),
      );
      expect(source.collectionCalls, isEmpty);
      final cover = container.listen(
        searchBrowseCategoryArtworkProvider(category),
        (_, _) {},
      );
      addTearDown(cover.close);
      expect(
        await container.read(
          searchBrowseCategoryArtworkProvider(category).future,
        ),
        'https://img.test/firstsong01.jpg',
      );
      expect(source.moodCalls, 1);
      expect(source.collectionCalls, ['VLlofi']);
      expect(source.collectionLimits, [1]);
      expect(source.continuationCalls, 0);
      expect(source.trackLookupCalls, isEmpty);
      expect(
        await artworkCache.read(category.id),
        'https://img.test/firstsong01.jpg',
      );
    },
  );

  test('direct song covers need no playlist or duration lookup', () async {
    const category = SearchBrowseCategory(
      id: 'direct',
      title: 'Directa',
      searchQuery: 'direct',
      target: InnerTubeBrowseTarget(
        browseId: 'FEmusic_moods_and_genres_category',
        params: 'direct',
      ),
    );
    final source = _FakeMoodGenreSearch(
      sections: [],
      moodPage: InnerTubeMoodGenrePage(
        sections: [
          InnerTubeHomeSection(
            title: 'Canciones',
            songs: [_song('direct00001', 'Directa')],
          ),
        ],
      ),
    );
    final container = _container(source);
    final subscription = container.listen(
      searchBrowseCategoryArtworkProvider(category),
      (_, _) {},
    );
    addTearDown(subscription.close);
    expect(
      await container.read(
        searchBrowseCategoryArtworkProvider(category).future,
      ),
      'https://img.test/direct00001.jpg',
    );
    expect(source.collectionCalls, isEmpty);
    expect(source.trackLookupCalls, isEmpty);
  });

  test('returns the complete curated catalog when discovery fails', () async {
    final source = _FakeMoodGenreSearch(
      sections: const <InnerTubeMoodGenreSection>[],
      moodsError: StateError('layout changed'),
    );
    final container = _container(source);

    final catalog = await container.read(searchBrowseCatalogProvider.future);

    expect(catalog.usesLiveYouTubeMusicCategories, isFalse);
    expect(catalog.categories, hasLength(12));
    expect(
      catalog.categories.map((item) => item.title),
      containsAll(<String>['Pop', 'Fiesta', 'Reggae', 'Clásica', 'Jazz']),
    );
  });

  test(
    'combines direct, continued and playlist songs without duplicates',
    () async {
      const target = InnerTubeBrowseTarget(
        browseId: 'FEmusic_moods_and_genres_category',
        params: 'opaque-focus',
      );
      final source = _FakeMoodGenreSearch(
        sections: const <InnerTubeMoodGenreSection>[],
        moodPage: InnerTubeMoodGenrePage(
          sections: <InnerTubeHomeSection>[
            InnerTubeHomeSection(
              title: 'Para concentrarse',
              items: <InnerTubeHomeItem>[
                InnerTubeHomeSongItem(_song('direct00001', 'Directa')),
                const InnerTubeHomeCollection(
                  title: 'Mix enfoque',
                  browseId: 'VLfocus',
                  kind: InnerTubeHomeCollectionKind.playlist,
                ),
              ],
            ),
          ],
          continuation: 'next-focus',
        ),
        continuationPage: InnerTubeMoodGenrePage(
          sections: <InnerTubeHomeSection>[
            InnerTubeHomeSection(
              title: 'Más',
              songs: <InnerTubeSong>[
                _song('direct00001', 'Directa duplicada'),
                _song('continued01', 'Continuada'),
              ],
            ),
          ],
        ),
        collectionSongs: <String, List<InnerTubeSong>>{
          'VLfocus': <InnerTubeSong>[
            _song('playlist001', 'Desde playlist'),
            _song('continued01', 'Continuada duplicada'),
          ],
        },
      );
      final container = _container(source);
      const category = SearchBrowseCategory(
        id: 'focus',
        title: 'Concentración',
        searchQuery: 'música para concentrarse',
        target: target,
      );

      final tracks = await _waitForTracks(
        container,
        searchBrowseCategoryTracksProvider(category),
        (_) => true,
      );

      expect(tracks.map((track) => track.id), <String>[
        'direct00001',
        'continued01',
        'playlist001',
      ]);
      expect(source.continuationCalls, 1);
      expect(source.collectionCalls, <String>['VLfocus']);
    },
  );

  test(
    'fills missing durations without replacing or dropping tracks',
    () async {
      const target = InnerTubeBrowseTarget(
        browseId: 'FEmusic_moods_and_genres_category',
        params: 'opaque-duration',
      );
      final source = _FakeMoodGenreSearch(
        sections: const <InnerTubeMoodGenreSection>[],
        moodPage: InnerTubeMoodGenrePage(
          sections: <InnerTubeHomeSection>[
            InnerTubeHomeSection(
              title: 'Canciones',
              songs: <InnerTubeSong>[
                _song('missing0001', 'Sin duración', duration: null),
                _song(
                  'known000001',
                  'Con duración',
                  duration: const Duration(minutes: 2, seconds: 5),
                ),
                _song('failed00001', 'No disponible', duration: null),
              ],
            ),
          ],
        ),
        lookupSongs: <String, InnerTubeSong>{
          'missing0001': _song(
            'missing0001',
            'Metadatos exactos',
            duration: const Duration(minutes: 4, seconds: 12),
          ),
        },
        lookupFailures: const <String>{'failed00001'},
      );
      final container = _container(source);
      const category = SearchBrowseCategory(
        id: 'duration',
        title: 'Duración',
        searchQuery: 'duration',
        target: target,
      );

      final emissions = <List<TrackInfo>>[];
      final tracks = await _waitForTracks(
        container,
        searchBrowseCategoryTracksProvider(category),
        (tracks) => tracks.first.duration != null,
        emissions: emissions,
      );

      expect(tracks.map((track) => track.title), <String>[
        'Sin duración',
        'Con duración',
        'No disponible',
      ]);
      expect(tracks[0].duration, const Duration(minutes: 4, seconds: 12));
      expect(tracks[1].duration, const Duration(minutes: 2, seconds: 5));
      expect(tracks[2].duration, isNull);
      expect(emissions.first[0].duration, isNull);
      expect(
        source.trackLookupCalls.where((id) => id == 'missing0001'),
        hasLength(1),
      );
      expect(
        source.trackLookupCalls.where((id) => id == 'failed00001'),
        hasLength(1),
      );
      expect(source.songLookupCalls, isEmpty);
    },
  );

  test('also enriches missing durations in curated fallback results', () async {
    final source = _FakeMoodGenreSearch(
      sections: const <InnerTubeMoodGenreSection>[],
      searchSongsResult: <InnerTubeSong>[
        _song('fallback001', 'Resultado de respaldo', duration: null),
      ],
      lookupSongs: <String, InnerTubeSong>{
        'fallback001': _song(
          'fallback001',
          'Metadatos exactos',
          duration: const Duration(minutes: 3, seconds: 33),
        ),
      },
    );
    final container = _container(source);
    const category = SearchBrowseCategory(
      id: 'fallback-duration',
      title: 'Fallback',
      searchQuery: 'fallback music',
    );

    final tracks = await _waitForTracks(
      container,
      searchBrowseCategoryTracksProvider(category),
      (tracks) => tracks.single.duration != null,
    );

    expect(tracks.single.duration, const Duration(minutes: 3, seconds: 33));
    expect(source.trackLookupCalls, <String>['fallback001']);
  });

  test(
    'emits immediately then progressively enriches every missing duration',
    () async {
      const target = InnerTubeBrowseTarget(
        browseId: 'FEmusic_moods_and_genres_category',
        params: 'opaque-bounded-duration',
      );
      final songs = <InnerTubeSong>[
        for (var index = 0; index < 20; index++)
          _song(
            'bounded${index.toString().padLeft(4, '0')}',
            'Canción $index',
            duration: null,
          ),
      ];
      final source = _FakeMoodGenreSearch(
        sections: const <InnerTubeMoodGenreSection>[],
        moodPage: InnerTubeMoodGenrePage(
          sections: <InnerTubeHomeSection>[
            InnerTubeHomeSection(title: 'Canciones', songs: songs),
          ],
        ),
        lookupSongs: <String, InnerTubeSong>{
          for (final song in songs)
            song.videoId: _song(
              song.videoId,
              song.title,
              duration: const Duration(minutes: 3),
            ),
        },
      );
      final container = _container(source);
      const category = SearchBrowseCategory(
        id: 'bounded-duration',
        title: 'Duraciones',
        searchQuery: 'durations',
        target: target,
      );

      final emissions = <List<TrackInfo>>[];
      final tracks = await _waitForTracks(
        container,
        searchBrowseCategoryTracksProvider(category),
        (tracks) => tracks.every((track) => track.duration != null),
        emissions: emissions,
      );

      expect(source.trackLookupCalls, hasLength(20));
      expect(
        source.trackLookupCalls,
        unorderedEquals(songs.map((song) => song.videoId)),
      );
      expect(emissions.first.every((track) => track.duration == null), isTrue);
      expect(emissions.length, greaterThanOrEqualTo(6));
      expect(tracks.every((track) => track.duration != null), isTrue);
    },
  );

  test(
    'leaving the category cancels the paced duration batches after initial rows',
    () async {
      const target = InnerTubeBrowseTarget(
        browseId: 'FEmusic_moods_and_genres_category',
        params: 'opaque-paced-duration',
      );
      final songs = <InnerTubeSong>[
        for (var index = 0; index < 16; index++)
          _song(
            'paced${index.toString().padLeft(6, '0')}',
            'Song $index',
            duration: null,
          ),
      ];
      final source = _FakeMoodGenreSearch(
        sections: const <InnerTubeMoodGenreSection>[],
        moodPage: InnerTubeMoodGenrePage(
          sections: <InnerTubeHomeSection>[
            InnerTubeHomeSection(title: 'Songs', songs: songs),
          ],
        ),
        durationLookup: (_) async => const Duration(minutes: 3),
      );
      final container = ProviderContainer(
        overrides: [youtubeMusicSearchProvider.overrideWithValue(source)],
      );
      const category = SearchBrowseCategory(
        id: 'paced-duration',
        title: 'Durations',
        searchQuery: 'paced durations',
        target: target,
      );
      final initialRows = await _waitForTracks(
        container,
        searchBrowseCategoryTracksProvider(category),
        (tracks) => tracks.where((track) => track.duration != null).length == 8,
      );
      expect(
        initialRows.map((track) => track.id),
        songs.map((song) => song.videoId),
      );
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        source.trackLookupCalls,
        songs.take(8).map((song) => song.videoId),
      );
    },
  );

  test(
    'stops duration enrichment after the active batch is disposed',
    () async {
      const target = InnerTubeBrowseTarget(
        browseId: 'FEmusic_moods_and_genres_category',
        params: 'opaque-cancel-duration',
      );
      final songs = <InnerTubeSong>[
        for (var index = 0; index < 12; index++)
          _song(
            'cancel${index.toString().padLeft(5, '0')}',
            'Canción $index',
            duration: null,
          ),
      ];
      final releaseFirstBatch = Completer<void>();
      final firstBatchStarted = Completer<void>();
      late final _FakeMoodGenreSearch source;
      source = _FakeMoodGenreSearch(
        sections: const <InnerTubeMoodGenreSection>[],
        moodPage: InnerTubeMoodGenrePage(
          sections: <InnerTubeHomeSection>[
            InnerTubeHomeSection(title: 'Canciones', songs: songs),
          ],
        ),
        durationLookup: (videoId) async {
          if (source.trackLookupCalls.length == 4 &&
              !firstBatchStarted.isCompleted) {
            firstBatchStarted.complete();
          }
          await releaseFirstBatch.future;
          return const Duration(minutes: 3);
        },
      );
      final container = ProviderContainer(
        overrides: [youtubeMusicSearchProvider.overrideWithValue(source)],
      );
      const category = SearchBrowseCategory(
        id: 'cancel-duration',
        title: 'Cancelación',
        searchQuery: 'cancel durations',
        target: target,
      );
      final initialEmission = Completer<void>();
      final subscription = container.listen<AsyncValue<List<TrackInfo>>>(
        searchBrowseCategoryTracksProvider(category),
        (_, next) {
          if (next case AsyncData(
            :final value,
          ) when value.length == songs.length && !initialEmission.isCompleted) {
            initialEmission.complete();
          }
        },
        fireImmediately: true,
      );

      await initialEmission.future.timeout(const Duration(seconds: 5));
      await firstBatchStarted.future.timeout(const Duration(seconds: 5));
      subscription.close();
      container.dispose();
      releaseFirstBatch.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(source.trackLookupCalls, hasLength(4));
    },
  );
}

Future<List<TrackInfo>> _waitForTracks(
  ProviderContainer container,
  ProviderListenable<AsyncValue<List<TrackInfo>>> provider,
  bool Function(List<TrackInfo> tracks) predicate, {
  List<List<TrackInfo>>? emissions,
}) async {
  final completer = Completer<List<TrackInfo>>();
  final subscription = container.listen<AsyncValue<List<TrackInfo>>>(provider, (
    _,
    next,
  ) {
    if (next case AsyncData(:final value)) {
      emissions?.add(value);
      if (!completer.isCompleted && predicate(value)) {
        completer.complete(value);
      }
    } else if (next case AsyncError(:final error, :final stackTrace)) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
  }, fireImmediately: true);
  try {
    return await completer.future.timeout(const Duration(seconds: 5));
  } finally {
    subscription.close();
  }
}

ProviderContainer _container(
  _FakeMoodGenreSearch source, {
  _MemorySearchBrowseCatalogCache? catalogCache,
  Duration? remoteCacheDuration,
}) {
  final artworkCache = _MemorySearchBrowseCategoryArtworkCache();
  final container = ProviderContainer(
    overrides: [
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
      youtubeMusicSearchProvider.overrideWithValue(source),
      searchBrowseCatalogCacheProvider.overrideWithValue(
        catalogCache ?? _MemorySearchBrowseCatalogCache(),
      ),
      searchBrowseCategoryArtworkCacheProvider.overrideWithValue(artworkCache),
      if (remoteCacheDuration != null)
        remoteDetailTracksCacheDurationProvider.overrideWithValue(
          remoteCacheDuration,
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

final class _MemorySearchBrowseCatalogCache
    implements SearchBrowseCatalogCache {
  _MemorySearchBrowseCatalogCache([this.snapshot]);

  SearchBrowseCatalogSnapshot? snapshot;

  @override
  Future<SearchBrowseCatalogSnapshot?> read(String languageCode) async =>
      snapshot;

  @override
  Future<void> write(
    String languageCode,
    SearchBrowseCatalogSnapshot catalog,
  ) async {
    snapshot = catalog;
  }
}

final class _MemorySearchBrowseCategoryArtworkCache
    implements SearchBrowseCategoryArtworkCache {
  final _values = <String, String>{};

  @override
  Future<String?> read(String categoryId) async => _values[categoryId];

  @override
  Future<void> write(String categoryId, String? artworkUrl) async {
    if (artworkUrl == null) {
      _values.remove(categoryId);
    } else {
      _values[categoryId] = artworkUrl;
    }
  }
}

InnerTubeSong _song(
  String videoId,
  String title, {
  Duration? duration = const Duration(minutes: 3),
}) => InnerTubeSong(
  videoId: videoId,
  title: title,
  artists: const <String>['Artista'],
  duration: duration,
  thumbnailUrl: 'https://img.test/$videoId.jpg',
);

SearchBrowseCategory _category(String id) => SearchBrowseCategory(
  id: id,
  title: id,
  searchQuery: id,
  target: InnerTubeBrowseTarget(
    browseId: 'FEmusic_moods_and_genres_category',
    params: id,
  ),
);

InnerTubeMoodGenrePage _collectionPage(String browseId) =>
    InnerTubeMoodGenrePage(
      sections: [
        InnerTubeHomeSection(
          title: 'Collections',
          items: [
            InnerTubeHomeCollection(
              title: browseId,
              browseId: browseId,
              kind: InnerTubeHomeCollectionKind.playlist,
              thumbnailUrl: 'https://img.test/$browseId.jpg',
            ),
          ],
        ),
      ],
    );

final class _FakeMoodGenreSearch
    implements
        YouTubeMusicSearch,
        YouTubeMusicMoodsAndGenres,
        YouTubeMusicCollectionLookup,
        YouTubeMusicDurationLookup,
        YouTubeMusicTrackLookup {
  _FakeMoodGenreSearch({
    required this.sections,
    this.moodsError,
    this.moodPage,
    this.continuationPage,
    this.collectionSongs = const <String, List<InnerTubeSong>>{},
    this.searchSongsResult = const <InnerTubeSong>[],
    this.lookupSongs = const <String, InnerTubeSong>{},
    this.lookupFailures = const <String>{},
    this.durationLookup,
    this.moodLookup,
    this.collectionLookup,
  });

  final List<InnerTubeMoodGenreSection> sections;
  final Object? moodsError;
  final InnerTubeMoodGenrePage? moodPage;
  final InnerTubeMoodGenrePage? continuationPage;
  final Map<String, List<InnerTubeSong>> collectionSongs;
  final List<InnerTubeSong> searchSongsResult;
  final Map<String, InnerTubeSong> lookupSongs;
  final Set<String> lookupFailures;
  final Future<Duration?> Function(String videoId)? durationLookup;
  final Future<InnerTubeMoodGenrePage> Function(InnerTubeBrowseTarget)?
  moodLookup;
  final Future<List<InnerTubeSong>> Function(String browseId)? collectionLookup;
  final List<String> collectionCalls = <String>[];
  final List<int> collectionLimits = <int>[];
  final List<String> trackLookupCalls = <String>[];
  final List<String> songLookupCalls = <String>[];
  int continuationCalls = 0;
  int moodCalls = 0;

  @override
  Future<List<InnerTubeMoodGenreSection>> getMoodsAndGenres({
    int maxSections = 8,
    int maxCategoriesPerSection = 32,
  }) async {
    final error = moodsError;
    if (error != null) throw error;
    return sections;
  }

  @override
  Future<InnerTubeMoodGenrePage> getMoodOrGenre(
    InnerTubeBrowseTarget target, {
    int maxSections = 6,
    int maxItemsPerSection = 20,
  }) async {
    moodCalls++;
    if (moodLookup != null) return moodLookup!(target);
    return moodPage ?? InnerTubeMoodGenrePage(sections: const []);
  }

  @override
  Future<InnerTubeMoodGenrePage> getMoodOrGenreContinuation(
    String continuation, {
    int maxSections = 6,
    int maxItemsPerSection = 20,
  }) async {
    continuationCalls++;
    return continuationPage ?? InnerTubeMoodGenrePage(sections: const []);
  }

  @override
  Future<List<InnerTubeSong>> getCollectionSongs(
    String browseId, {
    int limit = innerTubeDetailResultLimit,
  }) async {
    collectionCalls.add(browseId);
    collectionLimits.add(limit);
    if (collectionLookup != null) return collectionLookup!(browseId);
    return collectionSongs[browseId] ?? const <InnerTubeSong>[];
  }

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async => searchSongsResult.take(limit).toList(growable: false);

  @override
  Future<InnerTubeSong?> getSong(String videoId) async {
    songLookupCalls.add(videoId);
    if (lookupFailures.contains(videoId)) {
      throw StateError('player metadata unavailable');
    }
    return lookupSongs[videoId];
  }

  @override
  Future<Duration?> getSongDuration(String videoId) async {
    trackLookupCalls.add(videoId);
    final customLookup = durationLookup;
    if (customLookup != null) return customLookup(videoId);
    if (lookupFailures.contains(videoId)) {
      throw StateError('player metadata unavailable');
    }
    return lookupSongs[videoId]?.duration;
  }
}
