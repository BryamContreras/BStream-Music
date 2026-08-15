enum LyricsAnimationStyle {
  smooth,
  slide,
  highlight,
  none;

  String get code => name;

  static LyricsAnimationStyle fromCode(String? code) {
    return switch (code) {
      'slide' => LyricsAnimationStyle.slide,
      'highlight' => LyricsAnimationStyle.highlight,
      'none' => LyricsAnimationStyle.none,
      _ => LyricsAnimationStyle.smooth,
    };
  }
}
