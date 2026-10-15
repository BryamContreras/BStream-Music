import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../data/datasources/remote_music_datasource.dart';
import '../providers/music_providers.dart';
import '../providers/player/related_radio_queue_extender.dart';
import '../widgets/mini_player.dart';
import '../widgets/source_image.dart';
import '../widgets/surface_detail_app_bar.dart';
import 'artist_profile_page.dart';
import 'remote_collection_detail_page.dart';

/// A mood/genre is a browse page of shelves, not a generated song queue.
class SearchBrowseCategoryPage extends ConsumerStatefulWidget {
  const SearchBrowseCategoryPage({
    required this.category,
    required this.onOpenPlayer,
    this.onAddToPlaylist,
    super.key,
  });

  final SearchBrowseCategory category;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  @override
  ConsumerState<SearchBrowseCategoryPage> createState() =>
      _SearchBrowseCategoryPageState();
}

class _SearchBrowseCategoryPageState
    extends ConsumerState<SearchBrowseCategoryPage> {
  final _pages = <InnerTubeMoodGenrePage>[];
  final _loadedTokens = <String>{};
  bool _loadingMore = false;
  bool _continuationFailed = false;
  final _scrollMotion = GlassScrollMotionNotifier();

  @override
  void dispose() {
    _scrollMotion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final content = ref.watch(
      searchBrowseCategoryPageProvider(widget.category),
    );
    final defaultMode = defaultMiniPlayerModeForPlatform(
      Theme.of(context).platform,
    );
    final appearance = ref.watch(
      settingsControllerProvider.select(
        (settings) => (
          mode: settings.value?.miniPlayerMode ?? defaultMode,
          background:
              settings.value?.miniPlayerBackgroundMode ??
              defaultMiniPlayerBackgroundMode,
        ),
      ),
    );
    return NotificationListener<ScrollNotification>(
      onNotification: _scrollMotion.handleNotification,
      child: Scaffold(
        key: const ValueKey('search-browse-detail'),
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: SurfaceDetailAppBar(
          backdropMotion: _scrollMotion,
          title: Text(
            widget.category.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: content.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(strings.searchBrowseError),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => ref.invalidate(
                    searchBrowseCategoryPageProvider(widget.category),
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(strings.retry),
                ),
              ],
            ),
          ),
          data: (first) {
            final sections = _sections(first);
            if (sections.isEmpty) {
              return Center(child: Text(strings.searchBrowseEmpty));
            }
            final continuation = (_pages.lastOrNull ?? first).continuation;
            return CustomScrollView(
              key: const ValueKey('search-browse-detail-scroll'),
              scrollCacheExtent: const ScrollCacheExtent.pixels(160),
              slivers: [
                SliverList.builder(
                  itemCount: sections.length,
                  itemBuilder: (context, index) => _BrowseShelf(
                    key: ValueKey('browse-shelf-$index'),
                    section: sections[index],
                    onOpen: _openItem,
                  ),
                ),
                if (continuation != null &&
                    !_loadedTokens.contains(continuation))
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: TextButton.icon(
                          key: const ValueKey('search-browse-load-more'),
                          onPressed: _loadingMore
                              ? null
                              : () => _loadMore(continuation),
                          icon: _loadingMore
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.expand_more_rounded),
                          label: Text(
                            _continuationFailed
                                ? strings.retry
                                : strings.choose('Cargar más', 'Load more'),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
              ],
            );
          },
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: SizedBox(
            height: miniPlayerHeightFor(context, mode: appearance.mode),
            child: MiniPlayer(
              mode: appearance.mode,
              backgroundMode: appearance.background,
              onOpenPlayer: _openPlayer,
            ),
          ),
        ),
      ),
    );
  }

  List<InnerTubeHomeSection> _sections(InnerTubeMoodGenrePage first) {
    final sections = <InnerTubeHomeSection>[];
    final seen = <InnerTubeHomeItem>{};
    for (final page in [first, ..._pages]) {
      for (final section in page.sections) {
        final items = section.items.where(seen.add).toList(growable: false);
        if (items.isEmpty) continue;
        if (section.title.isEmpty && sections.isNotEmpty) {
          final previous = sections.removeLast();
          sections.add(
            InnerTubeHomeSection(
              title: previous.title,
              items: [...previous.items, ...items],
            ),
          );
        } else {
          sections.add(
            InnerTubeHomeSection(title: section.title, items: items),
          );
        }
      }
    }
    return sections;
  }

  Future<void> _loadMore(String token) async {
    if (_loadingMore || _loadedTokens.contains(token)) return;
    final retry = _continuationFailed;
    setState(() {
      _loadingMore = true;
      _continuationFailed = false;
    });
    try {
      if (retry) {
        ref.invalidate(searchBrowseCategoryContinuationProvider(token));
      }
      final page = await ref.read(
        searchBrowseCategoryContinuationProvider(token).future,
      );
      if (!mounted) return;
      setState(() {
        _pages.add(page);
        _loadedTokens.add(token);
      });
    } catch (_) {
      if (mounted) setState(() => _continuationFailed = true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _openPlayer() {
    Navigator.of(context).pop();
    widget.onOpenPlayer();
  }

  void _openItem(InnerTubeHomeItem item) {
    final strings = ref.read(appStringsProvider);
    if (item is InnerTubeHomeCollection) {
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => RemoteCollectionDetailPage(
            title: item.title,
            subtitle: item.subtitle ?? strings.youtubeMusic,
            artworkSource: item.thumbnailUrl,
            queueSourceId: 'browse-collection:${item.browseId}',
            tracksProvider: homeCollectionTracksProvider(item.browseId),
            detailsProvider: homeCollectionDetailProvider(item.browseId),
            emptyMessage: strings.homeCollectionEmpty,
            errorMessage: strings.homeCollectionLoadError,
            onOpenPlayer: _openPlayer,
            onAddToPlaylist: widget.onAddToPlaylist,
          ),
        ),
      );
    } else if (item is InnerTubeHomeArtistItem) {
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ArtistProfilePage(
            artistBrowseId: item.artist.browseId,
            artistName: item.artist.name,
            artistThumbnailUrl: item.artist.thumbnailUrl,
            onOpenPlayer: _openPlayer,
          ),
        ),
      );
    } else if (item is InnerTubeHomeSongItem) {
      final track = trackInfoFromInnerTubeSong(item.song);
      final selected = RecommendationPlaybackItem(track: track);
      final search = ref.read(youtubeMusicSearchProvider);
      final messenger = ScaffoldMessenger.maybeOf(context);
      final playback = ref
          .read(playerControllerProvider.notifier)
          .playRecommendation(
            selected,
            queue: [selected],
            queueSourceId: 'browse-radio:${track.id}',
            queueExtender: search is YouTubeMusicRelated
                ? buildRelatedRadioQueueExtender(
                    related: search as YouTubeMusicRelated,
                    seedVideoId: item.song.videoId,
                    initialQueue: [selected],
                  )
                : null,
          );
      unawaited(
        playback.catchError((Object _) {
          messenger?.showSnackBar(
            SnackBar(content: Text(strings.playbackError)),
          );
        }),
      );
      _openPlayer();
    }
  }
}

