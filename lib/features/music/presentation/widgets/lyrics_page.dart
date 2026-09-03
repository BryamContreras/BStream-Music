import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../../../platform_channels/android_screen_channel.dart';
import '../../../../platform_channels/lyrics_presentation_chrome.dart';
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
import 'uniform_playback_slider_track_shape.dart';

bool _usesMobileLyricsLayout(BuildContext context) =>
    switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };

double _lyricsCompanionWidthFor(Size size, {required bool mobileLayout}) {
  final preferred = size.width * (mobileLayout ? 0.38 : 0.34);
  final minimum = mobileLayout ? 210.0 : 300.0;
  final maximum = mobileLayout ? 300.0 : 580.0;
  final viewportMaximum = math.max(150.0, size.width * 0.50);
  return math.min(preferred.clamp(minimum, maximum), viewportMaximum);
}

double _lyricsDesktopCompanionGapFor(
  double viewportWidth, {
  required bool mobileLayout,
}) {
  if (mobileLayout) {
    return 0;
  }
  return math.min(80.0, math.max(0.0, (viewportWidth - 1720.0) * 0.40));
}

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

({
  Color color,
  double innerAlpha,
  double innerBlur,
  double outerAlpha,
  double outerBlur,
})
_lyricsHaloFor(BuildContext context, Color accent) {
  final mobileLayout = _usesMobileLyricsLayout(context);
  final haloColor = accent.computeLuminance() < 0.40
      ? Color.alphaBlend(
          Colors.white.withValues(alpha: mobileLayout ? 0.18 : 0.10),
          accent,
        )
      : accent;
  return (
    color: haloColor,
    // Smaller mobile glyphs and the artwork-derived background need a little
    // more contrast than desktop for the same perceived outer glow. Only the
    // Gaussian shadows are strengthened; the glyph itself remains white.
    innerAlpha: mobileLayout ? 0.48 : 0.30,
    innerBlur: 10,
    outerAlpha: mobileLayout ? 0.24 : 0.14,
    outerBlur: mobileLayout ? 26 : 24,
  );
}

class LyricsPage extends ConsumerStatefulWidget {
  const LyricsPage({
    super.key,
    this.presentationChrome = const LyricsPresentationChrome(),
  });

  @visibleForTesting
  final LyricsPresentationChrome presentationChrome;

