import 'package:bstream_music/features/music/data/parsers/lrc_parser.dart';
import 'package:bstream_music/features/music/domain/entities/lyric_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = LrcParser();

  test('returns an empty immutable list for missing lyrics', () {
    expect(parser.parse(null), isEmpty);
    expect(parser.parse('   '), isEmpty);
  });

  test('parses tenths, centiseconds, milliseconds, and comma fractions', () {
    final lines = parser.parse('''
[00:01.2]Tenth
[00:02.34]Centiseconds
[00:03.456]Milliseconds
[00:04,78]Comma
''');

    expect(lines, [
      const LyricLine(timestamp: Duration(milliseconds: 1200), text: 'Tenth'),
      const LyricLine(
        timestamp: Duration(milliseconds: 2340),
        text: 'Centiseconds',
      ),
      const LyricLine(
        timestamp: Duration(milliseconds: 3456),
        text: 'Milliseconds',
      ),
      const LyricLine(timestamp: Duration(milliseconds: 4780), text: 'Comma'),
    ]);
  });

  test('expands multiple timestamps and sorts them stably', () {
    final lines = parser.parse('''
[00:10.00][00:05.00]Chorus
[00:05.00]Earlier duplicate
[00:03.00]Verse
''');

    expect(lines.map((line) => line.text), [
      'Verse',
      'Chorus',
      'Earlier duplicate',
      'Chorus',
    ]);
    expect(lines.map((line) => line.timestamp.inSeconds), [3, 5, 5, 10]);
  });

  test('applies a global positive offset even when its tag comes last', () {
    final lines = parser.parse('''
[00:01.00]First
[00:02.50]Second
[offset:+250]
''');

    expect(lines[0].timestamp, const Duration(milliseconds: 1250));
    expect(lines[1].timestamp, const Duration(milliseconds: 2750));
  });

  test('applies a negative offset and clamps timestamps to zero', () {
    final lines = parser.parse('''
[offset:-1500]
[00:01.00]First
[00:02.00]Second
''');

    expect(lines[0].timestamp, Duration.zero);
    expect(lines[1].timestamp, const Duration(milliseconds: 500));
  });

  test('supports hour timestamps and ignores metadata tags', () {
    final lines = parser.parse('''
\uFEFF[ar:Artist]
[ti:Title]
[01:02:03.004]Long song
''');

    expect(lines, [
      const LyricLine(
        timestamp: Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 4),
        text: 'Long song',
      ),
    ]);
  });

  test('keeps empty timed lines and brackets that belong to lyric text', () {
    final lines = parser.parse('''
[00:01.00]
[00:02.00]Keep [this] text
''');

    expect(lines[0].text, isEmpty);
    expect(lines[1].text, 'Keep [this] text');
  });

  test('ignores malformed and out-of-range timestamps', () {
    final lines = parser.parse('''
[not-a-time]Metadata
[00:60.00]Invalid seconds
[01:02.1234]Too precise
[00:04.00]Valid
''');

    expect(lines, [
      const LyricLine(timestamp: Duration(seconds: 4), text: 'Valid'),
    ]);
  });
}