class _BrowseShelf extends ConsumerStatefulWidget {
  const _BrowseShelf({required this.section, required this.onOpen, super.key});
  final InnerTubeHomeSection section;
  final ValueChanged<InnerTubeHomeItem> onOpen;

  @override
  ConsumerState<_BrowseShelf> createState() => _BrowseShelfState();
}

class _BrowseShelfState extends ConsumerState<_BrowseShelf> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _move(double direction) {
    if (!_scroll.hasClients) return;
    final target =
        (_scroll.offset + direction * _scroll.position.viewportDimension * 0.8)
            .clamp(0.0, _scroll.position.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
      return;
    }
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 700;
        final cardWidth = wide ? 186.0 : 156.0;
        final scaler = MediaQuery.textScalerOf(context);
        final textHeight =
            scaler.scale(15) * 1.25 * 2 + scaler.scale(12) * 1.3 * 2;
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.section.title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (wide) ...[
                      IconButton(
                        onPressed: () => _move(-1),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).previousPageTooltip,
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      IconButton(
                        onPressed: () => _move(1),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).nextPageTooltip,
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: cardWidth + textHeight + 14,
                child: ListView.separated(
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  scrollCacheExtent: const ScrollCacheExtent.pixels(120),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: widget.section.items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, index) {
                    final item = widget.section.items[index];
                    final (
                      title,
                      subtitle,
                      artwork,
                      icon,
                      round,
                    ) = switch (item) {
                      InnerTubeHomeCollection() => (
                        item.title,
                        item.subtitle ??
                            '${strings.playlist} · ${strings.youtubeMusic}',
                        item.thumbnailUrl,
                        Icons.queue_music_rounded,
                        false,
                      ),
                      InnerTubeHomeSongItem() => (
                        item.song.title,
                        item.song.artist,
                        item.song.thumbnailUrl,
                        Icons.music_note_rounded,
                        false,
                      ),
                      InnerTubeHomeArtistItem() => (
                        item.artist.name,
                        strings.searchArtists,
                        item.artist.thumbnailUrl,
                        Icons.person_rounded,
                        true,
                      ),
                    };
                    return SizedBox(
                      width: cardWidth,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: ValueKey('browse-item-$title'),
                          onTap: () => widget.onOpen(item),
                          borderRadius: BorderRadius.circular(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  round ? cardWidth / 2 : 8,
                                ),
                                child: SizedBox.square(
                                  dimension: cardWidth,
                                  child: SourceImage(
                                    source: artwork,
                                    cacheWidth: wide ? 480 : 384,
                                    fallback: ColoredBox(
                                      color: AppColors.homeCardSurfaceFor(
                                        context,
                                      ),
                                      child: Icon(icon, size: 48),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  height: 1.25,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.contentTitleFor(context),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: AppColors.contentSubtitleFor(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
