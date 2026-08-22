import 'dart:async';
import 'dart:developer' as developer;

import 'package:media_kit/media_kit.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/platform/app_platform.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import 'crossfade_transition.dart';
import 'player_service.dart';

typedef MediaKitOperationDeadline = Future<void> Function(Duration duration);
typedef MediaKitPlayerBackendFactory = MediaKitPlayerBackend Function();

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
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    try {
      // Use media_kit's single, serialized teardown path. Dispatching `quit`
      // and `dispose` together races two native destruction paths for the same
      // mpv context and can cause an access violation while scrubbing.
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

class MediaKitPlayerService implements PlayerService, CrossfadeCapablePlayer {
  static const _crossfadeShutdownGrace = Duration(seconds: 2);

  MediaKitPlayerService({
    MediaKitPlayerBackend? backend,
    MediaKitPlayerBackendFactory? backendFactory,
    Duration operationTimeout = const Duration(seconds: 45),
    MediaKitOperationDeadline? operationDeadline,
  }) : assert(operationTimeout > Duration.zero),
       _operationTimeout = operationTimeout,
       _backendFactory = backendFactory ?? _MediaKitPlayerBackend.new,
       _usesDefaultBackendFactory = backendFactory == null,
       // Public injection name is intentional; the stored hook stays private.
       // ignore: prefer_initializing_formals
       _operationDeadline = operationDeadline {
    if (backend == null) {
      if (_usesDefaultBackendFactory) {
        _ensureInitialized();
      }
      _player = _backendFactory();
    } else {
      _player = backend;
    }
    _attachActivePlayer(_player);
  }

  late MediaKitPlayerBackend _player;
  MediaKitPlayerBackend? _standbyPlayer;
  final MediaKitPlayerBackendFactory _backendFactory;
  final bool _usesDefaultBackendFactory;
  final _snapshotController = StreamController<PlayerSnapshot>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _standbySubscriptions = <StreamSubscription<Object?>>[];
  final Duration _operationTimeout;
  final MediaKitOperationDeadline? _operationDeadline;

  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  double _masterVolume = 1;
  Future<void> _operationTail = Future<void>.value();
  _MediaKitOperationLease? _activeOperation;
  int _requestedGeneration = 0;
  int? _backendGeneration;
  bool _disposed = false;
  bool _crossfadeEnabled = false;
  Duration _crossfadeDuration = const Duration(seconds: 5);
  int _crossfadeGeneration = 0;
  CrossfadePlaybackSource? _preparedCrossfadeSource;
  Future<void>? _crossfadePreparation;
  Completer<void>? _crossfadePreparationCancellation;
  CrossfadeRamp? _crossfadeRamp;
  bool _crossfadePromotionInProgress = false;
  Completer<void>? _crossfadePromotionCompletion;
  bool _disableCrossfadeAfterHandoff = false;
  bool _crossfadePaused = false;
  Future<void> _crossfadeVolumeWriteTail = Future<void>.value();
  Future<void> _seekTail = Future<void>.value();
  int _seekRevision = 0;
  Duration _standbyPosition = Duration.zero;
  Duration? _standbyDuration;

  static bool _initialized = false;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  bool get supportsLocalQueueReplacement => false;

  @override
  bool get crossfadeEnabled => _crossfadeEnabled;

  @override
  Future<void> configureCrossfade({
    required bool enabled,
    required Duration duration,
  }) async {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'Must be positive.');
    }
    _crossfadeDuration = duration;
    final decision = crossfadeConfigurationDecision(
      currentEnabled: _crossfadeEnabled,
      overlapActive: _crossfadeRamp != null,
      requestedEnabled: enabled,
    );
    _crossfadeEnabled = decision.enabled;
    _disableCrossfadeAfterHandoff = decision.disableAfterHandoff;
    switch (decision.action) {
      case CrossfadeConfigurationAction.checkStart:
        _maybeStartCrossfade();
      case CrossfadeConfigurationAction.reset:
        _crossfadeGeneration++;
        await _resetCrossfadeState(restoreActiveVolume: true);
      case CrossfadeConfigurationAction.none:
      case CrossfadeConfigurationAction.deferDisable:
        return;
    }
  }

  @override
  Future<void> prepareCrossfade(CrossfadePlaybackSource? source) async {
    if (_disposed) {
      return;
    }
    if (!_crossfadeEnabled || source == null) {
      _crossfadeGeneration++;
      await _resetCrossfadeState(restoreActiveVolume: true);
      return;
    }
    if (_crossfadeRamp != null) {
      // Once both tracks are audible, finish that handoff atomically. The new
      // queue/configuration will stage its successor after promotion.
      return;
    }

    final existing = _preparedCrossfadeSource;
    final preparation = _crossfadePreparation;
    if (existing?.logicalKey == source.logicalKey) {
      if (preparation != null) {
        await preparation;
      }
      return;
    }

    final generation = ++_crossfadeGeneration;
    await _resetCrossfadeState(restoreActiveVolume: true);
    if (!_isCrossfadeCurrent(generation)) {
      return;
    }

    final future = _prepareCrossfadeSource(source, generation);
    _crossfadePreparation = future;
    try {
      await future;
    } finally {
      if (identical(_crossfadePreparation, future)) {
        _crossfadePreparation = null;
      }
    }
  }

  Future<void> _prepareCrossfadeSource(
    CrossfadePlaybackSource source,
    int generation,
  ) async {
    final standby = _standbyPlayer ??= _createCrossfadeBackend();
    final cancellation = Completer<void>();
    _crossfadePreparationCancellation = cancellation;
    _standbyPosition = Duration.zero;
    _standbyDuration = _crossfadeSourceDuration(source);
    _attachStandbyPlayer(standby, generation);
    try {
      await _runCrossfadePreparationWithDeadline(() async {
        await standby.setVolume(0);
        if (!_isCrossfadeCurrent(generation) ||
            !identical(standby, _standbyPlayer)) {
          return;
        }
        await standby.open(_crossfadeMedia(source), play: false);
      }, cancellation: cancellation);
      if (!_isCrossfadeCurrent(generation) ||
          !identical(standby, _standbyPlayer)) {
        return;
      }
      _preparedCrossfadeSource = source;
      _maybeStartCrossfade();
    } catch (error, stackTrace) {
      if (_isCrossfadeCurrent(generation)) {
        developer.log(
          'media_kit crossfade preload failed',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
        _crossfadeGeneration++;
        await _resetCrossfadeState(restoreActiveVolume: true);
      }
    } finally {
      if (identical(_crossfadePreparationCancellation, cancellation)) {
        _crossfadePreparationCancellation = null;
      }
    }
  }

  Future<void> _runCrossfadePreparationWithDeadline(
    Future<void> Function() operation, {
    required Completer<void> cancellation,
  }) {
    final result = Completer<void>();
    Future<void>.sync(operation).then(
      (_) {
        if (!result.isCompleted) result.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!result.isCompleted) result.completeError(error, stackTrace);
      },
    );
    cancellation.future.then((_) {
      if (!result.isCompleted) result.complete();
    });

    void completeTimeout() {
      if (result.isCompleted || cancellation.isCompleted) {
        return;
      }
      result.completeError(
        TimeoutException(
          'media_kit crossfade preload exceeded $_operationTimeout',
          _operationTimeout,
        ),
      );
    }

    Timer? timer;
    final injectedDeadline = _operationDeadline;
    if (injectedDeadline == null) {
      timer = Timer(_operationTimeout, completeTimeout);
    } else {
      injectedDeadline(_operationTimeout).then(
        (_) => completeTimeout(),
        onError: (Object error, StackTrace stackTrace) {
          if (!result.isCompleted) result.completeError(error, stackTrace);
        },
      );
    }
    return result.future.whenComplete(() => timer?.cancel());
  }

  MediaKitPlayerBackend _createCrossfadeBackend() {
    if (_usesDefaultBackendFactory) {
      _ensureInitialized();
    }
    return _backendFactory();
  }

  void _attachStandbyPlayer(MediaKitPlayerBackend player, int generation) {
    for (final subscription in _standbySubscriptions) {
      unawaited(subscription.cancel());
    }
    _standbySubscriptions
      ..clear()
      ..addAll([
        player.positionStream.listen((position) {
          if (_isCrossfadeCurrent(generation) &&
              identical(player, _standbyPlayer)) {
            _standbyPosition = position;
          }
        }),
        player.durationStream.listen((duration) {
          if (_isCrossfadeCurrent(generation) &&
              identical(player, _standbyPlayer) &&
              duration > Duration.zero) {
            _standbyDuration = duration;
          }
        }),
        player.errorStream.listen((message) {
          if (!_isCrossfadeCurrent(generation) ||
              !identical(player, _standbyPlayer)) {
            return;
          }
          developer.log(
            'media_kit standby error: ${_sanitizePlaybackError(message)}',
            name: 'BStreamPlayback',
          );
          unawaited(_abortCrossfadeGeneration(generation));
        }),
      ]);
  }

  Future<void> _abortCrossfadeGeneration(int generation) async {
    if (!_isCrossfadeCurrent(generation)) {
      return;
    }
    _crossfadeGeneration++;
    await _resetCrossfadeState(restoreActiveVolume: true);
  }

  Media _crossfadeMedia(CrossfadePlaybackSource source) {
    return switch (source) {
      LocalCrossfadePlaybackSource(:final track) => Media(track.filePath),
      RemoteCrossfadePlaybackSource(:final source) => Media(
        source.uri.scheme == 'file'
            ? source.uri.toFilePath()
            : _mediaKitSourceUri(source.uri.toString(), source.track),
        httpHeaders: _mediaKitHttpHeaders(source.httpHeaders),
      ),
    };
  }

  Duration? _crossfadeSourceDuration(CrossfadePlaybackSource source) =>
      switch (source) {
        LocalCrossfadePlaybackSource(:final track) => track.duration,
        RemoteCrossfadePlaybackSource(:final source) => source.track.duration,
      };

  PlayerSnapshot _crossfadeSnapshot(CrossfadePlaybackSource source) {
    final playbackOptions = (
      shuffle: _snapshot.shuffleEnabled,
      repeat: _snapshot.repeatMode,
    );
    return switch (source) {
      LocalCrossfadePlaybackSource(:final track) => PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id,
        sourceUrl: track.sourceUrl,
        thumbnailUrl: track.thumbnailPath ?? track.thumbnailUrl,
        position: _standbyPosition,
        duration: _standbyDuration ?? track.duration,
        volume: _masterVolume,
        isRemote: false,
        isExternal: track.isExternal,
        shuffleEnabled: playbackOptions.shuffle,
        repeatMode: playbackOptions.repeat,
      ),
      RemoteCrossfadePlaybackSource(:final source) => PlayerSnapshot(
        status: PlayerStatus.playing,
        title: source.track.title,
        artist: source.track.artist,
        album: source.track.album,
        trackId: source.track.id.isEmpty ? source.track.url : source.track.id,
        queueEntryId: source.queueEntryId,
        sourceUrl: source.track.url,
        thumbnailUrl: source.track.thumbnailUrl,
        position: _standbyPosition,
        duration: _standbyDuration ?? source.track.duration,
        volume: _masterVolume,
        isRemote: true,
        shuffleEnabled: playbackOptions.shuffle,
        repeatMode: playbackOptions.repeat,
      ),
    };
  }

  void _maybeStartCrossfade() {
    final effectiveDuration = crossfadeStartDuration(
      enabled: _crossfadeEnabled,
      disposed: _disposed,
      overlapActive: _crossfadeRamp != null,
      promotionInProgress: _crossfadePromotionInProgress,
      sourcePrepared: _preparedCrossfadeSource != null,
      standbyReady: _standbyPlayer != null,
      playing: _snapshot.status == PlayerStatus.playing,
      trackDuration: _snapshot.duration,
      position: _snapshot.position,
      configuredDuration: _crossfadeDuration,
    );
    if (effectiveDuration == null) return;
    final generation = _crossfadeGeneration;
    unawaited(_runCrossfade(generation, effectiveDuration));
  }

  Future<void> _runCrossfade(int generation, Duration duration) async {
    final incoming = _standbyPlayer;
    final source = _preparedCrossfadeSource;
    if (incoming == null ||
        source == null ||
        !_isCrossfadeCurrent(generation) ||
        _crossfadeRamp != null) {
      return;
    }
    final outgoing = _player;
    late final CrossfadeRamp ramp;
    ramp = CrossfadeRamp(
      duration: duration,
      applyGains: (gains) async {
        if (!_isCrossfadeCurrent(generation) ||
            !identical(_crossfadeRamp, ramp)) {
          return;
        }
        final master = _masterVolume;
        await _writeCrossfadeVolumes(
          outgoing: outgoing,
          incoming: incoming,
          outgoingVolume: gains.outgoing * master,
          incomingVolume: gains.incoming * master,
        );
      },
    );
    _crossfadeRamp = ramp;
    try {
      await incoming.play();
      if (!_isCrossfadeCurrent(generation) ||
          !identical(_crossfadeRamp, ramp)) {
        return;
      }
      final completion = ramp.start();
      if (_crossfadePaused || _snapshot.status != PlayerStatus.playing) {
        ramp.pause();
        await incoming.pause();
      }
      final completed = await completion;
      if (!completed ||
          !_isCrossfadeCurrent(generation) ||
          !identical(_crossfadeRamp, ramp)) {
        return;
      }
      await _promoteCrossfadePlayer(
        generation: generation,
        outgoing: outgoing,
        incoming: incoming,
        source: source,
      );
    } catch (error, stackTrace) {
      if (_isCrossfadeCurrent(generation)) {
        developer.log(
          'media_kit crossfade failed',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
        _crossfadeGeneration++;
        await _resetCrossfadeState(restoreActiveVolume: true);
      }
    }
  }

  Future<void> _promoteCrossfadePlayer({
    required int generation,
    required MediaKitPlayerBackend outgoing,
    required MediaKitPlayerBackend incoming,
    required CrossfadePlaybackSource source,
  }) async {
    if (_crossfadePromotionInProgress ||
        !_isCrossfadeCurrent(generation) ||
        !identical(outgoing, _player) ||
        !identical(incoming, _standbyPlayer)) {
      return;
    }
    _crossfadePromotionInProgress = true;
    final promotionCompletion = Completer<void>();
    _crossfadePromotionCompletion = promotionCompletion;
    try {
      final requestedGeneration = _requestedGeneration;
      var nextSnapshot = _crossfadeSnapshot(source);
      bool isCurrent() =>
          _isCrossfadeCurrent(generation) &&
          requestedGeneration == _requestedGeneration;
      void restoreSubscriptions(MediaKitPlayerBackend active) {
        if (!_disposed &&
            identical(active, _player) &&
            _subscriptions.isEmpty) {
          _attachActivePlayer(active);
        }
      }

      // Keep both decks and their event filters intact until every fallible
      // native gain write has succeeded. A failure before commit can then use
      // the regular reset path and leaves the outgoing deck authoritative.
      await incoming.setVolume(_masterVolume * 100);
      if (!isCurrent()) {
        return;
      }
      await outgoing.setVolume(0);
      if (!isCurrent()) {
        return;
      }

      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      _subscriptions.clear();
      for (final subscription in _standbySubscriptions) {
        await subscription.cancel();
      }
      _standbySubscriptions.clear();
      if (!isCurrent()) {
        restoreSubscriptions(outgoing);
        return;
      }

      // Commit the logical role swap without awaiting more native work. Event
      // subscriptions are already detached, so retiring the outgoing deck via
      // media_kit's serialized stop path cannot alter the promoted snapshot.
      _player = incoming;
      _standbyPlayer = outgoing;
      _preparedCrossfadeSource = null;
      _crossfadePreparation = null;
      _crossfadeRamp = null;
      _backendGeneration = _requestedGeneration;
      _standbyPosition = Duration.zero;
      _standbyDuration = null;
      _attachActivePlayer(incoming);
      if (_crossfadePaused || _snapshot.status == PlayerStatus.paused) {
        nextSnapshot = nextSnapshot.copyWith(status: PlayerStatus.paused);
      }
      _emit(nextSnapshot);
      if (_disableCrossfadeAfterHandoff) {
        _disableCrossfadeAfterHandoff = false;
        _crossfadeEnabled = false;
      }
      unawaited(_stopHealthyStandby(outgoing));
    } finally {
      if (!promotionCompletion.isCompleted) {
        promotionCompletion.complete();
      }
      if (identical(_crossfadePromotionCompletion, promotionCompletion)) {
        _crossfadePromotionCompletion = null;
      }
      _crossfadePromotionInProgress = false;
    }
  }

  Future<void> _stopHealthyStandby(MediaKitPlayerBackend standby) async {
    try {
      await standby.stop();
    } catch (_) {
      // The promoted deck is already authoritative and remains unaffected.
    }
  }

  Future<void> _promoteCrossfadeAfterOutgoingFailure() async {
    final outgoing = _player;
    final incoming = _standbyPlayer;
    final source = _preparedCrossfadeSource;
    final ramp = _crossfadeRamp;
    if (incoming == null || source == null || ramp == null) {
      return;
    }
    ramp.cancel();
    await _promoteCrossfadePlayer(
      generation: _crossfadeGeneration,
      outgoing: outgoing,
      incoming: incoming,
      source: source,
    );
  }

  bool _isCrossfadeCurrent(int generation) =>
      !_disposed && _crossfadeEnabled && generation == _crossfadeGeneration;

  Future<void> _resetCrossfadeState({required bool restoreActiveVolume}) async {
    _crossfadeRamp?.cancel();
    _crossfadeRamp = null;
    if (_disableCrossfadeAfterHandoff) {
      // A failed incoming deck must still honor an off toggle made while the
      // overlap was audible. Do this before awaiting native cleanup so a later
      // re-enable cannot be overwritten by this stale reset.
      _disableCrossfadeAfterHandoff = false;
      _crossfadeEnabled = false;
    }
    _crossfadePaused = false;
    _preparedCrossfadeSource = null;
    _crossfadePreparation = null;
    final cancellation = _crossfadePreparationCancellation;
    _crossfadePreparationCancellation = null;
    final hadPendingPreparation =
        cancellation != null && !cancellation.isCompleted;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    await _clearStandbyPlayer(
      stop: true,
      abandonPendingOpen: hadPendingPreparation,
    );
    if (restoreActiveVolume && !_disposed) {
      try {
        // A cancelled ramp may still have one native volume write in flight.
        // Restore only after that write settles so it cannot win late.
        await _crossfadeVolumeWriteTail;
        await _player.setVolume(_masterVolume * 100);
      } catch (_) {
        // A normal explicit load will restore the target volume again.
      }
    }
  }

  Future<void> _writeCrossfadeVolumes({
    required MediaKitPlayerBackend outgoing,
    required MediaKitPlayerBackend incoming,
    required double outgoingVolume,
    required double incomingVolume,
  }) {
    final write = _crossfadeVolumeWriteTail.then((_) async {
      if (_disposed) {
        return;
      }
      await Future.wait<void>([
        outgoing.setVolume(outgoingVolume.clamp(0, 1).toDouble() * 100),
        incoming.setVolume(incomingVolume.clamp(0, 1).toDouble() * 100),
      ]);
    });
    _crossfadeVolumeWriteTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<void> _invalidateCrossfadeForExplicitAction() async {
    _crossfadeGeneration++;
    final promotion = _crossfadePromotionCompletion;
    if (promotion != null) {
      await promotion.future;
    }
    await _resetCrossfadeState(restoreActiveVolume: true);
  }

  Future<bool> _awaitCrossfadeShutdownBarrier() async {
    final promotion = _crossfadePromotionCompletion;
    final timeout = _operationTimeout < _crossfadeShutdownGrace
        ? _operationTimeout
        : _crossfadeShutdownGrace;
    try {
      await Future.wait<void>([
        if (promotion != null) promotion.future,
        _crossfadeVolumeWriteTail,
      ]).timeout(timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearStandbyPlayer({
    required bool stop,
    bool abandonPendingOpen = false,
  }) async {
    for (final subscription in _standbySubscriptions) {
      await subscription.cancel();
    }
    _standbySubscriptions.clear();
    final standby = _standbyPlayer;
    if (standby != null) {
      if (abandonPendingOpen) {
        // Only detach a backend when its load can still own media_kit's
        // command lane. A healthy prepared deck is stopped normally.
        standby.abandonPendingOperations();
      } else if (stop) {
        try {
          await standby.stop();
        } catch (_) {
          // Preparation is best effort and must not interrupt the active deck.
        }
      }
      if (!abandonPendingOpen) {
        try {
          await standby.setVolume(0);
        } catch (_) {
          // The next preparation will replace an unusable backend if necessary.
        }
      }
    }
    _standbyPosition = Duration.zero;
    _standbyDuration = null;
  }

  void _attachActivePlayer(MediaKitPlayerBackend player) {
    _subscriptions.addAll([
      player.positionStream.listen((position) {
        if (!identical(player, _player) || !_acceptBackendEvent) {
          return;
        }
        _emit(_snapshot.copyWith(position: position));
        _maybeStartCrossfade();
      }),
      player.durationStream.listen((duration) {
        if (!identical(player, _player) || !_acceptBackendEvent) {
          return;
        }
        _emit(_snapshot.copyWith(duration: duration));
        _maybeStartCrossfade();
      }),
      player.volumeStream.listen((volume) {
        if (!identical(player, _player) ||
            !_acceptBackendEvent ||
            _crossfadeRamp != null) {
          return;
        }
        final physical = (volume / 100).clamp(0, 1).toDouble();
        if ((physical - _masterVolume).abs() <= 0.001) {
          _emit(_snapshot.copyWith(volume: _masterVolume));
        }
      }),
      player.bufferingStream.listen((buffering) {
        if (!identical(player, _player) || !_acceptBackendEvent) {
          return;
        }
        if (_snapshot.status == PlayerStatus.failed) {
          return;
        }
        if (buffering && _snapshot.status != PlayerStatus.playing) {
          _emit(_snapshot.copyWith(status: PlayerStatus.loading));
        }
      }),
      player.playingStream.listen((playing) {
        if (!identical(player, _player) || !_acceptBackendEvent) {
          return;
        }
        if (_snapshot.status == PlayerStatus.failed) {
          return;
        }
        if (!playing &&
            (_snapshot.status == PlayerStatus.stopped ||
                _crossfadeRamp != null)) {
          return;
        }
        _emit(
          _snapshot.copyWith(
            status: playing ? PlayerStatus.playing : PlayerStatus.paused,
          ),
        );
      }),
      player.completedStream.listen((completed) {
        if (!identical(player, _player) ||
            !_acceptBackendEvent ||
            _crossfadeRamp != null) {
          return;
        }
        if (_snapshot.status == PlayerStatus.failed) {
          return;
        }
        if (completed) {
          _emit(_snapshot.copyWith(status: PlayerStatus.completed));
        }
      }),
      player.errorStream.listen((message) {
        if (!identical(player, _player) ||
            (!_acceptBackendEvent && !_acceptOpeningBackendEvent)) {
          return;
        }
        if (_crossfadeRamp != null) {
          unawaited(_promoteCrossfadeAfterOutgoingFailure());
          return;
        }
        final detail = _sanitizePlaybackError(message);
        developer.log(
          'media_kit backend error: $detail',
          name: 'BStreamPlayback',
          error: detail,
        );
        _emit(
          _snapshot.copyWith(status: PlayerStatus.failed, errorMessage: detail),
        );
      }),
    ]);
  }

  @override
  Future<void> playRemote(TrackInfo track) async {
    final source = track.streamUrl;
    if (source == null || source.isEmpty) {
      throw const PlayerException(
        'No hay una URL reproducible. Obtén la información del track primero.',
        code: 'missing_stream_url',
      );
    }

    final generation = ++_requestedGeneration;
    _cancelActiveOpen();
    await _invalidateCrossfadeForExplicitAction();
    if (!_isCurrentGeneration(generation)) {
      return;
    }
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
        volume: _masterVolume,
        isRemote: true,
      ),
    );
    developer.log(
      'playRemote start, host=${_diagnosticHost(source)}, '
      'format=${track.streamExtension ?? track.streamMimeType ?? 'unknown'}, '
      'headerKeys=${_diagnosticHeaderKeys(track.httpHeaders)}',
      name: 'BStreamPlayback',
    );
    await _openForGeneration(_remoteMedia(track), generation, play: true);
  }

  Media _remoteMedia(TrackInfo track) {
    final source = track.streamUrl!;
    return Media(
      _mediaKitSourceUri(source, track),
      httpHeaders: _mediaKitHttpHeaders(track.httpHeaders),
    );
  }

  String _mediaKitSourceUri(String source, TrackInfo track) {
    final uri = Uri.tryParse(source);
    if (uri == null || uri.scheme == 'file' || uri.scheme == 'content') {
      return source;
    }
    if (uri.fragment.isNotEmpty || _hasKnownAudioExtension(uri.path)) {
      return source;
    }

    final extension = _remoteExtension(track);
    return extension == null
        ? source
        : uri.replace(fragment: '.$extension').toString();
  }

  Map<String, String>? _mediaKitHttpHeaders(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) {
      return null;
    }
    const forbidden = {
      'connection',
      'content-length',
      'host',
      'keep-alive',
      'proxy-authenticate',
      'proxy-authorization',
      'range',
      'te',
      'trailer',
      'transfer-encoding',
      'upgrade',
    };
    final filtered = <String, String>{};
    for (final entry in headers.entries) {
      if (!forbidden.contains(entry.key.trim().toLowerCase())) {
        filtered[entry.key] = entry.value;
      }
    }
    return filtered.isEmpty ? null : Map.unmodifiable(filtered);
  }

  String? _remoteExtension(TrackInfo track) {
    final direct = track.streamExtension?.trim().toLowerCase();
    if (direct != null && direct.isNotEmpty) {
      return direct.replaceFirst('.', '');
    }

    final mime = track.streamMimeType?.split(';').first.trim().toLowerCase();
    return switch (mime) {
      'audio/mp4' || 'video/mp4' || 'application/mp4' => 'm4a',
      'audio/aac' => 'aac',
      'audio/mpeg' => 'mp3',
      'audio/webm' || 'video/webm' => 'webm',
      'audio/ogg' => 'ogg',
      'audio/opus' => 'opus',
      'audio/flac' || 'audio/x-flac' => 'flac',
      'audio/3gpp' || 'video/3gpp' => '3gp',
      'application/vnd.apple.mpegurl' ||
      'application/x-mpegurl' ||
      'audio/mpegurl' => 'm3u8',
      'audio/wav' || 'audio/x-wav' => 'wav',
      _ => null,
    };
  }

  bool _hasKnownAudioExtension(String path) {
    return RegExp(
      r'\.(?:m4a|mp4|aac|mp3|webm|weba|ogg|oga|opus|wav|flac|mka|3gp|m3u8)$',
      caseSensitive: false,
    ).hasMatch(path);
  }

  String _diagnosticHost(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null) {
      return 'invalid';
    }
    if (uri.host.isEmpty) {
      return uri.scheme;
    }
    return uri.host;
  }

  String _diagnosticHeaderKeys(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) {
      return 'none';
    }
    final keys = headers.keys.map((key) => key.toLowerCase()).toList()..sort();
    return keys.join(',');
  }

  String _sanitizePlaybackError(String value) {
    return value.replaceAllMapped(
      RegExp(r'(https?://[^\s?#]+)(?:\?[^\s#]*)?(?:#[^\s]*)?'),
      (match) => match.group(1)!,
    );
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    final generation = ++_requestedGeneration;
    _cancelActiveOpen();
    await _invalidateCrossfadeForExplicitAction();
    if (!_isCurrentGeneration(generation)) {
      return;
    }
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
        volume: _masterVolume,
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
    await _invalidateCrossfadeForExplicitAction();
    if (!_isCurrentGeneration(generation)) {
      return;
    }
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
        volume: _masterVolume,
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
    _crossfadePaused = true;
    _crossfadeRamp?.pause();
    await _enqueueOperation(() async {
      if (!_isCurrentGeneration(generation)) {
        return;
      }
      final standby = _standbyPlayer;
      await Future.wait<void>([
        _player.pause(),
        if (_crossfadeRamp != null && standby != null) standby.pause(),
      ]);
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
      final standby = _standbyPlayer;
      await Future.wait<void>([
        _player.play(),
        if (_crossfadeRamp != null && standby != null) standby.play(),
      ]);
      if (_isCurrentGeneration(generation)) {
        _crossfadePaused = false;
        _crossfadeRamp?.resume();
        _emit(_snapshot.copyWith(status: PlayerStatus.playing));
      }
    }, label: 'play');
  }

  @override
  Future<void> togglePlayPause() {
    return _snapshot.status == PlayerStatus.playing ? pause() : resume();
  }

  @override
  Future<void> stop() async {
    final generation = ++_requestedGeneration;
    _backendGeneration = null;
    _cancelActiveOperation();
    await _invalidateCrossfadeForExplicitAction();
    await _enqueueOperation(() async {
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
    final requestedGeneration = _requestedGeneration;
    final revision = ++_seekRevision;
    final target = position < Duration.zero ? Duration.zero : position;
    final operation = _seekTail.then(
      (_) => _performSeek(
        target,
        requestedGeneration: requestedGeneration,
        revision: revision,
      ),
    );
    _seekTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _performSeek(
    Duration target, {
    required int requestedGeneration,
    required int revision,
  }) async {
    if (!_isCurrentGeneration(requestedGeneration) ||
        revision != _seekRevision) {
      return;
    }
    await _invalidateCrossfadeForExplicitAction();
    if (!_isCurrentGeneration(requestedGeneration) ||
        revision != _seekRevision) {
      return;
    }
    final generation = requestedGeneration;
    await _enqueueOperation(() async {
      if (_isCurrentGeneration(generation) && revision == _seekRevision) {
        await _player.seek(target);
        if (_isCurrentGeneration(generation) && revision == _seekRevision) {
          // Make the logical timeline authoritative before PlayerController
          // prepares the next deck. This prevents a stale near-end position
          // from immediately starting another overlap after a backward seek.
          _emit(_snapshot.copyWith(position: target));
        }
      }
    }, label: 'seek');
  }

  @override
  Future<void> setVolume(double volume) async {
    final normalized = volume.clamp(0, 1).toDouble();
    _masterVolume = normalized;
    _emit(_snapshot.copyWith(volume: normalized));
    final ramp = _crossfadeRamp;
    final standby = _standbyPlayer;
    if (ramp != null && standby != null) {
      final gains = crossfadeGains(
        masterVolume: normalized,
        progress: ramp.progress,
      );
      await _writeCrossfadeVolumes(
        outgoing: _player,
        incoming: standby,
        outgoingVolume: gains.outgoing,
        incomingVolume: gains.incoming,
      );
      return;
    }
    await _enqueueOperation(
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
    _crossfadeGeneration++;
    _backendGeneration = null;
    _cancelActiveOperation();
    _crossfadeRamp?.cancel();
    _crossfadeRamp = null;
    _crossfadePreparation = null;
    _preparedCrossfadeSource = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    for (final subscription in _standbySubscriptions) {
      await subscription.cancel();
    }
    _standbySubscriptions.clear();
    final standby = _standbyPlayer;
    _standbyPlayer = null;
    final cancellation = _crossfadePreparationCancellation;
    _crossfadePreparationCancellation = null;
    final hadPendingPreparation =
        cancellation != null && !cancellation.isCompleted;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    if (hadPendingPreparation) {
      // A blocked standby open owns media_kit's command lane. Detach it before
      // disposing the fresh wrapper so shutdown cannot wait behind the load.
      standby?.abandonPendingOperations();
    }
    final crossfadeStopped = await _awaitCrossfadeShutdownBarrier();
    if (!crossfadeStopped) {
      // A native gain/promotion command did not return within the shutdown
      // grace period. Detach both wrappers before disposing them so teardown
      // cannot race that command on the same mpv context.
      _player.abandonPendingOperations();
      if (standby != null) {
        standby.abandonPendingOperations();
      }
    }
    try {
      await Future.wait<void>([
        _runStandaloneWithDeadline(_player.dispose, label: 'dispose'),
        if (standby != null)
          standby.dispose().timeout(_operationTimeout, onTimeout: () {}),
      ]);
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
        await _player.setVolume(_masterVolume * 100);
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        // Until open returns, backend events may still belong to the source that
        // is being interrupted. Publish only the explicit loading snapshot.
        _backendGeneration = null;
        try {
          await _player.open(media, play: play);
        } catch (error, stackTrace) {
          final detail = _sanitizePlaybackError(error.toString());
          developer.log(
            'media_kit open failed for ${_diagnosticHost(media.uri)}',
            name: 'BStreamPlayback',
            error: detail,
            stackTrace: stackTrace,
          );
          if (_isCurrentGeneration(generation)) {
            rethrow;
          }
          return;
        }
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        if (_snapshot.status == PlayerStatus.failed) {
          throw PlayerException(
            _snapshot.errorMessage ?? 'MediaKit no pudo abrir el audio.',
            code: 'media_kit_open_failed',
          );
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
        final existingError = _snapshot.errorMessage;
        _emit(
          _snapshot.copyWith(
            status: PlayerStatus.failed,
            errorMessage:
                existingError ??
                'El reproductor tardó demasiado en abrir el audio.',
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

  bool get _acceptOpeningBackendEvent =>
      !_disposed &&
      _backendGeneration == null &&
      _activeOperation?.isOpen == true;

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
