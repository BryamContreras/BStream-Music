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

  test(
    'Higher Power retries without video duration on the same album',
    () async {
      final boiduQueries = <Map<String, String>>[];
      final resolver = AppleAnimatedArtworkResolver(
        fetchJson: (uri) async {
          if (uri.host == 'artwork.m8tec.top') return null;
          if (uri.host == 'artwork.boidu.dev') {
            boiduQueries.add(uri.queryParameters);
            return {
              'name': 'Higher Power',
              'artist': 'Coldplay',
              if (!uri.queryParameters.containsKey('d'))
                'videoUrl': 'https://mvod.itunes.apple.com/higher_768x768-.mp4',
            };
          }
          fail('Apple catalog should not be needed when the album is known');
        },
        fetchText: (_) async => null,
      );
      expect(
        await resolver.resolve(
          const AppleAnimatedArtworkTrack(
            title: 'Higher Power (Official Music Video)',
            artist: 'Coldplay',
            album: 'Music of the Spheres',
            duration: Duration(seconds: 258),
            preferVertical: false,
          ),
        ),
        Uri.parse('https://mvod.itunes.apple.com/higher_768x768-.mp4'),
      );
      expect(boiduQueries, hasLength(2));
      expect(boiduQueries.first['d'], '258');
      expect(boiduQueries.last.containsKey('d'), isFalse);
      expect(boiduQueries.last['al'], 'Music of the Spheres');
    },
  );

  test(
    'finds animated album edition after a matching single lacks it',
    () async {
      final calls = <Uri>[];
      final resolver = AppleAnimatedArtworkResolver(
        fetchJson: (uri) async {
          calls.add(uri);
          if (uri.host == 'artwork.m8tec.top') return null;
          if (uri.host == 'itunes.apple.com') {
            return {
              'results': [
                {
                  'trackName': 'Higher Power',
                  'artistName': 'Coldplay',
                  'collectionName': 'Higher Power - Single',
                  'trackTimeMillis': 211295,
                },
                {
                  'trackName': 'Higher Power (Tiësto Remix)',
                  'artistName': 'Coldplay',
                  'collectionName': 'Higher Power (Tiësto Remix) - Single',
                  'trackTimeMillis': 229565,
                },
                {
                  'trackName': 'Higher Power',
                  'artistName': 'Coldplay',
                  'collectionName': 'Music of the Spheres',
                  'trackTimeMillis': 206682,
                },
              ],
            };
          }
          return {
            'name': 'Higher Power',
            'artist': 'Coldplay',
            if (uri.queryParameters['al'] == 'Music of the Spheres')
              'videoUrl': 'https://mvod.itunes.apple.com/album_768x768-.mp4',
          };
        },
        fetchText: (_) async => null,
      );
      expect(
        await resolver.resolve(
          const AppleAnimatedArtworkTrack(
            title: 'Higher Power',
            artist: 'Coldplay',
            album: 'Higher Power - Single',
            duration: Duration(seconds: 211),
            preferVertical: false,
          ),
        ),
        Uri.parse('https://mvod.itunes.apple.com/album_768x768-.mp4'),
      );
      expect(
        calls.where((uri) => uri.host == 'itunes.apple.com'),
        hasLength(1),
      );
      expect(
        calls
            .where((uri) => uri.host == 'artwork.boidu.dev')
            .last
            .queryParameters['al'],
        'Music of the Spheres',
      );
    },
  );

  test(
    'recovers an animated album when YouTube provides no useful album',
    () async {
      final calls = <Uri>[];
      final resolver = AppleAnimatedArtworkResolver(
        fetchJson: (uri) async {
          calls.add(uri);
          if (uri.host == 'itunes.apple.com') {
            return {
              'results': [
                {
                  'trackName': 'Higher Power',
                  'artistName': 'Coldplay',
                  'collectionName': 'Music of the Spheres',
                  'trackTimeMillis': 206682,
                },
              ],
            };
          }
          if (uri.host == 'artwork.boidu.dev' &&
              uri.queryParameters['al'] == 'Music of the Spheres') {
            return {
              'name': 'Higher Power',
              'artist': 'Coldplay',
              'videoUrl': 'https://mvod.itunes.apple.com/higher_768x768-.mp4',
            };
          }
          return null;
        },
        fetchText: (_) async => null,
      );

      expect(
        await resolver.resolve(
          const AppleAnimatedArtworkTrack(
            title: 'Higher Power (Official Music Video)',
            artist: 'Coldplay',
            album: 'YouTube Music',
            duration: Duration(seconds: 207),
            preferVertical: false,
          ),
        ),
        Uri.parse('https://mvod.itunes.apple.com/higher_768x768-.mp4'),
      );
      expect(
        calls.where((uri) => uri.host == 'itunes.apple.com'),
        hasLength(1),
      );
    },
  );

  test(
    'does not borrow animated artwork from remix or unrelated artist',
    () async {
      final resolver = AppleAnimatedArtworkResolver(
        fetchJson: (uri) async {
          if (uri.host == 'artwork.m8tec.top') return null;
          if (uri.host == 'itunes.apple.com') {
            return {
              'results': [
                {
                  'trackName': 'Higher Power (Tiësto Remix)',
                  'artistName': 'Coldplay',
                  'collectionName': 'Higher Power (Tiësto Remix) - Single',
                  'trackTimeMillis': 229565,
                },
                {
                  'trackName': 'Higher Power',
                  'artistName': 'Boston',
                  'collectionName': 'Greatest Hits',
                  'trackTimeMillis': 211295,
                },
              ],
            };
          }
          return {'name': 'Higher Power', 'artist': 'Coldplay'};
        },
        fetchText: (_) async => null,
      );
      expect(
        await resolver.resolve(
          const AppleAnimatedArtworkTrack(
            title: 'Higher Power',
            artist: 'Coldplay',
            album: 'Higher Power - Single',
            duration: Duration(seconds: 211),
            preferVertical: false,
          ),
        ),
        isNull,
      );
    },
  );

  test('probes at most two alternate albums after catalog search', () async {
    final albumQueries = <String>[];
    final resolver = AppleAnimatedArtworkResolver(
      fetchJson: (uri) async {
        if (uri.host == 'artwork.m8tec.top') return null;
        if (uri.host == 'itunes.apple.com') {
          return {
            'results': [
              for (final album in ['Album A', 'Album B', 'Album C'])
                {
                  'trackName': 'Higher Power',
                  'artistName': 'Coldplay',
                  'collectionName': album,
                  'trackTimeMillis': 211295,
                },
            ],
          };
        }
        albumQueries.add(uri.queryParameters['al']!);
        return {'name': 'Higher Power', 'artist': 'Coldplay'};
      },
      fetchText: (_) async => null,
    );
    expect(
      await resolver.resolve(
        const AppleAnimatedArtworkTrack(
          title: 'Higher Power',
          artist: 'Coldplay',
          album: 'Higher Power - Single',
          duration: Duration(seconds: 211),
          preferVertical: false,
        ),
      ),
      isNull,
    );
    expect(albumQueries, [
      'Higher Power - Single',
      'Higher Power - Single',
      'Album A',
      'Album B',
    ]);
  });

  test(
    'known Apple albums distinguish animated and still-only covers',
    () async {
      final samples = [
        (
          const AppleAnimatedArtworkTrack(
            title: 'vampire (Official Music Video)',
            artist: 'Olivia Rodrigo',
            album: 'GUTS',
            duration: Duration(seconds: 219),
            preferVertical: false,
          ),
          true,
        ),
        (
          const AppleAnimatedArtworkTrack(
            title: 'good 4 u',
            artist: 'Olivia Rodrigo',
            album: 'SOUR',
            duration: Duration(seconds: 178),
            preferVertical: false,
          ),
          true,
        ),
        (
          const AppleAnimatedArtworkTrack(
            title: 'POR SI MAÑANA NO ESTOY',
            artist: 'Omar Courtz',
            album: 'Primera Musa',
            duration: Duration(seconds: 265),
            preferVertical: false,
          ),
          false,
        ),
      ];
      for (final sample in samples) {
        final queries = <Uri>[];
        final resolver = AppleAnimatedArtworkResolver(
          fetchJson: (uri) async {
            queries.add(uri);
            if (uri.host == 'artwork.m8tec.top') return null;
            if (uri.host == 'itunes.apple.com') return {'results': []};
            return {
              'name': sample.$1.title.replaceAll(' (Official Music Video)', ''),
              'artist': sample.$1.artist,
              if (sample.$2)
                'videoUrl': 'https://mvod.itunes.apple.com/test_768x768-.mp4',
            };
          },
          fetchText: (_) async => null,
        );
        final url = await resolver.resolve(sample.$1);
        expect(url != null, sample.$2, reason: sample.$1.title);
        expect(
          queries
              .where((uri) => uri.host == 'artwork.boidu.dev')
              .first
              .queryParameters['al'],
          sample.$1.album,
        );
      }
    },
  );
}
