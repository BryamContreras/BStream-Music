import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/widgets/app_shared_widgets.dart';
import '../../../../services/local_media/device_audio_filter.dart';
import '../../../../services/local_media/local_media_providers.dart';
import '../../../../services/player/player_service.dart';
import '../../domain/entities/device_audio_track.dart';
import '../providers/music_providers.dart';
import 'glass_popup_menu_button.dart';
import 'scrolled_under_tab_frame.dart';
import 'source_image.dart';
import 'track_play_button.dart';

enum _LocalMusicRouteType { root, allSongs, folder }

class _LocalMusicRoute {
  const _LocalMusicRoute.root()
    : type = _LocalMusicRouteType.root,
      folderId = null;

  const _LocalMusicRoute.allSongs()
    : type = _LocalMusicRouteType.allSongs,
      folderId = null;

  const _LocalMusicRoute.folder(this.folderId)
    : type = _LocalMusicRouteType.folder;

  final _LocalMusicRouteType type;
  final String? folderId;
}

/// Lets the app shell consume Back inside Local before changing the root tab.
class LocalMusicNavigationController extends ChangeNotifier {
  _LocalMusicPanelState? _state;
  _LocalMusicRoute _route = const _LocalMusicRoute.root();

  bool get canPop =>
      _state?._canPop ?? _route.type != _LocalMusicRouteType.root;

  bool maybePop() {
    final state = _state;
    if (state != null) {
      return state._popRoute();
    }
    if (_route.type == _LocalMusicRouteType.root) {
      return false;
    }
    _route = const _LocalMusicRoute.root();
    notifyListeners();
    return true;
  }

  void _attach(_LocalMusicPanelState state) => _state = state;

  void _detach(_LocalMusicPanelState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }
}

/// Browses device audio without adding it to BStream's Library.
class LocalMusicPanel extends ConsumerStatefulWidget {
  const LocalMusicPanel({
    required this.onOpenPlayer,
    this.navigationController,
    this.bottomContentPadding = 0,
    super.key,
  });

  final VoidCallback onOpenPlayer;
  final LocalMusicNavigationController? navigationController;
  final double bottomContentPadding;

  @override
  ConsumerState<LocalMusicPanel> createState() => _LocalMusicPanelState();
}

