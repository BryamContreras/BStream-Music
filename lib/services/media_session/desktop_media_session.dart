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
    this.album,
    this.thumbnailUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String? album;
  final String? thumbnailUrl;
}

/// Immutable system-session metadata, prepared when the logical queue changes.
/// Position updates can reuse both the entries and their fingerprint.
class DesktopMediaQueue {
  DesktopMediaQueue(Iterable<DesktopMediaQueueItem> entries)
    : items = List<DesktopMediaQueueItem>.unmodifiable(entries) {
    fingerprint = _fingerprintQueue(items);
  }

  final List<DesktopMediaQueueItem> items;
  late final int fingerprint;
}

int _fingerprintQueue(List<DesktopMediaQueueItem> queue) => Object.hashAll(
  queue.map(
    (item) => Object.hash(
      item.id,
      item.title,
      item.artist,
      item.album,
      item.thumbnailUrl,
    ),
  ),
);

class DesktopMediaSessionState {
  const DesktopMediaSessionState({
    required this.snapshot,
    required this.queue,
    required this.currentIndex,
  }) : _queueFingerprint = null;

  DesktopMediaSessionState.withQueue({
    required this.snapshot,
    required DesktopMediaQueue queue,
    required this.currentIndex,
  }) : queue = queue.items,
       _queueFingerprint = queue.fingerprint;

  final PlayerSnapshot snapshot;
  final List<DesktopMediaQueueItem> queue;
  final int currentIndex;
  final int? _queueFingerprint;

  String get queueKey =>
      '$currentIndex:${_queueFingerprint ?? _fingerprintQueue(queue)}';

  bool get hasPrevious => queue.length > 1 && currentIndex >= 0;

  bool get hasNext => queue.length > 1 && currentIndex >= 0;
}

abstract class DesktopMediaSession {
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks);

  Future<void> update(DesktopMediaSessionState state);

  Future<void> dispose();
}
