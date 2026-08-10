import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/utils/image_source.dart';
import '../../../../services/player/player_service.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';
import '../providers/music_providers.dart';
import 'favorite_star_badge.dart';
import 'now_playing_equalizer.dart';
import 'source_image.dart';
import 'track_play_button.dart';

enum _LibraryRouteType { root, downloads, live, playlist }

enum _TrackMenuAction {
  renameTrack,
  addToPlaylist,
  toggleFavorite,
  deleteTrack,
  removeFromPlaylist,
}

enum _PlaylistMenuAction { renamePlaylist, deletePlaylist }

class _LibraryRoute {
  const _LibraryRoute.root() : type = _LibraryRouteType.root, playlistId = null;

  const _LibraryRoute.downloads()
    : type = _LibraryRouteType.downloads,
      playlistId = null;

  const _LibraryRoute.live() : type = _LibraryRouteType.live, playlistId = null;

  const _LibraryRoute.playlist(this.playlistId)
    : type = _LibraryRouteType.playlist;

  final _LibraryRouteType type;
  final String? playlistId;

  String get key => switch (type) {
    _LibraryRouteType.root => 'root',
    _LibraryRouteType.downloads => 'downloads',
    _LibraryRouteType.live => 'live',
    _LibraryRouteType.playlist => 'playlist-$playlistId',
  };
}

class LibraryPanel extends ConsumerStatefulWidget {
  const LibraryPanel({
    required this.onOpenPlayer,
    this.navigationController,
    super.key,
  });

  final VoidCallback onOpenPlayer;
  final LibraryNavigationController? navigationController;

  @override
  ConsumerState<LibraryPanel> createState() => _LibraryPanelState();
}

class LibraryNavigationController extends ChangeNotifier {
  _LibraryPanelState? _state;
  _LibraryRoute _route = const _LibraryRoute.root();

  bool get canPop => _state?._canPop ?? _route.type != _LibraryRouteType.root;

  bool maybePop() {
    final state = _state;
    if (state != null) {
      return state._popRoute();
    }
    if (_route.type == _LibraryRouteType.root) {
      return false;
    }
    _route = const _LibraryRoute.root();
    notifyListeners();
    return true;
  }

  void openPlaylist(String playlistId) {
    _route = _LibraryRoute.playlist(playlistId);
    final state = _state;
    if (state != null) {
      state._openPlaylist(playlistId);
    } else {
      notifyListeners();
    }
  }

  void _attach(_LibraryPanelState state) {
    _state = state;
    notifyListeners();
  }

  void _detach(_LibraryPanelState state) {
    if (_state == state) {
      _state = null;
      notifyListeners();
    }
  }

  void _notifyRouteChanged(_LibraryRoute route) {
    _route = route;
    notifyListeners();
  }
}

