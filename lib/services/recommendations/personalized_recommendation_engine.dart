import 'dart:async';

import 'recommendation_catalog.dart';
import 'recommendation_feed_models.dart';
import 'recommendation_repository.dart';
import 'recommendation_storage_models.dart';

typedef RecommendationClock = DateTime Function();

class PersonalizedRecommendationConfig {
  const PersonalizedRecommendationConfig({
    this.feedKey = 'personalized-home-v1',
    this.feedTtl = const Duration(hours: 6),
    this.relatedTtl = const Duration(days: 7),
    this.artistReleaseTtl = const Duration(hours: 6),
    this.recentWindow = const Duration(days: 30),
    this.minimumDistinctSeeds = 1,
    this.historyScanLimit = 500,
    this.recentSeedLimit = 50,
    this.topSeedLimit = 8,
    this.becauseSeedCount = 2,
    this.artistSeedLimit = 6,
    this.candidateFetchLimit = 30,
    this.artistReleaseLimit = 8,
    this.networkConcurrency = 3,
    this.maxTracksPerArtist = 2,
    this.continueMinimum = 1,
    this.continueMaximum = 8,
    this.becauseMinimum = 3,
    this.becauseMaximum = 7,
    this.mixesMinimum = 1,
    this.mixesMaximum = 6,
    this.newForYouMinimum = 1,
    this.newForYouMaximum = 8,
    this.discoveryMinimum = 4,
    this.discoveryMaximum = 12,
  }) : assert(minimumDistinctSeeds >= 1),
       assert(historyScanLimit >= minimumDistinctSeeds),
       assert(recentSeedLimit >= 1),
       assert(topSeedLimit >= 1),
       assert(becauseSeedCount >= 0),
       assert(artistSeedLimit >= 0),
       assert(candidateFetchLimit >= 1),
       assert(artistReleaseLimit >= 1),
       assert(networkConcurrency >= 1),
       assert(maxTracksPerArtist >= 1),
       assert(continueMinimum >= 0 && continueMaximum >= continueMinimum),
       assert(becauseMinimum >= 0 && becauseMaximum >= becauseMinimum),
       assert(mixesMinimum >= 0 && mixesMaximum >= mixesMinimum),
       assert(newForYouMinimum >= 0 && newForYouMaximum >= newForYouMinimum),
       assert(discoveryMinimum >= 0 && discoveryMaximum >= discoveryMinimum);

  final String feedKey;
  final Duration feedTtl;
  final Duration relatedTtl;
  final Duration artistReleaseTtl;
  final Duration recentWindow;
  final int minimumDistinctSeeds;
  final int historyScanLimit;
  final int recentSeedLimit;
  final int topSeedLimit;
  final int becauseSeedCount;
  final int artistSeedLimit;
  final int candidateFetchLimit;
  final int artistReleaseLimit;
  final int networkConcurrency;
  final int maxTracksPerArtist;
  final int continueMinimum;
  final int continueMaximum;
  final int becauseMinimum;
  final int becauseMaximum;
  final int mixesMinimum;
  final int mixesMaximum;
  final int newForYouMinimum;
  final int newForYouMaximum;
  final int discoveryMinimum;
  final int discoveryMaximum;
}

class CachedPersonalizedRecommendationFeed {
  const CachedPersonalizedRecommendationFeed({
    required this.feed,
    required this.isExpired,
  });

  final PersonalizedRecommendationFeed feed;
  final bool isExpired;
}

/// Builds a local, deterministic ranking from YouTube candidate pools.
///
/// YouTube decides which candidates are related, while BStream decides which
/// ones are useful for the current listener: recent/ever exclusions, global
/// deduplication, artist diversity, section quotas and cache policy all live
/// here. An empty result is intentional during cold start; the application can
/// continue showing the generic YouTube Music home separately.
class PersonalizedRecommendationEngine {
  PersonalizedRecommendationEngine({
    required this.repository,
    required this.catalog,
    this.config = const PersonalizedRecommendationConfig(),
    RecommendationClock? clock,
  }) : _clock = clock ?? DateTime.now;

  final RecommendationRepository repository;
  final RecommendationCatalog catalog;
  final PersonalizedRecommendationConfig config;
  final RecommendationClock _clock;
  final Map<String, _CachedArtistReleases> _artistReleaseCache =
      <String, _CachedArtistReleases>{};

