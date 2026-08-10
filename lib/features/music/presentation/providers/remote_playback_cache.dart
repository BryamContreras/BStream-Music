part of 'music_providers.dart';

final remotePlaybackCacheProvider = Provider<RemotePlaybackCache>((ref) {
  final cache = RemotePlaybackCache();
  ref.onDispose(cache.dispose);
  return cache;
});

class RemotePlaybackCache {
  RemotePlaybackCache({
    bool? isAndroid,
    this.cacheDirectoryProvider,
    DateTime Function()? clock,
    Duration maximumAge = const Duration(minutes: 30),
    int maximumFiles = 3,
    int maximumBytes = 64 * 1024 * 1024,
  }) : assert(maximumAge >= Duration.zero),
       assert(maximumFiles > 0),
       assert(maximumBytes > 0),
       _isAndroid = isAndroid ?? AppPlatform.isAndroid,
       _clock = clock ?? DateTime.now,
       _maximumAge = maximumAge,
       _maximumFiles = maximumFiles,
       _maximumBytes = maximumBytes;

  static const _cacheFolderName = 'remote-playback-cache';
  static const _downloadIdleTimeout = Duration(seconds: 20);
  static const _downloadTotalTimeout = Duration(minutes: 30);
  static const _userAgent =
      'BStreamMusic/${AppConstants.appVersion} (Android) AppleWebKit/537.36 Chrome/125.0.0.0 Safari/537.36';
  static const _audioExtensions = {
    '.aiff',
    '.alac',
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

  final bool _isAndroid;
  final Future<Directory> Function()? cacheDirectoryProvider;
  final DateTime Function() _clock;
  final Duration _maximumAge;
  final int _maximumFiles;
  final int _maximumBytes;
  final _inFlight = <String, _RemoteCacheWarmup>{};
  Set<String> _protectedKeys = <String>{};
  Future<void> _downloadTail = Future<void>.value();
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    for (final job in _inFlight.values) {
      job.cancel();
    }
    _inFlight.clear();
  }

  /// Removes abandoned partial files and bounds leftovers from an interrupted
  /// process. Active sources are protected so rebuilding the Android activity
  /// cannot interrupt background playback.
  Future<void> prepareSession({
    Iterable<String> protectedSourceUrls = const <String>[],
  }) {
    if (!_isAndroid || _disposed) {
      return Future<void>.value();
    }
    _protectedKeys = protectedSourceUrls
        .map((source) => source.trim())
        .where((source) => source.isNotEmpty)
        .map(_cacheKeyFromSource)
        .toSet();
    return _scheduleMaintenance(() async {
      final directory = await _cacheDirectory();
      await _trimCache(directory);
    });
  }

  /// Keeps only the files required by the active playback window. The caller
  /// passes the previous, current, and predictable next remote tracks. Only
  /// tracks that have already been played or explicitly warmed exist on disk;
  /// retaining a track never downloads it by itself.
  Future<void> retainOnlyTracks(Iterable<TrackInfo> tracks) {
    if (!_isAndroid || _disposed) {
      return Future<void>.value();
    }
    final protectedKeys = tracks.map(_cacheKey).toSet();
    _protectedKeys = protectedKeys;
    for (final entry in _inFlight.entries) {
      if (!protectedKeys.contains(entry.key)) {
        entry.value.cancel();
      }
    }
    return _scheduleMaintenance(() async {
      final directory = await _cacheDirectory();
      await _deleteUnprotectedAudio(directory);
      await _trimCache(directory);
    });
  }

  void cancelSearchWarmups() {
    for (final job in _inFlight.values) {
      if (job.cancelOnSearchChange) {
        job.cancel();
      }
    }
  }

  /// Cancels the single-track playback warmup when the user changes the
  /// current queue item. Search warmups use a separate cancellation policy.
  void cancelPlaybackWarmups() {
    for (final job in _inFlight.values) {
      if (!job.cancelOnSearchChange) {
        job.cancel();
      }
    }
  }

  Future<File?> cachedFile(TrackInfo track) async {
    if (!_isAndroid) {
      return null;
    }

    final directory = await _cacheDirectory();
    final file = await _findCachedFile(directory, _baseName(track));
    if (file != null) {
      try {
        await file.setLastModified(DateTime.now());
      } catch (_) {
        // The file remains usable even if touching it fails.
      }
    }
    return file;
  }

