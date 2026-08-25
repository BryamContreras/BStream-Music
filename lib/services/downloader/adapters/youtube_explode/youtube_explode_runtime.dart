import 'dart:async';
import 'dart:collection';

import 'package:youtube_explode_dart/js_challenge.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../platform_channels/android_ytdl_channel.dart';
import '../../audio_stream_resolver.dart';
import '../../desktop_tool_locator.dart';
import 'android_quickjs_ejs_solver.dart';
import 'android_web_po_token_provider.dart';
import 'youtube_audio_stream_selector.dart';

/// Playback manifests should not wait behind background download manifests.
enum YoutubeExplodeManifestPriority { playback, download }

/// Owns the YouTube clients and the optional JavaScript challenge solver.
///
/// The no-solver client is created immediately on first use. The solver-backed
/// client is initialized only after a solver-dependent attempt is reached, so
/// normal playback does not pay the EJS download/runtime startup cost.
class YoutubeExplodeRuntime {
  YoutubeExplodeRuntime({
    required this.platform,
    this.androidChannel,
    this.denoExecutable,
    int? maximumConcurrentManifestRequests,
    Duration? manifestQueueTimeout,
  }) : _manifestScheduler = _YoutubeExplodeManifestScheduler(
         maximumConcurrentManifestRequests ??
             (platform == AppPlatformType.android ? 1 : 2),
         queueTimeout:
             manifestQueueTimeout ??
             (platform == AppPlatformType.android
                 ? const Duration(seconds: 2)
                 : const Duration(seconds: 4)),
       );

  final AppPlatformType platform;
  final AndroidYtdlChannel? androidChannel;
  final String? denoExecutable;
  final _YoutubeExplodeManifestScheduler _manifestScheduler;
  Future<YoutubeExplode>? _fastClientFuture;
  Future<YoutubeExplode>? _solverClientFuture;
  Future<BaseJSChallengeSolver>? _solverFuture;
  AndroidWebPoTokenProvider? _androidPoTokenProvider;
  bool _disposed = false;

  bool get supportsSolver =>
      platform == AppPlatformType.android ||
      platform == AppPlatformType.windows ||
      platform == AppPlatformType.linux ||
      platform == AppPlatformType.macos;

  Future<YoutubeExplode> get fastClient {
    _checkNotDisposed();
    return _fastClientFuture ??= Future<YoutubeExplode>.value(
      YoutubeExplode(
        manifestClientsProvider: () => _manifestClients(useSolver: false),
      ),
    );
  }

  Future<YoutubeExplode> get solverClient {
    _checkNotDisposed();
    if (!supportsSolver) {
      return Future<YoutubeExplode>.error(
        UnsupportedError('No JavaScript solver is available on this platform.'),
      );
    }
    return _solverClientFuture ??= _createSolverClient();
  }

  Future<YoutubeExplode> clientFor(YoutubeManifestAttempt attempt) {
    return attempt.requiresJsSolver ? solverClient : fastClient;
  }

  /// Runs a bounded manifest operation shared by playback and downloads.
  ///
  /// Queued playback work is preferred over downloads. A request that became
  /// obsolete while waiting is rejected before it can touch YouTube.
  Future<T> runManifestRequest<T>({
    required YoutubeExplodeManifestPriority priority,
    required Future<T> Function() operation,
    AudioResolverContinuationCallback? shouldContinue,
    Duration? executionTimeout,
    Object Function(Duration timeout)? executionTimeoutError,
    void Function()? onExecutionTimeout,
  }) {
    _checkNotDisposed();
    return _manifestScheduler.schedule(
      priority: priority,
      operation: operation,
      shouldContinue: shouldContinue,
      executionTimeout: executionTimeout,
      executionTimeoutError: executionTimeoutError,
      onExecutionTimeout: onExecutionTimeout,
    );
  }

  Future<YoutubeExplode> _createSolverClient() async {
    final solver = await (_solverFuture ??= _createSolver());
    final poTokenProvider = platform == AppPlatformType.android
        ? (_androidPoTokenProvider ??= AndroidWebPoTokenProvider(
            channel: androidChannel,
          ))
        : null;
    return YoutubeExplode(
      jsSolver: solver,
      poTokenProvider: poTokenProvider,
      manifestClientsProvider: () => _manifestClients(useSolver: true),
    );
  }

  Future<void> prewarmPoTokens() async {
    if (_disposed || platform != AppPlatformType.android) {
      return;
    }
    final provider = _androidPoTokenProvider ??= AndroidWebPoTokenProvider(
      channel: androidChannel,
    );
    await provider.prewarm();
  }

  Future<BaseJSChallengeSolver> _createSolver() async {
    switch (platform) {
      case AppPlatformType.android:
        return AndroidQuickJsEjsSolver(channel: androidChannel);
      case AppPlatformType.windows:
      case AppPlatformType.linux:
      case AppPlatformType.macos:
        return DenoEJSSolver.init(
          denoExe: denoExecutable ?? findBundledDenoExecutable(),
        );
      case AppPlatformType.unsupported:
        throw UnsupportedError('No JavaScript solver is available.');
    }
  }

