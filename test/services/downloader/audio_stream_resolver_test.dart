import 'package:bstream_music/core/errors/app_exception.dart';
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
        clientProfileKey: 'androidSdkless',
        expiresAt: expiresAt,
      );
      final copy = original.withSource(AudioStreamSource.innerTubeFallback);
      expect(copy.source, AudioStreamSource.innerTubeFallback);
      expect(copy.streamUrl, original.streamUrl);
      expect(copy.streamExtension, original.streamExtension);
      expect(copy.streamMimeType, original.streamMimeType);
      expect(copy.clientProfileKey, 'androidSdkless');
      expect(copy.expiresAt, same(expiresAt));
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
