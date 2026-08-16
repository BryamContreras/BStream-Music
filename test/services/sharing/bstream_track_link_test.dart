import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/sharing/bstream_track_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = BStreamTrackLinkCodec();
  const videoId = 'dQw4w9WgXcQ';

  TrackInfo track({required String id, required String url}) {
    return TrackInfo(
      id: id,
      title: 'Never Gonna Give You Up',
      artist: 'Rick Astley',
      url: url,
    );
  }

  group('BStreamTrackLink', () {
    test('builds metadata-free app URI and canonical YouTube fallback', () {
      const link = BStreamTrackLink(videoId: videoId);

      expect(link.appUri.toString(), 'bstreammusic://track/$videoId');
      expect(
        link.youtubeFallbackUri.toString(),
        'https://www.youtube.com/watch?v=$videoId',
      );
      expect(link.appUri.hasQuery, isFalse);
      expect(link.appUri.hasFragment, isFalse);
    });
  });

  group('BStreamTrackLinkCodec.decode', () {
    test('decodes the canonical custom-scheme URI', () {
      final link = codec.decode(Uri.parse('bstreammusic://track/$videoId'));

      expect(link.videoId, videoId);
    });

    test('treats URI scheme and host case-insensitively', () {
      final link = codec.decode(Uri.parse('BSTREAMMUSIC://TRACK/$videoId'));

      expect(link.videoId, videoId);
    });

    for (final invalidUri in <String>[
      'https://track/$videoId',
      'bstreammusic://album/$videoId',
      'bstreammusic://track/too-short',
      'bstreammusic://track/$videoId/extra',
      'bstreammusic://track/$videoId?title=Injected',
      'bstreammusic://track/$videoId#fragment',
      'bstreammusic://user@track/$videoId',
      'bstreammusic://track:1234/$videoId',
      'bstreammusic://track/',
    ]) {
      test('rejects non-canonical URI: $invalidUri', () {
        final uri = Uri.parse(invalidUri);

        expect(codec.tryDecode(uri), isNull);
        expect(() => codec.decode(uri), throwsFormatException);
      });
    }
  });

  group('BStreamTrackLinkCodec.tryFromTrack', () {
    final acceptedUrls = <String>[
      'https://www.youtube.com/watch?v=$videoId',
      'https://youtube.com/watch?feature=share&v=$videoId',
      'https://music.youtube.com/watch?v=$videoId&list=RDAMVM',
      'https://m.youtube.com/watch?v=$videoId',
      'https://youtu.be/$videoId?t=42',
      'https://www.youtube.com/shorts/$videoId',
      'https://www.youtube.com/embed/$videoId?autoplay=1',
      'https://www.youtube.com/live/$videoId?si=abc',
    ];

    for (final url in acceptedUrls) {
      test('extracts the video ID from $url', () {
        final link = codec.tryFromTrack(track(id: 'invalid', url: url));

        expect(link?.videoId, videoId);
      });
    }

    test('uses the catalog URL before a different valid track id', () {
      const urlVideoId = 'M7lc1UVf-VE';
      final link = codec.fromTrack(
        track(
          id: videoId,
          url: 'https://music.youtube.com/watch?v=$urlVideoId',
        ),
      );

      expect(link.videoId, urlVideoId);
    });

    test('falls back to the track id when its URL is not recognized', () {
      final link = codec.fromTrack(
        track(id: videoId, url: 'https://example.com/audio'),
      );

      expect(link.videoId, videoId);
    });

    for (final rejectedUrl in <String>[
      'https://rr1---sn.example.googlevideo.com/videoplayback?id=$videoId',
      'file:///storage/emulated/0/Music/song.mp3',
      'https://example.com/watch?v=$videoId',
      'https://youtube.com.evil.example/watch?v=$videoId',
      'https://www.youtube.com/playlist?list=$videoId',
      'not a URL',
    ]) {
      test('rejects a non-YouTube source: $rejectedUrl', () {
        final candidate = track(id: 'also-invalid', url: rejectedUrl);

        expect(codec.tryFromTrack(candidate), isNull);
        expect(() => codec.fromTrack(candidate), throwsFormatException);
      });
    }

    test('rejects video IDs that do not have exactly 11 valid characters', () {
      final candidates = <String>[
        'short',
        'dQw4w9WgXcQx',
        'dQw4w9WgXc!',
        'dQw4w9WgXc ',
      ];

      for (final candidate in candidates) {
        expect(
          codec.tryFromTrack(
            track(id: candidate, url: 'https://example.com/audio'),
          ),
          isNull,
          reason: candidate,
        );
      }
    });
  });
}
