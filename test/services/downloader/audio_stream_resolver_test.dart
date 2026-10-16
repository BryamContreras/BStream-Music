import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioStreamResolution', () {
    test('isUsable returns true for direct media URLs', () {
      const resolution = AudioStreamResolution(
        source: AudioStreamSource.innerTube,
        streamUrl: 'https://media.example/file.m4a',
      );
      expect(resolution.isUsable, isTrue);
    });

    test('isUsable returns false for empty URLs', () {
      const resolution = AudioStreamResolution(
        source: AudioStreamSource.innerTube,
        streamUrl: '',
      );
      expect(resolution.isUsable, isFalse);
    });

    test('isUsable accepts managed local files', () {
      const resolution = AudioStreamResolution(
        source: AudioStreamSource.innerTubeFallback,
        streamUrl: 'file:///tmp/audio.m4a',
      );
      expect(resolution.isUsable, isTrue);
    });

    test('isUsable rejects unsupported schemes', () {
      const resolution = AudioStreamResolution(
        source: AudioStreamSource.innerTubeFallback,
        streamUrl: 'ftp://media.example/audio.m4a',
      );
      expect(resolution.isUsable, isFalse);
    });

    test('withSource replaces the source while preserving transport', () {
      final expiresAt = DateTime.utc(2026, 9, 1);
      final original = AudioStreamResolution(
        source: AudioStreamSource.innerTube,
        streamUrl: 'https://media.example/file.m4a',
        streamExtension: 'm4a',
        streamMimeType: 'audio/mp4',
        sampleRate: 44100,
        channels: 2,
        clientProfileKey: 'androidSdkless',
        expiresAt: expiresAt,
      );
      final copy = original.withSource(AudioStreamSource.innerTubeFallback);
      expect(copy.source, AudioStreamSource.innerTubeFallback);
      expect(copy.streamUrl, original.streamUrl);
      expect(copy.streamExtension, original.streamExtension);
      expect(copy.streamMimeType, original.streamMimeType);
      expect(copy.sampleRate, 44100);
      expect(copy.channels, 2);
      expect(copy.clientProfileKey, 'androidSdkless');
      expect(copy.expiresAt, same(expiresAt));
    });

    test('fromTrack preserves actual selected-stream audio properties', () {
      const track = TrackInfo(
        id: 'track',
        title: 'Track',
        artist: 'Artist',
        url: 'https://example.com/track',
        streamUrl: 'https://example.com/audio.webm',
        streamCodec: 'opus',
        streamBitrate: 142000,
        streamSampleRate: 48000,
        streamChannels: 2,
      );
      final resolution = AudioStreamResolution.fromTrack(
        track,
        source: AudioStreamSource.innerTube,
      );
      expect(resolution.sampleRate, 48000);
      expect(resolution.channels, 2);
      expect(resolution.codec, 'opus');
      expect(resolution.bitrate, 142000);
      final fallback = AudioStreamResolution.fromFallbackTrack(track);
      expect(fallback.source, AudioStreamSource.innerTubeFallback);
      expect(fallback.sampleRate, 48000);
      expect(fallback.channels, 2);
    });
  });

  group('readableAudioStreamError', () {
    test('unwraps the final resolver cause', () {
      const error = AudioStreamResolverException(
        'All audio stream resolvers failed.',
        cause: DownloaderException(
          'ERROR: [youtube] Sign in to confirm you are not a bot',
          code: 'innertube_download_failed',
        ),
      );

      expect(
        readableAudioStreamError(error),
        'ERROR: [youtube] Sign in to confirm you are not a bot',
      );
    });

    test('preserves multiline extractor details', () {
      const error = DownloaderException(
        'ERROR: [youtube] Video unavailable\n'
        'This content is private\n'
        'Use an account with access',
        code: 'innertube_download_failed',
      );

      expect(readableAudioStreamError(error), contains('Video unavailable'));
      expect(readableAudioStreamError(error).split('\n'), hasLength(3));
    });

    test(
      'redacts signed URL queries while preserving the failing endpoint',
      () {
        const error = DownloaderException(
          'Failed to open '
          'https://rr4---sn.example.googlevideo.com/videoplayback?'
          'expire=1786779819&sig=temporary-secret#fragment',
          code: 'player_error',
        );

        expect(
          readableAudioStreamError(error),
          'Failed to open '
          'https://rr4---sn.example.googlevideo.com/videoplayback',
        );
      },
    );
  });
}
