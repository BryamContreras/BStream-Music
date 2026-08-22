// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/platform_channels/android_ytdl_channel.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_audio_stream_selector.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_explode_runtime.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

typedef _ClientEntry = ({
  String name,
  YoutubeApiClient client,
  bool requireWatchPage,
});

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final channel = AndroidYtdlChannel();

  print('# FALLBACK_FORCE_BENCHMARK | ${DateTime.now().toIso8601String()}');
  print('# Chain order: visionOS+watch -> safari+po (skipping androidSdkless)');
  print('');

  final orderedClients = <_ClientEntry>[
    (
      name: 'visionOS+watch',
      client: youtubeVisionOsClient,
      requireWatchPage: true,
    ),
    (
      name: 'safari+po',
      client: YoutubeApiClient.safari,
      requireWatchPage: true,
    ),
  ];

  final videoId = args.isEmpty ? 'dQw4w9WgXcQ' : args.first;
  final runtime = YoutubeExplodeRuntime(
    platform: AppPlatform.current,
    androidChannel: channel,
  );

  try {
    final coldTokenStopwatch = Stopwatch()..start();
    final coldToken = await channel.getPoTokens(videoId);
    coldTokenStopwatch.stop();
    print(
      '# [PO] cold=${coldTokenStopwatch.elapsedMilliseconds}ms available=${coldToken != null}',
    );

    if (coldToken != null) {
      final warmStopwatch = Stopwatch()..start();
      await channel.getPoTokens(videoId);
      warmStopwatch.stop();
      print('# [PO] warm=${warmStopwatch.elapsedMilliseconds}ms');
    }

    final totalStopwatch = Stopwatch()..start();

    for (var i = 0; i < orderedClients.length; i++) {
      final entry = orderedClients[i];
      final clientName = entry.name;
      final apiClient = entry.client;
      final requireWatchPage = entry.requireWatchPage;
      final isLastClient = i == orderedClients.length - 1;

      final solverClient = await runtime.solverClient;

      print(
        '# [ATTEMPT] $videoId | $clientName | watchPage=$requireWatchPage | solver=true | chainPos=$i',
      );

      final attemptStopwatch = Stopwatch()..start();
      try {
        final manifest = await solverClient.videos.streams
            .getManifest(
              VideoId.fromString(videoId),
              ytClients: [apiClient],
              requireWatchPage: requireWatchPage,
            )
            .timeout(const Duration(seconds: 25));
        attemptStopwatch.stop();

        final audioOnly = manifest.audioOnly;
        final selectedStream = selectPreferredYoutubeAudioStream(
          audioOnly,
          requireDirectUrl: true,
        );

        if (selectedStream != null) {
          totalStopwatch.stop();
          print(
            '# [SELECTED] $clientName succeeded in ${attemptStopwatch.elapsedMilliseconds}ms with ${audioOnly.length} audio streams',
          );
          print('');
          print(
            '# RESULT: success | client=$clientName | elapsed=${totalStopwatch.elapsedMilliseconds}ms | streams=${audioOnly.length} | codec=${selectedStream.audioCodec} | bitrate=${selectedStream.bitrate.bitsPerSecond}',
          );
          break;
        } else {
          totalStopwatch.stop();
          print(
            '# [NO_AUDIO] $clientName returned ${manifest.streams.length} streams but no audio in ${attemptStopwatch.elapsedMilliseconds}ms',
          );
          print('');
          print(
            '# RESULT: no-audio | client=$clientName | elapsed=${totalStopwatch.elapsedMilliseconds}ms | streams=${manifest.streams.length} | audio=${audioOnly.length}',
          );
        }
      } on RequestLimitExceededException {
        attemptStopwatch.stop();
        print(
          '# [RATELIMIT] $clientName got RequestLimitExceeded after ${attemptStopwatch.elapsedMilliseconds}ms',
        );
        if (requireWatchPage) {
          print(
            '# [BACKOFF] rate limit on requireWatchPage client, skipping remaining watch-page clients',
          );
          var skipIdx = i + 1;
          while (skipIdx < orderedClients.length &&
              orderedClients[skipIdx].requireWatchPage) {
            print(
              '# [SKIP] skipping ${orderedClients[skipIdx].name} (requireWatchPage backoff)',
            );
            skipIdx++;
          }
        }
        if (!isLastClient) {
          print('# [FALLBACK] moving to next client...');
          continue;
        } else {
          totalStopwatch.stop();
          print('');
          print(
            '# RESULT: rate-limited | elapsed=${totalStopwatch.elapsedMilliseconds}ms | clients-attempted=${i + 1}',
          );
        }
      } catch (error, stackTrace) {
        attemptStopwatch.stop();
        final errorMsg = error.toString().replaceAll(RegExp(r'[\r\n|]+'), ' ');
        print(
          '# [ERROR] $clientName threw $errorMsg after ${attemptStopwatch.elapsedMilliseconds}ms',
        );
        print('#   $stackTrace');
        totalStopwatch.stop();
        print('');
        print('# RESULT: error | client=$clientName | error=$errorMsg');
        break;
      }
    }
  } finally {
    await runtime.dispose();
    await channel.disposePoTokens();
  }
}