class _LocalMusicPanelState extends ConsumerState<LocalMusicPanel>
    with WidgetsBindingObserver {
  late _LocalMusicRoute _route;
  bool _catalogActionBusy = false;
  final _filterController = TextEditingController();
  final _filterFocus = FocusNode();
  bool _filterVisible = false;

  bool get _canPop => _route.type != _LocalMusicRouteType.root;

  @override
  void initState() {
    super.initState();
    _filterController.addListener(_onFilterChanged);
    _route =
        widget.navigationController?._route ?? const _LocalMusicRoute.root();
    widget.navigationController?._attach(this);
    if (AppPlatform.isIOS) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  void didUpdateWidget(covariant LocalMusicPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.navigationController,
      widget.navigationController,
    )) {
      oldWidget.navigationController?._detach(this);
      _route = widget.navigationController?._route ?? _route;
      widget.navigationController?._attach(this);
    }
  }

  @override
  void dispose() {
    _filterController.removeListener(_onFilterChanged);
    _filterController.dispose();
    _filterFocus.dispose();
    if (AppPlatform.isIOS) {
      WidgetsBinding.instance.removeObserver(this);
    }
    widget.navigationController?._detach(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && AppPlatform.isIOS) {
      ref.invalidate(deviceAudioCatalogResultProvider);
    }
  }

  void _openRoute(_LocalMusicRoute route) {
    _filterFocus.unfocus();
    _filterController.clear();
    _filterVisible = false;
    widget.navigationController?._route = route;
    setState(() => _route = route);
  }

  bool _popRoute() {
    if (_filterVisible) {
      _closeFilter();
      return true;
    }
    if (!_canPop) return false;
    _openRoute(const _LocalMusicRoute.root());
    return true;
  }

  void _onFilterChanged() => setState(() {});

  void _showFilter() {
    setState(() => _filterVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _filterVisible) _filterFocus.requestFocus();
    });
  }

  void _closeFilter() {
    _filterFocus.unfocus();
    _filterController.clear();
    setState(() => _filterVisible = false);
  }

  void _clearOrCloseFilter() {
    if (_filterController.text.isNotEmpty) {
      _filterController.clear();
      _filterFocus.requestFocus();
    } else {
      _closeFilter();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final settings = ref.watch(settingsControllerProvider);
    final settingsState = settings.value;
    if (settingsState == null) {
      return _LocalCatalogMessageFrame(
        title: strings.localTab,
        bottomContentPadding: widget.bottomContentPadding,
        loading: settings.isLoading,
        icon: Icons.folder_off_rounded,
        message: strings.localMusicLoadError,
      );
    }

    final filters = settingsState.localMusicFilters;
    final query = DeviceAudioQuery(
      bstreamRoot: settingsState.downloadDirectory,
      options: DeviceAudioFilterOptions(
        excludeWhatsAppAudio: filters.contains(
          LocalMusicFilter.hideWhatsAppAudio,
        ),
        excludeTelegramAudio: filters.contains(
          LocalMusicFilter.hideTelegramAudio,
        ),
        excludeAudioRecordings: filters.contains(
          LocalMusicFilter.hideAudioRecordings,
        ),
        excludeShortAudio: filters.contains(
          LocalMusicFilter.hideTracksUnder30Seconds,
        ),
      ),
    );
    final catalog = ref.watch(deviceAudioCatalogResultProvider(query));

    return catalog.when(
      loading: () => _LocalCatalogMessageFrame(
        title: strings.localTab,
        bottomContentPadding: widget.bottomContentPadding,
        loading: true,
        icon: Icons.folder_rounded,
        message: strings.localTab,
      ),
      error: (_, _) => _LocalCatalogMessageFrame(
        title: strings.localTab,
        bottomContentPadding: widget.bottomContentPadding,
        icon: Icons.folder_off_rounded,
        message: strings.localMusicLoadError,
        actionLabel: strings.retry,
        onAction: () => ref.invalidate(deviceAudioCatalogResultProvider(query)),
      ),
      data: (result) {
        if (result.permissionRequired) {
          return _LocalPermissionView(
            bottomContentPadding: widget.bottomContentPadding,
            busy: _catalogActionBusy,
            openSettingsInstead: result.permissionRequiresSettings,
            onRequestPermission: () => _requestPermission(query),
          );
        }
        if (!result.isSupported) {
          return _LocalCatalogMessageFrame(
            title: strings.localTab,
            bottomContentPadding: widget.bottomContentPadding,
            icon: Icons.folder_off_rounded,
            message: strings.localMusicEmptyBody,
          );
        }

        final tracks = result.tracks;
        return switch (_route.type) {
          _LocalMusicRouteType.root => _LocalMusicRootView(
            bottomContentPadding: widget.bottomContentPadding,
            tracks: tracks,
            folders: result.folders,
            totalDuration: result.totalDuration,
            refreshBusy: _catalogActionBusy,
            onRefresh: () => _refresh(query),
            onOpenAll: tracks.isEmpty
                ? null
                : () => _openRoute(const _LocalMusicRoute.allSongs()),
            onOpenFolder: (folderId) =>
                _openRoute(_LocalMusicRoute.folder(folderId)),
            onOpenPlayer: widget.onOpenPlayer,
          ),
          _LocalMusicRouteType.allSongs => _LocalTrackDetailView(
            bottomContentPadding: widget.bottomContentPadding,
            title: strings.allLocalSongs,
            tracks: tracks,
            totalDuration: result.totalDuration,
            filterController: _filterController,
            filterFocus: _filterFocus,
            filterVisible: _filterVisible,
            onShowFilter: _showFilter,
            onClearOrCloseFilter: _clearOrCloseFilter,
            queueSourceId: 'device-local:all',
            onBack: _popRoute,
            onOpenPlayer: widget.onOpenPlayer,
          ),
          _LocalMusicRouteType.folder => _buildFolderDetail(
            result.folders,
            widget.bottomContentPadding,
          ),
        };
      },
    );
  }

  Widget _buildFolderDetail(
    List<DeviceAudioFolder> folders,
    double bottomContentPadding,
  ) {
    final strings = ref.read(appStringsProvider);
    final folderId = _route.folderId;
    DeviceAudioFolder? folder;
    for (final item in folders) {
      if (item.id == folderId) {
        folder = item;
        break;
      }
    }
    return _LocalTrackDetailView(
      bottomContentPadding: bottomContentPadding,
      title: folder?.name ?? strings.localMusicFolders,
      tracks: folder?.tracks ?? const <DeviceAudioTrack>[],
      totalDuration: folder?.totalDuration,
      filterController: _filterController,
      filterFocus: _filterFocus,
      filterVisible: _filterVisible,
      onShowFilter: _showFilter,
      onClearOrCloseFilter: _clearOrCloseFilter,
      queueSourceId: 'device-local:folder:${folderId ?? 'unknown'}',
      onBack: _popRoute,
      onOpenPlayer: widget.onOpenPlayer,
    );
  }

  Future<void> _requestPermission(DeviceAudioQuery query) async {
    if (_catalogActionBusy) return;
    setState(() => _catalogActionBusy = true);
    try {
      await ref
          .read(deviceAudioCatalogProvider)
          .requestPermissionAndLoad(
            options: query.options,
            bstreamRoot: query.bstreamRoot,
          );
      ref.invalidate(deviceAudioCatalogResultProvider(query));
    } catch (_) {
      if (mounted) _showCatalogError();
    } finally {
      if (mounted) setState(() => _catalogActionBusy = false);
    }
  }

  Future<void> _refresh(DeviceAudioQuery query) async {
    if (_catalogActionBusy) return;
    setState(() => _catalogActionBusy = true);
    try {
      await ref
          .read(deviceAudioCatalogProvider)
          .refresh(options: query.options, bstreamRoot: query.bstreamRoot);
      ref.invalidate(deviceAudioCatalogResultProvider(query));
    } catch (_) {
      if (mounted) _showCatalogError();
    } finally {
      if (mounted) setState(() => _catalogActionBusy = false);
    }
  }

  void _showCatalogError() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(ref.read(appStringsProvider).localMusicLoadError),
        ),
      );
  }
}

