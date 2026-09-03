import 'package:bstream_music/services/youtube_music/playback/innertube_video_id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const videoId = 'dQw4w9WgXcQ';

  group('InnerTubeVideoId', () {
    test('validates and preserves a bare ID', () {
      final parsed = InnerTubeVideoId('  $videoId  ');

      expect(parsed.value, videoId);
      expect(parsed.toString(), videoId);
      expect(parsed, InnerTubeVideoId.parse(videoId));
    });

    test('rejects malformed bare IDs', () {
      expect(InnerTubeVideoId.tryParse('too-short'), isNull);
      expect(
        () => InnerTubeVideoId.parse('not a valid id'),
        throwsFormatException,
      );
    });

    test('extracts IDs from supported YouTube URL shapes', () {
      final inputs = <String>[
        'https://www.youtube.com/watch?v=$videoId&t=10',
        'https://music.youtube.com/watch?v=$videoId',
        'https://youtu.be/$videoId?si=share',
        'youtube.com/shorts/$videoId',
        'https://m.youtube.com/live/$videoId',
        'https://www.youtube-nocookie.com/embed/$videoId',
        'https://youtube.com/v/$videoId',
        'https://www.youtube.com/attribution_link'
            '?u=%2Fwatch%3Fv%3D$videoId%26feature%3Dshare',
      ];

      for (final input in inputs) {
        expect(InnerTubeVideoId.extract(input)?.value, videoId, reason: input);
      }
    });

    test('rejects lookalike domains and unrelated query parameters', () {
      expect(
        InnerTubeVideoId.extract(
          'https://www.youtube.com.evil.test/watch?v=$videoId',
        ),
        isNull,
      );
      expect(
        InnerTubeVideoId.extract('https://example.test/?v=$videoId'),
        isNull,
      );
      expect(
        InnerTubeVideoId.extract(
          'https://www.youtube.com/watch?video=$videoId',
        ),
        isNull,
      );
    });
  });
}
