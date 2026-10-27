import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../providers/music_providers.dart';
import '../widgets/artwork_gradient_header_background.dart';
import '../widgets/mini_player.dart';
import '../widgets/source_image.dart';
import '../widgets/surface_detail_app_bar.dart';
import 'remote_collection_detail_page.dart';

final artistReleaseCatalogProvider = FutureProvider.autoDispose
    .family<InnerTubeArtistReleaseCatalog, InnerTubeBrowseTarget>((
      ref,
      target,
    ) {
      final service = ref.watch(youtubeMusicSearchProvider);
      if (service is! YouTubeMusicArtistReleaseCatalogLookup) {
        throw UnsupportedError('Artist releases are not available.');
      }
      return (service as YouTubeMusicArtistReleaseCatalogLookup)
          .getArtistReleaseCatalog(target);
    });

class ArtistReleasesPage extends ConsumerWidget {
  const ArtistReleasesPage({
    required this.artistBrowseId,
    required this.artistName,
    required this.categoryTitle,
    required this.onOpenPlayer,
    this.target,
    this.initialReleases = const <InnerTubeAlbum>[],
    this.artistThumbnailUrl,
    super.key,
  });

  final String artistBrowseId;
  final String artistName;
  final String categoryTitle;
  final InnerTubeBrowseTarget? target;
  final List<InnerTubeAlbum> initialReleases;
  final String? artistThumbnailUrl;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final browseTarget = target;
    final catalog = browseTarget == null
        ? null
        : ref.watch(artistReleaseCatalogProvider(browseTarget));
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
    final miniPlayerMode = appearance.mode;
    final underlayMiniPlayer =
        miniPlayerMode == MiniPlayerMode.capsule ||
        appearance.background.usesBackdrop;
    final miniPlayerHeight = miniPlayerHeightFor(context, mode: miniPlayerMode);
    final bottomInset = underlayMiniPlayer
        ? miniPlayerHeight + MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    final fetchedCatalog = catalog?.value;
    final fetchedReleases = fetchedCatalog?.releases;
    // A profile shelf can already contain the entire category, in which case
    // YouTube Music publishes no separate "view all" browse endpoint. Keep its
    // releases visible as well while refreshing or if that endpoint fails.
    final releases = fetchedReleases?.isNotEmpty == true
        ? fetchedCatalog!.isComplete
              ? fetchedReleases!
              : _mergePartialReleases(fetchedReleases!, initialReleases)
        : initialReleases;
    final isComplete =
        browseTarget == null ||
        (fetchedReleases?.isNotEmpty == true && fetchedCatalog!.isComplete);
    final isLoading = catalog?.isLoading ?? false;
    final hasError = catalog?.hasError ?? false;
    final showPartialNotice =
        browseTarget != null &&
        releases.isNotEmpty &&
        !isLoading &&
        (hasError || !isComplete);
    final releaseKind = categoryTitle.toLowerCase();
    final countLabel = isComplete
        ? '${releases.length}'
        : '${releases.length}+';

