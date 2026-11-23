import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/errors/app_exception.dart';
import '../../core/utils/image_source.dart';
import '../../core/utils/safe_file_name.dart';
import '../../features/music/data/models/download_result_model.dart';
import '../../features/music/domain/entities/download_options.dart';
import '../../features/music/domain/entities/download_result.dart';
import '../../features/music/domain/entities/track_info.dart';
import '../audio_sources/audio_format_details.dart';
import '../youtube_music/innertube_search_service.dart';
import '../youtube_music/playback/innertube_playback_service.dart';
import '../youtube_music/playback/innertube_video_id.dart';
import 'downloader_service.dart';
import 'audio_stream_resolver.dart';
import 'http_audio_transfer.dart';

typedef DownloadAudioUpgrade =
    Future<AudioStreamResolution?> Function(
      String url,
      TrackInfo? metadata,
      AudioStreamResolution baseline,
      bool Function() shouldContinue,
    );

/// Downloader and metadata adapter backed only by InnerTube and `dart:io`.
final class InnerTubeDownloadService
    implements DownloaderService, CancellableDownloaderService {
  InnerTubeDownloadService({
    required this.playback,
    required this.catalog,
    HttpAudioTransfer? transfer,
    this.maxStreamRefreshes = 2,
    this.disposePlaybackService = false,
    this.audioUpgrade,
  }) : _transfer = transfer ?? HttpAudioTransfer() {
    if (maxStreamRefreshes < 0) {
      throw ArgumentError.value(
        maxStreamRefreshes,
        'maxStreamRefreshes',
        'Must not be negative.',
      );
    }
  }

  static const Uuid _uuid = Uuid();
  static const int _maximumCdnChunkBytes = 8 * 1024 * 1024;
  static const Duration _cancelledTaskRetention = Duration(minutes: 5);

  final InnerTubePlaybackService playback;
  final YouTubeMusicSearch catalog;
  final HttpAudioTransfer _transfer;
  final int maxStreamRefreshes;
  final bool disposePlaybackService;
  final DownloadAudioUpgrade? audioUpgrade;
  final StreamController<DownloadProgress> _progress =
      StreamController<DownloadProgress>.broadcast(sync: true);
  final Set<String> _cancelledTaskIds = <String>{};
  final Map<String, Timer> _cancelledTaskTimers = <String, Timer>{};
  final _cancellationEvents = StreamController<String?>.broadcast(sync: true);
  bool _disposed = false;

  @override
  Stream<DownloadProgress> get progressStream => _progress.stream;

  @override
  Future<void> initialize() async {
    _ensureActive();
  }

  @override
  Future<void> cancelDownload(String taskId) async {
    final normalizedTaskId = taskId.trim();
    if (normalizedTaskId.isEmpty || _disposed) return;
    _cancelledTaskIds.add(normalizedTaskId);
    _cancelledTaskTimers.remove(normalizedTaskId)?.cancel();
    _cancelledTaskTimers[normalizedTaskId] = Timer(_cancelledTaskRetention, () {
      _cancelledTaskIds.remove(normalizedTaskId);
      _cancelledTaskTimers.remove(normalizedTaskId);
    });
    _cancellationEvents.add(normalizedTaskId);
  }

  @override
  Future<TrackInfo> getInfo(String url) async {
    _ensureActive();
    final videoId = InnerTubeVideoId.extract(url);
    if (videoId == null) {
      throw const DownloaderException(
        'La referencia no contiene un video de YouTube válido.',
        code: 'innertube_invalid_video',
      );
    }
    final lookup = catalog;
    if (lookup is YouTubeMusicTrackLookup) {
      final song = await (lookup as YouTubeMusicTrackLookup).getSong(
        videoId.value,
      );
      if (song != null) return _trackFromSong(song);
    }
    return TrackInfo(
      id: videoId.value,
      title: 'YouTube ${videoId.value}',
      artist: 'Desconocido',
      url: Uri.https('www.youtube.com', '/watch', <String, String>{
        'v': videoId.value,
      }).toString(),
      thumbnailUrl: youtubeThumbnailSourceForVideoId(videoId.value),
      metadataSource: TrackMetadataSource.youtube,
    );
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) async {
    final metadata = await getInfo(url);
    final resolved = await playback.resolve(url);
    return metadata.copyWith(
      streamUrl: resolved.uri.toString(),
      streamExtension: resolved.extension,
      streamMimeType: resolved.format.mimeType,
      streamSource: 'innerTube',
      streamFormatId: resolved.format.itag.toString(),
      streamCodec: resolved.codec,
      streamBitrate:
          resolved.format.isAudioOnly && resolved.format.effectiveBitrate > 0
          ? resolved.format.effectiveBitrate
          : null,
      streamSampleRate: resolved.format.audioSampleRate,
      streamChannels: resolved.format.audioChannels,
      streamClientProfileKey: resolved.profile.key,
      httpHeaders: resolved.headers,
    );
  }

  @override
  Future<List<TrackInfo>> search(String query) async {
    _ensureActive();
    final direct = _directVideoReference(query);
    if (direct != null) return <TrackInfo>[await getInfo(direct.value)];
    final normalized = query.trim();
    if (normalized.isEmpty) return const <TrackInfo>[];
    final songs = await catalog.searchSongs(normalized);
    return List<TrackInfo>.unmodifiable(songs.map(_trackFromSong));
  }

  InnerTubeVideoId? _directVideoReference(String query) {
    final normalized = query.trim();
    // Plain eleven-letter search terms (for example, "traicionera") are not
    // necessarily video IDs. Digits and ID separators keep pasted bare IDs
    // fast while regular words continue through the music catalogue.
    final bareId = InnerTubeVideoId.tryParse(normalized);
    if (bareId != null && RegExp(r'[0-9_-]').hasMatch(normalized)) {
      return bareId;
    }
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme) return null;
    return InnerTubeVideoId.extract(normalized);
  }

  @override
  Future<DownloadResult> downloadAudio(
    String url,
    DownloadOptions options,
  ) async {
    _ensureActive();
    final requestedId = options.taskId?.trim();
    final taskId = requestedId == null || requestedId.isEmpty
        ? _uuid.v4()
        : requestedId;
    final destinationPaths = <String>{};

    try {
      _ensureTaskActive(taskId);
      _emit(
        DownloadProgress(
          taskId: taskId,
          url: url,
          status: DownloadProgressStatus.queued,
          progress: 0,
          message: 'Preparando descarga con InnerTube',
        ),
      );
      final requestedName = options.fileName?.trim();
      final metadata = requestedName == null || requestedName.isEmpty
          ? await getInfo(url)
          : null;
      _ensureTaskActive(taskId);
      final excludedProfileKeys = <String>{};
      var resolved = await _resolveDownloadStream(
        url,
        excludedProfileKeys: excludedProfileKeys,
      );
      _ensureTaskActive(taskId);
      AudioStreamResolution? upgrade;
      try {
        upgrade = await audioUpgrade?.call(
          url,
          options.track ?? metadata,
          AudioStreamResolution(
            source: AudioStreamSource.innerTube,
            streamUrl: resolved.uri.toString(),
            streamExtension: resolved.extension,
            streamMimeType: resolved.format.mimeType,
            codec: resolved.codec,
            bitrate: resolved.format.isAudioOnly
                ? resolved.format.effectiveBitrate
                : null,
            httpHeaders: resolved.headers,
          ),
          () => !_disposed && !_isTaskCancelled(taskId),
        );
      } on Object {
        _ensureTaskActive(taskId);
      }
      _ensureTaskActive(taskId);
      if (upgrade != null &&
          upgrade.isUsable &&
          const {
            'http',
            'https',
          }.contains(Uri.parse(upgrade.streamUrl).scheme) &&
          Uri.parse(upgrade.streamUrl).host.isNotEmpty &&
          upgrade.improvesOn(
            resolved.format.isAudioOnly
                ? resolved.format.effectiveBitrate
                : null,
          )) {
        try {
          return await _downloadUpgradedAudio(
            url,
            options,
            taskId,
            upgrade,
            metadata: options.track ?? metadata,
            destinationPaths: destinationPaths,
          );
        } on HttpAudioTransferException {
          _ensureTaskActive(taskId);
          // A failed optional CDN must not prevent the verified YouTube
          // download. Keep its untouched source ready as the fallback.
          await _deleteTransferArtifacts(destinationPaths);
          destinationPaths.clear();
        }
      }
      final outputDirectory = Directory(options.outputDirectory);
      await outputDirectory.create(recursive: true);
      final baseName = safeFileName(
        requestedName == null || requestedName.isEmpty
            ? _defaultFileName(metadata!)
            : requestedName,
      );
      var destination = await _availableDestination(
        outputDirectory,
        baseName,
        resolved.extension,
      );
      destinationPaths.add(destination.path);
      final stopwatch = Stopwatch()..start();

      for (var refresh = 0; ; refresh += 1) {
        _ensureTaskActive(taskId);
        _emit(
          DownloadProgress(
            taskId: taskId,
            url: url,
            status: DownloadProgressStatus.running,
            progress: null,
            message: refresh == 0
                ? 'Descargando con InnerTube (${resolved.profile.key})'
                : 'Continuando con ${resolved.profile.key}',
          ),
        );
        try {
          final result = await _transfer.download(
            uri: resolved.uri,
            destination: destination,
            headers: resolved.headers,
            rangePlan: _googleVideoRangePlan(resolved),
            isCancelled: () => _disposed || _isTaskCancelled(taskId),
            cancellationEvents: _cancellationFor(taskId),
            onProgress: (value) {
              if (_isTaskCancelled(taskId)) return;
              final fraction = value.fraction;
              _emit(
                DownloadProgress(
                  taskId: taskId,
                  url: url,
                  status: DownloadProgressStatus.running,
                  progress: fraction,
                  message: fraction == null
                      ? 'Descargando con ${resolved.profile.key}'
                      : 'Descargando con ${resolved.profile.key} '
                            '${(fraction * 100).toStringAsFixed(1)}%',
                  eta: _estimateEta(
                    stopwatch.elapsed,
                    value.transferredBytes,
                    value.totalBytes,
                  ),
                ),
              );
            },
          );
          _ensureTaskActive(taskId);
          stopwatch.stop();
          _emit(
            DownloadProgress(
              taskId: taskId,
              url: url,
              status: DownloadProgressStatus.completed,
              progress: 1,
              message: 'Descarga completada con InnerTube',
            ),
          );
          return DownloadResultModel.completed(
            sourceUrl: url,
            filePath: result.file.path,
            mediaType: DownloadMediaType.audio,
            audioFormat: AudioFormatDetails(
              codec: resolved.codec,
              mimeType: resolved.format.mimeType,
              bitrate: resolved.format.isAudioOnly
                  ? resolved.format.effectiveBitrate
                  : null,
              sampleRate: resolved.format.audioSampleRate,
              channels: resolved.format.audioChannels,
            ),
          );
        } on HttpAudioTransferException catch (error) {
          if (!error.shouldRefreshUrl || refresh >= maxStreamRefreshes) {
            rethrow;
          }
          // A CDN URL can expire or its PO token can rotate while the client
          // profile itself remains healthy. Refresh that same profile once;
          // only exclude it after the refreshed URL is rejected as well.
          if (refresh > 0) {
            excludedProfileKeys.add(resolved.profile.key);
          }
          final previousFormat = resolved.format;
          final previousExtension = resolved.extension;
          resolved = await _resolveDownloadStream(
            url,
            excludedProfileKeys: excludedProfileKeys,
          );
          if (resolved.format.itag != previousFormat.itag ||
              resolved.extension != previousExtension) {
            await _deletePartialTransferArtifacts(destination.path);
            if (resolved.extension != previousExtension) {
              destination = await _availableDestination(
                outputDirectory,
                baseName,
                resolved.extension,
              );
              destinationPaths.add(destination.path);
            }
          }
        }
      }
    } catch (error, stackTrace) {
      if (_isExplicitTaskCancellation(taskId, error)) {
        await _deleteTransferArtifacts(destinationPaths);
        Error.throwWithStackTrace(
          const DownloaderException(
            'Descarga cancelada.',
            code: 'download_cancelled',
          ),
          stackTrace,
        );
      }
      if (error is FileSystemException) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      _emit(
        DownloadProgress(
          taskId: taskId,
          url: url,
          status: DownloadProgressStatus.failed,
          message: 'No se pudo descargar: ${_displayError(error)}',
        ),
      );
      final wrapped = error is DownloaderException
          ? error
          : DownloaderException(
              'No se pudo descargar el audio con InnerTube.',
              code: 'innertube_download_failed',
              details: error,
            );
      Error.throwWithStackTrace(wrapped, stackTrace);
    } finally {
      _forgetTaskCancellation(taskId);
    }
  }

  bool _isTaskCancelled(String taskId) => _cancelledTaskIds.contains(taskId);

  Stream<void> _cancellationFor(String taskId) => _cancellationEvents.stream
      .where((cancelledId) => cancelledId == null || cancelledId == taskId)
      .map<void>((_) {});

  Future<DownloadResult> _downloadUpgradedAudio(
    String url,
    DownloadOptions options,
    String taskId,
    AudioStreamResolution source, {
    required TrackInfo? metadata,
    required Set<String> destinationPaths,
  }) async {
    final directory = Directory(options.outputDirectory);
    await directory.create(recursive: true);
    final requested = options.fileName?.trim();
    final name = safeFileName(
      requested == null || requested.isEmpty
          ? _defaultFileName(metadata!)
          : requested,
    );
    // Partial transfers from different providers must never share a file.
    final extension = source.source == AudioStreamSource.audioExtension;
    final extensionId = extension
        ? RegExp(r'^[a-f0-9]{12}').stringMatch(source.formatId ?? '')
        : null;
    final variant = extension
        ? (extensionId == null ? 'cd' : 'cd-$extensionId')
        : 'jiosaavn-${(source.bitrate! / 1000).round()}';
    final providerName = extension ? 'FLAC' : 'JioSaavn';
    final destination = await _availableDestination(
      directory,
      '$name-$variant',
      source.streamExtension ?? 'm4a',
    );
    destinationPaths.add(destination.path);
    final result = await _transfer.download(
      uri: Uri.parse(source.streamUrl),
      destination: destination,
      headers: source.httpHeaders ?? const {},
      isCancelled: () => _disposed || _isTaskCancelled(taskId),
      cancellationEvents: _cancellationFor(taskId),
      onProgress: (progress) {
        if (_disposed || _isTaskCancelled(taskId)) return;
        _emit(
          DownloadProgress(
            taskId: taskId,
            url: url,
            status: DownloadProgressStatus.running,
            progress: progress.fraction,
            message: providerName,
          ),
        );
      },
    );
    _ensureTaskActive(taskId);
    _emit(
      DownloadProgress(
        taskId: taskId,
        url: url,
        status: DownloadProgressStatus.completed,
        progress: 1,
        message: providerName,
      ),
    );
    return DownloadResultModel.completed(
      sourceUrl: url,
      filePath: result.file.path,
      mediaType: DownloadMediaType.audio,
      audioFormat: AudioFormatDetails(
        codec: source.codec,
        mimeType: source.streamMimeType,
        bitrate: source.bitrate,
        sampleRate: source.sampleRate,
        channels: source.channels,
        bitDepth: source.bitDepth,
      ),
    );
  }

  bool _isExplicitTaskCancellation(String taskId, Object error) {
    if (_isTaskCancelled(taskId)) return true;
    return error is DownloaderException && error.code == 'download_cancelled';
  }

  void _ensureTaskActive(String taskId) {
    _ensureActive();
    if (_isTaskCancelled(taskId)) {
      throw const DownloaderException(
        'Descarga cancelada.',
        code: 'download_cancelled',
      );
    }
  }

  void _forgetTaskCancellation(String taskId) {
    _cancelledTaskIds.remove(taskId);
    _cancelledTaskTimers.remove(taskId)?.cancel();
  }

  Future<void> _deletePartialTransferArtifacts(String destinationPath) async {
    await _deleteFileBestEffort('$destinationPath.part');
    await _deleteFileBestEffort('$destinationPath.part.if-range');
  }

  Future<void> _deleteTransferArtifacts(Iterable<String> paths) async {
    for (final path in paths) {
      await _deleteFileBestEffort(path);
      await _deletePartialTransferArtifacts(path);
    }
  }

  Future<void> _deleteFileBestEffort(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cancellation cleanup is best effort and must retain the original
      // cancellation result if another process briefly holds an artifact.
    }
  }

  Future<InnerTubeResolvedAudio> _resolveDownloadStream(
    String url, {
    required Set<String> excludedProfileKeys,
  }) async {
    try {
      return await playback.resolve(
        url,
        requireAudioOnly: true,
        excludedProfileKeys: excludedProfileKeys,
      );
    } on InnerTubePlaybackException catch (error) {
      // Prefer a compact audio-only representation. Some SDK-less clients
      // expose only a direct muxed MP4 (for example itag 18) under current GVS
      // enforcement; use it only after a playable response proves that this
      // is specifically an audio-only availability issue.
      if (!error.canRetryWithMuxed) rethrow;
      return playback.resolve(
        url,
        requireAudioOnly: false,
        excludedProfileKeys: excludedProfileKeys,
      );
    }
  }

  HttpAudioRangePlan? _googleVideoRangePlan(InnerTubeResolvedAudio resolved) {
    final host = resolved.uri.host.trim().toLowerCase();
    if (host != 'googlevideo.com' && !host.endsWith('.googlevideo.com')) {
      return null;
    }
    final totalBytes =
        resolved.probe.contentLength ??
        resolved.format.contentLength ??
        int.tryParse(resolved.uri.queryParameters['clen'] ?? '');
    if (totalBytes == null || totalBytes <= 0) {
      return null;
    }
    final mediaClient =
        resolved.uri.queryParameters['c'] ?? resolved.profile.clientName;
    final usesHeaderRange = mediaClient.trim().toUpperCase().startsWith(
      'ANDROID',
    );
    return HttpAudioRangePlan(
      totalBytes: totalBytes,
      maximumChunkBytes: _maximumCdnChunkBytes,
      transport: usesHeaderRange
          ? HttpAudioRangeTransport.header
          : HttpAudioRangeTransport.queryParameter,
    );
  }

  TrackInfo _trackFromSong(InnerTubeSong song) => TrackInfo(
    id: song.videoId,
    title: song.title,
    artist: song.artist.isEmpty ? 'Desconocido' : song.artist,
    artists: song.artists,
    artistBrowseIds: song.artistBrowseIds,
    album: song.album,
    albumBrowseId: song.albumBrowseId,
    duration: song.duration,
    thumbnailUrl:
        youtubeThumbnailSourceForVideoId(song.videoId) ?? song.thumbnailUrl,
    catalogThumbnailUrl: song.thumbnailUrl,
    url: song.watchUri.toString(),
    metadataSource: TrackMetadataSource.youtubeMusic,
  );

  String _defaultFileName(TrackInfo track) {
    final artist = track.artist.trim();
    final title = track.title.trim();
    if (artist.isNotEmpty && artist != 'Desconocido' && title.isNotEmpty) {
      return '$artist - $title';
    }
    return title.isNotEmpty ? title : 'BStream - ${track.id}';
  }

  Future<File> _availableDestination(
    Directory directory,
    String baseName,
    String extension,
  ) async {
    for (var suffix = 0; suffix < 10000; suffix += 1) {
      final name = suffix == 0 ? baseName : '$baseName ($suffix)';
      final candidate = File(p.join(directory.path, '$name.$extension'));
      if (!await candidate.exists()) return candidate;
    }
    throw const FileSystemException(
      'No se encontró un nombre de archivo libre.',
    );
  }

  Duration? _estimateEta(Duration elapsed, int received, int? total) {
    if (total == null || received <= 0 || received >= total) return null;
    if (elapsed.inMilliseconds < 250) return null;
    final bytesPerMillisecond = received / elapsed.inMilliseconds;
    if (!bytesPerMillisecond.isFinite || bytesPerMillisecond <= 0) return null;
    return Duration(
      milliseconds: ((total - received) / bytesPerMillisecond).round(),
    );
  }

  String _displayError(Object error) {
    final raw = error is AppException ? error.message : error.toString();
    final oneLine = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= 280) return oneLine;
    return '${oneLine.substring(0, 277)}...';
  }

  void _emit(DownloadProgress value) {
    if (!_progress.isClosed) _progress.add(value);
  }

  void _ensureActive() {
    if (_disposed) {
      throw const DownloaderException(
        'El gestor de descargas ya fue cerrado.',
        code: 'downloader_disposed',
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancellationEvents.add(null);
    for (final timer in _cancelledTaskTimers.values) {
      timer.cancel();
    }
    _cancelledTaskTimers.clear();
    _cancelledTaskIds.clear();
    await _cancellationEvents.close();
    if (disposePlaybackService) await playback.dispose();
    await _progress.close();
  }
}
