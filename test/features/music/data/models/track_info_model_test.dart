import 'package:bstream_music/features/music/data/models/track_info_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps search result webpage URLs out of streamUrl', () {
    final track = TrackInfoModel.fromJson({
      'id': 'abc123',
      'title': 'Example Song',
      'uploader': 'Example Artist',
      'url': 'https://www.youtube.com/watch?v=abc123',
      'webpage_url': 'https://www.youtube.com/watch?v=abc123',
      'thumbnails': [
        {
          'url': 'https://i.ytimg.com/vi/abc123/hqdefault.jpg',
          'width': 480,
          'height': 360,
        },
      ],
    });

    expect(track.url, 'https://www.youtube.com/watch?v=abc123');
    expect(track.streamUrl, isNull);
    expect(track.thumbnailUrl, 'https://i.ytimg.com/vi/abc123/hqdefault.jpg');
  });

  test('uses direct audio URLs from getInfo as streamUrl', () {
    final track = TrackInfoModel.fromJson({
      'id': 'abc123',
      'title': 'Example Song',
      'uploader': 'Example Artist',
      'webpage_url': 'https://www.youtube.com/watch?v=abc123',
      'url': 'https://rr1---sn.googlevideo.com/videoplayback?id=abc123',
      'http_headers': {'User-Agent': 'test-agent'},
    });

    expect(
      track.streamUrl,
      'https://rr1---sn.googlevideo.com/videoplayback?id=abc123',
    );
    expect(track.httpHeaders, {'User-Agent': 'test-agent'});
  });

  test('prefers m4a audio streams over webm when both are available', () {
    final track = TrackInfoModel.fromJson({
      'id': 'abc123',
      'title': 'Example Song',
      'uploader': 'Example Artist',
      'webpage_url': 'https://www.youtube.com/watch?v=abc123',
      'formats': [
        {
          'url': 'https://example.com/audio.webm',
          'ext': 'webm',
          'vcodec': 'none',
          'acodec': 'opus',
          'abr': 160,
        },
        {
          'url': 'https://example.com/audio.m4a',
          'ext': 'm4a',
          'vcodec': 'none',
          'acodec': 'mp4a.40.2',
          'abr': 128,
        },
      ],
    });

    expect(track.streamUrl, 'https://example.com/audio.m4a');
  });

  test('prefers the lowest bitrate within the same compatible format', () {
    final track = TrackInfoModel.fromJson({
      'id': 'abc123',
      'title': 'Example Song',
      'uploader': 'Example Artist',
      'webpage_url': 'https://www.youtube.com/watch?v=abc123',
      'formats': [
        {
          'url': 'https://example.com/audio-128.m4a',
          'ext': 'm4a',
          'vcodec': 'none',
          'acodec': 'mp4a.40.2',
          'abr': 128,
        },
        {
          'url': 'https://example.com/audio-48.m4a',
          'ext': 'm4a',
          'vcodec': 'none',
          'acodec': 'mp4a.40.2',
          'abr': 48,
        },
      ],
    });

    expect(track.streamUrl, 'https://example.com/audio-48.m4a');
  });
}