    return Scaffold(
      key: const ValueKey('artist-releases-page'),
      extendBody: underlayMiniPlayer,
      extendBodyBehindAppBar: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: SurfaceDetailAppBar(
        title: Text(
          categoryTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: ArtworkColorPageBackground(
              artworkSource: artistThumbnailUrl,
              keyPrefix: 'artist-releases',
            ),
          ),
          CustomScrollView(
            key: const ValueKey('artist-releases-scroll'),
            scrollCacheExtent: const ScrollCacheExtent.pixels(520),
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(height: surfaceDetailAppBarBodyInset(context)),
              ),
              SliverToBoxAdapter(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              ClipOval(
                                key: const ValueKey('artist-releases-artwork'),
                                child: SizedBox.square(
                                  dimension: 64,
                                  child: SourceImage(
                                    source: artistThumbnailUrl,
                                    cacheWidth: 256,
                                    fit: BoxFit.cover,
                                    fallback: ColoredBox(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.person_rounded,
                                        color: AppColors.contentSubtitleFor(
                                          context,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      artistName,
                                      key: const ValueKey(
                                        'artist-releases-artist',
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall
                                          ?.copyWith(
                                            color: AppColors.contentHeadingFor(
                                              context,
                                            ),
                                            fontWeight: FontWeight.w900,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    if (releases.isNotEmpty)
                                      Text(
                                        '$countLabel $releaseKind',
                                        key: const ValueKey(
                                          'artist-releases-count',
                                        ),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color:
                                                  AppColors.contentSubtitleFor(
                                                    context,
                                                  ),
                                            ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (isLoading && releases.isNotEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: LinearProgressIndicator(),
                  ),
                ),
              if (showPartialNotice)
                SliverToBoxAdapter(
                  child: Padding(
                    key: const ValueKey('artist-releases-partial'),
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          strings.artistReleasesPartial,
                          textAlign: TextAlign.center,
                        ),
                        TextButton.icon(
                          key: const ValueKey('artist-releases-retry'),
                          onPressed: () => ref.invalidate(
                            artistReleaseCatalogProvider(browseTarget),
                          ),
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(strings.retry),
                        ),
                      ],
                    ),
                  ),
                ),
              if (isLoading && releases.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (hasError && releases.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(strings.artistReleasesLoadError),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          key: const ValueKey('artist-releases-retry'),
                          onPressed: () => ref.invalidate(
                            artistReleaseCatalogProvider(browseTarget!),
                          ),
                          icon: const Icon(Icons.refresh_rounded),
                          label: Text(strings.retry),
                        ),
                      ],
                    ),
                  ),
                )
              else if (releases.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text(strings.artistWithoutReleases)),
                )
              else
                SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final contentWidth = math.min(
                      1080.0,
                      constraints.crossAxisExtent,
                    );
                    final horizontalInset =
                        (constraints.crossAxisExtent - contentWidth) / 2 + 10;
                    final gridWidth = contentWidth - 20;
                    final columns = (gridWidth / 220)
                        .ceil()
                        .clamp(2, 5)
                        .toInt();
                    return SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalInset,
                        8,
                        horizontalInset,
                        bottomInset + 24,
                      ),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisExtent: 278,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 14,
                        ),
                        itemCount: releases.length,
                        itemBuilder: (context, index) => _ArtistReleaseGridTile(
                          release: releases[index],
                          onTap: () =>
                              _openRelease(context, ref, releases[index]),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: SizedBox(
          height: miniPlayerHeight,
          child: MiniPlayer(
            mode: miniPlayerMode,
            backgroundMode: appearance.background,
            onOpenPlayer: onOpenPlayer,
          ),
        ),
      ),
    );
  }

  void _openRelease(
    BuildContext context,
    WidgetRef ref,
    InnerTubeAlbum release,
  ) {
    final strings = ref.read(appStringsProvider);
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteCollectionDetailPage(
          title: release.title,
          subtitle: release.artist.trim().isEmpty ? artistName : release.artist,
          artworkSource: release.thumbnailUrl,
          metadata: <String>[
            ?release.type?.trim().isEmpty == false ? release.type : null,
            ?release.year?.trim().isEmpty == false ? release.year : null,
          ],
          fallbackIcon: Icons.album_rounded,
          preferCollectionArtworkForTracks: true,
          queueSourceId: 'artist:$artistBrowseId:${release.browseId}',
          tracksProvider: homeAlbumTracksProvider(release.browseId),
          emptyMessage: strings.albumWithoutSongs,
          errorMessage: strings.albumLoadError,
          onOpenPlayer: () {
            Navigator.of(context).pop();
            onOpenPlayer();
          },
        ),
      ),
    );
  }
}

List<InnerTubeAlbum> _mergePartialReleases(
  List<InnerTubeAlbum> fetched,
  List<InnerTubeAlbum> initial,
) {
  final byBrowseId = <String, InnerTubeAlbum>{
    for (final release in fetched) release.browseId: release,
  };
  for (final release in initial) {
    byBrowseId.putIfAbsent(release.browseId, () => release);
  }
  return byBrowseId.values.toList(growable: false);
}

class _ArtistReleaseGridTile extends StatelessWidget {
  const _ArtistReleaseGridTile({required this.release, required this.onTap});

  final InnerTubeAlbum release;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metadata = <String>[
      ?release.type?.trim().isEmpty == false ? release.type!.trim() : null,
      ?release.year?.trim().isEmpty == false ? release.year!.trim() : null,
    ].join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('artist-release-grid-${release.browseId}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SourceImage(
                    source: release.thumbnailUrl,
                    cacheWidth: 512,
                    fit: BoxFit.cover,
                    fallback: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.album_rounded, size: 46),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                release.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (metadata.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.contentSubtitleFor(context),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
