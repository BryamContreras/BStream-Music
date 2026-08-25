import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dialog.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/widgets/app_shared_widgets.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../core/utils/image_source.dart';
import '../../../../core/platform/app_platform.dart';
import '../../../../platform_channels/android_external_audio_channel.dart';
import '../../../../services/recommendations/recommendation_feed_models.dart';
import '../../../../services/sharing/bstream_track_link.dart';
import '../../../../services/sharing/youtube_music_link.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../data/datasources/remote_music_datasource.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import '../providers/youtube_music_auth_controller.dart';
import '../widgets/bstream_logo.dart';
import '../widgets/favorite_star_badge.dart';
import '../widgets/library_panel.dart';
import '../widgets/local_music_panel.dart';
import '../widgets/mini_player.dart';
import '../widgets/playback_gradient_background.dart';
import '../widgets/player_panel.dart';
import '../widgets/playlist_picker_dialog.dart';
import '../widgets/scrolled_under_tab_frame.dart';
import '../widgets/settings_panel.dart';
import '../widgets/source_image.dart';
import '../widgets/youtube_music_account_button.dart';
import 'artist_profile_page.dart';
import 'remote_collection_detail_page.dart';
import 'search_view.dart';
import '../widgets/lyrics_page.dart';

double _shellSystemBottomInset(BuildContext context) {
  final mediaQuery = MediaQuery.of(context);
  // When Scaffold has already resized its body above the IME, the body's
  // bottom edge is the keyboard edge. Reserving viewPadding again leaves a
  // visible strip between the mini player and the bottom navigation.
  if (mediaQuery.viewInsets.bottom > 0) {
    return 0;
  }
  return math.max(mediaQuery.viewPadding.bottom, mediaQuery.padding.bottom);
}

enum HomeInitialDestination { home, player }

typedef HomeGreetingClock = DateTime Function();

/// Wall clock used by Home's greeting. Keeping the function injectable makes
/// morning and afternoon behavior deterministic in tests, while a later Home
/// rebuild still observes the current device time.
final homeGreetingClockProvider = Provider<HomeGreetingClock>(
  (ref) => DateTime.now,
);

class HomePage extends ConsumerStatefulWidget {
  const HomePage({
    super.key,
    this.initialDestination = HomeInitialDestination.home,
  });

  final HomeInitialDestination initialDestination;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static const _maxViewHistory = 2;
  static const _shellTransitionDuration = Duration(milliseconds: 320);

  late int _selectedIndex;
  final List<int> _viewHistory = [];
  final LibraryNavigationController _libraryNavigationController =
      LibraryNavigationController();
  final LocalMusicNavigationController _localMusicNavigationController =
      LocalMusicNavigationController();
  final SettingsNavigationController _settingsNavigationController =
      SettingsNavigationController();
  final FocusNode _desktopPlaybackShortcutFocus = FocusNode(
    debugLabel: 'Desktop playback shortcut',
  );
  int _rootBackCount = 0;
  DateTime? _lastRootBackAt;
  StreamSubscription<ExternalAudioRequest>? _externalAudioSubscription;
  ProviderSubscription<AsyncValue<BStreamTrackLink>>?
  _incomingTrackLinkSubscription;
  ProviderSubscription<AsyncValue<YouTubeMusicLink>>?
  _incomingYouTubeMusicLinkSubscription;
  Future<void> _externalAudioWork = Future<void>.value();
  Future<void> _incomingTrackLinkWork = Future<void>.value();
  Future<void> _incomingYouTubeMusicLinkWork = Future<void>.value();
  final Set<String> _startedExternalAudioRequests = <String>{};
  final Set<String> _reportedIncompleteExternalFolders = <String>{};
  LocalHistoryEntry? _playerHistoryEntry;
  bool _playerHistoryRegistrationScheduled = false;
  bool _ignorePlayerHistoryRemoval = false;

