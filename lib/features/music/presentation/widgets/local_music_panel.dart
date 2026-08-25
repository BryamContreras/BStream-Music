import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/widgets/app_shared_widgets.dart';
import '../../../../services/local_media/device_audio_filter.dart';
import '../../../../services/local_media/local_media_providers.dart';
import '../../../../services/player/player_service.dart';
import '../../domain/entities/device_audio_track.dart';
import '../providers/music_providers.dart';
import 'scrolled_under_tab_frame.dart';
import 'source_image.dart';

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

class _LocalMusicPanelState extends ConsumerState<LocalMusicPanel> {
  late _LocalMusicRoute _route;
  bool _catalogActionBusy = false;

  bool get _canPop => _route.type != _LocalMusicRouteType.root;

  @override
  void initState() {
    super.initState();
    _route =
        widget.navigationController?._route ?? const _LocalMusicRoute.root();
    widget.navigationController?._attach(this);
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
    widget.navigationController?._detach(this);
    super.dispose();
  }

  void _openRoute(_LocalMusicRoute route) {
    widget.navigationController?._route = route;
    setState(() => _route = route);
  }

  bool _popRoute() {
    if (!_canPop) return false;
    _openRoute(const _LocalMusicRoute.root());
    return true;
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
        final folders = result.folders;
        return switch (_route.type) {
          _LocalMusicRouteType.root => _LocalMusicRootView(
            bottomContentPadding: widget.bottomContentPadding,
            tracks: tracks,
            folders: folders,
            refreshBusy: _catalogActionBusy,
            onRefresh: () => _refresh(query),
            onOpenAll: tracks.isEmpty
                ? null
                : () => _openRoute(const _LocalMusicRoute.allSongs()),
            onOpenFolder: (folderId) =>
                _openRoute(_LocalMusicRoute.folder(folderId)),
          ),
          _LocalMusicRouteType.allSongs => _LocalTrackDetailView(
            bottomContentPadding: widget.bottomContentPadding,
            title: strings.allLocalSongs,
            tracks: tracks,
            queueSourceId: 'device-local:all',
            onBack: _popRoute,
            onOpenPlayer: widget.onOpenPlayer,
          ),
          _LocalMusicRouteType.folder => _buildFolderDetail(
            folders,
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
    required this.refreshBusy,
    required this.onRefresh,
    required this.onOpenAll,
    required this.onOpenFolder,
  });

  final double bottomContentPadding;
  final List<DeviceAudioTrack> tracks;
  final List<DeviceAudioFolder> folders;
  final bool refreshBusy;
  final VoidCallback onRefresh;
  final VoidCallback? onOpenAll;
  final ValueChanged<String> onOpenFolder;

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
                sumKnownDurations(tracks.map((track) => track.duration)),
              ),
              onTap: onOpenAll,
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
                    sumKnownDurations(
                      folder.tracks.map((track) => track.duration),
                    ),
                  ),
                  onTap: () => onOpenFolder(folder.id),
                ),
              );
            },
          ),
        SliverToBoxAdapter(child: SizedBox(height: bottomContentPadding + 24)),
      ],
    );
  }
}

class _LocalTrackDetailView extends ConsumerWidget {
  const _LocalTrackDetailView({
    required this.bottomContentPadding,
    required this.title,
    required this.tracks,
    required this.queueSourceId,
    required this.onBack,
    required this.onOpenPlayer,
  });

  final double bottomContentPadding;
  final String title;
  final List<DeviceAudioTrack> tracks;
  final String queueSourceId;
  final VoidCallback onBack;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final playback = ref.watch(
      playerControllerProvider.select(
        (value) => (
          trackId: value.value?.trackId,
          status: value.value?.status ?? PlayerStatus.idle,
        ),
      ),
    );
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
          IconButton.filled(
            key: const ValueKey('local-play-all'),
            tooltip: strings.playAll,
            onPressed: tracks.isEmpty
                ? null
                : () => _playTrack(context, ref, tracks.first),
            icon: const Icon(Icons.play_arrow_rounded),
          ),
        ],
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
              strings.songCountWithDuration(
                tracks.length,
                sumKnownDurations(tracks.map((track) => track.duration)),
              ),
              style: appListCardSubtitleStyle(context),
            ),
          ),
        ),
        if (tracks.isEmpty)
          SliverToBoxAdapter(
            child: _LocalEmptyState(
              title: strings.localMusicEmptyTitle,
              message: strings.localMusicEmptyBody,
            ),
          )
        else
          SliverList.separated(
            itemCount: tracks.length,
            separatorBuilder: (_, _) => const SizedBox(height: 7),
            itemBuilder: (context, index) {
              final track = tracks[index];
              final isCurrent = playback.trackId == track.id;
              final isPlaying =
                  isCurrent && playback.status == PlayerStatus.playing;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _DeviceAudioTrackCard(
                  track: track,
                  isCurrent: isCurrent,
                  isPlaying: isPlaying,
                  playTooltip: strings.play,
                  pauseTooltip: strings.pause,
                  onTap: () => _openOrPlay(context, ref, track),
                  onPlayPause: () =>
                      _toggleOrPlay(context, ref, track, isCurrent, isPlaying),
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
    bool isCurrent,
    bool isPlaying,
  ) async {
    final player = ref.read(playerControllerProvider.notifier);
    if (isCurrent) {
      if (isPlaying) {
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

class _DeviceAudioTrackCard extends StatelessWidget {
  const _DeviceAudioTrackCard({
    required this.track,
    required this.isCurrent,
    required this.isPlaying,
    required this.playTooltip,
    required this.pauseTooltip,
    required this.onTap,
    required this.onPlayPause,
  });

  final DeviceAudioTrack track;
  final bool isCurrent;
  final bool isPlaying;
  final String playTooltip;
  final String pauseTooltip;
  final VoidCallback onTap;
  final VoidCallback onPlayPause;

  @override
  Widget build(BuildContext context) {
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
        color: isCurrent ? colors.primary : AppColors.cardBorderFor(context),
      ),
    );
    return Material(
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
          style: appListCardTitleStyle(
            context,
          ).copyWith(fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w700),
        ),
        subtitle: Text(
          metadata,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: appListCardSubtitleStyle(context),
        ),
        trailing: IconButton(
          key: ValueKey('local-track-play-${track.id}'),
          tooltip: isPlaying ? pauseTooltip : playTooltip,
          onPressed: onPlayPause,
          icon: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: colors.primary,
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
    required this.onRequestPermission,
  });

  final double bottomContentPadding;
  final bool busy;
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
                      label: Text(strings.allowMusicAccess),
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
