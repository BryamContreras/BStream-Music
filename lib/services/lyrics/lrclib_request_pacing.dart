typedef LrclibMonotonicClock = Duration Function();

class LrclibRequestBudget {
  LrclibRequestBudget(this.limit, this._clock) : _startedAt = _clock();

  final Duration limit;
  final LrclibMonotonicClock _clock;
  final Duration _startedAt;

  Duration get remaining {
    final value = limit - (_clock() - _startedAt);
    return value.isNegative ? Duration.zero : value;
  }

  bool get isExpired => remaining <= Duration.zero;

  Duration timeoutFor(Duration requestTimeout) {
    final available = remaining;
    if (available <= Duration.zero) {
      return const Duration(microseconds: 1);
    }
    return available < requestTimeout ? available : requestTimeout;
  }
}

class LrclibRequestPacer {
  LrclibRequestPacer(this.minimumSpacing, this._clock);

  final Duration minimumSpacing;
  final LrclibMonotonicClock _clock;
  Duration? _lastRequestStartedAt;

  Duration get waitBeforeNextRequest {
    final previous = _lastRequestStartedAt;
    if (previous == null) {
      return Duration.zero;
    }
    final elapsed = _clock() - previous;
    final wait = minimumSpacing - elapsed;
    return wait.isNegative ? Duration.zero : wait;
  }

  void markRequestStarted() {
    _lastRequestStartedAt = _clock();
  }
}
