import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/errors/app_exception.dart' as app_errors;
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import '../../core/constants/app_constants.dart';
import 'player_service.dart';

class JustAudioPlayerService implements PlayerService {
  JustAudioPlayerService() {
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
          _emit(_snapshot.copyWith(position: position));
        });
    _durationSubscription = _player.durationStream.listen((duration) {
      final watch = _remoteStartupWatch;
      if (watch != null && duration != null && !_loggedRemoteDuration) {
        _loggedRemoteDuration = true;
        developer.log(
          'duration available after ${watch.elapsedMilliseconds}ms: $duration',
          name: 'BStreamPlayback',
        );
      }
      _emit(_snapshot.copyWith(duration: duration));
    });
    _volumeSubscription = _player.volumeStream.listen((volume) {
      _emit(_snapshot.copyWith(volume: volume.clamp(0, 1).toDouble()));
    });
    _stateSubscription = _player.playerStateStream.listen((state) {
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
        ProcessingState.completed => PlayerStatus.stopped,
        _ => state.playing ? PlayerStatus.playing : PlayerStatus.paused,
      };
      _emit(_snapshot.copyWith(status: status));
    });
    _playbackErrorSubscription = _player.errorStream.listen((error) {
      developer.log('playback failed', name: 'BStreamPlayback', error: error);
      _emit(
        _snapshot.copyWith(
          status: PlayerStatus.failed,
          errorMessage: error.message,
        ),
      );
    });
    _sequenceStateSubscription = _player.sequenceStateStream.listen((state) {
      final tag = state.currentSource?.tag;
      if (tag is! MediaItem) {
        return;
      }
      _emit(
        _snapshot.copyWith(
          title: tag.title,
          artist: tag.artist,
          trackId: tag.id,
          sourceUrl: tag.extras?['sourceUrl']?.toString(),
          thumbnailUrl: tag.artUri?.toString(),
          duration: tag.duration,
          isRemote: tag.extras?['isRemote'] == true,
        ),
      );
    });
  }

  static const _userAgent =
      'BStreamMusic/${AppConstants.appVersion} (Android) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36';

  final AudioPlayer _player = AudioPlayer(
    userAgent: _userAgent,
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
  final _snapshotController = StreamController<PlayerSnapshot>.broadcast();

  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<Duration?> _durationSubscription;
  late final StreamSubscription<double> _volumeSubscription;
  late final StreamSubscription<PlayerState> _stateSubscription;
  late final StreamSubscription<PlayerException> _playbackErrorSubscription;
  late final StreamSubscription<SequenceState?> _sequenceStateSubscription;

  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  bool _shuffleEnabled = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;
  List<String> _localQueueIds = const [];
  Stopwatch? _remoteStartupWatch;
  bool _loggedRemoteDuration = false;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  bool get supportsLocalQueueReplacement => true;

  @override
  Future<void> playRemote(TrackInfo track) async {
    final source = track.streamUrl;
    if (source == null || source.isEmpty) {
      throw const app_errors.PlayerException(
        'No hay una URL reproducible. Obtén la informacion del track primero.',
        code: 'missing_stream_url',
      );
    }

    _localQueueIds = const [];
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
    _remoteStartupWatch = Stopwatch()..start();
    _loggedRemoteDuration = track.duration != null;
    developer.log(
      'playRemote start, hasDuration=${track.duration != null}, hasHeaders=${track.httpHeaders?.isNotEmpty == true}',
      name: 'BStreamPlayback',
    );
    await _player.setAudioSource(
      AudioSource.uri(
        Uri.parse(source),
        headers: track.httpHeaders,
        tag: _remoteMediaItem(track),
      ),
      preload: false,
    );
    developer.log(
      'setAudioSource returned after ${_remoteStartupWatch?.elapsedMilliseconds ?? 0}ms',
      name: 'BStreamPlayback',
    );
    await _applyPlaybackOptions();
    _startPlayback();
    developer.log(
      'play requested after ${_remoteStartupWatch?.elapsedMilliseconds ?? 0}ms',
      name: 'BStreamPlayback',
    );
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    _localQueueIds = const [];
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.sourceUrl,
        thumbnailUrl: track.thumbnailPath ?? track.thumbnailUrl,
        duration: track.duration,
        volume: _snapshot.volume,
        isRemote: false,
      ),
    );
    await _player.setAudioSource(_localAudioSource(track));
    await _applyPlaybackOptions();
    _startPlayback();
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) async {
    if (tracks.isEmpty) {
      return;
    }
    final safeIndex = initialIndex.clamp(0, tracks.length - 1);
    final current = tracks[safeIndex];
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: current.title,
        artist: current.artist,
        trackId: current.id,
        sourceUrl: current.sourceUrl,
        thumbnailUrl: current.thumbnailPath ?? current.thumbnailUrl,
        duration: current.duration,
        volume: _snapshot.volume,
        isRemote: false,
      ),
    );
    final queueIds = tracks.map((track) => track.id).toList(growable: false);
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
    await _applyPlaybackOptions();
    _startPlayback();
  }

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {
    if (tracks.isEmpty) {
      _localQueueIds = const [];
      await _player.stop();
      await _player.clearAudioSources();
      _emit(
        PlayerSnapshot(
          status: PlayerStatus.stopped,
          volume: _snapshot.volume,
          shuffleEnabled: _shuffleEnabled,
          repeatMode: _repeatMode,
        ),
      );
      return;
    }

    final nextIds = tracks.map((track) => track.id).toList(growable: false);
    if (_sameQueue(nextIds, _localQueueIds) &&
        _player.sequence.length == tracks.length) {
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
          final moved = workingIds.removeAt(existingIndex);
          workingIds.insert(index, moved);
        } else {
          await _player.insertAudioSource(
            index,
            _localAudioSource(tracks[index]),
          );
          workingIds.insert(index, desiredId);
        }
      }
      while (workingIds.length > nextIds.length) {
        await _player.removeAudioSourceAt(workingIds.length - 1);
        workingIds.removeLast();
      }
    } else {
      final retainedIndex = currentTrackId == null
          ? -1
          : nextIds.indexOf(currentTrackId);
      final safeIndex = retainedIndex >= 0
          ? retainedIndex
          : preferredIndex.clamp(0, tracks.length - 1).toInt();
      await _player.setAudioSources(
        tracks.map(_localAudioSource).toList(growable: false),
        initialIndex: safeIndex,
        initialPosition: retainedIndex >= 0 ? currentPosition : Duration.zero,
      );
    }

    _localQueueIds = nextIds;
    final retainedIndex = currentTrackId == null
        ? -1
        : nextIds.indexOf(currentTrackId);
    if (retainedIndex >= 0) {
      await _player.seek(currentPosition, index: retainedIndex);
    } else {
      final safeIndex = preferredIndex.clamp(0, tracks.length - 1).toInt();
      await _player.seek(Duration.zero, index: safeIndex);
    }
    await _applyPlaybackOptions();
    if (shouldKeepPlaying && !_player.playing) {
      _startPlayback();
    } else if (!shouldKeepPlaying && _player.playing) {
      await _player.pause();
    }
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _emit(_snapshot.copyWith(status: PlayerStatus.paused));
  }

  @override
  Future<void> resume() async {
    _startPlayback();
  }

  @override
  Future<void> togglePlayPause() {
    return _player.playing ? pause() : resume();
  }

  @override
  Future<void> stop() {
    return _player.stop();
  }

  @override
  Future<void> seek(Duration position) {
    return _player.seek(position);
  }

  @override
  Future<void> setVolume(double volume) {
    final normalized = volume.clamp(0, 1).toDouble();
    _emit(_snapshot.copyWith(volume: normalized));
    return _player.setVolume(normalized);
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
    await _positionSubscription.cancel();
    await _durationSubscription.cancel();
    await _volumeSubscription.cancel();
    await _stateSubscription.cancel();
    await _playbackErrorSubscription.cancel();
    await _sequenceStateSubscription.cancel();
    await _player.dispose();
    await _snapshotController.close();
  }

  AudioSource _localAudioSource(LocalTrack track) {
    return AudioSource.file(track.filePath, tag: _localMediaItem(track));
  }

  MediaItem _remoteMediaItem(TrackInfo track) {
    return MediaItem(
      id: track.id.isEmpty ? track.url : track.id,
      album: 'BStream Music',
      title: track.title,
      artist: track.artist,
      artUri: _artUri(track.thumbnailUrl),
      duration: track.duration,
      extras: {'sourceUrl': track.url, 'isRemote': true},
    );
  }

  MediaItem _localMediaItem(LocalTrack track) {
    return MediaItem(
      id: track.id,
      album: 'BStream Music',
      title: track.title,
      artist: track.artist,
      artUri: _artUri(track.thumbnailPath ?? track.thumbnailUrl),
      duration: track.duration,
      extras: {'sourceUrl': track.sourceUrl, 'isRemote': false},
    );
  }

  Uri? _artUri(String? source) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
      return Uri.tryParse(normalized);
    }
    if (normalized.startsWith('file://')) {
      return Uri.tryParse(normalized);
    }
    final file = File(normalized);
    return file.existsSync() ? file.uri : null;
  }

  Future<void> _applyPlaybackOptions() async {
    await _player.setShuffleModeEnabled(_shuffleEnabled);
    await _player.setLoopMode(_loopMode);
  }

  void _startPlayback() {
    // just_audio's play Future completes when playback is paused, stopped, or
    // reaches the end. Awaiting it would keep playRemote/playLocal pending for
    // the entire song and could overwrite a later completed state. Playback
    // state and failures remain authoritative through the subscriptions above.
    unawaited(
      _player.play().catchError((Object error, StackTrace stackTrace) {
        developer.log(
          'play request failed',
          name: 'BStreamPlayback',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  LoopMode get _loopMode {
    return switch (_repeatMode) {
      PlaybackRepeatMode.one => LoopMode.one,
      PlaybackRepeatMode.all => LoopMode.all,
      PlaybackRepeatMode.off => LoopMode.off,
    };
  }

  void _emit(PlayerSnapshot snapshot) {
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
