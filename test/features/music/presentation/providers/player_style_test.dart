import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('player style codes are stable and decode defensively', () {
    expect(PlayerStyle.bstreamMusic.code, 'bstreamMusic');
    expect(PlayerStyle.appleMusic.code, 'appleMusic');
    expect(PlayerStyle.fromCode('bstreamMusic'), PlayerStyle.bstreamMusic);
    expect(PlayerStyle.fromCode('appleMusic'), PlayerStyle.appleMusic);
    expect(PlayerStyle.fromCode(null), defaultPlayerStyle);
    expect(PlayerStyle.fromCode('futureStyle'), defaultPlayerStyle);
    expect(defaultPlayerStyle, PlayerStyle.bstreamMusic);
  });
}