class _LibraryPanelState extends ConsumerState<LibraryPanel> {
  final _filterController = TextEditingController();
  late _LibraryRoute _route;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _route = widget.navigationController?._route ?? const _LibraryRoute.root();
    widget.navigationController?._attach(this);
    _filterController.addListener(() {
      setState(() => _filter = _filterController.text);
    });
  }

  @override
  void didUpdateWidget(covariant LibraryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationController != widget.navigationController) {
      oldWidget.navigationController?._detach(this);
      _route = widget.navigationController?._route ?? _route;
      widget.navigationController?._attach(this);
    }
  }

  @override
  void dispose() {
    widget.navigationController?._detach(this);
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tracks = ref.watch(libraryTracksProvider);
    final playlists = ref.watch(playlistsControllerProvider);
    final liveQueue = AppPlatform.isWindows
        ? ref.watch(tiktokLiveControllerProvider)
        : null;
    final strings = ref.watch(appStringsProvider);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final offset = Tween<Offset>(
          begin: const Offset(0.025, 0),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
      child: KeyedSubtree(
        key: ValueKey(_route.key),
        child: switch (_route.type) {
          _LibraryRouteType.root => _LibraryRootView(
            tracks: tracks,
            playlists: playlists,
            strings: strings,
            onOpenDownloads: _openDownloads,
            liveQueue: liveQueue,
            onOpenLive: _openLive,
            onOpenPlaylist: _openPlaylist,
            onCreatePlaylist: () => _showCreateDialog(context),
          ),
          _LibraryRouteType.downloads => tracks.when(
            data: (items) => _TrackListView(
              title: strings.downloadedSongs,
              subtitle: strings.songCountWithDuration(
                items.length,
                sumKnownDurations(items.map((track) => track.duration)),
              ),
              tracks: _filteredTracks(items),
              queueTracks: items,
              filterController: _filterController,
              onBack: _goRoot,
              onOpenPlayer: widget.onOpenPlayer,
              mode: _TrackListMode.downloads,
            ),
            loading: () => const _PanelLoading(key: ValueKey('downloads-load')),
            error: (error, _) => _PanelError(
              error: error,
              onBack: _goRoot,
              title: strings.library,
            ),
          ),
          _LibraryRouteType.live =>
            liveQueue == null
                ? _PanelError(
                    title: strings.library,
                    error: strings.playlistMissing,
                    onBack: _goRoot,
                  )
                : liveQueue.when(
                    data: (state) => _LiveQueueView(
                      state: state,
                      strings: strings,
                      onBack: _goRoot,
                      onOpenPlayer: widget.onOpenPlayer,
                    ),
                    loading: () =>
                        const _PanelLoading(key: ValueKey('live-load')),
                    error: (error, _) => _PanelError(
                      error: error,
                      onBack: _goRoot,
                      title: strings.liveQueueTitle,
                    ),
                  ),
          _LibraryRouteType.playlist => playlists.when(
            data: (items) {
              final playlist = items
                  .where((item) => item.id == _route.playlistId)
                  .firstOrNull;
              if (playlist == null) {
                return _PanelError(
                  title: strings.playlist,
                  error: strings.playlistMissing,
                  onBack: _goRoot,
                );
              }
              return tracks.when(
                data: (libraryTracks) {
                  final byId = {
                    for (final track in libraryTracks) track.id: track,
                  };
                  final playlistTracks = playlist.trackIds
                      .map((id) => byId[id])
                      .whereType<LocalTrack>()
                      .toList(growable: false);
                  return _TrackListView(
                    title: playlist.isFavorites
                        ? strings.favorites
                        : playlist.name,
                    subtitle: strings.songCountWithDuration(
                      playlistTracks.length,
                      sumKnownDurations(
                        playlistTracks.map((track) => track.duration),
                      ),
                    ),
                    tracks: _filteredTracks(playlistTracks),
                    queueTracks: playlistTracks,
                    filterController: _filterController,
                    onBack: _goRoot,
                    onOpenPlayer: widget.onOpenPlayer,
                    mode: _TrackListMode.playlist,
                    playlist: playlist,
                    playlistId: playlist.id,
                  );
                },
                loading: () =>
                    const _PanelLoading(key: ValueKey('playlist-load')),
                error: (error, _) => _PanelError(
                  error: error,
                  onBack: _goRoot,
                  title: playlist.isFavorites
                      ? strings.favorites
                      : playlist.name,
                ),
              );
            },
            loading: () => const _PanelLoading(key: ValueKey('playlists-load')),
            error: (error, _) => _PanelError(
              error: error,
              onBack: _goRoot,
              title: strings.playlist,
            ),
          ),
        },
      ),
    );
  }

  void _openDownloads() {
    _filterController.clear();
    setState(() => _route = const _LibraryRoute.downloads());
    widget.navigationController?._notifyRouteChanged(_route);
  }

  void _openLive() {
    if (!AppPlatform.isWindows) {
      return;
    }
    _filterController.clear();
    setState(() => _route = const _LibraryRoute.live());
    widget.navigationController?._notifyRouteChanged(_route);
  }

  void _openPlaylist(String playlistId) {
    _filterController.clear();
    setState(() => _route = _LibraryRoute.playlist(playlistId));
    widget.navigationController?._notifyRouteChanged(_route);
  }

  void _goRoot() {
    _filterController.clear();
    setState(() => _route = const _LibraryRoute.root());
    widget.navigationController?._notifyRouteChanged(_route);
  }

  bool get _canPop => _route.type != _LibraryRouteType.root;

  bool _popRoute() {
    if (!_canPop) {
      return false;
    }
    _goRoot();
    return true;
  }

  List<LocalTrack> _filteredTracks(List<LocalTrack> tracks) {
    final query = _filter.trim().toLowerCase();
    if (query.isEmpty) {
      return tracks;
    }
    return tracks
        .where((track) {
          return track.title.toLowerCase().contains(query) ||
              track.artist.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  Future<void> _showCreateDialog(BuildContext context) async {
    final strings = ref.read(appStringsProvider);
    final rawName = await showDialog<String>(
      context: context,
      builder: (_) => _CreatePlaylistDialog(strings: strings),
    );
    final name = rawName?.trim();
    if (!mounted || name == null || name.isEmpty) {
      return;
    }
    await ref.read(playlistsControllerProvider.notifier).create(name);
  }
}

class _CreatePlaylistDialog extends StatefulWidget {
  const _CreatePlaylistDialog({required this.strings});

  final AppStrings strings;

  @override
  State<_CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<_CreatePlaylistDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.strings.newPlaylist),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.strings.name),
        onSubmitted: _closeWithName,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: Text(widget.strings.cancel),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.check_rounded),
          label: Text(widget.strings.create),
          onPressed: () => _closeWithName(_controller.text),
        ),
      ],
    );
  }

  void _closeWithName(String value) {
    Navigator.of(context).pop(value.trim());
  }
}

class _LibraryRootView extends StatelessWidget {
  const _LibraryRootView({
    required this.tracks,
    required this.playlists,
    required this.liveQueue,
    required this.strings,
    required this.onOpenDownloads,
    required this.onOpenLive,
    required this.onOpenPlaylist,
    required this.onCreatePlaylist,
  });

  final AsyncValue<List<LocalTrack>> tracks;
  final AsyncValue<List<Playlist>> playlists;
  final AsyncValue<TikTokLiveState>? liveQueue;
  final AppStrings strings;
  final VoidCallback onOpenDownloads;
  final VoidCallback onOpenLive;
  final ValueChanged<String> onOpenPlaylist;
  final VoidCallback onCreatePlaylist;

