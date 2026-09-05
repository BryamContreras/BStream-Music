import 'package:bstream_music/features/music/data/models/track_info_model.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers semantic music metadata over a decorated video title', () {
    final track = TrackInfoModel.fromJson({
      'id': 'abc123',
      'title': 'ARTIST ❌ SONG 🤫 (OFFICIAL VIDEO)',
      'track': 'Song',
      'artist': 'Artist',
      'uploader': 'OfficialChannelVEVO',
      'url': 'https://www.youtube.com/watch?v=abc123',
    });

    expect(track.title, 'Song');
    expect(track.artist, 'Artist');
  });

  test('uses structured artist lists before falling back to the channel', () {
    final track = TrackInfoModel.fromJson({
      'id': 'abc123',
      'title': 'Collaboration',
      'artists': ['First Artist', 'Second Artist'],
      'uploader': 'MusicUploads',
      'url': 'https://www.youtube.com/watch?v=abc123',
    });

    expect(track.artist, 'First Artist, Second Artist');
  });

  test('round-trips canonical YouTube Music metadata and artist order', () {
    final encoded = TrackInfoModel(
      id: 'DlFXDl_ROAM',
      title: 'Die With A Smile',
      artist: 'stale scalar value',
      artists: const ['Lady Gaga', 'Bruno Mars'],
      artistBrowseIds: const ['UC-LadyGaga', null],
      album: 'MAYHEM',
      albumBrowseId: 'MPREmayhem001',
      duration: const Duration(minutes: 4, seconds: 12),
      thumbnailUrl: 'https://i.ytimg.com/vi/DlFXDl_ROAM/hq720.jpg',
      catalogThumbnailUrl: 'https://music.example/catalog-artwork.jpg',
      streamClientProfileKey: 'webMusic',
      url: 'https://www.youtube.com/watch?v=DlFXDl_ROAM',
      metadataSource: TrackMetadataSource.youtubeMusic,
    ).toJson();

    final track = TrackInfoModel.fromJson(encoded);

    expect(track.artist, 'Lady Gaga, Bruno Mars');
    expect(track.artists, const ['Lady Gaga', 'Bruno Mars']);
    expect(track.artistBrowseIds, const ['UC-LadyGaga', null]);
    expect(encoded['artist_browse_ids'], const ['UC-LadyGaga', null]);
    expect(track.album, 'MAYHEM');
    expect(track.albumBrowseId, 'MPREmayhem001');
    expect(encoded['album_browse_id'], 'MPREmayhem001');
    expect(track.streamClientProfileKey, 'webMusic');
    expect(encoded['stream_client_profile_key'], 'webMusic');
    expect(track.duration, const Duration(minutes: 4, seconds: 12));
    expect(
      track.catalogThumbnailUrl,
      'https://music.example/catalog-artwork.jpg',
    );
    expect(track.metadataSource, TrackMetadataSource.youtubeMusic);
  });

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

  test('parses the requested itag 140 stream used by YO SOY TU TITAN', () {
    final track = TrackInfoModel.fromJson({
      'id': 'q8j3zwNhLNo',
      'title':
          'YO SOY TU TITAN || Mikasa Music Waifu #1 - Pamorkil '
          '(Lyric Video)',
      'webpage_url': 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
      'requested_downloads': [
        {
          'format_id': '140',
          'url': 'https://rr2---sn.googlevideo.com/videoplayback?itag=140',
          'ext': 'm4a',
          'vcodec': 'none',
          'acodec': 'mp4a.40.2',
          'http_headers': {'User-Agent': 'Mozilla/5.0', 'Accept': '*/*'},
        },
      ],
    });

    expect(track.id, 'q8j3zwNhLNo');
    expect(track.url, 'https://www.youtube.com/watch?v=q8j3zwNhLNo');
    expect(
      track.streamUrl,
      'https://rr2---sn.googlevideo.com/videoplayback?itag=140',
    );
    expect(track.streamExtension, 'm4a');
    expect(track.streamMimeType, 'audio/mp4');
    expect(track.httpHeaders, {'User-Agent': 'Mozilla/5.0', 'Accept': '*/*'});
  });

  test('prefers a higher bitrate stream before m4a', () {
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

    expect(track.streamUrl, 'https://example.com/audio.webm');
  });

  test('prefers native AAC when the bitrate is equal', () {
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
          'abr': 128,
        },
        {
          'url': 'https://example.com/audio.aac',
          'ext': 'aac',
          'vcodec': 'none',
          'acodec': 'aac',
          'abr': 128,
        },
      ],
    });

    expect(track.streamUrl, 'https://example.com/audio.aac');
  });

  test('uses the headers from the selected preferred native stream', () {
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
          'http_headers': {'X-Format': 'opus'},
        },
        {
          'url': 'https://example.com/audio.m4a',
          'ext': 'm4a',
          'vcodec': 'none',
          'acodec': 'mp4a.40.2',
          'abr': 128,
          'http_headers': {'X-Format': 'aac'},
        },
      ],
    });

    expect(track.streamUrl, 'https://example.com/audio.webm');
    expect(track.httpHeaders, {'X-Format': 'opus'});
  });

  test('prefers the highest bitrate within the preferred native format', () {
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

    expect(track.streamUrl, 'https://example.com/audio-128.m4a');
  });

  test('falls back to the highest bitrate original audio format', () {
    final track = TrackInfoModel.fromJson({
      'id': 'abc123',
      'title': 'Example Song',
      'uploader': 'Example Artist',
      'webpage_url': 'https://www.youtube.com/watch?v=abc123',
      'formats': [
        {
          'url': 'https://example.com/audio-128.mp3',
          'ext': 'mp3',
          'vcodec': 'none',
          'acodec': 'mp3',
          'abr': 128,
        },
        {
          'url': 'https://example.com/audio-160.webm',
          'ext': 'webm',
          'vcodec': 'none',
          'acodec': 'opus',
          'abr': 160,
        },
      ],
    });

    expect(track.streamUrl, 'https://example.com/audio-160.webm');
  });
}
