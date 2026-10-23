import 'dart:async';

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/theme/app_ui.dart';
import 'package:bstream_music/core/widgets/app_shared_widgets.dart';
import 'package:bstream_music/features/music/domain/entities/search_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/presentation/pages/artist_profile_page.dart';
import 'package:bstream_music/features/music/presentation/pages/remote_collection_detail_page.dart';
import 'package:bstream_music/features/music/presentation/pages/search_view.dart';
import 'package:bstream_music/features/music/presentation/pages/search_browse_category_page.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/track_selection_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:bstream_music/services/youtube_music/search_browse_catalog_cache.dart';
import 'package:bstream_music/services/youtube_music/search_browse_artwork_cache.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('browse cards retain one grid repaint boundary for static art', (
    tester,
  ) async {
    await tester.pumpWidget(
      _searchApp(
        controller: _RecordingSearchController(SearchState()),
        platform: TargetPlatform.windows,
        surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
      ),
    );
    await tester.pumpAndSettle();

    final grid = tester.widget<SliverGrid>(
      find.byKey(const ValueKey('search-browse-grid')),
    );
    expect(
      (grid.delegate as SliverChildBuilderDelegate).addRepaintBoundaries,
      isTrue,
    );
    final card = find.byKey(const ValueKey('search-browse-card-pop'));
    expect(
      find.ancestor(of: card, matching: find.byType(RepaintBoundary)),
      findsWidgets,
      reason: 'Scrolling must still reuse the complete static card.',
    );
    expect(
      find.descendant(of: card, matching: find.byType(RepaintBoundary)),
      findsNothing,
      reason: 'The static pattern must not add a second retained layer.',
    );
    expect(
      find.byKey(const ValueKey('search-browse-pattern-pop')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'inactive browse retains live card state and artwork through refresh',
    (tester) async {
      final activity = ValueNotifier(false);
      addTearDown(activity.dispose);
      final categories = List.generate(
        84,
        (index) => SearchBrowseCategory(
          id: 'live-$index',
          title: 'Live category $index',
          searchQuery: 'live $index',
          target: InnerTubeBrowseTarget(browseId: 'moods', params: '$index'),
        ),
      );
      final catalog = SearchBrowseCatalog(
        categories: categories,
        usesLiveYouTubeMusicCategories: true,
      );
      final refresh = Completer<SearchBrowseCatalog>();
      var catalogRequests = 0;
      var artworkRequests = 0;
      await tester.pumpWidget(
        _searchApp(
          controller: _RecordingSearchController(SearchState()),
          activity: activity,
          useDefaultBrowseCatalogOverride: false,
          catalogCache: _MemorySearchBrowseCatalogCache(
            SearchBrowseCatalogSnapshot(
              usesLiveYouTubeMusicCategories: true,
              categories: const [
                SearchBrowseCategorySnapshot(
                  id: 'older-cached-card',
                  title: 'Older disk catalog',
                  searchQuery: 'cached',
                ),
              ],
            ),
          ),
          extraOverrides: [
            searchBrowseCatalogProvider.overrideWith((ref) {
              catalogRequests++;
              return catalogRequests == 1
                  ? Future.value(catalog)
                  : refresh.future;
            }),
            searchBrowseCategoryArtworkProvider.overrideWith((
              ref,
              category,
            ) async {
              // Production retains successful metadata lookups; model that cache
              // so the test counts requests rather than provider auto-disposal.
              ref.keepAlive();
              artworkRequests++;
              return 'https://img.test/${category.id}.jpg';
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(catalogRequests, 0);
      expect(artworkRequests, 0);
      activity.value = true;
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('search-browse-card-live-0'));
      final cover = find.byKey(const ValueKey('search-browse-cover-live-0'));
      final state = tester.state(card);
      final coverState = tester.state(cover);
      final initialArtworkRequests = artworkRequests;
      final container = ProviderScope.containerOf(tester.element(card));
      final grid = tester.widget<SliverGrid>(
        find.byKey(const ValueKey('search-browse-grid')),
      );
      expect((grid.delegate as SliverChildBuilderDelegate).childCount, 84);
      expect(catalogRequests, 1);
      expect(initialArtworkRequests, greaterThan(0));
      activity.value = false;
      await tester.pumpAndSettle();
      expect(tester.state(card), same(state));
      expect(tester.state(cover), same(coverState));
      expect(find.text('Live category 0'), findsOneWidget);
      expect(
        tester.widget<SourceImage>(cover).source,
        'https://img.test/live-0.jpg',
      );
      expect(artworkRequests, initialArtworkRequests);
      container.invalidate(searchBrowseCatalogProvider);
      await tester.pumpAndSettle();
      expect(
        catalogRequests,
        1,
        reason: 'An inactive tab must not restart discovery.',
      );
      activity.value = true;
      await tester.pump();
      await tester.pump();
      expect(catalogRequests, 2);
      expect(tester.state(card), same(state));
      expect(tester.state(cover), same(coverState));
      expect(artworkRequests, initialArtworkRequests);
      refresh.complete(
        SearchBrowseCatalog(
          categories: [
            SearchBrowseCategory(
              id: 'live-0',
              title: 'Updated live category',
              searchQuery: 'updated',
              target: categories.first.target,
            ),
          ],
          usesLiveYouTubeMusicCategories: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Updated live category'), findsOneWidget);
      expect(tester.state(card), same(state));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'locale change drops retained browse data without inactive discovery',
    (tester) async {
      final activity = ValueNotifier(true);
      addTearDown(activity.dispose);
      var catalogRequests = 0;
      await tester.pumpWidget(
        _searchApp(
          controller: _RecordingSearchController(SearchState()),
          activity: activity,
          useDefaultBrowseCatalogOverride: false,
          useTestLanguageProvider: true,
          extraOverrides: [
            searchBrowseCatalogProvider.overrideWith((ref) async {
              final language = ref.watch(appStringsProvider).appLanguage;
              catalogRequests++;
              return SearchBrowseCatalog(
                categories: [
                  SearchBrowseCategory(
                    id: 'live-${language.code}',
                    title: language == AppLanguage.spanish
                        ? 'Spanish live card'
                        : 'English live card',
                    searchQuery: language.code,
                  ),
                ],
                usesLiveYouTubeMusicCategories: true,
              );
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Spanish live card'), findsOneWidget);
      expect(catalogRequests, 1);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SearchView)),
      );
      activity.value = false;
      await tester.pumpAndSettle();
      container
          .read(_browseTestLanguageProvider.notifier)
          .select(AppLanguage.english);
      await tester.pumpAndSettle();
      expect(find.text('Spanish live card'), findsNothing);
      expect(find.text('Party'), findsOneWidget);
      expect(catalogRequests, 1);
      activity.value = true;
      await tester.pumpAndSettle();
      expect(find.text('English live card'), findsOneWidget);
      expect(find.text('Spanish live card'), findsNothing);
      expect(catalogRequests, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'category pagination keeps shelves and retries a failed continuation',
    (tester) async {
      const category = SearchBrowseCategory(
        id: 'page',
        title: 'Concentración',
        searchQuery: 'focus',
      );
      const firstItem = InnerTubeHomeCollection(
        title: 'Primera playlist',
        browseId: 'VLfirst',
        kind: InnerTubeHomeCollectionKind.playlist,
      );
      const nextItem = InnerTubeHomeCollection(
        title: 'Otra playlist',
        browseId: 'VLnext',
        kind: InnerTubeHomeCollectionKind.playlist,
      );
      var continuationAttempts = 0;
      await tester.pumpWidget(
        _searchApp(
          controller: _RecordingSearchController(SearchState()),
          browseCatalog: SearchBrowseCatalog(
            categories: [category],
            usesLiveYouTubeMusicCategories: false,
          ),
          extraOverrides: [
            playerControllerProvider.overrideWith(
              _RecordingPlayerController.new,
            ),
            searchBrowseCategoryPageProvider.overrideWith(
              (ref, category) async => InnerTubeMoodGenrePage(
                sections: [
                  InnerTubeHomeSection(title: 'Flotando', items: [firstItem]),
                ],
                continuation: 'next-page',
              ),
            ),
            searchBrowseCategoryContinuationProvider.overrideWith((
              ref,
              token,
            ) async {
              expect(token, 'next-page');
              if (++continuationAttempts == 1) {
                throw StateError('temporary network error');
              }
              return InnerTubeMoodGenrePage(
                sections: [
                  InnerTubeHomeSection(title: '', items: [firstItem, nextItem]),
                ],
                continuation: 'next-page',
              );
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('search-browse-action-page')));
      await tester.pumpAndSettle();
      final load = find.byKey(const ValueKey('search-browse-load-more'));
      await tester.ensureVisible(load);
      await tester.tap(load);
      await tester.pumpAndSettle();
      expect(continuationAttempts, 1);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text('Flotando'), findsOneWidget);
      await tester.tap(load);
      await tester.pumpAndSettle();
      expect(continuationAttempts, 2);
      expect(
        find.byKey(const ValueKey('browse-item-Primera playlist')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('browse-item-Otra playlist')),
        findsOneWidget,
      );
      expect(find.text('Flotando'), findsOneWidget);
      expect(
        load,
        findsNothing,
        reason: 'a repeated continuation token cannot trigger a loop',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'live category cover shows first-song artwork with opaque category colors',
    (tester) async {
      const category = SearchBrowseCategory(
        id: 'focus',
        title: 'Concentración',
        searchQuery: 'focus',
        target: InnerTubeBrowseTarget(
          browseId: 'FEmusic_moods_and_genres_category',
          params: 'focus',
        ),
      );
      await tester.pumpWidget(
        _searchApp(
          controller: _RecordingSearchController(SearchState()),
          browseCatalog: SearchBrowseCatalog(
            categories: [category],
            usesLiveYouTubeMusicCategories: true,
          ),
          extraOverrides: [
            searchBrowseCategoryArtworkProvider.overrideWith(
              (ref, category) async => 'https://img.test/first-song.jpg',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final cover = tester.widget<SourceImage>(
        find.byKey(const ValueKey('search-browse-cover-focus')),
      );
      expect(cover.source, 'https://img.test/first-song.jpg');
      expect(cover.cacheWidth, lessThanOrEqualTo(384));
      expect(cover.opacity, 0.72);
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('search-browse-cover-focus')),
          matching: find.byType(Opacity),
        ),
        findsNothing,
        reason: 'Artwork alpha must not allocate a layer for every card.',
      );
      final titlePadding = tester.widget<Padding>(
        find.byKey(const ValueKey('search-browse-title-padding-focus')),
      );
      expect(
        titlePadding.padding,
        const EdgeInsetsDirectional.fromSTEB(14, 13, 14, 13),
      );
      final surface = tester.widget<Ink>(
        find.byKey(const ValueKey('search-browse-surface-focus')),
      );
      expect(
        (surface.decoration! as BoxDecoration).gradient!.colors.every(
          (color) => color.a == 1,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cached category cover appears first and refreshes when metadata changes',
    (tester) async {
      const category = SearchBrowseCategory(
        id: 'focus',
        title: 'ConcentraciÃ³n',
        searchQuery: 'focus',
        target: InnerTubeBrowseTarget(
          browseId: 'FEmusic_moods_and_genres_category',
          params: 'focus',
        ),
      );
      final artworkCache = _MemorySearchBrowseCategoryArtworkCache()
        ..values['focus'] = 'https://img.test/cached-cover.jpg';
      final refreshedArtwork = Completer<String?>();

      await tester.pumpWidget(
        _searchApp(
          controller: _RecordingSearchController(SearchState()),
          browseCatalog: SearchBrowseCatalog(
            categories: [category],
            usesLiveYouTubeMusicCategories: true,
          ),
          artworkCache: artworkCache,
          extraOverrides: [
            searchBrowseCategoryArtworkProvider.overrideWith(
              (ref, category) => refreshedArtwork.future,
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        tester
            .widget<SourceImage>(
              find.byKey(const ValueKey('search-browse-cover-focus')),
            )
            .source,
        'https://img.test/cached-cover.jpg',
      );

      refreshedArtwork.complete('https://img.test/refreshed-cover.jpg');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SourceImage>(
              find.byKey(const ValueKey('search-browse-cover-focus')),
            )
            .source,
        'https://img.test/refreshed-cover.jpg',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restores cached browse cards and covers before live catalog refresh',
    (tester) async {
      const category = SearchBrowseCategory(
        id: 'yt:focus',
        title: 'ConcentraciÃ³n',
        searchQuery: 'ConcentraciÃ³n',
        target: InnerTubeBrowseTarget(
          browseId: 'FEmusic_moods_and_genres_category',
          params: 'focus-target',
        ),
      );
      final catalogCache = _MemorySearchBrowseCatalogCache(
        SearchBrowseCatalogSnapshot(
          usesLiveYouTubeMusicCategories: true,
          categories: const [
            SearchBrowseCategorySnapshot(
              id: 'yt:focus',
              title: 'ConcentraciÃ³n',
              searchQuery: 'ConcentraciÃ³n',
              browseId: 'FEmusic_moods_and_genres_category',
              params: 'focus-target',
            ),
          ],
        ),
      );
      final artworkCache = _MemorySearchBrowseCategoryArtworkCache()
        ..values['yt:focus'] = 'https://img.test/cached-focus.jpg';
      final liveCatalog = Completer<SearchBrowseCatalog>();
      final refreshedArtwork = Completer<String?>();

      await tester.pumpWidget(
        _searchApp(
          controller: _RecordingSearchController(SearchState()),
          useDefaultBrowseCatalogOverride: false,
          catalogCache: catalogCache,
          artworkCache: artworkCache,
          extraOverrides: [
            searchBrowseCatalogProvider.overrideWith(
              (ref) => liveCatalog.future,
            ),
            searchBrowseCategoryArtworkProvider.overrideWith(
              (ref, category) => refreshedArtwork.future,
            ),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey('search-browse-action-yt:focus')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SourceImage>(
              find.byKey(const ValueKey('search-browse-cover-yt:focus')),
            )
            .source,
        'https://img.test/cached-focus.jpg',
      );

      liveCatalog.complete(
        SearchBrowseCatalog(
          categories: [category],
          usesLiveYouTubeMusicCategories: true,
        ),
      );
      refreshedArtwork.complete('https://img.test/new-focus.jpg');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SourceImage>(
              find.byKey(const ValueKey('search-browse-cover-yt:focus')),
            )
            .source,
        'https://img.test/new-focus.jpg',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('offscreen cards do not start cover lookups', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final requested = <String>[];
    final categories = [
      for (var i = 0; i < 40; i++)
        SearchBrowseCategory(
          id: 'card-$i',
          title: 'Categoría $i',
          searchQuery: '$i',
          target: InnerTubeBrowseTarget(
            browseId: 'FEmusic_moods_and_genres_category',
            params: 'card-$i',
          ),
        ),
    ];
    await tester.pumpWidget(
      _searchApp(
        controller: _RecordingSearchController(SearchState()),
        browseCatalog: SearchBrowseCatalog(
          categories: categories,
          usesLiveYouTubeMusicCategories: true,
        ),
        extraOverrides: [
          searchBrowseCategoryArtworkProvider.overrideWith((
            ref,
            category,
          ) async {
            requested.add(category.id);
            return null;
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(requested, isNotEmpty);
    expect(requested.length, lessThan(12));
    expect(requested, isNot(contains('card-20')));
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1000.0]) {
    testWidgets(
      'category shelves fit width $width and open the selected playlist',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = width < 400
            ? 1.8
            : 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        const category = SearchBrowseCategory(
          id: 'focus',
          title: 'Concentración',
          searchQuery: 'focus',
        );
        final player = _RecordingPlayerController();
        final page = InnerTubeMoodGenrePage(
          sections: [
            InnerTubeHomeSection(
              title: 'Flotando',
              items: const [
                InnerTubeHomeCollection(
                  title: 'Lo-fi Loft',
                  browseId: 'VLlofi',
                  kind: InnerTubeHomeCollectionKind.playlist,
                ),
              ],
            ),
            InnerTubeHomeSection(
              title: 'Música clásica',
              items: const [
                InnerTubeHomeCollection(
                  title: 'Dulce Piano',
                  browseId: 'VLpiano',
                  kind: InnerTubeHomeCollectionKind.playlist,
                ),
              ],
            ),
          ],
        );
        await tester.pumpWidget(
          _searchApp(
            controller: _RecordingSearchController(SearchState()),
            browseCatalog: SearchBrowseCatalog(
              categories: [category],
              usesLiveYouTubeMusicCategories: false,
            ),
            extraOverrides: [
              playerControllerProvider.overrideWith(() => player),
              searchBrowseCategoryPageProvider.overrideWith(
                (ref, category) async => page,
              ),
              homeCollectionDetailProvider.overrideWith(
                (ref, id) async =>
                    RemoteCollectionData(title: 'Lo-fi Loft', tracks: []),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('search-browse-action-focus')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SearchBrowseCategoryPage), findsOneWidget);
        expect(find.text('Flotando'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('browse-item-Lo-fi Loft')),
          findsOneWidget,
        );
        expect(
          tester
              .getSize(find.byKey(const ValueKey('browse-item-Lo-fi Loft')))
              .width,
          closeTo(width < 700 ? 164.0 : 196.0, 0.5),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('browse-item-Lo-fi Loft')));
        await tester.pumpAndSettle();
        final detail = tester.widget<RemoteCollectionDetailPage>(
          find.byType(RemoteCollectionDetailPage),
        );
        expect(detail.title, 'Lo-fi Loft');
        expect(detail.queueSourceId, 'browse-collection:VLlofi');
        expect(player.lastRecommendationSelected, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'browse category cards stay opaque in every surface style and theme',
    (tester) async {
      for (final brightness in Brightness.values) {
        for (final mode in SurfaceBackgroundMode.values) {
          await tester.pumpWidget(
            _searchApp(
              controller: _RecordingSearchController(SearchState()),
              brightness: brightness,
              surfaceBackgroundMode: mode,
            ),
          );
          await tester.pumpAndSettle();
          for (final id in ['pop', 'party']) {
            final surface = tester.widget<Ink>(
              find.byKey(ValueKey('search-browse-surface-$id')),
            );
            final gradient = (surface.decoration! as BoxDecoration).gradient!;
            expect(
              gradient.colors.every((color) => color.a == 1),
              isTrue,
              reason: '$id / $mode / $brightness',
            );
          }
        }
      }
    },
  );

  testWidgets('search adds the marked songs to an existing playlist', (
    tester,
  ) async {
    final tracks = _searchTracks('Elegida', 'selected', count: 3);
    final playlists = _SearchSelectionPlaylists();
    final controller = _RecordingSearchController(
      SearchState(
        query: 'consulta',
        pages: {
          SearchCategory.songs: SearchPage(
            category: SearchCategory.songs,
            backend: SearchBackend.innerTube,
            tracks: tracks,
          ),
        },
      ),
    );
    await tester.pumpWidget(
      _searchApp(
        controller: controller,
        extraOverrides: [
          playlistsControllerProvider.overrideWith(() => playlists),
          libraryTracksProvider.overrideWith((ref) async => []),
          catalogPlaylistsProvider.overrideWith((ref) async => []),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Elegida 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elegida 2'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('search-selection-add-to-playlist')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('playlist-picker-create')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('playlist-picker-option-selection-playlist')),
    );
    await tester.pumpAndSettle();
    expect(playlists.tracks, [tracks[1], tracks[2]]);
    expect(
      find.byKey(const ValueKey('search-selection-toolbar')),
      findsNothing,
    );
  });

  for (final category in [SearchCategory.songs, SearchCategory.videos]) {
    testWidgets('$category supports multiselect downloads without playback', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final tracks = _searchTracks('Seleccionable', 'selected', count: 3);
      final downloads = _SearchSelectedDownloads();
      final player = _RecordingPlayerController();
      final controller = _RecordingSearchController(
        SearchState(
          query: 'consulta',
          selectedCategory: category,
          pages: {
            category: SearchPage(
              category: category,
              backend: SearchBackend.innerTube,
              tracks: tracks,
            ),
          },
        ),
      );
      await tester.pumpWidget(
        _searchApp(
          controller: controller,
          platform: TargetPlatform.android,
          extraOverrides: [
            downloadControllerProvider.overrideWith(() => downloads),
            playerControllerProvider.overrideWith(() => player),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Seleccionable 0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Seleccionable 2'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('search-selection-toolbar')),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('track-result-selection-selected-1')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('search-selection-download')));
      await tester.pumpAndSettle();
      expect(downloads.tracks, [tracks[0], tracks[2]]);
      expect(player.lastTrack, isNull);
      expect(player.lastRecommendationSelected, isNull);
      expect(
        find.byKey(const ValueKey('search-selection-toolbar')),
        findsNothing,
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('search selections clear on another query or category', (
    tester,
  ) async {
    final songs = _searchTracks('Cancion', 'selected', count: 2);
    final videos = _searchTracks('Video', 'videos', count: 2);
    final controller = _RecordingSearchController(
      SearchState(
        query: 'consulta',
        pages: {
          SearchCategory.songs: SearchPage(
            category: SearchCategory.songs,
            backend: SearchBackend.innerTube,
            tracks: songs,
          ),
          SearchCategory.videos: SearchPage(
            category: SearchCategory.videos,
            backend: SearchBackend.innerTube,
            tracks: videos,
          ),
        },
      ),
    );
    await tester.pumpWidget(_searchApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Cancion 0'));
    await tester.pumpAndSettle();
    await controller.selectCategory(SearchCategory.videos);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('search-selection-toolbar')),
      findsNothing,
    );
    await tester.longPress(find.text('Video 0'));
    await tester.pumpAndSettle();
    await controller.submit('otra consulta');
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SearchView)),
    );
    expect(
      container.read(trackSelectionProvider(searchTrackSelectionScope)).active,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('suggests while typing and searches a selected suggestion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = _RecordingSearchController(SearchState());
    final suggestions = _RecordingSuggestionSearch();

    await tester.pumpWidget(
      _searchApp(controller: controller, suggestionsService: suggestions),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'tay');
    await tester.pump(const Duration(milliseconds: 150));
    expect(suggestions.requestedQueries, isEmpty);
    expect(find.byKey(const ValueKey('search-suggestion-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-browse-grid')), findsNothing);

    await tester.enterText(find.byType(TextField), 'taylor');
    await tester.pump(const Duration(milliseconds: 310));
    expect(suggestions.requestedQueries, <String>['taylor']);
    suggestions.complete('taylor', <String>[
      'taylor',
      'Taylor Swift',
      'Taylor Swift canciones',
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Taylor Swift'), findsOneWidget);
    await tester.tap(find.text('Taylor Swift'));
    await tester.pump();

    expect(controller.submittedQueries, <String>['Taylor Swift']);
    expect(find.byKey(const ValueKey('search-suggestion-0')), findsNothing);
  });

  testWidgets('keyboard arrows select suggestions and Enter searches them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = _RecordingSearchController(SearchState());
    final suggestions = _RecordingSuggestionSearch();

    await tester.pumpWidget(
      _searchApp(
        controller: controller,
        suggestionsService: suggestions,
        platform: TargetPlatform.windows,
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'taylor');
    await tester.pump(const Duration(milliseconds: 310));
    suggestions.complete('taylor', ['Taylor Swift', 'Taylor Swift live']);
    await tester.pumpAndSettle();

    expect(find.text('taylor'), findsNWidgets(2));
    expect(find.text('Taylor Swift'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final selectedSuggestion = tester.widget<ListTile>(
      find.byKey(const ValueKey('search-suggestion-1')),
    );
    expect(selectedSuggestion.selected, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      tester
          .widget<ListTile>(find.byKey(const ValueKey('search-suggestion-2')))
          .selected,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.submittedQueries, ['Taylor Swift']);
    expect(find.byKey(const ValueKey('search-suggestion-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('mouse selects a suggestion on $platform across frames', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final controller = _RecordingSearchController(SearchState());
      final suggestions = _RecordingSuggestionSearch();
      await tester.pumpWidget(
        _searchApp(
          controller: controller,
          suggestionsService: suggestions,
          platform: platform,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'taylor');
      await tester.pump(const Duration(milliseconds: 310));
      suggestions.complete('taylor', ['Taylor Swift']);
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.down(tester.getCenter(find.text('Taylor Swift')));
      await tester.pump();
      expect(find.text('Taylor Swift'), findsOneWidget);
      expect(controller.submittedQueries, isEmpty);
      await mouse.up();
      // The fake search intentionally keeps the results in their loading state.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(controller.submittedQueries, ['Taylor Swift']);
      expect(find.byKey(const ValueKey('search-suggestion-0')), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Taylor Swift',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ignores suggestions from an older typed query', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final suggestions = _RecordingSuggestionSearch();

    await tester.pumpWidget(
      _searchApp(
        controller: _RecordingSearchController(SearchState()),
        suggestionsService: suggestions,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bad');
    await tester.pump(const Duration(milliseconds: 310));
    expect(suggestions.requestedQueries, <String>['bad']);

    await tester.enterText(find.byType(TextField), 'bad bunny');
    await tester.pump(const Duration(milliseconds: 310));
    suggestions.complete('bad bunny', <String>['Bad Bunny nuevo']);
    await tester.pumpAndSettle();
    expect(find.text('Bad Bunny nuevo'), findsOneWidget);

    suggestions.complete('bad', <String>['Resultado obsoleto']);
    await tester.pumpAndSettle();
    expect(find.text('Resultado obsoleto'), findsNothing);
    expect(find.text('Bad Bunny nuevo'), findsOneWidget);
  });

  testWidgets('shows an adaptive browse grid above the reserved player space', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const bottomContentPadding = 120.0;
    final controller = _RecordingSearchController(SearchState());

    await tester.pumpWidget(
      _searchApp(
        controller: controller,
        bottomContentPadding: bottomContentPadding,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Explorar todo'), findsOneWidget);
    expect(find.text('Busca canciones, artistas o álbumes'), findsNothing);
    expect(find.byKey(const ValueKey('search-browse-grid')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-browse-card-pop')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('search-browse-card-party')),
      findsOneWidget,
    );
    final popRect = tester.getRect(
      find.byKey(const ValueKey('search-browse-card-pop')),
    );
    final partyRect = tester.getRect(
      find.byKey(const ValueKey('search-browse-card-party')),
    );
    expect(popRect.top, closeTo(partyRect.top, 0.1));
    expect(popRect.width, closeTo(partyRect.width, 0.1));
    expect(popRect.height, greaterThanOrEqualTo(48));

    final popSurface = tester.widget<Ink>(
      find.byKey(const ValueKey('search-browse-surface-pop')),
    );
    expect((popSurface.decoration as BoxDecoration).gradient, isNotNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('search-browse-grid')),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );
    final scrollView = tester.widget<CustomScrollView>(
      find.byKey(const ValueKey('search-results-scroll')),
    );
    final reserveSliver = scrollView.slivers.last as SliverToBoxAdapter;
    expect((reserveSliver.child as SizedBox).height, bottomContentPadding + 16);
  });

  testWidgets('gives real YouTube Music categories distinct semantic artwork', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const categories = <SearchBrowseCategory>[
      SearchBrowseCategory(
        id: 'energy',
        title: 'Energ\u00eda',
        searchQuery: 'Energ\u00eda',
      ),
      SearchBrowseCategory(
        id: 'exercise',
        title: 'Ejercicio',
        searchQuery: 'Ejercicio',
      ),
      SearchBrowseCategory(
        id: 'christmas',
        title: 'Navidad',
        searchQuery: 'Navidad',
      ),
      SearchBrowseCategory(
        id: 'road',
        title: 'Para el camino',
        searchQuery: 'Para el camino',
      ),
      SearchBrowseCategory(
        id: 'feel-good',
        title: 'Para sentirse bien',
        searchQuery: 'Para sentirse bien',
      ),
      SearchBrowseCategory(
        id: 'focus',
        title: 'Concentraci\u00f3n',
        searchQuery: 'Concentraci\u00f3n',
      ),
      SearchBrowseCategory(id: 'sleep', title: 'Dormir', searchQuery: 'Dormir'),
      SearchBrowseCategory(
        id: 'relaxation',
        title: 'Relajaci\u00f3n',
        searchQuery: 'Relajaci\u00f3n',
      ),
      SearchBrowseCategory(
        id: 'gaming',
        title: 'Gaming',
        searchQuery: 'Gaming',
      ),
    ];
    const expectedIcons = <String, IconData>{
      'energy': Icons.electric_bolt_rounded,
      'exercise': Icons.fitness_center_rounded,
      'christmas': Icons.card_giftcard_rounded,
      'road': Icons.directions_car_rounded,
      'feel-good': Icons.sentiment_very_satisfied_rounded,
      'focus': Icons.center_focus_strong_rounded,
      'sleep': Icons.bedtime_rounded,
      'relaxation': Icons.air_rounded,
      'gaming': Icons.sports_esports_rounded,
    };
    final controller = _RecordingSearchController(SearchState());

    await tester.pumpWidget(
      _searchApp(
        controller: controller,
        browseCatalog: SearchBrowseCatalog(
          categories: categories,
          usesLiveYouTubeMusicCategories: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final visibleIcons = <int>{};
    for (final entry in expectedIcons.entries) {
      final iconFinder = find.byKey(
        ValueKey('search-browse-icon-${entry.key}'),
      );
      expect(iconFinder, findsOneWidget);
      final icon = tester.widget<Icon>(iconFinder);
      expect(icon.icon, entry.value);
      expect(visibleIcons.add(icon.icon!.codePoint), isTrue);
      expect(
        find.byKey(ValueKey('search-browse-pattern-${entry.key}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('search-browse-art-${entry.key}')),
        findsOneWidget,
      );
    }
    expect(visibleIcons, hasLength(categories.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keeps two browse columns tappable on a compact high-scale screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final controller = _RecordingSearchController(SearchState());
      final selected = <SearchBrowseCategory>[];

      await tester.pumpWidget(
        _searchApp(
          controller: controller,
          onBrowseCategorySelected: selected.add,
        ),
      );
      await tester.pumpAndSettle();

      final popRect = tester.getRect(
        find.byKey(const ValueKey('search-browse-card-pop')),
      );
      final partyRect = tester.getRect(
        find.byKey(const ValueKey('search-browse-card-party')),
      );
      expect(popRect.top, closeTo(partyRect.top, 0.1));
      expect(popRect.left, lessThan(partyRect.left));
      expect(popRect.height, greaterThanOrEqualTo(48));
      expect(
        find.byKey(const ValueKey('search-browse-art-pop')),
        findsNothing,
        reason: 'large text gets the full card width without decorative art',
      );
      expect(
        tester
            .widget<Padding>(
              find.byKey(const ValueKey('search-browse-title-padding-pop')),
            )
            .padding,
        const EdgeInsetsDirectional.fromSTEB(14, 13, 14, 13),
      );
      expect(tester.takeException(), isNull);

      final popAction = find.byKey(const ValueKey('search-browse-action-pop'));
      await tester.ensureVisible(popAction);
      await tester.pumpAndSettle();
      await tester.tap(popAction);
      await tester.pump();

      expect(selected.single.id, 'pop');
      expect(controller.submittedQueries, isEmpty);
    },
  );

  testWidgets('expands the browse grid to four columns on a wide viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = _RecordingSearchController(SearchState());

    await tester.pumpWidget(_searchApp(controller: controller));
    await tester.pumpAndSettle();

    final firstRow = ['pop', 'party', 'reggae', 'chill']
        .map(
          (id) =>
              tester.getRect(find.byKey(ValueKey('search-browse-card-$id'))),
        )
        .toList(growable: false);
    for (final rect in firstRow.skip(1)) {
      expect(rect.top, closeTo(firstRow.first.top, 0.1));
    }
    expect(
      tester.getRect(find.byKey(const ValueKey('search-browse-card-love'))).top,
      greaterThan(firstRow.first.bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop input follows a query changed programmatically', (
    tester,
  ) async {
    final controller = _RecordingSearchController(SearchState());

    await tester.pumpWidget(
      _searchApp(controller: controller, platform: TargetPlatform.windows),
    );
    await tester.pumpAndSettle();

    controller.replaceState(
      SearchState(
        query: 'música electrónica',
        loadingCategory: SearchCategory.songs,
      ),
    );
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'música electrónica',
    );

    controller.replaceState(SearchState());
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
    expect(controller.clearCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('browse cards open their shelves by default', (tester) async {
    const pop = SearchBrowseCategory(
      id: 'pop',
      title: 'Pop',
      searchQuery: 'pop music',
    );
    final controller = _RecordingSearchController(SearchState());
    var categoryLoads = 0;

    await tester.pumpWidget(
      _searchApp(
        controller: controller,
        browseCatalog: SearchBrowseCatalog(
          categories: const [pop],
          usesLiveYouTubeMusicCategories: false,
        ),
        extraOverrides: [
          searchBrowseCategoryPageProvider.overrideWith((ref, category) async {
            categoryLoads++;
            expect(category, pop);
            return InnerTubeMoodGenrePage(sections: const []);
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('search-browse-action-pop')));
    await tester.pumpAndSettle();

    final detail = tester.widget<SearchBrowseCategoryPage>(
      find.byType(SearchBrowseCategoryPage),
    );
    expect(detail.category, pop);
    expect(categoryLoads, 1);
    expect(controller.submittedQueries, isEmpty);
  });

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
      expect(
        find.byKey(ValueKey('search-category-icon-${category.name}')),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(find.byKey(ValueKey('search-category-${category.name}')))
            .height,
        48,
      );
      expect(
        tester
            .getSize(
              find.byKey(ValueKey('search-category-surface-${category.name}')),
            )
            .height,
        44,
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
        find.ancestor(
          of: find.byKey(ValueKey('search-category-surface-${category.name}')),
          matching: find.byType(AppCardGradientBorder),
        ),
        findsNothing,
      );
      final tapTarget = tester.getRect(
        find.byKey(ValueKey('search-category-${category.name}')),
      );
      final surface = tester.getRect(
        find.byKey(ValueKey('search-category-surface-${category.name}')),
      );
      expect(tapTarget.height, greaterThanOrEqualTo(48));
      expect(surface.height, greaterThanOrEqualTo(44));
      expect(surface.height, lessThan(tapTarget.height));
    }
    expect(tester.takeException(), isNull);

    final categoryScroller = find.ancestor(
      of: find.byKey(const ValueKey('search-category-songs')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
    );
    final categoryScrollable = find.descendant(
      of: categoryScroller,
      matching: find.byType(Scrollable),
    );
    final albumsTab = find.byKey(const ValueKey('search-category-albums'));
    await tester
        .state<ScrollableState>(categoryScrollable)
        .position
        .ensureVisible(tester.renderObject(albumsTab), alignment: 0.5);
    await tester.pump();
    await tester.tap(albumsTab);
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

  testWidgets(
    'narrow screens keep full category labels in a horizontal scroller',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
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

      await tester.pumpWidget(
        _searchApp(controller: controller, platform: TargetPlatform.android),
      );
      await tester.pumpAndSettle();

      final categoryScroller = find.ancestor(
        of: find.byKey(const ValueKey('search-category-songs')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is SingleChildScrollView &&
              widget.scrollDirection == Axis.horizontal,
        ),
      );
      expect(categoryScroller, findsOneWidget);

      for (final entry in const <SearchCategory, String>{
        SearchCategory.songs: 'Canciones',
        SearchCategory.videos: 'Videos',
        SearchCategory.albums: 'Álbumes',
        SearchCategory.artists: 'Artistas',
      }.entries) {
        final label = entry.value;
        final labelFinder = find.descendant(
          of: find.byKey(ValueKey('search-category-${entry.key.name}')),
          matching: find.text(label),
        );
        expect(labelFinder, findsOneWidget);

        final context = tester.element(labelFinder);
        final painter = TextPainter(
          text: TextSpan(
            text: label,
            style: DefaultTextStyle.of(context).style,
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        expect(
          tester.getSize(labelFinder).width,
          greaterThanOrEqualTo(painter.width - 0.01),
          reason: '$label must have enough width to render without ellipsis',
        );
      }

      for (var index = 1; index < SearchCategory.values.length; index++) {
        final previous = tester.getRect(
          find.byKey(
            ValueKey(
              'search-category-${SearchCategory.values[index - 1].name}',
            ),
          ),
        );
        final current = tester.getRect(
          find.byKey(
            ValueKey('search-category-${SearchCategory.values[index].name}'),
          ),
        );
        expect(
          current.left - previous.right,
          closeTo(6, 0.01),
          reason:
              'category cards should retain their horizontal breathing room',
        );
      }

      final songsLeftBefore = tester
          .getRect(find.byKey(const ValueKey('search-category-songs')))
          .left;
      final scrollable = find.descendant(
        of: categoryScroller,
        matching: find.byType(Scrollable),
      );
      final scrollPosition = tester.state<ScrollableState>(scrollable).position;
      expect(scrollPosition.maxScrollExtent, greaterThan(0));
      scrollPosition.jumpTo(scrollPosition.maxScrollExtent);
      await tester.pump();
      final songsLeftAfter = tester
          .getRect(find.byKey(const ValueKey('search-category-songs')))
          .left;
      expect(songsLeftAfter, lessThan(songsLeftBefore));

      await tester.tap(find.byKey(const ValueKey('search-category-artists')));
      await tester.pump();
      expect(controller.selectedCategories, [SearchCategory.artists]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mobile heading transitions out and back with the search state', (
    tester,
  ) async {
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

    expect(find.byKey(const ValueKey('search-tab-title')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-tab-header-surface')),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    final headingTransition = find.byKey(
      const ValueKey('search-tab-heading-transition'),
    );
    expect(
      tester.widget<AnimatedSwitcher>(headingTransition).duration,
      const Duration(milliseconds: 220),
    );
    expect(
      tester
          .widget<AnimatedPadding>(
            find.byKey(const ValueKey('search-input-section-padding')),
          )
          .duration,
      const Duration(milliseconds: 220),
    );
    expect(
      (tester
                  .widget<AnimatedPadding>(
                    find.byKey(const ValueKey('search-input-section-padding')),
                  )
                  .padding
              as EdgeInsets)
          .top,
      appTabFirstSectionTopGap,
    );

    await tester.enterText(find.byType(TextField), 'radiohead');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(find.byKey(const ValueKey('search-tab-title')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-tab-header-surface')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search-category-songs')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 80));

    final outgoingFade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('search-tab-title')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(outgoingFade.opacity.value, greaterThan(0));
    expect(outgoingFade.opacity.value, lessThan(1));
    expect(tester.takeException(), isNull);

    // The fake controller deliberately remains in a loading state, so use a
    // bounded pump instead of waiting for its progress indicator to settle.
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byKey(const ValueKey('search-tab-title')), findsNothing);
    expect(
      find.byKey(const ValueKey('search-tab-header-surface')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('search-tab-search-input')),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'radiohead',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('search-tab-header-surface')),
        matching: find.byKey(const ValueKey('search-tab-search-input')),
      ),
      findsOneWidget,
    );
    expect(
      (tester
                  .widget<AnimatedPadding>(
                    find.byKey(const ValueKey('search-input-section-padding')),
                  )
                  .padding
              as EdgeInsets)
          .top,
      10,
    );
    final headerBottom = tester
        .getRect(find.byKey(const ValueKey('search-tab-header-surface')))
        .bottom;
    final categoriesTop = tester
        .getRect(
          find.byKey(const ValueKey('search-category-horizontal-scroll')),
        )
        .top;
    expect(
      categoriesTop - headerBottom,
      closeTo(20, 0.01),
      reason: 'filters should sit closer to the active search bar',
    );

    await tester.tap(find.byKey(const ValueKey('search-clear-button')));
    await tester.pump();

    expect(find.byKey(const ValueKey('search-tab-title')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('search-tab-header-surface')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('search-category-songs')), findsNothing);

    final incomingFade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('search-tab-title')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(incomingFade.opacity.value, 0);

    await tester.pump(const Duration(milliseconds: 80));

    expect(incomingFade.opacity.value, greaterThan(0));
    expect(incomingFade.opacity.value, lessThan(1));
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();

    expect(
      (tester
                  .widget<AnimatedPadding>(
                    find.byKey(const ValueKey('search-input-section-padding')),
                  )
                  .padding
              as EdgeInsets)
          .top,
      appTabFirstSectionTopGap,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );

    await tester.pumpWidget(
      _searchApp(controller: controller, platform: TargetPlatform.windows),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('search-tab-title')), findsOneWidget);
  });

  testWidgets('mobile heading transition honors reduced motion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = _RecordingSearchController(SearchState());

    await tester.pumpWidget(
      _searchApp(
        controller: controller,
        platform: TargetPlatform.android,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<AnimatedSwitcher>(
            find.byKey(const ValueKey('search-tab-heading-transition')),
          )
          .duration,
      Duration.zero,
    );
    expect(
      tester
          .widget<AnimatedPadding>(
            find.byKey(const ValueKey('search-input-section-padding')),
          )
          .duration,
      Duration.zero,
    );

    await tester.enterText(find.byType(TextField), 'radiohead');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(find.byKey(const ValueKey('search-tab-title')), findsNothing);
    expect(
      find.byKey(const ValueKey('search-tab-header-surface')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('search-tab-header-surface')),
        matching: find.byKey(const ValueKey('search-tab-search-input')),
      ),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop keeps its heading during an active search', (
    tester,
  ) async {
    final controller = _RecordingSearchController(
      SearchState(query: 'radiohead', loadingCategory: SearchCategory.songs),
    );

    await tester.pumpWidget(
      _searchApp(controller: controller, platform: TargetPlatform.windows),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('search-tab-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-category-songs')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final category in [SearchCategory.songs, SearchCategory.videos]) {
    testWidgets('${category.name} starts radio from the selected result only', (
      tester,
    ) async {
      const selected = TrackInfo(
        id: 'abc123def45',
        title: 'Cancion elegida',
        artist: 'Artista',
        url: 'https://music.youtube.com/watch?v=abc123def45',
      );
      const unrelated = TrackInfo(
        id: 'xyz123uvw45',
        title: 'Otro resultado',
        artist: 'Otro artista',
        url: 'https://music.youtube.com/watch?v=xyz123uvw45',
      );
      final controller = _RecordingSearchController(
        SearchState(
          query: 'consulta',
          selectedCategory: category,
          pages: {
            category: SearchPage(
              category: category,
              backend: SearchBackend.innerTube,
              tracks: const [selected, unrelated],
            ),
          },
        ),
      );
      final player = _RecordingPlayerController();
      await tester.pumpWidget(
        _searchApp(
          controller: controller,
          extraOverrides: [playerControllerProvider.overrideWith(() => player)],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          ValueKey(
            category == SearchCategory.songs
                ? 'track-result-surface-${selected.id}'
                : 'track-result-play-${selected.id}',
          ),
        ),
      );
      await tester.pump();

      expect(player.lastRecommendationSelected?.track, selected);
      expect(player.lastRecommendationQueue?.map((item) => item.track), [
        selected,
      ]);
      expect(player.lastRecommendationSourceId, 'search-radio:${selected.id}');
      expect(player.lastRecommendationExtender, isNotNull);
      expect(player.lastTrack, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a search result without a radio ID stays a one-song queue', (
    tester,
  ) async {
    const selected = TrackInfo(
      id: 'outside',
      title: 'Sin radio',
      artist: 'Artista',
      url: 'https://example.com/audio',
    );
    const unrelated = TrackInfo(
      id: 'other',
      title: 'Otro resultado',
      artist: 'Otro artista',
      url: 'https://example.com/other',
    );
    final controller = _RecordingSearchController(
      SearchState(
        query: 'consulta',
        selectedCategory: SearchCategory.videos,
        pages: {
          SearchCategory.videos: SearchPage(
            category: SearchCategory.videos,
            backend: SearchBackend.innerTubeVideoFallback,
            tracks: const [selected, unrelated],
          ),
        },
      ),
    );
    final player = _RecordingPlayerController();
    await tester.pumpWidget(
      _searchApp(
        controller: controller,
        extraOverrides: [playerControllerProvider.overrideWith(() => player)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('track-result-surface-outside')),
    );
    await tester.pump();

    expect(player.lastTrack, selected);
    expect(player.lastQueue, [selected]);
    expect(player.lastRecommendationSelected, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'uses a subtle category transition without resetting the search scroll',
    (tester) async {
      final songs = _searchTracks('Canción', 'song');
      final videos = _searchTracks('Video', 'video');
      final controller = _RecordingSearchController(
        SearchState(
          query: 'radiohead',
          pages: <SearchCategory, SearchPage>{
            SearchCategory.songs: SearchPage(
              category: SearchCategory.songs,
              backend: SearchBackend.innerTube,
              tracks: songs,
            ),
            SearchCategory.videos: SearchPage(
              category: SearchCategory.videos,
              backend: SearchBackend.innerTube,
              tracks: videos,
            ),
          },
        ),
      );

      await tester.pumpWidget(
        _searchApp(
          controller: controller,
          platform: TargetPlatform.windows,
          extraOverrides: [
            playerControllerProvider.overrideWith(
              () => _RecordingPlayerController(),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final switcher = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('search-results-switcher')),
      );
      expect(switcher.duration, const Duration(milliseconds: 240));
      final heading = find.byKey(const ValueKey('search-tab-title'));
      final headingTop = tester.getTopLeft(heading).dy;
      final headerSurface = find.byKey(
        const ValueKey('search-tab-header-surface'),
      );
      expect(
        tester.widget<Material>(headerSurface).color,
        AppColors.tabHeaderSurfaceFor(
          tester.element(headerSurface),
          scrolledUnder: false,
        ),
      );
      expect(tester.getSize(headerSurface).height, closeTo(64, 0.1));

      await tester.drag(
        find.byKey(const ValueKey('search-results-scroll')),
        const Offset(0, -90),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final offsetBeforeSelection = scrollable.position.pixels;
      expect(offsetBeforeSelection, greaterThan(0));
      expect(tester.getTopLeft(heading).dy, closeTo(headingTop, 0.01));
      expect(
        tester.widget<Material>(headerSurface).color,
        AppColors.tabHeaderSurfaceFor(
          tester.element(headerSurface),
          scrolledUnder: true,
        ),
      );
      expect(tester.widget<Material>(headerSurface).elevation, 1);
      expect(
        tester.widget<Material>(headerSurface).surfaceTintColor,
        Colors.transparent,
      );

      await controller.selectCategory(SearchCategory.videos);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));

      final forwardSongTransition = tester.widget<SlideTransition>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('search-category-results-songs')),
              matching: find.byType(SlideTransition),
            )
            .first,
      );
      final forwardVideoTransition = tester.widget<SlideTransition>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('search-category-results-videos')),
              matching: find.byType(SlideTransition),
            )
            .first,
      );
      expect(forwardSongTransition.position.value.dx, lessThan(0));
      expect(forwardVideoTransition.position.value.dx, greaterThan(0));

      expect(find.text('Canción 0'), findsOneWidget);
      expect(find.text('Video 0'), findsOneWidget);
      expect(scrollable.position.pixels, closeTo(offsetBeforeSelection, 0.01));

      await tester.pumpAndSettle();

      expect(find.text('Canción 0'), findsNothing);
      expect(find.text('Video 0'), findsOneWidget);
      expect(scrollable.position.pixels, closeTo(offsetBeforeSelection, 0.01));

      await controller.selectCategory(SearchCategory.songs);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));

      final backwardVideoTransition = tester.widget<SlideTransition>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('search-category-results-videos')),
              matching: find.byType(SlideTransition),
            )
            .first,
      );
      final backwardSongTransition = tester.widget<SlideTransition>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('search-category-results-songs')),
              matching: find.byType(SlideTransition),
            )
            .first,
      );
      expect(backwardVideoTransition.position.value.dx, greaterThan(0));
      expect(backwardSongTransition.position.value.dx, lessThan(0));
      expect(scrollable.position.pixels, closeTo(offsetBeforeSelection, 0.01));

      await tester.pumpAndSettle();
      await controller.selectCategory(SearchCategory.videos);
      await tester.pumpAndSettle();

      controller.replaceState(
        SearchState(
          query: 'radiohead',
          selectedCategory: SearchCategory.videos,
          pages: <SearchCategory, SearchPage>{
            SearchCategory.videos: SearchPage(
              category: SearchCategory.videos,
              backend: SearchBackend.innerTube,
              tracks: _searchTracks('Video actualizado', 'updated'),
            ),
          },
        ),
      );
      await tester.pump();

      expect(find.text('Video 0'), findsNothing);
      expect(find.text('Video actualizado 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disables search category motion when reduced motion is active', (
    tester,
  ) async {
    final controller = _RecordingSearchController(
      SearchState(
        query: 'radiohead',
        pages: <SearchCategory, SearchPage>{
          SearchCategory.songs: SearchPage(
            category: SearchCategory.songs,
            backend: SearchBackend.innerTube,
            tracks: _searchTracks('Canción', 'song', count: 1),
          ),
          SearchCategory.videos: SearchPage(
            category: SearchCategory.videos,
            backend: SearchBackend.innerTube,
            tracks: _searchTracks('Video', 'video', count: 1),
          ),
        },
      ),
    );

    await tester.pumpWidget(
      _searchApp(
        controller: controller,
        disableAnimations: true,
        extraOverrides: [
          playerControllerProvider.overrideWith(
            () => _RecordingPlayerController(),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<AnimatedSwitcher>(
            find.byKey(const ValueKey('search-results-switcher')),
          )
          .duration,
      Duration.zero,
    );
    expect(
      tester
          .widget<AnimatedContainer>(
            find.byKey(const ValueKey('search-category-surface-songs')),
          )
          .duration,
      Duration.zero,
    );

    await controller.selectCategory(SearchCategory.videos);
    await tester.pumpAndSettle();

    expect(find.text('Canción 0'), findsNothing);
    expect(find.text('Video 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fallback exposes only Videos and explains InnerTube fallback', (
    tester,
  ) async {
    final fallbackPage = SearchPage(
      category: SearchCategory.videos,
      backend: SearchBackend.innerTubeVideoFallback,
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
    expect(
      find.textContaining('fallback de videos de InnerTube'),
      findsOneWidget,
    );
  });

  testWidgets(
    'Artists uses circular portraits and opens the selected profile',
    (tester) async {
      const artist = SearchArtist(
        browseId: 'UC-search-artist',
        name: 'Artista circular',
        thumbnailUrl: 'https://lh3.googleusercontent.com/artist=w512-h512',
      );
      final controller = _RecordingSearchController(
        SearchState(
          query: 'artista',
          pages: <SearchCategory, SearchPage>{
            SearchCategory.songs: SearchPage(
              category: SearchCategory.songs,
              backend: SearchBackend.innerTube,
            ),
            SearchCategory.artists: SearchPage(
              category: SearchCategory.artists,
              backend: SearchBackend.innerTube,
              artists: const <SearchArtist>[artist],
            ),
          },
        ),
      );

      await tester.pumpWidget(
        _searchApp(
          controller: controller,
          platform: TargetPlatform.android,
          extraOverrides: [
            playerControllerProvider.overrideWith(
              () => _RecordingPlayerController(),
            ),
            artistProfileProvider.overrideWith((ref, request) async {
              return InnerTubeArtistProfile(
                artist: InnerTubeArtist(
                  browseId: request.artistBrowseId,
                  name: request.artistName,
                  thumbnailUrl: request.artistThumbnailUrl,
                ),
                popularSongs: const <InnerTubeSong>[],
                albums: const <InnerTubeAlbum>[],
                singles: const <InnerTubeAlbum>[],
              );
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('search-category-songs')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('search-category-videos')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('search-category-albums')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('search-category-artists')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('search-category-artists')));
      await tester.pumpAndSettle();

      expect(controller.selectedCategories, [SearchCategory.artists]);
      final portrait = find.byKey(
        const ValueKey('search-artist-artwork-UC-search-artist'),
      );
      expect(portrait, findsOneWidget);
      expect(tester.widget<ClipOval>(portrait), isA<ClipOval>());
      expect(
        tester
            .widget<SourceImage>(
              find.descendant(of: portrait, matching: find.byType(SourceImage)),
            )
            .source,
        artist.thumbnailUrl,
      );
      expect(find.text(artist.name), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('search-artist-open-UC-search-artist')),
      );
      await tester.pumpAndSettle();

      final profile = tester.widget<ArtistProfilePage>(
        find.byType(ArtistProfilePage),
      );
      expect(profile.artistBrowseId, artist.browseId);
      expect(profile.artistName, artist.name);
      expect(profile.artistThumbnailUrl, artist.thumbnailUrl);
    },
  );

  testWidgets('Artists shows its own empty state', (tester) async {
    final controller = _RecordingSearchController(
      SearchState(
        query: 'sin coincidencias',
        selectedCategory: SearchCategory.artists,
        pages: <SearchCategory, SearchPage>{
          SearchCategory.artists: SearchPage(
            category: SearchCategory.artists,
            backend: SearchBackend.innerTube,
          ),
        },
      ),
    );

    await tester.pumpWidget(_searchApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('Artistas'), findsNWidgets(2));
    expect(
      find.text('No encontramos artistas para esta búsqueda.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.person_rounded), findsWidgets);
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
        thumbnailUrl: 'https://lh3.googleusercontent.com/album-cover=w512',
      );
      final tracks = <TrackInfo>[
        const TrackInfo(
          id: 'song-1',
          title: 'Primera',
          artist: 'Artista',
          url: 'https://music.youtube.com/watch?v=song-1',
          thumbnailUrl: 'https://i.ytimg.com/vi/song-1/hq720.jpg',
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
      final firstTrackArtwork = find.descendant(
        of: find.byKey(const ValueKey('remote-collection-track-song-1')),
        matching: find.byType(SourceImage),
      );
      expect(firstTrackArtwork, findsOneWidget);
      expect(
        tester.widget<SourceImage>(firstTrackArtwork).source,
        'https://lh3.googleusercontent.com/album-cover=w512',
      );
      expect(
        tester.widget<SourceImage>(firstTrackArtwork).fallbackSource,
        'https://i.ytimg.com/vi/song-1/hq720.jpg',
      );
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
  YouTubeMusicSearchSuggestions? suggestionsService,
  VoidCallback? onOpenPlayer,
  ValueChanged<SearchBrowseCategory>? onBrowseCategorySelected,
  SearchBrowseCatalog? browseCatalog,
  SearchBrowseCatalogCache? catalogCache,
  bool useDefaultBrowseCatalogOverride = true,
  List<Override> extraOverrides = const [],
  TargetPlatform? platform,
  Brightness brightness = Brightness.light,
  SurfaceBackgroundMode surfaceBackgroundMode = SurfaceBackgroundMode.accent,
  bool disableAnimations = false,
  double bottomContentPadding = 0,
  SearchBrowseCategoryArtworkCache? artworkCache,
  ValueListenable<bool>? activity,
  bool useTestLanguageProvider = false,
}) {
  const strings = AppStrings(AppLanguage.spanish);
  final resolvedBrowseCatalog =
      browseCatalog ??
      SearchBrowseCatalog(
        categories: fallbackSearchBrowseCategories(strings),
        usesLiveYouTubeMusicCategories: false,
      );
  return ProviderScope(
    overrides: [
      searchControllerProvider.overrideWith(() => controller),
      youtubeMusicSearchSuggestionsProvider.overrideWithValue(
        suggestionsService ?? const _NoSuggestionsSearch(),
      ),
      if (useTestLanguageProvider)
        appStringsProvider.overrideWith(
          (ref) => AppStrings(ref.watch(_browseTestLanguageProvider)),
        )
      else
        appStringsProvider.overrideWithValue(strings),
      searchBrowseCatalogCacheProvider.overrideWithValue(
        catalogCache ?? _MemorySearchBrowseCatalogCache(),
      ),
      if (useDefaultBrowseCatalogOverride)
        searchBrowseCatalogProvider.overrideWithValue(
          AsyncData(resolvedBrowseCatalog),
        ),
      searchBrowseCategoryArtworkCacheProvider.overrideWithValue(
        artworkCache ?? _MemorySearchBrowseCategoryArtworkCache(),
      ),
      ...extraOverrides,
    ],
    child: MaterialApp(
      theme: ThemeData(
        platform: platform,
        brightness: brightness,
        extensions: [AppSurfaceTheme(backgroundMode: surfaceBackgroundMode)],
      ),
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: disableAnimations),
              child: child!,
            )
          : null,
      home: Scaffold(
        body: activity == null
            ? SearchView(
                onOpenPlayer: onOpenPlayer ?? () {},
                onBrowseCategorySelected: onBrowseCategorySelected,
                bottomContentPadding: bottomContentPadding,
              )
            : ValueListenableBuilder<bool>(
                valueListenable: activity,
                builder: (context, active, _) => SearchView(
                  active: active,
                  onOpenPlayer: onOpenPlayer ?? () {},
                  onBrowseCategorySelected: onBrowseCategorySelected,
                  bottomContentPadding: bottomContentPadding,
                ),
              ),
      ),
    ),
  );
}

final _browseTestLanguageProvider =
    NotifierProvider<_BrowseTestLanguage, AppLanguage>(_BrowseTestLanguage.new);

class _BrowseTestLanguage extends Notifier<AppLanguage> {
  @override
  AppLanguage build() => AppLanguage.spanish;

  void select(AppLanguage language) => state = language;
}

final class _MemorySearchBrowseCategoryArtworkCache
    implements SearchBrowseCategoryArtworkCache {
  _MemorySearchBrowseCategoryArtworkCache({Map<String, String>? values}) {
    if (values != null) this.values.addAll(values);
  }

  final values = <String, String>{};

  @override
  Future<String?> read(String categoryId) async => values[categoryId];

  @override
  Future<void> write(String categoryId, String? artworkUrl) async {
    if (artworkUrl == null) {
      values.remove(categoryId);
    } else {
      values[categoryId] = artworkUrl;
    }
  }
}

final class _MemorySearchBrowseCatalogCache
    implements SearchBrowseCatalogCache {
  _MemorySearchBrowseCatalogCache([this.snapshot]);

  final SearchBrowseCatalogSnapshot? snapshot;

  @override
  Future<SearchBrowseCatalogSnapshot?> read(String languageCode) async =>
      snapshot;

  @override
  Future<void> write(
    String languageCode,
    SearchBrowseCatalogSnapshot catalog,
  ) async {}
}

class _NoSuggestionsSearch implements YouTubeMusicSearchSuggestions {
  const _NoSuggestionsSearch();

  @override
  Future<List<String>> getSearchSuggestions(
    String query, {
    int limit = 8,
  }) async => const <String>[];
}

class _SearchSelectedDownloads extends DownloadController {
  List<TrackInfo>? tracks;

  @override
  Map<String, DownloadTaskState> build() => const {};

  @override
  Future<int> downloadTracks(Iterable<TrackInfo> tracks) async {
    this.tracks = tracks.toList();
    return tracks.length;
  }
}

class _SearchSelectionPlaylists extends PlaylistsController {
  List<TrackInfo>? tracks;

  @override
  Future<List<Playlist>> build() async => [
    Playlist(
      id: 'selection-playlist',
      name: 'Selección',
      trackIds: const [],
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
  ];

  @override
  Future<int> addRemoteTracksToPlaylist(
    String playlistId,
    Iterable<TrackInfo> tracks, {
    bool download = false,
  }) async {
    expect(playlistId, 'selection-playlist');
    expect(download, isFalse);
    this.tracks = tracks.toList();
    return tracks.length;
  }
}

class _RecordingSuggestionSearch implements YouTubeMusicSearchSuggestions {
  final List<String> requestedQueries = <String>[];
  final Map<String, Completer<List<String>>> _pending =
      <String, Completer<List<String>>>{};

  @override
  Future<List<String>> getSearchSuggestions(String query, {int limit = 8}) {
    requestedQueries.add(query);
    return (_pending[query] = Completer<List<String>>()).future;
  }

  void complete(String query, List<String> values) {
    _pending[query]!.complete(values);
  }
}

List<TrackInfo> _searchTracks(
  String titlePrefix,
  String idPrefix, {
  int count = 12,
}) => List<TrackInfo>.generate(
  count,
  (index) => TrackInfo(
    id: '$idPrefix-$index',
    title: '$titlePrefix $index',
    artist: 'Artista',
    duration: const Duration(minutes: 3),
    url: 'https://music.youtube.com/watch?v=$idPrefix-$index',
  ),
  growable: false,
);

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

  void replaceState(SearchState value) {
    state = AsyncData(value);
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
  RecommendationPlaybackItem? lastRecommendationSelected;
  List<RecommendationPlaybackItem>? lastRecommendationQueue;
  String? lastRecommendationSourceId;
  RecommendationQueueExtender? lastRecommendationExtender;

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

  @override
  Future<void> playRecommendation(
    RecommendationPlaybackItem selected, {
    required List<RecommendationPlaybackItem> queue,
    String? queueSourceId,
    RecommendationQueueExtender? queueExtender,
  }) async {
    lastRecommendationSelected = selected;
    lastRecommendationQueue = List.unmodifiable(queue);
    lastRecommendationSourceId = queueSourceId;
    lastRecommendationExtender = queueExtender;
  }
}
