import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/platform/app_platform.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import 'player_service.dart';

typedef MediaKitOperationDeadline = Future<void> Function(Duration duration);

abstract interface class MediaKitPlayerBackend {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<double> get volumeStream;
  Stream<bool> get bufferingStream;
  Stream<bool> get playingStream;
  Stream<bool> get completedStream;
  Stream<String> get errorStream;
  Object? get platform;

  /// Detaches every in-flight command from the backend used by future calls.
  ///
  /// media_kit serializes native commands internally. A load which never
  /// completes would otherwise also block a later open or stop. Implementors
  /// must make subsequent calls target a fresh backend so a late completion
  /// cannot replace the new source.
  void abandonPendingOperations();

  Future<void> open(Media media, {required bool play});
  Future<void> pause();
  Future<void> play();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> dispose();
}

class _MediaKitPlayerBackend implements MediaKitPlayerBackend {
  _MediaKitPlayerBackend() {
    _player = _createPlayer();
    _playerSubscriptions = _forwardEvents(_player, _epoch);
  }

  late Player _player;
  late List<StreamSubscription<Object?>> _playerSubscriptions;
  int _epoch = 0;
  bool _disposed = false;

  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _volumes = StreamController<double>.broadcast();
  final _bufferings = StreamController<bool>.broadcast();
  final _playings = StreamController<bool>.broadcast();
  final _completions = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();

  Player _createPlayer() => Player(
    configuration: const PlayerConfiguration(title: AppConstants.appName),
  );

  List<StreamSubscription<Object?>> _forwardEvents(Player player, int epoch) {
    bool isCurrent() => !_disposed && epoch == _epoch;
    return <StreamSubscription<Object?>>[
      player.stream.position.listen((value) {
        if (isCurrent()) _positions.add(value);
      }),
      player.stream.duration.listen((value) {
        if (isCurrent()) _durations.add(value);
      }),
      player.stream.volume.listen((value) {
        if (isCurrent()) _volumes.add(value);
      }),
      player.stream.buffering.listen((value) {
        if (isCurrent()) _bufferings.add(value);
      }),
      player.stream.playing.listen((value) {
        if (isCurrent()) _playings.add(value);
      }),
      player.stream.completed.listen((value) {
        if (isCurrent()) _completions.add(value);
      }),
      player.stream.error.listen((value) {
        if (isCurrent()) _errors.add(value);
      }),
    ];
  }

  @override
  void abandonPendingOperations() {
    if (_disposed) {
      return;
    }
    final retiredPlayer = _player;
    final retiredSubscriptions = _playerSubscriptions;
    final epoch = ++_epoch;
    _player = _createPlayer();
    _playerSubscriptions = _forwardEvents(_player, epoch);
    unawaited(_retire(retiredPlayer, retiredSubscriptions));
  }

  Future<void> _retire(
    Player player,
    List<StreamSubscription<Object?>> subscriptions,
  ) async {
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        // Bypass media_kit's command lock: that lock is precisely what a
        // wedged open is holding. `quit` is also the command media_kit itself
        // uses to retire orphaned native references. It is dispatched before
        // command() first yields, so even a missing reply cannot delay the new
        // Player or allow this old instance to resume later.
        unawaited(
          platform
              .command(const ['quit'], waitForInitialization: false)
              .catchError((Object _) {}),
        );
      } else {
        await player.stop();
      }
    } catch (_) {
      // Best effort. The retired instance can no longer affect the service.
    }
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    try {
      await player.dispose();
    } catch (_) {
      // Native teardown can fail after a broken decoder/load. Process shutdown
      // remains the final owner of an unreachable retired instance.
    }
  }

  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration> get durationStream => _durations.stream;
  @override
  Stream<double> get volumeStream => _volumes.stream;
  @override
  Stream<bool> get bufferingStream => _bufferings.stream;
  @override
  Stream<bool> get playingStream => _playings.stream;
  @override
  Stream<bool> get completedStream => _completions.stream;
  @override
  Stream<String> get errorStream => _errors.stream;
  @override
  Object? get platform => _player.platform;

  @override
  Future<void> open(Media media, {required bool play}) =>
      _player.open(media, play: play);
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> play() => _player.play();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _epoch++;
    for (final subscription in _playerSubscriptions) {
      await subscription.cancel();
    }
    await Future.wait<void>([
      _positions.close(),
      _durations.close(),
      _volumes.close(),
      _bufferings.close(),
      _playings.close(),
      _completions.close(),
      _errors.close(),
    ]);
    await _player.dispose();
  }
}

