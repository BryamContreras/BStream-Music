import '../player/player_service.dart';

typedef DesktopMediaAction = Future<void> Function();
typedef DesktopMediaSeekAction = Future<void> Function(Duration position);
typedef DesktopMediaShuffleAction = Future<void> Function(bool enabled);
typedef DesktopMediaRepeatAction =
    Future<void> Function(PlaybackRepeatMode mode);
typedef DesktopMediaQueueAction = Future<void> Function(int index);

class DesktopMediaSessionCallbacks {
  const DesktopMediaSessionCallbacks({
    required this.play,
    required this.pause,
    required this.togglePlayPause,
    required this.next,
    required this.previous,
    required this.stop,
    required this.seek,
    required this.seekBy,
    required this.setShuffleEnabled,
    required this.setRepeatMode,
    required this.playQueueIndex,
  });

  final DesktopMediaAction play;
  final DesktopMediaAction pause;
  final DesktopMediaAction togglePlayPause;
  final DesktopMediaAction next;
  final DesktopMediaAction previous;
  final DesktopMediaAction stop;
  final DesktopMediaSeekAction seek;
  final DesktopMediaSeekAction seekBy;
  final DesktopMediaShuffleAction setShuffleEnabled;
  final DesktopMediaRepeatAction setRepeatMode;
  final DesktopMediaQueueAction playQueueIndex;
}

class DesktopMediaQueueItem {
  const DesktopMediaQueueItem({
    required this.id,
    required this.title,
    required this.artist,
    this.thumbnailUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String? thumbnailUrl;
}

class DesktopMediaSessionState {
  const DesktopMediaSessionState({
    required this.snapshot,
    required this.queue,
    required this.currentIndex,
  });

  final PlayerSnapshot snapshot;
  final List<DesktopMediaQueueItem> queue;
  final int currentIndex;

  String get queueKey =>
      '$currentIndex:${Object.hashAll(queue.map((item) => Object.hash(item.id, item.title, item.artist, item.thumbnailUrl)))}';

  bool get hasPrevious => queue.length > 1 && currentIndex >= 0;

  bool get hasNext => queue.length > 1 && currentIndex >= 0;
}

abstract class DesktopMediaSession {
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks);

  Future<void> update(DesktopMediaSessionState state);

  Future<void> dispose();
}
