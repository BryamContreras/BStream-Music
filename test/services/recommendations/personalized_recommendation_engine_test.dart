import 'dart:async';

import 'package:bstream_music/services/recommendations/recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 21, 12);

  group('PersonalizedRecommendationEngine', () {
    test('returns an empty personalized feed during cold start', () async {
      final repository = _FakeRepository();
      final catalog = _FakeCatalog();
      final engine = PersonalizedRecommendationEngine(
        repository: repository,
        catalog: catalog,
        clock: () => now,
      );

      final feed = await engine.refresh();

      expect(feed.sections, isEmpty);
      expect(catalog.candidateCalls, isEmpty);
      expect(repository.savedFeeds, isEmpty);
    });

    test('starts personalizing after the first qualifying playback', () async {
      final seed = _seed(1);
      final engine = PersonalizedRecommendationEngine(
        repository: _FakeRepository(
          top: <RecommendationSeed>[seed],
          recent: <RecommendationSeed>[seed],
        ),
        catalog: _FakeCatalog(),
        clock: () => now,
      );

      final feed = await engine.refresh();

      expect(feed.isNotEmpty, isTrue);
      expect(
        feed.sections.map((section) => section.kind),
        contains(PersonalizedSectionKind.continueListening),
      );
    });

    test('local-only seeds do not crowd out a later YouTube seed', () async {
      final remote = _seed(99);
      final localSeeds = <RecommendationSeed>[
        for (var index = 0; index < 8; index += 1)
          RecommendationSeed(
            trackKey: 'local-$index',
            trackId: 'local-$index',
            title: 'Local $index',
            artists: const <String>['Imported Artist'],
            source: PlaybackEventSource.local,
            playCount: 10,
            totalListenedMs: 600000,
            completedCount: 5,
            lastPlayedAt: now.subtract(Duration(minutes: index)),
            isFavorite: true,
          ),
      ];
      final catalog = _FakeCatalog();
      final engine = PersonalizedRecommendationEngine(
        repository: _FakeRepository(
          top: <RecommendationSeed>[...localSeeds, remote],
        ),
        catalog: catalog,
        config: const PersonalizedRecommendationConfig(
          continueMinimum: 99,
          continueMaximum: 99,
          becauseSeedCount: 0,
          artistSeedLimit: 0,
          newForYouMinimum: 99,
          newForYouMaximum: 99,
          discoveryMinimum: 99,
          discoveryMaximum: 99,
        ),
        clock: () => now,
      );

      await engine.refresh(forceNetwork: true);

      expect(catalog.candidateCalls, <String>[remote.trackKey]);
    });

    test(
      'a new listen shares radio and artist slots with all-time favorites',
      () async {
        final popular = <RecommendationSeed>[
          for (var index = 1; index <= 8; index += 1)
            _seed(index, artist: 'Popular $index', artistId: 'UCpopular$index'),
        ];
        final latest = _seed(
          99,
          artist: 'Recently discovered',
          artistId: 'UCrecentlyDiscovered',
        );
        final catalog = _FakeCatalog();
        final engine = PersonalizedRecommendationEngine(
          repository: _FakeRepository(
            top: popular,
            recent: <RecommendationSeed>[latest],
          ),
          catalog: catalog,
          config: const PersonalizedRecommendationConfig(
            topSeedLimit: 4,
            artistSeedLimit: 2,
            continueMinimum: 99,
            continueMaximum: 99,
            becauseSeedCount: 0,
            newForYouMinimum: 99,
            newForYouMaximum: 99,
            discoveryMinimum: 99,
            discoveryMaximum: 99,
          ),
          clock: () => now,
        );

        await engine.refresh(forceNetwork: true);

        expect(catalog.candidateCalls, contains(latest.trackKey));
        expect(catalog.artistReleaseCalls, contains('UCrecentlyDiscovered'));
        expect(catalog.candidateCalls.length, 4);
        expect(catalog.artistReleaseCalls.length, 2);
      },
    );

    test('builds every personalized section from qualifying history', () async {
      final first = _seed(1, artist: 'Seed One', artistId: 'UCseedOne');
      final second = _seed(2, artist: 'Seed Two', artistId: 'UCseedTwo');
      final repository = _FakeRepository(
        top: <RecommendationSeed>[first, second],
        recent: <RecommendationSeed>[first, second],
      );
      final catalog = _FakeCatalog(
        candidates: <String, List<RelatedTrackCandidate>>{
          first.trackKey: <RelatedTrackCandidate>[
            _candidate(11, rank: 0, artist: 'Because A'),
            _candidate(12, rank: 1, artist: 'Because B'),
            _candidate(13, rank: 2, artist: 'Because C'),
          ],
          second.trackKey: <RelatedTrackCandidate>[
            _candidate(21, rank: 0, artist: 'Discover A'),
            _candidate(22, rank: 1, artist: 'Discover B'),
            _candidate(23, rank: 2, artist: 'Discover C'),
            _candidate(24, rank: 3, artist: 'Discover D'),
          ],
        },
        releases: <String, List<RecommendationRelease>>{
          'UCseedOne': <RecommendationRelease>[
            _release(1, artist: 'Seed One', artistId: 'UCseedOne'),
          ],
          'UCseedTwo': <RecommendationRelease>[
            _release(2, artist: 'Seed Two', artistId: 'UCseedTwo'),
          ],
        },
      );
      final engine = PersonalizedRecommendationEngine(
        repository: repository,
        catalog: catalog,
        config: const PersonalizedRecommendationConfig(
          becauseSeedCount: 1,
          becauseMinimum: 3,
          becauseMaximum: 3,
          discoveryMinimum: 4,
          discoveryMaximum: 4,
        ),
        clock: () => now,
      );

      final feed = await engine.refresh();

      expect(
        feed.sections.map((section) => section.kind),
        <PersonalizedSectionKind>[
          PersonalizedSectionKind.continueListening,
          PersonalizedSectionKind.becauseYouListened,
          PersonalizedSectionKind.mixes,
          PersonalizedSectionKind.newForYou,
          PersonalizedSectionKind.discovery,
        ],
      );
      expect(feed.sections[1].title, 'Porque escuchaste Track 1');
      expect(feed.sections[2].title, 'Tus mixes');
      expect(feed.sections[3].title, 'Nuevos para ti');
      expect(feed.sections[4].title, 'Descubrimiento para ti');
      expect(
        repository.savedFeeds.single.expiresAt,
        now.add(const Duration(hours: 6)),
      );
    });

    test('deduplicates video IDs globally across track sections', () async {
      final first = _seed(1, artist: 'Seed A', artistId: 'UCA');
      final second = _seed(2, artist: 'Seed B', artistId: 'UCB');
      final duplicate = _candidate(30, rank: 0, artist: 'Shared');
      final repository = _FakeRepository(
        top: <RecommendationSeed>[first, second],
        recent: <RecommendationSeed>[first, second],
      );
      final catalog = _FakeCatalog(
        candidates: <String, List<RelatedTrackCandidate>>{
          first.trackKey: <RelatedTrackCandidate>[
            duplicate,
            _candidate(31, rank: 1, artist: 'One'),
          ],
          second.trackKey: <RelatedTrackCandidate>[
            duplicate,
            _candidate(32, rank: 1, artist: 'Two'),
            _candidate(33, rank: 2, artist: 'Three'),
          ],
        },
      );
      final engine = PersonalizedRecommendationEngine(
        repository: repository,
        catalog: catalog,
        config: const PersonalizedRecommendationConfig(
          becauseSeedCount: 1,
          becauseMinimum: 1,
          becauseMaximum: 2,
          mixesMinimum: 99,
          mixesMaximum: 99,
          newForYouMinimum: 99,
          newForYouMaximum: 99,
          discoveryMinimum: 1,
          discoveryMaximum: 8,
        ),
        clock: () => now,
      );

      final feed = await engine.refresh();
      final keys = _trackItems(feed).map((item) => item.trackKey).toList();

      expect(keys.toSet(), hasLength(keys.length));
      expect(keys.where((key) => key == duplicate.trackKey), hasLength(1));
    });

    test(
      'never allocates more than two tracks per artist in a section',
      () async {
        final first = _seed(1, artist: 'Seed A', artistId: 'UCA');
        final second = _seed(2, artist: 'Seed B', artistId: 'UCB');
        final repository = _FakeRepository(
          top: <RecommendationSeed>[first, second],
          recent: const <RecommendationSeed>[],
        );
        final catalog = _FakeCatalog(
          candidates: <String, List<RelatedTrackCandidate>>{
            first.trackKey: <RelatedTrackCandidate>[
              for (var index = 40; index < 46; index += 1)
                _candidate(index, rank: index, artist: 'Repeated Artist'),
            ],
            second.trackKey: <RelatedTrackCandidate>[
              _candidate(50, rank: 0, artist: 'Different One'),
              _candidate(51, rank: 1, artist: 'Different Two'),
            ],
          },
        );
        final engine = PersonalizedRecommendationEngine(
          repository: repository,
          catalog: catalog,
          config: const PersonalizedRecommendationConfig(
            continueMinimum: 99,
            continueMaximum: 99,
            becauseSeedCount: 1,
            becauseMinimum: 1,
            becauseMaximum: 8,
            mixesMinimum: 99,
            mixesMaximum: 99,
            newForYouMinimum: 99,
            newForYouMaximum: 99,
            discoveryMinimum: 1,
            discoveryMaximum: 8,
          ),
          clock: () => now,
        );

        final feed = await engine.refresh();
        for (final section in feed.sections) {
          final repeated = section.items
              .whereType<PersonalizedTrackItem>()
              .where((item) => item.artists.contains('Repeated Artist'));
          expect(repeated.length, lessThanOrEqualTo(2));
        }
      },
    );

    test('uses section-specific recent and ever-listened exclusions', () async {
      final recent = _seed(1, artist: 'Recent', artistId: 'UCRecent');
      final old = _seed(
        2,
        artist: 'Old',
        artistId: 'UCOld',
        album: 'Already Heard',
      );
      final repository = _FakeRepository(
        top: <RecommendationSeed>[recent, old],
        recent: <RecommendationSeed>[recent],
      );
      final catalog = _FakeCatalog(
        candidates: <String, List<RelatedTrackCandidate>>{
          recent.trackKey: <RelatedTrackCandidate>[
            _candidateFromSeed(old, rank: 0),
            _candidate(61, rank: 1, artist: 'Fresh A'),
          ],
          old.trackKey: <RelatedTrackCandidate>[
            _candidateFromSeed(recent, rank: 0),
            _candidate(62, rank: 1, artist: 'Fresh B'),
          ],
        },
        releases: <String, List<RecommendationRelease>>{
          'UCRecent': <RecommendationRelease>[
            _release(1, title: 'Already Heard'),
            _release(2, title: 'Actually New'),
          ],
          'UCOld': <RecommendationRelease>[_release(3, title: 'Another New')],
        },
      );
      final engine = PersonalizedRecommendationEngine(
        repository: repository,
        catalog: catalog,
        config: const PersonalizedRecommendationConfig(
          continueMinimum: 1,
          becauseSeedCount: 2,
          becauseMinimum: 1,
          becauseMaximum: 3,
          mixesMinimum: 99,
          mixesMaximum: 99,
          newForYouMinimum: 1,
          discoveryMinimum: 1,
        ),
        clock: () => now,
      );

      final feed = await engine.refresh();
      final because = feed.sections
          .where(
            (section) =>
                section.kind == PersonalizedSectionKind.becauseYouListened,
          )
          .expand((section) => section.items)
          .whereType<PersonalizedTrackItem>();
      final discovery = feed.sections
          .where((section) => section.kind == PersonalizedSectionKind.discovery)
          .expand((section) => section.items)
          .whereType<PersonalizedTrackItem>();
      final newTitles = feed.sections
          .where((section) => section.kind == PersonalizedSectionKind.newForYou)
          .expand((section) => section.items)
          .whereType<PersonalizedCollectionItem>()
          .map((item) => item.title);

      expect(
        because.map((item) => item.trackKey),
        isNot(contains(recent.trackKey)),
      );
      expect(
        discovery.map((item) => item.trackKey),
        isNot(contains(anyOf(recent.trackKey, old.trackKey))),
      );
      expect(newTitles, isNot(contains('Already Heard')));
      expect(newTitles, containsAll(<String>['Actually New', 'Another New']));
    });

    test('excludes downloaded library identities from discovery', () async {
      final first = _seed(1);
      final second = _seed(2);
      final inLibrary = _candidate(65, rank: 0, artist: 'Library Artist');
      final fresh = _candidate(66, rank: 1, artist: 'Fresh Artist');
      final engine = PersonalizedRecommendationEngine(
        repository: _FakeRepository(
          top: <RecommendationSeed>[first, second],
          libraryKeys: <String>{inLibrary.trackKey},
        ),
        catalog: _FakeCatalog(
          candidates: <String, List<RelatedTrackCandidate>>{
            first.trackKey: <RelatedTrackCandidate>[inLibrary, fresh],
          },
        ),
        config: const PersonalizedRecommendationConfig(
          continueMinimum: 99,
          continueMaximum: 99,
          becauseSeedCount: 0,
          mixesMinimum: 99,
          mixesMaximum: 99,
          newForYouMinimum: 99,
          newForYouMaximum: 99,
          discoveryMinimum: 1,
        ),
        clock: () => now,
      );

      final feed = await engine.refresh();
      final discoveryKeys = feed.sections
          .where((section) => section.kind == PersonalizedSectionKind.discovery)
          .expand((section) => section.items)
          .whereType<PersonalizedTrackItem>()
          .map((item) => item.trackKey);

      expect(discoveryKeys, contains(fresh.trackKey));
      expect(discoveryKeys, isNot(contains(inLibrary.trackKey)));
    });

    test(
      'hides a sparse section without consuming its global budget',
      () async {
        final first = _seed(1, artist: 'Seed A', artistId: 'UCA');
        final second = _seed(2, artist: 'Seed B', artistId: 'UCB');
        final candidate = _candidate(70, rank: 0, artist: 'Only Candidate');
        final repository = _FakeRepository(
          top: <RecommendationSeed>[first, second],
        );
        final catalog = _FakeCatalog(
          candidates: <String, List<RelatedTrackCandidate>>{
            first.trackKey: <RelatedTrackCandidate>[candidate],
            second.trackKey: <RelatedTrackCandidate>[
              candidate,
              _candidate(71, rank: 1, artist: 'Other'),
            ],
          },
        );
        final engine = PersonalizedRecommendationEngine(
          repository: repository,
          catalog: catalog,
          config: const PersonalizedRecommendationConfig(
            continueMinimum: 99,
            continueMaximum: 99,
            becauseSeedCount: 1,
            becauseMinimum: 2,
            mixesMinimum: 99,
            mixesMaximum: 99,
            newForYouMinimum: 99,
            newForYouMaximum: 99,
            discoveryMinimum: 1,
            discoveryMaximum: 1,
          ),
          clock: () => now,
        );

        final feed = await engine.refresh();
        final kinds = feed.sections.map((section) => section.kind);

        expect(
          kinds,
          isNot(contains(PersonalizedSectionKind.becauseYouListened)),
        );
        expect(
          _trackItems(feed).map((item) => item.trackKey),
          contains(candidate.trackKey),
        );
      },
    );

    test(
      'uses fresh related cache without a network candidate request',
      () async {
        final first = _seed(1, artistId: 'UCA');
        final second = _seed(2, artistId: 'UCB');
        final repository = _FakeRepository(
          top: <RecommendationSeed>[first, second],
          related: <String, List<RelatedTrackCandidate>>{
            first.trackKey: <RelatedTrackCandidate>[
              _candidate(81, rank: 0, artist: 'Cached A'),
            ],
            second.trackKey: <RelatedTrackCandidate>[
              _candidate(82, rank: 0, artist: 'Cached B'),
            ],
          },
        );
        final catalog = _FakeCatalog();
        final engine = PersonalizedRecommendationEngine(
          repository: repository,
          catalog: catalog,
          config: const PersonalizedRecommendationConfig(
            continueMinimum: 99,
            continueMaximum: 99,
            becauseMinimum: 1,
            mixesMinimum: 99,
            mixesMaximum: 99,
            newForYouMinimum: 99,
            newForYouMaximum: 99,
            discoveryMinimum: 99,
            discoveryMaximum: 99,
          ),
          clock: () => now,
        );

        final feed = await engine.refresh();

        expect(catalog.candidateCalls, isEmpty);
        expect(
          _trackItems(feed).map((item) => item.trackKey),
          contains('video000081'),
        );
      },
    );

    test(
      'isolates one failed YouTube seed and keeps the remaining feed',
      () async {
        final first = _seed(1, artistId: 'UCA');
        final second = _seed(2, artistId: 'UCB');
        final repository = _FakeRepository(
          top: <RecommendationSeed>[first, second],
        );
        final catalog = _FakeCatalog(
          failingSeeds: <String>{first.trackKey},
          candidates: <String, List<RelatedTrackCandidate>>{
            second.trackKey: <RelatedTrackCandidate>[
              _candidate(91, rank: 0, artist: 'Healthy A'),
              _candidate(92, rank: 1, artist: 'Healthy B'),
            ],
          },
        );
        final engine = PersonalizedRecommendationEngine(
          repository: repository,
          catalog: catalog,
          config: const PersonalizedRecommendationConfig(
            continueMinimum: 99,
            continueMaximum: 99,
            becauseSeedCount: 2,
            becauseMinimum: 1,
            mixesMinimum: 2,
            newForYouMinimum: 99,
            newForYouMaximum: 99,
            discoveryMinimum: 1,
          ),
          clock: () => now,
        );

        final feed = await engine.refresh();

        expect(feed.isNotEmpty, isTrue);
        expect(
          _trackItems(feed).map((item) => item.trackKey),
          contains('video000091'),
        );
      },
    );

    test(
      'one missing artist does not freeze an otherwise healthy refresh',
      () async {
        final first = _seed(1, artist: 'Healthy', artistId: 'UChealthy');
        final missing = _seed(2, artist: 'Removed', artistId: 'UCremoved');
        final cachedFeed = PersonalizedRecommendationFeed(
          generatedAt: now.subtract(const Duration(hours: 1)),
          sections: <PersonalizedRecommendationSection>[
            PersonalizedRecommendationSection(
              kind: PersonalizedSectionKind.discovery,
              title: 'Old cached feed',
              items: <PersonalizedRecommendationItem>[
                PersonalizedTrackItem.fromCandidate(
                  _candidate(90, rank: 0, artist: 'Old'),
                ),
              ],
            ),
          ],
        );
        final repository = _FakeRepository(
          top: <RecommendationSeed>[first, missing],
          recent: <RecommendationSeed>[first, missing],
          cachedFeed: RecommendationFeedCache(
            feedKey: 'personalized-home-v1',
            payload: cachedFeed.toJson(),
            generatedAt: cachedFeed.generatedAt,
            expiresAt: now.add(const Duration(hours: 5)),
          ),
        );
        final catalog = _FakeCatalog(
          failingArtists: const <String>{'UCremoved'},
          candidates: <String, List<RelatedTrackCandidate>>{
            first.trackKey: <RelatedTrackCandidate>[
              _candidate(101, rank: 0, artist: 'Fresh Candidate'),
            ],
            missing.trackKey: <RelatedTrackCandidate>[
              _candidate(102, rank: 0, artist: 'Another Candidate'),
            ],
          },
          releases: <String, List<RecommendationRelease>>{
            'UChealthy': <RecommendationRelease>[
              _release(
                101,
                artist: 'Healthy',
                artistId: 'UChealthy',
                title: 'Fresh Release',
              ),
            ],
          },
        );
        final engine = PersonalizedRecommendationEngine(
          repository: repository,
          catalog: catalog,
          config: const PersonalizedRecommendationConfig(
            becauseMinimum: 1,
            discoveryMinimum: 1,
          ),
          clock: () => now,
        );

        final refreshed = await engine.refresh(forceNetwork: true);

        expect(refreshed.toJson(), isNot(cachedFeed.toJson()));
        expect(repository.savedFeeds, hasLength(1));
        expect(
          refreshed.sections
              .expand((section) => section.items)
              .whereType<PersonalizedCollectionItem>()
              .map((item) => item.title),
          contains('Fresh Release'),
        );
      },
    );

    test(
      'a failed artist cannot freeze fresh history when healthy sources are cached',
      () async {
        final healthy = _seed(1, artist: 'Healthy', artistId: 'UChealthy');
        final missing = _seed(2, artist: 'Removed', artistId: 'UCremoved');
        final recent = <RecommendationSeed>[healthy, missing];
        final repository = _FakeRepository(
          top: <RecommendationSeed>[healthy, missing],
          recent: recent,
          related: <String, List<RelatedTrackCandidate>>{
            healthy.trackKey: <RelatedTrackCandidate>[
              _candidate(111, rank: 0, artist: 'Cached Healthy'),
            ],
            missing.trackKey: <RelatedTrackCandidate>[
              _candidate(112, rank: 0, artist: 'Cached Removed'),
            ],
          },
        );
        final catalog = _FakeCatalog(
          failingArtists: const <String>{'UCremoved'},
          releases: <String, List<RecommendationRelease>>{
            'UChealthy': <RecommendationRelease>[
              _release(111, artist: 'Healthy', artistId: 'UChealthy'),
            ],
          },
        );
        final engine = PersonalizedRecommendationEngine(
          repository: repository,
          catalog: catalog,
          config: const PersonalizedRecommendationConfig(
            becauseMinimum: 1,
            discoveryMinimum: 1,
          ),
          clock: () => now,
        );

        final firstFeed = await engine.refresh();
        recent
          ..clear()
          ..addAll(<RecommendationSeed>[missing, healthy]);
        final secondFeed = await engine.refresh();

        PersonalizedRecommendationSection continueSection(
          PersonalizedRecommendationFeed feed,
        ) => feed.sections.singleWhere(
          (section) =>
              section.kind == PersonalizedSectionKind.continueListening,
        );

        expect(
          (continueSection(firstFeed).items.first as PersonalizedTrackItem)
              .trackKey,
          healthy.trackKey,
        );
        expect(
          (continueSection(secondFeed).items.first as PersonalizedTrackItem)
              .trackKey,
          missing.trackKey,
        );
        expect(repository.savedFeeds, hasLength(2));
        expect(catalog.candidateCalls, isEmpty);
        expect(catalog.artistReleaseCalls, <String>[
          'UChealthy',
          'UCremoved',
          'UCremoved',
        ]);
      },
    );

    test('offline refresh preserves the last complete cached feed', () async {
      final seed = _seed(1, artistId: 'UCA');
      final cachedFeed = PersonalizedRecommendationFeed(
        generatedAt: now.subtract(const Duration(hours: 1)),
        sections: <PersonalizedRecommendationSection>[
          PersonalizedRecommendationSection(
            kind: PersonalizedSectionKind.discovery,
            title: 'Cached discovery',
            items: <PersonalizedRecommendationItem>[
              PersonalizedTrackItem.fromCandidate(
                _candidate(90, rank: 0, artist: 'Cached Artist'),
              ),
            ],
          ),
        ],
      );
      final repository = _FakeRepository(
        top: <RecommendationSeed>[seed],
        cachedFeed: RecommendationFeedCache(
          feedKey: 'personalized-home-v1',
          payload: cachedFeed.toJson(),
          generatedAt: cachedFeed.generatedAt,
          expiresAt: now.add(const Duration(hours: 5)),
        ),
      );
      final engine = PersonalizedRecommendationEngine(
        repository: repository,
        catalog: _FakeCatalog(failingSeeds: <String>{seed.trackKey}),
        config: const PersonalizedRecommendationConfig(
          continueMinimum: 99,
          continueMaximum: 99,
          becauseMinimum: 1,
          mixesMinimum: 99,
          mixesMaximum: 99,
          artistSeedLimit: 0,
          newForYouMinimum: 99,
          newForYouMaximum: 99,
          discoveryMinimum: 1,
        ),
        clock: () => now,
      );

      final refreshed = await engine.refresh(forceNetwork: true);

      expect(
        refreshed.sections.map((section) => section.toJson()),
        cachedFeed.sections.map((section) => section.toJson()),
      );
      expect(refreshed.generatedAt, now);
      expect(repository.savedFeeds, hasLength(1));
    });

    test('does not repopulate caches after history is cleared', () async {
      final seed = _seed(1);
      final gate = Completer<void>();
      final entered = Completer<void>();
      final repository = _FakeRepository(top: <RecommendationSeed>[seed]);
      final catalog = _FakeCatalog(
        candidateGate: gate,
        candidateEntered: entered,
        candidates: <String, List<RelatedTrackCandidate>>{
          seed.trackKey: <RelatedTrackCandidate>[
            _candidate(95, rank: 0, artist: 'Late Candidate'),
          ],
        },
      );
      final engine = PersonalizedRecommendationEngine(
        repository: repository,
        catalog: catalog,
        config: const PersonalizedRecommendationConfig(
          continueMinimum: 99,
          continueMaximum: 99,
          becauseMinimum: 1,
          mixesMinimum: 99,
          mixesMaximum: 99,
          newForYouMinimum: 99,
          newForYouMaximum: 99,
          discoveryMinimum: 1,
        ),
        clock: () => now,
      );

      final refresh = engine.refresh();
      await entered.future;
      repository.generation += 1;
      gate.complete();
      final feed = await refresh;

      expect(feed.sections, isEmpty);
      expect(repository.replaced, isEmpty);
      expect(repository.savedFeeds, isEmpty);
    });

    test('forced refresh bypasses fresh related candidates', () async {
      final seed = _seed(1);
      final cached = _candidate(96, rank: 0, artist: 'Cached');
      final fresh = _candidate(97, rank: 0, artist: 'Fresh');
      final repository = _FakeRepository(
        top: <RecommendationSeed>[seed],
        related: <String, List<RelatedTrackCandidate>>{
          seed.trackKey: <RelatedTrackCandidate>[cached],
        },
      );
      final catalog = _FakeCatalog(
        candidates: <String, List<RelatedTrackCandidate>>{
          seed.trackKey: <RelatedTrackCandidate>[fresh],
        },
      );
      final engine = PersonalizedRecommendationEngine(
        repository: repository,
        catalog: catalog,
        config: const PersonalizedRecommendationConfig(
          continueMinimum: 99,
          continueMaximum: 99,
          becauseMinimum: 1,
          mixesMinimum: 99,
          mixesMaximum: 99,
          newForYouMinimum: 99,
          newForYouMaximum: 99,
          discoveryMinimum: 99,
          discoveryMaximum: 99,
        ),
        clock: () => now,
      );

      final feed = await engine.refresh(forceNetwork: true);

      expect(catalog.candidateCalls, <String>[seed.trackKey]);
      expect(
        repository.replaced[seed.trackKey]!.single.trackKey,
        fresh.trackKey,
      );
      expect(
        _trackItems(feed).map((item) => item.trackKey),
        contains(fresh.trackKey),
      );
      expect(
        _trackItems(feed).map((item) => item.trackKey),
        isNot(contains(cached.trackKey)),
      );
    });

    test('reuses artist releases in-session until a forced refresh', () async {
      final seed = _seed(1, artist: 'Seed Artist', artistId: 'UCseedArtist');
      final catalog = _FakeCatalog(
        releases: <String, List<RecommendationRelease>>{
          'UCseedArtist': <RecommendationRelease>[
            _release(1, artist: 'Seed Artist', artistId: 'UCseedArtist'),
          ],
        },
      );
      final engine = PersonalizedRecommendationEngine(
        repository: _FakeRepository(top: <RecommendationSeed>[seed]),
        catalog: catalog,
        clock: () => now,
      );

      await engine.refresh();
      await engine.refresh();
      expect(catalog.artistReleaseCalls, <String>['UCseedArtist']);

      await engine.refresh(forceNetwork: true);
      expect(catalog.artistReleaseCalls, <String>[
        'UCseedArtist',
        'UCseedArtist',
      ]);
    });

    test('normalizes an automix browse ID without duplicating VL', () async {
      final seed = _seed(1);
      final engine = PersonalizedRecommendationEngine(
        repository: _FakeRepository(top: <RecommendationSeed>[seed]),
        catalog: _FakeCatalog(
          automixIds: <String, String>{
            seed.trackKey: 'VLRDAMVM${seed.videoId}',
          },
        ),
        config: const PersonalizedRecommendationConfig(
          continueMinimum: 99,
          continueMaximum: 99,
          becauseSeedCount: 0,
          newForYouMinimum: 99,
          newForYouMaximum: 99,
          discoveryMinimum: 99,
          discoveryMaximum: 99,
        ),
        clock: () => now,
      );

      final feed = await engine.refresh(forceNetwork: true);
      final mix = feed.sections
          .singleWhere(
            (section) => section.kind == PersonalizedSectionKind.mixes,
          )
          .items
          .whereType<PersonalizedCollectionItem>()
          .single;

      expect(mix.playlistId, 'RDAMVM${seed.videoId}');
      expect(mix.browseId, 'VLRDAMVM${seed.videoId}');
    });

    test('limits concurrent YouTube candidate requests to three', () async {
      final seeds = <RecommendationSeed>[
        for (var index = 1; index <= 8; index += 1) _seed(index),
      ];
      final catalog = _FakeCatalog(
        requestDelay: const Duration(milliseconds: 5),
      );
      final engine = PersonalizedRecommendationEngine(
        repository: _FakeRepository(top: seeds),
        catalog: catalog,
        config: const PersonalizedRecommendationConfig(
          networkConcurrency: 3,
          continueMinimum: 99,
          continueMaximum: 99,
          becauseSeedCount: 0,
          mixesMinimum: 99,
          mixesMaximum: 99,
          artistSeedLimit: 0,
          newForYouMinimum: 99,
          newForYouMaximum: 99,
          discoveryMinimum: 99,
          discoveryMaximum: 99,
        ),
        clock: () => now,
      );

      await engine.refresh(forceNetwork: true);

      expect(catalog.maximumConcurrentCandidateCalls, 3);
      expect(catalog.candidateCalls, seeds.map((seed) => seed.trackKey));
    });

    test('ranking and serialized payload are deterministic', () async {
      final seeds = <RecommendationSeed>[_seed(1), _seed(2)];
      final candidates = <String, List<RelatedTrackCandidate>>{
        seeds[0].trackKey: <RelatedTrackCandidate>[
          _candidate(102, rank: 1, artist: 'B'),
          _candidate(101, rank: 0, artist: 'A'),
        ],
        seeds[1].trackKey: <RelatedTrackCandidate>[
          _candidate(103, rank: 0, artist: 'C'),
          _candidate(102, rank: 1, artist: 'B'),
        ],
      };
      Future<Map<String, Object?>> build() async {
        final engine = PersonalizedRecommendationEngine(
          repository: _FakeRepository(top: seeds),
          catalog: _FakeCatalog(candidates: candidates),
          config: const PersonalizedRecommendationConfig(
            continueMinimum: 99,
            continueMaximum: 99,
            becauseMinimum: 1,
            mixesMinimum: 99,
            mixesMaximum: 99,
            newForYouMinimum: 99,
            newForYouMaximum: 99,
            discoveryMinimum: 1,
          ),
          clock: () => now,
        );
        return (await engine.refresh()).toJson();
      }

      expect(await build(), await build());
    });

    test('loads a stale cache immediately and reports expiration', () async {
      final cachedFeed = PersonalizedRecommendationFeed(
        generatedAt: now.subtract(const Duration(days: 1)),
        sections: <PersonalizedRecommendationSection>[
          PersonalizedRecommendationSection(
            kind: PersonalizedSectionKind.continueListening,
            title: 'Seguir escuchando',
            items: <PersonalizedRecommendationItem>[
              PersonalizedTrackItem.fromSeed(_seed(1)),
            ],
          ),
        ],
      );
      final repository = _FakeRepository(
        top: <RecommendationSeed>[_seed(1)],
        cachedFeed: RecommendationFeedCache(
          feedKey: 'personalized-home-v1',
          payload: cachedFeed.toJson(),
          generatedAt: cachedFeed.generatedAt,
          expiresAt: now.subtract(const Duration(minutes: 1)),
        ),
      );
      final engine = PersonalizedRecommendationEngine(
        repository: repository,
        catalog: _FakeCatalog(),
        clock: () => now,
      );

      final cached = await engine.loadCachedFeed();

      expect(cached, isNotNull);
      expect(cached!.isExpired, isTrue);
      expect(cached.feed.toJson(), cachedFeed.toJson());
    });

    test(
      'deletes a cached feed when recommendation history is empty',
      () async {
        final cachedFeed = PersonalizedRecommendationFeed(
          generatedAt: now.subtract(const Duration(hours: 1)),
          sections: <PersonalizedRecommendationSection>[
            PersonalizedRecommendationSection(
              kind: PersonalizedSectionKind.continueListening,
              title: 'Seguir escuchando',
              items: <PersonalizedRecommendationItem>[
                PersonalizedTrackItem.fromSeed(_seed(1)),
              ],
            ),
          ],
        );
        final repository = _FakeRepository(
          cachedFeed: RecommendationFeedCache(
            feedKey: 'personalized-home-v1',
            payload: cachedFeed.toJson(),
            generatedAt: cachedFeed.generatedAt,
            expiresAt: now.add(const Duration(hours: 1)),
          ),
        );
        final engine = PersonalizedRecommendationEngine(
          repository: repository,
          catalog: _FakeCatalog(),
          clock: () => now,
        );

        expect(await engine.loadCachedFeed(), isNull);
        expect(repository.deletedFeedKeys, const <String>[
          'personalized-home-v1',
        ]);
        expect(repository.cachedFeed, isNull);

        repository
          ..cachedFeed = RecommendationFeedCache(
            feedKey: 'personalized-home-v1',
            payload: cachedFeed.toJson(),
            generatedAt: cachedFeed.generatedAt,
            expiresAt: now.add(const Duration(hours: 1)),
          )
          ..deletedFeedKeys.clear();
        final refreshed = await engine.refresh();
        expect(refreshed.sections, isEmpty);
        expect(repository.deletedFeedKeys, const <String>[
          'personalized-home-v1',
        ]);
        expect(repository.cachedFeed, isNull);
        expect(await engine.loadCachedFeed(), isNull);
      },
    );

    test('ignores a cache with an unknown schema', () async {
      final repository = _FakeRepository(
        cachedFeed: RecommendationFeedCache(
          feedKey: 'personalized-home-v1',
          payload: <String, Object?>{
            'schemaVersion': 999,
            'generatedAt': now.toIso8601String(),
            'sections': <Object?>[],
          },
          generatedAt: now,
          expiresAt: now.add(const Duration(hours: 1)),
        ),
      );
      final engine = PersonalizedRecommendationEngine(
        repository: repository,
        catalog: _FakeCatalog(),
        clock: () => now,
      );

      expect(await engine.loadCachedFeed(), isNull);
    });
  });
}