  @override
  Widget build(BuildContext context) {
    final localTracks = tracks.value ?? const <LocalTrack>[];

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              key: const ValueKey('library-tab-title'),
              strings.library,
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _SectionTitle(strings.library),
          ),
          const SizedBox(height: 10),
          tracks.when(
            data: (items) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: _LibraryEntry(
                icon: Icons.library_music_rounded,
                title: strings.downloadedSongs,
                subtitle: strings.songCountWithDuration(
                  items.length,
                  sumKnownDurations(items.map((track) => track.duration)),
                ),
                onTap: onOpenDownloads,
              ),
            ),
            loading: () => const _LoadingRow(),
            error: (error, _) => _ErrorRow(error: error),
          ),
          if (liveQueue != null) ...[
            const SizedBox(height: 8),
            liveQueue!.when(
              data: (state) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _LibraryEntry(
                  icon: Icons.sensors_rounded,
                  title: strings.liveQueue,
                  subtitle: strings.liveQueueSummary(
                    state.liveQueue.length,
                    state.readyPlayCommands,
                    state.pendingPlayCommands,
                  ),
                  onTap: onOpenLive,
                ),
              ),
              loading: () => const _LoadingRow(),
              error: (error, _) => _ErrorRow(error: error),
            ),
          ],
          const SizedBox(height: 28),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: _SectionTitle(strings.playlist)),
                _NeutralLibraryIconButton(
                  tooltip: strings.newPlaylist,
                  icon: Icons.add_rounded,
                  onPressed: onCreatePlaylist,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _CreatePlaylistRow(
              label: strings.createPlaylist,
              onPressed: onCreatePlaylist,
            ),
          ),
          const SizedBox(height: 10),
          playlists.when(
            data: (items) => _PlaylistList(
              playlists: items,
              libraryTracks: localTracks,
              strings: strings,
              onOpenPlaylist: onOpenPlaylist,
            ),
            loading: () => const _LoadingRow(),
            error: (error, _) => _ErrorRow(error: error),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _LiveQueueView extends ConsumerWidget {
  const _LiveQueueView({
    required this.state,
    required this.strings,
    required this.onBack,
    required this.onOpenPlayer,
  });

  final TikTokLiveState state;
  final AppStrings strings;
  final VoidCallback onBack;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = state.liveQueue;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _DetailHeader(
              title: strings.liveQueueTitle,
              subtitle: strings.liveQueueSummary(
                items.length,
                state.readyPlayCommands,
                state.pendingPlayCommands,
              ),
              onBack: onBack,
              trailing: items.isEmpty
                  ? null
                  : IconButton.filledTonal(
                      tooltip: strings.clearLiveQueue,
                      icon: const Icon(Icons.playlist_remove_rounded),
                      onPressed: () async {
                        await ref
                            .read(tiktokLiveControllerProvider.notifier)
                            .clearLiveQueue();
                      },
                    ),
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      strings.liveQueueEmpty,
                      style: TextStyle(
                        color: AppColors.contentSubtitleFor(context),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: items.length,
                    itemExtent: 94,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                        child: _LiveQueueTile(
                          item: items[index],
                          onOpenPlayer: onOpenPlayer,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _LiveQueueTile extends ConsumerWidget {
  const _LiveQueueTile({required this.item, required this.onOpenPlayer});

  final LiveQueueItem item;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final activeTrackId = ref.watch(
      playerControllerProvider.select((player) => player.value?.trackId),
    );
    final isCurrent =
        item.localTrack != null && item.localTrack!.id == activeTrackId;
    final statusColor = _statusColor(context, isCurrent: isCurrent);
    final playButtonSize = AppPlatform.isAndroid ? 38.0 : 52.0;
    final playIconSize = AppPlatform.isAndroid ? 30.0 : 26.0;

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: isCurrent
          ? BorderSide(color: Theme.of(context).colorScheme.primary)
          : BorderSide(color: AppColors.cardBorderFor(context)),
    );
    return Material(
      color: AppColors.cardSurfaceFor(context),
      clipBehavior: Clip.antiAlias,
      shape: shape,
      child: ListTile(
        dense: false,
        minTileHeight: 86,
        contentPadding: const EdgeInsets.only(left: 12, right: 4),
        horizontalTitleGap: 10,
        shape: shape,
        tileColor: Colors.transparent,
        leading: _LocalArtwork(source: _thumbnailSource),
        title: Text(
          item.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: AppColors.contentTitleFor(context),
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    '${strings.requestedBy}: ${item.requestedBy}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.contentSubtitleFor(context),
                    ),
                  ),
                ),
                if (item.requestedByModerator) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.shield_rounded,
                    size: 15,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    strings.moderator,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ],
            ),
            Text(
              _statusText(strings, isCurrent: isCurrent),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: statusColor, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        trailing: item.isReady
            ? IconButton.filledTonal(
                tooltip: strings.play,
                icon: const Icon(Icons.play_arrow_rounded),
                iconSize: playIconSize,
                padding: EdgeInsets.zero,
                style: AppPlatform.isAndroid
                    ? IconButton.styleFrom(
                        fixedSize: Size.square(playButtonSize),
                        minimumSize: Size.square(playButtonSize),
                        maximumSize: Size.square(playButtonSize),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      )
                    : null,
                constraints: BoxConstraints.tight(Size.square(playButtonSize)),
                onPressed: () async {
                  onOpenPlayer();
                  await ref
                      .read(tiktokLiveControllerProvider.notifier)
                      .playLiveQueueItem(item.id);
                },
              )
            : _LiveQueueStatusIcon(item: item, color: statusColor),
        onTap: item.isReady
            ? () async {
                onOpenPlayer();
                await ref
                    .read(tiktokLiveControllerProvider.notifier)
                    .playLiveQueueItem(item.id);
              }
            : null,
      ),
    );
  }

  String? get _thumbnailSource {
    final localTrack = item.localTrack;
    if (localTrack != null) {
      return localTrack.thumbnailPath ?? localTrack.thumbnailUrl;
    }
    return item.remoteTrack?.thumbnailUrl;
  }

  Color _statusColor(BuildContext context, {required bool isCurrent}) {
    if (isCurrent) {
      return Theme.of(context).colorScheme.primary;
    }
    return switch (item.status) {
      LiveQueueItemStatus.ready => Theme.of(context).colorScheme.primary,
      LiveQueueItemStatus.failed => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
  }

  String _statusText(AppStrings strings, {required bool isCurrent}) {
    if (isCurrent) {
      return strings.nowPlaying;
    }
    return switch (item.status) {
      LiveQueueItemStatus.resolving => item.message ?? strings.search,
      LiveQueueItemStatus.downloading => item.message ?? strings.downloading,
      LiveQueueItemStatus.ready =>
        item.reusedExisting ? strings.reusedDownload : strings.completed,
      LiveQueueItemStatus.failed => item.message ?? strings.error,
    };
  }
}

class _LiveQueueStatusIcon extends StatelessWidget {
  const _LiveQueueStatusIcon({required this.item, required this.color});

  final LiveQueueItem item;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final icon = switch (item.status) {
      LiveQueueItemStatus.resolving => Icons.manage_search_rounded,
      LiveQueueItemStatus.downloading => Icons.downloading_rounded,
      LiveQueueItemStatus.ready => Icons.check_circle_rounded,
      LiveQueueItemStatus.failed => Icons.error_rounded,
    };
    final spinning = item.status == LiveQueueItemStatus.downloading;
    return SizedBox(
      width: 52,
      height: 52,
      child: Center(
        child: spinning
            ? SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            : Icon(icon, color: color, size: 28),
      ),
    );
  }
}

