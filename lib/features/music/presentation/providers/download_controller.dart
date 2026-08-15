part of 'music_providers.dart';

final downloadControllerProvider =
    NotifierProvider<DownloadController, Map<String, DownloadTaskState>>(
      DownloadController.new,
    );

const _unsetDownloadTaskValue = Object();

class DownloadTaskState {
  const DownloadTaskState({
    required this.url,
    required this.taskId,
    required this.mediaType,
    required this.status,
    this.progress,
    this.result,
    this.localTrack,
    this.errorMessage,
    this.title,
    this.reusedExisting = false,
  });

  final String url;
  final String taskId;
  final DownloadMediaType mediaType;
  final DownloadProgressStatus status;
  final double? progress;
  final DownloadResult? result;
  final LocalTrack? localTrack;
  final String? errorMessage;
  final String? title;
  final bool reusedExisting;

  DownloadTaskState copyWith({
    DownloadProgressStatus? status,
    Object? progress = _unsetDownloadTaskValue,
    Object? result = _unsetDownloadTaskValue,
    Object? localTrack = _unsetDownloadTaskValue,
    Object? errorMessage = _unsetDownloadTaskValue,
    Object? title = _unsetDownloadTaskValue,
    bool? reusedExisting,
  }) {
    return DownloadTaskState(
      url: url,
      taskId: taskId,
      mediaType: mediaType,
      status: status ?? this.status,
      progress: identical(progress, _unsetDownloadTaskValue)
          ? this.progress
          : (progress as num?)?.toDouble(),
      result: identical(result, _unsetDownloadTaskValue)
          ? this.result
          : result as DownloadResult?,
      localTrack: identical(localTrack, _unsetDownloadTaskValue)
          ? this.localTrack
          : localTrack as LocalTrack?,
      errorMessage: identical(errorMessage, _unsetDownloadTaskValue)
          ? this.errorMessage
          : errorMessage as String?,
      title: identical(title, _unsetDownloadTaskValue)
          ? this.title
          : title as String?,
      reusedExisting: reusedExisting ?? this.reusedExisting,
    );
  }
}

class DownloadController extends Notifier<Map<String, DownloadTaskState>> {
  final _queue = <TrackInfo>[];
  final _cleanupTimers = <String, Timer>{};
  bool _isProcessing = false;

  @override
  Map<String, DownloadTaskState> build() {
    final subscription = ref
        .watch(downloaderServiceProvider)
        .progressStream
        .listen((progress) {
          final taskKey = _taskKeyForProgress(progress);
          final existing = taskKey == null ? null : state[taskKey];
          if (existing == null) {
            return;
          }
          final nextStatus = _nextStatusForProgress(existing, progress);
          final restartingAfterFailure =
              existing.status == DownloadProgressStatus.failed &&
              (progress.status == DownloadProgressStatus.queued ||
                  progress.status == DownloadProgressStatus.running);
          final nextProgress = restartingAfterFailure
              ? progress.progress
              : _nextProgress(existing.progress, progress.progress);
          final nextError = progress.status == DownloadProgressStatus.failed
              ? progress.message
              : null;
          if (nextStatus == existing.status &&
              nextProgress == existing.progress &&
              nextError == existing.errorMessage) {
            return;
          }
          state = {
            ...state,
            taskKey!: existing.copyWith(
              status: nextStatus,
              progress: nextProgress,
              errorMessage: nextError,
            ),
          };
        });
    ref.onDispose(subscription.cancel);
    ref.onDispose(() {
      for (final timer in _cleanupTimers.values) {
        timer.cancel();
      }
      _cleanupTimers.clear();
    });
    return const {};
  }

  Future<void> downloadAudio(TrackInfo track) {
    return _enqueue(track, DownloadMediaType.audio);
  }

  Future<LocalTrack> downloadAudioForLibrary(
    TrackInfo track, {
    void Function()? onDownloadStarted,
  }) async {
    final result = await ref
        .read(localTrackDownloadHelperProvider)
        .resolveForLibrary(track, onDownloadStarted: onDownloadStarted);
    return result.track;
  }

