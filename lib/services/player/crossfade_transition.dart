import 'dart:async';
import 'dart:math' as math;

class CrossfadeGains {
  const CrossfadeGains({required this.outgoing, required this.incoming});

  final double outgoing;
  final double incoming;
}

CrossfadeGains crossfadeGains({
  required double masterVolume,
  required double progress,
}) {
  final target = masterVolume.clamp(0, 1).toDouble();
  final normalizedProgress = progress.clamp(0, 1).toDouble();
  // Audio volume is an amplitude multiplier, while perceived energy follows
  // roughly its square. Square-root gains keep total power constant and make
  // the incoming track audible from the beginning instead of hiding it until
  // the outgoing deck is already near silence.
  return CrossfadeGains(
    outgoing: target * math.sqrt(1 - normalizedProgress),
    incoming: target * math.sqrt(normalizedProgress),
  );
}

typedef CrossfadeGainApplier = Future<void> Function(CrossfadeGains gains);
typedef CrossfadeStopwatchFactory = Stopwatch Function();

/// Drives one cancellable, pausable volume ramp. The stopwatch makes skipped
/// or delayed ticks catch up instead of extending the overlap unpredictably.
class CrossfadeRamp {
  CrossfadeRamp({
    required this.duration,
    required this.applyGains,
    this.tickInterval = const Duration(milliseconds: 40),
    CrossfadeStopwatchFactory stopwatchFactory = Stopwatch.new,
  }) : assert(duration > Duration.zero),
       assert(tickInterval > Duration.zero),
       _watch = stopwatchFactory();

  final Duration duration;
  final Duration tickInterval;
  final CrossfadeGainApplier applyGains;

  final Stopwatch _watch;
  final Completer<bool> _completion = Completer<bool>();
  Timer? _timer;
  bool _started = false;
  bool _cancelled = false;
  bool _applying = false;

  double get progress => (_watch.elapsedMicroseconds / duration.inMicroseconds)
      .clamp(0, 1)
      .toDouble();

  bool get isRunning => _started && !_cancelled && !_completion.isCompleted;

  Future<bool> start() {
    if (_started) {
      return _completion.future;
    }
    _started = true;
    _watch.start();
    _schedule();
    unawaited(_tick());
    return _completion.future;
  }

  void pause() {
    if (!isRunning || !_watch.isRunning) {
      return;
    }
    _watch.stop();
    _timer?.cancel();
    _timer = null;
  }

  void resume() {
    if (!isRunning || _watch.isRunning) {
      return;
    }
    _watch.start();
    _schedule();
  }

  void cancel() {
    if (_cancelled || _completion.isCompleted) {
      return;
    }
    _cancelled = true;
    _watch.stop();
    _timer?.cancel();
    _timer = null;
    _completion.complete(false);
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(tickInterval, (_) => unawaited(_tick()));
  }

  Future<void> _tick() async {
    if (!isRunning || !_watch.isRunning || _applying) {
      return;
    }
    _applying = true;
    try {
      final currentProgress = progress;
      await applyGains(
        crossfadeGains(masterVolume: 1, progress: currentProgress),
      );
      if (_cancelled || _completion.isCompleted || currentProgress < 1) {
        return;
      }
      _watch.stop();
      _timer?.cancel();
      _timer = null;
      _completion.complete(true);
    } catch (error, stackTrace) {
      _watch.stop();
      _timer?.cancel();
      _timer = null;
      if (!_completion.isCompleted) {
        _completion.completeError(error, stackTrace);
      }
    } finally {
      _applying = false;
    }
  }
}
