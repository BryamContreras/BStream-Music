import 'dart:convert';
import 'dart:typed_data';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/audio_sources/audio_extension.dart';
import 'package:bstream_music/services/audio_sources/audio_extension_resolver.dart';
import 'package:bstream_music/services/audio_sources/bounded_audio_http_transport.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads and persists the selected source without losing URL parameters',
    () async {
      final transport = _Transport((request) {
        expect(request.uri.path, '/personal/source/manifest.json');
        expect(request.uri.queryParametersAll['key'], ['one', 'two']);
        return _json({..._manifest, 'allowDownloads': '0'});
      });
      final resolver = AudioExtensionResolver(transport: transport);
      addTearDown(resolver.dispose);

      final extension = await resolver.load(
        'https://addon.example/personal/source/?key=one&key=two',
      );
      final restored = AudioExtension.fromJson(
        jsonDecode(jsonEncode(extension.copyWith(enabled: false).toJson())),
      );
      expect(restored?.id, 'demo');
      expect(restored?.name, 'Demo audio');
      expect(restored?.manifestUri, extension.manifestUri);
      expect(restored?.enabled, isFalse);
      expect(restored?.allowDownloads, isFalse);
    },
  );

  test('normalizes a pasted manifest URL ending in a comma', () async {
    final transport = _Transport((request) {
      expect(request.uri.path, '/api/manifest.json');
      return _json(_manifest);
    });
    final resolver = AudioExtensionResolver(transport: transport);
    addTearDown(resolver.dispose);

    final sources = await resolver.loadSources(
      ' https://addon.example/api/manifest.json, ',
    );

    expect(sources.single.manifestUri.path, '/api/manifest.json');
    expect(transport.requests, hasLength(1));
  });

  test('uses a JSON service root when no manifest file exists', () async {
    final transport = _Transport((request) {
      if (request.uri.host == 'cdn.example') return _flac();
      expect(request.uri.queryParametersAll['key'], ['one', 'two']);
      return switch (request.uri.path) {
        '/personal/source/manifest.json' => _response(404),
        '/personal/source' || '/personal/source/' => _json(_manifest),
        '/personal/source/search' => _json({
          'tracks': [_song('recording')],
        }),
        '/personal/source/stream/recording' => _json({
          'url': 'https://cdn.example/audio.flac',
        }),
        final path => throw StateError('Unexpected path $path'),
      };
    });
    final resolver = AudioExtensionResolver(transport: transport);
    addTearDown(resolver.dispose);
    final extensions = await resolver.loadSources(
      'https://addon.example/personal/source?key=one&key=two',
    );

    final audio = await resolver.findUpgrade(_track, extensions: extensions);

    expect(extensions.single.id, 'demo');
    expect(audio?.streamUrl, 'https://cdn.example/audio.flac');
    expect(transport.requests, hasLength(5));
  });

  test(
    'supports a legacy query stream and measures omitted duration',
    () async {
      final transport = _Transport(
        (request) => switch (request.uri.path) {
          '/manifest.json' => _json(_manifest),
          '/search' => _json({
            'tracks': [
              {'id': 456, 'title': 'Signal', 'artist': 'Another artist'},
              {'id': 123, 'title': 'Signal', 'artist': 'Demo Artist'},
            ],
          }),
          '/stream/123' => _response(404),
          '/stream' => () {
            expect(request.uri.queryParameters['id'], '123');
            return _json({'streamUrl': 'https://cdn.example/audio.flac'});
          }(),
          '/audio.flac' => _flac(seconds: 183),
          final path => throw StateError('Unexpected path $path'),
        },
      );
      final resolver = AudioExtensionResolver(transport: transport);
      addTearDown(resolver.dispose);
      final extensions = await resolver.loadSources('https://addon.example');

      final audio = await resolver.findUpgrade(_track, extensions: extensions);

      expect(audio?.streamUrl, 'https://cdn.example/audio.flac');
      expect(transport.requests.map((request) => request.uri.path), [
        '/manifest.json',
        '/search',
        '/stream/123',
        '/stream',
        '/audio.flac',
      ]);
    },
  );

  test('requests CD FLAC even when Hi-Res is the first option', () async {
    final transport = _Transport((request) {
      final uri = request.uri;
      if (uri.path.endsWith('/manifest.json')) {
        return _json({
          ..._manifest,
          'settings': [
            {
              'key': 'audio_quality',
              'default': 'HI_RES_LOSSLESS',
              'options': [
                {
                  'value': 'HI_RES_LOSSLESS',
                  'label': 'Hi-Res 24-bit / 44.1kHz',
                },
                {'value': 'bad-24', 'label': '24-bit / 44.1 kHz FLAC'},
                {'value': 'bad-48', 'label': '16-bit / 48 kHz FLAC'},
                {'value': 'bad-lossy', 'label': '44.1 kHz AAC'},
                {'value': 'infer', 'label': '44.1 kHz FLAC'},
                {
                  'value': 'LOSSLESS',
                  'label': 'Lossless FLAC (16-bit / 44.1kHz)',
                },
              ],
            },
          ],
        });
      }
      if (uri.host == 'cdn.example') {
        expect(request.maximumBytes, 42);
        expect(request.readPrefix, isTrue);
        expect(request.headers['Range'], 'bytes=0-41');
        expect(request.headers['User-Agent'], 'Provider media client');
        expect(request.headers.containsKey('Authorization'), isFalse);
        return _flac();
      }
      expect(uri.queryParameters['quality'], 'LOSSLESS');
      expect(uri.queryParameters['key'], 'test-secret');
      if (uri.path.endsWith('/search')) {
        expect(uri.queryParameters['q'], 'signal demo artist');
        return _json({
          'tracks': [_song('id/with symbols &+')],
        });
      }
      expect(uri.pathSegments, ['api', 'stream', 'id/with symbols &+']);
      return _json({
        'url': 'https://cdn.example/signed?expires=123',
        'mimeType': 'audio/flac',
        'manifest': 'none',
        'headers': {
          'User-Agent': 'Provider media client',
          'Authorization': 'addon-controlled credential',
        },
      });
    });
    final resolver = AudioExtensionResolver(transport: transport);
    addTearDown(resolver.dispose);
    final extension = await resolver.load(
      'https://addon.example/api/manifest.json?key=test-secret',
    );

    final audio = await resolver.findUpgrade(_track, extensions: [extension]);

    expect(audio?.source, AudioStreamSource.audioExtension);
    expect(audio?.streamUrl, 'https://cdn.example/signed?expires=123');
    expect(audio?.formatId, matches(r'^[a-f0-9]{64}$'));
    expect(audio?.codec, 'flac');
    expect(audio?.streamExtension, 'flac');
    expect(audio?.streamMimeType, 'audio/flac');
    expect(audio?.sampleRate, 44100);
    expect(audio?.bitDepth, 16);
    expect(audio?.channels, 2);
    expect(audio?.bitrate, 800000);
    expect(audio?.httpHeaders, {'User-Agent': 'Provider media client'});
    expect(transport.requests, hasLength(4));
  });

  test(
    'looks past Hi-Res, previews and different recordings for a CD match',
    () async {
      final transport = _Transport((request) {
        return switch (request.uri.path) {
          '/manifest.json' => _json({
            ..._manifest,
            'resources': ['search'],
          }),
          '/search' => _json({
            'tracks': [
              _song('a0', title: 'Signal (Live)', media: 'different'),
              _song('a1', media: 'hires'),
              _song('a2', media: 'preview'),
              _song('a3', media: 'cd'),
            ],
          }),
          '/hires' => _flac(bitDepth: 24, sampleRate: 96000),
          '/preview' => _flac(seconds: 30),
          '/cd' => _flac(),
          final path => throw StateError('Unexpected path $path'),
        };
      });
      final resolver = AudioExtensionResolver(transport: transport);
      addTearDown(resolver.dispose);
      final extension = await resolver.load('https://addon.example');

      final audio = await resolver.findUpgrade(_track, extensions: [extension]);

      expect(audio?.streamUrl, 'https://cdn.example/cd');
      expect(transport.requests.map((request) => request.uri.path), [
        '/manifest.json',
        '/search',
        '/hires',
        '/preview',
        '/cd',
      ]);
    },
  );

  test('skips disabled and streaming-only sources for downloads', () async {
    final transport = _Transport((request) {
      if (request.uri.host == 'disabled.example') {
        return _json(_manifest);
      }
      return _json({..._manifest, 'allowDownloads': 0});
    });
    final resolver = AudioExtensionResolver(transport: transport);
    addTearDown(resolver.dispose);
    final disabled = await resolver.load('https://disabled.example');
    final streamingOnly = await resolver.load('https://addon.example');

    expect(
      await resolver.findUpgrade(
        _track,
        extensions: [disabled.copyWith(enabled: false), streamingOnly],
        forDownload: true,
      ),
      isNull,
    );
    expect(transport.requests, hasLength(2));
  });

  for (final (seconds, extraSamples, accepted) in [
    (177, 0, true),
    (183, 0, true),
    (177, -1, false),
    (183, 1, false),
  ]) {
    test(
      'checks actual FLAC duration at ${seconds}s + $extraSamples samples',
      () async {
        final transport = _Transport((request) {
          return switch (request.uri.path) {
            '/manifest.json' => _json({
              ..._manifest,
              'resources': ['search'],
            }),
            '/search' => _json({
              'tracks': [_song('recording', media: 'cd')],
            }),
            '/cd' => _flac(seconds: seconds, extraSamples: extraSamples),
            final path => throw StateError('Unexpected path $path'),
          };
        });
        final resolver = AudioExtensionResolver(transport: transport);
        addTearDown(resolver.dispose);
        final extension = await resolver.load('https://addon.example');

        final audio = await resolver.findUpgrade(
          _track,
          extensions: [extension],
        );

        expect(audio?.streamUrl, accepted ? 'https://cdn.example/cd' : isNull);
        expect(
          transport.requests.any((request) => request.uri.path == '/cd'),
          isTrue,
        );
      },
    );
  }

  test('does not continue resolving after the caller changes songs', () async {
    var current = true;
    final transport = _Transport((request) {
      if (request.uri.path == '/manifest.json') return _json(_manifest);
      expect(request.uri.path, '/search');
      current = false;
      return _json({
        'tracks': [_song('result')],
      });
    });
    final resolver = AudioExtensionResolver(transport: transport);
    addTearDown(resolver.dispose);

    final extension = await resolver.load('https://addon.example');
    expect(
      await resolver.findUpgrade(
        _track,
        extensions: [extension],
        shouldContinue: () => current,
      ),
      isNull,
    );
    expect(transport.requests, hasLength(2));
  });

  for (final scenario in [
    (
      flags: {'bitchordAuth': true, 'checkValidLossless': 1},
      reason: AudioExtensionError.officialClientOnly,
    ),
    (
      flags: {'checkValidLossless': '1'},
      reason: AudioExtensionError.outputRequired,
    ),
  ]) {
    test('reports ${scenario.reason.name} without probing audio', () async {
      final transport = _Transport((request) {
        expect(request.uri.path, '/manifest.json');
        return _json({..._manifest, ...scenario.flags});
      });
      final resolver = AudioExtensionResolver(transport: transport);
      addTearDown(resolver.dispose);

      await expectLater(
        resolver.loadSources('https://restricted.example'),
        throwsA(_error(scenario.reason)),
      );
      expect(transport.requests, hasLength(1));
    });
  }

  test(
    'distinguishes generic HTTP authentication from invalid input',
    () async {
      final transport = _Transport((request) => _response(401));
      final resolver = AudioExtensionResolver(transport: transport);
      addTearDown(resolver.dispose);

      await expectLater(
        resolver.loadSources('https://restricted.example'),
        throwsA(_error(AudioExtensionError.restricted)),
      );
      await expectLater(
        resolver.loadSources('file:///manifest.json'),
        throwsA(_error(AudioExtensionError.invalidUrl)),
      );
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'does not interpret a Mornye repository as an HTTP audio source',
    () async {
      final transport = _Transport(
        (request) => _json({
          'extensions': [
            {'id': 'demo', 'download_url': 'https://addon.example/demo.sflx'},
          ],
        }),
      );
      final resolver = AudioExtensionResolver(transport: transport);
      addTearDown(resolver.dispose);

      await expectLater(
        resolver.load('https://mornye.example/registry.json'),
        throwsA(_error(AudioExtensionError.unsupported)),
      );
      expect(transport.requests.single.uri.path, '/registry.json');
    },
  );

  test('rejects an executable module index and package URLs', () async {
    final transport = _Transport(
      (request) => _json({
        'id': 'demo',
        'category:music': [
          {'id': 'demo-js', 'type': 'MODULE', 'download': 'modules/demo.js'},
        ],
      }),
    );
    final resolver = AudioExtensionResolver(transport: transport);
    addTearDown(resolver.dispose);

    await expectLater(
      resolver.loadSources('https://addons.example/manifest.json'),
      throwsA(_error(AudioExtensionError.moduleIndex)),
    );
    for (final path in ['/demo.sflx', '/module.js']) {
      await expectLater(
        resolver.loadSources('https://addons.example$path'),
        throwsA(_error(AudioExtensionError.unsupported)),
      );
    }
    expect(transport.requests.single.uri.path, '/manifest.json');
  });

  for (final allowDownloads in [false, true]) {
    test(
      'imports available WioLand HTTP add-ons with catalog allowDownloads=$allowDownloads',
      () async {
        final transport = _Transport((request) {
          final uri = request.uri;
          return switch ((uri.host, uri.path)) {
            ('catalog.example', '/bitchord/manifest.json') => _json({
              ..._wioLandIndex,
              'allowDownloads': allowDownloads ? 1 : 0,
            }),
            ('catalog.example', '/bitchord/sources.json') => _json([
              _catalogSource('public', 'https://public.example/podcast'),
              _catalogSource('streaming-only', 'https://streaming.example'),
              _catalogSource('official-only', 'https://official.example'),
              _catalogSource('unavailable', 'https://unavailable.example'),
              _catalogSource('module', 'https://legacy.example', type: 'hifi'),
              _catalogSource('unrelated', 'https://unrelated.example'),
              _catalogSource('insecure', 'http://insecure.example'),
            ]),
            ('public.example', '/podcast/manifest.json') => _json({
              ..._manifest,
              'id': 'public',
            }),
            ('streaming.example', '/manifest.json') => _json({
              ..._manifest,
              'id': 'streaming-only',
              'allowDownloads': 0,
            }),
            ('official.example', '/manifest.json') => _json({
              ..._manifest,
              'id': 'official-only',
              'bitchordAuth': true,
            }),
            ('unavailable.example', '/manifest.json') => _response(503),
            final unexpected => throw StateError(
              'Unexpected request $unexpected',
            ),
          };
        });
        final resolver = AudioExtensionResolver(transport: transport);
        addTearDown(resolver.dispose);

        final extensions = await resolver.loadSources(
          'https://catalog.example/bitchord/manifest.json,',
        );

        expect(extensions.map((extension) => extension.id), [
          'public',
          'streaming-only',
        ]);
        expect(extensions.first.allowDownloads, allowDownloads);
        expect(extensions.last.allowDownloads, isFalse);
        expect(transport.requests, hasLength(6));
        if (!allowDownloads) {
          expect(
            await resolver.findUpgrade(
              _track,
              extensions: extensions,
              forDownload: true,
            ),
            isNull,
          );
          expect(transport.requests, hasLength(6));
        }
      },
    );
  }

  test('uses the public Monochrome API listed in a WioLand catalog', () async {
    const recordingId = '157949442196242432';
    final transport = _Transport((request) {
      final uri = request.uri;
      switch ((uri.host, uri.path)) {
        case ('catalog.example', '/bitchord/manifest.json'):
          return _json({
            'id': 'art.wiochord.lossless',
            'category:music': [_catalogModule('dial-monochrome')],
          });
        case ('catalog.example', '/bitchord/sources.json'):
          return _json([
            _catalogSource(
              'dial-monochrome',
              'https://tracks.monochrome.st',
              type: 'monochrome',
            ),
          ]);
        case ('tracks.monochrome.st', '/search/tracks'):
          expect(uri.queryParameters, {
            'q': 'signal demo artist',
            'limit': '20',
          });
          return _json({
            'tracks': [
              {
                'id': recordingId,
                'title': 'Signal',
                'artistNames': ['Demo Artist'],
                'duration': 180200,
                'playable': true,
              },
            ],
          });
        case ('tracks.monochrome.st', '/track/$recordingId'):
          expect(request.maximumBytes, 42);
          expect(request.readPrefix, isTrue);
          expect(request.headers['Range'], 'bytes=0-41');
          return _flac();
        default:
          throw StateError('Unexpected request $uri');
      }
    });
    final resolver = AudioExtensionResolver(transport: transport);
    addTearDown(resolver.dispose);

    final sources = await resolver.loadSources(
      'https://catalog.example/bitchord/manifest.json,',
    );
    expect(sources.single.protocol, AudioExtensionProtocol.monochrome);
    final restored = AudioExtension.fromJson(
      jsonDecode(jsonEncode(sources.single.toJson())),
    );
    expect(restored?.protocol, AudioExtensionProtocol.monochrome);
    final audio = await resolver.findUpgrade(_track, extensions: [restored!]);

    expect(audio?.streamUrl, 'https://tracks.monochrome.st/track/$recordingId');
    expect(audio?.bitDepth, 16);
    expect(transport.requests.map((request) => request.uri.path), [
      '/bitchord/manifest.json',
      '/bitchord/sources.json',
      '/search/tracks',
      '/track/$recordingId',
    ]);
  });

  test(
    'reports an unavailable WioLand catalog when every add-on is closed',
    () async {
      final transport = _Transport((request) {
        final uri = request.uri;
        return switch ((uri.host, uri.path)) {
          ('catalog.example', '/manifest.json') => _json({
            'id': 'art.wiojelt.bitchord.modules',
            'category:music': [_catalogModule('official-only')],
          }),
          ('catalog.example', '/sources.json') => _json([
            _catalogSource('official-only', 'https://official.example'),
          ]),
          ('official.example', '/manifest.json') => _json({
            ..._manifest,
            'bitchordAuth': true,
          }),
          final unexpected => throw StateError(
            'Unexpected request $unexpected',
          ),
        };
      });
      final resolver = AudioExtensionResolver(transport: transport);
      addTearDown(resolver.dispose);

      await expectLater(
        resolver.loadSources('https://catalog.example/manifest.json'),
        throwsA(_error(AudioExtensionError.noAvailableSources)),
      );
    },
  );
}

