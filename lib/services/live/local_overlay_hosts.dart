import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const localLiveOverlayHost = 'overlay.bstreammusic.test';
const localLiveOverlayIpv4 = '127.0.0.1';
const localLiveOverlayPort = 80;
const localLiveOverlayPath = '/overlay';
const localLiveOverlayUrl = 'http://overlay.bstreammusic.test/overlay';
const localOverlayHostsCommandTimeout = Duration(seconds: 30);

const _localOverlayHostsProcessCleanupTimeout = Duration(seconds: 2);
const _windowsMaximumCommandLineLength = 32767;
const _windowsCommandLineSafetyMargin = 512;
const _windowsOperationCancelledExitCode = 1223;
const _powerShellPolicyBlockedExitCode = 125;

const _ownedBlockBegin = '# BEGIN BStream Music LIVE Overlay';
const _ownedBlockEnd = '# END BStream Music LIVE Overlay';

/// Ensures that the stable LIVE overlay hostname resolves to IPv4 loopback.
abstract interface class LocalOverlayHostProvisioner {
  Future<void> ensureConfigured();
}

/// Injectable process boundary for the non-elevated PowerShell launcher.
abstract interface class LocalOverlayHostsCommandRunner {
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = localOverlayHostsCommandTimeout,
  });
}

/// Small process boundary that keeps timeout and cleanup behavior testable
/// without spawning PowerShell or showing UAC in unit tests.
abstract interface class LocalOverlayHostsProcess {
  int get pid;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;

  Future<void> closeStandardInput();
  bool kill();
}

typedef LocalOverlayHostsProcessStarter =
    Future<LocalOverlayHostsProcess> Function(
      String executable,
      List<String> arguments,
    );

final class LocalOverlayHostsCommandTimeoutException implements Exception {
  const LocalOverlayHostsCommandTimeoutException({
    required this.timeout,
    this.pid,
  });

  final Duration timeout;
  final int? pid;

  @override
  String toString() {
    final process = pid == null ? '' : ' (process $pid)';
    return 'The local overlay Windows command$process did not complete '
        'within ${timeout.inSeconds} seconds.';
  }
}

final class LocalOverlayHostsCommandLineException implements Exception {
  const LocalOverlayHostsCommandLineException(this.estimatedLength);

  final int estimatedLength;

  @override
  String toString() =>
      'The local overlay Windows command is too long '
      '($estimatedLength UTF-16 code units).';
}

