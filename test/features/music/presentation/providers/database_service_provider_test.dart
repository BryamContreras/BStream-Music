import 'dart:async';

import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/recommendations/recommendation_storage_models.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'closes its database service when the provider container is disposed',
    () async {
      final database = _ClosingDatabaseService();
      final container = ProviderContainer(
        overrides: [
          databaseServiceFactoryProvider.overrideWithValue(() => database),
        ],
      );

      expect(container.read(databaseServiceProvider), same(database));
      container.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(database.closeCalls, 1);
      await expectLater(database.database, throwsStateError);
    },
  );

  test(
    'drains a terminal playback-history write before closing the database',
    () async {
      final database = _OrderedDatabaseService();
      final container = ProviderContainer(
        overrides: [
          databaseServiceFactoryProvider.overrideWithValue(() => database),
        ],
      );
      expect(container.read(databaseServiceProvider), same(database));
      final shutdown = container.read(localDatabaseShutdownCoordinatorProvider);
      var elapsed = Duration.zero;
      final tracker = QualifiedPlaybackHistoryTracker(
        monotonicClock: () => elapsed,
        onWrite: (write) => database.recordPlaybackEvent(write.event),
      );
      shutdown.register(tracker.dispose);
      await tracker.setEnabled(true);
      tracker.update(
        track: PlaybackHistoryTrack(
          logicalKey: 'remote:queue:0',
          trackId: 'abcdefghijk',
          videoId: 'abcdefghijk',
          title: 'Track',
          artists: const ['Artist'],
          duration: const Duration(seconds: 1),
          source: PlaybackEventSource.streaming,
        ),
        status: PlayerStatus.playing,
      );
      elapsed = const Duration(seconds: 1);

      container.dispose();
      await database.writeStarted.future;

      expect(database.closeCalls, 0);
      expect(database.operations, ['write-start']);

      database.releaseWrite.complete();
      await _waitUntil(() => database.closeCalls == 1);

      expect(database.operations, ['write-start', 'write-end', 'close']);
    },
  );
}

class _ClosingDatabaseService extends LocalDatabaseService {
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

class _OrderedDatabaseService extends LocalDatabaseService {
  final Completer<void> writeStarted = Completer<void>();
  final Completer<void> releaseWrite = Completer<void>();
  final List<String> operations = <String>[];
  int closeCalls = 0;

  @override
  Future<void> recordPlaybackEvent(PlaybackEvent event) async {
    operations.add('write-start');
    writeStarted.complete();
    await releaseWrite.future;
    operations.add('write-end');
  }

  @override
  Future<void> close() async {
    closeCalls++;
    operations.add('close');
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for database shutdown.');
}
