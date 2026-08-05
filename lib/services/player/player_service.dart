import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';

enum PlayerStatus { idle, loading, playing, paused, stopped, failed }

enum PlaybackRepeatMode { off, all, one }

class PlayerSnapshot {
  const PlayerSnapshot({
    required this.status,
    this.title,
    this.artist,
    this.album,
    this.trackId,
    this.sourceUrl,
    this.thumbnailUrl,
    this.position = Duration.zero,
    this.duration,
    this.volume = 1,
    this.errorMessage,
    this.isRemote = false,
    this.shuffleEnabled = false,
    this.repeatMode = PlaybackRepeatMode.off,
  });

  final PlayerStatus status;
  final String? title;
  final String? artist;
  final String? album;
  final String? trackId;
  final String? sourceUrl;
  final String? thumbnailUrl;
  final Duration position;
  final Duration? duration;
  final double volume;
  final String? errorMessage;
  final bool isRemote;
  final bool shuffleEnabled;
  final PlaybackRepeatMode repeatMode;

  PlayerSnapshot copyWith({
    PlayerStatus? status,
    String? title,
    String? artist,
    String? album,
    String? trackId,
    String? sourceUrl,
    String? thumbnailUrl,
    Duration? position,
    Duration? duration,
    double? volume,
    String? errorMessage,
    bool? isRemote,
    bool? shuffleEnabled,
    PlaybackRepeatMode? repeatMode,
  }) {
    return PlayerSnapshot(
      status: status ?? this.status,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      trackId: trackId ?? this.trackId,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      errorMessage: errorMessage ?? this.errorMessage,
      isRemote: isRemote ?? this.isRemote,
      shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
      repeatMode: repeatMode ?? this.repeatMode,
    );
  }
}

abstract class PlayerService {
  Stream<PlayerSnapshot> get snapshotStream;
  PlayerSnapshot get currentSnapshot;

  /// Whether this backend can update an already loaded local playlist without
  /// reopening the current track.
  bool get supportsLocalQueueReplacement;

  Future<void> playRemote(TrackInfo track);
  Future<void> playLocal(LocalTrack track);
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex);

  /// Replaces the loaded local queue while retaining the current item when it
  /// is still present. [preferredIndex] is used if that item was removed.
  Future<void> replaceLocalQueue(List<LocalTrack> tracks, int preferredIndex);
  Future<void> pause();
  Future<void> resume();
  Future<void> togglePlayPause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setShuffleEnabled(bool enabled);
  Future<void> setRepeatMode(PlaybackRepeatMode mode);
  Future<void> dispose();
}
