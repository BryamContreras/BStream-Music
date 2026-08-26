import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../domain/entities/search_result.dart';
import '../providers/music_providers.dart';
import '../widgets/search_input.dart';
import '../widgets/scrolled_under_tab_frame.dart';
import '../widgets/now_playing_equalizer.dart';
import '../widgets/source_image.dart';
import '../widgets/track_result_tile.dart';
import 'artist_profile_page.dart';
import 'remote_collection_detail_page.dart';

class SearchView extends ConsumerWidget {
  const SearchView({
    required this.onOpenPlayer,
    this.onAddToPlaylist,
    this.bottomContentPadding = 0,
    super.key,
  });

  static const _headingTransitionDuration = Duration(milliseconds: 220);

  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;
  final double bottomContentPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(searchControllerProvider);
    final searchState = results.value ?? SearchState();
    final strings = ref.watch(appStringsProvider);
    final isMobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final showHeading = !isMobile || !searchState.hasQuery;
    final headingTransitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _headingTransitionDuration;

    return ScrolledUnderTabFrame(
      surfaceKey: const ValueKey('search-tab-header-surface'),
      header: AnimatedSwitcher(
        key: const ValueKey('search-tab-heading-transition'),
        duration: headingTransitionDuration,
        reverseDuration: headingTransitionDuration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.centerLeft,
          children: <Widget>[...previousChildren, ?currentChild],
        ),
        child: showHeading
            ? Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  key: const ValueKey('search-tab-title'),
                  strings.searchTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              )
            : SearchInput(
                key: const ValueKey('search-tab-search-input'),
                initialText: searchState.query,
                compact: true,
                requestFocusOnClear: false,
                hintText: strings.searchHint,
                tooltip: strings.search,
                clearTooltip: strings.clearSearch,
                onSubmitted: (query) =>
                    ref.read(searchControllerProvider.notifier).submit(query),
                onCleared: () =>
                    ref.read(searchControllerProvider.notifier).clear(),
              ),
      ),
      scrollKey: const ValueKey('search-results-scroll'),
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      slivers: [
        SliverToBoxAdapter(
          child: AnimatedPadding(
            key: const ValueKey('search-input-section-padding'),
            duration: headingTransitionDuration,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.fromLTRB(
              0,
              showHeading ? appTabFirstSectionTopGap : 20,
              0,
              14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showHeading)
                  Padding(
                    key: const ValueKey('search-input-container'),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: SearchInput(
                      hintText: strings.searchHint,
                      tooltip: strings.search,
                      clearTooltip: strings.clearSearch,
                      onSubmitted: (query) => ref
                          .read(searchControllerProvider.notifier)
                          .submit(query),
                      onCleared: () =>
                          ref.read(searchControllerProvider.notifier).clear(),
                    ),
                  ),
                if (searchState.hasQuery) ...[
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: _SearchCategoryTabs(
                      categories: searchState.availableCategories,
                      selectedCategory: searchState.selectedCategory,
                      strings: strings,
                      onSelected: (category) => ref
                          .read(searchControllerProvider.notifier)
                          .selectCategory(category),
                    ),
                  ),
                ],
                if (searchState.fallbackOnly) ...[
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: _FallbackNotice(
                      message: searchState.primaryError == null
                          ? strings.searchYtDlpVideoOnly
                          : strings.searchInnerTubeFallback,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        _SearchResultsSliver(
          results: results,
          strings: strings,
          onOpenPlayer: onOpenPlayer,
          onAddToPlaylist: onAddToPlaylist,
        ),
        SliverToBoxAdapter(
          child: SizedBox(
            key: const ValueKey('search-scroll-bottom-reserve'),
            height: bottomContentPadding + 16,
          ),
        ),
      ],
    );
  }
}

class _SearchResultsSliver extends StatelessWidget {
  const _SearchResultsSliver({
    required this.results,
    required this.strings,
    required this.onOpenPlayer,
    required this.onAddToPlaylist,
  });

  final AsyncValue<SearchState> results;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    return results.when(
      data: (state) {
        if (!state.hasQuery) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: _SearchEmptyState(
              icon: Icons.search_rounded,
              title: strings.searchEmptyTitle,
              subtitle: strings.searchEmptySubtitle,
            ),
          );
        }
        return _SearchCategoryResultsSliver(
          state: state,
          strings: strings,
          onOpenPlayer: onOpenPlayer,
          onAddToPlaylist: onAddToPlaylist,
        );
      },
      loading: () => const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => SliverFillRemaining(
        hasScrollBody: false,
        child: _SearchEmptyState(
          icon: Icons.error_outline_rounded,
          title: strings.searchErrorTitle,
          subtitle: error.toString(),
        ),
      ),
    );
  }

  static IconData _emptyIcon(SearchCategory category) => switch (category) {
    SearchCategory.songs => Icons.music_note_rounded,
    SearchCategory.videos => Icons.smart_display_rounded,
    SearchCategory.albums => Icons.album_rounded,
    SearchCategory.artists => Icons.person_rounded,
  };

  static String _emptyMessage(AppStrings strings, SearchCategory category) =>
      switch (category) {
        SearchCategory.songs => strings.searchSongsEmpty,
        SearchCategory.videos => strings.searchVideosEmpty,
        SearchCategory.albums => strings.searchAlbumsEmpty,
        SearchCategory.artists => strings.searchArtistsEmpty,
      };
}

