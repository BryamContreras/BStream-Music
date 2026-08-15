part of 'music_providers.dart';

final localTrackDownloadHelperProvider = Provider<LocalTrackDownloadHelper>((
  ref,
) {
  return LocalTrackDownloadHelper(ref);
});

class LocalTrackDownloadResult {
  const LocalTrackDownloadResult({
    required this.track,
    required this.remoteTrack,
    required this.reusedExisting,
    this.downloadResult,
  });

  final LocalTrack track;
  final TrackInfo remoteTrack;
  final bool reusedExisting;
  final DownloadResult? downloadResult;
}

class LocalTrackDownloadHelper {
  LocalTrackDownloadHelper(Ref ref) : _ref = ref;

  static const _maxThumbnailBytes = 10 * 1024 * 1024;
  static const _thumbnailIdleTimeout = Duration(seconds: 10);
  static const _thumbnailTotalTimeout = Duration(seconds: 30);

  final Ref _ref;
  final Map<String, Future<LocalTrackDownloadResult>> _inFlight = {};
  Future<void> _downloadTail = Future<void>.value();

  Future<LocalTrackDownloadResult> resolveForLibrary(
    TrackInfo track, {
    String? taskId,
    void Function(TrackInfo track)? onResolved,
    void Function()? onDownloadStarted,
  }) {
    return _ref
        .read(libraryOperationCoordinatorProvider)
        .runWithGate(
          () => _resolveForLibraryGated(
            track,
            taskId: taskId,
            onResolved: onResolved,
            onDownloadStarted: onDownloadStarted,
          ),
        );
  }

