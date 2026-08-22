part of 'music_providers.dart';

enum _LocalPlaybackAttempt { played, unavailable, cancelled }

class PlayerController extends AsyncNotifier<PlayerSnapshot> {
  static const _playlistQueueSourcePrefix = 'playlist:';
  static const String liveQueueSourceId = 'tiktok-live';
  static const _remoteCacheTrackIdPrefix =
      PlaybackIdentity.remoteCacheTrackIdPrefix;
  static const _remotePrefetchDepth = 3;
  static const _recommendationQueueExtensionThreshold = 3;

  final QueueNavigationState<_QueueItem> _queueNavigation =
      QueueNavigationState<_QueueItem>(lookAheadDepth: _remotePrefetchDepth);

  List<_QueueItem> get _queue => _queueNavigation.items;
  set _queue(List<_QueueItem> value) => _queueNavigation.replaceItems(value);
  int get _queueIndex => _queueNavigation.currentIndex;
  set _queueIndex(int value) => _queueNavigation.currentIndex = value;
  bool get _shuffleEnabled => _queueNavigation.shuffleEnabled;
  set _shuffleEnabled(bool value) => _queueNavigation.shuffleEnabled = value;
  PlaybackRepeatMode get _repeatMode => _queueNavigation.repeatMode;
  set _repeatMode(PlaybackRepeatMode value) =>
      _queueNavigation.repeatMode = value;
  Set<int> get _shufflePlayedIndices => _queueNavigation.playedIndices;
  List<int> get _shufflePlan => _queueNavigation.shufflePlan;
  bool _handlingCompletion = false;
  int? _changingLocalTrackRequestId;
  bool _explicitlyStopped = false;
  bool _useNativeLocalQueue = true;
  bool _activePlaybackIsRemote = false;
  String? _hybridLocalFallbackEntryId;
  String? _pendingHybridLocalFailureEntryId;
  String? _activeLocalQueueSourceId;
  String? _activeRemoteQueueSourceId;

  bool get isLiveQueueActive =>
      _activeLocalQueueSourceId == liveQueueSourceId ||
      _activeRemoteQueueSourceId == liveQueueSourceId;
  int _playRequestId = 0;
  int _seekRequestId = 0;
  final _PlaybackOptionsSyncCoordinator _playbackOptionsSync =
      _PlaybackOptionsSyncCoordinator();
  final _RemoteQueueEntryIdentityCoordinator _remoteQueueEntries =
      _RemoteQueueEntryIdentityCoordinator();
  final RemotePlaybackRetryCoordinator _remoteRetry =
      RemotePlaybackRetryCoordinator();
  int? _liveTerminalAdvanceScheduledRequestId;
  TrackInfo? _previousRemoteTrackForCache;
  PlayerSnapshot? _pendingRemoteSnapshot;
  QualifiedPlaybackHistoryTracker? _playbackHistoryTracker;
  LocalDatabaseShutdownRegistration? _playbackHistoryShutdownRegistration;
  bool _recommendationHistorySuspended = false;
  final RemotePrefetchCoordinator _remotePrefetch = RemotePrefetchCoordinator();

  Future<void> _crossfadeConfigurationTail = Future<void>.value();
  final _CrossfadePreparationCoordinator _crossfadePreparation =
      _CrossfadePreparationCoordinator();
  Future<void>? _nextNavigationInFlight;
  int _queueNavigationGeneration = 0;
  final RecommendationQueueExtensionCoordinator _recommendationExtension =
      RecommendationQueueExtensionCoordinator();
  bool _disposed = false;

  bool get _changingLocalTrack => _changingLocalTrackRequestId != null;

  @override
  Future<PlayerSnapshot> build() async {
    final service = ref.watch(playerServiceProvider);
    _activePlaybackIsRemote = service.currentSnapshot.isRemote;
    ref.listen<({bool enabled, Duration duration})?>(
      settingsControllerProvider.select((settings) {
        final value = settings.asData?.value;
        return value == null
            ? null
            : (
                enabled: value.crossfadeEnabled,
                duration: value.crossfadeDuration,
              );
      }),
      (previous, next) {
        if (next != null) {
          _scheduleCrossfadeConfiguration(
            enabled: next.enabled,
            duration: next.duration,
            prepareWhenEnabled:
                next.enabled && (previous == null || !previous.enabled),
          );
        }
      },
      fireImmediately: true,
    );
    final initialSnapshot = _decorateSnapshot(service.currentSnapshot);
    final historySink = ref.read(playbackHistorySinkProvider);
    final historyTracker = QualifiedPlaybackHistoryTracker(
      onWrite: (write) async {
        await historySink.persist(write);
        if (!_disposed && write.isInitialQualification) {
          ref
            ..invalidate(historyProvider)
            ..invalidate(homeRecommendationsProvider);
        }
      },
    );
    final historyShutdownRegistration = ref
        .read(localDatabaseShutdownCoordinatorProvider)
        .register(historyTracker.dispose);
    final previousHistoryTracker = _playbackHistoryTracker;
    final previousHistoryShutdownRegistration =
        _playbackHistoryShutdownRegistration;
    _playbackHistoryTracker = historyTracker;
    _playbackHistoryShutdownRegistration = historyShutdownRegistration;
    if (previousHistoryTracker != null) {
      unawaited(
        previousHistoryShutdownRegistration?.dispose() ??
            previousHistoryTracker.dispose(),
      );
    }
    ref.listen<bool?>(
      settingsControllerProvider.select(
        (settings) => settings.asData?.value.recommendationHistoryEnabled,
      ),
      (previous, next) {
        if (_recommendationHistorySuspended || next != true) {
          unawaited(historyTracker.setEnabled(false));
          return;
        }
        unawaited(() async {
          await historyTracker.setEnabled(true);
          if (_disposed ||
              _recommendationHistorySuspended ||
              !identical(_playbackHistoryTracker, historyTracker)) {
            return;
          }
          final current = state.value ?? service.currentSnapshot;
          _observePlaybackHistory(_decorateSnapshot(current));
        }());
      },
      fireImmediately: true,
    );
    final activeRemoteSource =
        (initialSnapshot.isRemote ||
            initialSnapshot.trackId?.startsWith(_remoteCacheTrackIdPrefix) ==
                true)
        ? initialSnapshot.sourceUrl?.trim()
        : null;
    unawaited(
      ref
          .read(remotePlaybackCacheProvider)
          .prepareSession(
            protectedSourceUrls: [
              if (activeRemoteSource != null && activeRemoteSource.isNotEmpty)
                activeRemoteSource,
            ],
          ),
    );
    final subscription = service.snapshotStream.listen((snapshot) {
      if (_disposed) {
        return;
      }
      final internalRemoteTransition =
          _isNativeRemoteQueueSnapshot(snapshot) ||
          _isCrossfadeRemoteQueueSnapshot(snapshot);
      if (!internalRemoteTransition && _isStaleRemoteSnapshot(snapshot)) {
        return;
      }
      final previousRemoteTrack = _playingRemoteTrack;
      final failedCachedRemote =
          snapshot.status == PlayerStatus.failed &&
          previousRemoteTrack != null &&
          _isCachedRemoteSnapshot(snapshot, previousRemoteTrack);
      if (failedCachedRemote &&
          _remoteRetry.invalidatedCacheIdentity ==
              _remoteTrackIdentity(previousRemoteTrack)) {
        // MediaKit may report the same failed open through both its Future
        // and error stream. The Future path is already replacing this cache
        // source with the network stream.
        return;
      }
      // A remote-to-remote handoff can briefly publish the outgoing native
      // item as stopped (or as a local/idle snapshot) before the replacement
      // source is ready.  That snapshot belongs to the previous selection;
      // allowing it through would move `_queueIndex` back and cancel the new
      // resolver, making the Next button appear to do nothing until the old
      // song completes.  Keep the pending selection authoritative until the
      // backend identifies that same queue entry/track.
      final pendingRemote = _pendingRemoteSnapshot;
      final activeRemote = _playingRemoteTrack;
      if (!internalRemoteTransition &&
          pendingRemote != null &&
          !_snapshotMatchesPending(snapshot, pendingRemote) &&
          !(activeRemote != null &&
              _isCachedRemoteSnapshot(snapshot, activeRemote))) {
        return;
      }
      final queueIndexChanged = _syncQueueIndexFromSnapshot(snapshot);
      if (snapshot.isRemote) {
        _activePlaybackIsRemote = true;
        final currentRemote = _playingRemoteTrack;
        if (currentRemote != null &&
            _snapshotBelongsToTrack(snapshot, currentRemote)) {
          _hybridLocalFallbackEntryId = null;
          _pendingHybridLocalFailureEntryId = null;
        }
      } else if (_snapshotMatchesCurrentLocal(snapshot)) {
        // Stopping/configuring the rejected local backend can emit more local
        // snapshots while its catalog stream fallback is already starting.
        // Do not hand ownership back to the stale local representation.
        if (_hybridLocalFallbackEntryId == null) {
          _activePlaybackIsRemote = false;
        }
      }
      if (queueIndexChanged && snapshot.isRemote) {
        _resetQueueNavigation();
        // ExoPlayer did not reload, but every pending resolver/cache operation
        // still belongs to the previous logical track and must become stale.
        _playRequestId++;
        _pendingRemoteSnapshot = null;
        _remoteRetry.resetLoadAndFailureState();
        _previousRemoteTrackForCache = previousRemoteTrack;
      }
      if (_maybeRecoverHybridLocalFailure(snapshot)) {
        return;
      }
      if (_isDuplicateTerminalRemoteFailureSnapshot(snapshot) ||
          _isRemoteFailureRecoveryInFlightSnapshot(snapshot)) {
        return;
      }
      final decorated = _decorateSnapshot(snapshot);
      _observePlaybackHistory(decorated);
      state = AsyncData(decorated);
      if (queueIndexChanged && decorated.isRemote) {
        _remotePrefetch.invalidate();
        unawaited(_warmUpcomingRemoteTracks(_playRequestId));
      } else if (queueIndexChanged) {
        _resetQueueNavigation();
        unawaited(_stageLocalCrossfade());
      }
      if (queueIndexChanged) {
        unawaited(_maybeExtendRecommendationQueue());
      }
      if (!_maybeRecoverRemoteFailure(
        decorated,
        failedCachedRemote: failedCachedRemote,
      )) {
        _maybeHandleCompletion(decorated);
      }
    });
    ref.onDispose(() {
      // Every asynchronous continuation checks this generation before it can
      // publish or persist work. Invalidate it before the provider and player
      // service are torn down so late completions become harmless.
      _disposed = true;
      _playRequestId++;
      _remoteQueueEntries.invalidate();
      _playbackOptionsSync.invalidate();
      _crossfadePreparation.invalidate();
      _recommendationExtension.invalidate();
      _changingLocalTrackRequestId = null;
      unawaited(historyShutdownRegistration.dispose());
      unawaited(subscription.cancel());
    });
    return initialSnapshot;
  }

  bool _snapshotMatchesCurrentLocal(PlayerSnapshot snapshot) {
    if (_queueIndex < 0 || _queueIndex >= _queue.length) return false;
    final local = _queue[_queueIndex].local;
    if (local == null) return false;
    return snapshot.trackId == local.id || snapshot.sourceUrl == local.filePath;
  }

  bool _maybeRecoverHybridLocalFailure(PlayerSnapshot snapshot) {
    if (snapshot.status != PlayerStatus.failed ||
        snapshot.isRemote ||
        _queueIndex < 0 ||
        _queueIndex >= _queue.length) {
      return false;
    }
    final item = _queue[_queueIndex];
    if (item.local == null ||
        item.remote == null ||
        !_snapshotMatchesCurrentLocal(snapshot)) {
      return false;
    }
    final entryId = _hybridEntryId(item);
    if (_hybridLocalFallbackEntryId == entryId) {
      // Native option synchronization and stop() can repeat the same failed
      // snapshot. One logical occurrence owns at most one local→stream handoff.
      return true;
    }
    if (_activePlaybackIsRemote) {
      return false;
    }
    // A failed snapshot can arrive before playLocal's Future completes. That
    // Future owns the synchronous fallback. Remember the signal so a backend
    // that resolves its Future normally cannot make us lose the only failure.
    if (_changingLocalTrack) {
      _pendingHybridLocalFailureEntryId = entryId;
      return true;
    }
    _hybridLocalFallbackEntryId = entryId;
    _activePlaybackIsRemote = true;
    unawaited(_playRemoteTrack(item.remote!));
    return true;
  }

  String _hybridEntryId(_QueueItem item) {
    return item.logicalEntryId ??
        item.remoteQueueEntryId ??
        'local:${item.local!.id}';
  }

  bool _startPendingHybridLocalFallback(int requestId) {
    if (!_isCurrentPlayRequest(requestId) ||
        _queueIndex < 0 ||
        _queueIndex >= _queue.length) {
      return false;
    }
    final item = _queue[_queueIndex];
    if (item.local == null || item.remote == null) {
      return false;
    }
    final entryId = _hybridEntryId(item);
    if (_pendingHybridLocalFailureEntryId != entryId) {
      return false;
    }
    _pendingHybridLocalFailureEntryId = null;
    _hybridLocalFallbackEntryId = entryId;
    _activePlaybackIsRemote = true;
    unawaited(_playRemoteTrack(item.remote!));
    return true;
  }

