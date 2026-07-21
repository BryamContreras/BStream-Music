import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/image_source.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';
import '../providers/music_providers.dart';
import '../widgets/download_progress_panel.dart';
import '../widgets/bstream_logo.dart';
import '../widgets/favorite_star_badge.dart';
import '../widgets/library_panel.dart';
import '../widgets/mini_player.dart';
import '../widgets/playback_gradient_background.dart';
import '../widgets/player_panel.dart';
import '../widgets/search_input.dart';
import '../widgets/settings_panel.dart';
import '../widgets/track_result_tile.dart';

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
  int _rootBackCount = 0;
  DateTime? _lastRootBackAt;

  @override
  void initState() {
    super.initState();
    unawaited(
      Future.wait([
        ref.read(downloaderWarmupProvider.future),
        ref.read(settingsControllerProvider.future),
      ]).catchError((_) => <Object?>[]),
    );
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
    _libraryNavigationController.dispose();
    super.dispose();
  }

  bool _restorePreviousView({int? fallback}) {
    final previous = _viewHistory.isNotEmpty
        ? _viewHistory.removeLast()
        : fallback;
    if (previous == null || previous == _selectedIndex) {
      return false;
    }

    setState(() {
      _selectedIndex = previous;
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final useSideNavigation = width >= 920 && !_usesAndroidNavigation;
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
        body: SafeArea(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF050705),
                  Color(0xFF030403),
                  Color(0xFF070907),
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
                Row(
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
                                onOpenPlayer: _openPlayer,
                                onOpenSearch: _openSearch,
                                onOpenPlaylist: _openPlaylistFromHome,
                              ),
                            ),
                            if (!_isPlayerSelected)
                              const DownloadProgressPanel(),
                            if (!_isPlayerSelected)
                              MiniPlayer(onOpenPlayer: _openPlayer),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: useSideNavigation
            ? null
            : _isPlayerSelected
            ? null
            : _BottomNavigation(
                selectedIndex: _selectedIndex,
                onDestinationSelected: _selectIndex,
                destinations: destinations,
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
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<_AppDestination> destinations;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF040504),
        border: Border(top: BorderSide(color: Color(0xFF121812))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 82,
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: dimPlaybackBackground
            ? const Color(0xDC040504)
            : const Color(0x66040504),
        border: const Border(right: BorderSide(color: Color(0xFF121812))),
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF101A12) : Colors.transparent,
            borderRadius: itemBorderRadius,
            border: Border.all(
              color: selected ? const Color(0xFF284F32) : Colors.transparent,
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
            selected: widget.selectedIndex == widget.homeIndex,
            child: _HomeView(
              onOpenPlayer: widget.onOpenPlayer,
              onOpenPlaylist: widget.onOpenPlaylist,
            ),
          ),
        if (_visitedIndexes.contains(widget.searchIndex))
          _PersistentViewSlot(
            selected: widget.selectedIndex == widget.searchIndex,
            child: _SearchView(onOpenPlayer: widget.onOpenPlayer),
          ),
        if (widget.selectedIndex == widget.playerIndex)
          _PersistentViewSlot(
            selected: true,
            child: PlayerPanel(
              onOpenSearch: widget.onOpenSearch,
              drawBackground: false,
            ),
          ),
        if (_visitedIndexes.contains(widget.libraryIndex))
          _PersistentViewSlot(
            selected: widget.selectedIndex == widget.libraryIndex,
            child: LibraryPanel(
              onOpenPlayer: widget.onOpenPlayer,
              navigationController: widget.libraryNavigationController,
            ),
          ),
        if (_visitedIndexes.contains(widget.settingsIndex))
          _PersistentViewSlot(
            selected: widget.selectedIndex == widget.settingsIndex,
            child: const SettingsPanel(),
          ),
      ],
    );
  }
}