  Future<LocalTrackDownloadResult> _resolveForLibraryGated(
    TrackInfo track, {
    required String? taskId,
    required void Function(TrackInfo track)? onResolved,
    required void Function()? onDownloadStarted,
  }) async {
    final identity = _trackIdentity(track);
    final active = _inFlight[identity];
    if (active != null) {
      final result = await active;
      onResolved?.call(result.remoteTrack);
      return result;
    }

    late final Future<LocalTrackDownloadResult> operation;
    operation = _resolveAndDownload(
      track,
      taskId: taskId,
      onResolved: onResolved,
      onDownloadStarted: onDownloadStarted,
    );
    _inFlight[identity] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[identity], operation)) {
        _inFlight.remove(identity);
      }
    }
  }

  Future<LocalTrackDownloadResult> _resolveAndDownload(
    TrackInfo track, {
    required String? taskId,
    required void Function(TrackInfo track)? onResolved,
    required void Function()? onDownloadStarted,
  }) async {
    final metadataTrack = await _resolveDownloadTrack(track);
    onResolved?.call(metadataTrack);

    final existing = await findExistingLocalTrack(metadataTrack);
    if (existing != null) {
      final enriched = await _enrichExistingTrack(existing, metadataTrack);
      return LocalTrackDownloadResult(
        track: enriched,
        remoteTrack: metadataTrack,
        reusedExisting: true,
      );
    }

    return _serializeDownload(() async {
      // A different source may have completed while this request waited for
      // the downloader. Recheck inside the shared critical section.
      final matching = await _findMatchingLocalTrack(metadataTrack);
      if (matching != null && await _isUsableAudioFile(matching.filePath)) {
        return LocalTrackDownloadResult(
          track: matching,
          remoteTrack: metadataTrack,
          reusedExisting: true,
        );
      }

      await _deleteUnusableStaleFile(matching);
      onDownloadStarted?.call();
      return _downloadAndSave(
        metadataTrack,
        staleMatch: matching,
        taskId: taskId,
      );
    });
  }

  Future<LocalTrackDownloadResult> _downloadAndSave(
    TrackInfo metadataTrack, {
    required LocalTrack? staleMatch,
    required String? taskId,
  }) async {
    final audioDirectory = await _audioDirectory();
    final thumbnailsDirectory = await _thumbnailsDirectory();
    await _removeMisplacedThumbnailFiles(audioDirectory);
    final identityDigest = sha256
        .convert(utf8.encode(_trackIdentity(metadataTrack)))
        .toString();
    final options = DownloadOptions(
      outputDirectory: audioDirectory,
      fileName: _identityFileName(metadataTrack, identityDigest),
      taskId: taskId,
    );

    final result = await _ref
        .read(downloadAudioProvider)
        .call(metadataTrack.url, options);
    if (!await _isExpectedDownloadedFile(
      result.filePath,
      audioDirectory: audioDirectory,
      identityDigest: identityDigest,
    )) {
      throw const DownloaderException(
        'La descarga finalizo sin un archivo de audio valido.',
        code: 'invalid_download_file',
      );
    }
    _SavedThumbnail? savedThumbnail;
    try {
      savedThumbnail = await _saveThumbnail(
        metadataTrack,
        thumbnailsDirectory,
        identityDigest,
      );

      final localTrack = LocalTrack(
        id: staleMatch?.id ?? 'remote-${identityDigest.substring(0, 24)}',
        title: metadataTrack.title,
        artist: metadataTrack.artist,
        filePath: result.filePath,
        addedAt: staleMatch?.addedAt ?? result.completedAt,
        sourceUrl: metadataTrack.url,
        thumbnailUrl: savedThumbnail?.sourceUrl ?? metadataTrack.thumbnailUrl,
        catalogThumbnailUrl: metadataTrack.catalogThumbnailUrl,
        thumbnailPath: savedThumbnail?.path ?? staleMatch?.thumbnailPath,
        duration: metadataTrack.duration,
        album: metadataTrack.album,
        artists: _artistsForPersistence(metadataTrack),
        metadataSource: metadataTrack.metadataSource,
        sourceId: metadataTrack.id.trim().isEmpty ? null : metadataTrack.id,
        lastPlayedAt: staleMatch?.lastPlayedAt,
        lastPlayedPlaylistId: staleMatch?.lastPlayedPlaylistId,
      );

      await _ref.read(libraryRepositoryProvider).saveLocalTrack(localTrack);
      await _commitSavedThumbnail(savedThumbnail);
      _ref.invalidate(libraryTracksProvider);

      return LocalTrackDownloadResult(
        track: localTrack,
        remoteTrack: metadataTrack,
        reusedExisting: false,
        downloadResult: result,
      );
    } catch (_) {
      // The media file is not useful unless its library row was persisted.
      // Remove only artifacts produced by this attempt; a stale row's prior
      // thumbnail remains intact when it was overwritten in place.
      await _deleteFileBestEffort(result.filePath);
      await _rollbackSavedThumbnail(savedThumbnail);
      rethrow;
    }
  }

  Future<LocalTrack?> findExistingLocalTrack(TrackInfo track) async {
    final tracks = await _ref.read(libraryRepositoryProvider).getLocalTracks();
    for (final localTrack in tracks) {
      if (_matchesTrackIdentity(localTrack, track) &&
          await _isUsableAudioFile(localTrack.filePath)) {
        return localTrack;
      }
    }
    return null;
  }

  Future<LocalTrack?> _findMatchingLocalTrack(TrackInfo track) async {
    final tracks = await _ref.read(libraryRepositoryProvider).getLocalTracks();
    for (final localTrack in tracks) {
      if (_matchesTrackIdentity(localTrack, track)) {
        return localTrack;
      }
    }
    return null;
  }

  Future<String> _audioDirectory() async {
    final settings = await _ref.read(settingsControllerProvider.future);
    return p.join(settings.downloadDirectory, 'audio');
  }

  Future<String> _thumbnailsDirectory() async {
    final settings = await _ref.read(settingsControllerProvider.future);
    return p.join(settings.downloadDirectory, 'thumbnails');
  }

  Future<TrackInfo> _resolveDownloadTrack(TrackInfo track) async {
    if (!_needsMetadataFallback(track)) {
      return track;
    }

    try {
      // Metadata enrichment is sourced from the downloader (yt-dlp / Android
      // youtubedl-android). The audio stream resolver is reserved for
      // playback streams and only carries transport data.
      final resolved = await _ref.read(getPlaybackInfoProvider).call(track.url);
      return _mergeTrackInfo(track, resolved);
    } catch (_) {
      // Metadata enrichment is best effort. The downloader still gets a
      // chance to fetch the media when InnerTube supplied a valid identity.
      if (track.url.trim().isNotEmpty &&
          _isMeaningfulTitle(track.title) &&
          _isMeaningfulArtist(track.artist)) {
        return track;
      }
      rethrow;
    }
  }

  bool _needsMetadataFallback(TrackInfo track) {
    return !_isMeaningfulTitle(track.title) ||
        !_isMeaningfulArtist(track.artist) ||
        track.artists.where(_isMeaningfulArtist).isEmpty ||
        track.album?.trim().isEmpty != false ||
        track.duration == null ||
        track.duration! <= Duration.zero ||
        track.thumbnailUrl?.trim().isEmpty != false;
  }

  bool _isMeaningfulTitle(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isNotEmpty &&
        !const {'sin titulo', 'sin título', 'untitled'}.contains(normalized);
  }

  bool _isMeaningfulArtist(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isNotEmpty &&
        !const {
          'desconocido',
          'unknown',
          'unknown artist',
          'sin artista',
        }.contains(normalized);
  }

  List<String> _artistsForPersistence(TrackInfo track) {
    final artists = track.artists
        .map((artist) => artist.trim())
        .where(_isMeaningfulArtist)
        .toSet()
        .toList(growable: false);
    if (artists.isNotEmpty) {
      return artists;
    }
    return _isMeaningfulArtist(track.artist) ? [track.artist.trim()] : const [];
  }

  Future<LocalTrack> _enrichExistingTrack(
    LocalTrack existing,
    TrackInfo metadata,
  ) async {
    final incomingIsCanonical =
        metadata.metadataSource == TrackMetadataSource.youtubeMusic;
    final existingArtists = existing.artists
        .where(_isMeaningfulArtist)
        .toList(growable: false);
    final incomingArtists = _artistsForPersistence(metadata);
    final nextArtists = incomingIsCanonical && incomingArtists.isNotEmpty
        ? incomingArtists
        : existingArtists.isNotEmpty
        ? existingArtists
        : incomingArtists;
    final nextAlbum = incomingIsCanonical
        ? _preferredMetadataText(metadata.album, existing.album)
        : _preferredMetadataText(existing.album, metadata.album);
    final nextCatalogThumbnail = _preferredMetadataText(
      metadata.catalogThumbnailUrl,
      existing.catalogThumbnailUrl,
    );

    final currentThumbnailPath = existing.thumbnailPath?.trim();
    final hasUsableThumbnail =
        currentThumbnailPath != null &&
        currentThumbnailPath.isNotEmpty &&
        await _isUsableFile(currentThumbnailPath);
    final incomingThumbnail = metadata.thumbnailUrl?.trim();
    final shouldRefreshThumbnail =
        !hasUsableThumbnail ||
        (incomingIsCanonical &&
            incomingThumbnail != null &&
            incomingThumbnail.isNotEmpty &&
            incomingThumbnail != existing.thumbnailUrl?.trim());
    _SavedThumbnail? savedThumbnail;
    if (shouldRefreshThumbnail) {
      final identityDigest = sha256
          .convert(utf8.encode(_trackIdentity(metadata)))
          .toString();
      savedThumbnail = await _saveThumbnail(
        metadata,
        await _thumbnailsDirectory(),
        identityDigest,
      );
    }

    final canonicalTitle =
        incomingIsCanonical && _isMeaningfulTitle(metadata.title)
        ? metadata.title
        : existing.title;
    final canonicalArtist = incomingIsCanonical && incomingArtists.isNotEmpty
        ? incomingArtists.join(', ')
        : existing.artist;
    final next = LocalTrack(
      id: existing.id,
      title: _isMeaningfulTitle(canonicalTitle)
          ? canonicalTitle
          : metadata.title,
      artist: _isMeaningfulArtist(canonicalArtist)
          ? canonicalArtist
          : metadata.artist,
      filePath: existing.filePath,
      addedAt: existing.addedAt,
      sourceUrl: existing.sourceUrl ?? metadata.url,
      thumbnailUrl:
          savedThumbnail?.sourceUrl ??
          (incomingIsCanonical
              ? _preferredMetadataText(
                  metadata.thumbnailUrl,
                  existing.thumbnailUrl,
                )
              : _preferredMetadataText(
                  existing.thumbnailUrl,
                  metadata.thumbnailUrl,
                )),
      catalogThumbnailUrl: nextCatalogThumbnail,
      thumbnailPath:
          savedThumbnail?.path ??
          (hasUsableThumbnail ? existing.thumbnailPath : null),
      duration: incomingIsCanonical
          ? metadata.duration ?? existing.duration
          : existing.duration ?? metadata.duration,
      album: nextAlbum,
      artists: nextArtists,
      metadataSource: incomingIsCanonical
          ? TrackMetadataSource.youtubeMusic
          : existing.metadataSource,
      sourceId: incomingIsCanonical
          ? (metadata.id.trim().isEmpty ? existing.sourceId : metadata.id)
          : existing.sourceId ??
                (metadata.id.trim().isEmpty ? null : metadata.id),
      lastPlayedAt: existing.lastPlayedAt,
      lastPlayedPlaylistId: existing.lastPlayedPlaylistId,
      isExternal: existing.isExternal,
    );
    if (_hasSameStoredMetadata(existing, next)) {
      await _commitSavedThumbnail(savedThumbnail);
      return existing;
    }
    try {
      await _ref.read(libraryRepositoryProvider).saveLocalTrack(next);
      await _commitSavedThumbnail(savedThumbnail);
      _ref.invalidate(libraryTracksProvider);
      return next;
    } catch (_) {
      await _rollbackSavedThumbnail(savedThumbnail);
      rethrow;
    }
  }

  String? _preferredMetadataText(String? preferred, String? fallback) {
    final normalized = preferred?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return preferred;
    }
    final fallbackNormalized = fallback?.trim();
    return fallbackNormalized == null || fallbackNormalized.isEmpty
        ? null
        : fallback;
  }

  bool _hasSameStoredMetadata(LocalTrack left, LocalTrack right) {
    return left.title == right.title &&
        left.artist == right.artist &&
        left.filePath == right.filePath &&
        left.sourceUrl == right.sourceUrl &&
        left.thumbnailUrl == right.thumbnailUrl &&
        left.catalogThumbnailUrl == right.catalogThumbnailUrl &&
        left.thumbnailPath == right.thumbnailPath &&
        left.duration == right.duration &&
        left.album == right.album &&
        _sameStrings(left.artists, right.artists) &&
        left.metadataSource == right.metadataSource &&
        left.sourceId == right.sourceId;
  }

  bool _sameStrings(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  bool _matchesTrackIdentity(LocalTrack localTrack, TrackInfo remoteTrack) {
    final localSource = _canonicalSource(localTrack.sourceUrl);
    final remoteSource = _canonicalSource(remoteTrack.url);
    if (localSource != null && remoteSource != null) {
      // A strong but different source wins over coincidental metadata. This
      // keeps live/remix/karaoke versions from being treated as one download.
      return localSource == remoteSource;
    }

    final localTitle = _normalizeMatchText(localTrack.title);
    final remoteTitle = _normalizeMatchText(remoteTrack.title);
    if (localTitle.isEmpty || remoteTitle.isEmpty) {
      return false;
    }

    final localArtist = _normalizeMatchText(localTrack.artist);
    final remoteArtist = _normalizeMatchText(remoteTrack.artist);
    if (localTitle != remoteTitle ||
        localArtist.isEmpty ||
        remoteArtist.isEmpty ||
        localArtist != remoteArtist) {
      return false;
    }

    final localDuration = localTrack.duration;
    final remoteDuration = remoteTrack.duration;
    return localDuration == null ||
        remoteDuration == null ||
        (localDuration - remoteDuration).abs() <= const Duration(seconds: 3);
  }

  Future<bool> _isUsableAudioFile(String path) async {
    return _isUsableFile(path);
  }

  Future<bool> _isUsableFile(String path) async {
    try {
      final file = File(path);
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteUnusableStaleFile(LocalTrack? track) async {
    if (track == null || await _isUsableAudioFile(track.filePath)) {
      return;
    }
    try {
      final file = File(track.filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Validation after yt-dlp remains authoritative if a locked stale file
      // cannot be removed before the retry.
    }
  }

  Future<bool> _isExpectedDownloadedFile(
    String path, {
    required String audioDirectory,
    required String identityDigest,
  }) async {
    final file = File(path);
    final expectedDirectory = p.normalize(p.absolute(audioDirectory));
    final actualDirectory = p.normalize(p.absolute(file.parent.path));
    final sameDirectory = AppPlatform.isWindows
        ? expectedDirectory.toLowerCase() == actualDirectory.toLowerCase()
        : expectedDirectory == actualDirectory;
    // yt-dlp may replace the surrounding brackets when restrictFileNames is
    // enabled, but it preserves the hexadecimal digest itself.
    final expectedToken = identityDigest.substring(0, 12);
    final valid =
        sameDirectory &&
        p.basenameWithoutExtension(path).contains(expectedToken) &&
        await _isUsableAudioFile(path);
    if (valid) {
      return true;
    }

    if (sameDirectory &&
        p.basenameWithoutExtension(path).contains(expectedToken)) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // The validation failure is reported below; cleanup is best effort.
      }
    }
    return false;
  }

  Future<T> _serializeDownload<T>(Future<T> Function() operation) async {
    final previous = _downloadTail;
    final gate = Completer<void>();
    _downloadTail = gate.future;
    await previous;
    try {
      return await operation();
    } finally {
      gate.complete();
    }
  }

  String _trackIdentity(TrackInfo track) {
    final source = _canonicalSource(track.url);
    if (source != null) {
      return 'source:$source';
    }
    final extractor = track.extractor?.trim().toLowerCase();
    final id = track.id.trim();
    if (extractor != null && extractor.isNotEmpty && id.isNotEmpty) {
      return 'extractor:$extractor:$id';
    }
    final seconds = track.duration?.inSeconds ?? -1;
    return 'metadata:${_normalizeMatchText(track.artist)}|'
        '${_normalizeMatchText(track.title)}|$seconds';
  }

  String _identityFileName(
    TrackInfo track,
    String identityDigest, {
    int digestLength = 12,
  }) {
    final suffix = ' [${identityDigest.substring(0, digestLength)}]';
    final label = safeFileName('${track.artist} - ${track.title}');
    final maximumLabelLength = 140 - suffix.length;
    final prefix = label.length <= maximumLabelLength
        ? label
        : label.substring(0, maximumLabelLength).trimRight();
    return '$prefix$suffix';
  }

  String? _canonicalSource(String? source) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null) {
      return normalized.toLowerCase();
    }

    final host = uri.host.toLowerCase();
    if (host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return 'youtube:${uri.pathSegments.first}';
    }
    if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
      final videoId = uri.queryParameters['v'];
      if (videoId != null && videoId.isNotEmpty) {
        return 'youtube:$videoId';
      }
      if (uri.pathSegments.length >= 2 &&
          const {
            'shorts',
            'embed',
            'live',
            'v',
          }.contains(uri.pathSegments.first)) {
        return 'youtube:${uri.pathSegments[1]}';
      }
    }

    if (!uri.hasScheme || uri.host.isEmpty) {
      return normalized;
    }

    final normalizedUri = uri.replace(
      scheme: uri.scheme.toLowerCase(),
      host: host,
      fragment: '',
    );
    return normalizedUri.toString();
  }

  String _normalizeMatchText(String value) {
    final folded = value.toLowerCase().split('').map((char) {
      return switch (char) {
        '\u00e1' || '\u00e0' || '\u00e4' || '\u00e2' || '\u00e3' => 'a',
        '\u00e9' || '\u00e8' || '\u00eb' || '\u00ea' => 'e',
        '\u00ed' || '\u00ec' || '\u00ef' || '\u00ee' => 'i',
        '\u00f3' || '\u00f2' || '\u00f6' || '\u00f4' || '\u00f5' => 'o',
        '\u00fa' || '\u00f9' || '\u00fc' || '\u00fb' => 'u',
        '\u00f1' => 'n',
        _ => char,
      };
    }).join();
    return folded
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
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
          // Best effort cleanup for files left by older Android commands.
        }
      }
    }
  }

  Future<_SavedThumbnail?> _saveThumbnail(
    TrackInfo track,
    String directoryPath,
    String identityDigest,
  ) async {
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
        try {
          final saved = await _downloadThumbnail(
            client,
            uri,
            track,
            directory,
            identityDigest,
          );
          if (saved != null) {
            return _SavedThumbnail(
              path: saved.path,
              sourceUrl: uri.toString(),
              createdNewFile: saved.createdNewFile,
            );
          }
        } catch (_) {
          // A timeout or TLS failure for one candidate must not prevent the
          // lower-resolution or catalog artwork fallbacks from being tried.
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<({String path, bool createdNewFile})?> _downloadThumbnail(
    HttpClient client,
    Uri uri,
    TrackInfo track,
    Directory directory,
    String identityDigest,
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
      await response.drain<void>();
      return null;
    }

    final bytes = await collectBoundedByteStream(
      response,
      maximumBytes: _maxThumbnailBytes,
      declaredLength: response.contentLength < 0
          ? null
          : response.contentLength,
      idleTimeout: _thumbnailIdleTimeout,
      totalTimeout: _thumbnailTotalTimeout,
    );
    final extension = _thumbnailExtension(
      uri,
      response.headers.contentType?.mimeType,
      bytes,
    );
    if (bytes.isEmpty || extension == null) {
      return null;
    }

    final baseName = _identityFileName(track, identityDigest, digestLength: 16);
    final file = File(p.join(directory.path, '$baseName$extension'));
    final createdNewFile = !await file.exists();
    final partial = File('${file.path}.part');
    await _deleteFileBestEffort(partial.path);
    try {
      await partial.writeAsBytes(bytes, flush: true);
      try {
        // POSIX replaces the destination atomically. Some Windows filesystems
        // reject replacement, in which case the bounded fallback below keeps
        // the non-atomic window as short as possible.
        final saved = await partial.rename(file.path);
        return (path: saved.path, createdNewFile: createdNewFile);
      } on FileSystemException {
        if (!await file.exists()) {
          rethrow;
        }
        await file.delete();
      }
      final saved = await partial.rename(file.path);
      return (path: saved.path, createdNewFile: createdNewFile);
    } finally {
      await _deleteFileBestEffort(partial.path);
    }
  }

  Future<void> _deleteExistingThumbnailVariants(
    Directory directory,
    String baseName,
    String protectedPath,
  ) async {
    final variants = {
      for (final extension in const ['.jpg', '.jpeg', '.png', '.webp'])
        p.join(directory.path, '$baseName$extension'),
    };
    for (final path in variants) {
      if (p.equals(path, protectedPath)) {
        continue;
      }
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

  Future<void> _commitSavedThumbnail(_SavedThumbnail? thumbnail) async {
    if (thumbnail == null) {
      return;
    }
    try {
      final file = File(thumbnail.path);
      await _deleteExistingThumbnailVariants(
        file.parent,
        p.basenameWithoutExtension(file.path),
        file.path,
      );
    } catch (_) {
      // Old thumbnail variants are harmless; the committed library row and
      // its selected artwork must remain authoritative.
    }
  }

  Future<void> _rollbackSavedThumbnail(_SavedThumbnail? thumbnail) async {
    if (thumbnail == null || !thumbnail.createdNewFile) {
      return;
    }
    await _deleteFileBestEffort(thumbnail.path);
  }

  Future<void> _deleteFileBestEffort(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Cleanup must not replace the persistence or transfer failure.
    }
  }

  Iterable<Uri> _thumbnailCandidates(TrackInfo track) sync* {
    final seen = <String>{};
    final direct = track.thumbnailUrl?.trim();
    final videoArtwork = youtubeThumbnailSourceForVideoId(
      _youtubeVideoId(track),
    );
    final candidates = <String>[
      ...youtubeThumbnailCandidates(videoArtwork),
      ...youtubeThumbnailCandidates(direct),
    ];
    for (final source in candidates) {
      final uri = Uri.tryParse(source);
      if (uri != null && uri.hasScheme && seen.add(uri.toString())) {
        yield uri;
      }
    }

    final catalogSource = track.catalogThumbnailUrl?.trim();
    final catalogUri = catalogSource == null
        ? null
        : Uri.tryParse(catalogSource);
    if (catalogUri != null &&
        catalogUri.hasScheme &&
        seen.add(catalogUri.toString())) {
      yield catalogUri;
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
    if (host != 'youtube.com' && !host.endsWith('.youtube.com')) {
      return null;
    }
    final queryId = uri.queryParameters['v'];
    if (queryId != null && queryId.isNotEmpty) {
      return queryId;
    }
    if (uri.pathSegments.length >= 2 &&
        const {
          'shorts',
          'embed',
          'live',
          'v',
        }.contains(uri.pathSegments.first)) {
      return uri.pathSegments[1];
    }
    return null;
  }

  String? _thumbnailExtension(Uri uri, String? mimeType, List<int> bytes) {
    final pathExtension = p.extension(uri.path).toLowerCase();
    if (const {'.jpg', '.jpeg', '.png', '.webp'}.contains(pathExtension)) {
      return pathExtension == '.jpeg' ? '.jpg' : pathExtension;
    }

    return switch (mimeType?.toLowerCase()) {
      'image/jpeg' => '.jpg',
      'image/png' => '.png',
      'image/webp' => '.webp',
      _ => _extensionFromMagicBytes(bytes),
    };
  }

  String? _extensionFromMagicBytes(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return '.jpg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return '.webp';
    }
    return null;
  }
}

class _SavedThumbnail {
  const _SavedThumbnail({
    required this.path,
    required this.sourceUrl,
    required this.createdNewFile,
  });

  final String path;
  final String sourceUrl;
  final bool createdNewFile;
}