  @override
  void initState() {
    super.initState();
    _selectedIndex = switch (widget.initialDestination) {
      HomeInitialDestination.home => _homeIndex,
      HomeInitialDestination.player => _playerIndex,
    };
    unawaited(
      Future.wait([
        ref.read(downloaderWarmupProvider.future),
        ref.read(settingsControllerProvider.future),
      ]).catchError((_) => <Object?>[]),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _ensurePlayerHistoryEntry();
        unawaited(_reconcileLocalLibrary());
      }
    });
    if (AppPlatform.isAndroid) {
      _externalAudioSubscription = const AndroidExternalAudioChannel().requests
          .listen(
            _queueExternalAudioRequest,
            onError: (Object error, StackTrace stackTrace) {
              debugPrint('External audio channel failed: $error');
              debugPrintStack(stackTrace: stackTrace);
            },
          );
    }
    _incomingTrackLinkSubscription = ref
        .listenManual<AsyncValue<BStreamTrackLink>>(
          incomingTrackLinkProvider,
          (_, next) => next.whenData(_queueIncomingTrackLink),
          fireImmediately: true,
        );
    _incomingYouTubeMusicLinkSubscription = ref
        .listenManual<AsyncValue<YouTubeMusicLink>>(
          incomingYouTubeMusicLinkProvider,
          (_, next) => next.whenData(_queueIncomingYouTubeMusicLink),
          fireImmediately: true,
        );
  }

  void _queueIncomingTrackLink(BStreamTrackLink link) {
    _incomingTrackLinkWork = _incomingTrackLinkWork
        .then((_) => _handleIncomingTrackLink(link))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Could not open shared BStream track: $error');
          debugPrintStack(stackTrace: stackTrace);
        });
  }

  Future<void> _handleIncomingTrackLink(BStreamTrackLink link) async {
    if (!mounted) {
      return;
    }
    _openPlayer();

    final watchUrl = link.youtubeUri.toString();
    TrackInfo? track;
    try {
      final search = ref.read(youtubeMusicSearchProvider);
      if (search is YouTubeMusicTrackLookup) {
        final song = await (search as YouTubeMusicTrackLookup)
            .getSong(link.videoId)
            .timeout(const Duration(seconds: 3));
        if (song != null) {
          track = trackInfoFromInnerTubeSong(song);
        }
      }
    } catch (error) {
      // Metadata is best effort and must never delay playback indefinitely.
      // The normal player path below still performs Explode -> yt-dlp audio
      // fallback with the canonical YouTube URL.
      debugPrint('Shared track InnerTube lookup failed: $error');
    }

    final strings = ref.read(appStringsProvider);
    track ??= TrackInfo(
      id: link.videoId,
      title: strings.sharedSong,
      artist: 'YouTube',
      url: watchUrl,
      thumbnailUrl: youtubeThumbnailSourceForVideoId(link.videoId),
    );

    if (!mounted) {
      return;
    }
    await ref.read(playerControllerProvider.future);
    await ref
        .read(playerControllerProvider.notifier)
        .playRemote(track, queueSourceId: 'shared-link:${link.videoId}');
  }

  void _queueIncomingYouTubeMusicLink(YouTubeMusicLink link) {
    _incomingYouTubeMusicLinkWork = _incomingYouTubeMusicLinkWork
        .then((_) => _handleIncomingYouTubeMusicLink(link))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Could not open YouTube Music link: $error');
          debugPrintStack(stackTrace: stackTrace);
        });
  }

  Future<void> _handleIncomingYouTubeMusicLink(YouTubeMusicLink link) async {
    if (!mounted) return;
    if (link.isTrack && link.videoId != null) {
      await _handleIncomingTrackLink(BStreamTrackLink(videoId: link.videoId!));
      return;
    }
    final collectionId = link.collectionId;
    if (collectionId == null || collectionId.isEmpty) return;
    final strings = ref.read(appStringsProvider);
    final isAlbum = link.kind == YouTubeMusicLinkKind.album;
    final title = switch (link.kind) {
      YouTubeMusicLinkKind.album => strings.album,
      YouTubeMusicLinkKind.mix => strings.mix,
      _ => strings.playlist,
    };
    final tracksProvider = isAlbum
        ? homeAlbumTracksProvider(collectionId)
        : homeCollectionTracksProvider(collectionId);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteCollectionDetailPage(
          title: title,
          subtitle: strings.youtubeMusic,
          artworkSource: null,
          metadata: const [],
          queueSourceId: 'incoming-youtube:${link.kind.name}:$collectionId',
          tracksProvider: tracksProvider,
          emptyMessage: strings.homeCollectionEmpty,
          errorMessage: strings.homeCollectionLoadError,
          onOpenPlayer: _openPlayer,
          onAddToPlaylist: _addRemoteTracksToPlaylist,
        ),
      ),
    );
  }

  Future<void> _addRemoteTracksToPlaylist(
    BuildContext context,
    List<TrackInfo> tracks, {
    String? initialPlaylistName,
  }) async {
    if (tracks.isEmpty || !context.mounted) return;
    final strings = ref.read(appStringsProvider);
    String? playlistId;
    if (initialPlaylistName != null) {
      final rawName = await showAppDialog<String>(
        context: context,
        builder: (_) => CreatePlaylistDialog(
          strings: strings,
          initialName: initialPlaylistName,
        ),
      );
      final name = rawName?.trim();
      if (!mounted || name == null || name.isEmpty) {
        return;
      }
      final created = await ref
          .read(playlistsControllerProvider.notifier)
          .create(name);
      playlistId = created?.id;
      if (!mounted || playlistId == null) {
        return;
      }
    }
    final playlists = (await ref.read(
      playlistsControllerProvider.future,
    )).where((playlist) => !playlist.isFavorites).toList(growable: false);
    if (!context.mounted) return;
    if (playlistId == null && playlists.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.createPlaylistFirst)));
      return;
    }
    final localTracks = await ref
        .read(libraryRepositoryProvider)
        .getLocalTracks();
    final catalogs = await ref.read(catalogPlaylistsProvider.future);
    if (!context.mounted) return;
    playlistId ??= await showAppDialog<String>(
      context: context,
      builder: (_) => PlaylistPickerDialog(
        title: strings.choosePlaylist,
        playlists: playlists,
        tracks: localTracks,
        catalogPlaylists: catalogs,
      ),
    );
    if (playlistId == null || !context.mounted) return;
    try {
      final added = await ref
          .read(playlistsControllerProvider.notifier)
          .addRemoteTracksToPlaylist(playlistId, tracks, download: false);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(strings.songsAddedToPlaylist(added))),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.error)));
      return;
    }
  }

  void _queueExternalAudioRequest(ExternalAudioRequest request) {
    _externalAudioWork = _externalAudioWork
        .then((_) => _handleExternalAudioRequest(request))
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Could not open external audio: $error');
          debugPrintStack(stackTrace: stackTrace);
        });
  }

  Future<void> _handleExternalAudioRequest(ExternalAudioRequest request) async {
    if (!mounted) {
      return;
    }
    final strings = ref.read(appStringsProvider);
    final tracks = request.toLocalTracks(unknownArtist: strings.unknownArtist);
    final player = ref.read(playerControllerProvider.notifier);

    if (_startedExternalAudioRequests.add(request.requestId)) {
      _openPlayer();
      await ref.read(playerControllerProvider.future);
      await player.playLocal(
        tracks[request.selectedIndex],
        queue: tracks,
        useNativeQueue: true,
        queueSourceId: request.queueSourceId,
      );
    } else if (player.isLocalQueueSourceActive(request.queueSourceId)) {
      await player.syncLocalQueueSource(request.queueSourceId, tracks);
    }

    if (!mounted ||
        request.permissionPending ||
        request.folderQueueComplete ||
        !_reportedIncompleteExternalFolders.add(request.requestId)) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(strings.externalAudioFolderUnavailable)),
      );
  }

  Future<void> _reconcileLocalLibrary() async {
    try {
      await ref.read(localLibraryReconciliationProvider.future);
    } catch (error, stackTrace) {
      // A background catalog cleanup must never prevent the app from opening.
      debugPrint('Local library reconciliation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  bool get _usesAndroidNavigation =>
      defaultTargetPlatform == TargetPlatform.android;

  int get _homeIndex => 0;
  int get _searchIndex => 1;
  int get _localIndex => 2;
  int get _playerIndex => _usesAndroidNavigation ? 5 : 3;
  int get _libraryIndex => _usesAndroidNavigation ? 3 : 4;
  int get _settingsIndex => _usesAndroidNavigation ? 4 : 5;

  bool get _isPlayerSelected => _selectedIndex == _playerIndex;

  void _selectIndex(int index) {
    _setSelectedIndex(index);
  }

  void _setSelectedIndex(int index, {bool recordHistory = true}) {
    if (index == _selectedIndex) {
      if (index == _playerIndex) {
        _schedulePlayerHistoryEntry();
      }
      return;
    }

    final leavingPlayer = _isPlayerSelected && index != _playerIndex;
    if (leavingPlayer) {
      _removePlayerHistoryEntry();
    }
    _releaseFocusForViewChange();
    setState(() {
      _rootBackCount = 0;
      _lastRootBackAt = null;
      if (recordHistory) {
        _viewHistory.add(_selectedIndex);
        while (_viewHistory.length > _maxViewHistory) {
          _viewHistory.removeAt(0);
        }
      }
      _selectedIndex = index;
    });
    if (index == _playerIndex) {
      _schedulePlayerHistoryEntry();
    }
  }

  void _openPlayer() {
    _setSelectedIndex(_playerIndex);
  }

  void _openSearch() {
    if (_isPlayerSelected) {
      _removePlayerHistoryEntry();
    }
    _releaseFocusForViewChange();
    setState(() {
      _viewHistory.clear();
      _rootBackCount = 0;
      _lastRootBackAt = null;
      _selectedIndex = _searchIndex;
    });
  }

  void _openLyrics() {
    Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => const LyricsPage()));
  }

  void _releaseFocusForViewChange() {
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus != null &&
        !identical(primaryFocus, _desktopPlaybackShortcutFocus)) {
      primaryFocus.unfocus(disposition: UnfocusDisposition.scope);
    }
    if (AppPlatform.isDesktop &&
        _desktopPlaybackShortcutFocus.canRequestFocus) {
      _desktopPlaybackShortcutFocus.requestFocus();
    }
  }

  KeyEventResult _handleDesktopPlaybackKey(
    FocusNode shortcutFocus,
    KeyEvent event,
  ) {
    if (!AppPlatform.isDesktop ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }

    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed ||
        !identical(FocusManager.instance.primaryFocus, shortcutFocus)) {
      return KeyEventResult.ignored;
    }

    unawaited(ref.read(playerControllerProvider.notifier).togglePlayPause());
    return KeyEventResult.handled;
  }

  void _handleSystemBack() {
    final strings = ref.read(appStringsProvider);
    if (_selectedIndex == _localIndex &&
        _localMusicNavigationController.maybePop()) {
      return;
    }
    if (_selectedIndex == _libraryIndex &&
        _libraryNavigationController.maybePop()) {
      return;
    }
    if (_selectedIndex == _settingsIndex &&
        _settingsNavigationController.maybePop()) {
      return;
    }
    // The player can be opened directly by a media notification, without a
    // previous in-app tab. Keep Back inside the app in that case.
    if (_selectedIndex == _playerIndex &&
        _restorePreviousView(fallback: _homeIndex)) {
      return;
    }
    if (_restorePreviousView()) {
      return;
    }
    if (_selectedIndex != _homeIndex) {
      _setSelectedIndex(_homeIndex, recordHistory: false);
      return;
    }
    final now = DateTime.now();
    if (_lastRootBackAt == null ||
        now.difference(_lastRootBackAt!) > const Duration(seconds: 2)) {
      _rootBackCount = 0;
    }
    _lastRootBackAt = now;
    _rootBackCount += 1;

    if (_rootBackCount >= 3) {
      SystemNavigator.pop();
      return;
    }

    final remaining = 3 - _rootBackCount;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(milliseconds: 900),
          content: Text(strings.exitPressesRemaining(remaining)),
        ),
      );
  }

  @override
  void dispose() {
    _removePlayerHistoryEntry();
    unawaited(_externalAudioSubscription?.cancel());
    _incomingTrackLinkSubscription?.close();
    _incomingYouTubeMusicLinkSubscription?.close();
    _localMusicNavigationController.dispose();
    _libraryNavigationController.dispose();
    _settingsNavigationController.dispose();
    _desktopPlaybackShortcutFocus.dispose();
    super.dispose();
  }

  bool _restorePreviousView({int? fallback}) {
    int? previous;
    while (_viewHistory.isNotEmpty) {
      final candidate = _viewHistory.removeLast();
      if (candidate != _selectedIndex) {
        previous = candidate;
        break;
      }
    }
    previous ??= fallback;
    final target = previous;
    if (target == null || target == _selectedIndex) {
      return false;
    }

    final leavingPlayer = _isPlayerSelected && target != _playerIndex;
    if (leavingPlayer) {
      _removePlayerHistoryEntry();
    }
    _releaseFocusForViewChange();
    setState(() {
      _selectedIndex = target;
    });
    if (target == _playerIndex) {
      _schedulePlayerHistoryEntry();
    }
    return true;
  }

  void _schedulePlayerHistoryEntry() {
    if (_playerHistoryRegistrationScheduled ||
        _playerHistoryEntry != null ||
        !_isPlayerSelected) {
      return;
    }
    _playerHistoryRegistrationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playerHistoryRegistrationScheduled = false;
      if (mounted) {
        _ensurePlayerHistoryEntry();
      }
    });
  }

  void _ensurePlayerHistoryEntry() {
    if (_playerHistoryEntry != null || !_isPlayerSelected) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route == null) {
      _schedulePlayerHistoryEntry();
      return;
    }

    late final LocalHistoryEntry entry;
    entry = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () => _handlePlayerHistoryRemoval(entry),
    );
    _playerHistoryEntry = entry;
    route.addLocalHistoryEntry(entry);
    // Rebuild PopScope with canPop enabled only after the route owns the local
    // entry. A Back event racing the first frame still uses the explicit Home
    // fallback in _handleSystemBack.
    setState(() {});
  }

  void _handlePlayerHistoryRemoval(LocalHistoryEntry entry) {
    if (identical(_playerHistoryEntry, entry)) {
      _playerHistoryEntry = null;
    }
    if (!mounted || _ignorePlayerHistoryRemoval || !_isPlayerSelected) {
      return;
    }
    _handleSystemBack();
  }

  void _removePlayerHistoryEntry() {
    final entry = _playerHistoryEntry;
    if (entry == null) {
      return;
    }
    _playerHistoryEntry = null;
    _ignorePlayerHistoryRemoval = true;
    try {
      entry.remove();
    } finally {
      _ignorePlayerHistoryRemoval = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final useSideNavigation = width >= 920 && !_usesAndroidNavigation;
    final showBottomNavigation = !useSideNavigation && !_isPlayerSelected;
    final systemBottomInset = _shellSystemBottomInset(context);
    final miniPlayerAppearance = ref.watch(
      settingsControllerProvider.select(
        (settings) => (
          mode: settings.value?.miniPlayerMode ?? defaultMiniPlayerMode,
          backgroundMode:
              settings.value?.miniPlayerBackgroundMode ??
              defaultMiniPlayerBackgroundMode,
        ),
      ),
    );
    final miniPlayerMode = miniPlayerAppearance.mode;
    final transparentSurfaces =
        AppColors.surfaceBackgroundModeFor(context) ==
        SurfaceBackgroundMode.transparent;
    final miniPlayerHeight = miniPlayerHeightFor(context, mode: miniPlayerMode);
    final bottomNavigationHeight = useSideNavigation
        ? 0.0
        : _BottomNavigation.baseHeight(glassyCompact: _usesAndroidNavigation) +
              systemBottomInset;
    final browsingViewportBottomPadding = transparentSurfaces
        ? 0.0
        : bottomNavigationHeight;
    final browsingContentBottomPadding =
        miniPlayerHeight + (transparentSurfaces ? bottomNavigationHeight : 0.0);
    final shellTransitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _shellTransitionDuration;
    final strings = ref.watch(appStringsProvider);
    final destinations = _usesAndroidNavigation
        ? [
            _AppDestination(
              index: _homeIndex,
              icon: Icons.home_rounded,
              label: strings.home,
            ),
            _AppDestination(
              index: _searchIndex,
              icon: Icons.search_rounded,
              label: strings.search,
            ),
            _AppDestination(
              index: _localIndex,
              icon: Icons.folder_rounded,
              label: strings.localTab,
            ),
            _AppDestination(
              index: _libraryIndex,
              icon: Icons.library_music_rounded,
              label: strings.library,
            ),
            _AppDestination(
              index: _settingsIndex,
              icon: Icons.settings_rounded,
              label: strings.settings,
            ),
          ]
        : [
            _AppDestination(
              index: _homeIndex,
              icon: Icons.home_rounded,
              label: strings.home,
            ),
            _AppDestination(
              index: _searchIndex,
              icon: Icons.search_rounded,
              label: strings.search,
            ),
            _AppDestination(
              index: _localIndex,
              icon: Icons.folder_rounded,
              label: strings.localTab,
            ),
            _AppDestination(
              index: _playerIndex,
              icon: Icons.graphic_eq_rounded,
              label: strings.player,
            ),
            _AppDestination(
              index: _libraryIndex,
              icon: Icons.library_music_rounded,
              label: strings.library,
            ),
            _AppDestination(
              index: _settingsIndex,
              icon: Icons.settings_rounded,
              label: strings.settings,
            ),
          ];

    return Focus(
      key: const ValueKey('desktop-playback-keyboard-shortcut'),
      focusNode: _desktopPlaybackShortcutFocus,
      autofocus: AppPlatform.isDesktop,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _handleDesktopPlaybackKey,
      child: PopScope(
        // The player is represented as local route history so native Android
        // Back (including predictive Back) cannot discard the app's root
        // route. Browsing roots keep the existing guarded exit behavior.
        canPop: _isPlayerSelected && _playerHistoryEntry != null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _handleSystemBack();
          }
        },
        child: Scaffold(
          // Keep the body edge-to-edge on Android. The bottom chrome is hosted
          // inside the body so its animation cannot resize the Scaffold.
          extendBody: !useSideNavigation && _usesAndroidNavigation,
          body: SafeArea(
            bottom: false,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: Theme.of(context).brightness == Brightness.dark
                      ? const [
                          Color(0xFF050705),
                          Color(0xFF030403),
                          Color(0xFF070907),
                        ]
                      : const [
                          Color(0xFFF5F8F6),
                          Color(0xFFFFFFFF),
                          Color(0xFFEFF7F1),
                        ],
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedSwitcher(
                    key: const ValueKey('shell-background-transition'),
                    duration: shellTransitionDuration,
                    reverseDuration: shellTransitionDuration,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (currentChild, previousChildren) => Stack(
                      fit: StackFit.expand,
                      children: <Widget>[...previousChildren, ?currentChild],
                    ),
                    child: SizedBox.expand(
                      key: ValueKey(
                        _isPlayerSelected
                            ? 'shell-background-player'
                            : 'shell-background-browsing',
                      ),
                      child: _isPlayerSelected
                          ? const PlayerPlaybackGradientBackground()
                          : const BrowsingTabBackground(),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    bottom: false,
                    child: Row(
                      children: [
                        if (useSideNavigation)
                          _SideNavigation(
                            selectedIndex: _selectedIndex,
                            dimPlaybackBackground: _isPlayerSelected,
                            transitionDuration: shellTransitionDuration,
                            onSelected: _selectIndex,
                            destinations: destinations,
                          ),
                        Expanded(
                          child: ClipRect(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Positioned.fill(
                                  child: _PersistentCurrentViews(
                                    selectedIndex: _selectedIndex,
                                    homeIndex: _homeIndex,
                                    searchIndex: _searchIndex,
                                    localIndex: _localIndex,
                                    playerIndex: _playerIndex,
                                    libraryIndex: _libraryIndex,
                                    settingsIndex: _settingsIndex,
                                    viewportBottomPadding:
                                        browsingViewportBottomPadding,
                                    contentBottomPadding:
                                        browsingContentBottomPadding,
                                    libraryNavigationController:
                                        _libraryNavigationController,
                                    localMusicNavigationController:
                                        _localMusicNavigationController,
                                    settingsNavigationController:
                                        _settingsNavigationController,
                                    onOpenPlayer: _openPlayer,
                                    onOpenSearch: _openSearch,
                                    onAddRemoteTracksToPlaylist:
                                        _addRemoteTracksToPlaylist,
                                  ),
                                ),
                                if (!useSideNavigation)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 0,
                                    child: _ShellVisibilityTransition(
                                      key: const ValueKey(
                                        'bottom-navigation-shell-transition',
                                      ),
                                      clipKey: const ValueKey(
                                        'bottom-navigation-shell-clip',
                                      ),
                                      opacityKey: const ValueKey(
                                        'bottom-navigation-shell-opacity',
                                      ),
                                      visible: showBottomNavigation,
                                      duration: shellTransitionDuration,
                                      child: _BottomNavigation(
                                        selectedIndex: _selectedIndex,
                                        onDestinationSelected: _selectIndex,
                                        destinations: destinations,
                                        glassyCompact: _usesAndroidNavigation,
                                        systemBottomInset: systemBottomInset,
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
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: useSideNavigation ? 0 : bottomNavigationHeight,
                    child: _ShellVisibilityTransition(
                      key: const ValueKey('mini-player-shell-transition'),
                      clipKey: const ValueKey('mini-player-shell-clip'),
                      opacityKey: const ValueKey('mini-player-shell-opacity'),
                      visible: !_isPlayerSelected,
                      duration: shellTransitionDuration,
                      child: SizedBox(
                        height: miniPlayerHeight,
                        child: MiniPlayer(
                          mode: miniPlayerMode,
                          backgroundMode: miniPlayerAppearance.backgroundMode,
                          onOpenPlayer: _openPlayer,
                          onOpenLyrics: _openLyrics,
                        ),
                      ),
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
}

class _ShellVisibilityTransition extends StatelessWidget {
  const _ShellVisibilityTransition({
    required this.visible,
    required this.duration,
    required this.child,
    this.clipKey,
    this.opacityKey,
    super.key,
  });

  final bool visible;
  final Duration duration;
  final Widget child;
  final Key? clipKey;
  final Key? opacityKey;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: visible ? 1 : 0),
          duration: duration,
          curve: Curves.easeOutCubic,
          builder: (context, value, child) {
            return ClipRect(
              key: clipKey,
              child: Opacity(
                key: opacityKey,
                opacity: value,
                child: FractionalTranslation(
                  translation: Offset(0, (1 - value) * 0.08),
                  child: child,
                ),
              ),
            );
          },
          child: child,
        ),
      ),
    );
  }
}

class _AppDestination {
  const _AppDestination({
    required this.index,
    required this.icon,
    required this.label,
  });

  final int index;
  final IconData icon;
  final String label;
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.glassyCompact,
    required this.systemBottomInset,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<_AppDestination> destinations;
  final bool glassyCompact;
  final double systemBottomInset;

  static double baseHeight({required bool glassyCompact}) =>
      glassyCompact ? 72.0 : 78.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transparent =
        AppColors.surfaceBackgroundModeFor(context) ==
        SurfaceBackgroundMode.transparent;
    final content = SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: systemBottomInset),
        child: ConstrainedBox(
          key: const ValueKey('bottom-navigation-content'),
          constraints: BoxConstraints(
            minHeight: baseHeight(glassyCompact: glassyCompact),
          ),
          child: Row(
            children: [
              for (final destination in destinations)
                Expanded(
                  child: _BottomNavigationItem(
                    destinationIndex: destination.index,
                    icon: destination.icon,
                    label: destination.label,
                    selected: selectedIndex == destination.index,
                    onTap: () => onDestinationSelected(destination.index),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (!glassyCompact && !transparent) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surfaceChromeFor(context, accentTintAlpha: 0.06),
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: content,
      );
    }

    return ClipRect(
      key: const ValueKey('bottom-navigation-glass'),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: transparent ? 18 : 32,
          sigmaY: transparent ? 18 : 32,
        ),
        child: DecoratedBox(
          key: const ValueKey('bottom-navigation-surface'),
          decoration: BoxDecoration(
            color: AppColors.surfaceChromeFor(
              context,
              accentModeAlpha: 0.86,
              transparentDarkAlpha: 0.42,
              transparentLightAlpha: 0.5,
              accentTintAlpha: transparent ? 0.05 : 0.06,
            ),
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: content,
        ),
      ),
    );
  }
}

class _BottomNavigationItem extends StatelessWidget {
  const _BottomNavigationItem({
    required this.destinationIndex,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final int destinationIndex;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    final inactive = Theme.of(context).colorScheme.onSurfaceVariant;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);

    return InkWell(
      key: ValueKey('bottom-navigation-item-$destinationIndex'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(appNavItemRadius),
      child: TweenAnimationBuilder<double>(
        key: ValueKey('bottom-navigation-selection-$destinationIndex'),
        tween: Tween<double>(end: selected ? 1 : 0),
        duration: duration,
        curve: Curves.easeOutCubic,
        builder: (context, value, _) {
          final foreground = Color.lerp(inactive, active, value)!;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(22)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Transform.scale(
                  key: ValueKey(
                    'bottom-navigation-icon-scale-$destinationIndex',
                  ),
                  scale: lerpDouble(1, 1.12, value)!,
                  child: Icon(icon, color: foreground, size: 28),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium!.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.lerp(
                      FontWeight.w600,
                      FontWeight.w800,
                      value,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({
    required this.selectedIndex,
    required this.dimPlaybackBackground,
    required this.transitionDuration,
    required this.onSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final bool dimPlaybackBackground;
  final Duration transitionDuration;
  final ValueChanged<int> onSelected;
  final List<_AppDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transparent =
        AppColors.surfaceBackgroundModeFor(context) ==
        SurfaceBackgroundMode.transparent;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: transparent ? 18 : 32,
          sigmaY: transparent ? 18 : 32,
        ),
        child: AnimatedContainer(
          key: const ValueKey('side-navigation-surface'),
          duration: transitionDuration,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: AppColors.surfaceChromeFor(
              context,
              accentModeAlpha: dimPlaybackBackground ? 0.72 : 0.9,
              transparentDarkAlpha: dimPlaybackBackground ? 0.28 : 0.34,
              transparentLightAlpha: dimPlaybackBackground ? 0.34 : 0.42,
              accentTintAlpha: transparent ? 0.05 : 0.06,
            ),
            border: Border(
              right: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: SafeArea(
            right: false,
            child: SizedBox(
              width: 248,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 20, 18, 26),
                    child: _SideNavigationBrand(),
                  ),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: destinations.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final destination = destinations[index];
                        return _SideNavigationItem(
                          destinationIndex: destination.index,
                          icon: destination.icon,
                          label: destination.label,
                          selected: selectedIndex == destination.index,
                          onTap: () => onSelected(destination.index),
                        );
                      },
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
}

class _SideNavigationItem extends StatelessWidget {
  const _SideNavigationItem({
    required this.destinationIndex,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final int destinationIndex;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    final inactive = Theme.of(context).colorScheme.onSurfaceVariant;
    final itemBorderRadius = BorderRadius.circular(10);
    final selectedSurface = AppColors.cardSurfaceFor(context);
    final selectedBorder = AppColors.cardBorderFor(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('side-navigation-item-$destinationIndex'),
        onTap: onTap,
        borderRadius: itemBorderRadius,
        hoverColor: const Color(0x12080A08),
        focusColor: const Color(0x18080A08),
        highlightColor: const Color(0x22080A08),
        child: TweenAnimationBuilder<double>(
          key: ValueKey('side-navigation-selection-$destinationIndex'),
          tween: Tween<double>(end: selected ? 1 : 0),
          duration: duration,
          curve: Curves.easeOutCubic,
          builder: (context, value, _) {
            final foreground = Color.lerp(inactive, active, value)!;
            return Container(
              height: 62,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Color.lerp(Colors.transparent, selectedSurface, value),
                borderRadius: itemBorderRadius,
                border: Border.all(
                  color: Color.lerp(Colors.transparent, selectedBorder, value)!,
                ),
              ),
              child: Row(
                children: [
                  Transform.scale(
                    key: ValueKey(
                      'side-navigation-icon-scale-$destinationIndex',
                    ),
                    scale: lerpDouble(1, 1.12, value)!,
                    child: Icon(icon, color: foreground, size: 28),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall!.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.lerp(
                          FontWeight.w700,
                          FontWeight.w900,
                          value,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SideNavigationBrand extends StatelessWidget {
  const _SideNavigationBrand();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const BStreamLogo(size: 40),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              AppConstants.appName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              strutStyle: const StrutStyle(
                fontSize: 14,
                height: 1.1,
                forceStrutHeight: true,
              ),
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontSize: 15,
                height: 1.1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PersistentCurrentViews extends StatefulWidget {
  const _PersistentCurrentViews({
    required this.selectedIndex,
    required this.homeIndex,
    required this.searchIndex,
    required this.localIndex,
    required this.playerIndex,
    required this.libraryIndex,
    required this.settingsIndex,
    required this.viewportBottomPadding,
    required this.contentBottomPadding,
    required this.libraryNavigationController,
    required this.localMusicNavigationController,
    required this.settingsNavigationController,
    required this.onOpenPlayer,
    required this.onOpenSearch,
    required this.onAddRemoteTracksToPlaylist,
  });

  final int selectedIndex;
  final int homeIndex;
  final int searchIndex;
  final int localIndex;
  final int playerIndex;
  final int libraryIndex;
  final int settingsIndex;
  final double viewportBottomPadding;
  final double contentBottomPadding;
  final LibraryNavigationController libraryNavigationController;
  final LocalMusicNavigationController localMusicNavigationController;
  final SettingsNavigationController settingsNavigationController;
  final VoidCallback onOpenPlayer;
  final VoidCallback onOpenSearch;
  final AddRemoteTracksToPlaylist onAddRemoteTracksToPlaylist;

  @override
  State<_PersistentCurrentViews> createState() =>
      _PersistentCurrentViewsState();
}

class _PersistentCurrentViewsState extends State<_PersistentCurrentViews> {
  late final Set<int> _visitedIndexes = {widget.selectedIndex};

  @override
  void didUpdateWidget(covariant _PersistentCurrentViews oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visitedIndexes.add(widget.selectedIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_visitedIndexes.contains(widget.homeIndex))
          _PersistentViewSlot(
            key: const ValueKey('home-view'),
            selected: widget.selectedIndex == widget.homeIndex,
            bottomPadding: widget.viewportBottomPadding,
            child: _HomeView(
              bottomContentPadding: widget.contentBottomPadding,
              onOpenPlayer: widget.onOpenPlayer,
              onAddRemoteTracksToPlaylist: widget.onAddRemoteTracksToPlaylist,
            ),
          ),
        if (_visitedIndexes.contains(widget.searchIndex))
          _PersistentViewSlot(
            key: const ValueKey('search-view'),
            selected: widget.selectedIndex == widget.searchIndex,
            bottomPadding: widget.viewportBottomPadding,
            child: SearchView(
              bottomContentPadding: widget.contentBottomPadding,
              onOpenPlayer: widget.onOpenPlayer,
              onAddToPlaylist: widget.onAddRemoteTracksToPlaylist,
            ),
          ),
        if (_visitedIndexes.contains(widget.localIndex))
          _PersistentViewSlot(
            key: const ValueKey('local-view'),
            selected: widget.selectedIndex == widget.localIndex,
            bottomPadding: widget.viewportBottomPadding,
            child: LocalMusicPanel(
              bottomContentPadding: widget.contentBottomPadding,
              onOpenPlayer: widget.onOpenPlayer,
              navigationController: widget.localMusicNavigationController,
            ),
          ),
        if (_visitedIndexes.contains(widget.playerIndex))
          _PersistentViewSlot(
            key: const ValueKey('player-view'),
            selected: widget.selectedIndex == widget.playerIndex,
            bottomPadding: 0,
            child: PlayerPanel(
              onOpenSearch: widget.onOpenSearch,
              drawBackground: false,
            ),
          ),
        if (_visitedIndexes.contains(widget.libraryIndex))
          _PersistentViewSlot(
            key: const ValueKey('library-view'),
            selected: widget.selectedIndex == widget.libraryIndex,
            bottomPadding: widget.viewportBottomPadding,
            child: LibraryPanel(
              bottomContentPadding: widget.contentBottomPadding,
              onOpenPlayer: widget.onOpenPlayer,
              navigationController: widget.libraryNavigationController,
            ),
          ),
        if (_visitedIndexes.contains(widget.settingsIndex))
          _PersistentViewSlot(
            key: const ValueKey('settings-view'),
            selected: widget.selectedIndex == widget.settingsIndex,
            bottomPadding: widget.viewportBottomPadding,
            child: SettingsPanel(
              bottomContentPadding: widget.contentBottomPadding,
              active: widget.selectedIndex == widget.settingsIndex,
              navigationController: widget.settingsNavigationController,
            ),
          ),
      ],
    );
  }
}

class _PersistentViewSlot extends StatefulWidget {
  const _PersistentViewSlot({
    required this.selected,
    required this.bottomPadding,
    required this.child,
    super.key,
  });

  final bool selected;
  final double bottomPadding;
  final Widget child;

  @override
  State<_PersistentViewSlot> createState() => _PersistentViewSlotState();
}

class _PersistentViewSlotState extends State<_PersistentViewSlot> {
  bool _hasEntered = false;

  @override
  void initState() {
    super.initState();
    if (widget.selected) {
      _scheduleEntryAnimation();
    } else {
      _hasEntered = true;
    }
  }

  @override
  void didUpdateWidget(covariant _PersistentViewSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected && !oldWidget.selected) {
      setState(() => _hasEntered = false);
      _scheduleEntryAnimation();
    }
  }

  void _scheduleEntryAnimation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() => _hasEntered = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final duration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 320);
    final entered = widget.selected && (_hasEntered || disableAnimations);

    return Positioned.fill(
      child: Padding(
        padding: EdgeInsets.only(bottom: widget.bottomPadding),
        child: IgnorePointer(
          ignoring: !widget.selected,
          child: ExcludeFocus(
            excluding: !widget.selected,
            child: ExcludeSemantics(
              excluding: !widget.selected,
              child: AnimatedOpacity(
                opacity: entered ? 1 : 0,
                duration: duration,
                // A symmetric fade keeps the outgoing view visible while a newly
                // visited, data-heavy tab completes its first frame. An ease-out
                // here made both slots nearly transparent at once and produced a
                // brief dark flash on slower Android devices.
                curve: Curves.easeInOutCubic,
                child: AnimatedSlide(
                  offset: entered ? Offset.zero : const Offset(0.018, 0),
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  child: RepaintBoundary(
                    child: TickerMode(
                      enabled: widget.selected,
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _authenticatedFirstName(YouTubeMusicAuthState state) {
  if (!state.isAuthenticated) {
    return null;
  }
  final displayName = state.profile?.displayName.trim() ?? '';
  if (displayName.isEmpty) {
    return null;
  }
  return displayName.split(RegExp(r'\s+')).first;
}

class _HomeView extends ConsumerWidget {
  const _HomeView({
    required this.bottomContentPadding,
    required this.onOpenPlayer,
    required this.onAddRemoteTracksToPlaylist,
  });

  final double bottomContentPadding;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist onAddRemoteTracksToPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final authState = ref.watch(youtubeMusicAuthControllerProvider);
    final firstName = _authenticatedFirstName(authState);
    final greetingTime = ref.watch(homeGreetingClockProvider)();
    final history = ref.watch(historyProvider);
    final hasHistory = history.value?.isNotEmpty ?? false;
    final recommendationsState = ref.watch(homeRecommendationsProvider);
    final recommendations =
        (recommendationsState.value ?? const <HomeRecommendationSection>[])
            .where((section) => !_isHomeMixSection(section, strings))
            .toList(growable: false);
    final hasPersonalizedContinue = recommendations.any(
      (section) => section.isContinueListening,
    );
    final showLegacyHistory = hasHistory && !hasPersonalizedContinue;
    final libraryTracks =
        ref.watch(libraryTracksProvider).value ?? const <LocalTrack>[];

    return ScrolledUnderTabFrame(
      surfaceKey: const ValueKey('home-tab-header-surface'),
      header: Row(
        children: [
          Expanded(
            child: Text(
              key: const ValueKey('home-tab-title'),
              strings.homeGreeting(
                hour: greetingTime.hour,
                firstName: firstName,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: appTabTitleStyle(context),
            ),
          ),
          SizedBox.square(
            dimension: 48,
            child: IconButton(
              key: const ValueKey('home-recommendations-refresh'),
              tooltip: strings.refreshHomeRecommendations,
              onPressed: recommendationsState.isLoading
                  ? null
                  : () => unawaited(
                      ref.read(homeRecommendationsProvider.notifier).refresh(),
                    ),
              iconSize: 30,
              padding: const EdgeInsets.all(6),
              icon: recommendationsState.isLoading
                  ? SizedBox.square(
                      dimension: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        semanticsLabel: strings.refreshingHomeRecommendations,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ),
          SizedBox.square(
            dimension: 48,
            child: YouTubeMusicAccountButton(strings: strings),
          ),
        ],
      ),
      scrollCacheExtent: const ScrollCacheExtent.pixels(900),
      slivers: [
        if (showLegacyHistory)
          SliverToBoxAdapter(
            child: _HomeRecentSection(
              history: history,
              strings: strings,
              onTrackSelected: (track, queue) {
                final playFuture = ref
                    .read(playerControllerProvider.notifier)
                    .playFromHistory(track, fallbackQueue: queue);
                onOpenPlayer();
                unawaited(playFuture);
              },
            ),
          ),
        if (recommendations.isNotEmpty && showLegacyHistory)
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        for (final section in recommendations)
          SliverToBoxAdapter(
            child: _HomeRemoteRecommendationSection(
              section: section,
              libraryTracks: libraryTracks,
              onOpenPlayer: onOpenPlayer,
              onAddRemoteTracksToPlaylist: onAddRemoteTracksToPlaylist,
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(
            key: const ValueKey('home-scroll-bottom-reserve'),
            height: math.max(96, bottomContentPadding + 20),
          ),
        ),
      ],
    );
  }
}

class _HomeRemoteRecommendationSection extends ConsumerWidget {
  const _HomeRemoteRecommendationSection({
    required this.section,
    required this.libraryTracks,
    required this.onOpenPlayer,
    required this.onAddRemoteTracksToPlaylist,
  });

  final HomeRecommendationSection section;
  final List<LocalTrack> libraryTracks;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist onAddRemoteTracksToPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expandedCards = MediaQuery.sizeOf(context).width >= 700;
    final strings = ref.watch(appStringsProvider);
    final artistOnly = section.items.every(
      (item) => item is HomeRecommendationArtistItem,
    );
    final cardWidth = artistOnly
        ? (expandedCards ? 148.0 : 124.0)
        : (expandedCards ? 176.0 : 148.0);
    return _HomeSection(
      key: ValueKey('home-recommendations-section-${section.title}'),
      title: section.title,
      child: SizedBox(
        key: ValueKey('home-recommendations-shelf-${section.title}'),
        height: _homeShelfHeight(
          context,
          cardWidth: cardWidth,
          minimumHeight: artistOnly
              ? (expandedCards ? 196 : 172)
              : (expandedCards ? 228 : 200),
        ),
        child: ListView.separated(
          scrollCacheExtent: const ScrollCacheExtent.pixels(760),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          scrollDirection: Axis.horizontal,
          itemCount: section.items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final item = section.items[index];
            return switch (item) {
              HomeRecommendationTrackItem() => _RecommendedTrackCard(
                track: item.track,
                localArtworkSource: _localArtworkSourceForRecommendation(item),
                fallbackArtworkSource: _fallbackArtworkSourceForRecommendation(
                  item,
                ),
                width: cardWidth,
                onTap: _trackTap(item, ref),
              ),
              HomeRecommendationCollectionItem(:final collection) =>
                _RecommendedCollectionCard(
                  collection: collection,
                  strings: strings,
                  width: cardWidth,
                  onOpenPlayer: onOpenPlayer,
                  onAddRemoteTracksToPlaylist: onAddRemoteTracksToPlaylist,
                ),
              HomeRecommendationArtistItem(:final artist) =>
                _RecommendedArtistCard(
                  artist: artist,
                  width: cardWidth,
                  onTap: () {
                    final request = (
                      artistBrowseId: artist.browseId,
                      artistName: artist.name,
                      artistThumbnailUrl: artist.thumbnailUrl,
                    );
                    // Start the browse request before the route transition;
                    // the short-lived provider cache lets the destination
                    // attach to the same in-flight operation.
                    unawaited(
                      ref
                          .read(artistProfileProvider(request).future)
                          .then<void>(
                            (_) {},
                            onError: (Object _, StackTrace _) {},
                          ),
                    );
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ArtistProfilePage(
                          artistBrowseId: artist.browseId,
                          artistName: artist.name,
                          artistThumbnailUrl: artist.thumbnailUrl,
                          seedVideoId: artist.seedVideoId,
                          onOpenPlayer: onOpenPlayer,
                        ),
                      ),
                    );
                  },
                ),
            };
          },
        ),
      ),
    );
  }

  VoidCallback? _trackTap(HomeRecommendationTrackItem selected, WidgetRef ref) {
    final localTrack = _localTrackForRecommendation(selected);
    if (section.personalizedKind != null) {
      final recommendationQueue = section.items
          .whereType<HomeRecommendationTrackItem>()
          .map(
            (item) => RecommendationPlaybackItem(
              track: item.track,
              localTrack: _localTrackForRecommendation(item),
            ),
          )
          .toList(growable: false);
      final selectedPlayback = RecommendationPlaybackItem(
        track: selected.track,
        localTrack: localTrack,
      );
      final sourceId =
          section.queueSourceId ??
          'personalized-home:${section.personalizedKind!.name}';
      return () {
        final player = ref.read(playerControllerProvider.notifier);
        RecommendationQueueExtender? queueExtender;
        final service = ref.read(youtubeMusicSearchProvider);
        final link = const BStreamTrackLinkCodec().tryFromTrack(selected.track);
        if (service is YouTubeMusicRelated && link != null) {
          queueExtender = _buildPersonalizedQueueExtender(
            related: service as YouTubeMusicRelated,
            seedVideoId: link.videoId,
            initialQueue: recommendationQueue,
          );
        }
        final playFuture = player.playRecommendation(
          selectedPlayback,
          queue: recommendationQueue,
          queueSourceId: sourceId,
          queueExtender: queueExtender,
        );
        onOpenPlayer();
        unawaited(playFuture);
      };
    }
    if (localTrack != null) {
      return () {
        final localQueue = section.items
            .whereType<HomeRecommendationTrackItem>()
            .map(_localTrackForRecommendation)
            .whereType<LocalTrack>()
            .toList(growable: false);
        final playFuture = ref
            .read(playerControllerProvider.notifier)
            .playLocal(
              localTrack,
              queue: localQueue,
              useNativeQueue: false,
              queueSourceId: section.queueSourceId,
            );
        onOpenPlayer();
        unawaited(playFuture);
      };
    }
    if (selected.track.url.trim().isEmpty) {
      return null;
    }
    return () {
      final remoteQueue = section.items
          .whereType<HomeRecommendationTrackItem>()
          .map((item) => item.track)
          .where((track) => track.url.trim().isNotEmpty)
          .toList(growable: false);
      final playFuture = ref
          .read(playerControllerProvider.notifier)
          .playRemote(
            selected.track,
            queue: remoteQueue,
            queueSourceId: section.queueSourceId,
          );
      onOpenPlayer();
      unawaited(playFuture);
    };
  }

  RecommendationQueueExtender _buildPersonalizedQueueExtender({
    required YouTubeMusicRelated related,
    required String seedVideoId,
    required List<RecommendationPlaybackItem> initialQueue,
  }) {
    final expanded = List<RecommendationPlaybackItem>.of(initialQueue);
    const linkCodec = BStreamTrackLinkCodec();
    final seenVideoIds = initialQueue
        .map((item) => linkCodec.tryFromTrack(item.track)?.videoId)
        .whereType<String>()
        .toSet();
    final requestedContinuations = <String>{};
    String? continuation;
    var needsInitialPage = true;
    var exhausted = false;

    return () async {
      if (exhausted) {
        return List<RecommendationPlaybackItem>.unmodifiable(expanded);
      }

      final previousLength = expanded.length;
      // A continuation can occasionally contain only duplicates from the
      // visible shelf. Follow a small bounded number of pages so one sparse
      // response does not falsely end the radio.
      for (var request = 0; request < 3; request++) {
        if (!needsInitialPage) {
          final token = continuation;
          if (token == null ||
              token.isEmpty ||
              !requestedContinuations.add(token)) {
            exhausted = true;
            break;
          }
        }
        final page = needsInitialPage
            ? await related.getNext(seedVideoId, radio: true, limit: 30)
            : await related.getNextContinuation(continuation!, limit: 30);
        needsInitialPage = false;
        final nextContinuation = page.continuation?.trim();
        continuation = nextContinuation == null || nextContinuation.isEmpty
            ? null
            : nextContinuation;
        for (final song in page.songs) {
          if (!seenVideoIds.add(song.videoId)) {
            continue;
          }
          expanded.add(
            RecommendationPlaybackItem(track: trackInfoFromInnerTubeSong(song)),
          );
        }
        if (continuation == null) {
          exhausted = true;
        }
        if (expanded.length > previousLength || exhausted) {
          break;
        }
      }
      return List<RecommendationPlaybackItem>.unmodifiable(expanded);
    };
  }

  LocalTrack? _localTrackForRecommendation(HomeRecommendationTrackItem item) {
    final localTrackId = item.localTrackId?.trim();
    final recommendationId = item.track.id.trim();
    for (final track in libraryTracks) {
      final sourceId = track.sourceId?.trim();
      if ((localTrackId != null &&
              localTrackId.isNotEmpty &&
              track.id == localTrackId) ||
          (recommendationId.isNotEmpty && sourceId == recommendationId)) {
        return track;
      }
    }
    return null;
  }

  String? _localArtworkSourceForRecommendation(
    HomeRecommendationTrackItem item,
  ) {
    final localTrack = _localTrackForRecommendation(item);
    return _firstHomeArtworkSource([localTrack?.thumbnailPath]);
  }

  String? _fallbackArtworkSourceForRecommendation(
    HomeRecommendationTrackItem item,
  ) {
    final localTrack = _localTrackForRecommendation(item);
    return _firstHomeArtworkSource([
      localTrack?.thumbnailUrl,
      localTrack?.catalogThumbnailUrl,
      item.track.thumbnailUrl,
      item.track.catalogThumbnailUrl,
    ]);
  }
}

bool _isHomeMixSection(HomeRecommendationSection section, AppStrings strings) {
  if (section.personalizedKind == PersonalizedSectionKind.mixes) {
    return true;
  }
  final normalizedTitle = section.title.trim().toLowerCase();
  final yourMixesTitles = <String>{
    strings.yourMixes.trim().toLowerCase(),
    'tus mixes',
    'your mixes',
  };
  return yourMixesTitles.contains(normalizedTitle) &&
      section.items.isNotEmpty &&
      section.items.every(
        (item) =>
            item is HomeRecommendationCollectionItem && item.collection.isMix,
      );
}

class _HomeRecentSection extends StatelessWidget {
  const _HomeRecentSection({
    required this.history,
    required this.strings,
    required this.onTrackSelected,
  });

  final AsyncValue<List<LocalTrack>> history;
  final AppStrings strings;
  final void Function(LocalTrack track, List<LocalTrack> queue) onTrackSelected;

  @override
  Widget build(BuildContext context) {
    final expandedCards = MediaQuery.sizeOf(context).width >= 700;
    final cardWidth = expandedCards ? 176.0 : 148.0;
    return _HomeSection(
      title: strings.recentlyPlayed,
      child: history.when(
        data: (items) {
          final tracks = items.take(10).toList(growable: false);
          if (tracks.isEmpty) {
            return _HomeEmptyText(strings.noRecentSongs);
          }
          return SizedBox(
            key: const ValueKey('home-recent-shelf'),
            height: _homeShelfHeight(
              context,
              cardWidth: cardWidth,
              minimumHeight: expandedCards ? 228 : 200,
            ),
            child: ListView.separated(
              scrollCacheExtent: const ScrollCacheExtent.pixels(760),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              scrollDirection: Axis.horizontal,
              itemCount: tracks.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final track = tracks[index];
                return _RecentTrackCard(
                  track: track,
                  width: cardWidth,
                  onTap: () => onTrackSelected(track, tracks),
                );
              },
            ),
          );
        },
        loading: () => const _HomeLoadingShelf(),
        error: (error, _) => _HomeEmptyText(error.toString()),
      ),
    );
  }
}

class _HomeSection extends StatelessWidget {
  const _HomeSection({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: appTabFirstSectionTopGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: appTabTitleHorizontalPadding,
            ),
            child: AppSectionTitle(
              title,
              key: ValueKey('home-section-title-$title'),
            ),
          ),
          const SizedBox(height: appSectionTitleGap),
          child,
        ],
      ),
    );
  }
}

class _RecommendedTrackCard extends StatelessWidget {
  const _RecommendedTrackCard({
    required this.track,
    required this.width,
    required this.onTap,
    this.localArtworkSource,
    this.fallbackArtworkSource,
  });

  final TrackInfo track;
  final String? localArtworkSource;
  final String? fallbackArtworkSource;
  final double width;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = this.track;
    final remoteArtworkSource =
        fallbackArtworkSource ??
        _firstHomeArtworkSource([
          track.thumbnailUrl,
          track.catalogThumbnailUrl,
        ]);
    return SizedBox(
      key: ValueKey('home-recommendation-${track.id}'),
      width: width,
      child: Material(
        color: AppColors.homeCardSurfaceFor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(appCardRadius),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(appCardRadius),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HomeArtwork(
                  source: localArtworkSource ?? remoteArtworkSource,
                  fallbackSource: localArtworkSource == null
                      ? null
                      : remoteArtworkSource,
                  surfaceKey: ValueKey(
                    'home-recommendation-artwork-${track.id}',
                  ),
                ),
                const SizedBox(height: 8),
                MarqueeText(
                  track.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecommendedArtistCard extends ConsumerWidget {
  const _RecommendedArtistCard({
    required this.artist,
    required this.width,
    required this.onTap,
  });

  final HomeRecommendationArtist artist;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final artworkExtent = width - 16;
    final suppliedThumbnail = artist.thumbnailUrl?.trim();
    final profileRequest = (
      artistBrowseId: artist.browseId,
      artistName: artist.name,
      artistThumbnailUrl: suppliedThumbnail == null || suppliedThumbnail.isEmpty
          ? null
          : suppliedThumbnail,
    );
    // A few fallback artists can arrive after Home's bounded enrichment
    // window. Resolve only visible missing portraits now; this same provider
    // response is reused if the user opens the artist profile.
    final progressiveThumbnail =
        suppliedThumbnail == null || suppliedThumbnail.isEmpty
        ? ref
              .watch(artistProfileProvider(profileRequest))
              .value
              ?.artist
              .thumbnailUrl
        : suppliedThumbnail;
    return SizedBox(
      key: ValueKey('home-artist-${artist.browseId}'),
      width: width,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(appCardRadius),
        child: Semantics(
          button: true,
          label: artist.name,
          child: InkWell(
            key: ValueKey('home-artist-open-${artist.browseId}'),
            borderRadius: BorderRadius.circular(appCardRadius),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Column(
                children: [
                  ClipOval(
                    key: ValueKey('home-artist-artwork-${artist.browseId}'),
                    child: SizedBox.square(
                      dimension: artworkExtent,
                      child: SourceImage(
                        source: progressiveThumbnail,
                        cacheWidth: 384,
                        fallback: ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            Icons.person_rounded,
                            size: artworkExtent * 0.42,
                            color: theme.colorScheme.onSurfaceVariant,
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
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
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
}

class _RecommendedCollectionCard extends StatelessWidget {
  const _RecommendedCollectionCard({
    required this.collection,
    required this.strings,
    required this.width,
    required this.onOpenPlayer,
    required this.onAddRemoteTracksToPlaylist,
  });

  final HomeRecommendationCollection collection;
  final AppStrings strings;
  final double width;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist onAddRemoteTracksToPlaylist;

  @override
  Widget build(BuildContext context) {
    final collection = this.collection;
    final theme = Theme.of(context);
    final rawSubtitle = collection.subtitle?.trim();
    final subtitle = rawSubtitle == null || rawSubtitle.isEmpty
        ? _collectionKindLabel(collection, strings)
        : rawSubtitle;
    return SizedBox(
      key: ValueKey('home-collection-${collection.browseId}'),
      width: width,
      child: Material(
        color: AppColors.homeCardSurfaceFor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(appCardRadius),
        ),
        child: Semantics(
          button: true,
          label: strings.openCollection(collection.title),
          child: InkWell(
            key: ValueKey('home-collection-open-${collection.browseId}'),
            borderRadius: BorderRadius.circular(appCardRadius),
            onTap: () => _openCollection(context, subtitle),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      _HomeArtwork(
                        source: collection.thumbnailUrl,
                        surfaceKey: ValueKey(
                          'home-collection-artwork-${collection.browseId}',
                        ),
                      ),
                      Positioned(
                        right: 7,
                        bottom: 7,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surface.withValues(alpha: 0.88),
                            shape: BoxShape.circle,
                          ),
                          child: const Padding(
                            padding: EdgeInsets.all(7),
                            child: Icon(Icons.chevron_right_rounded, size: 20),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  MarqueeText(
                    collection.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openCollection(BuildContext context, String subtitle) {
    final kind = _collectionKindLabel(collection, strings);
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteCollectionDetailPage(
          title: collection.title,
          subtitle: subtitle,
          artworkSource: collection.thumbnailUrl,
          metadata: subtitle == kind ? const [] : [kind],
          queueSourceId: 'home-collection:${collection.browseId}',
          tracksProvider: collection.isAlbum
              ? homeAlbumTracksProvider(collection.browseId)
              : homeCollectionTracksProvider(collection.browseId),
          emptyMessage: strings.homeCollectionEmpty,
          errorMessage: strings.homeCollectionLoadError,
          onOpenPlayer: onOpenPlayer,
          onAddToPlaylist: onAddRemoteTracksToPlaylist,
        ),
      ),
    );
  }

  String _collectionKindLabel(
    HomeRecommendationCollection collection,
    AppStrings strings,
  ) {
    return switch (collection.kind) {
      HomeRecommendationCollectionKind.mix => strings.mix,
      HomeRecommendationCollectionKind.playlist => strings.playlist,
      HomeRecommendationCollectionKind.album => strings.album,
    };
  }
}

class _RecentTrackCard extends ConsumerWidget {
  const _RecentTrackCard({
    required this.track,
    required this.width,
    required this.onTap,
  });

  final LocalTrack track;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isFavorite = ref.watch(
      favoriteTrackIdsProvider.select((ids) => ids.contains(track.id)),
    );
    return SizedBox(
      key: const ValueKey('home-recent-card'),
      width: width,
      child: Material(
        color: AppColors.homeCardSurfaceFor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(appCardRadius),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(appCardRadius),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    _HomeArtwork(
                      source: track.thumbnailPath ?? track.thumbnailUrl,
                      surfaceKey: ValueKey('home-recent-artwork-${track.id}'),
                    ),
                    if (isFavorite)
                      const Positioned(
                        top: 2,
                        right: 2,
                        child: FavoriteStarBadge(iconSize: 18),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                MarqueeText(
                  track.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeArtwork extends StatelessWidget {
  const _HomeArtwork({
    required this.source,
    required this.surfaceKey,
    this.fallbackSource,
  });

  final String? source;
  final String? fallbackSource;
  final Key surfaceKey;

  @override
  Widget build(BuildContext context) {
    return _HomeArtworkFrame(
      surfaceKey: surfaceKey,
      child: ProportionalArtwork(
        source: source,
        fallbackSource: fallbackSource,
        cacheWidth: 512,
        fallback: const _HomeImageFallback(icon: Icons.music_note_rounded),
      ),
    );
  }
}

class _HomeArtworkFrame extends StatelessWidget {
  const _HomeArtworkFrame({required this.surfaceKey, required this.child});

  final Key surfaceKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      key: surfaceKey,
      aspectRatio: 1,
      child: ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
    );
  }
}

class _HomeImageFallback extends StatelessWidget {
  const _HomeImageFallback({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        icon,
        size: 28,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _HomeEmptyText extends StatelessWidget {
  const _HomeEmptyText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        text,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _HomeLoadingShelf extends StatelessWidget {
  const _HomeLoadingShelf();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 110,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

String? _firstHomeArtworkSource(Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final normalized = candidate?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return normalized;
    }
  }
  return null;
}

double _homeShelfHeight(
  BuildContext context, {
  required double cardWidth,
  required double minimumHeight,
}) {
  final theme = Theme.of(context);
  final textHeight =
      _singleLineTextHeight(
        context,
        theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
      ) +
      _singleLineTextHeight(context, theme.textTheme.bodySmall);
  final artworkExtent = cardWidth - 16;
  final requiredHeight = 16 + artworkExtent + 8 + 2 + textHeight;
  return math.max(minimumHeight, requiredHeight.ceilToDouble());
}

double _singleLineTextHeight(BuildContext context, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: 'Ag', style: style),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}