Iterable<PersonalizedTrackItem> _trackItems(
  PersonalizedRecommendationFeed feed,
) {
  return feed.sections
      .expand((section) => section.items)
      .whereType<PersonalizedTrackItem>();
}

RecommendationSeed _seed(
  int id, {
  String? artist,
  String? artistId,
  String? album,
}) {
  final videoId = 'video${id.toString().padLeft(6, '0')}';
  return RecommendationSeed(
    trackKey: videoId,
    trackId: 'track-$id',
    videoId: videoId,
    title: 'Track $id',
    artists: <String>[artist ?? 'Artist $id'],
    artistBrowseIds: <String?>[artistId ?? 'UCartist$id'],
    album: album,
    thumbnailUrl: 'https://example.com/$id.jpg',
    durationMs: 180000,
    source: PlaybackEventSource.streaming,
    playCount: id,
    totalListenedMs: 60000 * id,
    completedCount: 1,
    lastPlayedAt: DateTime.utc(2026, 8, id.clamp(1, 20)),
  );
}

RelatedTrackCandidate _candidate(
  int id, {
  required int rank,
  required String artist,
}) {
  final videoId = 'video${id.toString().padLeft(6, '0')}';
  return RelatedTrackCandidate(
    trackId: videoId,
    videoId: videoId,
    title: 'Candidate $id',
    artists: <String>[artist],
    artistBrowseIds: <String?>['UC${artist.replaceAll(' ', '')}'],
    rank: rank,
  );
}