  Future<CachedPersonalizedRecommendationFeed?> loadCachedFeed() async {
    final cache = await repository.loadFeed(config.feedKey);
    if (cache == null) {
      return null;
    }
    final feed = PersonalizedRecommendationFeed.fromJson(cache.payload);
    if (feed == null) {
      return null;
    }
    final generation = repository.generation;
    try {
      final seeds = await repository.getTopSeeds(
        limit: config.minimumDistinctSeeds,
        minListenedMs: 0,
      );
      if (repository.generation != generation) {
        return null;
      }
      if (_uniqueSeeds(seeds).length < config.minimumDistinctSeeds) {
        await _deleteFeedBestEffort(generation);
        return null;
      }
    } on Object {
      // A temporarily unavailable history store must not make an otherwise
      // valid offline cache unusable. The background refresh will retry it.
    }
    return CachedPersonalizedRecommendationFeed(
      feed: feed,
      isExpired: cache.isExpiredAt(_clock().toUtc()),
    );
  }

  Future<PersonalizedRecommendationFeed> refresh({
    bool forceNetwork = false,
  }) async {
    final generation = repository.generation;
    final now = _clock().toUtc();
    final previousFeed = await _loadPreviousFeedBestEffort();
    final recentSince = now.subtract(config.recentWindow);
    final history = await Future.wait<List<RecommendationSeed>>(<
      Future<List<RecommendationSeed>>
    >[
      repository.getTopSeeds(limit: config.historyScanLimit, minListenedMs: 0),
      repository.getRecentSeeds(
        limit: config.recentSeedLimit,
        since: recentSince,
        minListenedMs: 0,
      ),
    ]);
    final libraryKeys = await repository.getLibraryTrackKeys();
    final topSeeds = _uniqueSeeds(history[0]);
    final recentSeeds = _uniqueSeeds(history[1]);
    final allSeeds = _uniqueSeeds(<RecommendationSeed>[
      ...topSeeds,
      ...recentSeeds,
    ]);

    if (allSeeds.length < config.minimumDistinctSeeds) {
      final emptyFeed = PersonalizedRecommendationFeed(
        generatedAt: now,
        sections: const <PersonalizedRecommendationSection>[],
      );
      await _deleteFeedBestEffort(generation);
      return emptyFeed;
    }

    // Local-only imports still belong in Continue, but they must not consume
    // the finite slots used for `/next`. Skip them before applying the limit
    // so later streaming/downloaded YouTube seeds remain eligible.
    final queryableSeeds = _balancedSeeds(
      recentSeeds.where((seed) => seed.canQueryYouTube),
      topSeeds.where((seed) => seed.canQueryYouTube),
      limit: config.topSeedLimit,
    );
    final pools = await _mapConcurrent<RecommendationSeed, _SeedCandidatePool>(
      queryableSeeds,
      concurrency: config.networkConcurrency,
      mapper: (seed, index) => _candidatePool(
        seed,
        seedIndex: index,
        now: now,
        generation: generation,
        forceNetwork: forceNetwork,
      ),
    );

    final sections = <PersonalizedRecommendationSection>[];
    final allocation = _TrackAllocation(
      maxTracksPerArtist: config.maxTracksPerArtist,
    );

    final continueItems = allocation.trySelect(
      recentSeeds.map(PersonalizedTrackItem.fromSeed),
      minimum: config.continueMinimum,
      maximum: config.continueMaximum,
    );
    if (continueItems.isNotEmpty) {
      sections.add(
        PersonalizedRecommendationSection(
          kind: PersonalizedSectionKind.continueListening,
          title: 'Seguir escuchando',
          items: continueItems,
        ),
      );
    }

    final recentKeys = recentSeeds.map((seed) => seed.trackKey).toSet();
    for (final pool in pools.take(config.becauseSeedCount)) {
      final ranked = pool.candidates.toList(growable: false)
        ..sort(_compareCandidates);
      final becauseItems = allocation.trySelect(
        ranked
            .where((candidate) => !recentKeys.contains(candidate.trackKey))
            .map(PersonalizedTrackItem.fromCandidate),
        minimum: config.becauseMinimum,
        maximum: config.becauseMaximum,
      );
      if (becauseItems.isEmpty) {
        continue;
      }
      sections.add(
        PersonalizedRecommendationSection(
          kind: PersonalizedSectionKind.becauseYouListened,
          title: 'Porque escuchaste ${pool.seed.title}',
          seedTrackKey: pool.seed.trackKey,
          seedTitle: pool.seed.title,
          items: becauseItems,
        ),
      );
    }

    final mixes = _buildMixes(queryableSeeds, pools);
    if (mixes.length >= config.mixesMinimum) {
      sections.add(
        PersonalizedRecommendationSection(
          kind: PersonalizedSectionKind.mixes,
          title: 'Tus mixes',
          items: mixes.take(config.mixesMaximum).toList(growable: false),
        ),
      );
    }

    final newForYou = await _buildNewForYou(
      recentSeeds,
      allSeeds,
      now: now,
      forceNetwork: forceNetwork,
    );
    if (newForYou.items.length >= config.newForYouMinimum) {
      sections.add(
        PersonalizedRecommendationSection(
          kind: PersonalizedSectionKind.newForYou,
          title: 'Nuevos para ti',
          items: newForYou.items
              .take(config.newForYouMaximum)
              .toList(growable: false),
        ),
      );
    }

    final everKeys = <String>{
      ...allSeeds.map((seed) => seed.trackKey),
      ...libraryKeys,
    };
    final discoveryCandidates = _rankDiscovery(
      pools,
    ).where((candidate) => !everKeys.contains(candidate.trackKey));
    final discoveryItems = allocation.trySelect(
      discoveryCandidates.map(PersonalizedTrackItem.fromCandidate),
      minimum: config.discoveryMinimum,
      maximum: config.discoveryMaximum,
    );
    if (discoveryItems.isNotEmpty) {
      sections.add(
        PersonalizedRecommendationSection(
          kind: PersonalizedSectionKind.discovery,
          title: 'Descubrimiento para ti',
          items: discoveryItems,
        ),
      );
    }

    final candidateSourcesUnavailable =
        pools.isNotEmpty &&
        pools.every((pool) => pool.networkFailed && pool.candidates.isEmpty);
    final resolvedSections = _mergePreviousNetworkSections(
      current: sections,
      previous: previousFeed,
      candidateSourcesUnavailable: candidateSourcesUnavailable,
      releaseSourcesUnavailable: newForYou.sourcesUnavailable,
    );
    final feed = PersonalizedRecommendationFeed(
      generatedAt: now,
      sections: resolvedSections,
    );
    if (repository.generation != generation) {
      return PersonalizedRecommendationFeed(
        generatedAt: now,
        sections: const <PersonalizedRecommendationSection>[],
      );
    }
    await _saveFeedBestEffort(feed, now, generation);
    return feed;
  }

