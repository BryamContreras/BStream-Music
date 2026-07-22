import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/utils/image_source.dart';
import '../../../../services/player/player_service.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import 'favorite_star_badge.dart';
import 'now_playing_equalizer.dart';
import 'playback_gradient_background.dart';
import 'playlist_picker_dialog.dart';

class PlayerPanel extends ConsumerStatefulWidget {
  const PlayerPanel({this.onOpenSearch, this.drawBackground = true, super.key});

  final VoidCallback? onOpenSearch;
  final bool drawBackground;

  @override
  ConsumerState<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends ConsumerState<PlayerPanel> {
  bool _showPlaybackQueue = false;

  @override
  Widget build(BuildContext context) {
    final presentation = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot =
            player.value ?? const PlayerSnapshot(status: PlayerStatus.idle);
        return (
          status: snapshot.status,
          title: snapshot.title,
          artist: snapshot.artist,
          trackId: snapshot.trackId,
          sourceUrl: snapshot.sourceUrl,
          thumbnailUrl: snapshot.thumbnailUrl,
          duration: snapshot.duration,
          volume: snapshot.volume,
          errorMessage: snapshot.errorMessage,
          isRemote: snapshot.isRemote,
          shuffleEnabled: snapshot.shuffleEnabled,
          repeatMode: snapshot.repeatMode,
          hasError: player.hasError,
          errorText: player.error?.toString(),
        );
      }),
    );
    final strings = ref.watch(appStringsProvider);
    final playbackQueue = ref.watch(playbackQueueProvider);
    final favoriteTrackIds = ref.watch(favoriteTrackIdsProvider);
    final localTracks =
        ref.watch(libraryTracksProvider).value ?? const <LocalTrack>[];
    final savedTrackId = _savedTrackIdForSnapshot(
      localTracks,
      trackId: presentation.trackId,
      sourceUrl: presentation.sourceUrl,
    );
    final currentTrackId = presentation.trackId;
    final isFavorite =
        (currentTrackId != null && favoriteTrackIds.contains(currentTrackId)) ||
        (savedTrackId != null && favoriteTrackIds.contains(savedTrackId));
    final snapshot = PlayerSnapshot(
      status: presentation.status,
      title: presentation.title,
      artist: presentation.artist,
      trackId: presentation.trackId,
      sourceUrl: presentation.sourceUrl,
      thumbnailUrl: presentation.thumbnailUrl,
      duration: presentation.duration,
      volume: presentation.volume,
      errorMessage: presentation.errorMessage,
      isRemote: presentation.isRemote,
      shuffleEnabled: presentation.shuffleEnabled,
      repeatMode: presentation.repeatMode,
    );
    final hasTrack =
        snapshot.title != null ||
        snapshot.artist != null ||
        presentation.hasError;

    return LayoutBuilder(
      builder: (context, outer) {
        final wide = outer.maxWidth >= 840;
        final stackedDesktop = AppPlatform.isDesktop && wide;
        final showSideQueue = AppPlatform.isDesktop && _showPlaybackQueue;
        final heightCompactness = AppPlatform.isDesktop
            ? ((680.0 - outer.maxHeight) / 140.0).clamp(0.0, 1.0)
            : 0.0;
        final regularTopPadding = wide ? (showSideQueue ? 12.0 : 20.0) : 10.0;
        final regularBottomPadding = wide
            ? (showSideQueue ? 12.0 : 24.0)
            : 20.0;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              key: const ValueKey('desktop-player-surface'),
              child: Stack(
                children: [
                  if (widget.drawBackground) ...[
                    _BlurredPlayerBackground(url: snapshot.thumbnailUrl),
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Color(0x70101A14),
                              Color(0x80080D0A),
                              Color(0x8C070B08),
                              Color(0x98080C09),
                            ],
                            stops: [0, 0.38, 0.72, 1],
                          ),
                        ),
                      ),
                    ),
                  ],
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      wide ? (showSideQueue ? 16 : 34) : 20,
                      lerpDouble(regularTopPadding, 8, heightCompactness)!,
                      wide ? (showSideQueue ? 16 : 34) : 20,
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
                            if (AppPlatform.isAndroid) {
                              unawaited(_openMobilePlaybackQueue(context));
                              return;
                            }
                            setState(() {
                              _showPlaybackQueue = !_showPlaybackQueue;
                            });
                          },
                          strings: strings,
                        ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final verticalCompactness = AppPlatform.isDesktop
                                  ? ((620.0 - constraints.maxHeight) / 140.0)
                                        .clamp(0.0, 1.0)
                                  : 0.0;
                              final artworkExtent = _artworkExtent(
                                constraints,
                                stackedDesktop: stackedDesktop,
                                wide: wide,
                                compactness: verticalCompactness,
                              );
                              final artwork = Center(
                                child: _LargeArtwork(
                                  url: snapshot.thumbnailUrl,
                                  maxExtent: artworkExtent,
                                  isFavorite: isFavorite,
                                ),
                              );
                              final gap = lerpDouble(
                                26,
                                12,
                                verticalCompactness,
                              )!;
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
                              final controls = _PlayerControls(
                                snapshot: snapshot,
                                hasTrack: hasTrack,
                                hasError: presentation.hasError,
                                errorText: presentation.errorText,
                                compact: !wide || stackedDesktop,
                                compactness: verticalCompactness,
                                maxWidth: stackedDesktop
                                    ? maxContentWidth
                                    : 520.0,
                                showVolumeButton: false,
                                strings: strings,
                              );

                              return SingleChildScrollView(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight,
                                  ),
                                  child: Center(
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: maxContentWidth,
                                      ),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          artwork,
                                          SizedBox(height: gap),
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
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (currentChild, _) =>
                  currentChild ?? const SizedBox.shrink(),
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: showSideQueue
                  ? SizedBox(
                      key: const ValueKey('desktop-playback-queue-rail'),
                      width: outer.maxWidth >= 1180 ? 360 : 320,
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
    required double compactness,
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
          .min(constraints.maxWidth - 16, constraints.maxHeight * 0.46)
          .clamp(210.0, 360.0)
          .toDouble();
    }

    final compactExtent = math
        .min(constraints.maxWidth * 0.31, constraints.maxHeight * 0.4)
        .clamp(170.0, 220.0)
        .toDouble();
    return lerpDouble(regularExtent, compactExtent, compactness)!;
  }
}

