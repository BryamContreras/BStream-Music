import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent, ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dialog.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/widgets/app_shared_widgets.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../core/widgets/liquid_glass_surface.dart';
import '../../../../core/utils/image_source.dart';
import '../../../../core/platform/app_platform.dart';
import '../../../../platform_channels/android_app_activation_channel.dart';
import '../../../../platform_channels/android_external_audio_channel.dart';
import '../../../../services/recommendations/recommendation_feed_models.dart';
import '../../../../services/sharing/bstream_track_link.dart';
import '../../../../services/sharing/youtube_music_link.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../data/datasources/remote_music_datasource.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/usecases/get_track_info.dart';
import '../providers/music_providers.dart';
import '../widgets/bstream_logo.dart';
import '../widgets/favorite_star_badge.dart';
import '../widgets/library_panel.dart';
import '../widgets/local_music_panel.dart';
import '../widgets/lyrics_page_route.dart';
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

bool _supportsNavigationHover(BuildContext context) =>
    switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };

enum HomeInitialDestination { home, player }

typedef HomeGreetingClock = DateTime Function();

/// Wall clock used by Home's greeting. Keeping the function injectable makes
/// morning and afternoon behavior deterministic in tests, while a later Home
/// rebuild still observes the current device time.
final homeGreetingClockProvider = Provider<HomeGreetingClock>(
  (ref) => DateTime.now,
);

final androidExternalAudioRequestsProvider =
    Provider<Stream<ExternalAudioRequest>?>((ref) {
      if (!AppPlatform.isAndroid) {
        return null;
      }
      return androidExternalAudioChannel.requests;
    });

