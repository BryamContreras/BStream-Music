import 'dart:async';
import 'dart:io';

import '../../../../../services/player/player_service.dart';
import '../../../domain/entities/track_info.dart';
import 'playback_identity.dart';

class RemotePrefetchEntry {
  const RemotePrefetchEntry({
    required this.index,
    required this.track,
    required this.queueEntryId,
  });

  final int index;
  final TrackInfo track;
  final String queueEntryId;
}

class RemotePrefetchPlan {
  const RemotePrefetchPlan({
    required this.currentQueueEntryId,
    required this.currentIdentity,
    required this.upcoming,
    required this.cacheWindow,
  });

  final String currentQueueEntryId;
  final String currentIdentity;
  final List<RemotePrefetchEntry> upcoming;
  final List<TrackInfo> cacheWindow;

  String get signature => <String>[
    currentQueueEntryId,
    currentIdentity,
    for (final entry in upcoming) ...<String>[
      entry.queueEntryId,
      PlaybackIdentity.remoteTrack(entry.track),
    ],
  ].join('\u0000');
}

/// Produces the bounded logical window that cache and native queues share.
abstract final class RemotePrefetchPlanner {
  static RemotePrefetchPlan? build({
    required List<TrackInfo?> queue,
    required int currentIndex,
    required int queueGeneration,
    List<String?>? queueEntryIds,
    required bool shuffleEnabled,
    required List<int> shufflePlan,
    required PlaybackRepeatMode repeatMode,
    required TrackInfo? actualPreviousTrack,
    int depth = 3,
  }) {
    if (currentIndex < 0 ||
        currentIndex >= queue.length ||
        queue[currentIndex] == null) {
      return null;
    }
    final current = queue[currentIndex]!;
    String queueEntryIdFor(int index) {
      if (queueEntryIds != null && index >= 0 && index < queueEntryIds.length) {
        final stableId = queueEntryIds[index]?.trim();
        if (stableId != null && stableId.isNotEmpty) {
          return stableId;
        }
      }
      return PlaybackIdentity.remoteQueueEntry(queueGeneration, index);
    }

    final currentEntryId = queueEntryIdFor(currentIndex);
    final upcoming = <RemotePrefetchEntry>[];
    if (queue.length > 1 && repeatMode != PlaybackRepeatMode.one) {
      if (shuffleEnabled) {
        for (final index in shufflePlan.take(depth)) {
          if (index < 0 || index >= queue.length || queue[index] == null) {
            break;
          }
          upcoming.add(
            RemotePrefetchEntry(
              index: index,
              track: queue[index]!,
              queueEntryId: queueEntryIdFor(index),
            ),
          );
        }
      } else {
        for (
          var offset = 1;
          offset < queue.length && upcoming.length < depth;
          offset++
        ) {
          var index = currentIndex + offset;
          if (index >= queue.length) {
            if (repeatMode != PlaybackRepeatMode.all) {
              break;
            }
            index %= queue.length;
          }
          final track = queue[index];
          if (track == null) {
            break;
          }
          upcoming.add(
            RemotePrefetchEntry(
              index: index,
              track: track,
              queueEntryId: queueEntryIdFor(index),
            ),
          );
        }
      }
    }

    TrackInfo? previous = actualPreviousTrack;
    if (previous == null ||
        PlaybackIdentity.remoteTrack(previous) ==
            PlaybackIdentity.remoteTrack(current)) {
      if (queue.length > 1) {
        final previousIndex = currentIndex > 0
            ? currentIndex - 1
            : queue.length - 1;
        previous = queue[previousIndex];
      } else {
        previous = null;
      }
    }

    final cacheWindow = <TrackInfo>[];
    final identities = <String>{};
    void retain(TrackInfo? track) {
      if (track != null &&
          identities.add(PlaybackIdentity.remoteTrack(track))) {
        cacheWindow.add(track);
      }
    }

    retain(current);
    for (final entry in upcoming) {
      retain(entry.track);
    }
    retain(previous);
    return RemotePrefetchPlan(
      currentQueueEntryId: currentEntryId,
      currentIdentity: PlaybackIdentity.remoteTrack(current),
      upcoming: List<RemotePrefetchEntry>.unmodifiable(upcoming),
      cacheWindow: List<TrackInfo>.unmodifiable(cacheWindow),
    );
  }
}

/// Owns invalidation and duplicate suppression for remote queue prefetches.
///
/// Network/cache work remains supplied by the caller; this component is the
/// single authority deciding whether an asynchronous prefetch still belongs
/// to the active logical queue window.
class RemotePrefetchCoordinator {
  String? _signature;
  Future<void> _serviceMutationTail = Future<void>.value();

  String? get signature => _signature;

  void invalidate() {
    _signature = null;
  }

  bool begin(String signature) {
    if (_signature == signature) {
      return false;
    }
    _signature = signature;
    return true;
  }

  bool isCurrent(String signature) => _signature == signature;

