import 'dart:async';

import 'package:bstream_music/services/storage/library_operation_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exclusive waits for an already active gate', () async {
    final coordinator = LibraryOperationCoordinator();
    addTearDown(coordinator.dispose);
    final gateStarted = Completer<void>();
    final releaseGate = Completer<void>();
    final exclusiveStarted = Completer<void>();
    final releaseExclusive = Completer<void>();
    var lateGateRan = false;

    final gated = coordinator.runWithGate(() async {
      gateStarted.complete();
      await releaseGate.future;
    });
    await gateStarted.future;

    final exclusive = coordinator.runExclusive(
      LibraryMaintenancePhase.preparingBackup,
      () async {
        exclusiveStarted.complete();
        await releaseExclusive.future;
      },
    );
    final lateGate = coordinator.runWithGate(() async {
      lateGateRan = true;
    });
    await Future<void>.delayed(Duration.zero);

    expect(exclusiveStarted.isCompleted, isFalse);
    expect(lateGateRan, isFalse);
    releaseGate.complete();
    await gated;
    await exclusiveStarted.future;
    expect(lateGateRan, isFalse);
    releaseExclusive.complete();
    await exclusive;
    await lateGate;
    expect(exclusiveStarted.isCompleted, isTrue);
    expect(lateGateRan, isTrue);
  });

  test('a new gate waits while an exclusive operation is active', () async {
    final coordinator = LibraryOperationCoordinator();
    addTearDown(coordinator.dispose);
    final exclusiveStarted = Completer<void>();
    final releaseExclusive = Completer<void>();
    final gateStarted = Completer<void>();

    final exclusive = coordinator.runExclusive(
      LibraryMaintenancePhase.committingRestore,
      () async {
        exclusiveStarted.complete();
        await releaseExclusive.future;
      },
    );
    await exclusiveStarted.future;

    final gated = coordinator.runWithGate(() async {
      gateStarted.complete();
      return 42;
    });
    await Future<void>.delayed(Duration.zero);

    expect(gateStarted.isCompleted, isFalse);
    releaseExclusive.complete();
    await exclusive;
    expect(await gated, 42);
    expect(gateStarted.isCompleted, isTrue);
  });

  test('gate drain timeout never executes the exclusive operation', () async {
    final coordinator = LibraryOperationCoordinator(
      activeGateDrainTimeout: Duration.zero,
    );
    addTearDown(coordinator.dispose);
    final gateStarted = Completer<void>();
    final releaseGate = Completer<void>();
    var destructiveOperationRan = false;

    final gated = coordinator.runWithGate(() async {
      gateStarted.complete();
      await releaseGate.future;
    });
    await gateStarted.future;

    await expectLater(
      coordinator.runExclusive(
        LibraryMaintenancePhase.committingRestore,
        () async => destructiveOperationRan = true,
      ),
      throwsA(isA<LibraryBusyException>()),
    );

    expect(destructiveOperationRan, isFalse);
    expect(coordinator.phase, LibraryMaintenancePhase.idle);
    expect(await coordinator.runWithGate(() async => 7), 7);

    releaseGate.complete();
    await gated;
  });

  test('gate and exclusive errors release all coordination state', () async {
    final coordinator = LibraryOperationCoordinator();
    addTearDown(coordinator.dispose);

    await expectLater(
      coordinator.runWithGate<void>(
        () async => throw StateError('simulated gate failure'),
      ),
      throwsStateError,
    );
    var firstExclusiveRan = false;
    await coordinator.runExclusive(
      LibraryMaintenancePhase.preparingBackup,
      () async => firstExclusiveRan = true,
    );
    expect(firstExclusiveRan, isTrue);

    final exclusiveStarted = Completer<void>();
    final releaseExclusive = Completer<void>();
    final failingExclusive = coordinator.runExclusive<void>(
      LibraryMaintenancePhase.migratingDirectory,
      () async {
        exclusiveStarted.complete();
        await releaseExclusive.future;
        throw StateError('simulated exclusive failure');
      },
    );
    final exclusiveExpectation = expectLater(
      failingExclusive,
      throwsStateError,
    );
    await exclusiveStarted.future;

    var waitingGateRan = false;
    final waitingGate = coordinator.runWithGate(() async {
      waitingGateRan = true;
      return 'released';
    });
    await Future<void>.delayed(Duration.zero);
    expect(waitingGateRan, isFalse);

    releaseExclusive.complete();
    await exclusiveExpectation;
    expect(await waitingGate, 'released');
    expect(waitingGateRan, isTrue);
    expect(coordinator.phase, LibraryMaintenancePhase.idle);
  });
}
