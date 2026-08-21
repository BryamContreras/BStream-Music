part of 'music_providers.dart';

final playerControllerProvider =
    AsyncNotifierProvider<PlayerController, PlayerSnapshot>(
      PlayerController.new,
    );

final playbackQueueProvider =
    NotifierProvider<PlaybackQueueNotifier, PlaybackQueueState>(
      PlaybackQueueNotifier.new,
    );

class PlaybackQueueEntry {
  const PlaybackQueueEntry({
    required this.id,
    required this.title,
    required this.artist,
    required this.isRemote,
    this.album,
    this.thumbnailUrl,
  });

  final String id;
  final String title;
  final String artist;
  final String? album;
  final String? thumbnailUrl;
  final bool isRemote;
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
  const _QueueItem.remote(this.remote) : local = null;

  const _QueueItem.local(this.local) : remote = null;

  final TrackInfo? remote;
  final LocalTrack? local;

  String get id {
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
    );
  }
}

class PlayerController extends AsyncNotifier<PlayerSnapshot> {
  static const _playlistQueueSourcePrefix = 'playlist:';
  static const String liveQueueSourceId = 'tiktok-live';
  static const _remoteCacheTrackIdPrefix = 'remote-cache:';
  static const _remotePrefetchDepth = 3;

  final _random = math.Random();
  List<_QueueItem> _queue = const [];
  int _queueIndex = -1;
  bool _shuffleEnabled = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;
  Set<int> _shufflePlayedIndices = <int>{};
  List<int> _shufflePlan = <int>[];
  bool _handlingCompletion = false;
  int? _changingLocalTrackRequestId;
  bool _explicitlyStopped = false;
  bool _useNativeLocalQueue = true;
  String? _activeLocalQueueSourceId;
  String? _activeRemoteQueueSourceId;

  bool get isLiveQueueActive =>
      _activeLocalQueueSourceId == liveQueueSourceId ||
      _activeRemoteQueueSourceId == liveQueueSourceId;
  int _playRequestId = 0;
  int _seekRequestId = 0;
  int _remoteQueueGeneration = 0;
  int? _remoteRecoveryAttemptedRequestId;
  String? _remoteRecoveryInFlightQueueEntryId;
  String? _invalidatedCachedRemoteIdentity;
  int? _remoteFallbackNoticeRequestId;
  String? _remoteFallbackNotice;
  TrackInfo? _previousRemoteTrackForCache;
  PlayerSnapshot? _pendingRemoteSnapshot;
  String? _lastRecordedLocalTrackId;
  Future<void> _historyWrite = Future<void>.value();
  String? _remotePrefetchSignature;
  Future<void> _crossfadeConfigurationTail = Future<void>.value();
  bool _disposed = false;

  bool get _changingLocalTrack => _changingLocalTrackRequestId != null;

  @override
  Future<PlayerSnapshot> build() async {
    final service = ref.watch(playerServiceProvider);
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
      final previousRemoteTrack = _currentRemoteTrack;
      final failedCachedRemote =
          snapshot.status == PlayerStatus.failed &&
          previousRemoteTrack != null &&
          _isCachedRemoteSnapshot(snapshot, previousRemoteTrack);
      if (failedCachedRemote &&
          _invalidatedCachedRemoteIdentity ==
              _remoteTrackIdentity(previousRemoteTrack)) {
        // MediaKit may report the same failed open through both its Future
        // and error stream. The Future path is already replacing this cache
        // source with the network stream.
        return;
      }
      final queueIndexChanged = _syncQueueIndexFromSnapshot(snapshot);
      if (queueIndexChanged && snapshot.isRemote) {
        // ExoPlayer did not reload, but every pending resolver/cache operation
        // still belongs to the previous logical track and must become stale.
        _playRequestId++;
        _pendingRemoteSnapshot = null;
        _remoteRecoveryInFlightQueueEntryId = null;
        _previousRemoteTrackForCache = previousRemoteTrack;
      }
      final decorated = _decorateSnapshot(snapshot);
      _recordNativeLocalTrackChange(decorated);
      state = AsyncData(decorated);
      if (queueIndexChanged && decorated.isRemote) {
        _remotePrefetchSignature = null;
        unawaited(_warmUpcomingRemoteTracks(_playRequestId));
      } else if (queueIndexChanged) {
        unawaited(_stageLocalCrossfade());
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
      _remoteQueueGeneration++;
      _changingLocalTrackRequestId = null;
      unawaited(subscription.cancel());
    });
    return initialSnapshot;
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
      if (!enabled || !prepareWhenEnabled) {
        return;
      }
      if (_currentRemoteTrack != null) {
        // Enabling in the middle of a track must not be defeated by a cache
        // signature produced while crossfade was disabled.
        _remotePrefetchSignature = null;
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
    final previousRemoteTrack = _currentRemoteTrack;
    _remotePrefetchSignature = null;
    _remoteQueueGeneration++;
    _useNativeLocalQueue = true;
    _activeLocalQueueSourceId = null;
    _activeRemoteQueueSourceId = queueSourceId;
    _previousRemoteTrackForCache = previousRemoteTrack;
    if (queue != null && queue.isNotEmpty) {
      _queue = List.unmodifiable(queue.map(_QueueItem.remote));
      _queueIndex = _queue.indexWhere(
        (item) =>
            item.remote?.url == track.url ||
            (track.id.isNotEmpty && item.remote?.id == track.id),
      );
      if (_queueIndex < 0) {
        _queue = List.unmodifiable([
          _QueueItem.remote(track),
          ...queue.map(_QueueItem.remote),
        ]);
        _queueIndex = 0;
      }
    } else {
      _queue = [_QueueItem.remote(track)];
      _queueIndex = 0;
    }
    _resetShuffleHistory();
    _publishPlaybackQueue();

    await _playRemoteTrack(track);
  }

