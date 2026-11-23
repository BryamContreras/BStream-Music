part of 'player_panel.dart';

/// The cover-led Spotify arrangement uses the existing playback actions,
/// artwork pipeline and utility controls rather than a second player instance.
class _SpotifyPlayerLayout extends StatelessWidget {
  const _SpotifyPlayerLayout({
    required this.snapshot,
    required this.artworkSource,
    required this.artworkFallbackSource,
    required this.visualIdentity,
    required this.trackTransitionsEnabled,
    required this.artworkStyle,
    required this.animatedArtworkEnabled,
    required this.canvasUrl,
    required this.autoFitInsetArtwork,
    required this.videoStartOffset,
    required this.videoDurationHint,
    required this.drawBackground,
    required this.hasTrack,
    required this.isFavorite,
    required this.savedTrackId,
    required this.hasError,
    required this.errorText,
    required this.queueVisible,
    required this.onToggleQueue,
    required this.onCollapse,
    required this.onOpenLyrics,
    required this.onOpenSearch,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final String? artworkSource;
  final String? artworkFallbackSource;
  final String visualIdentity;
  final bool trackTransitionsEnabled;
  final PlayerArtworkStyle artworkStyle;
  final bool animatedArtworkEnabled;
  final Uri? canvasUrl;
  final bool autoFitInsetArtwork;
  final Duration videoStartOffset;
  final Duration videoDurationHint;
  final bool drawBackground;
  final bool hasTrack;
  final bool isFavorite;
  final String? savedTrackId;
  final bool hasError;
  final String? errorText;
  final bool queueVisible;
  final VoidCallback onToggleQueue;
  final VoidCallback? onCollapse;
  final VoidCallback onOpenLyrics;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onOpenArtist;
  final VoidCallback? onOpenAlbum;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final bottomInset = math.max(
      MediaQuery.viewPaddingOf(context).bottom,
      MediaQuery.paddingOf(context).bottom,
    );
    final topInset = _playerTopSafeInset(context);
    final expandedArtworkTop = _expandedArtworkHeroTop(
      systemTopInset: topInset,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final mobile = AppPlatform.isMobileTargetPlatform(
          Theme.of(context).platform,
        );
        final landscape = constraints.maxWidth > constraints.maxHeight;
        final twoColumn =
            constraints.maxWidth >= (mobile ? 480 : 800) &&
            constraints.maxHeight >= 240 &&
            landscape;
        final padding = twoColumn ? 24.0 : 20.0;
        final availableWidth = math.max(
          0.0,
          constraints.maxWidth - padding * 2,
        );
        final compact = constraints.maxHeight - topInset - bottomInset < 680;
        final metadataCompactness = _playerControlsCompactness(
          constraints,
          mobileLandscape: mobile && landscape,
          systemBottomInset: bottomInset,
        );
        final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
        final scrollPortrait =
            !twoColumn &&
            (constraints.maxHeight - topInset < 600 || textScale > 1.8);
        final expandedArtwork =
            artworkStyle == PlayerArtworkStyle.expanded &&
            artworkSource?.trim().isNotEmpty == true;
        final useExpandedArtworkHero =
            expandedArtwork &&
            mobile &&
            !landscape &&
            !twoColumn &&
            constraints.maxWidth <= 480 &&
            textScale <= 1.8;
        final controls = _SpotifyPlayerControls(
          snapshot: snapshot,
          visualIdentity: visualIdentity,
          trackTransitionsEnabled: trackTransitionsEnabled,
          hasTrack: hasTrack,
          isFavorite: isFavorite,
          savedTrackId: savedTrackId,
          hasError: hasError,
          errorText: errorText,
          compact: compact,
          metadataCompactness: metadataCompactness,
          queueVisible: queueVisible,
          onToggleQueue: onToggleQueue,
          onOpenLyrics: onOpenLyrics,
          onOpenSearch: onOpenSearch,
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
          strings: strings,
        );
        Widget cover(double extent, {required double canvasWidth}) {
          if (useExpandedArtworkHero) {
            return Center(
              child: _ExpandedArtworkPlaceholder(
                maxExtent: extent,
                isFavorite: false,
              ),
            );
          }
          return LayoutBuilder(
            builder: (context, coverConstraints) {
              final visualExtent = expandedArtwork
                  ? math.min(
                      canvasWidth,
                      math.min(extent * 1.18, coverConstraints.maxHeight),
                    )
                  : extent;
              final baseExtent = math.min(extent, visualExtent);
              return Center(
                child: SizedBox(
                  width: visualExtent,
                  height: visualExtent,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: _LargeArtwork(
                      url: artworkSource,
                      fallbackUrl: artworkFallbackSource,
                      identity: visualIdentity,
                      isPlaying: snapshot.status == PlayerStatus.playing,
                      trackTransitionsEnabled: trackTransitionsEnabled,
                      artworkStyle: artworkStyle,
                      expandedTargetWidth: visualExtent,
                      fullBleedExpanded: false,
                      animatedArtworkEnabled: animatedArtworkEnabled,
                      canvasUrl: canvasUrl,
                      videoStartOffset: videoStartOffset,
                      videoDurationHint: videoDurationHint,
                      maxExtent: baseExtent,
                      isFavorite: false,
                      shadowCompactness: .7,
                      shadowHorizontalClearance: padding,
                      borderRadius: 6,
                    ),
                  ),
                ),
              );
            },
          );
        }

        Widget body(BoxConstraints bodyConstraints) {
          if (twoColumn) {
            final gap = mobile ? 24.0 : 48.0;
            final artworkWidth = math.min((availableWidth - gap) * .5, 520.0);
            final extent = math.max(
              0.0,
              math.min(artworkWidth, bodyConstraints.maxHeight - 8),
            );
            return Row(
              key: const ValueKey('spotify-player-adaptive-two-column'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: artworkWidth,
                  child: cover(extent, canvasWidth: artworkWidth),
                ),
                SizedBox(width: gap),
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('spotify-player-controls-scroll'),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: bodyConstraints.maxHeight,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: controls,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          final extent = math.min(availableWidth, 480.0);
          final artworkCanvasWidth = expandedArtwork && mobile
              ? constraints.maxWidth
              : math.min(availableWidth, 520.0);
          final content = ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              key: const ValueKey('spotify-player-adaptive-stack'),
              mainAxisSize: scrollPortrait
                  ? MainAxisSize.min
                  : MainAxisSize.max,
              children: [
                if (scrollPortrait)
                  cover(
                    math.min(extent, 360.0),
                    canvasWidth: artworkCanvasWidth,
                  )
                else
                  Expanded(
                    child: cover(extent, canvasWidth: artworkCanvasWidth),
                  ),
                SizedBox(height: compact ? 16 : 26),
                controls,
              ],
            ),
          );
          return scrollPortrait
              ? SingleChildScrollView(
                  key: const ValueKey('spotify-player-scroll'),
                  child: Center(child: content),
                )
              : Center(child: content);
        }

        final content = Padding(
          padding: EdgeInsets.fromLTRB(
            padding,
            topInset + 4,
            padding,
            (compact ? 8 : 18) + bottomInset,
          ),
          child: Column(
            children: [
              PlayerCollapseHandle(
                key: const ValueKey('spotify-player-grabber'),
                onCollapse: onCollapse,
                label: strings.minimizePlayer,
              ),
              SizedBox(height: compact ? 4 : 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, bodyConstraints) => body(bodyConstraints),
                ),
              ),
            ],
          ),
        );
        return Stack(
          key: const ValueKey('spotify-player-layout'),
          fit: StackFit.expand,
          children: [
            if (drawBackground)
              Positioned.fill(
                child: PlaybackArtworkBackdrop(
                  followArtworkVideo: true,
                  source: artworkSource,
                  fallbackSource: artworkFallbackSource,
                  animateTrackChanges: false,
                  reflectionArtworkRect: useExpandedArtworkHero
                      ? _expandedArtworkHeroImageRect(
                          constraints.maxWidth,
                          top: expandedArtworkTop,
                        )
                      : null,
                ),
              ),
            if (useExpandedArtworkHero)
              Positioned(
                top: expandedArtworkTop,
                left: 0,
                right: 0,
                height: _expandedArtworkHeroHeight(
                  constraints,
                  top: expandedArtworkTop,
                ),
                child: _ExpandedArtworkHero(
                  url: artworkSource,
                  fallbackUrl: artworkFallbackSource,
                  identity: visualIdentity,
                  isPlaying: snapshot.status == PlayerStatus.playing,
                  trackTransitionsEnabled: trackTransitionsEnabled,
                  animatedArtworkEnabled: animatedArtworkEnabled,
                  canvasUrl: canvasUrl,
                  autoFitInsetArtwork: autoFitInsetArtwork,
                  videoStartOffset: videoStartOffset,
                  videoDurationHint: videoDurationHint,
                ),
              ),
            content,
          ],
        );
      },
    );
  }
}