  void invalidateIfCurrent(String signature) {
    if (_signature == signature) {
      _signature = null;
    }
  }

  Future<void> prepare({
    required RemotePrefetchPlan plan,
    required bool cacheEnabled,
    required bool Function() isCurrent,
    required Future<void> Function(List<TrackInfo> tracks) retainOnlyTracks,
    required Future<File?> Function(TrackInfo track) cachedFile,
    required Future<File?> Function(TrackInfo track) warmResolved,
    required Future<TrackInfo> Function(
      TrackInfo track,
      bool Function() shouldContinue,
    )
    resolve,
    required RemotePlaybackSource Function(TrackInfo track, int queueIndex)
    networkSource,
    required PlayerService service,
    Future<void> Function(CrossfadePlaybackSource? source)? prepareCrossfade,
  }) async {
    if (!cacheEnabled) {
      invalidate();
      return;
    }
    if (!isCurrent()) {
      return;
    }

    // Protection and cancellation happen synchronously inside the cache.
    unawaited(retainOnlyTracks(plan.cacheWindow));
    if (!isCurrent()) {
      return;
    }
    final nativeService = service is NativeRemoteQueuePlayer
        ? service as NativeRemoteQueuePlayer
        : null;
    final crossfadePreparer =
        prepareCrossfade ??
        (service is CrossfadeCapablePlayer
            ? (source) =>
                  (service as CrossfadeCapablePlayer).prepareCrossfade(source)
            : null);
    final activeSignature = plan.signature;
    if (!begin(activeSignature)) {
      return;
    }
    bool current() => isCurrent() && this.isCurrent(activeSignature);

    if (plan.upcoming.isEmpty) {
      await _mutateServiceIfCurrent(current, () async {
        if (crossfadePreparer != null) {
          await crossfadePreparer(null);
        }
        if (!current()) {
          return;
        }
        await nativeService?.updateRemoteQueue(const <RemotePlaybackSource>[]);
      });
      return;
    }

    var completed = true;
    final preparedSources = <RemotePlaybackSource>[];
    final warmups = <({int sourceIndex, Future<File?> future})>[];
    for (final entry in plan.upcoming) {
      try {
        final existing = await cachedFile(entry.track);
        if (!current()) {
          return;
        }
        RemotePlaybackSource source;
        if (existing != null) {
          source = RemotePlaybackSource(
            track: entry.track,
            uri: existing.uri,
            queueEntryId: entry.queueEntryId,
          );
        } else {
          final resolved = await resolve(entry.track, current);
          if (!current()) {
            return;
          }
          source = networkSource(resolved, entry.index);
          warmups.add((
            sourceIndex: preparedSources.length,
            future: warmResolved(resolved),
          ));
        }
        preparedSources.add(source);
        if (preparedSources.length == 1 && crossfadePreparer != null) {
          await _mutateServiceIfCurrent(
            current,
            () => crossfadePreparer(RemoteCrossfadePlaybackSource(source)),
          );
          if (!current()) {
            return;
          }
        }
        if (nativeService != null) {
          await _mutateServiceIfCurrent(
            current,
            () => nativeService.updateRemoteQueue(
              preparedSources,
              finalize: false,
            ),
          );
        }
        if (!current()) {
          return;
        }
      } catch (_) {
        completed = false;
        break;
      }
    }

    if (nativeService != null &&
        completed &&
        preparedSources.length == plan.upcoming.length &&
        current()) {
      try {
        await _mutateServiceIfCurrent(
          current,
          () => nativeService.updateRemoteQueue(preparedSources),
        );
      } catch (_) {
        completed = false;
      }
    }

    for (final warmup in warmups) {
      try {
        final cached = await warmup.future;
        if (!current()) {
          return;
        }
        if (cached == null) {
          completed = false;
          continue;
        }
        if (nativeService != null) {
          final previous = preparedSources[warmup.sourceIndex];
          preparedSources[warmup.sourceIndex] = RemotePlaybackSource(
            track: previous.track,
            uri: cached.uri,
            queueEntryId: previous.queueEntryId,
            isOnlyLogicalQueueItem: previous.isOnlyLogicalQueueItem,
          );
          await _mutateServiceIfCurrent(
            current,
            () => nativeService.updateRemoteQueue(preparedSources),
          );
          if (!current()) {
            return;
          }
        }
      } catch (_) {
        completed = false;
      }
    }
    if (!completed && current()) {
      if (preparedSources.isEmpty && crossfadePreparer != null) {
        await _mutateServiceIfCurrent(current, () => crossfadePreparer(null));
      }
      invalidateIfCurrent(activeSignature);
    }
  }

  Future<void> _mutateServiceIfCurrent(
    bool Function() isCurrent,
    Future<void> Function() mutation,
  ) {
    final previous = _serviceMutationTail;
    final operation = () async {
      await previous;
      if (isCurrent()) {
        await mutation();
      }
    }();
    _serviceMutationTail = operation.catchError((Object _) {});
    return operation;
  }
}
