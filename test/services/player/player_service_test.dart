import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PlayerSnapshot copyWith retains omitted nullable metadata', () {
    const snapshot = PlayerSnapshot(
      status: PlayerStatus.playing,
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      trackId: 'track-1',
      sourceUrl: 'https://example.test/source',
      thumbnailUrl: 'https://example.test/art.jpg',
      duration: Duration(minutes: 3),
      errorMessage: 'old error',
      isExternal: true,
    );

    final updated = snapshot.copyWith(status: PlayerStatus.paused);

    expect(updated.status, PlayerStatus.paused);
    expect(updated.title, snapshot.title);
    expect(updated.artist, snapshot.artist);
    expect(updated.album, snapshot.album);
    expect(updated.trackId, snapshot.trackId);
    expect(updated.sourceUrl, snapshot.sourceUrl);
    expect(updated.thumbnailUrl, snapshot.thumbnailUrl);
    expect(updated.duration, snapshot.duration);
    expect(updated.errorMessage, snapshot.errorMessage);
    expect(updated.isExternal, isTrue);
    expect(updated.copyWith(isExternal: false).isExternal, isFalse);
  });

  test('PlayerSnapshot copyWith can explicitly clear nullable metadata', () {
    const snapshot = PlayerSnapshot(
      status: PlayerStatus.playing,
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      trackId: 'track-1',
      sourceUrl: 'https://example.test/source',
      thumbnailUrl: 'https://example.test/art.jpg',
      duration: Duration(minutes: 3),
      errorMessage: 'old error',
    );

    final updated = snapshot.copyWith(
      title: null,
      artist: null,
      album: null,
      trackId: null,
      sourceUrl: null,
      thumbnailUrl: null,
      duration: null,
      errorMessage: null,
    );

    expect(updated.title, isNull);
    expect(updated.artist, isNull);
    expect(updated.album, isNull);
    expect(updated.trackId, isNull);
    expect(updated.sourceUrl, isNull);
    expect(updated.thumbnailUrl, isNull);
    expect(updated.duration, isNull);
    expect(updated.errorMessage, isNull);
  });
}
