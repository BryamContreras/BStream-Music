import 'package:flutter/material.dart';

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

  TextStyle secondaryStyleFor(TextStyle style) => style.copyWith(
    inherit: false,
    fontSize: secondaryFontSize,
    height: 1.08,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    shadows: const [],
  );

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

  Widget _paragraph(String text, TextStyle style, {required bool primary}) =>
      primary
      ? Text(text, style: style, textAlign: widget.textAlign)
      : RichText(
          text: TextSpan(text: text, style: style),
          textAlign: widget.textAlign,
          textScaler: MediaQuery.textScalerOf(context),
          textDirection: Directionality.of(context),
          locale: Localizations.maybeLocaleOf(context),
        );

  Widget _pair(TextStyle style, {required bool primary}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      _paragraph(widget.originalText, style, primary: primary),
      if (widget.secondaryText case final secondary?) ...[
        const SizedBox(height: 4),
        KeyedSubtree(
          key: primary ? widget.secondaryKey : null,
          child: _paragraph(
            secondary,
            widget.secondaryStyleFor(style),
            primary: primary,
          ),
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: widget.contentKey,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      child: _disableAnimations
          ? _pair(widget.targetStyle, primary: true)
          : Stack(
              fit: StackFit.loose,
              clipBehavior: Clip.none,
              children: [
                FadeTransition(
                  opacity: _inactiveOpacity,
                  alwaysIncludeSemantics: !widget.active,
                  child: IgnorePointer(
                    ignoring: widget.active,
                    child: ExcludeSemantics(
                      excluding: widget.active,
                      child: RepaintBoundary(
                        child: _pair(
                          widget.inactiveStyle,
                          primary: !widget.active,
                        ),
                      ),
                    ),
                  ),
                ),
                FadeTransition(
                  opacity: _activeOpacity,
                  alwaysIncludeSemantics: widget.active,
                  child: IgnorePointer(
                    ignoring: !widget.active,
                    child: ExcludeSemantics(
                      excluding: !widget.active,
                      child: RepaintBoundary(
                        child: _pair(
                          widget.activeStyle,
                          primary: widget.active,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