  List<PersonalizedRecommendationSection> _mergePreviousNetworkSections({
    required List<PersonalizedRecommendationSection> current,
    required PersonalizedRecommendationFeed? previous,
    required bool candidateSourcesUnavailable,
    required bool releaseSourcesUnavailable,
  }) {
    if (previous == null ||
        (!candidateSourcesUnavailable && !releaseSourcesUnavailable)) {
      return current;
    }

    Iterable<PersonalizedRecommendationSection> sectionsFor(
      PersonalizedSectionKind kind,
    ) {
      final usePrevious = switch (kind) {
        PersonalizedSectionKind.becauseYouListened ||
        PersonalizedSectionKind.mixes ||
        PersonalizedSectionKind.discovery => candidateSourcesUnavailable,
        PersonalizedSectionKind.newForYou => releaseSourcesUnavailable,
        PersonalizedSectionKind.continueListening => false,
      };
      final source = usePrevious ? previous.sections : current;
      return source.where((section) => section.kind == kind);
    }

    // Continue is always rebuilt from the latest local history. Only the
    // network-dependent families fall back, independently, when every source
    // in that family is unavailable. This preserves a rich offline cache
    // without letting one removed artist freeze unrelated successful data.
    final seenItems = <String>{};
    final result = <PersonalizedRecommendationSection>[];
    for (final kind in PersonalizedSectionKind.values) {
      for (final section in sectionsFor(kind)) {
        final items = section.items
            .where((item) => seenItems.add(_recommendationItemKey(item)))
            .toList(growable: false);
        if (items.isEmpty) {
          continue;
        }
        result.add(
          PersonalizedRecommendationSection(
            kind: section.kind,
            title: section.title,
            seedTrackKey: section.seedTrackKey,
            seedTitle: section.seedTitle,
            items: items,
          ),
        );
      }
    }
    return result;
  }

