import 'dart:async';

import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/player/media_kit_player_service.dart';
import 'package:bstream_music/services/player/player_audio_output.dart';
import 'package:bstream_music/services/player/player_equalizer.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  group('restored playback position', () {
    const position = Duration(seconds: 42, milliseconds: 250);
    for (final localQueue in [false, true]) {
      test('seeks before audio starts (local queue=$localQueue)', () async {
        final backend = _InitialPositionBackend();
        final service = MediaKitPlayerService(backend: backend);
        addTearDown(service.dispose);
        final local = LocalTrack(
          id: 'restored',
          title: 'Restored',
          artist: 'Artist',
          filePath: '/music/restored.m4a',
          addedAt: DateTime(2026),
        );
        final play = localQueue
            ? service.playLocalQueue([local], 0, initialPosition: position)
            : service.playRemote(_track('restored'), initialPosition: position);
        await _waitUntil(() => backend.openCalls.isNotEmpty);
        expect(backend.openCalls.single.play, isFalse);
        expect(backend.openCalls.single.media.start, isNull);
        expect(backend.seekCalls, isEmpty);
        expect(backend.playCalls, 0);
        expect(service.currentSnapshot.position, position);
        backend.completeOpen(0);
        await play;
        expect(backend.playbackCommands, ['open:false', 'seek:42250', 'play']);
        expect(backend.seekCalls, [position]);
        expect(service.currentSnapshot.position, position);
        expect(service.currentSnapshot.status, PlayerStatus.playing);
      });
    }

    test(
      'normal and negative positions retain the single native open',
      () async {
        final backend = _InitialPositionBackend();
        final service = MediaKitPlayerService(backend: backend);
        addTearDown(service.dispose);
        final play = service.playRemote(
          _track('start'),
          initialPosition: const Duration(seconds: -1),
        );
        await _waitUntil(() => backend.openCalls.isNotEmpty);
        backend.completeOpen(0);
        await play;
        expect(backend.openCalls.single.play, isTrue);
        expect(backend.playbackCommands, ['open:true']);
        expect(backend.seekCalls, isEmpty);
        expect(backend.playCalls, 0);
        expect(service.currentSnapshot.position, Duration.zero);
      },
    );

    test(
      'a cancelled initial seek cannot start audio after a newer selection',
      () async {
        final backend = _InitialPositionBackend()
          ..seekBarrier = Completer<void>();
        final service = MediaKitPlayerService(backend: backend);
        addTearDown(() async {
          final barrier = backend.seekBarrier;
          if (barrier != null && !barrier.isCompleted) barrier.complete();
          await service.dispose();
        });
        final obsolete = service.playRemote(
          _track('obsolete'),
          initialPosition: position,
        );
        await _waitUntil(() => backend.openCalls.length == 1);
        backend.completeOpen(0);
        await backend.seekStarted.future;
        final selected = service.playRemote(_track('selected'));
        await _waitUntil(() => backend.openCalls.length == 2);
        backend.completeOpen(1);
        await Future.wait([obsolete, selected]);
        backend.seekBarrier!.complete();
        await _drainEvents();
        expect(backend.playCalls, 0);
        expect(backend.currentSourceId, 'selected');
        expect(service.currentSnapshot.trackId, 'selected');
        expect(service.currentSnapshot.position, Duration.zero);
        expect(service.currentSnapshot.status, PlayerStatus.playing);
      },
    );
  });

  group('native equalizer', () {
    const bass = EqualizerSettings(
      enabled: true,
      gainsDb: [6, 3, 0, 0, 0, 0, 0, 0, 0, 0],
    );
    const vocal = EqualizerSettings(
      enabled: true,
      gainsDb: [-3, 0, 3.5, 2, -1, 1, 2, 0, -1, -2],
    );

    test('optional capability leaves existing backends compatible', () async {
      final service = MediaKitPlayerService(backend: _FakeMediaKitBackend());
      addTearDown(service.dispose);
      expect(service.supportsEqualizer, isFalse);
      await service.configureEqualizer(const EqualizerSettings());
      await expectLater(
        service.configureEqualizer(bass),
        throwsUnsupportedError,
      );
    });

    test('tuning keeps the source, clock, logical volume and route', () async {
      final backend = _EqualizerBackend();
      final service = MediaKitPlayerService(backend: backend);
      addTearDown(service.dispose);
      await _playAndComplete(service, backend, 'equalized');
      await service.setVolume(.4);
      await service.selectAudioOutput('usb');
      backend.emitPosition(const Duration(seconds: 17));
      await _drainEvents();
      final volumeWrites = backend.volumeCalls.length;

      await service.configureEqualizer(bass);

      expect(backend.equalizer, bass);
      expect(service.currentSnapshot.trackId, 'equalized');
      expect(service.currentSnapshot.position, const Duration(seconds: 17));
      expect(service.currentSnapshot.volume, .4);
      expect(backend.volumeCalls.length, volumeWrites);
      expect(backend.selectedDeviceId, 'usb');
      expect(backend.openCalls, hasLength(1));
      expect(backend.pauseCalls, 0);
      expect(backend.stopCalls, 0);
      expect(backend.seekCalls, isEmpty);

      final writes = backend.equalizerCalls.length;
      for (var second = 18; second < 25; second++) {
        backend.emitPosition(Duration(seconds: second));
      }
      await _drainEvents();
      expect(backend.equalizerCalls.length, writes);
    });

    test(
      'a new standby inherits tuning before open and after promotion',
      () async {
        final active = _EqualizerBackend();
        final standby = _EqualizerBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);
        await service.configureEqualizer(bass);
        await service.selectAudioOutput('usb');
        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );
        await _prepareAndComplete(service, standby, 'b');
        expect(standby.equalizersAtOpen, [bass]);
        expect(standby.routesAtOpen, ['usb']);
        expect(standby.volumeCalls, [0]);
        await service.configureEqualizer(vocal);
        expect(active.equalizer, vocal);
        expect(standby.equalizer, vocal);

        active
          ..emitDuration(const Duration(seconds: 2))
          ..emitPosition(const Duration(milliseconds: 1600));
        await _waitUntil(() => service.currentSnapshot.trackId == 'b');
        await service.configureEqualizer(const EqualizerSettings());
        expect(active.equalizer.enabled, isFalse);
        expect(standby.equalizer.enabled, isFalse);
        expect(service.audioOutputState.selectedDeviceId, 'usb');
      },
    );

    test(
      'rapid changes coalesce and the latest curve reaches both decks',
      () async {
        final active = _EqualizerBackend();
        final standby = _EqualizerBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);
        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(seconds: 1),
        );
        await _prepareAndComplete(service, standby, 'b');
        active.releaseEqualizer = Completer<void>();
        final first = service.configureEqualizer(bass);
        await _waitUntil(() => active.equalizerCalls.contains(bass));
        const skipped = EqualizerSettings(
          enabled: true,
          gainsDb: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
        );
        final intermediate = service.configureEqualizer(skipped);
        final latest = service.configureEqualizer(vocal);
        active.releaseEqualizer!.complete();
        await Future.wait([first, intermediate, latest]);

        expect(active.equalizer, vocal);
        expect(standby.equalizer, vocal);
        expect(active.equalizerCalls, isNot(contains(skipped)));
        expect(standby.equalizerCalls, isNot(contains(skipped)));
      },
    );

    test('a filter failure is reported without preventing playback', () async {
      final backend = _EqualizerBackend()..failEqualizer = true;
      final service = MediaKitPlayerService(backend: backend);
      addTearDown(service.dispose);
      await expectLater(service.configureEqualizer(bass), throwsStateError);

      await _playAndComplete(service, backend, 'still-plays');

      expect(service.currentSnapshot.trackId, 'still-plays');
      expect(service.currentSnapshot.status, PlayerStatus.playing);
      expect(backend.openCalls, hasLength(1));
    });

    test(
      'a standby created during a pending update opens with the latest curve',
      () async {
        final active = _EqualizerBackend();
        final standby = _EqualizerBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);
        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(seconds: 1),
        );
        active.releaseEqualizer = Completer<void>();
        final first = service.configureEqualizer(bass);
        await _waitUntil(() => active.equalizerCalls.contains(bass));
        final preparation = service.prepareCrossfade(_crossfadeSource('b'));
        final latest = service.configureEqualizer(vocal);
        active.releaseEqualizer!.complete();
        await _waitUntil(() => standby.openCalls.isNotEmpty);
        expect(standby.equalizersAtOpen, [vocal]);
        standby.completeOpen(0);
        await Future.wait([first, latest, preparation]);
        expect(standby.playCalls, 0);
        expect(standby.volumeCalls, [0]);
      },
    );
  });

  group('player audio output', () {
    test(
      'selects only the player route and preserves playback and volume',
      () async {
        final backend = _AudioOutputBackend();
        final service = MediaKitPlayerService(backend: backend);
        addTearDown(service.dispose);
        await _playAndComplete(service, backend, 'route');
        await service.setVolume(.4);
        backend.emitPosition(const Duration(seconds: 12));
        await _drainEvents();

        await service.selectAudioOutput('usb');

        expect(backend.selectedDeviceId, 'usb');
        expect(service.audioOutputState.selectedDeviceId, 'usb');
        expect(service.currentSnapshot.trackId, 'route');
        expect(service.currentSnapshot.position, const Duration(seconds: 12));
        expect(service.currentSnapshot.volume, .4);
        expect(backend.openCalls, hasLength(1));
        expect(backend.pauseCalls, 0);
        expect(backend.stopCalls, 0);
      },
    );

    test(
      'rejects an unavailable route without changing the selection',
      () async {
        final backend = _AudioOutputBackend();
        final service = MediaKitPlayerService(backend: backend);
        addTearDown(service.dispose);

        await expectLater(
          service.selectAudioOutput('missing'),
          throwsArgumentError,
        );

        expect(backend.routeCalls, isEmpty);
        expect(
          service.audioOutputState.selectedDeviceId,
          systemDefaultAudioDeviceId,
        );
      },
    );

    test(
      'a hung route write is isolated and does not block later selections',
      () async {
        final backend = _AudioOutputBackend()
          ..blockedRoute = 'usb'
          ..releaseRoute = Completer<void>();
        final service = MediaKitPlayerService(
          backend: backend,
          operationTimeout: const Duration(milliseconds: 30),
        );
        addTearDown(service.dispose);

        await expectLater(
          service.selectAudioOutput('usb'),
          throwsA(isA<TimeoutException>()),
        );
        expect(backend.abandonCalls, 1);
        expect(service.currentSnapshot.status, PlayerStatus.failed);
        await service.selectAudioOutput('headphones');
        backend.releaseRoute!.complete();
        await _drainEvents();

        expect(backend.selectedDeviceId, 'headphones');
        expect(service.audioOutputState.selectedDeviceId, 'headphones');
      },
    );

    test(
      'routes a new crossfade deck before open and retains route on promotion',
      () async {
        final active = _AudioOutputBackend();
        final standby = _AudioOutputBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);
        await service.selectAudioOutput('usb');
        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );
        await _prepareAndComplete(service, standby, 'b');
        expect(standby.routesAtOpen, ['usb']);
        active
          ..emitDuration(const Duration(seconds: 2))
          ..emitPosition(const Duration(milliseconds: 1600));
        await _waitUntil(() => service.currentSnapshot.trackId == 'b');

        expect(service.audioOutputState.selectedDeviceId, 'usb');
        await service.selectAudioOutput('headphones');
        expect(active.selectedDeviceId, 'headphones');
        expect(standby.selectedDeviceId, 'headphones');
      },
    );

    test('rolls back both decks if a standby route write fails', () async {
      final active = _AudioOutputBackend();
      final standby = _AudioOutputBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);
      await _playAndComplete(service, active, 'a');
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');
      standby.failRoute = 'usb';

      await expectLater(service.selectAudioOutput('usb'), throwsStateError);

      expect(active.selectedDeviceId, systemDefaultAudioDeviceId);
      expect(standby.selectedDeviceId, systemDefaultAudioDeviceId);
      expect(
        service.audioOutputState.selectedDeviceId,
        systemDefaultAudioDeviceId,
      );
    });

    test(
      'falls back after unplug even without an output menu listener',
      () async {
        final backend = _AudioOutputBackend();
        final service = MediaKitPlayerService(backend: backend);
        addTearDown(service.dispose);
        await service.selectAudioOutput('usb');

        backend.updateDevices(const []);
        await Future<void>.delayed(const Duration(milliseconds: 700));

        expect(backend.selectedDeviceId, systemDefaultAudioDeviceId);
        expect(
          service.audioOutputState.selectedDeviceId,
          systemDefaultAudioDeviceId,
        );
      },
    );

    test(
      'ignores a transient empty device list during native startup',
      () async {
        final backend = _AudioOutputBackend();
        final service = MediaKitPlayerService(backend: backend);
        addTearDown(service.dispose);
        await service.selectAudioOutput('usb');
        backend.updateDevices(const []);
        await _drainEvents();
        backend.updateDevices(_AudioOutputBackend.availableDevices);
        await Future<void>.delayed(const Duration(milliseconds: 700));

        expect(service.audioOutputState.selectedDeviceId, 'usb');
        expect(backend.routeCalls, ['usb']);
      },
    );

    test(
      'a backend without the optional capability stays unsupported',
      () async {
        final service = MediaKitPlayerService(backend: _FakeMediaKitBackend());
        addTearDown(service.dispose);
        expect(service.audioOutputState.supported, false);
        await expectLater(
          service.selectAudioOutput('auto'),
          throwsArgumentError,
        );
      },
    );
  });

  for (final playingFirst in [true, false]) {
    test(
      'native EOF never publishes pause (${playingFirst ? 'playing' : 'completed'} first)',
      () async {
        final backend = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(backend: backend);
        addTearDown(service.dispose);
        final play = service.playRemote(_track('terminal'));
        await _waitUntil(() => backend.openCalls.isNotEmpty);
        backend.completeOpen(0);
        await play;
        await _drainEvents();
        final statuses = <PlayerStatus>[];
        final subscription = service.snapshotStream.listen(
          (snapshot) => statuses.add(snapshot.status),
        );
        addTearDown(subscription.cancel);

        // media_kit sets state.completed before publishing either stream.
        backend.completed = true;
        if (playingFirst) {
          backend.emitPlaying(false);
          await _drainEvents();
          backend.emitCompleted();
        } else {
          backend.emitCompleted();
          await _drainEvents();
          backend.emitPlaying(false);
        }
        await _drainEvents();

        expect(statuses, contains(PlayerStatus.completed));
        expect(statuses, isNot(contains(PlayerStatus.paused)));
        expect(service.currentSnapshot.status, PlayerStatus.completed);
      },
    );
  }

  test('a genuine native pause remains a pause rather than EOF', () async {
    final backend = _FakeMediaKitBackend();
    final service = MediaKitPlayerService(backend: backend);
    addTearDown(service.dispose);
    final play = service.playRemote(_track('pause'));
    await _waitUntil(() => backend.openCalls.isNotEmpty);
    backend.completeOpen(0);
    await play;
    backend.emitPlaying(false);
    await _drainEvents();

    expect(backend.completed, isFalse);
    expect(service.currentSnapshot.status, PlayerStatus.paused);
  });

  test(
    'a hung open cannot block a newer selection or overwrite it late',
    () async {
      final backend = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(backend: backend);
      addTearDown(service.dispose);

      final first = service.playRemote(_track('a'));
      await _waitUntil(() => backend.openCalls.length == 1);

      final second = service.playRemote(_track('b'));
      await _waitUntil(() => backend.openCalls.length == 2);
      backend.completeOpen(1);
      await Future.wait([first, second]);

      expect(backend.abandonCalls, 1);
      expect(backend.currentSourceId, 'b');
      expect(service.currentSnapshot.trackId, 'b');
      expect(service.currentSnapshot.status, PlayerStatus.playing);

      // A is still alive, but belongs to a retired backend and cannot replace B.
      backend.completeOpen(0);
      backend.emitErrorForSession(0, 'late failure from a');
      await _drainEvents();
      expect(backend.currentSourceId, 'b');
      expect(service.currentSnapshot.trackId, 'b');
      expect(service.currentSnapshot.status, PlayerStatus.playing);

      backend.emitErrorForSession(1, 'current failure from b');
      await _drainEvents();
      expect(service.currentSnapshot.status, PlayerStatus.failed);
      expect(service.currentSnapshot.errorMessage, 'current failure from b');
    },
  );

  test(
    'stop finishes while open never completes and wins late completion',
    () async {
      final backend = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(backend: backend);
      addTearDown(service.dispose);

      final play = service.playRemote(_track('a'));
      await _waitUntil(() => backend.openCalls.length == 1);
      final stop = service.stop();
      await Future.wait([play, stop]);

      expect(backend.abandonCalls, 1);
      expect(backend.stopCalls, 1);
      expect(backend.currentSourceId, isNull);
      expect(service.currentSnapshot.status, PlayerStatus.stopped);

      backend.completeOpen(0);
      await _drainEvents();
      expect(backend.currentSourceId, isNull);
      expect(service.currentSnapshot.status, PlayerStatus.stopped);
    },
  );

  test(
    'deadline retires a hung native open and publishes its failure',
    () async {
      final backend = _FakeMediaKitBackend();
      final deadline = Completer<void>();
      final service = MediaKitPlayerService(
        backend: backend,
        operationTimeout: const Duration(seconds: 1),
        operationDeadline: (_) => deadline.future,
      );
      addTearDown(service.dispose);

      final play = service.playRemote(_track('a'));
      await _waitUntil(() => backend.openCalls.length == 1);
      deadline.complete();

      await expectLater(play, throwsA(isA<TimeoutException>()));
      expect(backend.abandonCalls, 1);
      expect(service.currentSnapshot.status, PlayerStatus.failed);

      backend.completeOpen(0);
      await _drainEvents();
      expect(backend.currentSourceId, isNull);
      expect(service.currentSnapshot.status, PlayerStatus.failed);
    },
  );

  test('dispose finishes while an open remains hung', () async {
    final backend = _FakeMediaKitBackend();
    final service = MediaKitPlayerService(backend: backend);

    final play = service.playRemote(_track('a'));
    await _waitUntil(() => backend.openCalls.length == 1);
    await service.dispose();
    await play;

    expect(backend.abandonCalls, 1);
    expect(backend.disposed, isTrue);
  });

  test(
    'hints extensionless remote URLs and filters request-owned headers',
    () async {
      final backend = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(backend: backend);
      addTearDown(service.dispose);

      final play = service.playRemote(
        _track(
          'hinted',
          streamExtension: 'm4a',
          httpHeaders: const {
            'User-Agent': 'BStream test',
            'Cookie': 'CONSENT=YES',
            'Range': 'bytes=0-1',
            'Host': 'invalid.example',
          },
        ),
      );
      await _waitUntil(() => backend.openCalls.length == 1);

      final media = backend.openCalls.single.media;
      expect(media.uri, endsWith('#.m4a'));
      expect(media.httpHeaders, const {
        'User-Agent': 'BStream test',
        'Cookie': 'CONSENT=YES',
      });

      backend.completeOpen(0);
      await play;
    },
  );

  test(
    'an error emitted while opening is not overwritten by playing',
    () async {
      final backend = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(backend: backend);
      addTearDown(service.dispose);

      final play = service.playRemote(_track('open-error'));
      await _waitUntil(() => backend.openCalls.length == 1);
      backend.emitErrorForSession(0, 'Failed to open');
      await _drainEvents();

      expect(service.currentSnapshot.status, PlayerStatus.failed);
      expect(service.currentSnapshot.errorMessage, 'Failed to open');

      backend.completeOpen(0);
      await expectLater(play, throwsA(isA<PlayerException>()));
      expect(service.currentSnapshot.status, PlayerStatus.failed);
    },
  );

  group('same-recording source upgrades', () {
    for (final (difference, accepted) in [
      (const Duration(seconds: 3), true),
      (const Duration(milliseconds: 3001), false),
    ]) {
      test('validates a decoder runtime difference of $difference', () async {
        const duration = Duration(minutes: 3);
        const position = Duration(seconds: 41);
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend()
          ..durationOnOpen = duration + difference;
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);
        await _playAndComplete(service, active, 'a');
        active
          ..emitDuration(duration)
          ..emitPosition(position);
        await _drainEvents();

        final upgrade = service.upgradeRemoteSource(_upgradeSource());
        await _waitUntil(() => standby.openCalls.isNotEmpty);
        standby.completeOpen(0);

        expect(await upgrade, accepted);
        expect(standby.playCalls, accepted ? 1 : 0);
        expect(service.currentSnapshot.position, position);
        expect(service.currentSnapshot.status, PlayerStatus.playing);
        expect(active.openCalls, hasLength(1));
      });
    }

    test(
      'waits for decoded metadata before seeking a newly opened file',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);
        await _playAndComplete(service, active, 'a');
        active
          ..emitDuration(const Duration(minutes: 3))
          ..emitPosition(const Duration(seconds: 41));
        await _drainEvents();
        final upgrade = service.upgradeRemoteSource(_upgradeSource());
        await _waitUntil(() => standby.openCalls.isNotEmpty);
        standby.completeOpen(0);
        await _drainEvents();
        expect(standby.seekCalls, isEmpty);
        expect(standby.playCalls, 0);
        expect(standby.volumeCalls.every((value) => value == 0), isTrue);
        active.emitPosition(const Duration(seconds: 43));
        standby.emitDuration(const Duration(minutes: 3));
        expect(await upgrade, isTrue);
        expect(standby.seekCalls.first, const Duration(seconds: 43));
        expect(service.currentSnapshot.position, const Duration(seconds: 43));
      },
    );

    test(
      'keeps the upgrade muted until the decoder confirms the seek',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend()
          ..durationOnOpen = const Duration(minutes: 3)
          ..acknowledgeSeeks = false;
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);
        await _playAndComplete(service, active, 'a');
        active
          ..emitDuration(const Duration(minutes: 3))
          ..emitPosition(const Duration(seconds: 41));
        await _drainEvents();
        final upgrade = service.upgradeRemoteSource(_upgradeSource());
        await _waitUntil(() => standby.openCalls.isNotEmpty);
        standby.completeOpen(0);
        await _waitUntil(() => standby.seekCalls.isNotEmpty);
        standby.emitPosition(Duration.zero);
        await _drainEvents();
        expect(standby.playCalls, 0);
        expect(standby.volumeCalls.every((value) => value == 0), isTrue);
        expect(service.currentSnapshot.position, const Duration(seconds: 41));
        standby.emitPosition(const Duration(seconds: 41));
        expect(await upgrade, isTrue);
        expect(service.currentSnapshot.position, const Duration(seconds: 41));
      },
    );

    test('an ignored native seek retains the original source', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend()
        ..durationOnOpen = const Duration(minutes: 3)
        ..acknowledgeSeeks = false;
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
        operationTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(service.dispose);
      await _playAndComplete(service, active, 'a');
      active
        ..emitDuration(const Duration(minutes: 3))
        ..emitPosition(const Duration(seconds: 41));
      await _drainEvents();
      final upgrade = service.upgradeRemoteSource(_upgradeSource());
      await _waitUntil(() => standby.openCalls.isNotEmpty);
      standby.completeOpen(0);
      expect(await upgrade, isFalse);
      expect(standby.playCalls, 0);
      expect(active.openCalls, hasLength(1));
      expect(active.stopCalls, 0);
      expect(service.currentSnapshot.status, PlayerStatus.playing);
      expect(service.currentSnapshot.position, const Duration(seconds: 41));
    });

    test(
      'keeps the original audible until a muted aligned deck is ready',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend()
          ..durationOnOpen = const Duration(minutes: 3);
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);
        await _playAndComplete(service, active, 'a');
        await service.setVolume(.65);
        active
          ..emitDuration(const Duration(minutes: 3))
          ..emitPosition(const Duration(seconds: 41));
        await _drainEvents();
        final original = service.currentSnapshot;
        final snapshots = <PlayerSnapshot>[];
        final subscription = service.snapshotStream.listen(snapshots.add);
        final upgrade = service.upgradeRemoteSource(_upgradeSource());
        await _waitUntil(() => standby.openCalls.isNotEmpty);
        expect(standby.openCalls.single.play, isFalse);
        expect(standby.volumeCalls, [0]);
        expect(active.pauseCalls, 0);
        expect(active.stopCalls, 0);
        active.emitPosition(const Duration(seconds: 43));
        await _drainEvents();
        standby.completeOpen(0);
        expect(await upgrade, isTrue);
        expect(service.crossfadeEnabled, isFalse);
        expect(standby.seekCalls, [const Duration(seconds: 43)]);
        expect(standby.playCalls, 1);
        expect(service.currentSnapshot.trackId, original.trackId);
        expect(service.currentSnapshot.queueEntryId, original.queueEntryId);
        expect(service.currentSnapshot.sourceUrl, original.sourceUrl);
        expect(service.currentSnapshot.title, original.title);
        expect(service.currentSnapshot.position, const Duration(seconds: 43));
        expect(service.currentSnapshot.volume, .65);
        expect(
          snapshots.every(
            (snapshot) => snapshot.status == PlayerStatus.playing,
          ),
          isTrue,
        );
        expect(active.openCalls, hasLength(1));
        active.emitPosition(const Duration(seconds: 99));
        standby.emitPosition(const Duration(seconds: 44));
        await _drainEvents();
        expect(service.currentSnapshot.position, const Duration(seconds: 44));
        await subscription.cancel();
      },
    );

    for (final liveClockAvailable in [true, false]) {
      test(
        'uses live native position instead of stale UI ticks (available=$liveClockAvailable)',
        () async {
          final active = _LiveClockBackend(available: liveClockAvailable);
          final standby = _FakeMediaKitBackend()
            ..durationOnOpen = const Duration(minutes: 3);
          final service = MediaKitPlayerService(
            backend: active,
            backendFactory: () => standby,
          );
          addTearDown(service.dispose);
          await _playAndComplete(service, active, 'a');
          active
            ..emitDuration(const Duration(minutes: 3))
            ..emitPosition(const Duration(seconds: 41));
          await _drainEvents();
          final upgrade = service.upgradeRemoteSource(_upgradeSource());
          await _waitUntil(() => standby.openCalls.isNotEmpty);
          standby.completeOpen(0);
          expect(await upgrade, isTrue);
          expect(active.clock.reads, 2);
          expect(
            standby.seekCalls,
            liveClockAvailable
                ? [
                    const Duration(milliseconds: 43250),
                    const Duration(milliseconds: 43410),
                  ]
                : [const Duration(seconds: 41)],
          );
          expect(
            service.currentSnapshot.position,
            liveClockAvailable
                ? const Duration(milliseconds: 43410)
                : const Duration(seconds: 41),
          );
          expect(active.pauseCalls, 0);
          expect(active.openCalls, hasLength(1));
        },
      );
    }

    for (final action in ['pause', 'seek', 'volume', 'next', 'stale']) {
      test('$action cancels a preparing upgrade without playing it', () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend()
          ..durationOnOpen = const Duration(minutes: 3);
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);
        await _playAndComplete(service, active, 'a');
        active
          ..emitDuration(const Duration(minutes: 3))
          ..emitPosition(const Duration(seconds: 41));
        await _drainEvents();
        var current = true;
        final upgrade = service.upgradeRemoteSource(
          _upgradeSource(),
          shouldContinue: () => current,
        );
        await _waitUntil(() => standby.openCalls.isNotEmpty);
        switch (action) {
          case 'pause':
            await service.pause();
          case 'seek':
            await service.seek(const Duration(seconds: 72));
          case 'volume':
            await service.setVolume(.2);
          case 'next':
            final previousLoads = active.openCalls.length;
            final play = service.playRemote(_track('next'));
            await _waitUntil(() => active.openCalls.length > previousLoads);
            active.completeOpen(previousLoads);
            await play;
          case 'stale':
            current = false;
        }
        standby.completeOpen(0);
        expect(await upgrade, isFalse);
        expect(standby.playCalls, 0);
        expect(active.stopCalls, 0);
        expect(
          service.currentSnapshot.trackId,
          action == 'next' ? 'next' : 'a',
        );
        if (action == 'pause') {
          expect(service.currentSnapshot.status, PlayerStatus.paused);
        }
        if (action == 'seek') {
          expect(active.seekCalls.last, const Duration(seconds: 72));
        }
        if (action == 'volume') expect(service.currentSnapshot.volume, .2);
      });
    }

    test('standby failure retains current playback without a reload', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend()
        ..durationOnOpen = const Duration(minutes: 3);
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);
      await _playAndComplete(service, active, 'a');
      active.emitDuration(const Duration(minutes: 3));
      await _drainEvents();
      final upgrade = service.upgradeRemoteSource(_upgradeSource());
      await _waitUntil(() => standby.openCalls.isNotEmpty);
      standby.openCalls.single.completer.completeError(
        StateError('bad upgrade'),
      );
      expect(await upgrade, isFalse);
      expect(service.currentSnapshot.status, PlayerStatus.playing);
      expect(service.currentSnapshot.trackId, 'a');
      expect(active.openCalls, hasLength(1));
      expect(active.pauseCalls, 0);
    });
  });

  group('dual-deck crossfade', () {
    test(
      'preloads silently, hands off, and ignores the retired deck',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);

        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );

        final preparation = service.prepareCrossfade(_crossfadeSource('b'));
        await _waitUntil(() => standby.openCalls.length == 1);
        expect(standby.openCalls.single.play, isFalse);
        expect(standby.volumeCalls, [0]);

        standby
          ..emitPosition(const Duration(seconds: 17))
          ..emitDuration(const Duration(minutes: 4));
        await _drainEvents();
        expect(service.currentSnapshot.trackId, 'a');
        expect(service.currentSnapshot.position, Duration.zero);

        standby.completeOpen(0);
        await preparation;
        active
          ..emitDuration(const Duration(seconds: 2))
          ..emitPosition(const Duration(milliseconds: 1600));

        await _waitUntil(() => standby.playCalls == 1);
        await _waitUntil(() => service.currentSnapshot.trackId == 'b');

        expect(active.stopCalls, 0);
        await _waitUntil(() => active.stopCalls == 1);
        expect(active.abandonCalls, 0);
        expect(service.currentSnapshot.status, PlayerStatus.playing);
        expect(service.currentSnapshot.position, const Duration(seconds: 17));
        expect(service.currentSnapshot.duration, const Duration(minutes: 4));

        active
          ..emitPosition(const Duration(seconds: 99))
          ..emitDuration(const Duration(hours: 1))
          ..emitPlaying(false)
          ..emitCompleted()
          ..emitError('retired deck failure');
        await _drainEvents();
        expect(service.currentSnapshot.trackId, 'b');
        expect(service.currentSnapshot.position, const Duration(seconds: 17));
        expect(service.currentSnapshot.status, PlayerStatus.playing);

        standby.emitPosition(const Duration(seconds: 18));
        await _drainEvents();
        expect(service.currentSnapshot.position, const Duration(seconds: 18));
      },
    );

    test('reuses the retired deck without a delayed stop race', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);

      await _playAndComplete(service, active, 'a');
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');
      active
        ..emitDuration(const Duration(seconds: 2))
        ..emitPosition(const Duration(milliseconds: 1600));
      await _waitUntil(() => service.currentSnapshot.trackId == 'b');

      expect(active.stopCalls, 0);
      final preparation = service.prepareCrossfade(_crossfadeSource('c'));
      await _waitUntil(() => active.openCalls.length == 2);
      expect(active.stopCalls, 0);
      active.completeOpen(1);
      await preparation;

      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        active.stopCalls,
        0,
        reason: 'The cancelled retirement must not stop the newly prepared C.',
      );
    });

    test('keeps deck gains bounded by a changed master volume', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);

      await _playAndComplete(service, active, 'a');
      await service.setVolume(0.6);
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');

      final outgoingStart = active.volumeCalls.length;
      final incomingStart = standby.volumeCalls.length;
      active
        ..emitDuration(const Duration(seconds: 2))
        ..emitPosition(const Duration(milliseconds: 1600));
      await _waitUntil(
        () =>
            active.volumeCalls.length > outgoingStart + 1 &&
            standby.volumeCalls.length > incomingStart + 1,
      );

      final outgoingAtSixty = active.volumeCalls.sublist(outgoingStart);
      final incomingAtSixty = standby.volumeCalls.sublist(incomingStart);
      final pairedCount = outgoingAtSixty.length < incomingAtSixty.length
          ? outgoingAtSixty.length
          : incomingAtSixty.length;
      var hasAudibleEarlyOverlap = false;
      for (var index = 0; index < pairedCount; index++) {
        expect(outgoingAtSixty[index], inInclusiveRange(0, 60.001));
        expect(incomingAtSixty[index], inInclusiveRange(0, 60.001));
        if (outgoingAtSixty[index] > 60 * 0.8 &&
            incomingAtSixty[index] > 60 * 0.2) {
          hasAudibleEarlyOverlap = true;
        }
        expect(
          outgoingAtSixty[index] * outgoingAtSixty[index] +
              incomingAtSixty[index] * incomingAtSixty[index],
          closeTo(60 * 60, 0.2),
        );
      }
      expect(hasAudibleEarlyOverlap, isTrue);

      await service.setVolume(0.4);
      final outgoingAtForty = active.volumeCalls.length;
      final incomingAtForty = standby.volumeCalls.length;
      await _waitUntil(
        () =>
            active.volumeCalls.length > outgoingAtForty &&
            standby.volumeCalls.length > incomingAtForty,
      );
      expect(service.currentSnapshot.volume, 0.4);
      expect(
        active.volumeCalls.sublist(outgoingAtForty),
        everyElement(inInclusiveRange(0, 40.001)),
      );
      expect(
        standby.volumeCalls.sublist(incomingAtForty),
        everyElement(inInclusiveRange(0, 40.001)),
      );

      await _waitUntil(() => service.currentSnapshot.trackId == 'b');
      expect(service.currentSnapshot.volume, 0.4);
      expect(standby.volumeCalls.last, closeTo(40, 0.001));
    });

    test(
      'a promotion gain failure leaves the outgoing deck authoritative',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);

        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );
        await _prepareAndComplete(service, standby, 'b');
        standby
          ..failVolumeValue = 100
          ..failVolumeOccurrence = 2;
        active
          ..emitDuration(const Duration(seconds: 2))
          ..emitPosition(const Duration(milliseconds: 1600));

        await _waitUntil(() => standby.stopCalls == 1);
        expect(standby.abandonCalls, 0);
        expect(service.currentSnapshot.trackId, 'a');
        expect(active.volumeCalls.last, closeTo(100, 0.001));

        active.emitPosition(const Duration(milliseconds: 1750));
        await _drainEvents();
        expect(
          service.currentSnapshot.position,
          const Duration(milliseconds: 1750),
        );
      },
    );

    test('disabling a ready transition clears it without a handoff', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);

      await _playAndComplete(service, active, 'a');
      await service.setVolume(0.7);
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');

      await service.configureCrossfade(
        enabled: false,
        duration: const Duration(milliseconds: 400),
      );
      active
        ..emitDuration(const Duration(seconds: 2))
        ..emitPosition(const Duration(milliseconds: 1600));
      await Future<void>.delayed(const Duration(milliseconds: 450));

      expect(service.crossfadeEnabled, isFalse);
      expect(service.currentSnapshot.trackId, 'a');
      expect(standby.playCalls, 0);
      expect(standby.abandonCalls, 0);
      expect(standby.stopCalls, 1);
      expect(active.volumeCalls.last, closeTo(70, 0.001));
    });

    test(
      'disabling during a fade finishes the handoff then turns it off',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);

        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );
        await _prepareAndComplete(service, standby, 'b');
        active
          ..emitDuration(const Duration(seconds: 2))
          ..emitPosition(const Duration(milliseconds: 1600));
        await _waitUntil(() => standby.playCalls == 1);

        await service.configureCrossfade(
          enabled: false,
          duration: const Duration(milliseconds: 400),
        );
        expect(service.crossfadeEnabled, isTrue);

        await _waitUntil(() => service.currentSnapshot.trackId == 'b');
        expect(service.crossfadeEnabled, isFalse);
        await _waitUntil(() => active.stopCalls == 1);
        expect(active.abandonCalls, 0);
      },
    );

    test('a failed fade still honors a disable made during overlap', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);

      await _playAndComplete(service, active, 'a');
      await service.setVolume(0.63);
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');
      active
        ..emitDuration(const Duration(seconds: 2))
        ..emitPosition(const Duration(milliseconds: 1600));
      await _waitUntil(() => standby.volumeCalls.any((volume) => volume > 0));

      await service.configureCrossfade(
        enabled: false,
        duration: const Duration(milliseconds: 400),
      );
      expect(service.crossfadeEnabled, isTrue);
      standby.emitError('standby failed during overlap');

      await _waitUntil(() => standby.stopCalls == 1);
      expect(standby.abandonCalls, 0);
      expect(service.crossfadeEnabled, isFalse);
      expect(service.currentSnapshot.trackId, 'a');
      expect(active.volumeCalls.last, closeTo(63, 0.001));
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(service.currentSnapshot.trackId, 'a');
    });

    test('a seek during a deferred disable keeps crossfade off', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);

      await _playAndComplete(service, active, 'a');
      await service.setVolume(0.66);
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');
      active
        ..emitDuration(const Duration(seconds: 2))
        ..emitPosition(const Duration(milliseconds: 1600));
      await _waitUntil(() => standby.volumeCalls.any((volume) => volume > 0));

      await service.configureCrossfade(
        enabled: false,
        duration: const Duration(milliseconds: 400),
      );
      expect(service.crossfadeEnabled, isTrue);
      await service.seek(Duration.zero);

      expect(service.crossfadeEnabled, isFalse);
      expect(service.currentSnapshot.trackId, 'a');
      expect(service.currentSnapshot.position, Duration.zero);
      expect(active.seekCalls, [Duration.zero]);
      expect(active.volumeCalls.last, closeTo(66, 0.001));
      expect(standby.abandonCalls, 0);
      expect(standby.stopCalls, 1);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(service.currentSnapshot.trackId, 'a');
    });

    test('disabling cancels a blocked standby preload immediately', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);

      await _playAndComplete(service, active, 'a');
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      final preparation = service.prepareCrossfade(_crossfadeSource('b'));
      await _waitUntil(() => standby.openCalls.length == 1);

      await service.configureCrossfade(
        enabled: false,
        duration: const Duration(milliseconds: 400),
      );
      await preparation.timeout(const Duration(seconds: 1));

      expect(service.crossfadeEnabled, isFalse);
      expect(service.currentSnapshot.trackId, 'a');
      expect(standby.abandonCalls, 1);
      expect(standby.playCalls, 0);
    });

    test(
      'rapid seeks abandon one blocked preload and commit only zero',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);

        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );
        final preparation = service.prepareCrossfade(_crossfadeSource('b'));
        await _waitUntil(() => standby.openCalls.length == 1);
        expect(standby.volumeCalls, [0]);

        await Future.wait([
          service.seek(const Duration(seconds: 1)),
          service.seek(const Duration(milliseconds: 250)),
          service.seek(Duration.zero),
        ]);
        await preparation;

        expect(standby.abandonCalls, 1);
        expect(standby.stopCalls, 0);
        expect(standby.volumeCalls, [0]);
        expect(active.seekCalls, [Duration.zero]);
        expect(service.currentSnapshot.position, Duration.zero);
        expect(service.currentSnapshot.trackId, 'a');
      },
    );

    test(
      'seeking to zero during overlap cancels it without abandoning libmpv',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);

        await _playAndComplete(service, active, 'a');
        await service.setVolume(0.57);
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );
        await _prepareAndComplete(service, standby, 'b');
        active
          ..emitDuration(const Duration(seconds: 2))
          ..emitPosition(const Duration(milliseconds: 1600));
        await _waitUntil(() => standby.volumeCalls.any((volume) => volume > 0));

        await service.seek(Duration.zero);

        expect(active.seekCalls, [Duration.zero]);
        expect(service.currentSnapshot.position, Duration.zero);
        expect(standby.abandonCalls, 0);
        expect(standby.stopCalls, 1);
        expect(active.volumeCalls.last, closeTo(57, 0.001));
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(service.currentSnapshot.trackId, 'a');
        expect(standby.playCalls, 1);
      },
    );

    test('seek to zero waits for an in-flight promotion boundary', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);

      await _playAndComplete(service, active, 'a');
      await service.setVolume(0.62);
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');
      standby
        ..blockVolumeValue = 62
        ..blockVolumeOccurrence = 2;
      active
        ..emitDuration(const Duration(seconds: 2))
        ..emitPosition(const Duration(milliseconds: 1600));
      await _waitUntil(
        () => standby.blockedVolumeStarted?.isCompleted ?? false,
      );

      final seek = service.seek(Duration.zero);
      await _drainEvents();
      expect(active.seekCalls, isEmpty);
      standby.releaseBlockedVolume!.complete();
      await seek;

      expect(active.seekCalls, [Duration.zero]);
      expect(service.currentSnapshot.trackId, 'a');
      expect(service.currentSnapshot.position, Duration.zero);
      expect(standby.abandonCalls, 0);
    });

    test('pause freezes both decks and resume continues both', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );
      addTearDown(service.dispose);

      await _playAndComplete(service, active, 'a');
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');
      active
        ..emitDuration(const Duration(seconds: 2))
        ..emitPosition(const Duration(milliseconds: 1600));
      await _waitUntil(() => standby.playCalls == 1);

      await service.pause();
      expect(active.pauseCalls, 1);
      expect(standby.pauseCalls, 1);
      expect(service.currentSnapshot.status, PlayerStatus.paused);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(service.currentSnapshot.trackId, 'a');

      await service.resume();
      expect(active.playCalls, 1);
      expect(standby.playCalls, 2);
      expect(service.currentSnapshot.status, PlayerStatus.playing);
      await _waitUntil(() => service.currentSnapshot.trackId == 'b');
    });

    test(
      'stop during a fade stops both decks and prevents promotion',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );
        addTearDown(service.dispose);

        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );
        await _prepareAndComplete(service, standby, 'b');
        active
          ..emitDuration(const Duration(seconds: 2))
          ..emitPosition(const Duration(milliseconds: 1600));
        await _waitUntil(() => standby.playCalls == 1);

        await service.stop();
        expect(active.stopCalls, 1);
        expect(standby.stopCalls, 1);
        expect(service.currentSnapshot.trackId, 'a');
        expect(service.currentSnapshot.status, PlayerStatus.stopped);
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(service.currentSnapshot.trackId, 'a');
        expect(service.currentSnapshot.status, PlayerStatus.stopped);
      },
    );

    test('dispose releases the active and prepared standby decks', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );

      await _playAndComplete(service, active, 'a');
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');

      await service.dispose();
      expect(active.disposed, isTrue);
      expect(standby.disposed, isTrue);
      expect(standby.abandonCalls, 0);
    });

    test(
      'dispose waits for an overlapping ramp before releasing decks',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );

        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );
        await _prepareAndComplete(service, standby, 'b');
        active
          ..emitDuration(const Duration(seconds: 2))
          ..emitPosition(const Duration(milliseconds: 1600));
        await _waitUntil(() => standby.volumeCalls.any((volume) => volume > 0));

        await service.dispose().timeout(const Duration(seconds: 1));

        expect(active.disposed, isTrue);
        expect(standby.disposed, isTrue);
        expect(active.abandonCalls, 0);
        expect(standby.abandonCalls, 0);
      },
    );

    test('dispose waits for a promotion command already in flight', () async {
      final active = _FakeMediaKitBackend();
      final standby = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(
        backend: active,
        backendFactory: () => standby,
      );

      await _playAndComplete(service, active, 'a');
      await service.setVolume(0.62);
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 400),
      );
      await _prepareAndComplete(service, standby, 'b');
      standby
        ..blockVolumeValue = 62
        ..blockVolumeOccurrence = 2;
      active
        ..emitDuration(const Duration(seconds: 2))
        ..emitPosition(const Duration(milliseconds: 1600));
      await _waitUntil(
        () => standby.blockedVolumeStarted?.isCompleted ?? false,
      );

      var disposeCompleted = false;
      final dispose = service.dispose().whenComplete(
        () => disposeCompleted = true,
      );
      await _drainEvents();
      expect(disposeCompleted, isFalse);
      expect(active.disposed, isFalse);
      expect(standby.disposed, isFalse);

      standby.releaseBlockedVolume!.complete();
      await dispose.timeout(const Duration(seconds: 1));
      expect(active.disposed, isTrue);
      expect(standby.disposed, isTrue);
      expect(active.abandonCalls, 0);
      expect(standby.abandonCalls, 0);
    });

    test(
      'dispose abandons a blocked standby preload before teardown',
      () async {
        final active = _FakeMediaKitBackend();
        final standby = _FakeMediaKitBackend();
        final service = MediaKitPlayerService(
          backend: active,
          backendFactory: () => standby,
        );

        await _playAndComplete(service, active, 'a');
        await service.configureCrossfade(
          enabled: true,
          duration: const Duration(milliseconds: 400),
        );
        final preparation = service.prepareCrossfade(_crossfadeSource('b'));
        await _waitUntil(() => standby.openCalls.length == 1);

        await service.dispose().timeout(const Duration(seconds: 1));
        await preparation.timeout(const Duration(seconds: 1));

        expect(standby.abandonCalls, 1);
        expect(active.disposed, isTrue);
        expect(standby.disposed, isTrue);
      },
    );
  });
}

