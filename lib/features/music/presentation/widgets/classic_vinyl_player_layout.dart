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
            // The vinyl deck keeps its signature expanded composition in both
            // artwork modes. The artwork preference still affects the other
            // player styles, but switching between classic/expanded covers
            // must not shrink or re-center this turntable.
            final deckUsesExpandedGeometry =
                artworkStyle == PlayerArtworkStyle.classic ||
                artworkStyle == PlayerArtworkStyle.expanded;
            final expandedPortrait = !twoColumn && deckUsesExpandedGeometry;
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
            // On compact portrait phones, reserve more height for the
            // metadata, timeline, and transport controls instead of letting
            // the vinyl dominate the whole viewport. Larger phones keep the
            // roomy deck proportions used by the emulator.
            final compactPortraitViewport = !twoColumn && availableWidth < 400;
            final portraitDeckWidthFactor =
                expandedPortrait && compactPortraitViewport ? 0.90 : 1.02;
            // Very short viewports cannot spare the visual-clearance gap;
            // their compact fallback keeps the entire control stack reachable.
            final portraitDeckOverflowFactor = expandedPortrait
                ? (bodyHeight < 620
                      ? 0.075
                      : compactPortraitViewport
                      ? 0.195
                      : 0.18)
                : 0.0;
            final gap = twoColumn
                ? (mobileLandscape ? 14.0 : 44.0)
                : (constraints.maxHeight < 650 ? 10.0 : 18.0);
            final twoColumnAvailable = math.max(0.0, availableWidth - gap);
            const minimumLandscapeControlsWidth = 240.0;
            final preferredDeckPaneWidth = mobileLandscape
                ? twoColumnAvailable * (availableWidth < 700 ? 0.46 : 0.48)
                : twoColumnAvailable * 0.5;
            final deckPaneWidth = twoColumn
                ? math.min(
                    mobileLandscape
                        ? math.min(
                            preferredDeckPaneWidth,
                            math.max(
                              0.0,
                              twoColumnAvailable -
                                  minimumLandscapeControlsWidth,
                            ),
                          )
                        : preferredDeckPaneWidth,
                    560.0,
                  )
                : availableWidth;
            const minimumRoomyControlsHeight = 285.0;
            final regularPortraitDeckExtent = expandedPortrait
                ? math
                      .min(
                        availableWidth * portraitDeckWidthFactor,
                        bodyHeight * 0.60,
                      )
                      .clamp(210.0, 500.0)
                      .toDouble()
                : math
                      .min(deckPaneWidth, bodyHeight * 0.56)
                      .clamp(200.0, 460.0)
                      .toDouble();
            final regularDeckControlsGap = expandedPortrait
                ? (regularPortraitDeckExtent * portraitDeckOverflowFactor + 8)
                      .clamp(30.0, 100.0)
                      .toDouble()
                : gap;
            final compactPortrait =
                !twoColumn &&
                bodyHeight -
                        regularPortraitDeckExtent -
                        regularDeckControlsGap <
                    minimumRoomyControlsHeight;
            final deckExtent = twoColumn
                ? math.min(deckPaneWidth, bodyHeight * 0.98)
                : expandedPortrait
                ? math
                      .min(
                        availableWidth * portraitDeckWidthFactor,
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
                ? (deckExtent * portraitDeckOverflowFactor + 8)
                      .clamp(30.0, 100.0)
                      .toDouble()
                : gap;
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
              // Only give the lower controls the extra breathing room on
              // phones with enough vertical budget. Very short 320x568
              // frames retain their original compact metrics to avoid
              // introducing scroll just to enlarge a control.
              smallPhone: compactPortraitViewport && bodyHeight >= 620,
              tight: tightLandscape,
              roomy: roomyPortrait,
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
                expanded: deckUsesExpandedGeometry,
                portraitLayout: !twoColumn,
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
                  Positioned(
                    top: 0,
                    right: expandedPortrait ? contentHorizontalPadding : 0,
                    child: SizedBox.square(
                      dimension: 44,
                      child: IconButton(
                        key: const ValueKey('player-queue-toggle'),
                        tooltip: strings.playbackQueue,
                        isSelected: queueVisible,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                        color: queueVisible
                            ? Theme.of(context).colorScheme.primary
                            : AppColors.playbackControlForegroundFor(context),
                        iconSize: 24,
                        icon: const Icon(Icons.queue_music_rounded),
                        selectedIcon: const Icon(Icons.queue_music_rounded),
                        onPressed: onToggleQueue,
                      ),
                    ),
                  ),
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
    required this.portraitLayout,
  });

  final String? artworkSource;
  final String? artworkFallbackSource;
  final String visualIdentity;
  final bool isPlaying;
  final bool animationEnabled;
  final bool trackTransitionsEnabled;
  final bool expanded;
  final bool portraitLayout;

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
      portraitLayout: portraitLayout,
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
    required this.smallPhone,
    required this.tight,
    required this.roomy,
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
  final bool smallPhone;
  final bool tight;
  final bool roomy;
  final VoidCallback onOpenLyrics;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onOpenArtist;
  final VoidCallback? onOpenAlbum;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foreground = AppColors.playbackControlForegroundFor(context);
    final secondary = AppColors.playbackSecondaryControlForegroundFor(context);
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
                  ? (smallPhone ? 24 : 21)
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
                            ? (smallPhone ? 17 : 15)
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
                  compact: tight,
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
                  compact: tight,
                ),
              ],
            ],
          ),
        ],
      ),
    );
    final utilitySize = tight
        ? 40.0
        : compact
        ? (smallPhone ? 56.0 : 44.0)
        : roomy
        ? (smallPhone ? 58.0 : 54.0)
        : (smallPhone ? 52.0 : 48.0);
    final utilityIconSize = tight
        ? 22.0
        : compact
        ? (smallPhone ? 28.0 : 23.0)
        : roomy
        ? (smallPhone ? 30.0 : 28.0)
        : (smallPhone ? 27.0 : 25.0);
    final utilityLabelWidth = tight
        ? 96.0
        : compact
        ? (smallPhone ? 136.0 : 108.0)
        : roomy
        ? (smallPhone ? 144.0 : 136.0)
        : (smallPhone ? 132.0 : 120.0);
    final utilityButtons = Row(
      key: const ValueKey('classic-vinyl-player-utility-row'),
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _LabeledControlButton(
          key: const ValueKey('player-lyrics-control'),
          width: utilityLabelWidth,
          height: utilitySize,
          tooltip: strings.lyrics,
          iconSize: utilityIconSize,
          labelFontSize: smallPhone ? 15.0 : null,
          color: foreground,
          label: strings.lyrics,
          icon: Icons.lyrics_rounded,
          onPressed: hasTrack ? onOpenLyrics : null,
        ),
        _VolumeButton(
          key: const ValueKey('player-volume-control'),
          snapshot: snapshot,
          size: utilitySize,
          width: utilityLabelWidth,
          label: strings.volume,
          tooltip: strings.volume,
          iconSize: utilityIconSize,
          labelFontSize: smallPhone ? 15.0 : null,
          color: foreground,
        ),
      ],
    );
    final utilityRow = utilityButtons;
    final timeline = KeyedSubtree(
      key: const ValueKey('classic-vinyl-player-timeline'),
      child: _AppleMusicTimeline(
        strings: strings,
        compact: compact,
        trackHeight: 6,
        sliderHeight: tight ? 16 : 18,
        activeTrackColor: AppColors.downloadAccentFor(context),
        labelsAbove: true,
        sliderKey: const ValueKey('classic-vinyl-player-linear-seek'),
      ),
    );
    final transport = _ClassicVinylTransportControls(
      hasTrack: hasTrack,
      isPlaying: isPlaying,
      shuffleEnabled: snapshot.shuffleEnabled,
      repeatMode: snapshot.repeatMode,
      compact: compact,
      smallPhone: smallPhone,
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
          height: tight
              ? 2
              : compact
              ? (smallPhone ? 8 : 5)
              : roomy
              ? 16
              : 12,
        ),
        timeline,
        SizedBox(
          height: tight
              ? 2
              : compact
              ? (smallPhone ? 8 : 5)
              : roomy
              ? 16
              : 12,
        ),
        transport,
        SizedBox(
          height: tight
              ? 2
              : compact
              ? (smallPhone ? 6 : 3)
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
    required this.shuffleEnabled,
    required this.repeatMode,
    required this.compact,
    required this.smallPhone,
    required this.roomy,
    required this.strings,
  });

  final bool hasTrack;
  final bool isPlaying;
  final bool shuffleEnabled;
  final PlaybackRepeatMode repeatMode;
  final bool compact;
  final bool smallPhone;
  final bool roomy;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final transportWidth = math.min(width, 420.0);
        const edgeFlex = 105;
        const sideFlex = 110;
        const primaryFlex = 130;
        const totalFlex = (edgeFlex * 2) + (sideFlex * 2) + primaryFlex;
        final edgeSlotWidth = transportWidth * edgeFlex / totalFlex;
        final sideSlotWidth = transportWidth * sideFlex / totalFlex;
        final primarySlotWidth = transportWidth * primaryFlex / totalFlex;
        final edgeButtonSize = math.min(
          edgeSlotWidth,
          compact && smallPhone ? 52.0 : (compact ? 44.0 : 48.0),
        );
        final sideButtonSize = (width * 0.21).clamp(
          compact
              ? (smallPhone ? 58.0 : 48.0)
              : roomy
              ? (smallPhone ? 66.0 : 62.0)
              : (smallPhone ? 62.0 : 58.0),
          compact ? (smallPhone ? 72.0 : 60.0) : (smallPhone ? 80.0 : 76.0),
        );
        final fittedSideButtonSize = math.min(sideButtonSize, sideSlotWidth);
        final primaryButtonSize = (width * 0.252).clamp(
          compact
              ? (smallPhone ? 78.0 : 64.0)
              : roomy
              ? (smallPhone ? 86.0 : 82.0)
              : (smallPhone ? 80.0 : 76.0),
          compact ? (smallPhone ? 94.0 : 78.0) : (smallPhone ? 100.0 : 96.0),
        );
        final fittedPrimaryButtonSize = math.min(
          primaryButtonSize,
          primarySlotWidth,
        );
        final sideIconSize = (fittedSideButtonSize * 0.65).clamp(
          smallPhone ? 33.0 : 31.0,
          50.0,
        );
        final primaryIconSize = isPlaying
            ? (fittedPrimaryButtonSize * 0.80).clamp(40.0, 74.0)
            : (fittedPrimaryButtonSize * 0.92).clamp(44.0, 84.0);
        final foreground = AppColors.playbackControlForegroundFor(context);
        final secondary = AppColors.playbackSecondaryControlForegroundFor(
          context,
        );
        final active = Theme.of(context).colorScheme.primary;

        return Align(
          alignment: Alignment.center,
          child: SizedBox(
            key: const ValueKey('classic-vinyl-player-transport'),
            width: transportWidth,
            child: Row(
              children: [
                Expanded(
                  flex: edgeFlex,
                  child: Center(
                    child: _ControlButton(
                      key: const ValueKey('player-shuffle-control'),
                      size: edgeButtonSize,
                      tooltip: shuffleEnabled
                          ? strings.deactivateShuffle
                          : strings.activateShuffle,
                      iconSize: compact ? (smallPhone ? 25 : 23) : 25,
                      color: shuffleEnabled ? active : secondary,
                      icon: Icons.shuffle_rounded,
                      onPressed: hasTrack
                          ? () => ref
                                .read(playerControllerProvider.notifier)
                                .toggleShuffle()
                          : null,
                    ),
                  ),
                ),
                Expanded(
                  flex: sideFlex,
                  child: Center(
                    child: _ControlButton(
                      key: const ValueKey('player-previous-control'),
                      size: fittedSideButtonSize,
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
                  ),
                ),
                Expanded(
                  flex: primaryFlex,
                  child: Center(
                    child: SizedBox.square(
                      dimension: fittedPrimaryButtonSize,
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
                          Size.square(fittedPrimaryButtonSize),
                        ),
                        iconSize: primaryIconSize,
                        icon: Transform.translate(
                          offset: isPlaying
                              ? Offset.zero
                              : const Offset(1.25, 0),
                          transformHitTests: false,
                          child: Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                          ),
                        ),
                        onPressed: hasTrack
                            ? () => ref
                                  .read(playerControllerProvider.notifier)
                                  .togglePlayPause()
                            : null,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  flex: sideFlex,
                  child: Center(
                    child: _ControlButton(
                      key: const ValueKey('player-next-control'),
                      size: fittedSideButtonSize,
                      tooltip: strings.next,
                      iconSize: sideIconSize,
                      color: foreground,
                      icon: Icons.skip_next_rounded,
                      onPressed: hasTrack
                          ? () => ref
                                .read(playerControllerProvider.notifier)
                                .playNext()
                          : null,
                    ),
                  ),
                ),
                Expanded(
                  flex: edgeFlex,
                  child: Center(
                    child: _ControlButton(
                      key: const ValueKey('player-repeat-control'),
                      size: edgeButtonSize,
                      tooltip: switch (repeatMode) {
                        PlaybackRepeatMode.off => strings.repeatQueue,
                        PlaybackRepeatMode.all => strings.repeatOne,
                        PlaybackRepeatMode.one => strings.disableRepeat,
                      },
                      iconSize: compact ? (smallPhone ? 25 : 23) : 25,
                      color: repeatMode == PlaybackRepeatMode.off
                          ? secondary
                          : active,
                      icon: repeatMode == PlaybackRepeatMode.one
                          ? Icons.repeat_one_rounded
                          : Icons.repeat_rounded,
                      onPressed: hasTrack
                          ? () => ref
                                .read(playerControllerProvider.notifier)
                                .cycleRepeatMode()
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
