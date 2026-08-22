import 'dart:async';

import 'package:flutter/foundation.dart';

enum OptionalStartupService { notificationArtwork, audioService }

enum AppStartupStatus { idle, initializing, ready, degraded }

@immutable
class AppStartupSnapshot {
  const AppStartupSnapshot({
    required this.status,
    required this.attempt,
    this.failures = const <OptionalStartupService, Object>{},
  });

  const AppStartupSnapshot.idle()
    : status = AppStartupStatus.idle,
      attempt = 0,
      failures = const <OptionalStartupService, Object>{};

  final AppStartupStatus status;
  final int attempt;
  final Map<OptionalStartupService, Object> failures;

  bool get isDegraded => status == AppStartupStatus.degraded;
  bool get canRetry => failures.isNotEmpty;
}

typedef OptionalStartupOperation = Future<void> Function();
typedef AppStartupRetryDelay = Future<void> Function(Duration duration);

Future<void> defaultAppStartupRetryDelay(Duration duration) =>
    Future<void>.delayed(duration);

/// Starts optional native integrations without making them a prerequisite for
/// the first Flutter frame.
///
/// Transient failures are retried automatically with a bounded backoff.
/// Consumers can still observe [snapshot] and call [retryFailed] after that
/// budget is exhausted.
class AppStartupCoordinator {
  AppStartupCoordinator({
    required Map<OptionalStartupService, OptionalStartupOperation> operations,
    List<Duration> retryBackoff = const <Duration>[
      Duration(milliseconds: 500),
      Duration(seconds: 2),
    ],
    AppStartupRetryDelay? retryDelay,
  }) : _operations = Map.unmodifiable(operations),
       _retryBackoff = List<Duration>.unmodifiable(retryBackoff),
       _retryDelay = retryDelay ?? defaultAppStartupRetryDelay {
    if (_retryBackoff.any((duration) => duration < Duration.zero)) {
      throw ArgumentError.value(
        retryBackoff,
        'retryBackoff',
        'Durations must not be negative.',
      );
    }
  }

  final Map<OptionalStartupService, OptionalStartupOperation> _operations;
  final List<Duration> _retryBackoff;
  final AppStartupRetryDelay _retryDelay;
  final ValueNotifier<AppStartupSnapshot> snapshot =
      ValueNotifier<AppStartupSnapshot>(const AppStartupSnapshot.idle());
  Future<void>? _inFlight;
  bool _disposed = false;

  Future<void> initialize() => _run(_operations.keys.toSet());

  Future<void> retryFailed() {
    if (_disposed) {
      return Future<void>.error(
        StateError('App startup coordinator has been disposed.'),
      );
    }
    return _run(snapshot.value.failures.keys.toSet());
  }

  Future<void> _run(Set<OptionalStartupService> services) {
    if (_disposed) {
      return Future<void>.error(
        StateError('App startup coordinator has been disposed.'),
      );
    }
    final active = _inFlight;
    if (active != null) {
      return active;
    }
    if (services.isEmpty) {
      return Future<void>.value();
    }

    final previousFailures = Map<OptionalStartupService, Object>.of(
      snapshot.value.failures,
    );
    late final Future<void> run;
    run =
        () async {
          var pendingServices = services;
          for (var retryIndex = 0; ; retryIndex++) {
            if (_disposed) {
              return;
            }
            final attempt = snapshot.value.attempt + 1;
            snapshot.value = AppStartupSnapshot(
              status: AppStartupStatus.initializing,
              attempt: attempt,
              failures: Map.unmodifiable(previousFailures),
            );
            final results = await Future.wait(
              pendingServices.map((service) async {
                try {
                  await _operations[service]!();
                  return (service: service, error: null as Object?);
                } catch (error, stackTrace) {
                  debugPrint(
                    'Optional startup service ${service.name} failed: $error\n'
                    '$stackTrace',
                  );
                  return (service: service, error: error);
                }
              }),
            );
            if (_disposed) {
              return;
            }
            for (final result in results) {
              final error = result.error;
              if (error == null) {
                previousFailures.remove(result.service);
              } else {
                previousFailures[result.service] = error;
              }
            }
            snapshot.value = AppStartupSnapshot(
              status: previousFailures.isEmpty
                  ? AppStartupStatus.ready
                  : AppStartupStatus.degraded,
              attempt: attempt,
              failures: Map.unmodifiable(previousFailures),
            );
            pendingServices = results
                .where((result) => result.error != null)
                .map((result) => result.service)
                .toSet();
            if (pendingServices.isEmpty || retryIndex >= _retryBackoff.length) {
              return;
            }
            await _retryDelay(_retryBackoff[retryIndex]);
          }
        }().whenComplete(() {
          if (identical(_inFlight, run)) {
            _inFlight = null;
          }
        });
    _inFlight = run;
    return run;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    snapshot.dispose();
  }
}
