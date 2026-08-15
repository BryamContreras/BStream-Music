import 'package:bstream_music/features/music/domain/entities/search_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/pages/search_view.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('hides categories until a search is submitted', (tester) async {
    final controller = _RecordingSearchController(SearchState());

    await tester.pumpWidget(_searchApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Canción, artista o álbum'), findsOneWidget);
    for (final category in SearchCategory.values) {
      expect(
        find.byKey(ValueKey('search-category-${category.name}')),
        findsNothing,
      );
    }

    await tester.enterText(find.byType(TextField), 'radiohead');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(controller.submittedQueries, ['radiohead']);
    for (final category in SearchCategory.values) {
      expect(
        find.byKey(ValueKey('search-category-${category.name}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('shows responsive categories and clears the active search', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    final pages = <SearchCategory, SearchPage>{
      for (final category in SearchCategory.values)
        category: SearchPage(
          category: category,
          backend: SearchBackend.innerTube,
        ),
    };
    final controller = _RecordingSearchController(
      SearchState(query: 'radiohead', pages: pages),
    );

    await tester.pumpWidget(_searchApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-category-songs')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-category-videos')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('search-category-albums')),
      findsOneWidget,
    );
    for (final category in SearchCategory.values) {
      expect(
        tester
            .getRect(find.byKey(ValueKey('search-category-${category.name}')))
            .height,
        greaterThanOrEqualTo(48),
      );
    }
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('search-category-albums')));
    await tester.pump();

    expect(controller.selectedCategories, [SearchCategory.albums]);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextField), 'otra búsqueda');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('search-clear-button')));
    await tester.pump();

    expect(controller.clearCalls, 1);
    for (final category in SearchCategory.values) {
      expect(
        find.byKey(ValueKey('search-category-${category.name}')),
        findsNothing,
      );
    }
    expect(find.text('otra búsqueda'), findsNothing);
  });

  testWidgets('hides the search page heading on mobile only', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = _RecordingSearchController(SearchState());

    await tester.pumpWidget(
      _searchApp(controller: controller, platform: TargetPlatform.android),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-tab-title')), findsNothing);
    expect(find.byType(TextField), findsOneWidget);

    await tester.pumpWidget(
      _searchApp(controller: controller, platform: TargetPlatform.windows),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-tab-title')), findsOneWidget);
  });

  testWidgets('fallback exposes only Videos and explains yt-dlp', (
    tester,
  ) async {
    final fallbackPage = SearchPage(
      category: SearchCategory.videos,
      backend: SearchBackend.ytDlp,
      primaryError: StateError('InnerTube unavailable'),
    );
    final controller = _RecordingSearchController(
      SearchState(
        query: 'bstream',
        selectedCategory: SearchCategory.videos,
        pages: <SearchCategory, SearchPage>{
          SearchCategory.videos: fallbackPage,
        },
        fallbackOnly: true,
      ),
    );

    await tester.pumpWidget(_searchApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-category-songs')), findsNothing);
    expect(
      find.byKey(const ValueKey('search-category-videos')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search-category-albums')), findsNothing);
    expect(
      find.byKey(const ValueKey('search-fallback-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('InnerTube no respondió'), findsOneWidget);
  });

  testWidgets(
    'opens album details without playback and Play starts its queue',
    (tester) async {
      final album = SearchAlbum(
        browseId: 'MPRE-album',
        title: 'Álbum de prueba',
        artists: const ['Artista'],
        year: '2026',
        type: 'Álbum',
      );
      final tracks = <TrackInfo>[
        const TrackInfo(
          id: 'song-1',
          title: 'Primera',
          artist: 'Artista',
          url: 'https://music.youtube.com/watch?v=song-1',
        ),
        const TrackInfo(
          id: 'song-2',
          title: 'Segunda',
          artist: 'Artista',
          url: 'https://music.youtube.com/watch?v=song-2',
        ),
      ];
      final searchController = _RecordingSearchController(
        SearchState(
          query: 'album',
          selectedCategory: SearchCategory.albums,
          pages: <SearchCategory, SearchPage>{
            SearchCategory.albums: SearchPage(
              category: SearchCategory.albums,
              backend: SearchBackend.innerTube,
              albums: [album],
            ),
          },
        ),
      );
      final playerController = _RecordingPlayerController();
      var albumLoads = 0;
      var playerOpens = 0;

      await tester.pumpWidget(
        _searchApp(
          controller: searchController,
          onOpenPlayer: () => playerOpens++,
          extraOverrides: [
            playerControllerProvider.overrideWith(() => playerController),
            searchAlbumTracksProvider.overrideWith((ref, browseId) async {
              albumLoads++;
              return tracks;
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(albumLoads, 0, reason: 'Album tracks must remain lazy.');

      await tester.tap(
        find.byKey(const ValueKey('search-album-open-MPRE-album')),
      );
      await tester.pumpAndSettle();

      expect(albumLoads, 1);
      expect(
        find.byKey(const ValueKey('remote-collection-detail')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('remote-collection-title')))
            .data,
        album.title,
      );
      expect(find.text('Artista'), findsWidgets);
      expect(find.textContaining('2026'), findsOneWidget);
      expect(find.text('Primera'), findsOneWidget);
      expect(find.text('Segunda'), findsOneWidget);
      expect(playerController.lastTrack, isNull);
      expect(playerOpens, 0);

      await tester.tap(find.byKey(const ValueKey('remote-collection-play')));
      await tester.pump();

      expect(playerController.lastTrack, tracks.first);
      expect(playerController.lastQueue, tracks);
      expect(playerController.lastQueueSourceId, 'album:MPRE-album');
      expect(playerOpens, 1);
    },
  );

  testWidgets('retries an album provider after its cached failure', (
    tester,
  ) async {
    final album = SearchAlbum(
      browseId: 'MPRE-retry',
      title: 'Reintento',
      artists: const ['Artista'],
    );
    const track = TrackInfo(
      id: 'recovered-song',
      title: 'Recuperada',
      artist: 'Artista',
      url: 'https://music.youtube.com/watch?v=recovered-song',
    );
    final searchController = _RecordingSearchController(
      SearchState(
        query: 'retry',
        selectedCategory: SearchCategory.albums,
        pages: <SearchCategory, SearchPage>{
          SearchCategory.albums: SearchPage(
            category: SearchCategory.albums,
            backend: SearchBackend.innerTube,
            albums: [album],
          ),
        },
      ),
    );
    final playerController = _RecordingPlayerController();
    var albumLoads = 0;

    await tester.pumpWidget(
      _searchApp(
        controller: searchController,
        extraOverrides: [
          playerControllerProvider.overrideWith(() => playerController),
          searchAlbumTracksProvider.overrideWith((ref, browseId) async {
            albumLoads++;
            if (albumLoads == 1) {
              throw StateError('temporary failure');
            }
            return const <TrackInfo>[track];
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('search-album-open-MPRE-retry')),
    );
    await tester.pumpAndSettle();

    expect(albumLoads, 1);
    expect(
      find.byKey(const ValueKey('remote-collection-error')),
      findsOneWidget,
    );
    expect(
      find.text('No se pudieron cargar las canciones del álbum.'),
      findsOneWidget,
    );

    expect(playerController.lastTrack, isNull);

    await tester.tap(find.byKey(const ValueKey('remote-collection-retry')));
    await tester.pumpAndSettle();

    expect(albumLoads, 2);
    expect(find.byKey(const ValueKey('remote-collection-error')), findsNothing);
    expect(find.text('Recuperada'), findsOneWidget);
    expect(playerController.lastTrack, isNull);

    await tester.tap(
      find.byKey(const ValueKey('remote-collection-track-recovered-song')),
    );
    await tester.pump();

    expect(playerController.lastTrack, track);
    expect(playerController.lastQueue, const <TrackInfo>[track]);
    expect(playerController.lastQueueSourceId, 'album:MPRE-retry');
  });
}

Widget _searchApp({
  required _RecordingSearchController controller,
  VoidCallback? onOpenPlayer,
  List<Override> extraOverrides = const [],
  TargetPlatform? platform,
}) {
  return ProviderScope(
    overrides: [
      searchControllerProvider.overrideWith(() => controller),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
      ...extraOverrides,
    ],
    child: MaterialApp(
      theme: platform == null ? null : ThemeData(platform: platform),
      home: Scaffold(body: SearchView(onOpenPlayer: onOpenPlayer ?? () {})),
    ),
  );
}

class _RecordingSearchController extends SearchController {
  _RecordingSearchController(this.initialState);

  final SearchState initialState;
  final List<SearchCategory> selectedCategories = [];
  final List<String> submittedQueries = [];
  int clearCalls = 0;

  @override
  Future<SearchState> build() async => initialState;

  @override
  Future<void> submit(String query) async {
    final normalizedQuery = query.trim();
    submittedQueries.add(normalizedQuery);
    state = AsyncData(
      normalizedQuery.isEmpty
          ? SearchState()
          : SearchState(
              query: normalizedQuery,
              loadingCategory: SearchCategory.songs,
            ),
    );
  }

  @override
  Future<void> selectCategory(SearchCategory category) async {
    selectedCategories.add(category);
    final current = state.value ?? initialState;
    state = AsyncData(
      current.copyWith(selectedCategory: category, loadingCategory: null),
    );
  }

  @override
  void clear() {
    clearCalls++;
    state = AsyncData(SearchState());
  }
}

class _RecordingPlayerController extends PlayerController {
  TrackInfo? lastTrack;
  List<TrackInfo>? lastQueue;
  String? lastQueueSourceId;

  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);

  @override
  Future<void> playRemote(
    TrackInfo track, {
    List<TrackInfo>? queue,
    String? queueSourceId,
  }) async {
    lastTrack = track;
    lastQueue = queue == null ? null : List.unmodifiable(queue);
    lastQueueSourceId = queueSourceId;
  }
}