  List<YoutubeApiClient> _manifestClients({required bool useSolver}) {
    return defaultYoutubeManifestAttempts
        .where((attempt) => useSolver || !attempt.requiresJsSolver)
        .map((attempt) => attempt.client)
        .toList(growable: false);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _manifestScheduler.dispose();
    final clients = <Future<YoutubeExplode>>[
      ?_fastClientFuture,
      ?_solverClientFuture,
    ];
    var solverClientClosed = false;
    for (final future in clients) {
      try {
        (await future).close();
        if (identical(future, _solverClientFuture)) {
          solverClientClosed = true;
        }
      } catch (_) {}
    }
    if (!solverClientClosed) {
      _androidPoTokenProvider?.dispose();
      final solverFuture = _solverFuture;
      if (solverFuture != null) {
        try {
          (await solverFuture).dispose();
        } catch (_) {}
      }
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('YoutubeExplodeRuntime was disposed.');
    }
  }
}

class _YoutubeExplodeManifestScheduler {
  _YoutubeExplodeManifestScheduler(
    this.maximumConcurrentRequests, {
    required this.queueTimeout,
  }) {
    if (maximumConcurrentRequests <= 0) {
      throw ArgumentError.value(
        maximumConcurrentRequests,
        'maximumConcurrentManifestRequests',
        'Must be positive.',
      );
    }
    if (queueTimeout <= Duration.zero) {
      throw ArgumentError.value(
        queueTimeout,
        'manifestQueueTimeout',
        'Must be positive.',
      );
    }
  }

  final int maximumConcurrentRequests;
  final Duration queueTimeout;
  final ListQueue<_YoutubeExplodeManifestJob> _playbackQueue = ListQueue();
  final ListQueue<_YoutubeExplodeManifestJob> _downloadQueue = ListQueue();
  int _active = 0;
  int _activeDownloads = 0;
  bool _disposed = false;

  Future<T> schedule<T>({
    required YoutubeExplodeManifestPriority priority,
    required Future<T> Function() operation,
    AudioResolverContinuationCallback? shouldContinue,
    Duration? executionTimeout,
    Object Function(Duration timeout)? executionTimeoutError,
    void Function()? onExecutionTimeout,
  }) {
    if (_disposed) {
      return Future<T>.error(StateError('YoutubeExplodeRuntime was disposed.'));
    }
    final completer = Completer<T>();
    late final _YoutubeExplodeManifestJob job;
    Timer? queueTimer;
    job = _YoutubeExplodeManifestJob(
      priority: priority,
      execute: () async {
        job.started = true;
        queueTimer?.cancel();
        try {
          if (shouldContinue != null && !shouldContinue()) {
            throw const AudioStreamResolverException(
              'Audio stream resolution was superseded.',
            );
          }
          final operationFuture = Future<T>.sync(operation);
          Timer? executionTimer;
          if (executionTimeout != null) {
            executionTimer = Timer(executionTimeout, () {
              onExecutionTimeout?.call();
              if (!completer.isCompleted) {
                completer.completeError(
                  executionTimeoutError?.call(executionTimeout) ??
                      TimeoutException(
                        'YouTube manifest resolution timed out.',
                        executionTimeout,
                      ),
                  StackTrace.current,
                );
              }
            });
          }
          try {
            final result = await operationFuture;
            if (!completer.isCompleted) {
              completer.complete(result);
            }
          } finally {
            executionTimer?.cancel();
          }
        } catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
      reject: (error, stackTrace) {
        queueTimer?.cancel();
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    );
    switch (priority) {
      case YoutubeExplodeManifestPriority.playback:
        _playbackQueue.addLast(job);
      case YoutubeExplodeManifestPriority.download:
        _downloadQueue.addLast(job);
    }
    queueTimer = Timer(queueTimeout, () {
      if (job.started || !_removeQueued(job)) {
        return;
      }
      job.reject(
        TimeoutException(
          'YouTube manifest scheduler queue wait timed out.',
          queueTimeout,
        ),
        StackTrace.current,
      );
    });
    _drain();
    return completer.future;
  }

  bool _removeQueued(_YoutubeExplodeManifestJob job) {
    return _playbackQueue.remove(job) || _downloadQueue.remove(job);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final error = StateError('YoutubeExplodeRuntime was disposed.');
    final stackTrace = StackTrace.current;
    for (final queue in [_playbackQueue, _downloadQueue]) {
      while (queue.isNotEmpty) {
        queue.removeFirst().reject(error, stackTrace);
      }
    }
  }

  void _drain() {
    while (!_disposed && _active < maximumConcurrentRequests) {
      late final _YoutubeExplodeManifestJob job;
      if (_playbackQueue.isNotEmpty) {
        job = _playbackQueue.removeFirst();
      } else if (_downloadQueue.isNotEmpty && _activeDownloads == 0) {
        // Keep at least one desktop slot available for interactive playback;
        // on Android the global limit is already one.
        job = _downloadQueue.removeFirst();
      } else {
        break;
      }
      _active += 1;
      if (job.priority == YoutubeExplodeManifestPriority.download) {
        _activeDownloads += 1;
      }
      unawaited(
        job.execute().whenComplete(() {
          _active -= 1;
          if (job.priority == YoutubeExplodeManifestPriority.download) {
            _activeDownloads -= 1;
          }
          _drain();
        }),
      );
    }
  }
}

class _YoutubeExplodeManifestJob {
  _YoutubeExplodeManifestJob({
    required this.priority,
    required this.execute,
    required this.reject,
  });

  final YoutubeExplodeManifestPriority priority;
  final Future<void> Function() execute;
  final void Function(Object error, StackTrace stackTrace) reject;
  bool started = false;
}