  Future<PersonalizedRecommendationFeed?> _loadPreviousFeedBestEffort() async {
    try {
      final cache = await repository.loadFeed(config.feedKey);
      return cache == null
          ? null
          : PersonalizedRecommendationFeed.fromJson(cache.payload);
    } on Object {
      return null;
    }
  }

  Future<_SeedCandidatePool> _candidatePool(
    RecommendationSeed seed, {
    required int seedIndex,
    required DateTime now,
    required int generation,
    required bool forceNetwork,
  }) async {
    var cached = const <RelatedTrackCandidate>[];
    try {
      cached = await repository.getRelatedCandidates(
        seed.trackKey,
        ttl: config.relatedTtl,
        now: now,
      );
    } on Object {
      // Network can still recover from an unavailable local cache.
    }
    if (!forceNetwork) {
      if (cached.isNotEmpty) {
        return _SeedCandidatePool(
          seed: seed,
          seedIndex: seedIndex,
          candidates: _uniqueCandidates(cached, seed.trackKey),
          automixPlaylistId: _defaultMixPlaylistId(seed),
          networkFailed: false,
        );
      }
    }

    try {
      final response = await catalog.getCandidates(
        seed,
        limit: config.candidateFetchLimit,
      );
      final candidates = _uniqueCandidates(response.tracks, seed.trackKey);
      if (candidates.isNotEmpty && repository.generation == generation) {
        try {
          await repository.replaceRelatedCandidates(
            seedKey: seed.trackKey,
            candidates: candidates,
            fetchedAt: now,
            expectedGeneration: generation,
          );
        } on Object {
          // The fresh candidates remain useful for this render even when the
          // optional offline cache cannot be updated.
        }
      }
      return _SeedCandidatePool(
        seed: seed,
        seedIndex: seedIndex,
        candidates: candidates,
        automixPlaylistId:
            _nonEmpty(response.automixPlaylistId) ??
            _defaultMixPlaylistId(seed),
        networkFailed: false,
      );
    } on Object {
      return _SeedCandidatePool(
        seed: seed,
        seedIndex: seedIndex,
        candidates: _uniqueCandidates(cached, seed.trackKey),
        automixPlaylistId: _defaultMixPlaylistId(seed),
        networkFailed: true,
      );
    }
  }

  List<PersonalizedCollectionItem> _buildMixes(
    List<RecommendationSeed> seeds,
    List<_SeedCandidatePool> pools,
  ) {
    final poolByKey = <String, _SeedCandidatePool>{
      for (final pool in pools) pool.seed.trackKey: pool,
    };
    final seen = <String>{};
    final result = <PersonalizedCollectionItem>[];
    for (final seed in seeds) {
      final rawPlaylistId =
          _nonEmpty(poolByKey[seed.trackKey]?.automixPlaylistId) ??
          _defaultMixPlaylistId(seed);
      final playlistId = _playlistIdWithoutBrowsePrefix(rawPlaylistId);
      if (playlistId == null || !seen.add(playlistId)) {
        continue;
      }
      result.add(
        PersonalizedCollectionItem(
          id: 'mix:$playlistId',
          title: 'Mix de ${seed.title}',
          subtitle: seed.artists.join(', '),
          thumbnailUrl: seed.thumbnailUrl,
          browseId: 'VL$playlistId',
          playlistId: playlistId,
          kind: PersonalizedCollectionKind.mix,
          artists: seed.artists,
          artistBrowseIds: seed.artistBrowseIds,
        ),
      );
      if (result.length >= config.mixesMaximum) {
        break;
      }
    }
    return result;
  }