class _TrackListView extends ConsumerWidget {
  const _TrackListView({
    required this.title,
    required this.subtitle,
    required this.tracks,
    required this.queueTracks,
    required this.filterController,
    required this.onBack,
    required this.onOpenPlayer,
    required this.mode,
    this.playlist,
    this.playlistId,
  });

  final String title;
  final String subtitle;
  final List<LocalTrack> tracks;
  final List<LocalTrack> queueTracks;
  final TextEditingController filterController;
  final VoidCallback onBack;
  final VoidCallback onOpenPlayer;
  final _TrackListMode mode;
  final Playlist? playlist;
  final String? playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _DetailHeader(
              title: title,
              subtitle: subtitle,
              onBack: onBack,
              trailing: playlist == null || playlist!.isFavorites
                  ? null
                  : _PlaylistMenu(playlist: playlist!, onBack: onBack),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: TextField(
              controller: filterController,
              decoration: InputDecoration(
                hintText: strings.filterSongs,
                prefixIcon: const Icon(Icons.search_rounded),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: tracks.isEmpty
                ? Center(
                    child: Text(
                      strings.noSongsToShow,
                      style: TextStyle(
                        color: AppColors.contentSubtitleFor(context),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: tracks.length,
                    itemExtent: 76,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                        child: _LocalTrackTile(
                          track: tracks[index],
                          mode: mode,
                          playlistId: playlistId,
                          queueTracks: queueTracks,
                          onOpenPlayer: onOpenPlayer,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

enum _TrackListMode { downloads, playlist }

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.title,
    required this.subtitle,
    required this.onBack,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _NeutralLibraryIconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: Icons.arrow_back_rounded,
          iconSize: 28,
          buttonSize: 42,
          onPressed: onBack,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: AppColors.contentHeadingFor(context),
                ),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.contentSubtitleFor(context)),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

class _NeutralLibraryIconButton extends StatelessWidget {
  const _NeutralLibraryIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.iconSize,
    this.buttonSize,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final double? iconSize;
  final double? buttonSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: iconSize),
      style: IconButton.styleFrom(
        foregroundColor: colors.onSurface,
        backgroundColor: colors.surfaceContainerHighest.withValues(alpha: 0.84),
        hoverColor: colors.onSurface.withValues(alpha: 0.1),
        focusColor: colors.onSurface.withValues(alpha: 0.12),
        highlightColor: colors.onSurface.withValues(alpha: 0.14),
        shape: CircleBorder(
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.8)),
        ),
        fixedSize: buttonSize == null ? null : Size.square(buttonSize!),
        tapTargetSize: buttonSize == null
            ? null
            : MaterialTapTargetSize.shrinkWrap,
      ),
      constraints: buttonSize == null
          ? null
          : BoxConstraints.tightFor(width: buttonSize, height: buttonSize),
      padding: buttonSize == null ? null : EdgeInsets.zero,
      onPressed: onPressed,
    );
  }
}

class _PlaylistMenu extends ConsumerWidget {
  const _PlaylistMenu({required this.playlist, required this.onBack});

