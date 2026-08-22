import 'dart:async';
import 'dart:math' as math;

class CrossfadeGains {
  const CrossfadeGains({required this.outgoing, required this.incoming});

  final double outgoing;
  final double incoming;
}

enum CrossfadeConfigurationAction { none, checkStart, reset, deferDisable }

class CrossfadeConfigurationDecision {
  const CrossfadeConfigurationDecision({
    required this.enabled,
    required this.disableAfterHandoff,
    required this.action,
  });

  final bool enabled;
  final bool disableAfterHandoff;
  final CrossfadeConfigurationAction action;
}

/// Resolves enable/disable changes identically for every playback backend.
///
/// Disabling after both decks became audible is intentionally deferred until
/// promotion; resetting at that point would jump back to the outgoing track.
CrossfadeConfigurationDecision crossfadeConfigurationDecision({
  required bool currentEnabled,
  required bool overlapActive,
  required bool requestedEnabled,
}) {
  if (!requestedEnabled && overlapActive) {
    return CrossfadeConfigurationDecision(
      enabled: currentEnabled,
      disableAfterHandoff: true,
      action: CrossfadeConfigurationAction.deferDisable,
    );
  }
  if (currentEnabled == requestedEnabled) {
    return CrossfadeConfigurationDecision(
      enabled: currentEnabled,
      disableAfterHandoff: false,
      action: requestedEnabled
          ? CrossfadeConfigurationAction.checkStart
          : CrossfadeConfigurationAction.none,
    );
  }
  return CrossfadeConfigurationDecision(
    enabled: requestedEnabled,
    disableAfterHandoff: false,
    action: requestedEnabled
        ? CrossfadeConfigurationAction.none
        : CrossfadeConfigurationAction.reset,
  );
}

/// Returns the overlap duration when a prepared second deck should start.
///
/// Keeping this gate shared prevents JustAudio and MediaKit from drifting on
/// short tracks, late position ticks, or minimum handoff safety windows.
Duration? crossfadeStartDuration({
  required bool enabled,
  required bool disposed,
  required bool overlapActive,
  required bool promotionInProgress,
  required bool sourcePrepared,
  required bool standbyReady,
  required bool playing,
  required Duration? trackDuration,
  required Duration position,
  required Duration configuredDuration,
  Duration minimumRemaining = const Duration(milliseconds: 350),
}) {
  if (!enabled ||
      disposed ||
      overlapActive ||
      promotionInProgress ||
      !sourcePrepared ||
      !standbyReady ||
      !playing ||
      trackDuration == null ||
      trackDuration <= Duration.zero) {
    return null;
  }
  final remaining = trackDuration - position;
  if (remaining > configuredDuration || remaining < minimumRemaining) {
    return null;
  }
  return remaining < configuredDuration ? remaining : configuredDuration;
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
