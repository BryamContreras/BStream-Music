import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('player artwork style codes are stable and decode defensively', () {
    expect(PlayerArtworkStyle.classic.code, 'classic');
    expect(PlayerArtworkStyle.expanded.code, 'expanded');
    expect(PlayerArtworkStyle.fromCode('classic'), PlayerArtworkStyle.classic);
    expect(
      PlayerArtworkStyle.fromCode('expanded'),
      PlayerArtworkStyle.expanded,
    );
    expect(PlayerArtworkStyle.fromCode(null), defaultPlayerArtworkStyle);
    expect(
      PlayerArtworkStyle.fromCode('futureStyle'),
      defaultPlayerArtworkStyle,
    );
    expect(defaultPlayerArtworkStyle, PlayerArtworkStyle.classic);
  });
}