  Future<void> _playRemoteTrack(
    TrackInfo track, {
    bool automaticTransition = false,
  }) async {
    _explicitlyStopped = false;
    _remotePrefetchSignature = null;
    final requestId = ++_playRequestId;
    _changingLocalTrackRequestId = null;
    _remoteRecoveryInFlightQueueEntryId = null;
    _invalidatedCachedRemoteIdentity = null;
    _clearRemoteFallbackNotice();
    ref
        .read(remotePlaybackCacheProvider)
        .protectPlaybackWindow(_remoteCacheWindow());
    final pendingSnapshot = _remoteLoadingSnapshot(track);
    _pendingRemoteSnapshot = pendingSnapshot;
    state = AsyncData(pendingSnapshot);

    try {
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
        _invalidatedCachedRemoteIdentity = _remoteTrackIdentity(failedTrack);
        unawaited(ref.read(remotePlaybackCacheProvider).evict(failedTrack));
        return _remoteRecoveryInFlightQueueEntryId ==
            pendingSnapshot.queueEntryId;
      }

      if (nativeRemoteService != null) {
        final cachedSource = await _cachedRemotePlaybackSource(track);
        if (!_isCurrentPlayRequest(requestId)) {
          return;
        }
        if (cachedSource != null) {
          try {
            await nativeRemoteService.playRemoteSource(cachedSource);
            _clearPendingRemoteSnapshot(requestId);
            unawaited(_warmUpcomingRemoteTracks(requestId));
            return;
          } catch (_) {
            if (invalidateCachedSource(track)) {
              return;
            }
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
        try {
          await ref.read(playerServiceProvider).playLocal(cachedTrack);
          _clearPendingRemoteSnapshot(requestId);
          unawaited(_warmUpcomingRemoteTracks(requestId));
          return;
        } catch (_) {
          if (invalidateCachedSource(track)) {
            return;
          }
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
          try {
            await nativeRemoteService.playRemoteSource(cachedSource);
            _clearPendingRemoteSnapshot(requestId);
            unawaited(_warmUpcomingRemoteTracks(requestId));
            return;
          } catch (_) {
            if (invalidateCachedSource(playableTrack)) {
              return;
            }
          }
        }
        try {
          await nativeRemoteService.playRemoteSource(
            _networkRemotePlaybackSource(playableTrack),
          );
          _clearPendingRemoteSnapshot(requestId);
          unawaited(_warmUpcomingRemoteTracks(requestId));
          return;
        } catch (error) {
          if (_remoteRecoveryAttemptedRequestId == requestId ||
              _isRemoteRecoveryInFlight(
                requestId,
                pendingSnapshot.queueEntryId,
              )) {
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
          if (_remoteRecoveryAttemptedRequestId != requestId &&
              _shouldRecoverRemoteError(playableTrack, error)) {
            final fallbackOnly = _hasKnownResolverSource(playableTrack);
            if (_isYoutubeExplodeStream(playableTrack)) {
              _showRemoteFallbackNotice(
                AudioStreamSource.youtubeExplode,
                error,
                playableTrack,
                requestId,
                pendingSnapshot.queueEntryId,
              );
            }
            await _refreshAndReplayRemote(
              playableTrack,
              requestId,
              expectedQueueEntryId: pendingSnapshot.queueEntryId,
              mode: fallbackOnly
                  ? AudioResolutionMode.fallbackOnly
                  : AudioResolutionMode.primaryThenFallback,
            );
            return;
          }
          rethrow;
        }
      }

      final cachedPlayableTrack = cachedSourceFailed
          ? null
          : await _cachedRemoteTrack(playableTrack);
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }
      if (cachedPlayableTrack != null) {
        try {
          await ref.read(playerServiceProvider).playLocal(cachedPlayableTrack);
          _clearPendingRemoteSnapshot(requestId);
          unawaited(_warmUpcomingRemoteTracks(requestId));
          return;
        } catch (_) {
          if (invalidateCachedSource(playableTrack)) {
            return;
          }
        }
      }

      try {
        await ref.read(playerServiceProvider).playRemote(playableTrack);
        _clearPendingRemoteSnapshot(requestId);
        unawaited(_warmUpcomingRemoteTracks(requestId));
      } catch (error) {
        if (_remoteRecoveryAttemptedRequestId == requestId ||
            _isRemoteRecoveryInFlight(
              requestId,
              pendingSnapshot.queueEntryId,
            )) {
          // See the native branch above: this can be a late duplicate of the
          // primary failure that already triggered and completed recovery.
          return;
        }
        debugPrint(
          '[PlayerController] playerService.playRemote failed '
          '(hasStreamUrl=${playableTrack.streamUrl != null && playableTrack.streamUrl!.isNotEmpty}): '
          '${readableAudioStreamError(error)}',
        );
        if (_remoteRecoveryAttemptedRequestId != requestId &&
            _shouldRecoverRemoteError(playableTrack, error)) {
          final fallbackOnly = _hasKnownResolverSource(playableTrack);
          if (_isYoutubeExplodeStream(playableTrack)) {
            _showRemoteFallbackNotice(
              AudioStreamSource.youtubeExplode,
              error,
              playableTrack,
              requestId,
              pendingSnapshot.queueEntryId,
            );
          }
          await _refreshAndReplayRemote(
            playableTrack,
            requestId,
            expectedQueueEntryId: pendingSnapshot.queueEntryId,
            mode: fallbackOnly
                ? AudioResolutionMode.fallbackOnly
                : AudioResolutionMode.primaryThenFallback,
          );
          return;
        }
        rethrow;
      }
    } catch (error, stackTrace) {
      if (_isCurrentPlayRequest(requestId)) {
        _clearRemoteFallbackNotice();
        _pendingRemoteSnapshot = null;
        state = AsyncError(error, stackTrace);
      }
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
    _remoteFallbackNoticeRequestId = requestId;
    _remoteFallbackNotice = message;
    final pending = _remoteLoadingSnapshot(
      track,
    ).copyWith(errorMessage: message);
    _pendingRemoteSnapshot = pending;
    state = AsyncData(pending);
  }

  String? _fallbackNoticeFor(int requestId) {
    return _remoteFallbackNoticeRequestId == requestId
        ? _remoteFallbackNotice
        : null;
  }

  void _clearRemoteFallbackNotice([int? requestId]) {
    if (requestId != null && _remoteFallbackNoticeRequestId != requestId) {
      return;
    }
    _remoteFallbackNoticeRequestId = null;
    _remoteFallbackNotice = null;
  }

  bool _isCurrentPlayRequest(int requestId) => requestId == _playRequestId;

  bool _isRemoteRecoveryInFlight(int requestId, String? queueEntryId) {
    return _remoteRecoveryAttemptedRequestId == requestId &&
        _remoteRecoveryInFlightQueueEntryId == queueEntryId;
  }

  void _clearPendingRemoteSnapshot(int requestId) {
    if (_isCurrentPlayRequest(requestId)) {
      _pendingRemoteSnapshot = null;
      final hadFallbackNotice = _remoteFallbackNoticeRequestId == requestId;
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
    final rejectedPrimary =
        !failedCachedRemote && _isYoutubeExplodeStream(track);
    final fallbackOnly = !failedCachedRemote && _hasKnownResolverSource(track);
    if (!failedCachedRemote &&
        !rejectedPrimary &&
        !_shouldRefreshRemoteFailure(snapshot)) {
      return false;
    }

    final requestId = _playRequestId;
    final expectedQueueEntryId =
        snapshot.queueEntryId ?? _currentRemoteQueueEntryId;
    if (_remoteRecoveryAttemptedRequestId == requestId) {
      // A failed remote stream is not a completed song. Keep the failure on
      // the current item instead of silently advancing through the queue.
      return true;
    }

    _remoteRecoveryAttemptedRequestId = requestId;
    _remoteRecoveryInFlightQueueEntryId = expectedQueueEntryId;
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
      _invalidatedCachedRemoteIdentity = _remoteTrackIdentity(track);
      unawaited(ref.read(remotePlaybackCacheProvider).evict(track));
    }
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
    return true;
  }

  bool _snapshotBelongsToTrack(PlayerSnapshot snapshot, TrackInfo track) {
    final trackId = track.id.isEmpty ? track.url : track.id;
    if (snapshot.sourceUrl == track.url) {
      return true;
    }
    final snapshotTrackId = snapshot.trackId?.trim();
    if (snapshotTrackId != null && snapshotTrackId.isNotEmpty) {
      return snapshotTrackId == trackId;
    }
    return false;
  }

  bool _shouldRefreshRemoteFailure(PlayerSnapshot snapshot) {
    return _shouldRefreshRemoteErrorMessage(snapshot.errorMessage);
  }

  bool _shouldRefreshRemoteError(Object error) {
    return _shouldRefreshRemoteErrorMessage(error.toString());
  }

  bool _shouldRecoverRemoteError(TrackInfo track, Object error) {
    if (_isYoutubeExplodeStream(track)) {
      // A URL can resolve successfully but still be rejected by the native
      // backend (403, unsupported container/codec, expired signature, etc.).
      // That is a primary-resolver failure and must reach yt-dlp exactly once.
      return true;
    }
    return _shouldRefreshRemoteError(error);
  }

  bool _hasKnownResolverSource(TrackInfo track) {
    return _isYoutubeExplodeStream(track) || _isYtDlpStream(track);
  }

  bool _isYoutubeExplodeStream(TrackInfo track) {
    return track.streamSource == AudioStreamSource.youtubeExplode.name;
  }

  bool _isYtDlpStream(TrackInfo track) {
    return track.streamSource == AudioStreamSource.ytDlp.name;
  }

  bool _shouldRefreshRemoteErrorMessage(String? rawMessage) {
    final message = rawMessage?.trim().toLowerCase() ?? '';
    if (message.isEmpty) {
      return true;
    }

    const nonRefreshableMarkers = [
      'sign in',
      'not a bot',
      'confirm you',
      'cookies',
      'login required',
      'private video',
      'video unavailable',
      'members-only',
      'drm',
      'unrecognized input',
      'parserexception',
      'decoder',
      'format is not supported',
      'requested format is not available',
    ];
    if (nonRefreshableMarkers.any(message.contains)) {
      return false;
    }

    // Native backends use different messages for expired URLs, transport
    // failures and cache failures. Keep the existing one-refresh recovery for
    // unknown errors, while the definitive markers above prevent useless
    // retries for authentication, bot and format failures.
    return true;
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
    final pending = _pendingRemoteSnapshot;
    if (pending != null &&
        pending.queueEntryId != queueEntryId &&
        _remoteRecoveryInFlightQueueEntryId != pending.queueEntryId) {
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
    final current = _currentRemoteTrack;
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
      await _refreshAndReplayRemote(
        track,
        requestId,
        resumePosition: resumePosition,
        expectedQueueEntryId: expectedQueueEntryId,
        mode: mode,
      );
    } catch (error, stackTrace) {
      if (_isCurrentRemoteSelection(track, requestId, expectedQueueEntryId)) {
        _clearRemoteFallbackNotice();
        _pendingRemoteSnapshot = null;
        state = AsyncError(error, stackTrace);
      }
    } finally {
      if (_remoteRecoveryInFlightQueueEntryId == expectedQueueEntryId) {
        _remoteRecoveryInFlightQueueEntryId = null;
      }
    }
  }

  Future<void> _refreshAndReplayRemote(
    TrackInfo track,
    int requestId, {
    Duration resumePosition = Duration.zero,
    required String? expectedQueueEntryId,
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
  }) async {
    if (!_isCurrentRemoteSelection(track, requestId, expectedQueueEntryId)) {
      return;
    }
    _remoteRecoveryAttemptedRequestId = requestId;
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

    _replaceCurrentRemoteTrack(refreshed);
    _remotePrefetchSignature = null;
    final service = ref.read(playerServiceProvider);
    if (service is NativeRemoteQueuePlayer) {
      await (service as NativeRemoteQueuePlayer).playRemoteSource(
        _networkRemotePlaybackSource(refreshed),
      );
    } else {
      await service.playRemote(refreshed);
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
    final current = _currentRemoteTrack;
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
    next[_queueIndex] = _QueueItem.remote(track);
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
  }) async {
    final file = await ref.read(remotePlaybackCacheProvider).cachedFile(track);
    if (file == null) {
      return null;
    }
    try {
      if (!await file.exists() || await file.length() == 0) {
        return null;
      }
      return RemotePlaybackSource(
        track: track,
        uri: file.uri,
        queueEntryId: _remoteQueueEntryId(queueIndex ?? _queueIndex),
        isOnlyLogicalQueueItem: _queue.length == 1,
      );
    } catch (_) {
      return null;
    }
  }

  RemotePlaybackSource _networkRemotePlaybackSource(
    TrackInfo track, {
    int? queueIndex,
  }) {
    return RemotePlaybackSource(
      track: track,
      uri: Uri.parse(track.streamUrl!),
      queueEntryId: _remoteQueueEntryId(queueIndex ?? _queueIndex),
      httpHeaders: track.httpHeaders,
      isOnlyLogicalQueueItem: _queue.length == 1,
    );
  }

  String _remoteQueueEntryId(int index) {
    return 'remote:$_remoteQueueGeneration:$index';
  }

  String? get _currentRemoteQueueEntryId {
    return _queueIndex < 0 ? null : _remoteQueueEntryId(_queueIndex);
  }

  Future<LocalTrack?> _cachedRemoteTrack(TrackInfo track) async {
    final file = await ref.read(remotePlaybackCacheProvider).cachedFile(track);
    if (file == null) {
      return null;
    }

    try {
      if (!await file.exists() || await file.length() == 0) {
        return null;
      }
      final identity = track.id.isEmpty ? track.url : track.id;
      return LocalTrack(
        id: '$_remoteCacheTrackIdPrefix${identity.hashCode}',
        title: track.title,
        artist: track.artist,
        filePath: file.path,
        addedAt: await file.lastModified(),
        sourceUrl: track.url,
        thumbnailUrl: track.thumbnailUrl,
        catalogThumbnailUrl: track.catalogThumbnailUrl,
        duration: track.duration,
        album: track.album,
        artists: track.artists,
        metadataSource: track.metadataSource,
        sourceId: track.id.trim().isEmpty ? null : track.id,
      );
    } catch (_) {
      // A maintenance pass can evict the entry between lookup and playback.
      return null;
    }
  }

  Future<void> playLocal(
    LocalTrack track, {
    List<LocalTrack>? queue,
    bool useNativeQueue = true,
    String? queueSourceId,
  }) async {
    ref.read(remotePlaybackCacheProvider).cancelPlaybackWarmups();
    _remotePrefetchSignature = null;
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
    if (tracks.isEmpty) {
      _queue = const [];
      _queueIndex = -1;
      _shufflePlayedIndices = <int>{};
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
  /// currently playing source. LIVE requests arrive one at a time, so keeping
  /// the existing generation and numeric index also keeps Android's native
  /// `queueEntryId` values stable while new successors are prepared.
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
    final previousCurrent = _currentRemoteTrack;
    final nextQueue = tracks.map(_QueueItem.remote).toList(growable: false);

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
      nextQueue[nextIndex] = _QueueItem.remote(previousCurrent);
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
      _remotePrefetchSignature = null;
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

    if (remoteMatches) {
      ref.read(remotePlaybackCacheProvider).cancelPlaybackWarmups();
      _remotePrefetchSignature = null;
    }
    _queue = const [];
    _queueIndex = -1;
    _shufflePlayedIndices = <int>{};
    _shufflePlan = <int>[];
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
      await (service as CrossfadeCapablePlayer).prepareCrossfade(null);
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

  Future<void> _playLocalTrack(LocalTrack track) async {
    final requestId = ++_playRequestId;
    _changingLocalTrackRequestId = requestId;
    _pendingRemoteSnapshot = null;
    _remoteRecoveryInFlightQueueEntryId = null;
    try {
      if (!track.isExternal && await _purgeLocalTrackIfMissing(track)) {
        return;
      }
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }

      _explicitlyStopped = false;
      final service = ref.read(playerServiceProvider);
      await service.setShuffleEnabled(
        _useNativeLocalQueue ? _shuffleEnabled : false,
      );
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }
      await service.setRepeatMode(
        _useNativeLocalQueue ? _repeatMode : PlaybackRepeatMode.off,
      );
      if (!_isCurrentPlayRequest(requestId)) {
        return;
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
        return;
      }
      // The service emits several loading/position snapshots for an explicit
      // request. Claim the transition before persisting it so the stream
      // observer cannot write the same play a second time.
      _lastRecordedLocalTrackId = track.id;
      _changingLocalTrackRequestId = null;
      if (!track.isExternal) {
        await _recordLocalTrackPlayed(track.id);
      }
      if (_isCurrentPlayRequest(requestId)) {
        unawaited(_stageLocalCrossfade());
      }
    } catch (error, stackTrace) {
      if (_isCurrentPlayRequest(requestId)) {
        state = AsyncError(error, stackTrace);
      }
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
    final nextQueue = _queue
        .where(
          (item) => item.local == null || !trackIds.contains(item.local!.id),
        )
        .toList(growable: false);
    if (nextQueue.length == _queue.length) {
      return;
    }

    _queue = List.unmodifiable(nextQueue);
    _queueIndex = activeId == null || trackIds.contains(activeId)
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
    if (_queue.isEmpty) {
      return;
    }
    final previousRemoteTrack = _currentRemoteTrack;
    _queueIndex = _queueIndex <= 0 ? _queue.length - 1 : _queueIndex - 1;
    if (_queue[_queueIndex].remote != null) {
      _previousRemoteTrackForCache = previousRemoteTrack;
    }
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    await _playQueueItem(_queue[_queueIndex]);
  }

  Future<void> playNext({bool automatic = false}) async {
    if (_queue.isEmpty) {
      return;
    }
    if (automatic && _repeatMode == PlaybackRepeatMode.one) {
      await _playQueueItem(_queue[_queueIndex], automaticTransition: true);
      return;
    }

    final nextIndex = _nextQueueIndex(automatic: automatic);
    if (nextIndex < 0) {
      return;
    }

    final previousRemoteTrack = _currentRemoteTrack;
    _queueIndex = nextIndex;
    if (_queue[_queueIndex].remote != null) {
      _previousRemoteTrackForCache = previousRemoteTrack;
    }
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    await _playQueueItem(_queue[_queueIndex], automaticTransition: automatic);
  }

  Future<void> playQueueIndex(int index) async {
    if (index < 0 || index >= _queue.length || index == _queueIndex) {
      return;
    }
    final previousRemoteTrack = _currentRemoteTrack;
    _queueIndex = index;
    if (_queue[_queueIndex].remote != null) {
      _previousRemoteTrackForCache = previousRemoteTrack;
    }
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
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

    final nextQueue = List<_QueueItem>.of(_queue);
    final moved = nextQueue.removeAt(oldIndex);
    nextQueue.insert(newIndex, moved);

    final currentIndex = _queueIndex;
    if (currentIndex == oldIndex) {
      _queueIndex = newIndex;
    } else if (oldIndex < currentIndex && newIndex >= currentIndex) {
      _queueIndex = currentIndex - 1;
    } else if (oldIndex > currentIndex && newIndex <= currentIndex) {
      _queueIndex = currentIndex + 1;
    }

    _queue = List.unmodifiable(nextQueue);
    if (_queue.any((item) => item.remote != null)) {
      _remoteQueueGeneration++;
    }
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
      _remotePrefetchSignature = null;
      unawaited(_warmUpcomingRemoteTracks(_playRequestId));
    } else {
      unawaited(_stageLocalCrossfade());
    }
  }

  Future<void> stop() async {
    ref.read(remotePlaybackCacheProvider).cancelPlaybackWarmups();
    _remotePrefetchSignature = null;
    _playRequestId++;
    _changingLocalTrackRequestId = null;
    _pendingRemoteSnapshot = null;
    _remoteRecoveryInFlightQueueEntryId = null;
    _explicitlyStopped = true;
    await ref.read(playerServiceProvider).stop();
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
    if (_currentRemoteTrack != null) {
      _remotePrefetchSignature = null;
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
    _shuffleEnabled = enabled;
    _resetShuffleHistory();
    _syncPlaybackOptions();
    _remotePrefetchSignature = null;
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
    _repeatMode = mode;
    _syncPlaybackOptions();
    _remotePrefetchSignature = null;
    unawaited(_warmUpcomingRemoteTracks(_playRequestId));
    unawaited(_stageLocalCrossfade());
  }

  Future<void> _playQueueItem(
    _QueueItem item, {
    bool automaticTransition = false,
  }) async {
    final remote = item.remote;
    if (remote != null) {
      await _playRemoteTrack(remote, automaticTransition: automaticTransition);
      return;
    }

    final local = item.local;
    if (local != null) {
      await _playLocalTrack(local);
    }
  }

  Future<void> _warmUpcomingRemoteTracks(int requestId) async {
    final cache = ref.read(remotePlaybackCacheProvider);
    final service = ref.read(playerServiceProvider);
    final NativeRemoteQueuePlayer? nativeRemoteService =
        service is NativeRemoteQueuePlayer
        ? service as NativeRemoteQueuePlayer
        : null;
    final current = _currentRemoteTrack;
    if (!cache.isEnabled ||
        !_isCurrentPlayRequest(requestId) ||
        current == null) {
      return;
    }

    final currentIdentity = _remoteTrackIdentity(current);
    final currentQueueEntryId = _currentRemoteQueueEntryId;
    if (currentQueueEntryId == null) {
      return;
    }
    final upcoming = _upcomingRemoteEntriesForPrefetch();
    // Protection and cancellation happen synchronously inside the cache.
    // Resolving the next desktop tracks must not wait behind older full-file
    // downloads or a maintenance pass queued after them.
    unawaited(cache.retainOnlyTracks(_remoteCacheWindow()));
    if (!_isRemotePrefetchCurrent(requestId, currentQueueEntryId)) {
      return;
    }
    if (upcoming.isEmpty) {
      _remotePrefetchSignature = null;
      if (service case final CrossfadeCapablePlayer crossfadeService) {
        await crossfadeService.prepareCrossfade(null);
      }
      if (nativeRemoteService != null) {
        await nativeRemoteService.updateRemoteQueue(
          const <RemotePlaybackSource>[],
        );
      }
      return;
    }

    final signature = [
      currentQueueEntryId,
      currentIdentity,
      ...upcoming.expand(
        (entry) => [
          _remoteQueueEntryId(entry.index),
          _remoteTrackIdentity(entry.track),
        ],
      ),
    ].join('\u0000');
    if (_remotePrefetchSignature == signature) {
      return;
    }
    _remotePrefetchSignature = signature;

    var completed = true;
    final preparedSources = <RemotePlaybackSource>[];
    final warmups = <({int sourceIndex, Future<File?> future})>[];
    for (final entry in upcoming) {
      try {
        final track = entry.track;
        final existing = await cache.cachedFile(track);
        if (!_isRemotePrefetchCurrent(requestId, currentQueueEntryId) ||
            _remotePrefetchSignature != signature) {
          return;
        }
        RemotePlaybackSource source;
        if (existing != null) {
          source = RemotePlaybackSource(
            track: track,
            uri: existing.uri,
            queueEntryId: _remoteQueueEntryId(entry.index),
          );
        } else {
          final resolved = await _resolveRemoteTrack(
            track,
            shouldContinue: () =>
                _isRemotePrefetchCurrent(requestId, currentQueueEntryId) &&
                _remotePrefetchSignature == signature,
          );
          if (!_isRemotePrefetchCurrent(requestId, currentQueueEntryId) ||
              _remotePrefetchSignature != signature) {
            return;
          }
          source = _networkRemotePlaybackSource(
            resolved,
            queueIndex: entry.index,
          );
          warmups.add((
            sourceIndex: preparedSources.length,
            future: cache.warmResolved(resolved),
          ));
        }
        preparedSources.add(source);
        if (preparedSources.length == 1 && service is CrossfadeCapablePlayer) {
          final crossfadeService = service as CrossfadeCapablePlayer;
          unawaited(
            crossfadeService.prepareCrossfade(
              RemoteCrossfadePlaybackSource(source),
            ),
          );
        }
        if (nativeRemoteService != null) {
          await nativeRemoteService.updateRemoteQueue(
            preparedSources,
            finalize: false,
          );
        }
        if (!_isRemotePrefetchCurrent(requestId, currentQueueEntryId) ||
            _remotePrefetchSignature != signature) {
          return;
        }
      } catch (_) {
        completed = false;
        // Never put a later source after a missing immediate successor. Native
        // players would otherwise skip the failed queue item silently.
        break;
      }
    }

    if (nativeRemoteService != null &&
        completed &&
        preparedSources.length == upcoming.length &&
        _isRemotePrefetchCurrent(requestId, currentQueueEntryId) &&
        _remotePrefetchSignature == signature) {
      try {
        await nativeRemoteService.updateRemoteQueue(preparedSources);
      } catch (_) {
        completed = false;
      }
    }

    for (final warmup in warmups) {
      try {
        final cached = await warmup.future;
        if (!_isRemotePrefetchCurrent(requestId, currentQueueEntryId) ||
            _remotePrefetchSignature != signature) {
          return;
        }
        if (cached == null) {
          completed = false;
          continue;
        }
        if (nativeRemoteService != null) {
          final previous = preparedSources[warmup.sourceIndex];
          preparedSources[warmup.sourceIndex] = RemotePlaybackSource(
            track: previous.track,
            uri: cached.uri,
            queueEntryId: previous.queueEntryId,
            isOnlyLogicalQueueItem: previous.isOnlyLogicalQueueItem,
          );
          await nativeRemoteService.updateRemoteQueue(preparedSources);
          if (!_isRemotePrefetchCurrent(requestId, currentQueueEntryId) ||
              _remotePrefetchSignature != signature) {
            return;
          }
        }
      } catch (_) {
        completed = false;
      }
    }
    if (!completed &&
        _isRemotePrefetchCurrent(requestId, currentQueueEntryId) &&
        _remotePrefetchSignature == signature) {
      _remotePrefetchSignature = null;
      if (preparedSources.isEmpty && service is CrossfadeCapablePlayer) {
        final crossfadeService = service as CrossfadeCapablePlayer;
        await crossfadeService.prepareCrossfade(null);
      }
    }
  }

  Future<void> _stageLocalCrossfade() async {
    if (_disposed) {
      return;
    }
    final service = ref.read(playerServiceProvider);
    if (service is! CrossfadeCapablePlayer) {
      return;
    }
    final crossfadeService = service as CrossfadeCapablePlayer;
    if (!crossfadeService.crossfadeEnabled) {
      return;
    }
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
    await crossfadeService.prepareCrossfade(
      successor == null ? null : LocalCrossfadePlaybackSource(successor),
    );
  }

  bool _isRemotePrefetchCurrent(int requestId, String currentQueueEntryId) {
    return _isCurrentPlayRequest(requestId) &&
        _currentRemoteTrack != null &&
        _currentRemoteQueueEntryId == currentQueueEntryId;
  }

  List<TrackInfo> _remoteCacheWindow() {
    final tracks = <TrackInfo>[];
    final identities = <String>{};

    void add(TrackInfo? track) {
      if (track == null) {
        return;
      }
      final identity = track.url.trim().isNotEmpty ? track.url : track.id;
      if (identities.add(identity)) {
        tracks.add(track);
      }
    }

    add(_currentRemoteTrack);
    for (final entry in _upcomingRemoteEntriesForPrefetch()) {
      add(entry.track);
    }
    add(_previousRemoteTrackForRetention());
    return tracks;
  }

  TrackInfo? _previousRemoteTrackForRetention() {
    if (_queueIndex < 0 ||
        _queueIndex >= _queue.length ||
        _queue[_queueIndex].remote == null) {
      return null;
    }
    final actualPrevious = _previousRemoteTrackForCache;
    if (actualPrevious != null &&
        _remoteTrackIdentity(actualPrevious) !=
            _remoteTrackIdentity(_queue[_queueIndex].remote!)) {
      return actualPrevious;
    }
    if (_queue.length < 2) {
      return null;
    }
    final previousIndex = _queueIndex > 0 ? _queueIndex - 1 : _queue.length - 1;
    return _queue[previousIndex].remote;
  }

  List<({int index, TrackInfo track})> _upcomingRemoteEntriesForPrefetch() {
    if (_queue.length < 2 ||
        _queueIndex < 0 ||
        _queueIndex >= _queue.length ||
        _queue[_queueIndex].remote == null ||
        _repeatMode == PlaybackRepeatMode.one) {
      return const <({int index, TrackInfo track})>[];
    }

    if (_shuffleEnabled) {
      _ensureShufflePlan();
      return [
        for (final index in _shufflePlan.take(_remotePrefetchDepth))
          if (_queue[index].remote case final remote?)
            (index: index, track: remote),
      ];
    }

    final tracks = <({int index, TrackInfo track})>[];
    for (
      var offset = 1;
      offset < _queue.length && tracks.length < _remotePrefetchDepth;
      offset++
    ) {
      var nextIndex = _queueIndex + offset;
      if (nextIndex >= _queue.length) {
        if (_repeatMode != PlaybackRepeatMode.all) {
          break;
        }
        nextIndex %= _queue.length;
      }
      final remote = _queue[nextIndex].remote;
      if (remote != null) {
        tracks.add((index: nextIndex, track: remote));
      }
    }
    return tracks;
  }

  String _remoteTrackIdentity(TrackInfo track) {
    final source = track.url.trim();
    return source.isNotEmpty ? source : track.id;
  }

  bool _sameLogicalRemoteTrack(TrackInfo first, TrackInfo second) {
    final firstId = first.id.trim();
    final secondId = second.id.trim();
    if (firstId.isNotEmpty && secondId.isNotEmpty) {
      return firstId == secondId;
    }
    return first.url.trim() == second.url.trim();
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
      index = _queue.indexWhere((item) => item.id == trackId);
    }
    if (index < 0) {
      return false;
    }
    if (index == _queueIndex) {
      _markCurrentQueueIndexPlayed();
      return false;
    }
    _queueIndex = index;
    _remoteRecoveryAttemptedRequestId = null;
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    return true;
  }

  void _recordNativeLocalTrackChange(PlayerSnapshot snapshot) {
    // Explicit requests are recorded by _playLocalTrack after the player
    // accepts them. This observer exists for transitions made internally by
    // just_audio, including automatic advancement and notification controls.
    if (_changingLocalTrack ||
        snapshot.isRemote ||
        snapshot.status != PlayerStatus.playing) {
      return;
    }

    final trackId = snapshot.trackId?.trim();
    if (trackId == null ||
        trackId.isEmpty ||
        trackId == _lastRecordedLocalTrackId) {
      return;
    }

    LocalTrack? queuedLocalTrack;
    for (final item in _queue) {
      if (item.local?.id == trackId) {
        queuedLocalTrack = item.local;
        break;
      }
    }
    if (queuedLocalTrack == null || queuedLocalTrack.isExternal) {
      return;
    }

    // Set this synchronously. Position, duration and state streams may all
    // publish the same track before the database write finishes.
    _lastRecordedLocalTrackId = trackId;
    unawaited(_recordLocalTrackPlayed(trackId));
  }

  Future<void> _recordLocalTrackPlayed(String trackId) {
    final repository = ref.read(libraryRepositoryProvider);
    final playlistId = _playlistIdFromQueueSourceId(_activeLocalQueueSourceId);
    final playedAt = DateTime.now();
    final previousWrite = _historyWrite;

    final write = () async {
      await previousWrite;
      try {
        await repository.markPlayed(trackId, playedAt, playlistId: playlistId);
        ref.invalidate(historyProvider);
      } catch (error, stackTrace) {
        // Playback must remain healthy if a history update fails. Keeping the
        // writes serialized also prevents a rapid sequence of notification
        // skips from committing in the wrong order.
        debugPrint('Recently played update failed: $error\n$stackTrace');
      }
    }();
    _historyWrite = write;
    return write;
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
    if (_queue.length <= 1) {
      if (automatic && _repeatMode == PlaybackRepeatMode.off) {
        return -1;
      }
      return 0;
    }

    if (_shuffleEnabled) {
      return _nextShuffleQueueIndex(automatic: automatic);
    }

    if (_queueIndex >= _queue.length - 1) {
      if (automatic && _repeatMode == PlaybackRepeatMode.off) {
        return -1;
      }
      return 0;
    }

    return _queueIndex + 1;
  }

  int _nextShuffleQueueIndex({required bool automatic}) {
    _ensureShufflePlan();
    if (_shufflePlan.isNotEmpty) {
      final next = _shufflePlan.first;
      _shufflePlan = _shufflePlan.sublist(1);
      return next;
    }

    if (automatic && _repeatMode == PlaybackRepeatMode.off) {
      return -1;
    }

    _resetShuffleHistory();
    _ensureShufflePlan();
    if (_shufflePlan.isEmpty) {
      return _queueIndex;
    }
    final next = _shufflePlan.first;
    _shufflePlan = _shufflePlan.sublist(1);
    return next;
  }

  void _ensureShufflePlan() {
    if (!_shuffleEnabled || _queue.length < 2) {
      _shufflePlan = <int>[];
      return;
    }
    _shufflePlan.removeWhere(
      (index) =>
          index < 0 ||
          index >= _queue.length ||
          index == _queueIndex ||
          _shufflePlayedIndices.contains(index),
    );

    final targetDepth = math.min(_remotePrefetchDepth, _queue.length - 1);
    while (_shufflePlan.length < targetDepth) {
      final candidates = [
        for (var index = 0; index < _queue.length; index++)
          if (index != _queueIndex &&
              !_shufflePlayedIndices.contains(index) &&
              !_shufflePlan.contains(index))
            index,
      ];
      if (candidates.isEmpty) {
        if (_repeatMode != PlaybackRepeatMode.all) {
          return;
        }
        // Keep already reserved entries in the rolling window, but begin
        // choosing the following logical cycle. This prevents the native
        // horizon from shrinking to zero at a shuffle/repeat-all boundary.
        _shufflePlayedIndices = {_queueIndex};
        continue;
      }
      _shufflePlan = [
        ..._shufflePlan,
        candidates[_random.nextInt(candidates.length)],
      ];
    }
  }

  void _resetShuffleHistory() {
    _shufflePlayedIndices = <int>{};
    _shufflePlan = <int>[];
    _markCurrentQueueIndexPlayed();
  }

  void _markCurrentQueueIndexPlayed() {
    if (_queueIndex >= 0 &&
        _queueIndex < _queue.length &&
        !_shufflePlayedIndices.contains(_queueIndex)) {
      _shufflePlayedIndices = {..._shufflePlayedIndices, _queueIndex};
    }
    _shufflePlan.removeWhere((index) => index == _queueIndex);
  }

  PlayerSnapshot _decorateSnapshot(PlayerSnapshot snapshot) {
    final remote = _currentRemoteTrack;
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
        thumbnailUrl: snapshot.thumbnailUrl ?? pending.thumbnailUrl,
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
    final fromTrack = canonicalYouTubeThumbnailSource(track.thumbnailUrl);
    if (fromTrack != null) {
      return fromTrack;
    }

    final fromId = youtubeThumbnailSourceForVideoId(track.id);
    if (fromId != null) {
      return fromId;
    }

    return canonicalYouTubeThumbnailSource(fallback) ?? fallback;
  }

  bool _isCachedRemoteSnapshot(PlayerSnapshot snapshot, TrackInfo remote) {
    final trackId = snapshot.trackId;
    return !snapshot.isRemote &&
        trackId != null &&
        trackId.startsWith(_remoteCacheTrackIdPrefix) &&
        snapshot.sourceUrl == remote.url;
  }

  bool _snapshotMatchesPending(
    PlayerSnapshot snapshot,
    PlayerSnapshot pending,
  ) {
    final pendingQueueEntryId = pending.queueEntryId;
    if (pendingQueueEntryId != null && pendingQueueEntryId.isNotEmpty) {
      final snapshotQueueEntryId = snapshot.queueEntryId;
      if (snapshotQueueEntryId != null && snapshotQueueEntryId.isNotEmpty) {
        return snapshotQueueEntryId == pendingQueueEntryId;
      }
    }
    final pendingTrackId = pending.trackId;
    if (pendingTrackId != null && pendingTrackId.isNotEmpty) {
      final snapshotTrackId = snapshot.trackId?.trim();
      if (snapshotTrackId != null && snapshotTrackId.isNotEmpty) {
        return snapshotTrackId == pendingTrackId;
      }
    }
    final pendingSourceUrl = pending.sourceUrl;
    return pendingSourceUrl != null &&
        pendingSourceUrl.isNotEmpty &&
        snapshot.sourceUrl == pendingSourceUrl;
  }

  TrackInfo? get _currentRemoteTrack {
    if (_queueIndex < 0 || _queueIndex >= _queue.length) {
      return null;
    }
    return _queue[_queueIndex].remote;
  }

  /// Returns the canonical catalog metadata for the currently playing remote
  /// item. Player actions use this instead of rebuilding a lossy TrackInfo
  /// from the compact playback snapshot.
  TrackInfo? currentRemoteTrackFor(String sourceUrl) {
    final current = _currentRemoteTrack;
    return current != null && current.url == sourceUrl ? current : null;
  }

  void _syncPlaybackOptions() {
    final snapshot =
        state.value ?? ref.read(playerServiceProvider).currentSnapshot;
    state = AsyncData(_decorateSnapshot(snapshot));
    unawaited(_syncNativePlaybackOptions());
  }

  Future<void> _syncNativePlaybackOptions() async {
    try {
      final service = ref.read(playerServiceProvider);
      await service.setShuffleEnabled(_shuffleEnabled);
      await service.setRepeatMode(_repeatMode);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
    }
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
