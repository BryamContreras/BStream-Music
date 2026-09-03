part of 'music_providers.dart';

final remotePlaybackCacheProvider = Provider<RemotePlaybackCache>((ref) {
  final cache = RemotePlaybackCache();
  ref.onDispose(() => unawaited(cache.dispose()));
  return cache;
});

class RemotePlaybackCachePolicy {
  const RemotePlaybackCachePolicy({
    required this.enabled,
    required this.evictOutsidePlaybackWindow,
    required this.useApplicationCacheDirectory,
    required this.useHashedKeys,
    required this.maximumAge,
    required this.maximumFiles,
    required this.maximumBytes,
    required this.maximumEntryBytes,
    required this.partialMaximumAge,
  });

  static const disabled = RemotePlaybackCachePolicy(
    enabled: false,
    evictOutsidePlaybackWindow: true,
    useApplicationCacheDirectory: false,
    useHashedKeys: false,
    maximumAge: Duration.zero,
    maximumFiles: 1,
    maximumBytes: 1,
    maximumEntryBytes: 1,
    partialMaximumAge: Duration.zero,
  );

  static const mobile = RemotePlaybackCachePolicy(
    enabled: true,
    evictOutsidePlaybackWindow: true,
    useApplicationCacheDirectory: false,
    useHashedKeys: false,
    maximumAge: Duration(minutes: 30),
    maximumFiles: 5,
    maximumBytes: 64 * 1024 * 1024,
    maximumEntryBytes: 64 * 1024 * 1024,
    partialMaximumAge: Duration.zero,
  );

  // Kept for existing callers and tests; both mobile platforms use the same
  // bounded, playback-window cache policy.
  static const android = mobile;

  static const desktop = RemotePlaybackCachePolicy(
    enabled: true,
    evictOutsidePlaybackWindow: false,
    useApplicationCacheDirectory: true,
    useHashedKeys: true,
    maximumAge: Duration(hours: 12),
    maximumFiles: 24,
    maximumBytes: 256 * 1024 * 1024,
    maximumEntryBytes: 128 * 1024 * 1024,
    // Another BStream process may own a recent partial file on desktop.
    partialMaximumAge: Duration(hours: 1),
  );

  static RemotePlaybackCachePolicy current() =>
      forPlatform(AppPlatform.current);

  @visibleForTesting
  static RemotePlaybackCachePolicy forPlatform(AppPlatformType platform) {
    if (AppPlatform.isMobileOn(platform)) return mobile;
    if (platform == AppPlatformType.windows ||
        platform == AppPlatformType.linux ||
        platform == AppPlatformType.macos) {
      return desktop;
    }
    return disabled;
  }

  final bool enabled;
  final bool evictOutsidePlaybackWindow;
  final bool useApplicationCacheDirectory;
  final bool useHashedKeys;
  final Duration maximumAge;
  final int maximumFiles;
  final int maximumBytes;
  final int maximumEntryBytes;
  final Duration partialMaximumAge;
}

class RemotePlaybackCache {
  RemotePlaybackCache({
    RemotePlaybackCachePolicy? policy,
    this.cacheDirectoryProvider,
    DateTime Function()? clock,
    Duration? maximumAge,
    int? maximumFiles,
    int? maximumBytes,
    int? maximumEntryBytes,
  }) : assert(maximumAge == null || maximumAge >= Duration.zero),
       assert(maximumFiles == null || maximumFiles > 0),
       assert(maximumBytes == null || maximumBytes > 0),
       assert(maximumEntryBytes == null || maximumEntryBytes > 0),
       _policy = policy ?? RemotePlaybackCachePolicy.current(),
       _clock = clock ?? DateTime.now,
       _maximumAge =
           maximumAge ??
           (policy ?? RemotePlaybackCachePolicy.current()).maximumAge,
       _maximumFiles =
           maximumFiles ??
           (policy ?? RemotePlaybackCachePolicy.current()).maximumFiles,
       _maximumBytes =
           maximumBytes ??
           (policy ?? RemotePlaybackCachePolicy.current()).maximumBytes,
       _maximumEntryBytes =
           maximumEntryBytes ??
           (policy ?? RemotePlaybackCachePolicy.current()).maximumEntryBytes;

