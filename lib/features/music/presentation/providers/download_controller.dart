part of 'music_providers.dart';

final downloadControllerProvider =
    NotifierProvider<DownloadController, Map<String, DownloadTaskState>>(
      DownloadController.new,
    );

class DownloadTaskState {
  const DownloadTaskState({
    required this.url,
    required this.mediaType,
    required this.status,
    this.progress,
    this.result,
    this.localTrack,
    this.errorMessage,
    this.title,
  });

  final String url;
  final DownloadMediaType mediaType;
  final DownloadProgressStatus status;
  final double? progress;
  final DownloadResult? result;
  final LocalTrack? localTrack;
  final String? errorMessage;
  final String? title;

  DownloadTaskState copyWith({
    DownloadProgressStatus? status,
    double? progress,
    DownloadResult? result,
    LocalTrack? localTrack,
    String? errorMessage,
    String? title,
  }) {
    return DownloadTaskState(
      url: url,
      mediaType: mediaType,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      result: result ?? this.result,
      localTrack: localTrack ?? this.localTrack,
      errorMessage: errorMessage ?? this.errorMessage,
      title: title ?? this.title,
    );
  }
}

class DownloadController extends Notifier<Map<String, DownloadTaskState>> {
  final _queue = <TrackInfo>[];
  final _cleanupTimers = <String, Timer>{};
  bool _isProcessing = false;

