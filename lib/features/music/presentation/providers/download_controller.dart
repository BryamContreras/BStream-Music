part of 'music_providers.dart';

final downloadControllerProvider =
    NotifierProvider<DownloadController, Map<String, DownloadTaskState>>(
      DownloadController.new,
    );

const _unsetDownloadTaskValue = Object();

final playlistDownloadPreparationsProvider =
    NotifierProvider<_PlaylistDownloadPreparations, Set<String>>(
      _PlaylistDownloadPreparations.new,
    );

class _PlaylistDownloadPreparations extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void start(String id) => state = {...state, id};
  void stop(String id) => state = {...state}..remove(id);
}

class DownloadTaskState {
  const DownloadTaskState({
    required this.url,
    required this.taskId,
    required this.mediaType,
    required this.status,
    this.progress,
    this.result,
    this.localTrack,
    this.errorMessage,
    this.title,
    this.reusedExisting = false,
  });

  final String url;
  final String taskId;
  final DownloadMediaType mediaType;
  final DownloadProgressStatus status;
  final double? progress;
  final DownloadResult? result;
  final LocalTrack? localTrack;
  final String? errorMessage;
  final String? title;
  final bool reusedExisting;

  bool get isCancellable =>
      status == DownloadProgressStatus.queued ||
      status == DownloadProgressStatus.running;

  DownloadTaskState copyWith({
    DownloadProgressStatus? status,
    Object? progress = _unsetDownloadTaskValue,
    Object? result = _unsetDownloadTaskValue,
    Object? localTrack = _unsetDownloadTaskValue,
    Object? errorMessage = _unsetDownloadTaskValue,
    Object? title = _unsetDownloadTaskValue,
    bool? reusedExisting,
  }) {
    return DownloadTaskState(
      url: url,
      taskId: taskId,
      mediaType: mediaType,
      status: status ?? this.status,
      progress: identical(progress, _unsetDownloadTaskValue)
          ? this.progress
          : (progress as num?)?.toDouble(),
      result: identical(result, _unsetDownloadTaskValue)
          ? this.result
          : result as DownloadResult?,
      localTrack: identical(localTrack, _unsetDownloadTaskValue)
          ? this.localTrack
          : localTrack as LocalTrack?,
      errorMessage: identical(errorMessage, _unsetDownloadTaskValue)
          ? this.errorMessage
          : errorMessage as String?,
      title: identical(title, _unsetDownloadTaskValue)
          ? this.title
          : title as String?,
      reusedExisting: reusedExisting ?? this.reusedExisting,
    );
  }
}

class DownloadController extends Notifier<Map<String, DownloadTaskState>> {
  final _queue = <TrackInfo>[];
  final _cleanupTimers = <String, Timer>{};
  final _playlistEnqueues = <String, _PlaylistDownloadBatch>{};
  final _cancelGenerations = <String, int>{};
  bool _isProcessing = false;

  @override
  Map<String, DownloadTaskState> build() {
    final subscription = ref
        .watch(downloaderServiceProvider)
        .progressStream
        .listen((progress) {
          final taskKey = _taskKeyForProgress(progress);
          final existing = taskKey == null ? null : state[taskKey];
          if (existing == null) {
            return;
          }
          final nextStatus = _nextStatusForProgress(existing, progress);
          final restartingAfterFailure =
              existing.status == DownloadProgressStatus.failed &&
              (progress.status == DownloadProgressStatus.queued ||
                  progress.status == DownloadProgressStatus.running);
          final nextProgress = restartingAfterFailure
              ? progress.progress
              : _nextProgress(existing.progress, progress.progress);
          final nextError = progress.status == DownloadProgressStatus.failed
              ? progress.message
              : null;
          if (nextStatus == existing.status &&
              nextProgress == existing.progress &&
              nextError == existing.errorMessage) {
            return;
          }
          state = {
            ...state,
            taskKey!: existing.copyWith(
              status: nextStatus,
              progress: nextProgress,
              errorMessage: nextError,
            ),
          };
        });
    ref.onDispose(subscription.cancel);
    ref.onDispose(() {
      for (final timer in _cleanupTimers.values) {
        timer.cancel();
      }
      _cleanupTimers.clear();
      for (final batch in _playlistEnqueues.values) {
        batch.cancelled = true;
      }
    });
    return const {};
  }

