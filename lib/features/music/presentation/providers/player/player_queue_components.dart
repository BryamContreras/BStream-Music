// The public setters are the deliberate mutation boundary around the queue
// state machine; keeping the fields private prevents bypassing its helpers.
// ignore_for_file: unnecessary_getters_setters

part of '../music_providers.dart';

final playerControllerProvider =
    AsyncNotifierProvider<PlayerController, PlayerSnapshot>(
      PlayerController.new,
    );

final playbackQueueProvider =
    NotifierProvider<PlaybackQueueNotifier, PlaybackQueueState>(
      PlaybackQueueNotifier.new,
    );

final playerActionFailureProvider =
    NotifierProvider<PlayerActionFailureNotifier, PlayerActionFailure?>(
      PlayerActionFailureNotifier.new,
    );

class PlayerActionFailure {
  const PlayerActionFailure({
    required this.action,
    required this.error,
    required this.stackTrace,
  });

  final String action;
  final Object error;
  final StackTrace stackTrace;
}

class PlayerActionFailureNotifier extends Notifier<PlayerActionFailure?> {
  @override
  PlayerActionFailure? build() => null;

  void report(PlayerActionFailure failure) {
    state = failure;
  }

  void clear() {
    state = null;
  }
}

class PlaybackQueueEntry {
  const PlaybackQueueEntry({
    required this.id,
    required this.title,
    required this.artist,
    required this.isRemote,
    this.logicalEntryId,
    this.album,
    this.thumbnailUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String? album;
  final String? thumbnailUrl;
  final bool isRemote;
  final String? logicalEntryId;
}

class PlaybackQueueState {
  const PlaybackQueueState({this.entries = const [], this.currentIndex = -1});

  final List<PlaybackQueueEntry> entries;
  final int currentIndex;
}

class PlaybackQueueNotifier extends Notifier<PlaybackQueueState> {
  @override
  PlaybackQueueState build() => const PlaybackQueueState();

  void replace(List<PlaybackQueueEntry> entries, int currentIndex) {
    state = PlaybackQueueState(
      entries: List.unmodifiable(entries),
      currentIndex: currentIndex,
    );
  }
}

class _QueueItem {
  const _QueueItem.remote(
    this.remote, {
    this.remoteQueueEntryId,
    this.logicalEntryId,
  }) : local = null;

  const _QueueItem.local(this.local, {this.logicalEntryId})
    : remote = null,
      remoteQueueEntryId = null;

  const _QueueItem.hybrid({
    required this.local,
    required this.remote,
    this.remoteQueueEntryId,
    this.logicalEntryId,
  }) : assert(local != null),
       assert(remote != null);

  final TrackInfo? remote;
  final LocalTrack? local;
  final String? remoteQueueEntryId;
  final String? logicalEntryId;

  String get id {
    final stableId = logicalEntryId?.trim();
    if (stableId != null && stableId.isNotEmpty) {
      return stableId;
    }
    final remoteTrack = remote;
    if (remoteTrack != null) {
      return remoteTrack.id.isEmpty ? remoteTrack.url : remoteTrack.id;
    }
    return local?.id ?? '';
  }

  PlaybackQueueEntry get presentation {
    final localTrack = local;
    if (localTrack != null) {
      return PlaybackQueueEntry(
        id: localTrack.id,
        title: localTrack.title,
        artist: localTrack.artist,
        album: localTrack.album,
        thumbnailUrl: localTrack.thumbnailPath ?? localTrack.thumbnailUrl,
        isRemote: false,
        logicalEntryId: logicalEntryId,
      );
    }

    final remoteTrack = remote!;
    return PlaybackQueueEntry(
      id: remoteTrack.id.isEmpty ? remoteTrack.url : remoteTrack.id,
      title: remoteTrack.title,
      artist: remoteTrack.artist,
      album: remoteTrack.album,
      thumbnailUrl: remoteTrack.thumbnailUrl,
      isRemote: true,
      logicalEntryId: logicalEntryId,
    );
  }

  _QueueItem withRemoteQueueEntryId(String entryId) {
    final localTrack = local;
    final remoteTrack = remote;
    if (localTrack != null && remoteTrack != null) {
      return _QueueItem.hybrid(
        local: localTrack,
        remote: remoteTrack,
        remoteQueueEntryId: entryId,
        logicalEntryId: logicalEntryId,
      );
    }
    if (remoteTrack != null) {
      return _QueueItem.remote(
        remoteTrack,
        remoteQueueEntryId: entryId,
        logicalEntryId: logicalEntryId,
      );
    }
    return this;
  }

  _QueueItem withRemoteTrack(TrackInfo track) {
    final localTrack = local;
    if (localTrack != null) {
      return _QueueItem.hybrid(
        local: localTrack,
        remote: track,
        remoteQueueEntryId: remoteQueueEntryId,
        logicalEntryId: logicalEntryId,
      );
    }
    return _QueueItem.remote(
      track,
      remoteQueueEntryId: remoteQueueEntryId,
      logicalEntryId: logicalEntryId,
    );
  }

  _QueueItem withoutLocal() {
    final remoteTrack = remote;
    if (remoteTrack == null) {
      return this;
    }
    return _QueueItem.remote(
      remoteTrack,
      remoteQueueEntryId: remoteQueueEntryId,
      logicalEntryId: logicalEntryId,
    );
  }
}

/// Owns the mutable logical queue and the shuffle navigation state.
///
/// This class deliberately knows nothing about Riverpod or an audio backend.
/// A controller can replace/reorder items and ask for the next logical index;
/// the component guarantees that shuffle history and its rolling look-ahead
/// plan remain consistent with the current queue.
class QueueNavigationState<T> {
  QueueNavigationState({math.Random? random, this.lookAheadDepth = 3})
    : _random = random ?? math.Random();

  final math.Random _random;
  final int lookAheadDepth;

  List<T> _items = <T>[];
  int _currentIndex = -1;
  bool _shuffleEnabled = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;
  Set<int> _playedIndices = <int>{};
  List<int> _shufflePlan = <int>[];

  List<T> get items => _items;
  int get currentIndex => _currentIndex;
  bool get shuffleEnabled => _shuffleEnabled;
  PlaybackRepeatMode get repeatMode => _repeatMode;
  Set<int> get playedIndices => Set<int>.unmodifiable(_playedIndices);
  List<int> get shufflePlan => List<int>.unmodifiable(_shufflePlan);

  // These setters are the mutation boundary used by PlayerController while
  // the corresponding fields remain private to this state machine.
  set currentIndex(int value) => _currentIndex = value;
  set shuffleEnabled(bool value) => _shuffleEnabled = value;
  set repeatMode(PlaybackRepeatMode value) => _repeatMode = value;

  void replaceItems(List<T> items) {
    _items = List<T>.unmodifiable(items);
  }

  void restoreShuffleState({
    required Iterable<int> playedIndices,
    required Iterable<int> plan,
  }) {
    _playedIndices = Set<int>.of(playedIndices);
    _shufflePlan = List<int>.of(plan);
  }

  bool reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _items.length ||
        newIndex < 0 ||
        newIndex >= _items.length ||
        oldIndex == newIndex ||
        _items.length < 2) {
      return false;
    }

    final nextItems = List<T>.of(_items);
    final moved = nextItems.removeAt(oldIndex);
    nextItems.insert(newIndex, moved);
    if (_currentIndex == oldIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex++;
    }
    _items = List<T>.unmodifiable(nextItems);
    resetShuffleHistory();
    return true;
  }

