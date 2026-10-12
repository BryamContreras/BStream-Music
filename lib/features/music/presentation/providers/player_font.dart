enum PlayerFont {
  current,
  nunito,
  lora,
  spaceMono,
  fredoka;

  String get code => switch (this) {
    PlayerFont.current => 'current',
    PlayerFont.nunito => 'nunito',
    PlayerFont.lora => 'lora',
    PlayerFont.spaceMono => 'spaceMono',
    PlayerFont.fredoka => 'fredoka',
  };

  String? get fontFamily => switch (this) {
    PlayerFont.current => null,
    PlayerFont.nunito => 'Nunito',
    PlayerFont.lora => 'Lora',
    PlayerFont.spaceMono => 'Space Mono',
    PlayerFont.fredoka => 'Fredoka',
  };

  static PlayerFont fromCode(String? code) => switch (code) {
    'nunito' => PlayerFont.nunito,
    'lora' => PlayerFont.lora,
    'spaceMono' => PlayerFont.spaceMono,
    // Keep existing installations on the replacement font they selected.
    'mochiyPopOne' || 'fredoka' => PlayerFont.fredoka,
    _ => defaultPlayerFont,
  };
}

// Existing installations keep their platform's current typography.
const defaultPlayerFont = PlayerFont.current;
