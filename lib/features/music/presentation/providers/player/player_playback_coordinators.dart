part of '../music_providers.dart';

/// Assigns durable ids to logical remote queue entries.
///
/// Ids follow entries when a queue is reordered or reconciled. This prevents
/// a native snapshot emitted by an already loaded source from being mistaken
/// for whichever item later occupies its old numeric index.
class _RemoteQueueEntryIdentityCoordinator {
  int _generation = 0;
  int _sequence = 0;

  int get generation => _generation;

  void beginGeneration() {
    _generation++;
    _sequence = 0;
  }

  void invalidate() {
    _generation++;
  }

  String entryIdAt(List<_QueueItem> queue, int index) {
    if (index >= 0 && index < queue.length) {
      final stableId = queue[index].remoteQueueEntryId?.trim();
      if (stableId != null && stableId.isNotEmpty) {
        return stableId;
      }
    }
    return PlaybackIdentity.remoteQueueEntry(_generation, index);
  }

  _QueueItem newRemoteItem(TrackInfo track) {
    return _QueueItem.remote(
      track,
      remoteQueueEntryId: PlaybackIdentity.remoteQueueEntry(
        _generation,
        _sequence++,
      ),
    );
  }

  List<_QueueItem> reconcile(
    List<_QueueItem> incoming, {
    required List<_QueueItem> previousQueue,
  }) {
    final usedPreviousIndices = <int>{};
    final reconciled = <_QueueItem>[];
    for (var index = 0; index < incoming.length; index++) {
      final candidate = incoming[index];
      final remote = candidate.remote;
      if (remote == null) {
        reconciled.add(candidate);
        continue;
      }

      var matchedIndex = -1;
      final samePosition = index < previousQueue.length
          ? previousQueue[index].remote
          : null;
      if (samePosition != null &&
          PlaybackIdentity.sameRemoteTrack(samePosition, remote)) {
        matchedIndex = index;
      } else {
        for (
          var previousIndex = 0;
          previousIndex < previousQueue.length;
          previousIndex++
        ) {
          if (usedPreviousIndices.contains(previousIndex)) {
            continue;
          }
          final previous = previousQueue[previousIndex].remote;
          if (previous != null &&
              PlaybackIdentity.sameRemoteTrack(previous, remote)) {
            matchedIndex = previousIndex;
            break;
          }
        }
      }
      if (matchedIndex >= 0 && usedPreviousIndices.add(matchedIndex)) {
        reconciled.add(
          candidate.withRemoteQueueEntryId(
            previousQueue[matchedIndex].remoteQueueEntryId ??
                PlaybackIdentity.remoteQueueEntry(_generation, _sequence++),
          ),
        );
      } else {
        reconciled.add(
          candidate.withRemoteQueueEntryId(
            PlaybackIdentity.remoteQueueEntry(_generation, _sequence++),
          ),
        );
      }
    }
    return List<_QueueItem>.unmodifiable(reconciled);
  }
}

/// Serializes native shuffle/repeat updates and coalesces obsolete requests.
class _PlaybackOptionsSyncCoordinator {
  int _generation = 0;
  Future<void> _tail = Future<void>.value();

  void invalidate() {
    _generation++;
  }

  Future<void> synchronize({
    required bool Function() isDisposed,
    required PlayerService Function() service,
    required bool shuffleEnabled,
    required PlaybackRepeatMode repeatMode,
    required void Function() onSuccess,
    required void Function(Object error, StackTrace stackTrace) onFailure,
  }) {
    final generation = ++_generation;
    final previous = _tail;
    final operation = () async {
      try {
        await previous;
        if (isDisposed() || generation != _generation) {
          return;
        }
        final player = service();
        await player.setShuffleEnabled(shuffleEnabled);
        if (isDisposed() || generation != _generation) {
          return;
        }
        await player.setRepeatMode(repeatMode);
        if (!isDisposed() && generation == _generation) {
          onSuccess();
        }
      } catch (error, stackTrace) {
        if (!isDisposed() && generation == _generation) {
          onFailure(error, stackTrace);
        }
      }
    }();
    _tail = operation;
    return operation;
  }
}

/// Makes the newest crossfade preparation the final backend mutation.
class _CrossfadePreparationCoordinator {
  int _generation = 0;
  Future<void> _tail = Future<void>.value();

  void invalidate() {
    _generation++;
  }

  Future<void> schedule({
    required bool Function() isDisposed,
    required PlayerService Function() service,
    required CrossfadePlaybackSource? source,
    required void Function(Object error, StackTrace stackTrace) onError,
  }) {
    final generation = ++_generation;
    final previous = _tail;
    final operation = () async {
      await previous;
      if (isDisposed() || generation != _generation) {
        return;
      }
      final player = service();
      if (player is! CrossfadeCapablePlayer) {
        return;
      }
      final crossfadePlayer = player as CrossfadeCapablePlayer;
      if (source != null && !crossfadePlayer.crossfadeEnabled) {
        return;
      }
      await crossfadePlayer.prepareCrossfade(source);
    }();
    _tail = operation.catchError((Object error, StackTrace stackTrace) {
      onError(error, stackTrace);
    });
    return _tail;
  }
}