class _PersistentViewSlot extends StatelessWidget {
  const _PersistentViewSlot({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !selected,
        child: ExcludeSemantics(
          excluding: !selected,
          child: AnimatedOpacity(
            opacity: selected ? 1 : 0,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            child: AnimatedSlide(
              offset: selected ? Offset.zero : const Offset(0.018, 0),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              child: TickerMode(enabled: selected, child: child),
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
    final libraryTracks =
        ref.watch(libraryTracksProvider).value ?? const <LocalTrack>[];

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
            child: Text(
              strings.home,
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _HomeRecentSection(
            history: history,
            strings: strings,
            onTrackSelected: (track, queue) {
              final playFuture = ref
                  .read(playerControllerProvider.notifier)
                  .playLocal(track, queue: queue);
              onOpenPlayer();
              unawaited(playFuture);
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        SliverToBoxAdapter(
          child: _HomePlaylistSection(
            playlists: playlists,
            libraryTracks: libraryTracks,
            strings: strings,
            onPlaylistSelected: onOpenPlaylist,
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
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
    return _HomeSection(
      title: strings.recentlyPlayed,
      child: history.when(
        data: (items) {
          final tracks = items.take(10).toList(growable: false);
          if (tracks.isEmpty) {
            return _HomeEmptyText(strings.noRecentSongs);
          }
          return SizedBox(
            height: 184,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              scrollDirection: Axis.horizontal,
              itemCount: tracks.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final track = tracks[index];
                return _RecentTrackCard(
                  track: track,
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
            height: 196,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              scrollDirection: Axis.horizontal,
              itemCount: visible.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final playlist = visible[index];
                return _HomePlaylistCard(
                  playlist: playlist,
                  strings: strings,
                  thumbnailSources: _homePlaylistThumbnailSources(
                    playlist,
                    tracksById,
                  ),
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
  const _HomeSection({required this.title, required this.child});

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
                color: const Color(0xFFF1FFF5),
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

class _RecentTrackCard extends ConsumerWidget {
  const _RecentTrackCard({required this.track, required this.onTap});

  final LocalTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFavorite = ref.watch(
      favoriteTrackIdsProvider.select((ids) => ids.contains(track.id)),
    );
    return SizedBox(
      width: 132,
      child: Material(
        color: const Color(0xA0080A08),
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
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
    required this.strings,
    required this.onTap,
  });

  final Playlist playlist;
  final List<String> thumbnailSources;
  final AppStrings strings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 144,
      child: Material(
        color: const Color(0xA0080A08),
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
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  strings.songCount(playlist.trackIds.length),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
        child: _HomeImage(
          source: source,
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
            _HomeImage(
              source: sources.first,
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
                              child: _HomeImage(
                                source: source,
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

class _HomeImage extends StatelessWidget {
  const _HomeImage({required this.source, required this.fallback});

  final String? source;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return fallback;
    }

    if (isNetworkImageSource(normalized)) {
      return Image.network(
        normalized,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      );
    }

    final file = imageFileFromSource(normalized);
    if (file == null || !file.existsSync()) {
      return fallback;
    }
    return Image.file(
      File(file.path),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback,
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
      color: const Color(0xFF202520),
      child: Icon(icon, size: iconSize),
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
  if (file == null || !file.existsSync()) {
    return null;
  }
  return file.path;
}

class _SearchView extends ConsumerWidget {
  const _SearchView({required this.onOpenPlayer});

  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(searchControllerProvider);
    final strings = ref.watch(appStringsProvider);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    strings.searchTitle,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: SearchInput(
                    hintText: strings.searchHint,
                    tooltip: strings.search,
                    onSubmitted: (query) => ref
                        .read(searchControllerProvider.notifier)
                        .submit(query),
                  ),
                ),
              ],
            ),
          ),
        ),
        results.when(
          data: (tracks) {
            if (tracks.isEmpty) {
              return SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyState(
                  icon: Icons.album_rounded,
                  title: strings.searchEmptyTitle,
                  subtitle: strings.searchEmptySubtitle,
                ),
              );
            }
            return SliverPadding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 18),
              sliver: SliverList.separated(
                itemCount: tracks.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  return TrackResultTile(
                    track: tracks[index],
                    onOpenPlayer: onOpenPlayer,
                  );
                },
              ),
            );
          },
          loading: () => const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyState(
              icon: Icons.error_outline_rounded,
              title: strings.searchErrorTitle,
              subtitle: error.toString(),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
