import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum TikTokLiveBridgeStatus {
  idle,
  connecting,
  connected,
  disconnected,
  liveEnded,
  error,
}

class TikTokLiveBridgeEvent {
  const TikTokLiveBridgeEvent({
    required this.type,
    this.status,
    this.user,
    this.roomId,
    this.message,
    this.command,
  });

  final String type;
  final TikTokLiveBridgeStatus? status;
  final String? user;
  final String? roomId;
  final String? message;
  final TikTokLiveChatCommand? command;

  factory TikTokLiveBridgeEvent.fromJson(Map<String, dynamic> json) {
    final type = json['type']?.toString() ?? 'status';
    return TikTokLiveBridgeEvent(
      type: type,
      status: _statusFromType(type, json['status']?.toString()),
      user: json['user']?.toString(),
      roomId: json['room_id']?.toString(),
      message: json['message']?.toString(),
      command: type == 'command' ? TikTokLiveChatCommand.fromJson(json) : null,
    );
  }

  static TikTokLiveBridgeStatus? _statusFromType(String type, String? status) {
    final normalized = (status ?? type).toLowerCase();
    return switch (normalized) {
      'connecting' => TikTokLiveBridgeStatus.connecting,
      'connected' => TikTokLiveBridgeStatus.connected,
      'disconnected' => TikTokLiveBridgeStatus.disconnected,
      'live_ended' || 'liveended' => TikTokLiveBridgeStatus.liveEnded,
      'error' => TikTokLiveBridgeStatus.error,
      _ => null,
    };
  }
}

class TikTokLiveChatCommand {
  const TikTokLiveChatCommand({
    required this.action,
    required this.user,
    required this.text,
    this.query,
    this.isModerator = false,
  });

  final String action;
  final String user;
  final String text;
  final String? query;
  final bool isModerator;

  factory TikTokLiveChatCommand.fromJson(Map<String, dynamic> json) {
    return TikTokLiveChatCommand(
      action: json['action']?.toString() ?? '',
      query: json['query']?.toString(),
      user: json['user']?.toString() ?? 'unknown',
      text: json['text']?.toString() ?? '',
      isModerator: _jsonBool(json['is_moderator']),
    );
  }

  static bool _jsonBool(Object? value) {
    if (value is bool) {
      return value;
    }
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'true' || normalized == '1';
  }
}

class TikTokLiveCommandService {
  TikTokLiveCommandService();

  final _events = StreamController<TikTokLiveBridgeEvent>.broadcast();
  Process? _process;
  bool _stopping = false;
  TikTokLiveBridgeStatus? _lastTerminalStatus;

  Stream<TikTokLiveBridgeEvent> get events => _events.stream;

  bool get isRunning => _process != null;