const _track = TrackInfo(
  id: 'yt-id',
  title: 'Signal',
  artist: 'Demo Artist',
  url: 'https://example.com/track',
  duration: Duration(minutes: 3),
);

const _manifest = {
  'id': 'demo',
  'name': 'Demo audio',
  'resources': ['search', 'stream'],
};

final _wioLandIndex = {
  'id': 'art.wiochord.lossless',
  'category:music': [
    for (final id in [
      'public',
      'streaming-only',
      'official-only',
      'unavailable',
      'module',
      'insecure',
    ])
      _catalogModule(id),
  ],
};

Map<String, Object> _catalogModule(String id) => {
  'id': 'wiojelt-$id',
  'name': id,
  'type': 'MODULE',
  'download': 'modules/$id.js',
};

Map<String, Object> _catalogSource(
  String id,
  String url, {
  String type = 'addon',
}) => {'id': id, 'name': id, 'type': type, 'url': url};

Map<String, Object> _song(
  String id, {
  String title = 'Signal',
  String? media,
}) => {
  'id': id,
  'title': title,
  'artist': 'Demo Artist',
  'duration': 180.2,
  if (media != null) 'streamURL': 'https://cdn.example/$media',
};

BoundedAudioHttpResponse _json(Object data) => BoundedAudioHttpResponse(
  statusCode: 200,
  body: Uint8List.fromList(utf8.encode(jsonEncode(data))),
);

