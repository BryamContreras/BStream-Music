import 'dart:async';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
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

  group('manifest scheduler', () {
    test('bounds concurrent manifest requests', () async {
      final runtime = YoutubeExplodeRuntime(
        platform: AppPlatformType.windows,
        denoExecutable: 'unused-deno-for-scheduler-test',
        maximumConcurrentManifestRequests: 2,
        manifestQueueTimeout: const Duration(seconds: 2),
      );
      addTearDown(runtime.dispose);
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) {
          release.complete();
        }
      });
      final firstPairStarted = Completer<void>();
      var active = 0;
      var maximumActive = 0;
      var started = 0;

      Future<int> schedule(int index) {
        return runtime.runManifestRequest(
          priority: YoutubeExplodeManifestPriority.playback,
          operation: () async {
            active++;
            started++;
            maximumActive = active > maximumActive ? active : maximumActive;
            if (started == 2 && !firstPairStarted.isCompleted) {
              firstPairStarted.complete();
            }
            try {
              await release.future;
              return index;
            } finally {
              active--;
            }
          },
        );
      }

      final requests = [
        for (var index = 0; index < 4; index++) schedule(index),
      ];
      await firstPairStarted.future;
      await Future<void>.delayed(Duration.zero);

      expect(started, 2);
      expect(maximumActive, 2);

      release.complete();
      expect(await Future.wait(requests), [0, 1, 2, 3]);
      expect(maximumActive, 2);
    });

    test('starts queued playback before an older queued download', () async {
      final runtime = YoutubeExplodeRuntime(
        platform: AppPlatformType.windows,
        denoExecutable: 'unused-deno-for-priority-test',
        maximumConcurrentManifestRequests: 1,
        manifestQueueTimeout: const Duration(seconds: 2),
      );
      addTearDown(runtime.dispose);
      final releaseFirstDownload = Completer<void>();
      final releasePlayback = Completer<void>();
      addTearDown(() {
        if (!releaseFirstDownload.isCompleted) {
          releaseFirstDownload.complete();
        }
        if (!releasePlayback.isCompleted) {
          releasePlayback.complete();
        }
      });
      final firstDownloadStarted = Completer<void>();
      final playbackStarted = Completer<void>();
      final secondDownloadStarted = Completer<void>();
      final starts = <String>[];

      final firstDownload = runtime.runManifestRequest<void>(
        priority: YoutubeExplodeManifestPriority.download,
        operation: () async {
          starts.add('download-1');
          firstDownloadStarted.complete();
          await releaseFirstDownload.future;
        },
      );
      await firstDownloadStarted.future;

      final secondDownload = runtime.runManifestRequest<void>(
        priority: YoutubeExplodeManifestPriority.download,
        operation: () async {
          starts.add('download-2');
          secondDownloadStarted.complete();
        },
      );
      final playback = runtime.runManifestRequest<void>(
        priority: YoutubeExplodeManifestPriority.playback,
        operation: () async {
          starts.add('playback');
          playbackStarted.complete();
          await releasePlayback.future;
        },
      );

      releaseFirstDownload.complete();
      await firstDownload;
      await playbackStarted.future;

      expect(starts, ['download-1', 'playback']);
      expect(secondDownloadStarted.isCompleted, isFalse);

      releasePlayback.complete();
      await playback;
      await secondDownloadStarted.future;
      await secondDownload;
      expect(starts, ['download-1', 'playback', 'download-2']);
    });

    test('runs at most one download manifest on desktop', () async {
      final runtime = YoutubeExplodeRuntime(
        platform: AppPlatformType.windows,
        denoExecutable: 'unused-deno-for-download-limit-test',
        maximumConcurrentManifestRequests: 2,
        manifestQueueTimeout: const Duration(seconds: 2),
      );
      addTearDown(runtime.dispose);
      final releases = List.generate(3, (_) => Completer<void>());
      addTearDown(() {
        for (final release in releases) {
          if (!release.isCompleted) {
            release.complete();
          }
        }
      });
      final starts = List.generate(3, (_) => Completer<void>());
      var activeDownloads = 0;
      var maximumActiveDownloads = 0;

      final requests = [
        for (var index = 0; index < 3; index++)
          runtime.runManifestRequest<void>(
            priority: YoutubeExplodeManifestPriority.download,
            operation: () async {
              activeDownloads++;
              maximumActiveDownloads = activeDownloads > maximumActiveDownloads
                  ? activeDownloads
                  : maximumActiveDownloads;
              starts[index].complete();
              try {
                await releases[index].future;
              } finally {
                activeDownloads--;
              }
            },
          ),
      ];

      await starts[0].future;
      await Future<void>.delayed(Duration.zero);
      expect(starts[1].isCompleted, isFalse);

      releases[0].complete();
      await starts[1].future;
      expect(starts[2].isCompleted, isFalse);

      releases[1].complete();
      await starts[2].future;
      releases[2].complete();
      await Future.wait(requests);

      expect(maximumActiveDownloads, 1);
    });

    test('discards obsolete work before its operation starts', () async {
      final runtime = YoutubeExplodeRuntime(
        platform: AppPlatformType.android,
        maximumConcurrentManifestRequests: 1,
        manifestQueueTimeout: const Duration(seconds: 2),
      );
      addTearDown(runtime.dispose);
      final releaseBlocker = Completer<void>();
      addTearDown(() {
        if (!releaseBlocker.isCompleted) {
          releaseBlocker.complete();
        }
      });
      final blockerStarted = Completer<void>();
      var current = true;
      var obsoleteOperationCalls = 0;

      final blocker = runtime.runManifestRequest<void>(
        priority: YoutubeExplodeManifestPriority.playback,
        operation: () async {
          blockerStarted.complete();
          await releaseBlocker.future;
        },
      );
      await blockerStarted.future;

      final obsolete = runtime.runManifestRequest<void>(
        priority: YoutubeExplodeManifestPriority.playback,
        shouldContinue: () => current,
        operation: () async {
          obsoleteOperationCalls++;
        },
      );
      final obsoleteExpectation = expectLater(
        obsolete,
        throwsA(
          isA<AudioStreamResolverException>().having(
            (error) => error.message,
            'message',
            contains('superseded'),
          ),
        ),
      );

      current = false;
      releaseBlocker.complete();
      await blocker;
      await obsoleteExpectation;

      expect(obsoleteOperationCalls, 0);
    });

    test(
      'visible execution timeout keeps the slot until real work finishes',
      () async {
        final runtime = YoutubeExplodeRuntime(
          platform: AppPlatformType.android,
          maximumConcurrentManifestRequests: 1,
          manifestQueueTimeout: const Duration(seconds: 2),
        );
        addTearDown(runtime.dispose);
        final releaseTimedOutOperation = Completer<void>();
        addTearDown(() {
          if (!releaseTimedOutOperation.isCompleted) {
            releaseTimedOutOperation.complete();
          }
        });
        final realOperationStarted = Completer<void>();
        var nextOperationStarted = false;

        final timedOut = runtime.runManifestRequest<void>(
          priority: YoutubeExplodeManifestPriority.playback,
          executionTimeout: const Duration(milliseconds: 20),
          operation: () async {
            realOperationStarted.complete();
            await releaseTimedOutOperation.future;
          },
        );
        await realOperationStarted.future;
        await expectLater(timedOut, throwsA(isA<TimeoutException>()));

        final next = runtime.runManifestRequest<void>(
          priority: YoutubeExplodeManifestPriority.playback,
          operation: () async {
            nextOperationStarted = true;
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(nextOperationStarted, isFalse);

        releaseTimedOutOperation.complete();
        await next;
        expect(nextOperationStarted, isTrue);
      },
    );
  });
}