  void _scheduleCrossfadeConfiguration({
    required bool enabled,
    required Duration duration,
    required bool prepareWhenEnabled,
  }) {
    final previous = _crossfadeConfigurationTail;
    _crossfadeConfigurationTail = () async {
      await previous;
      if (_disposed) {
        return;
      }
      final service = ref.read(playerServiceProvider);
      if (service is! CrossfadeCapablePlayer) {
        return;
      }
      final crossfadeService = service as CrossfadeCapablePlayer;
      await crossfadeService.configureCrossfade(
        enabled: enabled,
        duration: duration,
      );
      if (_disposed) {
        return;
      }
      if (!enabled) {
        await _scheduleCrossfadePreparation(null);
        return;
      }
      if (!prepareWhenEnabled) {
        return;
      }
      if (_playingRemoteTrack != null) {
        // Enabling in the middle of a track must not be defeated by a cache
        // signature produced while crossfade was disabled.
        _remotePrefetch.invalidate();
        // Preparation can involve network/cache I/O. Do not keep it in the
        // configuration lane or a quick off toggle would wait behind a slow
        // standby load before it can cancel that load.
        unawaited(_warmUpcomingRemoteTracks(_playRequestId));
      } else {
        unawaited(_stageLocalCrossfade());
      }
    }();
    _crossfadeConfigurationTail = _crossfadeConfigurationTail.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Crossfade configuration failed: $error\n$stackTrace');
      },
    );
  }

  Future<void> playRemote(
    TrackInfo track, {
    List<TrackInfo>? queue,
    String? queueSourceId,
  }) async {
    _resetQueueNavigation();
    _clearRecommendationQueueExtension();
    final previousRemoteTrack = _playingRemoteTrack;
    _remotePrefetch.invalidate();
    _remoteQueueEntries.beginGeneration();
    _useNativeLocalQueue = true;
    _activeLocalQueueSourceId = null;
    _activeRemoteQueueSourceId = queueSourceId;
    _previousRemoteTrackForCache = previousRemoteTrack;
    final normalizedQueue = queue == null || queue.isEmpty
        ? <TrackInfo>[track]
        : List<TrackInfo>.of(queue);
    _queueIndex = normalizedQueue.indexWhere(
      (item) =>
          item.url == track.url || (track.id.isNotEmpty && item.id == track.id),
    );
    if (_queueIndex < 0) {
      normalizedQueue.insert(0, track);
      _queueIndex = 0;
    }
    _queue = List<_QueueItem>.unmodifiable(
      normalizedQueue.map(_remoteQueueEntries.newRemoteItem),
    );
    _resetShuffleHistory();
    _publishPlaybackQueue();

    await _playRemoteTrack(track);
  }

  /// Starts a recommendation shelf without splitting downloaded and remote
  /// entries into separate one-item queues.
  Future<void> playRecommendation(
    RecommendationPlaybackItem selected, {
    required List<RecommendationPlaybackItem> queue,
    String? queueSourceId,
    RecommendationQueueExtender? queueExtender,
  }) async {
    _resetQueueNavigation();
    _clearRecommendationQueueExtension();
    ref.read(remotePlaybackCacheProvider).cancelPlaybackWarmups();
    final previousRemoteTrack = _playingRemoteTrack;
    _remotePrefetch.invalidate();
    _remoteQueueEntries.beginGeneration();
    _useNativeLocalQueue = false;
    _activeLocalQueueSourceId = queueSourceId;
    _activeRemoteQueueSourceId = queueSourceId;
    _previousRemoteTrackForCache = previousRemoteTrack;

    final normalizedQueue = queue.isEmpty
        ? <RecommendationPlaybackItem>[selected]
        : List<RecommendationPlaybackItem>.of(queue);
    _queueIndex = normalizedQueue.indexWhere(
      (item) => _sameRecommendationPlaybackItem(item, selected),
    );
    if (_queueIndex < 0) {
      normalizedQueue.insert(0, selected);
      _queueIndex = 0;
    }
    _queue = List<_QueueItem>.unmodifiable(
      normalizedQueue.map(_newRecommendationQueueItem),
    );
    _resetShuffleHistory();
    _publishPlaybackQueue();
    if (queueExtender != null &&
        queueSourceId != null &&
        queueSourceId.trim().isNotEmpty) {
      _recommendationExtension.configure(
        sourceId: queueSourceId,
        extender: queueExtender,
      );
    }
    await _playQueueItem(_queue[_queueIndex]);
    unawaited(_maybeExtendRecommendationQueue());
  }

  /// Starts a catalog-backed playlist without requiring every entry to have a
  /// downloaded file.
  ///
  /// Items carrying both representations are local-first. If the file was
  /// removed or cannot be opened, the same logical entry is streamed instead.
  Future<void> playCatalogPlaylist(
    CatalogPlaybackItem selected, {
    required List<CatalogPlaybackItem> queue,
    required String playlistId,
  }) async {
    _resetQueueNavigation();
    _clearRecommendationQueueExtension();
    ref.read(remotePlaybackCacheProvider).cancelPlaybackWarmups();
    final previousRemoteTrack = _playingRemoteTrack;
    _remotePrefetch.invalidate();
    _remoteQueueEntries.beginGeneration();
    _useNativeLocalQueue = false;
    final sourceId = playlistQueueSourceId(playlistId);
    _activeLocalQueueSourceId = sourceId;
    _activeRemoteQueueSourceId = sourceId;
    _previousRemoteTrackForCache = previousRemoteTrack;

    final normalizedQueue = queue.isEmpty
        ? <CatalogPlaybackItem>[selected]
        : List<CatalogPlaybackItem>.of(queue);
    _queueIndex = normalizedQueue.indexWhere(
      (item) => item.entryId == selected.entryId,
    );
    if (_queueIndex < 0) {
      normalizedQueue.insert(0, selected);
      _queueIndex = 0;
    }
    _queue = List<_QueueItem>.unmodifiable(
      normalizedQueue.map(_newCatalogQueueItem),
    );
    _resetShuffleHistory();
    _publishPlaybackQueue();
    await _playQueueItem(_queue[_queueIndex]);
  }

  /// Reconciles an active catalog playlist after a local edit or a remote
  /// synchronization pass without reopening the item that is already playing.
  Future<bool> syncCatalogPlaylistSource(
    String sourceId,
    List<CatalogPlaybackItem> items,
  ) async {
    final synchronized = await _syncLogicalQueueSource(
      sourceId,
      items.map(_catalogQueueItem).toList(growable: false),
    );
    if (!synchronized) {
      return false;
    }

    final service = ref.read(playerServiceProvider);
    if (_useNativeLocalQueue && service.supportsLocalQueueReplacement) {
      final localQueue = _queue
          .map((item) => item.local)
          .whereType<LocalTrack>()
          .toList(growable: false);
      if (localQueue.length == _queue.length) {
        await service.replaceLocalQueue(localQueue, _queueIndex);
      }
    }
    return true;
  }

  _QueueItem _newCatalogQueueItem(CatalogPlaybackItem item) {
    final queueItem = _catalogQueueItem(item);
    final remote = queueItem.remote;
    if (remote == null) {
      return queueItem;
    }
    final assigned = _remoteQueueEntries.newRemoteItem(remote);
    return queueItem.withRemoteQueueEntryId(assigned.remoteQueueEntryId!);
  }

  static _QueueItem _catalogQueueItem(CatalogPlaybackItem item) {
    final local = item.localTrack;
    final remote = item.remoteTrack;
    if (local != null && remote != null) {
      return _QueueItem.hybrid(
        local: local,
        remote: remote,
        logicalEntryId: item.entryId,
      );
    }
    if (remote != null) {
      return _QueueItem.remote(remote, logicalEntryId: item.entryId);
    }
    return _QueueItem.local(local!, logicalEntryId: item.entryId);
  }

  void _clearRecommendationQueueExtension() {
    _recommendationExtension.clear();
  }

  Future<bool> _maybeExtendRecommendationQueue({bool atQueueEnd = false}) {
    if (_queueIndex < 0 || _queueIndex >= _queue.length) {
      return Future<bool>.value(false);
    }
    final sourceId = _recommendationExtension.sourceId;
    final remaining = _shuffleEnabled
        ? _queue.length - _shufflePlayedIndices.length
        : _queue.length - _queueIndex - 1;
    return _recommendationExtension.maybeExtend(
      sourceIsActive:
          sourceId != null &&
          (_activeLocalQueueSourceId == sourceId ||
              _activeRemoteQueueSourceId == sourceId),
      atQueueEnd: atQueueEnd,
      remaining: remaining,
      threshold: _recommendationQueueExtensionThreshold,
      currentLength: () => _queue.length,
      isDisposed: () => _disposed,
      synchronize: syncRecommendationQueueSource,
      onError: (error) {
        // Related radio is optional. Preserve the visible, playable shelf.
        debugPrint('Recommendation queue extension failed: $error');
      },
    );
  }

  /// Appends asynchronously resolved radio entries while the selected
  /// recommendation keeps playing. Returns false when the user has moved to
  /// another queue in the meantime.
  Future<bool> syncRecommendationQueueSource(
    String sourceId,
    List<RecommendationPlaybackItem> items,
  ) {
    return _syncLogicalQueueSource(
      sourceId,
      items.map(_recommendationQueueItem).toList(growable: false),
    );
  }

  Future<bool> _syncLogicalQueueSource(
    String sourceId,
    List<_QueueItem> candidates,
  ) async {
    if ((_activeLocalQueueSourceId != sourceId &&
            _activeRemoteQueueSourceId != sourceId) ||
        candidates.isEmpty ||
        _queueIndex < 0 ||
        _queueIndex >= _queue.length) {
      return false;
    }

    final current = _queue[_queueIndex];
    final previouslyPlayed = [
      for (final index in _shufflePlayedIndices)
        if (index >= 0 && index < _queue.length) _queue[index],
    ];
    final previousPlan = [
      for (final index in _shufflePlan)
        if (index >= 0 && index < _queue.length) _queue[index],
    ];
    final nextQueue = _remoteQueueEntries
        .reconcile(candidates, previousQueue: _queue)
        .toList();
    var nextIndex = nextQueue.indexWhere(
      (candidate) => _sameQueueItem(candidate, current),
    );
    if (nextIndex < 0 && _logicalEntryId(current) == null) {
      final occurrence = _queue
          .take(_queueIndex + 1)
          .where((item) => _sameQueueRepresentation(item, current))
          .length;
      var candidateOccurrence = 0;
      for (var index = 0; index < nextQueue.length; index++) {
        if (!_sameQueueRepresentation(nextQueue[index], current)) {
          continue;
        }
        candidateOccurrence++;
        if (candidateOccurrence == occurrence) {
          nextIndex = index;
          break;
        }
      }
    }
    if (nextIndex < 0) {
      return false;
    }
    final currentRemote = current.remote;
    if (currentRemote != null && nextQueue[nextIndex].remote != null) {
      nextQueue[nextIndex] = nextQueue[nextIndex]
          .withRemoteQueueEntryId(
            current.remoteQueueEntryId ?? _remoteQueueEntryId(_queueIndex),
          )
          .withRemoteTrack(currentRemote);
    }

    _queue = List<_QueueItem>.unmodifiable(nextQueue);
    _queueIndex = nextIndex;
    _activeLocalQueueSourceId = sourceId;
    _activeRemoteQueueSourceId = sourceId;
    if (_shuffleEnabled) {
      final restoredPlayed = <int>{};
      for (final played in previouslyPlayed) {
        final index = nextQueue.indexWhere(
          (candidate) => _sameQueueItem(candidate, played),
        );
        if (index >= 0) {
          restoredPlayed.add(index);
        }
      }
      final restoredPlan = <int>[];
      for (final planned in previousPlan) {
        final index = nextQueue.indexWhere(
          (candidate) => _sameQueueItem(candidate, planned),
        );
        if (index >= 0 &&
            index != _queueIndex &&
            !restoredPlayed.contains(index) &&
            !restoredPlan.contains(index)) {
          restoredPlan.add(index);
        }
      }
      _queueNavigation.restoreShuffleState(
        playedIndices: restoredPlayed,
        plan: restoredPlan,
      );
      _markCurrentQueueIndexPlayed();
      _ensureShufflePlan();
    } else {
      _resetShuffleHistory();
    }
    _publishPlaybackQueue();
    if (_queue[_queueIndex].remote != null) {
      _remotePrefetch.invalidate();
      unawaited(_warmUpcomingRemoteTracks(_playRequestId));
    } else {
      unawaited(_stageLocalCrossfade());
    }
    return true;
  }

  static _QueueItem _recommendationQueueItem(RecommendationPlaybackItem item) {
    final local = item.localTrack;
    return local == null
        ? _QueueItem.remote(item.track, logicalEntryId: item.logicalEntryId)
        : _QueueItem.hybrid(
            local: local,
            remote: item.track,
            logicalEntryId: item.logicalEntryId,
          );
  }

  _QueueItem _newRecommendationQueueItem(RecommendationPlaybackItem item) {
    final queueItem = _recommendationQueueItem(item);
    final remote = queueItem.remote;
    if (remote == null) {
      return queueItem;
    }
    final assigned = _remoteQueueEntries.newRemoteItem(remote);
    return queueItem.withRemoteQueueEntryId(assigned.remoteQueueEntryId!);
  }

  bool _sameRecommendationPlaybackItem(
    RecommendationPlaybackItem left,
    RecommendationPlaybackItem right,
  ) {
    final leftLocal = left.localTrack;
    final rightLocal = right.localTrack;
    final leftEntryId = left.logicalEntryId?.trim();
    final rightEntryId = right.logicalEntryId?.trim();
    if (leftEntryId != null || rightEntryId != null) {
      return leftEntryId != null && leftEntryId == rightEntryId;
    }
    if (leftLocal != null || rightLocal != null) {
      return leftLocal?.id == rightLocal?.id &&
          leftLocal != null &&
          rightLocal != null;
    }
    return _sameLogicalRemoteTrack(left.track, right.track);
  }

  String? _logicalEntryId(_QueueItem item) {
    final value = item.logicalEntryId?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  bool _sameQueueRepresentation(_QueueItem left, _QueueItem right) {
    final leftLocal = left.local;
    final rightLocal = right.local;
    if (leftLocal != null &&
        rightLocal != null &&
        leftLocal.id == rightLocal.id) {
      return true;
    }
    final leftRemote = left.remote;
    final rightRemote = right.remote;
    return leftRemote != null &&
        rightRemote != null &&
        _sameLogicalRemoteTrack(leftRemote, rightRemote);
  }

  bool _sameQueueItem(_QueueItem left, _QueueItem right) {
    final leftEntryId = _logicalEntryId(left);
    final rightEntryId = _logicalEntryId(right);
    if (leftEntryId != null || rightEntryId != null) {
      return leftEntryId != null && leftEntryId == rightEntryId;
    }
    return _sameQueueRepresentation(left, right);
  }

  Future<void> _playRemoteTrack(
    TrackInfo track, {
    bool automaticTransition = false,
  }) async {
    _activePlaybackIsRemote = true;
    _explicitlyStopped = false;
    _remotePrefetch.invalidate();
    _invalidateCrossfadePreparations();
    final requestId = ++_playRequestId;
    _changingLocalTrackRequestId = null;
    _remoteRetry.resetForSelection();
    _liveTerminalAdvanceScheduledRequestId = null;
    ref
        .read(remotePlaybackCacheProvider)
        .protectPlaybackWindow(_remoteCacheWindow());
    final pendingSnapshot = _remoteLoadingSnapshot(track);
    _pendingRemoteSnapshot = pendingSnapshot;
    state = AsyncData(pendingSnapshot);

    try {
      await _syncNativePlaybackOptions();
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }
      final service = ref.read(playerServiceProvider);
      final previousSnapshot = service.currentSnapshot;
      final replacingRemoteSource =
          previousSnapshot.isRemote ||
          previousSnapshot.trackId?.startsWith(_remoteCacheTrackIdPrefix) ==
              true;
      // Remote-to-remote transitions must not move audio_service through idle.
      // On Android that can stop the foreground service before Dart loads the
      // replacement source while the app is in the background.
      if (!automaticTransition && !replacingRemoteSource) {
        await service.stop();
        if (!_isCurrentPlayRequest(requestId)) {
          return;
        }
      }
      final NativeRemoteQueuePlayer? nativeRemoteService =
          service is NativeRemoteQueuePlayer
          ? service as NativeRemoteQueuePlayer
          : null;
      var cachedSourceFailed = false;
      bool invalidateCachedSource(TrackInfo failedTrack) {
        cachedSourceFailed = true;
        _remoteRetry.markInvalidatedCache(_remoteTrackIdentity(failedTrack));
        unawaited(ref.read(remotePlaybackCacheProvider).evict(failedTrack));
        return _remoteRetry.recoveryQueueEntryId ==
            pendingSnapshot.queueEntryId;
      }

      if (nativeRemoteService != null) {
        final cachedSource = await _cachedRemotePlaybackSource(track);
        if (!_isCurrentPlayRequest(requestId)) {
          return;
        }
        if (cachedSource != null) {
          final loadAttemptId = _beginRemoteLoadAttempt();
          try {
            await nativeRemoteService.playRemoteSource(cachedSource);
            if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
                !_isCurrentRemoteSelection(
                  track,
                  requestId,
                  pendingSnapshot.queueEntryId,
                )) {
              return;
            }
            _clearPendingRemoteSnapshot(requestId);
            unawaited(_warmUpcomingRemoteTracks(requestId));
            return;
          } catch (_) {
            if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
                !_isCurrentRemoteSelection(
                  track,
                  requestId,
                  pendingSnapshot.queueEntryId,
                )) {
              return;
            }
            if (invalidateCachedSource(track)) {
              return;
            }
          } finally {
            _finishRemoteLoadAttempt(loadAttemptId);
          }
        }
      }
      final cachedTrack = cachedSourceFailed
          ? null
          : await _cachedRemoteTrack(track);
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }
      if (cachedTrack != null) {
        final loadAttemptId = _beginRemoteLoadAttempt();
        try {
          await ref.read(playerServiceProvider).playLocal(cachedTrack);
          if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
              !_isCurrentRemoteSelection(
                track,
                requestId,
                pendingSnapshot.queueEntryId,
              )) {
            return;
          }
          _clearPendingRemoteSnapshot(requestId);
          unawaited(_warmUpcomingRemoteTracks(requestId));
          return;
        } catch (_) {
          if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
              !_isCurrentRemoteSelection(
                track,
                requestId,
                pendingSnapshot.queueEntryId,
              )) {
            return;
          }
          if (invalidateCachedSource(track)) {
            return;
          }
        } finally {
          _finishRemoteLoadAttempt(loadAttemptId);
        }
      }

      final playableTrack = await _resolveRemoteTrack(
        track,
        shouldContinue: () => _isCurrentRemoteSelection(
          track,
          requestId,
          pendingSnapshot.queueEntryId,
        ),
        onResolverFailure: (source, error) {
          _showRemoteFallbackNotice(
            source,
            error,
            track,
            requestId,
            pendingSnapshot.queueEntryId,
          );
        },
      );
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }
      _replaceCurrentRemoteTrack(playableTrack);

      if (nativeRemoteService != null) {
        final cachedSource = cachedSourceFailed
            ? null
            : await _cachedRemotePlaybackSource(playableTrack);
        if (!_isCurrentPlayRequest(requestId)) {
          return;
        }
        if (cachedSource != null) {
          final loadAttemptId = _beginRemoteLoadAttempt();
          try {
            await nativeRemoteService.playRemoteSource(cachedSource);
            if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
                !_isCurrentRemoteSelection(
                  playableTrack,
                  requestId,
                  pendingSnapshot.queueEntryId,
                )) {
              return;
            }
            _clearPendingRemoteSnapshot(requestId);
            unawaited(_warmUpcomingRemoteTracks(requestId));
            return;
          } catch (_) {
            if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
                !_isCurrentRemoteSelection(
                  playableTrack,
                  requestId,
                  pendingSnapshot.queueEntryId,
                )) {
              return;
            }
            if (invalidateCachedSource(playableTrack)) {
              return;
            }
          } finally {
            _finishRemoteLoadAttempt(loadAttemptId);
          }
        }
        final loadAttemptId = _beginRemoteLoadAttempt();
        try {
          await nativeRemoteService.playRemoteSource(
            _networkRemotePlaybackSource(playableTrack),
          );
          if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
              !_isCurrentRemoteSelection(
                playableTrack,
                requestId,
                pendingSnapshot.queueEntryId,
              )) {
            return;
          }
          _clearPendingRemoteSnapshot(requestId);
          unawaited(_warmUpcomingRemoteTracks(requestId));
          return;
        } catch (error) {
          if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
              !_isCurrentRemoteSelection(
                playableTrack,
                requestId,
                pendingSnapshot.queueEntryId,
              ) ||
              _isRemoteRecoveryInFlight(
                requestId,
                pendingSnapshot.queueEntryId,
              ) ||
              _isRemoteRetryInFlight(
                playableTrack,
                requestId,
                pendingSnapshot.queueEntryId,
              ) ||
              _resolvedRemoteSourceWasReplaced(playableTrack)) {
            // The backend can report the same rejected primary source through
            // its snapshot stream and through this Future. The stream recovery
            // may already have finished by the time the original Future
            // completes, so keep the fallback result instead of replacing it
            // with this stale primary error.
            return;
          }
          debugPrint(
            '[PlayerController] nativeRemoteService.playRemoteSource failed '
            '(hasStreamUrl=${playableTrack.streamUrl != null && playableTrack.streamUrl!.isNotEmpty}): '
            '${readableAudioStreamError(error)}',
          );
          if (_isYoutubeExplodeStream(playableTrack) &&
              _shouldRecoverRemoteError(playableTrack, error)) {
            if (_isYoutubeExplodeStream(playableTrack)) {
              _showRemoteFallbackNotice(
                AudioStreamSource.youtubeExplode,
                error,
                playableTrack,
                requestId,
                pendingSnapshot.queueEntryId,
              );
            }
            _markRemoteRecoveryInFlight(
              requestId,
              pendingSnapshot.queueEntryId,
            );
            try {
              await _refreshAndReplayRemote(
                playableTrack,
                requestId,
                expectedQueueEntryId: pendingSnapshot.queueEntryId,
                mode: AudioResolutionMode.fallbackOnly,
              );
            } finally {
              _clearRemoteRecoveryInFlight(
                requestId,
                pendingSnapshot.queueEntryId,
              );
            }
            return;
          }
          rethrow;
        } finally {
          _finishRemoteLoadAttempt(loadAttemptId);
        }
      }

      final cachedPlayableTrack = cachedSourceFailed
          ? null
          : await _cachedRemoteTrack(playableTrack);
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }
      if (cachedPlayableTrack != null) {
        final loadAttemptId = _beginRemoteLoadAttempt();
        try {
          await ref.read(playerServiceProvider).playLocal(cachedPlayableTrack);
          if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
              !_isCurrentRemoteSelection(
                playableTrack,
                requestId,
                pendingSnapshot.queueEntryId,
              )) {
            return;
          }
          _clearPendingRemoteSnapshot(requestId);
          unawaited(_warmUpcomingRemoteTracks(requestId));
          return;
        } catch (_) {
          if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
              !_isCurrentRemoteSelection(
                playableTrack,
                requestId,
                pendingSnapshot.queueEntryId,
              )) {
            return;
          }
          if (invalidateCachedSource(playableTrack)) {
            return;
          }
        } finally {
          _finishRemoteLoadAttempt(loadAttemptId);
        }
      }

      final loadAttemptId = _beginRemoteLoadAttempt();
      try {
        await ref.read(playerServiceProvider).playRemote(playableTrack);
        if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
            !_isCurrentRemoteSelection(
              playableTrack,
              requestId,
              pendingSnapshot.queueEntryId,
            )) {
          return;
        }
        _clearPendingRemoteSnapshot(requestId);
        unawaited(_warmUpcomingRemoteTracks(requestId));
      } catch (error) {
        if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
            !_isCurrentRemoteSelection(
              playableTrack,
              requestId,
              pendingSnapshot.queueEntryId,
            ) ||
            _isRemoteRecoveryInFlight(
              requestId,
              pendingSnapshot.queueEntryId,
            ) ||
            _isRemoteRetryInFlight(
              playableTrack,
              requestId,
              pendingSnapshot.queueEntryId,
            ) ||
            _resolvedRemoteSourceWasReplaced(playableTrack)) {
          // See the native branch above: this can be a late duplicate of the
          // primary failure that already triggered and completed recovery.
          return;
        }
        debugPrint(
          '[PlayerController] playerService.playRemote failed '
          '(hasStreamUrl=${playableTrack.streamUrl != null && playableTrack.streamUrl!.isNotEmpty}): '
          '${readableAudioStreamError(error)}',
        );
        if (_isYoutubeExplodeStream(playableTrack) &&
            _shouldRecoverRemoteError(playableTrack, error)) {
          if (_isYoutubeExplodeStream(playableTrack)) {
            _showRemoteFallbackNotice(
              AudioStreamSource.youtubeExplode,
              error,
              playableTrack,
              requestId,
              pendingSnapshot.queueEntryId,
            );
          }
          _markRemoteRecoveryInFlight(requestId, pendingSnapshot.queueEntryId);
          try {
            await _refreshAndReplayRemote(
              playableTrack,
              requestId,
              expectedQueueEntryId: pendingSnapshot.queueEntryId,
              mode: AudioResolutionMode.fallbackOnly,
            );
          } finally {
            _clearRemoteRecoveryInFlight(
              requestId,
              pendingSnapshot.queueEntryId,
            );
          }
          return;
        }
        rethrow;
      } finally {
        _finishRemoteLoadAttempt(loadAttemptId);
      }
    } catch (error, stackTrace) {
      await _retryOrPublishTerminalRemoteFailure(
        track,
        requestId,
        expectedQueueEntryId: pendingSnapshot.queueEntryId,
        initialError: error,
        initialStackTrace: stackTrace,
      );
    }
  }

  PlayerSnapshot _remoteLoadingSnapshot(TrackInfo track) {
    return PlayerSnapshot(
      status: PlayerStatus.loading,
      title: track.title,
      artist: track.artist,
      album: track.album,
      trackId: track.id.isEmpty ? track.url : track.id,
      queueEntryId: _currentRemoteQueueEntryId,
      sourceUrl: track.url,
      thumbnailUrl: _stableRemoteThumbnail(track),
      duration: track.duration,
      volume:
          state.value?.volume ??
          ref.read(playerServiceProvider).currentSnapshot.volume,
      isRemote: true,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
    );
  }

  void _showRemoteFallbackNotice(
    AudioStreamSource source,
    Object error,
    TrackInfo track,
    int requestId,
    String? expectedQueueEntryId,
  ) {
    if (!_isCurrentRemoteSelection(track, requestId, expectedQueueEntryId)) {
      return;
    }
    final provider = source == AudioStreamSource.youtubeExplode
        ? 'youtube_explode_dart'
        : 'yt-dlp';
    final detail = readableAudioStreamError(error);
    debugPrint(
      '[PlayerController] $provider failed at resolution stage '
      '(hasStreamUrl=${track.streamUrl != null && track.streamUrl!.isNotEmpty}): '
      '$detail',
    );
    final message = detail.isEmpty
        ? '$provider falló. Probando con yt-dlp...'
        : '$provider falló: $detail. Probando con yt-dlp...';
    _remoteRetry.setNotice(requestId, message);
    final pending = _remoteLoadingSnapshot(
      track,
    ).copyWith(errorMessage: message);
    _pendingRemoteSnapshot = pending;
    state = AsyncData(pending);
  }

  String? _fallbackNoticeFor(int requestId) {
    return _remoteRetry.noticeFor(requestId);
  }

  void _clearRemoteFallbackNotice([int? requestId]) {
    _remoteRetry.clearNotice(requestId);
  }

  bool _isCurrentPlayRequest(int requestId) => requestId == _playRequestId;

  bool _isRemoteRecoveryInFlight(int requestId, String? queueEntryId) {
    return _remoteRetry.isRecoveryInFlight(requestId, queueEntryId);
  }

  void _markRemoteRecoveryInFlight(int requestId, String? queueEntryId) {
    _remoteRetry.markRecoveryInFlight(requestId, queueEntryId);
  }

  void _clearRemoteRecoveryInFlight(int requestId, String? queueEntryId) {
    _remoteRetry.clearRecoveryInFlight(requestId, queueEntryId);
  }

  String _remoteRetryKey(TrackInfo track, int requestId, String? queueEntryId) {
    return _remoteRetry.retryKey(
      _remoteTrackIdentity(track),
      requestId,
      queueEntryId,
    );
  }

  bool _isRemoteRetryInFlight(
    TrackInfo track,
    int requestId,
    String? queueEntryId,
  ) {
    return _remoteRetry.isRetryInFlight(
      _remoteRetryKey(track, requestId, queueEntryId),
    );
  }

  bool _isDuplicateTerminalRemoteFailureSnapshot(PlayerSnapshot snapshot) {
    if (snapshot.status != PlayerStatus.failed ||
        _queueIndex < 0 ||
        _queueIndex >= _queue.length) {
      return false;
    }
    final track = _queue[_queueIndex].remote;
    if (track == null || !_snapshotBelongsToTrack(snapshot, track)) {
      return false;
    }
    final queueEntryId = snapshot.queueEntryId ?? _currentRemoteQueueEntryId;
    return _remoteRetry.isTerminalFailure(
      _remoteRetryKey(track, _playRequestId, queueEntryId),
    );
  }

  bool _isRemoteFailureRecoveryInFlightSnapshot(PlayerSnapshot snapshot) {
    if (snapshot.status != PlayerStatus.failed ||
        _queueIndex < 0 ||
        _queueIndex >= _queue.length) {
      return false;
    }
    final track = _queue[_queueIndex].remote;
    if (track == null || !_snapshotBelongsToTrack(snapshot, track)) {
      return false;
    }
    final queueEntryId = snapshot.queueEntryId ?? _currentRemoteQueueEntryId;
    return _isRemoteRecoveryInFlight(_playRequestId, queueEntryId) ||
        _isRemoteRetryInFlight(track, _playRequestId, queueEntryId);
  }

  void _markRemoteTerminalFailure(
    TrackInfo track,
    int requestId,
    String? queueEntryId,
  ) {
    _remoteRetry.markTerminalFailure(
      _remoteRetryKey(track, requestId, queueEntryId),
    );
  }

  bool _resolvedRemoteSourceWasReplaced(TrackInfo attemptedTrack) {
    return PlaybackIdentity.resolvedSourceWasReplaced(
      _playingRemoteTrack,
      attemptedTrack,
    );
  }

  int _beginRemoteLoadAttempt() {
    return _remoteRetry.beginLoadAttempt();
  }

  void _finishRemoteLoadAttempt(int attemptId) {
    _remoteRetry.finishLoadAttempt(attemptId);
  }

  void _markActiveRemoteLoadFailureHandled() {
    _remoteRetry.markActiveLoadFailureHandled();
  }

  bool _wasRemoteLoadFailureHandled(int attemptId) {
    return _remoteRetry.wasLoadFailureHandled(attemptId);
  }

  void _clearPendingRemoteSnapshot(int requestId) {
    if (_isCurrentPlayRequest(requestId)) {
      _pendingRemoteSnapshot = null;
      _remoteRetry.clearTerminalFailure();
      final hadFallbackNotice = _remoteRetry.noticeBelongsTo(requestId);
      _clearRemoteFallbackNotice(requestId);
      if (hadFallbackNotice) {
        // A successful fallback load is enough to retire the primary error.
        // Some backends report a ready/stopped snapshot until the user presses
        // Play, so waiting specifically for playing/paused would leave the
        // youtube_explode warning stuck on screen even though yt-dlp already
        // prepared a usable source.
        final serviceSnapshot = ref
            .read(playerServiceProvider)
            .currentSnapshot
            .copyWith(errorMessage: null);
        state = AsyncData(_decorateSnapshot(serviceSnapshot));
      }
    }
  }

  bool _maybeRecoverRemoteFailure(
    PlayerSnapshot snapshot, {
    bool failedCachedRemote = false,
  }) {
    if (_explicitlyStopped ||
        _changingLocalTrack ||
        snapshot.status != PlayerStatus.failed ||
        snapshot.trackId == null ||
        _queueIndex < 0 ||
        _queueIndex >= _queue.length) {
      return false;
    }

    final track = _queue[_queueIndex].remote;
    if (track == null || !_snapshotBelongsToTrack(snapshot, track)) {
      return false;
    }
    final requestId = _playRequestId;
    final expectedQueueEntryId =
        snapshot.queueEntryId ?? _currentRemoteQueueEntryId;
    if (_remoteRetry.isTerminalFailure(
      _remoteRetryKey(track, requestId, expectedQueueEntryId),
    )) {
      return true;
    }
    if (_isRemoteRecoveryInFlight(requestId, expectedQueueEntryId) ||
        _isRemoteRetryInFlight(track, requestId, expectedQueueEntryId)) {
      // The Future that started this backend load already owns the recovery.
      // Do not mark its active load as handled by the snapshot or its real
      // exception would be swallowed when it completes.
      return true;
    }

    final rejectedPrimary =
        !failedCachedRemote && _isYoutubeExplodeStream(track);
    final fallbackOnly = !failedCachedRemote && rejectedPrimary;
    if (!failedCachedRemote &&
        !rejectedPrimary &&
        !_shouldRefreshRemoteFailure(snapshot)) {
      _markActiveRemoteLoadFailureHandled();
      if (!_isRemoteCancellationMessage(snapshot.errorMessage)) {
        _markRemoteTerminalFailure(track, requestId, expectedQueueEntryId);
        _scheduleLiveAdvanceAfterTerminalRemoteFailure(
          track,
          requestId,
          expectedQueueEntryId,
        );
      }
      return false;
    }

    // From this point the snapshot path owns recovery. Keep that fact attached
    // to the backend load attempt until its Future settles, even if the shared
    // retry operation finishes first.
    _markActiveRemoteLoadFailureHandled();

    if (rejectedPrimary) {
      _showRemoteFallbackNotice(
        AudioStreamSource.youtubeExplode,
        snapshot.errorMessage ?? 'Error de reproducción.',
        track,
        requestId,
        expectedQueueEntryId,
      );
    }
    if (failedCachedRemote) {
      _remoteRetry.markInvalidatedCache(_remoteTrackIdentity(track));
      unawaited(ref.read(remotePlaybackCacheProvider).evict(track));
    }
    if (!failedCachedRemote && !rejectedPrimary) {
      unawaited(
        _retryOrPublishTerminalRemoteFailure(
          track,
          requestId,
          resumePosition: snapshot.position,
          expectedQueueEntryId: expectedQueueEntryId,
          initialError: PlayerException(
            snapshot.errorMessage ?? 'Remote playback failed.',
            code: 'transient_remote_playback',
          ),
          initialStackTrace: StackTrace.current,
        ),
      );
    } else {
      _markRemoteRecoveryInFlight(requestId, expectedQueueEntryId);
      unawaited(
        _recoverRemoteFailure(
          track,
          requestId,
          resumePosition: snapshot.position,
          expectedQueueEntryId: expectedQueueEntryId,
          mode: fallbackOnly
              ? AudioResolutionMode.fallbackOnly
              : AudioResolutionMode.primaryThenFallback,
        ),
      );
    }
    return true;
  }

  bool _snapshotBelongsToTrack(PlayerSnapshot snapshot, TrackInfo track) {
    return PlaybackIdentity.snapshotBelongsToTrack(snapshot, track);
  }

  bool _shouldRefreshRemoteFailure(PlayerSnapshot snapshot) {
    return _shouldRefreshRemoteErrorMessage(snapshot.errorMessage);
  }

  bool _shouldRefreshRemoteError(Object error) {
    return RemotePlaybackFailureClassifier.shouldRefresh(error);
  }

  bool _isRemoteCancellationError(Object error) {
    return RemotePlaybackFailureClassifier.isCancellation(error);
  }

  bool _isRemoteCancellationMessage(String? rawMessage) {
    return RemotePlaybackFailureClassifier.isCancellationMessage(rawMessage);
  }

  bool _shouldRecoverRemoteError(TrackInfo track, Object error) {
    return RemotePlaybackFailureClassifier.shouldRecover(track, error);
  }

  bool _isYoutubeExplodeStream(TrackInfo track) {
    return RemotePlaybackFailureClassifier.isYoutubeExplodeStream(track);
  }

  bool _isYtDlpStream(TrackInfo track) {
    return RemotePlaybackFailureClassifier.isYtDlpStream(track);
  }

  bool _shouldRefreshRemoteErrorMessage(String? rawMessage) {
    return RemotePlaybackFailureClassifier.shouldRefreshMessage(rawMessage);
  }

  bool _isNativeRemoteQueueSnapshot(PlayerSnapshot snapshot) {
    if (!snapshot.isRemote ||
        ref.read(playerServiceProvider) is! NativeRemoteQueuePlayer) {
      return false;
    }
    final queueEntryId = snapshot.queueEntryId;
    if (queueEntryId == null || queueEntryId.isEmpty) {
      return false;
    }
    final current = _playingRemoteTrack;
    final pending = _pendingRemoteSnapshot;
    if (pending != null &&
        pending.queueEntryId != queueEntryId &&
        _remoteRetry.recoveryQueueEntryId != pending.queueEntryId &&
        (current == null ||
            !_isRemoteRetryInFlight(
              current,
              _playRequestId,
              pending.queueEntryId,
            ))) {
      return false;
    }
    for (var index = 0; index < _queue.length; index++) {
      if (_queue[index].remote != null &&
          _remoteQueueEntryId(index) == queueEntryId) {
        return true;
      }
    }
    return false;
  }

  bool _isCrossfadeRemoteQueueSnapshot(PlayerSnapshot snapshot) {
    final service = ref.read(playerServiceProvider);
    if (!snapshot.isRemote ||
        snapshot.status != PlayerStatus.playing ||
        service is! CrossfadeCapablePlayer) {
      return false;
    }
    final queueEntryId = snapshot.queueEntryId;
    if (queueEntryId == null || queueEntryId.isEmpty) {
      return false;
    }
    for (var index = 0; index < _queue.length; index++) {
      if (_queue[index].remote != null &&
          _remoteQueueEntryId(index) == queueEntryId) {
        return true;
      }
    }
    return false;
  }

  bool _isStaleRemoteSnapshot(PlayerSnapshot snapshot) {
    final current = _playingRemoteTrack;
    if (current == null) {
      return false;
    }
    if (_isCachedRemoteSnapshot(snapshot, current)) {
      return false;
    }
    final expectedTrackId = current.id.isEmpty ? current.url : current.id;
    final snapshotTrackId = snapshot.trackId?.trim();
    if (snapshotTrackId != null &&
        snapshotTrackId.isNotEmpty &&
        snapshotTrackId == expectedTrackId) {
      return false;
    }
    final sourceUrl = snapshot.sourceUrl?.trim();
    if (sourceUrl != null && sourceUrl.isNotEmpty) {
      return snapshot.isRemote && sourceUrl != current.url;
    }
    return snapshotTrackId != null &&
        snapshotTrackId.isNotEmpty &&
        snapshotTrackId != expectedTrackId;
  }

  Future<void> _recoverRemoteFailure(
    TrackInfo track,
    int requestId, {
    required Duration resumePosition,
    required String? expectedQueueEntryId,
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
  }) async {
    if (!_isCurrentRemoteSelection(track, requestId, expectedQueueEntryId)) {
      return;
    }
    final pendingSnapshot = _remoteLoadingSnapshot(
      track,
    ).copyWith(errorMessage: _fallbackNoticeFor(requestId));
    _pendingRemoteSnapshot = pendingSnapshot;
    state = AsyncData(pendingSnapshot);
    try {
      if (mode == AudioResolutionMode.primaryThenFallback) {
        await _runCompleteRemotePlaybackRetryCycle(
          track,
          requestId,
          resumePosition: resumePosition,
          expectedQueueEntryId: expectedQueueEntryId,
        );
      } else {
        await _refreshAndReplayRemote(
          track,
          requestId,
          resumePosition: resumePosition,
          expectedQueueEntryId: expectedQueueEntryId,
          mode: mode,
        );
      }
    } catch (error, stackTrace) {
      await _retryOrPublishTerminalRemoteFailure(
        track,
        requestId,
        resumePosition: resumePosition,
        expectedQueueEntryId: expectedQueueEntryId,
        initialError: error,
        initialStackTrace: stackTrace,
      );
    } finally {
      _clearRemoteRecoveryInFlight(requestId, expectedQueueEntryId);
    }
  }

  Future<void> _refreshAndReplayRemote(
    TrackInfo track,
    int requestId, {
    Duration resumePosition = Duration.zero,
    required String? expectedQueueEntryId,
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
    void Function(TrackInfo track)? onResolved,
  }) async {
    if (!_isCurrentRemoteSelection(track, requestId, expectedQueueEntryId)) {
      return;
    }
    final refreshed = await _resolveRemoteTrack(
      track,
      forceRefresh: true,
      allowStaleStreamFallback: false,
      mode: mode,
      shouldContinue: () =>
          _isCurrentRemoteSelection(track, requestId, expectedQueueEntryId),
      onResolverFailure: (source, error) {
        _showRemoteFallbackNotice(
          source,
          error,
          track,
          requestId,
          expectedQueueEntryId,
        );
      },
    );
    if (!_isCurrentRemoteSelection(track, requestId, expectedQueueEntryId)) {
      return;
    }

    onResolved?.call(refreshed);
    _replaceCurrentRemoteTrack(refreshed);
    _remotePrefetch.invalidate();
    final service = ref.read(playerServiceProvider);
    final loadAttemptId = _beginRemoteLoadAttempt();
    try {
      if (service is NativeRemoteQueuePlayer) {
        await (service as NativeRemoteQueuePlayer).playRemoteSource(
          _networkRemotePlaybackSource(refreshed),
        );
      } else {
        await service.playRemote(refreshed);
      }
      if (_wasRemoteLoadFailureHandled(loadAttemptId) ||
          !_isCurrentRemoteSelection(
            refreshed,
            requestId,
            expectedQueueEntryId,
          )) {
        return;
      }
      final loadedSnapshot = service.currentSnapshot;
      if (loadedSnapshot.status == PlayerStatus.failed &&
          _snapshotBelongsToTrack(loadedSnapshot, refreshed)) {
        throw PlayerException(
          loadedSnapshot.errorMessage ?? 'Remote playback failed.',
          code: 'transient_remote_playback',
        );
      }
    } catch (_) {
      if (_wasRemoteLoadFailureHandled(loadAttemptId)) {
        return;
      }
      rethrow;
    } finally {
      _finishRemoteLoadAttempt(loadAttemptId);
    }
    if (!_isCurrentRemoteSelection(
      refreshed,
      requestId,
      expectedQueueEntryId,
    )) {
      return;
    }
    unawaited(_warmUpcomingRemoteTracks(requestId));
    if (resumePosition > Duration.zero) {
      final duration = refreshed.duration;
      final safeResumePosition = duration != null && resumePosition >= duration
          ? Duration(
              microseconds: math.max(
                0,
                duration.inMicroseconds -
                    const Duration(seconds: 1).inMicroseconds,
              ),
            )
          : resumePosition;
      await service.seek(safeResumePosition);
    }
    _clearPendingRemoteSnapshot(requestId);
  }

  Future<void> _retryOrPublishTerminalRemoteFailure(
    TrackInfo track,
    int requestId, {
    Duration resumePosition = Duration.zero,
    required String? expectedQueueEntryId,
    required Object initialError,
    required StackTrace initialStackTrace,
  }) {
    final key = _remoteRetryKey(track, requestId, expectedQueueEntryId);
    return _remoteRetry.run(
      key: key,
      initialError: initialError,
      initialStackTrace: initialStackTrace,
      isCurrent: () =>
          _isCurrentRemoteSelection(track, requestId, expectedQueueEntryId),
      isCancellation: _isRemoteCancellationError,
      shouldRetry: _shouldRefreshRemoteError,
      delay: ref.read(remotePlaybackRetryDelayProvider),
      onAttempt: (attempt, total) => _showRemoteRetryNotice(
        track,
        requestId,
        expectedQueueEntryId,
        attempt,
        total,
      ),
      runCycle: () => _runCompleteRemotePlaybackRetryCycle(
        track,
        requestId,
        resumePosition: resumePosition,
        expectedQueueEntryId: expectedQueueEntryId,
      ),
      onCancelled: () =>
          _clearCancelledRemoteRetryNotice(requestId, expectedQueueEntryId),
      onTerminal: (error, stackTrace) {
        final failedSnapshot = _remoteTerminalSnapshot(
          track,
          expectedQueueEntryId: expectedQueueEntryId,
          error: error,
        );
        _clearRemoteFallbackNotice();
        _pendingRemoteSnapshot = null;
        _markRemoteTerminalFailure(track, requestId, expectedQueueEntryId);
        final errorState = AsyncError<PlayerSnapshot>(error, stackTrace);
        // Retain the last snapshot so LIVE can identify and skip the failed
        // logical item while the provider still exposes the terminal error.
        // ignore: invalid_use_of_internal_member
        state = errorState.copyWithPrevious(AsyncData(failedSnapshot));
        _scheduleLiveAdvanceAfterTerminalRemoteFailure(
          track,
          requestId,
          expectedQueueEntryId,
        );
      },
      onStale: () =>
          _clearCancelledRemoteRetryNotice(requestId, expectedQueueEntryId),
    );
  }

  PlayerSnapshot _remoteTerminalSnapshot(
    TrackInfo attemptedTrack, {
    required String? expectedQueueEntryId,
    required Object error,
  }) {
    final track = _playingRemoteTrack ?? attemptedTrack;
    final serviceSnapshot = ref.read(playerServiceProvider).currentSnapshot;
    final serviceBelongsToTrack =
        _snapshotBelongsToTrack(serviceSnapshot, track) ||
        _isCachedRemoteSnapshot(serviceSnapshot, track);
    final pending = _pendingRemoteSnapshot;
    final position = serviceBelongsToTrack
        ? serviceSnapshot.position
        : pending?.position ?? Duration.zero;
    final duration =
        track.duration ??
        (serviceBelongsToTrack ? serviceSnapshot.duration : pending?.duration);
    final message = readableAudioStreamError(error).trim();
    return PlayerSnapshot(
      status: PlayerStatus.failed,
      title: track.title,
      artist: track.artist,
      album: track.album,
      trackId: track.id.isEmpty ? track.url : track.id,
      queueEntryId: expectedQueueEntryId ?? _currentRemoteQueueEntryId,
      sourceUrl: track.url,
      thumbnailUrl: _stableRemoteThumbnail(
        track,
        serviceBelongsToTrack
            ? serviceSnapshot.thumbnailUrl
            : pending?.thumbnailUrl,
      ),
      position: position,
      duration: duration,
      volume: serviceSnapshot.volume,
      errorMessage: message.isEmpty ? error.toString() : message,
      isRemote: true,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
    );
  }

  Future<void> _runCompleteRemotePlaybackRetryCycle(
    TrackInfo track,
    int requestId, {
    required Duration resumePosition,
    required String? expectedQueueEntryId,
  }) async {
    TrackInfo? resolvedTrack;
    try {
      await _refreshAndReplayRemote(
        track,
        requestId,
        resumePosition: resumePosition,
        expectedQueueEntryId: expectedQueueEntryId,
        mode: AudioResolutionMode.primaryThenFallback,
        onResolved: (value) => resolvedTrack = value,
      );
      return;
    } catch (error, stackTrace) {
      if (!_isCurrentRemoteSelection(track, requestId, expectedQueueEntryId)) {
        return;
      }
      final rejectedTrack = resolvedTrack;
      if (rejectedTrack == null ||
          !_isYoutubeExplodeStream(rejectedTrack) ||
          !_shouldRecoverRemoteError(rejectedTrack, error)) {
        Error.throwWithStackTrace(error, stackTrace);
      }

      _showRemoteFallbackNotice(
        AudioStreamSource.youtubeExplode,
        error,
        track,
        requestId,
        expectedQueueEntryId,
      );
      await _refreshAndReplayRemote(
        rejectedTrack,
        requestId,
        resumePosition: resumePosition,
        expectedQueueEntryId: expectedQueueEntryId,
        mode: AudioResolutionMode.fallbackOnly,
      );
    }
  }

  void _showRemoteRetryNotice(
    TrackInfo track,
    int requestId,
    String? expectedQueueEntryId,
    int attempt,
    int total,
  ) {
    if (!_isCurrentRemoteSelection(track, requestId, expectedQueueEntryId)) {
      return;
    }
    final message =
        'Conexión inestable. Reintentando $attempt/'
        '$total…';
    _remoteRetry.setNotice(requestId, message);
    final pending = _remoteLoadingSnapshot(
      track,
    ).copyWith(errorMessage: message);
    _pendingRemoteSnapshot = pending;
    state = AsyncData(pending);
  }

  void _clearCancelledRemoteRetryNotice(
    int requestId,
    String? expectedQueueEntryId,
  ) {
    final pending = _pendingRemoteSnapshot;
    if (pending?.queueEntryId != expectedQueueEntryId ||
        (!_isCurrentPlayRequest(requestId) &&
            !_remoteRetry.noticeBelongsTo(requestId))) {
      return;
    }
    _pendingRemoteSnapshot = null;
    _clearRemoteFallbackNotice(requestId);
    if (!_disposed) {
      state = AsyncData(
        _decorateSnapshot(ref.read(playerServiceProvider).currentSnapshot),
      );
    }
  }

  void _scheduleLiveAdvanceAfterTerminalRemoteFailure(
    TrackInfo track,
    int requestId,
    String? expectedQueueEntryId,
  ) {
    if (_activeRemoteQueueSourceId != liveQueueSourceId ||
        _liveTerminalAdvanceScheduledRequestId == requestId ||
        _queueIndex < 0 ||
        _queueIndex >= _queue.length - 1 ||
        !_isCurrentRemoteSelection(track, requestId, expectedQueueEntryId)) {
      return;
    }
    final failedIndex = _queueIndex;
    final navigationGeneration = _queueNavigationGeneration;
    _liveTerminalAdvanceScheduledRequestId = requestId;

    unawaited(
      Future<void>(() async {
        if (_liveTerminalAdvanceScheduledRequestId != requestId ||
            navigationGeneration != _queueNavigationGeneration ||
            _activeRemoteQueueSourceId != liveQueueSourceId ||
            _queueIndex != failedIndex ||
            !_isCurrentRemoteSelection(
              track,
              requestId,
              expectedQueueEntryId,
            ) ||
            failedIndex + 1 >= _queue.length) {
          return;
        }
        await playQueueIndex(failedIndex + 1);
      }).catchError((Object error, StackTrace stackTrace) {
        debugPrint(
          '[PlayerController] LIVE queue could not advance after a terminal '
          'remote failure: $error\n$stackTrace',
        );
      }),
    );
  }

  bool _isCurrentRemoteSelection(
    TrackInfo track,
    int requestId,
    String? expectedQueueEntryId,
  ) {
    if (!_isCurrentPlayRequest(requestId) ||
        (expectedQueueEntryId != null &&
            _currentRemoteQueueEntryId != expectedQueueEntryId)) {
      return false;
    }
    final current = _playingRemoteTrack;
    return current != null &&
        _remoteTrackIdentity(current) == _remoteTrackIdentity(track);
  }

  void _replaceCurrentRemoteTrack(TrackInfo track) {
    if (_queueIndex < 0 || _queueIndex >= _queue.length) {
      return;
    }
    final current = _queue[_queueIndex].remote;
    if (current == null || current.url != track.url) {
      return;
    }
    final next = List<_QueueItem>.of(_queue);
    next[_queueIndex] = next[_queueIndex].withRemoteTrack(track);
    _queue = List.unmodifiable(next);
    _publishPlaybackQueue();
  }

  Future<TrackInfo> _resolveRemoteTrack(
    TrackInfo track, {
    bool forceRefresh = false,
    bool allowStaleStreamFallback = true,
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
    AudioResolverFailureCallback? onResolverFailure,
    AudioResolverContinuationCallback? shouldContinue,
  }) async {
    if (!forceRefresh &&
        !AppPlatform.isAndroid &&
        track.streamUrl != null &&
        track.thumbnailUrl != null) {
      return track;
    }

    return ref
        .read(remoteTrackResolverProvider)
        .resolve(
          track,
          forceRefresh: forceRefresh,
          allowStaleStreamFallback: allowStaleStreamFallback,
          mode: mode,
          onResolverFailure: onResolverFailure,
          shouldContinue: shouldContinue,
        );
  }

  Future<RemotePlaybackSource?> _cachedRemotePlaybackSource(
    TrackInfo track, {
    int? queueIndex,
  }) {
    return RemotePlaybackSourceFactory.cachedSource(
      track: track,
      cachedFile: ref.read(remotePlaybackCacheProvider).cachedFile,
      queueEntryId: _remoteQueueEntryId(queueIndex ?? _queueIndex),
      isOnlyLogicalQueueItem: _queue.length == 1,
    );
  }

  RemotePlaybackSource _networkRemotePlaybackSource(
    TrackInfo track, {
    int? queueIndex,
  }) {
    return RemotePlaybackSourceFactory.network(
      track: track,
      queueEntryId: _remoteQueueEntryId(queueIndex ?? _queueIndex),
      isOnlyLogicalQueueItem: _queue.length == 1,
    );
  }

  String _remoteQueueEntryId(int index) {
    return _remoteQueueEntries.entryIdAt(_queue, index);
  }

  String? get _currentRemoteQueueEntryId {
    return _queueIndex < 0 ? null : _remoteQueueEntryId(_queueIndex);
  }

  Future<LocalTrack?> _cachedRemoteTrack(TrackInfo track) {
    return RemotePlaybackSourceFactory.cachedLocal(
      track: track,
      cachedFile: ref.read(remotePlaybackCacheProvider).cachedFile,
    );
  }

  Future<void> playLocal(
    LocalTrack track, {
    List<LocalTrack>? queue,
    bool useNativeQueue = true,
    String? queueSourceId,
  }) async {
    _resetQueueNavigation();
    _clearRecommendationQueueExtension();
    ref.read(remotePlaybackCacheProvider).cancelPlaybackWarmups();
    _remotePrefetch.invalidate();
    final service = ref.read(playerServiceProvider);
    final isPlaylistQueue = _playlistIdFromQueueSourceId(queueSourceId) != null;
    _useNativeLocalQueue =
        useNativeQueue ||
        (isPlaylistQueue && service.supportsLocalQueueReplacement);
    _activeLocalQueueSourceId = queueSourceId;
    _activeRemoteQueueSourceId = null;
    _previousRemoteTrackForCache = null;
    if (queue != null && queue.isNotEmpty) {
      _queue = List.unmodifiable(queue.map(_QueueItem.local));
      _queueIndex = _queue.indexWhere((item) => item.local?.id == track.id);
      if (_queueIndex < 0) {
        _queue = List.unmodifiable([
          _QueueItem.local(track),
          ...queue.map(_QueueItem.local),
        ]);
        _queueIndex = 0;
      }
    } else {
      _queue = [_QueueItem.local(track)];
      _queueIndex = 0;
    }
    _resetShuffleHistory();
    _publishPlaybackQueue();

    await _playLocalTrack(track);
    unawaited(
      ref
          .read(remotePlaybackCacheProvider)
          .retainOnlyTracks(const <TrackInfo>[]),
    );
  }

  /// Restores the playlist that was active when [track] was last played.
  ///
  /// History rows created before playlist context was introduced, deleted
  /// playlists and tracks removed from their former playlist keep the legacy
  /// behavior by using [fallbackQueue].
  Future<void> playFromHistory(
    LocalTrack track, {
    List<LocalTrack>? fallbackQueue,
  }) async {
    final playlistId = track.lastPlayedPlaylistId?.trim();
    if (playlistId != null && playlistId.isNotEmpty) {
      try {
        final repository = ref.read(libraryRepositoryProvider);
        final playlistsFuture = repository.getPlaylists();
        final tracksFuture = repository.getLocalTracks();
        final playlists = await playlistsFuture;
        final libraryTracks = await tracksFuture;

        Playlist? sourcePlaylist;
        for (final playlist in playlists) {
          if (playlist.id == playlistId) {
            sourcePlaylist = playlist;
            break;
          }
        }

        if (sourcePlaylist != null) {
          final tracksById = {
            for (final libraryTrack in libraryTracks)
              libraryTrack.id: libraryTrack,
          };
          final playlistQueue = sourcePlaylist.trackIds
              .map((trackId) => tracksById[trackId])
              .whereType<LocalTrack>()
              .toList(growable: false);
          final selectedIndex = playlistQueue.indexWhere(
            (candidate) => candidate.id == track.id,
          );
          if (selectedIndex >= 0) {
            await playLocal(
              playlistQueue[selectedIndex],
              queue: playlistQueue,
              useNativeQueue: false,
              queueSourceId: playlistQueueSourceId(playlistId),
            );
            return;
          }
        }
      } catch (error) {
        // History must remain playable if its optional context cannot be read.
        debugPrint('Recently played playlist restore failed: $error');
      }
    }

    await playLocal(track, queue: fallbackQueue);
  }

  void replaceLocalQueue(List<LocalTrack> tracks, {String? currentTrackId}) {
    _resetQueueNavigation();
    if (tracks.isEmpty) {
      _queue = const [];
      _queueIndex = -1;
      _queueNavigation.restoreShuffleState(
        playedIndices: const <int>[],
        plan: const <int>[],
      );
      _useNativeLocalQueue = true;
      _activeLocalQueueSourceId = null;
      _publishPlaybackQueue();
      unawaited(_stageLocalCrossfade());
      return;
    }

    final activeTrackId =
        currentTrackId ??
        state.value?.trackId ??
        ref.read(playerServiceProvider).currentSnapshot.trackId;
    _queue = List.unmodifiable(tracks.map(_QueueItem.local));
    final activeIndex = activeTrackId == null
        ? -1
        : _queue.indexWhere((item) => item.local?.id == activeTrackId);
    if (activeIndex >= 0) {
      _queueIndex = activeIndex;
    } else if (_queueIndex < 0 || _queueIndex >= _queue.length) {
      _queueIndex = 0;
    }
    _resetShuffleHistory();
    _publishPlaybackQueue();
    unawaited(_stageLocalCrossfade());
  }

  static String playlistQueueSourceId(String playlistId) {
    return '$_playlistQueueSourcePrefix$playlistId';
  }

  static String? _playlistIdFromQueueSourceId(String? sourceId) {
    if (sourceId == null || !sourceId.startsWith(_playlistQueueSourcePrefix)) {
      return null;
    }
    final playlistId = sourceId.substring(_playlistQueueSourcePrefix.length);
    return playlistId.isEmpty ? null : playlistId;
  }

  bool isLocalQueueSourceActive(String sourceId) {
    return _activeLocalQueueSourceId == sourceId;
  }

  Future<bool> syncLocalQueueSource(
    String sourceId,
    List<LocalTrack> tracks,
  ) async {
    if (_activeLocalQueueSourceId != sourceId) {
      return false;
    }
    replaceLocalQueue(tracks);
    _activeLocalQueueSourceId = sourceId;
    final service = ref.read(playerServiceProvider);
    final currentSnapshot = state.value ?? service.currentSnapshot;
    final currentTrackId = currentSnapshot.trackId ?? currentSnapshot.sourceUrl;
    final currentTrackStillPresent =
        currentTrackId != null &&
        tracks.any((track) => track.id == currentTrackId);
    if (_useNativeLocalQueue && service.supportsLocalQueueReplacement) {
      await service.replaceLocalQueue(tracks, _queueIndex);
    } else if (!currentTrackStillPresent && !currentSnapshot.isRemote) {
      if (tracks.isNotEmpty) {
        final safeIndex = _queueIndex >= 0 && _queueIndex < tracks.length
            ? _queueIndex
            : 0;
        await service.replaceLocalQueue(tracks, safeIndex);
      } else {
        await service.stop();
      }
    }
    unawaited(_stageLocalCrossfade());
    return true;
  }

  /// Extends or reconciles a logical remote queue without reopening the
  /// currently playing source. Stable per-entry ids keep Android's native
  /// current source mapped correctly even if reconciliation inserts or moves
  /// another item before it.
  Future<bool> syncRemoteQueueSource(
    String sourceId,
    List<TrackInfo> tracks,
  ) async {
    if (_activeRemoteQueueSourceId != sourceId) {
      return false;
    }
    if (tracks.isEmpty) {
      await clearQueueSource(sourceId);
      return true;
    }

    final previousQueue = _queue;
    final previousIndex = _queueIndex;
    final previousCurrent = _playingRemoteTrack;
    final nextQueue = _remoteQueueEntries
        .reconcile(
          tracks.map(_QueueItem.remote).toList(growable: false),
          previousQueue: previousQueue,
        )
        .toList();

    var nextIndex = -1;
    if (previousCurrent != null &&
        previousIndex >= 0 &&
        previousIndex < nextQueue.length &&
        _sameLogicalRemoteTrack(
          nextQueue[previousIndex].remote!,
          previousCurrent,
        )) {
      // Prefer the old numeric position. This is important when two LIVE
      // viewers request the same YouTube video and therefore share an id/url.
      nextIndex = previousIndex;
    } else if (previousCurrent != null) {
      nextIndex = nextQueue.indexWhere(
        (item) => _sameLogicalRemoteTrack(item.remote!, previousCurrent),
      );
    }
    if (nextIndex < 0) {
      nextIndex = previousIndex.clamp(0, nextQueue.length - 1).toInt();
    }

    // Resolution replaces the catalog URL of the active item with a signed
    // stream URL. Preserve that richer object while reconciling the remaining
    // catalog queue; otherwise appending a LIVE request would discard the
    // active transport metadata and trigger unnecessary re-resolution.
    if (previousCurrent != null &&
        nextIndex >= 0 &&
        nextIndex < nextQueue.length &&
        _sameLogicalRemoteTrack(
          nextQueue[nextIndex].remote!,
          previousCurrent,
        )) {
      nextQueue[nextIndex] = _QueueItem.remote(
        previousCurrent,
        remoteQueueEntryId: nextQueue[nextIndex].remoteQueueEntryId,
      );
    }

    _queue = List.unmodifiable(nextQueue);
    _queueIndex = nextIndex;
    _activeRemoteQueueSourceId = sourceId;
    _resetShuffleHistory();
    _publishPlaybackQueue();

    final queueChanged =
        previousQueue.length != _queue.length ||
        previousQueue.asMap().entries.any((entry) {
          if (entry.key >= _queue.length) {
            return true;
          }
          final before = entry.value.remote;
          final after = _queue[entry.key].remote;
          return before == null ||
              after == null ||
              !_sameLogicalRemoteTrack(before, after);
        });
    if (queueChanged) {
      _remotePrefetch.invalidate();
      ref
          .read(remotePlaybackCacheProvider)
          .protectPlaybackWindow(_remoteCacheWindow());
      unawaited(_warmUpcomingRemoteTracks(_playRequestId));
    }
    return true;
  }

  /// Clears a queue owned by [sourceId], regardless of whether it contains
  /// downloaded files or remote streams. Playback itself is intentionally
  /// left to the caller so `clearLiveQueue(stopPlayback: false)` keeps its
  /// existing behavior.
  Future<bool> clearQueueSource(String sourceId) async {
    final localMatches = _activeLocalQueueSourceId == sourceId;
    final remoteMatches = _activeRemoteQueueSourceId == sourceId;
    if (!localMatches && !remoteMatches) {
      return false;
    }

    _resetQueueNavigation();
    if (_recommendationExtension.sourceId == sourceId) {
      _clearRecommendationQueueExtension();
    }

    if (remoteMatches) {
      ref.read(remotePlaybackCacheProvider).cancelPlaybackWarmups();
      _remotePrefetch.invalidate();
    }
    _queue = const [];
    _queueIndex = -1;
    _queueNavigation.restoreShuffleState(
      playedIndices: const <int>[],
      plan: const <int>[],
    );
    _useNativeLocalQueue = true;
    if (localMatches) {
      _activeLocalQueueSourceId = null;
    }
    if (remoteMatches) {
      _activeRemoteQueueSourceId = null;
    }
    _publishPlaybackQueue();

    final service = ref.read(playerServiceProvider);
    if (remoteMatches && service is NativeRemoteQueuePlayer) {
      await (service as NativeRemoteQueuePlayer).updateRemoteQueue(
        const <RemotePlaybackSource>[],
      );
    }
    if (service is CrossfadeCapablePlayer) {
      await _scheduleCrossfadePreparation(null);
    }
    return true;
  }

  Future<void> removeDeletedLocalTracks(Set<String> trackIds) async {
    if (trackIds.isEmpty) {
      return;
    }

    final snapshot =
        state.value ?? ref.read(playerServiceProvider).currentSnapshot;
    final removedCurrent =
        !snapshot.isRemote &&
        snapshot.trackId != null &&
        trackIds.contains(snapshot.trackId);
    final removedQueuedLocal = _queue.any(
      (item) => item.local != null && trackIds.contains(item.local!.id),
    );
    if (!removedCurrent && !removedQueuedLocal) {
      // Deleting a library item must never reconcile the local backend over
      // an unrelated remote queue (where `_localQueue` is intentionally null).
      return;
    }
    _removeLocalTracksFromQueue(trackIds);
    final localQueue = _localQueue ?? const <LocalTrack>[];
    final service = ref.read(playerServiceProvider);

    if (removedCurrent) {
      await stop();
      if (_useNativeLocalQueue && service.supportsLocalQueueReplacement) {
        // stop() deliberately preserves the controller queue, while the native
        // player may still hold sources for files that are about to be deleted.
        // Reconcile after stopping so playback remains stopped and every stale
        // source is released before the filesystem cleanup begins.
        await service.replaceLocalQueue(localQueue, 0);
      }
      return;
    }

    if (_useNativeLocalQueue && service.supportsLocalQueueReplacement) {
      await service.replaceLocalQueue(localQueue, _queueIndex);
      unawaited(_stageLocalCrossfade());
    }
  }

  Future<_LocalPlaybackAttempt> _playLocalTrack(
    LocalTrack track, {
    bool publishFailure = true,
  }) async {
    _activePlaybackIsRemote = false;
    final requestId = ++_playRequestId;
    _changingLocalTrackRequestId = requestId;
    _pendingRemoteSnapshot = null;
    _remoteRetry.resetLoadAndFailureState();
    try {
      if (!track.isExternal && await _purgeLocalTrackIfMissing(track)) {
        return _LocalPlaybackAttempt.unavailable;
      }
      if (!_isCurrentPlayRequest(requestId)) {
        return _LocalPlaybackAttempt.cancelled;
      }

      _explicitlyStopped = false;
      final service = ref.read(playerServiceProvider);
      await _syncNativePlaybackOptions();
      if (!_isCurrentPlayRequest(requestId)) {
        return _LocalPlaybackAttempt.cancelled;
      }
      final localQueue = _localQueue;
      if (_useNativeLocalQueue &&
          localQueue != null &&
          localQueue.isNotEmpty &&
          _queueIndex >= 0) {
        await service.playLocalQueue(localQueue, _queueIndex);
      } else {
        await service.playLocal(track);
      }
      if (!_isCurrentPlayRequest(requestId)) {
        return _LocalPlaybackAttempt.cancelled;
      }
      _changingLocalTrackRequestId = null;
      if (_startPendingHybridLocalFallback(requestId)) {
        return _LocalPlaybackAttempt.played;
      }
      if (_isCurrentPlayRequest(requestId)) {
        unawaited(_stageLocalCrossfade());
      }
      return _LocalPlaybackAttempt.played;
    } catch (error, stackTrace) {
      if (_isCurrentPlayRequest(requestId)) {
        _pendingHybridLocalFailureEntryId = null;
        if (publishFailure) {
          state = AsyncError(error, stackTrace);
        } else {
          debugPrint(
            '[PlayerController] local source failed; using its catalog '
            'fallback: $error',
          );
        }
        return _LocalPlaybackAttempt.unavailable;
      }
      return _LocalPlaybackAttempt.cancelled;
    } finally {
      if (_changingLocalTrackRequestId == requestId) {
        _changingLocalTrackRequestId = null;
      }
    }
  }

  Future<bool> _purgeLocalTrackIfMissing(LocalTrack track) async {
    try {
      final result = await ref
          .read(localLibraryReconcilerProvider)
          .reconcile(tracks: [track]);
      if (!result.changed) {
        return false;
      }

      _removeLocalTracksFromQueue(result.removedTrackIds);
      ref
        ..invalidate(libraryTracksProvider)
        ..invalidate(historyProvider)
        ..invalidate(playlistsControllerProvider);
      return result.removedTrackIds.contains(track.id);
    } catch (error) {
      // A transient filesystem/database error should not block a playable file.
      debugPrint('Local track availability check failed: $error');
      return false;
    }
  }

  void _removeLocalTracksFromQueue(Set<String> trackIds) {
    if (trackIds.isEmpty || _queue.isEmpty) {
      return;
    }

    final activeId = _queueIndex >= 0 && _queueIndex < _queue.length
        ? _queue[_queueIndex].id
        : null;
    final nextQueue = <_QueueItem>[];
    var changed = false;
    for (final item in _queue) {
      final local = item.local;
      if (local == null || !trackIds.contains(local.id)) {
        nextQueue.add(item);
      } else if (item.remote != null) {
        // A synchronized/catalog-backed entry survives removal of its local
        // file. Its next playback transparently falls back to streaming.
        nextQueue.add(item.withoutLocal());
        changed = true;
      } else {
        changed = true;
      }
    }
    if (!changed) {
      return;
    }

    _resetQueueNavigation();
    _queue = List.unmodifiable(nextQueue);
    _queueIndex = activeId == null
        ? -1
        : _queue.indexWhere((item) => item.id == activeId);
    if (_queue.isEmpty) {
      _useNativeLocalQueue = true;
      _activeLocalQueueSourceId = null;
    }
    _resetShuffleHistory();
    _publishPlaybackQueue();
  }

  Future<void> pause() async {
    await ref.read(playerServiceProvider).pause();
  }

  Future<void> resume() async {
    final snapshot =
        state.value ?? ref.read(playerServiceProvider).currentSnapshot;
    if ((snapshot.status == PlayerStatus.stopped ||
            snapshot.status == PlayerStatus.completed ||
            _explicitlyStopped) &&
        _queueIndex >= 0 &&
        _queueIndex < _queue.length) {
      await _playQueueItem(_queue[_queueIndex]);
      return;
    }
    _explicitlyStopped = false;
    await ref.read(playerServiceProvider).resume();
  }

  Future<void> togglePlayPause() async {
    final snapshot =
        state.value ?? ref.read(playerServiceProvider).currentSnapshot;
    if ((snapshot.status == PlayerStatus.stopped ||
            snapshot.status == PlayerStatus.completed) &&
        _queueIndex >= 0 &&
        _queueIndex < _queue.length) {
      await _playQueueItem(_queue[_queueIndex]);
      return;
    }
    await ref.read(playerServiceProvider).togglePlayPause();
  }

  Future<void> playPrevious() async {
    _resetQueueNavigation();
    if (_queue.isEmpty) {
      return;
    }
    final previousRemoteTrack = _playingRemoteTrack;
    _queueIndex = _queueNavigation.previousIndex();
    if (_queue[_queueIndex].remote != null) {
      _previousRemoteTrackForCache = previousRemoteTrack;
    }
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    unawaited(_maybeExtendRecommendationQueue());
    await _playQueueItem(_queue[_queueIndex]);
  }

  void _resetQueueNavigation() {
    // Invalidate a Next that may be suspended while related radio is loading.
    // _playRequestId protects player I/O, while this generation also protects
    // the logical index before that obsolete operation starts new I/O.
    _queueNavigationGeneration++;
    _nextNavigationInFlight = null;
    _hybridLocalFallbackEntryId = null;
    _pendingHybridLocalFailureEntryId = null;
  }

  Future<void> playNext({bool automatic = false}) {
    final inFlight = _nextNavigationInFlight;
    if (inFlight != null) {
      return inFlight;
    }

    final generation = _queueNavigationGeneration;
    final operation = _performPlayNext(
      automatic: automatic,
      navigationGeneration: generation,
    );
    _nextNavigationInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_nextNavigationInFlight, operation)) {
        _nextNavigationInFlight = null;
      }
    });
  }

  Future<void> _performPlayNext({
    required bool automatic,
    required int navigationGeneration,
  }) async {
    if (navigationGeneration != _queueNavigationGeneration) {
      return;
    }
    if (_queue.isEmpty) {
      return;
    }
    if (automatic && _repeatMode == PlaybackRepeatMode.one) {
      await _playQueueItem(_queue[_queueIndex], automaticTransition: true);
      return;
    }

    final waitsForRecommendationGrowth = _shuffleEnabled
        ? () {
            _ensureShufflePlan();
            return _shufflePlan.isEmpty;
          }()
        : _queueIndex >= _queue.length - 1;
    if (waitsForRecommendationGrowth) {
      await _maybeExtendRecommendationQueue(atQueueEnd: true);
      if (navigationGeneration != _queueNavigationGeneration ||
          _queue.isEmpty ||
          _queueIndex < 0 ||
          _queueIndex >= _queue.length) {
        return;
      }
    }

    if (navigationGeneration != _queueNavigationGeneration) {
      return;
    }
    final nextIndex = _nextQueueIndex(automatic: automatic);
    if (nextIndex < 0) {
      return;
    }

    final previousRemoteTrack = _playingRemoteTrack;
    _queueIndex = nextIndex;
    if (_queue[_queueIndex].remote != null) {
      _previousRemoteTrackForCache = previousRemoteTrack;
    }
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    unawaited(_maybeExtendRecommendationQueue());
    await _playQueueItem(_queue[_queueIndex], automaticTransition: automatic);
  }

  Future<void> playQueueIndex(int index) async {
    _resetQueueNavigation();
    if (index < 0 || index >= _queue.length || index == _queueIndex) {
      return;
    }
    final previousRemoteTrack = _playingRemoteTrack;
    _queueIndex = index;
    if (_queue[_queueIndex].remote != null) {
      _previousRemoteTrackForCache = previousRemoteTrack;
    }
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    unawaited(_maybeExtendRecommendationQueue());
    await _playQueueItem(_queue[index]);
  }

  /// Reorders only the active playback queue. The library/playlist itself is
  /// left unchanged. On Android, just_audio receives the same order so its
  /// native next-track behavior stays in sync without restarting the current
  /// item.
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex >= _queue.length ||
        oldIndex == newIndex ||
        _queue.length < 2) {
      return;
    }
    _resetQueueNavigation();

    _queueNavigation.reorder(oldIndex, newIndex);
    _resetShuffleHistory();
    _publishPlaybackQueue();

    final localQueue = _localQueue;
    final service = ref.read(playerServiceProvider);
    if (_useNativeLocalQueue &&
        localQueue != null &&
        service.supportsLocalQueueReplacement) {
      await service.replaceLocalQueue(localQueue, _queueIndex);
      unawaited(_stageLocalCrossfade());
      return;
    }
    if (_queueIndex >= 0 &&
        _queueIndex < _queue.length &&
        _queue[_queueIndex].remote != null) {
      _remotePrefetch.invalidate();
      unawaited(_warmUpcomingRemoteTracks(_playRequestId));
    } else {
      unawaited(_stageLocalCrossfade());
    }
  }

  Future<void> stop() async {
    _resetQueueNavigation();
    ref.read(remotePlaybackCacheProvider).cancelPlaybackWarmups();
    _remotePrefetch.invalidate();
    _invalidateCrossfadePreparations();
    _playRequestId++;
    _changingLocalTrackRequestId = null;
    _pendingRemoteSnapshot = null;
    _remoteRetry.resetLoadAndFailureState();
    _explicitlyStopped = true;
    await ref.read(playerServiceProvider).stop();
    await _scheduleCrossfadePreparation(null);
    await ref
        .read(remotePlaybackCacheProvider)
        .retainOnlyTracks(const <TrackInfo>[]);
  }

  Future<void> seek(Duration position) async {
    final seekRequestId = ++_seekRequestId;
    final playRequestId = _playRequestId;
    await ref.read(playerServiceProvider).seek(position);
    if (_disposed ||
        seekRequestId != _seekRequestId ||
        playRequestId != _playRequestId) {
      return;
    }
    if (_playingRemoteTrack != null) {
      _remotePrefetch.invalidate();
      unawaited(_warmUpcomingRemoteTracks(_playRequestId));
    } else {
      unawaited(_stageLocalCrossfade());
    }
  }

  Future<void> setVolume(double volume) async {
    await ref.read(playerServiceProvider).setVolume(volume);
  }

  void toggleShuffle() {
    setShuffleEnabled(!_shuffleEnabled);
  }

  void setShuffleEnabled(bool enabled) {
    if (_shuffleEnabled == enabled) {
      return;
    }
    _resetQueueNavigation();
    _shuffleEnabled = enabled;
    _resetShuffleHistory();
    _syncPlaybackOptions();
    _remotePrefetch.invalidate();
    unawaited(_warmUpcomingRemoteTracks(_playRequestId));
    unawaited(_stageLocalCrossfade());
  }

  void cycleRepeatMode() {
    setRepeatMode(switch (_repeatMode) {
      PlaybackRepeatMode.off => PlaybackRepeatMode.all,
      PlaybackRepeatMode.all => PlaybackRepeatMode.one,
      PlaybackRepeatMode.one => PlaybackRepeatMode.off,
    });
  }

  void setRepeatMode(PlaybackRepeatMode mode) {
    if (_repeatMode == mode) {
      return;
    }
    _resetQueueNavigation();
    _repeatMode = mode;
    _syncPlaybackOptions();
    _remotePrefetch.invalidate();
    unawaited(_warmUpcomingRemoteTracks(_playRequestId));
    unawaited(_stageLocalCrossfade());
  }

  Future<void> _playQueueItem(
    _QueueItem item, {
    bool automaticTransition = false,
  }) async {
    final local = item.local;
    if (local != null) {
      final result = await _playLocalTrack(
        local,
        publishFailure: item.remote == null,
      );
      if (result == _LocalPlaybackAttempt.played ||
          result == _LocalPlaybackAttempt.cancelled) {
        return;
      }
    }

    final remote = item.remote;
    if (remote != null) {
      await _playRemoteTrack(remote, automaticTransition: automaticTransition);
    }
  }

  Future<void> _warmUpcomingRemoteTracks(int requestId) async {
    final cache = ref.read(remotePlaybackCacheProvider);
    final service = ref.read(playerServiceProvider);
    final plan = _remotePrefetchPlan();
    if (plan == null) {
      return;
    }
    await _remotePrefetch.prepare(
      plan: plan,
      cacheEnabled: cache.isEnabled,
      isCurrent: () =>
          _isRemotePrefetchCurrent(requestId, plan.currentQueueEntryId),
      retainOnlyTracks: (tracks) => cache.retainOnlyTracks(tracks),
      cachedFile: cache.cachedFile,
      warmResolved: cache.warmResolved,
      resolve: (track, shouldContinue) =>
          _resolveRemoteTrack(track, shouldContinue: shouldContinue),
      networkSource: (track, queueIndex) =>
          _networkRemotePlaybackSource(track, queueIndex: queueIndex),
      service: service,
      prepareCrossfade: service is CrossfadeCapablePlayer
          ? _scheduleCrossfadePreparation
          : null,
    );
  }

  Future<void> _stageLocalCrossfade() async {
    LocalTrack? successor;
    if (_queue.length > 1 &&
        _queueIndex >= 0 &&
        _queueIndex < _queue.length &&
        _queue[_queueIndex].local != null &&
        _repeatMode != PlaybackRepeatMode.one) {
      int nextIndex;
      if (_shuffleEnabled) {
        _ensureShufflePlan();
        nextIndex = _shufflePlan.isEmpty ? -1 : _shufflePlan.first;
      } else if (_queueIndex < _queue.length - 1) {
        nextIndex = _queueIndex + 1;
      } else {
        nextIndex = _repeatMode == PlaybackRepeatMode.all ? 0 : -1;
      }
      if (nextIndex >= 0 && nextIndex < _queue.length) {
        successor = _queue[nextIndex].local;
      }
    }
    await _scheduleCrossfadePreparation(
      successor == null ? null : LocalCrossfadePlaybackSource(successor),
    );
  }

  void _invalidateCrossfadePreparations() {
    _crossfadePreparation.invalidate();
  }

  Future<void> _scheduleCrossfadePreparation(CrossfadePlaybackSource? source) {
    return _crossfadePreparation.schedule(
      isDisposed: () => _disposed,
      service: () => ref.read(playerServiceProvider),
      source: source,
      onError: (error, stackTrace) {
        debugPrint('Crossfade preparation failed: $error\n$stackTrace');
      },
    );
  }

  bool _isRemotePrefetchCurrent(int requestId, String currentQueueEntryId) {
    return _isCurrentPlayRequest(requestId) &&
        _playingRemoteTrack != null &&
        _currentRemoteQueueEntryId == currentQueueEntryId;
  }

  RemotePrefetchPlan? _remotePrefetchPlan() {
    if (_shuffleEnabled) {
      _ensureShufflePlan();
    }
    return RemotePrefetchPlanner.build(
      queue: _queue.map((item) => item.remote).toList(growable: false),
      currentIndex: _queueIndex,
      queueGeneration: _remoteQueueEntries.generation,
      queueEntryIds: _queue
          .map((item) => item.remoteQueueEntryId)
          .toList(growable: false),
      shuffleEnabled: _shuffleEnabled,
      shufflePlan: _shufflePlan,
      repeatMode: _repeatMode,
      actualPreviousTrack: _previousRemoteTrackForCache,
      depth: _remotePrefetchDepth,
    );
  }

  List<TrackInfo> _remoteCacheWindow() {
    return _remotePrefetchPlan()?.cacheWindow ?? const <TrackInfo>[];
  }

  String _remoteTrackIdentity(TrackInfo track) {
    return PlaybackIdentity.remoteTrack(track);
  }

  bool _sameLogicalRemoteTrack(TrackInfo first, TrackInfo second) {
    return PlaybackIdentity.sameRemoteTrack(first, second);
  }

  List<LocalTrack>? get _localQueue {
    if (_queue.isEmpty || _queue.any((item) => item.local == null)) {
      return null;
    }
    return _queue.map((item) => item.local!).toList(growable: false);
  }

  bool _syncQueueIndexFromSnapshot(PlayerSnapshot snapshot) {
    if (_changingLocalTrack) {
      return false;
    }
    final trackId = snapshot.trackId;
    if (trackId == null || trackId.isEmpty || _queue.isEmpty) {
      return false;
    }

    var index = -1;
    final queueEntryId = snapshot.queueEntryId;
    if (queueEntryId != null && queueEntryId.isNotEmpty) {
      for (var candidate = 0; candidate < _queue.length; candidate++) {
        if (_queue[candidate].remote != null &&
            _remoteQueueEntryId(candidate) == queueEntryId) {
          index = candidate;
          break;
        }
      }
    }
    if (index < 0) {
      index = _queue.indexWhere(
        (item) =>
            item.local?.id == trackId ||
            item.remote?.id == trackId ||
            item.remote?.url == trackId ||
            item.id == trackId,
      );
    }
    if (index < 0) {
      return false;
    }
    if (index == _queueIndex) {
      _markCurrentQueueIndexPlayed();
      return false;
    }
    _queueIndex = index;
    _remoteRetry.resetLoadAndFailureState();
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    return true;
  }

  void _observePlaybackHistory(PlayerSnapshot snapshot) {
    _playbackHistoryTracker?.update(
      track: _playbackHistoryTrackFor(snapshot),
      status: snapshot.status,
    );
  }

  PlaybackHistoryTrack? _playbackHistoryTrackFor(PlayerSnapshot snapshot) {
    if (snapshot.isExternal ||
        _queueIndex < 0 ||
        _queueIndex >= _queue.length) {
      return null;
    }

    final item = _queue[_queueIndex];
    final local = item.local;
    if (local != null && snapshot.trackId == local.id) {
      return PlaybackHistoryTrackFactory.local(
        snapshot: snapshot,
        track: local,
        playRequestId: _playRequestId,
        queueIndex: _queueIndex,
        queueSourceId: _activeLocalQueueSourceId,
        playlistId: _playlistIdFromQueueSourceId(_activeLocalQueueSourceId),
        isFavorite: ref.read(favoriteTrackIdsProvider).contains(local.id),
      );
    }

    final remote = item.remote;
    if (remote != null) {
      return PlaybackHistoryTrackFactory.remote(
        snapshot: snapshot,
        track: remote,
        expectedQueueEntryId: _currentRemoteQueueEntryId,
      );
    }

    if (local == null) {
      return null;
    }
    return PlaybackHistoryTrackFactory.local(
      snapshot: snapshot,
      track: local,
      playRequestId: _playRequestId,
      queueIndex: _queueIndex,
      queueSourceId: _activeLocalQueueSourceId,
      playlistId: _playlistIdFromQueueSourceId(_activeLocalQueueSourceId),
      isFavorite: ref.read(favoriteTrackIdsProvider).contains(local.id),
    );
  }

  /// Quiesces pending writes before recommendation rows are deleted.
  Future<void> resetRecommendationHistoryTracking() async {
    await _playbackHistoryTracker?.reset();
  }

  /// Prevents playback snapshots from writing into a database while a backup
  /// transaction replaces it. Pending writes are fully drained first.
  Future<void> suspendRecommendationHistoryTracking() async {
    _recommendationHistorySuspended = true;
    await _playbackHistoryTracker?.setEnabled(false);
  }

  Future<void> resumeRecommendationHistoryTracking() async {
    _recommendationHistorySuspended = false;
    if (_disposed) {
      return;
    }
    final enabled =
        ref
            .read(settingsControllerProvider)
            .asData
            ?.value
            .recommendationHistoryEnabled ??
        false;
    final tracker = _playbackHistoryTracker;
    await tracker?.setEnabled(enabled);
    if (enabled &&
        tracker != null &&
        identical(_playbackHistoryTracker, tracker)) {
      final service = ref.read(playerServiceProvider);
      final current = state.value ?? service.currentSnapshot;
      _observePlaybackHistory(_decorateSnapshot(current));
    }
  }

  void _publishPlaybackQueue() {
    ref
        .read(playbackQueueProvider.notifier)
        .replace(
          _queue.map((item) => item.presentation).toList(growable: false),
          _queueIndex,
        );
  }

  int _nextQueueIndex({required bool automatic}) {
    return _queueNavigation.nextIndex(automatic: automatic);
  }

  void _ensureShufflePlan() {
    _queueNavigation.ensureShufflePlan();
  }

  void _resetShuffleHistory() {
    _queueNavigation.resetShuffleHistory();
  }

  void _markCurrentQueueIndexPlayed() {
    _queueNavigation.markCurrentIndexPlayed();
  }

  PlayerSnapshot _decorateSnapshot(PlayerSnapshot snapshot) {
    final remote = _playingRemoteTrack;
    if (remote != null) {
      final cachedRemote = _isCachedRemoteSnapshot(snapshot, remote);
      snapshot = snapshot.copyWith(
        album: remote.album ?? snapshot.album,
        trackId: cachedRemote
            ? (remote.id.isEmpty ? remote.url : remote.id)
            : snapshot.trackId,
        sourceUrl: remote.url,
        // just_audio publishes the MediaItem artwork again after the source
        // is loaded. Keep the artwork selected by the search result instead
        // of allowing extractor metadata to swap in another crop mid-load.
        thumbnailUrl: _stableRemoteThumbnail(remote, snapshot.thumbnailUrl),
        isRemote: true,
      );
    }

    final fallbackNotice = _fallbackNoticeFor(_playRequestId);
    if (fallbackNotice != null && remote != null) {
      if (snapshot.status == PlayerStatus.playing ||
          snapshot.status == PlayerStatus.paused) {
        _clearRemoteFallbackNotice(_playRequestId);
        snapshot = snapshot.copyWith(errorMessage: null);
      } else if (snapshot.status == PlayerStatus.failed) {
        if (_isYtDlpStream(remote)) {
          // The fallback itself failed. Its definitive player error must
          // replace the transient primary-resolver notice and remain visible.
          _clearRemoteFallbackNotice(_playRequestId);
        } else {
          // Some backends publish the rejected primary source through both the
          // load Future and an error stream. Keep the fallback notice until the
          // queue has actually switched to yt-dlp.
          snapshot = snapshot.copyWith(errorMessage: fallbackNotice);
        }
      } else {
        snapshot = snapshot.copyWith(errorMessage: fallbackNotice);
      }
    }

    final pending = _pendingRemoteSnapshot;
    if (pending != null && !_snapshotMatchesPending(snapshot, pending)) {
      return pending.copyWith(
        volume: snapshot.volume,
        // Never borrow artwork from the outgoing snapshot while the new
        // remote item is loading; doing so leaves the player showing the
        // previous cover during a mixed local/stream transition.
        thumbnailUrl: pending.thumbnailUrl ?? snapshot.thumbnailUrl,
        shuffleEnabled: _shuffleEnabled,
        repeatMode: _repeatMode,
      );
    }

    return snapshot.copyWith(
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
    );
  }

  String? _stableRemoteThumbnail(TrackInfo track, [String? fallback]) {
    return PlaybackIdentity.stableRemoteThumbnail(track, fallback);
  }

  bool _isCachedRemoteSnapshot(PlayerSnapshot snapshot, TrackInfo remote) {
    return PlaybackIdentity.cachedRemoteSnapshot(snapshot, remote);
  }

  bool _snapshotMatchesPending(
    PlayerSnapshot snapshot,
    PlayerSnapshot pending,
  ) {
    return PlaybackIdentity.snapshotMatchesPending(snapshot, pending);
  }

  TrackInfo? get _currentRemoteTrack {
    if (_queueIndex < 0 || _queueIndex >= _queue.length) {
      return null;
    }
    return _queue[_queueIndex].remote;
  }

  TrackInfo? get _playingRemoteTrack =>
      _activePlaybackIsRemote ? _currentRemoteTrack : null;

  /// Returns the canonical catalog metadata for the currently playing remote
  /// item. Player actions use this instead of rebuilding a lossy TrackInfo
  /// from the compact playback snapshot.
  TrackInfo? currentRemoteTrackFor(String sourceUrl) {
    final current = _playingRemoteTrack;
    return current != null && current.url == sourceUrl ? current : null;
  }

  void _syncPlaybackOptions() {
    final snapshot =
        state.value ?? ref.read(playerServiceProvider).currentSnapshot;
    state = AsyncData(_decorateSnapshot(snapshot));
    unawaited(_syncNativePlaybackOptions());
  }

  Future<void> _syncNativePlaybackOptions() {
    final desiredShuffle = _useNativeLocalQueue ? _shuffleEnabled : false;
    final desiredRepeat = _useNativeLocalQueue
        ? _repeatMode
        : PlaybackRepeatMode.off;
    return _playbackOptionsSync.synchronize(
      isDisposed: () => _disposed,
      service: () => ref.read(playerServiceProvider),
      shuffleEnabled: desiredShuffle,
      repeatMode: desiredRepeat,
      onSuccess: () => ref.read(playerActionFailureProvider.notifier).clear(),
      onFailure: (error, stackTrace) {
        debugPrint('Playback option sync failed: $error\n$stackTrace');
        ref
            .read(playerActionFailureProvider.notifier)
            .report(
              PlayerActionFailure(
                action: 'sync_playback_options',
                error: error,
                stackTrace: stackTrace,
              ),
            );
      },
    );
  }

  void _maybeHandleCompletion(PlayerSnapshot snapshot) {
    if (_explicitlyStopped ||
        _changingLocalTrack ||
        (snapshot.status == PlayerStatus.failed && snapshot.isRemote) ||
        (snapshot.status != PlayerStatus.stopped &&
            snapshot.status != PlayerStatus.completed &&
            snapshot.status != PlayerStatus.failed) ||
        snapshot.trackId == null ||
        _queue.isEmpty ||
        _queueIndex < 0 ||
        _handlingCompletion) {
      return;
    }

    _handlingCompletion = true;
    Future<void>(() async {
      try {
        await playNext(automatic: true);
      } finally {
        _handlingCompletion = false;
      }
    });
  }
}
