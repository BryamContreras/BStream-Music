enum PlayerStyle {
  bstreamMusic,
  appleMusic;

  String get code => switch (this) {
    PlayerStyle.bstreamMusic => 'bstreamMusic',
    PlayerStyle.appleMusic => 'appleMusic',
  };

  static PlayerStyle fromCode(String? code) {
    return switch (code) {
      'bstreamMusic' => PlayerStyle.bstreamMusic,
      'appleMusic' => PlayerStyle.appleMusic,
      _ => defaultPlayerStyle,
    };
  }
}

// Missing values belong to installations created before player styles were
// configurable, so they must retain BStream's original player.
const defaultPlayerStyle = PlayerStyle.bstreamMusic;
