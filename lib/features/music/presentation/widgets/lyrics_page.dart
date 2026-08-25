import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../platform_channels/android_screen_channel.dart';
import '../../../../services/lyrics/lyrics_romanization_service.dart';
import '../../../../services/lyrics/lyrics_service.dart';
import '../../../../services/player/player_service.dart';
import '../../domain/entities/lyrics.dart';
import '../providers/music_providers.dart';
import 'lyrics_animation_transition.dart';
import 'mini_player.dart';
import 'playback_gradient_background.dart';
import 'playback_progress_line.dart';
import 'source_image.dart';

bool _usesMobileLyricsLayout(BuildContext context) =>
    switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };

({double inactive, double active, double plain}) _lyricsTypographyFor(
  BuildContext context,
) {
  final desktop = switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };
  if (!desktop) {
    return (inactive: 27, active: 28, plain: 25);
  }

  final width = MediaQuery.sizeOf(context).width;
  if (width < 840) {
    return (inactive: 29, active: 30, plain: 27);
  }
  if (width < 1200) {
    return (inactive: 33, active: 34, plain: 30);
  }
  return (inactive: 36, active: 37, plain: 33);
}

class LyricsPage extends ConsumerStatefulWidget {
  const LyricsPage({super.key});

  @override
  ConsumerState<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends ConsumerState<LyricsPage> {
  final _manualSearchController = TextEditingController();
  final _screenChannel = const AndroidScreenChannel();
  String? _lookupIdentity;
  bool _showSimilarLyrics = false;
  String _manualSearchTitle = '';
  LyricsDocument? _romanizationSource;
  Set<LyricsRomanizationLanguage>? _romanizationLanguages;
  Future<RomanizedLyricsView>? _romanizationFuture;

  @override
  void initState() {
    super.initState();
    _setKeepScreenOn(true);
  }

  @override
  void dispose() {
    _setKeepScreenOn(false);
    _manualSearchController.dispose();
    super.dispose();
  }

  void _setKeepScreenOn(bool enabled) {
    if (AppPlatform.isAndroid) {
      unawaited(_screenChannel.setKeepScreenOn(enabled));
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final lookup = ref.watch(currentLyricsLookupProvider);
    final offset = ref.watch(lyricsOffsetControllerProvider);
    final selectedLyrics = ref.watch(selectedLyricsControllerProvider);
    final settings = ref.watch(settingsControllerProvider).value;
    final lyricsTextAlignment =
        settings?.lyricsTextAlignment ?? LyricsTextAlignment.normal;
    final lyricsCentered = lyricsTextAlignment == LyricsTextAlignment.centered;
    final lyricsAnimationStyle =
        settings?.lyricsAnimationStyle ?? LyricsAnimationStyle.smooth;
    final lyricsRomanizationEnabled =
        settings?.lyricsRomanizationEnabled ?? false;
    final lyricsRomanizationLanguages =
        settings?.lyricsRomanizationLanguages ??
        defaultLyricsRomanizationLanguages;
    final miniPlayerMode = settings?.miniPlayerMode ?? defaultMiniPlayerMode;
    final miniPlayerBackgroundMode =
        settings?.miniPlayerBackgroundMode ?? defaultMiniPlayerBackgroundMode;
    final systemBottomInset = math.max(
      MediaQuery.viewPaddingOf(context).bottom,
      MediaQuery.paddingOf(context).bottom,
    );
    final mobileLayout = _usesMobileLyricsLayout(context);
    final miniPlayerHeight = mobileLayout
        ? 0.0
        : miniPlayerHeightFor(context, mode: miniPlayerMode);
    final accent = AppColors.downloadAccentFor(context);
    _syncLookup(lookup);

    return Scaffold(
      backgroundColor: const Color(0xFF030504),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const PlayerPlaybackGradientBackground(),
          const DecoratedBox(
            decoration: BoxDecoration(color: Color(0x52000000)),
          ),
          DecoratedBox(
            key: const ValueKey('lyrics-accent-tint'),
            decoration: BoxDecoration(
              // Keep the artwork-derived gradient dominant; this is only a
              // restrained accent wash so Letras follows the active theme.
              color: accent.withValues(alpha: 0.075),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: systemBottomInset + miniPlayerHeight,
              ),
              child: Column(
                children: [
                  _LyricsHeader(lookup: lookup),
                  Expanded(
                    child: lookup == null
                        ? _LyricsMessage(
                            icon: Icons.lyrics_outlined,
                            message: strings.noPlayback,
                          )
                        : _showSimilarLyrics
                        ? _buildSimilarLyrics(lookup)
                        : selectedLyrics != null
                        ? _buildLyrics(
                            selectedLyrics,
                            offset,
                            lyricsCentered,
                            lyricsAnimationStyle,
                            lyricsRomanizationEnabled,
                            lyricsRomanizationLanguages,
                          )
                        : ref
                              .watch(lyricsProvider(lookup))
                              .when(
                                loading: () => _LyricsMessage(
                                  icon: Icons.manage_search_rounded,
                                  message: strings.lyricsLoading,
                                  loading: true,
                                ),
                                error: (error, _) {
                                  final noInternet =
                                      error is LyricsConnectionException;
                                  return _LyricsMessage(
                                    icon: noInternet
                                        ? Icons.wifi_off_rounded
                                        : Icons.cloud_off_rounded,
                                    message: noInternet
                                        ? strings.lyricsNoInternet
                                        : strings.lyricsLoadError,
                                    actionLabel: strings.retry,
                                    onAction: () =>
                                        ref.invalidate(lyricsProvider(lookup)),
                                  );
                                },
                                data: (lyrics) => _buildLyrics(
                                  lyrics,
                                  offset,
                                  lyricsCentered,
                                  lyricsAnimationStyle,
                                  lyricsRomanizationEnabled,
                                  lyricsRomanizationLanguages,
                                ),
                              ),
                  ),
                ],
              ),
            ),
          ),
          if (!mobileLayout)
            Positioned(
              left: 0,
              right: 0,
              bottom: systemBottomInset,
              child: SizedBox(
                height: miniPlayerHeight,
                child: MiniPlayer(
                  mode: miniPlayerMode,
                  backgroundMode: miniPlayerBackgroundMode,
                  onOpenPlayer: () => Navigator.of(context).pop(),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLyrics(
    LyricsDocument? lyrics,
    Duration offset,
    bool lyricsCentered,
    LyricsAnimationStyle lyricsAnimationStyle,
    bool lyricsRomanizationEnabled,
    Set<LyricsRomanizationLanguage> lyricsRomanizationLanguages,
  ) {
    final strings = ref.watch(appStringsProvider);
    if (lyrics == null) {
      return _LyricsMessage(
        icon: Icons.search_off_rounded,
        message: strings.lyricsNotFound,
        actionLabel: strings.similarLyrics,
        actionIcon: Icons.manage_search_rounded,
        onAction: () => setState(() => _showSimilarLyrics = true),
      );
    }
    final sourceFooter = strings.lyricsSource;
    if (lyrics.instrumental) {
      return _LyricsMessage(
        icon: Icons.piano_rounded,
        message: strings.lyricsInstrumental,
        footer: sourceFooter,
      );
    }
    final romanizationFuture =
        lyricsRomanizationEnabled && lyricsRomanizationLanguages.isNotEmpty
        ? _romanizedLyrics(lyrics, lyricsRomanizationLanguages)
        : null;
    return FutureBuilder<RomanizedLyricsView>(
      future: romanizationFuture,
      builder: (context, snapshot) => _buildLyricsContent(
        lyrics,
        offset: offset,
        lyricsCentered: lyricsCentered,
        lyricsAnimationStyle: lyricsAnimationStyle,
        sourceFooter: sourceFooter,
        romanized:
            lyricsRomanizationEnabled &&
                snapshot.connectionState == ConnectionState.done
            ? snapshot.data
            : null,
      ),
    );
  }

  Future<RomanizedLyricsView> _romanizedLyrics(
    LyricsDocument lyrics,
    Set<LyricsRomanizationLanguage> languages,
  ) {
    final sameLanguages =
        _romanizationLanguages?.length == languages.length &&
        _romanizationLanguages?.containsAll(languages) == true;
    if (identical(_romanizationSource, lyrics) &&
        sameLanguages &&
        _romanizationFuture != null) {
      return _romanizationFuture!;
    }
    _romanizationSource = lyrics;
    _romanizationLanguages = Set.unmodifiable(languages);
    final future = ref
        .read(lyricsRomanizationServiceProvider)
        .romanizeDocument(lyrics, languages);
    _romanizationFuture = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_romanizationFuture, future)) {
            _romanizationSource = null;
            _romanizationLanguages = null;
            _romanizationFuture = null;
          }
        },
      ),
    );
    return future;
  }

  Widget _buildLyricsContent(
    LyricsDocument lyrics, {
    required Duration offset,
    required bool lyricsCentered,
    required LyricsAnimationStyle lyricsAnimationStyle,
    required String sourceFooter,
    RomanizedLyricsView? romanized,
  }) {
    if (lyrics.lines.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _SyncedLyricsTimeline(
            lines: lyrics.lines,
            romanizedLines: romanized?.syncedLines,
            offset: offset,
            sourceFooter: sourceFooter,
            lyricsCentered: lyricsCentered,
            animationStyle: lyricsAnimationStyle,
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _LyricsOffsetControls(
              offset: offset,
              onDecrease: offset > LyricsOffsetController.minimum
                  ? ref.read(lyricsOffsetControllerProvider.notifier).decrease
                  : null,
              onIncrease: offset < LyricsOffsetController.maximum
                  ? ref.read(lyricsOffsetControllerProvider.notifier).increase
                  : null,
              onReset: ref.read(lyricsOffsetControllerProvider.notifier).reset,
            ),
          ),
        ],
      );
    }

