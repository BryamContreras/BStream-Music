import 'dart:async';

/// Cooperative cancellation shared by HTTP setup, WebSocket streaming, and
/// reconnect delays.
///
/// A broadcast stream is used instead of attaching callbacks to a single
/// never-completing Future on every reconnect. Each operation cancels its own
/// subscription in `finally`, so long LIVE sessions do not retain old sockets.
class CancellationToken {
  final _events = StreamController<void>.broadcast();
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  Stream<void> get onCancel => _events.stream;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _events.add(null);
    unawaited(_events.close());
  }
}
