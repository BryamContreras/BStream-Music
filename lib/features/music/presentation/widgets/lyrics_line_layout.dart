import 'dart:math' as math;

import 'package:flutter/material.dart';

const lyricsLineHorizontalPadding = 8.0;
const lyricsLineVerticalPadding = 12.0;
const lyricsSecondaryLineGap = 4.0;

typedef LyricsTextAccessibilityOverrides = ({
  bool boldText,
  double? lineHeight,
  double? letterSpacing,
  double? wordSpacing,
});

const noLyricsTextAccessibilityOverrides = (
  boldText: false,
  lineHeight: null,
  letterSpacing: null,
  wordSpacing: null,
);

LyricsTextAccessibilityOverrides lyricsTextAccessibilityOverridesOf(
  BuildContext context,
) => (
  boldText: MediaQuery.boldTextOf(context),
  lineHeight: MediaQuery.maybeLineHeightScaleFactorOverrideOf(context),
  letterSpacing: MediaQuery.maybeLetterSpacingOverrideOf(context),
  wordSpacing: MediaQuery.maybeWordSpacingOverrideOf(context),
);

/// Text applies these overrides automatically; the measured paragraph and
/// cached RichText endpoint must use the same metrics. Setting them twice on a
/// Text is harmless because Flutter replaces, rather than multiplies, them.
TextStyle applyLyricsTextAccessibility(
  TextStyle style,
  LyricsTextAccessibilityOverrides overrides,
) => overrides == noLyricsTextAccessibilityOverrides
    ? style
    : style.copyWith(
        fontWeight: overrides.boldText ? FontWeight.bold : null,
        height: overrides.lineHeight,
        letterSpacing: overrides.letterSpacing,
        wordSpacing: overrides.wordSpacing,
      );

/// Resolve inherited font metrics once, before measuring or painting a line.
/// A standalone TextPainter and a Text that implicitly merges DefaultTextStyle
/// otherwise disagree about fallback fonts, word spacing and font variations.
TextStyle resolveLyricsOriginalStyle(
  TextStyle inheritedStyle, {
  required double fontSize,
}) => inheritedStyle
    .merge(
      TextStyle(
        fontSize: fontSize,
        height: 1.16,
        fontWeight: FontWeight.w900,
        letterSpacing: -0.45,
      ),
    )
    .copyWith(inherit: false);

TextStyle lyricsSecondaryStyleFor(
  TextStyle style, {
  required double fontSize,
}) => style.copyWith(
  inherit: false,
  fontSize: fontSize,
  height: 1.08,
  fontWeight: FontWeight.w500,
  letterSpacing: 0,
  shadows: const [],
);

double romanizedLyricsFontSize(double activeFontSize) =>
    (activeFontSize * 0.60).clamp(14.0, 20.0).toDouble();

typedef _LyricsParagraphHeightKey = ({
  String text,
  TextStyle style,
  double minWidth,
  double maxWidth,
  TextAlign textAlign,
  TextScaler textScaler,
  TextDirection textDirection,
  Locale? locale,
  TextHeightBehavior? textHeightBehavior,
  TextWidthBasis textWidthBasis,
});

/// Retains only measured heights, never paragraphs, painters or glyph images.
///
/// The same originals are measured again when a companion arrives or a line
/// returns to the viewport. Keep the complete shaping inputs in the key, and
/// bound both entry count and retained text so a long listening session cannot
/// accumulate whole documents. Font changes and memory pressure clear the cache.
class LyricsParagraphHeightCache with WidgetsBindingObserver {
  LyricsParagraphHeightCache({
    this.maximumEntries = 512,
    this.maximumTextCodeUnits = 128 * 1024,
  }) : assert(maximumEntries > 0),
       assert(maximumTextCodeUnits > 0) {
    WidgetsBinding.instance.addObserver(this);
    PaintingBinding.instance.systemFonts.addListener(clear);
  }

  final int maximumEntries;
  final int maximumTextCodeUnits;
  final _heights = <_LyricsParagraphHeightKey, double>{};
  int _retainedTextCodeUnits = 0;
  int _layoutCount = 0;

  @visibleForTesting
  int get debugLayoutCount => _layoutCount;

  @visibleForTesting
  int get debugEntryCount => _heights.length;

  @visibleForTesting
  int get debugRetainedTextCodeUnits => _retainedTextCodeUnits;