RelatedTrackCandidate _candidateFromSeed(
  RecommendationSeed seed, {
  required int rank,
}) {
  return RelatedTrackCandidate(
    trackId: seed.trackId,
    videoId: seed.videoId,
    title: seed.title,
    artists: seed.artists,
    artistBrowseIds: seed.artistBrowseIds,
    album: seed.album,
    rank: rank,
  );
}

RecommendationRelease _release(
  int id, {
  String? title,
  String artist = 'Release Artist',
  String artistId = 'UCReleaseArtist',
}) {
  return RecommendationRelease(
    browseId: 'MPREb_release_$id',
    title: title ?? 'Release $id',
    artists: <String>[artist],
    artistBrowseIds: <String?>[artistId],
    year: '2026',
    type: 'Álbum',
  );
}

class _FakeRepository implements RecommendationRepository {
  _FakeRepository({
    this.top = const <RecommendationSeed>[],
    this.recent = const <RecommendationSeed>[],
    this.related = const <String, List<RelatedTrackCandidate>>{},
    this.libraryKeys = const <String>{},
    this.cachedFeed,
  });

  final List<RecommendationSeed> top;
  final List<RecommendationSeed> recent;
  final Map<String, List<RelatedTrackCandidate>> related;
  final Set<String> libraryKeys;
  @override
  int generation = 0;
  RecommendationFeedCache? cachedFeed;
  final List<RecommendationFeedCache> savedFeeds = <RecommendationFeedCache>[];
  final List<String> deletedFeedKeys = <String>[];
  final Map<String, List<RelatedTrackCandidate>> replaced =
      <String, List<RelatedTrackCandidate>>{};

