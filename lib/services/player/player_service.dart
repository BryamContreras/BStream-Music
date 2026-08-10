import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';

enum PlayerStatus { idle, loading, playing, paused, stopped, failed }

enum PlaybackRepeatMode { off, all, one }

const _unsetPlayerSnapshotValue = Object();

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
    this.isExternal = false,
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
  final bool isExternal;
  final bool shuffleEnabled;
  final PlaybackRepeatMode repeatMode;

  PlayerSnapshot copyWith({
    PlayerStatus? status,
    Object? title = _unsetPlayerSnapshotValue,
    Object? artist = _unsetPlayerSnapshotValue,
    Object? album = _unsetPlayerSnapshotValue,
    Object? trackId = _unsetPlayerSnapshotValue,
    Object? sourceUrl = _unsetPlayerSnapshotValue,
    Object? thumbnailUrl = _unsetPlayerSnapshotValue,
    Duration? position,
    Object? duration = _unsetPlayerSnapshotValue,
    double? volume,
    Object? errorMessage = _unsetPlayerSnapshotValue,
    bool? isRemote,
    bool? isExternal,
    bool? shuffleEnabled,
    PlaybackRepeatMode? repeatMode,
  }) {
    return PlayerSnapshot(
      status: status ?? this.status,
      title: identical(title, _unsetPlayerSnapshotValue)
          ? this.title
          : title as String?,
      artist: identical(artist, _unsetPlayerSnapshotValue)
          ? this.artist
          : artist as String?,
      album: identical(album, _unsetPlayerSnapshotValue)
          ? this.album
          : album as String?,
      trackId: identical(trackId, _unsetPlayerSnapshotValue)
          ? this.trackId
          : trackId as String?,
      sourceUrl: identical(sourceUrl, _unsetPlayerSnapshotValue)
          ? this.sourceUrl
          : sourceUrl as String?,
      thumbnailUrl: identical(thumbnailUrl, _unsetPlayerSnapshotValue)
          ? this.thumbnailUrl
          : thumbnailUrl as String?,
      position: position ?? this.position,
      duration: identical(duration, _unsetPlayerSnapshotValue)
          ? this.duration
          : duration as Duration?,
      volume: volume ?? this.volume,
      errorMessage: identical(errorMessage, _unsetPlayerSnapshotValue)
          ? this.errorMessage
          : errorMessage as String?,
      isRemote: isRemote ?? this.isRemote,
      isExternal: isExternal ?? this.isExternal,
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