  @override
  Map<String, DownloadTaskState> build() {
    final subscription = ref
        .read(downloaderServiceProvider)
        .progressStream
        .listen((progress) {
          final existing = state[progress.url];
          if (existing == null) {
            return;
          }
          final nextStatus = _nextStatusForProgress(existing, progress);
          final nextProgress = _nextProgress(
            existing.progress,
            progress.progress,
          );
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
            progress.url: existing.copyWith(
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
    });
    return const {};
  }

  Future<void> downloadAudio(TrackInfo track) {
    return _enqueue(track, DownloadMediaType.audio);
  }

  Future<LocalTrack> downloadAudioForLibrary(TrackInfo track) async {
    final metadataTrack = await _resolveDownloadTrack(track);
    final existing = await ref
        .read(localTrackDownloadHelperProvider)
        .findExistingLocalTrack(metadataTrack);
    if (existing != null) {
      return existing;
    }

    final completedTask = state[metadataTrack.url];
    if (completedTask?.status == DownloadProgressStatus.completed) {
      final completedTrack = await _waitForDownloadedLocalTrack(completedTask!);
      if (completedTrack != null) {
        return completedTrack;
      }
    }

    await downloadAudio(metadataTrack);
    final task = await _waitForCompletedTask(metadataTrack.url);
    final localTrack = await _waitForDownloadedLocalTrack(task);
    if (localTrack == null) {
      throw StateError('No se encontro la cancion descargada.');
    }
    return localTrack;
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
        mediaType: mediaType,
        status: DownloadProgressStatus.queued,
        progress: 0,
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
        await _download(track, DownloadMediaType.audio);
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<DownloadTaskState> _waitForCompletedTask(String url) async {
    while (true) {
      final task = state[url];
      if (task == null) {
        throw StateError('No se encontro la descarga.');
      }
      switch (task.status) {
        case DownloadProgressStatus.completed:
          if (task.result != null || task.localTrack != null) {
            return task;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        case DownloadProgressStatus.failed:
          throw StateError(task.errorMessage ?? 'No se pudo descargar.');
        case DownloadProgressStatus.queued:
        case DownloadProgressStatus.running:
          await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  Future<LocalTrack?> _waitForDownloadedLocalTrack(
    DownloadTaskState task,
  ) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final freshTask = state[task.url] ?? task;
      final localTrack = await _findDownloadedLocalTrack(freshTask);
      if (localTrack != null) {
        return localTrack;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<LocalTrack?> _findDownloadedLocalTrack(DownloadTaskState task) async {
    final localTrack = task.localTrack;
    if (localTrack != null) {
      return localTrack;
    }

    final result = task.result;
    if (result == null) {
      return null;
    }

    final tracks = await ref.read(libraryRepositoryProvider).getLocalTracks();
    for (final track in tracks) {
      if (track.id == result.id) {
        return track;
      }
    }
    for (final track in tracks) {
      if (track.sourceUrl == result.sourceUrl) {
        return track;
      }
    }
    return null;
  }

  Future<void> _download(TrackInfo track, DownloadMediaType mediaType) async {
    state = {
      ...state,
      track.url: state[track.url]!.copyWith(
        status: DownloadProgressStatus.running,
        progress: math.max(state[track.url]!.progress ?? 0, 0.02),
      ),
    };

    final settings = await ref.read(settingsControllerProvider.future);
    final metadataTrack = await _resolveDownloadTrack(track);
    final audioDirectory = p.join(settings.downloadDirectory, 'audio');
    final thumbnailsDirectory = p.join(
      settings.downloadDirectory,
      'thumbnails',
    );
    await _removeMisplacedThumbnailFiles(audioDirectory);
    final options = DownloadOptions(
      outputDirectory: audioDirectory,
      fileName: safeFileName(
        '${metadataTrack.artist} - ${metadataTrack.title}',
      ),
    );

    state = {
      ...state,
      track.url: state[track.url]!.copyWith(title: metadataTrack.title),
    };

    try {
      final result = await ref
          .read(downloadAudioProvider)
          .call(track.url, options);
      final thumbnailPath = await _saveThumbnail(
        metadataTrack,
        thumbnailsDirectory,
      );
      final localTrack = LocalTrack(
        id: result.id,
        title: metadataTrack.title,
        artist: metadataTrack.artist,
        filePath: result.filePath,
        addedAt: result.completedAt,
        sourceUrl: metadataTrack.url,
        thumbnailUrl: metadataTrack.thumbnailUrl,
        thumbnailPath: thumbnailPath,
        duration: metadataTrack.duration,
      );

      await ref.read(libraryRepositoryProvider).saveLocalTrack(localTrack);

      state = {
        ...state,
        track.url: state[track.url]!.copyWith(
          status: DownloadProgressStatus.completed,
          progress: 1,
          result: result,
          localTrack: localTrack,
        ),
      };
      _scheduleCleanup(track.url, const Duration(seconds: 3));
      ref.invalidate(libraryTracksProvider);
    } catch (error) {
      state = {
        ...state,
        track.url: state[track.url]!.copyWith(
          status: DownloadProgressStatus.failed,
          errorMessage: error.toString(),
        ),
      };
      _scheduleCleanup(track.url, const Duration(seconds: 10));
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

  Future<void> _removeMisplacedThumbnailFiles(String audioDirectory) async {
    final directory = Directory(audioDirectory);
    if (!await directory.exists()) {
      return;
    }

    final files = await directory
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    for (final file in files) {
      final extension = p.extension(file.path).toLowerCase();
      if (const {'.jpg', '.jpeg', '.png', '.webp'}.contains(extension)) {
        try {
          await file.delete();
        } catch (_) {
          // Best effort cleanup for files left by older Android download commands.
        }
      }
    }
  }

  Future<TrackInfo> _resolveDownloadTrack(TrackInfo track) async {
    if (track.thumbnailUrl != null &&
        track.duration != null &&
        track.title.trim().isNotEmpty &&
        track.artist.trim().isNotEmpty) {
      return track;
    }

    return ref.read(remoteTrackResolverProvider).resolve(track);
  }

  Future<String?> _saveThumbnail(TrackInfo track, String directoryPath) async {
    final candidates = _thumbnailCandidates(track).toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }

    final directory = Directory(directoryPath);
    await directory.create(recursive: true);
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);
    try {
      for (final uri in candidates) {
        final path = await _downloadThumbnail(client, uri, track, directory);
        if (path != null) {
          return path;
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _downloadThumbnail(
    HttpClient client,
    Uri uri,
    TrackInfo track,
    Directory directory,
  ) async {
    final request = await client.getUrl(uri);
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    );
    request.headers.set(
      HttpHeaders.acceptHeader,
      'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
    );
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }

    final bytes = await response.fold<List<int>>(
      <int>[],
      (previous, chunk) => previous..addAll(chunk),
    );
    final extension = _thumbnailExtension(
      uri,
      response.headers.contentType?.mimeType,
      bytes,
    );
    if (bytes.isEmpty || extension == null) {
      return null;
    }

    final identity = track.id.isEmpty
        ? track.url.hashCode.toString()
        : track.id;
    final baseName = safeFileName('${track.artist} - ${track.title} $identity');
    await _deleteExistingThumbnailVariants(directory, baseName);
    final file = File(p.join(directory.path, '$baseName$extension'));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> _deleteExistingThumbnailVariants(
    Directory directory,
    String baseName,
  ) async {
    final variants = {
      for (final extension in const ['.jpg', '.jpeg', '.png', '.webp'])
        p.join(directory.path, '$baseName$extension'),
    };
    for (final path in variants) {
      final file = File(path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          // Best effort cleanup; overwriting the current target still works.
        }
      }
    }
  }

  Iterable<Uri> _thumbnailCandidates(TrackInfo track) sync* {
    final seen = <String>{};
    final direct = track.thumbnailUrl?.trim();
    final directUri = direct == null ? null : Uri.tryParse(direct);
    if (directUri != null &&
        directUri.hasScheme &&
        seen.add(directUri.toString())) {
      yield directUri;
    }

    final videoId = _youtubeVideoId(track);
    if (videoId == null) {
      return;
    }
    for (final name in const ['maxresdefault.jpg', 'hqdefault.jpg']) {
      final uri = Uri.parse('https://i.ytimg.com/vi/$videoId/$name');
      if (seen.add(uri.toString())) {
        yield uri;
      }
    }
  }

  String? _youtubeVideoId(TrackInfo track) {
    final id = track.id.trim();
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) {
      return id;
    }

    final uri = Uri.tryParse(track.url);
    if (uri == null) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.first;
    }
    if (!host.contains('youtube.com')) {
      return null;
    }
    final queryId = uri.queryParameters['v'];
    if (queryId != null && queryId.isNotEmpty) {
      return queryId;
    }
    if (uri.pathSegments.length >= 2 &&
        const {'shorts', 'embed'}.contains(uri.pathSegments.first)) {
      return uri.pathSegments[1];
    }
    return null;
  }

  String? _thumbnailExtension(Uri uri, String? contentType, List<int> bytes) {
    if (_isJpeg(bytes)) {
      return '.jpg';
    }
    if (_isPng(bytes)) {
      return '.png';
    }
    if (_isWebp(bytes)) {
      return '.webp';
    }

    final pathExtension = p.extension(uri.path).toLowerCase();
    if (const {'.jpg', '.jpeg', '.png', '.webp'}.contains(pathExtension)) {
      return pathExtension;
    }
    return switch (contentType) {
      'image/png' => '.png',
      'image/webp' => '.webp',
      'image/jpeg' => '.jpg',
      _ => null,
    };
  }

  bool _isJpeg(List<int> bytes) {
    return bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF;
  }

  bool _isPng(List<int> bytes) {
    return bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
  }

  bool _isWebp(List<int> bytes) {
    return bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
  }
}
