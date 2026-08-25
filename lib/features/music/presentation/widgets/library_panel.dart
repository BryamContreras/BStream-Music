import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dialog.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/widgets/app_shared_widgets.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../services/player/player_service.dart';
import '../../../../services/youtube_music/account/youtube_music_account.dart';
import '../../domain/entities/catalog_playlist.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/playlist_entry.dart';
import '../../domain/entities/track_info.dart';
import '../providers/local_audio_availability.dart';
import '../providers/music_providers.dart';
import '../providers/subscribed_artists_controller.dart';
import '../pages/artist_profile_page.dart';
import 'favorite_star_badge.dart';
import 'glass_popup_menu_button.dart';
import 'library_subscribed_artists_shelf.dart';
import 'now_playing_equalizer.dart';
import 'playlist_artwork.dart';
import 'playlist_picker_dialog.dart';
import 'playlist_track_subtitle.dart';
import 'scrolled_under_tab_frame.dart';
import 'source_image.dart';
import 'track_play_button.dart';

enum _LibraryRouteType { root, downloads, live, playlist }

enum _TrackMenuAction {
  download,
  renameTrack,
  addToPlaylist,
  toggleFavorite,
  deleteTrack,
  removeFromPlaylist,
}

enum _PlaylistMenuAction { renamePlaylist, deletePlaylist }