class _SpotifyPlayerControls extends ConsumerWidget {
  const _SpotifyPlayerControls({
    required this.snapshot,
    required this.visualIdentity,
    required this.trackTransitionsEnabled,
    required this.hasTrack,
    required this.isFavorite,
    required this.savedTrackId,
    required this.hasError,
    required this.errorText,
    required this.compact,
    required this.metadataCompactness,
    required this.queueVisible,
    required this.onToggleQueue,
    required this.onOpenLyrics,
    required this.onOpenSearch,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    required this.strings,
  });
  final PlayerSnapshot snapshot;
  final String visualIdentity;
  final bool trackTransitionsEnabled;
  final bool hasTrack;
  final bool isFavorite;
  final String? savedTrackId;
  final bool hasError;
  final String? errorText;
  final bool compact;
  final double metadataCompactness;
  final bool queueVisible;
  final VoidCallback onToggleQueue;
  final VoidCallback onOpenLyrics;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onOpenArtist;
  final VoidCallback? onOpenAlbum;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foreground = AppColors.playbackControlForegroundFor(context);
    final secondary = AppColors.playbackSecondaryControlForegroundFor(context);
    final active = Theme.of(context).colorScheme.primary;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final isPlaying = snapshot.status == PlayerStatus.playing;
    final player = ref.read(playerControllerProvider.notifier);
    final gap = compact ? 12.0 : 20.0;
    final transportSpacing = _playerTransportSpacing(
      before: gap,
      after: gap,
      timelineTail:
          12 + math.max(20.0, MediaQuery.textScalerOf(context).scale(16)),
    );
    final side = compact ? 48.0 : 54.0;
    final primary = compact ? 68.0 : 76.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TrackChangeTransition(
                switcherKey: const ValueKey(
                  'spotify-player-metadata-track-transition',
                ),
                identity: visualIdentity,
                enabled: trackTransitionsEnabled,
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MarqueeText(
                      key: const ValueKey('player-track-title'),
                      snapshot.title ?? strings.noPlayback,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: AppColors.playbackTitleFor(context),
                        fontWeight: FontWeight.w800,
                        fontSize: _playerTitleFontSize(
                          context,
                          metadataCompactness,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    InkWell(
                      key: const ValueKey('player-track-artist-action'),
                      onTap: onOpenArtist,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          snapshot.artist ?? 'BStream Music',
                          key: const ValueKey('player-track-artist'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: secondary,
                                fontWeight: FontWeight.w600,
                                fontSize: _playerArtistFontSize(
                                  context,
                                  metadataCompactness,
                                ),
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!snapshot.isExternal) ...[
              _PlayerFavoriteButton(
                snapshot: snapshot,
                isFavorite: isFavorite,
                savedTrackId: savedTrackId,
                strings: strings,
                compact: compact,
              ),
              _PlayerMenu(
                snapshot: snapshot,
                isFavorite: isFavorite,
                savedTrackId: savedTrackId,
                onOpenSearch: onOpenSearch,
                onOpenArtist: onOpenArtist,
                onOpenAlbum: onOpenAlbum,
                strings: strings,
                compact: compact,
              ),
            ],
          ],
        ),
        SizedBox(height: gap),
        _AppleMusicTimeline(
          strings: strings,
          compact: compact,
          trackHeight: 3,
          sliderHeight: 24,
          showThumb: true,
          sliderKey: const ValueKey('spotify-player-linear-seek'),
        ),
        SizedBox(height: transportSpacing.before),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: 4 * side + primary + (compact ? 8 : 24),
            child: Row(
              key: const ValueKey('spotify-player-transport'),
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ControlButton(
                  key: const ValueKey('player-shuffle-control'),
                  size: side,
                  tooltip: snapshot.shuffleEnabled
                      ? strings.deactivateShuffle
                      : strings.activateShuffle,
                  iconSize: 26,
                  color: snapshot.shuffleEnabled ? active : secondary,
                  icon: Icons.shuffle_rounded,
                  onPressed: hasTrack ? () => player.toggleShuffle() : null,
                ),
                _ControlButton(
                  key: const ValueKey('player-previous-control'),
                  size: side,
                  tooltip: strings.previous,
                  iconSize: 38,
                  color: foreground,
                  icon: Icons.skip_previous_rounded,
                  onPressed: hasTrack ? () => player.playPrevious() : null,
                ),
                SizedBox.square(
                  dimension: primary,
                  child: IconButton(
                    key: const ValueKey('player-primary-control'),
                    tooltip: isPlaying ? strings.pause : strings.play,
                    style: IconButton.styleFrom(
                      backgroundColor: dark ? Colors.white : foreground,
                      disabledBackgroundColor:
                          (dark ? Colors.white : foreground).withValues(
                            alpha: .38,
                          ),
                      shape: const CircleBorder(),
                    ),
                    color: dark ? Colors.black : Colors.white,
                    disabledColor: (dark ? Colors.black : Colors.white)
                        .withValues(alpha: .5),
                    iconSize: 42,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints.tight(Size.square(primary)),
                    icon: PlaybackControlIcon(
                      isLoading: snapshot.status == PlayerStatus.loading,
                      isPlaying: isPlaying,
                      loadingLabel: strings.playbackLoading,
                    ),
                    onPressed: hasTrack ? () => player.togglePlayPause() : null,
                  ),
                ),
                _ControlButton(
                  key: const ValueKey('player-next-control'),
                  size: side,
                  tooltip: strings.next,
                  iconSize: 38,
                  color: foreground,
                  icon: Icons.skip_next_rounded,
                  onPressed: hasTrack ? () => player.playNext() : null,
                ),
                _ControlButton(
                  key: const ValueKey('player-repeat-control'),
                  size: side,
                  tooltip: switch (snapshot.repeatMode) {
                    PlaybackRepeatMode.off => strings.repeatQueue,
                    PlaybackRepeatMode.all => strings.repeatOne,
                    PlaybackRepeatMode.one => strings.disableRepeat,
                  },
                  iconSize: 26,
                  color: snapshot.repeatMode == PlaybackRepeatMode.off
                      ? secondary
                      : active,
                  icon: snapshot.repeatMode == PlaybackRepeatMode.one
                      ? Icons.repeat_one_rounded
                      : Icons.repeat_rounded,
                  onPressed: hasTrack ? () => player.cycleRepeatMode() : null,
                ),
              ],
            ),
          ),
        ),
        SizedBox(height: transportSpacing.after),
        _PlayerUtilityControls(
          showCapsule: false,
          snapshot: snapshot,
          hasTrack: hasTrack,
          queueVisible: queueVisible,
          onToggleQueue: onToggleQueue,
          onOpenLyrics: onOpenLyrics,
          strings: strings,
          size: compact ? 48 : 54,
          iconSize: compact ? 25 : 28,
          color: foreground,
        ),
        if (hasError) ...[
          const SizedBox(height: 8),
          PlayerErrorMessage(message: errorText ?? strings.playbackError),
        ],
      ],
    );
  }
}
