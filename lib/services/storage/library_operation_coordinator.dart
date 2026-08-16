import 'dart:async';

enum LibraryMaintenancePhase {
  idle,
  preparingBackup,
  snapshotting,
  preparingRestore,
  committingRestore,
  migratingDirectory,
  importingCsv,
  exportingCsv,
}

class LibraryBusyException implements Exception {
  const LibraryBusyException(this.phase);

  final LibraryMaintenancePhase phase;

  @override
  String toString() =>
      'La biblioteca está ocupada con una operación de mantenimiento '
      '($phase). Espera a que termine e intenta nuevamente.';
}

class LibraryOperationCoordinator {
  factory LibraryOperationCoordinator({
    Duration activeGateDrainTimeout = const Duration(seconds: 10),
    Duration gateWaitTimeout = const Duration(minutes: 5),
  }) {
    return LibraryOperationCoordinator._(
      activeGateDrainTimeout,
      gateWaitTimeout,
    );
  }

  LibraryOperationCoordinator._(
    this._activeGateDrainTimeout,
    this._gateWaitTimeout,
  );

  final Duration _activeGateDrainTimeout;
  final Duration _gateWaitTimeout;
  final _phaseController =
      StreamController<LibraryMaintenancePhase>.broadcast();
  LibraryMaintenancePhase _phase = LibraryMaintenancePhase.idle;
  Future<void> _exclusiveTail = Future<void>.value();
  final Map<String, Completer<void>> _activeReadGates = {};
  int _readGateCounter = 0;
  int _pendingExclusiveOperations = 0;
  Completer<void>? _exclusiveBarrier;

  Stream<LibraryMaintenancePhase> get phaseStream => _phaseController.stream;

  LibraryMaintenancePhase get phase => _phase;

  bool get isMaintaining => _phase != LibraryMaintenancePhase.idle;

  Future<T> runExclusive<T>(
    LibraryMaintenancePhase initialPhase,
    Future<T> Function() operation, {
    void Function(LibraryMaintenancePhase)? onPhaseChange,
  }) async {
    final previous = _exclusiveTail;
    final turn = Completer<void>();
    _exclusiveTail = turn.future;
    _reserveExclusiveOperation();
    var ownsTurn = false;
    try {
      await previous;
      ownsTurn = true;
      updatePhase(initialPhase, onPhaseChange);
      await drainActiveGates(timeout: _activeGateDrainTimeout);
      return await operation();
    } finally {
      try {
        if (ownsTurn) {
          updatePhase(LibraryMaintenancePhase.idle, onPhaseChange);
        }
      } finally {
        try {
          _releaseExclusiveOperation();
        } finally {
          if (!turn.isCompleted) {
            turn.complete();
          }
        }
      }
    }
  }

  Future<T> runWithGate<T>(Future<T> Function() operation) async {
    while (true) {
      final barrier = _exclusiveBarrier;
      if (barrier == null) {
        break;
      }
      try {
        await barrier.future.timeout(_gateWaitTimeout);
      } on TimeoutException {
        throw LibraryBusyException(_phase);
      }
    }

    // There is intentionally no await between the barrier check above and
    // registration. Dart executes this section synchronously, so an
    // exclusive reservation cannot slip between both operations.
    final gateId = '${++_readGateCounter}';
    final gate = Completer<void>();
    _activeReadGates[gateId] = gate;
    try {
      return await operation();
    } finally {
      _activeReadGates.remove(gateId);
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }

  Future<void> drainActiveGates({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_activeReadGates.isEmpty) {
      return;
    }
    final futures = _activeReadGates.values.map((gate) => gate.future).toList();
    try {
      await Future.wait(futures).timeout(timeout);
    } on TimeoutException {
      throw LibraryBusyException(_phase);
    }
  }

  void _reserveExclusiveOperation() {
    _pendingExclusiveOperations++;
    _exclusiveBarrier ??= Completer<void>();
  }

  void _releaseExclusiveOperation() {
    if (_pendingExclusiveOperations <= 0) {
      throw StateError('No hay una operación exclusiva pendiente.');
    }
    _pendingExclusiveOperations--;
    if (_pendingExclusiveOperations != 0) {
      return;
    }
    final barrier = _exclusiveBarrier;
    _exclusiveBarrier = null;
    if (barrier != null && !barrier.isCompleted) {
      barrier.complete();
    }
  }

  void updatePhase(
    LibraryMaintenancePhase phase, [
    void Function(LibraryMaintenancePhase)? onPhaseChange,
  ]) {
    _phase = phase;
    if (!_phaseController.isClosed) {
      _phaseController.add(phase);
    }
    onPhaseChange?.call(phase);
  }

  Future<void> dispose() async {
    if (!_phaseController.isClosed) {
      await _phaseController.close();
    }
  }
}