  Future<_NewForYouResult> _buildNewForYou(
    List<RecommendationSeed> recentSeeds,
    List<RecommendationSeed> allSeeds, {
    required DateTime now,
    required bool forceNetwork,
  }) async {
    final artistSeeds = _balancedArtistSeeds(
      recentSeeds,
      allSeeds,
      limit: config.artistSeedLimit,
    );
    final responses = await _mapConcurrent<_ArtistSeed, _ArtistReleasePool>(
      artistSeeds,
      concurrency: config.networkConcurrency,
      mapper: (artist, _) => _artistReleasesBestEffort(
        artist,
        now: now,
        forceNetwork: forceNetwork,
      ),
    );
    final heardAlbums = <String>{
      for (final seed in allSeeds)
        if (_normalized(seed.album).isNotEmpty) _normalized(seed.album),
    };
    final heardTitles = <String>{
      for (final seed in allSeeds) _normalized(seed.title),
    };
    final ranked = <_RankedRelease>[];
    for (
      var artistIndex = 0;
      artistIndex < responses.length;
      artistIndex += 1
    ) {
      final response = responses[artistIndex];
      for (
        var releaseIndex = 0;
        releaseIndex < response.releases.length;
        releaseIndex += 1
      ) {
        final release = response.releases[releaseIndex];
        final normalizedTitle = _normalized(release.title);
        if (heardAlbums.contains(normalizedTitle) ||
            heardTitles.contains(normalizedTitle)) {
          continue;
        }
        ranked.add(
          _RankedRelease(
            release: release,
            fallbackArtist: response.artist,
            artistIndex: artistIndex,
            releaseIndex: releaseIndex,
          ),
        );
      }
    }
    ranked.sort((left, right) {
      final artistComparison = left.artistIndex.compareTo(right.artistIndex);
      if (artistComparison != 0) {
        return artistComparison;
      }
      final releaseComparison = left.releaseIndex.compareTo(right.releaseIndex);
      if (releaseComparison != 0) {
        return releaseComparison;
      }
      return left.release.browseId.compareTo(right.release.browseId);
    });

    final seen = <String>{};
    final artistCounts = <String, int>{};
    final result = <PersonalizedCollectionItem>[];
    for (final rankedRelease in ranked) {
      final release = rankedRelease.release;
      if (!seen.add(release.browseId)) {
        continue;
      }
      final artistKeys = _artistKeys(release.artists, release.artistBrowseIds);
      final effectiveArtistKeys = artistKeys.isEmpty
          ? <String>['id:${rankedRelease.fallbackArtist.browseId}']
          : artistKeys;
      if (effectiveArtistKeys.any(
        (key) => (artistCounts[key] ?? 0) >= config.maxTracksPerArtist,
      )) {
        continue;
      }
      for (final key in effectiveArtistKeys) {
        artistCounts[key] = (artistCounts[key] ?? 0) + 1;
      }
      final artists = release.artists.isEmpty
          ? <String>[rankedRelease.fallbackArtist.name]
          : release.artists;
      result.add(
        PersonalizedCollectionItem(
          id: 'release:${release.browseId}',
          title: release.title,
          subtitle: <String?>[
            release.type,
            release.year,
          ].map(_nonEmpty).whereType<String>().join(' · '),
          thumbnailUrl: release.thumbnailUrl,
          browseId: release.browseId,
          playlistId: release.playlistId,
          kind: PersonalizedCollectionKind.release,
          artists: artists,
          artistBrowseIds: release.artistBrowseIds,
          year: release.year,
        ),
      );
      if (result.length >= config.newForYouMaximum) {
        break;
      }
    }
    return _NewForYouResult(
      items: result,
      sourcesUnavailable:
          responses.isNotEmpty &&
          responses.every(
            (response) => response.networkFailed && response.releases.isEmpty,
          ),
    );
  }

  Future<_ArtistReleasePool> _artistReleasesBestEffort(
    _ArtistSeed artist, {
    required DateTime now,
    required bool forceNetwork,
  }) async {
    final cached = _artistReleaseCache[artist.browseId];
    if (!forceNetwork && cached != null && cached.expiresAt.isAfter(now)) {
      return _ArtistReleasePool(
        artist: artist,
        releases: cached.releases,
        networkFailed: false,
      );
    }
    try {
      final releases = await catalog.getArtistReleases(
        artist.browseId,
        limit: config.artistReleaseLimit,
      );
      _artistReleaseCache[artist.browseId] = _CachedArtistReleases(
        releases: releases,
        expiresAt: now.add(config.artistReleaseTtl),
      );
      return _ArtistReleasePool(
        artist: artist,
        releases: releases,
        networkFailed: false,
      );
    } on Object {
      if (cached != null) {
        return _ArtistReleasePool(
          artist: artist,
          releases: cached.releases,
          networkFailed: true,
        );
      }
      return _ArtistReleasePool(
        artist: artist,
        releases: const <RecommendationRelease>[],
        networkFailed: true,
      );
    }
  }

