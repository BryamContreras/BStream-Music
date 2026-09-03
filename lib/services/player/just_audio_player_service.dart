import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/errors/app_exception.dart' as app_errors;
import '../../core/utils/image_source.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import 'crossfade_transition.dart';
import 'notification_artwork_service.dart';
import 'player_service.dart';

typedef JustAudioOperationDeadline = Future<void> Function(Duration duration);
typedef JustAudioPlayerFactory = AudioPlayer Function();

class JustAudioPlayerService
    implements PlayerService, NativeRemoteQueuePlayer, CrossfadeCapablePlayer {
  static const _crossfadeShutdownGrace = Duration(seconds: 2);
  static const _crossfadeHandoffReadyPollInterval = Duration(milliseconds: 100);
  static const _crossfadeHandoffSettleDuration = Duration(milliseconds: 120);
  static const _crossfadeHandoffRealignThreshold = Duration(milliseconds: 8);
  static const _crossfadeHandoffMaxRealignments = 3;
  static const _crossfadeRetirementGrace = Duration(milliseconds: 250);

  JustAudioPlayerService({
    NotificationArtworkService? notificationArtworkService,
    AudioPlayer? audioPlayer,
    AudioPlayer? crossfadeAudioPlayer,
    JustAudioPlayerFactory? crossfadePlayerFactory,
    Duration operationTimeout = const Duration(seconds: 45),
    JustAudioOperationDeadline? operationDeadline,
  }) : _notificationArtworkService =
           notificationArtworkService ?? NotificationArtworkService.instance,
       _player = audioPlayer ?? _createAudioPlayer(),
       _injectedCrossfadePlayer = crossfadeAudioPlayer,
       _crossfadePlayerFactory =
           crossfadePlayerFactory ?? _createCrossfadeAudioPlayer,
       _operationTimeout = operationTimeout,
       // Public injection name is intentional; the stored hook stays private.
       // ignore: prefer_initializing_formals
       _operationDeadline = operationDeadline,
       assert(operationTimeout > Duration.zero) {
    // main() starts this before the mobile UI is shown. Keep this best-effort
    // warmup for tests and alternate entry points that construct the service
    // directly; image generation itself is deferred to the system request.
    unawaited(_initializeNotificationArtworkSafely());
    // The stock stream can publish five timeline snapshots per second for the
    // whole lifetime of the foreground service. Four updates per second keeps
    // short tracks smooth, while the 500 ms ceiling bounds background work for
    // very long mixes.
    _positionSubscription = _player
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 250),
          maxPeriod: const Duration(milliseconds: 500),
        )
        .listen((position) {
          if (_crossfadeRamp != null && !_primaryStillRepresentsSnapshot) {
            // The native playlist may advance a few milliseconds before the
            // logical handoff. Keep showing the outgoing timeline until then,
            // but do not freeze it for the whole overlap.
            return;
          }
          _emit(_snapshot.copyWith(position: position));
          _maybeStartCrossfade();
        });
    _durationSubscription = _player.durationStream.listen((duration) {
      if (_crossfadeRamp != null && !_primaryStillRepresentsSnapshot) {
        return;
      }
      final watch = _remoteStartupWatch;
      if (watch != null && duration != null && !_loggedRemoteDuration) {
        _loggedRemoteDuration = true;
        developer.log(
          'duration available after ${watch.elapsedMilliseconds}ms: $duration',
          name: 'BStreamPlayback',
        );
      }
      // A source whose catalog row did not include a duration (notably
      // YouTube Music's Quick picks shelf) is still seekable once ExoPlayer
      // inspects the media. Keep that authoritative value if just_audio later
      // emits a transient null while refreshing the current sequence.
      if (_usableDuration(duration) == null &&
          _usableDuration(_snapshot.duration) != null) {
        return;
      }
      _emit(_snapshot.copyWith(duration: _usableDuration(duration)));
      _maybeStartCrossfade();
    });
    _volumeSubscription = _player.volumeStream.listen((volume) {
      if (_crossfadeRamp != null) {
        // During an overlap the primary player's physical gain is only one
        // side of the ramp. It must never replace the user's logical master.
        return;
      }
      final physical = volume.clamp(0, 1).toDouble();
      // Every supported volume change enters through setVolume. A delayed
      // native event from a cancelled ramp is physical deck state, not a new
      // user-selected master, and must not lower the next track.
      if ((physical - _masterVolume).abs() <= 0.001) {
        _emit(_snapshot.copyWith(volume: _masterVolume));
      }
    });
    _stateSubscription = _player.playerStateStream.listen((state) {
      // just_audio changes its native state to idle after a load error. Keep
      // the explicit failure until a new source is selected so the controller
      // and UI can process the error instead of seeing a misleading pause.
      if (_snapshot.status == PlayerStatus.failed) {
        return;
      }
      final watch = _remoteStartupWatch;
      if (watch != null) {
        developer.log(
          'state ${state.processingState.name}, playing=${state.playing}, elapsed=${watch.elapsedMilliseconds}ms',
          name: 'BStreamPlayback',
        );
        if (state.processingState == ProcessingState.ready && state.playing) {
          _remoteStartupWatch = null;
        }
      }
      final status = switch (state.processingState) {
        ProcessingState.loading || ProcessingState.buffering =>
          state.playing ? PlayerStatus.playing : PlayerStatus.loading,
        ProcessingState.completed => PlayerStatus.completed,
        _ => state.playing ? PlayerStatus.playing : PlayerStatus.paused,
      };
      if (_crossfadeRamp != null &&
          state.processingState == ProcessingState.completed) {
        return;
      }
      _emit(_snapshot.copyWith(status: status));
      _maybeStartCrossfade();
    });
    _playbackErrorSubscription = _player.errorStream.listen((error) {
      if (_crossfadeRamp != null) {
        unawaited(_promoteCrossfadeAfterOutgoingFailure());
        return;
      }
      final sequenceTags = _player.sequence
          .map((source) => source.tag)
          .toList(growable: false);
      if (!justAudioErrorBelongsToSnapshot(
        error,
        sequenceTags: sequenceTags,
        currentIndex: _player.currentIndex,
        snapshot: _snapshot,
      )) {
        developer.log(
          'ignored stale playback error for source index ${error.index}',
          name: 'BStreamPlayback',
          error: error,
        );
        return;
      }
      unawaited(
        _reportPlaybackFailure(
          error,
          _playbackGeneration,
          _remoteTrackForError(error, sequenceTags) ?? _activeRemoteTrack,
        ),
      );
    });
    _sequenceStateSubscription = _player.sequenceStateStream.listen(
      _handlePrimarySequenceState,
    );
  }

  void _handlePrimarySequenceState(SequenceState state, {bool force = false}) {
    final tag = state.currentSource?.tag;
    if (tag is! MediaItem) {
      return;
    }
    final queueEntryId = tag.extras?['queueEntryId']?.toString();
    final isRemote = tag.extras?['isRemote'] == true;
    final sameLogicalItem = _isSameLogicalMediaItem(
      snapshot: _snapshot,
      tag: tag,
      queueEntryId: queueEntryId,
    );
    if (!force && _crossfadeRamp != null && !sameLogicalItem) {
      // The primary playlist may reach its boundary a few milliseconds before
      // the volume ramp. Keep the old logical item visible until handoff.
      return;
    }
    if (isRemote && queueEntryId != null) {
      for (final source in _remoteQueueSources) {
        if (source.queueEntryId == queueEntryId) {
          _activeRemoteTrack = source.track;
          break;
        }
      }
      if (_snapshot.queueEntryId != queueEntryId) {
        _reportedFailureGeneration = null;
        _diagnosticGeneration = null;
        _diagnosticFuture = null;
      }
    }
    _emit(
      _snapshot.copyWith(
        title: tag.title,
        artist: tag.artist,
        album: tag.album,
        trackId: tag.id,
        queueEntryId: queueEntryId,
        sourceUrl: tag.extras?['sourceUrl']?.toString(),
        thumbnailUrl: displayArtworkSourceForMediaItem(tag),
        duration:
            _usableDuration(tag.duration) ??
            (sameLogicalItem ? _usableDuration(_snapshot.duration) : null),
        isRemote: isRemote,
        isExternal: tag.extras?['isExternal'] == true,
      ),
    );
  }

  bool get _primaryStillRepresentsSnapshot {
    final tag = _player.sequenceState.currentSource?.tag;
    if (tag is! MediaItem) {
      return true;
    }
    return _isSameLogicalMediaItem(
      snapshot: _snapshot,
      tag: tag,
      queueEntryId: tag.extras?['queueEntryId']?.toString(),
    );
  }

  static AudioPlayer _createAudioPlayer() => AudioPlayer(
    // Preserve the resolver's per-stream User-Agent. A player-wide value
    // overrides that header in just_audio and can invalidate signed YouTube
    // media URLs on Android.
    useProxyForRequestHeaders: false,
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 2),
        maxBufferDuration: Duration(seconds: 8),
        bufferForPlaybackDuration: Duration(milliseconds: 250),
        bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 750),
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: Duration(seconds: 1),
      ),
    ),
  );

  static AudioPlayer _createCrossfadeAudioPlayer() => AudioPlayer(
    // Only the primary player owns interruptions and activation. Both decks
    // still render through the same Android audio session during the overlap.
    handleInterruptions: false,
    handleAudioSessionActivation: false,
    useProxyForRequestHeaders: false,
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 2),
        maxBufferDuration: Duration(seconds: 8),
        bufferForPlaybackDuration: Duration(milliseconds: 250),
        bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 750),
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: Duration(seconds: 1),
      ),
    ),
  );

  final AudioPlayer _player;
  final AudioPlayer? _injectedCrossfadePlayer;
  final JustAudioPlayerFactory _crossfadePlayerFactory;
  AudioPlayer? _crossfadePlayer;
  bool _injectedCrossfadePlayerUsed = false;
  final NotificationArtworkService _notificationArtworkService;
  final Duration _operationTimeout;
  final JustAudioOperationDeadline? _operationDeadline;
  final _snapshotController = StreamController<PlayerSnapshot>.broadcast();

  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<Duration?> _durationSubscription;
  late final StreamSubscription<double> _volumeSubscription;
  late final StreamSubscription<PlayerState> _stateSubscription;
  late final StreamSubscription<PlayerException> _playbackErrorSubscription;
  late final StreamSubscription<SequenceState?> _sequenceStateSubscription;

  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  double _masterVolume = 1;
  int _playbackGeneration = 0;
  int? _reportedFailureGeneration;
  int? _diagnosticGeneration;
  Future<String>? _diagnosticFuture;
  TrackInfo? _activeRemoteTrack;
  bool _shuffleEnabled = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;
  List<String> _localQueueIds = const [];
  List<LocalTrack> _localQueueTracks = const [];
  List<RemotePlaybackSource> _remoteQueueSources = const [];
  bool _remoteHasSingleLogicalItem = false;
  Future<void> _remoteQueueMutationTail = Future<void>.value();
  _JustAudioOperationLease? _activeQueueOperation;
  int _remoteQueueRevision = 0;
  Stopwatch? _remoteStartupWatch;
  bool _loggedRemoteDuration = false;
  bool _crossfadeEnabled = false;
  Duration _crossfadeDuration = const Duration(seconds: 5);
  int _crossfadeGeneration = 0;
  CrossfadePlaybackSource? _preparedCrossfadeSource;
  Future<void>? _crossfadePreparation;
  CrossfadeRamp? _crossfadeRamp;
  bool _crossfadePromotionInProgress = false;
  Completer<void>? _crossfadePromotionCompletion;
  bool _disableCrossfadeAfterHandoff = false;
  bool _crossfadePaused = false;
  double _crossfadePrimaryGain = 1;
  double _crossfadeIncomingGain = 0;
  Future<void> _crossfadeVolumeWriteTail = Future<void>.value();
  final Set<Future<void>> _crossfadeRetirements = <Future<void>>{};
  Future<void> _seekTail = Future<void>.value();
  int _seekRevision = 0;
  StreamSubscription<PlayerException>? _crossfadeErrorSubscription;
  bool _disposed = false;

  Future<void> _initializeNotificationArtworkSafely() async {
    try {
      await _notificationArtworkService.initialize();
    } catch (error, stackTrace) {
      developer.log(
        'Optional notification artwork initialization failed',
        name: 'BStreamPlayback',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  bool get supportsLocalQueueReplacement => true;

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
        await _resetCrossfadeState(restorePrimaryVolume: true);
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
      await _resetCrossfadeState(restorePrimaryVolume: true);
      return;
    }
    if (_crossfadeRamp != null) {
      return;
    }

    final effectiveSource = _effectiveCrossfadeSource(source);
    final existing = _preparedCrossfadeSource;
    final preparation = _crossfadePreparation;
    if (existing?.logicalKey == effectiveSource.logicalKey) {
      if (preparation != null) {
        await preparation;
      }
      return;
    }

    final generation = ++_crossfadeGeneration;
    await _resetCrossfadeState(restorePrimaryVolume: true);
    if (!_isCrossfadeCurrent(generation)) {
      return;
    }
    final future = _prepareCrossfadeSource(effectiveSource, generation);
    _crossfadePreparation = future;
    try {
      await future;
    } finally {
      if (identical(_crossfadePreparation, future)) {
        _crossfadePreparation = null;
      }
    }
  }

  CrossfadePlaybackSource _effectiveCrossfadeSource(
    CrossfadePlaybackSource requested,
  ) {
    if (requested case LocalCrossfadePlaybackSource()) {
      final nextIndex = _player.nextIndex;
      if (nextIndex != null &&
          nextIndex >= 0 &&
          nextIndex < _localQueueTracks.length) {
        // just_audio owns the effective shuffled order for a native local
        // playlist. Use that exact successor instead of a second random plan.
        return LocalCrossfadePlaybackSource(_localQueueTracks[nextIndex]);
      }
    }
    return requested;
  }

  Future<void> _prepareCrossfadeSource(
    CrossfadePlaybackSource source,
    int generation,
  ) async {
    final incoming = _newCrossfadePlayer();
    _crossfadePlayer = incoming;
    _crossfadeErrorSubscription = incoming.errorStream.listen((error) {
      if (_isCrossfadeCurrent(generation) &&
          identical(incoming, _crossfadePlayer)) {
        developer.log(
          'just_audio standby error',
          name: 'BStreamPlayback',
          error: error,
        );
        unawaited(_abortCrossfadeGeneration(generation));
      }
    });
    try {
      await incoming.setVolume(0);
      if (!_isCrossfadeCurrent(generation) ||
          !identical(incoming, _crossfadePlayer)) {
        return;
      }
      await incoming
          .setAudioSource(_crossfadeAudioSource(source), preload: true)
          .timeout(_operationTimeout);
      if (!_isCrossfadeCurrent(generation) ||
          !identical(incoming, _crossfadePlayer)) {
        return;
      }
      _preparedCrossfadeSource = source;
      _maybeStartCrossfade();
    } catch (error, stackTrace) {
      if (_isCrossfadeCurrent(generation)) {
        developer.log(
          'just_audio crossfade preload failed',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
        _crossfadeGeneration++;
        await _resetCrossfadeState(restorePrimaryVolume: true);
      }
    }
  }

  AudioPlayer _newCrossfadePlayer() {
    final injected = _injectedCrossfadePlayer;
    if (injected != null && !_injectedCrossfadePlayerUsed) {
      _injectedCrossfadePlayerUsed = true;
      return injected;
    }
    return _crossfadePlayerFactory();
  }

  AudioSource _crossfadeAudioSource(CrossfadePlaybackSource source) =>
      switch (source) {
        LocalCrossfadePlaybackSource(:final track) => _localAudioSource(track),
        RemoteCrossfadePlaybackSource(:final source) => _remoteAudioSource(
          source,
        ),
      };

  bool _isCrossfadeCurrent(int generation) =>
      !_disposed && _crossfadeEnabled && generation == _crossfadeGeneration;

  Future<void> _abortCrossfadeGeneration(int generation) async {
    if (!_isCrossfadeCurrent(generation)) {
      return;
    }
    _crossfadeGeneration++;
    await _resetCrossfadeState(restorePrimaryVolume: true);
  }

  Future<void> _resetCrossfadeState({
    required bool restorePrimaryVolume,
  }) async {
    _crossfadeRamp?.cancel();
    _crossfadeRamp = null;
    _crossfadePrimaryGain = 1;
    _crossfadeIncomingGain = 0;
    if (_disableCrossfadeAfterHandoff) {
      // The user may disable crossfade after both decks became audible and
      // the incoming deck may then fail before promotion. Consume the pending
      // setting synchronously so a late reset cannot leave the service enabled
      // while Settings already says it is off.
      _disableCrossfadeAfterHandoff = false;
      _crossfadeEnabled = false;
    }
    _crossfadePaused = false;
    _preparedCrossfadeSource = null;
    _crossfadePreparation = null;
    final incoming = _crossfadePlayer;
    _crossfadePlayer = null;
    await _crossfadeErrorSubscription?.cancel();
    _crossfadeErrorSubscription = null;
    if (incoming != null) {
      try {
        await incoming.stop().timeout(const Duration(seconds: 2));
      } catch (_) {
        // A stale standby must never block the logical player.
      }
      try {
        await incoming.dispose().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Native teardown is best effort after an interrupted preload.
      }
    }
    if (restorePrimaryVolume && !_disposed) {
      try {
        // A ramp tick may already be queued when cancellation wins. Restore
        // through the same lane so this write is guaranteed to be last.
        await _writePrimaryCrossfadeVolume(_masterVolume);
      } catch (_) {
        // The next explicit load restores the logical master volume.
      }
    }
  }

  Future<void> _invalidateCrossfadeForExplicitAction() async {
    _crossfadeGeneration++;
    final promotion = _crossfadePromotionCompletion;
    if (promotion != null) {
      await promotion.future;
    }
    await _resetCrossfadeState(restorePrimaryVolume: true);
  }

  Future<void> _awaitCrossfadeShutdownBarrier() async {
    final promotion = _crossfadePromotionCompletion;
    final timeout = _operationTimeout < _crossfadeShutdownGrace
        ? _operationTimeout
        : _crossfadeShutdownGrace;
    try {
      await Future.wait<void>([
        if (promotion != null) promotion.future,
        _crossfadeVolumeWriteTail,
      ]).timeout(timeout);
    } catch (_) {
      // AudioPlayer.dispose is the bounded fallback for an unresponsive native
      // command. Reaching it only after this grace period keeps the normal path
      // serialized without letting a wedged load block application shutdown.
    }
  }

  void _maybeStartCrossfade() {
    final effectiveDuration = crossfadeStartDuration(
      enabled: _crossfadeEnabled,
      disposed: _disposed,
      overlapActive: _crossfadeRamp != null,
      promotionInProgress: _crossfadePromotionInProgress,
      sourcePrepared: _preparedCrossfadeSource != null,
      standbyReady: _crossfadePlayer != null,
      playing: _snapshot.status == PlayerStatus.playing,
      trackDuration: _usableDuration(_snapshot.duration),
      position: _snapshot.position,
      configuredDuration: _crossfadeDuration,
    );
    if (effectiveDuration == null) return;
    unawaited(_runCrossfade(_crossfadeGeneration, effectiveDuration));
  }

  Future<void> _runCrossfade(int generation, Duration duration) async {
    final incoming = _crossfadePlayer;
    final source = _preparedCrossfadeSource;
    if (incoming == null ||
        source == null ||
        !_isCrossfadeCurrent(generation) ||
        _crossfadeRamp != null) {
      return;
    }
    late final CrossfadeRamp ramp;
    ramp = CrossfadeRamp(
      duration: duration,
      applyGains: (gains) async {
        if (!_isCrossfadeCurrent(generation) ||
            !identical(_crossfadeRamp, ramp) ||
            !identical(_crossfadePlayer, incoming)) {
          return;
        }
        _crossfadePrimaryGain = gains.outgoing;
        _crossfadeIncomingGain = gains.incoming;
        final master = _masterVolume;
        await _writeCrossfadeVolumes(
          incoming: incoming,
          outgoingVolume: gains.outgoing * master,
          incomingVolume: gains.incoming * master,
        );
      },
    );
    _crossfadeRamp = ramp;
    try {
      unawaited(_playCrossfadeIncoming(incoming, generation));
      final completion = ramp.start();
      if (_crossfadePaused || _snapshot.status != PlayerStatus.playing) {
        ramp.pause();
        await incoming.pause();
      }
      final completed = await completion;
      if (!completed ||
          !_isCrossfadeCurrent(generation) ||
          !identical(_crossfadeRamp, ramp) ||
          !identical(_crossfadePlayer, incoming)) {
        return;
      }
      await _promoteCrossfadePlayer(
        generation: generation,
        incoming: incoming,
        source: source,
      );
    } catch (error, stackTrace) {
      if (_isCrossfadeCurrent(generation)) {
        developer.log(
          'just_audio crossfade failed',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
        _crossfadeGeneration++;
        await _resetCrossfadeState(restorePrimaryVolume: true);
        if (!_disposed) {
          // Promotion may already have moved the primary playlist before a
          // later native option/volume write failed. Reflect its authoritative
          // item so metadata can never remain on the outgoing song.
          _handlePrimarySequenceState(_player.sequenceState, force: true);
          _emit(
            _snapshot.copyWith(
              position: _player.position,
              status: _player.playing
                  ? PlayerStatus.playing
                  : PlayerStatus.paused,
            ),
          );
        }
      }
    }
  }

  Future<void> _playCrossfadeIncoming(
    AudioPlayer incoming,
    int generation,
  ) async {
    try {
      await incoming.play();
    } catch (error, stackTrace) {
      if (_isCrossfadeCurrent(generation) &&
          identical(incoming, _crossfadePlayer)) {
        developer.log(
          'just_audio standby play failed',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
        await _abortCrossfadeGeneration(generation);
      }
    }
  }

  Future<void> _promoteCrossfadeAfterOutgoingFailure() async {
    final incoming = _crossfadePlayer;
    final source = _preparedCrossfadeSource;
    final ramp = _crossfadeRamp;
    if (incoming == null || source == null || ramp == null) {
      return;
    }
    ramp.cancel();
    await _promoteCrossfadePlayer(
      generation: _crossfadeGeneration,
      incoming: incoming,
      source: source,
    );
  }

  Future<void> _promoteCrossfadePlayer({
    required int generation,
    required AudioPlayer incoming,
    required CrossfadePlaybackSource source,
  }) async {
    if (_crossfadePromotionInProgress ||
        !_isCrossfadeCurrent(generation) ||
        !identical(incoming, _crossfadePlayer)) {
      return;
    }
    _crossfadePromotionInProgress = true;
    final promotionCompletion = Completer<void>();
    _crossfadePromotionCompletion = promotionCompletion;
    try {
      await _enqueueQueueMutation(() async {
        if (!_isCrossfadeCurrent(generation) ||
            !identical(incoming, _crossfadePlayer)) {
          return;
        }
        await _player.setVolume(0);
        if (!_isCrossfadeCurrent(generation)) {
          return;
        }
        // Playback options are already stable for this queue, but applying a
        // setting can still cross the boundary. Do that while the prepared deck
        // remains the sole audible authority, then sample its freshest clock.
        await _applyPlaybackOptions();
        if (!_isCrossfadeCurrent(generation)) {
          return;
        }
        final incomingPosition = incoming.position;
        final synchronized = await _synchronizePrimaryToCrossfadeSource(
          source,
          incomingPosition,
          generation,
        );
        if (!synchronized || !_isCrossfadeCurrent(generation)) {
          if (_isCrossfadeCurrent(generation)) {
            _crossfadeGeneration++;
            await _resetCrossfadeState(restorePrimaryVolume: true);
            if (_player.processingState == ProcessingState.completed) {
              _emit(_snapshot.copyWith(status: PlayerStatus.completed));
            } else {
              _handlePrimarySequenceState(_player.sequenceState, force: true);
            }
          }
          return;
        }
        final shouldRemainPaused =
            _crossfadePaused || _snapshot.status == PlayerStatus.paused;
        if (shouldRemainPaused) {
          await _player.pause();
        } else if (!_player.playing) {
          _startPlayback(_playbackGeneration);
        }
        final handoffWatch = Stopwatch()..start();
        final handedOff = await _finishCrossfadeHandoff(
          generation: generation,
          incoming: incoming,
          remainPaused: shouldRemainPaused,
          handoffWatch: handoffWatch,
        );
        if (!handedOff || !_isCrossfadeCurrent(generation)) {
          if (_isCrossfadeCurrent(generation)) {
            await _abortCrossfadeGeneration(generation);
          }
          return;
        }

        var nextSnapshot = _crossfadeSnapshot(
          source,
          position: _player.position,
          detectedDuration: incoming.duration,
        );
        if (_crossfadePaused || _snapshot.status == PlayerStatus.paused) {
          nextSnapshot = nextSnapshot.copyWith(status: PlayerStatus.paused);
        }
        await _crossfadeErrorSubscription?.cancel();
        _crossfadeErrorSubscription = null;
        _crossfadeRamp = null;
        _preparedCrossfadeSource = null;
        _crossfadePreparation = null;
        _crossfadePlayer = null;
        _crossfadePrimaryGain = 1;
        _crossfadeIncomingGain = 0;
        _emit(nextSnapshot);
        if (_disableCrossfadeAfterHandoff) {
          _disableCrossfadeAfterHandoff = false;
          _crossfadeEnabled = false;
        }
        _scheduleCrossfadeRetirement(incoming);
      }, label: 'crossfadePromotion');
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

  Future<bool> _synchronizePrimaryToCrossfadeSource(
    CrossfadePlaybackSource source,
    Duration position,
    int generation,
  ) async {
    switch (source) {
      case LocalCrossfadePlaybackSource(:final track):
        final index = _localQueueTracks.indexWhere(
          (candidate) => candidate.id == track.id,
        );
        if (index >= 0 && index < _player.sequence.length) {
          await _player.seek(position, index: index);
        } else {
          return false;
        }
        if (!_isCrossfadeCurrent(generation)) return false;
        _activeRemoteTrack = null;
      case RemoteCrossfadePlaybackSource(:final source):
        final index = _remoteQueueSources.indexWhere(
          (candidate) => candidate.queueEntryId == source.queueEntryId,
        );
        if (index >= 0 && index < _player.sequence.length) {
          await _player.seek(position, index: index);
        } else {
          return false;
        }
        if (!_isCrossfadeCurrent(generation)) return false;
        _activeRemoteTrack = source.track;
    }
    return _isCrossfadeCurrent(generation);
  }

  bool get _primaryIsReadyForCrossfade {
    final state = _player.playerState;
    return state.playing && state.processingState == ProcessingState.ready;
  }

  Future<bool> _waitForPrimaryCrossfadeReadiness({
    required int generation,
    required Stopwatch handoffWatch,
  }) async {
    bool isReady(PlayerState state) =>
        state.playing && state.processingState == ProcessingState.ready;
    while (_isCrossfadeCurrent(generation)) {
      if (_primaryIsReadyForCrossfade) {
        return true;
      }
      final remaining = _operationTimeout - handoffWatch.elapsed;
      if (remaining <= Duration.zero) {
        return false;
      }
      final pollDuration = remaining < _crossfadeHandoffReadyPollInterval
          ? remaining
          : _crossfadeHandoffReadyPollInterval;
      try {
        await _player.playerStateStream
            .firstWhere(isReady)
            .timeout(pollDuration);
      } on TimeoutException {
        // Polling keeps cancellation responsive without treating a slow
        // Android rebuffer as permission to fade into an unready deck. The
        // prepared player remains the sole audible authority throughout.
      }
    }
    return false;
  }

  Future<bool> _realignPrimaryToIncomingClock({
    required int generation,
    required AudioPlayer incoming,
    required Stopwatch handoffWatch,
  }) async {
    if (!_isCrossfadeCurrent(generation) ||
        !identical(incoming, _crossfadePlayer)) {
      return false;
    }

    for (
      var realignment = 0;
      realignment <= _crossfadeHandoffMaxRealignments;
      realignment++
    ) {
      final ready = await _waitForPrimaryCrossfadeReadiness(
        generation: generation,
        handoffWatch: handoffWatch,
      );
      if (!ready ||
          !_isCrossfadeCurrent(generation) ||
          !identical(incoming, _crossfadePlayer)) {
        return false;
      }

      // Sample B last so the correction always targets its freshest clock.
      // A same-source seek may itself rebuffer on ExoPlayer, so every seek is
      // followed by another readiness wait and a new drift measurement.
      final primaryPosition = _player.position;
      final incomingPosition = incoming.position;
      final driftMicroseconds = (incomingPosition - primaryPosition)
          .inMicroseconds
          .abs();
      if (driftMicroseconds <=
          _crossfadeHandoffRealignThreshold.inMicroseconds) {
        // Yield once and confirm the invariant immediately before settle. This
        // catches a late buffering transition or a standby clock update that
        // raced the first sample.
        await Future<void>.delayed(Duration.zero);
        final confirmedReady = await _waitForPrimaryCrossfadeReadiness(
          generation: generation,
          handoffWatch: handoffWatch,
        );
        if (!confirmedReady ||
            !_isCrossfadeCurrent(generation) ||
            !identical(incoming, _crossfadePlayer)) {
          return false;
        }
        final confirmedDrift = (incoming.position - _player.position)
            .inMicroseconds
            .abs();
        if (confirmedDrift <=
            _crossfadeHandoffRealignThreshold.inMicroseconds) {
          return true;
        }
      }

      if (realignment == _crossfadeHandoffMaxRealignments ||
          handoffWatch.elapsed >= _operationTimeout) {
        return false;
      }
      await _player.seek(incoming.position);
      if (!_isCrossfadeCurrent(generation) ||
          !identical(incoming, _crossfadePlayer)) {
        return false;
      }
    }
    return false;
  }

  Future<bool> _finishCrossfadeHandoff({
    required int generation,
    required AudioPlayer incoming,
    required bool remainPaused,
    required Stopwatch handoffWatch,
  }) async {
    if (remainPaused) {
      // No audible settle is started while both decks are paused.
      return _completeCrossfadeCutover(
        generation: generation,
        incoming: incoming,
        remainPaused: true,
      );
    }

    while (_isCrossfadeCurrent(generation) &&
        identical(incoming, _crossfadePlayer) &&
        handoffWatch.elapsed < _operationTimeout) {
      final realigned = await _realignPrimaryToIncomingClock(
        generation: generation,
        incoming: incoming,
        handoffWatch: handoffWatch,
      );
      if (!_isCrossfadeCurrent(generation) ||
          !identical(incoming, _crossfadePlayer)) {
        return false;
      }
      if (realigned) {
        final settled = await _settleCrossfadeHandoff(
          generation: generation,
          incoming: incoming,
        );
        if (settled) {
          return true;
        }
        // Readiness can disappear between the final drift sample and the first
        // settle tick. No gains changed in that path, so B remains authoritative
        // while the bounded outer loop waits and aligns again.
        continue;
      }
      if (_primaryIsReadyForCrossfade) {
        final cutover = await _completeCrossfadeCutover(
          generation: generation,
          incoming: incoming,
          remainPaused: false,
        );
        if (cutover) {
          return true;
        }
        // The cutover restores B before returning false when A loses readiness
        // during the parallel native writes. Retry from readiness/alignment;
        // the shared stopwatch and operation deadline keep this finite.
      }
    }
    return false;
  }

  Future<bool> _settleCrossfadeHandoff({
    required int generation,
    required AudioPlayer incoming,
  }) async {
    if (!_primaryIsReadyForCrossfade) {
      return false;
    }

    final readinessLost = Completer<void>();
    Future<void>? restoration;
    Future<void> restorePreparedDeck() {
      return restoration ??= () async {
        if (!_isCrossfadeCurrent(generation) ||
            !identical(incoming, _crossfadePlayer)) {
          return;
        }
        _crossfadePrimaryGain = 0;
        _crossfadeIncomingGain = 1;
        final master = _masterVolume;
        await _writeCrossfadeVolumes(
          incoming: incoming,
          outgoingVolume: 0,
          incomingVolume: master,
        );
      }();
    }

    Future<void> handleReadinessLoss() async {
      await restorePreparedDeck();
      if (!readinessLost.isCompleted) {
        readinessLost.complete();
      }
    }

    late final CrossfadeRamp settleRamp;
    settleRamp = CrossfadeRamp(
      duration: _crossfadeHandoffSettleDuration,
      tickInterval: const Duration(milliseconds: 20),
      applyGains: (gains) async {
        if (!_isCrossfadeCurrent(generation) ||
            !identical(incoming, _crossfadePlayer)) {
          return;
        }
        if (!_primaryIsReadyForCrossfade) {
          await handleReadinessLoss();
          return;
        }
        // Both decks now render the same song. Use a linear complementary
        // handoff (derived from CrossfadeRamp's square-root progress) so their
        // correlated amplitudes sum to the master instead of producing a
        // +3 dB bump and comb-like coloration at the midpoint.
        final progress = (gains.incoming * gains.incoming)
            .clamp(0, 1)
            .toDouble();
        final primaryGain = progress;
        final incomingGain = 1 - progress;
        _crossfadePrimaryGain = primaryGain;
        _crossfadeIncomingGain = incomingGain;
        final master = _masterVolume;
        await _writeCrossfadeVolumes(
          incoming: incoming,
          outgoingVolume: primaryGain * master,
          incomingVolume: incomingGain * master,
        );
        if (_isCrossfadeCurrent(generation) &&
            identical(incoming, _crossfadePlayer) &&
            !_primaryIsReadyForCrossfade) {
          await handleReadinessLoss();
        }
      },
    );
    final completion = settleRamp.start();
    final completed = await Future.any<bool>([
      completion,
      readinessLost.future.then((_) => false),
    ]);
    if (!completed || readinessLost.isCompleted) {
      settleRamp.cancel();
      await restoration;
      return false;
    }
    if (!_isCrossfadeCurrent(generation) ||
        !identical(incoming, _crossfadePlayer)) {
      return false;
    }
    if (!_primaryIsReadyForCrossfade) {
      await handleReadinessLoss();
      return false;
    }
    return true;
  }

  Future<bool> _completeCrossfadeCutover({
    required int generation,
    required AudioPlayer incoming,
    required bool remainPaused,
  }) async {
    if (!_isCrossfadeCurrent(generation) ||
        !identical(incoming, _crossfadePlayer) ||
        (!remainPaused && !_primaryIsReadyForCrossfade)) {
      return false;
    }

    // If the two decoder clocks cannot converge after the bounded retries,
    // prefer one parallel terminal gain write over either mixing misaligned
    // copies or stopping B before A becomes audible. Normal promotion still
    // commits the metadata and retires B only after this write completes.
    _crossfadePrimaryGain = 1;
    _crossfadeIncomingGain = 0;
    final master = _masterVolume;
    await _writeCrossfadeVolumes(
      incoming: incoming,
      outgoingVolume: master,
      incomingVolume: 0,
    );
    if (!_isCrossfadeCurrent(generation) ||
        !identical(incoming, _crossfadePlayer)) {
      return false;
    }
    if (!remainPaused && !_primaryIsReadyForCrossfade) {
      // A lost readiness while the parallel native writes were in flight.
      // Put B back in charge before returning to the reset/cancellation path.
      _crossfadePrimaryGain = 0;
      _crossfadeIncomingGain = 1;
      final restoredMaster = _masterVolume;
      await _writeCrossfadeVolumes(
        incoming: incoming,
        outgoingVolume: 0,
        incomingVolume: restoredMaster,
      );
      return false;
    }
    return true;
  }

  PlayerSnapshot _crossfadeSnapshot(
    CrossfadePlaybackSource source, {
    required Duration position,
    required Duration? detectedDuration,
  }) {
    return switch (source) {
      LocalCrossfadePlaybackSource(:final track) => PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id,
        sourceUrl: track.sourceUrl,
        thumbnailUrl: track.thumbnailPath ?? track.thumbnailUrl,
        position: position,
        duration: _usableDuration(detectedDuration) ?? track.duration,
        volume: _masterVolume,
        isRemote: false,
        isExternal: track.isExternal,
        shuffleEnabled: _shuffleEnabled,
        repeatMode: _repeatMode,
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
        position: position,
        duration: _usableDuration(detectedDuration) ?? source.track.duration,
        volume: _masterVolume,
        isRemote: true,
        shuffleEnabled: _shuffleEnabled,
        repeatMode: _repeatMode,
      ),
    };
  }

  Future<void> _writeCrossfadeVolumes({
    required AudioPlayer incoming,
    required double outgoingVolume,
    required double incomingVolume,
  }) {
    final write = _crossfadeVolumeWriteTail.then((_) async {
      if (_disposed) {
        return;
      }
      await Future.wait<void>([
        _player.setVolume(outgoingVolume.clamp(0, 1).toDouble()),
        incoming.setVolume(incomingVolume.clamp(0, 1).toDouble()),
      ]);
    });
    _crossfadeVolumeWriteTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<void> _writePrimaryCrossfadeVolume(double volume) {
    final write = _crossfadeVolumeWriteTail.then((_) async {
      if (_disposed) {
        return;
      }
      await _player.setVolume(volume.clamp(0, 1).toDouble());
    });
    _crossfadeVolumeWriteTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  Future<void> _retireCrossfadePlayer(AudioPlayer player) async {
    await Future<void>.delayed(_crossfadeRetirementGrace);
    try {
      await player.stop().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Promotion is already complete; retirement cannot affect playback.
    }
    try {
      await player.dispose().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Best effort after a native decoder failure.
    }
  }

  void _scheduleCrossfadeRetirement(AudioPlayer player) {
    late final Future<void> retirement;
    retirement = _retireCrossfadePlayer(
      player,
    ).whenComplete(() => _crossfadeRetirements.remove(retirement));
    _crossfadeRetirements.add(retirement);
    unawaited(retirement);
  }

  @override
  Future<void> playRemote(TrackInfo track) async {
    final source = track.streamUrl;
    if (source == null || source.isEmpty) {
      throw const app_errors.PlayerException(
        'No hay una URL reproducible. Obtén la información del track primero.',
        code: 'missing_stream_url',
      );
    }
    final uri = Uri.tryParse(source);
    if (uri == null || !uri.hasScheme) {
      throw const app_errors.PlayerException(
        'La URL reproducible no es válida.',
        code: 'invalid_stream_url',
      );
    }
    await playRemoteSource(
      RemotePlaybackSource(
        track: track,
        uri: uri,
        queueEntryId: 'standalone:${track.id.isEmpty ? track.url : track.id}',
        httpHeaders: track.httpHeaders,
        isOnlyLogicalQueueItem: true,
      ),
    );
  }

  @override
  Future<void> playRemoteSource(RemotePlaybackSource source) async {
    final generation = ++_playbackGeneration;
    _remoteQueueRevision++;
    _cancelActiveSourceLoad();
    await _invalidateCrossfadeForExplicitAction();
    if (generation != _playbackGeneration || _disposed) {
      return;
    }
    final track = source.track;

    _activeRemoteTrack = track;
    _localQueueIds = const [];
    _localQueueTracks = const [];
    _reportedFailureGeneration = null;
    _diagnosticGeneration = null;
    _diagnosticFuture = null;
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id.isEmpty ? track.url : track.id,
        queueEntryId: source.queueEntryId,
        sourceUrl: track.url,
        thumbnailUrl: track.thumbnailUrl,
        duration: track.duration,
        volume: _masterVolume,
        isRemote: true,
      ),
    );
    _remoteStartupWatch = Stopwatch()..start();
    _loggedRemoteDuration = track.duration != null;
    developer.log(
      'playRemote start, hasDuration=${track.duration != null}, '
      'hasHeaders=${track.httpHeaders?.isNotEmpty == true}, '
      'format=${track.streamExtension ?? 'unknown'}',
      name: 'BStreamPlayback',
    );
    await _enqueueQueueMutation(
      () async {
        if (generation != _playbackGeneration) {
          return;
        }
        _localQueueIds = const [];
        _remoteQueueSources = [source];
        _remoteHasSingleLogicalItem = source.isOnlyLogicalQueueItem;
        try {
          final loadedDuration = await _player.setAudioSources(
            [_remoteAudioSource(source)],
            initialIndex: 0,
            initialPosition: Duration.zero,
            // Validate the signed URL before reporting that playback has
            // started. This turns HTTP/format failures into a catchable error
            // instead of a later, easily lost background event.
            preload: true,
          );
          if (generation == _playbackGeneration &&
              _usableDuration(loadedDuration) != null) {
            _emit(_snapshot.copyWith(duration: loadedDuration));
          }
        } catch (error) {
          if (generation == _playbackGeneration) {
            final baseMessage = _playerErrorMessage(error);
            final message = await _diagnosticMessage(error, generation, track);
            if (message != baseMessage) {
              throw app_errors.PlayerException(
                message,
                code: 'playback_source_error',
                details: error,
              );
            }
          }
          rethrow;
        }
        if (generation != _playbackGeneration) {
          return;
        }
        developer.log(
          'setAudioSources returned after ${_remoteStartupWatch?.elapsedMilliseconds ?? 0}ms',
          name: 'BStreamPlayback',
        );
        await _applyPlaybackOptions();
        if (generation != _playbackGeneration) {
          return;
        }
        _startPlayback(generation);
        developer.log(
          'play requested after ${_remoteStartupWatch?.elapsedMilliseconds ?? 0}ms',
          name: 'BStreamPlayback',
        );
      },
      isSourceLoad: true,
      label: 'setAudioSources',
      onTimeout: () {
        _handleSourceLoadTimeout(generation);
      },
    );
  }

  @override
  Future<void> updateRemoteQueue(
    List<RemotePlaybackSource> upcoming, {
    bool finalize = true,
  }) {
    final generation = _playbackGeneration;
    final revision = ++_remoteQueueRevision;
    final desired = List<RemotePlaybackSource>.unmodifiable(upcoming);
    return _enqueueQueueMutation(
      () async {
        if (generation != _playbackGeneration ||
            revision != _remoteQueueRevision ||
            _remoteQueueSources.isEmpty) {
          return;
        }
        await _reconcileRemoteQueue(
          desired,
          generation,
          revision,
          finalize: finalize,
        );
      },
      label: 'updateRemoteQueue',
      onTimeout: () {
        if (generation == _playbackGeneration &&
            revision == _remoteQueueRevision) {
          _remoteQueueRevision++;
        }
      },
    );
  }

  Future<void> _reconcileRemoteQueue(
    List<RemotePlaybackSource> upcoming,
    int generation,
    int revision, {
    required bool finalize,
  }) async {
    var currentIndex = _player.currentIndex;
    if (currentIndex == null ||
        currentIndex < 0 ||
        currentIndex >= _remoteQueueSources.length) {
      return;
    }
    final currentEntryId = _remoteQueueSources[currentIndex].queueEntryId;

    bool isCurrent() {
      if (_disposed ||
          generation != _playbackGeneration ||
          revision != _remoteQueueRevision) {
        return false;
      }
      final index = _player.currentIndex;
      return index != null &&
          index >= 0 &&
          index < _remoteQueueSources.length &&
          _remoteQueueSources[index].queueEntryId == currentEntryId;
    }

    if (currentIndex > 1) {
      final removeCount = currentIndex - 1;
      await _player.removeAudioSourceRange(0, removeCount);
      if (!isCurrent()) {
        return;
      }
      _remoteQueueSources.removeRange(0, removeCount);
      currentIndex = 1;
    }

    for (var offset = 0; offset < upcoming.length; offset++) {
      if (!isCurrent()) {
        return;
      }
      final desired = upcoming[offset];
      final targetIndex = currentIndex + 1 + offset;
      if (targetIndex < _remoteQueueSources.length &&
          _remoteQueueSources[targetIndex].sourceKey == desired.sourceKey) {
        continue;
      }

      var existingIndex = -1;
      for (
        var index = targetIndex + 1;
        index < _remoteQueueSources.length;
        index++
      ) {
        if (_remoteQueueSources[index].sourceKey == desired.sourceKey) {
          existingIndex = index;
          break;
        }
      }
      if (existingIndex >= 0) {
        await _player.moveAudioSource(existingIndex, targetIndex);
        if (!isCurrent()) {
          return;
        }
        final moved = _remoteQueueSources.removeAt(existingIndex);
        _remoteQueueSources.insert(targetIndex, moved);
      } else {
        await _player.insertAudioSource(
          targetIndex,
          _remoteAudioSource(desired),
        );
        if (!isCurrent()) {
          return;
        }
        _remoteQueueSources.insert(targetIndex, desired);
      }
    }

    final desiredLength = currentIndex + 1 + upcoming.length;
    while (finalize && _remoteQueueSources.length > desiredLength) {
      if (!isCurrent()) {
        return;
      }
      final removeIndex = _remoteQueueSources.length - 1;
      await _player.removeAudioSourceAt(removeIndex);
      if (!isCurrent()) {
        return;
      }
      _remoteQueueSources.removeAt(removeIndex);
    }
  }

  Future<void> _enqueueQueueMutation(
    Future<void> Function() mutation, {
    bool isSourceLoad = false,
    required String label,
    void Function()? onTimeout,
  }) {
    final operation = _remoteQueueMutationTail.then((_) async {
      if (_disposed) {
        return;
      }
      final lease = _JustAudioOperationLease(isSourceLoad: isSourceLoad);
      _activeQueueOperation = lease;
      try {
        await _runWithDeadline(
          mutation,
          lease,
          label: label,
          onTimeout: onTimeout,
        );
      } finally {
        if (identical(_activeQueueOperation, lease)) {
          _activeQueueOperation = null;
        }
      }
    });
    _remoteQueueMutationTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _runWithDeadline(
    Future<void> Function() operation,
    _JustAudioOperationLease lease, {
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
        onTimeout?.call();
        result.completeError(
          TimeoutException(
            'just_audio $label exceeded $_operationTimeout',
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
      _JustAudioOperationLease(isSourceLoad: false),
      label: label,
    );
  }

  void _cancelActiveSourceLoad() {
    final operation = _activeQueueOperation;
    if (operation?.isSourceLoad == true) {
      operation!.cancel();
    }
  }

  void _cancelActiveQueueOperation() {
    _activeQueueOperation?.cancel();
  }

  void _handleSourceLoadTimeout(int generation) {
    if (_disposed || generation != _playbackGeneration) {
      return;
    }
    _playbackGeneration++;
    _remoteQueueRevision++;
    _crossfadeGeneration++;
    unawaited(_resetCrossfadeState(restorePrimaryVolume: true));
    // stop() switches just_audio's platform activation synchronously. That
    // interrupts the still-alive native load before its Future can complete
    // and publish a source after this timeout.
    unawaited(
      _player.stop().catchError((Object error, StackTrace stackTrace) {
        developer.log(
          'failed to interrupt timed-out source load',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
    _emit(
      _snapshot.copyWith(
        status: PlayerStatus.failed,
        errorMessage: 'El reproductor tardó demasiado en abrir el audio.',
      ),
    );
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    final generation = ++_playbackGeneration;
    _activeRemoteTrack = null;
    _remoteQueueRevision++;
    _cancelActiveSourceLoad();
    await _invalidateCrossfadeForExplicitAction();
    if (generation != _playbackGeneration || _disposed) {
      return;
    }
    _localQueueIds = const [];
    _localQueueTracks = const [];
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
    await _enqueueQueueMutation(
      () async {
        if (generation != _playbackGeneration) {
          return;
        }
        _remoteQueueSources = const [];
        _remoteHasSingleLogicalItem = false;
        await _player.setAudioSource(_localAudioSource(track));
        if (generation != _playbackGeneration) {
          return;
        }
        await _applyPlaybackOptions();
        if (generation != _playbackGeneration) {
          return;
        }
        _localQueueIds = [track.id];
        _localQueueTracks = [track];
        _startPlayback(generation);
      },
      isSourceLoad: true,
      label: 'setAudioSource',
      onTimeout: () {
        _handleSourceLoadTimeout(generation);
      },
    );
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) async {
    if (tracks.isEmpty) {
      return;
    }
    final generation = ++_playbackGeneration;
    _activeRemoteTrack = null;
    _remoteQueueRevision++;
    _cancelActiveSourceLoad();
    await _invalidateCrossfadeForExplicitAction();
    if (generation != _playbackGeneration || _disposed) {
      return;
    }
    final safeIndex = initialIndex.clamp(0, tracks.length - 1);
    final current = tracks[safeIndex];
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: current.title,
        artist: current.artist,
        album: current.album,
        trackId: current.id,
        sourceUrl: current.sourceUrl,
        thumbnailUrl: current.thumbnailPath ?? current.thumbnailUrl,
        duration: current.duration,
        volume: _masterVolume,
        isRemote: false,
        isExternal: current.isExternal,
      ),
    );
    final queueIds = tracks.map((track) => track.id).toList(growable: false);
    await _enqueueQueueMutation(
      () async {
        if (generation != _playbackGeneration) {
          return;
        }
        _remoteQueueSources = const [];
        _remoteHasSingleLogicalItem = false;
        if (_sameQueue(queueIds, _localQueueIds) &&
            _player.sequence.length == tracks.length) {
          await _player.seek(Duration.zero, index: safeIndex);
        } else {
          await _player.setAudioSources(
            tracks.map(_localAudioSource).toList(growable: false),
            initialIndex: safeIndex,
            initialPosition: Duration.zero,
          );
          _localQueueIds = queueIds;
        }
        _localQueueTracks = List<LocalTrack>.unmodifiable(tracks);
        if (generation != _playbackGeneration) {
          return;
        }
        await _applyPlaybackOptions();
        if (generation != _playbackGeneration) {
          return;
        }
        _startPlayback(generation);
      },
      isSourceLoad: true,
      label: 'setAudioSources',
      onTimeout: () {
        _handleSourceLoadTimeout(generation);
      },
    );
  }

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {
    await _invalidateCrossfadeForExplicitAction();
    final generation = _playbackGeneration;
    final revision = ++_remoteQueueRevision;
    final desired = List<LocalTrack>.unmodifiable(tracks);
    bool isCurrent() =>
        !_disposed &&
        generation == _playbackGeneration &&
        revision == _remoteQueueRevision &&
        _activeRemoteTrack == null;
    await _enqueueQueueMutation(
      () async {
        // Queue replacement shares the same native mutation lane as remote
        // playback and stop. A request that was superseded before it reached the
        // lane must never overwrite the newer source.
        if (!isCurrent()) {
          return;
        }

        if (desired.isEmpty) {
          await _player.stop();
          if (!isCurrent()) {
            return;
          }
          await _player.clearAudioSources();
          if (!isCurrent()) {
            return;
          }
          _localQueueIds = const [];
          _localQueueTracks = const [];
          _emit(
            PlayerSnapshot(
              status: PlayerStatus.stopped,
              volume: _masterVolume,
              shuffleEnabled: _shuffleEnabled,
              repeatMode: _repeatMode,
            ),
          );
          return;
        }

        final nextIds = desired
            .map((track) => track.id)
            .toList(growable: false);
        if (_sameQueue(nextIds, _localQueueIds) &&
            _player.sequence.length == desired.length) {
          return;
        }

        final shouldKeepPlaying =
            _snapshot.status == PlayerStatus.playing ||
            (_snapshot.status == PlayerStatus.loading && _player.playing);
        final currentTrackId = _snapshot.trackId;
        final currentPosition = _player.position;
        final canUpdateIncrementally =
            _localQueueIds.isNotEmpty &&
            _player.sequence.length == _localQueueIds.length;

        if (canUpdateIncrementally) {
          final workingIds = List<String>.of(_localQueueIds);
          for (var index = 0; index < nextIds.length; index++) {
            final desiredId = nextIds[index];
            if (index < workingIds.length && workingIds[index] == desiredId) {
              continue;
            }

            final existingIndex = workingIds.indexOf(desiredId, index + 1);
            if (existingIndex >= 0) {
              await _player.moveAudioSource(existingIndex, index);
              if (!isCurrent()) {
                return;
              }
              final moved = workingIds.removeAt(existingIndex);
              workingIds.insert(index, moved);
            } else {
              await _player.insertAudioSource(
                index,
                _localAudioSource(desired[index]),
              );
              if (!isCurrent()) {
                return;
              }
              workingIds.insert(index, desiredId);
            }
          }
          while (workingIds.length > nextIds.length) {
            await _player.removeAudioSourceAt(workingIds.length - 1);
            if (!isCurrent()) {
              return;
            }
            workingIds.removeLast();
          }
        } else {
          final retainedIndex = currentTrackId == null
              ? -1
              : nextIds.indexOf(currentTrackId);
          final safeIndex = retainedIndex >= 0
              ? retainedIndex
              : preferredIndex.clamp(0, desired.length - 1).toInt();
          await _player.setAudioSources(
            desired.map(_localAudioSource).toList(growable: false),
            initialIndex: safeIndex,
            initialPosition: retainedIndex >= 0
                ? currentPosition
                : Duration.zero,
          );
          if (!isCurrent()) {
            return;
          }
        }

        if (!isCurrent()) {
          return;
        }
        _localQueueIds = nextIds;
        _localQueueTracks = desired;

        final retainedIndex = currentTrackId == null
            ? -1
            : nextIds.indexOf(currentTrackId);
        if (retainedIndex >= 0) {
          await _player.seek(currentPosition, index: retainedIndex);
        } else {
          final safeIndex = preferredIndex.clamp(0, desired.length - 1).toInt();
          await _player.seek(Duration.zero, index: safeIndex);
        }
        if (!isCurrent()) {
          return;
        }
        await _applyPlaybackOptions();
        if (!isCurrent()) {
          return;
        }
        if (shouldKeepPlaying && !_player.playing) {
          _startPlayback(generation);
        } else if (!shouldKeepPlaying && _player.playing) {
          await _player.pause();
        }
      },
      label: 'replaceLocalQueue',
      onTimeout: () {
        if (isCurrent()) {
          _remoteQueueRevision++;
        }
      },
    );
  }

  @override
  Future<void> pause() async {
    _crossfadePaused = true;
    _crossfadeRamp?.pause();
    final incoming = _crossfadePlayer;
    await Future.wait<void>([
      _player.pause(),
      if (_crossfadeRamp != null && incoming != null) incoming.pause(),
    ]);
    _emit(_snapshot.copyWith(status: PlayerStatus.paused));
  }

  @override
  Future<void> resume() async {
    _startPlayback(_playbackGeneration);
    final incoming = _crossfadePlayer;
    _crossfadePaused = false;
    if (_crossfadeRamp != null && incoming != null) {
      unawaited(_playCrossfadeIncoming(incoming, _crossfadeGeneration));
      _crossfadeRamp?.resume();
    }
    _emit(_snapshot.copyWith(status: PlayerStatus.playing));
  }

  @override
  Future<void> togglePlayPause() {
    return _player.playing ? pause() : resume();
  }

  @override
  Future<void> stop() async {
    final generation = ++_playbackGeneration;
    _activeRemoteTrack = null;
    _remoteQueueRevision++;
    _cancelActiveQueueOperation();
    await _invalidateCrossfadeForExplicitAction();
    await _enqueueQueueMutation(() async {
      if (generation != _playbackGeneration) {
        return;
      }
      _remoteQueueSources = const [];
      _remoteHasSingleLogicalItem = false;
      _localQueueTracks = const [];
      await _player.stop();
      if (generation == _playbackGeneration) {
        // An already-dispatched incremental playlist command may finish after
        // stop on some backends. Forget the optimistic queue identity so the
        // next local request performs a full, authoritative replacement.
        _localQueueIds = const [];
        _emit(_snapshot.copyWith(status: PlayerStatus.stopped));
      }
    }, label: 'stop');
  }

  @override
  Future<void> seek(Duration position) {
    final generation = _playbackGeneration;
    final revision = ++_seekRevision;
    final target = position < Duration.zero ? Duration.zero : position;
    final logicalIndex = _logicalPrimaryIndexForSnapshot(_snapshot);
    final operation = _seekTail.then(
      (_) => _performSeek(
        target,
        generation: generation,
        revision: revision,
        logicalIndex: logicalIndex,
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
    required int generation,
    required int revision,
    required int? logicalIndex,
  }) async {
    if (_disposed ||
        generation != _playbackGeneration ||
        revision != _seekRevision) {
      return;
    }
    await _invalidateCrossfadeForExplicitAction();
    if (_disposed ||
        generation != _playbackGeneration ||
        revision != _seekRevision) {
      return;
    }
    final index = logicalIndex != null && logicalIndex < _player.sequence.length
        ? logicalIndex
        : null;
    if (index == null) {
      await _player.seek(target);
    } else {
      await _player.seek(target, index: index);
    }
    if (!_disposed &&
        generation == _playbackGeneration &&
        revision == _seekRevision) {
      // Publish the committed target before the controller stages a new
      // standby. Otherwise a stale near-end snapshot can immediately restart
      // the crossfade that this seek just cancelled.
      _emit(_snapshot.copyWith(position: target));
    }
  }

  int? _logicalPrimaryIndexForSnapshot(PlayerSnapshot snapshot) {
    final sequence = _player.sequence;
    for (var index = 0; index < sequence.length; index++) {
      final tag = sequence[index].tag;
      if (tag is MediaItem &&
          _isSameLogicalMediaItem(
            snapshot: snapshot,
            tag: tag,
            queueEntryId: tag.extras?['queueEntryId']?.toString(),
          )) {
        return index;
      }
    }
    return null;
  }

  @override
  Future<void> setVolume(double volume) async {
    final normalized = volume.clamp(0, 1).toDouble();
    _masterVolume = normalized;
    _emit(_snapshot.copyWith(volume: normalized));
    final ramp = _crossfadeRamp;
    final incoming = _crossfadePlayer;
    if (ramp != null && incoming != null) {
      await _writeCrossfadeVolumes(
        incoming: incoming,
        outgoingVolume: _crossfadePrimaryGain * normalized,
        incomingVolume: _crossfadeIncomingGain * normalized,
      );
      return;
    }
    await _player.setVolume(normalized);
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    _shuffleEnabled = enabled;
    _emit(_snapshot.copyWith(shuffleEnabled: enabled));
    await _applyPlaybackOptions();
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {
    _repeatMode = mode;
    _emit(_snapshot.copyWith(repeatMode: mode));
    await _applyPlaybackOptions();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _playbackGeneration++;
    _remoteQueueRevision++;
    _crossfadeGeneration++;
    _crossfadeRamp?.cancel();
    _crossfadeRamp = null;
    await _awaitCrossfadeShutdownBarrier();
    _cancelActiveQueueOperation();
    final incoming = _crossfadePlayer;
    _crossfadePlayer = null;
    await _crossfadeErrorSubscription?.cancel();
    _crossfadeErrorSubscription = null;
    await _positionSubscription.cancel();
    await _durationSubscription.cancel();
    await _volumeSubscription.cancel();
    await _stateSubscription.cancel();
    await _playbackErrorSubscription.cancel();
    await _sequenceStateSubscription.cancel();
    final retirements = List<Future<void>>.of(_crossfadeRetirements);
    try {
      await Future.wait<void>([
        _runStandaloneWithDeadline(_player.dispose, label: 'dispose'),
        if (incoming != null) _retireCrossfadePlayer(incoming),
        ...retirements,
      ]);
    } on TimeoutException {
      // A native load can wedge during teardown on a broken media stack. The
      // Dart service still has to release its streams and let shutdown finish.
    } finally {
      await _snapshotController.close();
    }
  }

  AudioSource _localAudioSource(LocalTrack track) {
    final source = Uri.tryParse(track.filePath.trim());
    if (source != null &&
        (source.scheme == 'content' ||
            source.scheme == 'file' ||
            source.scheme == 'ipod-library')) {
      return AudioSource.uri(source, tag: _localMediaItem(track));
    }
    return AudioSource.file(track.filePath, tag: _localMediaItem(track));
  }

  AudioSource _remoteAudioSource(RemotePlaybackSource source) {
    return AudioSource.uri(
      _remoteSourceUri(source),
      headers: source.httpHeaders,
      tag: _remoteMediaItem(source),
    );
  }

  Uri _remoteSourceUri(RemotePlaybackSource playbackSource) {
    final source = playbackSource.uri;
    final track = playbackSource.track;
    if (source.scheme == 'file' || source.scheme == 'content') {
      return source;
    }
    if (source.fragment.isNotEmpty || _hasKnownAudioExtension(source.path)) {
      return source;
    }

    final extension = _remoteExtension(track);
    return extension == null ? source : source.replace(fragment: '.$extension');
  }

  String? _remoteExtension(TrackInfo track) {
    final direct = track.streamExtension?.trim().toLowerCase();
    if (direct != null && direct.isNotEmpty) {
      return direct.replaceFirst('.', '');
    }

    final mime = track.streamMimeType?.split(';').first.trim().toLowerCase();
    return switch (mime) {
      'audio/mp4' => 'm4a',
      'audio/aac' => 'aac',
      'audio/mpeg' => 'mp3',
      'audio/webm' => 'webm',
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

  MediaItem _remoteMediaItem(RemotePlaybackSource source) {
    final track = source.track;
    final artworkSource = track.thumbnailUrl?.trim();
    return MediaItem(
      id: track.id.isEmpty ? track.url : track.id,
      album: track.album ?? 'BStream Music',
      title: track.title,
      artist: track.artist,
      artUri: _notificationArtUri(artworkSource),
      duration: track.duration,
      extras: {
        'sourceUrl': track.url,
        'isRemote': true,
        'queueEntryId': source.queueEntryId,
        if (artworkSource != null && artworkSource.isNotEmpty)
          'displayArtwork': artworkSource,
      },
    );
  }

  MediaItem _localMediaItem(LocalTrack track) {
    final artworkSource = (track.thumbnailPath ?? track.thumbnailUrl)?.trim();
    return MediaItem(
      id: track.id,
      album: track.album ?? 'BStream Music',
      title: track.title,
      artist: track.artist,
      artUri: _notificationArtUri(artworkSource),
      duration: track.duration,
      extras: {
        'sourceUrl': track.sourceUrl,
        'isRemote': false,
        'isExternal': track.isExternal,
        if (artworkSource != null && artworkSource.isNotEmpty)
          'displayArtwork': artworkSource,
      },
    );
  }

  Uri? _notificationArtUri(String? source) {
    return _notificationArtworkService.uriFor(source) ?? _artUri(source);
  }

  Uri? _artUri(String? source) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    final stable = canonicalYouTubeThumbnailSource(normalized) ?? normalized;
    if (stable.startsWith('http://') || stable.startsWith('https://')) {
      return Uri.tryParse(stable);
    }
    if (stable.startsWith('file://')) {
      return Uri.tryParse(stable);
    }
    final file = File(stable);
    return file.existsSync() ? file.uri : null;
  }

  Future<void> _applyPlaybackOptions() async {
    final hasRemoteQueue = _remoteQueueSources.isNotEmpty;
    await _player.setShuffleModeEnabled(
      hasRemoteQueue ? false : _shuffleEnabled,
    );
    await _player.setLoopMode(
      hasRemoteQueue
          ? (_repeatMode == PlaybackRepeatMode.one ||
                    (_repeatMode == PlaybackRepeatMode.all &&
                        _remoteHasSingleLogicalItem)
                ? LoopMode.one
                : LoopMode.off)
          : _loopMode,
    );
  }

  void _startPlayback(int generation) {
    // just_audio's play Future completes when playback is paused, stopped, or
    // reaches the end. Awaiting it would keep playRemote/playLocal pending for
    // the entire song and could overwrite a later completed state. Playback
    // state and failures remain authoritative through the subscriptions above.
    unawaited(_playAndReportFailure(generation));
  }

  Future<void> _playAndReportFailure(int generation) async {
    try {
      await _player.play();
    } catch (error, stackTrace) {
      await _reportPlaybackFailure(error, generation, _activeRemoteTrack);
      developer.log(
        'play request failed',
        name: 'BStreamPlayback',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _reportPlaybackFailure(
    Object error,
    int generation,
    TrackInfo? track,
  ) async {
    if (generation != _playbackGeneration ||
        _reportedFailureGeneration == generation) {
      return;
    }
    _reportedFailureGeneration = generation;

    final message = await _diagnosticMessage(error, generation, track);
    if (generation != _playbackGeneration) {
      return;
    }
    developer.log(
      'playback failed: $message',
      name: 'BStreamPlayback',
      error: error,
    );
    _emit(
      _snapshot.copyWith(status: PlayerStatus.failed, errorMessage: message),
    );
  }

  TrackInfo? _remoteTrackForError(
    PlayerException error,
    List<Object?> sequenceTags,
  ) {
    final index = error.index;
    if (index == null || index < 0 || index >= sequenceTags.length) {
      return null;
    }
    final tag = sequenceTags[index];
    if (tag is! MediaItem || tag.extras?['isRemote'] != true) {
      return null;
    }
    final queueEntryId = tag.extras?['queueEntryId']?.toString();
    final sourceUrl = tag.extras?['sourceUrl']?.toString();
    for (final source in _remoteQueueSources) {
      if ((queueEntryId != null && source.queueEntryId == queueEntryId) ||
          (sourceUrl != null && source.track.url == sourceUrl)) {
        return source.track;
      }
    }
    return null;
  }

  Future<String> _diagnosticMessage(
    Object error,
    int generation,
    TrackInfo? track,
  ) {
    final cachedGeneration = _diagnosticGeneration;
    final cachedFuture = _diagnosticFuture;
    if (cachedGeneration == generation && cachedFuture != null) {
      return cachedFuture;
    }

    final baseMessage = _playerErrorMessage(error);
    final future = _buildDiagnosticMessage(baseMessage, track);
    _diagnosticGeneration = generation;
    _diagnosticFuture = future;
    return future;
  }

  Future<String> _buildDiagnosticMessage(
    String baseMessage,
    TrackInfo? track,
  ) async {
    if (!_needsHttpDiagnostic(baseMessage) || track == null) {
      return baseMessage;
    }

    final detail = await _probeRemoteSource(track);
    return detail == null ? baseMessage : '$baseMessage: $detail';
  }

  bool _needsHttpDiagnostic(String message) {
    final normalized = message.trim().toLowerCase();
    return normalized.isEmpty || normalized.contains('source error');
  }

  Future<String?> _probeRemoteSource(TrackInfo track) async {
    final source = track.streamUrl?.trim();
    final uri = source == null ? null : Uri.tryParse(source);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 4);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 6));
      request.followRedirects = true;
      request.maxRedirects = 3;
      track.httpHeaders?.forEach((key, value) {
        final normalized = key.toLowerCase();
        if (normalized == 'host' ||
            normalized == 'content-length' ||
            normalized == 'range') {
          return;
        }
        request.headers.set(key, value);
      });
      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      final status = response.statusCode;
      final reason = response.reasonPhrase.trim();
      final statusText = reason.isEmpty
          ? 'HTTP $status'
          : 'HTTP $status ($reason)';

      // Read only the first response chunk. This is enough to recognize the
      // container while never downloading or retaining the audio stream.
      final firstChunk = await response.first;
      final signature = _mediaSignature(firstChunk);
      final signatureText = signature == null ? '' : '; detected $signature';

      if (status >= 400) {
        return statusText;
      }

      final contentType = response.headers.contentType?.mimeType;
      final typeText = contentType == null ? '' : '; content-type $contentType';
      final decoderName = Platform.isIOS ? 'AVPlayer' : 'ExoPlayer';
      return '$statusText$typeText$signatureText; '
          '$decoderName no pudo decodificar la respuesta';
    } on TimeoutException {
      return 'HTTP timeout';
    } on SocketException {
      return 'error de red';
    } on HttpException {
      return 'error HTTP';
    } catch (_) {
      return 'falló al verificar la URL';
    } finally {
      client.close(force: true);
    }
  }

  String? _mediaSignature(List<int> bytes) {
    if (bytes.length >= 8 &&
        String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
      return 'MP4';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x1a &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xdf &&
        bytes[3] == 0xa3) {
      return 'WebM';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      return 'MP3';
    }
    if (bytes.isNotEmpty && bytes.first == 0x3c) {
      return 'HTML';
    }
    return null;
  }

  String _playerErrorMessage(Object error) {
    if (error is PlayerException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) {
        return message;
      }
      final playerName = Platform.isIOS ? 'AVPlayer' : 'ExoPlayer';
      return '$playerName error code ${error.code}';
    }
    final message = error.toString().trim();
    return message.isEmpty ? 'Error desconocido de reproducción.' : message;
  }

  LoopMode get _loopMode {
    return switch (_repeatMode) {
      PlaybackRepeatMode.one => LoopMode.one,
      PlaybackRepeatMode.all => LoopMode.all,
      PlaybackRepeatMode.off => LoopMode.off,
    };
  }

  void _emit(PlayerSnapshot snapshot) {
    if (_disposed) {
      return;
    }
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  bool _sameQueue(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}

Duration? _usableDuration(Duration? duration) {
  return duration != null && duration > Duration.zero ? duration : null;
}

bool _isSameLogicalMediaItem({
  required PlayerSnapshot snapshot,
  required MediaItem tag,
  required String? queueEntryId,
}) {
  final snapshotQueueEntryId = snapshot.queueEntryId?.trim();
  final normalizedQueueEntryId = queueEntryId?.trim();
  if (snapshotQueueEntryId != null && snapshotQueueEntryId.isNotEmpty) {
    return normalizedQueueEntryId != null &&
        normalizedQueueEntryId.isNotEmpty &&
        snapshotQueueEntryId == normalizedQueueEntryId;
  }

  final snapshotSourceUrl = snapshot.sourceUrl?.trim();
  final sourceUrl = tag.extras?['sourceUrl']?.toString().trim();
  if (snapshotSourceUrl != null && snapshotSourceUrl.isNotEmpty) {
    return sourceUrl != null &&
        sourceUrl.isNotEmpty &&
        snapshotSourceUrl == sourceUrl;
  }

  final snapshotTrackId = snapshot.trackId?.trim();
  final sourceTrackId = tag.id.trim();
  return snapshotTrackId != null &&
      snapshotTrackId.isNotEmpty &&
      sourceTrackId.isNotEmpty &&
      snapshotTrackId == sourceTrackId;
}

/// Returns whether a just_audio failure still belongs to the source represented
/// by [snapshot]. Errors for a removed or preloaded queue item must not fail the
/// current song.
bool justAudioErrorBelongsToSnapshot(
  PlayerException error, {
  required List<Object?> sequenceTags,
  required int? currentIndex,
  required PlayerSnapshot snapshot,
}) {
  final errorIndex = error.index;
  if (errorIndex == null) {
    // There is no source identity to distinguish a current failure from a
    // delayed event emitted by a replaced native source. Never relabel it as
    // the current song. Current load and play failures remain observable from
    // their generation-bound setAudioSources/play Futures.
    return false;
  }
  if (errorIndex < 0 || errorIndex >= sequenceTags.length) {
    return false;
  }

  final tag = sequenceTags[errorIndex];
  if (tag is! MediaItem) {
    return currentIndex == errorIndex;
  }

  final snapshotQueueEntryId = snapshot.queueEntryId?.trim();
  final sourceQueueEntryId = tag.extras?['queueEntryId']?.toString().trim();
  if (snapshotQueueEntryId != null &&
      snapshotQueueEntryId.isNotEmpty &&
      sourceQueueEntryId != null &&
      sourceQueueEntryId.isNotEmpty) {
    return snapshotQueueEntryId == sourceQueueEntryId;
  }

  final snapshotSourceUrl = snapshot.sourceUrl?.trim();
  final sourceUrl = tag.extras?['sourceUrl']?.toString().trim();
  if (snapshotSourceUrl != null &&
      snapshotSourceUrl.isNotEmpty &&
      sourceUrl != null &&
      sourceUrl.isNotEmpty) {
    return snapshotSourceUrl == sourceUrl;
  }

  final snapshotTrackId = snapshot.trackId?.trim();
  final sourceTrackId = tag.id.trim();
  if (snapshotTrackId != null &&
      snapshotTrackId.isNotEmpty &&
      sourceTrackId.isNotEmpty) {
    return snapshotTrackId == sourceTrackId;
  }
  return currentIndex == errorIndex;
}

class _JustAudioOperationLease {
  _JustAudioOperationLease({required this.isSourceLoad});

  final bool isSourceLoad;
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

/// Keeps Flutter player surfaces on the original artwork while mobile system
/// controls use a square derivative in [MediaItem.artUri]. Old queue items
/// without the extra retain the legacy fallback.
String? displayArtworkSourceForMediaItem(MediaItem item) {
  final displaySource = item.extras?['displayArtwork']?.toString().trim();
  if (displaySource != null && displaySource.isNotEmpty) {
    return displaySource;
  }
  return item.artUri?.toString();
}