  static const _cacheFolderName = 'remote-playback-cache';
  static const _publicationLockFileName = '.publish.lock';
  static const _publicationLockRetryDelay = Duration(milliseconds: 25);
  static const _publicationLockTimeout = Duration(seconds: 2);
  static const _downloadIdleTimeout = Duration(seconds: 20);
  static const _downloadTotalTimeout = Duration(minutes: 30);
  static const _userAgent =
      'BStreamMusic/${AppConstants.appVersion} AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36';
  static const _audioExtensions = {
    '.aiff',
    '.alac',
    '.3gp',
    '.3gpp',
    '.flac',
    '.m4a',
    '.m4b',
    '.mka',
    '.mp3',
    '.mp4',
    '.aac',
    '.oga',
    '.ogg',
    '.opus',
    '.vorbis',
    '.wav',
    '.weba',
    '.webm',
    '.wma',
  };
  // POSIX advisory file locks are process-scoped, so cache objects in the same
  // isolate share one directory gate first. The persistent file lock below
  // then coordinates publication with separate app processes.
  static final Map<String, Future<void>> _publicationTails =
      <String, Future<void>>{};

  final RemotePlaybackCachePolicy _policy;
  final Future<Directory> Function()? cacheDirectoryProvider;
  final DateTime Function() _clock;
  final Duration _maximumAge;
  final int _maximumFiles;
  final int _maximumBytes;
  final int _maximumEntryBytes;
  final _inFlight = <String, _RemoteCacheWarmup>{};
  final _invalidKeys = <String>{};
  List<String> _protectedKeys = <String>[];
  Future<void> _downloadTail = Future<void>.value();
  int _retentionGeneration = 0;
  final String _partialOwnerId = const Uuid().v4();
  bool _disposed = false;
  Future<void>? _disposeFuture;

