import 'dart:async';

import 'local_database_service.dart';

typedef LocalDatabaseShutdownDrain = Future<void> Function();

/// Drains database-backed producers before terminally closing the database.
///
/// Riverpod disposal callbacks are synchronous, while both a playback-history
/// tracker and SQLite need asynchronous teardown. Registering the producer in
/// advance makes their ordering deterministic regardless of callback order.
class LocalDatabaseShutdownCoordinator {
  final Map<int, LocalDatabaseShutdownRegistration> _registrations =
      <int, LocalDatabaseShutdownRegistration>{};
  final Set<Future<void>> _pendingDrains = <Future<void>>{};
  int _nextRegistrationId = 0;
  Future<void>? _shutdown;
  bool _closing = false;

  LocalDatabaseShutdownRegistration register(LocalDatabaseShutdownDrain drain) {
    if (_closing) {
      throw StateError('Database shutdown has already started.');
    }
    final registration = LocalDatabaseShutdownRegistration._(
      this,
      _nextRegistrationId++,
      drain,
    );
    _registrations[registration._id] = registration;
    return registration;
  }

  Future<void> disposeDatabase(LocalDatabaseService database) {
    return _shutdown ??= _disposeDatabase(database);
  }

  Future<void> _disposeDatabase(LocalDatabaseService database) async {
    _closing = true;
    final drains = <Future<void>>[
      ..._pendingDrains,
      for (final registration in _registrations.values.toList(growable: false))
        registration.dispose(),
    ];

    Object? firstError;
    StackTrace? firstStackTrace;
    for (final drain in drains) {
      try {
        await drain;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    try {
      await database.dispose();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _disposeRegistration(
    LocalDatabaseShutdownRegistration registration,
  ) {
    final existing = registration._disposal;
    if (existing != null) {
      return existing;
    }
    _registrations.remove(registration._id);
    late final Future<void> disposal;
    disposal = Future<void>.sync(registration._drain).whenComplete(() {
      _pendingDrains.remove(disposal);
    });
    registration._disposal = disposal;
    _pendingDrains.add(disposal);
    return disposal;
  }
}

class LocalDatabaseShutdownRegistration {
  LocalDatabaseShutdownRegistration._(this._coordinator, this._id, this._drain);

  final LocalDatabaseShutdownCoordinator _coordinator;
  final int _id;
  final LocalDatabaseShutdownDrain _drain;
  Future<void>? _disposal;

  Future<void> dispose() => _coordinator._disposeRegistration(this);
}