  @override
  ConsumerState<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends ConsumerState<LyricsPage>
    with SingleTickerProviderStateMixin {
  static const _mobileLayoutTransitionDuration = Duration(milliseconds: 500);

  final _manualSearchController = TextEditingController();
  final _screenChannel = const AndroidScreenChannel();
  late final AnimationController _mobileLayoutController;
  late final Animation<double> _mobileSideLayoutAnimation;
  String? _lookupIdentity;
  bool _showSimilarLyrics = false;
  String _manualSearchTitle = '';
  LyricsDocument? _romanizationSource;
  Set<LyricsRomanizationLanguage>? _romanizationLanguages;
  Future<RomanizedLyricsView>? _romanizationFuture;
  Future<void> _presentationChromeQueue = Future<void>.value();
  TargetPlatform? _presentationChromePlatform;
  bool _presentationChromeActive = false;
  bool? _mobileLandscapeTarget;
  bool? _mobileLayoutReducedMotion;
  int _mobileLayoutAnimationRevision = 0;

  @override
  void initState() {
    super.initState();
    _mobileLayoutController = AnimationController(
      vsync: this,
      duration: _mobileLayoutTransitionDuration,
    );
    _mobileSideLayoutAnimation = CurvedAnimation(
      parent: _mobileLayoutController,
      curve: Curves.easeInOutCubic,
      reverseCurve: Curves.easeInOutCubic,
    );
    _setKeepScreenOn(true);
  }

  @override
  void dispose() {
    _setKeepScreenOn(false);
    _setPresentationChromeActive(false, platform: _presentationChromePlatform);
    _mobileLayoutController.dispose();
    _manualSearchController.dispose();
    super.dispose();
  }

  void _setKeepScreenOn(bool enabled) {
    if (AppPlatform.isMobile) {
      unawaited(_screenChannel.setKeepScreenOn(enabled));
    }
  }

  void _setPresentationChromeActive(bool active, {TargetPlatform? platform}) {
    final resolvedPlatform = platform ?? _presentationChromePlatform;
    if (resolvedPlatform == null ||
        (_presentationChromeActive == active &&
            (!active || _presentationChromePlatform == resolvedPlatform))) {
      return;
    }

    final previousPlatform = _presentationChromePlatform;
    final wasActive = _presentationChromeActive;
    _presentationChromeActive = active;
    _presentationChromePlatform = resolvedPlatform;

    if (wasActive &&
        active &&
        previousPlatform != null &&
        previousPlatform != resolvedPlatform) {
      _enqueuePresentationChrome(previousPlatform, false);
    }
    _enqueuePresentationChrome(resolvedPlatform, active);
  }

  void _enqueuePresentationChrome(TargetPlatform platform, bool active) {
    _presentationChromeQueue = _presentationChromeQueue.then((_) async {
      try {
        await widget.presentationChrome.setSideModeActive(
          platform: platform,
          active: active,
        );
      } catch (_) {
        // Window chrome is cosmetic and must never make Lyrics unusable.
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mobileLayout = _usesMobileLyricsLayout(context);
    final size = MediaQuery.sizeOf(context);
    final landscapeTarget = mobileLayout && size.width > size.height;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final previousTarget = _mobileLandscapeTarget;
    final reducedMotionChanged =
        _mobileLayoutReducedMotion != null &&
        _mobileLayoutReducedMotion != reducedMotion;
    _mobileLandscapeTarget = landscapeTarget;
    _mobileLayoutReducedMotion = reducedMotion;

    if (previousTarget == null || reducedMotion) {
      _mobileLayoutAnimationRevision++;
      _mobileLayoutController.stop();
      _mobileLayoutController.value = landscapeTarget ? 1 : 0;
    } else if (previousTarget != landscapeTarget) {
      final revision = ++_mobileLayoutAnimationRevision;
      _mobileLayoutController.stop();
      // Let the first frame at the new size retain the previous arrangement.
      // Otherwise the platform's own rotation animation can consume most of
      // this transition before Flutter presents a frame to the user.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            revision != _mobileLayoutAnimationRevision ||
            _mobileLandscapeTarget != landscapeTarget ||
            _mobileLayoutReducedMotion == true) {
          return;
        }
        unawaited(
          _mobileLayoutController.animateTo(
            landscapeTarget ? 1 : 0,
            curve: Curves.linear,
          ),
        );
      });
    } else if (reducedMotionChanged) {
      _mobileLayoutAnimationRevision++;
      _mobileLayoutController.stop();
      _mobileLayoutController.value = landscapeTarget ? 1 : 0;
    }

    if (!mobileLayout) {
      return;
    }
    _setPresentationChromeActive(
      size.width > size.height,
      platform: Theme.of(context).platform,
    );
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
    final miniPlayerMode =
        settings?.miniPlayerMode ??
        defaultMiniPlayerModeForPlatform(Theme.of(context).platform);
    final miniPlayerBackgroundMode =
        settings?.miniPlayerBackgroundMode ?? defaultMiniPlayerBackgroundMode;
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final mediaPadding = MediaQuery.paddingOf(context);
    final systemLeftInset = math.max(viewPadding.left, mediaPadding.left);
    final systemRightInset = math.max(viewPadding.right, mediaPadding.right);
    final systemBottomInset = math.max(viewPadding.bottom, mediaPadding.bottom);
    final mobileLayout = _usesMobileLyricsLayout(context);
    final mediaSize = MediaQuery.sizeOf(context);
    final landscape = mediaSize.width > mediaSize.height;
    final showSideCompanion = mobileLayout ? landscape : true;
    final showBottomMiniPlayer = !mobileLayout && !showSideCompanion;
    final sideCompanionGap = showSideCompanion
        ? _lyricsDesktopCompanionGapFor(
            mediaSize.width,
            mobileLayout: mobileLayout,
          )
        : 0.0;
    final sideLayoutWidth = showSideCompanion && !mobileLayout
        ? math.min(mediaSize.width, 1720.0 + sideCompanionGap)
        : mediaSize.width;
    final sideLayoutWidthFactor = sideLayoutWidth / mediaSize.width;
    final companionLayoutSize = mobileLayout
        ? Size(
            math.max(mediaSize.width, mediaSize.height),
            math.min(mediaSize.width, mediaSize.height),
          )
        : Size(sideLayoutWidth, mediaSize.height);
    final companionWidth = _lyricsCompanionWidthFor(
      companionLayoutSize,
      mobileLayout: mobileLayout,
    );
    // Base mobile sizing on the orientation-independent long/short sides. The
    // outgoing companion therefore keeps its landscape width while portrait
    // clips it away instead of visibly snapping to a narrower width first.
    final animatedMobileCompanionWidth = math.min(
      math.max(210.0, companionWidth),
      math.min(mediaSize.width, mediaSize.height),
    );
    final animatedMobileCompanionSlotWidth = math.min(
      animatedMobileCompanionWidth,
      math.max(0.0, mediaSize.width - 150),
    );
    final miniPlayerHeight = miniPlayerHeightFor(context, mode: miniPlayerMode);
    final bottomChromeHeight = !mobileLayout && showBottomMiniPlayer
        ? miniPlayerHeight
        : 0.0;
    _syncLookup(lookup);

    final ({Widget content, bool showOffset}) lyricsPresentation =
        lookup == null
        ? (
            content: _LyricsMessage(
              icon: Icons.lyrics_outlined,
              message: strings.noPlayback,
            ),
            showOffset: false,
          )
        : _showSimilarLyrics
        ? (content: _buildSimilarLyrics(lookup), showOffset: false)
        : selectedLyrics != null
        ? (
            content: _buildLyrics(
              selectedLyrics,
              offset,
              lyricsCentered,
              lyricsAnimationStyle,
              lyricsRomanizationEnabled,
              lyricsRomanizationLanguages,
            ),
            showOffset: selectedLyrics.lines.isNotEmpty,
          )
        : ref
              .watch(lyricsProvider(lookup))
              .when(
                loading: () => (
                  content: _LyricsMessage(
                    icon: Icons.manage_search_rounded,
                    message: strings.lyricsLoading,
                    loading: true,
                  ),
                  showOffset: false,
                ),
                error: (error, _) {
                  final noInternet = error is LyricsConnectionException;
                  return (
                    content: _LyricsMessage(
                      icon: noInternet
                          ? Icons.wifi_off_rounded
                          : Icons.cloud_off_rounded,
                      message: noInternet
                          ? strings.lyricsNoInternet
                          : strings.lyricsLoadError,
                      actionLabel: strings.retry,
                      onAction: () => ref.invalidate(lyricsProvider(lookup)),
                    ),
                    showOffset: false,
                  );
                },
                data: (lyrics) => (
                  content: _buildLyrics(
                    lyrics,
                    offset,
                    lyricsCentered,
                    lyricsAnimationStyle,
                    lyricsRomanizationEnabled,
                    lyricsRomanizationLanguages,
                  ),
                  showOffset: lyrics?.lines.isNotEmpty == true,
                ),
              );

    final lyricsContentLayer = _buildLyricsContentLayer(
      content: lyricsPresentation.content,
      mobileLayout: mobileLayout,
      showOffset: lyricsPresentation.showOffset,
      offset: offset,
    );

    return Scaffold(
      backgroundColor: const Color(0xFF030504),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const PlayerPlaybackGradientBackground(),
          const DecoratedBox(
            decoration: BoxDecoration(color: Color(0x52000000)),
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: systemBottomInset + bottomChromeHeight,
              ),
              child: mobileLayout
                  ? _LyricsMobileOrientationLayout(
                      landscape: landscape,
                      animation: _mobileSideLayoutAnimation,
                      companionWidth: animatedMobileCompanionWidth,
                      companionSlotWidth: animatedMobileCompanionSlotWidth,
                      header: _LyricsHeader(lookup: lookup),
                      companion: const _LyricsPlaybackCompanion(
                        mobileLayout: true,
                      ),
                      content: lyricsContentLayer,
                    )
                  : Column(
                      children: [
                        if (!showSideCompanion) _LyricsHeader(lookup: lookup),
                        Expanded(
                          child: FractionallySizedBox(
                            key: const ValueKey('lyrics-side-layout-frame'),
                            widthFactor: sideLayoutWidthFactor,
                            alignment: Alignment.center,
                            child: Row(
                              children: [
                                if (showSideCompanion)
                                  SizedBox(
                                    key: const ValueKey(
                                      'lyrics-companion-width',
                                    ),
                                    width: companionWidth,
                                    child: const _LyricsPlaybackCompanion(
                                      mobileLayout: false,
                                    ),
                                  ),
                                if (showSideCompanion)
                                  SizedBox(
                                    key: const ValueKey(
                                      'lyrics-desktop-companion-gap',
                                    ),
                                    width: sideCompanionGap,
                                  ),
                                Expanded(
                                  key: const ValueKey('lyrics-content-region'),
                                  child: lyricsContentLayer,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          if (!mobileLayout && showBottomMiniPlayer)
            Positioned(
              left: systemLeftInset,
              right: systemRightInset,
              bottom: systemBottomInset,
              child: SizedBox(
                key: const ValueKey('lyrics-player-dock'),
                height: bottomChromeHeight,
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

  Widget _buildLyricsContentLayer({
    required Widget content,
    required bool mobileLayout,
    required bool showOffset,
    required Duration offset,
  }) {
    final strings = ref.watch(appStringsProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        if (!mobileLayout || showOffset)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _LyricsToolbarFit(
                enabled: mobileLayout,
                child: Row(
                  key: const ValueKey('lyrics-overlay-toolbar'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!mobileLayout)
                      _LyricsExitButton(
                        tooltip: strings.choose(
                          'Salir de Letras',
                          'Exit Lyrics',
                        ),
                        onPressed: () =>
                            unawaited(Navigator.of(context).maybePop()),
                      ),
                    if (!mobileLayout && showOffset) const SizedBox(width: 8),
                    if (showOffset)
                      _LyricsOffsetControls(
                        offset: offset,
                        onDecrease: offset > LyricsOffsetController.minimum
                            ? ref
                                  .read(lyricsOffsetControllerProvider.notifier)
                                  .decrease
                            : null,
                        onIncrease: offset < LyricsOffsetController.maximum
                            ? ref
                                  .read(lyricsOffsetControllerProvider.notifier)
                                  .increase
                            : null,
                        onReset: ref
                            .read(lyricsOffsetControllerProvider.notifier)
                            .reset,
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
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
      return _SyncedLyricsTimeline(
        lines: lyrics.lines,
        romanizedLines: romanized?.syncedLines,
        offset: offset,
        sourceFooter: sourceFooter,
        lyricsCentered: lyricsCentered,
        animationStyle: lyricsAnimationStyle,
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

/// Applies the new orientation's geometry once, then animates only composited
/// opacity/translation layers. This avoids remeasuring every lyric line on
/// each frame while its available width changes.
class _LyricsMobileOrientationLayout extends AnimatedWidget {
  const _LyricsMobileOrientationLayout({
    required this.landscape,
    required Animation<double> animation,
    required this.companionWidth,
    required this.companionSlotWidth,
    required this.header,
    required this.companion,
    required this.content,
  }) : super(listenable: animation);

  final bool landscape;
  final double companionWidth;
  final double companionSlotWidth;
  final Widget header;
  final Widget companion;
  final Widget content;

  Animation<double> get _animation => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    final landscapeFactor = _animation.value.clamp(0.0, 1.0).toDouble();
    final headerFactor = 1 - landscapeFactor;
    final settleFactor = landscape ? landscapeFactor : headerFactor;

    Widget companionFrame({required Widget child, Key? key}) {
      return SizedBox(
        key: key,
        width: companionSlotWidth,
        child: ClipRect(
          child: OverflowBox(
            alignment: AlignmentDirectional.centerStart,
            minWidth: companionWidth,
            maxWidth: companionWidth,
            child: SizedBox(
              key: const ValueKey('lyrics-companion-width'),
              width: companionWidth,
              child: child,
            ),
          ),
        ),
      );
    }

    return Stack(
      key: const ValueKey('lyrics-mobile-orientation-layout'),
      fit: StackFit.expand,
      clipBehavior: Clip.hardEdge,
      children: [
        Column(
          children: [
            if (landscape)
              const SizedBox.shrink(key: ValueKey('lyrics-mobile-header-slot'))
            else
              _LyricsPaintTransition(
                key: const ValueKey('lyrics-mobile-header-layout-transition'),
                opacityKey: const ValueKey(
                  'lyrics-mobile-header-layout-opacity',
                ),
                slideKey: const ValueKey('lyrics-mobile-header-layout-slide'),
                factor: headerFactor,
                hiddenOffset: const Offset(0, -14),
                child: header,
              ),
            Expanded(
              key: const ValueKey('lyrics-mobile-row-region'),
              child: FractionallySizedBox(
                key: const ValueKey('lyrics-side-layout-frame'),
                widthFactor: 1,
                child: Row(
                  children: [
                    if (landscape)
                      companionFrame(
                        key: const ValueKey('lyrics-mobile-companion-slot'),
                        child: _LyricsPaintTransition(
                          key: const ValueKey(
                            'lyrics-mobile-companion-layout-transition',
                          ),
                          opacityKey: const ValueKey(
                            'lyrics-mobile-companion-layout-opacity',
                          ),
                          slideKey: const ValueKey(
                            'lyrics-mobile-companion-layout-slide',
                          ),
                          factor: landscapeFactor,
                          hiddenOffset: const Offset(-24, 0),
                          child: companion,
                        ),
                      )
                    else
                      const SizedBox.shrink(
                        key: ValueKey('lyrics-mobile-companion-slot'),
                      ),
                    Expanded(
                      key: const ValueKey('lyrics-content-region'),
                      child: _LyricsContentSettleTransition(
                        factor: settleFactor,
                        landscape: landscape,
                        child: content,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (landscape && headerFactor > 0.001)
          Align(
            alignment: Alignment.topCenter,
            child: _LyricsPaintTransition(
              key: const ValueKey('lyrics-mobile-header-layout-transition'),
              opacityKey: const ValueKey('lyrics-mobile-header-layout-opacity'),
              slideKey: const ValueKey('lyrics-mobile-header-layout-slide'),
              factor: headerFactor,
              hiddenOffset: const Offset(0, -14),
              allowInteraction: false,
              child: header,
            ),
          ),
        if (!landscape && landscapeFactor > 0.001)
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            width: companionSlotWidth,
            child: companionFrame(
              child: _LyricsPaintTransition(
                key: const ValueKey(
                  'lyrics-mobile-companion-layout-transition',
                ),
                opacityKey: const ValueKey(
                  'lyrics-mobile-companion-layout-opacity',
                ),
                slideKey: const ValueKey(
                  'lyrics-mobile-companion-layout-slide',
                ),
                factor: landscapeFactor,
                hiddenOffset: const Offset(-24, 0),
                allowInteraction: false,
                child: companion,
              ),
            ),
          ),
      ],
    );
  }
}

class _LyricsPaintTransition extends StatelessWidget {
  const _LyricsPaintTransition({
    required this.opacityKey,
    required this.slideKey,
    required this.factor,
    required this.hiddenOffset,
    required this.child,
    this.allowInteraction = true,
    super.key,
  });

  final Key opacityKey;
  final Key slideKey;
  final double factor;
  final Offset hiddenOffset;
  final bool allowInteraction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final progress = factor.clamp(0.0, 1.0).toDouble();
    return Opacity(
      key: opacityKey,
      opacity: progress,
      child: ExcludeSemantics(
        excluding: !allowInteraction || progress < 0.999,
        child: IgnorePointer(
          ignoring: !allowInteraction || progress < 0.999,
          child: Transform.translate(
            key: slideKey,
            offset: hiddenOffset * (1 - progress),
            transformHitTests: false,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _LyricsContentSettleTransition extends StatelessWidget {
  const _LyricsContentSettleTransition({
    required this.factor,
    required this.landscape,
    required this.child,
  });

  final double factor;
  final bool landscape;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final progress = factor.clamp(0.0, 1.0).toDouble();
    final hiddenOffset = landscape ? const Offset(18, 0) : const Offset(-18, 0);
    final transitioning = progress < 0.999;
    return ExcludeSemantics(
      excluding: transitioning,
      child: IgnorePointer(
        ignoring: transitioning,
        child: Opacity(
          key: const ValueKey('lyrics-mobile-content-opacity'),
          opacity: 0.72 + (0.28 * progress),
          child: Transform.translate(
            key: const ValueKey('lyrics-mobile-content-slide'),
            offset: hiddenOffset * (1 - progress),
            transformHitTests: false,
            child: RepaintBoundary(
              key: const ValueKey('lyrics-mobile-content-repaint-boundary'),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricsToolbarFit extends StatelessWidget {
  const _LyricsToolbarFit({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }
    return FittedBox(
      key: const ValueKey('lyrics-mobile-toolbar-fit'),
      fit: BoxFit.scaleDown,
      child: child,
    );
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

class _LyricsExitButton extends StatelessWidget {
  const _LyricsExitButton({required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.downloadAccentFor(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = AppColors.menuBackgroundFor(
      context,
    ).withValues(alpha: isDark ? 0.62 : 0.72);
    final border = AppColors.menuBorderFor(context);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: surface,
        shape: BoxShape.circle,
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: isDark ? const Color(0x48000000) : const Color(0x20000000),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: IconButton(
        key: const ValueKey('lyrics-exit-button'),
        tooltip: tooltip,
        icon: const Icon(Icons.close_rounded),
        iconSize: 24,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        style: IconButton.styleFrom(
          minimumSize: const Size.square(48),
          maximumSize: const Size.square(48),
          foregroundColor: accent,
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          shape: const CircleBorder(),
        ),
        onPressed: onPressed,
      ),
    );
  }
}

class _LyricsPlaybackCompanion extends ConsumerWidget {
  const _LyricsPlaybackCompanion({required this.mobileLayout});

  final bool mobileLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final playback = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        return (
          title: snapshot?.title,
          artist: snapshot?.artist,
          thumbnailUrl: snapshot?.thumbnailUrl,
        );
      }),
    );
    final theme = Theme.of(context);
    final title = playback.title?.trim();
    final artist = playback.artist?.trim();
    final radius = BorderRadius.circular(mobileLayout ? 18 : 22);

    return Container(
      key: const ValueKey('lyrics-playback-companion'),
      margin: EdgeInsetsDirectional.fromSTEB(
        mobileLayout ? 8 : 14,
        mobileLayout ? 6 : 12,
        mobileLayout ? 5 : 8,
        mobileLayout ? 6 : 12,
      ),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: radius,
        border: Border.all(color: Colors.transparent),
      ),
      child: DecoratedBox(
        key: const ValueKey('lyrics-companion-glass-surface'),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: radius,
          border: Border.all(color: Colors.transparent),
        ),
        child: Padding(
          padding: mobileLayout
              ? const EdgeInsets.fromLTRB(12, 12, 12, 0)
              : const EdgeInsets.all(18),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    key: const ValueKey('lyrics-companion-artwork'),
                    borderRadius: BorderRadius.circular(appArtworkRadius),
                    child: SourceImage(
                      source: playback.thumbnailUrl,
                      cacheWidth: mobileLayout ? 512 : 1024,
                      fallback: ColoredBox(
                        key: const ValueKey(
                          'lyrics-companion-artwork-fallback',
                        ),
                        color: Colors.white.withValues(alpha: 0.08),
                        child: Icon(
                          Icons.music_note_rounded,
                          size: mobileLayout ? 42 : 58,
                          color: Colors.white.withValues(alpha: 0.62),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: mobileLayout ? 3 : 8),
              if (!mobileLayout) ...[
                MarqueeText(
                  title == null || title.isEmpty ? strings.noPlayback : title,
                  key: const ValueKey('lyrics-companion-title'),
                  pause: const Duration(milliseconds: 1700),
                  travel: const Duration(milliseconds: 6200),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontSize: 21,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  artist == null || artist.isEmpty
                      ? strings.unknownArtist
                      : artist,
                  key: const ValueKey('lyrics-companion-artist'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.68),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              _LyricsCompanionTimeline(mobileLayout: mobileLayout),
              _LyricsCompanionControls(mobileLayout: mobileLayout),
            ],
          ),
        ),
      ),
    );
  }
}

class _LyricsCompanionControls extends ConsumerWidget {
  const _LyricsCompanionControls({required this.mobileLayout});

  final bool mobileLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final playback = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        return (
          status: snapshot?.status,
          trackId: snapshot?.trackId,
          sourceUrl: snapshot?.sourceUrl,
          title: snapshot?.title,
          artist: snapshot?.artist,
        );
      }),
    );
    final hasTrack =
        playback.status != null &&
        playback.status != PlayerStatus.idle &&
        playback.status != PlayerStatus.failed &&
        (playback.trackId?.trim().isNotEmpty == true ||
            playback.sourceUrl?.trim().isNotEmpty == true ||
            playback.title?.trim().isNotEmpty == true ||
            playback.artist?.trim().isNotEmpty == true);
    final isPlaying = playback.status == PlayerStatus.playing;
    final foreground = Colors.white.withValues(alpha: 0.94);
    final sideSize = mobileLayout ? 44.0 : 40.0;
    final sideIconSize = mobileLayout ? 28.0 : 26.0;
    final primarySize = mobileLayout ? 48.0 : 46.0;
    final primaryIconSize = isPlaying
        ? mobileLayout
              ? 34.0
              : 32.0
        : mobileLayout
        ? 38.0
        : 36.0;

    IconButton sideControl({
      required Key key,
      required String tooltip,
      required IconData icon,
      required VoidCallback onPressed,
    }) {
      return IconButton(
        key: key,
        tooltip: tooltip,
        icon: Icon(icon),
        iconSize: sideIconSize,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tight(Size.square(sideSize)),
        style: IconButton.styleFrom(
          minimumSize: Size.square(sideSize),
          maximumSize: Size.square(sideSize),
          foregroundColor: foreground,
          disabledForegroundColor: foreground.withValues(alpha: 0.38),
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          shape: const CircleBorder(),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: hasTrack ? onPressed : null,
      );
    }

    return Transform.translate(
      offset: const Offset(0, -6),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              key: const ValueKey('lyrics-companion-transport-controls'),
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                sideControl(
                  key: const ValueKey('lyrics-companion-previous-control'),
                  tooltip: strings.previous,
                  icon: Icons.skip_previous_rounded,
                  onPressed: () => ref
                      .read(playerControllerProvider.notifier)
                      .playPrevious(),
                ),
                SizedBox.square(
                  dimension: primarySize,
                  child: IconButton(
                    key: const ValueKey('lyrics-companion-primary-control'),
                    tooltip: isPlaying ? strings.pause : strings.play,
                    icon: Transform.translate(
                      offset: isPlaying
                          ? Offset.zero
                          : Offset(mobileLayout ? 1.25 : 1.5, 0),
                      transformHitTests: false,
                      child: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    iconSize: primaryIconSize,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints.tight(Size.square(primarySize)),
                    style: IconButton.styleFrom(
                      minimumSize: Size.square(primarySize),
                      maximumSize: Size.square(primarySize),
                      foregroundColor: foreground,
                      disabledForegroundColor: foreground.withValues(
                        alpha: 0.38,
                      ),
                      backgroundColor: Colors.transparent,
                      disabledBackgroundColor: Colors.transparent,
                      shape: const CircleBorder(),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: hasTrack
                        ? () => ref
                              .read(playerControllerProvider.notifier)
                              .togglePlayPause()
                        : null,
                  ),
                ),
                sideControl(
                  key: const ValueKey('lyrics-companion-next-control'),
                  tooltip: strings.next,
                  icon: Icons.skip_next_rounded,
                  onPressed: () =>
                      ref.read(playerControllerProvider.notifier).playNext(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricsCompanionTimeline extends ConsumerWidget {
  const _LyricsCompanionTimeline({required this.mobileLayout});

  final bool mobileLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = ref.watch(appStringsProvider);
    final timeline = ref.watch(
      playerControllerProvider.select((player) {
        final snapshot = player.value;
        return (
          position: snapshot?.position ?? Duration.zero,
          duration: snapshot?.duration,
        );
      }),
    );
    final totalMilliseconds = timeline.duration?.inMilliseconds ?? 0;
    final clampedPosition = totalMilliseconds > 0
        ? Duration(
            milliseconds: timeline.position.inMilliseconds.clamp(
              0,
              totalMilliseconds,
            ),
          )
        : timeline.position;
    final labelStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.68),
      fontSize: mobileLayout ? 10 : 11,
      fontWeight: FontWeight.w800,
    );

    return Column(
      key: const ValueKey('lyrics-companion-timeline-block'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                formatDuration(clampedPosition),
                key: const ValueKey('lyrics-companion-position-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelStyle,
              ),
            ),
            Expanded(
              child: Text(
                formatDuration(timeline.duration),
                key: const ValueKey('lyrics-companion-duration-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: labelStyle,
              ),
            ),
          ],
        ),
        KeyedSubtree(
          key: const ValueKey('lyrics-companion-linear-timeline'),
          child: UniformPlaybackSeekBar(
            key: const ValueKey('lyrics-companion-timeline'),
            sliderKey: const ValueKey('lyrics-companion-linear-seek'),
            sliderThemeKey: const ValueKey('lyrics-companion-slider-theme'),
            position: clampedPosition,
            duration: timeline.duration,
            activeTrackColor: Colors.white.withValues(alpha: 0.88),
            inactiveTrackColor: Colors.white.withValues(alpha: 0.28),
            disabledActiveTrackColor: Colors.white.withValues(alpha: 0.30),
            disabledInactiveTrackColor: Colors.white.withValues(alpha: 0.18),
            semanticsLabel: strings.choose(
              'Barra de reproducción',
              'Playback timeline',
            ),
            onSeek: (position) => unawaited(
              ref.read(playerControllerProvider.notifier).seek(position),
            ),
          ),
        ),
      ],
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
      key: const ValueKey('lyrics-header'),
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
                    MarqueeText(
                      strings.lyrics,
                      key: const ValueKey('lyrics-header-title'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    MarqueeText(
                      currentLookup == null
                          ? strings.noPlayback
                          : '${currentLookup.title} - ${currentLookup.artist}',
                      key: const ValueKey('lyrics-header-track-title'),
                      pause: const Duration(milliseconds: 1700),
                      travel: const Duration(milliseconds: 6200),
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
  late int _activeIndex;
  final ScrollController _scrollController = ScrollController();
  ProviderSubscription<Duration>? _positionSubscription;
  Timer? _resumeAutoScrollTimer;
  bool _autoScrollSuspended = false;
  double? _activeScaledFontSize;
  double? _layoutWidth;
  double? _viewportHeight;
  List<double> _lineExtents = const [];
  List<double> _lineOffsets = const [0];
  double _linesStartOffset = 0;
  List<LyricLine>? _measuredLines;
  List<String>? _measuredRomanizedLines;
  double? _measuredContentWidth;
  double? _measuredActiveFontSize;
  TextScaler? _measuredTextScaler;
  TextDirection? _measuredTextDirection;
  Locale? _measuredLocale;

  @override
  void initState() {
    super.initState();
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
    final linesChanged = !identical(oldWidget.lines, widget.lines);
    if (linesChanged || oldWidget.offset != widget.offset) {
      _updateActiveLine(ref.read(currentPlaybackPositionProvider));
    }
    if (linesChanged ||
        !identical(oldWidget.romanizedLines, widget.romanizedLines)) {
      _invalidateLineMetrics();
      _scheduleAutoScroll();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextActiveScaledFontSize = MediaQuery.textScalerOf(
      context,
    ).scale(_lyricsTypographyFor(context).active);
    final previousActiveScaledFontSize = _activeScaledFontSize;
    _activeScaledFontSize = nextActiveScaledFontSize;
    if (previousActiveScaledFontSize != null &&
        previousActiveScaledFontSize != nextActiveScaledFontSize) {
      _scheduleAutoScroll();
    }
  }

  @override
  void dispose() {
    _positionSubscription?.close();
    _resumeAutoScrollTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _updateActiveLine(Duration position) {
    final next = _activeLineIndex(widget.lines, position + widget.offset);
    if (next == _activeIndex || !mounted) {
      return;
    }
    setState(() {
      _activeIndex = next;
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
      if (!_scrollController.hasClients ||
          targetIndex >= _lineExtents.length ||
          targetIndex >= _lineOffsets.length) {
        return;
      }
      final position = _scrollController.position;
      final lineExtent = _lineExtents[targetIndex];
      final target =
          (_linesStartOffset +
                  _lineOffsets[targetIndex] -
                  ((position.viewportDimension - lineExtent) * 0.43))
              .clamp(position.minScrollExtent, position.maxScrollExtent)
              .toDouble();
      final distance = (position.pixels - target).abs();
      if (distance < 0.5) {
        return;
      }
      if (MediaQuery.disableAnimationsOf(context)) {
        _scrollController.jumpTo(target);
        return;
      }
      final duration = Duration(
        milliseconds: (190 + (distance * 0.32)).round().clamp(220, 380).toInt(),
      );
      unawaited(
        _scrollController.animateTo(
          target,
          duration: duration,
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _syncLayoutMetrics({
    required double nextLayoutWidth,
    required double nextViewportHeight,
    required double linesStartOffset,
    required List<double> lineExtents,
    required List<double> lineOffsets,
    required bool metricsChanged,
  }) {
    final previousLayoutWidth = _layoutWidth;
    final previousViewportHeight = _viewportHeight;
    final previousLinesStartOffset = _linesStartOffset;
    _layoutWidth = nextLayoutWidth;
    _viewportHeight = nextViewportHeight;
    _linesStartOffset = linesStartOffset;
    _lineExtents = lineExtents;
    _lineOffsets = lineOffsets;
    if (previousLayoutWidth == null || previousViewportHeight == null) {
      return;
    }
    final geometryChanged =
        (previousLayoutWidth - nextLayoutWidth).abs() >= 0.5 ||
        (previousViewportHeight - nextViewportHeight).abs() >= 0.5 ||
        (previousLinesStartOffset - linesStartOffset).abs() >= 0.5;
    if (!metricsChanged && !geometryChanged) {
      return;
    }
    _resumeAutoScrollTimer?.cancel();
    _autoScrollSuspended = false;
    _scheduleAutoScroll();
  }

  void _invalidateLineMetrics() {
    _measuredLines = null;
    _measuredRomanizedLines = null;
    _measuredContentWidth = null;
    _measuredActiveFontSize = null;
    _measuredTextScaler = null;
    _measuredTextDirection = null;
    _measuredLocale = null;
  }

  bool _ensureLineMetrics({
    required double contentWidth,
    required double activeFontSize,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required Locale? locale,
  }) {
    final metricsAreCurrent =
        identical(_measuredLines, widget.lines) &&
        identical(_measuredRomanizedLines, widget.romanizedLines) &&
        _measuredContentWidth != null &&
        (_measuredContentWidth! - contentWidth).abs() < 0.5 &&
        _measuredActiveFontSize == activeFontSize &&
        _measuredTextScaler == textScaler &&
        _measuredTextDirection == textDirection &&
        _measuredLocale == locale;
    if (metricsAreCurrent) {
      return false;
    }

    final extents = <double>[
      for (var index = 0; index < widget.lines.length; index++)
        _measureLyricLineExtent(
          originalText: widget.lines[index].text,
          romanizedText:
              widget.romanizedLines != null &&
                  index < widget.romanizedLines!.length
              ? widget.romanizedLines![index]
              : null,
          contentWidth: contentWidth,
          activeFontSize: activeFontSize,
          textScaler: textScaler,
          textDirection: textDirection,
          locale: locale,
        ),
    ];
    final offsets = List<double>.filled(extents.length + 1, 0);
    for (var index = 0; index < extents.length; index++) {
      offsets[index + 1] = offsets[index] + extents[index];
    }

    _lineExtents = List<double>.unmodifiable(extents);
    _lineOffsets = List<double>.unmodifiable(offsets);
    _measuredLines = widget.lines;
    _measuredRomanizedLines = widget.romanizedLines;
    _measuredContentWidth = contentWidth;
    _measuredActiveFontSize = activeFontSize;
    _measuredTextScaler = textScaler;
    _measuredTextDirection = textDirection;
    _measuredLocale = locale;
    return true;
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
        AppPlatform.isMobileTargetPlatform(Theme.of(context).platform)
        ? 12.0
        : 24.0;
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.max(
          1.0,
          constraints.maxWidth - (horizontalPadding * 2),
        );
        final metricsChanged = _ensureLineMetrics(
          contentWidth: contentWidth,
          activeFontSize: typography.active,
          textScaler: textScaler,
          textDirection: textDirection,
          locale: locale,
        );
        final guidanceExtent = _measureSyncedLyricsGuidanceExtent(
          source: widget.sourceFooter,
          seekHint: strings.tapLyricsToSeek,
          contentWidth: contentWidth,
          textScaler: textScaler,
          textDirection: textDirection,
          locale: locale,
        );
        _syncLayoutMetrics(
          nextLayoutWidth: constraints.maxWidth,
          nextViewportHeight: constraints.maxHeight,
          linesStartOffset: verticalPadding + guidanceExtent + 12,
          lineExtents: _lineExtents,
          lineOffsets: _lineOffsets,
          metricsChanged: metricsChanged,
        );
        return NotificationListener<ScrollStartNotification>(
          onNotification: (notification) {
            if (notification.dragDetails != null) {
              _suspendAutoScroll();
            }
            return false;
          },
          child: CustomScrollView(
            key: const ValueKey('synced-lyrics-scroll'),
            controller: _scrollController,
            scrollCacheExtent: const ScrollCacheExtent.viewport(0.65),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  verticalPadding,
                  horizontalPadding,
                  0,
                ),
                sliver: SliverToBoxAdapter(
                  child: SizedBox(
                    height: guidanceExtent,
                    child: _SyncedLyricsGuidance(
                      source: widget.sourceFooter,
                      placement: 'top',
                      seekHint: strings.tapLyricsToSeek,
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                sliver: SliverVariedExtentList.builder(
                  key: const ValueKey('synced-lyrics-virtual-list'),
                  itemCount: widget.lines.length,
                  itemExtentBuilder: (index, _) => _lineExtents[index],
                  addAutomaticKeepAlives: false,
                  addRepaintBoundaries: true,
                  addSemanticIndexes: false,
                  itemBuilder: (context, index) => _LyricLineTile(
                    key: ValueKey('lyrics-line-tile-$index'),
                    contentKey: index == _activeIndex
                        ? const ValueKey('active-lyric-line')
                        : ValueKey('lyric-line-$index'),
                    originalText: widget.lines[index].text,
                    romanizedText:
                        widget.romanizedLines != null &&
                            index < widget.romanizedLines!.length
                        ? widget.romanizedLines![index]
                        : null,
                    romanizationKey: ValueKey(
                      'lyrics-line-romanization-$index',
                    ),
                    active: index == _activeIndex,
                    passed: index < _activeIndex,
                    lyricsCentered: widget.lyricsCentered,
                    animationStyle: widget.animationStyle,
                    activeFontSize: typography.active,
                    inactiveFontSize: typography.inactive,
                    onTap: () => _seekToLine(widget.lines[index]),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 20)),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  0,
                  horizontalPadding,
                  verticalPadding,
                ),
                sliver: SliverToBoxAdapter(
                  child: SizedBox(
                    height: guidanceExtent,
                    child: _SyncedLyricsGuidance(
                      source: widget.sourceFooter,
                      placement: 'bottom',
                      seekHint: strings.tapLyricsToSeek,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
    required this.originalText,
    required this.romanizedText,
    required this.romanizationKey,
    required this.active,
    required this.passed,
    required this.lyricsCentered,
    required this.animationStyle,
    required this.activeFontSize,
    required this.inactiveFontSize,
    required this.onTap,
    super.key,
  });

  final Key contentKey;
  final String originalText;
  final String? romanizedText;
  final Key romanizationKey;
  final bool active;
  final bool passed;
  final bool lyricsCentered;
  final LyricsAnimationStyle animationStyle;
  final double activeFontSize;
  final double inactiveFontSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.downloadAccentFor(context);
    final mobileLayout = _usesMobileLyricsLayout(context);
    final halo = _lyricsHaloFor(context, accent);
    final color = active
        ? mobileLayout
              ? Colors.white
              : Color.alphaBlend(accent.withValues(alpha: 0.08), Colors.white)
        : Colors.white.withValues(alpha: passed ? 0.62 : 0.38);
    final textStyle = TextStyle(
      color: color,
      fontSize: active ? activeFontSize : inactiveFontSize,
      height: 1.16,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.45,
      shadows: active
          ? [
              Shadow(
                color: halo.color.withValues(alpha: halo.innerAlpha),
                blurRadius: halo.innerBlur,
              ),
              Shadow(
                color: halo.color.withValues(alpha: halo.outerAlpha),
                blurRadius: halo.outerBlur,
              ),
              const Shadow(
                color: Color(0x7A000000),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ]
          : null,
    );
    final trimmedRomanization = _displayedRomanization(
      originalText,
      romanizedText,
    );
    final showRomanization = trimmedRomanization != null;
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

    return Semantics(
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
              color: isDark ? const Color(0x48000000) : const Color(0x20000000),
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
        AppPlatform.isMobileTargetPlatform(Theme.of(context).platform)
        ? 16.0
        : 28.0;
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
        height: 1.25,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _SyncedLyricsGuidance extends StatelessWidget {
  const _SyncedLyricsGuidance({
    required this.source,
    required this.placement,
    required this.seekHint,
  });

  final String source;
  final String placement;
  final String seekHint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LyricsSourceAttribution(source: source, placement: placement),
        const SizedBox(height: 6),
        Text(
          key: ValueKey('lyrics-seek-hint-$placement'),
          seekHint,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.52),
            fontSize: 12,
            height: 1.25,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
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

double _measureLyricLineExtent({
  required String originalText,
  required String? romanizedText,
  required double contentWidth,
  required double activeFontSize,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
}) {
  final textWidth = math.max(1.0, contentWidth - 16);
  final originalHeight = _measureTextHeight(
    text: originalText,
    style: TextStyle(
      fontSize: activeFontSize,
      height: 1.16,
      fontWeight: FontWeight.w900,
      letterSpacing: -0.45,
    ),
    maxWidth: textWidth,
    textScaler: textScaler,
    textDirection: textDirection,
    locale: locale,
  );
  final displayedRomanization = _displayedRomanization(
    originalText,
    romanizedText,
  );
  final romanizationHeight = displayedRomanization == null
      ? 0.0
      : 5 +
            _measureTextHeight(
              text: displayedRomanization,
              style: TextStyle(
                fontSize: (activeFontSize * 0.62).clamp(15.0, 22.0).toDouble(),
                height: 1.25,
                fontWeight: FontWeight.w700,
              ),
              maxWidth: textWidth,
              textScaler: textScaler,
              textDirection: textDirection,
              locale: locale,
            );
  // Every row reserves its active-state height. The text can animate without
  // moving every following lyric or invalidating the sliver's scroll geometry.
  return (24 + originalHeight + romanizationHeight).ceilToDouble();
}

double _measureSyncedLyricsGuidanceExtent({
  required String source,
  required String seekHint,
  required double contentWidth,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
}) {
  final sourceHeight = _measureTextHeight(
    text: source,
    style: const TextStyle(
      fontSize: 11,
      height: 1.25,
      fontWeight: FontWeight.w700,
    ),
    maxWidth: contentWidth,
    textScaler: textScaler,
    textDirection: textDirection,
    locale: locale,
  );
  final hintHeight = _measureTextHeight(
    text: seekHint,
    style: const TextStyle(
      fontSize: 12,
      height: 1.25,
      fontWeight: FontWeight.w700,
    ),
    maxWidth: contentWidth,
    textScaler: textScaler,
    textDirection: textDirection,
    locale: locale,
  );
  return (sourceHeight + 6 + hintHeight).ceilToDouble();
}

double _measureTextHeight({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: textDirection,
    textScaler: textScaler,
    locale: locale,
  )..layout(maxWidth: maxWidth);
  final height = painter.height;
  painter.dispose();
  return height;
}

String? _displayedRomanization(String originalText, String? romanizedText) {
  final trimmed = romanizedText?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed == originalText.trim()) {
    return null;
  }
  return trimmed;
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