// Keep overview covers at the same visual size as artwork in downloaded-song
// and playlist detail rows. The shared card icon token is intentionally
// smaller and is better suited to settings/action icons than album artwork.
const double _libraryOverviewArtworkSize = 56;
const double _libraryArtworkRowMinHeight = 70;
const EdgeInsets _libraryOverviewContentPadding = EdgeInsets.only(
  left: 12,
  right: 4,
);

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
    this.bottomContentPadding = 0,
    super.key,
  });

  final VoidCallback onOpenPlayer;
  final LibraryNavigationController? navigationController;
  final double bottomContentPadding;

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
  final Set<String> _selectedTrackIds = <String>{};
  late _LibraryRoute _route;
  String _filter = '';
  bool _selectionActionInProgress = false;
  int _routeDirection = 1;

  @override
  void initState() {
    super.initState();
    _route = widget.navigationController?._route ?? const _LibraryRoute.root();
    widget.navigationController?._attach(this);
    _filterController.addListener(() {
      setState(() {
        _filter = _filterController.text;
        _selectedTrackIds.clear();
      });
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
    final catalogPlaylists = ref.watch(catalogPlaylistsProvider);
    final subscribedArtists = ref.watch(subscribedArtistsProvider);
    final liveQueue = _supportsTikTokLive
        ? ref.watch(tiktokLiveControllerProvider)
        : null;
    final strings = ref.watch(appStringsProvider);
    final enablesTrackSelection =
        Theme.of(context).platform == TargetPlatform.android;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final transitionDuration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 260);
    final currentRouteKey = ValueKey(_route.key);

    return AnimatedSwitcher(
      key: const ValueKey('library-route-switcher'),
      duration: transitionDuration,
      reverseDuration: transitionDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final incoming = child.key == currentRouteKey;
        final horizontalOffset = incoming
            ? 0.04 * _routeDirection
            : -0.03 * _routeDirection;
        final offset = Tween<Offset>(
          begin: Offset(horizontalOffset, 0),
          end: Offset.zero,
        ).animate(animation);
        return ClipRect(
          child: FadeTransition(
            opacity: animation,
            child: SlideTransition(position: offset, child: child),
          ),
        );
      },
      child: KeyedSubtree(
        key: currentRouteKey,
        child: switch (_route.type) {
          _LibraryRouteType.root => _LibraryRootView(
            bottomContentPadding: widget.bottomContentPadding,
            tracks: tracks,
            playlists: playlists,
            catalogPlaylists: catalogPlaylists,
            subscribedArtists: subscribedArtists,
            strings: strings,
            onOpenDownloads: _openDownloads,
            liveQueue: liveQueue,
            onOpenLive: _openLive,
            onOpenPlaylist: _openPlaylist,
            onCreatePlaylist: () => _showCreateDialog(context),
            onOpenArtist: _openSubscribedArtist,
          ),
          _LibraryRouteType.downloads => tracks.when(
            data: (items) => _TrackListView(
              bottomContentPadding: widget.bottomContentPadding,
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
              selectionEnabled: enablesTrackSelection,
              selectionBusy: _selectionActionInProgress,
              selectedTrackIds: _selectedTrackIds,
              onSelectTrack: _selectTrack,
              onToggleTrack: _toggleTrackSelection,
              onClearSelection: _clearTrackSelection,
              onAddSelected: (context) =>
                  _addSelectedTracksToPlaylist(context, allTracks: items),
              onDeleteSelected: (context) =>
                  _deleteSelectedLibraryTracks(context, items),
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
                      bottomContentPadding: widget.bottomContentPadding,
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
              return ref
                  .watch(catalogPlaylistProvider(playlist.id))
                  .when(
                    data: (catalogPlaylist) {
                      if (catalogPlaylist == null) {
                        return _PanelError(
                          error: strings.playlistMissing,
                          onBack: _goRoot,
                          title: playlist.isFavorites
                              ? strings.favorites
                              : playlist.name,
                        );
                      }
                      return tracks.when(
                        data: (libraryTracks) {
                          final allItems = _catalogDisplayItems(
                            catalogPlaylist,
                            libraryTracks,
                          );
                          // A legacy backup can briefly expose playlist.trackIds
                          // before its v8 catalog entries are repaired. Keep the
                          // old local-only view as a recovery path instead of
                          // presenting an empty playlist.
                          if (allItems.isEmpty &&
                              playlist.trackIds.isNotEmpty) {
                            final byId = <String, LocalTrack>{
                              for (final track in libraryTracks)
                                track.id: track,
                            };
                            final playlistTracks = playlist.trackIds
                                .map((id) => byId[id])
                                .whereType<LocalTrack>()
                                .toList(growable: false);
                            return _TrackListView(
                              bottomContentPadding: widget.bottomContentPadding,
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
                              selectionEnabled: enablesTrackSelection,
                              selectionBusy: _selectionActionInProgress,
                              selectedTrackIds: _selectedTrackIds,
                              onSelectTrack: _selectTrack,
                              onToggleTrack: _toggleTrackSelection,
                              onClearSelection: _clearTrackSelection,
                              onAddSelected: (context) =>
                                  _addSelectedTracksToPlaylist(
                                    context,
                                    allTracks: libraryTracks,
                                    currentPlaylistId: playlist.id,
                                  ),
                              onDeleteSelected: (context) =>
                                  _removeSelectedTracksFromPlaylist(
                                    context,
                                    playlist,
                                    playlistTracks,
                                  ),
                            );
                          }
                          return _CatalogTrackListView(
                            bottomContentPadding: widget.bottomContentPadding,
                            title: playlist.isFavorites
                                ? strings.favorites
                                : playlist.name,
                            subtitle: strings.songCountWithDuration(
                              allItems.length,
                              sumKnownDurations(
                                allItems.map((item) => item.duration),
                              ),
                            ),
                            items: _filteredCatalogItems(allItems),
                            queueItems: allItems,
                            filterController: _filterController,
                            onBack: _goRoot,
                            onOpenPlayer: widget.onOpenPlayer,
                            playlist: playlist,
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
    _selectedTrackIds.clear();
    _filterController.clear();
    setState(() {
      _routeDirection = 1;
      _route = const _LibraryRoute.downloads();
    });
    widget.navigationController?._notifyRouteChanged(_route);
  }

  void _openLive() {
    if (!_supportsTikTokLive) {
      return;
    }
    _filterController.clear();
    setState(() {
      _routeDirection = 1;
      _route = const _LibraryRoute.live();
    });
    widget.navigationController?._notifyRouteChanged(_route);
  }

  bool get _supportsTikTokLive =>
      AppPlatform.supportsTikTokLive ||
      Theme.of(context).platform == TargetPlatform.android;

  void _openPlaylist(String playlistId) {
    _selectedTrackIds.clear();
    _filterController.clear();
    setState(() {
      _routeDirection = 1;
      _route = _LibraryRoute.playlist(playlistId);
    });
    widget.navigationController?._notifyRouteChanged(_route);
  }

  void _goRoot() {
    _selectedTrackIds.clear();
    _filterController.clear();
    setState(() {
      _routeDirection = -1;
      _route = const _LibraryRoute.root();
    });
    widget.navigationController?._notifyRouteChanged(_route);
  }

  bool get _canPop =>
      _selectedTrackIds.isNotEmpty || _route.type != _LibraryRouteType.root;

  bool _popRoute() {
    if (_selectedTrackIds.isNotEmpty) {
      _clearTrackSelection();
      return true;
    }
    if (!_canPop) {
      return false;
    }
    _goRoot();
    return true;
  }

  void _selectTrack(String trackId) {
    if (trackId.trim().isEmpty || _selectedTrackIds.contains(trackId)) {
      return;
    }
    setState(() => _selectedTrackIds.add(trackId));
  }

  void _toggleTrackSelection(String trackId) {
    setState(() {
      if (!_selectedTrackIds.remove(trackId)) {
        _selectedTrackIds.add(trackId);
      }
    });
  }

  void _clearTrackSelection() {
    if (_selectedTrackIds.isEmpty) {
      return;
    }
    setState(_selectedTrackIds.clear);
  }

  List<LocalTrack> _selectedTracks(Iterable<LocalTrack> tracks) {
    return tracks
        .where((track) => _selectedTrackIds.contains(track.id))
        .toList(growable: false);
  }

  Future<void> _addSelectedTracksToPlaylist(
    BuildContext context, {
    required List<LocalTrack> allTracks,
    String? currentPlaylistId,
  }) async {
    if (_selectionActionInProgress) {
      return;
    }
    setState(() => _selectionActionInProgress = true);
    try {
      await _addSelectedTracksToPlaylistUnlocked(
        context,
        allTracks: allTracks,
        currentPlaylistId: currentPlaylistId,
      );
    } finally {
      if (mounted) {
        setState(() => _selectionActionInProgress = false);
      }
    }
  }

  Future<void> _addSelectedTracksToPlaylistUnlocked(
    BuildContext context, {
    required List<LocalTrack> allTracks,
    String? currentPlaylistId,
  }) async {
    final selectedTracks = _selectedTracks(allTracks);
    if (selectedTracks.isEmpty) {
      _clearTrackSelection();
      return;
    }

    final playlists = (await ref.read(playlistsControllerProvider.future))
        .where(
          (playlist) =>
              !playlist.isFavorites && playlist.id != currentPlaylistId,
        )
        .toList(growable: false);
    final catalogPlaylists = await ref.read(catalogPlaylistsProvider.future);
    if (!mounted) {
      return;
    }
    if (playlists.isEmpty) {
      ScaffoldMessenger.of(this.context).showSnackBar(
        SnackBar(
          content: Text(ref.read(appStringsProvider).createPlaylistFirst),
        ),
      );
      return;
    }

    final playlistId = await showAppDialog<String>(
      context: this.context,
      builder: (_) => PlaylistPickerDialog(
        title: ref.read(appStringsProvider).choosePlaylist,
        playlists: playlists,
        tracks: allTracks,
        catalogPlaylists: catalogPlaylists,
      ),
    );
    if (playlistId == null || !mounted) {
      return;
    }

    final added = await ref
        .read(playlistsControllerProvider.notifier)
        .addTracksToPlaylist(
          playlistId,
          selectedTracks.map((track) => track.id),
        );
    if (!mounted) {
      return;
    }
    _clearTrackSelection();
    final strings = ref.read(appStringsProvider);
    ScaffoldMessenger.of(this.context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            added == 0
                ? strings.songsAlreadyInPlaylist
                : strings.songsAddedToPlaylist(added),
          ),
        ),
      );
  }

  Future<void> _removeSelectedTracksFromPlaylist(
    BuildContext context,
    Playlist playlist,
    List<LocalTrack> playlistTracks,
  ) async {
    if (_selectionActionInProgress) {
      return;
    }
    setState(() => _selectionActionInProgress = true);
    try {
      await _removeSelectedTracksFromPlaylistUnlocked(
        context,
        playlist,
        playlistTracks,
      );
    } finally {
      if (mounted) {
        setState(() => _selectionActionInProgress = false);
      }
    }
  }

  Future<void> _removeSelectedTracksFromPlaylistUnlocked(
    BuildContext context,
    Playlist playlist,
    List<LocalTrack> playlistTracks,
  ) async {
    final selectedTracks = _selectedTracks(playlistTracks);
    if (selectedTracks.isEmpty) {
      _clearTrackSelection();
      return;
    }

    final strings = ref.read(appStringsProvider);
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(
          playlist.isFavorites
              ? strings.removeFromFavorites
              : strings.removeFromPlaylist,
        ),
        content: Text(
          strings.removeSelectedSongs(
            selectedTracks.length,
            favorites: playlist.isFavorites,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.playlist_remove_rounded),
            label: Text(
              playlist.isFavorites
                  ? strings.removeFromFavorites
                  : strings.removeFromPlaylist,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final removed = await ref
        .read(playlistsControllerProvider.notifier)
        .removeTracksFromPlaylist(
          playlist.id,
          selectedTracks.map((track) => track.id),
        );
    if (!mounted) {
      return;
    }
    _clearTrackSelection();
    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(
        content: Text(
          strings.songsRemovedFromPlaylist(
            removed,
            favorites: playlist.isFavorites,
          ),
        ),
      ),
    );
  }

  Future<void> _deleteSelectedLibraryTracks(
    BuildContext context,
    List<LocalTrack> allTracks,
  ) async {
    if (_selectionActionInProgress) {
      return;
    }
    setState(() => _selectionActionInProgress = true);
    try {
      await _deleteSelectedLibraryTracksUnlocked(context, allTracks);
    } finally {
      if (mounted) {
        setState(() => _selectionActionInProgress = false);
      }
    }
  }

  Future<void> _deleteSelectedLibraryTracksUnlocked(
    BuildContext context,
    List<LocalTrack> allTracks,
  ) async {
    final selectedTracks = _selectedTracks(allTracks);
    if (selectedTracks.isEmpty) {
      _clearTrackSelection();
      return;
    }

    final strings = ref.read(appStringsProvider);
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text(strings.deleteSelectedSongs),
        content: Text(strings.confirmDeleteSongs(selectedTracks.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final deleted = await _deleteLibraryTracks(ref, selectedTracks);
    if (!mounted) {
      return;
    }
    _clearTrackSelection();
    ScaffoldMessenger.of(
      this.context,
    ).showSnackBar(SnackBar(content: Text(strings.songsDeleted(deleted))));
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

  List<_CatalogDisplayItem> _filteredCatalogItems(
    List<_CatalogDisplayItem> items,
  ) {
    final query = _filter.trim().toLowerCase();
    if (query.isEmpty) {
      return items;
    }
    return items
        .where(
          (item) =>
              item.title.toLowerCase().contains(query) ||
              item.artist.toLowerCase().contains(query) ||
              (item.album?.toLowerCase().contains(query) ?? false),
        )
        .toList(growable: false);
  }

  Future<void> _showCreateDialog(BuildContext context) async {
    final strings = ref.read(appStringsProvider);
    final rawName = await showAppDialog<String>(
      context: context,
      builder: (_) => CreatePlaylistDialog(strings: strings),
    );
    final name = rawName?.trim();
    if (!mounted || name == null || name.isEmpty) {
      return;
    }
    await ref.read(playlistsControllerProvider.notifier).create(name);
  }

  void _openSubscribedArtist(RemoteSubscribedArtist artist) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtistProfilePage(
          artistBrowseId: artist.browseId,
          artistName: artist.name,
          artistThumbnailUrl: artist.thumbnailUrl,
          onOpenPlayer: widget.onOpenPlayer,
        ),
      ),
    );
  }
}

class _LibraryRootView extends StatelessWidget {
  const _LibraryRootView({
    required this.bottomContentPadding,
    required this.tracks,
    required this.playlists,
    required this.catalogPlaylists,
    required this.subscribedArtists,
    required this.liveQueue,
    required this.strings,
    required this.onOpenDownloads,
    required this.onOpenLive,
    required this.onOpenPlaylist,
    required this.onCreatePlaylist,
    required this.onOpenArtist,
  });

  final double bottomContentPadding;
  final AsyncValue<List<LocalTrack>> tracks;
  final AsyncValue<List<Playlist>> playlists;
  final AsyncValue<List<CatalogPlaylist>> catalogPlaylists;
  final AsyncValue<List<RemoteSubscribedArtist>> subscribedArtists;
  final AsyncValue<TikTokLiveState>? liveQueue;
  final AppStrings strings;
  final VoidCallback onOpenDownloads;
  final VoidCallback onOpenLive;
  final ValueChanged<String> onOpenPlaylist;
  final VoidCallback onCreatePlaylist;
  final ValueChanged<RemoteSubscribedArtist> onOpenArtist;

  @override
  Widget build(BuildContext context) {
    final localTracks = tracks.value ?? const <LocalTrack>[];
    final catalogsById = <String, CatalogPlaylist>{
      for (final catalog in catalogPlaylists.value ?? const <CatalogPlaylist>[])
        catalog.playlist.id: catalog,
    };
    final followedArtists =
        subscribedArtists.value ?? const <RemoteSubscribedArtist>[];

    return ScrolledUnderTabFrame(
      surfaceKey: const ValueKey('library-tab-header-surface'),
      header: Text(
        key: const ValueKey('library-tab-title'),
        strings.library,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: appTabTitleStyle(context),
      ),
      scrollKey: const ValueKey('library-root-scroll'),
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: appTabFirstSectionTopGap),
            child: tracks.when(
              data: (items) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _LibraryEntry(
                  key: const ValueKey('library-downloads-entry'),
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
          ),
        ),
        if (liveQueue != null) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          SliverToBoxAdapter(
            child: liveQueue!.when(
              data: (state) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: _LibraryEntry(
                  key: const ValueKey('library-live-entry'),
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
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 28)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(child: _SectionTitle(strings.playlist)),
                _NeutralLibraryIconButton(
                  key: const ValueKey('library-create-playlist-button'),
                  tooltip: strings.newPlaylist,
                  icon: Icons.add_rounded,
                  onPressed: onCreatePlaylist,
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 10)),
        playlists.when(
          data: (items) => _PlaylistList(
            playlists: items,
            libraryTracks: localTracks,
            catalogPlaylists: catalogsById,
            strings: strings,
            onOpenPlaylist: onOpenPlaylist,
          ),
          loading: () => const SliverToBoxAdapter(child: _LoadingRow()),
          error: (error, _) =>
              SliverToBoxAdapter(child: _ErrorRow(error: error)),
        ),
        if (followedArtists.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
          SliverToBoxAdapter(
            child: LibrarySubscribedArtistsShelf(
              title: strings.choose('Artistas', 'Artists'),
              artists: followedArtists,
              onOpenArtist: onOpenArtist,
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: SizedBox(
            key: const ValueKey('library-scroll-bottom-reserve'),
            height: bottomContentPadding + 24,
          ),
        ),
      ],
    );
  }
}

class _LiveQueueView extends ConsumerWidget {
  const _LiveQueueView({
    required this.bottomContentPadding,
    required this.state,
    required this.strings,
    required this.onBack,
    required this.onOpenPlayer,
  });

  final double bottomContentPadding;
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
              key: const ValueKey('library-detail-header'),
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
                    padding: EdgeInsets.only(bottom: bottomContentPadding + 12),
                    itemCount: items.length,
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
    final activeTrack = ref.watch(
      playerControllerProvider.select(
        (player) => (
          trackId: player.value?.trackId,
          sourceUrl: player.value?.sourceUrl,
        ),
      ),
    );
    final isCurrent = _matchesActiveTrack(
      trackId: activeTrack.trackId,
      sourceUrl: activeTrack.sourceUrl,
    );
    final statusColor = _statusColor(context, isCurrent: isCurrent);
    final playButtonSize = AppPlatform.isAndroid ? 48.0 : 52.0;
    final playIconSize = AppPlatform.isAndroid ? 30.0 : 26.0;
    final subtitleStyle = appListCardSubtitleStyle(context);

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
        title: MarqueeText(
          item.displayTitle,
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
                    style: subtitleStyle,
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
              style: subtitleStyle.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w700,
              ),
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
        item.localTrack == null
            ? strings.readyForRemotePlayback
            : item.reusedExisting
            ? strings.reusedDownload
            : strings.completed,
      LiveQueueItemStatus.failed => item.message ?? strings.error,
    };
  }

  bool _matchesActiveTrack({String? trackId, String? sourceUrl}) {
    final localTrack = item.localTrack;
    if (localTrack != null && localTrack.id == trackId) {
      return true;
    }
    final remoteTrack = item.remoteTrack;
    if (remoteTrack == null) {
      return false;
    }
    final remoteId = remoteTrack.id.trim();
    if (remoteId.isNotEmpty && remoteId == trackId) {
      return true;
    }
    final activeSource = sourceUrl?.trim();
    return activeSource != null &&
        activeSource.isNotEmpty &&
        (activeSource == remoteTrack.url ||
            activeSource == remoteTrack.streamUrl);
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

class _CatalogDisplayItem {
  const _CatalogDisplayItem({required this.entry, this.playback});

  final PlaylistEntry entry;
  final CatalogPlaybackItem? playback;

  LocalTrack? get localTrack => playback?.localTrack;
  bool get isPlayable => playback != null;
  String get title => localTrack?.title ?? entry.track.title;
  String get artist {
    final localArtist = localTrack?.artist.trim();
    if (localArtist != null && localArtist.isNotEmpty) {
      return localArtist;
    }
    return entry.track.artists.join(', ');
  }

  String? get album => localTrack?.album ?? entry.track.album;
  Duration? get duration => localTrack?.duration ?? entry.track.duration;
  PlaylistArtworkSource? get trackArtworkSource =>
      preferredCatalogTrackArtworkSource(entry.track, localTrack: localTrack);
  String? get artworkSource => trackArtworkSource?.source;
  String? get artworkFallbackSource => trackArtworkSource?.fallbackSource;

  PlaylistArtworkSource? get playlistArtworkSource =>
      preferredCatalogPlaylistArtworkSource(
        entry.track,
        localTrack: localTrack,
      );

  bool matchesSnapshot(PlayerSnapshot? snapshot) {
    final trackId = snapshot?.trackId;
    return trackId != null &&
        (trackId == playback?.localTrack?.id ||
            trackId == playback?.remoteTrack?.id);
  }
}

List<_CatalogDisplayItem> _catalogDisplayItems(
  CatalogPlaylist playlist,
  Iterable<LocalTrack> libraryTracks,
) {
  final playbackByEntry = <String, CatalogPlaybackItem>{
    for (final item in catalogPlaylistPlaybackItems(playlist, libraryTracks))
      item.entryId: item,
  };
  final entries = playlist.entries.where((entry) => !entry.isDeleted).toList()
    ..sort((left, right) {
      final byPosition = left.position.compareTo(right.position);
      return byPosition != 0 ? byPosition : left.id.compareTo(right.id);
    });
  return List<_CatalogDisplayItem>.unmodifiable(
    entries.map(
      (entry) => _CatalogDisplayItem(
        entry: entry,
        playback: playbackByEntry[entry.id],
      ),
    ),
  );
}

List<PlaylistArtworkSource> _catalogPlaylistThumbnailSources(
  String playlistId,
  List<_CatalogDisplayItem> items,
) {
  return rotatingPlaylistArtworkSources(
    playlistId: playlistId,
    candidates: items.map((item) => item.playlistArtworkSource),
  );
}

Widget _trackMenuItem(BuildContext context, IconData icon, String label) {
  return Row(
    children: <Widget>[
      Icon(icon, color: AppColors.menuIconFor(context)),
      const SizedBox(width: 12),
      Expanded(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}

Future<String?> _pickDestinationPlaylist(
  BuildContext context,
  WidgetRef ref, {
  String? excludePlaylistId,
}) async {
  final strings = ref.read(appStringsProvider);
  final playlists = (await ref.read(playlistsControllerProvider.future))
      .where(
        (playlist) => !playlist.isFavorites && playlist.id != excludePlaylistId,
      )
      .toList(growable: false);
  if (!context.mounted) return null;
  if (playlists.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.createPlaylistFirst)));
    return null;
  }
  final tracks = await ref.read(libraryTracksProvider.future);
  final catalogs = await ref.read(catalogPlaylistsProvider.future);
  if (!context.mounted) return null;
  return showAppDialog<String>(
    context: context,
    builder: (_) => PlaylistPickerDialog(
      title: strings.choosePlaylist,
      playlists: playlists,
      tracks: tracks,
      catalogPlaylists: catalogs,
    ),
  );
}

TrackInfo? _remoteTrackInfoForLocal(LocalTrack track) {
  final sourceUrl = track.sourceUrl?.trim();
  final sourceId = track.sourceId?.trim();
  if ((sourceUrl == null || sourceUrl.isEmpty) &&
      (sourceId == null || sourceId.isEmpty)) {
    return null;
  }
  final id = sourceId == null || sourceId.isEmpty ? sourceUrl! : sourceId;
  final url = sourceUrl == null || sourceUrl.isEmpty
      ? Uri.https('www.youtube.com', '/watch', <String, String>{
          'v': id,
        }).toString()
      : sourceUrl;
  final artists = track.artists.isEmpty
      ? <String>[track.artist]
      : track.artists;
  return TrackInfo(
    id: id,
    title: track.title,
    artist: track.artist,
    artists: artists,
    artistBrowseIds: track.artistBrowseIds,
    album: track.album,
    duration: track.duration,
    thumbnailUrl: track.thumbnailUrl,
    catalogThumbnailUrl: track.catalogThumbnailUrl ?? track.thumbnailUrl,
    url: url,
    metadataSource: TrackMetadataSource.youtubeMusic,
  );
}

class _CatalogTrackListView extends ConsumerWidget {
  const _CatalogTrackListView({
    required this.bottomContentPadding,
    required this.title,
    required this.subtitle,
    required this.items,
    required this.queueItems,
    required this.filterController,
    required this.onBack,
    required this.onOpenPlayer,
    required this.playlist,
  });

  final double bottomContentPadding;
  final String title;
  final String subtitle;
  final List<_CatalogDisplayItem> items;
  final List<_CatalogDisplayItem> queueItems;
  final TextEditingController filterController;
  final VoidCallback onBack;
  final VoidCallback onOpenPlayer;
  final Playlist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _DetailHeader(
              key: const ValueKey('library-detail-header'),
              title: title,
              subtitle: subtitle,
              onBack: onBack,
              trailing: playlist.isFavorites
                  ? null
                  : _PlaylistMenu(playlist: playlist, onBack: onBack),
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
            child: items.isEmpty
                ? Center(
                    child: Text(
                      strings.noSongsToShow,
                      style: TextStyle(
                        color: AppColors.contentSubtitleFor(context),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.only(bottom: bottomContentPadding + 12),
                    itemCount: items.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                      child: _CatalogTrackTile(
                        key: ValueKey(
                          'library-catalog-entry-${items[index].entry.id}',
                        ),
                        item: items[index],
                        queueItems: queueItems,
                        playlist: playlist,
                        onOpenPlayer: onOpenPlayer,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _CatalogTrackTile extends ConsumerStatefulWidget {
  const _CatalogTrackTile({
    required this.item,
    required this.queueItems,
    required this.playlist,
    required this.onOpenPlayer,
    super.key,
  });

  final _CatalogDisplayItem item;
  final List<_CatalogDisplayItem> queueItems;
  final Playlist playlist;
  final VoidCallback onOpenPlayer;

  @override
  ConsumerState<_CatalogTrackTile> createState() => _CatalogTrackTileState();
}

class _CatalogTrackTileState extends ConsumerState<_CatalogTrackTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strings = ref.watch(appStringsProvider);
    final snapshot = ref.watch(playerControllerProvider).value;
    final queue = ref.watch(playbackQueueProvider);
    final isCurrent = _isCurrentOccurrence(snapshot, queue);
    final isPlaying = isCurrent && snapshot?.status == PlayerStatus.playing;
    final localTrack = widget.item.localTrack;
    final isDownloaded =
        localTrack != null &&
        ref
            .watch(localTrackAudioAvailabilityProvider(localTrack))
            .maybeWhen(data: (available) => available, orElse: () => true);
    final menuIconSize = AppPlatform.isAndroid ? 32.0 : 28.0;
    final menuIconColor = AppColors.menuIconFor(context);
    final borderRadius = BorderRadius.circular(appCardRadius);
    final baseColor = appListCardSurface(context);
    final activeColor = Color.alphaBlend(
      colors.primary.withValues(alpha: 0.13),
      baseColor,
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: isCurrent
              ? activeColor
              : _hovered
              ? Color.alphaBlend(
                  colors.onSurface.withValues(alpha: 0.075),
                  baseColor,
                )
              : baseColor,
          borderRadius: borderRadius,
          border: Border.all(
            color: isCurrent || _hovered
                ? colors.primary
                : appListCardBorder(context),
            width: isCurrent || _hovered ? 1.4 : 1,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: ListTile(
            minTileHeight: _libraryArtworkRowMinHeight,
            minVerticalPadding: 7,
            contentPadding: _libraryOverviewContentPadding,
            horizontalTitleGap: 10,
            shape: RoundedRectangleBorder(borderRadius: borderRadius),
            leading: Stack(
              children: <Widget>[
                _LocalArtwork(
                  source: widget.item.artworkSource,
                  fallbackSource: widget.item.artworkFallbackSource,
                ),
                if (isDownloaded)
                  Positioned(
                    right: 1,
                    bottom: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surface.withValues(alpha: 0.9),
                        shape: BoxShape.circle,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Icon(
                          Icons.download_done_rounded,
                          size: 14,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ),
                if (isCurrent || _hovered)
                  NowPlayingEqualizerOverlay(isPlaying: isPlaying),
              ],
            ),
            title: MarqueeText(
              widget.item.title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w700,
                color: isCurrent
                    ? colors.primary
                    : AppColors.contentTitleFor(context),
              ),
            ),
            subtitle: PlaylistTrackSubtitle(
              artist: widget.item.artist,
              duration: formatDuration(widget.item.duration),
              isDownloaded: isDownloaded,
              streamOnlyLabel: strings.streamOnlySong,
              cloudKey: ValueKey(
                'library-catalog-cloud-${widget.item.entry.id}',
              ),
              textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.contentSubtitleFor(context),
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TrackPlayButton(
                  key: ValueKey('library-catalog-play-${widget.item.entry.id}'),
                  tooltip: widget.item.isPlayable
                      ? isPlaying
                            ? strings.pause
                            : strings.play
                      : strings.choose(
                          'Canción no disponible en YouTube Music',
                          'Song unavailable on YouTube Music',
                        ),
                  isPlaying: isPlaying,
                  onPressed: widget.item.isPlayable ? _togglePlayback : null,
                ),
                SizedBox(
                  width: 36,
                  height: 44,
                  child: GlassPopupMenuButton<_TrackMenuAction>(
                    key: ValueKey(
                      'library-catalog-menu-${widget.item.entry.id}',
                    ),
                    tooltip: strings.moreOptions,
                    padding: EdgeInsets.zero,
                    iconSize: menuIconSize,
                    child: Center(
                      child: Icon(
                        Icons.more_vert_rounded,
                        size: menuIconSize,
                        color: menuIconColor,
                      ),
                    ),
                    onSelected: (action) => _handleAction(context, action),
                    itemBuilder: (context) {
                      final entries = <PopupMenuEntry<_TrackMenuAction>>[];
                      final remote = widget.item.playback?.remoteTrack;
                      if (remote != null && !isDownloaded) {
                        entries.add(
                          PopupMenuItem<_TrackMenuAction>(
                            value: _TrackMenuAction.download,
                            child: _trackMenuItem(
                              context,
                              Icons.download_rounded,
                              strings.download,
                            ),
                          ),
                        );
                      }
                      if (widget.item.isPlayable) {
                        entries.add(
                          PopupMenuItem<_TrackMenuAction>(
                            value: _TrackMenuAction.addToPlaylist,
                            child: _trackMenuItem(
                              context,
                              Icons.playlist_add_rounded,
                              strings.addToPlaylist,
                            ),
                          ),
                        );
                      }
                      entries.add(
                        PopupMenuItem<_TrackMenuAction>(
                          value: _TrackMenuAction.removeFromPlaylist,
                          child: _trackMenuItem(
                            context,
                            Icons.playlist_remove_rounded,
                            widget.playlist.isFavorites
                                ? strings.removeFromFavorites
                                : strings.removeFromPlaylist,
                          ),
                        ),
                      );
                      return entries;
                    },
                  ),
                ),
              ],
            ),
            onTap: widget.item.isPlayable ? _openOrPlay : null,
          ),
        ),
      ),
    );
  }

  Future<void> _togglePlayback() async {
    if (!widget.item.isPlayable) return;
    final snapshot = ref.read(playerControllerProvider).value;
    final queue = ref.read(playbackQueueProvider);
    final player = ref.read(playerControllerProvider.notifier);
    if (_isCurrentOccurrence(snapshot, queue)) {
      if (snapshot?.status == PlayerStatus.playing) {
        await player.pause();
        return;
      }
      if (snapshot?.status == PlayerStatus.paused) {
        await player.resume();
        return;
      }
    }
    await _play(player);
  }

  Future<void> _openOrPlay() async {
    if (!widget.item.isPlayable) return;
    final snapshot = ref.read(playerControllerProvider).value;
    final queue = ref.read(playbackQueueProvider);
    final alreadyLoaded =
        _isCurrentOccurrence(snapshot, queue) &&
        (snapshot?.status == PlayerStatus.loading ||
            snapshot?.status == PlayerStatus.playing ||
            snapshot?.status == PlayerStatus.paused);
    if (alreadyLoaded) {
      widget.onOpenPlayer();
      return;
    }
    final player = ref.read(playerControllerProvider.notifier);
    final future = _play(player);
    widget.onOpenPlayer();
    await future;
  }

  Future<void> _play(PlayerController player) {
    final playback = widget.item.playback;
    if (playback == null) return Future<void>.value();
    return player.playCatalogPlaylist(
      playback,
      queue: widget.queueItems
          .map((item) => item.playback)
          .whereType<CatalogPlaybackItem>()
          .toList(growable: false),
      playlistId: widget.playlist.id,
    );
  }

  bool _isCurrentOccurrence(
    PlayerSnapshot? snapshot,
    PlaybackQueueState queue,
  ) {
    final currentLogicalEntryId =
        queue.currentIndex >= 0 && queue.currentIndex < queue.entries.length
        ? queue.entries[queue.currentIndex].logicalEntryId
        : null;
    return currentLogicalEntryId != null
        ? currentLogicalEntryId == widget.item.entry.id
        : widget.item.matchesSnapshot(snapshot);
  }

  Future<void> _handleAction(
    BuildContext context,
    _TrackMenuAction action,
  ) async {
    final controller = ref.read(playlistsControllerProvider.notifier);
    switch (action) {
      case _TrackMenuAction.download:
        final remote = widget.item.playback?.remoteTrack;
        if (remote == null) return;
        await ref
            .read(downloadControllerProvider.notifier)
            .downloadAudio(remote);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ref.read(appStringsProvider).downloadQueued),
            ),
          );
        }
      case _TrackMenuAction.addToPlaylist:
        final playlistId = await _pickDestinationPlaylist(
          context,
          ref,
          excludePlaylistId: widget.playlist.id,
        );
        if (playlistId == null || !context.mounted) return;
        final local = widget.item.localTrack;
        final remote = widget.item.playback?.remoteTrack;
        if (local != null) {
          await controller.addTrackToPlaylist(playlistId, local.id);
        } else if (remote != null) {
          await controller.addRemoteTrackToPlaylist(playlistId, remote);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ref.read(appStringsProvider).songAddedToPlaylist),
            ),
          );
        }
      case _TrackMenuAction.removeFromPlaylist:
        await controller.removeCatalogEntry(
          widget.playlist.id,
          widget.item.entry.id,
        );
      case _TrackMenuAction.renameTrack:
      case _TrackMenuAction.toggleFavorite:
      case _TrackMenuAction.deleteTrack:
        return;
    }
  }
}

class _TrackListView extends ConsumerWidget {
  const _TrackListView({
    required this.bottomContentPadding,
    required this.title,
    required this.subtitle,
    required this.tracks,
    required this.queueTracks,
    required this.filterController,
    required this.onBack,
    required this.onOpenPlayer,
    required this.mode,
    required this.selectionEnabled,
    required this.selectionBusy,
    required this.selectedTrackIds,
    required this.onSelectTrack,
    required this.onToggleTrack,
    required this.onClearSelection,
    required this.onAddSelected,
    required this.onDeleteSelected,
    this.playlist,
    this.playlistId,
  });

  final double bottomContentPadding;
  final String title;
  final String subtitle;
  final List<LocalTrack> tracks;
  final List<LocalTrack> queueTracks;
  final TextEditingController filterController;
  final VoidCallback onBack;
  final VoidCallback onOpenPlayer;
  final _TrackListMode mode;
  final bool selectionEnabled;
  final bool selectionBusy;
  final Set<String> selectedTrackIds;
  final ValueChanged<String> onSelectTrack;
  final ValueChanged<String> onToggleTrack;
  final VoidCallback onClearSelection;
  final Future<void> Function(BuildContext context) onAddSelected;
  final Future<void> Function(BuildContext context) onDeleteSelected;
  final Playlist? playlist;
  final String? playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final selectionActive = selectionEnabled && selectedTrackIds.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: selectionActive
                  ? _TrackSelectionToolbar(
                      key: const ValueKey('library-selection-toolbar'),
                      count: selectedTrackIds.length,
                      removesFromPlaylist: mode == _TrackListMode.playlist,
                      favorites: playlist?.isFavorites ?? false,
                      busy: selectionBusy,
                      onClose: onClearSelection,
                      onAddToPlaylist: () => onAddSelected(context),
                      onDelete: () => onDeleteSelected(context),
                    )
                  : _DetailHeader(
                      key: const ValueKey('library-detail-header'),
                      title: title,
                      subtitle: subtitle,
                      onBack: onBack,
                      trailing: playlist == null || playlist!.isFavorites
                          ? null
                          : _PlaylistMenu(playlist: playlist!, onBack: onBack),
                    ),
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
                    padding: EdgeInsets.only(bottom: bottomContentPadding + 12),
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                        child: _LocalTrackTile(
                          key: ValueKey('library-track-${tracks[index].id}'),
                          track: tracks[index],
                          mode: mode,
                          playlistId: playlistId,
                          queueTracks: queueTracks,
                          onOpenPlayer: onOpenPlayer,
                          selectionActive: selectionActive,
                          selected: selectedTrackIds.contains(tracks[index].id),
                          onLongPress: selectionEnabled
                              ? () => onSelectTrack(tracks[index].id)
                              : null,
                          onSelectionTap: selectionActive
                              ? () => onToggleTrack(tracks[index].id)
                              : null,
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

class _TrackSelectionToolbar extends ConsumerWidget {
  const _TrackSelectionToolbar({
    required this.count,
    required this.removesFromPlaylist,
    required this.favorites,
    required this.busy,
    required this.onClose,
    required this.onAddToPlaylist,
    required this.onDelete,
    super.key,
  });

  final int count;
  final bool removesFromPlaylist;
  final bool favorites;
  final bool busy;
  final VoidCallback onClose;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('library-selection-close'),
            tooltip: strings.close,
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              strings.selectedSongs(count),
              key: const ValueKey('library-selection-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppColors.contentHeadingFor(context),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('library-selection-add-to-playlist'),
            tooltip: strings.addToPlaylist,
            onPressed: busy ? null : onAddToPlaylist,
            color: colors.primary,
            icon: const Icon(Icons.playlist_add_rounded),
          ),
          IconButton(
            key: ValueKey(
              removesFromPlaylist
                  ? 'library-selection-remove-from-playlist'
                  : 'library-selection-delete',
            ),
            tooltip: removesFromPlaylist
                ? (favorites
                      ? strings.removeFromFavorites
                      : strings.removeFromPlaylist)
                : strings.deleteSelectedSongs,
            onPressed: busy ? null : onDelete,
            color: removesFromPlaylist ? colors.primary : colors.error,
            icon: Icon(
              removesFromPlaylist
                  ? (favorites
                        ? Icons.favorite_border_rounded
                        : Icons.playlist_remove_rounded)
                  : Icons.delete_outline_rounded,
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
    super.key,
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
          buttonSize: 48,
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
    super.key,
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
    final buttonSize = AppPlatform.isAndroid ? 48.0 : 52.0;
    final buttonWidth = AppPlatform.isAndroid ? 36.0 : 40.0;
    final iconSize = AppPlatform.isAndroid ? 32.0 : 24.0;
    final menuIconColor = AppColors.menuIconFor(context);
    return SizedBox(
      width: buttonWidth,
      height: buttonSize,
      child: GlassPopupMenuButton<_PlaylistMenuAction>(
        tooltip: strings.moreOptions,
        padding: EdgeInsets.zero,
        iconSize: iconSize,
        child: Center(
          child: Icon(
            Icons.more_vert_rounded,
            size: iconSize,
            color: menuIconColor,
          ),
        ),
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
                Expanded(
                  child: Text(
                    strings.renamePlaylist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: _PlaylistMenuAction.deletePlaylist,
            child: Row(
              children: [
                Icon(Icons.delete_outline_rounded, color: menuIconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.deletePlaylist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
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
    final rawName = await showAppDialog<String>(
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
    final controller = ref.read(playlistsControllerProvider.notifier);
    final options = await controller.playlistDeleteOptions(playlist.id);
    if (!context.mounted) return;
    final scope = await showAppDialog<PlaylistDeleteScope>(
      context: context,
      builder: (dialogContext) {
        final linked = options.isYouTubeMusicLinked;
        final canDeleteRemote = options.canDeleteFromYouTubeMusic;
        return AppAlertDialog(
          title: Text(strings.deletePlaylist),
          content: Text(
            linked
                ? canDeleteRemote
                      ? strings.confirmDeleteSyncedPlaylist
                      : strings.confirmDeleteReadOnlySyncedPlaylist
                : strings.confirmDeletePlaylist,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(strings.cancel),
            ),
            if (linked)
              TextButton(
                key: const Key('playlist-delete-local-only'),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(PlaylistDeleteScope.localOnly),
                child: Text(strings.removePlaylistFromBStream),
              )
            else
              FilledButton.icon(
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(strings.delete),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(PlaylistDeleteScope.localOnly),
              ),
            if (canDeleteRemote)
              FilledButton.icon(
                key: const Key('playlist-delete-youtube-too'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  foregroundColor: Theme.of(dialogContext).colorScheme.onError,
                ),
                icon: const Icon(Icons.delete_forever_outlined),
                label: Text(strings.deletePlaylistFromYouTubeMusic),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(PlaylistDeleteScope.youtubeMusicToo),
              ),
          ],
        );
      },
    );
    if (scope == null) {
      return;
    }

    await controller.deletePlaylist(playlist.id, scope: scope);
    if (!context.mounted) {
      return;
    }
    onBack();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          scope == PlaylistDeleteScope.youtubeMusicToo
              ? ref
                    .read(appStringsProvider)
                    .youtubeMusicPlaylistDeletionScheduled
              : ref.read(appStringsProvider).playlistDeleted,
        ),
      ),
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
    return AppAlertDialog(
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
    return AppSectionTitle(text);
  }
}

class _PlaylistList extends StatelessWidget {
  const _PlaylistList({
    required this.playlists,
    required this.libraryTracks,
    required this.catalogPlaylists,
    required this.strings,
    required this.onOpenPlaylist,
  });

  final List<Playlist> playlists;
  final List<LocalTrack> libraryTracks;
  final Map<String, CatalogPlaylist> catalogPlaylists;
  final AppStrings strings;
  final ValueChanged<String> onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    if (playlists.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            strings.noLocalPlaylists,
            style: TextStyle(color: AppColors.contentSubtitleFor(context)),
          ),
        ),
      );
    }

    final tracksById = {for (final track in libraryTracks) track.id: track};

    return SliverList.builder(
      itemCount: playlists.length,
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        final playlistTracks = playlist.trackIds
            .map((id) => tracksById[id])
            .whereType<LocalTrack>()
            .toList(growable: false);
        final catalog = catalogPlaylists[playlist.id];
        final catalogItems = catalog == null
            ? const <_CatalogDisplayItem>[]
            : _catalogDisplayItems(catalog, libraryTracks);
        final itemCount = catalog == null
            ? playlistTracks.length
            : catalogItems.length;
        final duration = catalog == null
            ? sumKnownDurations(playlistTracks.map((track) => track.duration))
            : sumKnownDurations(catalogItems.map((item) => item.duration));
        final thumbnailSources = catalog == null
            ? _playlistThumbnailSources(playlist, tracksById)
            : _catalogPlaylistThumbnailSources(playlist.id, catalogItems);
        return Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, appCardGap),
          child: _PlaylistRow(
            key: ValueKey('library-playlist-${playlist.id}'),
            playlist: playlist,
            thumbnailSources: thumbnailSources,
            subtitle: strings.songCountWithDuration(itemCount, duration),
            strings: strings,
            onTap: () => onOpenPlaylist(playlist.id),
          ),
        );
      },
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
    super.key,
  });

  final Playlist playlist;
  final List<PlaylistArtworkSource> thumbnailSources;
  final String subtitle;
  final AppStrings strings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _LibraryEntry(
      icon: playlist.isFavorites
          ? Icons.favorite_rounded
          : Icons.queue_music_rounded,
      leading: thumbnailSources.isEmpty
          ? null
          : Stack(
              children: [
                _PlaylistCover(
                  key: ValueKey('library-playlist-artwork-${playlist.id}'),
                  sources: thumbnailSources,
                ),
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

List<PlaylistArtworkSource> _playlistThumbnailSources(
  Playlist playlist,
  Map<String, LocalTrack> tracksById,
) {
  final sources = playlist.trackIds
      .map((id) => tracksById[id])
      .whereType<LocalTrack>()
      .map(preferredLocalPlaylistArtworkSource);
  return rotatingPlaylistArtworkSources(
    playlistId: playlist.id,
    candidates: sources,
  );
}

class _LibraryEntry extends StatelessWidget {
  const _LibraryEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.leading,
    this.trailing,
    super.key,
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
        minTileHeight: _libraryArtworkRowMinHeight,
        minVerticalPadding: 7,
        contentPadding: _libraryOverviewContentPadding,
        horizontalTitleGap: 10,
        leading: leading ?? _FolderIcon(icon: icon),
        title: MarqueeText(title, style: appListCardTitleStyle(context)),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: appListCardSubtitleStyle(context),
        ),
        trailing: trailing ?? const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}

class _PlaylistCover extends StatelessWidget {
  const _PlaylistCover({required this.sources, super.key});

  final List<PlaylistArtworkSource> sources;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return const _FolderIcon(icon: Icons.queue_music_rounded);
    }

    final underlay = sources.skip(1).take(8).toList(growable: false);
    final rows = _secondaryArtworkRows(underlay);

    return ClipRRect(
      borderRadius: BorderRadius.circular(appArtworkRadius),
      child: SizedBox(
        width: _libraryOverviewArtworkSize,
        height: _libraryOverviewArtworkSize,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SourceImage(
              source: sources.first.source,
              fallbackSource: sources.first.fallbackSource,
              cacheWidth: 192,
              fallback: const _PlaylistCoverFallback(),
            ),
            if (rows.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: rows.length == 1 ? 20 : 34,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: Color(0xAA000000),
                    border: Border(
                      top: BorderSide(color: Color(0xAA050805), width: 1),
                    ),
                  ),
                  child: Column(
                    children: [
                      for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                        Expanded(
                          child: Row(
                            key: ValueKey(
                              'playlist-cover-secondary-row-$rowIndex',
                            ),
                            children: [
                              for (final artwork in rows[rowIndex])
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.all(0.75),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(1.5),
                                      child: SourceImage(
                                        source: artwork.source,
                                        fallbackSource: artwork.fallbackSource,
                                        cacheWidth: 64,
                                        fallback:
                                            const _PlaylistCoverFallback(),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
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

List<List<PlaylistArtworkSource>> _secondaryArtworkRows(
  List<PlaylistArtworkSource> sources,
) {
  if (sources.isEmpty) {
    return const <List<PlaylistArtworkSource>>[];
  }
  if (sources.length <= 4) {
    return <List<PlaylistArtworkSource>>[sources];
  }

  final firstRowLength = (sources.length + 1) ~/ 2;
  return <List<PlaylistArtworkSource>>[
    sources.take(firstRowLength).toList(growable: false),
    sources.skip(firstRowLength).toList(growable: false),
  ];
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
      borderRadius: BorderRadius.circular(appCardRadius),
      side: BorderSide(
        color: _hovered ? colors.primary : appListCardBorder(context),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: ShapeDecoration(
          color: appListCardSurface(context),
          shape: shape,
        ),
        child: Material(
          color: Colors.transparent,
          elevation: 0,
          shadowColor: const Color(0x14000000),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(appCardRadius),
          ),
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
      width: _libraryOverviewArtworkSize,
      height: _libraryOverviewArtworkSize,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        borderRadius: BorderRadius.circular(appListCardIconRadius),
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
    required this.selectionActive,
    required this.selected,
    required this.onLongPress,
    required this.onSelectionTap,
    this.playlistId,
    super.key,
  });

  final LocalTrack track;
  final _TrackListMode mode;
  final VoidCallback onOpenPlayer;
  final List<LocalTrack> queueTracks;
  final bool selectionActive;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onSelectionTap;
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
  bool get selectionActive => widget.selectionActive;
  bool get selected => widget.selected;

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
    final artwork = preferredLocalTrackArtworkSource(track);
    final menuButtonSize = AppPlatform.isAndroid ? 48.0 : 52.0;
    final menuButtonWidth = AppPlatform.isAndroid ? 36.0 : 40.0;
    final menuIconSize = AppPlatform.isAndroid ? 32.0 : 28.0;
    final menuItemIconColor = AppColors.menuIconFor(context);
    final localAudioAvailable = ref
        .watch(localTrackAudioAvailabilityProvider(track))
        .maybeWhen(data: (available) => available, orElse: () => true);
    final borderRadius = BorderRadius.circular(appCardRadius);
    final baseColor = AppColors.cardSurfaceFor(context);
    final borderColor = selected
        ? colors.primary
        : isCurrent
        ? colors.primary
        : _hovered
        ? colors.primary
        : AppColors.cardBorderFor(context);
    return Semantics(
      selected: selectionActive ? selected : null,
      container: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: selected
                ? Color.alphaBlend(
                    colors.primary.withValues(alpha: 0.14),
                    baseColor,
                  )
                : isCurrent
                ? Color.alphaBlend(
                    colors.onSurface.withValues(alpha: 0.075),
                    baseColor,
                  )
                : baseColor,
            borderRadius: borderRadius,
            border: Border.all(
              color: borderColor,
              width: selected || _hovered ? 1.4 : 1,
            ),
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
                    key: ValueKey('library-track-artwork-${track.id}'),
                    source: artwork?.source,
                    fallbackSource: artwork?.fallbackSource,
                  ),
                  if (isFavorite)
                    const Positioned(
                      top: 1,
                      right: 1,
                      child: FavoriteStarBadge(iconSize: 15),
                    ),
                  if (isCurrent || _hovered)
                    NowPlayingEqualizerOverlay(
                      key: ValueKey('now-playing-${track.id}'),
                      isPlaying: isPlaying,
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
              subtitle: PlaylistTrackSubtitle(
                artist: track.artist,
                duration: formatDuration(track.duration),
                isDownloaded:
                    mode != _TrackListMode.playlist || localAudioAvailable,
                streamOnlyLabel: strings.streamOnlySong,
                cloudKey: ValueKey('library-legacy-cloud-${track.id}'),
                textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.contentSubtitleFor(context),
                ),
              ),
              trailing: selectionActive
                  ? SizedBox.square(
                      dimension: 48,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          child: Icon(
                            selected
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            key: ValueKey(
                              selected
                                  ? 'selection-check-${track.id}'
                                  : 'selection-empty-${track.id}',
                            ),
                            color: selected
                                ? colors.primary
                                : colors.onSurfaceVariant,
                            size: 28,
                          ),
                        ),
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TrackPlayButton(
                          key: ValueKey('library-track-play-${track.id}'),
                          tooltip: isPlaying ? strings.pause : strings.play,
                          isPlaying: isPlaying,
                          onPressed: () => _togglePlayback(ref),
                        ),
                        SizedBox(
                          width: menuButtonWidth,
                          height: menuButtonSize,
                          child: GlassPopupMenuButton<_TrackMenuAction>(
                            key: ValueKey('library-track-menu-${track.id}'),
                            tooltip: strings.moreOptions,
                            padding: EdgeInsets.zero,
                            splashRadius: menuButtonSize / 2,
                            iconSize: menuIconSize,
                            child: Center(
                              child: Icon(
                                Icons.more_vert_rounded,
                                size: menuIconSize,
                                color: menuItemIconColor,
                              ),
                            ),
                            onSelected: (action) =>
                                _handleAction(context, ref, action),
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
                                            ? Icons.favorite_rounded
                                            : Icons.favorite_border_rounded,
                                        color: isFavorite
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.primary
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
                                if (_remoteTrackInfoForLocal(track) != null)
                                  PopupMenuItem(
                                    value: _TrackMenuAction.download,
                                    child: _trackMenuItem(
                                      context,
                                      Icons.download_rounded,
                                      strings.download,
                                    ),
                                  ),
                                PopupMenuItem(
                                  value: _TrackMenuAction.addToPlaylist,
                                  child: _trackMenuItem(
                                    context,
                                    Icons.playlist_add_rounded,
                                    strings.addToPlaylist,
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _TrackMenuAction.renameTrack,
                                  child: _trackMenuItem(
                                    context,
                                    Icons.drive_file_rename_outline_rounded,
                                    strings.rename,
                                  ),
                                ),
                                PopupMenuItem(
                                  value: _TrackMenuAction.toggleFavorite,
                                  child: _trackMenuItem(
                                    context,
                                    isFavorite
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    isFavorite
                                        ? strings.removeFromFavorites
                                        : strings.addToFavorites,
                                  ),
                                ),
                                if (playlistId != Playlist.favoritesId)
                                  PopupMenuItem(
                                    value: _TrackMenuAction.removeFromPlaylist,
                                    child: _trackMenuItem(
                                      context,
                                      Icons.playlist_remove_rounded,
                                      strings.removeFromPlaylist,
                                    ),
                                  ),
                              ],
                            },
                          ),
                        ),
                      ],
                    ),
              onLongPress: widget.onLongPress,
              onTap: widget.onSelectionTap ?? () => _openOrPlay(ref),
            ),
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
      case _TrackMenuAction.download:
        final remote = _remoteTrackInfoForLocal(track);
        if (remote == null) return;
        await ref
            .read(downloadControllerProvider.notifier)
            .downloadAudio(remote);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ref.read(appStringsProvider).downloadQueued),
            ),
          );
        }
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
    final rawName = await showAppDialog<String>(
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
    final playlistId = await _pickDestinationPlaylist(
      context,
      ref,
      excludePlaylistId: this.playlistId,
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
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) {
        return AppAlertDialog(
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

    await _deleteLibraryTracks(ref, [track]);

    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.read(appStringsProvider).songDeleted)),
    );
  }
}

Future<int> _deleteLibraryTracks(
  WidgetRef ref,
  Iterable<LocalTrack> requestedTracks,
) async {
  final requestedIds = requestedTracks.map((track) => track.id).toSet();
  if (requestedIds.isEmpty) {
    return 0;
  }

  final repository = ref.read(libraryRepositoryProvider);
  final currentTracks = await repository.getLocalTracks();
  final targets = currentTracks
      .where((track) => requestedIds.contains(track.id))
      .toList(growable: false);
  if (targets.isEmpty) {
    return 0;
  }

  // The repository implementation performs this ID + file-path guarded delete
  // and playlist pruning in one database transaction. Reusing the same
  // primitive as reconciliation also protects against a stale UI selection.
  final deletedIds = await repository.purgeMissingLocalTracks(targets);
  if (deletedIds.isEmpty) {
    return 0;
  }

  final deletedTracks = targets
      .where((track) => deletedIds.contains(track.id))
      .toList(growable: false);
  await ref
      .read(playerControllerProvider.notifier)
      .removeDeletedLocalTracks(deletedIds);
  await ref.read(playlistsControllerProvider.notifier).reloadFromRepository();
  ref
    ..invalidate(libraryTracksProvider)
    ..invalidate(historyProvider);

  // Re-read after the transaction and queue replacement so a concurrently
  // restored/downloaded record sharing a legacy path keeps its file.
  final survivors = await repository.getLocalTracks();
  final survivorPaths = survivors
      .expand((track) => [track.filePath, track.thumbnailPath])
      .map(_normalizedLocalPath)
      .whereType<String>()
      .toSet();
  final filesToDelete = <String, String>{};
  for (final target in deletedTracks) {
    for (final path in [target.filePath, target.thumbnailPath]) {
      final normalized = _normalizedLocalPath(path);
      if (normalized != null && !survivorPaths.contains(normalized)) {
        filesToDelete.putIfAbsent(normalized, () => path!);
      }
    }
  }
  // Let the list release FileImage listeners before unlinking thumbnails. This
  // matters on Windows tests and keeps the same code safe if desktop selection
  // is enabled later; Android itself permits unlinking open files.
  await WidgetsBinding.instance.endOfFrame;
  for (final path in filesToDelete.values) {
    await _deleteFileBestEffort(path);
  }
  return deletedIds.length;
}

String? _normalizedLocalPath(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  try {
    final normalized = p.normalize(p.absolute(trimmed));
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  } on FileSystemException {
    return Platform.isWindows ? trimmed.toLowerCase() : trimmed;
  }
}

Future<void> _deleteFileBestEffort(String path) async {
  final file = File(path);
  await FileImage(file).evict();
  await ResizeImage(FileImage(file), width: 256).evict();
  await ResizeImage(FileImage(file), width: 640).evict();
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      if (!await file.exists()) {
        return;
      }
      await file.delete();
      return;
    } on FileSystemException {
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  }
}

class _LocalArtwork extends StatelessWidget {
  const _LocalArtwork({required this.source, this.fallbackSource, super.key});

  final String? source;
  final String? fallbackSource;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(appArtworkRadius),
      child: SizedBox(
        width: 56,
        height: 56,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          child: ProportionalArtwork(
            source: source,
            fallbackSource: fallbackSource,
            cacheWidth: 256,
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