class _BlurredPlayerBackground extends StatelessWidget {
  const _BlurredPlayerBackground({required this.url});

  final String? url;

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
            child: _SourceImage(
              source: source,
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
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final bool isFavorite;
  final String? savedTrackId;
  final VoidCallback? onOpenSearch;
  final bool queueVisible;
  final VoidCallback onToggleQueue;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 58,
      child: Row(
        children: [
          _HeaderIconSlot(
            child: IconButton(
              tooltip: strings.playbackQueue,
              isSelected: queueVisible,
              style: IconButton.styleFrom(
                backgroundColor: queueVisible
                    ? Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.12)
                    : Colors.transparent,
              ),
              icon: const Icon(Icons.queue_music_rounded, size: 28),
              selectedIcon: const Icon(Icons.queue_music_rounded, size: 28),
              onPressed: onToggleQueue,
            ),
          ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  strings.nowPlaying,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: const Color(0xFFF4FFF5),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  snapshot.artist ?? 'BStream Music',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
          _HeaderIconSlot(
            child: _PlayerMenu(
              snapshot: snapshot,
              isFavorite: isFavorite,
              savedTrackId: savedTrackId,
              onOpenSearch: onOpenSearch,
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
            color: standaloneRail
                ? const Color(0xA0040504)
                : const Color(0xB0090C0A),
            borderRadius: standaloneRail ? null : BorderRadius.circular(6),
            border: standaloneRail
                ? const Border(left: BorderSide(color: Color(0xFF121812)))
                : Border.all(color: colors.onSurface.withValues(alpha: 0.14)),
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
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox.square(
                      dimension: 24,
                      child: IconButton(
                        tooltip: strings.close,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 24,
                          height: 24,
                        ),
                        icon: const Icon(Icons.close_rounded, size: 17),
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
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: queue.entries.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 2),
                        itemBuilder: (context, index) {
                          final entry = queue.entries[index];
                          final isCurrent = index == queue.currentIndex;
                          return _PlaybackQueueTile(
                            entry: entry,
                            isCurrent: isCurrent,
                            isPlaying: isCurrent && isPlaying,
                            onTap: isCurrent
                                ? null
                                : () {
                                    unawaited(
                                      ref
                                          .read(
                                            playerControllerProvider.notifier,
                                          )
                                          .playQueueIndex(index),
                                    );
                                  },
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

class _PlaybackQueueTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: isCurrent
            ? colors.onSurface.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 46,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: ColoredBox(
                          color: const Color(0xFF202520),
                          child: entry.thumbnailUrl == null
                              ? const Icon(Icons.music_note_rounded, size: 22)
                              : _SourceImage(
                                  source: entry.thumbnailUrl!,
                                  fit: BoxFit.cover,
                                  fallback: const Icon(
                                    Icons.music_note_rounded,
                                    size: 22,
                                  ),
                                ),
                        ),
                      ),
                      if (isCurrent)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Center(
                            child: NowPlayingEqualizer(
                              key: ValueKey('queue-now-playing-${entry.id}'),
                              isPlaying: isPlaying,
                              width: 42,
                              height: 14,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: isCurrent
                              ? FontWeight.w900
                              : FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
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

class _LargeArtwork extends StatelessWidget {
  const _LargeArtwork({
    required this.url,
    required this.maxExtent,
    required this.isFavorite,
  });

  final String? url;
  final double maxExtent;
  final bool isFavorite;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxExtent, maxHeight: maxExtent),
      child: AspectRatio(
        aspectRatio: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0xAA000000),
                blurRadius: 42,
                spreadRadius: 6,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF35E987), Color(0xFF176235)],
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
                      : _SourceImage(
                          source: url!,
                          fit: BoxFit.cover,
                          fallback: Icon(
                            Icons.music_note_rounded,
                            size: 108,
                            color: Theme.of(
                              context,
                            ).colorScheme.onPrimaryContainer,
                          ),
                        ),
                ),
                if (isFavorite)
                  const Positioned(
                    top: 6,
                    right: 6,
                    child: FavoriteStarBadge(iconSize: 26),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceImage extends StatelessWidget {
  const _SourceImage({
    required this.source,
    required this.fit,
    required this.fallback,
  });

  final String source;
  final BoxFit fit;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final normalized = source.trim();
    if (isNetworkImageSource(normalized)) {
      return Image.network(
        normalized,
        fit: fit,
        errorBuilder: (_, _, _) => fallback,
      );
    }

    final file = imageFileFromSource(normalized);
    if (file == null) {
      return fallback;
    }
    if (!file.existsSync()) {
      return fallback;
    }

    return Image.file(file, fit: fit, errorBuilder: (_, _, _) => fallback);
  }
}

class _FallbackBackground extends StatelessWidget {
  const _FallbackBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF111611), Color(0xFF070907), Color(0xFF030403)],
        ),
      ),
    );
  }
}