  Future<void> downloadAudio(TrackInfo track) {
    return _enqueue(track, DownloadMediaType.audio);
  }

  /// Adds only missing audio to the existing queue. File checks are local;
  /// resolution, retries, cancellation and catalog linking stay in _download.
  Future<int> downloadPlaylist(Playlist playlist) {
    final existing = _playlistEnqueues[playlist.id];
    if (existing != null && !existing.cancelled) return existing.operation;
    final batch = _PlaylistDownloadBatch();
    _playlistEnqueues[playlist.id] = batch;
    ref.read(playlistDownloadPreparationsProvider.notifier).start(playlist.id);
    batch.operation = _queuePlaylistDownloads(playlist, batch).whenComplete(() {
      if (identical(_playlistEnqueues[playlist.id], batch)) {
        _playlistEnqueues.remove(playlist.id);
        if (ref.mounted) {
          ref
              .read(playlistDownloadPreparationsProvider.notifier)
              .stop(playlist.id);
        }
      }
    });
    return batch.operation;
  }

  Future<int> _queuePlaylistDownloads(
    Playlist playlist,
    _PlaylistDownloadBatch batch,
  ) async {
    final library = await ref.read(libraryTracksProvider.future);
    if (batch.cancelled) return 0;
    final catalog = await ref.read(catalogPlaylistProvider(playlist.id).future);
    if (batch.cancelled) return 0;
    return _queueMissingDownloads(
      playlistDownloadItems(playlist, catalog, library),
      isCancelled: () => batch.cancelled,
    );
  }

  Future<int> downloadTracks(Iterable<TrackInfo> tracks) async {
    final requested = tracks.toList(growable: false);
    const codec = BStreamTrackLinkCodec();
    final generations = _cancellationSnapshot(requested);
    final library = await ref.read(libraryTracksProvider.future);
    final localsByVideoId = <String, LocalTrack>{};
    for (final local in library) {
      final id = codec
          .tryFromTrack(
            TrackInfo(
              id: local.sourceId ?? '',
              title: local.title,
              artist: local.artist,
              url: local.sourceUrl ?? '',
            ),
          )
          ?.videoId;
      if (id != null && id.isNotEmpty) {
        localsByVideoId.putIfAbsent(id, () => local);
      }
    }
    return _queueMissingDownloads([
      for (final track in requested)
        CatalogPlaybackItem(
          entryId: track.id,
          remoteTrack: track,
          localTrack: localsByVideoId[codec.tryFromTrack(track)?.videoId],
        ),
    ], generationsAtRequest: generations);
  }

  Future<int> cancelPlaylistDownloads(Playlist playlist) async {
    _playlistEnqueues.remove(playlist.id)?.cancelled = true;
    ref.read(playlistDownloadPreparationsProvider.notifier).stop(playlist.id);
    final library = await ref.read(libraryTracksProvider.future);
    final catalog = await ref.read(catalogPlaylistProvider(playlist.id).future);
    final ids = playlistDownloadVideoIds(playlist, catalog, library);
    for (final id in ids) {
      _cancelGenerations[id] = (_cancelGenerations[id] ?? 0) + 1;
    }
    final urls = pendingPlaylistDownloadUrls(playlist, catalog, library, state);
    final cancelled = await Future.wait(urls.map(cancelDownload));
    return cancelled.where((value) => value).length;
  }

  Future<int> _queueMissingDownloads(
    List<CatalogPlaybackItem> items, {
    bool Function()? isCancelled,
    Map<String, int>? generationsAtRequest,
  }) async {
    const codec = BStreamTrackLinkCodec();
    final generations =
        generationsAtRequest ??
        _cancellationSnapshot(
          items.map((item) => item.remoteTrack).whereType<TrackInfo>(),
        );
    final activeVideoIds = <String>{
      for (final task in state.values)
        if (task.isCancellable)
          ?codec
              .tryFromTrack(
                TrackInfo(id: '', title: '', artist: '', url: task.url),
              )
              ?.videoId,
    };
    final seen = <String>{};
    final availability = <String, Future<bool>>{};
    final probe = ref.read(localAudioUsabilityProbeProvider);
    var queued = 0;
    for (final item in items) {
      if (isCancelled?.call() == true) break;
      final remote = item.remoteTrack;
      if (remote == null) continue;
      final identity = codec.tryFromTrack(remote)?.videoId;
      if (identity == null || !seen.add(identity)) continue;
      if ((_cancelGenerations[identity] ?? 0) != generations[identity]) {
        continue;
      }
      final local = item.localTrack;
      if (local != null &&
          await availability.putIfAbsent(
            local.filePath,
            () => probe(local.filePath),
          )) {
        continue;
      }
      if (isCancelled?.call() == true) break;
      if ((_cancelGenerations[identity] ?? 0) != generations[identity]) {
        continue;
      }
      if (activeVideoIds.contains(identity) ||
          state[remote.url]?.isCancellable == true) {
        continue;
      }
      await downloadAudio(remote);
      activeVideoIds.add(identity);
      queued++;
    }
    return queued;
  }