final class SystemLocalOverlayHostsCommandRunner
    implements LocalOverlayHostsCommandRunner {
  const SystemLocalOverlayHostsCommandRunner({this.processStarter});

  final LocalOverlayHostsProcessStarter? processStarter;

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = localOverlayHostsCommandTimeout,
  }) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    _validateWindowsCommandLine(executable, arguments);

    final deadline = _LocalOverlayHostsCommandDeadline(timeout);
    final starter = processStarter ?? _startSystemProcess;
    final startFuture = starter(executable, arguments);
    LocalOverlayHostsProcess process;
    try {
      process = await deadline.wait(startFuture);
    } on LocalOverlayHostsCommandTimeoutException {
      // Process.start normally returns immediately. If Windows itself stalls,
      // terminate a process that materializes after our caller has timed out.
      unawaited(
        startFuture.then<void>(
          _terminateLateProcess,
          onError: (Object _, StackTrace _) {},
        ),
      );
      rethrow;
    }

    final stdoutCollector = _LocalOverlayHostsOutputCollector(process.stdout);
    final stderrCollector = _LocalOverlayHostsOutputCollector(process.stderr);
    var exited = false;
    try {
      final inputClosed = process.closeStandardInput();
      final exitCode = await deadline.wait(process.exitCode, pid: process.pid);
      exited = true;
      await deadline.wait(inputClosed, pid: process.pid);
      await deadline.wait(stdoutCollector.done, pid: process.pid);
      await deadline.wait(stderrCollector.done, pid: process.pid);
      return ProcessResult(
        process.pid,
        exitCode,
        systemEncoding.decode(stdoutCollector.bytes),
        systemEncoding.decode(stderrCollector.bytes),
      );
    } on LocalOverlayHostsCommandTimeoutException {
      await _terminateProcess(
        process,
        stdoutCollector: stdoutCollector,
        stderrCollector: stderrCollector,
      );
      rethrow;
    } on Object {
      if (!exited) {
        await _terminateProcess(
          process,
          stdoutCollector: stdoutCollector,
          stderrCollector: stderrCollector,
        );
      } else {
        await stdoutCollector.cancel();
        await stderrCollector.cancel();
      }
      rethrow;
    }
  }

  static Future<LocalOverlayHostsProcess> _startSystemProcess(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      runInShell: false,
    );
    return _SystemLocalOverlayHostsProcess(process);
  }

  static void _validateWindowsCommandLine(
    String executable,
    List<String> arguments,
  ) {
    var estimatedLength = _quotedWindowsArgumentLength(executable);
    for (final argument in arguments) {
      estimatedLength += 1 + _quotedWindowsArgumentLength(argument);
    }
    if (estimatedLength >=
        _windowsMaximumCommandLineLength - _windowsCommandLineSafetyMargin) {
      throw LocalOverlayHostsCommandLineException(estimatedLength);
    }
  }

  /// Mirrors the quoting growth used by Windows command-line construction.
  /// This is intentionally conservative because CreateProcess counts UTF-16
  /// code units, including quoting and the terminating null character.
  static int _quotedWindowsArgumentLength(String value) {
    if (value.isNotEmpty && !value.contains(RegExp(r'[\s"]'))) {
      return value.length;
    }

    var length = 2; // Opening and closing quotes.
    var pendingBackslashes = 0;
    for (final codeUnit in value.codeUnits) {
      if (codeUnit == 0x5C) {
        pendingBackslashes++;
        continue;
      }
      if (codeUnit == 0x22) {
        length += (pendingBackslashes * 2) + 2;
      } else {
        length += pendingBackslashes + 1;
      }
      pendingBackslashes = 0;
    }
    return length + (pendingBackslashes * 2);
  }

  static Future<void> _terminateLateProcess(
    LocalOverlayHostsProcess process,
  ) async {
    try {
      process.kill();
    } on Object {
      // The process may already have exited before the delayed start resolves.
    }
    try {
      await process.closeStandardInput().timeout(
        _localOverlayHostsProcessCleanupTimeout,
      );
    } on Object {
      // Cleanup is best-effort and must never extend the public timeout.
    }
  }

  static Future<void> _terminateProcess(
    LocalOverlayHostsProcess process, {
    required _LocalOverlayHostsOutputCollector stdoutCollector,
    required _LocalOverlayHostsOutputCollector stderrCollector,
  }) async {
    try {
      process.kill();
    } on Object {
      // The command may have exited at the same instant the timer fired.
    }
    try {
      await process.closeStandardInput().timeout(
        _localOverlayHostsProcessCleanupTimeout,
      );
    } on Object {
      // Closing a pipe after termination can legitimately fail on Windows.
    }
    try {
      await process.exitCode.timeout(_localOverlayHostsProcessCleanupTimeout);
    } on Object {
      // Do not turn cleanup of an unresponsive process into another hang.
    }
    await Future.wait<void>(<Future<void>>[
      stdoutCollector.cancel(),
      stderrCollector.cancel(),
    ]).timeout(
      _localOverlayHostsProcessCleanupTimeout,
      onTimeout: () => <void>[],
    );
  }
}

final class _SystemLocalOverlayHostsProcess
    implements LocalOverlayHostsProcess {
  const _SystemLocalOverlayHostsProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  Future<void> closeStandardInput() => _process.stdin.close();

  @override
  bool kill() => _process.kill();
}

final class _LocalOverlayHostsOutputCollector {
  _LocalOverlayHostsOutputCollector(Stream<List<int>> stream) {
    _subscription = stream.listen(
      _bytes.add,
      onError: _done.completeError,
      onDone: _done.complete,
      cancelOnError: true,
    );
  }

  final BytesBuilder _bytes = BytesBuilder(copy: false);
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;

  Future<void> get done => _done.future;
  Uint8List get bytes => _bytes.toBytes();

