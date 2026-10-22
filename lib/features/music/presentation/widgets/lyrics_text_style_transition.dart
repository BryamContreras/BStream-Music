import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'lyrics_glyph_snapshot.dart';
import 'lyrics_line_layout.dart';

/// Crossfades the two final lyric appearances without interpolating paragraph
/// metrics, glyph colors, or Gaussian text shadows on every display frame.
///
/// Both paragraphs keep their final layout. Their repaint boundaries retain
/// the glyph pictures while [FadeTransition] changes only layer opacity. This
/// is especially useful for a Japanese line followed by a long transliteration
/// or translation: shaping that pair should happen once, not 30 times per line.
class LyricsTextStyleTransition extends StatefulWidget {
  const LyricsTextStyleTransition({
    required this.active,
    required this.originalText,
    required this.secondaryText,
    required this.secondaryKey,
    required this.activeStyle,
    required this.inactiveStyle,
    required this.secondaryFontSize,
    required this.textAlign,
    required this.contentKey,
    super.key,
  });

  final bool active;
  final String originalText;
  final String? secondaryText;
  final Key secondaryKey;
  final TextStyle activeStyle;
  final TextStyle inactiveStyle;
  final double secondaryFontSize;
  final TextAlign textAlign;
  final Key contentKey;

  TextStyle get targetStyle => active ? activeStyle : inactiveStyle;

  TextStyle secondaryStyleFor(TextStyle style) =>
      lyricsSecondaryStyleFor(style, fontSize: secondaryFontSize);

  @override
  State<LyricsTextStyleTransition> createState() =>
      _LyricsTextStyleTransitionState();
}

