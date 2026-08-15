import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/downloader/fallback_audio_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FallbackAudioResolver', () {
    test('does not start fallback after the request is superseded', () async {
      final primary = _FailingAudioResolver(
        error: StateError('primary unavailable'),
      );
      final fallback = _FakeAudioResolver(
        result: const AudioStreamResolution(
          source: AudioStreamSource.ytDlp,
          streamUrl: 'file:///tmp/fallback.m4a',
        ),
      );
      final resolver = FallbackAudioResolver([primary, fallback]);
      var active = true;

      await expectLater(
        resolver.resolveWithMode(
          const TrackInfo(
            id: 'video-id',
            title: 'Track',
            artist: 'Artist',
            url: 'https://www.youtube.com/watch?v=video-id',
          ),
          shouldContinue: () => active,
          onResolverFailure: (_, _) => active = false,
        ),
        throwsA(
          isA<AudioStreamResolverException>().having(
            (error) => error.message,
            'message',
            contains('superseded'),
          ),
        ),
      );

      expect(primary.resolveCalls, 1);
      expect(fallback.resolveCalls, 0);
    });

    test('returns the primary result when it succeeds', () async {
      final resolver = FallbackAudioResolver([
        _FakeAudioResolver(
          result: AudioStreamResolution(
            source: AudioStreamSource.youtubeExplode,
            streamUrl: 'https://media.example/primary.m4a',
          ),
        ),
        _FakeAudioResolver(
          result: AudioStreamResolution(
            source: AudioStreamSource.ytDlp,
            streamUrl: 'https://media.example/fallback.m4a',
          ),
        ),
      ]);
      final resolved = await resolver.resolve(
        const TrackInfo(
          id: 'video-id',
          title: 'Track',
          artist: 'Artist',
          url: 'https://www.youtube.com/watch?v=video-id',
        ),
      );
      expect(resolved.source, AudioStreamSource.youtubeExplode);
      expect(resolved.streamUrl, 'https://media.example/primary.m4a');
    });

    test(
      'falls back to the secondary resolver when the primary fails',
      () async {
        final resolver = FallbackAudioResolver([
          _FailingAudioResolver(error: Exception('boom')),
          _FakeAudioResolver(
            result: AudioStreamResolution(
              source: AudioStreamSource.ytDlp,
              streamUrl: 'https://media.example/fallback.m4a',
            ),
          ),
        ]);
        final resolved = await resolver.resolve(
          const TrackInfo(
            id: 'video-id',
            title: 'Track',
            artist: 'Artist',
            url: 'https://www.youtube.com/watch?v=video-id',
          ),
        );
        expect(resolved.source, AudioStreamSource.ytDlp);
        expect(resolved.streamUrl, 'https://media.example/fallback.m4a');
      },
    );

    test('falls back when the primary returns an empty URL', () async {
      final resolver = FallbackAudioResolver([
        _FakeAudioResolver(
          result: const AudioStreamResolution(
            source: AudioStreamSource.youtubeExplode,
            streamUrl: '',
          ),
        ),
        _FakeAudioResolver(
          result: AudioStreamResolution(
            source: AudioStreamSource.ytDlp,
            streamUrl: 'https://media.example/fallback.m4a',
          ),
        ),
      ]);
      final resolved = await resolver.resolve(
        const TrackInfo(
          id: 'video-id',
          title: 'Track',
          artist: 'Artist',
          url: 'https://www.youtube.com/watch?v=video-id',
        ),
      );
      expect(resolved.source, AudioStreamSource.ytDlp);
    });

    test('fallback-only mode skips the primary resolver', () async {
      final primary = _FailingAudioResolver(error: Exception('primary'));
      final fallback = _FakeAudioResolver(
        result: const AudioStreamResolution(
          source: AudioStreamSource.ytDlp,
          streamUrl: 'https://media.example/fallback.m4a',
        ),
      );
      final resolver = FallbackAudioResolver([primary, fallback]);

      final resolved = await resolver.resolveWithMode(
        const TrackInfo(
          id: 'video-id',
          title: 'Track',
          artist: 'Artist',
          url: 'https://www.youtube.com/watch?v=video-id',
        ),
        mode: AudioResolutionMode.fallbackOnly,
      );

      expect(resolved.source, AudioStreamSource.ytDlp);
      expect(primary.resolveCalls, 0);
      expect(fallback.resolveCalls, 1);
    });

    test('reports the primary error when fallback begins', () async {
      final failure = Exception('primary failed');
      final reports = <({AudioStreamSource source, Object error})>[];
      final resolver = FallbackAudioResolver([
        _FailingAudioResolver(error: failure),
        _FakeAudioResolver(
          result: const AudioStreamResolution(
            source: AudioStreamSource.ytDlp,
            streamUrl: 'https://media.example/fallback.m4a',
          ),
        ),
      ]);

      await resolver.resolveWithMode(
        const TrackInfo(
          id: 'video-id',
          title: 'Track',
          artist: 'Artist',
          url: 'https://www.youtube.com/watch?v=video-id',
        ),
        onResolverFailure: (source, error) {
          reports.add((source: source, error: error));
        },
      );

      expect(reports, hasLength(1));
      expect(reports.single.source, AudioStreamSource.youtubeExplode);
      expect(reports.single.error, same(failure));
    });

    test('throws aggregated exception when all resolvers fail', () async {
      final resolver = FallbackAudioResolver([
        _FailingAudioResolver(error: Exception('first')),
        _FailingAudioResolver(error: Exception('second')),
      ]);
      await expectLater(
        resolver.resolve(
          const TrackInfo(
            id: 'video-id',
            title: 'Track',
            artist: 'Artist',
            url: 'https://www.youtube.com/watch?v=video-id',
          ),
        ),
        throwsA(
          isA<AudioStreamResolverException>().having(
            (e) => e.message,
            'message',
            contains('All audio stream resolvers failed'),
          ),
        ),
      );
    });

    test('throws when no resolver is registered', () async {
      final resolver = FallbackAudioResolver(const []);
      await expectLater(
        resolver.resolve(
          const TrackInfo(
            id: 'video-id',
            title: 'Track',
            artist: 'Artist',
            url: 'https://www.youtube.com/watch?v=video-id',
          ),
        ),
        throwsA(isA<AudioStreamResolverException>()),
      );
    });
  });
}

class _FakeAudioResolver implements AudioStreamResolver {
  _FakeAudioResolver({required this.result});

  final AudioStreamResolution result;
  int resolveCalls = 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    resolveCalls++;
    return result;
  }

  @override
  Future<void> dispose() async {}
}

class _FailingAudioResolver implements AudioStreamResolver {
  _FailingAudioResolver({required this.error});

  final Object error;
  int resolveCalls = 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    resolveCalls++;
    throw error;
  }

  @override
  Future<void> dispose() async {}
}