  Future<void> _enqueue(TrackInfo track, DownloadMediaType mediaType) async {
    final existing = state[track.url];
    if (existing != null &&
        existing.status != DownloadProgressStatus.failed &&
        existing.status != DownloadProgressStatus.completed) {
      return;
    }

    _cleanupTimers.remove(track.url)?.cancel();
    state = {
      ...state,
      track.url: DownloadTaskState(
        url: track.url,
        taskId: const Uuid().v4(),
        mediaType: mediaType,
        status: DownloadProgressStatus.queued,
        title: track.title,
      ),
    };
    _queue.add(track);
    unawaited(_processQueue());
  }

  Future<void> _processQueue() async {
    if (_isProcessing) {
      return;
    }
    _isProcessing = true;

    try {
      while (_queue.isNotEmpty) {
        final track = _queue.removeAt(0);
        if (!state.containsKey(track.url)) {
          continue;
        }
        await _download(track);
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _download(TrackInfo track) async {
    final queued = state[track.url];
    if (queued == null) {
      return;
    }
    final taskId = queued.taskId;
    state = {
      ...state,
      track.url: queued.copyWith(status: DownloadProgressStatus.running),
    };

    try {
      final outcome = await ref
          .read(localTrackDownloadHelperProvider)
          .resolveForLibrary(
            track,
            taskId: taskId,
            onResolved: (resolved) {
              final active = state[track.url];
              if (active?.taskId != taskId) {
                return;
              }
              state = {
                ...state,
                track.url: active!.copyWith(title: resolved.title),
              };
            },
          );
      final active = state[track.url];
      if (active?.taskId != taskId) {
        return;
      }
      state = {
        ...state,
        track.url: active!.copyWith(
          status: DownloadProgressStatus.completed,
          progress: 1,
          result: outcome.downloadResult,
          localTrack: outcome.track,
          errorMessage: null,
          reusedExisting: outcome.reusedExisting,
        ),
      };
      _scheduleCleanup(track.url, const Duration(seconds: 3));
    } catch (error, stackTrace) {
      debugPrint('Audio download failed: $error\n$stackTrace');
      final active = state[track.url];
      if (active?.taskId != taskId) {
        return;
      }
      state = {
        ...state,
        track.url: active!.copyWith(
          status: DownloadProgressStatus.failed,
          errorMessage: error.toString(),
        ),
      };
      _scheduleCleanup(track.url, const Duration(seconds: 10));
    }
  }

  DownloadProgressStatus _nextStatusForProgress(
    DownloadTaskState existing,
    DownloadProgress progress,
  ) {
    if (progress.status == DownloadProgressStatus.queued &&
        existing.status == DownloadProgressStatus.running) {
      return DownloadProgressStatus.running;
    }

    if (progress.status == DownloadProgressStatus.completed &&
        existing.result == null &&
        existing.localTrack == null) {
      return DownloadProgressStatus.running;
    }

    return progress.status;
  }

  String? _taskKeyForProgress(DownloadProgress progress) {
    if (progress.taskId.isNotEmpty) {
      for (final entry in state.entries) {
        if (entry.value.taskId == progress.taskId) {
          return entry.key;
        }
      }
      return null;
    }
    return state.containsKey(progress.url) ? progress.url : null;
  }

  double? _nextProgress(double? current, double? incoming) {
    if (incoming == null || incoming.isNaN || incoming.isInfinite) {
      return current;
    }
    final normalized = incoming.clamp(0.0, 1.0).toDouble();
    if (current == null) {
      return normalized;
    }
    return math.max(current, normalized);
  }

  void _scheduleCleanup(String url, Duration delay) {
    _cleanupTimers.remove(url)?.cancel();
    _cleanupTimers[url] = Timer(delay, () {
      final next = Map<String, DownloadTaskState>.from(state)..remove(url);
      state = next;
      _cleanupTimers.remove(url);
    });
  }
}