class _SearchCategoryResultsSliver extends StatefulWidget {
  const _SearchCategoryResultsSliver({
    required this.state,
    required this.strings,
    required this.onOpenPlayer,
    required this.onAddToPlaylist,
  });

  static const _transitionDuration = Duration(milliseconds: 240);

  final SearchState state;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  @override
  State<_SearchCategoryResultsSliver> createState() =>
      _SearchCategoryResultsSliverState();
}

class _SearchCategoryResultsSliverState
    extends State<_SearchCategoryResultsSliver> {
  int _direction = 1;

  @override
  void didUpdateWidget(covariant _SearchCategoryResultsSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.state.selectedCategory.index;
    final next = widget.state.selectedCategory.index;
    if (previous != next) {
      _direction = next > previous ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final selectedCategory = widget.state.selectedCategory;
    final selectedKey = ValueKey(
      'search-category-results-${selectedCategory.name}',
    );

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 18),
      sliver: SliverToBoxAdapter(
        child: AnimatedSwitcher(
          key: const ValueKey('search-results-switcher'),
          duration: disableAnimations
              ? Duration.zero
              : _SearchCategoryResultsSliver._transitionDuration,
          reverseDuration: disableAnimations
              ? Duration.zero
              : _SearchCategoryResultsSliver._transitionDuration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[...previousChildren, ?currentChild],
          ),
          transitionBuilder: (child, animation) {
            final incoming = child.key == selectedKey;
            final horizontalOffset = incoming
                ? 0.045 * _direction
                : -0.03 * _direction;
            return ClipRect(
              child: FadeTransition(
                opacity: Tween<double>(begin: 0.35, end: 1).animate(animation),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(horizontalOffset, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
            );
          },
          // The key changes only with the selected category. Loading a page,
          // refreshing it, or updating its bounded results therefore does not
          // replay the tab transition or disturb the outer scroll position.
          child: KeyedSubtree(
            key: selectedKey,
            child: _SearchCategoryResultsBody(
              state: widget.state,
              strings: widget.strings,
              onOpenPlayer: widget.onOpenPlayer,
              onAddToPlaylist: widget.onAddToPlaylist,
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchCategoryResultsBody extends StatelessWidget {
  const _SearchCategoryResultsBody({
    required this.state,
    required this.strings,
    required this.onOpenPlayer,
    required this.onAddToPlaylist,
  });

  final SearchState state;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    if (state.isSelectedCategoryLoading || !state.hasSelectedPage) {
      return SizedBox(
        height: _minimumBodyHeight(context),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final page = state.selectedPage!;
    if (page.isEmpty) {
      return ConstrainedBox(
        constraints: BoxConstraints(minHeight: _minimumBodyHeight(context)),
        child: _SearchEmptyState(
          icon: _SearchResultsSliver._emptyIcon(state.selectedCategory),
          title: _categoryLabel(strings, state.selectedCategory),
          subtitle: _SearchResultsSliver._emptyMessage(
            strings,
            state.selectedCategory,
          ),
        ),
      );
    }

    if (state.selectedCategory == SearchCategory.albums) {
      return Column(
        children: [
          for (var index = 0; index < page.albums.length; index++) ...[
            _AlbumResultTile(
              key: ValueKey('search-album-${page.albums[index].browseId}'),
              album: page.albums[index],
              strings: strings,
              onOpenPlayer: onOpenPlayer,
              onAddToPlaylist: onAddToPlaylist,
            ),
            if (index < page.albums.length - 1) const SizedBox(height: 6),
          ],
        ],
      );
    }

    if (state.selectedCategory == SearchCategory.artists) {
      return _ArtistResultsGrid(
        artists: page.artists,
        strings: strings,
        onOpenPlayer: onOpenPlayer,
      );
    }

    final tracks = page.tracks;
    // Search pages are deliberately bounded, so keeping their rows mounted
    // makes the cross-fade stable and avoids decoding thumbnails repeatedly.
    return Column(
      children: [
        for (var index = 0; index < tracks.length; index++) ...[
          TrackResultTile(
            key: ValueKey(
              'search-result-${tracks[index].id.isNotEmpty ? tracks[index].id : tracks[index].url}',
            ),
            track: tracks[index],
            queue: tracks,
            onOpenPlayer: onOpenPlayer,
          ),
          if (index < tracks.length - 1) const SizedBox(height: 6),
        ],
      ],
    );
  }

  double _minimumBodyHeight(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.48).clamp(220.0, 480.0);
}

class _SearchCategoryTabs extends StatelessWidget {
  const _SearchCategoryTabs({
    required this.categories,
    required this.selectedCategory,
    required this.strings,
    required this.onSelected,
  });

  final List<SearchCategory> categories;
  final SearchCategory selectedCategory;
  final AppStrings strings;
  final ValueChanged<SearchCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Row(
      children: [
        for (var index = 0; index < categories.length; index++) ...[
          if (index > 0) const SizedBox(width: 6),
          Expanded(
            child: _SearchCategoryTab(
              category: categories[index],
              icon: _categoryIcon(categories[index]),
              label: _categoryLabel(strings, categories[index]),
              selected: categories[index] == selectedCategory,
              selectedColor: colors.primaryContainer,
              onSelected: onSelected,
            ),
          ),
        ],
      ],
    );
  }
}

class _SearchCategoryTab extends StatelessWidget {
  const _SearchCategoryTab({
    required this.category,
    required this.icon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.onSelected,
  });

  final SearchCategory category;
  final IconData icon;
  final String label;
  final bool selected;
  final Color selectedColor;
  final ValueChanged<SearchCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(appNavItemRadius);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final motionDuration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final scaledLabelHeight = MediaQuery.textScalerOf(context).scale(14);
    final tapTargetHeight = (scaledLabelHeight + 20)
        .clamp(48.0, 80.0)
        .toDouble();
    final surfaceHeight = (scaledLabelHeight + 14).clamp(44.0, 74.0).toDouble();
    final contentColor = selected
        ? colors.onPrimaryContainer
        : AppColors.contentTitleFor(context);

    return Semantics(
      selected: selected,
      button: true,
      child: SizedBox(
        height: tapTargetHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AnimatedContainer(
                key: ValueKey('search-category-surface-${category.name}'),
                width: double.infinity,
                height: surfaceHeight,
                duration: motionDuration,
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: selected
                      ? selectedColor
                      : AppColors.cardSurfaceFor(context),
                  borderRadius: radius,
                  border: Border.all(
                    color: selected
                        ? colors.primary
                        : AppColors.cardBorderFor(context),
                  ),
                ),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('search-category-${category.name}'),
                borderRadius: radius,
                onTap: selected ? null : () => onSelected(category),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TweenAnimationBuilder<Color?>(
                          duration: motionDuration,
                          curve: Curves.easeOutCubic,
                          tween: ColorTween(end: contentColor),
                          builder: (context, color, _) => Icon(
                            icon,
                            key: ValueKey(
                              'search-category-icon-${category.name}',
                            ),
                            size: 18,
                            color: color ?? contentColor,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: AnimatedDefaultTextStyle(
                            duration: motionDuration,
                            curve: Curves.easeOutCubic,
                            style:
                                (Theme.of(context).textTheme.labelLarge ??
                                        const TextStyle())
                                    .copyWith(
                                      color: contentColor,
                                      fontWeight: selected
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                    ),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistResultsGrid extends StatelessWidget {
  const _ArtistResultsGrid({
    required this.artists,
    required this.strings,
    required this.onOpenPlayer,
  });

  final List<SearchArtist> artists;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 10.0;
        const targetCardWidth = 126.0;
        final availableWidth = constraints.maxWidth;
        final columnCount =
            ((availableWidth + spacing) / (targetCardWidth + spacing))
                .floor()
                .clamp(2, 8);
        final cardWidth =
            (availableWidth - spacing * (columnCount - 1)) / columnCount;

        return Wrap(
          key: const ValueKey('search-artist-results'),
          spacing: spacing,
          runSpacing: 12,
          children: [
            for (final artist in artists)
              _ArtistResultCard(
                key: ValueKey('search-artist-${artist.browseId}'),
                artist: artist,
                strings: strings,
                width: cardWidth,
                onOpenPlayer: onOpenPlayer,
              ),
          ],
        );
      },
    );
  }
}

class _ArtistResultCard extends ConsumerWidget {
  const _ArtistResultCard({
    required this.artist,
    required this.strings,
    required this.width,
    required this.onOpenPlayer,
    super.key,
  });

  final SearchArtist artist;
  final AppStrings strings;
  final double width;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final artworkExtent = (width - 16).clamp(76.0, 124.0);
    final radius = BorderRadius.circular(appCardRadius);

    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label: '${strings.goToArtist}: ${artist.name}',
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            key: ValueKey('search-artist-open-${artist.browseId}'),
            borderRadius: radius,
            onTap: () => _openArtist(context, ref),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.cardBorderFor(context),
                      ),
                    ),
                    padding: const EdgeInsets.all(1),
                    child: ClipOval(
                      key: ValueKey('search-artist-artwork-${artist.browseId}'),
                      child: SizedBox.square(
                        dimension: artworkExtent,
                        child: SourceImage(
                          source: artist.thumbnailUrl,
                          cacheWidth: 384,
                          fallback: ColoredBox(
                            color: colors.surfaceContainerHighest,
                            child: Icon(
                              Icons.person_rounded,
                              size: artworkExtent * 0.42,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    artist.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.contentTitleFor(context),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openArtist(BuildContext context, WidgetRef ref) {
    final request = (
      artistBrowseId: artist.browseId,
      artistName: artist.name,
      artistThumbnailUrl: artist.thumbnailUrl,
    );
    unawaited(
      ref
          .read(artistProfileProvider(request).future)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ArtistProfilePage(
          artistBrowseId: artist.browseId,
          artistName: artist.name,
          artistThumbnailUrl: artist.thumbnailUrl,
          onOpenPlayer: onOpenPlayer,
        ),
      ),
    );
  }
}

class _FallbackNotice extends StatelessWidget {
  const _FallbackNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('search-fallback-notice'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colors.onSecondaryContainer.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 20,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumResultTile extends StatefulWidget {
  const _AlbumResultTile({
    required this.album,
    required this.strings,
    required this.onOpenPlayer,
    this.onAddToPlaylist,
    super.key,
  });

  final SearchAlbum album;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  @override
  State<_AlbumResultTile> createState() => _AlbumResultTileState();
}

class _AlbumResultTileState extends State<_AlbumResultTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(appCardRadius);
    final surface = _hovered
        ? Color.alphaBlend(
            colors.onSurface.withValues(alpha: 0.09),
            AppColors.cardSurfaceFor(context),
          )
        : AppColors.cardSurfaceFor(context);
    final details = [
      album.type?.trim(),
      album.year?.trim(),
    ].whereType<String>().where((value) => value.isNotEmpty).join(' • ');
    final artist = album.artist.trim().isEmpty
        ? widget.strings.unknownArtist
        : album.artist.trim();

    return Semantics(
      button: true,
      label: widget.strings.openAlbum(album.title),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: surface,
            borderRadius: radius,
            border: Border.all(
              color: _hovered
                  ? colors.primary
                  : AppColors.cardBorderFor(context),
              width: _hovered ? 1.4 : 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('search-album-open-${album.browseId}'),
              borderRadius: radius,
              onTap: _openAlbum,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    HoverEqualizerArtwork(
                      width: 52,
                      height: 18,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(appArtworkRadius),
                        child: SizedBox.square(
                          dimension: 62,
                          child: ProportionalArtwork(
                            source: album.thumbnailUrl,
                            cacheWidth: 256,
                            fallback: const ColoredBox(
                              color: Color(0xFF202520),
                              child: Icon(Icons.album_rounded),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MarqueeText(
                            album.title,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: AppColors.contentTitleFor(context),
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            artist,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: AppColors.contentSubtitleFor(context),
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (details.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              details,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: AppColors.contentSubtitleFor(
                                      context,
                                    ),
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.primary,
                      size: 30,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openAlbum() {
    final album = widget.album;
    final artist = album.artist.trim().isEmpty
        ? widget.strings.unknownArtist
        : album.artist.trim();
    final metadata = [album.type?.trim() ?? '', album.year?.trim() ?? ''];
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteCollectionDetailPage(
          title: album.title,
          subtitle: artist,
          artworkSource: album.thumbnailUrl,
          metadata: metadata,
          fallbackIcon: Icons.album_rounded,
          queueSourceId: 'album:${album.browseId}',
          tracksProvider: searchAlbumTracksProvider(album.browseId),
          emptyMessage: widget.strings.albumWithoutSongs,
          errorMessage: widget.strings.albumLoadError,
          onOpenPlayer: widget.onOpenPlayer,
          onAddToPlaylist: widget.onAddToPlaylist,
        ),
      ),
    );
  }
}

String _categoryLabel(AppStrings strings, SearchCategory category) =>
    switch (category) {
      SearchCategory.songs => strings.searchSongs,
      SearchCategory.videos => strings.searchVideos,
      SearchCategory.albums => strings.searchAlbums,
      SearchCategory.artists => strings.searchArtists,
    };

IconData _categoryIcon(SearchCategory category) => switch (category) {
  SearchCategory.songs => Icons.music_note_rounded,
  SearchCategory.videos => Icons.smart_display_rounded,
  SearchCategory.albums => Icons.album_rounded,
  SearchCategory.artists => Icons.person_rounded,
};

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 46,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.contentTitleFor(context),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.contentSubtitleFor(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
