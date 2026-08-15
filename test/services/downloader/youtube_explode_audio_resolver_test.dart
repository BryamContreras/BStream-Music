import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/downloader/youtube_audio_stream_selector.dart';
import 'package:bstream_music/services/downloader/youtube_explode_audio_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  group('YoutubeExplodeAudioResolver', () {
    test('throws when the URL is not a YouTube URL', () async {
      final resolver = YoutubeExplodeAudioResolver();
      addTearDown(resolver.dispose);
      expect(
        () => resolver.resolve(
          const TrackInfo(
            id: 'soundcloud-1',
            title: 'Track',
            artist: 'Artist',
            url: 'https://soundcloud.com/artist/track',
          ),
        ),
        throwsA(isA<AudioStreamResolverException>()),
      );
    });

    test('throws when the URL is empty', () async {
      final resolver = YoutubeExplodeAudioResolver();
      addTearDown(resolver.dispose);
      expect(
        () => resolver.resolve(
          const TrackInfo(id: '', title: 'Track', artist: 'Artist', url: ''),
        ),
        throwsA(isA<AudioStreamResolverException>()),
      );
    });
  });

  group('staged YouTube manifest resolution', () {
    test('uses maintained clients in a deterministic order', () {
      final attempts = defaultYoutubeManifestAttempts;

      expect(attempts.map((attempt) => attempt.name), [
        'visionOS+watch',
        'visionOS',
        'iOS',
        'androidVr',
      ]);
      expect(_clientVersion(attempts[0].client), '1.02');
      expect(_clientVersion(attempts[1].client), '1.02');
      expect(_clientVersion(attempts[2].client), '21.26.4');
      expect(_clientVersion(attempts[3].client), '1.65.10');
      expect(attempts.map((attempt) => attempt.requireWatchPage), [
        true,
        false,
        false,
        false,
      ]);
    });

    test('provides fresh mutable nested payloads for every attempt list', () {
      final first = defaultYoutubeManifestAttempts;
      final firstIosClient =
          first[2].client.payload['context']['client'] as Map<String, dynamic>;

      // youtube_explode_dart's iOS path performs this same nested mutation
      // after fetching visitor data. This used to throw because our payload
      // was built from const maps.
      firstIosClient['visitorData'] = 'visitor-from-first-session';
      expect(firstIosClient['visitorData'], 'visitor-from-first-session');

      final second = defaultYoutubeManifestAttempts;
      final secondIosClient =
          second[2].client.payload['context']['client'] as Map<String, dynamic>;

      expect(secondIosClient, isNot(same(firstIosClient)));
      expect(secondIosClient, isNot(contains('visitorData')));
      expect(second[0].client, isNot(same(first[0].client)));
      expect(second[3].client, isNot(same(first[3].client)));
    });

    test('stops after the first client returns usable audio', () async {
      final calls = <String>[];
      final validated = <int>[];

      final result = await resolvePreferredYoutubeAudioStream(
        videoId: VideoId('abcdefghijk'),
        loadManifest: (videoId, client, requireWatchPage) async {
          calls.add('${_clientName(client)}:$requireWatchPage');
          return StreamManifest([_audioStream(tag: 140)]);
        },
        validateSelectedStream: (stream) async {
          validated.add(stream.tag);
        },
      );

      expect(result.tag, 140);
      expect(calls, ['VISIONOS:true']);
      expect(validated, [140]);
    });

    test(
      'continues when the exact selected AAC is 403 after muxed validation',
      () async {
        final manifestCalls = <String>[];
        final validated = <int>[];
        var manifestIndex = 0;
        final attempts = [
          YoutubeManifestAttempt(name: 'first', client: youtubeVisionOsClient),
          YoutubeManifestAttempt(name: 'second', client: youtubeVisionOsClient),
        ];

        final result = await resolvePreferredYoutubeAudioStream(
          videoId: VideoId('abcdefghijk'),
          attempts: attempts,
          loadManifest: (videoId, client, requireWatchPage) async {
            manifestIndex++;
            manifestCalls.add('manifest-$manifestIndex');
            // The package's internal HEAD checks the first (muxed) stream. A
            // successful muxed URL must not vouch for the AAC selected below.
            return StreamManifest([
              _muxedStream(tag: 18),
              _audioStream(tag: manifestIndex == 1 ? 140 : 141),
            ]);
          },
          validateSelectedStream: (stream) async {
            validated.add(stream.tag);
            if (stream.tag == 140) {
              throw const YoutubePlaybackStreamValidationException(
                'The selected audio stream was rejected.',
                statusCode: HttpStatus.forbidden,
              );
            }
          },
        );

        expect(result.tag, 141);
        expect(manifestCalls, ['manifest-1', 'manifest-2']);
        expect(validated, [140, 141]);
      },
    );

    test(
      'continues after a client-specific VideoUnplayableException',
      () async {
        final calls = <String>[];

        final result = await resolvePreferredYoutubeAudioStream(
          videoId: VideoId('abcdefghijk'),
          loadManifest: (videoId, client, requireWatchPage) async {
            final name = _clientName(client);
            calls.add('$name:$requireWatchPage');
            if (requireWatchPage) {
              throw VideoUnplayableException('Unavailable for this client.');
            }
            return StreamManifest([_audioStream(tag: 251, codec: 'opus')]);
          },
        );

        expect(result.tag, 251);
        expect(calls, ['VISIONOS:true', 'VISIONOS:false']);
      },
    );

    test('continues when playback only receives fragmented audio', () async {
      var callCount = 0;
      final attempts = [
        YoutubeManifestAttempt(name: 'first', client: youtubeVisionOsClient),
        YoutubeManifestAttempt(name: 'second', client: youtubeCurrentIosClient),
      ];

      final result = await resolvePreferredYoutubeAudioStream(
        videoId: VideoId('abcdefghijk'),
        requireDirectUrl: true,
        attempts: attempts,
        loadManifest: (videoId, client, requireWatchPage) async {
          callCount++;
          return StreamManifest([
            _audioStream(tag: 140 + callCount, fragmented: callCount == 1),
          ]);
        },
      );

      expect(result.tag, 142);
      expect(callCount, 2);
    });

    test(
      'uses the context-free VisionOS retry before mobile edge fallbacks',
      () async {
        final calls = <String>[];

        final result = await resolvePreferredYoutubeAudioStream(
          videoId: VideoId('abcdefghijk'),
          loadManifest: (videoId, client, requireWatchPage) async {
            calls.add('${_clientName(client)}:$requireWatchPage');
            if (requireWatchPage || _clientName(client) != 'VISIONOS') {
              throw StateError('Attempt unavailable.');
            }
            return StreamManifest([_audioStream(tag: 140)]);
          },
        );

        expect(result.tag, 140);
        expect(calls, ['VISIONOS:true', 'VISIONOS:false']);
      },
    );

    test(
      'reports every attempted client when none can resolve audio',
      () async {
        await expectLater(
          resolvePreferredYoutubeAudioStream(
            videoId: VideoId('abcdefghijk'),
            attempts: [
              YoutubeManifestAttempt(
                name: 'vision',
                client: youtubeVisionOsClient,
              ),
              YoutubeManifestAttempt(
                name: 'ios',
                client: youtubeCurrentIosClient,
              ),
            ],
            loadManifest: (videoId, client, requireWatchPage) async {
              throw StateError(_clientName(client));
            },
          ),
          throwsA(
            isA<YoutubeAudioManifestException>().having(
              (error) => error.failures.map((failure) => failure.clientName),
              'attempted clients',
              ['vision', 'ios'],
            ),
          ),
        );
      },
    );
  });

  group('selected playback stream HTTP validation', () {
    test('accepts 206 with bytes and sends the requested headers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requestSeen = Completer<void>();
      late String? receivedRange;
      late String? receivedUserAgent;
      late String? receivedProbeHeader;
      server.listen((request) async {
        receivedRange = request.headers.value(HttpHeaders.rangeHeader);
        receivedUserAgent = request.headers.value(HttpHeaders.userAgentHeader);
        receivedProbeHeader = request.headers.value('x-bstream-probe');
        request.response
          ..statusCode = HttpStatus.partialContent
          ..contentLength = 2
          ..add(const [7, 8]);
        await request.response.close();
        if (!requestSeen.isCompleted) {
          requestSeen.complete();
        }
      });

      final validator = YoutubePlaybackStreamValidator(
        headers: const {
          HttpHeaders.userAgentHeader: 'BStream probe',
          'x-bstream-probe': 'same-headers',
        },
        timeout: const Duration(seconds: 2),
      );

      await validator.validate(_audioStream(tag: 140, url: _serverUrl(server)));
      await requestSeen.future;

      expect(receivedRange, 'bytes=0-1');
      expect(receivedUserAgent, 'BStream probe');
      expect(receivedProbeHeader, 'same-headers');
    });

    test('also accepts a 200 response when it contains bytes', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = 1
          ..add(const [1]);
        await request.response.close();
      });

      final validator = YoutubePlaybackStreamValidator(
        headers: const {},
        timeout: const Duration(seconds: 2),
      );

      await validator.validate(_audioStream(tag: 140, url: _serverUrl(server)));
    });

    test('rejects HTTP errors and an empty successful response', () async {
      for (final response in <({int status, bool writeBytes})>[
        (status: HttpStatus.forbidden, writeBytes: true),
        (status: HttpStatus.notFound, writeBytes: true),
        (status: HttpStatus.tooManyRequests, writeBytes: true),
        (status: HttpStatus.internalServerError, writeBytes: true),
        (status: HttpStatus.partialContent, writeBytes: false),
      ]) {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          request.response.statusCode = response.status;
          if (response.writeBytes) {
            request.response.add(const [1]);
          }
          await request.response.close();
        });
        final validator = YoutubePlaybackStreamValidator(
          headers: const {},
          timeout: const Duration(seconds: 2),
        );

        try {
          await expectLater(
            validator.validate(_audioStream(tag: 140, url: _serverUrl(server))),
            throwsA(
              isA<YoutubePlaybackStreamValidationException>().having(
                (error) => error.statusCode,
                'statusCode',
                response.status == HttpStatus.partialContent
                    ? isNull
                    : response.status,
              ),
            ),
          );
        } finally {
          await server.close(force: true);
        }
      }
    });

    test('times out while waiting for response headers', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requestSeen = Completer<void>();
      server.listen((request) {
        if (!requestSeen.isCompleted) {
          requestSeen.complete();
        }
        // Intentionally leave the response open. The validator must close its
        // client when the bounded probe expires.
      });

      final validator = YoutubePlaybackStreamValidator(
        headers: const {},
        timeout: const Duration(milliseconds: 40),
      );

      await expectLater(
        validator.validate(_audioStream(tag: 140, url: _serverUrl(server))),
        throwsA(
          isA<YoutubePlaybackStreamValidationException>().having(
            (error) => error.cause,
            'cause',
            isA<TimeoutException>(),
          ),
        ),
      );
      await requestSeen.future;
    });
  });
}