  List<RelatedTrackCandidate> _rankDiscovery(List<_SeedCandidatePool> pools) {
    final aggregated = <String, _AggregatedCandidate>{};
    for (final pool in pools) {
      for (final candidate in pool.candidates) {
        final current = aggregated[candidate.trackKey];
        if (current == null) {
          aggregated[candidate.trackKey] = _AggregatedCandidate(
            candidate: candidate,
            appearances: 1,
            bestSeedIndex: pool.seedIndex,
            bestRank: candidate.rank,
          );
        } else {
          current.appearances += 1;
          if (pool.seedIndex < current.bestSeedIndex ||
              (pool.seedIndex == current.bestSeedIndex &&
                  candidate.rank < current.bestRank)) {
            current.bestSeedIndex = pool.seedIndex;
            current.bestRank = candidate.rank;
            current.candidate = candidate;
          }
        }
      }
    }
    final ranked = aggregated.values.toList(growable: false)
      ..sort((left, right) {
        final appearanceComparison = right.appearances.compareTo(
          left.appearances,
        );
        if (appearanceComparison != 0) {
          return appearanceComparison;
        }
        final seedComparison = left.bestSeedIndex.compareTo(
          right.bestSeedIndex,
        );
        if (seedComparison != 0) {
          return seedComparison;
        }
        final rankComparison = left.bestRank.compareTo(right.bestRank);
        if (rankComparison != 0) {
          return rankComparison;
        }
        return left.candidate.trackKey.compareTo(right.candidate.trackKey);
      });
    return ranked.map((item) => item.candidate).toList(growable: false);
  }

  Future<void> _saveFeedBestEffort(
    PersonalizedRecommendationFeed feed,
    DateTime now,
    int generation,
  ) async {
    if (repository.generation != generation) {
      return;
    }
    try {
      await repository.saveFeed(
        RecommendationFeedCache(
          feedKey: config.feedKey,
          payload: feed.toJson(),
          generatedAt: now,
          expiresAt: now.add(config.feedTtl),
        ),
        expectedGeneration: generation,
      );
    } on Object {
      // Personalization is an enhancement. A cache write must not replace a
      // usable in-memory feed with an error state.
    }
  }

  Future<void> _deleteFeedBestEffort(int generation) async {
    if (repository.generation != generation) {
      return;
    }
    try {
      await repository.deleteFeed(
        config.feedKey,
        expectedGeneration: generation,
      );
    } on Object {
      // The in-memory empty result remains authoritative for this render. A
      // later refresh can retry optional cache cleanup.
    }
  }
}

class _TrackAllocation {
  _TrackAllocation({required this.maxTracksPerArtist});

  final int maxTracksPerArtist;
  Set<String> _seenTrackKeys = <String>{};

  List<PersonalizedTrackItem> trySelect(
    Iterable<PersonalizedTrackItem> candidates, {
    required int minimum,
    required int maximum,
  }) {
    if (maximum == 0) {
      return const <PersonalizedTrackItem>[];
    }
    final stagedKeys = Set<String>.of(_seenTrackKeys);
    // Artist diversity is a section-level policy. Track identity remains
    // global so the same video can never leak into another section.
    final stagedArtistCounts = <String, int>{};
    final selected = <PersonalizedTrackItem>[];
    for (final candidate in candidates) {
      if (!stagedKeys.add(candidate.trackKey)) {
        continue;
      }
      final artistKeys = _artistKeys(
        candidate.artists,
        candidate.artistBrowseIds,
      );
      if (artistKeys.any(
        (artist) => (stagedArtistCounts[artist] ?? 0) >= maxTracksPerArtist,
      )) {
        stagedKeys.remove(candidate.trackKey);
        continue;
      }
      for (final artist in artistKeys) {
        stagedArtistCounts[artist] = (stagedArtistCounts[artist] ?? 0) + 1;
      }
      selected.add(candidate);
      if (selected.length >= maximum) {
        break;
      }
    }
    if (selected.length < minimum) {
      return const <PersonalizedTrackItem>[];
    }
    _seenTrackKeys = stagedKeys;
    return List<PersonalizedTrackItem>.unmodifiable(selected);
  }
}

