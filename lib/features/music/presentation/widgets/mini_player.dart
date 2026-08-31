import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../services/downloader/audio_stream_resolver.dart';
import '../../../../services/player/player_service.dart';
import '../../domain/entities/local_track.dart';
import '../providers/music_providers.dart';
import 'favorite_star_badge.dart';
import 'playback_progress_line.dart';
import 'playlist_artwork.dart';
import 'source_image.dart';
import 'track_change_transition.dart';

double miniPlayerHeightFor(
  BuildContext context, {
  MiniPlayerMode mode = MiniPlayerMode.standard,
}) {
  final compactAndroid = Theme.of(context).platform == TargetPlatform.android;
  final baseHeight = compactAndroid
      ? 65.0
      : AppPlatform.isDesktop
      ? 98.0
      : 78.0;
  final textScale = MediaQuery.textScalerOf(context).scale(1.0);
  final contentHeight = baseHeight + math.max(0.0, (textScale - 1.0) * 35.0);
  return contentHeight + _miniPlayerMarginFor(context, mode).vertical;
}

EdgeInsets _miniPlayerMarginFor(BuildContext context, MiniPlayerMode mode) {
  if (mode != MiniPlayerMode.capsule) {
    return EdgeInsets.zero;
  }
  final compactAndroid = Theme.of(context).platform == TargetPlatform.android;
  if (compactAndroid) {
    return const EdgeInsets.fromLTRB(8, 5, 8, 8);
  }
  if (AppPlatform.isDesktop) {
    return const EdgeInsets.fromLTRB(14, 8, 14, 10);
  }
  return const EdgeInsets.fromLTRB(12, 6, 12, 8);
}

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({
    this.onOpenPlayer,
    this.onOpenLyrics,
    this.mode = MiniPlayerMode.standard,
    this.backgroundMode = MiniPlayerBackgroundMode.artwork,
    super.key,
  });

  final VoidCallback? onOpenPlayer;
  final VoidCallback? onOpenLyrics;
  final MiniPlayerMode mode;
  final MiniPlayerBackgroundMode backgroundMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presentation = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        final rawError = player.error ?? snapshot?.errorMessage;
        return (
          status: snapshot?.status,
          title: snapshot?.title,
          artist: snapshot?.artist,
          trackId: snapshot?.trackId,
          sourceUrl: snapshot?.sourceUrl,
          thumbnailUrl: snapshot?.thumbnailUrl,
          volume: snapshot?.volume ?? 1.0,
          shuffleEnabled: snapshot?.shuffleEnabled ?? false,
          repeatMode: snapshot?.repeatMode ?? PlaybackRepeatMode.off,
          hasError:
              player.hasError ||
              snapshot?.status == PlayerStatus.failed ||
              snapshot?.errorMessage?.trim().isNotEmpty == true,
          errorText: rawError == null
              ? null
              : readableAudioStreamError(rawError),
        );
      }),
    );
    final strings = ref.watch(appStringsProvider);
    final localTracks =
        ref.watch(libraryTracksProvider).value ?? const <LocalTrack>[];
    final localTrack = _miniLocalTrackForSnapshot(
      localTracks,
      trackId: presentation.trackId,
      sourceUrl: presentation.sourceUrl,
    );
    final localArtwork = localTrack == null
        ? null
        : preferredLocalTrackArtworkSource(localTrack);
    final artworkSource = localArtwork?.source ?? presentation.thumbnailUrl;
    final artworkFallbackSource = localArtwork?.fallbackSource;
    final isFavorite = ref.watch(
      favoriteTrackIdsProvider.select(
        (ids) => ids.contains(presentation.trackId),
      ),
    );
    final theme = Theme.of(context);
    final compactAndroid = theme.platform == TargetPlatform.android;
    final usesDesktopLayout = AppPlatform.isDesktop && !compactAndroid;
    final windowsLayout =
        usesDesktopLayout && MediaQuery.sizeOf(context).width >= 360;
    final horizontalPadding = compactAndroid
        ? 12.0
        : windowsLayout
        ? 12.0
        : 20.0;
    final artworkSize = compactAndroid
        ? 44.0
        : windowsLayout
        ? 64.0
        : 52.0;
    final isPlaying = presentation.status == PlayerStatus.playing;
    final playControlSize = compactAndroid ? 50.0 : 54.0;
    final playIconSize = compactAndroid
        ? isPlaying
              ? 37.0
              : 45.0
        : windowsLayout
        ? isPlaying
              ? 41.0
              : 45.0
        : 35.0;
    final minimumHeight = miniPlayerHeightFor(context);
    final isDark = theme.brightness == Brightness.dark;
    final capsule = mode == MiniPlayerMode.capsule;
    final capsuleMargin = _miniPlayerMarginFor(context, mode);
    final capsuleRadius = compactAndroid
        ? 28.0
        : AppPlatform.isDesktop
        ? 40.0
        : 32.0;
    final hasTrack =
        presentation.trackId != null &&
        presentation.status != null &&
        presentation.status != PlayerStatus.idle &&
        presentation.status != PlayerStatus.stopped &&
        presentation.status != PlayerStatus.failed;
    final compactErrorText = compactAndroid && presentation.hasError
        ? presentation.errorText ?? strings.playbackError
        : null;
    final visualIdentity = playbackVisualIdentity(
      trackId: presentation.trackId,
      sourceUrl: presentation.sourceUrl,
      title: presentation.title,
      artist: presentation.artist,
      thumbnailUrl: artworkSource,
    );
    final metadata = TrackChangeTransition(
      key: const ValueKey('mini-player-metadata'),
      switcherKey: const ValueKey('mini-player-track-transition'),
      identity: visualIdentity,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          _MiniArtwork(
            url: hasTrack ? artworkSource : null,
            fallbackUrl: artworkFallbackSource,
            size: artworkSize,
            isFavorite: isFavorite,
            circular: capsule,
          ),
          SizedBox(
            width: compactAndroid
                ? 8
                : windowsLayout
                ? 10
                : 12,
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MarqueeText(
                  key: const ValueKey('mini-player-track-title-marquee'),
                  presentation.title ?? strings.noPlayback,
                  pause: const Duration(milliseconds: 1700),
                  travel: const Duration(milliseconds: 6200),
                  style: TextStyle(
                    fontSize: windowsLayout ? 16 : null,
                    fontWeight: windowsLayout
                        ? FontWeight.w900
                        : FontWeight.w800,
                    color: AppColors.playbackTitleFor(context),
                    shadows: isDark
                        ? const [
                            Shadow(color: Color(0xAA000000), blurRadius: 8),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  compactErrorText ?? presentation.artist ?? 'BStream Music',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: windowsLayout ? 13 : null,
                    color: compactErrorText == null
                        ? AppColors.contentSubtitleFor(context)
                        : theme.colorScheme.error,
                    shadows: compactErrorText == null && isDark
                        ? const [
                            Shadow(color: Color(0x99000000), blurRadius: 7),
                          ]
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final primaryControl = SizedBox.square(
      dimension: playControlSize,
      child: IconButton(
        key: const ValueKey('mini-player-primary-control'),
        tooltip: isPlaying ? strings.pause : strings.play,
        style: IconButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: AppColors.playbackControlForegroundFor(context),
          disabledBackgroundColor: Colors.transparent,
          disabledForegroundColor: AppColors.playbackControlForegroundFor(
            context,
          ).withValues(alpha: 0.62),
          shape: const CircleBorder(),
        ),
        iconSize: playIconSize,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tight(Size.square(playControlSize)),
        icon: Transform.translate(
          offset: windowsLayout && !isPlaying
              ? const Offset(1, 0)
              : Offset.zero,
          child: Icon(
            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
        ),
        onPressed: () =>
            ref.read(playerControllerProvider.notifier).togglePlayPause(),
      ),
    );
    final previousControl = _MiniTransportButton(
      key: const ValueKey('mini-player-previous-control'),
      tooltip: strings.previous,
      icon: Icons.skip_previous_rounded,
      dimension: 48,
      iconSize: compactAndroid ? 28 : 30,
      onPressed: () =>
          ref.read(playerControllerProvider.notifier).playPrevious(),
    );
    final nextControl = _MiniTransportButton(
      key: const ValueKey('mini-player-next-control'),
      tooltip: strings.next,
      icon: Icons.skip_next_rounded,
      dimension: 48,
      iconSize: compactAndroid ? 28 : 30,
      onPressed: () => ref.read(playerControllerProvider.notifier).playNext(),
    );
    final desktopShuffle = _MiniTransportButton(
      key: const ValueKey('mini-player-shuffle-control'),
      tooltip: presentation.shuffleEnabled
          ? strings.deactivateShuffle
          : strings.activateShuffle,
      icon: Icons.shuffle_rounded,
      iconSize: 26,
      color: presentation.shuffleEnabled
          ? AppColors.downloadAccentFor(context)
          : null,
      onPressed: () =>
          ref.read(playerControllerProvider.notifier).toggleShuffle(),
    );
    final desktopRepeat = _MiniTransportButton(
      key: const ValueKey('mini-player-repeat-control'),
      tooltip: switch (presentation.repeatMode) {
        PlaybackRepeatMode.off => strings.repeatQueue,
        PlaybackRepeatMode.all => strings.repeatOne,
        PlaybackRepeatMode.one => strings.disableRepeat,
      },
      icon: presentation.repeatMode == PlaybackRepeatMode.one
          ? Icons.repeat_one_rounded
          : Icons.repeat_rounded,
      iconSize: 26,
      color: presentation.repeatMode == PlaybackRepeatMode.off
          ? null
          : AppColors.downloadAccentFor(context),
      onPressed: () =>
          ref.read(playerControllerProvider.notifier).cycleRepeatMode(),
    );
    final desktopVolume = _MiniVolumeControl(
      key: const ValueKey('mini-player-volume-control'),
      volume: presentation.volume,
      tooltip: strings.volume,
    );
    final desktopLyrics = _MiniTransportButton(
      key: const ValueKey('mini-player-lyrics-control'),
      tooltip: strings.lyrics,
      icon: Icons.lyrics_rounded,
      onPressed: onOpenLyrics,
    );

    return Container(
      key: const ValueKey('mini-player-container'),
      margin: capsuleMargin,
      clipBehavior: backgroundMode == MiniPlayerBackgroundMode.transparent
          ? Clip.antiAlias
          : Clip.antiAliasWithSaveLayer,
      decoration: capsule
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(capsuleRadius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.08),
                  blurRadius: compactAndroid ? 6 : 8,
                  offset: Offset(0, compactAndroid ? 1 : 2),
                ),
              ],
            )
          : BoxDecoration(
              borderRadius: compactAndroid
                  ? const BorderRadius.vertical(top: Radius.circular(10))
                  : BorderRadius.zero,
            ),
      foregroundDecoration: capsule
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(capsuleRadius),
              border: Border.all(
                color: AppColors.downloadAccentFor(
                  context,
                ).withValues(alpha: isDark ? 0.22 : 0.18),
                width: 0.5,
                strokeAlign: BorderSide.strokeAlignInside,
              ),
            )
          : null,
      child: Material(
        key: const ValueKey('mini-player-frame'),
        color: Colors.transparent,
        child: Stack(
          children: [
            if (backgroundMode == MiniPlayerBackgroundMode.accent)
              Positioned.fill(
                child: _MiniAccentBackground(
                  legacyDesktopKey: usesDesktopLayout,
                ),
              )
            else if (backgroundMode == MiniPlayerBackgroundMode.artwork)
              Positioned.fill(
                key: const ValueKey('mini-player-artwork-background'),
                child: _MiniBlurBackground(
                  url: hasTrack ? artworkSource : null,
                  fallbackUrl: artworkFallbackSource,
                ),
              ),
            if (backgroundMode == MiniPlayerBackgroundMode.artwork)
              Positioned.fill(
                child: DecoratedBox(
                  key: const ValueKey('mini-player-background-overlay'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: hasTrack
                          ? isDark
                                ? const [
                                    Color(0xDA0A100C),
                                    Color(0x99112816),
                                    Color(0xE407100A),
                                  ]
                                : const [
                                    Color(0xEAF5F8F6),
                                    Color(0xDDEAF3ED),
                                    Color(0xEEF5F8F6),
                                  ]
                          : isDark
                          ? const [
                              Color(0xE60B0B0B),
                              Color(0xD4141414),
                              Color(0xEB090909),
                            ]
                          : const [
                              Color(0xEDEFEFEF),
                              Color(0xE2E5E5E5),
                              Color(0xF2F2F2F2),
                            ],
                    ),
                  ),
                ),
              ),
            if (backgroundMode == MiniPlayerBackgroundMode.transparent)
              const Positioned.fill(child: _MiniGlassBackground()),
            if (!capsule)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: compactAndroid ? 11 : 1,
                child: IgnorePointer(
                  child: CustomPaint(
                    key: const ValueKey('mini-player-accent-top-border'),
                    painter: _MiniAccentBorderPainter(
                      color: AppColors.downloadAccentFor(
                        context,
                      ).withValues(alpha: 0.22),
                      cornerRadius: compactAndroid ? 10 : 0,
                    ),
                  ),
                ),
              ),
            if (!windowsLayout && !capsule)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _MiniProgress(
                  key: const ValueKey('mini-player-progress'),
                  height: 2,
                  rounded: true,
                ),
              ),
            InkWell(
              onTap: onOpenPlayer,
              child: ConstrainedBox(
                key: const ValueKey('mini-player-surface'),
                constraints: BoxConstraints(minHeight: minimumHeight),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalPadding,
                    vertical: windowsLayout ? 1 : 4,
                  ),
                  child: windowsLayout
                      ? Column(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  Expanded(flex: 3, child: metadata),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    flex: 4,
                                    child: Center(
                                      child: Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                desktopShuffle,
                                                previousControl,
                                                primaryControl,
                                                nextControl,
                                                desktopRepeat,
                                              ],
                                            ),
                                            const SizedBox(height: 0),
                                            if (!capsule)
                                              Align(
                                                alignment: Alignment.center,
                                                child: ConstrainedBox(
                                                  constraints:
                                                      const BoxConstraints(
                                                        maxWidth: 480,
                                                      ),
                                                  child: const SizedBox(
                                                    width: double.infinity,
                                                    child: _MiniProgress(
                                                      interactive: true,
                                                      key: ValueKey(
                                                        'mini-player-progress',
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
                                  const SizedBox(width: 16),
                                  Expanded(
                                    flex: 3,
                                    child: Padding(
                                      padding: const EdgeInsets.only(right: 8),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          if (presentation.hasError)
                                            Flexible(
                                              child: Text(
                                                presentation.errorText ??
                                                    strings.playbackError,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.right,
                                                style: TextStyle(
                                                  color:
                                                      theme.colorScheme.error,
                                                ),
                                              ),
                                            ),
                                          if (presentation.hasError)
                                            const SizedBox(width: 12),
                                          desktopLyrics,
                                          const SizedBox(width: 4),
                                          Flexible(child: desktopVolume),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            if (compactAndroid) {
                              final showPosition = constraints.maxWidth >= 280;
                              return Row(
                                children: [
                                  Expanded(child: metadata),
                                  if (showPosition)
                                    const SizedBox(
                                      width: 42,
                                      child: _MiniPositionText(),
                                    ),
                                  primaryControl,
                                ],
                              );
                            }

                            return Row(
                              children: [
                                Expanded(child: metadata),
                                if (presentation.hasError)
                                  Flexible(
                                    child: Text(
                                      presentation.errorText ??
                                          strings.playbackError,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: theme.colorScheme.error,
                                      ),
                                    ),
                                  ),
                                const SizedBox(width: 14),
                                const SizedBox(
                                  width: 54,
                                  child: _MiniPositionText(),
                                ),
                                const SizedBox(width: 12),
                                primaryControl,
                              ],
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniAccentBorderPainter extends CustomPainter {
  const _MiniAccentBorderPainter({
    required this.color,
    required this.cornerRadius,
  });

  final Color color;
  final double cornerRadius;
  final double strokeWidth = 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || strokeWidth <= 0) {
      return;
    }

    final inset = strokeWidth / 2;
    final maximumRadius = math.max(
      0.0,
      math.min((size.width - strokeWidth) / 2, size.height - strokeWidth),
    );
    final radius = (cornerRadius - inset).clamp(0.0, maximumRadius).toDouble();
    final right = size.width - inset;
    final path = Path();

    if (radius == 0) {
      path
        ..moveTo(inset, inset)
        ..lineTo(right, inset);
    } else {
      final diameter = radius * 2;
      path
        ..moveTo(inset, inset + radius)
        ..arcTo(
          Rect.fromLTWH(inset, inset, diameter, diameter),
          math.pi,
          math.pi / 2,
          false,
        )
        ..lineTo(right - radius, inset)
        ..arcTo(
          Rect.fromLTWH(right - diameter, inset, diameter, diameter),
          -math.pi / 2,
          math.pi / 2,
          false,
        );
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniAccentBorderPainter oldDelegate) {
    return color != oldDelegate.color ||
        cornerRadius != oldDelegate.cornerRadius ||
        strokeWidth != oldDelegate.strokeWidth;
  }
}

class _MiniTransportButton extends StatelessWidget {
  const _MiniTransportButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.dimension = 48,
    this.iconSize,
    this.color,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double dimension;
  final double? iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: dimension,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        color: color ?? AppColors.playbackControlForegroundFor(context),
        iconSize: iconSize,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(
          width: dimension,
          height: dimension,
        ),
        onPressed: onPressed,
      ),
    );
  }
}

class _MiniVolumeControl extends ConsumerWidget {
  const _MiniVolumeControl({
    required this.volume,
    required this.tooltip,
    super.key,
  });

  final double volume;
  final String tooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = AppColors.downloadAccentFor(context);
    final inactive = AppColors.menuInactiveSliderFor(context);
    final normalizedVolume = volume.clamp(0.0, 1.0).toDouble();
    final increasedVolume = (normalizedVolume + 0.05)
        .clamp(0.0, 1.0)
        .toDouble();
    final decreasedVolume = (normalizedVolume - 0.05)
        .clamp(0.0, 1.0)
        .toDouble();

    void setVolume(double value) =>
        unawaited(ref.read(playerControllerProvider.notifier).setVolume(value));

    String percentage(double value) => '${(value * 100).round()}%';

    return Semantics(
      container: true,
      slider: true,
      label: tooltip,
      value: percentage(normalizedVolume),
      increasedValue: percentage(increasedVolume),
      decreasedValue: percentage(decreasedVolume),
      onIncrease: normalizedVolume < 1
          ? () => setVolume(increasedVolume)
          : null,
      onDecrease: normalizedVolume > 0
          ? () => setVolume(decreasedVolume)
          : null,
      child: ExcludeSemantics(
        child: SizedBox(
          width: 152,
          height: 44,
          child: Row(
            children: [
              Icon(
                _miniVolumeIcon(normalizedVolume),
                size: 22,
                color: AppColors.playbackControlForegroundFor(context),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _MiniSliderControl(
                  key: const ValueKey('mini-player-volume-slider'),
                  value: normalizedVolume,
                  activeColor: accent,
                  inactiveColor: inactive,
                  onChanged: setVolume,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniSliderControl extends StatefulWidget {
  const _MiniSliderControl({
    required this.value,
    required this.activeColor,
    required this.inactiveColor,
    required this.onChanged,
    this.onChangeEnd,
    this.trackHeight = 3,
    this.keyboardStep = 0.05,
    super.key,
  });

  final double value;
  final Color activeColor;
  final Color inactiveColor;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double trackHeight;
  final double keyboardStep;

  @override
  State<_MiniSliderControl> createState() => _MiniSliderControlState();
}

class _MiniSliderControlState extends State<_MiniSliderControl> {
  static const double _thumbDiameter = 14;

  double? _lastInteractionValue;

  @override
  Widget build(BuildContext context) {
    final normalizedValue = widget.value.clamp(0.0, 1.0).toDouble();
    final enabled = widget.onChanged != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final thumbRadius = _thumbDiameter / 2;
        final usableWidth = math.max(1.0, width - _thumbDiameter).toDouble();
        final thumbLeft = usableWidth * normalizedValue;
        final trackTop = (height - widget.trackHeight) / 2;
        final thumbTop = (height - _thumbDiameter) / 2;

        void updateFromPosition(double dx) {
          if (!enabled) {
            return;
          }
          final value = ((dx - thumbRadius) / usableWidth)
              .clamp(0.0, 1.0)
              .toDouble();
          _lastInteractionValue = value;
          widget.onChanged!(value);
        }

        void finishInteraction() {
          if (!enabled) {
            return;
          }
          final value = _lastInteractionValue ?? normalizedValue;
          _lastInteractionValue = null;
          widget.onChangeEnd?.call(value);
        }

        KeyEventResult handleKeyEvent(FocusNode node, KeyEvent event) {
          if (!enabled) {
            return KeyEventResult.ignored;
          }
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          double? nextValue;
          if (key == LogicalKeyboardKey.arrowLeft ||
              key == LogicalKeyboardKey.arrowDown) {
            nextValue = (normalizedValue - widget.keyboardStep)
                .clamp(0.0, 1.0)
                .toDouble();
          } else if (key == LogicalKeyboardKey.arrowRight ||
              key == LogicalKeyboardKey.arrowUp) {
            nextValue = (normalizedValue + widget.keyboardStep)
                .clamp(0.0, 1.0)
                .toDouble();
          }
          if (nextValue != null) {
            widget.onChanged!(nextValue);
            widget.onChangeEnd?.call(nextValue);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }

        return Focus(
          canRequestFocus: enabled,
          onKeyEvent: handleKeyEvent,
          child: Builder(
            builder: (focusContext) => MouseRegion(
              cursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: enabled
                    ? (details) {
                        Focus.of(focusContext).requestFocus();
                        updateFromPosition(details.localPosition.dx);
                      }
                    : null,
                onTapUp: enabled ? (_) => finishInteraction() : null,
                onTapCancel: enabled
                    ? () => _lastInteractionValue = null
                    : null,
                onHorizontalDragStart: enabled
                    ? (details) {
                        Focus.of(focusContext).requestFocus();
                        updateFromPosition(details.localPosition.dx);
                      }
                    : null,
                onHorizontalDragUpdate: enabled
                    ? (details) => updateFromPosition(details.localPosition.dx)
                    : null,
                onHorizontalDragEnd: enabled
                    ? (_) => finishInteraction()
                    : null,
                onHorizontalDragCancel: enabled
                    ? () => _lastInteractionValue = null
                    : null,
                child: Stack(
                  children: [
                    Positioned(
                      left: thumbRadius,
                      right: thumbRadius,
                      top: trackTop,
                      height: widget.trackHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.inactiveColor,
                          borderRadius: BorderRadius.circular(
                            widget.trackHeight / 2,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: thumbRadius,
                      top: trackTop,
                      width: usableWidth * normalizedValue,
                      height: widget.trackHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.activeColor,
                          borderRadius: BorderRadius.circular(
                            widget.trackHeight / 2,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: thumbLeft,
                      top: thumbTop,
                      width: _thumbDiameter,
                      height: _thumbDiameter,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.activeColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

IconData _miniVolumeIcon(double volume) {
  if (volume <= 0) {
    return Icons.volume_off_rounded;
  }
  if (volume < 0.5) {
    return Icons.volume_down_rounded;
  }
  return Icons.volume_up_rounded;
}

class _MiniBlurBackground extends StatelessWidget {
  const _MiniBlurBackground({required this.url, required this.fallbackUrl});

  final String? url;
  final String? fallbackUrl;

  @override
  Widget build(BuildContext context) {
    final source = url?.trim();
    if (source == null || source.isEmpty) {
      return const _MiniFallbackBackground();
    }
    final physicalWidth =
        MediaQuery.sizeOf(context).width *
        MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (physicalWidth * 1.28).ceil().clamp(640, 1280).toInt();

    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
      child: Transform.scale(
        scale: 1.28,
        child: SourceImage(
          source: source,
          fallbackSource: fallbackUrl,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth,
          filterQuality: FilterQuality.high,
          fallback: const _MiniFallbackBackground(),
        ),
      ),
    );
  }
}

class _MiniAccentBackground extends StatelessWidget {
  const _MiniAccentBackground({required this.legacyDesktopKey});

  final bool legacyDesktopKey;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: legacyDesktopKey
          ? const ValueKey('mini-player-desktop-background')
          : const ValueKey('mini-player-accent-background'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: AppColors.desktopMiniPlayerGradientFor(context),
        ),
      ),
    );
  }
}

class _MiniGlassBackground extends StatelessWidget {
  const _MiniGlassBackground();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = AppColors.downloadAccentFor(context);
    final surface = theme.colorScheme.surface;
    final surfaceAlpha = isDark ? 0.36 : 0.42;

    Color glassColor(double accentAlpha) => Color.alphaBlend(
      accent.withValues(alpha: accentAlpha),
      surface.withValues(alpha: surfaceAlpha),
    );

    return ClipRect(
      child: BackdropFilter(
        key: const ValueKey('mini-player-glass-blur'),
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: DecoratedBox(
          key: const ValueKey('mini-player-glass-background'),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                glassColor(isDark ? 0.04 : 0.028),
                glassColor(isDark ? 0.075 : 0.052),
                glassColor(isDark ? 0.035 : 0.024),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniProgress extends ConsumerStatefulWidget {
  const _MiniProgress({
    this.interactive = false,
    this.height = 3,
    this.rounded = false,
    super.key,
  });

  final bool interactive;
  final double height;
  final bool rounded;

  @override
  ConsumerState<_MiniProgress> createState() => _MiniProgressState();
}

class _MiniProgressState extends ConsumerState<_MiniProgress> {
  double? _dragProgress;

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        return (
          position: snapshot?.position ?? Duration.zero,
          duration: snapshot?.duration,
        );
      }),
    );
    final progressColor = AppColors.downloadAccentFor(context);
    final strings = ref.watch(appStringsProvider);
    final duration = timeline.duration;
    final position = timeline.position;
    final progress = duration == null || duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();

    if (!widget.interactive) {
      final line = PlaybackProgressLine(
        value: progress,
        color: progressColor,
        height: widget.height,
        colorAnimationKey: const ValueKey('mini-progress-color-animation'),
        fillKey: const ValueKey('mini-progress-fill'),
        semanticsLabel: strings.choose(
          'Progreso de reproducción',
          'Playback progress',
        ),
      );
      return widget.rounded
          ? ClipRRect(
              borderRadius: BorderRadius.circular(widget.height / 2),
              child: line,
            )
          : line;
    }

    final totalMicroseconds = duration?.inMicroseconds ?? 0;
    final canSeek = totalMicroseconds > 0;
    final inactiveColor = AppColors.menuInactiveSliderFor(context);
    final displayedProgress = (_dragProgress ?? progress)
        .clamp(0.0, 1.0)
        .toDouble();
    final keyboardStep = canSeek
        ? (const Duration(seconds: 5).inMicroseconds / totalMicroseconds)
              .clamp(0.01, 0.1)
              .toDouble()
        : 0.05;
    final increasedProgress = (displayedProgress + keyboardStep)
        .clamp(0.0, 1.0)
        .toDouble();
    final decreasedProgress = (displayedProgress - keyboardStep)
        .clamp(0.0, 1.0)
        .toDouble();

    Duration positionFor(double value) => Duration(
      microseconds: (totalMicroseconds * value.clamp(0.0, 1.0)).round(),
    );

    void seekTo(double value) {
      if (!canSeek) {
        return;
      }
      final seek = ref
          .read(playerControllerProvider.notifier)
          .seek(positionFor(value));
      unawaited(
        seek.whenComplete(() {
          if (mounted) {
            setState(() => _dragProgress = null);
          }
        }),
      );
    }

    return SizedBox(
      height: 32,
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: _MiniTimeText(
              key: const ValueKey('mini-player-current-time'),
              duration: position,
              alignment: Alignment.centerRight,
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Semantics(
              container: true,
              slider: true,
              enabled: canSeek,
              label: strings.choose(
                'Progreso de reproducción',
                'Playback progress',
              ),
              value: formatDuration(positionFor(displayedProgress)),
              increasedValue: formatDuration(positionFor(increasedProgress)),
              decreasedValue: formatDuration(positionFor(decreasedProgress)),
              onIncrease: canSeek && displayedProgress < 1
                  ? () => seekTo(increasedProgress)
                  : null,
              onDecrease: canSeek && displayedProgress > 0
                  ? () => seekTo(decreasedProgress)
                  : null,
              child: ExcludeSemantics(
                child: _MiniSliderControl(
                  key: const ValueKey('mini-player-progress-control'),
                  value: displayedProgress,
                  activeColor: progressColor,
                  inactiveColor: inactiveColor,
                  trackHeight: 3,
                  keyboardStep: keyboardStep,
                  onChanged: canSeek
                      ? (value) => setState(() => _dragProgress = value)
                      : null,
                  onChangeEnd: canSeek ? seekTo : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 48,
            child: _MiniTimeText(
              key: const ValueKey('mini-player-total-time'),
              duration: duration,
              alignment: Alignment.centerLeft,
              textAlign: TextAlign.left,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniTimeText extends StatelessWidget {
  const _MiniTimeText({
    required this.duration,
    required this.alignment,
    required this.textAlign,
    super.key,
  });

  final Duration? duration;
  final Alignment alignment;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Text(
        formatDuration(duration),
        maxLines: 1,
        softWrap: false,
        textAlign: textAlign,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: AppColors.contentSubtitleFor(context),
        ),
      ),
    );
  }
}

class _MiniPositionText extends ConsumerWidget {
  const _MiniPositionText();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seconds = ref.watch(
      playerControllerProvider.select(
        (player) => player.value?.position.inSeconds ?? 0,
      ),
    );
    return _MiniTimeText(
      duration: Duration(seconds: seconds),
      alignment: Alignment.centerRight,
      textAlign: TextAlign.right,
    );
  }
}

class _MiniFallbackBackground extends StatelessWidget {
  const _MiniFallbackBackground();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      key: const ValueKey('mini-player-neutral-background'),
      color: isDark ? const Color(0xFF0B0B0B) : const Color(0xFFF1F1F1),
    );
  }
}

class _MiniArtwork extends ConsumerWidget {
  const _MiniArtwork({
    required this.url,
    required this.fallbackUrl,
    required this.size,
    required this.isFavorite,
    required this.circular,
  });

  final String? url;
  final String? fallbackUrl;
  final double size;
  final bool isFavorite;
  final bool circular;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = circular
        ? ref.watch(
            playerControllerProvider.select((player) {
              final snapshot = player.value;
              final duration = snapshot?.duration;
              if (duration == null || duration.inMilliseconds <= 0) {
                return 0.0;
              }
              return (snapshot!.position.inMilliseconds /
                      duration.inMilliseconds)
                  .clamp(0.0, 1.0)
                  .toDouble();
            }),
          )
        : 0.0;
    final ringInset = circular ? 2.5 : 0.0;

    return SizedBox(
      key: const ValueKey('mini-player-artwork'),
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (circular)
            Padding(
              padding: EdgeInsets.all(ringInset),
              child: ClipOval(
                key: const ValueKey('mini-player-artwork-circle'),
                clipBehavior: Clip.antiAliasWithSaveLayer,
                child: _MiniArtworkImage(url: url, fallbackUrl: fallbackUrl),
              ),
            )
          else
            ClipRRect(
              key: const ValueKey('mini-player-artwork-rounded-rect'),
              borderRadius: BorderRadius.circular(appArtworkRadius),
              clipBehavior: Clip.antiAliasWithSaveLayer,
              child: _MiniArtworkImage(url: url, fallbackUrl: fallbackUrl),
            ),
          if (circular)
            Positioned.fill(
              child: ExcludeSemantics(
                child: TweenAnimationBuilder<double>(
                  key: const ValueKey('mini-player-artwork-progress-animation'),
                  tween: Tween<double>(end: progress),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  builder: (context, animatedProgress, _) {
                    return CircularProgressIndicator(
                      key: const ValueKey('mini-player-artwork-progress-ring'),
                      value: animatedProgress,
                      strokeWidth: 2,
                      strokeCap: StrokeCap.round,
                      color: AppColors.downloadAccentFor(context),
                      backgroundColor: AppColors.menuInactiveSliderFor(
                        context,
                      ).withValues(alpha: 0.55),
                    );
                  },
                ),
              ),
            ),
          if (isFavorite)
            const Positioned(
              top: 3,
              right: 3,
              child: FavoriteStarBadge(iconSize: 11),
            ),
        ],
      ),
    );
  }
}

class _MiniArtworkImage extends StatelessWidget {
  const _MiniArtworkImage({required this.url, required this.fallbackUrl});

  final String? url;
  final String? fallbackUrl;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: url == null
            ? Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF1B1B1B)
                  : const Color(0xFFE5E5E5)
            : Theme.of(context).colorScheme.primaryContainer,
      ),
      child: url == null
          ? const Icon(Icons.graphic_eq_rounded)
          : ProportionalArtwork(
              source: url,
              fallbackSource: fallbackUrl,
              cacheWidth: 256,
              filterQuality: FilterQuality.high,
              fallback: const Icon(Icons.graphic_eq_rounded),
            ),
    );
  }
}

LocalTrack? _miniLocalTrackForSnapshot(
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