class _PlayerControls extends ConsumerWidget {
  const _PlayerControls({
    required this.snapshot,
    required this.hasTrack,
    required this.hasError,
    required this.errorText,
    required this.compact,
    required this.compactness,
    required this.maxWidth,
    required this.showVolumeButton,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final bool hasTrack;
  final bool hasError;
  final String? errorText;
  final bool compact;
  final double compactness;
  final double maxWidth;
  final bool showVolumeButton;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPlaying = snapshot.status == PlayerStatus.playing;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            snapshot.title ?? strings.noPlayback,
            maxLines: compact ? 2 : 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontSize: lerpDouble(
                compact ? 28 : 42,
                compact ? 24 : 34,
                compactness,
              ),
              fontWeight: FontWeight.w900,
              color: const Color(0xFFF8FFF9),
            ),
          ),
          SizedBox(height: lerpDouble(6, 4, compactness)),
          Text(
            snapshot.artist ?? 'BStream Music',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize: lerpDouble(
                compact ? 18 : 26,
                compact ? 16 : 21,
                compactness,
              ),
              fontWeight: FontWeight.w800,
              color: const Color(0xFFE2EFE5),
            ),
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
            showVolumeButton: showVolumeButton,
            strings: strings,
          ),
          if (hasError) ...[
            SizedBox(height: lerpDouble(18, 10, compactness)),
            Text(
              errorText ?? strings.playbackError,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlaybackButtons extends ConsumerWidget {
  const _PlaybackButtons({
    required this.snapshot,
    required this.hasTrack,
    required this.isPlaying,
    required this.compact,
    required this.compactness,
    required this.showVolumeButton,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final bool hasTrack;
  final bool isPlaying;
  final bool compact;
  final double compactness;
  final bool showVolumeButton;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeColor = Theme.of(context).colorScheme.primary;
    final inactiveColor = const Color(0xFFC9D4CC);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final narrow = width < 360;
        final roomy = width >= 420 || !compact;
        final regularSmallButtonSize = roomy
            ? (width * 0.105).clamp(48.0, compact ? 52.0 : 56.0)
            : (width * 0.105).clamp(34.0, 40.0);
        final compactSmallButtonSize = (width * 0.09).clamp(42.0, 46.0);
        final smallButtonSize = lerpDouble(
          regularSmallButtonSize,
          compactSmallButtonSize,
          compactness,
        )!;
        final regularSideButtonSize = (width * 0.145).clamp(
          roomy ? 56.0 : 44.0,
          compact ? 62.0 : 72.0,
        );
        final compactSideButtonSize = (width * 0.115).clamp(46.0, 54.0);
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
        final smallIconSize = (smallButtonSize * 0.62).clamp(22.0, 34.0);
        final sideIconSize = (sideButtonSize * 0.84).clamp(36.0, 58.0);
        final playIconSize = (playSize * 0.62).clamp(40.0, 64.0);
        final centerGap = narrow ? 9.0 : (width * 0.034).clamp(9.0, 32.0);
        final outerGap = narrow ? 16.0 : (width * 0.075).clamp(16.0, 60.0);
        final showVolume = showVolumeButton && width >= 430;

        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ControlButton(
                  size: smallButtonSize,
                  tooltip: snapshot.shuffleEnabled
                      ? strings.deactivateShuffle
                      : strings.activateShuffle,
                  iconSize: smallIconSize,
                  color: snapshot.shuffleEnabled ? activeColor : inactiveColor,
                  icon: Icons.shuffle_rounded,
                  onPressed: hasTrack
                      ? () => ref
                            .read(playerControllerProvider.notifier)
                            .toggleShuffle()
                      : null,
                ),
                SizedBox(width: outerGap),
                _ControlButton(
                  size: sideButtonSize,
                  tooltip: strings.previous,
                  iconSize: sideIconSize,
                  color: const Color(0xFFF5FFF7),
                  icon: Icons.skip_previous_rounded,
                  onPressed: hasTrack
                      ? () => ref
                            .read(playerControllerProvider.notifier)
                            .playPrevious()
                      : null,
                ),
                SizedBox(width: centerGap),
                SizedBox(
                  width: playSize,
                  height: playSize,
                  child: IconButton.filled(
                    tooltip: isPlaying ? strings.pause : strings.play,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints.tight(Size.square(playSize)),
                    iconSize: playIconSize,
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
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
                  size: sideButtonSize,
                  tooltip: strings.next,
                  iconSize: sideIconSize,
                  color: const Color(0xFFF5FFF7),
                  icon: Icons.skip_next_rounded,
                  onPressed: hasTrack
                      ? () => ref
                            .read(playerControllerProvider.notifier)
                            .playNext()
                      : null,
                ),
                SizedBox(width: outerGap),
                _ControlButton(
                  size: smallButtonSize,
                  tooltip: switch (snapshot.repeatMode) {
                    PlaybackRepeatMode.off => strings.repeatQueue,
                    PlaybackRepeatMode.all => strings.repeatOne,
                    PlaybackRepeatMode.one => strings.disableRepeat,
                  },
                  iconSize: smallIconSize,
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
                ),
                if (showVolume) ...[
                  SizedBox(width: outerGap),
                  _VolumeButton(
                    snapshot: snapshot,
                    size: smallButtonSize,
                    tooltip: strings.volume,
                    iconSize: smallIconSize,
                    color: const Color(0xFFE4EEE7),
                  ),
                ],
              ],
            ),
          ),
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
  });

  final PlayerSnapshot snapshot;
  final double size;
  final String tooltip;
  final double iconSize;
  final Color color;

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
              targetAnchor: Alignment.topRight,
              followerAnchor: Alignment.bottomRight,
              offset: const Offset(0, -8),
              child: _VolumePopover(onClose: _hidePopover),
            ),
          ],
        );
      },
      child: CompositedTransformTarget(
        link: _layerLink,
        child: _ControlButton(
          size: widget.size,
          tooltip: widget.tooltip,
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

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 282,
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 10),
        decoration: BoxDecoration(
          color: const Color(0xFF202820),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF354136)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x99000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    strings.volume,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: const Color(0xFFF4FFF5),
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Semantics(
                  label: strings.close,
                  button: true,
                  child: SizedBox.square(
                    dimension: 28,
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded),
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      onPressed: onClose,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 30,
              child: Row(
                children: [
                  Icon(
                    _volumeIcon(volume),
                    color: const Color(0xFFE4EEE7),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 8,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                      ),
                      child: Slider(
                        value: volume,
                        onChanged: (value) => unawaited(
                          ref
                              .read(playerControllerProvider.notifier)
                              .setVolume(value),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 42,
                    child: Text(
                      '${(volume * 100).round()}%',
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        color: Color(0xFFF4FFF5),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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

class _PlayerMenu extends ConsumerWidget {
  const _PlayerMenu({
    required this.snapshot,
    required this.isFavorite,
    required this.savedTrackId,
    required this.onOpenSearch,
    required this.strings,
  });

  final PlayerSnapshot snapshot;
  final bool isFavorite;
  final String? savedTrackId;
  final VoidCallback? onOpenSearch;
  final AppStrings strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      enabled: snapshot.trackId != null,
      tooltip: strings.moreOptions,
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert_rounded, size: 34),
      onSelected: (value) {
        switch (value) {
          case 'download':
            _downloadCurrent(context, ref);
          case 'playlist':
            unawaited(_showPlaylistPicker(context, ref));
          case 'favorite':
            unawaited(_toggleFavorite(context, ref));
          case 'volume':
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) {
                _showVolumeControl(context);
              }
            });
        }
      },
      itemBuilder: (context) => [
        if (snapshot.isRemote && snapshot.sourceUrl != null)
          PopupMenuItem(
            value: 'download',
            child: Row(
              children: [
                const Icon(Icons.download_rounded),
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
              const Icon(Icons.playlist_add_rounded),
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
                isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
                color: isFavorite ? const Color(0xFFFFD54F) : null,
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
        if (AppPlatform.isAndroid || AppPlatform.isDesktop)
          PopupMenuItem(
            value: 'volume',
            child: Row(
              children: [
                const Icon(Icons.volume_up_rounded),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    strings.volumeControl,
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

  void _showVolumeControl(BuildContext context) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    var closed = false;

    void close() {
      if (closed) {
        return;
      }
      closed = true;
      if (!entry.mounted) {
        return;
      }
      entry.remove();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        entry.dispose();
      });
    }

    entry = OverlayEntry(
      builder: (overlayContext) {
        final top = MediaQuery.paddingOf(overlayContext).top + 64;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: close,
              ),
            ),
            Positioned(
              top: top,
              right: 12,
              child: _VolumePopover(onClose: close),
            ),
          ],
        );
      },
    );
    overlay.insert(entry);
  }

  void _downloadCurrent(BuildContext context, WidgetRef ref) {
    final sourceUrl = snapshot.sourceUrl;
    if (sourceUrl == null || sourceUrl.trim().isEmpty) {
      return;
    }

    ref
        .read(downloadControllerProvider.notifier)
        .downloadAudio(_trackInfoFromSnapshot(sourceUrl));
    onOpenSearch?.call();
  }

  Future<void> _toggleFavorite(BuildContext context, WidgetRef ref) async {
    var trackId = savedTrackId;
    final currentTrackId = snapshot.trackId?.trim();

    if (trackId == null && !snapshot.isRemote) {
      trackId = currentTrackId;
    }
    if (trackId == null && isFavorite) {
      trackId = currentTrackId;
    }

    if (trackId == null || trackId.isEmpty) {
      final sourceUrl = snapshot.sourceUrl?.trim();
      if (sourceUrl == null || sourceUrl.isEmpty) {
        return;
      }

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(strings.downloading)));
      try {
        final localTrack = await ref
            .read(downloadControllerProvider.notifier)
            .downloadAudioForLibrary(_trackInfoFromSnapshot(sourceUrl));
        trackId = localTrack.id;
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
    if (!context.mounted) {
      return;
    }

    final playlistId = await showDialog<String>(
      context: context,
      builder: (context) {
        return PlaylistPickerDialog(
          title: strings.choosePlaylist,
          playlists: playlists,
          tracks: localTracks,
        );
      },
    );
    if (playlistId == null || !context.mounted) {
      return;
    }

    var trackId = currentTrackId;
    if (snapshot.isRemote) {
      final sourceUrl = snapshot.sourceUrl;
      if (sourceUrl == null || sourceUrl.trim().isEmpty) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(strings.downloading)));
      try {
        final localTrack = await ref
            .read(downloadControllerProvider.notifier)
            .downloadAudioForLibrary(_trackInfoFromSnapshot(sourceUrl));
        trackId = localTrack.id;
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
    }

    await ref
        .read(playlistsControllerProvider.notifier)
        .addTrackToPlaylist(playlistId, trackId);
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(strings.songAddedToPlaylist)));
  }

  TrackInfo _trackInfoFromSnapshot(String sourceUrl) {
    return TrackInfo(
      id: snapshot.trackId ?? sourceUrl,
      title: snapshot.title ?? strings.noTitle,
      artist: snapshot.artist ?? strings.unknownArtist,
      url: sourceUrl,
      thumbnailUrl: snapshot.thumbnailUrl,
      duration: snapshot.duration,
    );
  }
}

