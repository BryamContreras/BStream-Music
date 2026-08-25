import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/recommendations/recommendations.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'mixes qualified top and recent seeds, reuses cache, and excludes seeds',
    () async {
      final top = _seed(
        key: 'top-seed',
        artist: 'Artista top',
        artistBrowseId: 'UCtopseedartist01',
      );
      final recent = _seed(
        key: 'recent-seed',
        artist: 'Artista reciente',
        artistBrowseId: 'UCrecentseedart1',
      );
      final repository = _FakeRecommendationRepository(
        topSeeds: [top],
        recentSeeds: [recent],
        related: {
          top.trackKey: [
            _candidate(
              videoId: 'TopRelate01',
              artist: 'Similar Dos',
              artistBrowseId: 'UCsimilarcache02',
              rank: 0,
            ),
            _candidate(
              videoId: 'TopRepeat1',
              artist: 'Artista top',
              artistBrowseId: 'UCtopseedartist01',
              rank: 1,
            ),
          ],
          recent.trackKey: [
            _candidate(
              videoId: 'RecRelate01',
              artist: 'Similar Uno',
              artistBrowseId: 'UCsimilarcache01',
              rank: 0,
            ),
            _candidate(
              videoId: 'RecRelate02',
              artist: 'Similar Uno',
              artistBrowseId: 'UCsimilarcache01',
              rank: 1,
            ),
            _candidate(
              videoId: 'RecRepeat1',
              artist: 'Artista reciente',
              artistBrowseId: 'UCrecentseedart1',
              rank: 2,
            ),
          ],
        },
      );
      final now = DateTime.utc(2026, 8, 24, 12);
      final source = RepositoryHomeArtistRecommendationSource(
        repository: repository,
        clock: () => now,
      );

      final result = await source.load();
      final artists = result.artists;

      expect(repository.topMinListenedMs, 30000);
      expect(repository.recentMinListenedMs, 30000);
      expect(result.hasQualifiedHistory, isTrue);
      expect(repository.relatedSeedKeys, ['recent-seed', 'top-seed']);
      expect(repository.relatedNow, everyElement(now));
      expect(repository.relatedTtls, everyElement(const Duration(days: 7)));
      expect(artists.map((artist) => artist.name), [
        'Similar Uno',
        'Similar Dos',
      ]);
      expect(
        artists.map((artist) => artist.name),
        isNot(contains('Artista top')),
      );
      expect(
        artists.map((artist) => artist.name),
        isNot(contains('Artista reciente')),
      );
      expect(artists.first.seedVideoId, 'RecRelate01');
    },
  );

  test('reports a genuine cold start before a listen qualifies', () async {
    final repository = _FakeRecommendationRepository();
    final source = RepositoryHomeArtistRecommendationSource(
      repository: repository,
    );

    final result = await source.load();

    expect(result.artists, isEmpty);
    expect(result.hasQualifiedHistory, isFalse);
    expect(repository.relatedSeedKeys, isEmpty);
    expect(repository.topMinListenedMs, 30000);
    expect(repository.recentMinListenedMs, 30000);
  });

  test(
    'keeps qualified history distinct from an empty related cache',
    () async {
      final recent = _seed(
        key: 'recent-without-cache',
        artist: 'Escuchado recientemente',
        artistBrowseId: 'UCrecentwithoutcache',
      );
      final repository = _FakeRecommendationRepository(
        topSeeds: [recent],
        recentSeeds: [recent],
      );
      final source = RepositoryHomeArtistRecommendationSource(
        repository: repository,
      );

      final result = await source.load();

      expect(result.hasQualifiedHistory, isTrue);
      expect(result.artists, isEmpty);
      expect(repository.relatedSeedKeys, ['recent-without-cache']);
    },
  );

  test('recent listens rank ahead of older top listens', () async {
    final top = _seed(
      key: 'older-top',
      artist: 'Artista histórico',
      artistBrowseId: 'UChistoricalartist1',
    );
    final recent = _seed(
      key: 'latest-listen',
      artist: 'Artista reciente',
      artistBrowseId: 'UClatestartist0001',
    );
    final repository = _FakeRecommendationRepository(
      topSeeds: [top],
      recentSeeds: [recent],
      related: {
        top.trackKey: [
          _candidate(
            videoId: 'OldRelated1',
            artist: 'Relacionado histórico',
            artistBrowseId: 'UColdrelatedartist1',
            rank: 0,
          ),
        ],
        recent.trackKey: [
          _candidate(
            videoId: 'NewRelated1',
            artist: 'Relacionado reciente',
            artistBrowseId: 'UCnewrelatedartist1',
            rank: 0,
          ),
        ],
      },
    );
    final source = RepositoryHomeArtistRecommendationSource(
      repository: repository,
    );

    final result = await source.load();

    expect(repository.relatedSeedKeys, ['latest-listen', 'older-top']);
    expect(result.artists.map((artist) => artist.name), [
      'Relacionado reciente',
      'Relacionado histórico',
    ]);
  });

  test('repeated tracks in one radio count an artist only once', () async {
    final newest = _seed(
      key: 'newest-seed',
      artist: 'Semilla nueva',
      artistBrowseId: 'UCnewestseedartist1',
    );
    final second = _seed(
      key: 'second-seed',
      artist: 'Semilla segunda',
      artistBrowseId: 'UCsecondseedartist1',
    );
    final repository = _FakeRecommendationRepository(
      recentSeeds: [newest, second],
      related: {
        newest.trackKey: [
          _candidate(
            videoId: 'NewestRel01',
            artist: 'Relacionado nuevo',
            artistBrowseId: 'UCnewestrelated001',
            rank: 2,
          ),
        ],
        second.trackKey: List<RelatedTrackCandidate>.generate(
          5,
          (index) => _candidate(
            videoId: 'RepeatRel0$index',
            artist: 'Artista repetido',
            artistBrowseId: 'UCrepeatedartist01',
            rank: index,
          ),
        ),
      },
    );
    final source = RepositoryHomeArtistRecommendationSource(
      repository: repository,
    );

    final result = await source.load();

    expect(result.artists.map((artist) => artist.name), [
      'Relacionado nuevo',
      'Artista repetido',
    ]);
  });

  test(
    'uses only the newest qualified track for each listened artist',
    () async {
      final latestDistinct = _seed(
        key: 'latest-reik-track',
        artist: 'Reik',
        artistBrowseId: 'UCrecentdistinct01',
      );
      final latestRepeated = _seed(
        key: 'latest-paulo-track',
        artist: 'Paulo Londra',
        artistBrowseId: 'UCrepeatedseed001',
      );
      final olderRepeated = _seed(
        key: 'older-paulo-track',
        artist: 'Paulo Londra',
        artistBrowseId: 'UCrepeatedseed001',
      );
      final topRepeated = _seed(
        key: 'top-paulo-track',
        artist: 'Paulo Londra',
        artistBrowseId: 'UCrepeatedseed001',
      );
      final repository = _FakeRecommendationRepository(
        recentSeeds: [latestDistinct, latestRepeated, olderRepeated],
        topSeeds: [topRepeated],
        related: {
          latestDistinct.trackKey: [
            _candidate(
              videoId: 'CamilaRel001',
              artist: 'Camila',
              artistBrowseId: 'UCdistinctrelated1',
              rank: 1,
            ),
          ],
          latestRepeated.trackKey: [
            _candidate(
              videoId: 'DannyRel0001',
              artist: 'Danny Ocean',
              artistBrowseId: 'UCrepeatedrelated1',
              rank: 1,
            ),
          ],
          olderRepeated.trackKey: [
            _candidate(
              videoId: 'BadBunny001',
              artist: 'Bad Bunny',
              artistBrowseId: 'UColdduplicate001',
              rank: 0,
            ),
          ],
          topRepeated.trackKey: [
            _candidate(
              videoId: 'JBalvin0001',
              artist: 'J Balvin',
              artistBrowseId: 'UCtopduplicate0001',
              rank: 0,
            ),
          ],
        },
      );
      final source = RepositoryHomeArtistRecommendationSource(
        repository: repository,
      );

      final result = await source.load();

      expect(repository.relatedSeedKeys, [
        'latest-reik-track',
        'latest-paulo-track',
      ]);
      expect(result.artists.map((artist) => artist.name), [
        'Camila',
        'Danny Ocean',
      ]);
      expect(
        result.artists.map((artist) => artist.name),
        isNot(containsAll(<String>['Bad Bunny', 'J Balvin'])),
      );
    },
  );

  test(
    'refresh uses official artist-to-artist shelves and reuses their cache',
    () async {
      final reik = _seed(
        key: 'reik-track',
        artist: 'Reik',
        artistBrowseId: 'UCreikseedartist01',
      );
      final paulo = _seed(
        key: 'paulo-track',
        artist: 'Paulo Londra',
        artistBrowseId: 'UCpauloseedartist1',
      );
      final repository = _FakeRecommendationRepository(
        recentSeeds: [reik, paulo],
        related: {
          reik.trackKey: [
            _candidate(
              videoId: 'BadFallback1',
              artist: 'Bad Bunny',
              artistBrowseId: 'UCbadfallback0001',
              rank: 1,
            ),
          ],
          paulo.trackKey: [
            _candidate(
              videoId: 'BalvinFall01',
              artist: 'J Balvin',
              artistBrowseId: 'UCbalvinfallback1',
              rank: 1,
            ),
          ],
        },
      );
      final lookup = _FakeArtistProfileLookup({
        reik.artistBrowseIds.single!: InnerTubeArtistProfile(
          artist: InnerTubeArtist(
            browseId: reik.artistBrowseIds.single!,
            name: 'Reik',
          ),
          popularSongs: const [],
          albums: const [],
          singles: const [],
          relatedArtists: const [
            InnerTubeArtist(
              browseId: 'UCtommyrelated001',
              name: 'Tommy Torres',
              thumbnailUrl: 'https://img.test/tommy.jpg',
            ),
            InnerTubeArtist(
              browseId: 'UCaxelrelated0001',
              name: 'Axel',
              thumbnailUrl: 'https://img.test/axel.jpg',
            ),
          ],
        ),
        paulo.artistBrowseIds.single!: InnerTubeArtistProfile(
          artist: InnerTubeArtist(
            browseId: paulo.artistBrowseIds.single!,
            name: 'Paulo Londra',
          ),
          popularSongs: const [],
          albums: const [],
          singles: const [],
          relatedArtists: const [
            InnerTubeArtist(
              browseId: 'UClitrelated00001',
              name: 'LIT killah',
              thumbnailUrl: 'https://img.test/lit.jpg',
            ),
            InnerTubeArtist(
              browseId: 'UCmicrorelated001',
              name: 'Micro TDH',
              thumbnailUrl: 'https://img.test/micro.jpg',
            ),
          ],
        ),
      });
      final now = DateTime.utc(2026, 8, 25, 4);
      final source = RepositoryHomeArtistRecommendationSource(
        repository: repository,
        artistLookup: lookup,
        clock: () => now,
      );

      final initial = await source.load();
      expect(initial.artists.map((artist) => artist.name), [
        'Bad Bunny',
        'J Balvin',
      ]);

      final refreshed = await source.load(refresh: true);
      expect(refreshed.artists.map((artist) => artist.name), [
        'Tommy Torres',
        'LIT killah',
        'Axel',
        'Micro TDH',
      ]);
      expect(
        refreshed.artists.map((artist) => artist.name),
        isNot(containsAll(<String>['Bad Bunny', 'J Balvin'])),
      );
      expect(refreshed.artists.first.thumbnailUrl, endsWith('/tommy.jpg'));
      expect(lookup.requestedBrowseIds, [
        'UCreikseedartist01',
        'UCpauloseedartist1',
      ]);
      expect(repository.feeds, hasLength(2));

      final cachedOnly = RepositoryHomeArtistRecommendationSource(
        repository: repository,
        clock: () => now.add(const Duration(hours: 1)),
      );
      final fromCache = await cachedOnly.load();
      expect(
        fromCache.artists.map((artist) => artist.name),
        refreshed.artists.map((artist) => artist.name),
      );
      expect(fromCache.artists.first.thumbnailUrl, endsWith('/tommy.jpg'));
    },
  );
}

