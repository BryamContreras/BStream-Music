enum MiniPlayerBackgroundMode {
  accent,
  artwork,
  transparent,
  liquidGlass;

  String get code => switch (this) {
    MiniPlayerBackgroundMode.accent => 'accent',
    MiniPlayerBackgroundMode.artwork => 'artwork',
    MiniPlayerBackgroundMode.transparent => 'transparent',
    MiniPlayerBackgroundMode.liquidGlass => 'liquidGlass',
  };

  bool get usesBackdrop => switch (this) {
    MiniPlayerBackgroundMode.accent ||
    MiniPlayerBackgroundMode.artwork => false,
    MiniPlayerBackgroundMode.transparent ||
    MiniPlayerBackgroundMode.liquidGlass => true,
  };

  bool get isLiquidGlass => this == MiniPlayerBackgroundMode.liquidGlass;

  static MiniPlayerBackgroundMode fromCode(String? code) {
    return switch (code) {
      'accent' => MiniPlayerBackgroundMode.accent,
      'artwork' => MiniPlayerBackgroundMode.artwork,
      'transparent' => MiniPlayerBackgroundMode.transparent,
      'liquidGlass' => MiniPlayerBackgroundMode.liquidGlass,
      _ => defaultMiniPlayerBackgroundMode,
    };
  }
}

const defaultMiniPlayerBackgroundMode = MiniPlayerBackgroundMode.accent;
