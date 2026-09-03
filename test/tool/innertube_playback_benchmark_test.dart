import 'package:bstream_music/services/youtube_music/innertube_transport.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_profile.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_player_response_parser.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_validator.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_video_id.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/innertube_playback_benchmark.dart';

void main() {
  group('raw InnerTube benchmark classification', () {
    test('reports capability layers as blocked instead of failed', () {
      expect(
        rawCapabilityBlockReason(InnerTubeClientRegistry.androidSdkless),
        isNull,
      );
      expect(
        rawCapabilityBlockReason(InnerTubeClientRegistry.tv),
        'EJS required',
      );
      expect(
        rawCapabilityBlockReason(InnerTubeClientRegistry.web),
        'EJS + WebPO required',
      );
      expect(
        rawCapabilityBlockReason(InnerTubeClientRegistry.ios),
        'platform PO required',
      );
    });

    test('excludes blocked samples from pass/fail statistics', () {
      final result = RawProfileResult(
        InnerTubeClientRegistry.androidSdkless,
        <RawBenchmarkSample>[
          _valid(350),
          RawBenchmarkSample.blocked('EJS challenge encountered'),
          RawBenchmarkSample.blocked('EJS challenge encountered'),
        ],
      );

      expect(result.successes, 1);
      expect(result.evaluated, 1);
      expect(result.failures, 0);
      expect(result.blocked, 2);
      expect(result.medianMilliseconds, 350);
      expect(result.blockReasons, <String>{'EJS challenge encountered'});
    });

    test(
      'does not recommend capability-gated or partially skipped profiles',
      () {
        final recommended = selectRawRecommendedProfile(<RawProfileResult>[
          RawProfileResult(InnerTubeClientRegistry.tv, <RawBenchmarkSample>[
            _valid(100),
          ]),
          RawProfileResult(
            InnerTubeClientRegistry.visionOS,
            <RawBenchmarkSample>[
              _valid(200),
              RawBenchmarkSample.blocked('unexpected EJS challenge'),
            ],
          ),
          RawProfileResult(
            InnerTubeClientRegistry.androidSdkless,
            <RawBenchmarkSample>[_valid(400), _valid(300)],
          ),
        ]);

        expect(recommended, InnerTubeClientRegistry.androidSdkless);
      },
    );

    test(
      'orders correctness before latency without treating skips as fails',
      () {
        final perfect = RawProfileResult(
          InnerTubeClientRegistry.visionOS,
          <RawBenchmarkSample>[_valid(900), _valid(800)],
        );
        final fasterButFailed = RawProfileResult(
          InnerTubeClientRegistry.androidSdkless,
          <RawBenchmarkSample>[
            _valid(100),
            RawBenchmarkSample.failed(
              'rejected',
              const Duration(milliseconds: 1),
            ),
          ],
        );
        final ranking = <RawProfileResult>[fasterButFailed, perfect]
          ..sort(compareRawProfileResults);

        expect(ranking.first, same(perfect));
      },
    );

    test(
      'bootstraps visitor data without exposing it to sample output',
      () async {
        final transport = _FakeTransport(
          getResponse: const InnerTubeHttpResponse(
            statusCode: 200,
            body:
                '{"INNERTUBE_API_KEY":"key",'
                '"INNERTUBE_CLIENT_VERSION":"1.0",'
                '"VISITOR_DATA":"private-visitor"}',
          ),
        );

        final visitorData = await bootstrapRawBenchmarkVisitorData(transport);

        expect(visitorData, 'private-visitor');
        expect(transport.getCalls, 1);
        expect(transport.lastGetUri?.host, 'music.youtube.com');
        expect(transport.lastGetHeaders, contains('user-agent'));
      },
    );

    test(
      'sends visitor identity and HTML5 playback context before deep probe',
      () async {
        final transport = _FakeTransport(
          postResponse: const InnerTubeHttpResponse(
            statusCode: 200,
            body: r'''
            {
              "playabilityStatus": {"status": "OK"},
              "videoDetails": {"videoId": "dQw4w9WgXcQ"},
              "streamingData": {
                "expiresInSeconds": "3600",
                "adaptiveFormats": [{
                  "itag": 251,
                  "url": "https://media.test/audio?expire=9999999999",
                  "mimeType": "audio/webm; codecs=\"opus\"",
                  "bitrate": 128000,
                  "audioQuality": "AUDIO_QUALITY_MEDIUM",
                  "contentLength": "5000000"
                }]
              }
            }
            ''',
          ),
        );
        final validator = _FakeValidator();

        final sample = await measureRawInnerTubeProfile(
          transport,
          validator,
          const InnerTubePlayerResponseParser(),
          InnerTubeVideoId.extract('dQw4w9WgXcQ')!,
          InnerTubeClientRegistry.androidSdkless,
          visitorData: 'private-visitor',
        );

        expect(sample.outcome, RawBenchmarkOutcome.valid);
        expect(
          transport.lastPostHeaders?['X-Goog-Visitor-Id'],
          'private-visitor',
        );
        final body = transport.lastPostBody! as Map<String, Object?>;
        final context = body['context']! as Map<String, Object?>;
        final client = context['client']! as Map<String, Object?>;
        expect(client['visitorData'], 'private-visitor');
        final playback = body['playbackContext']! as Map<String, Object?>;
        final content =
            playback['contentPlaybackContext']! as Map<String, Object?>;
        expect(content['html5Preference'], 'HTML5_PREF_WANTS');
        expect(validator.calls, 1);
        expect(validator.lastHeaders, contains('Origin'));
      },
    );

    test('does not request gated profiles in a raw diagnostic', () async {
      final transport = _FakeTransport();
      final validator = _FakeValidator();

      final sample = await measureRawInnerTubeProfile(
        transport,
        validator,
        const InnerTubePlayerResponseParser(),
        InnerTubeVideoId.extract('dQw4w9WgXcQ')!,
        InnerTubeClientRegistry.web,
        visitorData: 'private-visitor',
      );

      expect(sample.outcome, RawBenchmarkOutcome.blocked);
      expect(transport.postCalls, 0);
      expect(validator.calls, 0);
    });
  });
}

