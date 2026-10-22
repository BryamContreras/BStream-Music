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
    for (final track in cacheWindow) PlaybackIdentity.remoteTrack(track),
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
  RemotePrefetchCoordinator({
    DateTime Function()? clock,
    this.maxAutomaticRetries = 2,
    this.additionalWarmupDelay = const Duration(seconds: 20),
  }) : _clock = clock ?? DateTime.now,
       assert(maxAutomaticRetries >= 0),
       assert(additionalWarmupDelay >= Duration.zero);

  final DateTime Function() _clock;
  final int maxAutomaticRetries;

  /// Native URLs and NEXT remain immediate. Only optional full-file transfers
  /// for the second/third successor wait, leaving the audible stream room.
  final Duration additionalWarmupDelay;
  String? _signature;
  String? _failedSignature;
  DateTime? _retryAfter;
  int _failureCount = 0;
  int _generation = 0;
  bool _disposed = false;
  Timer? _retryTimer;
  Timer? _warmupDelayTimer;
  Completer<bool>? _warmupDelayCompletion;
  Future<void> _serviceMutationTail = Future<void>.value();

  String? get signature => _signature;

  void invalidate() {
    _generation++;
    _cancelWarmupDelay();
    _retryTimer?.cancel();
    _retryTimer = null;
    _signature = null;
    _failedSignature = null;
    _retryAfter = null;
    _failureCount = 0;
  }

  bool begin(String signature) {
    if (_disposed || _signature == signature) {
      return false;
    }
    if (_failedSignature == signature &&
        _retryAfter != null &&
        _clock().isBefore(_retryAfter!)) {
      return false;
    }
    if (_failedSignature != signature) {
      _failureCount = 0;
      _failedSignature = null;
      _retryAfter = null;
    }
    _generation++;
    _cancelWarmupDelay();
    _retryTimer?.cancel();
    _retryTimer = null;
    _signature = signature;
    return true;
  }

  bool isCurrent(String signature) => !_disposed && _signature == signature;

  void invalidateIfCurrent(String signature) {
    if (_signature == signature) {
      _generation++;
      _cancelWarmupDelay();
      _retryTimer?.cancel();
      _retryTimer = null;
      _signature = null;
      _failedSignature = signature;
      _failureCount++;
      _retryAfter = _clock().add(
        Duration(
          seconds: (5 * (1 << (_failureCount - 1).clamp(0, 4))).clamp(5, 60),
        ),
      );
    }
  }

  void dispose() {
    _disposed = true;
    invalidate();
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
    void Function(RemotePlaybackSource source)? onSourcePrepared,
    required PlayerService service,
    Future<void> Function(CrossfadePlaybackSource? source)? prepareCrossfade,
  }) async {
    if (_disposed || !isCurrent()) {
      return;
    }

    final activeSignature = plan.signature;
    if (!begin(activeSignature)) {
      return;
    }

    final generation = _generation;
    final nativeService = service is NativeRemoteQueuePlayer
        ? service as NativeRemoteQueuePlayer
        : null;
    final crossfadePreparer =
        prepareCrossfade ??
        (service is CrossfadeCapablePlayer
            ? (source) =>
                  (service as CrossfadeCapablePlayer).prepareCrossfade(source)
            : null);
    bool current() =>
        generation == _generation &&
        isCurrent() &&
        this.isCurrent(activeSignature);

    void retryAfterFailure() {
      if (!current()) return;
      invalidateIfCurrent(activeSignature);
      if (_failureCount > maxAutomaticRetries) return;
      final retryGeneration = _generation;
      final delay = _retryAfter!.difference(_clock());
      _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
        _retryTimer = null;
        if (_disposed ||
            retryGeneration != _generation ||
            _failedSignature != activeSignature ||
            !isCurrent()) {
          return;
        }
        // A bounded number of delayed attempts for this logical window. No
        // position snapshot or periodic poll is needed to refill a failed queue.
        unawaited(
          prepare(
            plan: plan,
            cacheEnabled: cacheEnabled,
            isCurrent: isCurrent,
            retainOnlyTracks: retainOnlyTracks,
            cachedFile: cachedFile,
            warmResolved: warmResolved,
            resolve: resolve,
            networkSource: networkSource,
            onSourcePrepared: onSourcePrepared,
            service: service,
            prepareCrossfade: prepareCrossfade,
          ),
        );
      });
    }

    Future<void>? retention;
    var retentionFailed = false;
    if (cacheEnabled) {
      // Protection and cancellation happen synchronously inside the cache.
      // Native lookahead must not depend on persistent audio caching being on.
      retention = Future<void>.sync(() => retainOnlyTracks(plan.cacheWindow))
          .catchError((Object _) {
            retentionFailed = true;
          });
      if (!current()) return;
    }

    if (plan.upcoming.isEmpty) {
      try {
        await _mutateServiceIfCurrent(current, () async {
          if (crossfadePreparer != null) {
            await crossfadePreparer(null);
          }
          if (!current()) {
            return;
          }
          await nativeService?.updateRemoteQueue(
            const <RemotePlaybackSource>[],
          );
        });
        await retention;
        if (retentionFailed) retryAfterFailure();
      } catch (_) {
        retryAfterFailure();
      }
      return;
    }

    // With caching off, prepare just the immediate successor for background
    // continuity. Do not read/download cache files or resolve an entire batch.
    final upcoming = cacheEnabled
        ? plan.upcoming
        : plan.upcoming.take(1).toList(growable: false);
    if (!cacheEnabled && nativeService == null && crossfadePreparer == null) {
      return;
    }

    var completed = true;
    final preparedSources = <RemotePlaybackSource>[];
    final warmups = <({int sourceIndex, TrackInfo track})>[];
    Future<bool>? immediateWarmup;
    var sourcesFinalized = false;

    Future<bool> warmAndPublish(
      ({int sourceIndex, TrackInfo track}) warmup,
    ) async {
      try {
        if (!current()) return false;
        final cached = await warmResolved(warmup.track);
        if (!current() || cached == null) return false;
        if (nativeService != null) {
          final previous = preparedSources[warmup.sourceIndex];
          preparedSources[warmup.sourceIndex] = RemotePlaybackSource(
            track: previous.track,
            uri: cached.uri,
            queueEntryId: previous.queueEntryId,
            isOnlyLogicalQueueItem: previous.isOnlyLogicalQueueItem,
          );
          onSourcePrepared?.call(preparedSources[warmup.sourceIndex]);
          await _mutateServiceIfCurrent(
            current,
            () => nativeService.updateRemoteQueue(
              List<RemotePlaybackSource>.unmodifiable(preparedSources),
              finalize: sourcesFinalized,
            ),
          );
        }
        return current();
      } catch (_) {
        return false;
      }
    }

    for (final entry in upcoming) {
      try {
        final existing = cacheEnabled ? await cachedFile(entry.track) : null;
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
          if (cacheEnabled) {
            warmups.add((sourceIndex: preparedSources.length, track: resolved));
          }
        }
        preparedSources.add(source);
        onSourcePrepared?.call(source);
        // Enqueue the successor before loading the optional standby deck. A
        // slow crossfade preparation must not leave the native queue empty.
        if (nativeService != null) {
          await _mutateServiceIfCurrent(
            current,
            () => nativeService.updateRemoteQueue(
              List<RemotePlaybackSource>.unmodifiable(preparedSources),
              finalize: false,
            ),
          );
          if (!current()) return;
        }
        if (preparedSources.length == 1 && warmups.isNotEmpty) {
          // Start NEXT's full transfer now. A slow later resolver or optional
          // standby deck must not hold it behind the rest of the lookahead.
          // Publishing uses the same service gate and immutable snapshots.
          immediateWarmup = warmAndPublish(warmups.first);
        }
        if (preparedSources.length == 1 && crossfadePreparer != null) {
          await _mutateServiceIfCurrent(
            current,
            () => crossfadePreparer(RemoteCrossfadePlaybackSource(source)),
          );
          if (!current()) {
            return;
          }
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
        preparedSources.length == upcoming.length &&
        current()) {
      try {
        await _mutateServiceIfCurrent(current, () async {
          await nativeService.updateRemoteQueue(
            List<RemotePlaybackSource>.unmodifiable(preparedSources),
          );
          sourcesFinalized = true;
        });
      } catch (_) {
        completed = false;
      }
    }

    for (final warmup in warmups) {
      try {
        if (!current()) return;
        if (warmup.sourceIndex == 0) {
          final warmed = await (immediateWarmup ?? warmAndPublish(warmup));
          if (!current()) return;
          if (!warmed) {
            completed = false;
            break;
          }
          continue;
        }
        // Retry a failed NEXT/native preparation on its normal backoff, rather
        // than waiting through optional transfers before scheduling the retry.
        if (!completed || retentionFailed) break;
        if (!await _waitForAdditionalWarmup(current)) return;
        final warmed = await warmAndPublish(warmup);
        if (!current()) return;
        if (!warmed) {
          completed = false;
          break;
        }
      } catch (_) {
        completed = false;
      }
    }
    await retention;
    if (retentionFailed) completed = false;
    if (!completed && current()) {
      if (preparedSources.isEmpty && crossfadePreparer != null) {
        try {
          await _mutateServiceIfCurrent(current, () => crossfadePreparer(null));
        } catch (_) {
          // A failed standby cleanup must not prevent the bounded queue retry.
        }
      }
      retryAfterFailure();
    } else if (completed && current()) {
      _failedSignature = null;
      _retryAfter = null;
      _failureCount = 0;
    }
  }

  Future<bool> _waitForAdditionalWarmup(bool Function() isCurrent) {
    if (additionalWarmupDelay == Duration.zero) {
      return Future<bool>.value(isCurrent());
    }
    if (!isCurrent()) return Future<bool>.value(false);
    _cancelWarmupDelay();
    final completion = Completer<bool>();
    _warmupDelayCompletion = completion;
    _warmupDelayTimer = Timer(additionalWarmupDelay, () {
      if (!identical(_warmupDelayCompletion, completion)) return;
      _warmupDelayTimer = null;
      _warmupDelayCompletion = null;
      completion.complete(isCurrent());
    });
    return completion.future;
  }

  void _cancelWarmupDelay() {
    _warmupDelayTimer?.cancel();
    _warmupDelayTimer = null;
    final completion = _warmupDelayCompletion;
    _warmupDelayCompletion = null;
    if (completion != null && !completion.isCompleted) {
      completion.complete(false);
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
