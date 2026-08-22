import 'dart:async';

import 'package:flutter/foundation.dart';

import 'desktop_media_session.dart';

/// Keeps an optional system media session attached to the live player state.
///
/// Native session initialization can fail while the platform is restoring the
/// process. The binding retains the newest metadata, retries with bounded
/// backoff, and publishes that metadata as soon as initialization succeeds.
class DesktopMediaSessionBinding {
  DesktopMediaSessionBinding(
    this._session,
    this._callbacks, {
    List<Duration> retryBackoff = const <Duration>[
      Duration(milliseconds: 500),
      Duration(seconds: 2),
    ],
  }) : _retryBackoff = List<Duration>.unmodifiable(retryBackoff) {
    if (_retryBackoff.any((duration) => duration < Duration.zero)) {
      throw ArgumentError.value(
        retryBackoff,
        'retryBackoff',
        'Durations must not be negative.',
      );
    }
  }

  final DesktopMediaSession _session;
  final DesktopMediaSessionCallbacks _callbacks;
  final List<Duration> _retryBackoff;

  DesktopMediaSessionState? _latestState;
  Future<void>? _initialization;
  Future<void> _updateTail = Future<void>.value();
  Timer? _retryTimer;
  int _retryIndex = 0;
  bool _initialized = false;
  bool _disposed = false;
  bool _publishRequested = false;
  bool _retryExhausted = false;

  bool get isInitialized => _initialized;

  void start() {
    unawaited(_initialize());
  }

  /// Retains [state] even while initialization is retrying.
  Future<void> update(DesktopMediaSessionState state) {
    if (_disposed) {
      return Future<void>.value();
    }
    _latestState = state;
    if (!_initialized) {
      if (!_retryExhausted && _initialization == null && _retryTimer == null) {
        unawaited(_initialize());
      }
      return _initialization ?? Future<void>.value();
    }
    return _publishLatest();
  }

  Future<void> _initialize() {
    if (_disposed || _initialized) {
      return Future<void>.value();
    }
    final active = _initialization;
    if (active != null) {
      return active;
    }

    _retryTimer?.cancel();
    _retryTimer = null;
    late final Future<void> attempt;
    attempt =
        () async {
          try {
            await _session.initialize(_callbacks);
          } catch (error, stackTrace) {
            debugPrint(
              'Desktop media session initialization failed: $error\n$stackTrace',
            );
            if (!_disposed && _retryIndex < _retryBackoff.length) {
              final delay = _retryBackoff[_retryIndex++];
              _retryTimer = Timer(delay, () {
                _retryTimer = null;
                unawaited(_initialize());
              });
            } else if (!_disposed) {
              _retryExhausted = true;
            }
            return;
          }

          if (_disposed) {
            return;
          }
          _initialized = true;
          _retryIndex = 0;
          _retryExhausted = false;
          await _publishLatest();
        }().whenComplete(() {
          if (identical(_initialization, attempt)) {
            _initialization = null;
          }
        });
    _initialization = attempt;
    return attempt;
  }

  Future<void> _publishLatest() {
    _publishRequested = true;
    final previous = _updateTail;
    late final Future<void> update;
    update = () async {
      await previous.catchError((Object _) {});
      while (_publishRequested && !_disposed && _initialized) {
        _publishRequested = false;
        final state = _latestState;
        if (state == null) {
          continue;
        }
        try {
          await _session.update(state);
        } catch (error, stackTrace) {
          debugPrint(
            'Desktop media session update failed: $error\n$stackTrace',
          );
        }
      }
    }();
    _updateTail = update;
    return update;
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _initialization?.catchError((Object _) {});
    await _updateTail.catchError((Object _) {});
    await _session.dispose();
  }
}
