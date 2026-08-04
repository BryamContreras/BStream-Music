import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
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

class DesktopDownloaderService implements DownloaderService {
  DesktopDownloaderService({
    SharedPreferences? initialPreferences,
    List<Directory>? toolDirectories,
  }) : _preferences = initialPreferences,
       _toolDirectoryOverrides = toolDirectories;

  static const _ytDlpPathKey = 'desktop.ytDlpPath';
  static const _progressTemplate =
      'download:BSTREAM_PROGRESS|%(progress._percent_str)s|%(progress.eta)s';
  static const _audioFileExtensions = {
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
  final _uuid = const Uuid();
  final _progressController = StreamController<DownloadProgress>.broadcast();
  final _activeProcesses = <int, Process>{};

  SharedPreferences? _resolvedPreferences;
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
  Future<List<TrackInfo>> search(String query) async {
    final output = await _runYtDlp([
      '--dump-json',
      '--flat-playlist',
      '--no-warnings',
      'ytsearch${AppConstants.defaultSearchLimit}:$query',
    ]);

    return const LineSplitter()
        .convert(output)
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .map(TrackInfoModel.fromJson)
        .toList(growable: false);
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

  Future<String> _runYtDlp(List<String> args) async {
    final executable = await getYtDlpPath();
    late final Process process;
    try {
      process = await _startProcess(executable, args);
    } on ProcessException catch (error) {
      throw DownloaderException(
        'No se pudo ejecutar yt-dlp. Configura la ruta o agregalo al PATH.',
        code: 'yt_dlp_not_found',
        details: error,
      );
    }

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    try {
      final stdoutDone = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(stdoutBuffer.write)
          .asFuture<void>();
      final stderrDone = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(stderrBuffer.write)
          .asFuture<void>();

      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);

      if (exitCode != 0) {
        throw DownloaderException(
          _cleanProcessError(stderrBuffer.toString(), stdoutBuffer.toString()),
          code: 'yt_dlp_failed',
        );
      }
      return stdoutBuffer.toString();
    } finally {
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
            if (!_handleProgressLine(taskId, url, line)) {
              errorBuffer.writeln(line);
            }
          })
          .asFuture<void>();

      final exitCode = await process.exitCode;
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
              ? 'yt-dlp termino con codigo $exitCode.'
              : errorBuffer.toString().trim(),
          code: 'yt_dlp_download_failed',
        );
      }

      final filePath =
          printedFilePath ?? await _findNewestFile(outputDirectory, mediaType);
      if (filePath == null) {
        throw const DownloaderException(
          'No se encontro el archivo descargado.',
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
      final process = await Process.start(
        executable,
        buildYtDlpProcessArguments(executable, args),
        environment: environment,
      );
      _activeProcesses[process.pid] = process;
      return process;
    } on ProcessException catch (error) {
      throw DownloaderException(
        'No se pudo iniciar yt-dlp. Configura la ruta o agregalo al PATH.',
        code: 'yt_dlp_not_found',
        details: error,
      );
    }
  }

  void _forgetProcess(Process process) {
    _activeProcesses.remove(process.pid);
  }

  void _terminateProcessTree(Process process) {
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

  Future<bool> _checkExecutable(String executable, List<String> args) async {
    try {
      final result = await Process.run(
        executable,
        buildYtDlpProcessArguments(executable, args),
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
      return result.exitCode == 0;
    } on ProcessException {
      return false;
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
    final processes = _activeProcesses.values.toList(growable: false);
    _activeProcesses.clear();
    for (final process in processes) {
      _terminateProcessTree(process);
    }
    await _progressController.close();
  }
}