class _LocalMusicRootView extends ConsumerWidget {
  const _LocalMusicRootView({
    required this.bottomContentPadding,
    required this.tracks,
    required this.folders,
    required this.totalDuration,
    required this.refreshBusy,
    required this.onRefresh,
    required this.onOpenAll,
    required this.onOpenFolder,
    required this.onOpenPlayer,
  });

  final double bottomContentPadding;
  final List<DeviceAudioTrack> tracks;
  final List<DeviceAudioFolder> folders;
  final Duration? totalDuration;
  final bool refreshBusy;
  final VoidCallback onRefresh;
  final VoidCallback? onOpenAll;
  final ValueChanged<String> onOpenFolder;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return ScrolledUnderTabFrame(
      surfaceKey: const ValueKey('local-tab-header-surface'),
      header: Row(
        children: [
          Expanded(
            child: Text(
              key: const ValueKey('local-tab-title'),
              strings.localTab,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: appTabTitleStyle(context),
            ),
          ),
          IconButton(
            key: const ValueKey('local-refresh'),
            tooltip: strings.refresh,
            onPressed: refreshBusy ? null : onRefresh,
            icon: refreshBusy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      scrollKey: const ValueKey('local-root-scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              6,
              appTabFirstSectionTopGap,
              6,
              0,
            ),
            child: AppListCard(
              key: const ValueKey('local-all-songs-entry'),
              icon: Icons.library_music_rounded,
              title: strings.allLocalSongs,
              subtitle: strings.songCountWithDuration(
                tracks.length,
                totalDuration,
              ),
              onTap: onOpenAll,
              trailing: TrackPlayButton(
                key: const ValueKey('local-all-songs-play'),
                tooltip: strings.playAll,
                isPlaying: false,
                onPressed: tracks.isEmpty
                    ? null
                    : () => _playCollection(
                        context,
                        ref,
                        tracks,
                        'device-local:all',
                      ),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 28)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: appTabTitleHorizontalPadding,
            ),
            child: AppSectionTitle(strings.localMusicFolders),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        if (folders.isEmpty)
          SliverToBoxAdapter(
            child: _LocalEmptyState(
              title: strings.localMusicEmptyTitle,
              message: strings.localMusicEmptyBody,
            ),
          )
        else
          SliverList.separated(
            itemCount: folders.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final folder = folders[index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: AppListCard(
                  key: ValueKey('local-folder-${folder.id}'),
                  icon: Icons.folder_rounded,
                  title: folder.name,
                  subtitle: strings.songCountWithDuration(
                    folder.tracks.length,
                    folder.totalDuration,
                  ),
                  onTap: () => onOpenFolder(folder.id),
                  trailing: TrackPlayButton(
                    key: ValueKey('local-folder-play-${folder.id}'),
                    tooltip: strings.playAll,
                    isPlaying: false,
                    onPressed: folder.tracks.isEmpty
                        ? null
                        : () => _playCollection(
                            context,
                            ref,
                            folder.tracks,
                            'device-local:folder:${folder.id}',
                          ),
                  ),
                ),
              );
            },
          ),
        SliverToBoxAdapter(child: SizedBox(height: bottomContentPadding + 24)),
      ],
    );
  }

