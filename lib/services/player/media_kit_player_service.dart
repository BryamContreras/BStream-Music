import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../../core/errors/app_exception.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import 'player_service.dart';

class MediaKitPlayerService implements PlayerService {
  MediaKitPlayerService() {
    _ensureInitialized();
    _player = Player();
    _subscriptions.addAll([
      _player.stream.position.listen((position) {
        _emit(_snapshot.copyWith(position: position));
      }),
      _player.stream.duration.listen((duration) {
        _emit(_snapshot.copyWith(duration: duration));
      }),
      _player.stream.volume.listen((volume) {
        _emit(
          _snapshot.copyWith(volume: (volume / 100).clamp(0, 1).toDouble()),
        );
      }),
      _player.stream.buffering.listen((buffering) {
        if (buffering && _snapshot.status != PlayerStatus.playing) {
          _emit(_snapshot.copyWith(status: PlayerStatus.loading));
        }
      }),
      _player.stream.playing.listen((playing) {
        if (!playing && _snapshot.status == PlayerStatus.stopped) {
          return;
        }
        _emit(
          _snapshot.copyWith(
            status: playing ? PlayerStatus.playing : PlayerStatus.paused,
          ),
        );
      }),
      _player.stream.completed.listen((completed) {
        if (completed) {
          _emit(_snapshot.copyWith(status: PlayerStatus.stopped));
        }
      }),
      _player.stream.error.listen((message) {
        _emit(
          _snapshot.copyWith(
            status: PlayerStatus.failed,
            errorMessage: message,
          ),
        );
      }),
    ]);
  }

  late final Player _player;
  final _snapshotController = StreamController<PlayerSnapshot>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];

  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);

  static bool _initialized = false;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  Future<void> playRemote(TrackInfo track) async {
    final source = track.streamUrl;
    if (source == null || source.isEmpty) {
      throw const PlayerException(
        'No hay una URL reproducible. Obten la informacion del track primero.',
        code: 'missing_stream_url',
      );
    }

    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: track.title,
        artist: track.artist,
        trackId: track.id.isEmpty ? track.url : track.id,
        sourceUrl: track.url,
        thumbnailUrl: track.thumbnailUrl,
        volume: _snapshot.volume,
        isRemote: true,
      ),
    );
    await _player.open(
      Media(source, httpHeaders: track.httpHeaders),
      play: true,
    );
    _emit(_snapshot.copyWith(status: PlayerStatus.playing));
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
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
    await _player.open(Media(track.filePath), play: true);
    _emit(_snapshot.copyWith(status: PlayerStatus.playing));
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
    return _snapshot.status == PlayerStatus.playing ? pause() : resume();
  }

  @override
  Future<void> stop() {
    return _player.stop().then((_) {
      _emit(_snapshot.copyWith(status: PlayerStatus.stopped));
    });
  }

  @override
  Future<void> seek(Duration position) {
    return _player.seek(position);
  }

  @override
  Future<void> setVolume(double volume) {
    final normalized = volume.clamp(0, 1).toDouble();
    _emit(_snapshot.copyWith(volume: normalized));
    return _player.setVolume(normalized * 100);
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
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _snapshotController.close();
  }

  static void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    MediaKit.ensureInitialized();
    _initialized = true;
  }

  void _emit(PlayerSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }
}