RecommendationSeed _seed({
  required String key,
  required String artist,
  required String artistBrowseId,
}) {
  return RecommendationSeed(
    trackKey: key,
    trackId: key,
    videoId: 'SeedVideo01',
    title: 'Semilla $key',
    artists: [artist],
    artistBrowseIds: [artistBrowseId],
    source: PlaybackEventSource.streaming,
    playCount: 1,
    totalListenedMs: 45000,
    completedCount: 0,
    lastPlayedAt: DateTime.utc(2026, 8, 24),
  );
}

RelatedTrackCandidate _candidate({
  required String videoId,
  required String artist,
  required String artistBrowseId,
  required int rank,
}) {
  return RelatedTrackCandidate(
    trackId: videoId,
    videoId: videoId,
    title: 'Candidata $videoId',
    artists: [artist],
    artistBrowseIds: [artistBrowseId],
    rank: rank,
  );
}

class _FakeRecommendationRepository implements RecommendationRepository {
  _FakeRecommendationRepository({
    this.topSeeds = const <RecommendationSeed>[],
    this.recentSeeds = const <RecommendationSeed>[],
    this.related = const <String, List<RelatedTrackCandidate>>{},
  });

  final List<RecommendationSeed> topSeeds;
  final List<RecommendationSeed> recentSeeds;
  final Map<String, List<RelatedTrackCandidate>> related;
  final Map<String, RecommendationFeedCache> feeds = {};
  int? topMinListenedMs;
  int? recentMinListenedMs;
  final List<String> relatedSeedKeys = [];
  final List<Duration> relatedTtls = [];
  final List<DateTime> relatedNow = [];

