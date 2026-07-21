import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' hide PlayerException;

import '../../core/errors/app_exception.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import '../../core/constants/app_constants.dart';
import 'player_service.dart';

class JustAudioPlayerService implements PlayerService {
  JustAudioPlayerService() {
    _positionSubscription = _player.positionStream.listen((position) {
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
  Future<void> playRemote(TrackInfo track) async {
    final source = track.streamUrl;
    if (source == null || source.isEmpty) {
      throw const PlayerException(
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
    await _player.play();
    developer.log(
      'play returned after ${_remoteStartupWatch?.elapsedMilliseconds ?? 0}ms',
      name: 'BStreamPlayback',
    );
    _emit(_snapshot.copyWith(status: PlayerStatus.playing));
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
    await _player.play();
    _emit(_snapshot.copyWith(status: PlayerStatus.playing));
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
    await _player.play();
    _emit(_snapshot.copyWith(status: PlayerStatus.playing));
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _emit(_snapshot.copyWith(status: PlayerStatus.paused));
  }

  @override
  Future<void> resume() async {
    await _player.play();
    _emit(_snapshot.copyWith(status: PlayerStatus.playing));
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
