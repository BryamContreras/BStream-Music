import 'dart:async';

import 'package:bstream_music/services/player/crossfade_transition.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('crossfadeConfigurationDecision', () {
    test('defers disable only while both decks are audible', () {
      final decision = crossfadeConfigurationDecision(
        currentEnabled: true,
        overlapActive: true,
        requestedEnabled: false,
      );

      expect(decision.enabled, isTrue);
      expect(decision.disableAfterHandoff, isTrue);
      expect(decision.action, CrossfadeConfigurationAction.deferDisable);
    });

    test('reset and start checks are backend-neutral', () {
      expect(
        crossfadeConfigurationDecision(
          currentEnabled: true,
          overlapActive: false,
          requestedEnabled: false,
        ).action,
        CrossfadeConfigurationAction.reset,
      );
      expect(
        crossfadeConfigurationDecision(
          currentEnabled: true,
          overlapActive: false,
          requestedEnabled: true,
        ).action,
        CrossfadeConfigurationAction.checkStart,
      );
    });
  });

  group('crossfadeStartDuration', () {
    test('starts inside the configured window and clamps short remainder', () {
      final normal = crossfadeStartDuration(
        enabled: true,
        disposed: false,
        overlapActive: false,
        promotionInProgress: false,
        sourcePrepared: true,
        standbyReady: true,
        playing: true,
        trackDuration: const Duration(seconds: 100),
        position: const Duration(seconds: 95),
        configuredDuration: const Duration(seconds: 5),
      );
      final late = crossfadeStartDuration(
        enabled: true,
        disposed: false,
        overlapActive: false,
        promotionInProgress: false,
        sourcePrepared: true,
        standbyReady: true,
        playing: true,
        trackDuration: const Duration(seconds: 100),
        position: const Duration(seconds: 97),
        configuredDuration: const Duration(seconds: 5),
      );

      expect(normal, const Duration(seconds: 5));
      expect(late, const Duration(seconds: 3));
    });

    test('rejects unsafe, inactive and already-running transitions', () {
      Duration? decide({
        bool enabled = true,
        bool overlapActive = false,
        bool playing = true,
        Duration position = const Duration(seconds: 95),
      }) => crossfadeStartDuration(
        enabled: enabled,
        disposed: false,
        overlapActive: overlapActive,
        promotionInProgress: false,
        sourcePrepared: true,
        standbyReady: true,
        playing: playing,
        trackDuration: const Duration(seconds: 100),
        position: position,
        configuredDuration: const Duration(seconds: 5),
      );

      expect(decide(enabled: false), isNull);
      expect(decide(overlapActive: true), isNull);
      expect(decide(playing: false), isNull);
      expect(decide(position: const Duration(milliseconds: 99700)), isNull);
    });
  });

  group('crossfadeGains', () {
    test('returns the expected gains at 0, 50, and 100 percent', () {
      final start = crossfadeGains(masterVolume: 0.8, progress: 0);
      final middle = crossfadeGains(masterVolume: 0.8, progress: 0.5);
      final end = crossfadeGains(masterVolume: 0.8, progress: 1);

      expect(start.outgoing, 0.8);
      expect(start.incoming, 0);
      expect(middle.outgoing, closeTo(0.8 / sqrt2, 1e-12));
      expect(middle.incoming, closeTo(0.8 / sqrt2, 1e-12));
      expect(end.outgoing, 0);
      expect(end.incoming, 0.8);
    });

    test('brings the incoming track up clearly during the first tenth', () {
      final early = crossfadeGains(masterVolume: 1, progress: 0.1);

      expect(early.outgoing, greaterThan(0.9));
      expect(early.incoming, greaterThan(0.3));
    });

    test('clamps master volume and progress to their valid ranges', () {
      final belowRange = crossfadeGains(masterVolume: -2, progress: -3);
      final aboveRange = crossfadeGains(masterVolume: 4, progress: 7);

      expect(belowRange.outgoing, 0);
      expect(belowRange.incoming, 0);
      expect(aboveRange.outgoing, 0);
      expect(aboveRange.incoming, 1);
    });

    test('never exceeds master volume throughout the transition', () {
      for (final master in [0.0, 0.1, 0.35, 0.72, 1.0]) {
        for (var step = 0; step <= 100; step++) {
          final gains = crossfadeGains(
            masterVolume: master,
            progress: step / 100,
          );

          expect(gains.outgoing, inInclusiveRange(0, master));
          expect(gains.incoming, inInclusiveRange(0, master));
          expect(
            gains.outgoing * gains.outgoing + gains.incoming * gains.incoming,
            closeTo(master * master, 1e-12),
          );
        }
      }
    });
  });

  group('CrossfadeRamp', () {
    testWidgets('applies exact gains at 0, 50, and 100 percent', (
      tester,
    ) async {
      final watch = _FakeStopwatch();
      final applied = <CrossfadeGains>[];
      final ramp = CrossfadeRamp(
        duration: const Duration(seconds: 10),
        tickInterval: const Duration(milliseconds: 40),
        stopwatchFactory: () => watch,
        applyGains: (gains) async => applied.add(gains),
      );

      final completion = ramp.start();
      await tester.pump();
      _expectGains(applied.single, outgoing: 1, incoming: 0);
      expect(ramp.progress, 0);
      expect(ramp.isRunning, isTrue);

      watch.elapse(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 40));
      _expectGains(applied.last, outgoing: 1 / sqrt2, incoming: 1 / sqrt2);
      expect(ramp.progress, 0.5);

      watch.elapse(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 40));
      _expectGains(applied.last, outgoing: 0, incoming: 1);
      expect(await completion, isTrue);
      expect(ramp.progress, 1);
      expect(ramp.isRunning, isFalse);

      final callCount = applied.length;
      await tester.pump(const Duration(seconds: 1));
      expect(applied, hasLength(callCount));
    });

    testWidgets('pause freezes progress and resume continues the same ramp', (
      tester,
    ) async {
      final watch = _FakeStopwatch();
      final applied = <CrossfadeGains>[];
      final ramp = CrossfadeRamp(
        duration: const Duration(seconds: 4),
        tickInterval: const Duration(milliseconds: 40),
        stopwatchFactory: () => watch,
        applyGains: (gains) async => applied.add(gains),
      );

      final completion = ramp.start();
      await tester.pump();
      watch.elapse(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 40));
      _expectGains(applied.last, outgoing: 0.8660254037844386, incoming: 0.5);

      ramp.pause();
      final callsAtPause = applied.length;
      watch.elapse(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(ramp.progress, 0.25);
      expect(applied, hasLength(callsAtPause));
      expect(ramp.isRunning, isTrue);

      ramp.resume();
      watch.elapse(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 40));
      _expectGains(applied.last, outgoing: 1 / sqrt2, incoming: 1 / sqrt2);

      watch.elapse(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 40));
      expect(await completion, isTrue);
      _expectGains(applied.last, outgoing: 0, incoming: 1);
    });

    testWidgets('cancel completes false and prevents later gain writes', (
      tester,
    ) async {
      final watch = _FakeStopwatch();
      final applied = <CrossfadeGains>[];
      final ramp = CrossfadeRamp(
        duration: const Duration(seconds: 2),
        tickInterval: const Duration(milliseconds: 40),
        stopwatchFactory: () => watch,
        applyGains: (gains) async => applied.add(gains),
      );

      final firstStart = ramp.start();
      expect(identical(firstStart, ramp.start()), isTrue);
      await tester.pump();
      expect(applied, hasLength(1));

      ramp.cancel();
      expect(await firstStart, isFalse);
      expect(ramp.isRunning, isFalse);
      final progressAtCancel = ramp.progress;
      final callsAtCancel = applied.length;

      watch.elapse(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      expect(ramp.progress, progressAtCancel);
      expect(applied, hasLength(callsAtCancel));

      ramp
        ..cancel()
        ..pause()
        ..resume();
      expect(ramp.isRunning, isFalse);
    });

    testWidgets('a slow callback does not accumulate overlapping gain writes', (
      tester,
    ) async {
      final watch = _FakeStopwatch();
      final firstWrite = Completer<void>();
      final applied = <CrossfadeGains>[];
      var activeWrites = 0;
      var maximumConcurrentWrites = 0;
      final ramp = CrossfadeRamp(
        duration: const Duration(seconds: 1),
        tickInterval: const Duration(milliseconds: 20),
        stopwatchFactory: () => watch,
        applyGains: (gains) async {
          applied.add(gains);
          activeWrites++;
          maximumConcurrentWrites = maximumConcurrentWrites < activeWrites
              ? activeWrites
              : maximumConcurrentWrites;
          if (applied.length == 1) {
            await firstWrite.future;
          }
          activeWrites--;
        },
      );

      final completion = ramp.start();
      await tester.pump();
      expect(applied, hasLength(1));

      watch.elapse(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 200));
      expect(applied, hasLength(1));
      expect(maximumConcurrentWrites, 1);

      firstWrite.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(applied, hasLength(2));
      _expectGains(applied.last, outgoing: 1 / sqrt2, incoming: 1 / sqrt2);
      expect(maximumConcurrentWrites, 1);

      watch.elapse(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 20));
      expect(await completion, isTrue);
      _expectGains(applied.last, outgoing: 0, incoming: 1);
      expect(maximumConcurrentWrites, 1);
    });

    testWidgets('cancel wins while a slow callback is still pending', (
      tester,
    ) async {
      final watch = _FakeStopwatch();
      final write = Completer<void>();
      var calls = 0;
      final ramp = CrossfadeRamp(
        duration: const Duration(seconds: 1),
        tickInterval: const Duration(milliseconds: 20),
        stopwatchFactory: () => watch,
        applyGains: (_) async {
          calls++;
          await write.future;
        },
      );

      final completion = ramp.start();
      await tester.pump();
      expect(calls, 1);

      ramp.cancel();
      expect(await completion, isFalse);
      write.complete();
      await tester.pump();
      watch.elapse(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 1);
      expect(ramp.isRunning, isFalse);
    });

    testWidgets('callback errors complete the ramp with the same error', (
      tester,
    ) async {
      final watch = _FakeStopwatch();
      final ramp = CrossfadeRamp(
        duration: const Duration(seconds: 1),
        stopwatchFactory: () => watch,
        applyGains: (_) => Future<void>.error(StateError('gain write failed')),
      );

      final completion = ramp.start();
      final errorExpectation = expectLater(
        completion,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'gain write failed',
          ),
        ),
      );
      await tester.pump();
      await errorExpectation;
      expect(ramp.isRunning, isFalse);
    });
  });
}

const sqrt2 = 1.4142135623730951;

void _expectGains(
  CrossfadeGains gains, {
  required double outgoing,
  required double incoming,
}) {
  expect(gains.outgoing, closeTo(outgoing, 1e-12));
  expect(gains.incoming, closeTo(incoming, 1e-12));
}

class _FakeStopwatch implements Stopwatch {
  Duration _elapsed = Duration.zero;

  void elapse(Duration duration) {
    if (isRunning) {
      _elapsed += duration;
    }
  }

  @override
  Duration get elapsed => _elapsed;

  @override
  int get elapsedMicroseconds => _elapsed.inMicroseconds;

  @override
  int get elapsedMilliseconds => _elapsed.inMilliseconds;

  @override
  int get elapsedTicks => _elapsed.inMicroseconds;

  @override
  int get frequency => Duration.microsecondsPerSecond;

  @override
  bool isRunning = false;

  @override
  void reset() {
    _elapsed = Duration.zero;
  }

  @override
  void start() {
    isRunning = true;
  }

  @override
  void stop() {
    isRunning = false;
  }
}
