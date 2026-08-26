import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dialog.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/utils/image_source.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../services/downloader/audio_stream_resolver.dart';
import '../../../../services/player/player_service.dart';
import '../../../../services/sharing/bstream_track_link.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import '../pages/artist_profile_page.dart';
import '../pages/remote_collection_detail_page.dart';
import 'favorite_star_badge.dart';
import 'glass_popup_menu_button.dart';
import 'lyrics_page.dart';
import 'now_playing_equalizer.dart';
import 'playback_gradient_background.dart';
import 'playlist_artwork.dart';
import 'playlist_picker_dialog.dart';
import 'source_image.dart';
import 'track_change_transition.dart';

class PlayerPanel extends ConsumerStatefulWidget {
  const PlayerPanel({this.onOpenSearch, this.drawBackground = true, super.key});

  final VoidCallback? onOpenSearch;
  final bool drawBackground;

  @override
  ConsumerState<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends ConsumerState<PlayerPanel> {
  static const _mobileArtworkMaxReduction = 20.0;
  static const _mobileArtworkComfortHeight = 680.0;
  static const _mobileArtworkExtentCeiling = 400.0;
  static const _mobileArtworkShadowCompressionRange = 100.0;
  static const _mobileArtworkShadowActivationRange = 0.2;
  static const _mobileFrameComfortHeight = 820.0;
  static const _mobileFrameCompressionRange = 100.0;

  bool _showPlaybackQueue = false;
  bool _artistNavigationBusy = false;
  bool _albumNavigationBusy = false;
  final Map<String, _AlbumNavigationTarget> _albumNavigationTargets = {};
  final Set<String> _albumNavigationMisses = {};

  @override
  Widget build(BuildContext context) {
    final presentation = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot =
            player.value ?? const PlayerSnapshot(status: PlayerStatus.idle);
        final rawError = player.error ?? snapshot.errorMessage;
        return (
          status: snapshot.status,
          title: snapshot.title,
          artist: snapshot.artist,
          album: snapshot.album,
          trackId: snapshot.trackId,
          sourceUrl: snapshot.sourceUrl,
          thumbnailUrl: snapshot.thumbnailUrl,
          duration: snapshot.duration,
          volume: snapshot.volume,
          errorMessage: snapshot.errorMessage,
          isRemote: snapshot.isRemote,
          isExternal: snapshot.isExternal,
          shuffleEnabled: snapshot.shuffleEnabled,
          repeatMode: snapshot.repeatMode,
          hasError:
              player.hasError ||
              snapshot.status == PlayerStatus.failed ||
              snapshot.errorMessage?.trim().isNotEmpty == true,
          errorText: rawError == null
              ? null
              : readableAudioStreamError(rawError),
        );
      }),
    );
    final strings = ref.watch(appStringsProvider);
    final playbackQueue = ref.watch(playbackQueueProvider);
    final favoriteTrackIds = ref.watch(favoriteTrackIdsProvider);
    final localTracks =
        ref.watch(libraryTracksProvider).value ?? const <LocalTrack>[];
    final savedTrack = _savedTrackForSnapshot(
      localTracks,
      trackId: presentation.trackId,
      sourceUrl: presentation.sourceUrl,
    );
    final savedTrackId = savedTrack?.id;
    final currentTrackId = presentation.trackId;
    final isFavorite =
        (currentTrackId != null && favoriteTrackIds.contains(currentTrackId)) ||
        (savedTrackId != null && favoriteTrackIds.contains(savedTrackId));
    final snapshot = PlayerSnapshot(
      status: presentation.status,
      title: presentation.title,
      artist: presentation.artist,
      album: presentation.album,
      trackId: presentation.trackId,
      sourceUrl: presentation.sourceUrl,
      thumbnailUrl: presentation.thumbnailUrl,
      duration: presentation.duration,
      volume: presentation.volume,
      errorMessage: presentation.errorMessage,
      isRemote: presentation.isRemote,
      isExternal: presentation.isExternal,
      shuffleEnabled: presentation.shuffleEnabled,
      repeatMode: presentation.repeatMode,
    );
    final localArtwork = savedTrack == null
        ? null
        : preferredLocalTrackArtworkSource(savedTrack);
    final artworkSource = localArtwork?.source ?? snapshot.thumbnailUrl;
    final artworkFallbackSource = localArtwork?.fallbackSource;
    final visualIdentity = playbackVisualIdentity(
      trackId: snapshot.trackId,
      sourceUrl: snapshot.sourceUrl,
      title: snapshot.title,
      artist: snapshot.artist,
      thumbnailUrl: artworkSource,
    );
    final hasTrack =
        snapshot.title != null ||
        snapshot.artist != null ||
        presentation.hasError;
    final canOpenArtist =
        !snapshot.isExternal && snapshot.artist?.trim().isNotEmpty == true;
    final onOpenArtist = canOpenArtist
        ? () => unawaited(_openArtist(snapshot, savedTrackId))
        : null;
    final albumTrack = snapshot.isExternal
        ? null
        : _shareTrackForSnapshot(
            snapshot,
            ref,
            strings,
            savedTrackId: savedTrackId,
          );
    final hasYouTubeMusicMetadata =
        albumTrack != null && _hasYouTubeMusicCatalogMetadata(albumTrack);
    final albumTitle = hasYouTubeMusicMetadata
        ? _preferredAlbumTitle(albumTrack.album, snapshot.album)
        : null;
    final albumNavigationKey = !hasYouTubeMusicMetadata
        ? null
        : _albumNavigationKey(albumTrack, albumTitle);
    final onOpenAlbum = albumNavigationKey == null
        ? null
        : () => unawaited(
            _openAlbumForTrack(
              key: albumNavigationKey,
              track: albumTrack!,
              albumTitle: albumTitle,
            ),
          );

    return LayoutBuilder(
      builder: (context, outer) {
        final wide = outer.maxWidth >= 840;
        final mobile = Theme.of(context).platform == TargetPlatform.android;
        final stackedDesktop = AppPlatform.isDesktop && wide;
        final showSideQueue = AppPlatform.isDesktop && _showPlaybackQueue;
        final disableAnimations = MediaQuery.disableAnimationsOf(context);
        final queueTransitionDuration = disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 320);
        final systemBottomInset = math.max(
          MediaQuery.viewPaddingOf(context).bottom,
          MediaQuery.paddingOf(context).bottom,
        );
        final mobileFrameCompactness = mobile
            ? ((_mobileFrameComfortHeight -
                          (outer.maxHeight - systemBottomInset)) /
                      _mobileFrameCompressionRange)
                  .clamp(0.0, 1.0)
            : 0.0;
        final heightCompactness = AppPlatform.isDesktop
            ? ((680.0 - outer.maxHeight) / 140.0).clamp(0.0, 1.0)
            : 0.0;
        final regularTopPadding = wide
            ? (showSideQueue ? 12.0 : 20.0)
            : mobile
            // Keep short phones from pushing the header down while leaving
            // the roomy layout unchanged. The extra top space is reserved
            // for the system/header chrome, not the artwork metadata.
            ? lerpDouble(10, 12, mobileFrameCompactness)!
            : 10.0;
        final regularBottomPadding = mobile
            ? 16.0 + systemBottomInset
            : wide
            ? (showSideQueue ? 12.0 : 24.0)
            : 20.0 + systemBottomInset;
        final horizontalContentPadding = wide
            ? (showSideQueue ? 16.0 : 34.0)
            : 20.0;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              key: const ValueKey('desktop-player-surface'),
              child: Stack(
                children: [
                  if (widget.drawBackground) ...[
                    _BlurredPlayerBackground(
                      url: artworkSource,
                      fallbackUrl: artworkFallbackSource,
                    ),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: playerPlaybackOverlayColors(context),
                            stops: const [0, 0.38, 0.72, 1],
                          ),
                        ),
                      ),
                    ),
                  ],
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalContentPadding,
                      lerpDouble(regularTopPadding, 8, heightCompactness)!,
                      horizontalContentPadding,
                      lerpDouble(regularBottomPadding, 8, heightCompactness)!,
                    ),
                    child: Column(
                      children: [
                        _PlayerHeader(
                          snapshot: snapshot,
                          isFavorite: isFavorite,
                          savedTrackId: savedTrackId,
                          onOpenSearch: widget.onOpenSearch,
                          queueVisible: showSideQueue,
                          onToggleQueue: () {
                            if (mobile) {
                              unawaited(_openMobilePlaybackQueue(context));
                              return;
                            }
                            setState(() {
                              _showPlaybackQueue = !_showPlaybackQueue;
                            });
                          },
                          onOpenArtist: onOpenArtist,
                          onOpenAlbum: onOpenAlbum,
                          strings: strings,
                        ),
                        Expanded(
                          child: LayoutBuilder(
                            key: const ValueKey('player-content-layout'),
                            builder: (context, constraints) {
                              final verticalCompactness = AppPlatform.isDesktop
                                  ? ((620.0 - constraints.maxHeight) / 140.0)
                                        .clamp(0.0, 1.0)
                                  : 0.0;
                              final regularArtworkExtent = _artworkExtent(
                                constraints,
                                stackedDesktop: stackedDesktop,
                                wide: wide,
                                mobile: mobile,
                                compactness: verticalCompactness,
                                mobileFrameCompactness: mobileFrameCompactness,
                              );
                              final artworkExtent = mobile
                                  ? _mobileArtworkExtent(
                                      constraints: constraints,
                                      regularExtent: regularArtworkExtent,
                                      hasError: presentation.hasError,
                                    )
                                  : regularArtworkExtent;
                              // A short, narrow phone can make the cover
                              // width-bound before the frame-height factor is
                              // large enough to shrink its halo. Once the
                              // mobile layout has entered its compact range,
                              // include that measured cover reduction so the
                              // shadow follows the artwork proportionally.
                              // Roomy mobile frames retain the original
                              // shadow values exactly.
                              final mobileArtworkShadowActivation = mobile
                                  ? (mobileFrameCompactness /
                                            _mobileArtworkShadowActivationRange)
                                        .clamp(0.0, 1.0)
                                  : 0.0;
                              final mobileArtworkShadowCompactness =
                                  ((_mobileArtworkExtentCeiling -
                                              artworkExtent) /
                                          _mobileArtworkShadowCompressionRange)
                                      .clamp(0.0, 1.0) *
                                  mobileArtworkShadowActivation;
                              final artworkShadowCompactness = math.max(
                                verticalCompactness,
                                math.max(
                                  mobileFrameCompactness,
                                  mobileArtworkShadowCompactness,
                                ),
                              );
                              final maxContentWidth = stackedDesktop
                                  ? showSideQueue
                                        ? constraints.maxWidth
                                        : math
                                              .min(
                                                constraints.maxWidth * 0.84,
                                                1040.0,
                                              )
                                              .clamp(700.0, 1040.0)
                                              .toDouble()
                                  : 520.0;
                              final artworkCanvasWidth = math.min(
                                constraints.maxWidth,
                                maxContentWidth,
                              );
                              final artworkHorizontalClearance = math.max(
                                0.0,
                                (artworkCanvasWidth - artworkExtent) / 2,
                              );
                              final artwork = Center(
                                child: _LargeArtwork(
                                  url: artworkSource,
                                  fallbackUrl: artworkFallbackSource,
                                  identity: visualIdentity,
                                  maxExtent: artworkExtent,
                                  isFavorite: isFavorite,
                                  shadowCompactness: artworkShadowCompactness,
                                  shadowHorizontalClearance:
                                      artworkHorizontalClearance,
                                ),
                              );
                              final gap = mobile
                                  ? lerpDouble(22, 26, mobileFrameCompactness)!
                                  : lerpDouble(26, 12, verticalCompactness)!;
                              final controls = _PlayerControls(
                                snapshot: snapshot,
                                hasTrack: hasTrack,
                                isFavorite: isFavorite,
                                savedTrackId: savedTrackId,
                                hasError: presentation.hasError,
                                errorText: presentation.errorText,
                                compact: !wide || stackedDesktop,
                                compactness: verticalCompactness,
                                maxWidth: stackedDesktop
                                    ? maxContentWidth
                                    : 520.0,
                                onOpenLyrics: _openLyrics,
                                onOpenArtist: onOpenArtist,
                                strings: strings,
                              );

                              return SingleChildScrollView(
                                key: const ValueKey('player-content-scroll'),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight,
                                  ),
                                  child: Align(
                                    alignment: mobile
                                        ? Alignment.bottomCenter
                                        : Alignment.center,
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: maxContentWidth,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          artwork,
                                          SizedBox(
                                            key: const ValueKey(
                                              'player-artwork-title-gap',
                                            ),
                                            height: gap,
                                          ),
                                          controls,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            AnimatedSwitcher(
              key: const ValueKey('desktop-playback-queue-switcher'),
              duration: queueTransitionDuration,
              reverseDuration: queueTransitionDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (currentChild, previousChildren) => Stack(
                alignment: Alignment.centerRight,
                children: <Widget>[...previousChildren, ?currentChild],
              ),
              transitionBuilder: (child, animation) => ClipRect(
                child: FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    axis: Axis.horizontal,
                    alignment: Alignment.centerRight,
                    sizeFactor: animation,
                    child: child,
                  ),
                ),
              ),
              child: showSideQueue
                  ? SizedBox(
                      key: const ValueKey('desktop-playback-queue-rail'),
                      width: outer.maxWidth >= 1180 ? 400 : 352,
                      child: _PlaybackQueuePanel(
                        queue: playbackQueue,
                        strings: strings,
                        standaloneRail: true,
                        onClose: () {
                          setState(() => _showPlaybackQueue = false);
                        },
                      ),
                    )
                  : const SizedBox.shrink(
                      key: ValueKey('desktop-playback-queue-hidden'),
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openMobilePlaybackQueue(BuildContext context) async {
    _hideKeyboard();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const _MobilePlaybackQueuePage()),
    );
    if (!mounted) {
      return;
    }

    // Persistent tabs can retain the search field's focus while the queue is
    // open. Clear it after the route is popped so Android does not reopen the
    // keyboard when returning to the player.
    _hideKeyboard();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _hideKeyboard();
      }
    });
  }

  Future<void> _openLyrics() async {
    _hideKeyboard();
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute<void>(builder: (_) => const LyricsPage()));
    if (mounted) {
      _hideKeyboard();
    }
  }

  Future<void> _openArtist(
    PlayerSnapshot snapshot,
    String? savedTrackId,
  ) async {
    if (_artistNavigationBusy) return;
    _artistNavigationBusy = true;
    try {
      final strings = ref.read(appStringsProvider);
      final target = await _resolveArtistNavigationTarget(
        snapshot,
        ref,
        strings,
        savedTrackId: savedTrackId,
      );
      if (!mounted) return;
      if (target == null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text(strings.artistProfileLoadError)),
          );
        return;
      }
      final request = (
        artistBrowseId: target.browseId,
        artistName: target.name,
        artistThumbnailUrl: null,
      );
      unawaited(
        ref
            .read(artistProfileProvider(request).future)
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ArtistProfilePage(
            artistBrowseId: target.browseId,
            artistName: target.name,
            seedVideoId: target.seedVideoId,
            onOpenPlayer: () {},
          ),
        ),
      );
    } finally {
      _artistNavigationBusy = false;
    }
  }

  Future<void> _openAlbumForTrack({
    required String key,
    required TrackInfo track,
    required String? albumTitle,
  }) async {
    if (_albumNavigationBusy) {
      return;
    }
    final strings = ref.read(appStringsProvider);
    if (_albumNavigationMisses.contains(key)) {
      _showAlbumNavigationUnavailable(strings.albumNavigationUnavailable);
      return;
    }

    _albumNavigationBusy = true;
    try {
      final target =
          _albumNavigationTargets[key] ??
          await _resolveAlbumNavigationTarget(
            track: track,
            albumTitle: albumTitle,
            service: ref.read(youtubeMusicSearchProvider),
          );
      if (!mounted) return;
      if (target == null) {
        _albumNavigationMisses.add(key);
        _showAlbumNavigationUnavailable(strings.albumNavigationUnavailable);
        return;
      }
      _albumNavigationTargets[key] = target;
      _hideKeyboard();
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RemoteCollectionDetailPage(
            title: target.title,
            subtitle: target.artist,
            artworkSource: target.thumbnailUrl,
            queueSourceId: 'player-album:${target.browseId}',
            tracksProvider: homeAlbumTracksProvider(target.browseId),
            emptyMessage: strings.albumWithoutSongs,
            errorMessage: strings.albumLoadError,
            fallbackIcon: Icons.album_rounded,
            metadata: target.metadata,
            onOpenPlayer: () {},
          ),
        ),
      );
    } on Object {
      if (mounted) {
        _showAlbumNavigationUnavailable(strings.albumNavigationUnavailable);
      }
    } finally {
      _albumNavigationBusy = false;
    }
  }

  void _showAlbumNavigationUnavailable(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _hideKeyboard() {
    FocusManager.instance.primaryFocus?.unfocus(
      disposition: UnfocusDisposition.scope,
    );
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  double _artworkExtent(
    BoxConstraints constraints, {
    required bool stackedDesktop,
    required bool wide,
    required bool mobile,
    required double compactness,
    required double mobileFrameCompactness,
  }) {
    late final double regularExtent;
    if (stackedDesktop) {
      regularExtent = math
          .min(constraints.maxWidth * 0.34, constraints.maxHeight * 0.44)
          .clamp(240.0, 340.0)
          .toDouble();
    } else if (wide) {
      regularExtent = math
          .min(constraints.maxWidth * 0.42, constraints.maxHeight * 0.74)
          .clamp(320.0, 520.0)
          .toDouble();
    } else {
      regularExtent = math
          .min(
            constraints.maxWidth - (mobile ? 8 : 16),
            // The single-line title frees a little vertical room. Use more of
            // it on tall phones while retaining the compact short-phone
            // fraction so the lower controls remain reachable.
            constraints.maxHeight *
                (mobile
                    ? lerpDouble(0.50, 0.47, mobileFrameCompactness)!
                    : 0.56),
          )
          .clamp(mobile ? 180.0 : 210.0, _mobileArtworkExtentCeiling)
          .toDouble();
    }

    final compactExtent = math
        .min(constraints.maxWidth * 0.31, constraints.maxHeight * 0.4)
        .clamp(170.0, 220.0)
        .toDouble();
    return lerpDouble(regularExtent, compactExtent, compactness)!;
  }

  double _mobileArtworkExtent({
    required BoxConstraints constraints,
    required double regularExtent,
    required bool hasError,
  }) {
    if (hasError || !constraints.maxHeight.isFinite) {
      return regularExtent;
    }

    // Preserve the normal artwork size whenever the lower controls fit. Only
    // reclaim the measured shortfall, capped at 20 dp, so small devices do not
    // get an aggressive reflow. Error content intentionally keeps the normal
    // artwork size and uses the scroll view as its fallback.
    final shortfall = math.max(
      0.0,
      _mobileArtworkComfortHeight - constraints.maxHeight,
    );
    return regularExtent -
        math.min(_mobileArtworkMaxReduction, shortfall).toDouble();
  }
}

class _BlurredPlayerBackground extends StatelessWidget {
  const _BlurredPlayerBackground({
    required this.url,
    required this.fallbackUrl,
  });

  final String? url;
  final String? fallbackUrl;

  @override
  Widget build(BuildContext context) {
    final source = url?.trim();
    if (source == null || source.isEmpty) {
      return const Positioned.fill(child: _FallbackBackground());
    }

    return Positioned.fill(
      child: ClipRect(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 44, sigmaY: 44),
          child: Transform.scale(
            scale: 1.28,
            child: SourceImage(
              source: source,
              fallbackSource: fallbackUrl,
              fit: BoxFit.cover,
              fallback: const _FallbackBackground(),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerHeader extends StatelessWidget {
  const _PlayerHeader({
    required this.snapshot,
    required this.isFavorite,
    required this.savedTrackId,
    required this.onOpenSearch,
    required this.queueVisible,
    required this.onToggleQueue,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final bool isFavorite;
  final String? savedTrackId;
  final VoidCallback? onOpenSearch;
  final bool queueVisible;
  final VoidCallback onToggleQueue;
  final VoidCallback? onOpenArtist;
  final VoidCallback? onOpenAlbum;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final controlColor = AppColors.playbackControlForegroundFor(context);
    return ConstrainedBox(
      key: const ValueKey('player-header'),
      constraints: const BoxConstraints(minHeight: 58),
      child: Row(
        children: [
          _HeaderIconSlot(
            child: IconButton(
              key: const ValueKey('player-queue-toggle'),
              tooltip: strings.playbackQueue,
              isSelected: queueVisible,
              style: IconButton.styleFrom(
                foregroundColor: queueVisible ? colors.primary : controlColor,
                backgroundColor: queueVisible
                    ? colors.primary.withValues(alpha: 0.16)
                    : Colors.transparent,
              ),
              icon: Transform.scale(
                scaleY: 1.2,
                child: const Icon(Icons.queue_music_rounded, size: 28),
              ),
              selectedIcon: Transform.scale(
                scaleY: 1.2,
                child: const Icon(Icons.queue_music_rounded, size: 28),
              ),
              onPressed: onToggleQueue,
            ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  key: const ValueKey('player-tab-title'),
                  strings.nowPlaying,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                InkWell(
                  key: const ValueKey('player-header-artist-action'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: onOpenArtist,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      snapshot.artist ?? 'BStream Music',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _HeaderIconSlot(
            child: snapshot.isExternal
                ? const SizedBox.shrink()
                : _PlayerMenu(
                    snapshot: snapshot,
                    isFavorite: isFavorite,
                    savedTrackId: savedTrackId,
                    onOpenSearch: onOpenSearch,
                    onOpenArtist: onOpenArtist,
                    onOpenAlbum: onOpenAlbum,
                    strings: strings,
                  ),
          ),
        ],
      ),
    );
  }
}

class _HeaderIconSlot extends StatelessWidget {
  const _HeaderIconSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(dimension: 48, child: Center(child: child));
  }
}

class _PlaybackQueuePanel extends ConsumerWidget {
  const _PlaybackQueuePanel({
    required this.queue,
    required this.strings,
    required this.onClose,
    this.standaloneRail = false,
  });

  final PlaybackQueueState queue;
  final AppStrings strings;
  final VoidCallback onClose;
  final bool standaloneRail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final isPlaying = ref.watch(
      playerControllerProvider.select(
        (player) => player.value?.status == PlayerStatus.playing,
      ),
    );
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 32, sigmaY: 32),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.64),
            borderRadius: standaloneRail ? null : BorderRadius.circular(6),
            border: standaloneRail
                ? Border(left: BorderSide(color: colors.outlineVariant))
                : Border.all(color: colors.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        strings.playbackQueueSummary(queue.entries.length),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: AppColors.contentHeadingFor(context),
                            ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox.square(
                      dimension: 48,
                      child: IconButton(
                        tooltip: strings.close,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: onClose,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: colors.onSurface.withValues(alpha: 0.1),
              ),
              Expanded(
                child: queue.entries.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            strings.playbackQueueEmpty,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.contentSubtitleFor(context),
                            ),
                          ),
                        ),
                      )
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        itemCount: queue.entries.length,
                        itemBuilder: (context, index) {
                          final entry = queue.entries[index];
                          final isCurrent = index == queue.currentIndex;
                          return Padding(
                            key: ValueKey('playback-queue-$index-${entry.id}'),
                            padding: EdgeInsets.only(
                              bottom: index == queue.entries.length - 1 ? 0 : 4,
                            ),
                            child: ReorderableDelayedDragStartListener(
                              index: index,
                              child: _PlaybackQueueTile(
                                entry: entry,
                                isCurrent: isCurrent,
                                isPlaying: isCurrent && isPlaying,
                                onTap: isCurrent
                                    ? null
                                    : () {
                                        unawaited(
                                          ref
                                              .read(
                                                playerControllerProvider
                                                    .notifier,
                                              )
                                              .playQueueIndex(index),
                                        );
                                      },
                              ),
                            ),
                          );
                        },
                        onReorderItem: (oldIndex, newIndex) {
                          unawaited(
                            ref
                                .read(playerControllerProvider.notifier)
                                .reorderQueue(oldIndex, newIndex),
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

class _PlaybackQueueTile extends StatefulWidget {
  const _PlaybackQueueTile({
    required this.entry,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
  });

  final PlaybackQueueEntry entry;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback? onTap;

  @override
  State<_PlaybackQueueTile> createState() => _PlaybackQueueTileState();
}

class _PlaybackQueueTileState extends State<_PlaybackQueueTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final isCurrent = widget.isCurrent;
    final isPlaying = widget.isPlaying;
    final colors = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Material(
          color: isCurrent || _hovered
              ? colors.onSurface.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 52,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(appArtworkRadius),
                          child: ColoredBox(
                            color: const Color(0xFF202520),
                            child: entry.thumbnailUrl == null
                                ? const Icon(Icons.music_note_rounded, size: 22)
                                : SourceImage(
                                    source: entry.thumbnailUrl,
                                    fit: BoxFit.cover,
                                    cacheWidth: 256,
                                    fallback: const Icon(
                                      Icons.music_note_rounded,
                                      size: 22,
                                    ),
                                  ),
                          ),
                        ),
                        if (isCurrent || _hovered)
                          NowPlayingEqualizerOverlay(
                            key: ValueKey('queue-now-playing-${entry.id}'),
                            isPlaying: isPlaying,
                            width: 52,
                            height: 20,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: isCurrent
                                ? FontWeight.w900
                                : FontWeight.w700,
                            color: AppColors.contentTitleFor(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          entry.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontSize: 13,
                                color: AppColors.contentSubtitleFor(context),
                              ),
                        ),
                      ],
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

class _MobilePlaybackQueuePage extends ConsumerWidget {
  const _MobilePlaybackQueuePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(playbackQueueProvider);
    final strings = ref.watch(appStringsProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const PlayerPlaybackGradientBackground(),
          SafeArea(
            child: _PlaybackQueuePanel(
              queue: queue,
              strings: strings,
              standaloneRail: true,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

class _LargeArtwork extends StatefulWidget {
  const _LargeArtwork({
    required this.url,
    required this.fallbackUrl,
    required this.identity,
    required this.maxExtent,
    required this.isFavorite,
    required this.shadowCompactness,
    required this.shadowHorizontalClearance,
  });

  final String? url;
  final String? fallbackUrl;
  final String identity;
  final double maxExtent;
  final bool isFavorite;
  final double shadowCompactness;
  final double shadowHorizontalClearance;

  @override
  State<_LargeArtwork> createState() => _LargeArtworkState();
}

class _LargeArtworkState extends State<_LargeArtwork> {
  String? _lastSource;
  late String _lastIdentity;
  int _transitionId = 0;

  @override
  void initState() {
    super.initState();
    _lastSource = _normalizedSource(widget.url);
    _lastIdentity = widget.identity;
  }

  @override
  void didUpdateWidget(covariant _LargeArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextSource = _normalizedSource(widget.url);
    if (_lastSource != nextSource || _lastIdentity != widget.identity) {
      final shouldAnimate =
          _lastIdentity != 'idle' && widget.identity != 'idle';
      _lastSource = nextSource;
      _lastIdentity = widget.identity;
      if (shouldAnimate) {
        _transitionId += 1;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _normalizedSource(widget.url);
    final transitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 420);
    return ConstrainedBox(
      key: const ValueKey('player-large-artwork'),
      constraints: BoxConstraints(
        maxWidth: widget.maxExtent,
        maxHeight: widget.maxExtent,
      ),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              key: const ValueKey('player-artwork-track-transition'),
              duration: transitionDuration,
              reverseDuration: transitionDuration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (currentChild, previousChildren) => Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [...previousChildren, ?currentChild],
              ),
              transitionBuilder: noDimmingFadeTransitionBuilder,
              child: SizedBox.expand(
                key: ValueKey(_transitionId),
                child: _PlayerArtworkSurface(
                  url: source,
                  fallbackUrl: widget.fallbackUrl,
                  compactness: widget.shadowCompactness,
                  horizontalClearance: widget.shadowHorizontalClearance,
                ),
              ),
            ),
            if (widget.isFavorite)
              const Positioned(
                top: 6,
                right: 6,
                child: FavoriteStarBadge(iconSize: 26),
              ),
          ],
        ),
      ),
    );
  }

  String? _normalizedSource(String? source) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return canonicalYouTubeThumbnailSource(normalized);
  }
}

class _PlayerArtworkSurface extends StatelessWidget {
  const _PlayerArtworkSurface({
    required this.url,
    required this.fallbackUrl,
    required this.compactness,
    required this.horizontalClearance,
  });

  final String? url;
  final String? fallbackUrl;
  final double compactness;
  final double horizontalClearance;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = colors.brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final artworkExtent = constraints.biggest.shortestSide;
        // Flutter's BoxShadow blur radius is converted to sigma before paint.
        // Three sigmas cover the visible Gaussian tail closely enough that a
        // compact scroll viewport cannot reveal a hard lateral cut. Ease into
        // this safety profile quickly on short frames, while a roomy player
        // (compactness == 0) keeps its original shadow exactly.
        const blurRadiusToSigma = 0.57735;
        const safeSigmaCount = 3.0;
        final safeCompactBlur = math.max(
          0.0,
          (horizontalClearance - (safeSigmaCount * 0.5)) /
              (safeSigmaCount * blurRadiusToSigma),
        );
        final compactBlurRadius = math.min(
          artworkExtent * 0.035,
          safeCompactBlur,
        );
        final shadowCompactness = Curves.easeOutCubic.transform(
          compactness.clamp(0.0, 1.0),
        );
        final shadowAlpha = lerpDouble(
          isDark ? 0.67 : 0.2,
          isDark ? 0.3 : 0.1,
          shadowCompactness,
        )!;
        final shadow = BoxShadow(
          color: Colors.black.withValues(alpha: shadowAlpha),
          // Keep the roomy-player shadow unchanged while scaling its visual
          // footprint with both the cover and the available frame height.
          // On short phones the smaller, lighter halo stays softly inside the
          // available breathing room instead of reaching the metadata or the
          // viewport edge after the cover itself has been compacted.
          blurRadius: lerpDouble(42, compactBlurRadius, shadowCompactness)!,
          spreadRadius: lerpDouble(6, 0, shadowCompactness)!,
          offset: Offset(
            0,
            lerpDouble(18, artworkExtent * 0.018, shadowCompactness)!,
          ),
        );
        return DecoratedBox(
          key: const ValueKey('player-artwork-surface'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(appArtworkRadius),
            boxShadow: [shadow],
          ),
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(appArtworkRadius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: AppColors.downloadGradientFor(context),
                        ),
                      ),
                      child: url == null
                          ? Icon(
                              Icons.music_note_rounded,
                              size: 108,
                              color: Theme.of(
                                context,
                              ).colorScheme.onPrimaryContainer,
                            )
                          : ColoredBox(
                              color: colors.surfaceContainerHighest,
                              child: ProportionalArtwork(
                                source: url,
                                fallbackSource: fallbackUrl,
                                fallback: Icon(
                                  Icons.music_note_rounded,
                                  size: 108,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FallbackBackground extends StatelessWidget {
  const _FallbackBackground();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF111611), Color(0xFF070907), Color(0xFF030403)]
              : const [Color(0xFFE5F2E9), Color(0xFFF5F8F6), Colors.white],
        ),
      ),
    );
  }
}

class _PlayerControls extends ConsumerWidget {
  const _PlayerControls({
    required this.snapshot,
    required this.hasTrack,
    required this.isFavorite,
    required this.savedTrackId,
    required this.hasError,
    required this.errorText,
    required this.compact,
    required this.compactness,
    required this.maxWidth,
    required this.onOpenLyrics,
    required this.onOpenArtist,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final bool hasTrack;
  final bool isFavorite;
  final String? savedTrackId;
  final bool hasError;
  final String? errorText;
  final bool compact;
  final double compactness;
  final double maxWidth;
  final VoidCallback onOpenLyrics;
  final VoidCallback? onOpenArtist;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = snapshot.status == PlayerStatus.playing;
    final mobile = Theme.of(context).platform == TargetPlatform.android;
    final titleStyle = Theme.of(context).textTheme.headlineMedium?.copyWith(
      fontSize: lerpDouble(compact ? 28 : 42, compact ? 24 : 34, compactness),
      fontWeight: FontWeight.w900,
      color: AppColors.playbackTitleFor(context),
    );
    final artistStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
      fontSize: lerpDouble(compact ? 18 : 26, compact ? 16 : 21, compactness),
      fontWeight: FontWeight.w800,
      color: AppColors.contentSubtitleFor(context),
    );
    final titleArtistGap = lerpDouble(6, 4, compactness)!;
    final visualIdentity = playbackVisualIdentity(
      trackId: snapshot.trackId,
      sourceUrl: snapshot.sourceUrl,
      title: snapshot.title,
      artist: snapshot.artist,
      thumbnailUrl: snapshot.thumbnailUrl,
    );

    Widget metadata() => SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MarqueeText(
            key: const ValueKey('player-track-title'),
            snapshot.title ?? strings.noPlayback,
            style: titleStyle,
          ),
          SizedBox(
            key: const ValueKey('player-title-artist-gap'),
            height: titleArtistGap,
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: InkWell(
                  key: const ValueKey('player-track-artist-action'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: onOpenArtist,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      key: const ValueKey('player-track-artist'),
                      snapshot.artist ?? 'BStream Music',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: artistStyle,
                    ),
                  ),
                ),
              ),
              if (!snapshot.isExternal) ...[
                _PlayerShareButton(
                  snapshot: snapshot,
                  savedTrackId: savedTrackId,
                  strings: strings,
                ),
                _PlayerFavoriteButton(
                  snapshot: snapshot,
                  isFavorite: isFavorite,
                  savedTrackId: savedTrackId,
                  strings: strings,
                ),
              ],
            ],
          ),
        ],
      ),
    );

    // The Android body is bottom-aligned so its playback actions stay close to
    // the system inset. Reserve one title line while the real text metrics are
    // measured; long titles now slide horizontally instead of wrapping.
    final stableMetadata = mobile
        ? SizedBox(
            key: const ValueKey('player-stable-metadata'),
            width: double.infinity,
            child: Stack(
              alignment: Alignment.topLeft,
              children: [
                ExcludeSemantics(
                  child: Opacity(
                    opacity: 0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('A', maxLines: 1, style: titleStyle),
                        SizedBox(height: titleArtistGap),
                        Text('A', maxLines: 1, style: artistStyle),
                      ],
                    ),
                  ),
                ),
                metadata(),
              ],
            ),
          )
        : metadata();

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TrackChangeTransition(
            switcherKey: const ValueKey('player-metadata-track-transition'),
            identity: visualIdentity,
            alignment: Alignment.topLeft,
            child: stableMetadata,
          ),
          SizedBox(height: lerpDouble(compact ? 22 : 36, 14, compactness)),
          const _Timeline(),
          SizedBox(height: lerpDouble(compact ? 18 : 28, 12, compactness)),
          _PlaybackButtons(
            snapshot: snapshot,
            hasTrack: hasTrack,
            isPlaying: isPlaying,
            compact: compact,
            compactness: compactness,
            onOpenLyrics: onOpenLyrics,
            strings: strings,
          ),
          if (hasError) ...[
            SizedBox(height: lerpDouble(18, 10, compactness)),
            PlayerErrorMessage(
              key: const ValueKey('player-error-message'),
              message: errorText ?? strings.playbackError,
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact error surface used by the full player.
///
/// Keeping it separate also makes the three-line Android error contract easy
/// to verify without constructing the complete player and its animations.
class PlayerErrorMessage extends StatelessWidget {
  const PlayerErrorMessage({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: Theme.of(context).colorScheme.error,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _PlayerShareButton extends ConsumerWidget {
  const _PlayerShareButton({
    required this.snapshot,
    required this.savedTrackId,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final String? savedTrackId;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = snapshot.isExternal
        ? null
        : _shareTrackForSnapshot(
            snapshot,
            ref,
            strings,
            savedTrackId: savedTrackId,
          );
    final shareService = ref.read(trackShareServiceProvider);
    final canShare = track != null && shareService.canShare(track);
    final color = AppColors.playbackSecondaryControlForegroundFor(context);

    return Builder(
      builder: (buttonContext) {
        return IconButton(
          key: const ValueKey('player-share-control'),
          tooltip: strings.shareSong,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          padding: const EdgeInsets.all(9),
          color: color,
          disabledColor: color.withValues(alpha: 0.38),
          iconSize: 30,
          icon: const Icon(Icons.share_rounded),
          onPressed: canShare
              ? () => unawaited(
                  _shareTrack(
                    context: buttonContext,
                    ref: ref,
                    track: track,
                    strings: strings,
                  ),
                )
              : null,
        );
      },
    );
  }
}

class _PlayerFavoriteButton extends ConsumerWidget {
  const _PlayerFavoriteButton({
    required this.snapshot,
    required this.isFavorite,
    required this.savedTrackId,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final bool isFavorite;
  final String? savedTrackId;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasIdentity =
        (snapshot.trackId?.trim().isNotEmpty ?? false) ||
        (snapshot.sourceUrl?.trim().isNotEmpty ?? false);
    final activeColor = Theme.of(context).colorScheme.primary;
    final inactiveColor = AppColors.playbackSecondaryControlForegroundFor(
      context,
    );

    return IconButton(
      key: const ValueKey('player-favorite-control'),
      tooltip: isFavorite
          ? strings.removeFromFavorites
          : strings.addToFavorites,
      color: isFavorite ? activeColor : inactiveColor,
      disabledColor: inactiveColor.withValues(alpha: 0.38),
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      padding: const EdgeInsets.all(9),
      iconSize: 30,
      icon: Icon(
        isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
      ),
      onPressed: !snapshot.isExternal && hasIdentity
          ? () => unawaited(
              _toggleFavoriteForSnapshot(
                context: context,
                ref: ref,
                snapshot: snapshot,
                isFavorite: isFavorite,
                savedTrackId: savedTrackId,
                strings: strings,
              ),
            )
          : null,
    );
  }
}

TrackInfo _shareTrackForSnapshot(
  PlayerSnapshot snapshot,
  WidgetRef ref,
  AppStrings strings, {
  required String? savedTrackId,
}) {
  final sourceUrl = snapshot.sourceUrl?.trim() ?? '';
  if (sourceUrl.isNotEmpty) {
    final canonical = ref
        .read(playerControllerProvider.notifier)
        .currentRemoteTrackFor(sourceUrl);
    if (canonical != null) {
      return canonical;
    }
  }

  final normalizedSavedTrackId = savedTrackId?.trim();
  if (normalizedSavedTrackId != null && normalizedSavedTrackId.isNotEmpty) {
    final localTracks =
        ref.read(libraryTracksProvider).value ?? const <LocalTrack>[];
    for (final localTrack in localTracks) {
      if (localTrack.id != normalizedSavedTrackId) {
        continue;
      }
      final sourceId = localTrack.sourceId?.trim();
      return TrackInfo(
        id: sourceId != null && sourceId.isNotEmpty ? sourceId : localTrack.id,
        title: localTrack.title,
        artist: localTrack.artist,
        url: localTrack.sourceUrl?.trim() ?? '',
        thumbnailUrl: localTrack.thumbnailUrl,
        catalogThumbnailUrl: localTrack.catalogThumbnailUrl,
        duration: localTrack.duration,
        album: localTrack.album,
        artists: localTrack.artists,
        artistBrowseIds: localTrack.artistBrowseIds,
        metadataSource: localTrack.metadataSource,
      );
    }
  }

  return TrackInfo(
    id: snapshot.trackId?.trim() ?? '',
    title: snapshot.title?.trim().isNotEmpty == true
        ? snapshot.title!.trim()
        : strings.noTitle,
    artist: snapshot.artist?.trim().isNotEmpty == true
        ? snapshot.artist!.trim()
        : strings.unknownArtist,
    url: sourceUrl,
    thumbnailUrl: snapshot.thumbnailUrl,
    duration: snapshot.duration,
    album: snapshot.album,
  );
}

typedef _ArtistNavigationTarget = ({
  String browseId,
  String name,
  String? seedVideoId,
});

Future<_ArtistNavigationTarget?> _resolveArtistNavigationTarget(
  PlayerSnapshot snapshot,
  WidgetRef ref,
  AppStrings strings, {
  required String? savedTrackId,
}) async {
  final track = _shareTrackForSnapshot(
    snapshot,
    ref,
    strings,
    savedTrackId: savedTrackId,
  );
  final structuredArtists = track.artists
      .map((artist) => artist.trim())
      .where((artist) => artist.isNotEmpty)
      .toList(growable: false);
  final fallbackArtist = track.artist.split(',').first.trim();
  var artistName = structuredArtists.isNotEmpty
      ? structuredArtists.first
      : fallbackArtist;
  if (artistName.isEmpty) return null;
  var browseId = track.artistBrowseIds.isEmpty
      ? null
      : track.artistBrowseIds.first?.trim();
  final link = const BStreamTrackLinkCodec().tryFromTrack(track);
  final seedVideoId = link?.videoId;
  final service = ref.read(youtubeMusicSearchProvider);

  if ((browseId == null || browseId.isEmpty) &&
      seedVideoId != null &&
      service is YouTubeMusicTrackLookup) {
    try {
      final song = await (service as YouTubeMusicTrackLookup).getSong(
        seedVideoId,
      );
      if (song != null && song.artists.isNotEmpty) {
        artistName = song.artists.first.trim().isEmpty
            ? artistName
            : song.artists.first.trim();
        browseId = song.artistBrowseIds.isEmpty
            ? null
            : song.artistBrowseIds.first?.trim();
      }
    } on Object {
      // A catalog lookup is best effort; the exact-name search below can
      // still recover browse metadata for older local tracks.
    }
  }

  if (browseId == null || browseId.isEmpty) {
    try {
      final candidates = await service.searchSongs(artistName, limit: 5);
      for (final candidate in candidates) {
        for (var index = 0; index < candidate.artists.length; index += 1) {
          if (candidate.artists[index].trim().toLowerCase() !=
              artistName.toLowerCase()) {
            continue;
          }
          final candidateBrowseId = index < candidate.artistBrowseIds.length
              ? candidate.artistBrowseIds[index]?.trim()
              : null;
          if (candidateBrowseId != null && candidateBrowseId.isNotEmpty) {
            browseId = candidateBrowseId;
            break;
          }
        }
        if (browseId?.isNotEmpty == true) break;
      }
    } on Object {
      return null;
    }
  }

  if (browseId == null || browseId.isEmpty) return null;
  return (browseId: browseId, name: artistName, seedVideoId: seedVideoId);
}

typedef _AlbumNavigationTarget = ({
  String browseId,
  String title,
  String artist,
  String? thumbnailUrl,
  List<String> metadata,
});

bool _hasYouTubeMusicCatalogMetadata(TrackInfo track) {
  return track.metadataSource == TrackMetadataSource.youtubeMusic ||
      track.artistBrowseIds.any(
        (browseId) => browseId?.trim().isNotEmpty == true,
      );
}

String? _preferredAlbumTitle(String? trackAlbum, String? snapshotAlbum) {
  for (final candidate in <String?>[trackAlbum, snapshotAlbum]) {
    final normalized = candidate?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return normalized;
    }
  }
  return null;
}

String _albumNavigationKey(TrackInfo track, String? albumTitle) {
  final artistBrowseId = track.artistBrowseIds
      .whereType<String>()
      .map((value) => value.trim())
      .firstWhere((value) => value.isNotEmpty, orElse: () => '');
  final artistIdentity = artistBrowseId.isNotEmpty
      ? 'id:$artistBrowseId'
      : 'name:${_normalizeCatalogText(track.artists.isNotEmpty ? track.artists.first : track.artist.split(',').first)}';
  final normalizedAlbum = _normalizeCatalogText(albumTitle ?? '');
  final albumIdentity = normalizedAlbum.isNotEmpty
      ? 'album:$normalizedAlbum'
      : 'track:${track.id.trim().isNotEmpty ? track.id.trim() : track.url.trim()}';
  return '$albumIdentity\u0000$artistIdentity';
}

Future<String?> _resolveAlbumTitleForTrack({
  required TrackInfo track,
  required String? albumTitle,
  required YouTubeMusicSearch service,
}) async {
  final knownAlbum = albumTitle?.trim();
  if (knownAlbum != null && knownAlbum.isNotEmpty) {
    return knownAlbum;
  }

  final primaryArtist = track.artists
      .map((artist) => artist.trim())
      .firstWhere(
        (artist) => artist.isNotEmpty,
        orElse: () => track.artist.split(',').first.trim(),
      );
  final queryParts = <String>[track.title.trim(), primaryArtist]
    ..removeWhere((part) => part.isEmpty);
  if (queryParts.isEmpty) return null;

  final candidates = await service.searchSongs(queryParts.join(' '), limit: 10);
  InnerTubeSong? selected;
  final videoId = track.id.trim();
  if (videoId.isNotEmpty) {
    for (final candidate in candidates) {
      if (candidate.videoId == videoId) {
        selected = candidate;
        break;
      }
    }
  }

  if (selected == null) {
    final expectedTitle = _normalizeCatalogText(track.title);
    final expectedArtists = <String>{
      for (final artist in track.artists) _normalizeCatalogText(artist),
      for (final artist in track.artist.split(','))
        _normalizeCatalogText(artist),
    }..removeWhere((artist) => artist.isEmpty);
    final exactMatches = candidates
        .where((candidate) {
          if (_normalizeCatalogText(candidate.title) != expectedTitle) {
            return false;
          }
          return candidate.artists.any(
            (artist) => expectedArtists.contains(_normalizeCatalogText(artist)),
          );
        })
        .toList(growable: false);
    if (exactMatches.length == 1) {
      selected = exactMatches.single;
    }
  }

  final resolvedAlbum = selected?.album?.trim();
  return resolvedAlbum == null || resolvedAlbum.isEmpty ? null : resolvedAlbum;
}

Future<_AlbumNavigationTarget?> _resolveAlbumNavigationTarget({
  required TrackInfo track,
  required String? albumTitle,
  required YouTubeMusicSearch service,
}) async {
  final directBrowseId = track.albumBrowseId?.trim();
  final directTitle = albumTitle?.trim();
  if (directBrowseId != null &&
      directTitle != null &&
      directTitle.isNotEmpty &&
      _isValidAlbumBrowseId(directBrowseId)) {
    return (
      browseId: directBrowseId,
      title: directTitle,
      artist: track.artist.trim(),
      thumbnailUrl: track.catalogThumbnailUrl ?? track.thumbnailUrl,
      metadata: const <String>[],
    );
  }

  var resolvedAlbumTitle = directTitle;
  final videoId = const BStreamTrackLinkCodec().tryFromTrack(track)?.videoId;
  if (videoId != null && service is YouTubeMusicRelated) {
    final page = await (service as YouTubeMusicRelated).getNext(
      videoId,
      radio: false,
      limit: 20,
    );
    InnerTubeSong? exactSong;
    for (final song in page.songs) {
      if (song.videoId == videoId) {
        exactSong = song;
        break;
      }
    }
    if (exactSong != null) {
      final browseId = exactSong.albumBrowseId?.trim();
      final title = exactSong.album?.trim();
      if (browseId != null &&
          title != null &&
          title.isNotEmpty &&
          _isValidAlbumBrowseId(browseId)) {
        return (
          browseId: browseId,
          title: title,
          artist: exactSong.artist.trim().isNotEmpty
              ? exactSong.artist.trim()
              : track.artist.trim(),
          thumbnailUrl:
              exactSong.thumbnailUrl ??
              track.catalogThumbnailUrl ??
              track.thumbnailUrl,
          metadata: const <String>[],
        );
      }
      if (resolvedAlbumTitle == null || resolvedAlbumTitle.isEmpty) {
        resolvedAlbumTitle = title;
      }
    }
  }

  resolvedAlbumTitle ??= await _resolveAlbumTitleForTrack(
    track: track,
    albumTitle: albumTitle,
    service: service,
  );
  if (resolvedAlbumTitle == null) {
    return null;
  }
  if (service is! YouTubeMusicCatalogSearch) {
    return null;
  }
  final expectedTitle = _normalizeCatalogText(resolvedAlbumTitle);
  if (expectedTitle.isEmpty) {
    return null;
  }
  final expectedArtists = <String>{
    for (final artist in track.artists) _normalizeCatalogText(artist),
    for (final artist in track.artist.split(',')) _normalizeCatalogText(artist),
  }..removeWhere((artist) => artist.isEmpty);
  final primaryArtist = track.artists
      .map((artist) => artist.trim())
      .firstWhere(
        (artist) => artist.isNotEmpty,
        orElse: () => track.artist.split(',').first.trim(),
      );
  final query = primaryArtist.isEmpty
      ? resolvedAlbumTitle
      : '$resolvedAlbumTitle $primaryArtist';
  final results = await (service as YouTubeMusicCatalogSearch).searchAlbums(
    query,
    limit: 10,
  );
  final exactTitleMatches = results
      .where((album) {
        return _isValidAlbumBrowseId(album.browseId) &&
            _normalizeCatalogText(album.title) == expectedTitle;
      })
      .toList(growable: false);
  if (exactTitleMatches.isEmpty) {
    return null;
  }

  InnerTubeAlbum? selected;
  for (final album in exactTitleMatches) {
    if (album.artists.any(
      (artist) => expectedArtists.contains(_normalizeCatalogText(artist)),
    )) {
      selected = album;
      break;
    }
  }
  selected ??= exactTitleMatches.length == 1 ? exactTitleMatches.single : null;
  if (selected == null) {
    return null;
  }

  final resolvedArtist = selected.artist.trim().isNotEmpty
      ? selected.artist.trim()
      : track.artist.trim();
  final metadata = <String>[
    ?selected.type?.trim(),
    ?selected.year?.trim(),
  ].where((value) => value.isNotEmpty).toList(growable: false);
  return (
    browseId: selected.browseId.trim(),
    title: selected.title.trim(),
    artist: resolvedArtist,
    thumbnailUrl: selected.thumbnailUrl ?? track.thumbnailUrl,
    metadata: List<String>.unmodifiable(metadata),
  );
}

bool _isValidAlbumBrowseId(String value) =>
    RegExp(r'^MPRE[A-Za-z0-9_-]{1,200}$').hasMatch(value.trim());

String _normalizeCatalogText(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'[\s\-–—_:·]+'), ' ').trim();

Future<void> _shareTrack({
  required BuildContext context,
  required WidgetRef ref,
  required TrackInfo track,
  required AppStrings strings,
}) async {
  final renderObject = context.findRenderObject();
  final origin = renderObject is RenderBox && renderObject.hasSize
      ? renderObject.localToGlobal(Offset.zero) & renderObject.size
      : null;

  try {
    await ref
        .read(trackShareServiceProvider)
        .shareTrack(
          track,
          message: strings.shareSongMessage(track.title, track.artist),
          title: strings.shareSongTitle,
          sharePositionOrigin: origin,
        );
  } catch (_) {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(strings.shareFailed)));
  }
}

class _PlaybackButtons extends ConsumerWidget {
  const _PlaybackButtons({
    required this.snapshot,
    required this.hasTrack,
    required this.isPlaying,
    required this.compact,
    required this.compactness,
    required this.onOpenLyrics,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final bool hasTrack;
  final bool isPlaying;
  final bool compact;
  final double compactness;
  final VoidCallback onOpenLyrics;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeColor = Theme.of(context).colorScheme.primary;
    final controlColor = AppColors.playbackControlForegroundFor(context);
    final inactiveColor = AppColors.playbackSecondaryControlForegroundFor(
      context,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final mobile = Theme.of(context).platform == TargetPlatform.android;
        final narrow = width < 360;
        final veryNarrow = width < 300;
        final roomy = width >= 420 || !compact;
        final regularSmallButtonSize = (width * 0.105).clamp(
          48.0,
          compact ? 52.0 : 56.0,
        );
        final compactSmallButtonSize = (width * 0.09).clamp(48.0, 50.0);
        final smallButtonSize = lerpDouble(
          regularSmallButtonSize,
          compactSmallButtonSize,
          compactness,
        )!;
        final regularSideButtonSize = (width * 0.145).clamp(
          roomy ? 56.0 : 44.0,
          compact ? 62.0 : 72.0,
        );
        final compactSideButtonSize = (width * 0.115).clamp(48.0, 54.0);
        final sideButtonSize = lerpDouble(
          regularSideButtonSize,
          compactSideButtonSize,
          compactness,
        )!;
        final regularPlaySize = (width * 0.22).clamp(
          roomy ? 74.0 : 64.0,
          compact ? 88.0 : 104.0,
        );
        final compactPlaySize = (width * 0.17).clamp(68.0, 78.0);
        final playSize = lerpDouble(
          regularPlaySize,
          compactPlaySize,
          compactness,
        )!;
        final secondarySideButtonSize = (sideButtonSize - 4.0).clamp(
          48.0,
          66.0,
        );
        final secondarySideIconSize = (secondarySideButtonSize * 0.72).clamp(
          28.0,
          50.0,
        );
        final secondaryControlSize = mobile && !veryNarrow
            ? narrow
                  ? 50.0
                  : (secondarySideButtonSize + 2.0).clamp(50.0, 68.0)
            : narrow
            ? smallButtonSize.clamp(48.0, 50.0)
            : secondarySideButtonSize;
        final secondaryControlIconSize = mobile && !veryNarrow
            ? narrow
                  ? 34.0
                  : (secondarySideIconSize + 2.0).clamp(30.0, 52.0)
            : narrow
            ? (secondaryControlSize * 0.68).clamp(28.0, 34.0)
            : secondarySideIconSize;
        final sideButtonGrowth = mobile && !veryNarrow ? 6.0 : 4.0;
        final largerSideButtonSize = (sideButtonSize + sideButtonGrowth).clamp(
          52.0,
          76.0,
        );
        final largerSideIconSize = (largerSideButtonSize * 0.84).clamp(
          38.0,
          58.0,
        );
        final enlargedPlaySize = (playSize + 6.0).clamp(
          roomy ? 84.0 : 76.0,
          compact ? 94.0 : 116.0,
        );
        final enlargedPlayIconSize = mobile
            ? isPlaying
                  ? (enlargedPlaySize * 0.80).clamp(58.0, 76.0)
                  : (enlargedPlaySize * 0.92).clamp(68.0, 88.0)
            : isPlaying
            ? (enlargedPlaySize * 0.76).clamp(56.0, 88.0)
            : (enlargedPlaySize * 0.88).clamp(64.0, 104.0);
        final centerGap = veryNarrow
            ? 2.0
            : narrow
            ? 6.0
            : (width * 0.04).clamp(12.0, 34.0);
        final outerGap = narrow ? 6.0 : (width * 0.075).clamp(16.0, 60.0);
        final edgeGap = veryNarrow
            ? 0.0
            : narrow
            ? 6.0
            : (width * 0.025).clamp(10.0, 18.0);
        final mobileLabelWidth = (width * (narrow ? 0.36 : 0.33)).clamp(
          112.0,
          132.0,
        );
        const mobileLabelHeight = 48.0;
        final mobileSecondaryGap = narrow ? 8.0 : 10.0;
        final lyricsButton = mobile
            ? _LabeledControlButton(
                key: const ValueKey('player-lyrics-control'),
                width: mobileLabelWidth,
                height: mobileLabelHeight,
                tooltip: strings.lyrics,
                label: strings.lyrics,
                iconSize: 24,
                color: controlColor,
                icon: Icons.lyrics_rounded,
                onPressed: hasTrack ? onOpenLyrics : null,
              )
            : _ControlButton(
                key: const ValueKey('player-lyrics-control'),
                size: secondaryControlSize,
                tooltip: strings.lyrics,
                iconSize: secondaryControlIconSize,
                color: controlColor,
                icon: Icons.lyrics_rounded,
                onPressed: hasTrack ? onOpenLyrics : null,
              );
        final shuffleButton = _ControlButton(
          key: const ValueKey('player-shuffle-control'),
          size: secondaryControlSize,
          tooltip: snapshot.shuffleEnabled
              ? strings.deactivateShuffle
              : strings.activateShuffle,
          iconSize: secondaryControlIconSize,
          color: snapshot.shuffleEnabled ? activeColor : inactiveColor,
          icon: Icons.shuffle_rounded,
          onPressed: hasTrack
              ? () =>
                    ref.read(playerControllerProvider.notifier).toggleShuffle()
              : null,
        );
        final repeatButton = _ControlButton(
          key: const ValueKey('player-repeat-control'),
          size: secondaryControlSize,
          tooltip: switch (snapshot.repeatMode) {
            PlaybackRepeatMode.off => strings.repeatQueue,
            PlaybackRepeatMode.all => strings.repeatOne,
            PlaybackRepeatMode.one => strings.disableRepeat,
          },
          iconSize: secondaryControlIconSize,
          color: snapshot.repeatMode == PlaybackRepeatMode.off
              ? inactiveColor
              : activeColor,
          icon: snapshot.repeatMode == PlaybackRepeatMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          onPressed: hasTrack
              ? () => ref
                    .read(playerControllerProvider.notifier)
                    .cycleRepeatMode()
              : null,
        );
        final volumeButton = _VolumeButton(
          key: const ValueKey('player-volume-control'),
          snapshot: snapshot,
          size: mobile ? mobileLabelHeight : secondaryControlSize,
          width: mobile ? mobileLabelWidth : null,
          label: mobile ? strings.volume : null,
          tooltip: strings.volume,
          iconSize: mobile ? 24 : secondaryControlIconSize,
          color: controlColor,
        );
        final previousButton = _ControlButton(
          key: const ValueKey('player-previous-control'),
          size: largerSideButtonSize,
          tooltip: strings.previous,
          iconSize: largerSideIconSize,
          color: controlColor,
          icon: Icons.skip_previous_rounded,
          onPressed: hasTrack
              ? () => ref.read(playerControllerProvider.notifier).playPrevious()
              : null,
        );
        final primaryButton = SizedBox(
          width: enlargedPlaySize,
          height: enlargedPlaySize,
          child: IconButton(
            key: const ValueKey('player-primary-control'),
            tooltip: isPlaying ? strings.pause : strings.play,
            style: IconButton.styleFrom(
              backgroundColor: Colors.transparent,
              disabledBackgroundColor: Colors.transparent,
            ),
            color: controlColor,
            disabledColor: controlColor.withValues(alpha: 0.38),
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tight(Size.square(enlargedPlaySize)),
            iconSize: enlargedPlayIconSize,
            icon: Transform.translate(
              offset: isPlaying ? Offset.zero : Offset(mobile ? 1.25 : 1.5, 0),
              transformHitTests: false,
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            onPressed: hasTrack
                ? () => ref
                      .read(playerControllerProvider.notifier)
                      .togglePlayPause()
                : null,
          ),
        );
        final nextButton = _ControlButton(
          key: const ValueKey('player-next-control'),
          size: largerSideButtonSize,
          tooltip: strings.next,
          iconSize: largerSideIconSize,
          color: controlColor,
          icon: Icons.skip_next_rounded,
          onPressed: hasTrack
              ? () => ref.read(playerControllerProvider.notifier).playNext()
              : null,
        );
        final centerButtons = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            previousButton,
            SizedBox(width: centerGap),
            primaryButton,
            SizedBox(width: centerGap),
            nextButton,
          ],
        );
        final controls = mobile
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        shuffleButton,
                        SizedBox(width: edgeGap),
                        centerButtons,
                        SizedBox(width: edgeGap),
                        repeatButton,
                      ],
                    ),
                  ),
                  SizedBox(height: mobileSecondaryGap),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [lyricsButton, volumeButton],
                  ),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  lyricsButton,
                  SizedBox(width: edgeGap),
                  shuffleButton,
                  SizedBox(width: outerGap),
                  centerButtons,
                  SizedBox(width: outerGap),
                  repeatButton,
                  SizedBox(width: edgeGap),
                  volumeButton,
                ],
              );

        if (mobile) {
          return controls;
        }
        return Center(
          child: FittedBox(fit: BoxFit.scaleDown, child: controls),
        );
      },
    );
  }
}