class _SeedCandidatePool {
  const _SeedCandidatePool({
    required this.seed,
    required this.seedIndex,
    required this.candidates,
    required this.automixPlaylistId,
    required this.networkFailed,
  });

  final RecommendationSeed seed;
  final int seedIndex;
  final List<RelatedTrackCandidate> candidates;
  final String? automixPlaylistId;
  final bool networkFailed;
}

class _AggregatedCandidate {
  _AggregatedCandidate({
    required this.candidate,
    required this.appearances,
    required this.bestSeedIndex,
    required this.bestRank,
  });

  RelatedTrackCandidate candidate;
  int appearances;
  int bestSeedIndex;
  int bestRank;
}

class _ArtistSeed {
  const _ArtistSeed({required this.browseId, required this.name});

  final String browseId;
  final String name;
}

class _ArtistReleasePool {
  const _ArtistReleasePool({
    required this.artist,
    required this.releases,
    required this.networkFailed,
  });

  final _ArtistSeed artist;
  final List<RecommendationRelease> releases;
  final bool networkFailed;
}

class _NewForYouResult {
  const _NewForYouResult({
    required this.items,
    required this.sourcesUnavailable,
  });

  final List<PersonalizedCollectionItem> items;
  final bool sourcesUnavailable;
}

class _CachedArtistReleases {
  const _CachedArtistReleases({
    required this.releases,
    required this.expiresAt,
  });

  final List<RecommendationRelease> releases;
  final DateTime expiresAt;
}

class _RankedRelease {
  const _RankedRelease({
    required this.release,
    required this.fallbackArtist,
    required this.artistIndex,
    required this.releaseIndex,
  });

  final RecommendationRelease release;
  final _ArtistSeed fallbackArtist;
  final int artistIndex;
  final int releaseIndex;
}

List<RecommendationSeed> _uniqueSeeds(List<RecommendationSeed> seeds) {
  final unique = <String, RecommendationSeed>{};
  for (final seed in seeds) {
    unique.putIfAbsent(seed.trackKey, () => seed);
  }
  return unique.values.toList(growable: false);
}

/// Reserves half of a bounded seed budget for recent listening, then fills
/// the remainder with long-term favorites and frequency. Duplicate tracks do
/// not consume a slot, and either side can fill unused capacity from the
/// other. This keeps Home responsive to a new listen without discarding the
/// user's established taste profile.
List<RecommendationSeed> _balancedSeeds(
  Iterable<RecommendationSeed> recent,
  Iterable<RecommendationSeed> top, {
  required int limit,
}) {
  if (limit <= 0) {
    return const <RecommendationSeed>[];
  }
  final recentList = recent.toList(growable: false);
  final result = <RecommendationSeed>[];
  final seen = <String>{};

  void append(Iterable<RecommendationSeed> values, {int? maximum}) {
    for (final seed in values) {
      if (result.length >= limit ||
          (maximum != null && result.length >= maximum)) {
        return;
      }
      if (seen.add(seed.trackKey)) {
        result.add(seed);
      }
    }
  }

  append(recentList, maximum: (limit + 1) ~/ 2);
  append(top);
  append(recentList);
  return List<RecommendationSeed>.unmodifiable(result);
}

List<RelatedTrackCandidate> _uniqueCandidates(
  List<RelatedTrackCandidate> candidates,
  String seedTrackKey,
) {
  final unique = <String, RelatedTrackCandidate>{};
  for (final candidate in candidates) {
    if (candidate.trackKey == seedTrackKey) {
      continue;
    }
    final current = unique[candidate.trackKey];
    if (current == null || candidate.rank < current.rank) {
      unique[candidate.trackKey] = candidate;
    }
  }
  final result = unique.values.toList(growable: false)
    ..sort(_compareCandidates);
  return result;
}

