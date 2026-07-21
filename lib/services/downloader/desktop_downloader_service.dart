import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  DesktopDownloaderService({SharedPreferences? initialPreferences})
    : _preferences = initialPreferences;

  static const _ytDlpPathKey = 'desktop.ytDlpPath';
  static const _ffmpegPathKey = 'desktop.ffmpegPath';

  final SharedPreferences? _preferences;
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

  Future<void> setFfmpegPath(String? path) async {
    final prefs = await _prefs;
    if (path == null || path.trim().isEmpty) {
      await prefs.remove(_ffmpegPathKey);
      return;
    }
    await prefs.setString(_ffmpegPathKey, path.trim());
  }

  Future<String> getYtDlpPath() async {
    final configured = _configuredExecutable(
      (await _prefs).getString(_ytDlpPathKey),
      ['yt-dlp.exe', 'yt-dlp'],
    );
    if (configured != null) return configured;
    return _findBundledTool(['yt-dlp.exe', 'yt-dlp']) ?? 'yt-dlp';
  }

  Future<String?> getFfmpegPath() async {
    final names = [
      'ffmpeg.exe',
      'ffmpeg',
      p.join('ffmpeg', 'bin', 'ffmpeg.exe'),
      p.join('ffmpeg', 'bin', 'ffmpeg'),
    ];
    final configured = _configuredExecutable(
      (await _prefs).getString(_ffmpegPathKey),
      names,
    );
    if (configured != null) return configured;
    return _findBundledTool([
      'ffmpeg.exe',
      'ffmpeg',
      p.join('ffmpeg', 'bin', 'ffmpeg.exe'),
      p.join('ffmpeg', 'bin', 'ffmpeg'),
    ]);
  }

  Future<bool> hasYtDlp() async {
    return _checkExecutable(await getYtDlpPath(), const ['--version']);
  }

  Future<bool> hasFfmpeg() async {
    return _checkExecutable(await getFfmpegPath() ?? 'ffmpeg', const [
      '-version',
    ]);
  }

  @override
  Future<TrackInfo> getInfo(String url) async {
    final output = await _runYtDlp([
      '--dump-single-json',
      '--no-playlist',
      '--no-warnings',
      '-f',
      AppConstants.remotePlaybackAudioFormat,
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
      args: [
        '--newline',
        '--no-playlist',
        '--print',
        'after_move:filepath',
        '-f',
        'bestaudio/best',
        '-x',
        '--audio-format',
        options.audioFormat,
        '--audio-quality',
        options.quality ?? AppConstants.defaultAudioQuality,
        if (options.embedMetadata) ...['--embed-metadata', '--embed-thumbnail'],
      ],
    );
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
    final taskId = _uuid.v4();
    final outputDirectory = Directory(options.outputDirectory);
    await outputDirectory.create(recursive: true);

    final template = _outputTemplate(options, mediaType);
    final ffmpegPath = await getFfmpegPath();
    final fullArgs = [
      ...args,
      if (options.restrictFileNames) '--restrict-filenames',
      if (ffmpegPath != null && ffmpegPath.trim().isNotEmpty) ...[
        '--ffmpeg-location',
        ffmpegPath,
      ],
      '-o',
      template,
      url,
    ];

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
    final process = await _startProcess(executable, fullArgs);
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
          .listen((line) => errorBuffer.writeln(line))
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
      final process = await Process.start(executable, args);
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

  String _outputTemplate(DownloadOptions options, DownloadMediaType mediaType) {
    final extension = options.audioFormat;
    final fileName =
        options.fileName == null || options.fileName!.trim().isEmpty
        ? '%(uploader,channel,artist|BStream)s - %(title)s'
        : safeFileName(options.fileName!);
    return p.join(options.outputDirectory, '$fileName.$extension');
  }

  void _handleProgressLine(String taskId, String url, String line) {
    final match = RegExp(
      r'\[download\]\s+([0-9]+(?:\.[0-9]+)?)%',
    ).firstMatch(line);
    if (match == null) {
      return;
    }

    final rawProgress = double.tryParse(match.group(1)!);
    final eta = RegExp(r'ETA\s+([0-9:]+)').firstMatch(line)?.group(1);
    _emitProgress(
      DownloadProgress(
        taskId: taskId,
        url: url,
        status: DownloadProgressStatus.running,
        progress: rawProgress == null ? null : rawProgress / 100,
        message: line.replaceFirst('[download]', '').trim(),
        eta: _parseEta(eta),
      ),
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
    final allowedExtensions = {
      '.mp3',
      '.m4a',
      '.opus',
      '.flac',
      '.aac',
      '.wav',
    };

    final files = await directory
        .list()
        .where(
          (entity) =>
              entity is File &&
              allowedExtensions.contains(
                p.extension(entity.path).toLowerCase(),
              ),
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
        args,
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      );
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
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
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final currentDirectory = Directory.current;
    final directories = <Directory>[
      Directory(p.join(executableDirectory.path, 'tools')),
      Directory(p.join(currentDirectory.path, 'windows', 'tools')),
      Directory(p.join(currentDirectory.path, 'tools')),
    ];

    var cursor = executableDirectory;
    for (var index = 0; index < 8; index++) {
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
