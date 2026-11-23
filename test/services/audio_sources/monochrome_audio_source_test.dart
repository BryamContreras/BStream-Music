import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/audio_sources/monochrome_audio_source.dart';
import 'package:bstream_music/services/jiosaavn/jiosaavn_recording_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const releaseTrack = {
    'id': '155102871061270528',
    'trackId': '155102871061270528',
    'title': 'One More Time',
    'artistNames': ['Daft Punk'],
    'releaseId': '155102851176075264',
    'duration': 320357,
    'explicit': false,
    'playable': true,
  };

  test('builds public search and direct stream routes', () {
    final base = Uri.parse('https://tracks.monochrome.st/');
    final search = MonochromeAudioSource.searchUri(base, 'Daft Punk & friends');

    expect(search.path, '/search/tracks');
    expect(search.queryParameters, {'q': 'Daft Punk & friends', 'limit': '20'});
    expect(
      MonochromeAudioSource.streamUri(base, releaseTrack['id']! as String),
      Uri.parse('https://tracks.monochrome.st/track/155102871061270528'),
    );
    expect(
      () => MonochromeAudioSource.streamUri(base, '../search'),
      throwsArgumentError,
    );
  });

  test('native catalog milliseconds match a YouTube Music recording', () {
    final candidates = MonochromeAudioSource.parseSearch({
      'tracks': [releaseTrack],
      'releases': [],
    });
    final matches = const JioSaavnRecordingMatcher().rankedMatches(
      const TrackInfo(
        id: 'youtube-music-id',
        title: 'One More Time',
        artist: 'Daft Punk',
        album: 'Discovery',
        duration: Duration(minutes: 5, seconds: 20),
        url: 'https://music.youtube.com/watch?v=youtube-music-id',
      ),
      candidates,
    );
    expect(matches.single.duration, const Duration(milliseconds: 320357));
    expect(matches.single.artists, ['Daft Punk']);
    expect(matches.single.id, releaseTrack['id']);
  });

  test('accepts nested track lists and ignores unusable rows', () {
    final candidates = MonochromeAudioSource.parseSearch({
      'data': {
        'tracks': [
          {...releaseTrack, 'playable': false},
          {...releaseTrack, 'duration': 0},
          {...releaseTrack, 'trackId': '../track', 'id': '../track'},
          {
            ...releaseTrack,
            'id': '123',
            'trackId': 123,
            'album': {'title': 'Discovery'},
          },
        ],
      },
    });
    expect(candidates.single.id, '123');
    expect(candidates.single.album, 'Discovery');
  });
}