class _LyricsTextStyleTransitionState extends State<LyricsTextStyleTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _activeOpacity;
  late final Animation<double> _inactiveOpacity;
  bool _disableAnimations = false;
  _LyricsOriginalParagraphMetrics? _originalMetrics;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
      value: widget.active ? 1 : 0,
    );
    _activeOpacity = _controller.drive(
      CurveTween(curve: Curves.easeInOutCubic),
    );
    _inactiveOpacity = _activeOpacity.drive(Tween(begin: 1.0, end: 0.0));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations == disabled) return;
    _disableAnimations = disabled;
    _controller.stop();
    _controller.value = widget.active ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant LyricsTextStyleTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active == widget.active) return;
    if (_disableAnimations) {
      _controller.stop();
      _controller.value = widget.active ? 1 : 0;
    } else {
      // A seek can retarget an unfinished transition. Keep its current opacity
      // so the pair does not flash or restart from an endpoint.
      _controller.animateTo(
        widget.active ? 1 : 0,
        duration: const Duration(milliseconds: 520),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  TextStyle _resolvedStyle(TextStyle style) => applyLyricsTextAccessibility(
    style.inherit ? DefaultTextStyle.of(context).style.merge(style) : style,
    lyricsTextAccessibilityOverridesOf(context),
  ).copyWith(inherit: false);

  Widget _paragraph(String text, TextStyle style, {required bool primary}) {
    final resolvedStyle = _resolvedStyle(style);
    final defaults = DefaultTextStyle.of(context);
    final heightBehavior =
        defaults.textHeightBehavior ??
        DefaultTextHeightBehavior.maybeOf(context);
    return primary
        ? Text(
            text,
            style: resolvedStyle,
            textAlign: widget.textAlign,
            textHeightBehavior: heightBehavior,
            textWidthBasis: defaults.textWidthBasis,
          )
        : RichText(
            text: TextSpan(text: text, style: resolvedStyle),
            textAlign: widget.textAlign,
            textScaler: MediaQuery.textScalerOf(context),
            textDirection: Directionality.of(context),
            locale: Localizations.maybeLocaleOf(context),
            textHeightBehavior: heightBehavior,
            textWidthBasis: defaults.textWidthBasis,
          );
  }

  Widget _pair(TextStyle style, {required bool primary}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      primary && !_disableAnimations
          ? _cachedActiveOriginal(style)
          : _paragraph(widget.originalText, style, primary: primary),
      if (widget.secondaryText case final secondary?) ...[
        const SizedBox(height: lyricsSecondaryLineGap),
        KeyedSubtree(
          key: primary ? widget.secondaryKey : null,
          child: primary && !_disableAnimations
              ? FadeTransition(
                  opacity: _activeOpacity,
                  child: _paragraph(
                    secondary,
                    widget.secondaryStyleFor(style),
                    primary: true,
                  ),
                )
              : _paragraph(
                  secondary,
                  widget.secondaryStyleFor(style),
                  primary: primary,
                ),
        ),
      ],
    ],
  );

  _LyricsOriginalParagraphMetrics _metricsFor(double width) {
    final defaults = DefaultTextStyle.of(context);
    final activeStyle = _resolvedStyle(widget.activeStyle);
    final inactiveStyle = _resolvedStyle(widget.inactiveStyle);
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final heightBehavior =
        defaults.textHeightBehavior ??
        DefaultTextHeightBehavior.maybeOf(context);
    final cached = _originalMetrics;
    if (cached != null &&
        cached.matches(
          text: widget.originalText,
          width: width,
          activeStyle: activeStyle,
          inactiveStyle: inactiveStyle,
          textScaler: textScaler,
          textDirection: textDirection,
          locale: locale,
          heightBehavior: heightBehavior,
          widthBasis: defaults.textWidthBasis,
          textAlign: widget.textAlign,
        )) {
      return cached;
    }
    return _originalMetrics = _LyricsOriginalParagraphMetrics.measure(
      text: widget.originalText,
      width: width,
      activeStyle: activeStyle,
      inactiveStyle: inactiveStyle,
      textScaler: textScaler,
      textDirection: textDirection,
      locale: locale,
      heightBehavior: heightBehavior,
      widthBasis: defaults.textWidthBasis,
      textAlign: widget.textAlign,
    );
  }

  Widget _cachedActiveOriginal(TextStyle style) => LayoutBuilder(
    builder: (context, constraints) {
      final paragraph = RepaintBoundary(
        child: _paragraph(widget.originalText, style, primary: true),
      );
      if (!constraints.hasBoundedWidth) {
        return FadeTransition(opacity: _activeOpacity, child: paragraph);
      }
      final metrics = _metricsFor(constraints.maxWidth);
      final resolvedStyle = _resolvedStyle(style);
      return AnimatedBuilder(
        animation: _controller,
        child: paragraph,
        builder: (context, child) => LyricsGlyphSnapshot(
          // Selection starts at alpha zero. Capture once immediately, retain
          // the bitmap through the entrance/exit, then release the inactive row.
          enabled: widget.active || _controller.value > 0,
          opacity: _activeOpacity,
          width: constraints.maxWidth,
          height: metrics.activeHeight,
          revision: (
            widget.originalText,
            resolvedStyle,
            metrics.textScaler,
            metrics.textDirection,
            metrics.locale,
            metrics.heightBehavior,
            metrics.widthBasis,
            widget.textAlign,
          ),
          child: child!,
        ),
      );
    },
  );

  /// Compatible companions have identical glyphs and differ only in alpha.
  /// Reuse one picture instead of compositing two long translations on every
  /// display frame. Other colors/paint styles retain the full endpoint fade.
  TextStyle? _sharedSecondaryStyle() {
    if (widget.secondaryText == null) return null;
    final active = _resolvedStyle(widget.secondaryStyleFor(widget.activeStyle));
    final inactive = _resolvedStyle(
      widget.secondaryStyleFor(widget.inactiveStyle),
    );
    final activeColor = active.color;
    final inactiveColor = inactive.color;
    if (activeColor == null ||
        inactiveColor == null ||
        active.foreground != null ||
        inactive.foreground != null) {
      return null;
    }
    final opaqueColor = activeColor.withValues(alpha: 1);
    if (opaqueColor != inactiveColor.withValues(alpha: 1)) return null;
    final opaqueActive = active.copyWith(color: opaqueColor);
    final opaqueInactive = inactive.copyWith(color: opaqueColor);
    return opaqueActive == opaqueInactive ? opaqueActive : null;
  }

  Widget _crossfadePairs() => Stack(
    fit: StackFit.loose,
    clipBehavior: Clip.none,
    children: [
      FadeTransition(
        opacity: _inactiveOpacity,
        child: RepaintBoundary(
          child: _pair(widget.inactiveStyle, primary: false),
        ),
      ),
      // Original opacity is painted inside its snapshot, allowing its initial
      // capture at alpha zero. The companion keeps its ordinary endpoint fade.
      RepaintBoundary(child: _pair(widget.activeStyle, primary: true)),
    ],
  );

  Widget _sharedCompanion(TextStyle secondaryStyle) => LayoutBuilder(
    builder: (context, constraints) {
      // Unbounded widths are not used by the lyrics list. Keep the general
      // fallback rather than guessing an unconstrained paragraph's geometry.
      if (!constraints.hasBoundedWidth) return _crossfadePairs();
      final activeStyle = _resolvedStyle(widget.activeStyle);
      final inactiveStyle = _resolvedStyle(widget.inactiveStyle);
      final metrics = _metricsFor(constraints.maxWidth);
      final originalHeight = math.max(
        metrics.activeHeight,
        metrics.inactiveHeight,
      );
      final activeSecondary = _resolvedStyle(
        widget.secondaryStyleFor(widget.activeStyle),
      );
      final inactiveSecondary = _resolvedStyle(
        widget.secondaryStyleFor(widget.inactiveStyle),
      );
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: originalHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: FadeTransition(
                    opacity: _inactiveOpacity,
                    child: RepaintBoundary(
                      child: _paragraph(
                        widget.originalText,
                        inactiveStyle,
                        primary: false,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _cachedActiveOriginal(activeStyle),
                ),
              ],
            ),
          ),
          const SizedBox(height: lyricsSecondaryLineGap),
          _SharedLyricsCompanionTransition(
            progress: _activeOpacity,
            activeAlpha: activeSecondary.color!.a,
            inactiveAlpha: inactiveSecondary.color!.a,
            activeOffset: metrics.activeHeight - originalHeight,
            inactiveOffset: metrics.inactiveHeight - originalHeight,
            child: RepaintBoundary(
              child: KeyedSubtree(
                key: widget.secondaryKey,
                child: _paragraph(
                  widget.secondaryText!,
                  secondaryStyle,
                  primary: true,
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final sharedSecondary = _disableAnimations ? null : _sharedSecondaryStyle();
    return Semantics(
      label: widget.secondaryText == null
          ? widget.originalText
          : '${widget.originalText}\n${widget.secondaryText}',
      selected: widget.active,
      child: ExcludeSemantics(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: lyricsLineHorizontalPadding,
                vertical: lyricsLineVerticalPadding,
              ),
              child: _disableAnimations
                  ? _pair(widget.targetStyle, primary: true)
                  : sharedSecondary == null
                  ? _crossfadePairs()
                  : _sharedCompanion(sharedSecondary),
            ),
            // The discoverable active-line marker must not own the glyph subtree.
            // Its key changes at every boundary; keying the Padding above disposed
            // both cached appearances exactly when the next animation began.
            Positioned.fill(
              child: IgnorePointer(child: SizedBox(key: widget.contentKey)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Moves the shared companion between the two original paragraph baselines.
/// Only composition changes; the long paragraph below remains a fixed picture.
class _SharedLyricsCompanionTransition extends AnimatedWidget {
  const _SharedLyricsCompanionTransition({
    required Animation<double> progress,
    required this.activeAlpha,
    required this.inactiveAlpha,
    required this.activeOffset,
    required this.inactiveOffset,
    required this.child,
  }) : super(listenable: progress);

  final double activeAlpha;
  final double inactiveAlpha;
  final double activeOffset;
  final double inactiveOffset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final progress = (listenable as Animation<double>).value;
    final foregroundAlpha = activeAlpha * progress;
    final backgroundAlpha = inactiveAlpha * (1 - progress);
    // Match the solid glyph interior of the previous source-over pair. A
    // linear alpha interpolation would make its mid-transition text brighter.
    final alpha = foregroundAlpha + backgroundAlpha * (1 - foregroundAlpha);
    return Opacity(
      opacity: alpha.clamp(0.0, 1.0).toDouble(),
      child: Transform.translate(
        offset: Offset(
          0,
          inactiveOffset + (activeOffset - inactiveOffset) * progress,
        ),
        child: child,
      ),
    );
  }
}

class _LyricsOriginalParagraphMetrics {
  _LyricsOriginalParagraphMetrics.measure({
    required this.text,
    required this.width,
    required this.activeStyle,
    required this.inactiveStyle,
    required this.textScaler,
    required this.textDirection,
    required this.locale,
    required this.heightBehavior,
    required this.widthBasis,
    required this.textAlign,
  }) {
    double height(TextStyle style) => measureLyricsParagraphHeight(
      text: text,
      style: style,
      minWidth: width,
      maxWidth: width,
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
      textHeightBehavior: heightBehavior,
      textWidthBasis: widthBasis,
    );

    activeHeight = height(activeStyle);
    inactiveHeight =
        activeStyle.compareTo(inactiveStyle) == RenderComparison.layout
        ? height(inactiveStyle)
        : activeHeight;
  }

  final String text;
  final double width;
  final TextStyle activeStyle;
  final TextStyle inactiveStyle;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final Locale? locale;
  final TextHeightBehavior? heightBehavior;
  final TextWidthBasis widthBasis;
  final TextAlign textAlign;
  late final double activeHeight;
  late final double inactiveHeight;

  bool matches({
    required String text,
    required double width,
    required TextStyle activeStyle,
    required TextStyle inactiveStyle,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required Locale? locale,
    required TextHeightBehavior? heightBehavior,
    required TextWidthBasis widthBasis,
    required TextAlign textAlign,
  }) =>
      this.text == text &&
      this.width == width &&
      this.activeStyle.compareTo(activeStyle) != RenderComparison.layout &&
      this.inactiveStyle.compareTo(inactiveStyle) != RenderComparison.layout &&
      this.textScaler == textScaler &&
      this.textDirection == textDirection &&
      this.locale == locale &&
      this.heightBehavior == heightBehavior &&
      this.widthBasis == widthBasis &&
      this.textAlign == textAlign;
}