RawBenchmarkSample _valid(int milliseconds) => RawBenchmarkSample(
  outcome: RawBenchmarkOutcome.valid,
  requestElapsed: Duration(milliseconds: milliseconds ~/ 2),
  totalElapsed: Duration(milliseconds: milliseconds),
);

final class _FakeTransport implements InnerTubeTransport {
  _FakeTransport({this.getResponse, this.postResponse});

  final InnerTubeHttpResponse? getResponse;
  final InnerTubeHttpResponse? postResponse;
  int getCalls = 0;
  int postCalls = 0;
  Uri? lastGetUri;
  Map<String, String>? lastGetHeaders;
  Map<String, String>? lastPostHeaders;
  Object? lastPostBody;

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    getCalls += 1;
    lastGetUri = uri;
    lastGetHeaders = headers;
    return getResponse ??
        const InnerTubeHttpResponse(statusCode: 500, body: 'unconfigured');
  }

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) async {
    postCalls += 1;
    lastPostHeaders = headers;
    lastPostBody = body;
    return postResponse ??
        const InnerTubeHttpResponse(statusCode: 500, body: 'unconfigured');
  }

  @override
  void close() {}
}

final class _FakeValidator implements InnerTubeStreamValidator {
  int calls = 0;
  Map<String, String>? lastHeaders;

  @override
  Future<InnerTubeStreamProbe> validate(
    Uri uri, {
    required Map<String, String> headers,
    int? contentLength,
  }) async {
    calls += 1;
    lastHeaders = headers;
    return const InnerTubeStreamProbe(
      statusCode: 206,
      elapsed: Duration(milliseconds: 10),
      probedOffset: 3 * 1024 * 1024,
      receivedBytes: 1024,
      contentLength: 5000000,
    );
  }
}