  Future<File?> warmResolved(
    TrackInfo track, {
    bool cancelOnSearchChange = false,
  }) {
    if (!_isAndroid || _disposed || !_hasStream(track)) {
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
    final future = _downloadTail.then((_) {
      if (_disposed || job.cancelled) {
        return null;
      }
      return _downloadIfMissing(track, job);
    });
    job.future = future;
    _inFlight[key] = job;
    _downloadTail = future.catchError((_) => null).then((_) {});
    unawaited(
      future.whenComplete(() {
        if (identical(_inFlight[key], job)) {
          _inFlight.remove(key);
        }
      }),
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
    await _trimCache(directory);

    final baseName = _baseName(track);
    final cached = await _findCachedFile(directory, baseName);
    if (cached != null) {
      return cached;
    }

    final uri = Uri.tryParse(track.streamUrl ?? '');
    if (uri == null || !uri.hasScheme) {
      return null;
    }

    final tempFile = File(p.join(directory.path, '$baseName.part'));
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
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _deleteIfExists(tempFile);
        return null;
      }

      final extension = _audioExtension(
        uri,
        response.headers.contentType?.mimeType,
      );
      final finalFile = File(p.join(directory.path, '$baseName$extension'));
      await _deleteExistingVariants(directory, baseName);
      final written = await writeBoundedByteStreamToFile(
        response,
        tempFile,
        maximumBytes: _maximumBytes,
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
      await tempFile.rename(finalFile.path);
      await _trimCache(directory);
      return finalFile;
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
    final directory = Directory(
      p.join(
        (await getTemporaryDirectory()).path,
        'BStream-Music',
        _cacheFolderName,
      ),
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
    final existing = <File>[];
    for (final file in files) {
      try {
        if (await file.length() > 0) {
          existing.add(file);
        }
      } catch (_) {
        // Ignore stale files that disappear while scanning.
      }
    }
    if (existing.isEmpty) {
      return null;
    }
    existing.sort(
      (left, right) =>
          right.lastModifiedSync().compareTo(left.lastModifiedSync()),
    );
    return existing.first;
  }

  Future<void> _deleteUnprotectedAudio(Directory directory) async {
    if (!await directory.exists()) {
      return;
    }
    await for (final entity in directory.list()) {
      if (entity is! File) {
        continue;
      }
      final extension = p.extension(entity.path).toLowerCase();
      final baseName = p.basenameWithoutExtension(entity.path);
      if (extension == '.part') {
        await _deleteIfExists(entity);
      } else if (_audioExtensions.contains(extension) &&
          !_protectedBaseNames.contains(baseName)) {
        await _deleteIfExists(entity);
      }
    }
  }

  Future<void> _trimCache(Directory directory) async {
    if (!await directory.exists()) {
      return;
    }

    final now = _clock();
    final files = <File>[];
    await for (final entity in directory.list()) {
      if (entity is! File) {
        continue;
      }
      try {
        final modified = await entity.lastModified();
        final protected = _protectedBaseNames.contains(
          p.basenameWithoutExtension(entity.path),
        );
        if (p.extension(entity.path) == '.part' ||
            (!protected && now.difference(modified) > _maximumAge)) {
          await entity.delete();
          continue;
        }
        if (_audioExtensions.contains(p.extension(entity.path).toLowerCase())) {
          files.add(entity);
        }
      } catch (_) {
        // Best effort cache cleanup.
      }
    }

    files.sort((left, right) {
      final leftProtected = _isProtectedFile(left);
      final rightProtected = _isProtectedFile(right);
      if (leftProtected != rightProtected) {
        return leftProtected ? -1 : 1;
      }
      return right.lastModifiedSync().compareTo(left.lastModifiedSync());
    });

    var totalBytes = 0;
    var retainedFiles = 0;
    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      try {
        final length = await file.length();
        if (_isProtectedFile(file)) {
          retainedFiles++;
          totalBytes += length;
          continue;
        }
        if (retainedFiles >= _maximumFiles ||
            totalBytes + length > _maximumBytes) {
          await file.delete();
          continue;
        }
        retainedFiles++;
        totalBytes += length;
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

  Set<String> get _protectedBaseNames => {
    for (final key in _protectedKeys) 'remote_$key',
  };

  bool _isProtectedFile(File file) {
    return _protectedBaseNames.contains(p.basenameWithoutExtension(file.path));
  }

  Future<void> _deleteExistingVariants(Directory directory, String baseName) {
    return Future.wait([
      for (final extension in _audioExtensions)
        _deleteIfExists(File(p.join(directory.path, '$baseName$extension'))),
    ]);
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
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

  String _baseName(TrackInfo track) => 'remote_${_cacheKey(track)}';

  String _cacheKey(TrackInfo track) {
    final source = track.url.trim().isNotEmpty ? track.url : track.id;
    return _cacheKeyFromSource(source);
  }

  String _cacheKeyFromSource(String source) {
    final encoded = base64Url.encode(utf8.encode(source)).replaceAll('=', '');
    if (encoded.length <= 72) {
      return encoded;
    }
    return encoded.substring(0, 72);
  }

  String _audioExtension(Uri uri, String? mimeType) {
    final mime = (mimeType ?? uri.queryParameters['mime'] ?? '').toLowerCase();
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
    final pathExtension = p.extension(uri.path).toLowerCase();
    if (_audioExtensions.contains(pathExtension)) {
      return pathExtension;
    }
    return '.m4a';
  }
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