  double measure({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required TextScaler textScaler,
    required TextDirection textDirection,
    required Locale? locale,
    double minWidth = 0,
    TextAlign textAlign = TextAlign.start,
    TextHeightBehavior? textHeightBehavior,
    TextWidthBasis textWidthBasis = TextWidthBasis.parent,
  }) {
    final key = (
      text: text,
      style: style,
      minWidth: minWidth,
      maxWidth: maxWidth,
      textAlign: textAlign,
      textScaler: textScaler,
      textDirection: textDirection,
      locale: locale,
      textHeightBehavior: textHeightBehavior,
      textWidthBasis: textWidthBasis,
    );
    final cached = _heights.remove(key);
    if (cached != null) {
      _heights[key] = cached;
      return cached;
    }

    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: textAlign,
      textDirection: textDirection,
      textScaler: textScaler,
      locale: locale,
      textHeightBehavior: textHeightBehavior,
      textWidthBasis: textWidthBasis,
    );
    late final double height;
    try {
      painter.layout(minWidth: minWidth, maxWidth: maxWidth);
      height = painter.height;
      _layoutCount++;
    } finally {
      painter.dispose();
    }
    if (text.length <= maximumTextCodeUnits) {
      _heights[key] = height;
      _retainedTextCodeUnits += text.length;
      while (_heights.length > maximumEntries ||
          _retainedTextCodeUnits > maximumTextCodeUnits) {
        final oldest = _heights.keys.first;
        _heights.remove(oldest);
        _retainedTextCodeUnits -= oldest.text.length;
      }
    }
    return height;
  }

  void clear() {
    _heights.clear();
    _retainedTextCodeUnits = 0;
  }

  @override
  void didHaveMemoryPressure() => clear();

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PaintingBinding.instance.systemFonts.removeListener(clear);
    clear();
  }
}

final _lyricsParagraphHeights = LyricsParagraphHeightCache();

double measureLyricsParagraphHeight({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
  double minWidth = 0,
  TextAlign textAlign = TextAlign.start,
  TextHeightBehavior? textHeightBehavior,
  TextWidthBasis textWidthBasis = TextWidthBasis.parent,
}) => _lyricsParagraphHeights.measure(
  text: text,
  style: style,
  minWidth: minWidth,
  maxWidth: maxWidth,
  textAlign: textAlign,
  textScaler: textScaler,
  textDirection: textDirection,
  locale: locale,
  textHeightBehavior: textHeightBehavior,
  textWidthBasis: textWidthBasis,
);

/// The virtual list reserves the larger complete endpoint, including wrapped
/// companion text. It must not assume a smaller font always occupies less
/// height: different font weights/fallback runs can wrap differently.
double measureLyricsLineExtent({
  required String originalText,
  required String? secondaryText,
  required double contentWidth,
  required TextStyle activeStyle,
  required TextStyle inactiveStyle,
  required double secondaryFontSize,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required Locale? locale,
  TextHeightBehavior? textHeightBehavior,
  TextWidthBasis textWidthBasis = TextWidthBasis.parent,
  LyricsTextAccessibilityOverrides accessibility =
      noLyricsTextAccessibilityOverrides,
}) {
  final width = math.max(1.0, contentWidth - lyricsLineHorizontalPadding * 2);

  double paragraphHeight(String text, TextStyle style) =>
      measureLyricsParagraphHeight(
        text: text,
        style: applyLyricsTextAccessibility(style, accessibility),
        maxWidth: width,
        textDirection: textDirection,
        textScaler: textScaler,
        locale: locale,
        textHeightBehavior: textHeightBehavior,
        textWidthBasis: textWidthBasis,
      );

  final activeOriginalHeight = paragraphHeight(originalText, activeStyle);
  final inactiveOriginalHeight =
      activeStyle.compareTo(inactiveStyle) == RenderComparison.layout
      ? paragraphHeight(originalText, inactiveStyle)
      : activeOriginalHeight;
  var activePairHeight = activeOriginalHeight;
  var inactivePairHeight = inactiveOriginalHeight;
  if (secondaryText != null) {
    final activeSecondaryStyle = lyricsSecondaryStyleFor(
      activeStyle,
      fontSize: secondaryFontSize,
    );
    final inactiveSecondaryStyle = lyricsSecondaryStyleFor(
      inactiveStyle,
      fontSize: secondaryFontSize,
    );
    final activeSecondaryHeight = paragraphHeight(
      secondaryText,
      activeSecondaryStyle,
    );
    // Companion metrics normally match: only opacity/color differ. Do not
    // shape the same long translation twice merely to reserve its height.
    final inactiveSecondaryHeight =
        activeSecondaryStyle.compareTo(inactiveSecondaryStyle) ==
            RenderComparison.layout
        ? paragraphHeight(secondaryText, inactiveSecondaryStyle)
        : activeSecondaryHeight;
    activePairHeight += lyricsSecondaryLineGap + activeSecondaryHeight;
    inactivePairHeight += lyricsSecondaryLineGap + inactiveSecondaryHeight;
  }

  return (lyricsLineVerticalPadding * 2 +
          math.max(activePairHeight, inactivePairHeight))
      .ceilToDouble();
}