BoundedAudioHttpResponse _response(int status) =>
    BoundedAudioHttpResponse(statusCode: status, body: Uint8List(0));

BoundedAudioHttpResponse _flac({
  int sampleRate = 44100,
  int bitDepth = 16,
  int seconds = 180,
  int extraSamples = 0,
}) {
  final bytes = Uint8List(42)
    ..setRange(0, 4, ascii.encode('fLaC'))
    ..[4] = 0x80
    ..[7] = 34;
  ByteData.sublistView(bytes).setUint64(
    18,
    (sampleRate << 44) |
        (1 << 41) |
        ((bitDepth - 1) << 36) |
        (seconds * sampleRate + extraSamples),
  );
  return BoundedAudioHttpResponse(
    statusCode: 206,
    body: bytes,
    headers: const {'content-range': 'bytes 0-41/18000000'},
  );
}

Matcher _error(AudioExtensionError reason) => isA<AudioExtensionException>()
    .having((error) => error.reason, 'reason', reason);

typedef _Request = ({
  Uri uri,
  Map<String, String> headers,
  int maximumBytes,
  bool readPrefix,
});

class _Transport implements BoundedAudioHttpTransport {
  _Transport(this.respond);

  final BoundedAudioHttpResponse Function(_Request) respond;
  final requests = <_Request>[];

  @override
  Future<BoundedAudioHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maximumBytes = 512 * 1024,
    bool readPrefix = false,
    Duration? timeout,
  }) async {
    final request = (
      uri: uri,
      headers: headers,
      maximumBytes: maximumBytes,
      readPrefix: readPrefix,
    );
    requests.add(request);
    return respond(request);
  }

  @override
  Future<void> close() async {}
}
