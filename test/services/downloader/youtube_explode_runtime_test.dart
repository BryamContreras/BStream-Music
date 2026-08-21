import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_audio_stream_selector.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_explode_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  test('shares the fast client and closes it exactly once', () async {
    final runtime = YoutubeExplodeRuntime(
      platform: AppPlatformType.windows,
      denoExecutable: 'missing-deno-for-fast-path-test',
    );

    final first = await runtime.fastClient;
    final second = await runtime.clientFor(
      const YoutubeManifestAttempt(
        name: 'fast',
        client: YoutubeApiClient.androidSdkless,
      ),
    );

    expect(second, same(first));
    await runtime.dispose();
    await runtime.dispose();

    expect(() => runtime.fastClient, throwsA(isA<StateError>()));
  });
}
