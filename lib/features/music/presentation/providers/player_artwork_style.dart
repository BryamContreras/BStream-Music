enum PlayerArtworkStyle {
  classic,
  expanded;

  String get code => switch (this) {
    PlayerArtworkStyle.classic => 'classic',
    PlayerArtworkStyle.expanded => 'expanded',
  };

  static PlayerArtworkStyle fromCode(String? code) {
    return switch (code) {
      'classic' => PlayerArtworkStyle.classic,
      'expanded' => PlayerArtworkStyle.expanded,
      _ => defaultPlayerArtworkStyle,
    };
  }
}

// Installations created before artwork styles were configurable must retain
// the original square-cover presentation.
const defaultPlayerArtworkStyle = PlayerArtworkStyle.classic;
