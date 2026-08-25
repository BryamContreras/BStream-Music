import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../../../core/errors/app_exception.dart';
import '../../../../core/utils/safe_file_name.dart';
import '../../../../features/music/data/models/download_result_model.dart';
import '../../../../features/music/domain/entities/download_options.dart';
import '../../../../features/music/domain/entities/download_result.dart';
import '../../../../features/music/domain/entities/track_info.dart';
import '../../downloader_service.dart';
import 'youtube_audio_stream_selector.dart';
import 'youtube_explode_audio_resolver.dart';
import 'youtube_explode_runtime.dart';

/// A resolved YouTube audio stream ready to be written to disk.
class YoutubeExplodeDownloadStream {
  const YoutubeExplodeDownloadStream({
    required this.bytes,
    required this.extension,
    required this.videoId,
    this.attemptName,
    this.contentLength,
    this.mimeType,
    this.formatId,
  });

  final Stream<List<int>> bytes;
  final String extension;
  final String videoId;
  final String? attemptName;
  final int? contentLength;
  final String? mimeType;
  final String? formatId;
}

/// Injectable boundary around the concrete `youtube_explode_dart` client.
abstract interface class YoutubeExplodeDownloadClient {
  Future<YoutubeExplodeDownloadStream> resolve(String url);

  Future<void> dispose();
}

/// Optional capability for clients that can continue through multiple
/// InnerTube profiles before the service falls back to yt-dlp.
abstract interface class YoutubeExplodeDownloadCandidateClient
    implements YoutubeExplodeDownloadClient {
  Stream<YoutubeExplodeDownloadStream> resolveCandidates(String url);
}

