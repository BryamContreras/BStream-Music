import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioStreamResolution', () {
    test('isUsable returns true for direct media URLs', () {
      const resolution = AudioStreamResolution(
        source: AudioStreamSource.youtubeExplode,
        streamUrl: 'https://media.example/file.m4a',
      );
      expect(resolution.isUsable, isTrue);
    });

    test('isUsable returns false for empty URLs', () {
      const resolution = AudioStreamResolution(
        source: AudioStreamSource.youtubeExplode,
        streamUrl: '',
      );
      expect(resolution.isUsable, isFalse);
    });

    test('isUsable accepts managed local files', () {
      const resolution = AudioStreamResolution(
        source: AudioStreamSource.ytDlp,
        streamUrl: 'file:///tmp/audio.m4a',
      );
      expect(resolution.isUsable, isTrue);
    });

    test('isUsable rejects unsupported schemes', () {
      const resolution = AudioStreamResolution(
        source: AudioStreamSource.ytDlp,
        streamUrl: 'ftp://media.example/audio.m4a',
      );
      expect(resolution.isUsable, isFalse);
    });

    test('withSource replaces the source while preserving transport', () {
      const original = AudioStreamResolution(
        source: AudioStreamSource.youtubeExplode,
        streamUrl: 'https://media.example/file.m4a',
        streamExtension: 'm4a',
        streamMimeType: 'audio/mp4',
      );
      final copy = original.withSource(AudioStreamSource.ytDlp);
      expect(copy.source, AudioStreamSource.ytDlp);
      expect(copy.streamUrl, original.streamUrl);
      expect(copy.streamExtension, original.streamExtension);
      expect(copy.streamMimeType, original.streamMimeType);
    });
  });

  group('readableAudioStreamError', () {
    test('unwraps the final yt-dlp stderr and removes Android wrappers', () {
      const error = AudioStreamResolverException(
        'All audio stream resolvers failed.',
        cause: DownloaderException(
          'com.yausername.youtubedl_android.YoutubeDLException: '
          'ERROR: [youtube] Sign in to confirm you are not a bot',
          code: 'ytdl_error',
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
        code: 'ytdl_error',
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