class MediaKitPlayerService implements PlayerService {
  MediaKitPlayerService({
    MediaKitPlayerBackend? backend,
    Duration operationTimeout = const Duration(seconds: 45),
    MediaKitOperationDeadline? operationDeadline,
  }) : assert(operationTimeout > Duration.zero),
       _operationTimeout = operationTimeout,
       // Public injection name is intentional; the stored hook stays private.
       // ignore: prefer_initializing_formals
       _operationDeadline = operationDeadline {
    if (backend == null) {
      _ensureInitialized();
      _player = _MediaKitPlayerBackend();
    } else {
      _player = backend;
    }
    _subscriptions.addAll([
      _player.positionStream.listen((position) {
        if (!_acceptBackendEvent) {
          return;
        }
        _emit(_snapshot.copyWith(position: position));
      }),
      _player.durationStream.listen((duration) {
        if (!_acceptBackendEvent) {
          return;
        }
        _emit(_snapshot.copyWith(duration: duration));
      }),
      _player.volumeStream.listen((volume) {
        if (!_acceptBackendEvent) {
          return;
        }
        _emit(
          _snapshot.copyWith(volume: (volume / 100).clamp(0, 1).toDouble()),
        );
      }),
      _player.bufferingStream.listen((buffering) {
        if (!_acceptBackendEvent) {
          return;
        }
        if (_snapshot.status == PlayerStatus.failed) {
          return;
        }
        if (buffering && _snapshot.status != PlayerStatus.playing) {
          _emit(_snapshot.copyWith(status: PlayerStatus.loading));
        }
      }),
      _player.playingStream.listen((playing) {
        if (!_acceptBackendEvent) {
          return;
        }
        if (_snapshot.status == PlayerStatus.failed) {
          return;
        }
        if (!playing && _snapshot.status == PlayerStatus.stopped) {
          return;
        }
        _emit(
          _snapshot.copyWith(
            status: playing ? PlayerStatus.playing : PlayerStatus.paused,
          ),
        );
      }),
      _player.completedStream.listen((completed) {
        if (!_acceptBackendEvent) {
          return;
        }
        if (_snapshot.status == PlayerStatus.failed) {
          return;
        }
        if (completed) {
          _emit(_snapshot.copyWith(status: PlayerStatus.stopped));
        }
      }),
      _player.errorStream.listen((message) {
        if (!_acceptBackendEvent) {
          return;
        }
        _emit(
          _snapshot.copyWith(
            status: PlayerStatus.failed,
            errorMessage: message,
          ),
        );
      }),
    ]);
  }

  late final MediaKitPlayerBackend _player;
  final _snapshotController = StreamController<PlayerSnapshot>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final Duration _operationTimeout;
  final MediaKitOperationDeadline? _operationDeadline;

  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  Future<void> _operationTail = Future<void>.value();
  _MediaKitOperationLease? _activeOperation;
  int _requestedGeneration = 0;
  int? _backendGeneration;
  bool _disposed = false;

  static bool _initialized = false;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  bool get supportsLocalQueueReplacement => false;

