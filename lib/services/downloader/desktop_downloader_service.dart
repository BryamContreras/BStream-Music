import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../core/utils/safe_file_name.dart';
import '../../features/music/data/models/download_result_model.dart';
import '../../features/music/data/models/track_info_model.dart';
import '../../features/music/domain/entities/download_options.dart';
import '../../features/music/domain/entities/download_result.dart';
import '../../features/music/domain/entities/track_info.dart';
import 'downloader_service.dart';

typedef DesktopProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);
typedef DesktopProcessTerminator = void Function(Process process);

class DesktopDownloaderService
    implements DownloaderService, ManagedPlaybackDownloader {
  DesktopDownloaderService({
    SharedPreferences? initialPreferences,
    List<Directory>? toolDirectories,
    Future<Directory> Function()? managedPlaybackDirectory,
    int managedPlaybackMaximumFiles = 12,
    int managedPlaybackMaximumBytes = 256 * 1024 * 1024,
    int managedPlaybackMaximumEntryBytes = 128 * 1024 * 1024,
    DesktopProcessStarter? processStarter,
    DesktopProcessTerminator? processTerminator,
    Duration processResolutionTimeout = const Duration(minutes: 2),
    Duration processIdleTimeout = const Duration(seconds: 45),
    Duration processDownloadTotalTimeout = const Duration(hours: 6),
  }) : _preferences = initialPreferences,
       _toolDirectoryOverrides = toolDirectories,
       _managedPlaybackDirectoryOverride = managedPlaybackDirectory,
       _managedPlaybackMaximumFiles = managedPlaybackMaximumFiles,
       _managedPlaybackMaximumBytes = managedPlaybackMaximumBytes,
       _managedPlaybackMaximumEntryBytes = managedPlaybackMaximumEntryBytes,
       _processStarterOverride = processStarter,
       _processTerminatorOverride = processTerminator,
       _processResolutionTimeout = processResolutionTimeout,
       _processIdleTimeout = processIdleTimeout,
       _processDownloadTotalTimeout = processDownloadTotalTimeout,
       assert(managedPlaybackMaximumFiles > 0),
       assert(managedPlaybackMaximumBytes > 0),
       assert(managedPlaybackMaximumEntryBytes > 0),
       assert(managedPlaybackMaximumEntryBytes <= managedPlaybackMaximumBytes),
       assert(processResolutionTimeout > Duration.zero),
       assert(processIdleTimeout > Duration.zero),
       assert(processDownloadTotalTimeout > Duration.zero);

  static const _ytDlpPathKey = 'desktop.ytDlpPath';
  static const _progressTemplate =
      'download:BSTREAM_PROGRESS|%(progress._percent_str)s|%(progress.eta)s';
  static const _audioFileExtensions = {
    '.3gp',
    '.3gpp',
    '.aac',
    '.aiff',
    '.alac',
    '.flac',
    '.m4a',
    '.m4b',
    '.mka',
    '.mp3',
    '.mp4',
    '.oga',
    '.ogg',
    '.opus',
    '.vorbis',
    '.wav',
    '.weba',
    '.webm',
    '.wma',
  };

  final SharedPreferences? _preferences;
  final List<Directory>? _toolDirectoryOverrides;
  final Future<Directory> Function()? _managedPlaybackDirectoryOverride;
  final int _managedPlaybackMaximumFiles;
  final int _managedPlaybackMaximumBytes;
  final int _managedPlaybackMaximumEntryBytes;
  final DesktopProcessStarter? _processStarterOverride;
  final DesktopProcessTerminator? _processTerminatorOverride;
  final Duration _processResolutionTimeout;
  final Duration _processIdleTimeout;
  final Duration _processDownloadTotalTimeout;
  final _uuid = const Uuid();
  final _progressController = StreamController<DownloadProgress>.broadcast();
  final _activeProcesses = <int, Process>{};

  SharedPreferences? _resolvedPreferences;
  Future<void> _managedPlaybackTail = Future<void>.value();
  int _managedPlaybackGeneration = 0;
  Process? _activeManagedPlaybackProcess;
  // The downloader cannot know the exact instant at which the player has
  // switched from the previously returned file to the newest one. Keep a
  // bounded hand-off window so post-download pruning cannot unlink the source
  // that is still playing while its replacement is being opened.
  List<String> _protectedManagedPlaybackPaths = const [];
  bool _disposed = false;

  @override
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  Future<SharedPreferences> get _prefs async {
    _resolvedPreferences ??=
        _preferences ?? await SharedPreferences.getInstance();
    return _resolvedPreferences!;
  }

  @override
  Future<void> initialize() async {
    await _prefs;
  }

  Future<void> setYtDlpPath(String? path) async {
    final prefs = await _prefs;
    if (path == null || path.trim().isEmpty) {
      await prefs.remove(_ytDlpPathKey);
      return;
    }
    await prefs.setString(_ytDlpPathKey, path.trim());
  }

  Future<String> getYtDlpPath() async {
    final configured = _configuredExecutable(
      (await _prefs).getString(_ytDlpPathKey),
      ['yt-dlp.exe', 'yt-dlp'],
    );
    final bundled = _findBundledTool(['yt-dlp.exe', 'yt-dlp']);

    // Older builds could persist the bare command `yt-dlp` after checking the
    // desktop tools. That works from an interactive shell but fails when
    // macOS launches the app from Finder, Dock, or Launchpad because those
    // processes do not inherit the shell PATH. Prefer an explicit user path,
    // then the bundled executable, and use a bare command only as a fallback.
    if (configured != null && File(configured).isAbsolute) {
      return configured;
    }
    return bundled ?? configured ?? 'yt-dlp';
  }

  Future<bool> hasYtDlp() async {
    return _checkExecutable(await getYtDlpPath(), const ['--version']);
  }

  @override
  Future<TrackInfo> getInfo(String url) async {
    final output = await _runYtDlp([
      '--dump-single-json',
      '--no-playlist',
      '--no-warnings',
      '-f',
      AppConstants.preferredNativeAudioFormat,
      url,
    ]);

    return TrackInfoModel.fromJson(jsonDecode(output) as Map<String, dynamic>);
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) {
    return getInfo(url);
  }

  @override
  Future<ManagedPlaybackResource> prepareManagedPlayback(String url) {
    final generation = ++_managedPlaybackGeneration;
    final activeProcess = _activeManagedPlaybackProcess;
    if (activeProcess != null) {
      _terminateProcessTree(activeProcess);
    }
    final next = _managedPlaybackTail.then((_) {
      _ensureManagedPlaybackCurrent(generation);
      return _prepareManagedPlayback(url, generation);
    });
    _managedPlaybackTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<ManagedPlaybackResource> _prepareManagedPlayback(
    String url,
    int generation,
  ) async {
    _ensureManagedPlaybackCurrent(generation);
    final root = await _managedPlaybackDirectory();
    _ensureManagedPlaybackCurrent(generation);
    await root.create(recursive: true);
    await _trimManagedPlaybackCache(
      root,
      protectedPaths: _protectedManagedPlaybackPaths,
    );

    Object? embeddedError;
    for (final client in const <String?>['web_embedded', null]) {
      _ensureManagedPlaybackCurrent(generation);
      try {
        final output = await _runYtDlp(
          buildManagedPlaybackArguments(url, root.path, playerClient: client),
          managedPlaybackGeneration: generation,
        );
        _ensureManagedPlaybackCurrent(generation);
        final file = _managedPlaybackFileFromOutput(output, root);
        if (file == null || !await file.exists() || await file.length() == 0) {
          throw const DownloaderException(
            'yt-dlp finalizó sin preparar un archivo reproducible.',
            code: 'yt_dlp_managed_playback_missing',
          );
        }
        final fileLength = await file.length();
        if (fileLength > _managedPlaybackMaximumEntryBytes) {
          try {
            await file.delete();
          } catch (_) {
            // The explicit size failure below remains the useful result.
          }
          throw DownloaderException(
            'El audio preparado excede el límite de caché de '
            '$_managedPlaybackMaximumEntryBytes bytes.',
            code: 'yt_dlp_managed_playback_too_large',
          );
        }
        await file.setLastModified(DateTime.now());
        _ensureManagedPlaybackCurrent(generation);
        final protectedPaths = _managedPlaybackProtectionWindow(file.path);
        _protectedManagedPlaybackPaths = protectedPaths;
        await _trimManagedPlaybackCache(root, protectedPaths: protectedPaths);
        _ensureManagedPlaybackCurrent(generation);
        final extension = p
            .extension(file.path)
            .replaceFirst('.', '')
            .toLowerCase();
        final baseSegments = p.basenameWithoutExtension(file.path).split('.');
        return ManagedPlaybackResource(
          filePath: file.path,
          extension: extension.isEmpty ? null : extension,
          mimeType: _audioMimeType(extension),
          formatId: baseSegments.length > 1 ? baseSegments.last : null,
        );
      } catch (error) {
        _ensureManagedPlaybackCurrent(generation);
        if (error is DownloaderException &&
            const {
              'yt_dlp_process_idle_timeout',
              'yt_dlp_process_total_timeout',
            }.contains(error.code)) {
          rethrow;
        }
        if (client == null) {
          if (embeddedError == null) {
            rethrow;
          }
          throw DownloaderException(
            '${_cleanManagedPlaybackError(error)}\n'
            'Primer intento (web_embedded): '
            '${_cleanManagedPlaybackError(embeddedError)}',
            code: 'yt_dlp_managed_playback_failed',
          );
        }
        embeddedError = error;
      }
    }

    throw const DownloaderException(
      'yt-dlp no pudo preparar el audio para reproducirlo.',
      code: 'yt_dlp_managed_playback_failed',
    );
  }

  void _ensureManagedPlaybackCurrent(int generation) {
    if (_disposed || generation != _managedPlaybackGeneration) {
      throw const DownloaderException(
        'La preparación fue reemplazada por una pista más reciente.',
        code: 'yt_dlp_managed_playback_superseded',
      );
    }
  }

  @visibleForTesting
  List<String> buildManagedPlaybackArguments(
    String url,
    String outputDirectory, {
    String? playerClient,
  }) {
    return [
      '--ignore-config',
      '--no-playlist',
      '--no-warnings',
      '--newline',
      '--progress',
      '--progress-template',
      _progressTemplate,
      '--progress-delta',
      '1',
      '--fixup',
      'never',
      '--downloader',
      'native',
      '--http-chunk-size',
      '1M',
      '--max-filesize',
      _managedPlaybackMaximumEntryBytes.toString(),
      '--print',
      'after_move:filepath',
      '-f',
      AppConstants.preferredNativeAudioFormat,
      if (playerClient != null) ...[
        '--extractor-args',
        'youtube:player_client=$playerClient',
      ],
      '-o',
      p.join(outputDirectory, '%(id)s.%(format_id)s.%(ext)s'),
      url,
    ];
  }

  @override
  Future<List<TrackInfo>> search(String query) async {
    final output = await _runYtDlp(buildSearchArguments(query));

    return const LineSplitter()
        .convert(output)
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .map(TrackInfoModel.fromJson)
        .toList(growable: false);
  }

  @visibleForTesting
  List<String> buildSearchArguments(String query) {
    return [
      '--dump-json',
      '--flat-playlist',
      '--no-warnings',
      'ytsearch${AppConstants.defaultSearchLimit}:$query',
    ];
  }

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    return _download(
      url: url,
      options: options,
      mediaType: DownloadMediaType.audio,
      args: buildAudioDownloadArguments(url, options),
    );
  }

  @visibleForTesting
  List<String> buildAudioDownloadArguments(
    String url,
    DownloadOptions options,
  ) {
    return [
      '--ignore-config',
      '--newline',
      '--no-playlist',
      '--fixup',
      'never',
      '--downloader',
      'native',
      '--progress',
      '--progress-template',
      _progressTemplate,
      '--progress-delta',
      '0.2',
      '--print',
      'after_move:filepath',
      '-f',
      AppConstants.preferredNativeAudioFormat,
      if (options.restrictFileNames) '--restrict-filenames',
      '-o',
      buildAudioOutputTemplate(options),
      url,
    ];
  }

  @visibleForTesting
  String buildAudioOutputTemplate(DownloadOptions options) {
    final fileName =
        options.fileName == null || options.fileName!.trim().isEmpty
        ? '%(uploader,channel,artist|BStream)s - %(title)s'
        : safeFileName(options.fileName!);
    return p.join(options.outputDirectory, '$fileName.%(ext)s');
  }

  @visibleForTesting
  bool isSupportedAudioFilePath(String filePath) {
    return _audioFileExtensions.contains(p.extension(filePath).toLowerCase());
  }

  Future<String> _runYtDlp(
    List<String> args, {
    int? managedPlaybackGeneration,
  }) async {
    if (managedPlaybackGeneration != null) {
      _ensureManagedPlaybackCurrent(managedPlaybackGeneration);
    }
    final executable = await getYtDlpPath();
    if (managedPlaybackGeneration != null) {
      _ensureManagedPlaybackCurrent(managedPlaybackGeneration);
    }
    late final Process process;
    try {
      process = await _startProcess(executable, args);
    } on ProcessException catch (error) {
      throw DownloaderException(
        'No se pudo ejecutar yt-dlp. Configura la ruta o agrégalo al PATH.',
        code: 'yt_dlp_not_found',
        details: error,
      );
    }

    if (managedPlaybackGeneration != null) {
      if (managedPlaybackGeneration != _managedPlaybackGeneration ||
          _disposed) {
        _terminateProcessTree(process);
        _forgetProcess(process);
        _ensureManagedPlaybackCurrent(managedPlaybackGeneration);
      }
      _activeManagedPlaybackProcess = process;
    }

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final managedPlayback = managedPlaybackGeneration != null;
    final watchdog = _YtDlpProcessWatchdog(
      process: process,
      terminate: _terminateProcessTree,
      totalTimeout: managedPlayback
          ? _processDownloadTotalTimeout
          : _processResolutionTimeout,
      totalError: DownloaderException(
        managedPlayback
            ? 'yt-dlp excedió el límite total de preparación de audio '
                  '(${_durationLabel(_processDownloadTotalTimeout)}).'
            : 'yt-dlp no resolvio la solicitud en '
                  '${_durationLabel(_processResolutionTimeout)}.',
        code: managedPlayback
            ? 'yt_dlp_process_total_timeout'
            : 'yt_dlp_process_resolution_timeout',
      ),
      idleTimeout: managedPlayback ? _processIdleTimeout : null,
      idleError: managedPlayback
          ? DownloaderException(
              'yt-dlp dejó de reportar actividad durante '
              '${_durationLabel(_processIdleTimeout)}.',
              code: 'yt_dlp_process_idle_timeout',
            )
          : null,
    );
    try {
      final stdoutDone = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) {
            watchdog.touch();
            stdoutBuffer.write(chunk);
          })
          .asFuture<void>();
      final stderrDone = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen((chunk) {
            watchdog.touch();
            stderrBuffer.write(chunk);
          })
          .asFuture<void>();

      final exitCode = await watchdog.waitForExit();
      await Future.wait([stdoutDone, stderrDone]);

      if (managedPlaybackGeneration != null) {
        _ensureManagedPlaybackCurrent(managedPlaybackGeneration);
      }

      if (exitCode != 0) {
        throw DownloaderException(
          _cleanProcessError(stderrBuffer.toString(), stdoutBuffer.toString()),
          code: 'yt_dlp_failed',
        );
      }
      return stdoutBuffer.toString();
    } finally {
      if (identical(_activeManagedPlaybackProcess, process)) {
        _activeManagedPlaybackProcess = null;
      }
      _forgetProcess(process);
    }
  }

  Future<DownloadResult> _download({
    required String url,
    required DownloadOptions options,
    required DownloadMediaType mediaType,
    required List<String> args,
  }) async {
    final requestedTaskId = options.taskId?.trim();
    final taskId = requestedTaskId == null || requestedTaskId.isEmpty
        ? _uuid.v4()
        : requestedTaskId;
    final outputDirectory = Directory(options.outputDirectory);
    await outputDirectory.create(recursive: true);

    _emitProgress(
      DownloadProgress(
        taskId: taskId,
        url: url,
        status: DownloadProgressStatus.queued,
        progress: 0,
        message: 'Preparando descarga',
      ),
    );

    final executable = await getYtDlpPath();
    final process = await _startProcess(executable, args);
    final errorBuffer = StringBuffer();
    String? printedFilePath;
    final watchdog = _YtDlpProcessWatchdog(
      process: process,
      terminate: _terminateProcessTree,
      totalTimeout: _processDownloadTotalTimeout,
      totalError: DownloaderException(
        'yt-dlp excedió el límite total de descarga '
        '(${_durationLabel(_processDownloadTotalTimeout)}).',
        code: 'yt_dlp_process_total_timeout',
      ),
      idleTimeout: _processIdleTimeout,
      idleError: DownloaderException(
        'yt-dlp dejó de reportar actividad durante '
        '${_durationLabel(_processIdleTimeout)}.',
        code: 'yt_dlp_process_idle_timeout',
      ),
    );

    _emitProgress(
      DownloadProgress(
        taskId: taskId,
        url: url,
        status: DownloadProgressStatus.running,
        progress: 0,
        message: 'Descargando',
      ),
    );

    try {
      final stdoutDone = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            watchdog.touch();
            final path = _pathFromOutput(line);
            if (path != null) {
              printedFilePath = path;
            }
            _handleProgressLine(taskId, url, line);
          })
          .asFuture<void>();

      final stderrDone = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            watchdog.touch();
            if (!_handleProgressLine(taskId, url, line)) {
              errorBuffer.writeln(line);
            }
          })
          .asFuture<void>();

      final exitCode = await watchdog.waitForExit();
      await Future.wait([stdoutDone, stderrDone]);

      if (exitCode != 0) {
        _emitProgress(
          DownloadProgress(
            taskId: taskId,
            url: url,
            status: DownloadProgressStatus.failed,
            message: errorBuffer.toString().trim(),
          ),
        );
        throw DownloaderException(
          errorBuffer.toString().trim().isEmpty
              ? 'yt-dlp terminó con código $exitCode.'
              : errorBuffer.toString().trim(),
          code: 'yt_dlp_download_failed',
        );
      }

      final filePath =
          printedFilePath ?? await _findNewestFile(outputDirectory, mediaType);
      if (filePath == null) {
        throw const DownloaderException(
          'No se encontró el archivo descargado.',
        );
      }

      _emitProgress(
        DownloadProgress(
          taskId: taskId,
          url: url,
          status: DownloadProgressStatus.completed,
          progress: 1,
          message: 'Descarga completada',
        ),
      );

      return DownloadResultModel.completed(
        sourceUrl: url,
        filePath: filePath,
        mediaType: mediaType,
      );
    } finally {
      _forgetProcess(process);
    }
  }

  Future<Process> _startProcess(String executable, List<String> args) async {
    if (_disposed) {
      throw const DownloaderException(
        'El gestor de descargas ya fue cerrado.',
        code: 'downloader_disposed',
      );
    }
    try {
      // Finder and Dock do not provide the interactive shell environment.
      // Include the tool's directory explicitly so yt-dlp can still resolve
      // helper binaries when the app is launched outside Terminal.
      final environment = Map<String, String>.from(Platform.environment);
      final executablePath = File(executable);
      if (executablePath.isAbsolute) {
        final toolDirectory = executablePath.parent.path;
        final separator = Platform.isWindows ? ';' : ':';
        final existingPath = environment['PATH'];
        environment['PATH'] = [
          toolDirectory,
          if (existingPath != null && existingPath.isNotEmpty) existingPath,
        ].join(separator);
      }
      final processArguments = buildYtDlpProcessArguments(executable, args);
      final starter = _processStarterOverride;
      final process = starter == null
          ? await Process.start(
              executable,
              processArguments,
              environment: environment,
            )
          : await starter(executable, processArguments);
      _activeProcesses[process.pid] = process;
      return process;
    } on ProcessException catch (error) {
      throw DownloaderException(
        'No se pudo iniciar yt-dlp. Configura la ruta o agrégalo al PATH.',
        code: 'yt_dlp_not_found',
        details: error,
      );
    }
  }

  void _forgetProcess(Process process) {
    _activeProcesses.remove(process.pid);
  }

  void _terminateProcessTree(Process process) {
    final terminator = _processTerminatorOverride;
    if (terminator != null) {
      terminator(process);
      return;
    }
    if (Platform.isWindows) {
      unawaited(
        Process.run('taskkill', ['/PID', process.pid.toString(), '/T', '/F'])
            .then((result) {
              if (result.exitCode != 0) {
                process.kill();
              }
            })
            .catchError((_) {
              process.kill();
            }),
      );
      return;
    }
    process.kill();
  }

  bool _handleProgressLine(String taskId, String url, String line) {
    final sample = parseAudioDownloadProgressLine(line);
    if (sample == null) {
      return false;
    }

    final progress = sample.progress.clamp(0.0, 0.98).toDouble();
    _emitProgress(
      DownloadProgress(
        taskId: taskId,
        url: url,
        status: DownloadProgressStatus.running,
        progress: progress,
        message: 'Descargando ${(progress * 100).toStringAsFixed(1)}%',
        eta: sample.eta,
      ),
    );
    return true;
  }

  @visibleForTesting
  ({double progress, Duration? eta})? parseAudioDownloadProgressLine(
    String line,
  ) {
    final structured = RegExp(
      r'BSTREAM_PROGRESS\|\s*~?\s*([0-9]+(?:\.[0-9]+)?)%\|([^|\r\n]*)',
    ).firstMatch(line);
    if (structured != null) {
      final rawProgress = double.tryParse(structured.group(1)!);
      if (rawProgress == null) {
        return null;
      }
      final rawEta = structured.group(2)?.trim();
      final etaSeconds = rawEta == null ? null : double.tryParse(rawEta);
      return (
        progress: (rawProgress / 100).clamp(0.0, 1.0).toDouble(),
        eta: etaSeconds == null || !etaSeconds.isFinite || etaSeconds < 0
            ? null
            : Duration(milliseconds: (etaSeconds * 1000).round()),
      );
    }

    final standard = RegExp(
      r'\[download\]\s+([0-9]+(?:\.[0-9]+)?)%',
    ).firstMatch(line);
    final rawProgress = standard == null
        ? null
        : double.tryParse(standard.group(1)!);
    if (rawProgress == null) {
      return null;
    }
    final eta = RegExp(
      r'ETA\s+((?:[0-9]+:)?[0-9]{1,2}:[0-9]{2})',
    ).firstMatch(line)?.group(1);
    return (
      progress: (rawProgress / 100).clamp(0.0, 1.0).toDouble(),
      eta: _parseEta(eta),
    );
  }

  String? _pathFromOutput(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('[') ||
        trimmed.startsWith('WARNING') ||
        trimmed.startsWith('ERROR')) {
      return null;
    }
    final file = File(trimmed);
    return file.existsSync() ? file.path : null;
  }

  Future<String?> _findNewestFile(
    Directory directory,
    DownloadMediaType mediaType,
  ) async {
    final files = await directory
        .list()
        .where(
          (entity) => entity is File && isSupportedAudioFilePath(entity.path),
        )
        .cast<File>()
        .toList();

    files.sort(
      (left, right) =>
          right.lastModifiedSync().compareTo(left.lastModifiedSync()),
    );
    return files.isEmpty ? null : files.first.path;
  }

  Future<Directory> _managedPlaybackDirectory() async {
    final override = _managedPlaybackDirectoryOverride;
    if (override != null) {
      return override();
    }
    final temporary = await getTemporaryDirectory();
    return Directory(p.join(temporary.path, 'bstream_managed_playback'));
  }

  File? _managedPlaybackFileFromOutput(String output, Directory root) {
    for (final line in const LineSplitter().convert(output).reversed) {
      final value = line.trim();
      if (value.isEmpty) {
        continue;
      }
      final file = File(value);
      if (!file.isAbsolute || !p.isWithin(root.path, file.path)) {
        continue;
      }
      if (file.existsSync() && isSupportedAudioFilePath(file.path)) {
        return file;
      }
    }
    return null;
  }

  @visibleForTesting
  Future<void> trimManagedPlaybackCacheForTesting(
    Directory root, {
    String? protectedPath,
    Iterable<String> protectedPaths = const [],
  }) {
    return _trimManagedPlaybackCache(
      root,
      protectedPaths: [...protectedPaths, ?protectedPath],
    );
  }

  Future<void> _trimManagedPlaybackCache(
    Directory root, {
    required Iterable<String> protectedPaths,
  }) async {
    const maximumAge = Duration(hours: 12);
    final cutoff = DateTime.now().subtract(maximumAge);
    final normalizedProtectedPaths = protectedPaths
        .map((path) => p.canonicalize(p.absolute(path)))
        .toSet();
    final files = await root
        .list(followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();

    for (final file in files.where(
      (file) =>
          !_isProtectedManagedPlaybackFile(file, normalizedProtectedPaths) &&
          (file.path.endsWith('.part') ||
              file.path.endsWith('.ytdl') ||
              file.lastModifiedSync().isBefore(cutoff)),
    )) {
      try {
        await file.delete();
      } catch (_) {
        // Cache cleanup must never prevent playback.
      }
    }

    final completed = await root
        .list(followLinks: false)
        .where(
          (entity) => entity is File && isSupportedAudioFilePath(entity.path),
        )
        .cast<File>()
        .toList();
    completed.sort((left, right) {
      final leftProtected = _isProtectedManagedPlaybackFile(
        left,
        normalizedProtectedPaths,
      );
      final rightProtected = _isProtectedManagedPlaybackFile(
        right,
        normalizedProtectedPaths,
      );
      if (leftProtected != rightProtected) {
        return leftProtected ? -1 : 1;
      }
      return right.lastModifiedSync().compareTo(left.lastModifiedSync());
    });

    var retainedFiles = 0;
    var retainedBytes = 0;
    for (final file in completed) {
      final protected = _isProtectedManagedPlaybackFile(
        file,
        normalizedProtectedPaths,
      );
      int length;
      try {
        length = await file.length();
      } catch (_) {
        continue;
      }
      final exceedsLimits =
          retainedFiles >= _managedPlaybackMaximumFiles ||
          length > _managedPlaybackMaximumBytes - retainedBytes;
      if (!protected && exceedsLimits) {
        try {
          await file.delete();
        } catch (_) {
          // Cache cleanup must never prevent playback.
        }
        continue;
      }
      retainedFiles++;
      retainedBytes += length;
    }
  }

  bool _isProtectedManagedPlaybackFile(File file, Set<String> protectedPaths) {
    if (protectedPaths.isEmpty) {
      return false;
    }
    final candidate = p.canonicalize(p.absolute(file.path));
    return protectedPaths.any((path) => p.equals(candidate, path));
  }

  List<String> _managedPlaybackProtectionWindow(String newestPath) {
    final newest = p.canonicalize(p.absolute(newestPath));
    final paths = <String>[newest];
    for (final existing in _protectedManagedPlaybackPaths) {
      final normalized = p.canonicalize(p.absolute(existing));
      if (!paths.any((path) => p.equals(path, normalized))) {
        paths.add(normalized);
      }
      if (paths.length == 2) {
        break;
      }
    }
    return List<String>.unmodifiable(paths);
  }

  @visibleForTesting
  int get managedPlaybackMaximumEntryBytesForTesting =>
      _managedPlaybackMaximumEntryBytes;

  String? _audioMimeType(String extension) {
    return switch (extension) {
      'm4a' || 'm4b' || 'mp4' => 'audio/mp4',
      'aac' => 'audio/aac',
      'mp3' => 'audio/mpeg',
      'webm' || 'weba' => 'audio/webm',
      'ogg' || 'oga' => 'audio/ogg',
      'opus' => 'audio/opus',
      'flac' => 'audio/flac',
      'wav' => 'audio/wav',
      '3gp' || '3gpp' => 'audio/3gpp',
      _ => null,
    };
  }

  String _cleanManagedPlaybackError(Object error) {
    if (error is DownloaderException) {
      return error.message.trim();
    }
    return error.toString().trim();
  }

  Future<bool> _checkExecutable(String executable, List<String> args) async {
    Process? process;
    try {
      process = await _startProcess(executable, args);
      final watchdog = _YtDlpProcessWatchdog(
        process: process,
        terminate: _terminateProcessTree,
        totalTimeout: _processResolutionTimeout,
        totalError: DownloaderException(
          'yt-dlp no respondio a la comprobacion en '
          '${_durationLabel(_processResolutionTimeout)}.',
          code: 'yt_dlp_process_resolution_timeout',
        ),
      );
      final stdoutDone = process.stdout.drain<void>();
      final stderrDone = process.stderr.drain<void>();
      final exitCode = await watchdog.waitForExit();
      await Future.wait([stdoutDone, stderrDone]);
      return exitCode == 0;
    } catch (_) {
      return false;
    } finally {
      if (process != null) {
        _forgetProcess(process);
      }
    }
  }

  @visibleForTesting
  List<String> buildYtDlpProcessArguments(
    String ytDlpExecutable,
    List<String> args,
  ) {
    final arguments = List<String>.of(args);
    if (!arguments.contains('--ignore-config')) {
      arguments.insert(0, '--ignore-config');
    }
    var insertionIndex = arguments.indexOf('--ignore-config') + 1;
    if (!_hasOption(arguments, '--socket-timeout')) {
      arguments.insertAll(insertionIndex, const ['--socket-timeout', '20']);
      insertionIndex += 2;
    }

    final deno = _findBundledDeno(ytDlpExecutable);
    if (deno != null && !_hasJavaScriptRuntime(arguments, 'deno')) {
      arguments.insertAll(insertionIndex, [
        '--js-runtimes',
        'deno:${p.absolute(deno)}',
      ]);
      insertionIndex += 2;
    }

    // Deno is bundled in release builds. Explicitly enabling Node as a second
    // choice also keeps local/development builds working when Deno has not yet
    // been provisioned but a supported Node installation is on PATH.
    if (!_hasJavaScriptRuntime(arguments, 'node')) {
      arguments.insertAll(insertionIndex, const ['--js-runtimes', 'node']);
    }
    return arguments;
  }

  bool _hasOption(List<String> arguments, String option) {
    return arguments.any(
      (argument) => argument == option || argument.startsWith('$option='),
    );
  }

  bool _hasJavaScriptRuntime(List<String> args, String runtime) {
    for (var index = 0; index < args.length; index++) {
      final argument = args[index];
      String? value;
      if (argument == '--js-runtimes' && index + 1 < args.length) {
        value = args[index + 1];
      } else if (argument.startsWith('--js-runtimes=')) {
        value = argument.substring('--js-runtimes='.length);
      }
      if (value != null &&
          (value == runtime || value.startsWith('$runtime:'))) {
        return true;
      }
    }
    return false;
  }

  String? _findBundledDeno(String ytDlpExecutable) {
    final executable = File(ytDlpExecutable);
    if (executable.isAbsolute) {
      for (final name in const ['deno.exe', 'deno']) {
        final sibling = File(p.join(executable.parent.path, name));
        if (sibling.existsSync()) {
          return sibling.path;
        }
      }
    }
    return _findBundledTool(const ['deno.exe', 'deno']);
  }

  String? _findBundledTool(List<String> relativeNames) {
    for (final directory in _toolDirectories()) {
      for (final relativeName in relativeNames) {
        final candidate = File(p.join(directory.path, relativeName));
        if (candidate.existsSync()) {
          return candidate.path;
        }
      }
    }
    return null;
  }

  String? _configuredExecutable(
    String? configured,
    List<String> relativeNames,
  ) {
    final value = configured?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }

    final type = FileSystemEntity.typeSync(value);
    if (type == FileSystemEntityType.file) {
      return value;
    }
    if (type == FileSystemEntityType.directory) {
      for (final relativeName in relativeNames) {
        final candidate = File(p.join(value, relativeName));
        if (candidate.existsSync()) {
          return candidate.path;
        }
      }
      return null;
    }

    final looksLikePath =
        value.contains('/') ||
        value.contains(r'\') ||
        p.extension(value).isNotEmpty;
    return looksLikePath ? null : value;
  }

  List<Directory> _toolDirectories() {
    final overrides = _toolDirectoryOverrides;
    if (overrides != null) {
      return List.unmodifiable(overrides);
    }

    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final currentDirectory = Directory.current;
    final directories = <Directory>[
      Directory(p.join(executableDirectory.path, 'tools')),
      Directory(p.join(executableDirectory.parent.path, 'Resources', 'tools')),
      Directory(p.join(currentDirectory.path, 'linux', 'tools')),
      Directory(p.join(currentDirectory.path, 'macos', 'tools')),
      Directory(p.join(currentDirectory.path, 'windows', 'tools')),
      Directory(p.join(currentDirectory.path, 'tools')),
    ];

    // LaunchServices (Finder/Dock) can start a macOS Flutter executable with
    // a minimal environment. In that case some Flutter builds expose a
    // relative `resolvedExecutable`, so the paths derived only from the
    // executable directory are not sufficient. Keep the standard bundle
    // locations as deterministic fallbacks; this does not depend on PATH.
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      directories.add(
        Directory('/Applications/BStream Music.app/Contents/Resources/tools'),
      );
      if (home != null && home.isNotEmpty) {
        directories.add(
          Directory(
            p.join(
              home,
              'Applications',
              'BStream Music.app',
              'Contents',
              'Resources',
              'tools',
            ),
          ),
        );
      }
    }

    var cursor = executableDirectory;
    for (var index = 0; index < 8; index++) {
      directories.add(Directory(p.join(cursor.path, 'linux', 'tools')));
      directories.add(Directory(p.join(cursor.path, 'macos', 'tools')));
      directories.add(Directory(p.join(cursor.path, 'windows', 'tools')));
      final parent = cursor.parent;
      if (parent.path == cursor.path) {
        break;
      }
      cursor = parent;
    }

    final unique = <String, Directory>{};
    for (final directory in directories) {
      unique[p.normalize(directory.path)] = directory;
    }
    return unique.values.toList(growable: false);
  }

  Duration? _parseEta(String? value) {
    if (value == null) {
      return null;
    }
    final parts = value.split(':').map(int.tryParse).toList();
    if (parts.any((part) => part == null)) {
      return null;
    }
    if (parts.length == 2) {
      return Duration(minutes: parts[0]!, seconds: parts[1]!);
    }
    if (parts.length == 3) {
      return Duration(hours: parts[0]!, minutes: parts[1]!, seconds: parts[2]!);
    }
    return null;
  }

  String _durationLabel(Duration duration) {
    if (duration.inHours > 0 && duration == Duration(hours: duration.inHours)) {
      return '${duration.inHours} h';
    }
    if (duration.inMinutes > 0 &&
        duration == Duration(minutes: duration.inMinutes)) {
      return '${duration.inMinutes} min';
    }
    if (duration.inSeconds > 0) {
      return '${duration.inSeconds} s';
    }
    return '${duration.inMilliseconds} ms';
  }

  String _cleanProcessError(Object? stderr, Object? stdout) {
    final error = stderr?.toString().trim() ?? '';
    if (error.isNotEmpty) {
      return error;
    }
    final output = stdout?.toString().trim() ?? '';
    return output.isEmpty ? 'yt-dlp no devolvio detalles del error.' : output;
  }

  void _emitProgress(DownloadProgress progress) {
    if (!_progressController.isClosed) {
      _progressController.add(progress);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _managedPlaybackGeneration++;
    _activeManagedPlaybackProcess = null;
    final processes = _activeProcesses.values.toList(growable: false);
    _activeProcesses.clear();
    for (final process in processes) {
      _terminateProcessTree(process);
    }
    await _progressController.close();
  }
}

