part of 'player_panel.dart';

class _ClassicVinylPlayerLayout extends StatelessWidget {
  const _ClassicVinylPlayerLayout({
    required this.snapshot,
    required this.artworkSource,
    required this.artworkFallbackSource,
    required this.visualIdentity,
    required this.trackTransitionsEnabled,
    required this.artworkStyle,
    required this.animatedArtworkEnabled,
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
    final systemBottomInset = math.max(
      MediaQuery.viewPaddingOf(context).bottom,
      MediaQuery.paddingOf(context).bottom,
    );
    return Stack(
      key: const ValueKey('classic-vinyl-player-layout'),
      fit: StackFit.expand,
      children: [
        if (drawBackground) ...[
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
        LayoutBuilder(
          builder: (context, constraints) {
            final mobile = AppPlatform.isMobileTargetPlatform(
              Theme.of(context).platform,
            );
            final mobileLandscape =
                mobile &&
                constraints.maxWidth > constraints.maxHeight &&
                constraints.maxWidth >= 480 &&
                constraints.maxHeight >= 240;
            final contentHorizontalPadding = mobileLandscape
                ? (constraints.maxWidth >= 760 ? 16.0 : 12.0)
                : constraints.maxWidth >= 900
                ? 44.0
                : constraints.maxWidth >= 430
                ? 22.0
                : 16.0;
            final topPadding = mobileLandscape ? 4.0 : 8.0;
            final bottomPadding =
                (mobileLandscape ? 4.0 : 12.0) + systemBottomInset;
            final contentAvailableWidth = math.max(
              0.0,
              constraints.maxWidth - (contentHorizontalPadding * 2),
            );
            final twoColumn =
                mobileLandscape ||
                (!mobile &&
                    contentAvailableWidth >= 760 &&
                    constraints.maxHeight >= 420);
            final expandedPortrait =
                !twoColumn && artworkStyle == PlayerArtworkStyle.expanded;
            final horizontalPadding = expandedPortrait
                ? 0.0
                : contentHorizontalPadding;
            final availableWidth = math.max(
              0.0,
              constraints.maxWidth - (horizontalPadding * 2),
            );
            final bodyTop = mobileLandscape ? 0.0 : 28.0;
            final bodyHeight = math.max(
              0.0,
              constraints.maxHeight - topPadding - bottomPadding - bodyTop,
            );
            final gap = twoColumn
                ? (mobileLandscape ? 14.0 : 44.0)
                : (constraints.maxHeight < 650 ? 10.0 : 18.0);
            final twoColumnAvailable = math.max(0.0, availableWidth - gap);
            final deckPaneWidth = twoColumn
                ? math.min(
                    mobileLandscape
                        ? twoColumnAvailable *
                              (availableWidth < 700 ? 0.46 : 0.48)
                        : twoColumnAvailable * 0.5,
                    560.0,
                  )
                : availableWidth;
            final compactPortrait = !twoColumn && bodyHeight < 620;
            final deckExtent = twoColumn
                ? math.min(deckPaneWidth, bodyHeight * 0.98)
                : expandedPortrait
                ? math
                      .min(
                        availableWidth * 1.02,
                        bodyHeight * (compactPortrait ? 0.47 : 0.60),
                      )
                      .clamp(210.0, 500.0)
                      .toDouble()
                : math
                      .min(
                        deckPaneWidth,
                        bodyHeight * (compactPortrait ? 0.47 : 0.56),
                      )
                      .clamp(200.0, 460.0)
                      .toDouble();
            final deckControlsGap = expandedPortrait
                ? (deckExtent * 0.075 + 8).clamp(30.0, 42.0).toDouble()
                : gap;
            const minimumRoomyControlsHeight = 285.0;
            final portraitControlsHeight = math.max(
              0.0,
              bodyHeight - deckExtent - deckControlsGap,
            );
            final tightLandscape = mobileLandscape && bodyHeight < 330;
            final effectiveTextScale =
                MediaQuery.textScalerOf(context).scale(16) / 16;
            final roomyPortrait =
                !twoColumn &&
                !compactPortrait &&
                portraitControlsHeight >= minimumRoomyControlsHeight &&
                effectiveTextScale <= 1.25 &&
                !hasError;
            final controls = _ClassicVinylControls(
              snapshot: snapshot,
              visualIdentity: visualIdentity,
              trackTransitionsEnabled: trackTransitionsEnabled,
              hasTrack: hasTrack,
              isFavorite: isFavorite,
              savedTrackId: savedTrackId,
              hasError: hasError,
              errorText: errorText,
              compact: compactPortrait || tightLandscape,
              roomy: roomyPortrait,
              queueVisible: queueVisible,
              onToggleQueue: onToggleQueue,
              onOpenLyrics: onOpenLyrics,
              onOpenSearch: onOpenSearch,
              onOpenArtist: onOpenArtist,
              onOpenAlbum: onOpenAlbum,
              strings: strings,
            );
            final deck = SizedBox.square(
              key: const ValueKey('classic-vinyl-player-deck-slot'),
              dimension: deckExtent,
              child: _ClassicVinylPlaybackDeck(
                artworkSource: artworkSource,
                artworkFallbackSource: artworkFallbackSource,
                visualIdentity: visualIdentity,
                isPlaying: snapshot.status == PlayerStatus.playing,
                animationEnabled: animatedArtworkEnabled,
                trackTransitionsEnabled: trackTransitionsEnabled,
                expanded: artworkStyle == PlayerArtworkStyle.expanded,
              ),
            );

            Widget body;
            if (twoColumn) {
              final scrollControls =
                  effectiveTextScale > 1.35 || bodyHeight < 340 || hasError;
              final centeredControls = Align(
                alignment: Alignment.center,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: controls,
                ),
              );
              body = Row(
                key: const ValueKey('classic-vinyl-player-two-column'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: deckPaneWidth,
                    child: Center(child: deck),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: scrollControls
                        ? SingleChildScrollView(
                            key: const ValueKey(
                              'classic-vinyl-player-controls-scroll',
                            ),
                            clipBehavior: Clip.hardEdge,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: bodyHeight,
                              ),
                              child: centeredControls,
                            ),
                          )
                        : centeredControls,
                  ),
                ],
              );
            } else {
              final paddedControls = Padding(
                padding: expandedPortrait
                    ? EdgeInsets.symmetric(horizontal: contentHorizontalPadding)
                    : EdgeInsets.zero,
                child: controls,
              );
              final scrollPortrait =
                  compactPortrait ||
                  portraitControlsHeight < minimumRoomyControlsHeight ||
                  effectiveTextScale > 1.25 ||
                  hasError;
              body = SingleChildScrollView(
                key: const ValueKey('classic-vinyl-player-stack'),
                clipBehavior: expandedPortrait ? Clip.none : Clip.hardEdge,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: bodyHeight),
                  child: scrollPortrait
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                deck,
                                SizedBox(height: deckControlsGap),
                              ],
                            ),
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 520,
                                ),
                                child: paddedControls,
                              ),
                            ),
                          ],
                        )
                      : SizedBox(
                          height: bodyHeight,
                          child: Column(
                            children: [
                              deck,
                              SizedBox(height: deckControlsGap),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, controlRegion) {
                                    final maxControlWidth = expandedPortrait
                                        ? 520 + (contentHorizontalPadding * 2)
                                        : 520.0;
                                    return Center(
                                      child: SizedBox(
                                        width: math.min(
                                          controlRegion.maxWidth,
                                          maxControlWidth,
                                        ),
                                        height: controlRegion.maxHeight,
                                        child: paddedControls,
                                      ),
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

            return Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                topPadding,
                horizontalPadding,
                bottomPadding,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(top: bodyTop, child: body),
                  if (!mobileLandscape)
                    Align(
                      alignment: Alignment.topCenter,
                      child: _ApplePlayerGrabber(
                        onCollapse: onCollapse,
                        label: strings.minimizePlayer,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ClassicVinylPlaybackDeck extends ConsumerWidget {
  const _ClassicVinylPlaybackDeck({
    required this.artworkSource,
    required this.artworkFallbackSource,
    required this.visualIdentity,
    required this.isPlaying,
    required this.animationEnabled,
    required this.trackTransitionsEnabled,
    required this.expanded,
  });

  final String? artworkSource;
  final String? artworkFallbackSource;
  final String visualIdentity;
  final bool isPlaying;
  final bool animationEnabled;
  final bool trackTransitionsEnabled;
  final bool expanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timeline = ref.watch(
      playerControllerProvider.select((player) {
        final value = player.value;
        return (
          position: value?.position ?? Duration.zero,
          duration: value?.duration ?? Duration.zero,
        );
      }),
    );
    final durationMilliseconds = timeline.duration.inMilliseconds;
    final progress = durationMilliseconds <= 0
        ? 0.0
        : (timeline.position.inMilliseconds / durationMilliseconds).clamp(
            0.0,
            1.0,
          );
    return ClassicVinylDeck(
      artworkSource: artworkSource,
      artworkFallbackSource: artworkFallbackSource,
      identity: visualIdentity,
      isPlaying: isPlaying,
      animationEnabled: animationEnabled,
      progress: progress,
      trackTransitionsEnabled: trackTransitionsEnabled,
      expanded: expanded,
    );
  }
}

class _ClassicVinylControls extends ConsumerWidget {
  const _ClassicVinylControls({
    required this.snapshot,
    required this.visualIdentity,
    required this.trackTransitionsEnabled,
    required this.hasTrack,
    required this.isFavorite,
    required this.savedTrackId,
    required this.hasError,
    required this.errorText,
    required this.compact,
    required this.roomy,
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
  final bool roomy;
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
    final isPlaying = snapshot.status == PlayerStatus.playing;
    final metadata = TrackChangeTransition(
      switcherKey: const ValueKey('classic-vinyl-metadata-transition'),
      identity: visualIdentity,
      enabled: trackTransitionsEnabled,
      alignment: Alignment.centerLeft,
      child: Column(
        key: const ValueKey('classic-vinyl-player-metadata'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          MarqueeText(
            key: const ValueKey('player-track-title'),
            snapshot.title ?? strings.noPlayback,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: AppColors.playbackTitleFor(context),
              fontSize: compact
                  ? 21
                  : roomy
                  ? 28
                  : 25,
              fontWeight: FontWeight.w900,
              height: 1.08,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const ValueKey('player-track-artist-action'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: onOpenArtist,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      key: const ValueKey('player-track-artist'),
                      snapshot.artist ?? 'BStream Music',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: secondary,
                        fontSize: compact
                            ? 15
                            : roomy
                            ? 18
                            : 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              if (!snapshot.isExternal) ...[
                _PlayerFavoriteButton(
                  snapshot: snapshot,
                  isFavorite: isFavorite,
                  savedTrackId: savedTrackId,
                  strings: strings,
                  appleStyle: true,
                ),
                _PlayerMenu(
                  snapshot: snapshot,
                  isFavorite: isFavorite,
                  savedTrackId: savedTrackId,
                  onOpenSearch: onOpenSearch,
                  onOpenArtist: onOpenArtist,
                  onOpenAlbum: onOpenAlbum,
                  strings: strings,
                  appleStyle: true,
                ),
              ],
            ],
          ),
        ],
      ),
    );
    final utilitySize = compact
        ? 44.0
        : roomy
        ? 52.0
        : 48.0;
    final utilityIconSize = compact
        ? 23.0
        : roomy
        ? 27.0
        : 25.0;
    final utilityButtons = Row(
      key: const ValueKey('classic-vinyl-player-utility-row'),
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _ControlButton(
          key: const ValueKey('player-shuffle-control'),
          size: utilitySize,
          tooltip: snapshot.shuffleEnabled
              ? strings.deactivateShuffle
              : strings.activateShuffle,
          iconSize: utilityIconSize,
          color: snapshot.shuffleEnabled ? active : secondary,
          icon: Icons.shuffle_rounded,
          onPressed: hasTrack
              ? () =>
                    ref.read(playerControllerProvider.notifier).toggleShuffle()
              : null,
        ),
        _ControlButton(
          key: const ValueKey('player-lyrics-control'),
          size: utilitySize,
          tooltip: strings.lyrics,
          iconSize: utilityIconSize,
          color: foreground,
          icon: Icons.lyrics_rounded,
          onPressed: hasTrack ? onOpenLyrics : null,
        ),
        _ControlButton(
          key: const ValueKey('player-repeat-control'),
          size: utilitySize,
          tooltip: switch (snapshot.repeatMode) {
            PlaybackRepeatMode.off => strings.repeatQueue,
            PlaybackRepeatMode.all => strings.repeatOne,
            PlaybackRepeatMode.one => strings.disableRepeat,
          },
          iconSize: utilityIconSize,
          color: snapshot.repeatMode == PlaybackRepeatMode.off
              ? secondary
              : active,
          icon: snapshot.repeatMode == PlaybackRepeatMode.one
              ? Icons.repeat_one_rounded
              : Icons.repeat_rounded,
          onPressed: hasTrack
              ? () => ref
                    .read(playerControllerProvider.notifier)
                    .cycleRepeatMode()
              : null,
        ),
        _VolumeButton(
          key: const ValueKey('player-volume-control'),
          snapshot: snapshot,
          size: utilitySize,
          tooltip: strings.volume,
          iconSize: utilityIconSize,
          color: foreground,
        ),
        SizedBox.square(
          dimension: utilitySize,
          child: IconButton(
            key: const ValueKey('player-queue-toggle'),
            tooltip: strings.playbackQueue,
            isSelected: queueVisible,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tight(Size.square(utilitySize)),
            color: queueVisible ? active : foreground,
            iconSize: utilityIconSize,
            icon: const Icon(Icons.queue_music_rounded),
            selectedIcon: const Icon(Icons.queue_music_rounded),
            onPressed: onToggleQueue,
          ),
        ),
      ],
    );
    final utilityRow = utilityButtons;
    final timeline = KeyedSubtree(
      key: const ValueKey('classic-vinyl-player-timeline'),
      child: _AppleMusicTimeline(
        strings: strings,
        compact: compact,
        trackHeight: 4,
        sliderHeight: 18,
        activeTrackColor: AppColors.downloadAccentFor(context),
        sliderKey: const ValueKey('classic-vinyl-player-linear-seek'),
      ),
    );
    final transport = _ClassicVinylTransportControls(
      hasTrack: hasTrack,
      isPlaying: isPlaying,
      compact: compact,
      roomy: roomy,
      strings: strings,
    );

    if (roomy) {
      return Column(
        key: const ValueKey('classic-vinyl-player-controls'),
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [metadata, timeline, transport, utilityRow],
      );
    }

    return Column(
      key: const ValueKey('classic-vinyl-player-controls'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        metadata,
        SizedBox(
          height: compact
              ? 5
              : roomy
              ? 16
              : 12,
        ),
        timeline,
        SizedBox(
          height: compact
              ? 5
              : roomy
              ? 16
              : 12,
        ),
        transport,
        SizedBox(
          height: compact
              ? 3
              : roomy
              ? 12
              : 8,
        ),
        Center(child: utilityRow),
        if (hasError) ...[
          SizedBox(height: compact ? 6 : 10),
          PlayerErrorMessage(
            key: const ValueKey('player-error-message'),
            message: errorText ?? strings.playbackError,
          ),
        ],
      ],
    );
  }
}

class _ClassicVinylTransportControls extends ConsumerWidget {
  const _ClassicVinylTransportControls({
    required this.hasTrack,
    required this.isPlaying,
    required this.compact,
    required this.roomy,
    required this.strings,
  });

  final bool hasTrack;
  final bool isPlaying;
  final bool compact;
  final bool roomy;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final sideButtonSize = (width * 0.21).clamp(
          compact
              ? 52.0
              : roomy
              ? 64.0
              : 58.0,
          compact ? 64.0 : 76.0,
        );
        final primaryButtonSize = (width * 0.252).clamp(
          compact
              ? 72.0
              : roomy
              ? 84.0
              : 76.0,
          compact ? 88.0 : 116.0,
        );
        final sideIconSize = (sideButtonSize * 0.65).clamp(38.0, 50.0);
        final primaryIconSize = isPlaying
            ? (primaryButtonSize * 0.80).clamp(58.0, 76.0)
            : (primaryButtonSize * 0.92).clamp(68.0, 88.0);
        final centerGap = (width * 0.04).clamp(
          compact ? 8.0 : 12.0,
          compact ? 18.0 : 34.0,
        );
        final foreground = AppColors.playbackControlForegroundFor(context);

        return Row(
          key: const ValueKey('classic-vinyl-player-transport'),
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ControlButton(
              key: const ValueKey('player-previous-control'),
              size: sideButtonSize,
              tooltip: strings.previous,
              iconSize: sideIconSize,
              color: foreground,
              icon: Icons.skip_previous_rounded,
              onPressed: hasTrack
                  ? () => ref
                        .read(playerControllerProvider.notifier)
                        .playPrevious()
                  : null,
            ),
            SizedBox(width: centerGap),
            SizedBox.square(
              dimension: primaryButtonSize,
              child: IconButton(
                key: const ValueKey('player-primary-control'),
                tooltip: isPlaying ? strings.pause : strings.play,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  disabledBackgroundColor: Colors.transparent,
                ),
                color: foreground,
                disabledColor: foreground.withValues(alpha: 0.38),
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tight(
                  Size.square(primaryButtonSize),
                ),
                iconSize: primaryIconSize,
                icon: Transform.translate(
                  offset: isPlaying ? Offset.zero : const Offset(1.25, 0),
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
            ),
            SizedBox(width: centerGap),
            _ControlButton(
              key: const ValueKey('player-next-control'),
              size: sideButtonSize,
              tooltip: strings.next,
              iconSize: sideIconSize,
              color: foreground,
              icon: Icons.skip_next_rounded,
              onPressed: hasTrack
                  ? () => ref.read(playerControllerProvider.notifier).playNext()
                  : null,
            ),
          ],
        );
      },
    );
  }
}
