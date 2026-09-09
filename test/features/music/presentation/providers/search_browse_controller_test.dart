import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';

void main() {
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
      isTrue,
      reason: 'curated cards fill sparse regional responses',
    );
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

ProviderContainer _container(_FakeMoodGenreSearch source) {
  final container = ProviderContainer(
    overrides: [
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
      youtubeMusicSearchProvider.overrideWithValue(source),
    ],
  );
  addTearDown(container.dispose);
  return container;
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
  final List<String> collectionCalls = <String>[];
  final List<String> trackLookupCalls = <String>[];
  final List<String> songLookupCalls = <String>[];
  int continuationCalls = 0;

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
  }) async => moodPage ?? InnerTubeMoodGenrePage(sections: const []);

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
