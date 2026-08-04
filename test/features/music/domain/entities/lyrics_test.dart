import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LyricsLookup uses every lookup field for value equality', () {
    const first = LyricsLookup(
      title: 'Song',
      artist: 'Artist',
      duration: Duration(minutes: 3),
      album: 'Album',
      sourceId: 'source-1',
    );
    const same = LyricsLookup(
      title: 'Song',
      artist: 'Artist',
      duration: Duration(minutes: 3),
      album: 'Album',
      sourceId: 'source-1',
    );
    const differentDuration = LyricsLookup(
      title: 'Song',
      artist: 'Artist',
      duration: Duration(minutes: 4),
      album: 'Album',
      sourceId: 'source-1',
    );
    const differentSourceId = LyricsLookup(
      title: 'Song',
      artist: 'Artist',
      duration: Duration(minutes: 3),
      album: 'Album',
      sourceId: 'source-2',
    );

    expect(first, same);
    expect(first.hashCode, same.hashCode);
    expect(first, isNot(differentDuration));
    expect(first, isNot(differentSourceId));
    expect(first.isValid, isTrue);
    expect(const LyricsLookup(title: ' ', artist: 'Artist').isValid, isFalse);
    expect(const LyricsLookup(title: 'Song', artist: '').isValid, isTrue);
  });

  test('LyricsDocument reports synchronized and plain content', () {
    const synchronized = LyricsDocument(
      provider: 'test',
      trackName: 'Song',
      artistName: 'Artist',
      plainLyrics: 'Plain lyrics',
      syncedLyrics: '[00:01.00]Line',
      lines: [LyricLine(timestamp: Duration(seconds: 1), text: 'Line')],
    );
    const instrumental = LyricsDocument(
      provider: 'test',
      trackName: 'Song',
      artistName: 'Artist',
      instrumental: true,
    );

    expect(synchronized.hasSyncedLyrics, isTrue);
    expect(synchronized.hasPlainLyrics, isTrue);
    expect(synchronized.hasContent, isTrue);
    expect(instrumental.hasSyncedLyrics, isFalse);
    expect(instrumental.hasContent, isTrue);
  });
}
