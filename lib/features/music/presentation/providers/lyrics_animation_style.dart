enum LyricsAnimationStyle {
  smooth,
  slide,
  highlight;

  String get code => name;

  static LyricsAnimationStyle fromCode(String? code) {
    return switch (code) {
      'slide' => LyricsAnimationStyle.slide,
      'highlight' => LyricsAnimationStyle.highlight,
      _ => LyricsAnimationStyle.smooth,
    };
  }
}