  @override
  Future<List<RecommendationSeed>> getTopSeeds({
    required int limit,
    DateTime? since,
    int minListenedMs = 30000,
  }) async => top.take(limit).toList(growable: false);

  @override
  Future<List<RecommendationSeed>> getRecentSeeds({
    required int limit,
    DateTime? since,
    int minListenedMs = 30000,
  }) async => recent.take(limit).toList(growable: false);

  @override
  Future<Set<String>> getLibraryTrackKeys() async => libraryKeys;

  @override
  Future<List<RelatedTrackCandidate>> getRelatedCandidates(
    String seedKey, {
    required Duration ttl,
    required DateTime now,
  }) async => related[seedKey] ?? const <RelatedTrackCandidate>[];

  @override
  Future<RecommendationFeedCache?> loadFeed(String feedKey) async => cachedFeed;

  @override
  Future<bool> deleteFeed(
    String feedKey, {
    required int expectedGeneration,
  }) async {
    if (generation != expectedGeneration) {
      return false;
    }
    deletedFeedKeys.add(feedKey);
    if (cachedFeed?.feedKey == feedKey) {
      cachedFeed = null;
    }
    return true;
  }

  @override
  Future<bool> replaceRelatedCandidates({
    required String seedKey,
    required List<RelatedTrackCandidate> candidates,
    required DateTime fetchedAt,
    required int expectedGeneration,
  }) async {
    if (generation != expectedGeneration) {
      return false;
    }
    replaced[seedKey] = candidates;
    return true;
  }

