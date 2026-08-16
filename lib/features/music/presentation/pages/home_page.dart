import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/utils/image_source.dart';
import '../../../../core/platform/app_platform.dart';
import '../../../../platform_channels/android_external_audio_channel.dart';
import '../../../../services/sharing/bstream_track_link.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../data/datasources/remote_music_datasource.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import '../widgets/bstream_logo.dart';
import '../widgets/favorite_star_badge.dart';
import '../widgets/library_panel.dart';
import '../widgets/mini_player.dart';
import '../widgets/playback_gradient_background.dart';
import '../widgets/player_panel.dart';
import '../widgets/settings_panel.dart';
import '../widgets/source_image.dart';
import 'remote_collection_detail_page.dart';
import 'search_view.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  static const _maxViewHistory = 2;

  int _selectedIndex = 0;
  final List<int> _viewHistory = [];
  final LibraryNavigationController _libraryNavigationController =
      LibraryNavigationController();
  final SettingsNavigationController _settingsNavigationController =
      SettingsNavigationController();
  int _rootBackCount = 0;
  DateTime? _lastRootBackAt;
  StreamSubscription<ExternalAudioRequest>? _externalAudioSubscription;
  ProviderSubscription<AsyncValue<BStreamTrackLink>>?
  _incomingTrackLinkSubscription;
  Future<void> _externalAudioWork = Future<void>.value();
  Future<void> _incomingTrackLinkWork = Future<void>.value();
  final Set<String> _startedExternalAudioRequests = <String>{};
  final Set<String> _reportedIncompleteExternalFolders = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(
      Future.wait([
        ref.read(downloaderWarmupProvider.future),
        ref.read(settingsControllerProvider.future),
      ]).catchError((_) => <Object?>[]),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
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

    final watchUrl = link.youtubeFallbackUri.toString();
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
  int get _playerIndex => _usesAndroidNavigation ? 4 : 2;
  int get _libraryIndex => _usesAndroidNavigation ? 2 : 3;
  int get _settingsIndex => _usesAndroidNavigation ? 3 : 4;

  bool get _isPlayerSelected => _selectedIndex == _playerIndex;
  bool get _usesPlaybackGradient =>
      _selectedIndex == _homeIndex ||
      _selectedIndex == _searchIndex ||
      _selectedIndex == _libraryIndex ||
      _selectedIndex == _settingsIndex;

  void _selectIndex(int index) {
    _setSelectedIndex(index);
  }

  void _setSelectedIndex(int index, {bool recordHistory = true}) {
    if (index == _selectedIndex) {
      return;
    }

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
  }

  void _openPlayer() {
    _setSelectedIndex(_playerIndex);
  }

  void _openSearch() {
    setState(() {
      _viewHistory.clear();
      _rootBackCount = 0;
      _lastRootBackAt = null;
      _selectedIndex = _searchIndex;
    });
  }

  void _openPlaylistFromHome(String playlistId) {
    _libraryNavigationController.openPlaylist(playlistId);
    _setSelectedIndex(_libraryIndex);
  }

  void _handleSystemBack() {
    final strings = ref.read(appStringsProvider);
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
    unawaited(_externalAudioSubscription?.cancel());
    _incomingTrackLinkSubscription?.close();
    _libraryNavigationController.dispose();
    _settingsNavigationController.dispose();
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

    setState(() {
      _selectedIndex = target;
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(desktopMediaSessionProvider);
    final width = MediaQuery.sizeOf(context).width;
    final useSideNavigation = width >= 920 && !_usesAndroidNavigation;
    final showBottomNavigation = !useSideNavigation && !_isPlayerSelected;
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _handleSystemBack();
        }
      },
      child: Scaffold(
        extendBody: showBottomNavigation && _usesAndroidNavigation,
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
                if (_isPlayerSelected)
                  const PlayerPlaybackGradientBackground()
                else if (_usesPlaybackGradient)
                  const PlaybackGradientBackground(),
                SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      if (useSideNavigation)
                        _SideNavigation(
                          selectedIndex: _selectedIndex,
                          dimPlaybackBackground: _isPlayerSelected,
                          onSelected: _selectIndex,
                          destinations: destinations,
                        ),
                      Expanded(
                        child: ClipRect(
                          child: Column(
                            children: [
                              Expanded(
                                child: _PersistentCurrentViews(
                                  selectedIndex: _selectedIndex,
                                  homeIndex: _homeIndex,
                                  searchIndex: _searchIndex,
                                  playerIndex: _playerIndex,
                                  libraryIndex: _libraryIndex,
                                  settingsIndex: _settingsIndex,
                                  libraryNavigationController:
                                      _libraryNavigationController,
                                  settingsNavigationController:
                                      _settingsNavigationController,
                                  onOpenPlayer: _openPlayer,
                                  onOpenSearch: _openSearch,
                                  onOpenPlaylist: _openPlaylistFromHome,
                                ),
                              ),
                              if (!_isPlayerSelected)
                                MiniPlayer(onOpenPlayer: _openPlayer),
                            ],
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
        bottomNavigationBar: !showBottomNavigation
            ? null
            : _BottomNavigation(
                selectedIndex: _selectedIndex,
                onDestinationSelected: _selectIndex,
                destinations: destinations,
                glassyCompact: _usesAndroidNavigation,
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
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<_AppDestination> destinations;
  final bool glassyCompact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = SafeArea(
      top: false,
      child: ConstrainedBox(
        key: const ValueKey('bottom-navigation-content'),
        constraints: BoxConstraints(minHeight: glassyCompact ? 76.0 : 82.0),
        child: Row(
          children: [
            for (final destination in destinations)
              Expanded(
                child: _BottomNavigationItem(
                  icon: destination.icon,
                  label: destination.label,
                  selected: selectedIndex == destination.index,
                  onTap: () => onDestinationSelected(destination.index),
                ),
              ),
          ],
        ),
      ),
    );
    if (!glassyCompact) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
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
        filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.9),
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
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    final inactive = Theme.of(context).colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(22)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: selected ? 1.12 : 1,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: Icon(
                icon,
                color: selected ? active : inactive,
                size: selected ? 31 : 28,
              ),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              style: Theme.of(context).textTheme.labelMedium!.copyWith(
                color: inactive,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({
    required this.selectedIndex,
    required this.dimPlaybackBackground,
    required this.onSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final bool dimPlaybackBackground;
  final ValueChanged<int> onSelected;
  final List<_AppDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(
              alpha: dimPlaybackBackground ? 0.72 : 0.9,
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
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    final inactive = Theme.of(context).colorScheme.onSurfaceVariant;
    final itemBorderRadius = BorderRadius.circular(10);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: itemBorderRadius,
        hoverColor: const Color(0x12080A08),
        focusColor: const Color(0x18080A08),
        highlightColor: const Color(0x22080A08),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.cardSurfaceFor(context)
                : Colors.transparent,
            borderRadius: itemBorderRadius,
            border: Border.all(
              color: selected
                  ? AppColors.cardBorderFor(context)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              AnimatedScale(
                scale: selected ? 1.12 : 1,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: Icon(
                  icon,
                  color: selected ? active : inactive,
                  size: selected ? 31 : 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  style: Theme.of(context).textTheme.titleSmall!.copyWith(
                    color: selected ? active : inactive,
                    fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
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
    required this.playerIndex,
    required this.libraryIndex,
    required this.settingsIndex,
    required this.libraryNavigationController,
    required this.settingsNavigationController,
    required this.onOpenPlayer,
    required this.onOpenSearch,
    required this.onOpenPlaylist,
  });

  final int selectedIndex;
  final int homeIndex;
  final int searchIndex;
  final int playerIndex;
  final int libraryIndex;
  final int settingsIndex;
  final LibraryNavigationController libraryNavigationController;
  final SettingsNavigationController settingsNavigationController;
  final VoidCallback onOpenPlayer;
  final VoidCallback onOpenSearch;
  final ValueChanged<String> onOpenPlaylist;

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
            child: _HomeView(
              onOpenPlayer: widget.onOpenPlayer,
              onOpenPlaylist: widget.onOpenPlaylist,
            ),
          ),
        if (_visitedIndexes.contains(widget.searchIndex))
          _PersistentViewSlot(
            key: const ValueKey('search-view'),
            selected: widget.selectedIndex == widget.searchIndex,
            child: SearchView(onOpenPlayer: widget.onOpenPlayer),
          ),
        if (widget.selectedIndex == widget.playerIndex)
          _PersistentViewSlot(
            key: const ValueKey('player-view'),
            selected: true,
            child: PlayerPanel(
              onOpenSearch: widget.onOpenSearch,
              drawBackground: false,
            ),
          ),
        if (_visitedIndexes.contains(widget.libraryIndex))
          _PersistentViewSlot(
            key: const ValueKey('library-view'),
            selected: widget.selectedIndex == widget.libraryIndex,
            child: LibraryPanel(
              onOpenPlayer: widget.onOpenPlayer,
              navigationController: widget.libraryNavigationController,
            ),
          ),
        if (_visitedIndexes.contains(widget.settingsIndex))
          _PersistentViewSlot(
            key: const ValueKey('settings-view'),
            selected: widget.selectedIndex == widget.settingsIndex,
            child: SettingsPanel(
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
    required this.child,
    super.key,
  });

  final bool selected;
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
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !widget.selected,
        child: ExcludeSemantics(
          excluding: !widget.selected,
          child: AnimatedOpacity(
            opacity: widget.selected && _hasEntered ? 1 : 0,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            child: AnimatedSlide(
              offset: widget.selected && _hasEntered
                  ? Offset.zero
                  : const Offset(0.018, 0),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              child: TickerMode(enabled: widget.selected, child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeView extends ConsumerWidget {
  const _HomeView({required this.onOpenPlayer, required this.onOpenPlaylist});

  final VoidCallback onOpenPlayer;
  final ValueChanged<String> onOpenPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final history = ref.watch(historyProvider);
    final playlists = ref.watch(playlistsControllerProvider);
    final hasHistory = history.value?.isNotEmpty ?? false;
    final hasPlaylists = playlists.value?.isNotEmpty ?? false;
    final recommendationsState = ref.watch(homeRecommendationsProvider);
    final recommendations =
        recommendationsState.value ?? const <HomeRecommendationSection>[];
    final libraryTracks =
        ref.watch(libraryTracksProvider).value ?? const <LocalTrack>[];

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    key: const ValueKey('home-tab-title'),
                    strings.home,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    key: const ValueKey('home-recommendations-refresh'),
                    tooltip: strings.refreshHomeRecommendations,
                    onPressed: recommendationsState.isLoading
                        ? null
                        : () => ref.invalidate(homeRecommendationsProvider),
                    icon: recommendationsState.isLoading
                        ? SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              semanticsLabel:
                                  strings.refreshingHomeRecommendations,
                            ),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasHistory)
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
        if (hasPlaylists) ...[
          if (hasHistory) const SliverToBoxAdapter(child: SizedBox(height: 12)),
          SliverToBoxAdapter(
            child: _HomePlaylistSection(
              playlists: playlists,
              libraryTracks: libraryTracks,
              strings: strings,
              onPlaylistSelected: onOpenPlaylist,
            ),
          ),
        ],
        if (recommendations.isNotEmpty && (hasHistory || hasPlaylists))
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        for (final section in recommendations)
          SliverToBoxAdapter(
            child: _HomeRemoteRecommendationSection(
              section: section,
              onOpenPlayer: onOpenPlayer,
              onTrackSelected: (track, queue) {
                final playFuture = ref
                    .read(playerControllerProvider.notifier)
                    .playRemote(track, queue: queue);
                onOpenPlayer();
                unawaited(playFuture);
              },
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }
}

class _HomeRemoteRecommendationSection extends ConsumerWidget {
  const _HomeRemoteRecommendationSection({
    required this.section,
    required this.onOpenPlayer,
    required this.onTrackSelected,
  });

  final HomeRecommendationSection section;
  final VoidCallback onOpenPlayer;
  final void Function(TrackInfo track, List<TrackInfo> queue) onTrackSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expandedCards = MediaQuery.sizeOf(context).width >= 700;
    final strings = ref.watch(appStringsProvider);
    final trackQueue = section.tracks;
    final cardWidth = expandedCards ? 176.0 : 148.0;
    return _HomeSection(
      key: ValueKey('home-recommendations-section-${section.title}'),
      title: section.title,
      child: SizedBox(
        key: ValueKey('home-recommendations-shelf-${section.title}'),
        height: _homeShelfHeight(
          context,
          cardWidth: cardWidth,
          minimumHeight: expandedCards ? 228 : 200,
        ),
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          scrollDirection: Axis.horizontal,
          itemCount: section.items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final item = section.items[index];
            return switch (item) {
              HomeRecommendationTrackItem(:final track) =>
                _RecommendedTrackCard(
                  track: track,
                  width: cardWidth,
                  onTap: () => onTrackSelected(track, trackQueue),
                ),
              HomeRecommendationCollectionItem(:final collection) =>
                _RecommendedCollectionCard(
                  collection: collection,
                  strings: strings,
                  width: cardWidth,
                  onOpenPlayer: onOpenPlayer,
                ),
            };
          },
        ),
      ),
    );
  }
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

class _HomePlaylistSection extends StatelessWidget {
  const _HomePlaylistSection({
    required this.playlists,
    required this.libraryTracks,
    required this.strings,
    required this.onPlaylistSelected,
  });

  final AsyncValue<List<Playlist>> playlists;
  final List<LocalTrack> libraryTracks;
  final AppStrings strings;
  final ValueChanged<String> onPlaylistSelected;

  @override
  Widget build(BuildContext context) {
    final expandedCards = MediaQuery.sizeOf(context).width >= 700;
    final cardWidth = expandedCards ? 188.0 : 160.0;
    final tracksById = {for (final track in libraryTracks) track.id: track};
    return _HomeSection(
      title: strings.myPlaylists,
      child: playlists.when(
        data: (items) {
          final visible = items.take(10).toList(growable: false);
          if (visible.isEmpty) {
            return _HomeEmptyText(strings.noLocalPlaylists);
          }
          return SizedBox(
            key: const ValueKey('home-playlist-shelf'),
            height: _homeShelfHeight(
              context,
              cardWidth: cardWidth,
              minimumHeight: expandedCards ? 240 : 212,
            ),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              scrollDirection: Axis.horizontal,
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final playlist = visible[index];
                final playlistTracks = playlist.trackIds
                    .map((id) => tracksById[id])
                    .whereType<LocalTrack>()
                    .toList(growable: false);
                return _HomePlaylistCard(
                  playlist: playlist,
                  strings: strings,
                  subtitle: strings.songCountWithDuration(
                    playlistTracks.length,
                    sumKnownDurations(
                      playlistTracks.map((track) => track.duration),
                    ),
                  ),
                  thumbnailSources: _homePlaylistThumbnailSources(
                    playlist,
                    tracksById,
                  ),
                  width: cardWidth,
                  onTap: () => onPlaylistSelected(playlist.id),
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
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
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
  });

  final TrackInfo track;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      key: ValueKey('home-recommendation-${track.id}'),
      width: width,
      child: Material(
        color: AppColors.cardSurfaceFor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HomeArtwork(
                  source: track.thumbnailUrl ?? track.catalogThumbnailUrl,
                ),
                const SizedBox(height: 8),
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
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
  });

  final HomeRecommendationCollection collection;
  final AppStrings strings;
  final double width;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    final collection = this.collection;
    final theme = Theme.of(context);
    final rawSubtitle = collection.subtitle?.trim();
    final subtitle = rawSubtitle == null || rawSubtitle.isEmpty
        ? (collection.isMix ? strings.mix : strings.playlist)
        : rawSubtitle;
    return SizedBox(
      key: ValueKey('home-collection-${collection.browseId}'),
      width: width,
      child: Material(
        color: AppColors.cardSurfaceFor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Semantics(
          button: true,
          label: strings.openCollection(collection.title),
          child: InkWell(
            key: ValueKey('home-collection-open-${collection.browseId}'),
            onTap: () => _openCollection(context, subtitle),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      _HomeArtwork(source: collection.thumbnailUrl),
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
                  Text(
                    collection.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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

  void _openCollection(BuildContext context, String subtitle) {
    final kind = collection.isMix ? strings.mix : strings.playlist;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteCollectionDetailPage(
          title: collection.title,
          subtitle: subtitle,
          artworkSource: collection.thumbnailUrl,
          metadata: subtitle == kind ? const [] : [kind],
          queueSourceId: 'home-collection:${collection.browseId}',
          tracksProvider: homeCollectionTracksProvider(collection.browseId),
          emptyMessage: strings.homeCollectionEmpty,
          errorMessage: strings.homeCollectionLoadError,
          onOpenPlayer: onOpenPlayer,
        ),
      ),
    );
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
        color: AppColors.cardSurfaceFor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: InkWell(
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
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomePlaylistCard extends StatelessWidget {
  const _HomePlaylistCard({
    required this.playlist,
    required this.thumbnailSources,
    required this.subtitle,
    required this.strings,
    required this.width,
    required this.onTap,
  });

  final Playlist playlist;
  final List<String> thumbnailSources;
  final String subtitle;
  final AppStrings strings;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      key: const ValueKey('home-playlist-card'),
      width: width,
      child: Material(
        color: AppColors.cardSurfaceFor(context),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    _HomePlaylistCover(sources: thumbnailSources),
                    if (playlist.isFavorites)
                      const Positioned(
                        top: 2,
                        right: 2,
                        child: FavoriteStarBadge(iconSize: 18),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  playlist.isFavorites ? strings.favorites : playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
  const _HomeArtwork({required this.source});

  final String? source;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 1,
        child: ProportionalArtwork(
          source: source,
          cacheWidth: 640,
          fallback: const _HomeImageFallback(icon: Icons.music_note_rounded),
        ),
      ),
    );
  }
}

class _HomePlaylistCover extends StatelessWidget {
  const _HomePlaylistCover({required this.sources});

  final List<String> sources;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: const AspectRatio(
          aspectRatio: 1,
          child: _HomeImageFallback(icon: Icons.queue_music_rounded),
        ),
      );
    }

    final underlay = sources.skip(1).take(3).toList(growable: false);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            SourceImage(
              source: sources.first,
              cacheWidth: 640,
              fallback: const _HomeImageFallback(
                icon: Icons.queue_music_rounded,
              ),
            ),
            if (underlay.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 34,
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xAA000000)),
                  child: Row(
                    children: [
                      for (final source in underlay)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(1),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: SourceImage(
                                source: source,
                                cacheWidth: 256,
                                fallback: const _HomeImageFallback(
                                  icon: Icons.music_note_rounded,
                                  iconSize: 16,
                                ),
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

class _HomeImageFallback extends StatelessWidget {
  const _HomeImageFallback({required this.icon, this.iconSize = 28});

  final IconData icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        icon,
        size: iconSize,
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

List<String> _homePlaylistThumbnailSources(
  Playlist playlist,
  Map<String, LocalTrack> tracksById,
) {
  final sources = playlist.trackIds
      .map((id) => tracksById[id])
      .whereType<LocalTrack>()
      .map(_homeTrackThumbnailSource)
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

String? _homeTrackThumbnailSource(LocalTrack track) {
  final source = track.thumbnailPath ?? track.thumbnailUrl;
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }

  if (isNetworkImageSource(normalized)) {
    return normalized;
  }

  final file = imageFileFromSource(normalized);
  if (file == null) {
    return null;
  }
  return file.path;
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
