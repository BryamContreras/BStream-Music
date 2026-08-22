import 'dart:async';

import 'package:bstream_music/services/recommendations/recommendation_repository.dart';
import 'package:bstream_music/services/recommendations/recommendation_storage_models.dart';
import 'package:bstream_music/services/storage/library_operation_coordinator.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SQLite recommendation reads wait for library maintenance', () async {
    final database = _FakeRecommendationDatabase();
    final coordinator = LibraryOperationCoordinator();
    final repository = LocalDatabaseRecommendationRepository(
      database: database,
      coordinator: coordinator,
    );
    final maintenanceEntered = Completer<void>();
    final releaseMaintenance = Completer<void>();
    final maintenance = coordinator.runExclusive<void>(
      LibraryMaintenancePhase.snapshotting,
      () async {
        maintenanceEntered.complete();
        await releaseMaintenance.future;
      },
    );
    await maintenanceEntered.future;

    final read = repository.getTopSeeds(limit: 8);
    await Future<void>.delayed(Duration.zero);
    expect(database.topSeedReads, 0);

    releaseMaintenance.complete();
    await maintenance;
    expect(await read, isEmpty);
    expect(database.topSeedReads, 1);

    await coordinator.dispose();
  });
}

class _FakeRecommendationDatabase extends LocalDatabaseService {
  int topSeedReads = 0;

  @override
  Future<List<RecommendationSeed>> getTopRecommendationSeeds({
    int limit = 20,
    DateTime? since,
    int minListenedMs = 30000,
  }) async {
    topSeedReads += 1;
    return const <RecommendationSeed>[];
  }
}