class _YtDlpProcessWatchdog {
  _YtDlpProcessWatchdog({
    required this.process,
    required this.terminate,
    required this.totalTimeout,
    required this.totalError,
    this.idleTimeout,
    this.idleError,
  }) : assert(totalTimeout > Duration.zero),
       assert(idleTimeout == null || idleTimeout > Duration.zero),
       assert((idleTimeout == null) == (idleError == null)) {
    _totalTimer = Timer(totalTimeout, () => _expire(totalError));
    _resetIdleTimer();
  }

  final Process process;
  final void Function(Process process) terminate;
  final Duration totalTimeout;
  final DownloaderException totalError;
  final Duration? idleTimeout;
  final DownloaderException? idleError;
  final Completer<_YtDlpProcessTimeout> _deadline =
      Completer<_YtDlpProcessTimeout>();

  late final Timer _totalTimer;
  Timer? _idleTimer;

  void touch() {
    if (_deadline.isCompleted) {
      return;
    }
    _resetIdleTimer();
  }

  Future<int> waitForExit() async {
    final outcome = await Future.any<Object>([
      process.exitCode.then<Object>(_YtDlpProcessExit.new),
      _deadline.future,
    ]);
    _totalTimer.cancel();
    _idleTimer?.cancel();
    if (outcome is _YtDlpProcessExit) {
      return outcome.code;
    }

    final timeout = outcome as _YtDlpProcessTimeout;
    try {
      terminate(process);
    } catch (_) {
      process.kill();
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {
      // The watchdog error below is the useful failure for the caller.
    }
    throw timeout.error;
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    final timeout = idleTimeout;
    final error = idleError;
    if (timeout == null || error == null || _deadline.isCompleted) {
      return;
    }
    _idleTimer = Timer(timeout, () => _expire(error));
  }

  void _expire(DownloaderException error) {
    if (!_deadline.isCompleted) {
      _deadline.complete(_YtDlpProcessTimeout(error));
    }
  }
}

class _YtDlpProcessExit {
  const _YtDlpProcessExit(this.code);

  final int code;
}

class _YtDlpProcessTimeout {
  const _YtDlpProcessTimeout(this.error);

  final DownloaderException error;
}