  Map<String, int> _cancellationSnapshot(Iterable<TrackInfo> tracks) {
    const codec = BStreamTrackLinkCodec();
    final generations = <String, int>{};
    for (final track in tracks) {
      final id = codec.tryFromTrack(track)?.videoId;
      if (id != null) generations[id] = _cancelGenerations[id] ?? 0;
    }
    return generations;
  }

  /// Removes a queued task or interrupts only its active transfer.
  Future<bool> cancelDownload(String url) async {
    final task = state[url];
    if (task == null || !task.isCancellable) return false;

    _cleanupTimers.remove(url)?.cancel();
    _queue.removeWhere((track) => track.url == url);
    state = Map<String, DownloadTaskState>.from(state)..remove(url);

    if (task.status == DownloadProgressStatus.running) {
      final downloader = ref.read(downloaderServiceProvider);
      if (downloader is CancellableDownloaderService) {
        await (downloader as CancellableDownloaderService).cancelDownload(
          task.taskId,
        );
      }
    }
    return true;
  }

  Future<LocalTrack> downloadAudioForLibrary(
    TrackInfo track, {
    void Function()? onDownloadStarted,
  }) async {
    final result = await ref
        .read(localTrackDownloadHelperProvider)
        .resolveForLibrary(track, onDownloadStarted: onDownloadStarted);
    return result.track;
  }

  Future<void> _enqueue(TrackInfo track, DownloadMediaType mediaType) async {
    final existing = state[track.url];
    if (existing != null &&
        existing.status != DownloadProgressStatus.failed &&
        existing.status != DownloadProgressStatus.completed) {
      return;
    }

    _cleanupTimers.remove(track.url)?.cancel();
    state = {
      ...state,
      track.url: DownloadTaskState(
        url: track.url,
        taskId: const Uuid().v4(),
        mediaType: mediaType,
        status: DownloadProgressStatus.queued,
        title: track.title,
      ),
    };
    _queue.add(track);
    unawaited(_processQueue());
  }

