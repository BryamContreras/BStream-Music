part of 'music_providers.dart';

final sleepTimerControllerProvider =
    NotifierProvider<SleepTimerController, SleepTimerState>(
      SleepTimerController.new,
    );

class SleepTimerState {
  const SleepTimerState({
    required this.isActive,
    required this.selectedDuration,
    required this.remaining,
    this.endsAt,
  });

  const SleepTimerState.inactive({
    this.selectedDuration = const Duration(minutes: 30),
  }) : isActive = false,
       remaining = Duration.zero,
       endsAt = null;

  final bool isActive;
  final Duration selectedDuration;
  final Duration remaining;
  final DateTime? endsAt;
}

class SleepTimerController extends Notifier<SleepTimerState> {
  Timer? _ticker;

  @override
  SleepTimerState build() {
    ref.onDispose(_cancelTicker);
    return const SleepTimerState.inactive();
  }

  void setEnabled(bool enabled) {
    if (enabled) {
      start(state.selectedDuration);
    } else {
      cancel();
    }
  }

  void selectDuration(Duration duration) {
    if (duration <= Duration.zero) {
      return;
    }
    if (state.isActive) {
      start(duration);
      return;
    }
    state = SleepTimerState.inactive(selectedDuration: duration);
  }

  void start(Duration duration) {
    if (duration <= Duration.zero) {
      return;
    }
    _cancelTicker();
    final endsAt = DateTime.now().add(duration);
    state = SleepTimerState(
      isActive: true,
      selectedDuration: duration,
      remaining: duration,
      endsAt: endsAt,
    );
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void cancel() {
    _cancelTicker();
    state = SleepTimerState.inactive(selectedDuration: state.selectedDuration);
  }

  void _tick() {
    final endsAt = state.endsAt;
    if (!state.isActive || endsAt == null) {
      _cancelTicker();
      return;
    }
    final remaining = endsAt.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      unawaited(_expire());
      return;
    }
    state = SleepTimerState(
      isActive: true,
      selectedDuration: state.selectedDuration,
      remaining: remaining,
      endsAt: endsAt,
    );
  }

  Future<void> _expire() async {
    if (!state.isActive) {
      return;
    }
    final selectedDuration = state.selectedDuration;
    _cancelTicker();
    state = SleepTimerState.inactive(selectedDuration: selectedDuration);
    await ref.read(playerControllerProvider.notifier).stop();
  }

  void _cancelTicker() {
    _ticker?.cancel();
    _ticker = null;
  }
}