  Future<void> _playCollection(
    BuildContext context,
    WidgetRef ref,
    List<DeviceAudioTrack> tracks,
    String sourceId,
  ) async {
    final strings = ref.read(appStringsProvider);
    final addedAt = DateTime.now();
    final queue = tracks
        .map(
          (track) => track.toTransientLocalTrack(
            unknownArtist: strings.unknownArtist,
            addedAt: addedAt,
          ),
        )
        .toList(growable: false);
    final playback = ref
        .read(playerControllerProvider.notifier)
        .playLocal(
          queue.first,
          queue: queue,
          useNativeQueue: false,
          queueSourceId: sourceId,
        );
    onOpenPlayer();
    try {
      await playback;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(strings.error)));
      }
    }
  }
}

class _LocalTrackDetailView extends ConsumerWidget {
  const _LocalTrackDetailView({
    required this.bottomContentPadding,
    required this.title,
    required this.tracks,
    required this.totalDuration,
    required this.filterController,
    required this.filterFocus,
    required this.filterVisible,
    required this.onShowFilter,
    required this.onClearOrCloseFilter,
    required this.queueSourceId,
    required this.onBack,
    required this.onOpenPlayer,
  });

  final double bottomContentPadding;
  final String title;
  final List<DeviceAudioTrack> tracks;
  final Duration? totalDuration;
  final TextEditingController filterController;
  final FocusNode filterFocus;
  final bool filterVisible;
  final VoidCallback onShowFilter;
  final VoidCallback onClearOrCloseFilter;
  final String queueSourceId;
  final VoidCallback onBack;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final query = filterController.text.trim().toLowerCase();
    final visibleTracks = query.isEmpty
        ? tracks
        : tracks
              .where(
                (track) =>
                    track.title.toLowerCase().contains(query) ||
                    (track.artist?.toLowerCase().contains(query) ?? false) ||
                    (track.album?.toLowerCase().contains(query) ?? false),
              )
              .toList();
    return ScrolledUnderTabFrame(
      surfaceKey: const ValueKey('local-detail-header-surface'),
      header: Row(
        children: [
          IconButton(
            key: const ValueKey('local-detail-back'),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              key: const ValueKey('local-detail-title'),
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: appTabTitleStyle(context),
            ),
          ),
          GlassPopupMenuButton<bool>(
            key: const ValueKey('local-detail-menu'),
            tooltip: strings.moreOptions,
            icon: Icon(
              Icons.more_vert_rounded,
              color: AppColors.menuIconFor(context),
            ),
            onSelected: (_) => onShowFilter(),
            itemBuilder: (context) => [
              PopupMenuItem(
                key: const ValueKey('local-detail-search'),
                value: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.search_rounded),
                    const SizedBox(width: 12),
                    Text(strings.searchPlaylistSongs),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      pinnedFooterHasOwnSurface: true,
      pinnedFooter: _LocalSearchFooter(
        controller: filterController,
        focusNode: filterFocus,
        visible: filterVisible,
        hint: strings.filterSongs,
        closeTooltip: strings.close,
        onClearOrClose: onClearOrCloseFilter,
      ),
      scrollKey: ValueKey('local-detail-scroll-$queueSourceId'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              appTabTitleHorizontalPadding,
              appTabFirstSectionTopGap,
              appTabTitleHorizontalPadding,
              10,
            ),
            child: Text(
              strings.songCountWithDuration(tracks.length, totalDuration),
              style: appListCardSubtitleStyle(context),
            ),
          ),
        ),
        if (visibleTracks.isEmpty)
          SliverToBoxAdapter(
            child: _LocalEmptyState(
              title: query.isEmpty
                  ? strings.localMusicEmptyTitle
                  : strings.noSongsToShow,
              message: query.isEmpty ? strings.localMusicEmptyBody : '',
            ),
          )
        else
          SliverList.separated(
            itemCount: visibleTracks.length,
            separatorBuilder: (_, _) => const SizedBox(height: appTrackRowGap),
            itemBuilder: (context, index) {
              final track = visibleTracks[index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _DeviceAudioTrackCard(
                  track: track,
                  playTooltip: strings.play,
                  pauseTooltip: strings.pause,
                  onTap: () => _openOrPlay(context, ref, track),
                  onPlayPause: () => _toggleOrPlay(context, ref, track),
                ),
              );
            },
          ),
        SliverToBoxAdapter(child: SizedBox(height: bottomContentPadding + 24)),
      ],
    );
  }

  Future<void> _openOrPlay(
    BuildContext context,
    WidgetRef ref,
    DeviceAudioTrack track,
  ) async {
    final snapshot = ref.read(playerControllerProvider).value;
    if (snapshot?.trackId == track.id &&
        (snapshot?.status == PlayerStatus.loading ||
            snapshot?.status == PlayerStatus.playing ||
            snapshot?.status == PlayerStatus.paused)) {
      onOpenPlayer();
      return;
    }
    await _playTrack(context, ref, track);
  }

  Future<void> _toggleOrPlay(
    BuildContext context,
    WidgetRef ref,
    DeviceAudioTrack track,
  ) async {
    final player = ref.read(playerControllerProvider.notifier);
    final snapshot = ref.read(playerControllerProvider).value;
    if (snapshot?.trackId == track.id) {
      if (snapshot?.status == PlayerStatus.playing) {
        await player.pause();
      } else {
        await player.resume();
      }
      return;
    }
    await _playTrack(context, ref, track);
  }

  Future<void> _playTrack(
    BuildContext context,
    WidgetRef ref,
    DeviceAudioTrack selected,
  ) async {
    final strings = ref.read(appStringsProvider);
    final addedAt = DateTime.now();
    final queue = tracks
        .map(
          (track) => track.toTransientLocalTrack(
            unknownArtist: strings.unknownArtist,
            addedAt: addedAt,
          ),
        )
        .toList(growable: false);
    final selectedTrack = queue.firstWhere((track) => track.id == selected.id);
    final playback = ref
        .read(playerControllerProvider.notifier)
        .playLocal(
          selectedTrack,
          queue: queue,
          // Avoid handing thousands of content URIs to the native backend.
          useNativeQueue: false,
          queueSourceId: queueSourceId,
        );
    onOpenPlayer();
    try {
      await playback;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(strings.error)));
      }
    }
  }
}

