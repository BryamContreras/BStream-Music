import 'dart:async';

import 'package:flutter/scheduler.dart';

/// Vsync-aligned clocks for decoration, without requesting unused display
/// frames. Controls/gestures keep their ordinary TickerProvider.
class FrameRateTickerProvider implements TickerProvider {
  FrameRateTickerProvider({this.maxFramesPerSecond = 60})
    : assert(maxFramesPerSecond > 0);

  final double maxFramesPerSecond;
  final Set<_FrameRateTicker> _tickers = {};
  double _refreshRate = 60;
  bool _enabled = true;
  bool _disposed = false;

  void setDisplayRefreshRate(double hertz) {
    _refreshRate = hertz.isFinite && hertz > 0 ? hertz : 60;
    for (final ticker in _tickers) {
      ticker.delay = _delay;
    }
  }

  Duration get _delay {
    if (_refreshRate <= maxFramesPerSecond + 0.5) return Duration.zero;
    // Wake between the unwanted vsync and the next desired one. Requesting
    // only after that unwanted vsync avoids an otherwise idle 120 Hz frame.
    final stride = (_refreshRate / maxFramesPerSecond).ceil();
    return Duration(
      microseconds: ((stride - 0.5) * 1000000 / _refreshRate).round(),
    );
  }

  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    for (final ticker in _tickers) {
      ticker.muted = !value;
    }
  }

  @override
  Ticker createTicker(TickerCallback onTick) {
    assert(!_disposed);
    late final _FrameRateTicker ticker;
    ticker = _FrameRateTicker(
      onTick,
      delay: _delay,
      onDispose: () {
        _tickers.remove(ticker);
      },
    )..muted = !_enabled;
    _tickers.add(ticker);
    return ticker;
  }

  void dispose() {
    _disposed = true;
    for (final ticker in _tickers.toList(growable: false)) {
      ticker.dispose();
    }
    _tickers.clear();
  }
}

class _FrameRateTicker extends Ticker {
  _FrameRateTicker(
    super.onTick, {
    required this.delay,
    required this.onDispose,
  });

  Duration delay;
  final void Function() onDispose;
  _TickerFrameBatch? _batch;
  bool _disposed = false;

  @override
  bool get scheduled => _batch != null || super.scheduled;

  @override
  void scheduleTick({bool rescheduling = false}) {
    if (!rescheduling || delay == Duration.zero) {
      super.scheduleTick(rescheduling: rescheduling);
      return;
    }
    assert(shouldScheduleTick);
    _batch = _TickerFrameBatch.enqueue(this, delay);
  }

  void _requestFrame() {
    _batch = null;
    if (!_disposed && shouldScheduleTick) {
      // This registration is asynchronous, not inside the last vsync.
      super.scheduleTick();
    }
  }

  void _cancelWake() {
    _batch?.remove(this);
    _batch = null;
  }

  @override
  void unscheduleTick() {
    _cancelWake();
    super.unscheduleTick();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelWake();
    super.dispose();
    onDispose();
  }
}

/// Titles created on different frames converge on the same wake-up instead of
/// interleaving several bounded clocks into a screen-wide 120 Hz workload.
class _TickerFrameBatch {
  _TickerFrameBatch(this.delay);

  static final _batches = <Duration, _TickerFrameBatch>{};
  final Duration delay;
  final _pending = <_FrameRateTicker>{};
  Timer? _timer;

  static _TickerFrameBatch enqueue(_FrameRateTicker ticker, Duration delay) {
    final batch = _batches.putIfAbsent(delay, () => _TickerFrameBatch(delay));
    batch._pending.add(ticker);
    batch._timer ??= Timer(delay, batch._flush);
    return batch;
  }

  void remove(_FrameRateTicker ticker) {
    _pending.remove(ticker);
    if (_pending.isEmpty) {
      _timer?.cancel();
      _batches.remove(delay);
    }
  }

  void _flush() {
    _batches.remove(delay);
    _timer = null;
    final pending = _pending.toList(growable: false);
    _pending.clear();
    for (final ticker in pending) {
      ticker._requestFrame();
    }
  }
}
