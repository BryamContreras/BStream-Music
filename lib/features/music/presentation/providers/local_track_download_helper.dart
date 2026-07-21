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
  const LocalTrackDownloadHelper(this._ref);

  final Ref _ref;

  Future<LocalTrackDownloadResult> resolveForLibrary(
    TrackInfo track, {
    bool reuseExisting = false,
    void Function(TrackInfo track)? onResolved,
    void Function()? onDownloadStarted,
  }) async {
    final metadataTrack = await _resolveDownloadTrack(track);
    onResolved?.call(metadataTrack);

    if (reuseExisting) {
      final existing = await findExistingLocalTrack(metadataTrack);
      if (existing != null) {
        return LocalTrackDownloadResult(
          track: existing,
          remoteTrack: metadataTrack,
          reusedExisting: true,
        );
      }
    }

    onDownloadStarted?.call();
    final audioDirectory = await _audioDirectory();
    final thumbnailsDirectory = await _thumbnailsDirectory();
    await _removeMisplacedThumbnailFiles(audioDirectory);
    final options = DownloadOptions(
      outputDirectory: audioDirectory,
      fileName: safeFileName(
        '${metadataTrack.artist} - ${metadataTrack.title}',
      ),
    );

    final result = await _ref
        .read(downloadAudioProvider)
        .call(metadataTrack.url, options);
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

    await _ref.read(libraryRepositoryProvider).saveLocalTrack(localTrack);
    _ref.invalidate(libraryTracksProvider);

    return LocalTrackDownloadResult(
      track: localTrack,
      remoteTrack: metadataTrack,
      reusedExisting: false,
      downloadResult: result,
    );
  }

  Future<LocalTrack?> findExistingLocalTrack(TrackInfo track) async {
    final tracks = await _ref.read(libraryRepositoryProvider).getLocalTracks();
    for (final localTrack in tracks) {
      if (await _matchesExistingTrack(localTrack, track)) {
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
    if (track.thumbnailUrl != null &&
        track.duration != null &&
        track.title.trim().isNotEmpty &&
        track.artist.trim().isNotEmpty) {
      return track;
    }

    return _ref.read(remoteTrackResolverProvider).resolve(track);
  }

  Future<bool> _matchesExistingTrack(
    LocalTrack localTrack,
    TrackInfo remoteTrack,
  ) async {
    if (!await File(localTrack.filePath).exists()) {
      return false;
    }

    final localSource = _canonicalSource(localTrack.sourceUrl);
    final remoteSource = _canonicalSource(remoteTrack.url);
    if (localSource != null &&
        remoteSource != null &&
        localSource == remoteSource) {
      return true;
    }

    final localTitle = _normalizeMatchText(localTrack.title);
    final remoteTitle = _normalizeMatchText(remoteTrack.title);
    if (localTitle.isEmpty || remoteTitle.isEmpty) {
      return false;
    }

    final localArtist = _normalizeMatchText(localTrack.artist);
    final remoteArtist = _normalizeMatchText(remoteTrack.artist);
    if (localTitle == remoteTitle && localArtist == remoteArtist) {
      return true;
    }

    final localLabel = _normalizeMatchText(
      '${localTrack.artist} ${localTrack.title}',
    );
    final remoteLabel = _normalizeMatchText(
      '${remoteTrack.artist} ${remoteTrack.title}',
    );
    return localLabel == remoteLabel;
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
    if (host.contains('youtube.com')) {
      final videoId = uri.queryParameters['v'];
      if (videoId != null && videoId.isNotEmpty) {
        return 'youtube:$videoId';
      }
      if (uri.pathSegments.length >= 2 &&
          const {'shorts', 'embed'}.contains(uri.pathSegments.first)) {
        return 'youtube:${uri.pathSegments[1]}';
      }
    }

    return normalized.toLowerCase();
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
