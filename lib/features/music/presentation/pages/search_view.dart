import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/search_result.dart';
import '../providers/music_providers.dart';
import '../widgets/search_input.dart';
import '../widgets/source_image.dart';
import '../widgets/track_result_tile.dart';
import 'remote_collection_detail_page.dart';

class SearchView extends ConsumerWidget {
  const SearchView({required this.onOpenPlayer, super.key});

  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(searchControllerProvider);
    final searchState = results.value ?? SearchState();
    final strings = ref.watch(appStringsProvider);
    final isMobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isMobile || !searchState.hasQuery) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      key: const ValueKey('search-tab-title'),
                      strings.searchTitle,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
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
  });

  final AsyncValue<SearchState> results;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;

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
        if (state.isSelectedCategoryLoading || !state.hasSelectedPage) {
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final page = state.selectedPage!;
        if (page.isEmpty) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: _SearchEmptyState(
              icon: _emptyIcon(state.selectedCategory),
              title: _categoryLabel(strings, state.selectedCategory),
              subtitle: _emptyMessage(strings, state.selectedCategory),
            ),
          );
        }

        if (state.selectedCategory == SearchCategory.albums) {
          return SliverPadding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 18),
            sliver: SliverList.separated(
              itemCount: page.albums.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final album = page.albums[index];
                return _AlbumResultTile(
                  key: ValueKey('search-album-${album.browseId}'),
                  album: album,
                  strings: strings,
                  onOpenPlayer: onOpenPlayer,
                );
              },
            ),
          );
        }

        final tracks = page.tracks;
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 18),
          // Search is capped at a small result set. Keeping its rows mounted
          // avoids repeatedly decoding the same thumbnails while scrolling.
          sliver: SliverToBoxAdapter(
            child: Column(
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
            ),
          ),
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
  };

  static String _emptyMessage(AppStrings strings, SearchCategory category) =>
      switch (category) {
        SearchCategory.songs => strings.searchSongsEmpty,
        SearchCategory.videos => strings.searchVideosEmpty,
        SearchCategory.albums => strings.searchAlbumsEmpty,
      };
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
    final radius = BorderRadius.circular(8);
    final tabHeight = (MediaQuery.textScalerOf(context).scale(14) + 20)
        .clamp(48.0, 80.0)
        .toDouble();

    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? selectedColor : AppColors.cardSurfaceFor(context),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? colors.primary : AppColors.cardBorderFor(context),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('search-category-${category.name}'),
          onTap: selected ? null : () => onSelected(category),
          child: SizedBox(
            height: tabHeight,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      key: ValueKey('search-category-icon-${category.name}'),
                      size: 18,
                      color: selected
                          ? colors.onPrimaryContainer
                          : AppColors.contentTitleFor(context),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: selected
                              ? colors.onPrimaryContainer
                              : AppColors.contentTitleFor(context),
                          fontWeight: selected
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                      ),
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
    super.key,
  });

  final SearchAlbum album;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;

  @override
  State<_AlbumResultTile> createState() => _AlbumResultTileState();
}

class _AlbumResultTileState extends State<_AlbumResultTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(8);
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
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
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
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            album.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: AppColors.contentTitleFor(context),
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: AppColors.contentSubtitleFor(context),
                                ),
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
    };

IconData _categoryIcon(SearchCategory category) => switch (category) {
  SearchCategory.songs => Icons.music_note_rounded,
  SearchCategory.videos => Icons.smart_display_rounded,
  SearchCategory.albums => Icons.album_rounded,
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