  @override
  Future<bool> saveFeed(
    RecommendationFeedCache feed, {
    required int expectedGeneration,
  }) async {
    if (generation != expectedGeneration) {
      return false;
    }
    savedFeeds.add(feed);
    cachedFeed = feed;
    return true;
  }
}

class _FakeCatalog implements RecommendationCatalog {
  _FakeCatalog({
    this.candidates = const <String, List<RelatedTrackCandidate>>{},
    this.releases = const <String, List<RecommendationRelease>>{},
    this.failingSeeds = const <String>{},
    this.failingArtists = const <String>{},
    this.candidateGate,
    this.candidateEntered,
    this.requestDelay = Duration.zero,
    this.automixIds = const <String, String>{},
  });

  final Map<String, List<RelatedTrackCandidate>> candidates;
  final Map<String, List<RecommendationRelease>> releases;
  final Set<String> failingSeeds;
  final Set<String> failingArtists;
  final Completer<void>? candidateGate;
  final Completer<void>? candidateEntered;
  final Duration requestDelay;
  final Map<String, String> automixIds;
  final List<String> candidateCalls = <String>[];
  final List<String> artistReleaseCalls = <String>[];
  int _concurrentCandidateCalls = 0;
  int maximumConcurrentCandidateCalls = 0;

  @override
  Future<SeedRecommendationCandidates> getCandidates(
    RecommendationSeed seed, {
    required int limit,
  }) async {
    candidateCalls.add(seed.trackKey);
    _concurrentCandidateCalls += 1;
    if (_concurrentCandidateCalls > maximumConcurrentCandidateCalls) {
      maximumConcurrentCandidateCalls = _concurrentCandidateCalls;
    }
    try {
      if (candidateEntered?.isCompleted == false) {
        candidateEntered!.complete();
      }
      await candidateGate?.future;
      if (requestDelay > Duration.zero) {
        await Future<void>.delayed(requestDelay);
      }
      if (failingSeeds.contains(seed.trackKey)) {
        throw StateError('offline');
      }
      return SeedRecommendationCandidates(
        tracks: (candidates[seed.trackKey] ?? const <RelatedTrackCandidate>[])
            .take(limit)
            .toList(growable: false),
        automixPlaylistId: automixIds[seed.trackKey],
      );
    } finally {
      _concurrentCandidateCalls -= 1;
    }
  }

  @override
  Future<List<RecommendationRelease>> getArtistReleases(
    String artistBrowseId, {
    required int limit,
  }) async {
    artistReleaseCalls.add(artistBrowseId);
    if (failingArtists.contains(artistBrowseId)) {
      throw StateError('artist unavailable');
    }
    return (releases[artistBrowseId] ?? const <RecommendationRelease>[])
        .take(limit)
        .toList(growable: false);
  }
}