  @override
  int get generation => 0;

  @override
  Future<List<RecommendationSeed>> getTopSeeds({
    required int limit,
    DateTime? since,
    int minListenedMs = 30000,
  }) async {
    topMinListenedMs = minListenedMs;
    return topSeeds.take(limit).toList(growable: false);
  }

  @override
  Future<List<RecommendationSeed>> getRecentSeeds({
    required int limit,
    DateTime? since,
    int minListenedMs = 30000,
  }) async {
    recentMinListenedMs = minListenedMs;
    return recentSeeds.take(limit).toList(growable: false);
  }

  @override
  Future<List<RelatedTrackCandidate>> getRelatedCandidates(
    String seedKey, {
    required Duration ttl,
    required DateTime now,
  }) async {
    relatedSeedKeys.add(seedKey);
    relatedTtls.add(ttl);
    relatedNow.add(now);
    return related[seedKey] ?? const <RelatedTrackCandidate>[];
  }

  @override
  Future<Set<String>> getLibraryTrackKeys() async => const <String>{};

  @override
  Future<RecommendationFeedCache?> loadFeed(String feedKey) async =>
      feeds[feedKey];

  @override
  Future<bool> deleteFeed(
    String feedKey, {
    required int expectedGeneration,
  }) async => feeds.remove(feedKey) != null;

  @override
  Future<bool> replaceRelatedCandidates({
    required String seedKey,
    required List<RelatedTrackCandidate> candidates,
    required DateTime fetchedAt,
    required int expectedGeneration,
  }) async => true;

  @override
  Future<bool> saveFeed(
    RecommendationFeedCache feed, {
    required int expectedGeneration,
  }) async {
    feeds[feed.feedKey] = feed;
    return true;
  }
}

class _FakeArtistProfileLookup implements YouTubeMusicArtistProfileLookup {
  _FakeArtistProfileLookup(this.profiles);

  final Map<String, InnerTubeArtistProfile> profiles;
  final List<String> requestedBrowseIds = [];

  @override
  Future<InnerTubeArtistProfile> getArtistProfile(
    String artistBrowseId, {
    String? fallbackName,
    String? fallbackThumbnailUrl,
    int songLimit = 20,
    int releaseLimit = 20,
  }) async {
    requestedBrowseIds.add(artistBrowseId);
    final profile = profiles[artistBrowseId];
    if (profile == null) {
      throw StateError('Missing artist profile fixture: $artistBrowseId');
    }
    return profile;
  }
}