final androidAppActivationsProvider =
    Provider<Stream<AndroidAppActivationEvent>?>((ref) {
      if (!AppPlatform.isAndroid) {
        return null;
      }
      return androidAppActivationChannel.activations;
    });

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
  static const _playerExpansionDuration = Duration(milliseconds: 420);
  static const _bottomNavigationHideTravel = 24.0;
  static const _bottomNavigationShowTravel = 12.0;

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
  // The floating Liquid Glass sheets never overlap once laid out. Sharing
  // their backdrop input lets the engine blur the moving tab only once while
  // every sheet keeps its own wash, refraction rim and painted optics.
  final BackdropKey _liquidGlassChromeBackdropKey = BackdropKey();
  // The mini player crosses the navigation chrome while expanding/collapsing.
  // Keep it out of the sibling group during that transient overlap.
  final BackdropKey _liquidGlassMiniPlayerBackdropKey = BackdropKey();
  final ValueNotifier<bool> _liquidGlassChromeMoving = ValueNotifier(false);
  Timer? _liquidGlassChromeSettleTimer;
  int _rootBackCount = 0;
  DateTime? _lastRootBackAt;
  StreamSubscription<ExternalAudioRequest>? _externalAudioSubscription;
  StreamSubscription<AndroidAppActivationEvent>? _appActivationSubscription;
  ProviderSubscription<AsyncValue<BStreamTrackLink>>?
  _incomingTrackLinkSubscription;
  ProviderSubscription<AsyncValue<YouTubeMusicLink>>?
  _incomingYouTubeMusicLinkSubscription;
  Future<void> _externalAudioWork = Future<void>.value();
  Future<void> _incomingTrackLinkWork = Future<void>.value();
  Future<void> _incomingYouTubeMusicLinkWork = Future<void>.value();
  final Set<String> _startedExternalAudioRequests = <String>{};
  final Set<String> _reportedIncompleteExternalFolders = <String>{};
  int _latestAppEntryGeneration = 0;
  LocalHistoryEntry? _playerHistoryEntry;
  bool _playerHistoryRegistrationScheduled = false;
  bool _ignorePlayerHistoryRemoval = false;
  bool _bottomNavigationRevealed = true;
  double _bottomNavigationScrollTravel = 0;
  int _bottomNavigationScrollDirection = 0;
  bool _bottomNavigationUserScrollActive = false;
  bool _bottomNavigationIgnoringOverscroll = false;

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
    _externalAudioSubscription = ref
        .read(androidExternalAudioRequestsProvider)
        ?.listen(
          _queueExternalAudioRequest,
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('External audio channel failed: $error');
            debugPrintStack(stackTrace: stackTrace);
          },
        );
    _appActivationSubscription = ref
        .read(androidAppActivationsProvider)
        ?.listen(
          _handleAndroidAppActivation,
          onError: (Object error, StackTrace stackTrace) {
            debugPrint('Android app activation channel failed: $error');
            debugPrintStack(stackTrace: stackTrace);
          },
        );
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
    _openPlayerFromExternalEntry();

    final watchUrl = link.youtubeUri.toString();
    final strings = ref.read(appStringsProvider);
    final fallbackTrack = TrackInfo(
      id: link.videoId,
      title: strings.sharedSong,
      artist: 'YouTube',
      url: watchUrl,
      thumbnailUrl: youtubeThumbnailSourceForVideoId(link.videoId),
    );
    final search = ref.read(youtubeMusicSearchProvider);
    final getTrackInfo = ref.read(getTrackInfoProvider);

    if (!mounted) {
      return;
    }
    await ref.read(playerControllerProvider.future);
    if (!mounted) {
      return;
    }
    final controller = ref.read(playerControllerProvider.notifier);
    final playback = controller.playRemote(
      fallbackTrack,
      queueSourceId: 'shared-link:${link.videoId}',
    );
    unawaited(
      _enrichIncomingTrackMetadata(
        link: link,
        watchUrl: watchUrl,
        search: search,
        getTrackInfo: getTrackInfo,
        playback: playback,
      ),
    );
    await playback;
  }

  Future<void> _enrichIncomingTrackMetadata({
    required BStreamTrackLink link,
    required String watchUrl,
    required YouTubeMusicSearch search,
    required GetTrackInfo getTrackInfo,
    required Future<void> playback,
  }) async {
    TrackInfo? resolved;
    if (search case final YouTubeMusicTrackLookup lookup) {
      try {
        final song = await lookup.getSong(link.videoId);
        if (song != null) {
          resolved = trackInfoFromInnerTubeSong(song);
        }
      } catch (error) {
        debugPrint('Shared track InnerTube player lookup failed: $error');
      }
    }

    if (resolved == null && search is YouTubeMusicRelated) {
      try {
        final page = await (search as YouTubeMusicRelated).getNext(
          link.videoId,
          limit: 8,
        );
        for (final song in page.songs) {
          if (song.videoId == link.videoId) {
            resolved = trackInfoFromInnerTubeSong(song);
            break;
          }
        }
      } catch (error) {
        debugPrint('Shared track InnerTube watch-next lookup failed: $error');
      }
    }

    // The playback lookup can fill the same canonical fields when watch-next
    // omits them. Run it only after the audio load settles so metadata work
    // does not compete with active InnerTube stream resolution.
    if (resolved == null) {
      try {
        await playback;
      } catch (_) {
        // Metadata remains useful even when playback itself failed.
      }
      if (!mounted) {
        return;
      }
      final controller = ref.read(playerControllerProvider.notifier);
      if (controller.currentRemoteTrackFor(watchUrl) == null) {
        return;
      }
      try {
        resolved = await getTrackInfo(
          watchUrl,
        ).timeout(const Duration(seconds: 20));
      } catch (error) {
        debugPrint('Shared track extractor metadata lookup failed: $error');
      }
    }

    if (!mounted || resolved == null) {
      return;
    }
    ref
        .read(playerControllerProvider.notifier)
        .enrichCurrentRemoteTrackMetadata(
          resolved.copyWith(id: link.videoId, url: watchUrl),
        );
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
    final isPlaylist = link.kind == YouTubeMusicLinkKind.playlist;
    final title = switch (link.kind) {
      YouTubeMusicLinkKind.album => strings.album,
      YouTubeMusicLinkKind.mix => strings.mix,
      _ => strings.playlist,
    };
    final tracksProvider = isAlbum
        ? homeAlbumTracksProvider(collectionId)
        : isPlaylist
        ? incomingYouTubeMusicPlaylistTracksProvider(collectionId)
        : homeCollectionTracksProvider(collectionId);
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RemoteCollectionDetailPage(
            title: title,
            subtitle: strings.youtubeMusic,
            artworkSource: null,
            metadata: const [],
            queueSourceId: 'incoming-youtube:${link.kind.name}:$collectionId',
            tracksProvider: tracksProvider,
            detailsProvider: isAlbum
                ? null
                : isPlaylist
                ? incomingYouTubeMusicPlaylistDetailProvider(collectionId)
                : homeCollectionDetailProvider(collectionId),
            emptyMessage: strings.homeCollectionEmpty,
            errorMessage: strings.homeCollectionLoadError,
            onOpenPlayer: _openPlayer,
            onAddToPlaylist: _addRemoteTracksToPlaylist,
          ),
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

  void _handleAndroidAppActivation(AndroidAppActivationEvent event) {
    if (!mounted) {
      return;
    }
    if (event.entryGeneration < _latestAppEntryGeneration) {
      return;
    }
    _latestAppEntryGeneration = event.entryGeneration;
    switch (event.activation) {
      case AndroidAppActivation.home:
        _openHomeFromExternalEntry();
        break;
      case AndroidAppActivation.player:
        _openPlayerFromExternalEntry();
        break;
    }
  }

  Future<void> _handleExternalAudioRequest(ExternalAudioRequest request) async {
    if (!mounted) {
      return;
    }
    final isLatestAppEntry =
        request.entryGeneration >= _latestAppEntryGeneration;
    if (request.entryGeneration > _latestAppEntryGeneration) {
      _latestAppEntryGeneration = request.entryGeneration;
    }
    final strings = ref.read(appStringsProvider);
    final tracks = request.toLocalTracks(unknownArtist: strings.unknownArtist);
    final player = ref.read(playerControllerProvider.notifier);

    if (_startedExternalAudioRequests.add(request.requestId)) {
      if (request.openPlayer && isLatestAppEntry) {
        _openPlayerFromExternalEntry();
      }
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

  bool get _usesMobileNavigation =>
      AppPlatform.isMobileTargetPlatform(defaultTargetPlatform);

  int get _homeIndex => 0;
  int get _searchIndex => 1;
  int get _localIndex => 2;
  int get _playerIndex => _usesMobileNavigation ? 5 : 3;
  int get _libraryIndex => _usesMobileNavigation ? 3 : 4;
  int get _settingsIndex => _usesMobileNavigation ? 4 : 5;

  bool get _isPlayerSelected => _selectedIndex == _playerIndex;

  void _selectIndex(int index) {
    _setSelectedIndex(index);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final viewInsetBottom = MediaQuery.viewInsetsOf(context).bottom;
    _resetBottomNavigationScrollIntent();
    _bottomNavigationUserScrollActive = false;
    _bottomNavigationIgnoringOverscroll = false;
    _liquidGlassChromeSettleTimer?.cancel();
    _liquidGlassChromeSettleTimer = null;
    _setLiquidGlassChromeMoving(false);
    if (viewInsetBottom > 0) {
      // Keep the mini player attached to the navigation while the IME changes
      // the usable viewport. Revealing both pieces of chrome also keeps the
      // focused field reachable above the keyboard.
      _bottomNavigationRevealed = true;
    }
  }

  void _resetBottomNavigationScrollIntent() {
    _bottomNavigationScrollTravel = 0;
    _bottomNavigationScrollDirection = 0;
  }

  void _setLiquidGlassChromeMoving(bool moving) {
    if (_liquidGlassChromeMoving.value != moving) {
      _liquidGlassChromeMoving.value = moving;
    }
  }

  Duration _resolvedMotionDuration(Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

  void _beginLiquidGlassChromeMotion() {
    _liquidGlassChromeSettleTimer?.cancel();
    _liquidGlassChromeSettleTimer = null;
    _setLiquidGlassChromeMoving(true);
  }

  void _scheduleLiquidGlassChromeSettled(Duration transitionDuration) {
    _liquidGlassChromeSettleTimer?.cancel();
    _liquidGlassChromeSettleTimer = null;
    if (transitionDuration == Duration.zero) {
      _setLiquidGlassChromeMoving(false);
      return;
    }
    _liquidGlassChromeSettleTimer = Timer(transitionDuration, () {
      _liquidGlassChromeSettleTimer = null;
      if (mounted) {
        _setLiquidGlassChromeMoving(false);
      }
    });
  }

  void _setBottomNavigationRevealed(bool revealed) {
    if (_bottomNavigationRevealed == revealed || !mounted) {
      return;
    }
    final transitionDuration = _resolvedMotionDuration(
      _shellTransitionDuration,
    );
    _beginLiquidGlassChromeMotion();
    setState(() => _bottomNavigationRevealed = revealed);
    _scheduleLiquidGlassChromeSettled(transitionDuration);
  }

  bool _handleBrowsingScroll(ScrollNotification notification) {
    final usesSideNavigation =
        MediaQuery.sizeOf(context).width >= 920 && !_usesMobileNavigation;
    if (_isPlayerSelected ||
        usesSideNavigation ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        MediaQuery.viewInsetsOf(context).bottom > 0) {
      return false;
    }

    final metrics = notification.metrics;
    if (notification is ScrollStartNotification) {
      // Pointer-signal scrolling announces its UserScroll direction just
      // before a ScrollStart without dragDetails; retain that user intent.
      _bottomNavigationUserScrollActive =
          notification.dragDetails != null || _bottomNavigationUserScrollActive;
      _bottomNavigationIgnoringOverscroll = false;
      _resetBottomNavigationScrollIntent();
      if (_bottomNavigationUserScrollActive && metrics.extentBefore <= 1) {
        _setBottomNavigationRevealed(true);
      }
      return false;
    }
    if (notification is UserScrollNotification) {
      _bottomNavigationUserScrollActive =
          notification.direction != ScrollDirection.idle;
      if (!_bottomNavigationUserScrollActive) {
        _resetBottomNavigationScrollIntent();
      }
      if (_bottomNavigationUserScrollActive && metrics.extentBefore <= 1) {
        _setBottomNavigationRevealed(true);
      }
      return false;
    }
    if (notification is ScrollEndNotification) {
      _bottomNavigationUserScrollActive = false;
      _bottomNavigationIgnoringOverscroll = false;
      _resetBottomNavigationScrollIntent();
      return false;
    }
    if (metrics.maxScrollExtent <= 0) {
      _bottomNavigationUserScrollActive = false;
      _bottomNavigationIgnoringOverscroll = false;
      _resetBottomNavigationScrollIntent();
      _setBottomNavigationRevealed(true);
      return false;
    }
    if (notification is OverscrollNotification || metrics.outOfRange) {
      _bottomNavigationIgnoringOverscroll = true;
      _resetBottomNavigationScrollIntent();
      return false;
    }
    if (notification is! ScrollUpdateNotification ||
        _bottomNavigationIgnoringOverscroll ||
        (!_bottomNavigationUserScrollActive &&
            notification.dragDetails == null)) {
      return false;
    }
    if (metrics.extentBefore <= 1) {
      _resetBottomNavigationScrollIntent();
      _setBottomNavigationRevealed(true);
      return false;
    }

    final rawDelta = notification.scrollDelta ?? 0;
    if (rawDelta.abs() < 0.5) {
      return false;
    }
    final towardsEnd = switch (metrics.axisDirection) {
      AxisDirection.down => rawDelta > 0,
      AxisDirection.up => rawDelta < 0,
      AxisDirection.left || AxisDirection.right => false,
    };
    final direction = towardsEnd ? 1 : -1;
    if (_bottomNavigationScrollDirection != direction) {
      _bottomNavigationScrollDirection = direction;
      _bottomNavigationScrollTravel = 0;
    }
    _bottomNavigationScrollTravel += rawDelta.abs();
    final threshold = towardsEnd
        ? _bottomNavigationHideTravel
        : _bottomNavigationShowTravel;
    if (_bottomNavigationScrollTravel >= threshold) {
      _bottomNavigationScrollTravel = 0;
      _setBottomNavigationRevealed(!towardsEnd);
    }
    return false;
  }

  void _setSelectedIndex(
    int index, {
    bool recordHistory = true,
    bool revealBottomNavigation = true,
  }) {
    if (index == _selectedIndex) {
      if (index == _playerIndex) {
        _schedulePlayerHistoryEntry();
      }
      return;
    }

    final leavingPlayer = _isPlayerSelected && index != _playerIndex;
    final enteringPlayer = !_isPlayerSelected && index == _playerIndex;
    final revealsBottomNavigation =
        index != _playerIndex &&
        revealBottomNavigation &&
        !_bottomNavigationRevealed;
    final chromeTransitionDuration = enteringPlayer || leavingPlayer
        ? _resolvedMotionDuration(_playerExpansionDuration)
        : revealsBottomNavigation
        ? _resolvedMotionDuration(_shellTransitionDuration)
        : null;
    if (chromeTransitionDuration != null) {
      _beginLiquidGlassChromeMotion();
    }
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
      if (index != _playerIndex && revealBottomNavigation) {
        _bottomNavigationRevealed = true;
      }
      _resetBottomNavigationScrollIntent();
    });
    if (chromeTransitionDuration != null) {
      _scheduleLiquidGlassChromeSettled(chromeTransitionDuration);
    }
    if (index == _playerIndex) {
      _schedulePlayerHistoryEntry();
    }
  }

  void _openPlayer() {
    _setSelectedIndex(_playerIndex);
  }

  void _openPlayerFromExternalEntry() {
    Navigator.maybeOf(context)?.popUntil((route) => route.isFirst);
    if (_isPlayerSelected) {
      _viewHistory.clear();
      _rootBackCount = 0;
      _lastRootBackAt = null;
      _schedulePlayerHistoryEntry();
      return;
    }
    _releaseFocusForViewChange();
    setState(() {
      _viewHistory.clear();
      _rootBackCount = 0;
      _lastRootBackAt = null;
      _selectedIndex = _playerIndex;
    });
    _schedulePlayerHistoryEntry();
  }

  void _openHomeFromExternalEntry() {
    Navigator.maybeOf(context)?.popUntil((route) => route.isFirst);
    if (_isPlayerSelected) {
      _removePlayerHistoryEntry();
    }
    _releaseFocusForViewChange();
    setState(() {
      _viewHistory.clear();
      _rootBackCount = 0;
      _lastRootBackAt = null;
      _selectedIndex = _homeIndex;
      _bottomNavigationRevealed = true;
      _resetBottomNavigationScrollIntent();
    });
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
      _bottomNavigationRevealed = true;
      _resetBottomNavigationScrollIntent();
    });
  }

  void _openLyrics() {
    Navigator.of(context).push<void>(buildLyricsPageRoute(context));
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
    unawaited(_appActivationSubscription?.cancel());
    _incomingTrackLinkSubscription?.close();
    _incomingYouTubeMusicLinkSubscription?.close();
    _localMusicNavigationController.dispose();
    _libraryNavigationController.dispose();
    _settingsNavigationController.dispose();
    _desktopPlaybackShortcutFocus.dispose();
    _liquidGlassChromeSettleTimer?.cancel();
    _liquidGlassChromeMoving.dispose();
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
      if (target != _playerIndex) {
        _bottomNavigationRevealed = true;
      }
      _resetBottomNavigationScrollIntent();
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
    final useSideNavigation = width >= 920 && !_usesMobileNavigation;
    final showBottomNavigation = !useSideNavigation && !_isPlayerSelected;
    final systemBottomInset = _shellSystemBottomInset(context);
    final defaultMode = defaultMiniPlayerModeForPlatform(
      Theme.of(context).platform,
    );
    final miniPlayerAppearance = ref.watch(
      settingsControllerProvider.select(
        (settings) => (
          mode: settings.value?.miniPlayerMode ?? defaultMode,
          backgroundMode:
              settings.value?.miniPlayerBackgroundMode ??
              defaultMiniPlayerBackgroundMode,
          surfaceMode: settings.value?.surfaceBackgroundMode,
          playerStyle: settings.value?.playerStyle ?? defaultPlayerStyle,
          animatedArtworkEnabled:
              settings.value?.animatedArtworkEnabled ??
              defaultAnimatedArtworkEnabled,
        ),
      ),
    );
    final miniPlayerMode = miniPlayerAppearance.mode;
    final playerStyle = miniPlayerAppearance.playerStyle;
    final animatedArtworkEnabled = miniPlayerAppearance.animatedArtworkEnabled;
    // ThemeExtension modes switch halfway through AnimatedTheme.lerp. Use the
    // persisted setting for structural shell behavior so a scroll gesture
    // cannot briefly choose the non-Liquid hide policy during that animation.
    final surfaceMode =
        miniPlayerAppearance.surfaceMode ??
        AppColors.surfaceBackgroundModeFor(context);
    final transparentSurfaces = surfaceMode.usesBackdrop;
    final miniPlayerHeight = miniPlayerHeightFor(context, mode: miniPlayerMode);
    final bottomNavigationHeight = useSideNavigation
        ? 0.0
        : _BottomNavigation.baseHeight(glassyCompact: _usesMobileNavigation) +
              systemBottomInset;
    final bottomNavigationBaseHeight = useSideNavigation
        ? 0.0
        : _BottomNavigation.baseHeight(glassyCompact: _usesMobileNavigation);
    final browsingViewportBottomPadding = transparentSurfaces
        ? 0.0
        : bottomNavigationHeight;
    final browsingContentBottomPadding =
        miniPlayerHeight + (transparentSurfaces ? bottomNavigationHeight : 0.0);
    final shellTransitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _shellTransitionDuration;
    final playerExpansionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _playerExpansionDuration;
    final strings = ref.watch(appStringsProvider);
    final destinations = _usesMobileNavigation
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
    final useLiquidBottomNavigation =
        surfaceMode.isLiquidGlass && !useSideNavigation;
    _AppDestination destinationAt(int destinationIndex) => destinations
        .firstWhere((destination) => destination.index == destinationIndex);
    final bottomNavigationDestinations = useLiquidBottomNavigation
        ? <_AppDestination>[
            destinationAt(_homeIndex),
            destinationAt(_localIndex),
            destinationAt(_libraryIndex),
            destinationAt(_settingsIndex),
          ]
        : destinations;
    final detachedSearchDestination = useLiquidBottomNavigation
        ? destinationAt(_searchIndex)
        : null;
    final liquidBottomNavigationCollapsed =
        showBottomNavigation &&
        useLiquidBottomNavigation &&
        !_bottomNavigationRevealed;
    final bottomNavigationVisible =
        showBottomNavigation &&
        (useLiquidBottomNavigation || _bottomNavigationRevealed);
    final miniPlayerNavigationOffset =
        !useSideNavigation && !_bottomNavigationRevealed
        ? bottomNavigationBaseHeight
        : 0.0;
    final liquidNavigationHeight = _BottomNavigation.liquidContentHeight(
      glassyCompact: _usesMobileNavigation,
    );
    // Capsule mini players already contribute an 8 px horizontal margin. Keep
    // that transparent margin beside the two navigation controls so the
    // actual glass surfaces retain an even 8 px gap at narrow widths.
    final collapsedMiniPlayerHorizontalInset = liquidBottomNavigationCollapsed
        ? 10.0 +
              liquidNavigationHeight +
              (miniPlayerMode == MiniPlayerMode.capsule ? 0.0 : 8.0)
        : 0.0;

    void selectBottomNavigationDestination(int index) {
      final keepLiquidNavigationCollapsed =
          liquidBottomNavigationCollapsed && index == _searchIndex;
      _setSelectedIndex(
        index,
        revealBottomNavigation: !keepLiquidNavigationCollapsed,
      );
    }

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
          extendBody: !useSideNavigation && _usesMobileNavigation,
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
                    duration: playerExpansionDuration,
                    reverseDuration: playerExpansionDuration,
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
                            transitionDuration: playerExpansionDuration,
                            onSelected: _selectIndex,
                            destinations: destinations,
                          ),
                        Expanded(
                          child: ClipRect(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Positioned.fill(
                                  child:
                                      NotificationListener<ScrollNotification>(
                                        onNotification: _handleBrowsingScroll,
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
                                          playerTransitionDuration:
                                              playerExpansionDuration,
                                          libraryNavigationController:
                                              _libraryNavigationController,
                                          localMusicNavigationController:
                                              _localMusicNavigationController,
                                          settingsNavigationController:
                                              _settingsNavigationController,
                                          playerStyle: playerStyle,
                                          animatedArtworkEnabled:
                                              animatedArtworkEnabled,
                                          onOpenPlayer: _openPlayer,
                                          onCollapsePlayer: _handleSystemBack,
                                          onOpenSearch: _openSearch,
                                          onAddRemoteTracksToPlaylist:
                                              _addRemoteTracksToPlaylist,
                                        ),
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
                                      visible: bottomNavigationVisible,
                                      duration: shellTransitionDuration,
                                      hiddenTranslation: const Offset(0, 1),
                                      preserveBackdropMaterial:
                                          useLiquidBottomNavigation,
                                      child: _BottomNavigation(
                                        selectedIndex: _selectedIndex,
                                        onDestinationSelected:
                                            selectBottomNavigationDestination,
                                        onExpandLiquidNavigation: () =>
                                            _setBottomNavigationRevealed(true),
                                        destinations:
                                            bottomNavigationDestinations,
                                        detachedSearchDestination:
                                            detachedSearchDestination,
                                        liquidGlass: useLiquidBottomNavigation,
                                        liquidCollapsed:
                                            liquidBottomNavigationCollapsed,
                                        backdropGroupKey:
                                            _liquidGlassChromeBackdropKey,
                                        backdropMotion:
                                            _liquidGlassChromeMoving,
                                        transitionDuration:
                                            shellTransitionDuration,
                                        glassyCompact: _usesMobileNavigation,
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
                    // Keep the layout bounds around the complete vertical
                    // travel. A paint-only translation outside a box whose
                    // bottom stayed above the navigation looked correct, but
                    // taps on the compact mini player were rejected by that
                    // ancestor and reached the browsing content underneath.
                    bottom: bottomNavigationHeight - bottomNavigationBaseHeight,
                    child: AnimatedPadding(
                      key: const ValueKey('mini-player-horizontal-inset'),
                      padding: EdgeInsets.symmetric(
                        horizontal: collapsedMiniPlayerHorizontalInset,
                      ),
                      duration: shellTransitionDuration,
                      curve: Curves.easeOutCubic,
                      child: SizedBox(
                        height: miniPlayerHeight + bottomNavigationBaseHeight,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: TweenAnimationBuilder<double>(
                            key: const ValueKey(
                              'mini-player-navigation-offset',
                            ),
                            tween: Tween<double>(
                              end: miniPlayerNavigationOffset,
                            ),
                            duration: shellTransitionDuration,
                            curve: Curves.easeOutCubic,
                            builder: (context, offset, child) =>
                                Transform.translate(
                                  key: const ValueKey(
                                    'mini-player-shell-position',
                                  ),
                                  offset: Offset(0, offset),
                                  child: child,
                                ),
                            child: _ShellVisibilityTransition(
                              key: const ValueKey(
                                'mini-player-shell-transition',
                              ),
                              clipKey: const ValueKey('mini-player-shell-clip'),
                              opacityKey: const ValueKey(
                                'mini-player-shell-opacity',
                              ),
                              visible: !_isPlayerSelected,
                              duration: playerExpansionDuration,
                              hiddenTranslation:
                                  miniPlayerAppearance
                                      .backgroundMode
                                      .isLiquidGlass
                                  ? const Offset(0, 1)
                                  : const Offset(0, 0.36),
                              hiddenScale: 0.94,
                              preserveBackdropMaterial: miniPlayerAppearance
                                  .backgroundMode
                                  .isLiquidGlass,
                              translationKey: const ValueKey(
                                'mini-player-shell-translation',
                              ),
                              scaleKey: const ValueKey(
                                'mini-player-shell-scale',
                              ),
                              child: SizedBox(
                                height: miniPlayerHeight,
                                child: MiniPlayer(
                                  mode: miniPlayerMode,
                                  backgroundMode:
                                      miniPlayerAppearance.backgroundMode,
                                  liquidGlassBackdropGroupKey:
                                      _liquidGlassMiniPlayerBackdropKey,
                                  liquidGlassBackdropMotion:
                                      _liquidGlassChromeMoving,
                                  onOpenPlayer: _openPlayer,
                                  onOpenLyrics: _openLyrics,
                                ),
                              ),
                            ),
                          ),
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
    this.hiddenTranslation = const Offset(0, 0.08),
    this.hiddenScale = 1,
    this.clipKey,
    this.opacityKey,
    this.translationKey,
    this.scaleKey,
    this.preserveBackdropMaterial = false,
    super.key,
  });

  final bool visible;
  final Duration duration;
  final Widget child;
  final Offset hiddenTranslation;
  final double hiddenScale;
  final Key? clipKey;
  final Key? opacityKey;
  final Key? translationKey;
  final Key? scaleKey;
  final bool preserveBackdropMaterial;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(
        excluding: !visible,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: visible ? 1 : 0),
          duration: duration,
          curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
          builder: (context, value, child) {
            final scale = lerpDouble(hiddenScale, 1, value)!;
            final movingChild = FractionalTranslation(
              key: translationKey,
              translation: Offset.lerp(hiddenTranslation, Offset.zero, value)!,
              child: Transform.scale(
                key: scaleKey,
                scaleX: scale,
                // A live backdrop must keep its physical height. Scaling it
                // vertically stretches the captured pixels and flattens the
                // rim while the sheet is moving.
                scaleY: preserveBackdropMaterial ? 1 : scale,
                alignment: Alignment.bottomCenter,
                child: child,
              ),
            );
            return ClipRect(
              key: clipKey,
              // Keep Liquid Glass out of an Opacity save layer: fading the
              // complete BackdropFilter also fades its sampled background and
              // makes the material look like a flat overlay. Its full-height
              // translation exits through this clip instead. Other surface
              // modes retain their established fade.
              child: preserveBackdropMaterial
                  ? KeyedSubtree(key: opacityKey, child: movingChild)
                  : Opacity(
                      key: opacityKey,
                      opacity:
                          1 - math.pow(1 - value.clamp(0.0, 1.0), 3).toDouble(),
                      child: movingChild,
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
    required this.onExpandLiquidNavigation,
    required this.destinations,
    required this.detachedSearchDestination,
    required this.liquidGlass,
    required this.liquidCollapsed,
    required this.backdropGroupKey,
    required this.backdropMotion,
    required this.transitionDuration,
    required this.glassyCompact,
    required this.systemBottomInset,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onExpandLiquidNavigation;
  final List<_AppDestination> destinations;
  final _AppDestination? detachedSearchDestination;
  final bool liquidGlass;
  final bool liquidCollapsed;
  final BackdropKey backdropGroupKey;
  final ValueListenable<bool> backdropMotion;
  final Duration transitionDuration;
  final bool glassyCompact;
  final double systemBottomInset;

  static double baseHeight({required bool glassyCompact}) =>
      glassyCompact ? 72.0 : 78.0;

  static double liquidContentHeight({required bool glassyCompact}) =>
      baseHeight(glassyCompact: glassyCompact) - 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaceMode = AppColors.surfaceBackgroundModeFor(context);
    final transparent = surfaceMode.usesBackdrop;
    final navigationItems = Row(
      children: [
        for (final destination in destinations)
          Expanded(
            child: _BottomNavigationItem(
              destinationIndex: destination.index,
              icon: destination.icon,
              label: destination.label,
              selected: selectedIndex == destination.index,
              onTap: () => onDestinationSelected(destination.index),
              liquidGlass: liquidGlass,
            ),
          ),
      ],
    );
    if (liquidGlass) {
      final radius = BorderRadius.circular(34);
      final liquidHeight = liquidContentHeight(glassyCompact: glassyCompact);
      final homeDestination = destinations.first;
      final contentTransitionDuration = Duration(
        milliseconds: math.min(220, transitionDuration.inMilliseconds),
      );
      final mainContent = AnimatedSwitcher(
        duration: contentTransitionDuration,
        reverseDuration: contentTransitionDuration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: <Widget>[...previousChildren, ?currentChild],
        ),
        child: liquidCollapsed
            ? _LiquidNavigationSelectionLayer(
                key: const ValueKey('bottom-navigation-liquid-collapsed'),
                selectedOrdinal: selectedIndex == homeDestination.index
                    ? 0
                    : -1,
                itemCount: 1,
                transitionDuration: transitionDuration,
                child: SizedBox.expand(
                  child: _BottomNavigationItem(
                    semanticsKey: const ValueKey(
                      'bottom-navigation-collapsed-home',
                    ),
                    semanticsHint: MaterialLocalizations.of(
                      context,
                    ).showMenuTooltip,
                    semanticsExpanded: false,
                    destinationIndex: homeDestination.index,
                    icon: homeDestination.icon,
                    label: homeDestination.label,
                    selected: selectedIndex == homeDestination.index,
                    onTap: onExpandLiquidNavigation,
                    liquidGlass: true,
                    iconOnly: true,
                  ),
                ),
              )
            : _LiquidNavigationSelectionLayer(
                key: const ValueKey('bottom-navigation-liquid-expanded'),
                selectedOrdinal: destinations.indexWhere(
                  (destination) => destination.index == selectedIndex,
                ),
                itemCount: destinations.length,
                transitionDuration: transitionDuration,
                child: navigationItems,
              ),
      );
      final mainGlass = ValueListenableBuilder<bool>(
        valueListenable: backdropMotion,
        child: DecoratedBox(
          key: const ValueKey('bottom-navigation-surface'),
          decoration: BoxDecoration(
            color: AppColors.surfaceChromeFor(context),
            borderRadius: radius,
          ),
          child: SizedBox(
            key: const ValueKey('bottom-navigation-content'),
            child: mainContent,
          ),
        ),
        builder: (context, moving, child) => LiquidGlassSurface(
          key: const ValueKey('bottom-navigation-glass'),
          borderRadius: radius,
          blurSigma: 8,
          intensity: 1,
          backdropGroupKey: backdropGroupKey,
          backdropMotion: moving,
          child: child!,
        ),
      );
      return AnimatedPadding(
        duration: transitionDuration,
        curve: Curves.easeOutCubic,
        padding: liquidCollapsed
            ? EdgeInsets.fromLTRB(10, 0, 10, systemBottomInset + 8)
            : EdgeInsets.fromLTRB(10, 4, 10, systemBottomInset + 4),
        child: SizedBox(
          height: liquidHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final searchExtent = detachedSearchDestination == null
                  ? 0.0
                  : liquidHeight + 8;
              final expandedMainWidth = math.max(
                0.0,
                constraints.maxWidth - searchExtent,
              );
              final collapsedMainWidth = math.min(
                liquidHeight,
                expandedMainWidth,
              );
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: liquidCollapsed ? 0 : 1),
                duration: transitionDuration,
                curve: Curves.easeOutCubic,
                child: mainGlass,
                builder: (context, value, mainGlass) {
                  final mainWidth = lerpDouble(
                    collapsedMainWidth,
                    expandedMainWidth,
                    value,
                  )!;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: mainWidth,
                        // Morph only the geometry. Resampling a live runtime
                        // image filter through a non-identity scale can blur
                        // its thin rim and forces extra GPU work mid-scroll.
                        child: mainGlass,
                      ),
                      const Spacer(),
                      if (detachedSearchDestination case final search?) ...[
                        const SizedBox(width: 8),
                        SizedBox.square(
                          dimension: liquidHeight,
                          child: LiquidGlassSurface(
                            key: const ValueKey(
                              'bottom-navigation-search-glass',
                            ),
                            borderRadius: BorderRadius.circular(
                              liquidHeight / 2,
                            ),
                            blurSigma: 8,
                            intensity: 1,
                            backdropGroupKey: backdropGroupKey,
                            backdropMotion: false,
                            child: DecoratedBox(
                              key: const ValueKey(
                                'bottom-navigation-search-surface',
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceChromeFor(context),
                                shape: BoxShape.circle,
                              ),
                              child: _DetachedSearchButton(
                                destination: search,
                                selected: selectedIndex == search.index,
                                onTap: () =>
                                    onDestinationSelected(search.index),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              );
            },
          ),
        ),
      );
    }
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
          child: navigationItems,
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

    final surface = DecoratedBox(
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
    );
    return ClipRect(
      key: const ValueKey('bottom-navigation-glass'),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: transparent ? 18 : 32,
          sigmaY: transparent ? 18 : 32,
        ),
        child: surface,
      ),
    );
  }
}

/// One persistent convex lens shared by the navigation items.
///
/// It is deliberately paint-only: nesting another [BackdropFilter] inside the
/// main capsule would sample the already filtered sheet and can create the
/// mismatched caps that Android previously showed. The outer surface shader
/// supplies the backdrop-coloured light; this layer adds selection depth and
/// moves as a single piece between slots.
class _LiquidNavigationSelectionLayer extends StatefulWidget {
  const _LiquidNavigationSelectionLayer({
    super.key,
    required this.selectedOrdinal,
    required this.itemCount,
    required this.transitionDuration,
    required this.child,
  });

  final int selectedOrdinal;
  final int itemCount;
  final Duration transitionDuration;
  final Widget child;

  @override
  State<_LiquidNavigationSelectionLayer> createState() =>
      _LiquidNavigationSelectionLayerState();
}

class _LiquidNavigationSelectionLayerState
    extends State<_LiquidNavigationSelectionLayer> {
  late int _lastVisibleOrdinal;

  @override
  void initState() {
    super.initState();
    _lastVisibleOrdinal = math.max(0, widget.selectedOrdinal);
  }

  @override
  void didUpdateWidget(_LiquidNavigationSelectionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedOrdinal >= 0) {
      _lastVisibleOrdinal = widget.selectedOrdinal;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.itemCount <= 0) {
      return widget.child;
    }
    final reducedMotion = widget.transitionDuration == Duration.zero;
    final travelDuration = reducedMotion
        ? Duration.zero
        : const Duration(milliseconds: 360);
    final fadeDuration = reducedMotion
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final colors = Theme.of(context).colorScheme;
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;

    return LayoutBuilder(
      builder: (context, constraints) {
        final slotWidth = constraints.maxWidth / widget.itemCount;
        final ordinal = _lastVisibleOrdinal.clamp(0, widget.itemCount - 1);
        final lens = AnimatedOpacity(
          key: const ValueKey('bottom-navigation-selection-lens-opacity'),
          opacity: widget.selectedOrdinal >= 0 ? 1 : 0,
          duration: fadeDuration,
          curve: Curves.easeOutCubic,
          child: IgnorePointer(
            child: CustomPaint(
              key: const ValueKey('bottom-navigation-selection-lens'),
              painter: _LiquidNavigationSelectionPainter(
                brightness: colors.brightness,
                accent: colors.primary,
                highContrast: highContrast,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            if (widget.itemCount == 1)
              Positioned(
                key: const ValueKey(
                  'bottom-navigation-selection-lens-position',
                ),
                left: 3,
                top: 2,
                right: 3,
                bottom: 2,
                child: lens,
              )
            else
              AnimatedPositioned(
                key: const ValueKey(
                  'bottom-navigation-selection-lens-position',
                ),
                duration: travelDuration,
                curve: Curves.easeOutQuart,
                left: slotWidth * ordinal + 3,
                top: 2,
                bottom: 2,
                width: math.max(0, slotWidth - 6),
                child: lens,
              ),
            widget.child,
          ],
        );
      },
    );
  }
}

class _LiquidNavigationSelectionPainter extends CustomPainter {
  const _LiquidNavigationSelectionPainter({
    required this.brightness,
    required this.accent,
    required this.highContrast,
  });

  final Brightness brightness;
  final Color accent;
  final bool highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final dark = brightness == Brightness.dark;
    final contrast = highContrast ? 1.25 : 1.0;
    final bounds = (Offset.zero & size).deflate(0.75);
    final radius = BorderRadius.circular(bounds.height / 2);
    final shape = radius.toRSuperellipse(bounds);
    final shadowBounds = bounds.shift(const Offset(0, 1.5));

    canvas.drawRSuperellipse(
      radius.toRSuperellipse(shadowBounds),
      Paint()
        ..color = Colors.black.withValues(
          alpha: ((dark ? 0.19 : 0.11) * contrast).clamp(0.0, 0.26),
        )
        ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 4.5),
    );
    canvas.drawRSuperellipse(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: dark ? 0.025 : 0.018),
            Colors.black.withValues(alpha: dark ? 0.13 : 0.075),
          ],
          stops: const [0, 0.48, 1],
        ).createShader(bounds),
    );
    canvas.drawRSuperellipse(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = highContrast ? 1.35 : 1.0
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: dark ? 0.24 : 0.2),
            accent.withValues(alpha: 0.055),
            Colors.black.withValues(alpha: dark ? 0.2 : 0.12),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(bounds),
    );
    final innerBounds = bounds.deflate(1.5);
    if (!innerBounds.isEmpty) {
      canvas.drawRSuperellipse(
        BorderRadius.circular(
          innerBounds.height / 2,
        ).toRSuperellipse(innerBounds),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.65
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              accent.withValues(alpha: dark ? 0.12 : 0.09),
              Colors.transparent,
              accent.withValues(alpha: dark ? 0.065 : 0.045),
            ],
            stops: const [0, 0.56, 1],
          ).createShader(innerBounds),
      );
    }
  }

  @override
  bool shouldRepaint(_LiquidNavigationSelectionPainter oldDelegate) =>
      oldDelegate.brightness != brightness ||
      oldDelegate.accent != accent ||
      oldDelegate.highContrast != highContrast;
}