    final plainLyrics = lyrics.plainLyrics?.trim();
    if (plainLyrics != null && plainLyrics.isNotEmpty) {
      return _PlainLyricsView(
        lyrics: plainLyrics,
        romanizedLyrics: romanized?.plainLyrics?.trim(),
        sourceFooter: sourceFooter,
        lyricsCentered: lyricsCentered,
      );
    }
    return _LyricsMessage(
      icon: Icons.search_off_rounded,
      message: ref.watch(appStringsProvider).lyricsNotFound,
      actionLabel: ref.watch(appStringsProvider).similarLyrics,
      actionIcon: Icons.manage_search_rounded,
      onAction: () => setState(() => _showSimilarLyrics = true),
    );
  }

  Widget _buildSimilarLyrics(LyricsLookup lookup) {
    final strings = ref.watch(appStringsProvider);
    final manualRequest = _manualSearchTitle.isEmpty
        ? null
        : (title: _manualSearchTitle, context: lookup);
    final candidates = manualRequest == null
        ? ref.watch(similarLyricsProvider(lookup))
        : ref.watch(manualLyricsSearchProvider(manualRequest));
    return Column(
      key: const ValueKey('similar-lyrics-panel'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('similar-lyrics-back'),
                tooltip: strings.backToLyrics,
                color: AppColors.downloadAccentFor(context),
                onPressed: () => setState(() => _showSimilarLyrics = false),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.similarLyrics,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      strings.chooseSimilarLyrics,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.58),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: TextField(
            key: const ValueKey('manual-lyrics-search-field'),
            controller: _manualSearchController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _submitManualLyricsSearch(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              hintText: strings.manualLyricsSearchHint,
              hintStyle: TextStyle(
                color: Colors.white.withValues(alpha: 0.46),
                fontWeight: FontWeight.w700,
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: AppColors.downloadAccentFor(context),
              ),
              suffixIcon: IconButton(
                key: ValueKey(
                  _manualSearchTitle.isEmpty
                      ? 'manual-lyrics-search-submit'
                      : 'manual-lyrics-search-clear',
                ),
                tooltip: _manualSearchTitle.isEmpty
                    ? strings.manualLyricsSearchAction
                    : strings.backToLyrics,
                onPressed: _manualSearchTitle.isEmpty
                    ? _submitManualLyricsSearch
                    : _clearManualLyricsSearch,
                icon: Icon(
                  _manualSearchTitle.isEmpty
                      ? Icons.arrow_forward_rounded
                      : Icons.close_rounded,
                  color: AppColors.downloadAccentFor(context),
                ),
              ),
              filled: true,
              fillColor: Colors.black.withValues(alpha: 0.5),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 13,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                  color: AppColors.downloadAccentFor(context),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: candidates.when(
            loading: () => _LyricsMessage(
              icon: Icons.manage_search_rounded,
              message: strings.similarLyricsLoading,
              loading: true,
            ),
            error: (error, _) {
              final noInternet = error is LyricsConnectionException;
              return _LyricsMessage(
                icon: noInternet
                    ? Icons.wifi_off_rounded
                    : Icons.cloud_off_rounded,
                message: noInternet
                    ? strings.lyricsNoInternet
                    : strings.lyricsLoadError,
                actionLabel: strings.retry,
                onAction: () => manualRequest == null
                    ? ref.invalidate(similarLyricsProvider(lookup))
                    : ref.invalidate(manualLyricsSearchProvider(manualRequest)),
              );
            },
            data: (items) {
              if (items.isEmpty) {
                return _LyricsMessage(
                  icon: Icons.search_off_rounded,
                  message: strings.similarLyricsEmpty,
                );
              }
              return _SimilarLyricsList(
                candidates: items,
                onSelected: (candidate) {
                  ref
                      .read(selectedLyricsControllerProvider.notifier)
                      .select(candidate.document);
                  setState(() {
                    _showSimilarLyrics = false;
                  });
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _syncLookup(LyricsLookup? lookup) {
    final nextIdentity = lookup == null
        ? null
        : (lookup.sourceId?.trim().isNotEmpty ?? false)
        ? 'source:${lookup.sourceId!.trim()}'
        : '${lookup.title.trim().toLowerCase()}\u0000'
              '${lookup.artist.trim().toLowerCase()}';
    if (nextIdentity == _lookupIdentity) {
      return;
    }
    _lookupIdentity = nextIdentity;
    _showSimilarLyrics = false;
    _manualSearchTitle = '';
    if (_manualSearchController.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _lookupIdentity == nextIdentity) {
          _manualSearchController.clear();
        }
      });
    }
  }

  void _submitManualLyricsSearch() {
    final title = _manualSearchController.text.trim();
    if (title.isEmpty || title == _manualSearchTitle) {
      return;
    }
    setState(() => _manualSearchTitle = title);
  }

  void _clearManualLyricsSearch() {
    _manualSearchController.clear();
    if (_manualSearchTitle.isEmpty) {
      return;
    }
    setState(() => _manualSearchTitle = '');
  }
}

class _SimilarLyricsList extends ConsumerWidget {
  const _SimilarLyricsList({
    required this.candidates,
    required this.onSelected,
  });

  final List<LyricsCandidate> candidates;
  final ValueChanged<LyricsCandidate> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    return ListView.separated(
      key: const ValueKey('similar-lyrics-list'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
      itemCount: candidates.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final candidate = candidates[index];
        final accent = AppColors.downloadAccentFor(context);
        final duration = candidate.duration;
        final metadata = <String>[
          if (duration != null) _formatLyricsDuration(duration),
          candidate.isSynced
              ? strings.syncedLyricsLabel
              : strings.plainLyricsLabel,
        ].join('  •  ');
        return Material(
          key: ValueKey(
            'similar-lyrics-candidate-'
            '${candidate.document.providerId ?? index}',
          ),
          color: Colors.black.withValues(alpha: 0.46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: accent.withValues(alpha: 0.30)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onSelected(candidate),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    candidate.isSynced
                        ? Icons.graphic_eq_rounded
                        : Icons.subject_rounded,
                    color: accent.withValues(alpha: 0.86),
                    size: 23,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          candidate.trackName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          candidate.artistName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.67),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          metadata,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.46),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: accent.withValues(alpha: 0.70),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LyricsHeader extends ConsumerWidget {
  const _LyricsHeader({required this.lookup});

  final LyricsLookup? lookup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final currentLookup = lookup;
    final mobileLayout = _usesMobileLyricsLayout(context);
    final playback = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        return (
          status: snapshot?.status,
          thumbnailUrl: snapshot?.thumbnailUrl,
          hasTrack:
              snapshot?.title?.trim().isNotEmpty == true &&
              snapshot?.status != PlayerStatus.idle &&
              snapshot?.status != PlayerStatus.failed,
        );
      }),
    );
    final isPlaying = playback.status == PlayerStatus.playing;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 12, 6),
          child: Row(
            children: [
              if (!mobileLayout) ...[
                IconButton(
                  key: const ValueKey('lyrics-back-button'),
                  tooltip: strings.back,
                  icon: const Icon(Icons.arrow_back_rounded),
                  color: AppColors.downloadAccentFor(context),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 4),
              ],
              if (mobileLayout) ...[
                _LyricsHeaderArtwork(
                  source: playback.thumbnailUrl,
                  onTap: () => Navigator.of(context).maybePop(),
                  semanticsLabel: currentLookup == null
                      ? strings.choose('Portada de la canción', 'Track artwork')
                      : strings.choose(
                          'Portada de ${currentLookup.title}',
                          'Artwork for ${currentLookup.title}',
                        ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.lyrics,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      currentLookup == null
                          ? strings.noPlayback
                          : '${currentLookup.title} - ${currentLookup.artist}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.68),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (mobileLayout)
                SizedBox.square(
                  dimension: 48,
                  child: IconButton(
                    key: const ValueKey('lyrics-playback-control'),
                    tooltip: isPlaying ? strings.pause : strings.play,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    color: Colors.white,
                    disabledColor: Colors.white.withValues(alpha: 0.36),
                    iconSize: isPlaying ? 36 : 40,
                    onPressed: playback.hasTrack
                        ? () => ref
                              .read(playerControllerProvider.notifier)
                              .togglePlayPause()
                        : null,
                    icon: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const _LyricsHeaderProgress(),
      ],
    );
  }
}

class _LyricsHeaderArtwork extends StatelessWidget {
  const _LyricsHeaderArtwork({
    required this.source,
    required this.onTap,
    required this.semanticsLabel,
  });

  final String? source;
  final VoidCallback? onTap;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      key: const ValueKey('lyrics-header-artwork-fallback'),
      color: Colors.white.withValues(alpha: 0.08),
      child: Icon(
        Icons.music_note_rounded,
        size: 22,
        color: Colors.white.withValues(alpha: 0.68),
      ),
    );
    return Semantics(
      image: true,
      button: onTap != null,
      label: semanticsLabel,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(appArtworkRadius),
        child: ClipRRect(
          key: const ValueKey('lyrics-header-artwork'),
          borderRadius: BorderRadius.circular(appArtworkRadius),
          child: SizedBox.square(
            dimension: 42,
            child: SourceImage(
              source: source,
              fallback: fallback,
              cacheWidth: 192,
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricsHeaderProgress extends ConsumerWidget {
  const _LyricsHeaderProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final totalMilliseconds = timeline.duration?.inMilliseconds ?? 0;
    final progress = totalMilliseconds <= 0
        ? 0.0
        : (timeline.position.inMilliseconds / totalMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
    final strings = ref.watch(appStringsProvider);

    return PlaybackProgressLine(
      key: const ValueKey('lyrics-header-progress'),
      value: progress,
      color: progressColor,
      progressAnimationKey: const ValueKey('lyrics-header-progress-animation'),
      colorAnimationKey: const ValueKey(
        'lyrics-header-progress-color-animation',
      ),
      fillKey: const ValueKey('lyrics-header-progress-fill'),
      semanticsLabel: strings.choose(
        'Progreso de reproducción',
        'Playback progress',
      ),
    );
  }
}

class _SyncedLyricsTimeline extends ConsumerStatefulWidget {
  const _SyncedLyricsTimeline({
    required this.lines,
    required this.romanizedLines,
    required this.offset,
    required this.sourceFooter,
    required this.lyricsCentered,
    required this.animationStyle,
  });

  final List<LyricLine> lines;
  final List<String>? romanizedLines;
  final Duration offset;
  final String sourceFooter;
  final bool lyricsCentered;
  final LyricsAnimationStyle animationStyle;

  @override
  ConsumerState<_SyncedLyricsTimeline> createState() =>
      _SyncedLyricsTimelineState();
}

class _SyncedLyricsTimelineState extends ConsumerState<_SyncedLyricsTimeline> {
  late List<GlobalKey> _lineKeys;
  late int _activeIndex;
  ProviderSubscription<Duration>? _positionSubscription;
  Timer? _resumeAutoScrollTimer;
  bool _autoScrollSuspended = false;
  double? _activeScaledFontSize;
  double? _layoutWidth;
  int _animationRevision = 0;

  @override
  void initState() {
    super.initState();
    _lineKeys = _createLineKeys();
    _activeIndex = _activeLineIndex(
      widget.lines,
      ref.read(currentPlaybackPositionProvider) + widget.offset,
    );
    _positionSubscription = ref.listenManual<Duration>(
      currentPlaybackPositionProvider,
      (_, position) => _updateActiveLine(position),
    );
    _scheduleAutoScroll();
  }

  @override
  void didUpdateWidget(covariant _SyncedLyricsTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      _lineKeys = _createLineKeys();
    }
    if (oldWidget.animationStyle != widget.animationStyle) {
      _animationRevision++;
    }
    if (!identical(oldWidget.lines, widget.lines) ||
        oldWidget.offset != widget.offset) {
      _updateActiveLine(ref.read(currentPlaybackPositionProvider));
    }
    if (!identical(oldWidget.romanizedLines, widget.romanizedLines)) {
      _scheduleAutoScroll();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextActiveScaledFontSize = MediaQuery.textScalerOf(
      context,
    ).scale(_lyricsTypographyFor(context).active);
    final nextLayoutWidth = MediaQuery.sizeOf(context).width;
    final previousActiveScaledFontSize = _activeScaledFontSize;
    final previousLayoutWidth = _layoutWidth;
    _activeScaledFontSize = nextActiveScaledFontSize;
    _layoutWidth = nextLayoutWidth;
    if (previousActiveScaledFontSize != null &&
        (previousActiveScaledFontSize != nextActiveScaledFontSize ||
            previousLayoutWidth != nextLayoutWidth)) {
      _scheduleAutoScroll();
    }
  }

  @override
  void dispose() {
    _positionSubscription?.close();
    _resumeAutoScrollTimer?.cancel();
    super.dispose();
  }

  List<GlobalKey> _createLineKeys() {
    return List<GlobalKey>.generate(widget.lines.length, (_) => GlobalKey());
  }

  void _updateActiveLine(Duration position) {
    final next = _activeLineIndex(widget.lines, position + widget.offset);
    if (next == _activeIndex || !mounted) {
      return;
    }
    setState(() {
      _activeIndex = next;
      _animationRevision++;
    });
    _scheduleAutoScroll();
  }

  void _scheduleAutoScroll() {
    if (_activeIndex < 0 || _autoScrollSuspended) {
      return;
    }
    final targetIndex = _activeIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _autoScrollSuspended || targetIndex != _activeIndex) {
        return;
      }
      final targetContext = _lineKeys[targetIndex].currentContext;
      if (targetContext == null) {
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          targetContext,
          alignment: 0.43,
          duration: const Duration(milliseconds: 520),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _suspendAutoScroll() {
    _resumeAutoScrollTimer?.cancel();
    _autoScrollSuspended = true;
    _resumeAutoScrollTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) {
        return;
      }
      _autoScrollSuspended = false;
      _scheduleAutoScroll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final typography = _lyricsTypographyFor(context);
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final verticalPadding = (viewportHeight * 0.27).clamp(96.0, 260.0);
    final horizontalPadding =
        Theme.of(context).platform == TargetPlatform.android ? 12.0 : 24.0;

    return NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (notification.dragDetails != null) {
          _suspendAutoScroll();
        }
        return false;
      },
      child: SingleChildScrollView(
        key: const ValueKey('synced-lyrics-scroll'),
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          verticalPadding,
          horizontalPadding,
          verticalPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LyricsSourceAttribution(
              source: widget.sourceFooter,
              placement: 'top',
            ),
            const SizedBox(height: 12),
            for (var index = 0; index < widget.lines.length; index++)
              KeyedSubtree(
                key: _lineKeys[index],
                child: _LyricLineTile(
                  key: ValueKey('lyrics-line-tile-$index'),
                  contentKey: index == _activeIndex
                      ? const ValueKey('active-lyric-line')
                      : ValueKey('lyric-line-$index'),
                  line: widget.lines[index],
                  originalText: widget.lines[index].text,
                  romanizedText:
                      widget.romanizedLines != null &&
                          index < widget.romanizedLines!.length
                      ? widget.romanizedLines![index]
                      : null,
                  romanizationKey: ValueKey('lyrics-line-romanization-$index'),
                  active: index == _activeIndex,
                  passed: index < _activeIndex,
                  lyricsCentered: widget.lyricsCentered,
                  animationStyle: widget.animationStyle,
                  animationRevision: _animationRevision,
                  activeFontSize: typography.active,
                  inactiveFontSize: typography.inactive,
                  onTap: () => _seekToLine(widget.lines[index]),
                ),
              ),
            const SizedBox(height: 20),
            _LyricsSourceAttribution(
              source: widget.sourceFooter,
              placement: 'bottom',
            ),
            const SizedBox(height: 10),
            Text(
              key: const ValueKey('lyrics-seek-hint'),
              strings.tapLyricsToSeek,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.52),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _seekToLine(LyricLine line) {
    final targetMilliseconds = (line.timestamp - widget.offset).inMilliseconds
        .clamp(0, 1 << 31)
        .toInt();
    unawaited(
      ref
          .read(playerControllerProvider.notifier)
          .seek(Duration(milliseconds: targetMilliseconds)),
    );
  }
}

class _LyricLineTile extends StatelessWidget {
  const _LyricLineTile({
    required this.contentKey,
    required this.line,
    required this.originalText,
    required this.romanizedText,
    required this.romanizationKey,
    required this.active,
    required this.passed,
    required this.lyricsCentered,
    required this.animationStyle,
    required this.animationRevision,
    required this.activeFontSize,
    required this.inactiveFontSize,
    required this.onTap,
    super.key,
  });

  final Key contentKey;
  final LyricLine line;
  final String originalText;
  final String? romanizedText;
  final Key romanizationKey;
  final bool active;
  final bool passed;
  final bool lyricsCentered;
  final LyricsAnimationStyle animationStyle;
  final int animationRevision;
  final double activeFontSize;
  final double inactiveFontSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.downloadAccentFor(context);
    final color = active
        ? Color.alphaBlend(accent.withValues(alpha: 0.08), Colors.white)
        : Colors.white.withValues(alpha: passed ? 0.62 : 0.38);
    final textStyle = TextStyle(
      color: color,
      fontSize: active ? activeFontSize : inactiveFontSize,
      height: 1.16,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.45,
      shadows: active
          ? [
              Shadow(color: accent.withValues(alpha: 0.30), blurRadius: 10),
              Shadow(color: accent.withValues(alpha: 0.14), blurRadius: 24),
              const Shadow(
                color: Color(0x7A000000),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ]
          : null,
    );
    final trimmedRomanization = romanizedText?.trim();
    final showRomanization =
        trimmedRomanization != null &&
        trimmedRomanization.isNotEmpty &&
        trimmedRomanization != originalText.trim();
    final animationDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    final lineText = Padding(
      key: contentKey,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            originalText,
            textAlign: lyricsCentered ? TextAlign.center : TextAlign.start,
          ),
          if (showRomanization) ...[
            SizedBox(height: active ? 5 : 4),
            AnimatedDefaultTextStyle(
              duration: animationDuration,
              curve: Curves.easeOutCubic,
              style: TextStyle(
                color: Colors.white.withValues(
                  alpha: active ? 0.72 : (passed ? 0.55 : 0.48),
                ),
                fontSize: ((active ? activeFontSize : inactiveFontSize) * 0.62)
                    .clamp(15.0, 22.0)
                    .toDouble(),
                height: 1.25,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
              child: Text(
                trimmedRomanization,
                key: romanizationKey,
                textAlign: lyricsCentered ? TextAlign.center : TextAlign.start,
              ),
            ),
          ],
        ],
      ),
    );
    final styledLine = AnimatedDefaultTextStyle(
      duration: animationDuration,
      curve: Curves.easeOutCubic,
      style: textStyle,
      child: lineText,
    );
    return Semantics(
      label: showRomanization
          ? '$originalText\n$trimmedRomanization'
          : originalText,
      excludeSemantics: true,
      selected: active,
      button: true,
      onTap: onTap,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: LyricsAnimationTransition(
          style: animationStyle,
          active: active,
          accent: accent,
          alignment: lyricsCentered ? Alignment.center : Alignment.centerLeft,
          revision: animationRevision,
          child: styledLine,
        ),
      ),
    );
  }
}

class _LyricsOffsetControls extends ConsumerWidget {
  const _LyricsOffsetControls({
    required this.offset,
    required this.onDecrease,
    required this.onIncrease,
    required this.onReset,
  });

  final Duration offset;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final accent = AppColors.downloadAccentFor(context);
    final opaqueSurface = AppColors.menuBackgroundFor(context);
    final border = AppColors.menuBorderFor(context);
    final subtleTextAccent = Color.alphaBlend(
      accent.withValues(alpha: 0.08),
      AppColors.menuForegroundFor(context),
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = opaqueSurface.withValues(alpha: isDark ? 0.62 : 0.72);
    final seconds = offset.inMilliseconds / 1000;
    final formatted =
        '${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(2)} s';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        label: strings.lyricsOffset,
        value: formatted,
        child: Container(
          key: const ValueKey('lyrics-offset-control'),
          height: 48,
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: border),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? const Color(0x48000000)
                    : const Color(0x20000000),
                blurRadius: 12,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 48,
                child: IconButton(
                  key: const ValueKey('lyrics-offset-decrease'),
                  tooltip: strings.choose(
                    'Atrasar letra 0.50 segundos',
                    'Delay lyrics by 0.50 seconds',
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 19,
                  color: accent,
                  icon: const Icon(Icons.remove_rounded),
                  onPressed: onDecrease,
                ),
              ),
              SizedBox(
                width: 92,
                height: 40,
                child: Semantics(
                  label: strings.resetLyricsOffset,
                  value: formatted,
                  button: true,
                  enabled: offset != Duration.zero,
                  excludeSemantics: true,
                  child: Tooltip(
                    message: strings.resetLyricsOffset,
                    child: TextButton(
                      key: const ValueKey('lyrics-offset-reset'),
                      onPressed: offset == Duration.zero ? null : onReset,
                      style: TextButton.styleFrom(
                        foregroundColor: accent,
                        disabledForegroundColor: accent.withValues(alpha: 0.54),
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(92, 40),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (offset != Duration.zero) ...[
                              const Icon(Icons.restart_alt_rounded, size: 15),
                              const SizedBox(width: 3),
                            ],
                            Text(
                              formatted,
                              key: const ValueKey('lyrics-offset-value'),
                              maxLines: 1,
                              style: TextStyle(
                                color: offset == Duration.zero
                                    ? subtleTextAccent.withValues(alpha: 0.72)
                                    : subtleTextAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox.square(
                dimension: 48,
                child: IconButton(
                  key: const ValueKey('lyrics-offset-increase'),
                  tooltip: strings.choose(
                    'Adelantar letra 0.50 segundos',
                    'Advance lyrics by 0.50 seconds',
                  ),
                  padding: EdgeInsets.zero,
                  iconSize: 19,
                  color: accent,
                  icon: const Icon(Icons.add_rounded),
                  onPressed: onIncrease,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlainLyricsView extends ConsumerWidget {
  const _PlainLyricsView({
    required this.lyrics,
    required this.romanizedLyrics,
    required this.sourceFooter,
    required this.lyricsCentered,
  });

  final String lyrics;
  final String? romanizedLyrics;
  final String sourceFooter;
  final bool lyricsCentered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final typography = _lyricsTypographyFor(context);
    final accent = AppColors.downloadAccentFor(context);
    final displayedLyrics = lyricsCentered
        ? lyrics.split('\n').map((line) => line.trim()).join('\n')
        : lyrics;
    final trimmedRomanization = romanizedLyrics?.trim();
    final showRomanization =
        trimmedRomanization != null &&
        trimmedRomanization.isNotEmpty &&
        trimmedRomanization != lyrics.trim();
    final displayedRomanization = showRomanization
        ? (lyricsCentered
              ? trimmedRomanization
                    .split('\n')
                    .map((line) => line.trim())
                    .join('\n')
              : trimmedRomanization)
        : null;
    final originalLines = displayedLyrics.split('\n');
    final romanizedLines = displayedRomanization?.split('\n');
    final canPairLines =
        romanizedLines != null && romanizedLines.length == originalLines.length;
    final originalStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontSize: typography.plain,
      height: 1.38,
      fontWeight: FontWeight.w800,
      shadows: [
        Shadow(color: accent.withValues(alpha: 0.16), blurRadius: 12),
        Shadow(color: accent.withValues(alpha: 0.06), blurRadius: 24),
      ],
    );
    final romanizedStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.62),
      fontSize: typography.plain * 0.62,
      height: 1.36,
      fontWeight: FontWeight.w600,
    );
    final horizontalPadding =
        Theme.of(context).platform == TargetPlatform.android ? 16.0 : 28.0;
    return SingleChildScrollView(
      key: const ValueKey('plain-lyrics-scroll'),
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        26,
        horizontalPadding,
        48,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.24),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    strings.lyricsUnsynced,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _LyricsSourceAttribution(source: sourceFooter, placement: 'top'),
          const SizedBox(height: 24),
          Column(
            key: const ValueKey('plain-lyrics-text'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: canPairLines
                ? [
                    for (var index = 0; index < originalLines.length; index++)
                      _PlainLyricLine(
                        key: ValueKey('plain-lyrics-pair-$index'),
                        originalKey: ValueKey('plain-lyrics-original-$index'),
                        romanizationKey: ValueKey(
                          'plain-lyrics-romanization-$index',
                        ),
                        original: originalLines[index],
                        romanized: romanizedLines[index],
                        textAlign: lyricsCentered
                            ? TextAlign.center
                            : TextAlign.start,
                        originalStyle: originalStyle,
                        romanizedStyle: romanizedStyle,
                      ),
                  ]
                : [
                    Text(
                      key: const ValueKey('plain-lyrics-original'),
                      displayedLyrics,
                      textAlign: lyricsCentered
                          ? TextAlign.center
                          : TextAlign.start,
                      style: originalStyle,
                    ),
                  ],
          ),
          if (displayedRomanization != null && !canPairLines) ...[
            const SizedBox(height: 12),
            Text(
              key: const ValueKey('plain-lyrics-romanization'),
              displayedRomanization,
              textAlign: lyricsCentered ? TextAlign.center : TextAlign.start,
              style: romanizedStyle,
            ),
          ],
          const SizedBox(height: 32),
          _LyricsSourceAttribution(source: sourceFooter, placement: 'bottom'),
        ],
      ),
    );
  }
}

class _LyricsSourceAttribution extends StatelessWidget {
  const _LyricsSourceAttribution({
    required this.source,
    required this.placement,
  });

  final String source;
  final String placement;

  @override
  Widget build(BuildContext context) {
    return Text(
      source,
      key: ValueKey('lyrics-source-$placement'),
      textAlign: TextAlign.center,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.42),
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _PlainLyricLine extends StatelessWidget {
  const _PlainLyricLine({
    required this.originalKey,
    required this.romanizationKey,
    required this.original,
    required this.romanized,
    required this.textAlign,
    required this.originalStyle,
    required this.romanizedStyle,
    super.key,
  });

  final Key originalKey;
  final Key romanizationKey;
  final String original;
  final String romanized;
  final TextAlign textAlign;
  final TextStyle originalStyle;
  final TextStyle romanizedStyle;

  @override
  Widget build(BuildContext context) {
    final trimmedRomanization = romanized.trim();
    final showRomanization =
        trimmedRomanization.isNotEmpty &&
        trimmedRomanization != original.trim();
    final semanticLabel = showRomanization
        ? '$original\n$trimmedRomanization'
        : original;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              original,
              key: originalKey,
              textAlign: textAlign,
              style: originalStyle,
            ),
            if (showRomanization) ...[
              const SizedBox(height: 4),
              Text(
                trimmedRomanization,
                key: romanizationKey,
                textAlign: textAlign,
                style: romanizedStyle,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LyricsMessage extends StatelessWidget {
  const _LyricsMessage({
    required this.icon,
    required this.message,
    this.loading = false,
    this.actionLabel,
    this.actionIcon = Icons.refresh_rounded,
    this.onAction,
    this.footer,
  });

  final IconData icon;
  final String message;
  final bool loading;
  final String? actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox.square(
                dimension: 38,
                child: CircularProgressIndicator(strokeWidth: 4),
              )
            else
              Icon(icon, size: 52, color: AppColors.downloadAccentFor(context)),
            const SizedBox(height: 18),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.downloadAccentFor(context),
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  side: BorderSide(
                    color: AppColors.downloadAccentFor(
                      context,
                    ).withValues(alpha: 0.72),
                  ),
                ),
                icon: Icon(actionIcon),
                label: Text(actionLabel!),
              ),
            ],
            if (footer != null) ...[
              const SizedBox(height: 18),
              Text(
                footer!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.42),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatLyricsDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

int _activeLineIndex(List<LyricLine> lines, Duration effectivePosition) {
  var low = 0;
  var high = lines.length - 1;
  var result = -1;
  final target = effectivePosition.inMilliseconds;
  while (low <= high) {
    final middle = low + ((high - low) >> 1);
    if (lines[middle].timestamp.inMilliseconds <= target) {
      result = middle;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return result;
}
