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
    this.thumbnailUrl,
  });

  final String id;
  final String title;
  final String artist;
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

  String get id => remote?.url ?? local?.id ?? '';

  PlaybackQueueEntry get presentation {
    final localTrack = local;
    if (localTrack != null) {
      return PlaybackQueueEntry(
        id: localTrack.id,
        title: localTrack.title,
        artist: localTrack.artist,
        thumbnailUrl: localTrack.thumbnailPath ?? localTrack.thumbnailUrl,
        isRemote: false,
      );
    }

    final remoteTrack = remote!;
    return PlaybackQueueEntry(
      id: remoteTrack.id.isEmpty ? remoteTrack.url : remoteTrack.id,
      title: remoteTrack.title,
      artist: remoteTrack.artist,
      thumbnailUrl: remoteTrack.thumbnailUrl,
      isRemote: true,
    );
  }
}

class PlayerController extends AsyncNotifier<PlayerSnapshot> {
  final _random = math.Random();
  List<_QueueItem> _queue = const [];
  int _queueIndex = -1;
  bool _shuffleEnabled = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;
  Set<int> _shufflePlayedIndices = <int>{};
  bool _handlingCompletion = false;
  bool _changingLocalTrack = false;
  bool _explicitlyStopped = false;
  bool _useNativeLocalQueue = true;
  String? _activeLocalQueueSourceId;
  int _playRequestId = 0;
  PlayerSnapshot? _pendingRemoteSnapshot;

  @override
  Future<PlayerSnapshot> build() async {
    final service = ref.watch(playerServiceProvider);
    final subscription = service.snapshotStream.listen((snapshot) {
      final decorated = _decorateSnapshot(snapshot);
      _syncQueueIndexFromSnapshot(decorated);
      state = AsyncData(decorated);
      _maybeHandleCompletion(decorated);
    });
    ref.onDispose(subscription.cancel);
    return _decorateSnapshot(service.currentSnapshot);
  }

  Future<void> playRemote(TrackInfo track, {List<TrackInfo>? queue}) async {
    _useNativeLocalQueue = true;
    _activeLocalQueueSourceId = null;
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

  Future<void> _playRemoteTrack(TrackInfo track) async {
    _explicitlyStopped = false;
    final requestId = ++_playRequestId;
    final pendingSnapshot = _remoteLoadingSnapshot(track);
    _pendingRemoteSnapshot = pendingSnapshot;
    state = AsyncData(pendingSnapshot);

    try {
      await ref.read(playerServiceProvider).stop();
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }

      final cachedTrack = await _cachedRemoteTrack(track);
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }
      if (cachedTrack != null) {
        await ref.read(playerServiceProvider).playLocal(cachedTrack);
        _clearPendingRemoteSnapshot(requestId);
        return;
      }

      final playableTrack = await _resolveRemoteTrack(track);
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }

      final cachedPlayableTrack = await _cachedRemoteTrack(playableTrack);
      if (!_isCurrentPlayRequest(requestId)) {
        return;
      }
      if (cachedPlayableTrack != null) {
        await ref.read(playerServiceProvider).playLocal(cachedPlayableTrack);
        _clearPendingRemoteSnapshot(requestId);
        return;
      }