  Future<void> cancel() async {
    if (!_done.isCompleted) _done.complete();
    await _subscription.cancel();
  }
}

final class _LocalOverlayHostsCommandDeadline {
  _LocalOverlayHostsCommandDeadline(this.timeout)
    : _watch = Stopwatch()..start();

  final Duration timeout;
  final Stopwatch _watch;

  Future<T> wait<T>(Future<T> operation, {int? pid}) async {
    final remaining = timeout - _watch.elapsed;
    if (remaining <= Duration.zero) {
      throw LocalOverlayHostsCommandTimeoutException(
        timeout: timeout,
        pid: pid,
      );
    }
    try {
      return await operation.timeout(remaining);
    } on TimeoutException {
      throw LocalOverlayHostsCommandTimeoutException(
        timeout: timeout,
        pid: pid,
      );
    }
  }
}

typedef LocalOverlayHostsReader = Future<String> Function(String path);
typedef LocalOverlayHostsPathProvider = String Function();

enum LocalOverlayHostStatus { configured, missing, conflicting, malformed }

final class LocalOverlayHostInspection {
  const LocalOverlayHostInspection({
    required this.status,
    this.isOwned = false,
    this.mappedAddresses = const <String>[],
  });

  final LocalOverlayHostStatus status;
  final bool isOwned;
  final List<String> mappedAddresses;

  bool get isConfigured => status == LocalOverlayHostStatus.configured;
}

class LocalOverlayHostsException implements Exception {
  const LocalOverlayHostsException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() {
    final suffix = cause == null ? '' : ': $cause';
    return 'LocalOverlayHostsException: $message$suffix';
  }
}

final class LocalOverlayHostsConflictException
    extends LocalOverlayHostsException {
  const LocalOverlayHostsConflictException(super.message);
}

final class LocalOverlayHostsElevationException
    extends LocalOverlayHostsException {
  const LocalOverlayHostsElevationException(super.message, [super.cause]);
}

final class LocalOverlayHostsElevationCancelledException
    extends LocalOverlayHostsElevationException {
  const LocalOverlayHostsElevationCancelledException(super.message);
}

final class LocalOverlayHostsPowerShellUnavailableException
    extends LocalOverlayHostsElevationException {
  const LocalOverlayHostsPowerShellUnavailableException(super.message);
}

final class LocalOverlayHostsPolicyException
    extends LocalOverlayHostsElevationException {
  const LocalOverlayHostsPolicyException(super.message, [super.cause]);
}

final class LocalOverlayHostsTimeoutException
    extends LocalOverlayHostsElevationException {
  const LocalOverlayHostsTimeoutException(super.message, [super.cause]);
}

final class LocalOverlayHostsVerificationException
    extends LocalOverlayHostsException {
  const LocalOverlayHostsVerificationException(super.message);
}