  Future<void> connect(String rawUser) async {
    final user = normalizeCreatorInput(rawUser);
    if (user.isEmpty) {
      throw const FormatException('Ingresa un usuario o link de TikTok LIVE.');
    }

    await disconnect();
    _stopping = false;
    _lastTerminalStatus = null;
    final launch = await _resolveBridgeLaunch();

    _emit(
      TikTokLiveBridgeEvent(
        type: 'status',
        status: TikTokLiveBridgeStatus.connecting,
        user: user,
        message: 'Abriendo puente TikTok LIVE...',
      ),
    );

    _process = await Process.start(launch.executable, [
      ...launch.args,
      '--user',
      user,
      '--parent-pid',
      '$pid',
    ]);

    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    _process!.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _handleStdoutLine,
          onError: (Object error) {
            _handleStreamError(error);
            _completeOnce(stdoutDone);
          },
          onDone: () => _completeOnce(stdoutDone),
        );
    _process!.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          _handleStderrLine,
          onError: (Object error) {
            _handleStreamError(error);
            _completeOnce(stderrDone);
          },
          onDone: () => _completeOnce(stderrDone),
        );

    unawaited(_watchExit(_process!, user, stdoutDone.future));
  }

  Future<void> disconnect() async {
    final process = _process;
    if (process == null) {
      return;
    }
    _stopping = true;
    _process = null;
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 4),
      onTimeout: () => -1,
    );
    _emit(
      const TikTokLiveBridgeEvent(
        type: 'disconnected',
        status: TikTokLiveBridgeStatus.disconnected,
        message: 'Desconectado.',
      ),
    );
  }

  Future<void> dispose() async {
    await disconnect();
    await _events.close();
  }

  void _handleStdoutLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final event = TikTokLiveBridgeEvent.fromJson(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
        _rememberTerminalEvent(event);
        _emit(event);
        return;
      }
    } catch (_) {
      // Non-JSON output is reported as status text below.
    }

    _emit(TikTokLiveBridgeEvent(type: 'status', message: trimmed));
  }

  void _handleStderrLine(String line) {
    final message = line.trim();
    if (message.isEmpty) {
      return;
    }
    _emit(TikTokLiveBridgeEvent(type: 'status', message: message));
  }

  void _handleStreamError(Object error) {
    final event = TikTokLiveBridgeEvent(
      type: 'error',
      status: TikTokLiveBridgeStatus.error,
      message: error.toString(),
    );
    _rememberTerminalEvent(event);
    _emit(event);
  }

  Future<void> _watchExit(
    Process process,
    String user,
    Future<void> stdoutDone,
  ) async {
    final exitCode = await process.exitCode;
    await stdoutDone.timeout(const Duration(seconds: 1), onTimeout: () {});
    if (!identical(_process, process)) {
      return;
    }
    _process = null;
    if (_stopping) {
      return;
    }
    if (_lastTerminalStatus == TikTokLiveBridgeStatus.error ||
        _lastTerminalStatus == TikTokLiveBridgeStatus.liveEnded) {
      return;
    }

    _emit(
      TikTokLiveBridgeEvent(
        type: exitCode == 0 ? 'disconnected' : 'error',
        status: exitCode == 0
            ? TikTokLiveBridgeStatus.disconnected
            : TikTokLiveBridgeStatus.error,
        user: user,
        message: exitCode == 0
            ? 'TikTok LIVE desconectado.'
            : 'El puente TikTok LIVE termino con codigo $exitCode.',
      ),
    );
  }

  void _rememberTerminalEvent(TikTokLiveBridgeEvent event) {
    if (event.status == TikTokLiveBridgeStatus.error ||
        event.status == TikTokLiveBridgeStatus.liveEnded) {
      _lastTerminalStatus = event.status;
    }
  }

  void _completeOnce(Completer<void> completer) {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  File? _findBridgeScript() {
    for (final directory in _scriptDirectories()) {
      final candidate = File(p.join(directory.path, 'tiktok_live_bridge.py'));
      if (candidate.existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  Iterable<Directory> _scriptDirectories() sync* {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final currentDirectory = Directory.current;
    yield Directory(p.join(executableDirectory.path, 'scripts'));
    yield Directory(p.join(currentDirectory.path, 'scripts'));
    yield Directory(p.join(currentDirectory.path, '..', '..', '..', 'scripts'));

    var cursor = executableDirectory;
    for (var index = 0; index < 8; index++) {
      yield Directory(p.join(cursor.path, 'scripts'));
      final parent = cursor.parent;
      if (parent.path == cursor.path) {
        break;
      }
      cursor = parent;
    }
  }

  Future<_BridgeLaunch> _resolveBridgeLaunch() async {
    final bundledBridge = _findBundledBridgeExecutable();
    if (bundledBridge != null) {
      return _BridgeLaunch(bundledBridge.path, const []);
    }

    final script = _findBridgeScript();
    if (script == null) {
      throw const FileSystemException(
        'No se encontro el puente TikTok LIVE empaquetado ni '
        'scripts/tiktok_live_bridge.py.',
      );
    }

    final python = await _resolveBridgePython(script);
    if (python == null) {
      throw const ProcessException(
        'python',
        [],
        'No se encontro Python ni el puente TikTok LIVE empaquetado.',
      );
    }

    return _BridgeLaunch(python.executable, [...python.args, script.path]);
  }

  File? _findBundledBridgeExecutable() {
    for (final directory in _toolDirectories()) {
      for (final relativePath in _bridgeExecutableNames()) {
        final candidate = File(p.join(directory.path, relativePath));
        if (candidate.existsSync()) {
          return candidate;
        }
      }
    }
    return null;
  }

  Iterable<String> _bridgeExecutableNames() sync* {
    if (Platform.isWindows) {
      yield p.join('tiktok-live-bridge', 'tiktok_live_bridge.exe');
      yield p.join('tiktok_live_bridge', 'tiktok_live_bridge.exe');
      yield 'tiktok_live_bridge.exe';
      yield 'tiktok-live-bridge.exe';
      return;
    }
    yield p.join('tiktok-live-bridge', 'tiktok_live_bridge');
    yield p.join('tiktok_live_bridge', 'tiktok_live_bridge');
    yield 'tiktok_live_bridge';
    yield 'tiktok-live-bridge';
  }

  Iterable<Directory> _toolDirectories() sync* {
    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final currentDirectory = Directory.current;
    yield Directory(p.join(currentDirectory.path, 'windows', 'tools'));
    yield Directory(p.join(currentDirectory.path, 'tools'));
    yield Directory(p.join(executableDirectory.path, 'tools'));

    var cursor = executableDirectory;
    for (var index = 0; index < 8; index++) {
      yield Directory(p.join(cursor.path, 'windows', 'tools'));
      yield Directory(p.join(cursor.path, 'tools'));
      final parent = cursor.parent;
      if (parent.path == cursor.path) {
        break;
      }
      cursor = parent;
    }
  }

  Future<_PythonLaunch?> _resolveBridgePython(File script) async {
    final existingVenv = await _existingVenvPython(script);
    if (existingVenv != null) {
      if (!await _hasTikTokLive(existingVenv)) {
        await _installBridgeRequirements(existingVenv, script);
      }
      return existingVenv;
    }

    final systemPython = await _resolveSystemPython();
    if (systemPython == null) {
      return null;
    }

    final venvPython = await _ensureAppVenv(systemPython);
    if (!await _hasTikTokLive(venvPython)) {
      await _installBridgeRequirements(venvPython, script);
    }
    return venvPython;
  }

  Future<_PythonLaunch?> _existingVenvPython(File script) async {
    final candidates = <Directory>[
      Directory(p.join(Directory.current.path, '.venv-tiktok')),
      ..._ancestorVenvDirectories(script.parent),
      ..._ancestorVenvDirectories(File(Platform.resolvedExecutable).parent),
      await _appVenvDirectory(),
    ];

    final seen = <String>{};
    for (final directory in candidates) {
      final normalized = p.normalize(directory.path);
      if (!seen.add(normalized)) {
        continue;
      }
      final python = _venvPython(directory);
      if (python.existsSync()) {
        return _PythonLaunch(python.path, const ['-u']);
      }
    }
    return null;
  }

  Iterable<Directory> _ancestorVenvDirectories(Directory start) sync* {
    var cursor = start;
    for (var index = 0; index < 10; index++) {
      yield Directory(p.join(cursor.path, '.venv-tiktok'));
      final parent = cursor.parent;
      if (parent.path == cursor.path) {
        break;
      }
      cursor = parent;
    }
  }

  Future<_PythonLaunch?> _resolveSystemPython() async {
    final candidates = Platform.isWindows
        ? [
            const _PythonLaunch('py', ['-3', '-u']),
            const _PythonLaunch('python', ['-u']),
            const _PythonLaunch('python3', ['-u']),
          ]
        : [
            const _PythonLaunch('python3', ['-u']),
            const _PythonLaunch('python', ['-u']),
          ];

    for (final candidate in candidates) {
      if (await _canRunPython(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  Future<_PythonLaunch> _ensureAppVenv(_PythonLaunch systemPython) async {
    final directory = await _appVenvDirectory();
    final python = _venvPython(directory);
    if (python.existsSync()) {
      return _PythonLaunch(python.path, const ['-u']);
    }

    _emit(
      const TikTokLiveBridgeEvent(
        type: 'status',
        status: TikTokLiveBridgeStatus.connecting,
        message: 'Creando entorno virtual para TikTok LIVE...',
      ),
    );
    await directory.parent.create(recursive: true);
    final args = [
      ...systemPython.args.where((arg) => arg != '-u'),
      '-m',
      'venv',
      directory.path,
    ];
    final result = await Process.run(
      systemPython.executable,
      args,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    if (result.exitCode != 0 || !python.existsSync()) {
      throw ProcessException(
        systemPython.executable,
        args,
        _processOutput(result),
        result.exitCode,
      );
    }
    return _PythonLaunch(python.path, const ['-u']);
  }

  Future<Directory> _appVenvDirectory() async {
    try {
      final support = await getApplicationSupportDirectory();
      return Directory(p.join(support.path, 'tiktok-live-python'));
    } catch (_) {
      return Directory(p.join(Directory.current.path, '.venv-tiktok'));
    }
  }

  File _venvPython(Directory directory) {
    return File(
      Platform.isWindows
          ? p.join(directory.path, 'Scripts', 'python.exe')
          : p.join(directory.path, 'bin', 'python'),
    );
  }

  Future<bool> _canRunPython(_PythonLaunch candidate) async {
    try {
      final result = await Process.run(candidate.executable, [
        ...candidate.args.where((arg) => arg != '-u'),
        '-c',
        'import sys; assert sys.version_info >= (3, 9)',
      ]).timeout(const Duration(seconds: 4));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _hasTikTokLive(_PythonLaunch python) async {
    try {
      final result = await Process.run(
        python.executable,
        [...python.args.where((arg) => arg != '-u'), '-c', 'import TikTokLive'],
        stdoutEncoding: const Utf8Codec(allowMalformed: true),
        stderrEncoding: const Utf8Codec(allowMalformed: true),
      ).timeout(const Duration(seconds: 8));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _installBridgeRequirements(
    _PythonLaunch python,
    File script,
  ) async {
    final requirements = File(
      p.join(script.parent.path, 'requirements-tiktok.txt'),
    );
    _emit(
      const TikTokLiveBridgeEvent(
        type: 'status',
        status: TikTokLiveBridgeStatus.connecting,
        message: 'Instalando TikTokLive en el entorno virtual...',
      ),
    );

    final args = [
      ...python.args.where((arg) => arg != '-u'),
      '-m',
      'pip',
      'install',
      if (requirements.existsSync()) ...[
        '-r',
        requirements.path,
      ] else
        'TikTokLive',
    ];
    final result = await Process.run(
      python.executable,
      args,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        python.executable,
        args,
        _processOutput(result),
        result.exitCode,
      );
    }
  }

  String _processOutput(ProcessResult result) {
    final stderr = result.stderr?.toString().trim() ?? '';
    if (stderr.isNotEmpty) {
      return stderr;
    }
    final stdout = result.stdout?.toString().trim() ?? '';
    return stdout.isEmpty ? 'El proceso no devolvio detalles.' : stdout;
  }

  void _emit(TikTokLiveBridgeEvent event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }
}

class _BridgeLaunch {
  const _BridgeLaunch(this.executable, this.args);

  final String executable;
  final List<String> args;
}

class _PythonLaunch {
  const _PythonLaunch(this.executable, this.args);

  final String executable;
  final List<String> args;
}

String normalizeCreatorInput(String value) {
  var text = value.trim();
  if (text.isEmpty) {
    return '';
  }

  final liveUrlMatch = RegExp(
    r'tiktok\.com/@([^/?#\s]+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (liveUrlMatch != null) {
    text = liveUrlMatch.group(1) ?? '';
  }

  text = text.trim();
  if (text.startsWith('@')) {
    text = text.substring(1);
  }
  text = text.split('?').first.split('#').first.split('/').first.trim();
  return text.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
}