  int previousIndex() {
    if (_items.isEmpty) {
      return -1;
    }
    return _currentIndex <= 0 ? _items.length - 1 : _currentIndex - 1;
  }

  int nextIndex({required bool automatic}) {
    if (_items.length <= 1) {
      if (automatic && _repeatMode == PlaybackRepeatMode.off) {
        return -1;
      }
      return _items.isEmpty ? -1 : 0;
    }

    if (_shuffleEnabled) {
      return _nextShuffleIndex(automatic: automatic);
    }
    if (_currentIndex >= _items.length - 1) {
      if (automatic && _repeatMode == PlaybackRepeatMode.off) {
        return -1;
      }
      return 0;
    }
    return _currentIndex + 1;
  }

  int _nextShuffleIndex({required bool automatic}) {
    ensureShufflePlan();
    if (_shufflePlan.isNotEmpty) {
      return _shufflePlan.removeAt(0);
    }
    if (automatic && _repeatMode == PlaybackRepeatMode.off) {
      return -1;
    }

    resetShuffleHistory();
    ensureShufflePlan();
    return _shufflePlan.isEmpty ? _currentIndex : _shufflePlan.removeAt(0);
  }

  void ensureShufflePlan() {
    if (!_shuffleEnabled || _items.length < 2) {
      _shufflePlan = <int>[];
      return;
    }
    _shufflePlan.removeWhere(
      (index) =>
          index < 0 ||
          index >= _items.length ||
          index == _currentIndex ||
          _playedIndices.contains(index),
    );

    final targetDepth = math.min(lookAheadDepth, _items.length - 1);
    while (_shufflePlan.length < targetDepth) {
      final candidates = [
        for (var index = 0; index < _items.length; index++)
          if (index != _currentIndex &&
              !_playedIndices.contains(index) &&
              !_shufflePlan.contains(index))
            index,
      ];
      if (candidates.isEmpty) {
        if (_repeatMode != PlaybackRepeatMode.all) {
          return;
        }
        _playedIndices = {_currentIndex};
        continue;
      }
      _shufflePlan.add(candidates[_random.nextInt(candidates.length)]);
    }
  }

  void resetShuffleHistory() {
    _playedIndices = <int>{};
    _shufflePlan = <int>[];
    markCurrentIndexPlayed();
  }

  void markCurrentIndexPlayed() {
    if (_currentIndex >= 0 && _currentIndex < _items.length) {
      _playedIndices.add(_currentIndex);
    }
    _shufflePlan.removeWhere((index) => index == _currentIndex);
  }
}