String _clientName(YoutubeApiClient client) {
  return client.payload['context']['client']['clientName'] as String;
}

String _clientVersion(YoutubeApiClient client) {
  return client.payload['context']['client']['clientVersion'] as String;
}

AudioOnlyStreamInfo _audioStream({
  required int tag,
  String codec = 'mp4a.40.2',
  bool fragmented = false,
  String? url,
}) {
  final container = codec == 'opus' ? 'webm' : 'mp4';
  return AudioOnlyStreamInfo.fromJson({
    'videoId': const {'value': 'abcdefghijk'},
    'tag': tag,
    'url': url ?? 'https://media.example/$tag',
    'container': {'name': container},
    'size': const {'totalBytes': 1024},
    'bitrate': const {'bitsPerSecond': 128000},
    'audioCodec': codec,
    'qualityLabel': 'audio',
    'fragments': fragmented
        ? const [
            {'path': '/fragment'},
          ]
        : const [],
    'codec': 'audio/$container; codecs="$codec"',
    'audioTrack': null,
  });
}

MuxedStreamInfo _muxedStream({required int tag}) {
  return MuxedStreamInfo.fromJson({
    'videoId': const {'value': 'abcdefghijk'},
    'tag': tag,
    'url': 'https://media.example/muxed-$tag',
    'container': const {'name': 'mp4'},
    'size': const {'totalBytes': 2048},
    'bitrate': const {'bitsPerSecond': 256000},
    'audioCodec': 'mp4a.40.2',
    'videoCodec': 'avc1.4d401e',
    'qualityLabel': '360p',
    'videoQuality': 'medium360',
    'videoResolution': const {'width': 640, 'height': 360},
    'framerate': const {'framesPerSecond': 30},
    'codec': 'video/mp4; codecs="avc1.4d401e, mp4a.40.2"',
  });
}

String _serverUrl(HttpServer server) {
  return 'http://${server.address.address}:${server.port}/videoplayback';
}
