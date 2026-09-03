import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_ui.dart';
import 'package:bstream_music/features/music/domain/entities/search_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/pages/artist_profile_page.dart';
import 'package:bstream_music/features/music/presentation/pages/search_view.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'centers the initial prompt above reserved player space and names albums',
    (tester) async {
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

      expect(find.text('Busca canciones, artistas o álbumes'), findsOneWidget);
      expect(find.textContaining('enlaces'), findsNothing);

      final availableArea = find.byKey(
        const ValueKey('search-initial-empty-available-area'),
      );
      final areaRect = tester.getRect(availableArea);
      expect(areaRect.bottom, closeTo(800, 0.1));

      final iconRect = tester.getRect(find.byIcon(Icons.search_rounded).last);
      final subtitleRect = tester.getRect(
        find.text('Los resultados aparecerán aquí.'),
      );
      final promptCenter = (iconRect.top + subtitleRect.bottom) / 2;
      final usableAreaCenter =
          (areaRect.top + areaRect.bottom - bottomContentPadding) / 2;
      expect(promptCenter, closeTo(usableAreaCenter, 0.1));
    },
  );

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
  bool disableAnimations = false,
  double bottomContentPadding = 0,
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
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: disableAnimations),
              child: child!,
            )
          : null,
      home: Scaffold(
        body: SearchView(
          onOpenPlayer: onOpenPlayer ?? () {},
          bottomContentPadding: bottomContentPadding,
        ),
      ),
    ),
  );
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
