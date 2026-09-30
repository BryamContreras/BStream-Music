import 'package:bstream_music/services/animated_artwork/apple_animated_artwork_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

const _track = AppleAnimatedArtworkTrack(
  title: 'Numb',
  artist: 'Linkin Park',
  album: 'Meteora',
  duration: Duration(seconds: 187),
  preferVertical: false,
);

void main() {
  test('m8tec HLS resolves to a compatible MP4 before boidu', () async {
    final calls = <Uri>[];
    final playlists = <Uri>[];
    final resolver = AppleAnimatedArtworkResolver(
      fetchJson: (uri) async {
        calls.add(uri);
        return {
          'artist': 'LINKIN PARK',
          'album': 'METEORA',
          'url': 'https://mvod.itunes.apple.com/master.m3u8',
        };
      },
      fetchText: (uri) async {
        playlists.add(uri);
        if (uri.path == '/master.m3u8') {
          return '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=2100000,CODECS="avc1.64001f",RESOLUTION=768x768\n'
              'media_768x768.m3u8\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=9000000,CODECS="avc1.64001f",RESOLUTION=2160x2160\n'
              'media_2160x2160.m3u8\n';
        }
        return '#EXTM3U\n'
            '#EXT-X-MAP:URI="video.mp4",BYTERANGE="896@0"\n';
      },
    );
    expect(
      await resolver.resolve(_track),
      Uri.parse('https://mvod.itunes.apple.com/video.mp4'),
    );
    expect(calls.single.host, 'artwork.m8tec.top');
    expect(playlists.map((uri) => uri.path), [
      '/master.m3u8',
      '/media_768x768.m3u8',
    ]);
    expect(
      await resolver.resolve(_track),
      Uri.parse('https://mvod.itunes.apple.com/video.mp4'),
    );
    expect(calls.length, 1); // Positive result is cached.
  });

  test('falls back to boidu when m8tec fails', () async {
    final calls = <Uri>[];
    final resolver = AppleAnimatedArtworkResolver(
      fetchJson: (uri) async {
        calls.add(uri);
        if (uri.host == 'artwork.m8tec.top') throw StateError('offline');
        return {
          'name': 'Numb',
          'artist': 'LINKIN PARK',
          'videoUrl': 'https://mvod.itunes.apple.com/fallback_768x768-.mp4',
        };
      },
      fetchText: (_) async => null,
    );
    expect(
      await resolver.resolve(_track),
      Uri.parse('https://mvod.itunes.apple.com/fallback_768x768-.mp4'),
    );
    expect(calls.map((uri) => uri.host).toList(), [
      'artwork.m8tec.top',
      'artwork.boidu.dev',
    ]);
    expect(calls.last.queryParameters['d'], '187');
  });

  test(
    'cleans video suffixes and uses square video when tall is absent',
    () async {
      final queries = <Uri>[];
      final resolver = AppleAnimatedArtworkResolver(
        fetchJson: (uri) async {
          queries.add(uri);
          if (uri.host == 'artwork.m8tec.top') return null;
          return {
            'name': 'Numb',
            'artist': 'LINKIN PARK',
            'videoUrl': 'https://mvod.itunes.apple.com/square_768x768-.mp4',
          };
        },
        fetchText: (_) async => null,
      );
      final track = AppleAnimatedArtworkTrack(
        title: 'Numb (Official Video)',
        artist: 'Linkin Park',
        album: 'Meteora',
        duration: const Duration(seconds: 187),
        preferVertical: true,
      );
      expect(
        await resolver.resolve(track),
        Uri.parse('https://mvod.itunes.apple.com/square_768x768-.mp4'),
      );
      expect(queries.last.queryParameters['s'], 'Numb');
    },
  );

  test('rejects mismatched or non-Apple videos', () async {
    final resolver = AppleAnimatedArtworkResolver(
      fetchJson: (uri) async => uri.host == 'artwork.m8tec.top'
          ? {
              'artist': 'Someone else',
              'album': 'Meteora',
              'url': 'https://mvod.itunes.apple.com/master.m3u8',
            }
          : {
              'name': 'Numb',
              'artist': 'LINKIN PARK',
              'videoUrl': 'https://example.com/untrusted.mp4',
            },
      fetchText: (_) async => null,
    );
    expect(await resolver.resolve(_track), isNull);
  });

  test('rejects a 2160px direct MP4 instead of downloading it', () async {
    final resolver = AppleAnimatedArtworkResolver(
      fetchJson: (uri) async => uri.host == 'artwork.m8tec.top'
          ? null
          : {
              'name': 'Numb',
              'artist': 'LINKIN PARK',
              'videoUrl': 'https://mvod.itunes.apple.com/video_2160x2160-.mp4',
            },
      fetchText: (_) async => null,
    );
    expect(await resolver.resolve(_track), isNull);
  });
}