  @override
  Future<void> playRemote(TrackInfo track) async {
    final source = track.streamUrl;
    if (source == null || source.isEmpty) {
      throw const PlayerException(
        'No hay una URL reproducible. Obten la informacion del track primero.',
        code: 'missing_stream_url',
      );
    }

    final generation = ++_requestedGeneration;
    _cancelActiveOpen();
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id.isEmpty ? track.url : track.id,
        sourceUrl: track.url,
        thumbnailUrl: track.thumbnailUrl,
        duration: track.duration,
        volume: _snapshot.volume,
        isRemote: true,
      ),
    );
    await _openForGeneration(
      Media(source, httpHeaders: track.httpHeaders),
      generation,
      play: true,
    );
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    final generation = ++_requestedGeneration;
    _cancelActiveOpen();
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id,
        sourceUrl: track.sourceUrl,
        thumbnailUrl: track.thumbnailPath ?? track.thumbnailUrl,
        duration: track.duration,
        volume: _snapshot.volume,
        isRemote: false,
        isExternal: track.isExternal,
      ),
    );
    await _openForGeneration(Media(track.filePath), generation, play: true);
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) {
    if (tracks.isEmpty) {
      return Future.value();
    }
    final safeIndex = initialIndex.clamp(0, tracks.length - 1);
    return playLocal(tracks[safeIndex]);
  }

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {
    // Desktop playback remains controller-managed. If the current item still
    // exists, updating the controller queue is enough and preserves position.
    if (tracks.any((track) => track.id == _snapshot.trackId)) {
      return;
    }
    if (tracks.isEmpty) {
      await stop();
      return;
    }

    final safeIndex = preferredIndex.clamp(0, tracks.length - 1).toInt();
    final track = tracks[safeIndex];
    final shouldPlay = _snapshot.status == PlayerStatus.playing;
    final generation = ++_requestedGeneration;
    _cancelActiveOpen();
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id,
        sourceUrl: track.sourceUrl,
        thumbnailUrl: track.thumbnailPath ?? track.thumbnailUrl,
        duration: track.duration,
        volume: _snapshot.volume,
        isRemote: false,
        isExternal: track.isExternal,
      ),
    );
    await _openForGeneration(
      Media(track.filePath),
      generation,
      play: shouldPlay,
    );
  }

  @override
  Future<void> pause() async {
    final generation = _requestedGeneration;
    await _enqueueOperation(() async {
      if (!_isCurrentGeneration(generation)) {
        return;
      }
      await _player.pause();
      if (_isCurrentGeneration(generation)) {
        _emit(_snapshot.copyWith(status: PlayerStatus.paused));
      }
    }, label: 'pause');
  }

  @override
  Future<void> resume() async {
    final generation = _requestedGeneration;
    await _enqueueOperation(() async {
      if (!_isCurrentGeneration(generation)) {
        return;
      }
      await _player.play();
      if (_isCurrentGeneration(generation)) {
        _emit(_snapshot.copyWith(status: PlayerStatus.playing));
      }
    }, label: 'play');
  }

  @override
  Future<void> togglePlayPause() {
    return _snapshot.status == PlayerStatus.playing ? pause() : resume();
  }

  @override
  Future<void> stop() {
    final generation = ++_requestedGeneration;
    _backendGeneration = null;
    _cancelActiveOperation();
    return _enqueueOperation(() async {
      if (!_isCurrentGeneration(generation)) {
        return;
      }
      await _player.stop();
      if (_isCurrentGeneration(generation)) {
        _emit(_snapshot.copyWith(status: PlayerStatus.stopped));
      }
    }, label: 'stop');
  }

  @override
  Future<void> seek(Duration position) {
    final generation = _requestedGeneration;
    return _enqueueOperation(() async {
      if (_isCurrentGeneration(generation)) {
        await _player.seek(position);
      }
    }, label: 'seek');
  }

  @override
  Future<void> setVolume(double volume) {
    final normalized = volume.clamp(0, 1).toDouble();
    _emit(_snapshot.copyWith(volume: normalized));
    return _enqueueOperation(
      () => _player.setVolume(normalized * 100),
      label: 'setVolume',
    );
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    _emit(_snapshot.copyWith(shuffleEnabled: enabled));
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {
    _emit(_snapshot.copyWith(repeatMode: mode));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _requestedGeneration++;
    _backendGeneration = null;
    _cancelActiveOperation();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await _runStandaloneWithDeadline(_player.dispose, label: 'dispose');
    } on TimeoutException {
      // The native backend may be wedged in an earlier open. Dart-side
      // resources must still be released and application shutdown must finish.
    } finally {
      await _snapshotController.close();
    }
  }

  static void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    MediaKit.ensureInitialized();
    _initialized = true;
  }

  Future<void> _configureLinuxAudioClientName() async {
    if (!AppPlatform.isLinux) {
      return;
    }

    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        // PipeWire's native mpv backend uses this option instead of the
        // PulseAudio application properties set by the GTK runner.
        await platform.setProperty('audio-client-name', AppConstants.appName);
      } catch (_) {
        // Playback must remain functional if an older libmpv ignores this
        // optional metadata property.
      }
    }
  }

  Future<void> _openForGeneration(
    Media media,
    int generation, {
    required bool play,
  }) {
    return _enqueueOperation(
      () async {
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        await _configureLinuxAudioClientName();
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        // A cancelled open is isolated by a new backend. Restore the logical
        // volume before that replacement begins playback.
        await _player.setVolume(_snapshot.volume * 100);
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        // Until open returns, backend events may still belong to the source that
        // is being interrupted. Publish only the explicit loading snapshot.
        _backendGeneration = null;
        try {
          await _player.open(media, play: play);
        } catch (_) {
          if (_isCurrentGeneration(generation)) {
            rethrow;
          }
          return;
        }
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        _backendGeneration = generation;
        _emit(
          _snapshot.copyWith(
            status: play ? PlayerStatus.playing : PlayerStatus.paused,
          ),
        );
      },
      isOpen: true,
      label: 'open',
      onTimeout: () {
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        _requestedGeneration++;
        _backendGeneration = null;
        _emit(
          _snapshot.copyWith(
            status: PlayerStatus.failed,
            errorMessage: 'El reproductor tardo demasiado en abrir el audio.',
          ),
        );
      },
    );
  }

  Future<void> _enqueueOperation(
    Future<void> Function() operation, {
    bool isOpen = false,
    required String label,
    void Function()? onTimeout,
  }) {
    final future = _operationTail.then((_) async {
      if (_disposed) {
        return;
      }
      final lease = _MediaKitOperationLease(isOpen: isOpen);
      _activeOperation = lease;
      try {
        await _runWithDeadline(
          operation,
          lease,
          label: label,
          onTimeout: onTimeout,
        );
      } finally {
        if (identical(_activeOperation, lease)) {
          _activeOperation = null;
        }
      }
    });
    _operationTail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return future;
  }

  Future<void> _runWithDeadline(
    Future<void> Function() operation,
    _MediaKitOperationLease lease, {
    required String label,
    void Function()? onTimeout,
  }) {
    final result = Completer<void>();
    Future<void>.sync(operation).then(
      (_) {
        if (!result.isCompleted) {
          result.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      },
    );
    lease.cancelled.then((_) {
      if (!result.isCompleted) {
        result.complete();
      }
    });
    void completeTimeout() {
      if (result.isCompleted || lease.isCancelled) {
        return;
      }
      try {
        // The raw native Future remains alive after a Dart timeout. Move all
        // future commands and events to a fresh Player before releasing the
        // service lane, so that late native completion is harmless.
        _player.abandonPendingOperations();
        _backendGeneration = null;
        onTimeout?.call();
        result.completeError(
          TimeoutException(
            'media_kit $label exceeded $_operationTimeout',
            _operationTimeout,
          ),
        );
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }

    Timer? timer;
    final injectedDeadline = _operationDeadline;
    if (injectedDeadline == null) {
      timer = Timer(_operationTimeout, completeTimeout);
    } else {
      injectedDeadline(_operationTimeout).then(
        (_) => completeTimeout(),
        onError: (Object error, StackTrace stackTrace) {
          if (!result.isCompleted) {
            result.completeError(error, stackTrace);
          }
        },
      );
    }
    return result.future.whenComplete(() => timer?.cancel());
  }

  Future<void> _runStandaloneWithDeadline(
    Future<void> Function() operation, {
    required String label,
  }) {
    return _runWithDeadline(
      operation,
      _MediaKitOperationLease(isOpen: false),
      label: label,
    );
  }

  void _cancelActiveOpen() {
    final operation = _activeOperation;
    if (operation?.isOpen == true) {
      operation!.cancel();
      _backendGeneration = null;
      _player.abandonPendingOperations();
    }
  }

  void _cancelActiveOperation() {
    final operation = _activeOperation;
    if (operation == null) {
      return;
    }
    operation.cancel();
    _backendGeneration = null;
    _player.abandonPendingOperations();
  }

  bool _isCurrentGeneration(int generation) =>
      !_disposed && generation == _requestedGeneration;

  bool get _acceptBackendEvent =>
      !_disposed && _backendGeneration == _requestedGeneration;

  void _emit(PlayerSnapshot snapshot) {
    if (_disposed) {
      return;
    }
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }
}

class _MediaKitOperationLease {
  _MediaKitOperationLease({required this.isOpen});

  final bool isOpen;
  final Completer<void> _cancellation = Completer<void>();
  bool _isCancelled = false;

  Future<void> get cancelled => _cancellation.future;
  bool get isCancelled => _isCancelled;

  void cancel() {
    if (!_cancellation.isCompleted) {
      _isCancelled = true;
      _cancellation.complete();
    }
  }
}