class _VolumeButton extends ConsumerStatefulWidget {
  const _VolumeButton({
    required this.snapshot,
    required this.size,
    required this.tooltip,
    required this.iconSize,
    required this.color,
    this.width,
    this.label,
    super.key,
  });

  final PlayerSnapshot snapshot;
  final double size;
  final String tooltip;
  final double iconSize;
  final Color color;
  final double? width;
  final String? label;

  @override
  ConsumerState<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends ConsumerState<_VolumeButton> {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _overlayController = OverlayPortalController();

  void _togglePopover() {
    _overlayController.toggle();
  }

  void _hidePopover() {
    if (_overlayController.isShowing) {
      _overlayController.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _overlayController,
      overlayChildBuilder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _hidePopover,
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: widget.label == null
                  ? Alignment.topRight
                  : Alignment.centerRight,
              followerAnchor: widget.label == null
                  ? Alignment.bottomRight
                  : Alignment.centerRight,
              offset: widget.label == null
                  ? const Offset(-4, -10)
                  : const Offset(-4, 0),
              child: _VolumePopover(onClose: _hidePopover),
            ),
          ],
        );
      },
      child: CompositedTransformTarget(
        link: _layerLink,
        child: widget.label == null
            ? _ControlButton(
                size: widget.size,
                tooltip: widget.tooltip,
                iconSize: widget.iconSize,
                color: widget.color,
                icon: _volumeIcon(widget.snapshot.volume),
                onPressed: _togglePopover,
              )
            : _LabeledControlButton(
                width: widget.width ?? widget.size,
                height: widget.size,
                tooltip: widget.tooltip,
                label: widget.label!,
                iconSize: widget.iconSize,
                color: widget.color,
                icon: _volumeIcon(widget.snapshot.volume),
                onPressed: _togglePopover,
              ),
      ),
    );
  }
}

