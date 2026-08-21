import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'base_ejs_solver.dart';
import 'ejs.dart';

class DenoEJSSolver extends BaseEJSSolver {
  final _DenoProcess _deno;

  DenoEJSSolver._(this._deno);

  static Future<DenoEJSSolver> init({
    String? denoExe,
    Duration evalTimeout = const Duration(seconds: 15),
  }) async {
    final modules = await EJSBuilder.getJSModules();
    final deno = await _DenoProcess.init(
      initCode: modules,
      denoExe: denoExe,
      evalTimeout: evalTimeout,
    );
    return DenoEJSSolver._(deno);
  }

  @override
  Future<String> executeJavaScript(String jsCode) async {
    final filePath = path.join(
      _deno.tmpDir.path,
      'ejs_output_${DateTime.now().microsecondsSinceEpoch}.txt',
    );

    // JSON encoding keeps Windows backslashes from becoming JS escapes.
    final wrappedCode =
        'await Deno.writeTextFile(${jsonEncode(filePath)}, $jsCode);';
    final result = await _deno.eval(wrappedCode);

    if (result != 'undefined') {
      throw Exception('Expected undefined result from Deno eval, got: $result');
    }

    final file = File(filePath);
    try {
      return await file.readAsString();
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    super.dispose();
    _deno.dispose();
  }
}

class _DenoProcess {
  static final _logger = Logger('YoutubeExplode.Deno.Process');

  final Process _process;
  final Directory tmpDir;
  final Duration evalTimeout;
  final Queue<_EvalRequest> _evalQueue = Queue<_EvalRequest>();

  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  _EvalRequest? _activeRequest;
  Timer? _evalTimer;
  String _stderr = '';
  bool _disposed = false;
  bool _terminal = false;

  _DenoProcess(this._process, this.tmpDir, this.evalTimeout) {
    _stdoutSubscription = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      _handleStdout,
      onDone: _handleProcessDone,
      onError: (Object error, StackTrace stackTrace) {
        _terminal = true;
        _failAll(error, stackTrace);
      },
    );
    _stderrSubscription = _process.stderr
        .transform(utf8.decoder)
        .listen(_handleStderr, onError: (_) {});
    unawaited(
      _process.exitCode.then((_) => _handleProcessDone()),
    );
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _evalTimer?.cancel();
    _failAll(StateError('Deno process disposed.'));
    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    _process.kill();
    unawaited(_deleteDirectory());
  }

  Future<String> eval(String code) {
    if (_disposed || _terminal) {
      return Future<String>.error(StateError('Deno process is unavailable.'));
    }
    final completer = Completer<String>();
    _evalQueue.addLast(_EvalRequest(code, completer));
    _processQueue();
    return completer.future;
  }

  void _processQueue() {
    if (_disposed ||
        _terminal ||
        _activeRequest != null ||
        _evalQueue.isEmpty) {
      return;
    }

    final request = _evalQueue.removeFirst();
    _activeRequest = request;
    try {
      _process.stdin.writeln(request.code);
      _evalTimer = Timer(evalTimeout, () {
        _terminal = true;
        _failAll(TimeoutException('Deno JavaScript evaluation timed out.'));
        _process.kill();
      });
    } catch (error, stackTrace) {
      _terminal = true;
      _failAll(error, stackTrace);
    }
  }

  void _handleStdout(String line) {
    if (line.trim().isEmpty) {
      return;
    }
    _completeActive(null, null, result: line.trim());
  }

  void _handleStderr(String chunk) {
    if (chunk.isEmpty) return;
    if (_stderr.length >= 2048) return;
    final remaining = 2048 - _stderr.length;
    _stderr += chunk.substring(0, min(chunk.length, remaining));
  }

  void _handleProcessDone() {
    if (_disposed || _terminal) {
      return;
    }
    _terminal = true;
    final detail = _stderr.trim();
    _failAll(
      StateError(
        detail.isEmpty
            ? 'Deno process closed while awaiting eval result.'
            : 'Deno process closed: $detail',
      ),
    );
  }

  void _completeActive(
    Object? error,
    StackTrace? stackTrace, {
    String? result,
  }) {
    final request = _activeRequest;
    if (request == null) {
      return;
    }
    _activeRequest = null;
    _evalTimer?.cancel();
    _evalTimer = null;
    if (error != null) {
      request.completer.completeError(error, stackTrace ?? StackTrace.current);
    } else {
      request.completer.complete(result!);
    }
    _processQueue();
  }

  void _failAll(Object error, [StackTrace? stackTrace]) {
    _completeActive(error, stackTrace);
    while (_evalQueue.isNotEmpty) {
      final request = _evalQueue.removeFirst();
      if (!request.completer.isCompleted) {
        request.completer
            .completeError(error, stackTrace ?? StackTrace.current);
      }
    }
  }

  Future<void> _deleteDirectory() async {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<_DenoProcess> init({
    required String initCode,
    String? denoExe,
    Duration evalTimeout = const Duration(seconds: 15),
  }) async {
    if (evalTimeout <= Duration.zero) {
      throw ArgumentError.value(
          evalTimeout, 'evalTimeout', 'Must be positive.');
    }

    final tmpDir = await Directory.systemTemp.createTemp('yt_deno_');
    final tmpFile = File(path.join(tmpDir.path, 'deno_init.js'));
    try {
      await tmpFile.writeAsString(initCode);
      final process = await Process.start(denoExe ?? 'deno', [
        'repl',
        '--quiet',
        '--no-lock',
        '--no-npm',
        '--no-remote',
        '--allow-write=${tmpDir.path}',
        '--eval-file=${tmpFile.path}',
      ], environment: {
        ...Platform.environment,
        'NO_COLOR': '1',
      });
      _logger.info(
        'Deno process started with PID: ${process.pid}, '
        'using tmpdir: ${tmpDir.path}',
      );
      return _DenoProcess(process, tmpDir, evalTimeout);
    } catch (_) {
      try {
        await tmpDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }
}

class _EvalRequest {
  final String code;
  final Completer<String> completer;

  _EvalRequest(this.code, this.completer);
}