TrackInfo _track(
  String id, {
  String? streamExtension,
  Map<String, String>? httpHeaders,
  Duration? duration,
}) => TrackInfo(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  url: 'https://www.youtube.com/watch?v=$id',
  streamUrl: 'https://media.example/$id',
  streamExtension: streamExtension,
  httpHeaders: httpHeaders,
  duration: duration,
);

RemotePlaybackSource _upgradeSource() {
  final track = _track('a', duration: const Duration(minutes: 3)).copyWith(
    streamUrl: 'https://quality.example/a.m4a',
    streamBitrate: 320000,
    streamExtension: 'm4a',
    streamCodec: 'aac',
  );
  return RemotePlaybackSource(
    track: track,
    uri: Uri.parse(track.streamUrl!),
    queueEntryId: 'queue-a',
  );
}

RemoteCrossfadePlaybackSource _crossfadeSource(String id) {
  final track = _track(id, duration: const Duration(minutes: 3));
  return RemoteCrossfadePlaybackSource(
    RemotePlaybackSource(
      track: track,
      uri: Uri.parse(track.streamUrl!),
      queueEntryId: 'queue-$id',
    ),
  );
}

Future<void> _playAndComplete(
  MediaKitPlayerService service,
  _FakeMediaKitBackend backend,
  String id,
) async {
  final play = service.playRemote(_track(id));
  await _waitUntil(() => backend.openCalls.isNotEmpty);
  backend.completeOpen(backend.openCalls.length - 1);
  await play;
}