  bool get isEnabled => _policy.enabled && !_disposed;

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }
    _disposed = true;
    _retentionGeneration++;
    for (final job in _inFlight.values) {
      job.cancel();
    }
    _inFlight.clear();
    final future = _downloadTail.catchError((_) {}).then((_) {});
    _disposeFuture = future;
    return future;
  }

  /// Removes abandoned partial files and bounds leftovers from an interrupted
  /// process. Active sources are protected so rebuilding the Android activity
  /// cannot interrupt background playback.
  Future<void> prepareSession({
    Iterable<String> protectedSourceUrls = const <String>[],
  }) {
    if (!_policy.enabled || _disposed) {
      return Future<void>.value();
    }
    _protectedKeys = protectedSourceUrls
        .map((source) => source.trim())
        .where((source) => source.isNotEmpty)
        .map(_cacheKeyFromSource)
        .toSet()
        .toList(growable: false);
    final retentionGeneration = ++_retentionGeneration;
    return _scheduleMaintenance(() async {
      if (!_isRetentionCurrent(retentionGeneration)) {
        return;
      }
      final directory = await _cacheDirectory();
      await _trimCache(directory, retentionGeneration);
    });
  }

  /// Keeps only the files required by the active playback window. The caller
  /// passes the current, predictable next, and previous remote tracks in
  /// retention-priority order. Only
  /// tracks that have already been played or explicitly warmed exist on disk;
  /// retaining a track never downloads it by itself.
  Future<void> retainOnlyTracks(Iterable<TrackInfo> tracks) {
    if (!_policy.enabled || _disposed) {
      return Future<void>.value();
    }
    final retentionGeneration = _protectTracks(tracks);
    return _scheduleMaintenance(() async {
      if (!_isRetentionCurrent(retentionGeneration)) {
        return;
      }
      final directory = await _cacheDirectory();
      if (_policy.evictOutsidePlaybackWindow) {
        await _deleteUnprotectedAudio(directory, retentionGeneration);
      }
      await _trimCache(directory, retentionGeneration);
    });
  }

  /// Updates protection and cancels obsolete downloads immediately without
  /// deleting files. This closes the transition race between selecting a new
  /// queue item and replacing the source currently open in the backend.
  void protectPlaybackWindow(Iterable<TrackInfo> tracks) {
    if (!_policy.enabled || _disposed) {
      return;
    }
    _protectTracks(tracks);
  }

  void cancelSearchWarmups() {
    for (final job in _inFlight.values) {
      if (job.cancelOnSearchChange) {
        job.cancel();
      }
    }
  }

  /// Cancels playback warmups when the user changes the
  /// current queue item. Search warmups use a separate cancellation policy.
  void cancelPlaybackWarmups() {
    for (final job in _inFlight.values) {
      if (!job.cancelOnSearchChange) {
        job.cancel();
      }
    }
  }

  /// Stops reusing a cache entry that the player could not open. Deletion is
  /// best effort because another desktop process (or the active backend) may
  /// still hold the file open; the in-memory invalid marker makes lookups fall
  /// back to streaming immediately either way.
  Future<void> evict(TrackInfo track) {
    if (!_policy.enabled || _disposed) {
      return Future<void>.value();
    }
    final key = _cacheKey(track);
    _invalidKeys.add(key);
    _inFlight.remove(key)?.cancel();
    final baseName = _baseName(track);
    return _scheduleMaintenance(() async {
      final directory = await _cacheDirectory();
      await _deleteCachedVariants(directory, baseName);
    });
  }

  Future<File?> cachedFile(TrackInfo track) async {
    if (!_policy.enabled || _disposed) {
      return null;
    }

    try {
      final key = _cacheKey(track);
      if (_invalidKeys.contains(key)) {
        return null;
      }
      final directory = await _cacheDirectory();
      final file = await _findCachedFile(directory, _baseName(track));
      if (_invalidKeys.contains(key) ||
          file == null ||
          !await file.exists() ||
          await file.length() == 0) {
        return null;
      }
      try {
        await file.setLastModified(_clock());
      } catch (_) {
        // The file remains usable even if touching it fails.
      }
      return await file.exists() && await file.length() > 0 ? file : null;
    } catch (_) {
      // Maintenance may remove an entry between discovery and validation.
      return null;
    }
  }

  Future<File?> warmResolved(
    TrackInfo track, {
    bool cancelOnSearchChange = false,
  }) {
    if (!_policy.enabled || _disposed || !_hasStream(track)) {
      return Future<File?>.value();
    }

    final key = _cacheKey(track);
    final existing = _inFlight[key];
    if (existing != null) {
      if (!cancelOnSearchChange) {
        existing.cancelOnSearchChange = false;
      }
      return existing.future;
    }

    final job = _RemoteCacheWarmup(cancelOnSearchChange: cancelOnSearchChange);
    final future = _downloadTail.then((_) async {
      if (_disposed || job.cancelled) {
        return null;
      }
      try {
        return await _downloadIfMissing(track, job);
      } catch (_) {
        // The playback cache is an optimization. Directory/provider failures
        // must always fall back to streaming instead of surfacing as playback
        // errors.
        return null;
      }
    });
    job.future = future;
    _inFlight[key] = job;
    _downloadTail = future.catchError((_) => null).then((_) {});
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_inFlight[key], job)) {
            _inFlight.remove(key);
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_inFlight[key], job)) {
            _inFlight.remove(key);
          }
        },
      ),
    );
    return future;
  }

  Future<File?> _downloadIfMissing(
    TrackInfo track,
    _RemoteCacheWarmup job,
  ) async {
    if (job.cancelled) {
      return null;
    }

    final directory = await _cacheDirectory();
    await _trimCache(directory, _retentionGeneration);
    if (job.cancelled) {
      return null;
    }

    final baseName = _baseName(track);
    final key = _cacheKey(track);
    final replacingInvalidEntry = _invalidKeys.contains(key);
    if (replacingInvalidEntry) {
      await _deleteCachedVariants(directory, baseName);
    } else {
      final cached = await _findCachedFile(directory, baseName);
      if (cached != null) {
        return cached;
      }
    }

    final uri = Uri.tryParse(track.streamUrl ?? '');
    if (uri == null || !uri.hasScheme) {
      return null;
    }

    final tempFile = File(
      p.join(directory.path, '$baseName.$_partialOwnerId.part'),
    );
    job.tempFile = tempFile;
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    job.client = client;
    try {
      if (job.cancelled) {
        return null;
      }

      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final headers = track.httpHeaders;
      for (final entry
          in headers?.entries ?? const <MapEntry<String, String>>[]) {
        request.headers.set(entry.key, entry.value);
      }

      final response = await request.close();
      if (job.cancelled) {
        await _deleteIfExists(tempFile);
        return null;
      }
      if (!_isCompleteRemoteCacheResponse(response)) {
        await _deleteIfExists(tempFile);
        return null;
      }
      if (!_isCacheableAudioContentType(response.headers.contentType)) {
        await _deleteIfExists(tempFile);
        return null;
      }

      final extension = _audioExtension(
        track,
        uri,
        response.headers.contentType?.mimeType,
      );
      final finalFile = File(p.join(directory.path, '$baseName$extension'));
      final written = await writeBoundedByteStreamToFile(
        response,
        tempFile,
        maximumBytes: _maximumEntryBytes,
        declaredLength: response.contentLength < 0
            ? null
            : response.contentLength,
        idleTimeout: _downloadIdleTimeout,
        totalTimeout: _downloadTotalTimeout,
      );
      if (job.cancelled) {
        await _deleteIfExists(tempFile);
        return null;
      }
      if (written == 0 ||
          !await tempFile.exists() ||
          await tempFile.length() == 0) {
        await _deleteIfExists(tempFile);
        return null;
      }
      final published = await _publishDownloadedFile(
        directory: directory,
        baseName: baseName,
        tempFile: tempFile,
        finalFile: finalFile,
        replacingInvalidEntry: replacingInvalidEntry,
        job: job,
      );
      if (published == null) {
        await _deleteIfExists(tempFile);
        return null;
      }
      _invalidKeys.remove(key);
      await _trimCache(directory, _retentionGeneration);
      return await published.exists() ? published : null;
    } catch (_) {
      await _deleteIfExists(tempFile);
      return null;
    } finally {
      if (job.cancelled) {
        await _deleteIfExists(tempFile);
      }
      job.client = null;
      job.tempFile = null;
      client.close(force: true);
    }
  }

  Future<Directory> _cacheDirectory() async {
    final providedDirectory = cacheDirectoryProvider;
    if (providedDirectory != null) {
      final directory = await providedDirectory();
      await directory.create(recursive: true);
      return directory;
    }
    final root = _policy.useApplicationCacheDirectory
        ? await getApplicationCacheDirectory()
        : await getTemporaryDirectory();
    final directory = Directory(
      _policy.useApplicationCacheDirectory
          ? p.join(root.path, _cacheFolderName)
          : p.join(root.path, 'BStream-Music', _cacheFolderName),
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<File?> _findCachedFile(Directory directory, String baseName) async {
    if (!await directory.exists()) {
      return null;
    }

    final files = await directory
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .where((file) {
          final extension = p.extension(file.path).toLowerCase();
          return _audioExtensions.contains(extension) &&
              p.basenameWithoutExtension(file.path) == baseName;
        })
        .toList();
    final existing = <({File file, DateTime modified})>[];
    for (final file in files) {
      try {
        if (await file.length() > 0) {
          existing.add((file: file, modified: await file.lastModified()));
        }
      } catch (_) {
        // Ignore stale files that disappear while scanning.
      }
    }
    if (existing.isEmpty) {
      return null;
    }
    existing.sort((left, right) => right.modified.compareTo(left.modified));
    return existing.first.file;
  }

  Future<File?> _publishDownloadedFile({
    required Directory directory,
    required String baseName,
    required File tempFile,
    required File finalFile,
    required bool replacingInvalidEntry,
    required _RemoteCacheWarmup job,
  }) async {
    final publicationKey = await _publicationKey(directory);
    final previous = _publicationTails[publicationKey] ?? Future<void>.value();
    final operation = previous.catchError((_) {}).then((_) async {
      if (job.cancelled) {
        return null;
      }
      return _publishDownloadedFileAcrossProcesses(
        directory: directory,
        baseName: baseName,
        tempFile: tempFile,
        finalFile: finalFile,
        replacingInvalidEntry: replacingInvalidEntry,
        job: job,
      );
    });
    final tail = operation.then<void>((_) {}, onError: (_, _) {});
    _publicationTails[publicationKey] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_publicationTails[publicationKey], tail)) {
          _publicationTails.remove(publicationKey);
        }
      }),
    );
    return operation;
  }

  Future<String> _publicationKey(Directory directory) async {
    String directoryPath;
    try {
      directoryPath = await directory.resolveSymbolicLinks();
    } catch (_) {
      directoryPath = directory.absolute.path;
    }
    var key = p.canonicalize(directoryPath);
    if (Platform.isWindows) {
      key = key.toLowerCase();
    }
    return key;
  }

  Future<File?> _publishDownloadedFileAcrossProcesses({
    required Directory directory,
    required String baseName,
    required File tempFile,
    required File finalFile,
    required bool replacingInvalidEntry,
    required _RemoteCacheWarmup job,
  }) async {
    if (job.cancelled) {
      return null;
    }
    if (!_policy.useApplicationCacheDirectory) {
      return _publishDownloadedFileUnlocked(
        directory: directory,
        baseName: baseName,
        tempFile: tempFile,
        finalFile: finalFile,
        replacingInvalidEntry: replacingInvalidEntry,
        job: job,
      );
    }

    final lockFile = File(p.join(directory.path, _publicationLockFileName));
    RandomAccessFile? lockHandle;
    try {
      lockHandle = await lockFile.open(mode: FileMode.append);
      final acquired = await _acquirePublicationFileLock(lockHandle, job);
      if (!acquired) {
        await lockHandle.close();
        return null;
      }
    } catch (_) {
      await lockHandle?.close();
      // The cache is best effort. If cross-process coordination is unavailable,
      // fall back to streaming instead of publishing an ambiguous entry.
      return null;
    }

    try {
      if (job.cancelled) {
        return null;
      }
      return await _publishDownloadedFileUnlocked(
        directory: directory,
        baseName: baseName,
        tempFile: tempFile,
        finalFile: finalFile,
        replacingInvalidEntry: replacingInvalidEntry,
        job: job,
      );
    } finally {
      try {
        await lockHandle.unlock();
      } catch (_) {
        // Closing the handle also releases the OS lock.
      }
      await lockHandle.close();
    }
  }

  Future<bool> _acquirePublicationFileLock(
    RandomAccessFile lockHandle,
    _RemoteCacheWarmup job,
  ) async {
    final stopwatch = Stopwatch()..start();
    while (!job.cancelled && !_disposed) {
      try {
        await lockHandle.lock(FileLock.exclusive);
        return true;
      } catch (_) {
        if (stopwatch.elapsed >= _publicationLockTimeout) {
          return false;
        }
        await Future<void>.delayed(_publicationLockRetryDelay);
      }
    }
    return false;
  }

  Future<File?> _publishDownloadedFileUnlocked({
    required Directory directory,
    required String baseName,
    required File tempFile,
    required File finalFile,
    required bool replacingInvalidEntry,
    required _RemoteCacheWarmup job,
  }) async {
    if (job.cancelled) {
      return null;
    }
    if (!replacingInvalidEntry) {
      final concurrentlyCached = await _findCachedFile(directory, baseName);
      if (job.cancelled) {
        return null;
      }
      if (concurrentlyCached != null) {
        await _deleteIfExists(tempFile);
        return concurrentlyCached;
      }
    } else {
      // Retry after MediaKit has switched away from the failed local source;
      // Windows may have kept the corrupt file locked during the first
      // invalidation pass.
      await _deleteCachedVariants(directory, baseName);
    }
    if (job.cancelled) {
      return null;
    }
    try {
      return await tempFile.rename(finalFile.path);
    } catch (_) {
      if (job.cancelled) {
        return null;
      }
      final winner = replacingInvalidEntry
          ? null
          : await _findCachedFile(directory, baseName);
      if (winner != null) {
        await _deleteIfExists(tempFile);
        return winner;
      }
      rethrow;
    }
  }

  Future<void> _deleteUnprotectedAudio(
    Directory directory,
    int retentionGeneration,
  ) async {
    if (!await directory.exists() ||
        !_isRetentionCurrent(retentionGeneration)) {
      return;
    }
    await for (final entity in directory.list()) {
      if (!_isRetentionCurrent(retentionGeneration)) {
        return;
      }
      if (entity is! File) {
        continue;
      }
      final extension = p.extension(entity.path).toLowerCase();
      final baseName = p.basenameWithoutExtension(entity.path);
      if (extension == '.part') {
        await _deleteIfExists(entity, retentionGeneration: retentionGeneration);
      } else if (_audioExtensions.contains(extension) &&
          !_protectedBaseNames.contains(baseName)) {
        if (!_isRetentionCurrent(retentionGeneration)) {
          return;
        }
        await _deleteIfExists(entity, retentionGeneration: retentionGeneration);
      }
    }
  }

  Future<void> _trimCache(Directory directory, int retentionGeneration) async {
    if (!await directory.exists() ||
        !_isRetentionCurrent(retentionGeneration)) {
      return;
    }

    final now = _clock();
    final files = <({File file, DateTime modified, int length})>[];
    await for (final entity in directory.list()) {
      if (!_isRetentionCurrent(retentionGeneration)) {
        return;
      }
      if (entity is! File) {
        continue;
      }
      try {
        final modified = await entity.lastModified();
        final extension = p.extension(entity.path).toLowerCase();
        if (p.basename(entity.path) == _publicationLockFileName) {
          continue;
        }
        if (extension == '.part' || extension == '.lock') {
          final partialExpired =
              _policy.partialMaximumAge == Duration.zero ||
              now.difference(modified) > _policy.partialMaximumAge;
          if (partialExpired) {
            if (!_isRetentionCurrent(retentionGeneration)) {
              return;
            }
            await _deleteIfExists(
              entity,
              retentionGeneration: retentionGeneration,
            );
          }
          continue;
        }
        if (!_audioExtensions.contains(extension)) {
          continue;
        }
        final length = await entity.length();
        if (length <= 0) {
          await _deleteIfExists(
            entity,
            retentionGeneration: retentionGeneration,
          );
          continue;
        }
        final protected = _protectedBaseNames.contains(
          p.basenameWithoutExtension(entity.path),
        );
        if (!protected && now.difference(modified) > _maximumAge) {
          if (!_isRetentionCurrent(retentionGeneration)) {
            return;
          }
          await _deleteIfExists(
            entity,
            retentionGeneration: retentionGeneration,
          );
          continue;
        }
        files.add((file: entity, modified: modified, length: length));
      } catch (_) {
        // Best effort cache cleanup.
      }
    }

    final protectedPriorities = <String, int>{
      for (var index = 0; index < _protectedKeys.length; index++)
        'remote_${_protectedKeys[index]}': index,
    };
    int? protectionPriority(File file) =>
        protectedPriorities[p.basenameWithoutExtension(file.path)];

    files.sort((left, right) {
      final leftPriority = protectionPriority(left.file);
      final rightPriority = protectionPriority(right.file);
      if (leftPriority != null || rightPriority != null) {
        if (leftPriority == null) {
          return 1;
        }
        if (rightPriority == null) {
          return -1;
        }
        final priorityOrder = leftPriority.compareTo(rightPriority);
        if (priorityOrder != 0) {
          return priorityOrder;
        }
      }
      return right.modified.compareTo(left.modified);
    });

    var totalBytes = 0;
    var retainedFiles = 0;
    for (var index = 0; index < files.length; index++) {
      final entry = files[index];
      final file = entry.file;
      try {
        if (!_isRetentionCurrent(retentionGeneration)) {
          return;
        }
        final priority = protectionPriority(file);
        final exceedsLimits =
            retainedFiles >= _maximumFiles ||
            totalBytes + entry.length > _maximumBytes;
        // The active source (priority zero) may temporarily exceed a new
        // limit because deleting a file that ExoPlayer has open is unsafe.
        if (exceedsLimits && priority != 0) {
          await file.delete();
          continue;
        }
        retainedFiles++;
        totalBytes += entry.length;
      } catch (_) {
        // Best effort cache cleanup.
      }
    }
  }

  Future<void> _scheduleMaintenance(Future<void> Function() operation) {
    final future = _downloadTail.then((_) async {
      if (!_disposed) {
        await operation();
      }
    });
    _downloadTail = future.catchError((_) {});
    return future.catchError((_) {});
  }

  bool _isRetentionCurrent(int generation) {
    return !_disposed && generation == _retentionGeneration;
  }

  int _protectTracks(Iterable<TrackInfo> tracks) {
    final protectedKeys = tracks.map(_cacheKey).toSet().toList(growable: false);
    _protectedKeys = protectedKeys;
    final protectedKeySet = protectedKeys.toSet();
    for (final entry in _inFlight.entries) {
      if (!protectedKeySet.contains(entry.key)) {
        entry.value.cancel();
      }
    }
    return ++_retentionGeneration;
  }

  Set<String> get _protectedBaseNames => {
    for (final key in _protectedKeys) 'remote_$key',
  };

  Future<void> _deleteCachedVariants(
    Directory directory,
    String baseName,
  ) async {
    if (!await directory.exists()) {
      return;
    }
    await for (final entity in directory.list()) {
      if (entity is! File ||
          p.basenameWithoutExtension(entity.path) != baseName ||
          !_audioExtensions.contains(p.extension(entity.path).toLowerCase())) {
        continue;
      }
      await _deleteIfExists(entity);
    }
  }

  Future<void> _deleteIfExists(File file, {int? retentionGeneration}) async {
    try {
      final exists = await file.exists();
      if (retentionGeneration != null &&
          !_isRetentionCurrent(retentionGeneration)) {
        return;
      }
      if (exists) {
        await file.delete();
      }
    } catch (_) {
      // Best effort cleanup.
    }
  }

  bool _hasStream(TrackInfo track) {
    final streamUrl = track.streamUrl;
    return streamUrl != null && streamUrl.trim().isNotEmpty;
  }

  bool _isCacheableAudioContentType(ContentType? contentType) {
    final mime = contentType?.mimeType.toLowerCase();
    if (mime == null || mime.isEmpty) {
      return true;
    }
    return mime.startsWith('audio/') ||
        mime.startsWith('video/') ||
        mime == 'application/octet-stream' ||
        mime == 'binary/octet-stream' ||
        mime == 'application/ogg' ||
        mime == 'application/mp4' ||
        mime == 'application/webm' ||
        mime == 'application/x-m4a';
  }

  String _baseName(TrackInfo track) => 'remote_${_cacheKey(track)}';

  String _cacheKey(TrackInfo track) {
    final source = track.url.trim().isNotEmpty ? track.url : track.id;
    return _cacheKeyFromSource(source);
  }

  String _cacheKeyFromSource(String source) {
    if (_policy.useHashedKeys) {
      return sha256.convert(utf8.encode(source)).toString();
    }
    final encoded = base64Url.encode(utf8.encode(source)).replaceAll('=', '');
    if (encoded.length <= 72) {
      return encoded;
    }
    return encoded.substring(0, 72);
  }

  String _audioExtension(TrackInfo track, Uri uri, String? mimeType) {
    final mime =
        (mimeType ?? track.streamMimeType ?? uri.queryParameters['mime'] ?? '')
            .toLowerCase();
    if (mime.contains('audio/mp4') || mime.contains('mp4a')) {
      return '.m4a';
    }
    if (mime.contains('audio/webm') || mime.contains('webm')) {
      return '.webm';
    }
    if (mime.contains('audio/ogg') || mime.contains('ogg')) {
      return '.ogg';
    }
    if (mime.contains('opus')) {
      return '.opus';
    }
    if (mime.contains('mpeg') || mime.contains('mp3')) {
      return '.mp3';
    }
    if (mime.contains('aac')) {
      return '.aac';
    }
    if (mime.contains('3gpp') || mime.contains('3gp')) {
      return '.3gp';
    }
    final declaredExtension = track.streamExtension
        ?.trim()
        .toLowerCase()
        .replaceFirst('.', '');
    if (declaredExtension != null &&
        _audioExtensions.contains('.$declaredExtension')) {
      return '.$declaredExtension';
    }
    final pathExtension = p.extension(uri.path).toLowerCase();
    if (_audioExtensions.contains(pathExtension)) {
      return pathExtension;
    }
    return '.m4a';
  }
}

