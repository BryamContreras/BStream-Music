enum PlayerStyle {
  bstreamMusic,
  appleMusic,
  classicVinyl;

  String get code => switch (this) {
    PlayerStyle.bstreamMusic => 'bstreamMusic',
    PlayerStyle.appleMusic => 'appleMusic',
    PlayerStyle.classicVinyl => 'classicVinyl',
  };

  static PlayerStyle fromCode(String? code) {
    return switch (code) {
      'bstreamMusic' => PlayerStyle.bstreamMusic,
      'appleMusic' => PlayerStyle.appleMusic,
      'classicVinyl' => PlayerStyle.classicVinyl,
      _ => defaultPlayerStyle,
    };
  }
}

// Missing values belong to installations created before player styles were
// configurable, so they must retain BStream's original player.
const defaultPlayerStyle = PlayerStyle.bstreamMusic;