  Future<void> _processQueue() async {
    if (_isProcessing) {
      return;
    }
    _isProcessing = true;

    try {
      while (_queue.isNotEmpty) {
        final track = _queue.removeAt(0);
        if (!state.containsKey(track.url)) {
          continue;
        }
        await _download(track);
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _download(TrackInfo track) async {
    final queued = state[track.url];
    if (queued == null) {
      return;
    }
    final taskId = queued.taskId;
    state = {
      ...state,
      track.url: queued.copyWith(status: DownloadProgressStatus.running),
    };

    final helper = ref.read(localTrackDownloadHelperProvider);
    helper.registerCancellationProbe(
      taskId,
      () => state[track.url]?.taskId != taskId,
    );
    try {
      final outcome = await helper.resolveForLibrary(
        track,
        taskId: taskId,
        onResolved: (resolved) {
          final active = state[track.url];
          if (active?.taskId != taskId) {
            return;
          }
          state = {
            ...state,
            track.url: active!.copyWith(title: resolved.title),
          };
        },
      );
      final active = state[track.url];
      if (active?.taskId != taskId) {
        return;
      }
      state = {
        ...state,
        track.url: active!.copyWith(
          status: DownloadProgressStatus.completed,
          progress: 1,
          result: outcome.downloadResult,
          localTrack: outcome.track,
          errorMessage: null,
          reusedExisting: outcome.reusedExisting,
        ),
      };
      _scheduleCleanup(track.url, const Duration(seconds: 3));
    } catch (error, stackTrace) {
      final active = state[track.url];
      if (active?.taskId != taskId) {
        return;
      }
      debugPrint('Audio download failed: $error\n$stackTrace');
      state = {
        ...state,
        track.url: active!.copyWith(
          status: DownloadProgressStatus.failed,
          errorMessage: error.toString(),
        ),
      };
      _scheduleCleanup(track.url, const Duration(seconds: 10));
    } finally {
      helper.unregisterCancellationProbe(taskId);
    }
  }

  DownloadProgressStatus _nextStatusForProgress(
    DownloadTaskState existing,
    DownloadProgress progress,
  ) {
    if (progress.status == DownloadProgressStatus.queued &&
        existing.status == DownloadProgressStatus.running) {
      return DownloadProgressStatus.running;
    }

    if (progress.status == DownloadProgressStatus.completed &&
        existing.result == null &&
        existing.localTrack == null) {
      return DownloadProgressStatus.running;
    }

    return progress.status;
  }

  String? _taskKeyForProgress(DownloadProgress progress) {
    if (progress.taskId.isNotEmpty) {
      for (final entry in state.entries) {
        if (entry.value.taskId == progress.taskId) {
          return entry.key;
        }
      }
      return null;
    }
    return state.containsKey(progress.url) ? progress.url : null;
  }

  double? _nextProgress(double? current, double? incoming) {
    if (incoming == null || incoming.isNaN || incoming.isInfinite) {
      return current;
    }
    final normalized = incoming.clamp(0.0, 1.0).toDouble();
    if (current == null) {
      return normalized;
    }
    return math.max(current, normalized);
  }

  void _scheduleCleanup(String url, Duration delay) {
    _cleanupTimers.remove(url)?.cancel();
    _cleanupTimers[url] = Timer(delay, () {
      final next = Map<String, DownloadTaskState>.from(state)..remove(url);
      state = next;
      _cleanupTimers.remove(url);
    });
  }
}

class _PlaylistDownloadBatch {
  bool cancelled = false;
  late final Future<int> operation;
}

List<CatalogPlaybackItem> playlistDownloadItems(
  Playlist playlist,
  CatalogPlaylist? catalog,
  Iterable<LocalTrack> library,
) {
  if (catalog != null) return catalogPlaylistPlaybackItems(catalog, library);
  final localsById = {for (final track in library) track.id: track};
  return [
    for (final id in playlist.trackIds)
      if (localsById[id] case final local?)
        CatalogPlaybackItem(
          entryId: id,
          localTrack: local,
          remoteTrack:
              local.sourceId?.trim().isNotEmpty == true ||
                  local.sourceUrl?.trim().isNotEmpty == true
              ? TrackInfo(
                  id: local.sourceId?.trim().isNotEmpty == true
                      ? local.sourceId!.trim()
                      : local.id,
                  title: local.title,
                  artist: local.artist,
                  artists: local.artists,
                  artistBrowseIds: local.artistBrowseIds,
                  album: local.album,
                  duration: local.duration,
                  thumbnailUrl: local.thumbnailUrl,
                  catalogThumbnailUrl: local.catalogThumbnailUrl,
                  url: local.sourceUrl?.trim().isNotEmpty == true
                      ? local.sourceUrl!.trim()
                      : 'https://www.youtube.com/watch?v=${local.sourceId!.trim()}',
                  metadataSource: local.metadataSource,
                )
              : null,
        ),
  ];
}

Set<String> playlistDownloadVideoIds(
  Playlist playlist,
  CatalogPlaylist? catalog,
  Iterable<LocalTrack> library,
) {
  const codec = BStreamTrackLinkCodec();
  return {
    for (final item in playlistDownloadItems(playlist, catalog, library))
      if (item.remoteTrack case final remote?)
        ?codec.tryFromTrack(remote)?.videoId,
  };
}

Set<String> pendingPlaylistDownloadUrls(
  Playlist playlist,
  CatalogPlaylist? catalog,
  Iterable<LocalTrack> library,
  Map<String, DownloadTaskState> tasks,
) {
  const codec = BStreamTrackLinkCodec();
  final ids = playlistDownloadVideoIds(playlist, catalog, library);
  return {
    for (final task in tasks.values)
      if (task.isCancellable &&
          ids.contains(
            codec
                .tryFromTrack(
                  TrackInfo(id: '', title: '', artist: '', url: task.url),
                )
                ?.videoId,
          ))
        task.url,
  };
}
