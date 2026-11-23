import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/animation/frame_rate_ticker_provider.dart';
import '../../domain/entities/lyric_word.dart';
import 'lyrics_glyph_snapshot.dart';
import 'lyrics_line_layout.dart';

/// A playback anchor in lyric time, including the user's lyric offset.
@immutable
class LyricsWordPlaybackSample {
  const LyricsWordPlaybackSample({
    required this.position,
    required this.sampledAt,
    required this.isPlaying,
  });

  final Duration position;
  final Duration sampledAt;
  final bool isPlaying;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LyricsWordPlaybackSample &&
          position == other.position &&
          sampledAt == other.sampledAt &&
          isPlaying == other.isPlaying;

  @override
  int get hashCode => Object.hash(position, sampledAt, isPlaying);
}

/// Paints word timing over two retained, fully shaped paragraphs.
///
/// The original paragraph supplies wrapping, ligatures and bidi order. Only a
/// clip changes as a word advances; playback never reshapes or relayouts text.
class LyricsWordTimingText extends StatefulWidget {
  const LyricsWordTimingText({
    required this.text,
    required this.words,
    required this.style,
    required this.textAlign,
    required this.active,
    required this.playback,
    required this.monotonicClock,
    super.key,
  });

  final String text;
  final List<LyricWord> words;
  final TextStyle style;
  final TextAlign textAlign;
  final bool active;
  final ValueListenable<LyricsWordPlaybackSample> playback;
  final Duration Function() monotonicClock;

  @override
  State<LyricsWordTimingText> createState() => _LyricsWordTimingTextState();
}

