part of '../music_providers.dart';

final playbackSessionStoreProvider = Provider<PlaybackSessionStore>(
  (ref) => SharedPreferencesPlaybackSessionStore(),
);

/// Saves selections promptly and checkpoints only the small cursor while
/// playing. The store independently reuses the unchanged queue payload.
class _PlaybackSessionCheckpoint with WidgetsBindingObserver {
  _PlaybackSessionCheckpoint({
    required this.store,
    required this.capture,
    required this.canPersist,
    required this.hasQueue,
  });

  final PlaybackSessionStore store;
  final PlaybackSession? Function() capture;
  final bool Function() canPersist;
  final bool Function() hasQueue;
  WidgetsBinding? _binding;
  Timer? _timer;
  bool _active = false;
  bool _disposed = false;
  bool _hasSeenQueue = false;

  void activate() {
    if (_active || _disposed) return;
    _active = true;
    _hasSeenQueue = hasQueue();
    // Pure controller tests need no binding; the production shell already
    // installs one before creating its providers.
    try {
      _binding = WidgetsBinding.instance;
      _binding!.addObserver(this);
    } catch (_) {
      _binding = null;
    }
  }

  void schedule({bool immediate = false}) {
    if (!_active || _disposed || !canPersist()) return;
    // A backend snapshot alone has no logical session to checkpoint. Once a
    // real queue existed, keep scheduling so removing it still clears storage.
    if (!_hasSeenQueue && !hasQueue()) return;
    _hasSeenQueue = true;
    if (immediate) {
      _timer?.cancel();
      _timer = null;
    }
    _timer ??= Timer(
      immediate ? Duration.zero : const Duration(seconds: 5),
      () => unawaited(flush()),
    );
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (!_active || _disposed || !canPersist()) return;
    final session = capture();
    if (session == null && !_hasSeenQueue) return;
    _hasSeenQueue = _hasSeenQueue || session != null;
    try {
      if (session == null) {
        await store.clear();
      } else {
        await store.write(session);
      }
    } catch (error) {
      debugPrint('Playback session checkpoint failed: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(flush());
  }

  void dispose() {
    if (_disposed) return;
    // Capture synchronously while the controller still owns its selection;
    // the immutable write may finish after Riverpod's synchronous disposal.
    unawaited(flush());
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _binding?.removeObserver(this);
  }
}
