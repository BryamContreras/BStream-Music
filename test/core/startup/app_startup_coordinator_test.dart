import 'dart:async';

import 'package:bstream_music/core/startup/app_startup_coordinator.dart';
import 'package:bstream_music/main.dart' as app;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'mounts the application before optional startup work completes',
    () async {
      final pending = Completer<void>();
      var applicationMounted = false;
      VoidCallback? scheduledStartup;

      final startup = app.launchBStreamMusicApp(
        initializeAndroidServices: true,
        initializeNotificationArtwork: () => pending.future,
        initializeAudioService: () => pending.future,
        runApplication: (Widget _) {
          applicationMounted = true;
        },
        scheduleStartup: (callback) {
          scheduledStartup = callback;
        },
      );
      addTearDown(startup.dispose);

      expect(applicationMounted, isTrue);
      expect(startup.snapshot.value.status, AppStartupStatus.idle);
      scheduledStartup!();
      expect(startup.snapshot.value.status, AppStartupStatus.initializing);
      pending.complete();
      await startup.initialize();
      expect(startup.snapshot.value.status, AppStartupStatus.ready);
      expect(startup.snapshot.value.attempt, 1);
    },
  );

  test('reports degraded startup and retries only failed services', () async {
    var artworkAttempts = 0;
    var audioAttempts = 0;
    final coordinator = AppStartupCoordinator(
      retryBackoff: const <Duration>[],
      operations: {
        OptionalStartupService.notificationArtwork: () async {
          artworkAttempts++;
          if (artworkAttempts == 1) {
            throw StateError('loopback unavailable');
          }
        },
        OptionalStartupService.audioService: () async {
          audioAttempts++;
        },
      },
    );
    addTearDown(coordinator.dispose);

    await coordinator.initialize();
    expect(coordinator.snapshot.value.status, AppStartupStatus.degraded);
    expect(coordinator.snapshot.value.failures.keys, {
      OptionalStartupService.notificationArtwork,
    });

    await coordinator.retryFailed();
    expect(coordinator.snapshot.value.status, AppStartupStatus.ready);
    expect(artworkAttempts, 2);
    expect(audioAttempts, 1);
  });

  test(
    'automatically retries only failed services with bounded backoff',
    () async {
      var artworkAttempts = 0;
      var audioAttempts = 0;
      final delays = <Duration>[];
      final coordinator = AppStartupCoordinator(
        retryBackoff: const <Duration>[
          Duration(milliseconds: 500),
          Duration(seconds: 2),
        ],
        retryDelay: (duration) async {
          delays.add(duration);
        },
        operations: {
          OptionalStartupService.notificationArtwork: () async {
            artworkAttempts++;
            if (artworkAttempts < 3) {
              throw StateError('loopback unavailable');
            }
          },
          OptionalStartupService.audioService: () async {
            audioAttempts++;
          },
        },
      );
      addTearDown(coordinator.dispose);

      await coordinator.initialize();

      expect(coordinator.snapshot.value.status, AppStartupStatus.ready);
      expect(coordinator.snapshot.value.attempt, 3);
      expect(artworkAttempts, 3);
      expect(audioAttempts, 1);
      expect(delays, const <Duration>[
        Duration(milliseconds: 500),
        Duration(seconds: 2),
      ]);
    },
  );

  test('stops after the configured automatic retry budget', () async {
    var attempts = 0;
    final coordinator = AppStartupCoordinator(
      retryBackoff: const <Duration>[Duration.zero, Duration.zero],
      retryDelay: (_) async {},
      operations: {
        OptionalStartupService.audioService: () async {
          attempts++;
          throw StateError('service unavailable');
        },
      },
    );
    addTearDown(coordinator.dispose);

    await coordinator.initialize();

    expect(attempts, 3);
    expect(coordinator.snapshot.value.status, AppStartupStatus.degraded);
    expect(coordinator.snapshot.value.attempt, 3);
    expect(coordinator.snapshot.value.canRetry, isTrue);
  });
}