/// Adds an owned entry to the Windows hosts file through one narrowly scoped
/// elevated PowerShell child process.
///
/// Inspection is always performed without elevation. An already-correct entry,
/// including one managed by the user or another tool, is accepted unchanged.
final class WindowsLocalOverlayHostProvisioner
    implements LocalOverlayHostProvisioner {
  WindowsLocalOverlayHostProvisioner({
    this.commandRunner = const SystemLocalOverlayHostsCommandRunner(),
    LocalOverlayHostsReader? hostsReader,
    LocalOverlayHostsPathProvider? hostsPathProvider,
    this.powerShellExecutable,
    this.commandTimeout = localOverlayHostsCommandTimeout,
    bool? isWindows,
  }) : _hostsReader = hostsReader ?? _readHostsFile,
       _hostsPathProvider = hostsPathProvider ?? _defaultHostsPath,
       _isWindows = isWindows ?? Platform.isWindows {
    if (commandTimeout <= Duration.zero) {
      throw ArgumentError.value(
        commandTimeout,
        'commandTimeout',
        'must be positive',
      );
    }
  }

  final LocalOverlayHostsCommandRunner commandRunner;
  final String? powerShellExecutable;
  final Duration commandTimeout;
  final LocalOverlayHostsReader _hostsReader;
  final LocalOverlayHostsPathProvider _hostsPathProvider;
  final bool _isWindows;

  Future<void>? _configuring;

  /// Reads and classifies the current mapping without requesting elevation.
  Future<LocalOverlayHostInspection> inspect() async {
    _ensureWindows();
    final path = _validatedAbsoluteWindowsPath(
      _hostsPathProvider(),
      parameterName: 'hostsPath',
    );
    return _inspectPath(path);
  }

  @override
  Future<void> ensureConfigured() {
    _ensureWindows();
    final pending = _configuring;
    if (pending != null) return pending;

    late final Future<void> operation;
    operation = _ensureConfiguredInternal().whenComplete(() {
      if (identical(_configuring, operation)) _configuring = null;
    });
    _configuring = operation;
    return operation;
  }

  Future<void> _ensureConfiguredInternal() async {
    final hostsPath = _validatedAbsoluteWindowsPath(
      _hostsPathProvider(),
      parameterName: 'hostsPath',
    );
    final before = await _inspectPath(hostsPath);
    if (before.isConfigured) return;
    _throwForUnsafeInspection(before);

    final executable = _validatedAbsoluteWindowsPath(
      powerShellExecutable ?? _defaultPowerShellExecutable(),
      parameterName: 'powerShellExecutable',
    );
    if (powerShellExecutable == null && !await File(executable).exists()) {
      throw const LocalOverlayHostsPowerShellUnavailableException(
        'Windows PowerShell 5.1 is unavailable, so BStream cannot request the '
        'narrow administrative permission required for the LIVE overlay hostname.',
      );
    }
    final innerScript = _buildElevatedHostsScript(hostsPath);
    final outerScript = _buildElevationLauncher(
      encodedInnerScript: _encodePowerShell(innerScript),
      elevatedProcessTimeout: _elevatedProcessTimeout(commandTimeout),
    );

    ProcessResult result;
    try {
      result = await commandRunner.run(executable, <String>[
        '-NoLogo',
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        outerScript,
      ], timeout: commandTimeout);
    } on LocalOverlayHostsCommandTimeoutException catch (error) {
      throw LocalOverlayHostsTimeoutException(
        'Windows did not complete the LIVE overlay hostname permission '
        'request within ${_describeDuration(commandTimeout)}.',
        error,
      );
    } on Object catch (error) {
      throw LocalOverlayHostsElevationException(
        'Windows could not request permission to configure the LIVE overlay hostname.',
        error,
      );
    }

    if (result.exitCode != 0) {
      if (result.exitCode == _windowsOperationCancelledExitCode) {
        throw const LocalOverlayHostsElevationCancelledException(
          'The Windows administrator permission request was cancelled.',
        );
      }
      if (result.exitCode == _powerShellPolicyBlockedExitCode) {
        throw const LocalOverlayHostsPolicyException(
          'A Windows application-control policy blocked the restricted '
          'PowerShell operation required to configure the LIVE overlay hostname.',
        );
      }
      final details = _boundedProcessDetails(result);
      throw LocalOverlayHostsElevationException(
        details.isEmpty
            ? 'Windows did not authorize the LIVE overlay hostname change '
                  '(exit ${result.exitCode}).'
            : 'Windows did not configure the LIVE overlay hostname '
                  '(exit ${result.exitCode}): $details',
      );
    }

    final after = await _inspectPath(hostsPath);
    if (after.isConfigured) return;
    _throwForUnsafeInspection(after);
    throw const LocalOverlayHostsVerificationException(
      'Windows reported success, but the LIVE overlay hostname is still missing.',
    );
  }

  Future<LocalOverlayHostInspection> _inspectPath(String path) async {
    final contents = await _hostsReader(path);
    return inspectLocalOverlayHosts(contents);
  }

  void _ensureWindows() {
    if (!_isWindows) {
      throw UnsupportedError(
        'The local LIVE overlay hostname is supported on Windows only.',
      );
    }
  }

  static void _throwForUnsafeInspection(LocalOverlayHostInspection value) {
    if (value.status == LocalOverlayHostStatus.conflicting) {
      throw LocalOverlayHostsConflictException(
        '$localLiveOverlayHost already points to '
        '${value.mappedAddresses.join(', ')}. BStream will not overwrite it.',
      );
    }
    if (value.status == LocalOverlayHostStatus.malformed) {
      throw const LocalOverlayHostsConflictException(
        'The BStream marker block in the Windows hosts file is incomplete or malformed.',
      );
    }
  }

  static String _boundedProcessDetails(ProcessResult result) {
    final stderr = result.stderr.toString().trim();
    final stdout = result.stdout.toString().trim();
    final value = stderr.isNotEmpty ? stderr : stdout;
    if (value.length <= 800) return value;
    return '${value.substring(0, 800)}…';
  }

  static Future<String> _readHostsFile(String path) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.length >= 4 &&
        ((bytes[0] == 0xFF &&
                bytes[1] == 0xFE &&
                bytes[2] == 0x00 &&
                bytes[3] == 0x00) ||
            (bytes[0] == 0x00 &&
                bytes[1] == 0x00 &&
                bytes[2] == 0xFE &&
                bytes[3] == 0xFF))) {
      throw const LocalOverlayHostsException(
        'BStream will not modify a UTF-32 Windows hosts file.',
      );
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3));
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes, littleEndian: true, offset: 2);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes, littleEndian: false, offset: 2);
    }
    if (bytes.contains(0)) {
      throw const LocalOverlayHostsException(
        'The Windows hosts file uses an ambiguous encoding.',
      );
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // Mapping tokens are ASCII; latin1 keeps them inspectable even when an
      // old hosts file contains comments in the active Windows code page.
      return latin1.decode(bytes);
    }
  }

  static String _decodeUtf16(
    List<int> bytes, {
    required bool littleEndian,
    required int offset,
  }) {
    final codeUnits = <int>[];
    for (var index = offset; index + 1 < bytes.length; index += 2) {
      final first = bytes[index];
      final second = bytes[index + 1];
      codeUnits.add(
        littleEndian ? first | (second << 8) : (first << 8) | second,
      );
    }
    return String.fromCharCodes(codeUnits);
  }

  static String _defaultHostsPath() {
    final root = _validatedSystemRoot();
    return '$root\\System32\\drivers\\etc\\hosts';
  }

  static String _defaultPowerShellExecutable() {
    final root = _validatedSystemRoot();
    return '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  }

  static String _validatedSystemRoot() {
    final value =
        Platform.environment['SystemRoot'] ?? Platform.environment['WINDIR'];
    if (value == null) {
      throw const LocalOverlayHostsException(
        'Windows did not provide SystemRoot.',
      );
    }
    return _validatedAbsoluteWindowsPath(
      value.replaceFirst(RegExp(r'[\\/]+$'), ''),
      parameterName: 'SystemRoot',
    );
  }

  static String _validatedAbsoluteWindowsPath(
    String value, {
    required String parameterName,
  }) {
    final normalized = value.trim();
    if (!RegExp(r'^[A-Za-z]:[\\/]').hasMatch(normalized) ||
        normalized.length > 1024 ||
        normalized.contains(RegExp(r'[\x00-\x1F]'))) {
      throw LocalOverlayHostsException(
        '$parameterName must be an absolute, bounded Windows path.',
      );
    }
    return normalized;
  }

  static Duration _elevatedProcessTimeout(Duration totalTimeout) {
    final milliseconds = totalTimeout.inMilliseconds - 5000;
    return Duration(milliseconds: milliseconds < 1000 ? 1000 : milliseconds);
  }

  static String _describeDuration(Duration value) {
    if (value.inMilliseconds >= 1000 &&
        value.inMilliseconds.remainder(1000) == 0) {
      return '${value.inSeconds} seconds';
    }
    return '${value.inMilliseconds} milliseconds';
  }

  static String _buildElevationLauncher({
    required String encodedInnerScript,
    required Duration elevatedProcessTimeout,
  }) {
    return r'''
$ErrorActionPreference = 'Stop'
$powerShell = Join-Path $PSHOME 'powershell.exe'
$innerCommand = {{INNER_COMMAND}}
$timeoutMilliseconds = {{TIMEOUT_MILLISECONDS}}
$arguments = @(
  '-NoLogo',
  '-NoProfile',
  '-WindowStyle', 'Hidden',
  '-NonInteractive',
  '-ExecutionPolicy', 'Bypass',
  '-EncodedCommand', $innerCommand
)
try {
  $process = Start-Process `
    -FilePath $powerShell `
    -Verb RunAs `
    -WindowStyle Hidden `
    -ArgumentList $arguments `
    -PassThru
}
catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  $nativeCode = $_.Exception.NativeErrorCode
  if ($null -eq $nativeCode -and $null -ne $_.Exception.InnerException) {
    $nativeCode = $_.Exception.InnerException.NativeErrorCode
  }
  if ($nativeCode -eq 1223) { exit 1223 }
  exit 1
}
if ($null -eq $process) {
  [Console]::Error.WriteLine('Windows did not create the elevated process.')
  exit 1
}
$completed = $process.WaitForExit($timeoutMilliseconds)
if (-not $completed) {
  try { $process.Kill() } catch { }
  [Console]::Error.WriteLine(
    'The elevated LIVE overlay hostname process timed out.'
  )
  exit 124
}
$process.WaitForExit()
exit $process.ExitCode
'''
        .replaceAll('{{INNER_COMMAND}}', _powerShellLiteral(encodedInnerScript))
        .replaceAll(
          '{{TIMEOUT_MILLISECONDS}}',
          elevatedProcessTimeout.inMilliseconds.toString(),
        );
  }

  static String _buildElevatedHostsScript(String hostsPath) {
    return r'''
$ErrorActionPreference = 'Stop'
$hostsPath = {{HOSTS_PATH}}
$hostName = {{HOST_NAME}}
$loopback = {{LOOPBACK}}
$beginMarker = {{BEGIN_MARKER}}
$endMarker = {{END_MARKER}}
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
  exit 125
}
$mutex = New-Object System.Threading.Mutex($false, 'Local\BStreamMusic.LiveOverlay.Hosts.v1')
$lockTaken = $false

function Get-BStreamEncoding([byte[]]$bytes) {
  if ($bytes.Length -ge 4 -and
      (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and
        $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) -or
       ($bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and
        $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF))) {
    throw 'BStream will not modify a UTF-32 Windows hosts file.'
  }
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
      $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    return @((New-Object System.Text.UTF8Encoding($true, $true)), 3)
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    return @([System.Text.Encoding]::Unicode, 2)
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    return @([System.Text.Encoding]::BigEndianUnicode, 2)
  }
  if ($bytes -contains 0x00) {
    throw 'The Windows hosts file uses an ambiguous encoding.'
  }
  try {
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    [void]$strictUtf8.GetString($bytes)
    return @($strictUtf8, 0)
  }
  catch {
    return @([System.Text.Encoding]::Default, 0)
  }
}

function Get-BStreamMappings([string]$content) {
  $result = @()
  foreach ($line in [System.Text.RegularExpressions.Regex]::Split($content, "`r`n|`n|`r")) {
    $active = ($line -split '#', 2)[0].Trim()
    if ([string]::IsNullOrWhiteSpace($active)) { continue }
    $parts = [System.Text.RegularExpressions.Regex]::Split($active, '\s+')
    if ($parts.Count -lt 2) { continue }
    for ($index = 1; $index -lt $parts.Count; $index++) {
      if ($parts[$index].TrimEnd('.').Equals(
          $hostName, [System.StringComparison]::OrdinalIgnoreCase)) {
        $result += $parts[0]
      }
    }
  }
  return @($result)
}

function Invoke-BStreamFlushDns {
  # The hosts entry is the durable postcondition. Some managed PCs block the
  # cache flush even though name resolution observes hosts changes correctly,
  # so flushing is an optimization and must not roll back a valid mapping.
  try {
    $ipconfig = Join-Path $env:SystemRoot 'System32\ipconfig.exe'
    & $ipconfig /flushdns 2>$null | Out-Null
  }
  catch { }
}

try {
  $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
  if (-not $lockTaken) { throw 'Timed out waiting to update the Windows hosts file.' }
  if (-not (Test-Path -LiteralPath $hostsPath -PathType Leaf)) {
    throw 'The Windows hosts file does not exist.'
  }

  [byte[]]$originalBytes = [System.IO.File]::ReadAllBytes($hostsPath)
  $encodingInfo = Get-BStreamEncoding $originalBytes
  $encoding = $encodingInfo[0]
  [int]$preambleLength = $encodingInfo[1]
  $content = $encoding.GetString(
    $originalBytes,
    $preambleLength,
    $originalBytes.Length - $preambleLength
  )
  $mappings = @(Get-BStreamMappings $content)
  $conflicts = @($mappings | Where-Object { $_ -ne $loopback })
  if ($conflicts.Count -gt 0) {
    throw "$hostName already maps to $($conflicts -join ', ')."
  }

  if ($mappings -notcontains $loopback) {
    $markerLines = @([System.Text.RegularExpressions.Regex]::Split(
      $content, "`r`n|`n|`r") | ForEach-Object { $_.Trim() })
    if ($markerLines -contains $beginMarker -or $markerLines -contains $endMarker) {
      throw 'The existing BStream hosts marker block is malformed.'
    }

    $newLine = if ($content.Contains("`r`n")) {
      "`r`n"
    } elseif ($content.Contains("`n")) {
      "`n"
    } elseif ($content.Contains("`r")) {
      "`r"
    } else {
      "`r`n"
    }
    $separator = if ([string]::IsNullOrEmpty($content) -or
        $content.EndsWith("`r") -or $content.EndsWith("`n")) { '' } else { $newLine }
    $block = $beginMarker + $newLine + $loopback + "`t" + $hostName +
      $newLine + $endMarker + $newLine
    [byte[]]$suffixBytes = $encoding.GetBytes($separator + $block)
    [byte[]]$updatedBytes = New-Object byte[] ($originalBytes.Length + $suffixBytes.Length)
    [System.Array]::Copy($originalBytes, 0, $updatedBytes, 0, $originalBytes.Length)
    [System.Array]::Copy(
      $suffixBytes, 0, $updatedBytes, $originalBytes.Length, $suffixBytes.Length)

    $directory = [System.IO.Path]::GetDirectoryName($hostsPath)
    $nonce = [Guid]::NewGuid().ToString('N')
    $temporary = [System.IO.Path]::Combine($directory, "hosts.bstream.$nonce.tmp")
    $backup = [System.IO.Path]::Combine($directory, "hosts.bstream.$nonce.bak")
    try {
      [System.IO.File]::WriteAllBytes($temporary, $updatedBytes)
      $acl = Get-Acl -LiteralPath $hostsPath
      Set-Acl -LiteralPath $temporary -AclObject $acl

      [byte[]]$currentBytes = [System.IO.File]::ReadAllBytes($hostsPath)
      $expectedHash = [Convert]::ToBase64String(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($originalBytes))
      $updatedHash = [Convert]::ToBase64String(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($updatedBytes))
      $currentHash = [Convert]::ToBase64String(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash($currentBytes))
      if ($currentHash -ne $expectedHash) {
        throw 'The Windows hosts file changed while BStream was preparing it.'
      }

      [System.IO.File]::Replace($temporary, $hostsPath, $backup, $true)
      $temporary = $null
      [byte[]]$verifiedBytes = [System.IO.File]::ReadAllBytes($hostsPath)
      $verifiedEncodingInfo = Get-BStreamEncoding $verifiedBytes
      $verifiedEncoding = $verifiedEncodingInfo[0]
      [int]$verifiedPreambleLength = $verifiedEncodingInfo[1]
      $verifiedContent = $verifiedEncoding.GetString(
        $verifiedBytes,
        $verifiedPreambleLength,
        $verifiedBytes.Length - $verifiedPreambleLength
      )
      $verified = @(Get-BStreamMappings $verifiedContent)
      if ($verified -notcontains $loopback -or
          @($verified | Where-Object { $_ -ne $loopback }).Count -gt 0) {
        throw 'The LIVE overlay hostname could not be verified after writing.'
      }
      Invoke-BStreamFlushDns
    }
    catch {
      $operationError = $_
      if (Test-Path -LiteralPath $backup -PathType Leaf) {
        [byte[]]$failedBytes = [System.IO.File]::ReadAllBytes($hostsPath)
        $failedHash = [Convert]::ToBase64String(
          [System.Security.Cryptography.SHA256]::Create().ComputeHash($failedBytes))
        if ($failedHash -eq $updatedHash) {
          Copy-Item -LiteralPath $backup -Destination $hostsPath -Force
        }
      }
      Invoke-BStreamFlushDns
      throw $operationError
    }
    finally {
      if ($null -ne $temporary) {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
      }
      Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
  }
  else {
    Invoke-BStreamFlushDns
  }
}
finally {
  if ($lockTaken) { [void]$mutex.ReleaseMutex() }
  $mutex.Dispose()
}
'''
        .replaceAll('{{HOSTS_PATH}}', _powerShellLiteral(hostsPath))
        .replaceAll('{{HOST_NAME}}', _powerShellLiteral(localLiveOverlayHost))
        .replaceAll('{{LOOPBACK}}', _powerShellLiteral(localLiveOverlayIpv4))
        .replaceAll('{{BEGIN_MARKER}}', _powerShellLiteral(_ownedBlockBegin))
        .replaceAll('{{END_MARKER}}', _powerShellLiteral(_ownedBlockEnd));
  }

  static String _powerShellLiteral(String value) =>
      "'${value.replaceAll("'", "''")}'";

  static String _encodePowerShell(String script) {
    final bytes = BytesBuilder(copy: false);
    for (final codeUnit in script.codeUnits) {
      bytes.addByte(codeUnit & 0xFF);
      bytes.addByte((codeUnit >> 8) & 0xFF);
    }
    return base64Encode(bytes.takeBytes());
  }
}