String? _savedTrackIdForSnapshot(
  List<LocalTrack> tracks, {
  required String? trackId,
  required String? sourceUrl,
}) {
  final normalizedId = trackId?.trim();
  if (normalizedId != null && normalizedId.isNotEmpty) {
    for (final track in tracks) {
      if (track.id == normalizedId) {
        return track.id;
      }
    }
  }

  final normalizedSource = sourceUrl?.trim();
  if (normalizedSource == null || normalizedSource.isEmpty) {
    return null;
  }
  for (final track in tracks) {
    if (track.sourceUrl?.trim() == normalizedSource) {
      return track.id;
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
          thumbnailUrl: snapshot?.thumbnailUrl,
        );
      }),
    );
    final position = timeline.position;
    final duration = timeline.duration;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              formatDuration(position),
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFFF5FFF7),
              ),
            ),
            Text(
              formatDuration(duration),
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFFF5FFF7),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        _WavySeekBar(
          position: position,
          duration: duration,
          isPlaying: timeline.isPlaying,
          artworkUrl: timeline.thumbnailUrl,
          onSeek: (next) =>
              ref.read(playerControllerProvider.notifier).seek(next),
        ),
      ],
    );
  }
}

class _WavySeekBar extends StatefulWidget {
  const _WavySeekBar({
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.artworkUrl,
    required this.onSeek,
  });

