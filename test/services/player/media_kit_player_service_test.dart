import 'dart:async';

import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/player/media_kit_player_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
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

class _FakeMediaKitBackend implements MediaKitPlayerBackend {
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
    final call = _OpenCall(media, session, play: play);
    openCalls.add(call);
    return call.completer.future;
  }

  void completeOpen(int index) {
    final call = openCalls[index];
    if (call.session == session) currentSourceId = _id(call.media);
    call.completer.complete();
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
