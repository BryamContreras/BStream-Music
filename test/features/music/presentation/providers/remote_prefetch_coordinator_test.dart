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
      final coordinator = RemotePrefetchCoordinator();
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
      final coordinator = RemotePrefetchCoordinator();
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
