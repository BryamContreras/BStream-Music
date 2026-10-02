import 'package:bstream_music/services/visual_track_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves artist names that start with a collaboration word', () {
    expect(primaryVisualArtist('X Ambassadors'), 'X Ambassadors');
    expect(primaryVisualArtist('Featuring Friends'), 'Featuring Friends');
    expect(sameVisualArtist('X Ambassadors', 'X Ambassadors'), isTrue);
  });

  test('separates only genuine artist collaborations', () {
    expect(primaryVisualArtist('Artist x Other'), 'Artist');
    expect(primaryVisualArtist('Artist feat. Other'), 'Artist');
    expect(primaryVisualArtist('Artist ft Other'), 'Artist');
    expect(primaryVisualArtist('Artist, Other'), 'Artist');
    expect(primaryVisualArtist('Artist & Other'), 'Artist');
    expect(primaryVisualArtist('Artist; Other'), 'Artist');
    expect(primaryVisualArtist('X Ambassadors x Other'), 'X Ambassadors');
  });

  test('folds UTF-8 accents while retaining version distinctions', () {
    expect(normalVisualText('Mañana · Beyoncé'), 'manana beyonce');
    expect(
      sameVisualTitle('Por si mañana no estoy', 'POR SI MANANA NO ESTOY'),
      isTrue,
    );
    expect(sameVisualArtist('Beyoncé', 'Beyonce'), isTrue);
    expect(sameVisualTitle('Higher Power', 'Higher Power (Live)'), isFalse);
    expect(sameVisualTitle('Higher Power', 'Higher Power (Remix)'), isFalse);
  });
}
