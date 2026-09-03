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
import '../youtube_music/innertube_search_service.dart';
import '../youtube_music/playback/innertube_playback_service.dart';
import '../youtube_music/playback/innertube_video_id.dart';
import 'downloader_service.dart';
import 'http_audio_transfer.dart';

/// Downloader and metadata adapter backed only by InnerTube and `dart:io`.
final class InnerTubeDownloadService implements DownloaderService {
  InnerTubeDownloadService({
    required this.playback,
    required this.catalog,
    HttpAudioTransfer? transfer,
    this.maxStreamRefreshes = 2,
    this.disposePlaybackService = false,
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

  final InnerTubePlaybackService playback;
  final YouTubeMusicSearch catalog;
  final HttpAudioTransfer _transfer;
  final int maxStreamRefreshes;
  final bool disposePlaybackService;
  final StreamController<DownloadProgress> _progress =
      StreamController<DownloadProgress>.broadcast(sync: true);
  bool _disposed = false;

  @override
  Stream<DownloadProgress> get progressStream => _progress.stream;

  @override
  Future<void> initialize() async {
    _ensureActive();
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
    _emit(
      DownloadProgress(
        taskId: taskId,
        url: url,
        status: DownloadProgressStatus.queued,
        progress: 0,
        message: 'Preparando descarga con InnerTube',
      ),
    );

    try {
      final metadata = await getInfo(url);
      final excludedProfileKeys = <String>{};
      var resolved = await _resolveDownloadStream(
        url,
        excludedProfileKeys: excludedProfileKeys,
      );
      final outputDirectory = Directory(options.outputDirectory);
      await outputDirectory.create(recursive: true);
      final requestedName = options.fileName?.trim();
      final baseName = safeFileName(
        requestedName == null || requestedName.isEmpty
            ? _defaultFileName(metadata)
            : requestedName,
      );
      var destination = await _availableDestination(
        outputDirectory,
        baseName,
        resolved.extension,
      );
      final stopwatch = Stopwatch()..start();

      for (var refresh = 0; ; refresh += 1) {
        _ensureActive();
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
            isCancelled: () => _disposed,
            onProgress: (value) {
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
            final partial = HttpAudioTransfer.partialFileFor(destination);
            if (await partial.exists()) await partial.delete();
            if (resolved.extension != previousExtension) {
              destination = await _availableDestination(
                outputDirectory,
                baseName,
                resolved.extension,
              );
            }
          }
        }
      }
    } on FileSystemException {
      rethrow;
    } catch (error, stackTrace) {
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
    if (disposePlaybackService) await playback.dispose();
    await _progress.close();
  }
}