class _LyricsWordTimingTextState extends State<LyricsWordTimingText>
    with WidgetsBindingObserver {
  final _vsync = FrameRateTickerProvider(maxFramesPerSecond: 30);
  final _paintClock = _WordPaintClock();
  late final Ticker _ticker;
  Timer? _boundaryTimer;
  bool _tickerMode = true;
  bool _appActive = true;
  bool _reducedMotion = false;
  bool _validWords = false;
  _WordParagraph? _paragraph;
  Object? _paragraphKey;
  int _layoutCount = 0;

  @visibleForTesting
  int get debugParagraphLayoutCount => _layoutCount;

  @visibleForTesting
  bool get debugTickerActive => _ticker.isActive;

  bool get _visible => widget.active && _tickerMode && _appActive;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _validWords = _validateWords(widget.text, widget.words);
    _ticker = _vsync.createTicker(_tick);
    widget.playback.addListener(_synchronizeClock);
    _synchronizeClock();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode = TickerMode.valuesOf(context).enabled;
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _vsync.setDisplayRefreshRate(View.of(context).display.refreshRate);
    _synchronizeClock();
  }

  @override
  void didUpdateWidget(covariant LyricsWordTimingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playback != widget.playback) {
      oldWidget.playback.removeListener(_synchronizeClock);
      widget.playback.addListener(_synchronizeClock);
    }
    if (oldWidget.text != widget.text ||
        !listEquals(oldWidget.words, widget.words)) {
      _validWords = _validateWords(widget.text, widget.words);
      _invalidateParagraph();
    }
    _synchronizeClock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    _synchronizeClock();
  }

  Duration _positionNow() {
    final sample = widget.playback.value;
    final elapsed = widget.monotonicClock() - sample.sampledAt;
    return sample.isPlaying && !elapsed.isNegative
        ? sample.position + elapsed
        : sample.position;
  }

  void _tick(Duration _) {
    final position = _positionNow();
    _updatePaintPosition(position);
    if (!_hasSingingWord(position)) _synchronizeClock();
  }

  void _updatePaintPosition(Duration position) {
    final previous = _paintClock.position;
    if (!_visible || !_validWords || position == previous) return;
    final earlier = previous < position ? previous : position;
    final later = previous < position ? position : previous;
    // Native position samples also arrive between words. The existing clip
    // already represents this gap, so only invalidate when pixels can change.
    final changed = widget.words.any(
      (word) => _reducedMotion
          ? earlier < word.start && later >= word.start
          : earlier < word.end && later >= word.start,
    );
    if (changed) _paintClock.update(position);
  }

  bool _hasSingingWord(Duration position) =>
      widget.words.any((word) => word.start <= position && position < word.end);

  void _synchronizeClock() {
    _boundaryTimer?.cancel();
    _boundaryTimer = null;
    final position = _positionNow();
    _updatePaintPosition(position);
    _vsync.enabled = _visible;
    if (!_visible || !_validWords || !widget.playback.value.isPlaying) {
      _ticker.stop();
      return;
    }
    if (!_reducedMotion && _hasSingingWord(position)) {
      if (!_ticker.isActive) _ticker.start();
      return;
    }
    _ticker.stop();
    Duration? next;
    for (final word in widget.words) {
      if (word.start > position && (next == null || word.start < next)) {
        next = word.start;
      }
    }
    if (next != null) {
      _boundaryTimer = Timer(next - position, _synchronizeClock);
    }
  }

  void _invalidateParagraph() {
    _paragraph?.dispose();
    _paragraph = null;
    _paragraphKey = null;
  }

  void _fontsChanged() {
    _invalidateParagraph();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    widget.playback.removeListener(_synchronizeClock);
    _boundaryTimer?.cancel();
    _vsync.dispose();
    _paintClock.dispose();
    _invalidateParagraph();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final defaults = DefaultTextStyle.of(context);
    final snapshotPixelRatio =
        !kIsWeb && Theme.of(context).platform == TargetPlatform.android
        ? MediaQuery.devicePixelRatioOf(context)
        : null;
    final style = applyLyricsTextAccessibility(
      widget.style.inherit ? defaults.style.merge(widget.style) : widget.style,
      lyricsTextAccessibilityOverridesOf(context),
    ).copyWith(inherit: false);
    if (!_validWords) {
      return Text(widget.text, style: style, textAlign: widget.textAlign);
    }
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final heightBehavior =
        defaults.textHeightBehavior ??
        DefaultTextHeightBehavior.maybeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final key = (
          text: widget.text,
          style: style,
          width: width,
          align: widget.textAlign,
          scaler: scaler,
          direction: direction,
          locale: locale,
          heightBehavior: heightBehavior,
          widthBasis: defaults.textWidthBasis,
          snapshotPixelRatio: snapshotPixelRatio,
        );
        if (_paragraph == null || _paragraphKey != key) {
          _invalidateParagraph();
          _paragraphKey = key;
          _paragraph = _WordParagraph(
            text: widget.text,
            words: widget.words,
            style: style,
            width: width,
            align: widget.textAlign,
            scaler: scaler,
            direction: direction,
            locale: locale,
            heightBehavior: heightBehavior,
            widthBasis: defaults.textWidthBasis,
            snapshotPixelRatio: snapshotPixelRatio,
            onForegroundReady: _paintClock.invalidate,
          );
          _layoutCount++;
        }
        final paragraph = _paragraph!;
        return Semantics(
          label: widget.text,
          selected: widget.active,
          child: ExcludeSemantics(
            child: RepaintBoundary(
              child: SizedBox(
                width: width.isFinite ? width : paragraph.foreground.width,
                height: paragraph.foreground.height,
                child: CustomPaint(
                  key: const ValueKey('lyrics-word-timing-paint'),
                  painter: _WordTimingPainter(
                    paragraph: paragraph,
                    clock: _paintClock,
                    reducedMotion: _reducedMotion,
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

bool _validateWords(String text, List<LyricWord> words) {
  if (words.isEmpty) return false;
  var previousOffset = 0;
  Duration? previousStart;
  for (final word in words) {
    if (word.text.trim().isEmpty ||
        word.start.isNegative ||
        word.end <= word.start ||
        (previousStart != null && word.start < previousStart) ||
        word.startOffset < previousOffset ||
        word.endOffset <= word.startOffset ||
        word.endOffset > text.length ||
        text.substring(word.startOffset, word.endOffset) != word.text) {
      return false;
    }
    previousOffset = word.endOffset;
    previousStart = word.start;
  }
  return true;
}

class _WordPaintClock extends ChangeNotifier {
  Duration position = Duration.zero;

  void update(Duration value) {
    position = value;
    invalidate();
  }

  void invalidate() => notifyListeners();
}

class _WordParagraph {
  _WordParagraph({
    required String text,
    required List<LyricWord> words,
    required TextStyle style,
    required double width,
    required TextAlign align,
    required TextScaler scaler,
    required TextDirection direction,
    required Locale? locale,
    required TextHeightBehavior? heightBehavior,
    required TextWidthBasis widthBasis,
    required double? snapshotPixelRatio,
    required VoidCallback onForegroundReady,
  }) {
    TextPainter painter(TextStyle appearance) => TextPainter(
      text: TextSpan(text: text, style: appearance),
      textAlign: align,
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
      textHeightBehavior: heightBehavior,
      textWidthBasis: widthBasis,
    )..layout(minWidth: width.isFinite ? width : 0, maxWidth: width);
    foreground = painter(style);
    final color = style.color ?? Colors.white;
    background = painter(
      style.copyWith(
        color: color.withValues(alpha: color.a * 0.38),
        shadows: const [],
      ),
    );
    tokens = [
      for (final word in words)
        _WordBoxes(
          word,
          foreground.getBoxesForSelection(
            TextSelection(
              baseOffset: word.startOffset,
              extentOffset: word.endOffset,
            ),
          ),
        ),
    ];
    lastEnd = words.map((word) => word.end).reduce((a, b) => a > b ? a : b);
    if (snapshotPixelRatio != null && (style.shadows?.isNotEmpty ?? false)) {
      unawaited(_snapshotForeground(snapshotPixelRatio, onForegroundReady));
    }
  }

  late final TextPainter foreground;
  late final TextPainter background;
  late final List<_WordBoxes> tokens;
  late final Duration lastEnd;
  ui.Image? _foregroundImage;
  Rect? _foregroundBounds;
  bool _disposed = false;

  Future<void> _snapshotForeground(double ratio, VoidCallback onReady) async {
    const padding = LyricsGlyphSnapshot.overflowPadding;
    final width = ((foreground.width + padding * 2) * ratio).ceil();
    final height = ((foreground.height + padding * 2) * ratio).ceil();
    if (width > LyricsGlyphSnapshot.maximumSnapshotEdge ||
        height > LyricsGlyphSnapshot.maximumSnapshotEdge ||
        width * height > LyricsGlyphSnapshot.maximumSnapshotPixels) {
      return;
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(ratio);
    foreground.paint(canvas, const Offset(padding, padding));
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(width, height);
      if (_disposed) {
        image.dispose();
        return;
      }
      _foregroundBounds = Rect.fromLTWH(
        -padding,
        -padding,
        width / ratio,
        height / ratio,
      );
      _foregroundImage = image;
      onReady();
    } on Exception {
      // The live paragraph remains available if the renderer cannot retain it.
    } finally {
      picture.dispose();
    }
  }

  void paintForeground(Canvas canvas) {
    final image = _foregroundImage;
    if (image == null) {
      foreground.paint(canvas, Offset.zero);
      return;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      _foregroundBounds!,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  void dispose() {
    _disposed = true;
    _foregroundImage?.dispose();
    foreground.dispose();
    background.dispose();
  }
}

class _WordBoxes {
  _WordBoxes(this.word, this.boxes)
    : width = boxes.fold(0.0, (total, box) => total + box.right - box.left);

  final LyricWord word;
  final List<ui.TextBox> boxes;
  final double width;
}

class _WordTimingPainter extends CustomPainter {
  _WordTimingPainter({
    required this.paragraph,
    required this.clock,
    required this.reducedMotion,
  }) : super(repaint: clock);

  final _WordParagraph paragraph;
  final _WordPaintClock clock;
  final bool reducedMotion;

  @override
  void paint(Canvas canvas, Size size) {
    final position = clock.position;
    if (position >= paragraph.lastEnd) {
      paragraph.paintForeground(canvas);
      return;
    }
    paragraph.background.paint(canvas, Offset.zero);
    final firstStart = paragraph.tokens.first.word.start;
    if (reducedMotion ? position < firstStart : position <= firstStart) return;
    final clip = Path();
    for (final token in paragraph.tokens) {
      final word = token.word;
      if (position < word.start) break;
      final progress = reducedMotion || position >= word.end
          ? 1.0
          : (position - word.start).inMicroseconds /
                (word.end - word.start).inMicroseconds;
      var remaining = token.width * progress;
      for (final box in token.boxes) {
        final rect = box.toRect();
        final paintedWidth = math.min(remaining, rect.width);
        if (paintedWidth > 0) {
          clip.addRect(
            box.direction == TextDirection.rtl
                ? Rect.fromLTRB(
                    rect.right - paintedWidth,
                    rect.top,
                    rect.right,
                    rect.bottom,
                  )
                : Rect.fromLTWH(rect.left, rect.top, paintedWidth, rect.height),
          );
        }
        remaining -= paintedWidth;
        if (remaining <= 0) break;
      }
    }
    canvas.save();
    canvas.clipPath(clip);
    paragraph.paintForeground(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WordTimingPainter oldDelegate) =>
      paragraph != oldDelegate.paragraph ||
      clock != oldDelegate.clock ||
      reducedMotion != oldDelegate.reducedMotion;
}