  final Playlist playlist;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final buttonSize = AppPlatform.isAndroid ? 42.0 : 52.0;
    final iconSize = AppPlatform.isAndroid ? 32.0 : 24.0;
    final menuIconColor = AppColors.menuIconFor(context);
    return SizedBox.square(
      dimension: buttonSize,
      child: PopupMenuButton<_PlaylistMenuAction>(
        tooltip: strings.moreOptions,
        padding: EdgeInsets.zero,
        iconSize: iconSize,
        child: Center(child: Icon(Icons.more_vert_rounded, size: iconSize)),
        onSelected: (action) => _handleAction(context, ref, action),
        itemBuilder: (context) => [
          PopupMenuItem(
            value: _PlaylistMenuAction.renamePlaylist,
            child: Row(
              children: [
                Icon(
                  Icons.drive_file_rename_outline_rounded,
                  color: menuIconColor,
                ),
                const SizedBox(width: 12),
                Text(strings.renamePlaylist),
              ],
            ),
          ),
          PopupMenuItem(
            value: _PlaylistMenuAction.deletePlaylist,
            child: Row(
              children: [
                Icon(Icons.delete_outline_rounded, color: menuIconColor),
                const SizedBox(width: 12),
                Text(strings.deletePlaylist),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    _PlaylistMenuAction action,
  ) async {
    switch (action) {
      case _PlaylistMenuAction.renamePlaylist:
        await _renamePlaylist(context, ref);
      case _PlaylistMenuAction.deletePlaylist:
        await _deletePlaylist(context, ref);
    }
  }

  Future<void> _renamePlaylist(BuildContext context, WidgetRef ref) async {
    final strings = ref.read(appStringsProvider);
    final rawName = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: strings.renamePlaylist,
        initialValue: playlist.name,
        hint: strings.name,
        cancelLabel: strings.cancel,
        confirmLabel: strings.rename,
      ),
    );
    final name = rawName?.trim();
    if (name == null || name.isEmpty || name == playlist.name) {
      return;
    }

    await ref
        .read(playlistsControllerProvider.notifier)
        .renamePlaylist(playlist.id, name);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.read(appStringsProvider).playlistRenamed)),
    );
  }

  Future<void> _deletePlaylist(BuildContext context, WidgetRef ref) async {
    final strings = ref.read(appStringsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(strings.deletePlaylist),
          content: Text(strings.confirmDeletePlaylist),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(strings.delete),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    await ref
        .read(playlistsControllerProvider.notifier)
        .deletePlaylist(playlist.id);
    if (!context.mounted) {
      return;
    }
    onBack();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.read(appStringsProvider).playlistDeleted)),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initialValue,
    required this.hint,
    required this.cancelLabel,
    required this.confirmLabel,
  });

  final String title;
  final String initialValue;
  final String hint;
  final String cancelLabel;
  final String confirmLabel;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: _closeWithName,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.check_rounded),
          label: Text(widget.confirmLabel),
          onPressed: () => _closeWithName(_controller.text),
        ),
      ],
    );
  }

  void _closeWithName(String value) {
    Navigator.of(context).pop(value.trim());
  }
}

class _PanelLoading extends StatelessWidget {
  const _PanelLoading({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator());
  }
}

class _PanelError extends StatelessWidget {
  const _PanelError({
    required this.error,
    required this.onBack,
    required this.title,
  });

  final Object error;
  final VoidCallback onBack;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailHeader(title: title, subtitle: 'Error', onBack: onBack),
          const SizedBox(height: 20),
          Text(
            error.toString(),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w900,
        color: AppColors.contentHeadingFor(context),
      ),
    );
  }
}

class _PlaylistList extends StatelessWidget {
  const _PlaylistList({
    required this.playlists,
    required this.libraryTracks,
    required this.strings,
    required this.onOpenPlaylist,
  });

  final List<Playlist> playlists;
  final List<LocalTrack> libraryTracks;
  final AppStrings strings;
  final ValueChanged<String> onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    if (playlists.isEmpty) {
      return Text(
        strings.noLocalPlaylists,
        style: TextStyle(color: AppColors.contentSubtitleFor(context)),
      );
    }

    final tracksById = {for (final track in libraryTracks) track.id: track};

