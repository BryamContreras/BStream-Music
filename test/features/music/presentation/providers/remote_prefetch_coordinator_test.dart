import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/player/remote_prefetch_coordinator.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'duplicate position snapshots do not repeat cache retention or warmups',
    () async {
      final coordinator = RemotePrefetchCoordinator(
        additionalWarmupDelay: Duration.zero,
      );
      var warmups = 0;
      var retentions = 0;
      for (var i = 0; i < 5; i++) {
        await _prepare(coordinator, (track) async {
          warmups++;
          return File('unused-${track.id}.m4a');
        }, onRetain: () => retentions++);
      }
      expect(warmups, 3);
      expect(retentions, 1);
    },
  );
  test(
    'coalesces failures with exponential backoff, but new queues start now',
    () {
      var now = DateTime.utc(2026);
      final coordinator = RemotePrefetchCoordinator(clock: () => now);
      expect(coordinator.begin('a'), isTrue);
      expect(coordinator.begin('a'), isFalse);
      coordinator.invalidateIfCurrent('a');
      expect(coordinator.begin('a'), isFalse);
      now = now.add(const Duration(seconds: 5));
      expect(coordinator.begin('a'), isTrue);
      coordinator.invalidateIfCurrent('a');
      now = now.add(const Duration(seconds: 5));
      expect(coordinator.begin('a'), isFalse);
      expect(coordinator.begin('b'), isTrue);
      coordinator.invalidateIfCurrent('a');
      expect(coordinator.isCurrent('b'), isTrue);
      coordinator.invalidate();
      expect(coordinator.begin('b'), isTrue);
    },
  );

  test(
    'warms immediate-next before starting the other full transfers',
    () async {
      final gates = List.generate(3, (_) => Completer<File?>());
      final started = <String>[];
      final coordinator = RemotePrefetchCoordinator(
        additionalWarmupDelay: Duration.zero,
      );
      final operation = _prepare(coordinator, (track) {
        started.add(track.id);
        return gates[int.parse(track.id) - 1].future;
      });
      await _flush();
      expect(started, ['1']);
      gates[0].complete(File('unused-one.m4a'));
      await _flush();
      expect(started, ['1', '2']);
      gates[1].complete(File('unused-two.m4a'));
      await _flush();
      expect(started, ['1', '2', '3']);
      gates[2].complete(File('unused-three.m4a'));
      await operation;
    },
  );

  test('changing tracks does not start pending old warmups', () async {
    var current = true;
    final first = Completer<File?>();
    final started = <String>[];
    final operation = _prepare(RemotePrefetchCoordinator(), (track) {
      started.add(track.id);
      return first.future;
    }, isCurrent: () => current);
    await _flush();
    current = false;
    first.complete(File('unused.m4a'));
    await operation;
    expect(started, ['1']);
  });

  testWidgets(
    'NEXT downloads and publishes while a later resolver is blocked',
    (tester) async {
      final fixture = _RetryFixture(
        additionalWarmupDelay: const Duration(seconds: 20),
      );
      addTearDown(fixture.coordinator.dispose);
      final later = Completer<TrackInfo>();
      fixture.blockedSecondResolution = later;
      final operation = fixture.prepare();
      await tester.pump();

      expect(fixture.resolved, ['1', '2']);
      expect(fixture.warmed, ['1']);
      expect(fixture.crossfades, ['1']);
      expect(fixture.player.updates.last.single.track.id, '1');
      expect(fixture.player.updates.last.single.uri.scheme, 'file');
      expect(fixture.player.finalizations, everyElement(isFalse));

      fixture.coordinator.invalidate();
      later.complete(fixture.plan.upcoming[1].track);
      await operation;
      expect(fixture.warmed, ['1']);
    },
  );

  testWidgets(
    'later full transfers wait after NEXT while native URLs are ready',
    (tester) async {
      final fixture = _RetryFixture(
        additionalWarmupDelay: const Duration(seconds: 20),
      );
      addTearDown(fixture.coordinator.dispose);
      final operation = fixture.prepare();
      await tester.pump();
      expect(fixture.resolved, ['1', '2', '3']);
      expect(fixture.warmed, ['1']);
      expect(fixture.player.updates.last, hasLength(3));
      expect(fixture.player.updates.last.first.uri.scheme, 'file');
      expect(fixture.player.updates.last.skip(1).map((s) => s.uri.scheme), [
        'https',
        'https',
      ]);

      await tester.pump(const Duration(seconds: 19));
      expect(fixture.warmed, ['1']);
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.warmed, ['1', '2']);
      await tester.pump(const Duration(seconds: 20));
      await operation;
      expect(fixture.warmed, ['1', '2', '3']);
      expect(
        fixture.player.updates.last.map((s) => s.uri.scheme),
        everyElement('file'),
      );
    },
  );

  for (final dispose in [false, true]) {
    testWidgets(
      '${dispose ? 'dispose' : 'invalidate'} cancels later transfers',
      (tester) async {
        final fixture = _RetryFixture(
          additionalWarmupDelay: const Duration(seconds: 20),
        );
        addTearDown(fixture.coordinator.dispose);
        final operation = fixture.prepare();
        await tester.pump();
        expect(fixture.warmed, ['1']);
        final updates = fixture.player.updates.length;
        if (dispose) {
          fixture.coordinator.dispose();
        } else {
          fixture.coordinator.invalidate();
        }
        await operation;
        await tester.pump(const Duration(minutes: 1));
        expect(fixture.warmed, ['1']);
        expect(fixture.player.updates, hasLength(updates));
      },
    );
  }

  testWidgets(
    'failed NEXT cache retries without waiting for optional transfers',
    (tester) async {
      final fixture = _RetryFixture(
        additionalWarmupDelay: const Duration(seconds: 20),
      )..remainingWarmFailures = 1;
      addTearDown(fixture.coordinator.dispose);
      await fixture.prepare();
      expect(fixture.warmed, ['1']);
      expect(fixture.player.updates.last, hasLength(3));

      fixture.advance(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.warmed, ['1', '1']);
      fixture.coordinator.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'cache off still prepares only the next native source without cache I/O',
    (tester) async {
      final fixture = _RetryFixture(cacheEnabled: false);
      addTearDown(fixture.coordinator.dispose);

      await fixture.prepare();
      await fixture.prepare();

      expect(fixture.resolved, ['1']);
      expect(fixture.cacheReads, 0);
      expect(fixture.cacheRetentions, 0);
      expect(fixture.warmed, isEmpty);
      expect(fixture.crossfades, ['1']);
      expect(fixture.prepared, ['1']);
      expect(fixture.player.updates, hasLength(2));
      expect(fixture.player.updates.last.map((source) => source.track.id), [
        '1',
      ]);
      expect(fixture.player.updates.last.single.uri.scheme, 'https');
    },
  );

  testWidgets('cache on preserves the full bounded native and file window', (
    tester,
  ) async {
    final fixture = _RetryFixture();
    addTearDown(fixture.coordinator.dispose);

    await fixture.prepare();

    expect(fixture.resolved, ['1', '2', '3']);
    expect(fixture.cacheReads, 3);
    expect(fixture.cacheRetentions, 1);
    expect(fixture.retained, ['0', '1', '2', '3']);
    expect(fixture.warmed, ['1', '2', '3']);
    expect(fixture.crossfades, ['1']);
    expect(fixture.player.updates.last, hasLength(3));
    expect(
      fixture.player.updates.last.map((source) => source.uri.scheme),
      everyElement('file'),
    );
  });

  testWidgets('failed prefetch retries without any playback snapshots', (
    tester,
  ) async {
    final fixture = _RetryFixture(cacheEnabled: false)..remainingFailures = 1;
    addTearDown(fixture.coordinator.dispose);
    await fixture.prepare();
    expect(fixture.resolved, ['1']);

    fixture.advance(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));
    expect(fixture.resolved, ['1']);
    fixture.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(fixture.resolved, ['1', '1']);
    expect(fixture.player.updates.last.single.track.id, '1');

    fixture.advance(const Duration(minutes: 2));
    await tester.pump(const Duration(minutes: 2));
    expect(fixture.resolved, ['1', '1']);
  });

  testWidgets('automatic retry budget is bounded with exponential backoff', (
    tester,
  ) async {
    final fixture = _RetryFixture(cacheEnabled: false)..remainingFailures = 99;
    addTearDown(fixture.coordinator.dispose);
    await fixture.prepare();

    fixture.advance(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(fixture.resolved, hasLength(2));
    fixture.advance(const Duration(seconds: 9));
    await tester.pump(const Duration(seconds: 9));
    expect(fixture.resolved, hasLength(2));
    fixture.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(fixture.resolved, hasLength(3));

    fixture.advance(const Duration(hours: 1));
    await tester.pump(const Duration(hours: 1));
    expect(fixture.resolved, hasLength(3));
    expect(fixture.player.updates, isEmpty);
  });

  for (final dispose in [false, true]) {
    testWidgets('${dispose ? 'dispose' : 'invalidate'} cancels pending retry', (
      tester,
    ) async {
      final fixture = _RetryFixture(cacheEnabled: false)
        ..remainingFailures = 99;
      addTearDown(fixture.coordinator.dispose);
      await fixture.prepare();
      if (dispose) {
        fixture.coordinator.dispose();
      } else {
        fixture.coordinator.invalidate();
      }

      fixture.advance(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(fixture.resolved, ['1']);
      expect(fixture.player.updates, isEmpty);
      if (dispose) {
        await fixture.prepare();
        expect(fixture.resolved, ['1']);
      }
    });
  }

  testWidgets('retry cannot prepare a selection that is no longer current', (
    tester,
  ) async {
    final fixture = _RetryFixture(cacheEnabled: false)..remainingFailures = 1;
    addTearDown(fixture.coordinator.dispose);
    await fixture.prepare();
    fixture.current = false;

    fixture.advance(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(fixture.resolved, ['1']);
    expect(fixture.player.updates, isEmpty);
  });

  testWidgets('new queue replaces the old backoff without waiting for it', (
    tester,
  ) async {
    final fixture = _RetryFixture(cacheEnabled: false)..remainingFailures = 1;
    addTearDown(fixture.coordinator.dispose);
    await fixture.prepare();
    fixture.plan = _plan(generation: 2);
    await fixture.prepare();
    expect(fixture.resolved, ['1', '1']);
    expect(fixture.player.updates.last.single.queueEntryId, '2:1');

    fixture.advance(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(fixture.resolved, ['1', '1']);
  });

  testWidgets('same plan invalidation rejects a late previous resolver', (
    tester,
  ) async {
    final fixture = _RetryFixture(cacheEnabled: false);
    addTearDown(fixture.coordinator.dispose);
    final oldResolution = Completer<TrackInfo>();
    fixture.blockedResolution = oldResolution;
    final first = fixture.prepare();
    await tester.pump();
    fixture.coordinator.invalidate();
    await fixture.prepare();
    final updates = fixture.player.updates.length;

    oldResolution.complete(fixture.plan.upcoming.first.track);
    await first;
    await tester.pump();
    expect(fixture.player.updates, hasLength(updates));
    expect(fixture.prepared, ['1']);
  });

  testWidgets('a native queue mutation failure also gets a bounded retry', (
    tester,
  ) async {
    final fixture = _RetryFixture(cacheEnabled: false);
    addTearDown(fixture.coordinator.dispose);
    fixture.player.remainingFailures = 1;
    await fixture.prepare();
    expect(fixture.player.updates, isEmpty);

    fixture.advance(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(fixture.resolved, ['1', '1']);
    expect(fixture.player.updates.last.single.track.id, '1');
  });

  testWidgets('optional standby loading does not delay native successor', (
    tester,
  ) async {
    final fixture = _RetryFixture(cacheEnabled: false);
    addTearDown(fixture.coordinator.dispose);
    final standby = Completer<void>();
    fixture.blockedStandby = standby;
    final operation = fixture.prepare();
    await tester.pump();

    expect(fixture.crossfades, ['1']);
    expect(fixture.player.updates.single.single.track.id, '1');
    standby.complete();
    await operation;
    expect(fixture.player.updates, hasLength(2));
  });

  testWidgets('cache maintenance does not delay native successor', (
    tester,
  ) async {
    final fixture = _RetryFixture();
    addTearDown(fixture.coordinator.dispose);
    final maintenance = Completer<void>();
    fixture.blockedRetention = maintenance;
    final operation = fixture.prepare();
    await tester.pump();
    expect(fixture.player.updates.last, hasLength(3));
    maintenance.complete();
    await operation;
  });

  testWidgets('late cache maintenance failures cannot reset the retry budget', (
    tester,
  ) async {
    final fixture = _RetryFixture();
    addTearDown(fixture.coordinator.dispose);
    final first = Completer<void>();
    fixture.blockedRetention = first;
    final operation = fixture.prepare();
    await tester.pump();
    expect(fixture.player.updates.last, hasLength(3));
    first.completeError(const FileSystemException('Cache unavailable'));
    await operation;

    for (final backoff in [5, 10]) {
      final next = Completer<void>();
      fixture.blockedRetention = next;
      fixture.advance(Duration(seconds: backoff));
      await tester.pump(Duration(seconds: backoff));
      next.completeError(const FileSystemException('Cache unavailable'));
      await tester.pump();
    }
    expect(fixture.cacheRetentions, 3);
    fixture.advance(const Duration(hours: 1));
    await tester.pump(const Duration(hours: 1));
    expect(fixture.cacheRetentions, 3);
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

Future<void> _prepare(
  RemotePrefetchCoordinator coordinator,
  Future<File?> Function(TrackInfo) warm, {
  bool Function()? isCurrent,
  void Function()? onRetain,
}) {
  final queue = List.generate(
    4,
    (i) => TrackInfo(
      id: '$i',
      title: 'Track $i',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=$i',
    ),
  );
  final plan = RemotePrefetchPlanner.build(
    queue: queue,
    currentIndex: 0,
    queueGeneration: 1,
    shuffleEnabled: false,
    shufflePlan: const [],
    repeatMode: PlaybackRepeatMode.off,
    actualPreviousTrack: null,
  )!;
  return coordinator.prepare(
    plan: plan,
    cacheEnabled: true,
    isCurrent: isCurrent ?? () => true,
    retainOnlyTracks: (_) async {
      onRetain?.call();
    },
    cachedFile: (_) async => null,
    warmResolved: warm,
    resolve: (track, _) async => track,
    networkSource: (track, _) => RemotePlaybackSource(
      track: track,
      uri: Uri.parse('https://cdn.test/${track.id}'),
      queueEntryId: track.id,
    ),
    service: _NoNativePlayer(),
  );
}

class _NoNativePlayer implements PlayerService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RemotePrefetchPlan _plan({int generation = 1}) {
  final tracks = List.generate(
    4,
    (index) => TrackInfo(
      id: '$index',
      title: 'Track $index',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=$index',
    ),
  );
  return RemotePrefetchPlan(
    currentQueueEntryId: '$generation:0',
    currentIdentity: '0',
    upcoming: [
      for (var index = 1; index < tracks.length; index++)
        RemotePrefetchEntry(
          index: index,
          track: tracks[index],
          queueEntryId: '$generation:$index',
        ),
    ],
    cacheWindow: tracks,
  );
}

class _RetryFixture {
  _RetryFixture({
    this.cacheEnabled = true,
    Duration additionalWarmupDelay = Duration.zero,
  }) {
    coordinator = RemotePrefetchCoordinator(
      clock: () => now,
      additionalWarmupDelay: additionalWarmupDelay,
    );
  }

  final bool cacheEnabled;
  late final RemotePrefetchCoordinator coordinator;
  final player = _NativePlayer();
  RemotePrefetchPlan plan = _plan();
  DateTime now = DateTime.utc(2026);
  bool current = true;
  int remainingFailures = 0;
  int remainingWarmFailures = 0;
  int cacheReads = 0;
  int cacheRetentions = 0;
  final resolved = <String>[];
  final retained = <String>[];
  final warmed = <String>[];
  final crossfades = <String?>[];
  final prepared = <String>[];
  Completer<TrackInfo>? blockedResolution;
  Completer<TrackInfo>? blockedSecondResolution;
  Completer<void>? blockedStandby;
  Completer<void>? blockedRetention;

  void advance(Duration duration) => now = now.add(duration);

  Future<void> prepare() => coordinator.prepare(
    plan: plan,
    cacheEnabled: cacheEnabled,
    isCurrent: () => current,
    retainOnlyTracks: (tracks) async {
      cacheRetentions++;
      retained.addAll(tracks.map((track) => track.id));
      await blockedRetention?.future;
    },
    cachedFile: (track) async {
      cacheReads++;
      return null;
    },
    warmResolved: (track) async {
      warmed.add(track.id);
      if (remainingWarmFailures > 0) {
        remainingWarmFailures--;
        return null;
      }
      return File('unused-${track.id}.m4a').absolute;
    },
    resolve: (track, shouldContinue) async {
      expectSync(shouldContinue(), isTrue);
      resolved.add(track.id);
      if (remainingFailures > 0) {
        remainingFailures--;
        throw const SocketException('Slow connection');
      }
      if (track.id == '2' && blockedSecondResolution != null) {
        final blocked = blockedSecondResolution!;
        blockedSecondResolution = null;
        return blocked.future;
      }
      final blocked = blockedResolution;
      blockedResolution = null;
      return blocked == null ? track : await blocked.future;
    },
    networkSource: (track, index) => RemotePlaybackSource(
      track: track,
      uri: Uri.parse('https://cdn.test/${track.id}'),
      queueEntryId: plan.upcoming
          .firstWhere((entry) => entry.index == index)
          .queueEntryId,
    ),
    onSourcePrepared: (source) => prepared.add(source.track.id),
    service: player,
    prepareCrossfade: (source) async {
      crossfades.add(
        source is RemoteCrossfadePlaybackSource ? source.source.track.id : null,
      );
      if (source != null) await blockedStandby?.future;
    },
  );
}

class _NativePlayer implements PlayerService, NativeRemoteQueuePlayer {
  int remainingFailures = 0;
  final updates = <List<RemotePlaybackSource>>[];
  final finalizations = <bool>[];

  @override
  Future<void> updateRemoteQueue(
    List<RemotePlaybackSource> upcoming, {
    bool finalize = true,
  }) async {
    if (remainingFailures > 0) {
      remainingFailures--;
      throw const SocketException('Native source preparation failed');
    }
    updates.add(List.of(upcoming));
    finalizations.add(finalize);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