bool _isCompleteRemoteCacheResponse(HttpClientResponse response) {
  if (response.statusCode == HttpStatus.ok) {
    return true;
  }
  if (response.statusCode != HttpStatus.partialContent) {
    return false;
  }

  // A few media edges answer an un-ranged GET with 206. Accept that response
  // only when Content-Range proves it contains the complete entity; otherwise
  // publishing it would turn a prefix into a corrupt cache hit.
  final rawRange = response.headers.value(HttpHeaders.contentRangeHeader);
  if (rawRange == null) {
    return false;
  }
  final match = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+)$',
    caseSensitive: false,
  ).firstMatch(rawRange.trim());
  if (match == null) {
    return false;
  }
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final total = int.tryParse(match.group(3)!);
  if (start != 0 || end == null || total == null || total <= 0) {
    return false;
  }
  if (end != total - 1) {
    return false;
  }
  return response.contentLength < 0 || response.contentLength == total;
}

class _RemoteCacheWarmup {
  _RemoteCacheWarmup({required this.cancelOnSearchChange});

  late final Future<File?> future;
  bool cancelOnSearchChange;
  bool cancelled = false;
  HttpClient? client;
  File? tempFile;

  void cancel() {
    if (cancelled) {
      return;
    }
    cancelled = true;
    client?.close(force: true);
  }
}