class _DetachedSearchButton extends StatelessWidget {
  const _DetachedSearchButton({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _AppDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lightLiquidIcon = colors.brightness == Brightness.light;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
    final animatedIcon = TweenAnimationBuilder<double>(
      key: ValueKey('bottom-navigation-selection-${destination.index}'),
      tween: Tween<double>(end: selected ? 1 : 0),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => Transform.scale(
        key: ValueKey('bottom-navigation-icon-scale-${destination.index}'),
        scale: lerpDouble(1, 1.12, value)!,
        child: Icon(
          destination.icon,
          size: 30,
          color: lightLiquidIcon
              ? Colors.black
              : Color.lerp(colors.onSurfaceVariant, colors.primary, value),
        ),
      ),
    );
    final hoverTarget = LiquidGlassHoverTarget(
      key: ValueKey('bottom-navigation-hover-glass-${destination.index}'),
      borderRadius: BorderRadius.circular(32),
      intensity: 0.72,
      // An Android emulator reports the host cursor as a mouse and can leave
      // this droplet latched over a single item. That extra rim intersects the
      // parent capsule and makes one cap look thicker than the Search orb.
      enabled: _supportsNavigationHover(context),
      child: Center(child: animatedIcon),
    );
    return Tooltip(
      message: destination.label,
      excludeFromSemantics: true,
      child: Semantics(
        key: const ValueKey('bottom-navigation-detached-search'),
        label: destination.label,
        button: true,
        selected: selected,
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey('bottom-navigation-item-${destination.index}'),
          onTap: onTap,
          customBorder: const CircleBorder(),
          splashFactory: NoSplash.splashFactory,
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return colors.primary.withValues(alpha: 0.12);
            }
            return Colors.transparent;
          }),
          child: hoverTarget,
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
    required this.liquidGlass,
    this.semanticsKey,
    this.semanticsHint,
    this.semanticsExpanded,
    this.iconOnly = false,
  });

  final int destinationIndex;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool liquidGlass;
  final Key? semanticsKey;
  final String? semanticsHint;
  final bool? semanticsExpanded;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = colors.primary;
    final inactive = colors.onSurfaceVariant;
    final lightLiquidIcon =
        liquidGlass && colors.brightness == Brightness.light;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
    final animatedSelection = TweenAnimationBuilder<double>(
      key: ValueKey('bottom-navigation-selection-$destinationIndex'),
      tween: Tween<double>(end: selected ? 1 : 0),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, _) {
        final foreground = Color.lerp(inactive, active, value)!;
        final iconForeground = lightLiquidIcon ? Colors.black : foreground;
        if (iconOnly) {
          return Center(
            child: Transform.scale(
              key: ValueKey('bottom-navigation-icon-scale-$destinationIndex'),
              scale: lerpDouble(1, 1.12, value)!,
              child: Icon(icon, color: iconForeground, size: 30),
            ),
          );
        }
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(22)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Transform.scale(
                key: ValueKey('bottom-navigation-icon-scale-$destinationIndex'),
                scale: lerpDouble(1, 1.12, value)!,
                child: Icon(icon, color: iconForeground, size: 28),
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
    );
    final scaledSelection = liquidGlass
        ? MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.35,
            child: animatedSelection,
          )
        : animatedSelection;
    final item = liquidGlass
        ? LiquidGlassHoverTarget(
            key: ValueKey('bottom-navigation-hover-glass-$destinationIndex'),
            borderRadius: BorderRadius.circular(iconOnly ? 32 : 22),
            intensity: 0.72,
            // Bottom navigation is touch chrome on Android, including when it
            // is hosted by an emulator with a desktop mouse attached. Keeping
            // hover droplets desktop-only leaves every mobile edge on the
            // same single LiquidGlassSurface.
            enabled: _supportsNavigationHover(context),
            child: scaledSelection,
          )
        : scaledSelection;
    final control = InkWell(
      key: ValueKey('bottom-navigation-item-$destinationIndex'),
      onTap: onTap,
      borderRadius: iconOnly ? null : BorderRadius.circular(appNavItemRadius),
      customBorder: iconOnly ? const CircleBorder() : null,
      splashFactory: liquidGlass ? NoSplash.splashFactory : null,
      overlayColor: liquidGlass
          ? WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return active.withValues(alpha: 0.12);
              }
              return Colors.transparent;
            })
          : null,
      child: item,
    );
    if (!liquidGlass) {
      return control;
    }
    final semantics = Semantics(
      key:
          semanticsKey ??
          ValueKey('bottom-navigation-primary-destination-$destinationIndex'),
      label: label,
      hint: semanticsHint,
      button: true,
      selected: selected,
      expanded: semanticsExpanded,
      onTap: onTap,
      excludeSemantics: true,
      child: control,
    );
    if (!iconOnly) {
      return semantics;
    }
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: semantics,
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
    final surfaceMode = AppColors.surfaceBackgroundModeFor(context);
    final transparent = surfaceMode.usesBackdrop;
    final liquidGlass = surfaceMode.isLiquidGlass;
    const liquidRadius = BorderRadius.horizontal(right: Radius.circular(28));
    final surface = AnimatedContainer(
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
        border: liquidGlass
            ? null
            : Border(
                right: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
        borderRadius: liquidGlass ? liquidRadius : null,
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
    );
    if (surfaceMode.isLiquidGlass) {
      return LiquidGlassSurface(
        key: const ValueKey('side-navigation-liquid-glass'),
        borderRadius: liquidRadius,
        blurSigma: 8,
        intensity: 1,
        edgeTreatment: LiquidGlassEdgeTreatment.none,
        child: surface,
      );
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: transparent ? 18 : 32,
          sigmaY: transparent ? 18 : 32,
        ),
        child: surface,
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
    final liquidGlass = AppColors.surfaceBackgroundModeFor(
      context,
    ).isLiquidGlass;
    final selectedSurface = liquidGlass
        ? Colors.transparent
        : AppColors.cardSurfaceFor(context);
    final selectedBorder = liquidGlass
        ? Colors.transparent
        : AppColors.cardBorderFor(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
    final animatedSelection = TweenAnimationBuilder<double>(
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
                key: ValueKey('side-navigation-icon-scale-$destinationIndex'),
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
    );
    final item = liquidGlass
        ? LiquidGlassHoverTarget(
            key: ValueKey('side-navigation-hover-glass-$destinationIndex'),
            borderRadius: BorderRadius.circular(16),
            intensity: 0.7,
            child: animatedSelection,
          )
        : animatedSelection;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('side-navigation-item-$destinationIndex'),
        onTap: onTap,
        borderRadius: itemBorderRadius,
        hoverColor: liquidGlass ? Colors.transparent : const Color(0x12080A08),
        focusColor: const Color(0x18080A08),
        highlightColor: liquidGlass
            ? Colors.transparent
            : const Color(0x22080A08),
        splashFactory: liquidGlass ? NoSplash.splashFactory : null,
        child: item,
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
    required this.playerTransitionDuration,
    required this.libraryNavigationController,
    required this.localMusicNavigationController,
    required this.settingsNavigationController,
    required this.playerStyle,
    required this.animatedArtworkEnabled,
    required this.onOpenPlayer,
    required this.onCollapsePlayer,
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
  final Duration playerTransitionDuration;
  final LibraryNavigationController libraryNavigationController;
  final LocalMusicNavigationController localMusicNavigationController;
  final SettingsNavigationController settingsNavigationController;
  final PlayerStyle playerStyle;
  final bool animatedArtworkEnabled;
  final VoidCallback onOpenPlayer;
  final VoidCallback onCollapsePlayer;
  final VoidCallback onOpenSearch;
  final AddRemoteTracksToPlaylist onAddRemoteTracksToPlaylist;

  @override
  State<_PersistentCurrentViews> createState() =>
      _PersistentCurrentViewsState();
}

class _PersistentCurrentViewsState extends State<_PersistentCurrentViews> {
  late final Set<int> _visitedIndexes = {widget.selectedIndex};
  late final bool _playerWasInitialDestination;

  @override
  void initState() {
    super.initState();
    _playerWasInitialDestination = widget.selectedIndex == widget.playerIndex;
  }

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
            transitionStyle: _PersistentViewTransitionStyle.player,
            transitionDuration: widget.playerTransitionDuration,
            animateInitialEntry: !_playerWasInitialDestination,
            child: PlayerPanel(
              onOpenSearch: widget.onOpenSearch,
              onCollapse: widget.onCollapsePlayer,
              drawBackground: false,
              style: widget.playerStyle,
              animatedArtworkEnabled: widget.animatedArtworkEnabled,
              trackTransitionsEnabled:
                  widget.selectedIndex == widget.playerIndex,
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

enum _PersistentViewTransitionStyle { tab, player }

class _PersistentViewSlot extends StatefulWidget {
  const _PersistentViewSlot({
    required this.selected,
    required this.bottomPadding,
    required this.child,
    this.transitionStyle = _PersistentViewTransitionStyle.tab,
    this.transitionDuration,
    this.animateInitialEntry = true,
    super.key,
  });

  final bool selected;
  final double bottomPadding;
  final Widget child;
  final _PersistentViewTransitionStyle transitionStyle;
  final Duration? transitionDuration;
  final bool animateInitialEntry;

  @override
  State<_PersistentViewSlot> createState() => _PersistentViewSlotState();
}

class _PersistentViewSlotState extends State<_PersistentViewSlot> {
  bool _hasEntered = false;

  @override
  void initState() {
    super.initState();
    if (widget.selected) {
      // A player restored as the initial destination has no mini-player to
      // expand from. Mount it at rest so its controls never begin below the
      // safe viewport. Later mini/full changes still use the dedicated motion.
      if (!widget.animateInitialEntry) {
        _hasEntered = true;
      } else {
        _scheduleEntryAnimation();
      }
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
        : widget.transitionDuration ?? const Duration(milliseconds: 320);
    final entered = widget.selected && (_hasEntered || disableAnimations);
    final playerTransition =
        widget.transitionStyle == _PersistentViewTransitionStyle.player;
    final hiddenOffset = playerTransition
        ? const Offset(0, 0.045)
        : const Offset(0.018, 0);
    final hiddenScale = playerTransition ? 0.965 : 1.0;

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
                  key: playerTransition
                      ? const ValueKey('player-view-slide-transition')
                      : null,
                  offset: entered ? Offset.zero : hiddenOffset,
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  child: AnimatedScale(
                    key: playerTransition
                        ? const ValueKey('player-view-scale-transition')
                        : null,
                    scale: entered ? 1 : hiddenScale,
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.bottomCenter,
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
      ),
    );
  }
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
              strings.homeGreeting(hour: greetingTime.hour),
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
        color: AppColors.homeCardSurfaceFor(context, solidInLiquidGlass: true),
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
        color: AppColors.homeCardSurfaceFor(context, solidInLiquidGlass: true),
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