    return Column(
      children: playlists
          .map(
            (playlist) => Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
              child: _PlaylistRow(
                playlist: playlist,
                thumbnailSources: _playlistThumbnailSources(
                  playlist,
                  tracksById,
                ),
                subtitle: strings.songCountWithDuration(
                  playlist.trackIds
                      .map((id) => tracksById[id])
                      .whereType<LocalTrack>()
                      .length,
                  sumKnownDurations(
                    playlist.trackIds
                        .map((id) => tracksById[id])
                        .whereType<LocalTrack>()
                        .map((track) => track.duration),
                  ),
                ),
                strings: strings,
                onTap: () => onOpenPlaylist(playlist.id),
              ),
            ),
          )
          .toList(growable: false),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.thumbnailSources,
    required this.subtitle,
    required this.strings,
    required this.onTap,
  });

  final Playlist playlist;
  final List<String> thumbnailSources;
  final String subtitle;
  final AppStrings strings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _LibraryEntry(
      icon: playlist.isFavorites
          ? Icons.star_rounded
          : Icons.queue_music_rounded,
      leading: thumbnailSources.isEmpty
          ? null
          : Stack(
              children: [
                _PlaylistCover(sources: thumbnailSources),
                if (playlist.isFavorites)
                  const Positioned(
                    top: 1,
                    right: 1,
                    child: FavoriteStarBadge(iconSize: 15),
                  ),
              ],
            ),
      title: playlist.isFavorites ? strings.favorites : playlist.name,
      subtitle: subtitle,
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

List<String> _playlistThumbnailSources(
  Playlist playlist,
  Map<String, LocalTrack> tracksById,
) {
  final sources = playlist.trackIds
      .map((id) => tracksById[id])
      .whereType<LocalTrack>()
      .map((track) => _trackThumbnailSource(track))
      .whereType<String>()
      .toSet()
      .toList(growable: false);

  if (sources.length <= 1) {
    return sources;
  }

  final start = playlist.id.hashCode.abs() % sources.length;
  return [
    ...sources.skip(start),
    ...sources.take(start),
  ].take(4).toList(growable: false);
}

String? _trackThumbnailSource(LocalTrack track) {
  final source = track.thumbnailPath ?? track.thumbnailUrl;
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }

  if (isNetworkImageSource(normalized)) {
    return normalized;
  }

  final file = imageFileFromSource(normalized);
  if (file == null || !file.existsSync()) {
    return null;
  }
  return file.path;
}

class _CreatePlaylistRow extends StatelessWidget {
  const _CreatePlaylistRow({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.add_rounded,
                  size: 34,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: AppColors.contentTitleFor(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryEntry extends StatelessWidget {
  const _LibraryEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.leading,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return _FolderShell(
      child: ListTile(
        minTileHeight: 76,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        leading: leading ?? _FolderIcon(icon: icon),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: AppColors.contentTitleFor(context),
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: AppColors.contentSubtitleFor(context)),
        ),
        trailing: trailing ?? const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}

class _PlaylistCover extends StatelessWidget {
  const _PlaylistCover({required this.sources});

  final List<String> sources;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return const _FolderIcon(icon: Icons.queue_music_rounded);
    }

    final underlay = sources.skip(1).take(3).toList(growable: false);

    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        width: 58,
        height: 58,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SourceImage(
              source: sources.first,
              fallback: const _PlaylistCoverFallback(),
            ),
            if (underlay.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 22,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Color(0xAA000000),
                    border: Border(
                      top: BorderSide(color: Color(0xAA050805), width: 1),
                    ),
                  ),
                  child: Row(
                    children: [
                      for (final source in underlay)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(1),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(1.5),
                              child: SourceImage(
                                source: source,
                                fallback: const _PlaylistCoverFallback(),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistCoverFallback extends StatelessWidget {
  const _PlaylistCoverFallback();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Icon(
        Icons.queue_music_rounded,
        size: 20,
        color: colors.onSurfaceVariant,
      ),
    );
  }
}

class _FolderShell extends StatefulWidget {
  const _FolderShell({required this.child});

  final Widget child;

  @override
  State<_FolderShell> createState() => _FolderShellState();
}

class _FolderShellState extends State<_FolderShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(
        color: _hovered ? colors.primary : AppColors.cardBorderFor(context),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: ShapeDecoration(
          color: AppColors.cardSurfaceFor(context),
          shape: shape,
        ),
        child: Material(
          color: Colors.transparent,
          elevation: 0,
          shadowColor: const Color(0x14000000),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: widget.child,
        ),
      ),
    );
  }
}

class _FolderIcon extends StatelessWidget {
  const _FolderIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).extension<AppAccentTheme>();
    final gradientColors = accent == null
        ? const [Color(0xFF18C75A), Color(0xFF0B8F43), Color(0xFF076B35)]
        : [accent.seed, accent.dark, accent.dark.withValues(alpha: 0.78)];
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: Theme.of(context).colorScheme.onPrimary),
    );
  }
}

class _LocalTrackTile extends ConsumerStatefulWidget {
  const _LocalTrackTile({
    required this.track,
    required this.mode,
    required this.onOpenPlayer,
    required this.queueTracks,
    this.playlistId,
  });

  final LocalTrack track;
  final _TrackListMode mode;
  final VoidCallback onOpenPlayer;
  final List<LocalTrack> queueTracks;
  final String? playlistId;

  @override
  ConsumerState<_LocalTrackTile> createState() => _LocalTrackTileState();
}

class _LocalTrackTileState extends ConsumerState<_LocalTrackTile> {
  bool _hovered = false;

