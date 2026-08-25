enum MiniPlayerBackgroundMode {
  accent,
  artwork,
  transparent;

  String get code => switch (this) {
    MiniPlayerBackgroundMode.accent => 'accent',
    MiniPlayerBackgroundMode.artwork => 'artwork',
    MiniPlayerBackgroundMode.transparent => 'transparent',
  };

  static MiniPlayerBackgroundMode fromCode(String? code) {
    return switch (code) {
      'accent' => MiniPlayerBackgroundMode.accent,
      'artwork' => MiniPlayerBackgroundMode.artwork,
      'transparent' => MiniPlayerBackgroundMode.transparent,
      _ => defaultMiniPlayerBackgroundMode,
    };
  }
}

const defaultMiniPlayerBackgroundMode = MiniPlayerBackgroundMode.accent;