Future<void> _prepareAndComplete(
  MediaKitPlayerService service,
  _FakeMediaKitBackend standby,
  String id,
) async {
  final preparation = service.prepareCrossfade(_crossfadeSource(id));
  await _waitUntil(() => standby.openCalls.isNotEmpty);
  standby.completeOpen(standby.openCalls.length - 1);
  await preparation;
}

Future<void> _drainEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition did not become true.');
}

class _OpenCall {
  _OpenCall(this.media, this.session, {required this.play});
  final Media media;
  final int session;
  final bool play;
  final completer = Completer<void>();
}

class _LiveClockBackend extends _FakeMediaKitBackend {
  _LiveClockBackend({required bool available})
    : clock = _NativeClock(available);
  final _NativeClock clock;
  @override
  Object? get platform => clock;
}

class _NativeClock implements NativePlayer {
  _NativeClock(this.available);
  final bool available;
  int reads = 0;
  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async {
    expect(property, 'time-pos');
    reads++;
    if (!available) throw StateError('No native clock');
    return reads == 1 ? '43.25' : '43.41';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AudioOutputBackend extends _FakeMediaKitBackend
    implements PlayerAudioOutput {
  static const availableDevices = [
    PlayerAudioDevice(id: 'usb', name: 'USB speakers'),
    PlayerAudioDevice(id: 'headphones', name: 'Headphones'),
  ];
  final outputs = StreamController<PlayerAudioOutputState>.broadcast();
  List<PlayerAudioDevice> devices = availableDevices;
  String selectedDeviceId = systemDefaultAudioDeviceId;
  String? failRoute;
  String? blockedRoute;
  Completer<void>? releaseRoute;
  final routeCalls = <String>[];
  final routesAtOpen = <String>[];

  @override
  PlayerAudioOutputState get audioOutputState => PlayerAudioOutputState(
    supported: true,
    devices: devices,
    selectedDeviceId: selectedDeviceId,
  );

  @override
  Stream<PlayerAudioOutputState> get audioOutputStream => outputs.stream;

  @override
  Future<void> selectAudioOutput(String deviceId) async {
    routeCalls.add(deviceId);
    final requestSession = session;
    if (deviceId == blockedRoute) await releaseRoute!.future;
    if (requestSession != session) throw StateError('Route request cancelled');
    if (deviceId == failRoute) throw StateError('Injected output failure');
    selectedDeviceId = deviceId;
    outputs.add(audioOutputState);
  }

  void updateDevices(List<PlayerAudioDevice> value) {
    devices = value;
    outputs.add(audioOutputState);
  }

  @override
  Future<void> open(Media media, {required bool play}) {
    routesAtOpen.add(selectedDeviceId);
    return super.open(media, play: play);
  }

  @override
  Future<void> dispose() async {
    await outputs.close();
    await super.dispose();
  }
}

class _EqualizerBackend extends _AudioOutputBackend
    implements EqualizerCapablePlayer {
  EqualizerSettings equalizer = const EqualizerSettings();
  final equalizerCalls = <EqualizerSettings>[];
  final equalizersAtOpen = <EqualizerSettings>[];
  Completer<void>? releaseEqualizer;
  bool failEqualizer = false;

  @override
  bool get supportsEqualizer => true;

  @override
  Future<void> configureEqualizer(EqualizerSettings settings) async {
    equalizerCalls.add(settings);
    final barrier = releaseEqualizer;
    if (barrier != null) await barrier.future;
    if (failEqualizer) throw StateError('Injected optional filter failure');
    equalizer = settings;
  }

  @override
  Future<void> open(Media media, {required bool play}) {
    equalizersAtOpen.add(equalizer);
    return super.open(media, play: play);
  }
}

class _InitialPositionBackend extends _FakeMediaKitBackend {
  final playbackCommands = <String>[];
  final seekStarted = Completer<void>();
  Completer<void>? seekBarrier;

  @override
  Future<void> open(Media media, {required bool play}) {
    playbackCommands.add('open:$play');
    return super.open(media, play: play);
  }

  @override
  Future<void> seek(Duration position) async {
    playbackCommands.add('seek:${position.inMilliseconds}');
    await super.seek(position);
    if (!seekStarted.isCompleted) seekStarted.complete();
    await seekBarrier?.future;
  }

  @override
  Future<void> play() async {
    playbackCommands.add('play');
    await super.play();
  }
}

class _FakeMediaKitBackend implements MediaKitPlayerBackend {
  @override
  bool completed = false;
  Duration? durationOnOpen;
  bool acknowledgeSeeks = true;
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final volumes = StreamController<double>.broadcast();
  final bufferings = StreamController<bool>.broadcast();
  final playings = StreamController<bool>.broadcast();
  final completions = StreamController<bool>.broadcast();
  final errors = StreamController<String>.broadcast();
  final openCalls = <_OpenCall>[];

  int session = 0;
  int abandonCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;
  int playCalls = 0;
  final volumeCalls = <double>[];
  final seekCalls = <Duration>[];
  String? currentSourceId;
  bool disposed = false;
  double? failVolumeValue;
  int failVolumeOccurrence = 1;
  int _matchingVolumeCalls = 0;
  double? blockVolumeValue;
  int blockVolumeOccurrence = 1;
  int _matchingBlockedVolumeCalls = 0;
  Completer<void>? blockedVolumeStarted;
  Completer<void>? releaseBlockedVolume;

  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration> get durationStream => durations.stream;
  @override
  Stream<double> get volumeStream => volumes.stream;
  @override
  Stream<bool> get bufferingStream => bufferings.stream;
  @override
  Stream<bool> get playingStream => playings.stream;
  @override
  Stream<bool> get completedStream => completions.stream;
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  Object? get platform => null;

  @override
  void abandonPendingOperations() {
    abandonCalls++;
    session++;
    currentSourceId = null;
  }

  @override
  Future<void> open(Media media, {required bool play}) {
    completed = false;
    final call = _OpenCall(media, session, play: play);
    openCalls.add(call);
    return call.completer.future;
  }

  void completeOpen(int index) {
    final call = openCalls[index];
    if (call.session == session) currentSourceId = _id(call.media);
    call.completer.complete();
    final duration = durationOnOpen;
    if (duration != null) emitDuration(duration);
  }

  void emitErrorForSession(int sourceSession, String message) {
    if (sourceSession == session) errors.add(message);
  }

  void emitPosition(Duration position) => positions.add(position);

  void emitDuration(Duration duration) => durations.add(duration);

  void emitPlaying(bool playing) => playings.add(playing);

  void emitCompleted() => completions.add(true);

  void emitError(String message) => errors.add(message);

  String _id(Media media) =>
      Uri.parse(media.uri).pathSegments.last.split('.').first;

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
    if (acknowledgeSeeks) emitPosition(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumeCalls.add(volume);
    final blockingValue = blockVolumeValue;
    if (blockingValue != null && (volume - blockingValue).abs() <= 0.001) {
      _matchingBlockedVolumeCalls++;
      if (_matchingBlockedVolumeCalls == blockVolumeOccurrence) {
        blockVolumeValue = null;
        blockedVolumeStarted = Completer<void>()..complete();
        releaseBlockedVolume = Completer<void>();
        await releaseBlockedVolume!.future;
      }
    }
    final failingValue = failVolumeValue;
    if (failingValue != null && (volume - failingValue).abs() <= 0.001) {
      _matchingVolumeCalls++;
      if (_matchingVolumeCalls == failVolumeOccurrence) {
        failVolumeValue = null;
        throw StateError('injected volume failure');
      }
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    currentSourceId = null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    final blockedVolume = releaseBlockedVolume;
    if (blockedVolume != null && !blockedVolume.isCompleted) {
      blockedVolume.complete();
    }
    await Future.wait<void>([
      positions.close(),
      durations.close(),
      volumes.close(),
      bufferings.close(),
      playings.close(),
      completions.close(),
      errors.close(),
    ]);
  }
}