class _VolumePopover extends ConsumerWidget {
  const _VolumePopover({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final snapshot =
        ref.watch(playerControllerProvider).value ??
        const PlayerSnapshot(status: PlayerStatus.idle);
    final volume = snapshot.volume.clamp(0.0, 1.0).toDouble();
    final menuBackground = AppColors.menuBackgroundFor(context);
    final menuForeground = AppColors.menuForegroundFor(context);
    final menuIcon = AppColors.menuIconFor(context);
    final menuBorder = AppColors.menuBorderFor(context);
    final menuInactiveSlider = AppColors.menuInactiveSliderFor(context);
    final accent = AppColors.downloadAccentFor(context);

    final popover = Container(
      key: const ValueKey('volume-popover'),
      width: math.min(244.0, MediaQuery.sizeOf(context).width - 32),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        gradient: AppColors.glassSurfaceGradientFor(
          context,
          baseColor: menuBackground,
          intensity: 0.82,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: menuBorder),
      ),
      child: Semantics(
        key: const ValueKey('volume-popover-semantics'),
        container: true,
        onDismiss: onClose,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              Icon(_volumeIcon(volume), color: menuIcon, size: 19),
              const SizedBox(width: 6),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2.5,
                    activeTrackColor: accent,
                    inactiveTrackColor: menuInactiveSlider,
                    thumbColor: accent,
                    overlayColor: accent.withValues(alpha: 0.14),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 13,
                    ),
                  ),
                  child: Slider(
                    value: volume,
                    semanticFormatterCallback: (value) =>
                        '${strings.volume} ${(value * 100).round()}%',
                    onChanged: (value) => unawaited(
                      ref
                          .read(playerControllerProvider.notifier)
                          .setVolume(value),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 38,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    key: const ValueKey('volume-popover-percentage'),
                    '${(volume * 100).round()}%',
                    maxLines: 1,
                    style: TextStyle(
                      color: menuForeground,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final roundedPopover = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child:
          AppColors.surfaceBackgroundModeFor(context) ==
              SurfaceBackgroundMode.transparent
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: popover,
            )
          : popover,
    );

    return DecoratedBox(
      key: const ValueKey('volume-popover-shadow'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.38
                  : 0.2,
            ),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(color: Colors.transparent, child: roundedPopover),
    );
  }
}

IconData _volumeIcon(double volume) {
  if (volume <= 0.001) {
    return Icons.volume_off_rounded;
  }
  if (volume < 0.5) {
    return Icons.volume_down_rounded;
  }
  return Icons.volume_up_rounded;
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.size,
    required this.tooltip,
    required this.iconSize,
    required this.color,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final double size;
  final String tooltip;
  final double iconSize;
  final Color color;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tight(Size.square(size)),
        iconSize: iconSize,
        color: color,
        icon: Icon(icon),
        onPressed: onPressed,
      ),
    );
  }
}