  final Duration position;
  final Duration? duration;
  final bool isPlaying;
  final String? artworkUrl;
  final ValueChanged<Duration> onSeek;

  @override
  State<_WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<_WavySeekBar>
    with SingleTickerProviderStateMixin {
  static const _trackInset = 10.0;
  static const _fallbackWaveColor = Color(0xFF91CDA7);
  late final AnimationController _wavePhase;
  ImageStream? _artworkStream;
  ImageStreamListener? _artworkListener;
  String? _resolvedArtworkSource;
  var _colorRequest = 0;
  Color _waveColor = _fallbackWaveColor;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveWaveColor();
  }

  @override
  void didUpdateWidget(covariant _WavySeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncAnimation();
    }
    if (oldWidget.artworkUrl != widget.artworkUrl) {
      _resolveWaveColor();
    }
  }

  @override
  void dispose() {
    _detachArtworkListener();
    _wavePhase.dispose();
    super.dispose();
  }

  void _resolveWaveColor() {
    final source = widget.artworkUrl?.trim();
    if (_resolvedArtworkSource == source) {
      return;
    }
    _resolvedArtworkSource = source;
    _detachArtworkListener();
    final request = ++_colorRequest;

    ImageProvider<Object>? provider;
    if (source != null && source.isNotEmpty) {
      if (isNetworkImageSource(source)) {
        provider = NetworkImage(source);
      } else {
        final file = imageFileFromSource(source);
        if (file != null && file.existsSync()) {
          provider = FileImage(file);
        }
      }
    }

    if (provider == null) {
      if (_waveColor != _fallbackWaveColor) {
        setState(() => _waveColor = _fallbackWaveColor);
      }
      return;
    }

    final stream = provider.resolve(
      createLocalImageConfiguration(context, size: const Size.square(32)),
    );
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (imageInfo, _) async {
        stream.removeListener(listener);
        if (identical(_artworkStream, stream)) {
          _artworkStream = null;
          _artworkListener = null;
        }
        final color = await _extractArtworkTint(imageInfo);
        if (!mounted || request != _colorRequest || color == null) {
          return;
        }
        setState(() => _waveColor = color);
      },
      onError: (_, _) {
        stream.removeListener(listener);
        if (identical(_artworkStream, stream)) {
          _artworkStream = null;
          _artworkListener = null;
        }
      },
    );
    _artworkStream = stream;
    _artworkListener = listener;
    stream.addListener(listener);
  }

  Future<Color?> _extractArtworkTint(ImageInfo imageInfo) async {
    const sampleSize = 24;
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      imageInfo.image,
      Rect.fromLTWH(
        0,
        0,
        imageInfo.image.width.toDouble(),
        imageInfo.image.height.toDouble(),
      ),
      const Rect.fromLTWH(0, 0, 24, 24),
      Paint()..filterQuality = FilterQuality.low,
    );
    final picture = recorder.endRecording();
    final sampledImage = await picture.toImage(sampleSize, sampleSize);
    picture.dispose();
    final data = await sampledImage.toByteData(format: ImageByteFormat.rawRgba);
    sampledImage.dispose();
    if (data == null) {
      return null;
    }

    final bytes = data.buffer.asUint8List();
    var hueX = 0.0;
    var hueY = 0.0;
    var saturationSum = 0.0;
    var totalWeight = 0.0;
    for (var index = 0; index + 3 < bytes.length; index += 4) {
      final alpha = bytes[index + 3] / 255;
      if (alpha < 0.2) {
        continue;
      }
      final hsl = HSLColor.fromColor(
        Color.fromARGB(
          bytes[index + 3],
          bytes[index],
          bytes[index + 1],
          bytes[index + 2],
        ),
      );
      final midtoneWeight =
          1 - ((hsl.lightness - 0.5).abs() * 0.55).clamp(0.0, 0.45);
      final weight = alpha * (0.12 + (hsl.saturation * 0.88)) * midtoneWeight;
      final radians = hsl.hue * math.pi / 180;
      hueX += math.cos(radians) * weight;
      hueY += math.sin(radians) * weight;
      saturationSum += hsl.saturation * weight;
      totalWeight += weight;
    }
    if (totalWeight <= 0.001) {
      return null;
    }

    final hue = (math.atan2(hueY, hueX) * 180 / math.pi + 360) % 360;
    final saturation = (saturationSum / totalWeight).clamp(0.28, 0.62);
    return HSLColor.fromAHSL(1, hue, saturation, 0.73).toColor();
  }

  void _detachArtworkListener() {
    final stream = _artworkStream;
    final listener = _artworkListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _artworkStream = null;
    _artworkListener = null;
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
    final fraction = totalMs <= 0 ? 0.0 : currentMs / totalMs;

    return LayoutBuilder(
      builder: (context, constraints) {
        void seekFromDx(double dx) {
          if (totalMs <= 0) {
            return;
          }
          final trackWidth = constraints.maxWidth - (_trackInset * 2);
          final nextFraction = ((dx - _trackInset) / trackWidth).clamp(
            0.0,
            1.0,
          );
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
          enabled: totalMs > 0,
          value: '${(fraction * 100).round()}%',
          onIncrease: totalMs <= 0
              ? null
              : () => seekBy(const Duration(seconds: 10)),
          onDecrease: totalMs <= 0
              ? null
              : () => seekBy(const Duration(seconds: -10)),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => seekFromDx(details.localPosition.dx),
            onHorizontalDragStart: (details) =>
                seekFromDx(details.localPosition.dx),
            onHorizontalDragUpdate: (details) =>
                seekFromDx(details.localPosition.dx),
            child: SizedBox(
              width: double.infinity,
              height: 38,
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: _waveColor),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                builder: (context, color, _) => CustomPaint(
                  painter: _WavySeekBarPainter(
                    fraction: fraction,
                    phase: _wavePhase,
                    enabled: totalMs > 0,
                    waveColor: color ?? _fallbackWaveColor,
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
  }) : super(repaint: phase);

  static const _trackInset = 10.0;
  static const _trackHalfHeight = 3.0;
  static const _maxWaveHeight = 15.5;

  final double fraction;
  final Animation<double> phase;
  final bool enabled;
  final Color waveColor;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final trackStart = _trackInset;
    final trackEnd = size.width - _trackInset;
    final trackWidth = math.max(0.0, trackEnd - trackStart);
    final activeEnd = trackStart + (trackWidth * fraction.clamp(0.0, 1.0));
    final inactivePaint = Paint()
      ..color = enabled ? const Color(0x66E7ECE8) : const Color(0x526B756E)
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
      Paint()..color = const Color(0x26000000),
    );
    canvas.drawCircle(
      thumbCenter,
      10.5,
      Paint()
        ..color = enabled
            ? Color.lerp(waveColor, Colors.white, 0.18)!.withAlpha(236)
            : const Color(0xFF747D76),
    );
    canvas.drawCircle(
      thumbCenter,
      10.5,
      Paint()
        ..color = const Color(0x704A544C)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _WavySeekBarPainter oldDelegate) {
    return fraction != oldDelegate.fraction ||
        enabled != oldDelegate.enabled ||
        waveColor != oldDelegate.waveColor;
  }
}
