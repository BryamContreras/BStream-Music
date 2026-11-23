import 'dart:async';
import 'dart:developer' as developer;

import 'package:media_kit/media_kit.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/platform/app_platform.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import '../audio_sources/audio_source_policy.dart';
import 'crossfade_transition.dart';
import 'media_kit_equalizer.dart';
import 'player_audio_output.dart';
import 'player_equalizer.dart';
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

  /// Native EOF state, updated before its playing/completed stream events.
  bool get completed;
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

class _MediaKitPlayerBackend
    implements
        MediaKitPlayerBackend,
        PlayerAudioOutput,
        EqualizerCapablePlayer {
  _MediaKitPlayerBackend() {
    _player = _createPlayer();
    _playerInitialization = _headlessInitialization(_player);
    _playerInitialization?.ignore();
    _playerSubscriptions = _forwardEvents(_player, _epoch);
  }

  static const _useHeadlessAudio = bool.fromEnvironment(
    'BSTREAM_HEADLESS_AUDIO',
  );

  late Player _player;
  Future<void>? _playerInitialization;
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
  final _audioOutputs = StreamController<PlayerAudioOutputState>.broadcast();
  List<PlayerAudioDevice> _audioDevices = const [];
  String _audioDeviceId = systemDefaultAudioDeviceId;
  EqualizerSettings _equalizerSettings = const EqualizerSettings();
  EqualizerSettings? _appliedEqualizer = const EqualizerSettings();
  double _logicalVolume = 100;
  double _equalizerOutputGain = 1;
  bool _equalizerUnavailable = false;
  Future<void>? _equalizerRecovery;
  Future<void> _equalizerTail = Future<void>.value();
  int _equalizerRevision = 0;
  Completer<void> _equalizerCancellation = Completer<void>();

  @override
  bool get supportsEqualizer =>
      !_equalizerUnavailable && _player.platform is NativePlayer;

  @override
  Future<void> configureEqualizer(EqualizerSettings settings) {
    _equalizerSettings = settings.normalized;
    final revision = ++_equalizerRevision;
    final player = _player;
    final epoch = _epoch;
    final initialization = _playerInitialization;
    final operation = _equalizerTail.then((_) async {
      if (_disposed || epoch != _epoch || revision != _equalizerRevision) {
        return;
      }
      if (initialization != null) await initialization;
      if (_disposed || epoch != _epoch || revision != _equalizerRevision) {
        return;
      }
      final curve = _equalizerSettings;
      if (_appliedEqualizer == curve) return;
      if (_equalizerUnavailable && curve.enabled && !curve.isFlat) {
        throw UnsupportedError('The native equalizer is unavailable.');
      }
      final platform = player.platform;
      if (platform is! NativePlayer) {
        throw UnsupportedError('This backend has no native equalizer.');
      }
      _appliedEqualizer = null;
      final gain = curve.outputGain;
      try {
        // The shipped minimal libavfilter contains equalizer, but not volume.
        // Process the bands in f64 and reserve output headroom using mpv's own
        // gain. Linear floating-point filtering commutes with this attenuation
        // and has no integer clipping between bands.
        if (gain < _equalizerOutputGain) {
          await _setEqualizerOutputGain(player, gain);
        }
        await MediaKitEqualizerFilter.apply(platform, curve);
        await _setEqualizerOutputGain(player, gain);
      } catch (_) {
        try {
          await MediaKitEqualizerFilter.apply(
            platform,
            const EqualizerSettings(),
          );
        } catch (_) {
          // Preserve the original optional-filter error for the caller.
        }
        await _setEqualizerOutputGain(player, 1);
        rethrow;
      }
      if (!_disposed && epoch == _epoch) _appliedEqualizer = curve;
    });
    final future = Future.any<void>([operation, _equalizerCancellation.future]);
    _equalizerTail = future.catchError((Object _) {});
    return future;
  }

  Future<void> _setEqualizerOutputGain(Player player, double gain) async {
    if (_disposed || !identical(player, _player)) return;
    if (_equalizerOutputGain == gain) return;
    _equalizerOutputGain = gain;
    await player.setVolume(_logicalVolume * gain);
  }

  Future<void> _restorePlayerState(Player player, String deviceId) async {
    await _restoreAudioOutput(player, deviceId);
    final curve = _equalizerUnavailable
        ? const EqualizerSettings()
        : _equalizerSettings;
    final platform = player.platform;
    if (platform is NativePlayer) {
      try {
        await MediaKitEqualizerFilter.apply(platform, curve);
        await player.setVolume(_logicalVolume * curve.outputGain);
        if (!_disposed && identical(player, _player)) {
          _equalizerOutputGain = curve.outputGain;
        }
        if (!_disposed && identical(player, _player)) _appliedEqualizer = curve;
      } catch (error, stackTrace) {
        await player.setVolume(_logicalVolume);
        if (!_disposed && identical(player, _player)) _equalizerOutputGain = 1;
        // A filter unavailable in an older libmpv must not prevent a fresh
        // decoder from recovering after a cancelled or blocked load.
        developer.log(
          'Could not restore the native equalizer',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  void _onNativeEqualizerLog(Player player, int epoch, PlayerLog log) {
    if (_disposed ||
        epoch != _epoch ||
        _equalizerUnavailable ||
        _equalizerRecovery != null ||
        log.level != 'error') {
      return;
    }
    final curve = _appliedEqualizer;
    if (curve == null || !curve.enabled || curve.isFlat) return;
    final filterError =
        ((log.prefix.contains('lavfi') || log.prefix == 'af') &&
            RegExp(
              'No such filter|initializ|filtergraph|Option.*not found',
              caseSensitive: false,
            ).hasMatch(log.text)) ||
        (log.prefix == 'cplayer' &&
            log.text.toLowerCase().contains('audio filter'));
    if (!filterError) return;
    // af is writable while idle, even when a required FFmpeg filter is absent.
    // A failure can therefore arrive only when the first audio frame is decoded.
    // Retire just this optional effect; source ownership stays with playback.
    _equalizerUnavailable = true;
    final recovery = _recoverNativeEqualizer(player, epoch);
    _equalizerRecovery = recovery;
    unawaited(
      recovery.whenComplete(() {
        if (identical(_equalizerRecovery, recovery)) _equalizerRecovery = null;
      }),
    );
  }

  Future<void> _recoverNativeEqualizer(Player player, int epoch) async {
    bool isCurrent() => !_disposed && epoch == _epoch;
    try {
      developer.log(
        'Bypassing an unavailable native equalizer; retaining the playback source',
        name: 'BStreamPlayback',
      );
      final platform = player.platform;
      if (platform is NativePlayer) {
        await MediaKitEqualizerFilter.apply(
          platform,
          const EqualizerSettings(),
        );
      }
      if (!isCurrent()) return;
      _appliedEqualizer = const EqualizerSettings();
      await _setEqualizerOutputGain(player, 1);
    } catch (error, stackTrace) {
      developer.log(
        'Could not recover playback after bypassing the optional equalizer',
        name: 'BStreamPlayback',
        error: error,
        stackTrace: stackTrace,
      );
      if (isCurrent()) _errors.add(error.toString());
    }
  }

  @override
  PlayerAudioOutputState get audioOutputState => PlayerAudioOutputState(
    supported: true,
    devices: _audioDevices,
    selectedDeviceId: _audioDeviceId,
  );

  @override
  Stream<PlayerAudioOutputState> get audioOutputStream => _audioOutputs.stream;

  void _publishAudioOutput() {
    if (!_disposed) _audioOutputs.add(audioOutputState);
  }

  Future<void> _setPlayerAudioDevice(Player player, String id) async {
    await player.setAudioDevice(AudioDevice(id, ''));
    // media_kit logs some native command failures instead of throwing. Read
    // back the preference before reporting that it was accepted.
    final platform = player.platform;
    if (platform is NativePlayer &&
        await platform.getProperty('audio-device') != id) {
      throw StateError('The player did not accept the audio output.');
    }
  }

  @override
  Future<void> selectAudioOutput(String deviceId) async {
    final player = _player;
    final epoch = _epoch;
    await _withPlayer((player) => _setPlayerAudioDevice(player, deviceId));
    if (_disposed || epoch != _epoch || !identical(player, _player)) {
      throw StateError('Audio output selection was cancelled.');
    }
    _audioDeviceId = deviceId;
    _publishAudioOutput();
  }

  Future<void> _restoreAudioOutput(Player player, String id) async {
    final initialization = _headlessInitialization(player);
    if (initialization != null) await initialization;
    try {
      await _setPlayerAudioDevice(player, id);
    } catch (_) {
      await _setPlayerAudioDevice(player, systemDefaultAudioDeviceId);
      if (!_disposed && identical(player, _player)) {
        _audioDeviceId = systemDefaultAudioDeviceId;
        _publishAudioOutput();
      }
    }
  }

  Player _createPlayer() => Player(
    configuration: const PlayerConfiguration(title: AppConstants.appName),
  );

  Future<void>? _headlessInitialization(Player player) =>
      _useHeadlessAudio ? _configurePlayer(player) : null;

  Future<void> _configurePlayer(Player player) async {
    final platform = player.platform;
    if (platform == null) {
      return;
    }
    // GitHub's hosted Windows runners do not expose an audio device. libmpv's
    // timed null output preserves the real playback clock, allowing native
    // integration tests to exercise both crossfade decks without changing the
    // output selected by production builds.
    await (platform as dynamic).setProperty('ao', 'null');
  }

  Future<void> _withPlayer(Future<void> Function(Player player) operation) {
    final player = _player;
    final initialization = _playerInitialization;
    if (initialization == null) {
      return operation(player);
    }
    return initialization.then((_) => operation(player));
  }

  List<StreamSubscription<Object?>> _forwardEvents(Player player, int epoch) {
    bool isCurrent() => !_disposed && epoch == _epoch;
    void updateAudioDevices(List<AudioDevice> devices) {
      if (!isCurrent()) return;
      final seen = <String>{};
      _audioDevices = List.unmodifiable([
        for (final device in devices)
          if (device.name.isNotEmpty && seen.add(device.name))
            PlayerAudioDevice(
              id: device.name,
              name: device.description.isEmpty
                  ? device.name
                  : device.description,
            ),
      ]);
      _publishAudioOutput();
    }

    final subscriptions = <StreamSubscription<Object?>>[
      player.stream.position.listen((value) {
        if (isCurrent()) _positions.add(value);
      }),
      player.stream.duration.listen((value) {
        if (isCurrent()) _durations.add(value);
      }),
      player.stream.volume.listen((value) {
        // Crossfade envelopes and EQ attenuation belong to this physical deck.
        // Expose the requested gain rather than the compensated native value.
        if (isCurrent()) _volumes.add(_logicalVolume);
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
        if (!isCurrent()) return;
        _errors.add(value);
      }),
      player.stream.log.listen(
        (log) => _onNativeEqualizerLog(player, epoch, log),
      ),
      player.stream.audioDevices.listen(updateAudioDevices),
      player.stream.audioDevice.listen((_) {
        if (isCurrent()) _publishAudioOutput();
      }),
    ];
    // Read after subscribing so a device notification cannot be lost between
    // the initial state and the stream subscription.
    // A replacement Player initially exposes only "auto" before its native
    // enumeration arrives. Retain the known list across that startup window.
    if (epoch == 0 || _audioDevices.isEmpty) {
      updateAudioDevices(player.state.audioDevices);
    }
    return subscriptions;
  }

  @override
  void abandonPendingOperations() {
    if (_disposed) {
      return;
    }
    final retiredPlayer = _player;
    final retiredSubscriptions = _playerSubscriptions;
    final epoch = ++_epoch;
    _equalizerRecovery = null;
    _player = _createPlayer();
    _equalizerCancellation.complete();
    _equalizerCancellation = Completer<void>();
    _equalizerRevision++;
    _equalizerTail = Future<void>.value();
    _appliedEqualizer = const EqualizerSettings();
    _playerInitialization = _restorePlayerState(_player, _audioDeviceId);
    _playerInitialization?.ignore();
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
  bool get completed => _player.state.completed;
  @override
  Stream<String> get errorStream => _errors.stream;
  @override
  Object? get platform => _player.platform;

  @override
  Future<void> open(Media media, {required bool play}) =>
      _withPlayer((player) => player.open(media, play: play));
  @override
  Future<void> pause() => _withPlayer((player) => player.pause());
  @override
  Future<void> play() => _withPlayer((player) => player.play());
  @override
  Future<void> stop() => _withPlayer((player) => player.stop());
  @override
  Future<void> seek(Duration position) =>
      _withPlayer((player) => player.seek(position));
  @override
  Future<void> setVolume(double volume) {
    _logicalVolume = volume;
    return _withPlayer(
      (player) => player.setVolume(_logicalVolume * _equalizerOutputGain),
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _epoch++;
    _equalizerCancellation.complete();
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
      _audioOutputs.close(),
    ]);
    await _player.dispose();
  }
}

class MediaKitPlayerService
    implements
        PlayerService,
        CrossfadeCapablePlayer,
        AudioSourceUpgradePlayer,
        PlayerAudioOutput,
        EqualizerCapablePlayer {
  static const _crossfadeShutdownGrace = Duration(seconds: 2);
  static const _crossfadeRetirementGrace = Duration(milliseconds: 250);

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
  final _audioOutputController =
      StreamController<PlayerAudioOutputState>.broadcast();
  PlayerAudioOutputState _audioOutputState = const PlayerAudioOutputState();
  Future<void> _audioOutputTail = Future<void>.value();
  bool _changingAudioOutput = false;
  EqualizerSettings _equalizerSettings = const EqualizerSettings();
  Future<void> _equalizerTail = Future<void>.value();
  int _equalizerRevision = 0;
  Timer? _missingAudioDeviceTimer;
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
  bool _sourceUpgradeActive = false;
  Completer<void>? _sourceUpgradeCancellation;
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
  Duration? _standbyDecodedDuration;
  int _standbyRetirementGeneration = 0;

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
  PlayerAudioOutputState get audioOutputState => _audioOutputState;

  @override
  Stream<PlayerAudioOutputState> get audioOutputStream =>
      _audioOutputController.stream;

  @override
  bool get supportsEqualizer =>
      _player is EqualizerCapablePlayer &&
      (_player as EqualizerCapablePlayer).supportsEqualizer;

  @override
  Future<void> configureEqualizer(EqualizerSettings settings) {
    if (_disposed) return Future<void>.value();
    _equalizerSettings = settings.normalized;
    final revision = ++_equalizerRevision;
    final future = _equalizerTail.then((_) async {
      if (_disposed || revision != _equalizerRevision) return;
      if (!supportsEqualizer) {
        if (_equalizerSettings.enabled) {
          throw UnsupportedError('This backend has no native equalizer.');
        }
        return;
      }
      Object? failure;
      StackTrace? failureStack;
      for (final backend in <MediaKitPlayerBackend>{_player, ?_standbyPlayer}) {
        if (_disposed || revision != _equalizerRevision) return;
        try {
          if (backend case final EqualizerCapablePlayer equalizer) {
            await equalizer.configureEqualizer(_equalizerSettings);
          }
        } catch (error, stackTrace) {
          failure ??= error;
          failureStack ??= stackTrace;
        }
      }
      if (!_disposed && revision == _equalizerRevision && failure != null) {
        Error.throwWithStackTrace(failure, failureStack!);
      }
    });
    _equalizerTail = future.catchError((Object _) {});
    return future;
  }

  Future<void> _synchronizeBackendEqualizer(
    MediaKitPlayerBackend backend,
  ) async {
    if (backend is! EqualizerCapablePlayer) return;
    final equalizer = backend as EqualizerCapablePlayer;
    if (!equalizer.supportsEqualizer) return;
    // A standby deck can be created while a slider update is already queued.
    // Join that lane and re-check the revision before making the deck audible.
    var revision = -1;
    do {
      final future = _equalizerTail.then((_) async {
        if (_disposed) return;
        revision = _equalizerRevision;
        await equalizer.configureEqualizer(_equalizerSettings);
      });
      _equalizerTail = future.catchError((Object _) {});
      try {
        await future;
      } catch (error, stackTrace) {
        developer.log(
          'Could not apply the optional native equalizer',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }
    } while (!_disposed && revision != _equalizerRevision);
  }

  Future<void> _serializeAudioOutput(Future<void> Function() operation) {
    final future = _audioOutputTail.then((_) async {
      if (_disposed) return;
      await operation();
    });
    _audioOutputTail = future.catchError((Object _) {});
    return future;
  }

  Future<void> _setBackendAudioOutput(
    MediaKitPlayerBackend backend,
    String deviceId,
  ) async {
    if (backend case final PlayerAudioOutput output) {
      await output
          .selectAudioOutput(deviceId)
          .timeout(
            _operationTimeout,
            onTimeout: () {
              // A timed-out command can still complete natively. Isolate its
              // Player before allowing another route request to enter this lane.
              backend.abandonPendingOperations();
              _crossfadeGeneration++;
              unawaited(_resetCrossfadeState(restoreActiveVolume: true));
              if (identical(backend, _player)) {
                _backendGeneration = null;
                _emit(
                  _snapshot.copyWith(
                    status: PlayerStatus.failed,
                    errorMessage: 'No se pudo cambiar la salida de audio.',
                  ),
                );
              }
              throw TimeoutException(
                'media_kit audio output selection exceeded $_operationTimeout',
                _operationTimeout,
              );
            },
          );
    }
  }

  void _publishAudioOutputState(PlayerAudioOutputState state) {
    if (_disposed) return;
    _audioOutputState = state;
    _audioOutputController.add(state);
  }

  void _onAudioOutputState(PlayerAudioOutputState state) {
    if (_disposed) return;
    final selectedId = _changingAudioOutput
        ? _audioOutputState.selectedDeviceId
        : state.selectedDeviceId;
    _publishAudioOutputState(
      PlayerAudioOutputState(
        supported: state.supported,
        devices: state.devices,
        selectedDeviceId: selectedId,
      ),
    );
    _missingAudioDeviceTimer?.cancel();
    if (selectedId == systemDefaultAudioDeviceId ||
        state.devices.any((device) => device.id == selectedId)) {
      return;
    }
    // Hotplug notifications can briefly expose an empty/automatic-only list,
    // especially while a native backend initializes. Confirm disappearance
    // after that burst before falling back, even while the picker is closed.
    _missingAudioDeviceTimer = Timer(const Duration(milliseconds: 600), () {
      if (_disposed ||
          _changingAudioOutput ||
          _audioOutputState.selectedDeviceId != selectedId ||
          _audioOutputState.devices.any((device) => device.id == selectedId)) {
        return;
      }
      unawaited(
        selectAudioOutput(systemDefaultAudioDeviceId).catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          developer.log(
            'Could not restore the automatic audio output',
            name: 'BStreamPlayback',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
    });
  }

  @override
  Future<void> selectAudioOutput(String deviceId) => _serializeAudioOutput(
    () async {
      if (!_audioOutputState.supported ||
          (deviceId != systemDefaultAudioDeviceId &&
              !_audioOutputState.devices.any(
                (device) => device.id == deviceId,
              ))) {
        throw ArgumentError.value(deviceId, 'deviceId', 'Unavailable output.');
      }
      final previousId = _audioOutputState.selectedDeviceId;
      final outputs = <MediaKitPlayerBackend>[
        if (_player is PlayerAudioOutput) _player,
        if (_standbyPlayer case final PlayerAudioOutput _) _standbyPlayer!,
      ];
      _changingAudioOutput = true;
      try {
        for (final output in outputs) {
          await _setBackendAudioOutput(output, deviceId);
        }
        if (_disposed) return;
        _publishAudioOutputState(
          PlayerAudioOutputState(
            supported: true,
            devices: _audioOutputState.devices,
            selectedDeviceId: deviceId,
          ),
        );
      } catch (_) {
        // Keep both decks on the previous route if either native write fails.
        for (final output in outputs) {
          try {
            await _setBackendAudioOutput(output, previousId);
          } catch (_) {
            // A disconnected device may also reject rollback. Reflect the
            // active backend below rather than claiming a failed selection.
          }
        }
        rethrow;
      } finally {
        _changingAudioOutput = false;
        if (_player case final PlayerAudioOutput output) {
          _onAudioOutputState(output.audioOutputState);
        }
      }
    },
  );

  @override
  Future<bool> upgradeRemoteSource(
    RemotePlaybackSource source, {
    bool Function()? shouldContinue,
  }) async {
    final before = _snapshot;
    final duration = before.duration;
    if (_disposed ||
        _sourceUpgradeActive ||
        !before.isRemote ||
        before.status != PlayerStatus.playing ||
        before.sourceUrl != source.track.url ||
        before.trackId !=
            (source.track.id.isEmpty ? source.track.url : source.track.id) ||
        (before.queueEntryId != null &&
            before.queueEntryId != source.queueEntryId) ||
        duration == null ||
        duration - before.position <=
            _crossfadeDuration + const Duration(seconds: 3) ||
        _crossfadeRamp != null ||
        _crossfadePreparation != null ||
        _preparedCrossfadeSource != null ||
        _crossfadePromotionInProgress ||
        !(shouldContinue?.call() ?? true)) {
      return false;
    }
    final playbackGeneration = _requestedGeneration;
    final seekRevision = _seekRevision;
    final generation = ++_crossfadeGeneration;
    final outgoing = _player;
    final prepared = RemoteCrossfadePlaybackSource(source);
    final cancellation = Completer<void>();
    var committed = false;
    _sourceUpgradeActive = true;
    bool isCurrent() =>
        !_disposed &&
        _sourceUpgradeActive &&
        generation == _crossfadeGeneration &&
        playbackGeneration == _requestedGeneration &&
        seekRevision == _seekRevision &&
        _snapshot.status == PlayerStatus.playing &&
        _snapshot.sourceUrl == before.sourceUrl &&
        _snapshot.queueEntryId == before.queueEntryId &&
        (shouldContinue?.call() ?? true);
    try {
      await _resetCrossfadeState(
        restoreActiveVolume: true,
        preserveStandby: true,
        preserveSourceUpgrade: true,
      );
      if (!isCurrent()) return false;
      _sourceUpgradeCancellation = cancellation;
      final preparation = _prepareCrossfadeSource(prepared, generation);
      _crossfadePreparation = preparation;
      await preparation;
      if (identical(_crossfadePreparation, preparation)) {
        _crossfadePreparation = null;
      }
      final incoming = _standbyPlayer;
      if (!isCurrent() ||
          incoming == null ||
          _preparedCrossfadeSource != prepared) {
        return false;
      }
      // media_kit.open completes after dispatching playlist-pos, before mpv
      // finishes loading the file. Seeking at that point can be silently
      // ignored. Wait for decoder metadata, rather than catalog duration.
      await _waitForSourceUpgradeValue<Duration>(
        incoming.durationStream,
        (value) => value > Duration.zero,
        current: _standbyDecodedDuration,
        cancellation: cancellation,
      );
      if (!isCurrent()) return false;
      if (_standbyDuration != null &&
          (_standbyDuration! - duration).abs() >
              audioUpgradeDurationTolerance) {
        return false;
      }
      // Loading never pauses the active decoder. Only seek the muted prepared
      // source, using the clock after preparation rather than its old position.
      var position = await _sourceUpgradePosition(outgoing, _snapshot.position);
      if (!isCurrent()) return false;
      await _seekSourceUpgrade(incoming, position, cancellation);
      if (!isCurrent()) return false;
      await incoming.play().timeout(_operationTimeout);
      if (!isCurrent()) return false;
      // A native seek may have waited for buffering while the old decoder kept
      // advancing. Correct that drift once while the new decoder is muted.
      // Native time-pos avoids using the UI's throttled position snapshot.
      final livePosition = await _sourceUpgradePosition(
        outgoing,
        _snapshot.position,
      );
      if (!isCurrent()) return false;
      if ((livePosition - position).abs() > const Duration(milliseconds: 30)) {
        position = livePosition;
        await _seekSourceUpgrade(incoming, position, cancellation);
        if (!isCurrent()) return false;
      }
      late final CrossfadeRamp ramp;
      ramp = CrossfadeRamp(
        duration: const Duration(milliseconds: 100),
        tickInterval: const Duration(milliseconds: 20),
        applyGains: (gains) async {
          if (!isCurrent() || !identical(_crossfadeRamp, ramp)) {
            ramp.cancel();
            return;
          }
          // Both decks carry the same recording. Linear amplitude gains avoid
          // the level increase an equal-power overlap would add here.
          await _writeCrossfadeVolumes(
            outgoing: outgoing,
            incoming: incoming,
            outgoingVolume: gains.outgoing * gains.outgoing * _masterVolume,
            incomingVolume: gains.incoming * gains.incoming * _masterVolume,
          );
        },
      );
      _crossfadeRamp = ramp;
      if (!await ramp.start() || !isCurrent()) return false;
      await _promoteCrossfadePlayer(
        generation: generation,
        outgoing: outgoing,
        incoming: incoming,
        source: prepared,
      );
      committed = identical(_player, incoming);
      return committed;
    } catch (error, stackTrace) {
      if (!_disposed) {
        developer.log(
          'media_kit source upgrade kept the original source',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
      }
      return false;
    } finally {
      if (!cancellation.isCompleted) cancellation.complete();
      if (identical(_sourceUpgradeCancellation, cancellation)) {
        _sourceUpgradeCancellation = null;
      }
      if (generation == _crossfadeGeneration) {
        _sourceUpgradeActive = false;
        if (!committed) {
          _crossfadeGeneration++;
          await _resetCrossfadeState(restoreActiveVolume: true);
        }
      }
    }
  }

  Future<void> _seekSourceUpgrade(
    MediaKitPlayerBackend incoming,
    Duration position,
    Completer<void> cancellation,
  ) async {
    // Subscribe before seeking: an acknowledged command is not proof that
    // the decoder accepted the target. Keep it muted until its real clock
    // reaches that target, and keep the original if it cannot seek there.
    final aligned = _waitForSourceUpgradeValue<Duration>(
      incoming.positionStream,
      (value) => (value - position).abs() <= const Duration(milliseconds: 150),
      current: _standbyPosition,
      cancellation: cancellation,
    );
    await Future.wait<void>([
      aligned,
      incoming.seek(position).timeout(_operationTimeout),
    ], eagerError: true);
  }

  Future<void> _waitForSourceUpgradeValue<T>(
    Stream<T> stream,
    bool Function(T value) accepts, {
    required T? current,
    required Completer<void> cancellation,
  }) async {
    if (current != null && accepts(current)) return;
    final completion = Completer<void>();
    final subscription = stream.listen(
      (value) {
        if (!completion.isCompleted && accepts(value)) completion.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (!completion.isCompleted) completion.completeError(error, stack);
      },
      onDone: () {
        if (!completion.isCompleted) {
          completion.completeError(StateError('Prepared decoder was closed.'));
        }
      },
    );
    try {
      await Future.any<void>([
        completion.future,
        cancellation.future.then<void>((_) {
          throw StateError('Source alignment was cancelled.');
        }),
      ]).timeout(_operationTimeout);
    } finally {
      await subscription.cancel();
    }
  }

  Future<Duration> _sourceUpgradePosition(
    MediaKitPlayerBackend backend,
    Duration fallback,
  ) async {
    final platform = backend.platform;
    if (platform is NativePlayer) {
      try {
        final seconds = double.tryParse(
          await platform
              .getProperty('time-pos')
              .timeout(const Duration(milliseconds: 250)),
        );
        if (seconds != null && seconds.isFinite && seconds >= 0) {
          return Duration(microseconds: (seconds * 1000000).round());
        }
      } catch (_) {
        // Alternate/older native backends may not expose a usable live clock.
        // The last source position is still a safe bounded fallback.
      }
    }
    return fallback;
  }

  Future<void> _cancelSourceUpgradeForAction() async {
    if (!_sourceUpgradeActive) return;
    _sourceUpgradeActive = false;
    _crossfadeGeneration++;
    await _resetCrossfadeState(restoreActiveVolume: true);
  }

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
    if (_disposed || _sourceUpgradeActive) {
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
    await _resetCrossfadeState(
      restoreActiveVolume: true,
      preserveStandby: true,
    );
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
    // Promotion leaves the muted outgoing backend available for reuse. Cancel
    // its delayed stop before opening the next prepared source on that deck.
    _standbyRetirementGeneration++;
    final standby = _standbyPlayer ??= _createCrossfadeBackend();
    final cancellation = Completer<void>();
    _crossfadePreparationCancellation = cancellation;
    _standbyPosition = Duration.zero;
    _standbyDuration = _crossfadeSourceDuration(source);
    _standbyDecodedDuration = null;
    _attachStandbyPlayer(standby, generation);
    try {
      await _runCrossfadePreparationWithDeadline(() async {
        await standby.setVolume(0);
        if (!_isCrossfadeCurrent(generation) ||
            !identical(standby, _standbyPlayer)) {
          return;
        }
        if (standby is PlayerAudioOutput) {
          await _serializeAudioOutput(
            () => _setBackendAudioOutput(
              standby,
              _audioOutputState.selectedDeviceId,
            ),
          );
          if (!_isCrossfadeCurrent(generation) ||
              !identical(standby, _standbyPlayer)) {
            return;
          }
        }
        await _synchronizeBackendEqualizer(standby);
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
              identical(player, _standbyPlayer)) {
            _standbyDecodedDuration = duration > Duration.zero
                ? duration
                : null;
            if (duration > Duration.zero) _standbyDuration = duration;
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
    if (_sourceUpgradeActive) return;
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
      var nextSnapshot = _sourceUpgradeActive
          ? _snapshot.copyWith(position: _standbyPosition)
          : _crossfadeSnapshot(source);
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
      // Reassert the terminal gains through the shared parallel write lane.
      // Besides preserving the transactional failure boundary, this avoids two
      // serialized native round trips exactly where the audible decks switch.
      await _writeCrossfadeVolumes(
        outgoing: outgoing,
        incoming: incoming,
        outgoingVolume: 0,
        incomingVolume: _masterVolume,
      );
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
      _standbyDecodedDuration = null;
      _attachActivePlayer(incoming);
      if (_crossfadePaused || _snapshot.status == PlayerStatus.paused) {
        nextSnapshot = nextSnapshot.copyWith(status: PlayerStatus.paused);
      }
      _emit(nextSnapshot);
      if (_disableCrossfadeAfterHandoff) {
        _disableCrossfadeAfterHandoff = false;
        _crossfadeEnabled = false;
      }
      final retirementGeneration = ++_standbyRetirementGeneration;
      unawaited(_stopHealthyStandbyAfterGrace(outgoing, retirementGeneration));
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

  Future<void> _stopHealthyStandbyAfterGrace(
    MediaKitPlayerBackend standby,
    int retirementGeneration,
  ) async {
    await Future<void>.delayed(_crossfadeRetirementGrace);
    if (_disposed ||
        retirementGeneration != _standbyRetirementGeneration ||
        !identical(standby, _standbyPlayer) ||
        _preparedCrossfadeSource != null ||
        _crossfadePreparation != null) {
      return;
    }
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
      !_disposed &&
      (_crossfadeEnabled || _sourceUpgradeActive) &&
      generation == _crossfadeGeneration;

  Future<void> _resetCrossfadeState({
    required bool restoreActiveVolume,
    bool preserveStandby = false,
    bool preserveSourceUpgrade = false,
  }) async {
    if (!preserveSourceUpgrade) {
      _sourceUpgradeActive = false;
      final sourceCancellation = _sourceUpgradeCancellation;
      _sourceUpgradeCancellation = null;
      if (sourceCancellation != null && !sourceCancellation.isCompleted) {
        sourceCancellation.complete();
      }
    }
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
      stop: !preserveStandby,
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
    _standbyRetirementGeneration++;
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
    _standbyDecodedDuration = null;
  }

  void _attachActivePlayer(MediaKitPlayerBackend player) {
    if (player case final PlayerAudioOutput output) {
      _subscriptions.add(
        output.audioOutputStream.listen((_) {
          if (!_disposed && identical(player, _player)) {
            _onAudioOutputState(output.audioOutputState);
          }
        }),
      );
      _onAudioOutputState(output.audioOutputState);
    }
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
                _snapshot.status == PlayerStatus.completed ||
                player.completed ||
                _crossfadeRamp != null)) {
          // Native EOF sets completed before broadcasting playing=false. It
          // is not a user pause: publishing paused here cancels the queue's
          // autoplay intent, or invalidates an already scheduled completion
          // when the two streams arrive in the opposite order. Let the EOF
          // stream publish the terminal event; genuine pauses still pass.
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
  Future<void> playRemote(
    TrackInfo track, {
    Duration initialPosition = Duration.zero,
  }) async {
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
        position: initialPosition < Duration.zero
            ? Duration.zero
            : initialPosition,
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
    await _openForGeneration(
      _remoteMedia(track),
      generation,
      play: true,
      initialPosition: initialPosition,
    );
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
  Future<void> playLocal(
    LocalTrack track, {
    Duration initialPosition = Duration.zero,
  }) async {
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
        position: initialPosition < Duration.zero
            ? Duration.zero
            : initialPosition,
        volume: _masterVolume,
        isRemote: false,
        isExternal: track.isExternal,
      ),
    );
    await _openForGeneration(
      Media(track.filePath),
      generation,
      play: true,
      initialPosition: initialPosition,
    );
  }

  @override
  Future<void> playLocalQueue(
    List<LocalTrack> tracks,
    int initialIndex, {
    Duration initialPosition = Duration.zero,
  }) {
    if (tracks.isEmpty) {
      return Future.value();
    }
    final safeIndex = initialIndex.clamp(0, tracks.length - 1);
    return playLocal(tracks[safeIndex], initialPosition: initialPosition);
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
    final upgradeCancellation = _cancelSourceUpgradeForAction();
    final generation = _requestedGeneration;
    _crossfadePaused = true;
    _crossfadeRamp?.pause();
    await _enqueueOperation(() async {
      if (!_isCurrentGeneration(generation)) {
        return;
      }
      final standby = _standbyPlayer;
      await Future.wait<void>([
        upgradeCancellation,
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
    final upgradeCancellation = _cancelSourceUpgradeForAction();
    final requestedGeneration = _requestedGeneration;
    final revision = ++_seekRevision;
    final target = position < Duration.zero ? Duration.zero : position;
    final operation = _seekTail.then((_) async {
      await upgradeCancellation;
      return _performSeek(
        target,
        requestedGeneration: requestedGeneration,
        revision: revision,
      );
    });
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
    final upgradeCancellation = _cancelSourceUpgradeForAction();
    final normalized = volume.clamp(0, 1).toDouble();
    _masterVolume = normalized;
    _emit(_snapshot.copyWith(volume: normalized));
    await upgradeCancellation;
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
    _missingAudioDeviceTimer?.cancel();
    _requestedGeneration++;
    _crossfadeGeneration++;
    _standbyRetirementGeneration++;
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
      await _audioOutputController.close();
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
    Duration initialPosition = Duration.zero,
  }) {
    final startPosition = initialPosition < Duration.zero
        ? Duration.zero
        : initialPosition;
    return _enqueueOperation(
      () async {
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        await _configureLinuxAudioClientName();
        if (!_isCurrentGeneration(generation)) {
          return;
        }
        await _synchronizeBackendEqualizer(_player);
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
          // A restored position is a one-time seek, not Media.start (which
          // would also change the start of subsequent native repeats).
          await _player.open(
            media,
            play: play && startPosition == Duration.zero,
          );
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
        if (startPosition > Duration.zero) {
          await _player.seek(startPosition);
          if (!_isCurrentGeneration(generation)) return;
          if (play) {
            await _player.play();
            if (!_isCurrentGeneration(generation)) return;
          }
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
            position: startPosition,
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