class _LabeledControlButton extends StatelessWidget {
  const _LabeledControlButton({
    required this.width,
    required this.height,
    required this.tooltip,
    required this.label,
    required this.iconSize,
    required this.color,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final double width;
  final double height;
  final String tooltip;
  final String label;
  final double iconSize;
  final Color color;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Tooltip(
        message: tooltip,
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: color,
            disabledForegroundColor: color.withValues(alpha: 0.38),
            backgroundColor: Colors.transparent,
            disabledBackgroundColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: onPressed,
          icon: Icon(icon, size: iconSize),
          label: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}

class _PlayerMenu extends ConsumerWidget {
  const _PlayerMenu({
    required this.snapshot,
    required this.isFavorite,
    required this.savedTrackId,
    required this.onOpenSearch,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final bool isFavorite;
  final String? savedTrackId;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onOpenArtist;
  final VoidCallback? onOpenAlbum;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final menuIconColor = AppColors.menuIconFor(context);
    return GlassPopupMenuButton<String>(
      enabled: snapshot.trackId != null,
      tooltip: strings.moreOptions,
      padding: EdgeInsets.zero,
      iconColor: AppColors.playbackControlForegroundFor(context),
      icon: const Icon(Icons.more_vert_rounded, size: 34),
      onSelected: (value) {
        switch (value) {
          case 'download':
            unawaited(_downloadCurrent(context, ref));
          case 'playlist':
            unawaited(_showPlaylistPicker(context, ref));
          case 'favorite':
            unawaited(
              _toggleFavoriteForSnapshot(
                context: context,
                ref: ref,
                snapshot: snapshot,
                isFavorite: isFavorite,
                savedTrackId: savedTrackId,
                strings: strings,
              ),
            );
          case 'artist':
            onOpenArtist?.call();
          case 'album':
            onOpenAlbum?.call();
        }
      },
      itemBuilder: (context) => [
        if (onOpenArtist != null)
          PopupMenuItem(
            key: const ValueKey('player-menu-go-to-artist'),
            value: 'artist',
            child: Row(
              children: [
                Icon(Icons.person_search_rounded, color: menuIconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.goToArtist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (onOpenAlbum != null)
          PopupMenuItem(
            key: const ValueKey('player-menu-go-to-album'),
            value: 'album',
            child: Row(
              children: [
                Icon(Icons.album_rounded, color: menuIconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.goToAlbum,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (snapshot.isRemote && snapshot.sourceUrl != null)
          PopupMenuItem(
            key: const ValueKey('player-menu-download'),
            value: 'download',
            child: Row(
              children: [
                Icon(Icons.download_rounded, color: menuIconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.download,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'playlist',
          child: Row(
            children: [
              Icon(Icons.playlist_add_rounded, color: menuIconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  strings.addToPlaylist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'favorite',
          child: Row(
            children: [
              Icon(
                isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: isFavorite
                    ? Theme.of(context).colorScheme.primary
                    : menuIconColor,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  isFavorite
                      ? strings.removeFromFavorites
                      : strings.addToFavorites,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _downloadCurrent(BuildContext context, WidgetRef ref) async {
    final sourceUrl = snapshot.sourceUrl;
    if (sourceUrl == null || sourceUrl.trim().isEmpty) {
      return;
    }

    try {
      await ref
          .read(downloadControllerProvider.notifier)
          .downloadAudio(_trackInfoFromSnapshot(sourceUrl, ref));
    } catch (_) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(strings.downloadQueueFailed)));
      return;
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(strings.downloadQueued)));
  }

  Future<void> _showPlaylistPicker(BuildContext context, WidgetRef ref) async {
    final currentTrackId = snapshot.trackId;
    if (currentTrackId == null || currentTrackId.trim().isEmpty) {
      return;
    }

    final playlists = (await ref.read(
      playlistsControllerProvider.future,
    )).where((playlist) => !playlist.isFavorites).toList(growable: false);
    if (!context.mounted) {
      return;
    }
    if (playlists.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.createPlaylistFirst)));
      return;
    }

    final localTracks = await ref
        .read(libraryRepositoryProvider)
        .getLocalTracks();
    final catalogPlaylists = await ref.read(catalogPlaylistsProvider.future);
    if (!context.mounted) {
      return;
    }

    final playlistId = await showAppDialog<String>(
      context: context,
      builder: (context) {
        return PlaylistPickerDialog(
          title: strings.choosePlaylist,
          playlists: playlists,
          tracks: localTracks,
          catalogPlaylists: catalogPlaylists,
        );
      },
    );
    if (playlistId == null || !context.mounted) {
      return;
    }

    if (snapshot.isRemote) {
      final sourceUrl = snapshot.sourceUrl;
      if (sourceUrl == null || sourceUrl.trim().isEmpty) {
        return;
      }
      try {
        final added = await ref
            .read(playlistsControllerProvider.notifier)
            .addRemoteTrackToPlaylist(
              playlistId,
              _trackInfoFromSnapshot(sourceUrl, ref),
            );
        if (added == null) {
          return;
        }
      } catch (error) {
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error.toString())));
        return;
      }
      if (!context.mounted) {
        return;
      }
    } else {
      await ref
          .read(playlistsControllerProvider.notifier)
          .addTrackToPlaylist(playlistId, currentTrackId);
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.songAddedToPlaylist)));
  }

  TrackInfo _trackInfoFromSnapshot(String sourceUrl, WidgetRef ref) {
    final canonical = ref
        .read(playerControllerProvider.notifier)
        .currentRemoteTrackFor(sourceUrl);
    if (canonical != null) {
      return canonical;
    }
    return TrackInfo(
      id: snapshot.trackId ?? sourceUrl,
      title: snapshot.title ?? strings.noTitle,
      artist: snapshot.artist ?? strings.unknownArtist,
      url: sourceUrl,
      thumbnailUrl: snapshot.thumbnailUrl,
      duration: snapshot.duration,
      album: snapshot.album,
    );
  }
}

Future<void> _toggleFavoriteForSnapshot({
  required BuildContext context,
  required WidgetRef ref,
  required PlayerSnapshot snapshot,
  required bool isFavorite,
  required String? savedTrackId,
  required AppStrings strings,
}) async {
  var trackId = savedTrackId;
  final currentTrackId = snapshot.trackId?.trim();

  if (trackId == null && !snapshot.isRemote) {
    trackId = currentTrackId;
  }
  if (trackId == null && isFavorite && !snapshot.isRemote) {
    trackId = currentTrackId;
  }

  if (trackId == null || trackId.isEmpty) {
    final sourceUrl = snapshot.sourceUrl?.trim();
    if (sourceUrl == null || sourceUrl.isEmpty) {
      return;
    }

    try {
      final canonical = ref
          .read(playerControllerProvider.notifier)
          .currentRemoteTrackFor(sourceUrl);
      final remote =
          canonical ??
          TrackInfo(
            id: snapshot.trackId ?? sourceUrl,
            title: snapshot.title ?? strings.noTitle,
            artist: snapshot.artist ?? strings.unknownArtist,
            url: sourceUrl,
            thumbnailUrl: snapshot.thumbnailUrl,
            duration: snapshot.duration,
            album: snapshot.album,
          );
      // Remote tracks are added to Favorites first. Downloading is a
      // best-effort follow-up, so a network failure cannot lose the like.
      final isNowFavorite = await ref
          .read(playlistsControllerProvider.notifier)
          .toggleFavoriteRemote(remote);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              isNowFavorite
                  ? strings.addedToFavorites
                  : strings.removedFromFavorites,
            ),
          ),
        );
      return;
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }
  }

  final isNowFavorite = await ref
      .read(playlistsControllerProvider.notifier)
      .toggleFavorite(trackId);
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          isNowFavorite
              ? strings.addedToFavorites
              : strings.removedFromFavorites,
        ),
      ),
    );
}

LocalTrack? _savedTrackForSnapshot(
  List<LocalTrack> tracks, {
  required String? trackId,
  required String? sourceUrl,
}) {
  final normalizedId = trackId?.trim();
  if (normalizedId != null && normalizedId.isNotEmpty) {
    for (final track in tracks) {
      if (track.id == normalizedId) {
        return track;
      }
    }
  }

  final normalizedSource = sourceUrl?.trim();
  if (normalizedSource == null || normalizedSource.isEmpty) {
    return null;
  }
  for (final track in tracks) {
    if (track.sourceUrl?.trim() == normalizedSource) {
      return track;
    }
  }
  return null;
}

class _Timeline extends ConsumerWidget {
  const _Timeline();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timeline = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        return (
          position: snapshot?.position ?? Duration.zero,
          duration: snapshot?.duration,
          isPlaying: snapshot?.status == PlayerStatus.playing,
        );
      }),
    );
    final position = timeline.position;
    final duration = timeline.duration;
    final progressColor = AppColors.downloadAccentFor(context);
    final positionLabel = formatDuration(position);
    final durationLabel = formatDuration(duration);
    final labelStyle = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        fontWeight: FontWeight.w900,
        color: AppColors.contentSubtitleFor(context),
      ),
    );
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);

    double labelWidth(String label) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      return painter.width;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final stackLabels =
            labelWidth(positionLabel) + labelWidth(durationLabel) + 16 >
            constraints.maxWidth;
        final labels = stackLabels
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(positionLabel, style: labelStyle),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(durationLabel, style: labelStyle),
                  ),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(positionLabel, style: labelStyle),
                  Text(durationLabel, style: labelStyle),
                ],
              );

        return Column(
          children: [
            labels,
            const SizedBox(height: 6),
            _WavySeekBar(
              position: position,
              duration: duration,
              isPlaying: timeline.isPlaying,
              waveColor: progressColor,
              onSeek: (next) =>
                  ref.read(playerControllerProvider.notifier).seek(next),
            ),
          ],
        );
      },
    );
  }
}

