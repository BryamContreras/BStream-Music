import 'dart:convert';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/downloader/innertube_audio_resolver.dart';
import 'package:bstream_music/services/youtube_music/innertube_transport.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_profile.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_router.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_playback_service.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps InnerTube transport metadata to the resolver contract', () async {
    final transport = _Transport();
    final playback = InnerTubePlaybackService(
      transport: transport,
      validator: _Validator(),
      router: InnerTubeClientRouter(
        profiles: const [
          InnerTubeClientRegistry.androidSdkless,
          InnerTubeClientRegistry.visionOS,
        ],
      ),
      maxRequestAttempts: 1,
    );
    final resolver = InnerTubeAudioResolver(playback);
    addTearDown(() async {
      await resolver.dispose();
      await playback.dispose();
    });

    final result = await resolver.resolve(
      const TrackInfo(
        id: 'dQw4w9WgXcQ',
        title: 'Test',
        artist: 'BStream',
        url: 'https://youtu.be/dQw4w9WgXcQ',
      ),
    );

    expect(result.source, AudioStreamSource.innerTube);
    expect(result.streamExtension, 'm4a');
    expect(result.streamMimeType, 'audio/mp4');
    expect(result.formatId, '140');
    expect(result.codec, 'mp4a.40.2');
    expect(result.clientProfileKey, 'androidSdkless');
    expect(result.expiresAt, isNotNull);
    expect(result.expiresAt!.isAfter(DateTime.now()), isTrue);
    expect(transport.clientIds, ['3']);
  });

  test('fallback mode skips the benchmark default client', () async {
    final transport = _Transport();
    final playback = InnerTubePlaybackService(
      transport: transport,
      validator: _Validator(),
      router: InnerTubeClientRouter(
        profiles: const [
          InnerTubeClientRegistry.androidSdkless,
          InnerTubeClientRegistry.visionOS,
        ],
      ),
      maxRequestAttempts: 1,
    );
    final resolver = InnerTubeAudioResolver(playback);
    addTearDown(() async {
      await resolver.dispose();
      await playback.dispose();
    });

    final result = await resolver.resolveWithMode(
      const TrackInfo(
        id: 'dQw4w9WgXcQ',
        title: 'Test',
        artist: 'BStream',
        url: 'dQw4w9WgXcQ',
      ),
      mode: AudioResolutionMode.fallbackOnly,
    );

    expect(result.source, AudioStreamSource.innerTubeFallback);
    expect(result.clientProfileKey, 'visionOS');
    expect(transport.clientIds, ['101']);
  });

  test(
    'fallback mode also excludes the client of the rejected stream',
    () async {
      final transport = _Transport();
      final playback = InnerTubePlaybackService(
        transport: transport,
        validator: _Validator(),
        router: InnerTubeClientRouter(
          profiles: const [
            InnerTubeClientRegistry.androidSdkless,
            InnerTubeClientRegistry.visionOS,
            _secondaryProfile,
          ],
        ),
        maxRequestAttempts: 1,
      );
      final resolver = InnerTubeAudioResolver(playback);
      addTearDown(() async {
        await resolver.dispose();
        await playback.dispose();
      });

      final result = await resolver.resolveWithMode(
        const TrackInfo(
          id: 'dQw4w9WgXcQ',
          title: 'Test',
          artist: 'BStream',
          url: 'not-a-youtube-url',
          streamClientProfileKey: 'visionOS',
        ),
        mode: AudioResolutionMode.fallbackOnly,
      );

      expect(result.clientProfileKey, 'secondary');
      expect(transport.clientIds, ['7']);
    },
  );

  test('reports fallback source when fallback-only resolution fails', () async {
    final transport = _Transport(error: StateError('fallback unavailable'));
    final playback = InnerTubePlaybackService(
      transport: transport,
      validator: _Validator(),
      router: InnerTubeClientRouter(
        profiles: const [
          InnerTubeClientRegistry.androidSdkless,
          InnerTubeClientRegistry.visionOS,
        ],
      ),
      maxRequestAttempts: 1,
    );
    final resolver = InnerTubeAudioResolver(playback);
    addTearDown(() async {
      await resolver.dispose();
      await playback.dispose();
    });
    AudioStreamSource? failedSource;

    await expectLater(
      resolver.resolveWithMode(
        const TrackInfo(
          id: 'dQw4w9WgXcQ',
          title: 'Test',
          artist: 'BStream',
          url: 'dQw4w9WgXcQ',
        ),
        mode: AudioResolutionMode.fallbackOnly,
        onResolverFailure: (source, _) => failedSource = source,
      ),
      throwsA(isA<AudioStreamResolverException>()),
    );

    expect(failedSource, AudioStreamSource.innerTubeFallback);
    expect(transport.clientIds, ['101']);
  });
}

const _secondaryProfile = InnerTubeClientProfile(
  key: 'secondary',
  clientName: 'TVHTML5',
  clientVersion: '1.0',
  clientId: 7,
  host: 'www.youtube.com',
  origin: 'https://www.youtube.com',
  userAgent: 'BStream test',
  capabilities: InnerTubeClientCapabilities(
    playerJavaScript: InnerTubePlayerJavaScriptRequirement.notRequired,
    playerPoToken: InnerTubePoTokenRequirement.notRequired,
    streamingDataPoToken: InnerTubePoTokenRequirement.notRequired,
    poTokenProvider: InnerTubePoTokenProvider.none,
  ),
  availability: InnerTubeClientAvailability.stable,
);

final class _Transport implements InnerTubeTransport {
  _Transport({this.error});

  final Object? error;
  final List<String> clientIds = [];

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) async {
    clientIds.add(headers['X-YouTube-Client-Name']!);
    final failure = error;
    if (failure != null) throw failure;
    return InnerTubeHttpResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'playabilityStatus': <String, Object?>{'status': 'OK'},
        'videoDetails': <String, Object?>{'videoId': 'dQw4w9WgXcQ'},
        'streamingData': <String, Object?>{
          'expiresInSeconds': '1200',
          'adaptiveFormats': <Object?>[
            <String, Object?>{
              'itag': 140,
              'url': 'https://media.example/audio',
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'contentLength': '2000000',
            },
          ],
        },
      }),
    );
  }

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) => throw UnimplementedError();

  @override
  void close() {}
}

final class _Validator implements InnerTubeStreamValidator {
  @override
  Future<InnerTubeStreamProbe> validate(
    Uri uri, {
    required Map<String, String> headers,
    int? contentLength,
  }) async => InnerTubeStreamProbe(
    statusCode: 206,
    elapsed: Duration.zero,
    probedOffset: 1024 * 1024,
    receivedBytes: 1,
    contentLength: contentLength,
  );
}