int _compareCandidates(
  RelatedTrackCandidate left,
  RelatedTrackCandidate right,
) {
  final rankComparison = left.rank.compareTo(right.rank);
  if (rankComparison != 0) {
    return rankComparison;
  }
  return left.trackKey.compareTo(right.trackKey);
}

Iterable<_ArtistSeed> _artistSeeds(List<RecommendationSeed> seeds) sync* {
  final seen = <String>{};
  for (final seed in seeds) {
    for (var index = 0; index < seed.artistBrowseIds.length; index += 1) {
      final browseId = _nonEmpty(seed.artistBrowseIds[index]);
      if (browseId == null || !seen.add(browseId)) {
        continue;
      }
      final name = index < seed.artists.length
          ? seed.artists[index].trim()
          : seed.artists.join(', ').trim();
      yield _ArtistSeed(
        browseId: browseId,
        name: name.isEmpty ? 'Artista' : name,
      );
    }
  }
}

List<_ArtistSeed> _balancedArtistSeeds(
  List<RecommendationSeed> recent,
  List<RecommendationSeed> all, {
  required int limit,
}) {
  if (limit <= 0) {
    return const <_ArtistSeed>[];
  }
  final recentArtists = _artistSeeds(recent).toList(growable: false);
  final topArtists = _artistSeeds(all).toList(growable: false);
  final result = <_ArtistSeed>[];
  final seen = <String>{};

  void append(Iterable<_ArtistSeed> values, {int? maximum}) {
    for (final artist in values) {
      if (result.length >= limit ||
          (maximum != null && result.length >= maximum)) {
        return;
      }
      if (seen.add(artist.browseId)) {
        result.add(artist);
      }
    }
  }

  append(recentArtists, maximum: (limit + 1) ~/ 2);
  append(topArtists);
  append(recentArtists);
  return List<_ArtistSeed>.unmodifiable(result);
}

List<String> _artistKeys(List<String> artists, List<String?> artistBrowseIds) {
  final keys = <String>{};
  final length = artists.length > artistBrowseIds.length
      ? artists.length
      : artistBrowseIds.length;
  for (var index = 0; index < length; index += 1) {
    final browseId = index < artistBrowseIds.length
        ? _nonEmpty(artistBrowseIds[index])
        : null;
    if (browseId != null) {
      keys.add('id:$browseId');
      continue;
    }
    if (index < artists.length) {
      final name = _normalized(artists[index]);
      if (name.isNotEmpty) {
        keys.add('name:$name');
      }
    }
  }
  return keys.toList(growable: false)..sort();
}

String? _defaultMixPlaylistId(RecommendationSeed seed) {
  final videoId = _nonEmpty(seed.videoId);
  return videoId == null ? null : 'RDAMVM$videoId';
}

String? _playlistIdWithoutBrowsePrefix(String? value) {
  final normalized = _nonEmpty(value);
  if (normalized == null) {
    return null;
  }
  if (normalized.startsWith('VL') && normalized.length > 2) {
    return normalized.substring(2);
  }
  return normalized;
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _normalized(String? value) {
  return value?.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ') ?? '';
}

String _recommendationItemKey(PersonalizedRecommendationItem item) {
  return switch (item) {
    PersonalizedTrackItem() => 'track:${item.trackKey}',
    PersonalizedCollectionItem() => 'collection:${item.browseId}',
  };
}

/// Runs at most [concurrency] asynchronous operations at once while preserving
/// the exact input order in the returned list.
Future<List<R>> _mapConcurrent<T, R>(
  List<T> values, {
  required int concurrency,
  required Future<R> Function(T value, int index) mapper,
}) async {
  if (values.isEmpty) {
    return <R>[];
  }
  final results = List<R?>.filled(values.length, null);
  var nextIndex = 0;

  Future<void> worker() async {
    while (true) {
      final index = nextIndex;
      if (index >= values.length) {
        return;
      }
      nextIndex += 1;
      results[index] = await mapper(values[index], index);
    }
  }

  await Future.wait<void>(<Future<void>>[
    for (
      var index = 0;
      index < concurrency && index < values.length;
      index += 1
    )
      worker(),
  ]);
  return List<R>.unmodifiable(results.cast<R>());
}