class _LocalSearchFooter extends StatelessWidget {
  const _LocalSearchFooter({
    required this.controller,
    required this.focusNode,
    required this.visible,
    required this.hint,
    required this.closeTooltip,
    required this.onClearOrClose,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool visible;
  final String hint;
  final String closeTooltip;
  final VoidCallback onClearOrClose;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: duration,
          child: ClipRect(
            child: AnimatedSize(
              duration: duration,
              alignment: Alignment.topCenter,
              child: visible
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                      child: AppSurfaceInput(
                        key: const ValueKey('local-filter-surface'),
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          textAlignVertical: TextAlignVertical.center,
                          decoration: InputDecoration(
                            hintText: hint,
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: IconButton(
                              key: const ValueKey(
                                'local-filter-clear-or-close',
                              ),
                              tooltip: closeTooltip,
                              onPressed: onClearOrClose,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}

final _localCardPlaybackProvider = Provider.autoDispose((ref) {
  return ref.watch(
    playerControllerProvider.select((player) {
      final snapshot = player.value;
      return (
        trackId: snapshot?.trackId,
        playing: snapshot?.status == PlayerStatus.playing,
      );
    }),
  );
});

class _DeviceAudioTrackCard extends ConsumerWidget {
  const _DeviceAudioTrackCard({
    required this.track,
    required this.playTooltip,
    required this.pauseTooltip,
    required this.onTap,
    required this.onPlayPause,
  });

  final DeviceAudioTrack track;
  final String playTooltip;
  final String pauseTooltip;
  final VoidCallback onTap;
  final VoidCallback onPlayPause;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(
      _localCardPlaybackProvider.select((value) {
        final current = value.trackId == track.id;
        return (current: current, playing: current && value.playing);
      }),
    );
    final isCurrent = playback.current;
    final isPlaying = playback.playing;
    final colors = Theme.of(context).colorScheme;
    final artist = track.artist?.trim();
    final album = track.album?.trim();
    final metadata = <String>[
      if (artist != null && artist.isNotEmpty) artist,
      if (album != null && album.isNotEmpty) album,
      formatDuration(track.duration),
    ].join(' · ');
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(appCardRadius),
      side: BorderSide(
        color: isCurrent
            ? colors.primary
            : AppColors.cardBorderFor(context, solidInLiquidGlass: true),
      ),
    );
    return AppCardGradientBorder(
      solidInLiquidGlass: true,
      emphasized: isCurrent,
      child: Material(
        key: ValueKey('local-track-${track.id}'),
        color: AppColors.cardSurfaceFor(context),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          minTileHeight: 72,
          minVerticalPadding: 7,
          contentPadding: const EdgeInsets.only(left: 12, right: 4),
          horizontalTitleGap: 10,
          onTap: onTap,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(appListCardIconRadius),
            child: SizedBox.square(
              dimension: 52,
              child: SourceImage(
                source: track.artworkSource,
                cacheWidth: 192,
                fallback: Container(
                  color: colors.primary.withValues(alpha: 0.14),
                  child: Icon(
                    isCurrent
                        ? Icons.graphic_eq_rounded
                        : Icons.music_note_rounded,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: appListCardTitleStyle(context).copyWith(
              fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w700,
            ),
          ),
          subtitle: Text(
            metadata,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: appListCardSubtitleStyle(context),
          ),
          trailing: TrackPlayButton(
            key: ValueKey('local-track-play-${track.id}'),
            tooltip: isPlaying ? pauseTooltip : playTooltip,
            onPressed: onPlayPause,
            isPlaying: isPlaying,
          ),
        ),
      ),
    );
  }
}

class _LocalPermissionView extends ConsumerWidget {
  const _LocalPermissionView({
    required this.bottomContentPadding,
    required this.busy,
    required this.openSettingsInstead,
    required this.onRequestPermission,
  });

  final double bottomContentPadding;
  final bool busy;
  final bool openSettingsInstead;
  final VoidCallback onRequestPermission;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return ScrolledUnderTabFrame(
      surfaceKey: const ValueKey('local-tab-header-surface'),
      header: Text(
        key: const ValueKey('local-tab-title'),
        strings.localTab,
        style: appTabTitleStyle(context),
      ),
      scrollKey: const ValueKey('local-permission-scroll'),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, bottomContentPadding + 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.audio_file_rounded,
                      size: 58,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      strings.localMusicPermissionTitle,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      strings.localMusicPermissionBody,
                      textAlign: TextAlign.center,
                      style: appListCardSubtitleStyle(context),
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const ValueKey('local-request-permission'),
                      onPressed: busy ? null : onRequestPermission,
                      icon: busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.folder_open_rounded),
                      label: Text(
                        openSettingsInstead
                            ? strings.openSettings
                            : strings.allowMusicAccess,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LocalCatalogMessageFrame extends StatelessWidget {
  const _LocalCatalogMessageFrame({
    required this.title,
    required this.bottomContentPadding,
    required this.icon,
    required this.message,
    this.loading = false,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final double bottomContentPadding;
  final IconData icon;
  final String message;
  final bool loading;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return ScrolledUnderTabFrame(
      surfaceKey: const ValueKey('local-tab-header-surface'),
      header: Text(
        key: const ValueKey('local-tab-title'),
        title,
        style: appTabTitleStyle(context),
      ),
      scrollKey: const ValueKey('local-message-scroll'),
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomContentPadding),
            child: Center(
              child: loading
                  ? const CircularProgressIndicator()
                  : _LocalEmptyState(
                      title: message,
                      message: '',
                      icon: icon,
                      actionLabel: actionLabel,
                      onAction: onAction,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LocalEmptyState extends StatelessWidget {
  const _LocalEmptyState({
    required this.title,
    required this.message,
    this.icon = Icons.audio_file_rounded,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              if (message.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: appListCardSubtitleStyle(context),
                ),
              ],
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 16),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