  LocalTrack get track => widget.track;
  _TrackListMode get mode => widget.mode;
  VoidCallback get onOpenPlayer => widget.onOpenPlayer;
  List<LocalTrack> get queueTracks => widget.queueTracks;
  String? get playlistId => widget.playlistId;

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final isFavorite = ref.watch(
      favoriteTrackIdsProvider.select((ids) => ids.contains(track.id)),
    );
    final playback = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        return (trackId: snapshot?.trackId, status: snapshot?.status);
      }),
    );
    final isCurrent =
        playback.trackId == track.id &&
        (playback.status == PlayerStatus.loading ||
            playback.status == PlayerStatus.playing ||
            playback.status == PlayerStatus.paused);
    final isPlaying = isCurrent && playback.status == PlayerStatus.playing;
    final colors = Theme.of(context).colorScheme;
    final menuButtonSize = AppPlatform.isAndroid ? 42.0 : 52.0;
    final menuIconSize = AppPlatform.isAndroid ? 32.0 : 28.0;
    final menuItemIconColor = AppColors.menuIconFor(context);
    final borderRadius = BorderRadius.circular(8);
    final baseColor = AppColors.cardSurfaceFor(context);
    final borderColor = isCurrent
        ? colors.primary
        : _hovered
        ? colors.primary
        : AppColors.cardBorderFor(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: isCurrent
              ? Color.alphaBlend(
                  colors.onSurface.withValues(alpha: 0.075),
                  baseColor,
                )
              : baseColor,
          borderRadius: borderRadius,
          border: Border.all(color: borderColor, width: _hovered ? 1.4 : 1),
        ),
        child: Material(
          color: Colors.transparent,
          child: ListTile(
            dense: false,
            minTileHeight: 70,
            minVerticalPadding: 7,
            contentPadding: const EdgeInsets.only(left: 12, right: 4),
            horizontalTitleGap: 10,
            shape: RoundedRectangleBorder(borderRadius: borderRadius),
            tileColor: Colors.transparent,
            leading: Stack(
              children: [
                _LocalArtwork(
                  source: track.thumbnailPath ?? track.thumbnailUrl,
                ),
                if (isFavorite)
                  const Positioned(
                    top: 1,
                    right: 1,
                    child: FavoriteStarBadge(iconSize: 15),
                  ),
                if (isCurrent)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Center(
                      child: NowPlayingEqualizer(
                        key: ValueKey('now-playing-${track.id}'),
                        isPlaying: isPlaying,
                      ),
                    ),
                  ),
              ],
            ),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w700,
                color: AppColors.contentTitleFor(context),
              ),
            ),
            subtitle: Text(
              '${track.artist}  -  ${formatDuration(track.duration)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.contentSubtitleFor(context),
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TrackPlayButton(
                  tooltip: isPlaying ? strings.pause : strings.play,
                  isPlaying: isPlaying,
                  onPressed: () => _togglePlayback(ref),
                ),
                SizedBox(
                  width: menuButtonSize,
                  height: menuButtonSize,
                  child: PopupMenuButton<_TrackMenuAction>(
                    tooltip: strings.moreOptions,
                    padding: EdgeInsets.zero,
                    splashRadius: menuButtonSize / 2,
                    iconSize: menuIconSize,
                    child: Center(
                      child: Icon(Icons.more_vert_rounded, size: menuIconSize),
                    ),
                    onSelected: (action) => _handleAction(context, ref, action),
                    itemBuilder: (context) => switch (mode) {
                      _TrackListMode.downloads => [
                        PopupMenuItem(
                          value: _TrackMenuAction.renameTrack,
                          child: Row(
                            children: [
                              Icon(
                                Icons.drive_file_rename_outline_rounded,
                                color: menuItemIconColor,
                              ),
                              const SizedBox(width: 12),
                              Text(strings.rename),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: _TrackMenuAction.addToPlaylist,
                          child: Row(
                            children: [
                              Icon(
                                Icons.playlist_add_rounded,
                                color: menuItemIconColor,
                              ),
                              const SizedBox(width: 12),
                              Text(strings.addToPlaylist),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: _TrackMenuAction.toggleFavorite,
                          child: Row(
                            children: [
                              Icon(
                                isFavorite
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                color: isFavorite
                                    ? const Color(0xFFFFD54F)
                                    : menuItemIconColor,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                isFavorite
                                    ? strings.removeFromFavorites
                                    : strings.addToFavorites,
                              ),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: _TrackMenuAction.deleteTrack,
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_outline_rounded,
                                color: menuItemIconColor,
                              ),
                              const SizedBox(width: 12),
                              Text(strings.deleteSong),
                            ],
                          ),
                        ),
                      ],
                      _TrackListMode.playlist => [
                        PopupMenuItem(
                          value: _TrackMenuAction.renameTrack,
                          child: Row(
                            children: [
                              Icon(
                                Icons.drive_file_rename_outline_rounded,
                                color: menuItemIconColor,
                              ),
                              const SizedBox(width: 12),
                              Text(strings.rename),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: _TrackMenuAction.toggleFavorite,
                          child: Row(
                            children: [
                              Icon(
                                isFavorite
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                color: isFavorite
                                    ? const Color(0xFFFFD54F)
                                    : menuItemIconColor,
                              ),
                              const SizedBox(width: 12),
                              Text(
                                isFavorite
                                    ? strings.removeFromFavorites
                                    : strings.addToFavorites,
                              ),
                            ],
                          ),
                        ),
                        if (playlistId != Playlist.favoritesId)
                          PopupMenuItem(
                            value: _TrackMenuAction.removeFromPlaylist,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.playlist_remove_rounded,
                                  color: menuItemIconColor,
                                ),
                                const SizedBox(width: 12),
                                Text(strings.removeFromPlaylist),
                              ],
                            ),
                          ),
                      ],
                    },
                  ),
                ),
              ],
            ),
            onTap: () => _openOrPlay(ref),
          ),
        ),
      ),
    );
  }

  Future<void> _togglePlayback(WidgetRef ref) async {
    final snapshot = ref.read(playerControllerProvider).value;
    final player = ref.read(playerControllerProvider.notifier);
    if (snapshot?.trackId == track.id) {
      if (snapshot?.status == PlayerStatus.playing) {
        await player.pause();
        return;
      }
      if (snapshot?.status == PlayerStatus.paused) {
        await player.resume();
        return;
      }
    }

    final queueSourceId = playlistId == null
        ? null
        : PlayerController.playlistQueueSourceId(playlistId!);
    await player.playLocal(
      track,
      queue: queueTracks,
      useNativeQueue: queueSourceId == null,
      queueSourceId: queueSourceId,
    );
  }

  Future<void> _openOrPlay(WidgetRef ref) async {
    final snapshot = ref.read(playerControllerProvider).value;
    final alreadyLoaded =
        snapshot?.trackId == track.id &&
        (snapshot?.status == PlayerStatus.loading ||
            snapshot?.status == PlayerStatus.playing ||
            snapshot?.status == PlayerStatus.paused);
    if (alreadyLoaded) {
      onOpenPlayer();
      return;
    }

    final queueSourceId = playlistId == null
        ? null
        : PlayerController.playlistQueueSourceId(playlistId!);
    final playFuture = ref
        .read(playerControllerProvider.notifier)
        .playLocal(
          track,
          queue: queueTracks,
          useNativeQueue: queueSourceId == null,
          queueSourceId: queueSourceId,
        );
    onOpenPlayer();
    await playFuture;
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    _TrackMenuAction action,
  ) async {
    switch (action) {
      case _TrackMenuAction.renameTrack:
        await _renameTrack(context, ref);
      case _TrackMenuAction.addToPlaylist:
        await _addToPlaylist(context, ref);
      case _TrackMenuAction.toggleFavorite:
        final isNowFavorite = await ref
            .read(playlistsControllerProvider.notifier)
            .toggleFavorite(track.id);
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                isNowFavorite
                    ? ref.read(appStringsProvider).addedToFavorites
                    : ref.read(appStringsProvider).removedFromFavorites,
              ),
            ),
          );
      case _TrackMenuAction.deleteTrack:
        await _deleteTrack(context, ref);
      case _TrackMenuAction.removeFromPlaylist:
        final id = playlistId;
        if (id == null) {
          return;
        }
        await ref
            .read(playlistsControllerProvider.notifier)
            .removeTrackFromPlaylist(id, track.id);
    }
  }

  Future<void> _renameTrack(BuildContext context, WidgetRef ref) async {
    final strings = ref.read(appStringsProvider);
    final rawName = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: strings.renameSong,
        initialValue: track.title,
        hint: strings.name,
        cancelLabel: strings.cancel,
        confirmLabel: strings.rename,
      ),
    );
    final name = rawName?.trim();
    if (name == null || name.isEmpty || name == track.title) {
      return;
    }

    await ref
        .read(libraryRepositoryProvider)
        .saveLocalTrack(track.copyWith(title: name));
    ref
      ..invalidate(libraryTracksProvider)
      ..invalidate(historyProvider);

    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.read(appStringsProvider).songRenamed)),
    );
  }

  Future<void> _addToPlaylist(BuildContext context, WidgetRef ref) async {
    final playlists = (await ref.read(
      playlistsControllerProvider.future,
    )).where((playlist) => !playlist.isFavorites).toList(growable: false);
    if (!context.mounted) {
      return;
    }
    if (playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ref.read(appStringsProvider).createPlaylistFirst),
        ),
      );
      return;
    }

    final playlistId = await showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: Text(ref.read(appStringsProvider).choosePlaylist),
          children: playlists
              .map(
                (playlist) => SimpleDialogOption(
                  onPressed: () => Navigator.of(context).pop(playlist.id),
                  child: Text(playlist.name),
                ),
              )
              .toList(growable: false),
        );
      },
    );
    if (playlistId == null || !context.mounted) {
      return;
    }

    await ref
        .read(playlistsControllerProvider.notifier)
        .addTrackToPlaylist(playlistId, track.id);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.read(appStringsProvider).songAddedToPlaylist)),
    );
  }

  Future<void> _deleteTrack(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(ref.read(appStringsProvider).deleteSong),
          content: Text(track.title),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(ref.read(appStringsProvider).cancel),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(ref.read(appStringsProvider).delete),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    await ref.read(libraryRepositoryProvider).deleteLocalTrack(track.id);
    await ref
        .read(playlistsControllerProvider.notifier)
        .removeTrackFromAllPlaylists(track.id);
    await _deleteFile(track.filePath);
    await _deleteFile(track.thumbnailPath);
    ref
      ..invalidate(libraryTracksProvider)
      ..invalidate(historyProvider);

    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.read(appStringsProvider).songDeleted)),
    );
  }

  Future<void> _deleteFile(String? path) async {
    if (path == null || path.trim().isEmpty) {
      return;
    }
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class _LocalArtwork extends StatelessWidget {
  const _LocalArtwork({required this.source});

  final String? source;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        width: 56,
        height: 56,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: ProportionalArtwork(
            source: source,
            fallback: Icon(
              Icons.audiotrack_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 18),
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        error.toString(),
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}
