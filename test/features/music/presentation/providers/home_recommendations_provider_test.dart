import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/services/recommendations/recommendations.dart';
import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart'
    as ytm_account;
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'authenticated Home is preferred without calling anonymous Home',
    () async {
      final anonymous = _FakeHomeSearch([
        _homeCollectionSection('Inicio anónimo', 'VLPLanonymoushome001'),
      ]);
      final authenticated = _FakeHomeSearch([
        _homeCollectionSection('Inicio autenticado', 'VLPLauthenticated001'),
      ]);
      final container = _containerFor(
        anonymous,
        authenticatedHome: authenticated,
      );

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(
        sections.map((section) => section.title),
        contains('Inicio autenticado'),
      );
      expect(authenticated.homeCalls, 1);
      expect(anonymous.homeCalls, 0);
    },
  );

  test(
    'authenticated Home marks its artist shelf as account recommendations',
    () async {
      final anonymous = _FakeHomeSearch(const <InnerTubeHomeSection>[]);
      final authenticated = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Para tu cuenta',
          items: [
            InnerTubeHomeArtistItem(
              InnerTubeArtist(
                browseId: 'UCaccountartist001',
                name: 'Artista de la cuenta',
                thumbnailUrl: 'https://img.test/account-artist.jpg',
              ),
            ),
          ],
        ),
      ]);
      final container = _containerFor(
        anonymous,
        authenticatedHome: authenticated,
      );

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(sections.single.title, 'Artistas recomendados');
      expect(
        sections.single.queueSourceId,
        startsWith('youtube-account-home:'),
      );
      expect(anonymous.homeCalls, 0);
    },
  );

  test(
    'authenticated Home read failure falls back to anonymous once',
    () async {
      final anonymous = _FakeHomeSearch([
        _homeCollectionSection('Respaldo anónimo', 'VLPLfallbackhome001'),
      ]);
      final authenticated = _FakeHomeSearch(const <InnerTubeHomeSection>[])
        ..homeError = const ytm_account.YouTubeMusicAccountException(
          'expired fixture',
          statusCode: 401,
        );
      final container = _containerFor(
        anonymous,
        authenticatedHome: authenticated,
      );

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(
        sections.map((section) => section.title),
        contains('Respaldo anónimo'),
      );
      expect(authenticated.homeCalls, 1);
      expect(anonymous.homeCalls, 1);
    },
  );

  test(
    'authenticated Home format failure falls back to anonymous once',
    () async {
      final anonymous = _FakeHomeSearch([
        _homeCollectionSection('Formato de respaldo', 'VLPLformatfallback01'),
      ]);
      final authenticated = _FakeHomeSearch(const <InnerTubeHomeSection>[])
        ..homeError = const InnerTubeFormatException('malformed fixture');
      final container = _containerFor(
        anonymous,
        authenticatedHome: authenticated,
      );

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(
        sections.map((section) => section.title),
        contains('Formato de respaldo'),
      );
      expect(authenticated.homeCalls, 1);
      expect(anonymous.homeCalls, 1);
    },
  );

  test(
    'unexpected authenticated Home bugs do not get hidden by fallback',
    () async {
      final anonymous = _FakeHomeSearch([
        _homeCollectionSection('No debe usarse', 'VLPLunexpectedhome01'),
      ]);
      final authenticated = _FakeHomeSearch(const <InnerTubeHomeSection>[])
        ..homeError = StateError('programming fixture');
      final container = _containerFor(
        anonymous,
        authenticatedHome: authenticated,
      );

      await expectLater(
        container.read(youtubeMusicHomeRecommendationsProvider.future),
        throwsStateError,
      );
      expect(authenticated.homeCalls, 1);
      expect(anonymous.homeCalls, 0);
    },
  );

  test(
    'combined Home reacts to authenticated login and later logout generation',
    () async {
      final anonymous = _FakeHomeSearch([
        _homeCollectionSection('Inicio público', 'VLPLpublicreactive01'),
      ]);
      final authenticated = _FakeHomeSearch([
        _homeCollectionSection('Inicio de cuenta', 'VLPLaccountreactive1'),
      ]);
      final authController = _MutableHomeAuthController(
        const YouTubeMusicAuthState(
          phase: YouTubeMusicAuthPhase.anonymous,
          generation: 0,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
          youtubeMusicSearchProvider.overrideWithValue(anonymous),
          youtubeMusicAuthControllerProvider.overrideWith(() => authController),
          youtubeMusicAuthenticatedHomeProvider.overrideWith((ref) {
            return ref.watch(youtubeMusicAuthControllerProvider).isAuthenticated
                ? authenticated
                : null;
          }),
          personalizedHomeFeedSourceProvider.overrideWithValue(null),
          homeArtistRecommendationSourceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      await container.read(youtubeMusicHomeRecommendationsProvider.future);
      var sections = await container.read(homeRecommendationsProvider.future);
      expect(
        sections.map((section) => section.title),
        contains('Inicio público'),
      );

      authController.publish(
        const YouTubeMusicAuthState(
          phase: YouTubeMusicAuthPhase.authenticated,
          generation: 1,
          profile: YouTubeMusicAccountProfile(
            channelId: 'UC-reactive-account',
            displayName: 'Cuenta reactiva',
          ),
        ),
      );
      await container.read(youtubeMusicHomeRecommendationsProvider.future);
      sections = await container.read(homeRecommendationsProvider.future);
      expect(
        sections.map((section) => section.title),
        contains('Inicio de cuenta'),
      );
      expect(
        sections.map((section) => section.title),
        isNot(contains('Inicio público')),
      );

      authController.publish(
        const YouTubeMusicAuthState(
          phase: YouTubeMusicAuthPhase.anonymous,
          generation: 2,
        ),
      );
      await container.read(youtubeMusicHomeRecommendationsProvider.future);
      sections = await container.read(homeRecommendationsProvider.future);
      expect(
        sections.map((section) => section.title),
        contains('Inicio público'),
      );
      expect(
        sections.map((section) => section.title),
        isNot(contains('Inicio de cuenta')),
      );
    },
  );

  test(
    'extracts embedded artists into a circular shelf without resolving collections',
    () async {
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Para ti',
          items: [
            InnerTubeHomeSongItem(_song()),
            const InnerTubeHomeArtistItem(
              InnerTubeArtist(
                browseId: 'UCartist00001',
                name: 'Artista popular',
                thumbnailUrl: 'https://img.test/artist.jpg',
              ),
            ),
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
      expect(source.nextCalls, 0);
      expect(source.relatedCalls, 0);
      expect(source.lastMaxSections, 6);
      expect(source.lastMaxItemsPerSection, 12);

      expect(sections, hasLength(2));
      final artistSection = sections.first;
      expect(artistSection.title, 'Artistas populares');
      expect(artistSection.items, hasLength(1));
      final artist =
          (artistSection.items.single as HomeRecommendationArtistItem).artist;
      expect(artist.name, 'Artista popular');
      expect(artist.browseId, 'UCartist00001');
      expect(artist.thumbnailUrl, 'https://img.test/artist.jpg');

      final section = sections.last;
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

  test(
    'uses stable artists from anonymous Home without related fanout',
    () async {
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Para ti',
          items: [
            InnerTubeHomeSongItem(
              _song(
                artists: const ['Popular Uno', 'Popular Dos'],
                artistBrowseIds: const ['UCpopular00001', 'UCpopular00002'],
              ),
            ),
          ],
        ),
      ]);
      source.artistProfiles['UCpopular00001'] = InnerTubeArtistProfile(
        artist: const InnerTubeArtist(
          browseId: 'UCpopular00001',
          name: 'Popular Uno',
          thumbnailUrl: 'https://img.test/popular-one.jpg',
        ),
        popularSongs: const [],
        albums: const [],
        singles: const [],
      );
      final container = _containerFor(source);

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(sections, hasLength(2));
      final artists = sections.first;
      expect(artists.title, 'Artistas populares');
      expect(artists.items, hasLength(2));
      expect(
        artists.items.whereType<HomeRecommendationArtistItem>().map(
          (item) => item.artist.name,
        ),
        ['Popular Uno', 'Popular Dos'],
      );
      expect(
        (artists.items.first as HomeRecommendationArtistItem)
            .artist
            .thumbnailUrl,
        'https://img.test/popular-one.jpg',
      );
      expect(source.nextCalls, 0);
      expect(source.relatedCalls, 0);
      expect(sections.last.title, 'Para ti');
    },
  );

  test(
    'keeps a circular artist shelf from valid Home song identities',
    () async {
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Selección rápida',
          items: [
            InnerTubeHomeSongItem(
              _song(
                artists: const ['Artista Uno', 'Artista Dos', 'Sin página'],
                artistBrowseIds: const [
                  'UChomeartist0001',
                  'MPLAhomeartist002',
                  null,
                ],
              ),
            ),
          ],
        ),
      ]);
      source.artistProfiles['UChomeartist0001'] = InnerTubeArtistProfile(
        artist: const InnerTubeArtist(
          browseId: 'UChomeartist0001',
          name: 'Artista Uno',
          thumbnailUrl: 'https://img.test/home-artist.jpg',
        ),
        popularSongs: const [],
        albums: const [],
        singles: const [],
      );
      final container = _containerFor(source);

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(sections, hasLength(2));
      final artists = sections.first.items
          .whereType<HomeRecommendationArtistItem>()
          .map((item) => item.artist)
          .toList(growable: false);
      expect(artists.map((artist) => artist.name), [
        'Artista Uno',
        'Artista Dos',
      ]);
      expect(artists.map((artist) => artist.browseId), [
        'UChomeartist0001',
        'MPLAhomeartist002',
      ]);
      expect(
        artists.map((artist) => artist.seedVideoId),
        everyElement('AbCdEfGhIj1'),
      );
      expect(artists.first.thumbnailUrl, 'https://img.test/home-artist.jpg');
      expect(source.artistProfileCalls, 2);
      expect(source.nextCalls, 0);
      expect(source.relatedCalls, 0);
      expect(sections.last.title, 'Selección rápida');
    },
  );

  test(
    'keeps Home artist order stable without deriving an arbitrary radio',
    () async {
      final first = _song(
        videoId: 'FirstSeed01',
        artists: const ['Primero'],
        artistBrowseIds: const ['UCfirstcandidate01'],
      );
      final second = _song(
        videoId: 'SecondSeed1',
        artists: const ['Segundo'],
        artistBrowseIds: const ['UCsecondcandidate2'],
      );
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Selección rápida',
          items: [InnerTubeHomeSongItem(first), InnerTubeHomeSongItem(second)],
        ),
      ])..nextErrors['FirstSeed01'] = const FormatException('transient');
      final container = _containerFor(source);

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(source.nextCalls, 0);
      expect(source.relatedCalls, 0);
      final artists = sections.first.items
          .whereType<HomeRecommendationArtistItem>()
          .map((item) => item.artist)
          .toList(growable: false);
      expect(
        artists.map((artist) => artist.name),
        containsAllInOrder(const ['Primero', 'Segundo']),
      );
    },
  );

  test(
    'publishes valid Home artists immediately when enrichment has no budget',
    () async {
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Selección rápida',
          items: [
            InnerTubeHomeSongItem(
              _song(
                artists: const ['Artista inmediato'],
                artistBrowseIds: const ['UCimmediateartist1'],
              ),
            ),
          ],
        ),
      ]);
      final container = _containerFor(
        source,
        artistEnrichmentBudget: Duration.zero,
      );
      final stopwatch = Stopwatch()..start();

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(source.nextCalls, 0);
      expect(source.relatedCalls, 0);
      expect(source.artistProfileCalls, 0);
      final artist =
          (sections.first.items.single as HomeRecommendationArtistItem).artist;
      expect(artist.name, 'Artista inmediato');
      expect(artist.browseId, 'UCimmediateartist1');
    },
  );

  test(
    'resolves one recommended collection when Home contains only collections',
    () async {
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Esenciales',
          items: const [
            InnerTubeHomeCollection(
              title: 'Playlist estable',
              browseId: 'VLPLcollectionartists1',
              playlistId: 'PLcollectionartists1',
              kind: InnerTubeHomeCollectionKind.playlist,
              thumbnailUrl: 'https://img.test/collection-cover.jpg',
            ),
          ],
        ),
      ]);
      source.collectionSongs['VLPLcollectionartists1'] = [
        _song(
          artists: const ['Desde colección', 'Invitado real'],
          artistBrowseIds: const ['UCcollectionartist1', 'UCcollectionartist2'],
        ),
      ];
      source.artistProfiles['UCcollectionartist1'] = InnerTubeArtistProfile(
        artist: const InnerTubeArtist(
          browseId: 'UCcollectionartist1',
          name: 'Desde colección',
          thumbnailUrl: 'https://img.test/artist-profile.jpg',
        ),
        popularSongs: const [],
        albums: const [],
        singles: const [],
      );
      final container = _containerFor(source);

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(source.collectionCalls, 1);
      expect(source.lastCollectionBrowseId, 'VLPLcollectionartists1');
      expect(source.lastCollectionLimit, 8);
      expect(source.nextCalls, 0);
      expect(source.relatedCalls, 0);
      expect(source.artistProfileCalls, 2);
      expect(sections, hasLength(2));
      final artists = sections.first.items
          .whereType<HomeRecommendationArtistItem>()
          .map((item) => item.artist)
          .toList(growable: false);
      expect(artists.map((artist) => artist.name), [
        'Desde colección',
        'Invitado real',
      ]);
      expect(artists.first.thumbnailUrl, 'https://img.test/artist-profile.jpg');
      expect(artists.last.thumbnailUrl, isNull);
      expect(
        artists.map((artist) => artist.thumbnailUrl),
        isNot(contains('https://img.test/catalog.jpg')),
      );
      expect(sections.last.title, 'Esenciales');
      expect(
        sections.last.items.single,
        isA<HomeRecommendationCollectionItem>(),
      );
    },
  );

  test(
    'combines up to three narrow Home collections into a varied artist shelf',
    () async {
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Colecciones recomendadas',
          items: const [
            InnerTubeHomeCollection(
              title: 'Colección uno',
              browseId: 'VLPLartistgroup0001',
              kind: InnerTubeHomeCollectionKind.playlist,
            ),
            InnerTubeHomeCollection(
              title: 'Colección dos',
              browseId: 'VLPLartistgroup0002',
              kind: InnerTubeHomeCollectionKind.playlist,
            ),
            InnerTubeHomeCollection(
              title: 'Colección tres',
              browseId: 'VLPLartistgroup0003',
              kind: InnerTubeHomeCollectionKind.playlist,
            ),
          ],
        ),
      ]);
      for (var group = 1; group <= 3; group += 1) {
        source.collectionSongs['VLPLartistgroup000$group'] = [
          _song(
            videoId: 'GroupSong0$group',
            artists: ['Artista ${group}A', 'Artista ${group}B'],
            artistBrowseIds: [
              'UCartist${group}aaaaaaaa',
              'UCartist${group}bbbbbbbb',
            ],
          ),
        ];
      }
      final container = _containerFor(source);

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(source.collectionCalls, 3);
      expect(source.requestedCollectionBrowseIds, {
        'VLPLartistgroup0001',
        'VLPLartistgroup0002',
        'VLPLartistgroup0003',
      });
      expect(source.nextCalls, 0);
      expect(source.relatedCalls, 0);
      final artists = sections.first.items
          .whereType<HomeRecommendationArtistItem>()
          .map((item) => item.artist.name)
          .toList(growable: false);
      expect(artists, hasLength(6));
      expect(
        artists,
        containsAll(<String>[
          'Artista 1A',
          'Artista 1B',
          'Artista 2A',
          'Artista 2B',
          'Artista 3A',
          'Artista 3B',
        ]),
      );
    },
  );

  test(
    'rebuilding Home keeps contributing artist collections stable',
    () async {
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Colecciones rotativas',
          items: List<InnerTubeHomeItem>.generate(
            4,
            (index) => InnerTubeHomeCollection(
              title: 'Colección $index',
              browseId: 'VLPLrotateartists00$index',
              kind: InnerTubeHomeCollectionKind.playlist,
            ),
          ),
        ),
      ]);
      for (var index = 0; index < 4; index += 1) {
        source.collectionSongs['VLPLrotateartists00$index'] = [
          _song(
            videoId: 'RotateSong$index',
            artists: ['Artista rotativo $index'],
            artistBrowseIds: ['UCrotateartist000$index'],
          ),
        ];
      }
      final container = _containerFor(source);

      final first = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );
      container.invalidate(youtubeMusicHomeRecommendationsProvider);
      final second = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      Set<String> names(List<HomeRecommendationSection> sections) => sections
          .first
          .items
          .whereType<HomeRecommendationArtistItem>()
          .map((item) => item.artist.name)
          .toSet();
      expect(names(first), hasLength(3));
      expect(names(second), hasLength(3));
      expect(names(first), equals(names(second)));
      expect(names(first), {
        'Artista rotativo 0',
        'Artista rotativo 1',
        'Artista rotativo 2',
      });
    },
  );

  test(
    'drops only Tus mixes and preserves other all-mix Home shelves',
    () async {
      final source = _FakeHomeSearch([
        InnerTubeHomeSection(
          title: 'Tus mixes',
          items: const [
            InnerTubeHomeCollection(
              title: 'Mix diario',
              browseId: 'VLRDmixonly00001',
              playlistId: 'RDmixonly00001',
              kind: InnerTubeHomeCollectionKind.mix,
            ),
            InnerTubeHomeCollection(
              title: 'Mix para entrenar',
              browseId: 'VLRDmixonly00002',
              playlistId: 'RDmixonly00002',
              kind: InnerTubeHomeCollectionKind.mix,
            ),
          ],
        ),
        InnerTubeHomeSection(
          title: 'Mixes para entrenar',
          items: const [
            InnerTubeHomeCollection(
              title: 'Energía diaria',
              browseId: 'VLRDtraining0001',
              playlistId: 'RDtraining0001',
              kind: InnerTubeHomeCollectionKind.mix,
            ),
          ],
        ),
      ]);
      final container = _containerFor(source);

      final sections = await container.read(
        youtubeMusicHomeRecommendationsProvider.future,
      );

      expect(sections, hasLength(1));
      expect(sections.single.title, 'Mixes para entrenar');
      expect(
        (sections.single.items.single as HomeRecommendationCollectionItem)
            .collection
            .title,
        'Energía diaria',
      );
      expect(source.homeCalls, 1);
      expect(source.collectionCalls, 1);
      expect(source.lastCollectionBrowseId, 'VLRDtraining0001');
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

  test('remote detail track families are auto disposable', () {
    expect(
      homeCollectionTracksProvider('VLPL_collection').isAutoDispose,
      isTrue,
    );
    expect(homeAlbumTracksProvider('MPRE_album').isAutoDispose, isTrue);
    expect(searchAlbumTracksProvider('MPRE_search').isAutoDispose, isTrue);
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
    'releases collection tracks after the short detail cache expires',
    () async {
      final source = _FakeHomeSearch(const [])
        ..collectionSongs['VLPL_expiring_collection'] = [
          _song(videoId: 'expiring-song', title: 'Expiring song'),
        ];
      final container = _containerFor(
        source,
        remoteDetailCacheDuration: const Duration(milliseconds: 20),
      );
      final provider = homeCollectionTracksProvider('VLPL_expiring_collection');
      final subscription = container.listen(provider, (_, _) {});

      final first = await container.read(provider.future);
      subscription.close();
      await _eventually(() => !container.exists(provider));
      final second = await container.read(provider.future);

      expect(source.collectionCalls, 2);
      expect(identical(first, second), isFalse);
      expect(second.single.id, 'expiring-song');
    },
  );

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
          youtubeMusicAuthControllerProvider.overrideWith(
            () => _MutableHomeAuthController(
              const YouTubeMusicAuthState(
                phase: YouTubeMusicAuthPhase.anonymous,
                generation: 0,
              ),
            ),
          ),
          personalizedHomeFeedSourceProvider.overrideWithValue(source),
          homeArtistRecommendationSourceProvider.overrideWithValue(null),
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
        'Nuevos para ti',
        'Descubrimiento',
      ]);
      expect(cached, hasLength(4));
      expect(
        cached.where(
          (section) =>
              section.personalizedKind == PersonalizedSectionKind.mixes,
        ),
        isEmpty,
      );
      expect(cached.first.isContinueListening, isTrue);
      final downloaded =
          cached.first.items.single as HomeRecommendationTrackItem;
      expect(downloaded.localTrackId, 'download-row-id');
      expect(downloaded.track.id, 'AbCdEfGhIj1');
      expect(
        downloaded.track.url,
        'https://www.youtube.com/watch?v=AbCdEfGhIj1',
      );
      final release =
          (cached[2].items.single as HomeRecommendationCollectionItem)
              .collection;
      expect(release.kind, HomeRecommendationCollectionKind.album);

      await _eventually(() => source.refreshCalls == 1);
      expect(source.forceNetworkCalls, [false]);
      genericCompleter.complete([
        HomeRecommendationSection.items(
          title: 'Artistas populares',
          items: const [
            HomeRecommendationArtistItem(
              HomeRecommendationArtist(
                name: 'Artista recomendado',
                browseId: 'UCcombinedartist',
              ),
            ),
          ],
        ),
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
      expect(combined[1].title, 'Artistas populares');
      expect(
        combined
            .skip(1)
            .takeWhile((section) => section.title != 'YouTube Music')
            .last
            .personalizedKind,
        PersonalizedSectionKind.discovery,
      );
      expect(combined.last.title, 'YouTube Music');
      expect(combined.last.tracks.map((track) => track.id), ['aBcDeFgHiJ1']);
    },
  );

  test(
    'combined Home ranks recommended artists from listened candidate pools',
    () async {
      PersonalizedTrackItem track({
        required String videoId,
        required String title,
        required String artist,
        required String artistBrowseId,
      }) => PersonalizedTrackItem(
        trackId: videoId,
        videoId: videoId,
        title: title,
        artists: <String>[artist],
        artistBrowseIds: <String?>[artistBrowseId],
      );

      final feed = PersonalizedRecommendationFeed(
        generatedAt: DateTime.utc(2026),
        sections: [
          PersonalizedRecommendationSection(
            kind: PersonalizedSectionKind.continueListening,
            title: 'history',
            items: [
              track(
                videoId: 'Listen00001',
                title: 'Escuchada',
                artist: 'Artista escuchado',
                artistBrowseId: 'UClistenedartist1',
              ),
            ],
          ),
          PersonalizedRecommendationSection(
            kind: PersonalizedSectionKind.becauseYouListened,
            title: 'related',
            seedTitle: 'Escuchada',
            items: [
              track(
                videoId: 'Related0001',
                title: 'Relacionada uno',
                artist: 'Similar Uno',
                artistBrowseId: 'UCsimilarartist1',
              ),
              track(
                videoId: 'Related0002',
                title: 'Relacionada dos',
                artist: 'Similar Dos',
                artistBrowseId: 'UCsimilarartist2',
              ),
              track(
                videoId: 'Related0003',
                title: 'Otra del primero',
                artist: 'Similar Uno',
                artistBrowseId: 'UCsimilarartist1',
              ),
              track(
                videoId: 'Related0004',
                title: 'No debe recomendarse',
                artist: 'Artista escuchado',
                artistBrowseId: 'UClistenedartist1',
              ),
            ],
          ),
          PersonalizedRecommendationSection(
            kind: PersonalizedSectionKind.discovery,
            title: 'discovery',
            items: [
              track(
                videoId: 'Discover001',
                title: 'Similar tres',
                artist: 'Similar Tres',
                artistBrowseId: 'UCsimilarartist3',
              ),
            ],
          ),
        ],
      );
      final source = _FakePersonalizedHomeFeedSource(
        CachedPersonalizedRecommendationFeed(feed: feed, isExpired: false),
      );
      final generic = [
        HomeRecommendationSection.items(
          title: 'Artistas populares',
          items: const [
            HomeRecommendationArtistItem(
              HomeRecommendationArtist(
                name: 'Similar Uno',
                browseId: 'UCsimilarartist1',
                thumbnailUrl: 'https://img.test/similar-one.jpg',
              ),
            ),
            HomeRecommendationArtistItem(
              HomeRecommendationArtist(
                name: 'Popular sin relación',
                browseId: 'UCpopularfallback1',
              ),
            ),
          ],
        ),
      ];
      final artistSource = _StaticHomeArtistRecommendationSource(const [
        HomeRecommendationArtist(
          name: 'Similar Uno',
          browseId: 'UCsimilarartist1',
        ),
        HomeRecommendationArtist(
          name: 'Similar Dos',
          browseId: 'UCsimilarartist2',
        ),
        HomeRecommendationArtist(
          name: 'Similar Tres',
          browseId: 'UCsimilarartist3',
        ),
      ]);
      final container = _combinedContainer(
        source,
        generic: generic,
        artistSource: artistSource,
      );
      await container.read(youtubeMusicHomeRecommendationsProvider.future);

      final combined = await container.read(homeRecommendationsProvider.future);

      final artistSection = combined.singleWhere(
        (section) => section.title == 'Artistas recomendados',
      );
      final artists = artistSection.items
          .whereType<HomeRecommendationArtistItem>()
          .map((item) => item.artist)
          .toList(growable: false);
      expect(artists.map((artist) => artist.name), [
        'Similar Uno',
        'Similar Dos',
        'Similar Tres',
      ]);
      expect(
        artists.map((artist) => artist.name),
        isNot(contains('Artista escuchado')),
      );
      expect(artists.first.thumbnailUrl, 'https://img.test/similar-one.jpg');
      expect(artistSource.loadCalls, greaterThanOrEqualTo(1));
      expect(
        combined.where((section) => section.title == 'Artistas populares'),
        isEmpty,
      );
    },
  );

  test(
    'account Home artists complement local listening recommendations',
    () async {
      final source = _FakePersonalizedHomeFeedSource(null);
      final artistSource = _StaticHomeArtistRecommendationSource(const [
        HomeRecommendationArtist(
          name: 'Relacionado local uno',
          browseId: 'UClocalrelated001',
        ),
        HomeRecommendationArtist(
          name: 'Relacionado local dos',
          browseId: 'UClocalrelated002',
        ),
      ]);
      final container = _combinedContainer(
        source,
        artistSource: artistSource,
        generic: [
          HomeRecommendationSection.items(
            title: 'Artistas recomendados',
            queueSourceId: 'youtube-account-home:artists',
            items: const [
              HomeRecommendationArtistItem(
                HomeRecommendationArtist(
                  name: 'Cuenta uno',
                  browseId: 'UCaccountrelated01',
                ),
              ),
              HomeRecommendationArtistItem(
                HomeRecommendationArtist(
                  name: 'Cuenta dos',
                  browseId: 'UCaccountrelated02',
                ),
              ),
            ],
          ),
        ],
      );
      await container.read(youtubeMusicHomeRecommendationsProvider.future);

      final combined = await container.read(homeRecommendationsProvider.future);
      final artists = combined.single.items
          .whereType<HomeRecommendationArtistItem>()
          .map((item) => item.artist.name);

      expect(artists, [
        'Relacionado local uno',
        'Cuenta uno',
        'Relacionado local dos',
        'Cuenta dos',
      ]);
      expect(combined.single.title, 'Artistas recomendados');
    },
  );

  test(
    'anonymous popular artists never replace qualified local history',
    () async {
      final source = _FakePersonalizedHomeFeedSource(
        CachedPersonalizedRecommendationFeed(
          feed: _personalizedFeed(),
          isExpired: false,
        ),
      );
      final artistSource = _StaticHomeArtistRecommendationSource(const []);
      final container = _combinedContainer(
        source,
        artistSource: artistSource,
        generic: [
          HomeRecommendationSection.items(
            title: 'Artistas populares',
            items: const [
              HomeRecommendationArtistItem(
                HomeRecommendationArtist(
                  name: 'Popular anónimo',
                  browseId: 'UCanonymouspopular1',
                ),
              ),
            ],
          ),
        ],
      );
      await container.read(youtubeMusicHomeRecommendationsProvider.future);

      final combined = await container.read(homeRecommendationsProvider.future);

      expect(artistSource.loadCalls, greaterThanOrEqualTo(1));
      expect(
        combined.expand((section) => section.items),
        isNot(contains(isA<HomeRecommendationArtistItem>())),
      );
      expect(
        combined.map((section) => section.title),
        isNot(contains('Artistas populares')),
      );
    },
  );

  test(
    'cold start keeps anonymous artists explicitly labeled popular',
    () async {
      final source = _FakePersonalizedHomeFeedSource(null);
      final artistSource = _StaticHomeArtistRecommendationSource(
        const [],
        hasQualifiedHistory: false,
      );
      final container = _combinedContainer(
        source,
        artistSource: artistSource,
        generic: [
          HomeRecommendationSection.items(
            title: 'Artistas populares',
            items: const [
              HomeRecommendationArtistItem(
                HomeRecommendationArtist(
                  name: 'Popular de inicio',
                  browseId: 'UCcoldstartpopular1',
                ),
              ),
            ],
          ),
        ],
      );
      await container.read(youtubeMusicHomeRecommendationsProvider.future);

      final combined = await container.read(homeRecommendationsProvider.future);

      expect(combined.single.title, 'Artistas populares');
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
          youtubeMusicAuthControllerProvider.overrideWith(
            () => _MutableHomeAuthController(
              const YouTubeMusicAuthState(
                phase: YouTubeMusicAuthPhase.anonymous,
                generation: 0,
              ),
            ),
          ),
          personalizedHomeFeedSourceProvider.overrideWithValue(source),
          homeArtistRecommendationSourceProvider.overrideWithValue(null),
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
  HomeArtistRecommendationSource? artistSource,
}) {
  final container = ProviderContainer(
    overrides: [
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
      youtubeMusicAuthControllerProvider.overrideWith(
        () => _MutableHomeAuthController(
          const YouTubeMusicAuthState(
            phase: YouTubeMusicAuthPhase.anonymous,
            generation: 0,
          ),
        ),
      ),
      personalizedHomeFeedSourceProvider.overrideWithValue(source),
      homeArtistRecommendationSourceProvider.overrideWithValue(artistSource),
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

ProviderContainer _containerFor(
  _FakeHomeSearch source, {
  Duration? artistEnrichmentBudget,
  YouTubeMusicHome? authenticatedHome,
  Duration? remoteDetailCacheDuration,
}) {
  final container = ProviderContainer(
    overrides: [
      youtubeMusicSearchProvider.overrideWithValue(source),
      youtubeMusicAuthenticatedHomeProvider.overrideWithValue(
        authenticatedHome,
      ),
      if (artistEnrichmentBudget != null)
        homeArtistEnrichmentBudgetProvider.overrideWithValue(
          artistEnrichmentBudget,
        ),
      if (remoteDetailCacheDuration != null)
        remoteDetailTracksCacheDurationProvider.overrideWithValue(
          remoteDetailCacheDuration,
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

InnerTubeHomeSection _homeCollectionSection(String title, String browseId) {
  return InnerTubeHomeSection(
    title: title,
    items: <InnerTubeHomeItem>[
      InnerTubeHomeCollection(
        title: '$title colección',
        browseId: browseId,
        kind: InnerTubeHomeCollectionKind.playlist,
      ),
    ],
  );
}

InnerTubeSong _song({
  String videoId = 'AbCdEfGhIj1',
  String title = 'Una cancion',
  List<String> artists = const ['Artista', 'Invitado'],
  List<String?>? artistBrowseIds,
}) {
  return InnerTubeSong(
    videoId: videoId,
    title: title,
    artists: artists,
    artistBrowseIds: artistBrowseIds,
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
        YouTubeMusicRelated,
        YouTubeMusicArtistProfileLookup {
  _FakeHomeSearch(this.sections);

  final List<InnerTubeHomeSection> sections;
  final Map<String, List<InnerTubeSong>> collectionSongs = {};
  final Map<String, InnerTubeNextPage> nextPages = {};
  final Map<String, Object> nextErrors = {};
  final Map<String, InnerTubeRelatedPage> relatedPages = {};
  final Map<String, InnerTubeArtistProfile> artistProfiles = {};
  Completer<InnerTubeNextPage>? nextBlocker;
  Object? homeError;
  Object? collectionError;
  int homeCalls = 0;
  int searchCalls = 0;
  int collectionCalls = 0;
  int nextCalls = 0;
  int relatedCalls = 0;
  int artistProfileCalls = 0;
  String? lastNextVideoId;
  bool? lastNextRadio;
  int? lastNextLimit;
  String? lastRelatedBrowseId;
  int? lastRelatedLimit;
  int? lastMaxSections;
  int? lastMaxItemsPerSection;
  int? lastCollectionLimit;
  String? lastCollectionBrowseId;
  final Set<String> requestedCollectionBrowseIds = <String>{};

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
    requestedCollectionBrowseIds.add(browseId);
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
    lastNextLimit = limit;
    final blocker = nextBlocker;
    if (blocker != null) {
      return blocker.future;
    }
    final failure = nextErrors[videoId];
    if (failure != null) {
      throw failure;
    }
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
  }) async {
    relatedCalls++;
    lastRelatedBrowseId = browseId;
    lastRelatedLimit = limit;
    return relatedPages[browseId] ??
        InnerTubeRelatedPage(
          songs: const [],
          albums: const [],
          artists: const [],
          collections: const [],
        );
  }

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

  @override
  Future<InnerTubeArtistProfile> getArtistProfile(
    String artistBrowseId, {
    String? fallbackName,
    String? fallbackThumbnailUrl,
    int songLimit = 20,
    int releaseLimit = 20,
  }) async {
    artistProfileCalls++;
    return artistProfiles[artistBrowseId] ??
        InnerTubeArtistProfile(
          artist: InnerTubeArtist(
            browseId: artistBrowseId,
            name: fallbackName ?? 'Artista',
            thumbnailUrl: fallbackThumbnailUrl,
          ),
          popularSongs: const [],
          albums: const [],
          singles: const [],
        );
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

class _StaticHomeArtistRecommendationSource
    implements HomeArtistRecommendationSource {
  _StaticHomeArtistRecommendationSource(
    this.artists, {
    this.hasQualifiedHistory = true,
  });

  final List<HomeRecommendationArtist> artists;
  final bool hasQualifiedHistory;
  int loadCalls = 0;

  @override
  Future<HomeArtistRecommendationResult> load({
    bool refresh = false,
    bool forceNetwork = false,
  }) async {
    loadCalls += 1;
    return HomeArtistRecommendationResult(
      artists: artists,
      hasQualifiedHistory: hasQualifiedHistory,
    );
  }
}

class _MutableHomeAuthController extends YouTubeMusicAuthController {
  _MutableHomeAuthController(this.initialState);

  final YouTubeMusicAuthState initialState;

  @override
  YouTubeMusicAuthState build() => initialState;

  void publish(YouTubeMusicAuthState value) => state = value;
}