/// Production adapter that downloads through `StreamClient.get(StreamInfo)`.
///
/// Using the managed stream is important: the package handles ranged requests,
/// fragmented streams, retries, and refreshes an expired media URL when needed.
class DefaultYoutubeExplodeDownloadClient
    implements YoutubeExplodeDownloadCandidateClient {
  DefaultYoutubeExplodeDownloadClient({
    YoutubeExplode? client,
    YoutubeExplodeRuntime? runtime,
    YoutubeSelectedAudioValidator? validateDownloadStream,
    Iterable<YoutubeManifestAttempt>? manifestAttempts,
    this.downloadProbeTimeout = const Duration(seconds: 4),
    this.resolveTimeout = const Duration(seconds: 30),
  }) : _injectedClient = client,
       _runtime = runtime,
       _injectedDownloadValidator = validateDownloadStream,
       _manifestAttempts = manifestAttempts == null
           ? null
           : List<YoutubeManifestAttempt>.unmodifiable(manifestAttempts),
       _ownedClient = client == null && runtime == null
           ? YoutubeExplode()
           : null {
    if (client != null && runtime != null) {
      throw ArgumentError('Provide either client or runtime, not both.');
    }
    if (downloadProbeTimeout <= Duration.zero) {
      throw ArgumentError.value(
        downloadProbeTimeout,
        'downloadProbeTimeout',
        'Must be positive.',
      );
    }
    if (resolveTimeout <= Duration.zero) {
      throw ArgumentError.value(
        resolveTimeout,
        'resolveTimeout',
        'Must be positive.',
      );
    }
  }

  final YoutubeExplode? _injectedClient;
  final YoutubeExplodeRuntime? _runtime;
  final YoutubeSelectedAudioValidator? _injectedDownloadValidator;
  final List<YoutubeManifestAttempt>? _manifestAttempts;
  final Duration downloadProbeTimeout;
  final Duration resolveTimeout;
  YoutubeExplode? _ownedClient;
  Future<YoutubeExplode>? _clientFuture;
  YoutubeSelectedAudioValidator? _ownedDownloadValidator;
  bool _disposed = false;

  YoutubeSelectedAudioValidator get _validateDownloadStream {
    final injected = _injectedDownloadValidator;
    if (injected != null) {
      return injected;
    }
    return _ownedDownloadValidator ??= YoutubePlaybackStreamValidator(
      headers: YoutubeHttpClient.defaultHeaders,
      timeout: downloadProbeTimeout,
    ).validate;
  }

  YoutubeExplode get _client {
    final owned = _ownedClient;
    if (owned != null) {
      return owned;
    }
    final injected = _injectedClient;
    if (injected != null) {
      return injected;
    }
    throw StateError('YoutubeExplodeDownloadClient has no client.');
  }

  Future<YoutubeExplode> _ensureFastClient() {
    if (_disposed) {
      throw StateError('YoutubeExplodeDownloadClient was disposed.');
    }
    final runtime = _runtime;
    if (runtime != null) {
      return runtime.fastClient;
    }
    return _clientFuture ??= Future<YoutubeExplode>.value(_client);
  }

  @override
  Future<YoutubeExplodeDownloadStream> resolve(String url) {
    return resolveCandidates(url).first;
  }

  @override
  Stream<YoutubeExplodeDownloadStream> resolveCandidates(String url) async* {
    if (_disposed) {
      throw const DownloaderException(
        'El cliente de youtube_explode_dart ya fue cerrado.',
        code: 'youtube_explode_disposed',
      );
    }

    final client = await _ensureFastClient();
    final runtime = _runtime;
    final videoId = VideoId.fromString(url);
    final attempts = _manifestAttempts ?? defaultYoutubeManifestAttempts;
    var nextAttemptIndex = 0;

    while (nextAttemptIndex < attempts.length) {
      final remainingAttempts = attempts.sublist(nextAttemptIndex);
      var selectedClient = client;
      YoutubeManifestAttempt? selectedAttempt;
      var withinResolutionBudget = true;
      Future<AudioOnlyStreamInfo> resolveManifest() {
        return resolvePreferredYoutubeAudioStream(
          videoId: videoId,
          loadManifest: (videoId, ytClient, requireWatchPage) {
            return client.videos.streams.getManifest(
              videoId,
              ytClients: [ytClient],
              requireWatchPage: requireWatchPage,
            );
          },
          loadManifestForAttempt: runtime == null
              ? null
              : (videoId, attempt) async {
                  selectedClient = await runtime.clientFor(attempt);
                  return selectedClient.videos.streams.getManifest(
                    videoId,
                    ytClients: [attempt.client],
                    requireWatchPage: attempt.requireWatchPage,
                  );
                },
          validateSelectedStream: (candidate) {
            // Fragmented DASH streams are assembled by StreamClient and their
            // base URL is not independently readable. Direct streams prove
            // that the selected URL returns bytes before a large transfer.
            if (candidate.fragments.isNotEmpty) {
              return Future<void>.value();
            }
            return _validateDownloadStream(candidate);
          },
          jsSolverAvailable: runtime?.supportsSolver ?? false,
          attempts: remainingAttempts,
          shouldContinue: () => withinResolutionBudget,
          onAttempt: (attempt, _, error) {
            if (error == null) {
              selectedAttempt = attempt;
            }
          },
        );
      }

      final stream = runtime == null
          ? await resolveManifest().timeout(
              resolveTimeout,
              onTimeout: () {
                withinResolutionBudget = false;
                throw DownloaderException(
                  'youtube_explode_dart no resolvio el audio en '
                  '${resolveTimeout.inSeconds} segundos.',
                  code: 'youtube_explode_resolve_timeout',
                );
              },
            )
          : await runtime.runManifestRequest(
              priority: YoutubeExplodeManifestPriority.download,
              operation: resolveManifest,
              shouldContinue: () => withinResolutionBudget,
              executionTimeout: resolveTimeout,
              executionTimeoutError: (_) => DownloaderException(
                'youtube_explode_dart no resolvio el audio en '
                '${resolveTimeout.inSeconds} segundos.',
                code: 'youtube_explode_resolve_timeout',
              ),
              onExecutionTimeout: () => withinResolutionBudget = false,
            );

      final attempt = selectedAttempt;
      if (attempt == null) {
        throw const YoutubeAudioManifestException([]);
      }
      final selectedIndex = remainingAttempts.indexWhere(
        (candidate) => identical(candidate, attempt),
      );
      if (selectedIndex < 0) {
        throw StateError('The selected YouTube client was not in the plan.');
      }
      nextAttemptIndex += selectedIndex + 1;

      final extension = youtubeAudioContainerExtension(stream.container);
      if (extension == null) {
        continue;
      }
      final totalBytes = stream.size.totalBytes;
      yield YoutubeExplodeDownloadStream(
        bytes: selectedClient.videos.streams.get(stream),
        extension: extension,
        videoId: videoId.value,
        attemptName: attempt.name,
        contentLength: totalBytes > 0 ? totalBytes : null,
        mimeType: youtubeAudioContainerMimeType(stream.container),
        formatId: stream.tag.toString(),
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final owned = _ownedClient;
    _ownedClient = null;
    _clientFuture = null;
    if (owned != null) {
      owned.close();
    }
  }
}

/// Adds a `youtube_explode_dart` audio-download primary in front of yt-dlp.
///
/// Metadata, playback-info fallback, and search stay delegated to [fallback].
/// The decorator does not dispose [fallback], whose owner remains responsible
/// for its lifecycle.
class YoutubeExplodeDownloadService implements DownloaderService {
  YoutubeExplodeDownloadService({
    required this.fallback,
    YoutubeExplodeDownloadClient? client,
    this.resolveTimeout = const Duration(seconds: 30),
    this.downloadIdleTimeout = const Duration(seconds: 30),
    this.downloadTotalTimeout = const Duration(hours: 6),
  }) : _client = client ?? DefaultYoutubeExplodeDownloadClient() {
    if (resolveTimeout <= Duration.zero) {
      throw ArgumentError.value(
        resolveTimeout,
        'resolveTimeout',
        'Must be positive.',
      );
    }
    if (downloadIdleTimeout <= Duration.zero) {
      throw ArgumentError.value(
        downloadIdleTimeout,
        'downloadIdleTimeout',
        'Must be positive.',
      );
    }
    if (downloadTotalTimeout <= Duration.zero) {
      throw ArgumentError.value(
        downloadTotalTimeout,
        'downloadTotalTimeout',
        'Must be positive.',
      );
    }
    _fallbackProgressSubscription = fallback.progressStream.listen(
      _emitProgress,
      onError: _emitProgressError,
    );
  }

  static const _uuid = Uuid();
  static const _progressMinimumInterval = Duration(milliseconds: 200);
  static const _progressMinimumDelta = 0.01;

  final DownloaderService fallback;
  final YoutubeExplodeDownloadClient _client;
  final Duration resolveTimeout;
  final Duration downloadIdleTimeout;
  final Duration downloadTotalTimeout;
  final StreamController<DownloadProgress> _progressController =
      StreamController<DownloadProgress>.broadcast(sync: true);
  late final StreamSubscription<DownloadProgress> _fallbackProgressSubscription;
  Future<void> _fallbackDownloadTail = Future<void>.value();
  bool _disposed = false;

  @override
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  @override
  Future<void> initialize() => fallback.initialize();

  @override
  Future<TrackInfo> getInfo(String url) => fallback.getInfo(url);

  @override
  Future<TrackInfo> getPlaybackInfo(String url) =>
      fallback.getPlaybackInfo(url);

  @override
  Future<List<TrackInfo>> search(String query) => fallback.search(query);

  @override
  Future<DownloadResult> downloadAudio(
    String url,
    DownloadOptions options,
  ) async {
    if (_disposed) {
      throw const DownloaderException(
        'El gestor de descargas ya fue cerrado.',
        code: 'downloader_disposed',
      );
    }

    final requestedTaskId = options.taskId?.trim();
    final taskId = requestedTaskId == null || requestedTaskId.isEmpty
        ? _uuid.v4()
        : requestedTaskId;
    final normalizedOptions = options.copyWith(taskId: taskId);

    _emitProgress(
      DownloadProgress(
        taskId: taskId,
        url: url,
        status: DownloadProgressStatus.queued,
        progress: 0,
        message: 'Preparando descarga con youtube_explode_dart',
      ),
    );

    Object? primaryError;
    StackTrace? primaryStackTrace;
    try {
      return await _downloadWithYoutubeExplode(url, normalizedOptions, taskId);
    } catch (error, stackTrace) {
      if (error is FileSystemException) {
        // A permissions, path, or disk failure is local. Retrying the same
        // write through yt-dlp would be misleading and cannot repair it.
        Error.throwWithStackTrace(error, stackTrace);
      }
      primaryError = error;
      primaryStackTrace = stackTrace;
      if (_disposed) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      _emitProgress(
        DownloadProgress(
          taskId: taskId,
          url: url,
          status: DownloadProgressStatus.failed,
          message:
              'youtube_explode_dart falló: ${_displayError(error)}. '
              'Cambiando a yt-dlp.',
        ),
      );
    }

    try {
      // Keep the task id stable so the fallback's queued/running event replaces
      // the transient primary error in the existing UI task.
      // yt-dlp recovery and output discovery mutate shared platform state, so
      // only this last-resort stage is serialized. youtube_explode candidates
      // continue downloading in parallel.
      return await _serializeFallbackDownload(
        () => fallback.downloadAudio(url, normalizedOptions),
      );
    } catch (fallbackError, fallbackStackTrace) {
      final message =
          'No se pudo descargar el audio. youtube_explode_dart falló: '
          '${_displayError(primaryError)}. yt-dlp también falló: '
          '${_displayError(fallbackError)}.';
      _emitProgress(
        DownloadProgress(
          taskId: taskId,
          url: url,
          status: DownloadProgressStatus.failed,
          message: message,
        ),
      );
      final exception = DownloaderException(
        message,
        code: 'audio_download_all_backends_failed',
        details: <String, Object?>{
          'youtubeExplodeError': primaryError,
          'youtubeExplodeStackTrace': primaryStackTrace,
          'ytDlpError': fallbackError,
        },
      );
      Error.throwWithStackTrace(exception, fallbackStackTrace);
    }
  }

  Future<T> _serializeFallbackDownload<T>(
    Future<T> Function() operation,
  ) async {
    final previous = _fallbackDownloadTail;
    final gate = Completer<void>();
    _fallbackDownloadTail = gate.future;
    await previous;
    try {
      return await operation();
    } finally {
      gate.complete();
    }
  }

  Future<DownloadResult> _downloadWithYoutubeExplode(
    String url,
    DownloadOptions options,
    String taskId,
  ) async {
    _emitProgress(
      DownloadProgress(
        taskId: taskId,
        url: url,
        status: DownloadProgressStatus.running,
        progress: 0,
        message: 'Resolviendo audio con youtube_explode_dart',
      ),
    );

    final candidates = _client is YoutubeExplodeDownloadCandidateClient
        ? (_client as YoutubeExplodeDownloadCandidateClient).resolveCandidates(
            url,
          )
        : Stream<YoutubeExplodeDownloadStream>.fromFuture(_client.resolve(url));
    final iterator = StreamIterator<YoutubeExplodeDownloadStream>(candidates);
    Object? lastTransferError;
    StackTrace? lastTransferStackTrace;

    try {
      while (true) {
        final hasCandidate = await iterator.moveNext().timeout(
          resolveTimeout,
          onTimeout: () => throw DownloaderException(
            'youtube_explode_dart no resolvio el audio en '
            '${resolveTimeout.inSeconds} segundos.',
            code: 'youtube_explode_resolve_timeout',
          ),
        );
        if (!hasCandidate) {
          if (lastTransferError != null) {
            Error.throwWithStackTrace(
              lastTransferError,
              lastTransferStackTrace ?? StackTrace.current,
            );
          }
          throw const DownloaderException(
            'youtube_explode_dart agoto todos los clientes sin encontrar '
            'un audio descargable.',
            code: 'youtube_explode_candidates_exhausted',
          );
        }

        final resolved = iterator.current;
        try {
          return await _downloadResolvedWithYoutubeExplode(
            url,
            options,
            taskId,
            resolved,
          );
        } on FileSystemException {
          rethrow;
        } catch (error, stackTrace) {
          lastTransferError = error;
          lastTransferStackTrace = stackTrace;
          final attempt = resolved.attemptName?.trim();
          _emitProgress(
            DownloadProgress(
              taskId: taskId,
              url: url,
              status: DownloadProgressStatus.running,
              progress: 0,
              message:
                  'El cliente ${attempt == null || attempt.isEmpty ? 'actual' : attempt} '
                  'no pudo completar la transferencia. Probando el siguiente '
                  'cliente de youtube_explode_dart.',
            ),
          );
        }
      }
    } finally {
      try {
        await iterator.cancel();
      } catch (_) {
        // Preserve the completed download or the failure that selected yt-dlp.
      }
    }
  }

  Future<DownloadResult> _downloadResolvedWithYoutubeExplode(
    String url,
    DownloadOptions options,
    String taskId,
    YoutubeExplodeDownloadStream resolved,
  ) async {
    final extension = _normalizeExtension(resolved.extension);
    final outputDirectory = Directory(options.outputDirectory);
    await outputDirectory.create(recursive: true);
    final requestedName = options.fileName?.trim();
    final baseName = safeFileName(
      requestedName == null || requestedName.isEmpty
          ? 'BStream - ${resolved.videoId}'
          : requestedName,
    );
    final completedFile = File(
      p.join(outputDirectory.path, '$baseName.$extension'),
    );
    final partialFile = File('${completedFile.path}.part');
    await _deleteIfExists(partialFile);

    IOSink? output;
    var receivedBytes = 0;
    final expectedBytes =
        resolved.contentLength != null && resolved.contentLength! > 0
        ? resolved.contentLength
        : null;
    final stopwatch = Stopwatch()..start();
    var lastProgress = -1.0;
    var lastProgressAt = Duration.zero;

    _emitProgress(
      DownloadProgress(
        taskId: taskId,
        url: url,
        status: DownloadProgressStatus.running,
        progress: expectedBytes == null ? null : 0,
        message: 'Descargando con youtube_explode_dart',
      ),
    );

    try {
      output = partialFile.openWrite(mode: FileMode.writeOnly);
      await _consumeDownloadStream(resolved.bytes, (chunk) {
        if (chunk.isEmpty) {
          return;
        }
        output!.add(chunk);
        receivedBytes += chunk.length;
        if (expectedBytes != null && receivedBytes > expectedBytes) {
          throw DownloaderException(
            'youtube_explode_dart recibió más bytes de los esperados '
            '($receivedBytes de $expectedBytes).',
            code: 'youtube_explode_size_mismatch',
          );
        }

        final rawProgress = expectedBytes == null
            ? null
            : receivedBytes / expectedBytes;
        final visibleProgress = rawProgress?.clamp(0.0, 0.98).toDouble();
        final elapsedSinceLast = stopwatch.elapsed - lastProgressAt;
        final progressDelta = visibleProgress == null
            ? 0.0
            : visibleProgress - lastProgress;
        if (lastProgress < 0 ||
            elapsedSinceLast >= _progressMinimumInterval ||
            progressDelta >= _progressMinimumDelta) {
          lastProgress = visibleProgress ?? lastProgress;
          lastProgressAt = stopwatch.elapsed;
          _emitProgress(
            DownloadProgress(
              taskId: taskId,
              url: url,
              status: DownloadProgressStatus.running,
              progress: visibleProgress,
              message: visibleProgress == null
                  ? 'Descargando con youtube_explode_dart'
                  : 'Descargando con youtube_explode_dart '
                        '${(visibleProgress * 100).toStringAsFixed(1)}%',
              eta: _estimateEta(
                elapsed: stopwatch.elapsed,
                receivedBytes: receivedBytes,
                expectedBytes: expectedBytes,
              ),
            ),
          );
        }
      });
      await output.flush();
      await output.close();
      output = null;

      if (receivedBytes <= 0) {
        throw const DownloaderException(
          'youtube_explode_dart devolvió un stream vacío.',
          code: 'youtube_explode_empty_download',
        );
      }
      if (expectedBytes != null && receivedBytes != expectedBytes) {
        throw DownloaderException(
          'La descarga de youtube_explode_dart quedó incompleta '
          '($receivedBytes de $expectedBytes bytes).',
          code: 'youtube_explode_size_mismatch',
        );
      }
      final diskBytes = await partialFile.length();
      if (diskBytes != receivedBytes) {
        throw DownloaderException(
          'No se pudieron confirmar todos los bytes descargados '
          '($diskBytes de $receivedBytes).',
          code: 'youtube_explode_file_size_mismatch',
        );
      }

      if (await completedFile.exists()) {
        await completedFile.delete();
      }
      final savedFile = await partialFile.rename(completedFile.path);
      _emitProgress(
        DownloadProgress(
          taskId: taskId,
          url: url,
          status: DownloadProgressStatus.completed,
          progress: 1,
          message: 'Descarga completada con youtube_explode_dart',
        ),
      );
      return DownloadResultModel.completed(
        sourceUrl: url,
        filePath: savedFile.path,
        mediaType: DownloadMediaType.audio,
      );
    } catch (_) {
      if (output != null) {
        try {
          await output.close();
        } catch (_) {
          // Preserve the original download failure.
        }
      }
      await _deleteIfExists(partialFile);
      rethrow;
    } finally {
      stopwatch.stop();
    }
  }

  Future<void> _consumeDownloadStream(
    Stream<List<int>> stream,
    void Function(List<int> chunk) onChunk,
  ) async {
    final stopwatch = Stopwatch()..start();
    final iterator = StreamIterator<List<int>>(stream);
    try {
      while (true) {
        final remaining = downloadTotalTimeout - stopwatch.elapsed;
        if (remaining <= Duration.zero) {
          throw DownloaderException(
            'La descarga de youtube_explode_dart excedió el límite total de '
            '${downloadTotalTimeout.inMinutes} minutos.',
            code: 'youtube_explode_download_total_timeout',
          );
        }
        final waitingForTotal = remaining <= downloadIdleTimeout;
        final nextTimeout = waitingForTotal ? remaining : downloadIdleTimeout;
        final hasNext = await iterator.moveNext().timeout(
          nextTimeout,
          onTimeout: () => throw DownloaderException(
            waitingForTotal
                ? 'La descarga de youtube_explode_dart excedió el límite '
                      'total de ${downloadTotalTimeout.inMinutes} minutos.'
                : 'La descarga de youtube_explode_dart dejó de recibir datos '
                      'durante ${downloadIdleTimeout.inSeconds} segundos.',
            code: waitingForTotal
                ? 'youtube_explode_download_total_timeout'
                : 'youtube_explode_download_idle_timeout',
          ),
        );
        if (!hasNext) {
          return;
        }
        onChunk(iterator.current);
      }
    } finally {
      stopwatch.stop();
      try {
        await iterator.cancel();
      } catch (_) {
        // Preserve the transfer result or timeout that initiated cancellation.
      }
    }
  }

  String _normalizeExtension(String extension) {
    final normalized = extension.trim().toLowerCase().replaceFirst(
      RegExp(r'^\.'),
      '',
    );
    if (!RegExp(r'^[a-z0-9]{1,10}$').hasMatch(normalized)) {
      throw DownloaderException(
        'youtube_explode_dart devolvió una extensión no válida: $extension',
        code: 'youtube_explode_invalid_extension',
      );
    }
    return normalized;
  }

  Duration? _estimateEta({
    required Duration elapsed,
    required int receivedBytes,
    required int? expectedBytes,
  }) {
    if (expectedBytes == null ||
        receivedBytes <= 0 ||
        receivedBytes >= expectedBytes ||
        elapsed.inMilliseconds < 250) {
      return null;
    }
    final bytesPerMillisecond = receivedBytes / elapsed.inMilliseconds;
    if (!bytesPerMillisecond.isFinite || bytesPerMillisecond <= 0) {
      return null;
    }
    return Duration(
      milliseconds: ((expectedBytes - receivedBytes) / bytesPerMillisecond)
          .round(),
    );
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Cleanup is best effort. A following open/rename reports the real error.
    }
  }

  String _displayError(Object error) {
    final raw = error is AppException ? error.message : error.toString();
    final singleLine = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.isEmpty) {
      return error.runtimeType.toString();
    }
    return singleLine.length <= 320
        ? singleLine
        : '${singleLine.substring(0, 317)}...';
  }

  void _emitProgress(DownloadProgress progress) {
    if (!_progressController.isClosed) {
      _progressController.add(progress);
    }
  }

  void _emitProgressError(Object error, StackTrace stackTrace) {
    if (!_progressController.isClosed) {
      _progressController.addError(error, stackTrace);
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _fallbackProgressSubscription.cancel();
    await _client.dispose();
    await _progressController.close();
  }
}
