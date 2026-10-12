import 'dart:io';

import 'package:bstream_music/services/spotify_canvas/spotify_canvas_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const track = SpotifyCanvasTrack(
    'Woman (Official Video)',
    'Doja Cat',
    Duration(seconds: 173),
  );

  Map<String, dynamic> result({
    String name = 'Woman',
    String artist = 'Doja Cat',
    int durationMs = 172626,
  }) => {
    'results': [
      {
        'trackId': '6Uj1ctrBOjOas8xZXGqKk4',
        'name': name,
        'artistNames': [artist],
        'durationMs': durationMs,
      },
    ],
  };

  Map<String, dynamic> canvas(String url) => {
    'hasCanvas': true,
    'canvases': [
      {'type': 'VIDEO', 'canvasUrl': url},
    ],
  };

  test('resolves verified track, caches result and sends title only', () async {
    final requests = <Uri>[];
    var mediaProbes = 0;
    final resolver = SpotifyCanvasResolver(
      fetchJson: (uri) async {
        requests.add(uri);
        if (uri.path == '/api/search') return result();
        return canvas('https://canvaz.scdn.co/upload/test.cnvs.mp4');
      },
      probeMediaSize: (_) async {
        mediaProbes++;
        return 4 * 1024 * 1024;
      },
    );

    final url = await resolver.resolve(track);
    expect(url?.host, 'canvaz.scdn.co');
    expect(await resolver.resolve(track), url);
    expect(requests, hasLength(2));
    expect(mediaProbes, 1);
    expect(requests.first.queryParameters['track'], 'Woman');
    expect(requests.last.queryParameters['id'], '6Uj1ctrBOjOas8xZXGqKk4');
  });

  test(
    'resolves current GET-only provider streams with a one-byte probe',
    () async {
      final url = Uri.parse(
        'https://www.spotycovs.lol/api/canvas?id=6Uj1ctrBOjOas8xZXGqKk4&stream=1',
      );
      final methods = <String>[];
      final ranges = <String?>[];
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async =>
            uri.path == '/api/search' ? result() : canvas(url.toString()),
      );
      final resolved = await _withMediaServer(() => resolver.resolve(track), (
        request,
      ) async {
        methods.add(request.method);
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.contentType = ContentType('video', 'mp4')
          ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1310039')
          ..contentLength = 1
          ..add([0]);
        await request.response.close();
      });
      expect(resolved, url);
      expect(methods, ['GET']);
      expect(ranges, ['bytes=0-0']);
      expect(await resolver.resolve(track), url);
      expect(methods, hasLength(1));
    },
  );

  test(
    'direct CDN media falls back to Range when HEAD is unsupported',
    () async {
      final url = Uri.parse('https://canvaz.scdn.co/upload/test.cnvs.mp4');
      final methods = <String>[];
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async =>
            uri.path == '/api/search' ? result() : canvas(url.toString()),
      );
      final resolved = await _withMediaServer(() => resolver.resolve(track), (
        request,
      ) async {
        methods.add(request.method);
        if (request.method == 'HEAD') {
          request.response.statusCode = HttpStatus.methodNotAllowed;
        } else {
          request.response
            ..statusCode = HttpStatus.partialContent
            ..headers.contentType = ContentType('video', 'mp4')
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/1310039')
            ..contentLength = 1
            ..add([0]);
        }
        await request.response.close();
      });
      expect(resolved, url);
      expect(methods, ['HEAD', 'GET']);
    },
  );

  test(
    'provider streams still reject oversized or unknown total sizes',
    () async {
      final url = Uri.parse(
        'https://www.spotycovs.lol/api/canvas?id=6Uj1ctrBOjOas8xZXGqKk4&stream=1',
      );
      for (final total in [
        '${SpotifyCanvasResolver.maxCanvasBytes + 1}',
        '*',
      ]) {
        final resolver = SpotifyCanvasResolver(
          fetchJson: (uri) async =>
              uri.path == '/api/search' ? result() : canvas(url.toString()),
        );
        final resolved = await _withMediaServer(() => resolver.resolve(track), (
          request,
        ) async {
          request.response
            ..statusCode = HttpStatus.partialContent
            ..headers.contentType = ContentType('video', 'mp4')
            ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 0-0/$total')
            ..contentLength = 1
            ..add([0]);
          await request.response.close();
        });
        expect(resolved, isNull, reason: total);
      }
    },
  );

  test('provider JSON errors cannot be mistaken for small video files', () async {
    final url = Uri.parse(
      'https://www.spotycovs.lol/api/canvas?id=6Uj1ctrBOjOas8xZXGqKk4&stream=1',
    );
    final resolver = SpotifyCanvasResolver(
      fetchJson: (uri) async =>
          uri.path == '/api/search' ? result() : canvas(url.toString()),
    );
    final resolved = await _withMediaServer(() => resolver.resolve(track), (
      request,
    ) async {
      request.response
        ..headers.contentType = ContentType.json
        ..contentLength = 2
        ..write('{}');
      await request.response.close();
    });
    expect(resolved, isNull);
  });

  test('provider streams must belong to the verified Spotify track', () async {
    for (final rawUrl in [
      'https://spotycovs.lol/api/canvas?id=6Uj1ctrBOjOas8xZXGqKk4&stream=1',
      'https://www.spotycovs.lol/api/canvas?id=4HYDUMY0xSpeBr0AMY9cUz&stream=1',
      'https://www.spotycovs.lol/api/canvas?id=6Uj1ctrBOjOas8xZXGqKk4',
      'https://www.spotycovs.lol/other?id=6Uj1ctrBOjOas8xZXGqKk4&stream=1',
      'https://www.spotycovs.lol:8443/api/canvas?id=6Uj1ctrBOjOas8xZXGqKk4&stream=1',
      'https://user@www.spotycovs.lol/api/canvas?id=6Uj1ctrBOjOas8xZXGqKk4&stream=1',
    ]) {
      var probes = 0;
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async =>
            uri.path == '/api/search' ? result() : canvas(rawUrl),
        probeMediaSize: (_) async {
          probes++;
          return 1310039;
        },
      );
      final accepted = rawUrl.startsWith('https://spotycovs.lol/');
      expect(
        await resolver.resolve(track),
        accepted ? Uri.parse(rawUrl) : null,
      );
      expect(probes, accepted ? 1 : 0);
    }
  });

  test('does not show Canvas for wrong artist, title or duration', () async {
    for (final wrong in [
      result(artist: 'Another Artist'),
      result(name: 'Womanizer'),
      result(durationMs: 240000),
    ]) {
      var requests = 0;
      final resolver = SpotifyCanvasResolver(
        fetchJson: (_) async {
          requests++;
          return wrong;
        },
      );
      expect(await resolver.resolve(track), isNull);
      expect(requests, 3); // Two searches and the verified direct fallback.
    }
  });

  test(
    'matches non-Latin song and artist names without transliteration',
    () async {
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async => uri.path == '/api/search'
            ? {
                'results': [
                  {
                    'trackId': '6Uj1ctrBOjOas8xZXGqKk4',
                    'name': '光',
                    'artistNames': ['宇多田ヒカル'],
                    'durationMs': 200000,
                  },
                ],
              }
            : canvas('https://canvaz.scdn.co/upload/test.cnvs.mp4'),
        probeMediaSize: (_) async => 4 * 1024 * 1024,
      );
      expect(
        await resolver.resolve(
          const SpotifyCanvasTrack('光', '宇多田ヒカル', Duration(seconds: 200)),
        ),
        isNotNull,
      );
    },
  );

  test('rejects unexpected video host and handles absent Canvas', () async {
    for (final response in [
      canvas('https://example.com/track.mp4'),
      {'hasCanvas': false, 'canvases': []},
    ]) {
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async =>
            uri.path == '/api/search' ? result() : response,
      );
      expect(await resolver.resolve(track), isNull);
    }
  });

  test('network failure returns no Canvas and is coalesced', () async {
    var requests = 0;
    final resolver = SpotifyCanvasResolver(
      fetchJson: (_) async {
        requests++;
        throw const FormatException('offline');
      },
    );
    final values = await Future.wait([
      resolver.resolve(track),
      resolver.resolve(track),
    ]);
    expect(values, [null, null]);
    expect(requests, 1);
  });

  test('does not load oversized or unmeasurable Canvas files', () async {
    for (final bytes in <int?>[
      SpotifyCanvasResolver.maxCanvasBytes + 1,
      null,
    ]) {
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async => uri.path == '/api/search'
            ? result()
            : canvas('https://canvaz.scdn.co/upload/test.cnvs.mp4'),
        probeMediaSize: (_) async => bytes,
      );
      expect(await resolver.resolve(track), isNull);
    }
  });

  test('artist-qualified retry finds a crowded search result', () async {
    final searches = <String?>[];
    final resolver = SpotifyCanvasResolver(
      fetchJson: (uri) async {
        if (uri.path == '/api/search') {
          searches.add(uri.queryParameters['track']);
          return uri.queryParameters['track'] ==
                  'Bad Bunny - Otra Noche en Miami'
              ? {
                  'results': [
                    {
                      'trackId': '4vCAzANUWDE24URV6wQ4ra',
                      'name': 'Otra Noche en Miami',
                      'artistNames': ['Bad Bunny'],
                      'durationMs': 233128,
                    },
                  ],
                }
              : {'results': []};
        }
        return canvas('https://canvaz.scdn.co/upload/miami.cnvs.mp4');
      },
      probeMediaSize: (_) async => 1000000,
    );
    expect(
      await resolver.resolve(
        const SpotifyCanvasTrack(
          'Otra Noche en Miami (Video Oficial)',
          'Bad Bunny - Topic',
          Duration(seconds: 270),
        ),
      ),
      Uri.parse('https://canvaz.scdn.co/upload/miami.cnvs.mp4'),
    );
    expect(searches, [
      'Otra Noche en Miami',
      'Bad Bunny - Otra Noche en Miami',
    ]);
  });

  test('direct catalog fallback finds a studio Canvas omitted by search', () async {
    final requests = <Uri>[];
    final resolver = SpotifyCanvasResolver(
      fetchJson: (uri) async {
        requests.add(uri);
        if (uri.path == '/api/search') {
          return {
            'results': [
              {
                'trackId': '1kuGVB7EU95pJObxwvfwKS',
                'name': 'vampire - live piano performance',
                'artistNames': ['Olivia Rodrigo'],
                'durationMs': 217000,
              },
            ],
          };
        }
        return {
          'trackId': '1kuGVB7EU95pJObxwvfwKS',
          'hasCanvas': true,
          'resolution': {
            'matchedTrack': 'vampire',
            'matchedArtist': 'Olivia Rodrigo',
          },
          'canvases': [
            {
              'type': 'VIDEO',
              'canvasUrl':
                  'https://www.spotycovs.lol/api/canvas?id=1kuGVB7EU95pJObxwvfwKS&stream=1',
            },
          ],
        };
      },
      probeMediaSize: (_) async => 1600000,
    );
    expect(
      await resolver.resolve(
        const SpotifyCanvasTrack(
          'vampire',
          'Olivia Rodrigo',
          Duration(seconds: 219),
        ),
      ),
      Uri.parse(
        'https://www.spotycovs.lol/api/canvas?id=1kuGVB7EU95pJObxwvfwKS&stream=1',
      ),
    );
    expect(requests.last.queryParameters['track'], 'vampire Olivia Rodrigo');
  });

  test('direct fallback rejects another artist or recording', () async {
    for (final wrong in [
      ('vampire', 'Another Artist'),
      ('vampire - live piano performance', 'Olivia Rodrigo'),
    ]) {
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async => uri.path == '/api/search'
            ? {'results': []}
            : {
                'trackId': '1kuGVB7EU95pJObxwvfwKS',
                'hasCanvas': true,
                'resolution': {
                  'matchedTrack': wrong.$1,
                  'matchedArtist': wrong.$2,
                },
                'canvases': [
                  {
                    'type': 'VIDEO',
                    'canvasUrl': 'https://canvaz.scdn.co/upload/wrong.cnvs.mp4',
                  },
                ],
              },
        probeMediaSize: (_) async => 1600000,
      );
      expect(
        await resolver.resolve(
          const SpotifyCanvasTrack(
            'vampire',
            'Olivia Rodrigo',
            Duration(seconds: 219),
          ),
        ),
        isNull,
      );
    }
  });

  test(
    'direct lookup keeps duo names intact and rejects a solo namesake',
    () async {
      for (final matchedArtist in ['Polo & Pan', 'Polo']) {
        Uri? directRequest;
        final resolver = SpotifyCanvasResolver(
          fetchJson: (uri) async {
            if (uri.path == '/api/search') return {'results': []};
            directRequest = uri;
            return {
              'trackId': '6Uj1ctrBOjOas8xZXGqKk4',
              'hasCanvas': true,
              'resolution': {
                'matchedTrack': 'Feel Good',
                'matchedArtist': matchedArtist,
              },
              'canvases': [
                {
                  'type': 'VIDEO',
                  'canvasUrl':
                      'https://canvaz.scdn.co/upload/feelgood.cnvs.mp4',
                },
              ],
            };
          },
          probeMediaSize: (_) async => 1000000,
        );
        final url = await resolver.resolve(
          const SpotifyCanvasTrack(
            'Feel Good',
            'Polo & Pan',
            Duration(seconds: 250),
          ),
        );
        expect(url != null, matchedArtist == 'Polo & Pan');
        expect(directRequest?.queryParameters['track'], 'Feel Good Polo & Pan');
      }
    },
  );

  test(
    'tries a second verified release only when the first lacks Canvas',
    () async {
      final requestedIds = <String>[];
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async {
          if (uri.path == '/api/search') {
            return {
              'results': [
                {
                  'trackId': '595wwjQiad6e6lSTScmXvz',
                  'name': 'POR SI MAÑANA NO ESTOY',
                  'artistNames': ['Omar Courtz'],
                  'durationMs': 264946,
                },
                {
                  'trackId': '5FIvygEAeCSTFO6lY3Cda0',
                  'name': 'POR SI MANANA NO ESTOY',
                  'artistNames': ['Omar Courtz'],
                  'durationMs': 264946,
                },
              ],
            };
          }
          requestedIds.add(uri.queryParameters['id']!);
          return requestedIds.length == 1
              ? {'hasCanvas': false, 'canvases': []}
              : canvas('https://canvaz.scdn.co/upload/omar.cnvs.mp4');
        },
        probeMediaSize: (_) async => 500000,
      );
      expect(
        await resolver.resolve(
          const SpotifyCanvasTrack(
            'Por Si Mañana No Estoy',
            'Omar Courtz',
            Duration(seconds: 265),
          ),
        ),
        Uri.parse('https://canvaz.scdn.co/upload/omar.cnvs.mp4'),
      );
      expect(requestedIds, [
        '595wwjQiad6e6lSTScmXvz',
        '5FIvygEAeCSTFO6lY3Cda0',
      ]);
    },
  );

  test('honors provider cooldown across different tracks', () async {
    var requests = 0;
    final resolver = SpotifyCanvasResolver(
      fetchJson: (_) async {
        requests++;
        return {'code': 'cooldown_active_try_again_in_a_moment'};
      },
    );
    expect(await resolver.resolve(track), isNull);
    expect(
      await resolver.resolve(
        const SpotifyCanvasTrack(
          'Another Song',
          'Another Artist',
          Duration(seconds: 200),
        ),
      ),
      isNull,
    );
    expect(requests, 1);
  });

  test('provider cooldown preserves an already resolved Canvas', () async {
    var throttled = false;
    final resolver = SpotifyCanvasResolver(
      fetchJson: (uri) async {
        if (throttled) {
          return {'code': 'spotify_rate_limited'};
        }
        return uri.path == '/api/search'
            ? result()
            : canvas('https://canvaz.scdn.co/upload/test.cnvs.mp4');
      },
      probeMediaSize: (_) async => 1000000,
    );
    final first = await resolver.resolve(track);
    throttled = true;
    await resolver.resolve(
      const SpotifyCanvasTrack(
        'Another Song',
        'Another Artist',
        Duration(seconds: 200),
      ),
    );
    expect(await resolver.resolve(track), first);
  });

  test('accepts a credited collaborator only with matching duration', () async {
    for (final durationMs in <int?>[200000, null, 260000]) {
      var canvasRequests = 0;
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async {
          if (uri.path == '/api/search') {
            return {
              'results': [
                {
                  'trackId': '6Uj1ctrBOjOas8xZXGqKk4',
                  'name': 'Hola',
                  'artistNames': ['Miranda!', 'Julieta Venegas'],
                  'durationMs': ?durationMs,
                },
              ],
            };
          }
          canvasRequests++;
          return canvas('https://canvaz.scdn.co/upload/hola.cnvs.mp4');
        },
        probeMediaSize: (_) async => 1000000,
      );
      final resolved = await resolver.resolve(
        const SpotifyCanvasTrack(
          'Hola',
          'Julieta Venegas',
          Duration(seconds: 200),
        ),
      );
      expect(resolved != null, durationMs == 200000);
      expect(canvasRequests, 1);
    }
  });

  test('known Spotify releases keep their verified Canvas result', () async {
    final samples = [
      (
        const SpotifyCanvasTrack(
          'La Curiosidad (Official Audio)',
          'Jay Wheeler',
          Duration.zero,
        ),
        '4HYDUMY0xSpeBr0AMY9cUz',
        'La Curiosidad',
        <String>['Jay Wheeler', 'DJ Nelson', 'Myke Towers'],
        true,
      ),
      (
        const SpotifyCanvasTrack(
          'La Difícil',
          'Bad Bunny',
          Duration(seconds: 163),
        ),
        '6NfrH0ANGmgBXyxgV2PeXt',
        'La Difícil',
        <String>['Bad Bunny'],
        true,
      ),
      (
        const SpotifyCanvasTrack(
          'Otra Noche en Miami',
          'Bad Bunny',
          Duration(seconds: 233),
        ),
        '4vCAzANUWDE24URV6wQ4ra',
        'Otra Noche en Miami',
        <String>['Bad Bunny'],
        false,
      ),
    ];
    for (final sample in samples) {
      var searches = 0;
      var canvases = 0;
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async {
          if (uri.path == '/api/search') {
            searches++;
            return {
              'results': [
                {
                  'trackId': sample.$2,
                  'name': sample.$3,
                  'artistNames': sample.$4,
                  'durationMs': sample.$1.duration.inMilliseconds,
                },
              ],
            };
          }
          canvases++;
          return sample.$5
              ? canvas('https://canvaz.scdn.co/upload/${sample.$2}.cnvs.mp4')
              : {'hasCanvas': false, 'canvases': []};
        },
        probeMediaSize: (_) async => 1000000,
      );
      final url = await resolver.resolve(sample.$1);
      expect(url != null, sample.$5, reason: sample.$3);
      expect(searches, 1, reason: sample.$3);
      expect(canvases, sample.$5 ? 1 : 2, reason: sample.$3);
    }
  });
}

Future<Uri?> _withMediaServer(
  Future<Uri?> Function() resolve,
  Future<void> Function(HttpRequest) respond,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = HttpClient();
  final subscription = server.listen(respond);
  try {
    return await HttpOverrides.runZoned(
      resolve,
      createHttpClient: (_) => _RoutedCanvasClient(client, server.port),
    );
  } finally {
    client.close(force: true);
    await subscription.cancel();
    await server.close(force: true);
  }
}

class _RoutedCanvasClient implements HttpClient {
  _RoutedCanvasClient(this.client, this.port);

  final HttpClient client;
  final int port;

  Uri _route(Uri uri) => uri.replace(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: port,
  );

  @override
  Duration? get connectionTimeout => client.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;

  @override
  Future<HttpClientRequest> getUrl(Uri uri) => client.getUrl(_route(uri));

  @override
  Future<HttpClientRequest> headUrl(Uri uri) => client.headUrl(_route(uri));

  @override
  void close({bool force = false}) => client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