class _WavySeekBar extends StatefulWidget {
  const _WavySeekBar({
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.waveColor,
    required this.onSeek,
  });

  final Duration position;
  final Duration? duration;
  final bool isPlaying;
  final Color waveColor;
  final ValueChanged<Duration> onSeek;

  @override
  State<_WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<_WavySeekBar>
    with SingleTickerProviderStateMixin {
  static const _trackInset = 10.0;
  late final AnimationController _wavePhase;
  double? _dragFraction;

  @override
  void initState() {
    super.initState();
    _wavePhase = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _WavySeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _wavePhase.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.isPlaying) {
      _wavePhase.repeat();
    } else {
      _wavePhase.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration?.inMilliseconds ?? 0;
    final currentMs = widget.position.inMilliseconds.clamp(0, totalMs);
    final timelineFraction = totalMs <= 0 ? 0.0 : currentMs / totalMs;
    final fraction = _dragFraction ?? timelineFraction;
    final canSeek = totalMs > 0;

    String percentageFor(int milliseconds) {
      final seekFraction = milliseconds / totalMs;
      return '${(seekFraction * 100).round()}%';
    }

    final currentValue = '${(fraction * 100).round()}%';
    final increasedValue = canSeek
        ? percentageFor(
            (currentMs + const Duration(seconds: 10).inMilliseconds).clamp(
              0,
              totalMs,
            ),
          )
        : null;
    final decreasedValue = canSeek
        ? percentageFor(
            (currentMs - const Duration(seconds: 10).inMilliseconds).clamp(
              0,
              totalMs,
            ),
          )
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        double fractionFromDx(double dx) {
          if (totalMs <= 0) {
            return 0;
          }
          final trackWidth = constraints.maxWidth - (_trackInset * 2);
          if (trackWidth <= 0) {
            return 0;
          }
          return ((dx - _trackInset) / trackWidth).clamp(0.0, 1.0).toDouble();
        }

        void commitFraction(double nextFraction) {
          if (totalMs <= 0) {
            return;
          }
          widget.onSeek(
            Duration(milliseconds: (totalMs * nextFraction).round()),
          );
        }

        void seekBy(Duration delta) {
          final target = (currentMs + delta.inMilliseconds).clamp(0, totalMs);
          widget.onSeek(Duration(milliseconds: target));
        }

        return Semantics(
          slider: true,
          enabled: canSeek,
          value: currentValue,
          increasedValue: increasedValue,
          decreasedValue: decreasedValue,
          onIncrease: canSeek
              ? () => seekBy(const Duration(seconds: 10))
              : null,
          onDecrease: canSeek
              ? () => seekBy(const Duration(seconds: -10))
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) =>
                commitFraction(fractionFromDx(details.localPosition.dx)),
            onHorizontalDragStart: (details) => setState(
              () => _dragFraction = fractionFromDx(details.localPosition.dx),
            ),
            onHorizontalDragUpdate: (details) => setState(
              () => _dragFraction = fractionFromDx(details.localPosition.dx),
            ),
            onHorizontalDragEnd: (_) {
              final committed = _dragFraction;
              setState(() => _dragFraction = null);
              if (committed != null) {
                commitFraction(committed);
              }
            },
            onHorizontalDragCancel: () => setState(() => _dragFraction = null),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: TweenAnimationBuilder<Color?>(
                key: const ValueKey('player-progress-color-animation'),
                tween: ColorTween(end: widget.waveColor),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                builder: (context, color, _) => CustomPaint(
                  painter: _WavySeekBarPainter(
                    fraction: fraction,
                    phase: _wavePhase,
                    enabled: totalMs > 0,
                    waveColor: color ?? AppColors.downloadAccentFor(context),
                    isDark: Theme.of(context).brightness == Brightness.dark,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WavySeekBarPainter extends CustomPainter {
  _WavySeekBarPainter({
    required this.fraction,
    required this.phase,
    required this.enabled,
    required this.waveColor,
    required this.isDark,
  }) : super(repaint: phase);

  static const _trackInset = 10.0;
  static const _trackHalfHeight = 3.0;
  static const _maxWaveHeight = 15.5;

  final double fraction;
  final Animation<double> phase;
  final bool enabled;
  final Color waveColor;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final trackStart = _trackInset;
    final trackEnd = size.width - _trackInset;
    final trackWidth = math.max(0.0, trackEnd - trackStart);
    final activeEnd = trackStart + (trackWidth * fraction.clamp(0.0, 1.0));
    final inactivePaint = Paint()
      ..color = enabled
          ? (isDark ? const Color(0x66E7ECE8) : const Color(0x665E6A62))
          : (isDark ? const Color(0x526B756E) : const Color(0x523B463F))
      ..strokeWidth = _trackHalfHeight * 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(trackStart, centerY),
      Offset(trackEnd, centerY),
      inactivePaint,
    );

    final activeLength = activeEnd - trackStart;
    if (activeLength > 0.5) {
      final waveBaseY = centerY - _trackHalfHeight;
      final earlyProgress = (fraction / 0.5).clamp(0.0, 1.0);
      final easedProgress =
          earlyProgress * earlyProgress * (3 - (2 * earlyProgress));
      final progressHeightScale = 0.78 + (0.22 * easedProgress);
      final heightScale =
          (activeLength / 90).clamp(0.0, 1.0) * progressHeightScale;
      final activeBasePaint = Paint()
        ..color = waveColor.withAlpha(220)
        ..strokeWidth = _trackHalfHeight * 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(trackStart, centerY),
        Offset(activeEnd, centerY),
        activeBasePaint,
      );

      ({
        double center,
        double radius,
        double heightFactor,
        double skew,
        double shape,
      })
      movingCrest({
        required double offset,
        required double speedVariation,
        required double secondVariation,
        required double radiusFactor,
        required double heightFactor,
        required double pulseOffset,
        required double skew,
        required double shape,
      }) {
        final rawTravel = (phase.value + offset) % 1.0;
        final travel =
            rawTravel -
            ((speedVariation / (math.pi * 2)) *
                math.sin(math.pi * 2 * rawTravel)) -
            ((secondVariation / (math.pi * 4)) *
                math.sin(math.pi * 4 * rawTravel));
        final pulse =
            0.82 + (0.18 * math.sin((math.pi * 2 * rawTravel) + pulseOffset));
        final radiusPulse =
            0.9 + (0.1 * math.cos((math.pi * 2 * rawTravel) + pulseOffset));
        return (
          center: trackStart + (activeLength * travel),
          radius: radiusFactor * radiusPulse,
          heightFactor: heightFactor * pulse,
          skew: skew,
          shape: shape,
        );
      }

      final broadRadius = math
          .min(112.0, math.max(32.0, activeLength * 0.3))
          .toDouble();

      Path waveLayerPath(
        List<
          ({
            double center,
            double radius,
            double heightFactor,
            double skew,
            double shape,
          })
        >
        crests,
      ) {
        final path = Path()..moveTo(trackStart, waveBaseY);
        for (var x = trackStart; x <= activeEnd; x += 1.5) {
          var combinedHeight = 0.0;
          for (final crest in crests) {
            final normalized = (x - crest.center) / crest.radius;
            if (normalized <= -1 || normalized >= 1) {
              continue;
            }
            final localProgress = (normalized + 1) / 2;
            final profile = math
                .pow(math.sin(math.pi * localProgress), crest.shape)
                .toDouble();
            final rawVisibility = math.min(
              ((crest.center - trackStart) / crest.radius).clamp(0.0, 1.0),
              ((activeEnd - crest.center) / crest.radius).clamp(0.0, 1.0),
            );
            final crestVisibility =
                rawVisibility * rawVisibility * (3 - (2 * rawVisibility));
            final edgeDistance = math.min(x - trackStart, activeEnd - x);
            final edgeProgress = (edgeDistance / 24).clamp(0.0, 1.0);
            final edgeVisibility =
                edgeProgress * edgeProgress * (3 - (2 * edgeProgress));
            final asymmetricProfile =
                profile * (1 + (crest.skew * (localProgress - 0.5)));
            final crestHeight =
                _maxWaveHeight *
                crest.heightFactor *
                heightScale *
                crestVisibility *
                edgeVisibility *
                asymmetricProfile;
            combinedHeight = math.max(combinedHeight, crestHeight);
          }
          path.lineTo(x, waveBaseY - combinedHeight);
        }
        return path
          ..lineTo(activeEnd, waveBaseY)
          ..close();
      }

      final backWave = waveLayerPath([
        movingCrest(
          offset: 0.02,
          speedVariation: 0.38,
          secondVariation: -0.16,
          radiusFactor: broadRadius * 1.02,
          heightFactor: 0.72,
          pulseOffset: 0.4,
          skew: -0.28,
          shape: 1.05,
        ),
        movingCrest(
          offset: 0.5,
          speedVariation: -0.24,
          secondVariation: 0.18,
          radiusFactor: broadRadius * 0.7,
          heightFactor: 0.64,
          pulseOffset: 2.1,
          skew: 0.34,
          shape: 1.55,
        ),
      ]);
      final backPaint = Paint()
        ..color = waveColor.withAlpha(188)
        ..style = PaintingStyle.fill;
      canvas.drawPath(backWave, backPaint);

      final frontWave = waveLayerPath([
        movingCrest(
          offset: 0.25,
          speedVariation: -0.34,
          secondVariation: -0.14,
          radiusFactor: broadRadius * 0.82,
          heightFactor: 1,
          pulseOffset: 1.25,
          skew: 0.22,
          shape: 1.25,
        ),
        movingCrest(
          offset: 0.74,
          speedVariation: 0.3,
          secondVariation: 0.12,
          radiusFactor: broadRadius * 0.58,
          heightFactor: 0.86,
          pulseOffset: 3.4,
          skew: -0.38,
          shape: 1.8,
        ),
      ]);
      final frontPaint = Paint()
        ..color = waveColor.withAlpha(220)
        ..style = PaintingStyle.fill;
      canvas.drawPath(frontWave, frontPaint);
      canvas.drawCircle(
        Offset(trackStart, centerY),
        _trackHalfHeight,
        Paint()..color = waveColor.withAlpha(225),
      );
    }

    final thumbCenter = Offset(activeEnd, centerY);
    canvas.drawCircle(
      thumbCenter,
      12.5,
      Paint()..color = Colors.black.withValues(alpha: isDark ? 0.15 : 0.1),
    );
    canvas.drawCircle(
      thumbCenter,
      10.5,
      Paint()
        ..color = enabled
            ? Color.lerp(
                waveColor,
                isDark ? Colors.white : Colors.black,
                0.18,
              )!.withAlpha(236)
            : (isDark ? const Color(0xFF747D76) : const Color(0xFF9AA59D)),
    );
    canvas.drawCircle(
      thumbCenter,
      10.5,
      Paint()
        ..color = isDark ? const Color(0x704A544C) : const Color(0x705B665E)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _WavySeekBarPainter oldDelegate) {
    return fraction != oldDelegate.fraction ||
        enabled != oldDelegate.enabled ||
        waveColor != oldDelegate.waveColor ||
        isDark != oldDelegate.isDark;
  }
}