      try {
        await ref.read(playerServiceProvider).playRemote(playableTrack);
        _clearPendingRemoteSnapshot(requestId);
      } catch (_) {
        final refreshed = await _resolveRemoteTrack(
          playableTrack,
          forceRefresh: true,
        );
        if (!_isCurrentPlayRequest(requestId)) {
          return;
        }

        await ref.read(playerServiceProvider).playRemote(refreshed);
        _clearPendingRemoteSnapshot(requestId);
      }
    } catch (error, stackTrace) {
      if (_isCurrentPlayRequest(requestId)) {
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
      trackId: track.id.isEmpty ? track.url : track.id,
      sourceUrl: track.url,
      thumbnailUrl: track.thumbnailUrl,
      duration: track.duration,
      volume:
          state.value?.volume ??
          ref.read(playerServiceProvider).currentSnapshot.volume,
      isRemote: true,
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
    );
  }

  bool _isCurrentPlayRequest(int requestId) => requestId == _playRequestId;

  void _clearPendingRemoteSnapshot(int requestId) {
    if (_isCurrentPlayRequest(requestId)) {
      _pendingRemoteSnapshot = null;
    }
  }

  Future<TrackInfo> _resolveRemoteTrack(
    TrackInfo track, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        track.streamUrl != null &&
        track.thumbnailUrl != null) {
      return track;
    }

    return ref
        .read(remoteTrackResolverProvider)
        .resolve(track, forceRefresh: forceRefresh);
  }

  Future<LocalTrack?> _cachedRemoteTrack(TrackInfo track) async {
    final file = await ref.read(remotePlaybackCacheProvider).cachedFile(track);
    if (file == null) {
      return null;
    }

    final identity = track.id.isEmpty ? track.url : track.id;
    return LocalTrack(
      id: 'remote-cache:${identity.hashCode}',
      title: track.title,
      artist: track.artist,
      filePath: file.path,
      addedAt: await file.lastModified(),
      sourceUrl: track.url,
      thumbnailUrl: track.thumbnailUrl,
      duration: track.duration,
    );
  }

  Future<void> playLocal(
    LocalTrack track, {
    List<LocalTrack>? queue,
    bool useNativeQueue = true,
    String? queueSourceId,
  }) async {
    _useNativeLocalQueue = useNativeQueue;
    _activeLocalQueueSourceId = queueSourceId;
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
  }

  void replaceLocalQueue(List<LocalTrack> tracks, {String? currentTrackId}) {
    if (tracks.isEmpty) {
      _queue = const [];
      _queueIndex = -1;
      _shufflePlayedIndices = <int>{};
      _useNativeLocalQueue = true;
      _activeLocalQueueSourceId = null;
      _publishPlaybackQueue();
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
  }

  static String playlistQueueSourceId(String playlistId) {
    return 'playlist:$playlistId';
  }

  bool isLocalQueueSourceActive(String sourceId) {
    return _activeLocalQueueSourceId == sourceId;
  }

  bool syncLocalQueueSource(String sourceId, List<LocalTrack> tracks) {
    if (_activeLocalQueueSourceId != sourceId || _useNativeLocalQueue) {
      return false;
    }
    replaceLocalQueue(tracks);
    _activeLocalQueueSourceId = sourceId;
    return true;
  }

  Future<void> _playLocalTrack(LocalTrack track) async {
    _explicitlyStopped = false;
    _playRequestId++;
    _pendingRemoteSnapshot = null;
    _changingLocalTrack = true;
    try {
      final service = ref.read(playerServiceProvider);
      await service.setShuffleEnabled(
        _useNativeLocalQueue ? _shuffleEnabled : false,
      );
      await service.setRepeatMode(
        _useNativeLocalQueue ? _repeatMode : PlaybackRepeatMode.off,
      );
      final localQueue = _localQueue;
      if (_useNativeLocalQueue &&
          localQueue != null &&
          localQueue.isNotEmpty &&
          _queueIndex >= 0) {
        await service.playLocalQueue(localQueue, _queueIndex);
      } else {
        await service.playLocal(track);
      }
      await ref
          .read(libraryRepositoryProvider)
          .markPlayed(track.id, DateTime.now());
      ref.invalidate(historyProvider);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
    } finally {
      _changingLocalTrack = false;
    }
  }

  Future<void> pause() async {
    await ref.read(playerServiceProvider).pause();
  }

  Future<void> resume() async {
    final snapshot =
        state.value ?? ref.read(playerServiceProvider).currentSnapshot;
    if ((snapshot.status == PlayerStatus.stopped || _explicitlyStopped) &&
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
    if (snapshot.status == PlayerStatus.stopped &&
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
    _queueIndex = _queueIndex <= 0 ? _queue.length - 1 : _queueIndex - 1;
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    await _playQueueItem(_queue[_queueIndex]);
  }

  Future<void> playNext({bool automatic = false}) async {
    if (_queue.isEmpty) {
      return;
    }
    if (automatic && _repeatMode == PlaybackRepeatMode.one) {
      await _playQueueItem(_queue[_queueIndex]);
      return;
    }

    final nextIndex = _nextQueueIndex(automatic: automatic);
    if (nextIndex < 0) {
      return;
    }

    _queueIndex = nextIndex;
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    await _playQueueItem(_queue[_queueIndex]);
  }

  Future<void> playQueueIndex(int index) async {
    if (index < 0 || index >= _queue.length || index == _queueIndex) {
      return;
    }
    _queueIndex = index;
    _markCurrentQueueIndexPlayed();
    _publishPlaybackQueue();
    await _playQueueItem(_queue[index]);
  }

  Future<void> stop() async {
    _playRequestId++;
    _pendingRemoteSnapshot = null;
    _explicitlyStopped = true;
    await ref.read(playerServiceProvider).stop();
  }

  Future<void> seek(Duration position) async {
    await ref.read(playerServiceProvider).seek(position);
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
  }

  Future<void> _playQueueItem(_QueueItem item) async {
    final remote = item.remote;
    if (remote != null) {
      await _playRemoteTrack(remote);
      return;
    }

    final local = item.local;
    if (local != null) {
      await _playLocalTrack(local);
    }
  }

  List<LocalTrack>? get _localQueue {
    if (_queue.isEmpty || _queue.any((item) => item.local == null)) {
      return null;
    }
    return _queue.map((item) => item.local!).toList(growable: false);
  }

  void _syncQueueIndexFromSnapshot(PlayerSnapshot snapshot) {
    if (_changingLocalTrack) {
      return;
    }
    final trackId = snapshot.trackId;
    if (trackId == null || trackId.isEmpty || _queue.isEmpty) {
      return;
    }
    if (_queueIndex >= 0 &&
        _queueIndex < _queue.length &&
        _queue[_queueIndex].id == trackId) {
      _markCurrentQueueIndexPlayed();
      return;
    }
    final index = _queue.indexWhere((item) => item.id == trackId);
    if (index >= 0 && index != _queueIndex) {
      _queueIndex = index;
      _markCurrentQueueIndexPlayed();
      _publishPlaybackQueue();
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
    final unplayed = [
      for (var index = 0; index < _queue.length; index++)
        if (index != _queueIndex && !_shufflePlayedIndices.contains(index))
          index,
    ];
    if (unplayed.isNotEmpty) {
      return unplayed[_random.nextInt(unplayed.length)];
    }

    if (automatic && _repeatMode == PlaybackRepeatMode.off) {
      return -1;
    }

    _resetShuffleHistory();
    final candidates = [
      for (var index = 0; index < _queue.length; index++)
        if (index != _queueIndex) index,
    ];
    if (candidates.isEmpty) {
      return _queueIndex;
    }
    return candidates[_random.nextInt(candidates.length)];
  }

  void _resetShuffleHistory() {
    _shufflePlayedIndices = <int>{};
    _markCurrentQueueIndexPlayed();
  }

  void _markCurrentQueueIndexPlayed() {
    if (_queueIndex >= 0 &&
        _queueIndex < _queue.length &&
        !_shufflePlayedIndices.contains(_queueIndex)) {
      _shufflePlayedIndices = {..._shufflePlayedIndices, _queueIndex};
    }
  }

  PlayerSnapshot _decorateSnapshot(PlayerSnapshot snapshot) {
    final pending = _pendingRemoteSnapshot;
    if (pending != null && !_snapshotMatchesPending(snapshot, pending)) {
      return pending.copyWith(
        volume: snapshot.volume,
        shuffleEnabled: _shuffleEnabled,
        repeatMode: _repeatMode,
      );
    }

    final remote = _currentRemoteTrack;
    if (remote != null) {
      snapshot = snapshot.copyWith(sourceUrl: remote.url, isRemote: true);
    }
    return snapshot.copyWith(
      shuffleEnabled: _shuffleEnabled,
      repeatMode: _repeatMode,
    );
  }

  bool _snapshotMatchesPending(
    PlayerSnapshot snapshot,
    PlayerSnapshot pending,
  ) {
    final pendingTrackId = pending.trackId;
    if (pendingTrackId != null &&
        pendingTrackId.isNotEmpty &&
        snapshot.trackId == pendingTrackId) {
      return true;
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
        (snapshot.status != PlayerStatus.stopped &&
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