LocalOverlayHostInspection inspectLocalOverlayHosts(String contents) {
  final lines = const LineSplitter().convert(
    contents.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
  );
  var beginIndex = -1;
  var endIndex = -1;
  var beginCount = 0;
  var endCount = 0;
  final mappings = <String>[];
  final mappingLines = <int>[];

  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final line = lines[lineIndex];
    final trimmed = line.trim();
    if (trimmed == _ownedBlockBegin) {
      beginCount++;
      beginIndex = lineIndex;
    } else if (trimmed == _ownedBlockEnd) {
      endCount++;
      endIndex = lineIndex;
    }

    final commentIndex = line.indexOf('#');
    final active = (commentIndex < 0 ? line : line.substring(0, commentIndex))
        .trim();
    if (active.isEmpty) continue;
    final parts = active.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    for (final candidate in parts.skip(1)) {
      final normalizedHost = candidate.toLowerCase().replaceFirst(
        RegExp(r'\.$'),
        '',
      );
      if (normalizedHost == localLiveOverlayHost) {
        mappings.add(parts.first);
        mappingLines.add(lineIndex);
      }
    }
  }

  final immutableMappings = List<String>.unmodifiable(mappings);
  if (mappings.any((address) => address != localLiveOverlayIpv4)) {
    return LocalOverlayHostInspection(
      status: LocalOverlayHostStatus.conflicting,
      mappedAddresses: immutableMappings,
    );
  }

  final hasMarkers = beginCount != 0 || endCount != 0;
  final hasValidOwnedBlock =
      beginCount == 1 &&
      endCount == 1 &&
      beginIndex < endIndex &&
      mappingLines.any(
        (lineIndex) => lineIndex > beginIndex && lineIndex < endIndex,
      );
  if (hasMarkers && !hasValidOwnedBlock) {
    return LocalOverlayHostInspection(
      status: LocalOverlayHostStatus.malformed,
      mappedAddresses: immutableMappings,
    );
  }

  if (mappings.contains(localLiveOverlayIpv4)) {
    return LocalOverlayHostInspection(
      status: LocalOverlayHostStatus.configured,
      isOwned: hasValidOwnedBlock,
      mappedAddresses: immutableMappings,
    );
  }

  return const LocalOverlayHostInspection(
    status: LocalOverlayHostStatus.missing,
  );
}
