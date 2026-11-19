enum LyricsBackgroundStyle {
  blur,
  gradient,
  animatedGradient;

  String get code => name;

  static LyricsBackgroundStyle fromCode(String? code) => switch (code) {
    'blur' => LyricsBackgroundStyle.blur,
    'gradient' => LyricsBackgroundStyle.gradient,
    'animatedGradient' => LyricsBackgroundStyle.animatedGradient,
    _ => defaultLyricsBackgroundStyle,
  };
}

const defaultLyricsBackgroundStyle = LyricsBackgroundStyle.animatedGradient;
