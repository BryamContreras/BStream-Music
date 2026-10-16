import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/player/recommendation_playback_item.dart';
import 'package:bstream_music/features/music/presentation/providers/player/recommendation_queue_extension_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RecommendationQueueExtensionCoordinator suspension', () {
    test('restores the source and its continuation callback', () async {
      final harness = _Harness();
      var calls = 0;
      Future<List<RecommendationPlaybackItem>> extender() async {
        calls++;
        return _items(2);
      }

      harness.coordinator.configure(sourceId: 'radio', extender: extender);
      final snapshot = harness.coordinator.suspend();

      expect(snapshot, isNotNull);
      expect(snapshot!.sourceId, 'radio');
      expect(snapshot.extender, same(extender));
      expect(snapshot.exhausted, isFalse);
      expect(harness.coordinator.sourceId, isNull);
      expect(await harness.extend(), isFalse);
      expect(calls, 0);

      harness.coordinator.restore(snapshot);

      expect(harness.coordinator.sourceId, 'radio');
      expect(await harness.extend(), isTrue);
      expect(harness.length, 2);
      expect(calls, 1);
    });

    test(
      'preserves exhaustion instead of requesting the finished radio again',
      () async {
        final harness = _Harness();
        var calls = 0;
        harness.coordinator.configure(
          sourceId: 'finished-radio',
          extender: () async {
            calls++;
            return _items(1);
          },
        );
        expect(await harness.extend(), isFalse);
        final snapshot = harness.coordinator.suspend();
        expect(snapshot!.exhausted, isTrue);

        harness.coordinator.configure(
          sourceId: 'temporary',
          extender: () async => _items(5),
        );
        harness.coordinator.restore(snapshot);

        expect(await harness.extend(), isFalse);
        expect(calls, 1);
        expect(harness.syncCalls, 0);
      },
    );

    test(
      'ignores a pending result and permits a fresh restored request',
      () async {
        final harness = _Harness();
        final previousResult = Completer<List<RecommendationPlaybackItem>>();
        final restoredResult = Completer<List<RecommendationPlaybackItem>>();
        var calls = 0;
        harness.coordinator.configure(
          sourceId: 'same-radio',
          extender: () {
            calls++;
            return calls == 1 ? previousResult.future : restoredResult.future;
          },
        );
        final previous = harness.extend();
        final snapshot = harness.coordinator.suspend();
        harness.coordinator.restore(snapshot);
        final restored = harness.extend();
        expect(calls, 2);

        previousResult.complete(_items(4));
        expect(await previous, isFalse);
        expect(harness.syncCalls, 0);
        expect(harness.length, 1);

        // Completing the old request must not clear the new coalesced request.
        final coalesced = harness.extend();
        expect(calls, 2);
        restoredResult.complete(_items(2));
        expect(await restored, isTrue);
        expect(await coalesced, isTrue);
        expect(harness.syncCalls, 1);
        expect(harness.length, 2);
      },
    );

    test(
      'a stale synchronization cannot exhaust the restored continuation',
      () async {
        final harness = _Harness();
        final synchronizationStarted = Completer<void>();
        final synchronizationResult = Completer<bool>();
        var calls = 0;
        harness.coordinator.configure(
          sourceId: 'same-radio',
          extender: () async {
            calls++;
            return _items(2);
          },
        );
        final previous = harness.extend(
          synchronize: (_, _) {
            synchronizationStarted.complete();
            return synchronizationResult.future;
          },
        );
        await synchronizationStarted.future;
        final snapshot = harness.coordinator.suspend();
        harness.coordinator.restore(snapshot);

        synchronizationResult.complete(false);
        expect(await previous, isFalse);
        expect(await harness.extend(), isTrue);
        expect(calls, 2);
        expect(harness.length, 2);
      },
    );

    test('does not report failures from a suspended generation', () async {
      final harness = _Harness();
      final previousResult = Completer<List<RecommendationPlaybackItem>>();
      harness.coordinator.configure(
        sourceId: 'radio',
        extender: () => previousResult.future,
      );
      final previous = harness.extend();
      final snapshot = harness.coordinator.suspend();
      harness.coordinator.restore(snapshot);

      previousResult.completeError(StateError('late network failure'));

      expect(await previous, isFalse);
      expect(harness.errors, isEmpty);
      expect(harness.coordinator.sourceId, 'radio');
    });

    test(
      'restoring no snapshot clears a currently active continuation',
      () async {
        final harness = _Harness();
        expect(harness.coordinator.suspend(), isNull);
        harness.coordinator.configure(
          sourceId: 'temporary',
          extender: () async => _items(2),
        );

        harness.coordinator.restore(null);

        expect(harness.coordinator.sourceId, isNull);
        expect(await harness.extend(), isFalse);
        expect(harness.syncCalls, 0);
      },
    );
  });
}

class _Harness {
  final coordinator = RecommendationQueueExtensionCoordinator();
  final errors = <Object>[];
  int length = 1;
  int syncCalls = 0;

  Future<bool> extend({
    Future<bool> Function(String, List<RecommendationPlaybackItem>)?
    synchronize,
  }) => coordinator.maybeExtend(
    sourceIsActive: true,
    atQueueEnd: true,
    remaining: 0,
    threshold: 3,
    currentLength: () => length,
    isDisposed: () => false,
    synchronize:
        synchronize ??
        (_, items) async {
          syncCalls++;
          length = items.length;
          return true;
        },
    onError: errors.add,
  );
}

List<RecommendationPlaybackItem> _items(int count) => List.generate(
  count,
  (index) => RecommendationPlaybackItem(
    track: TrackInfo(
      id: '$index',
      title: 'Track $index',
      artist: 'Artist',
      url: 'https://music.youtube.com/watch?v=$index',
    ),
  ),
);
