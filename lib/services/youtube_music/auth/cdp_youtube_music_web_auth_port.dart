import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'youtube_music_auth_models.dart';
import 'youtube_music_cookie_codec.dart';
import 'youtube_music_navigation_policy.dart';
import 'youtube_music_web_auth_port.dart';

enum DesktopOperatingSystem { linux, windows, unsupported }

/// Desktop-specific browser boundary consumed by the external login surface.
abstract interface class DesktopYouTubeMusicWebAuthPort
    implements YouTubeMusicWebAuthPort {
  YouTubeMusicNavigationPolicy get navigationPolicy;

  Stream<Uri> get navigationStream;

  Stream<void> get browserClosedStream;

  Uri? get currentUri;

  bool get isPrepared;

  Future<void> bringToForeground();

  Future<void> minimize();
}

class CdpEvent {
  const CdpEvent(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
}

abstract interface class CdpTargetConnection {
  String get targetId;

  Stream<CdpEvent> get events;

  Future<void> get closed;

  Future<Map<String, Object?>> send(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]);

  Future<void> close();
}

abstract interface class CdpTargetConnector {
  Future<CdpTargetConnection> connect({
    required Uri devToolsHttpEndpoint,
    required Duration timeout,
  });
}

abstract interface class CdpBrowserSession {
  Uri get devToolsHttpEndpoint;

  Future<void> get closed;

  Future<void> close();

  /// Deletes only the one temporary profile owned by this session.
  Future<bool> deleteTemporaryProfile();
}

abstract interface class CdpBrowserLauncher {
  Future<CdpBrowserSession> launch({
    required DesktopOperatingSystem operatingSystem,
    required Duration startupTimeout,
  });
}

typedef CdpFileExists = bool Function(String path);
typedef CdpProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

class ChromiumExecutableLocator {
  ChromiumExecutableLocator({
    required this.environment,
    required this.fileExists,
  });

  factory ChromiumExecutableLocator.system() => ChromiumExecutableLocator(
    environment: Platform.environment,
    fileExists: (value) => File(value).existsSync(),
  );

  final Map<String, String> environment;
  final CdpFileExists fileExists;

  String? locate(DesktopOperatingSystem operatingSystem) {
    for (final candidate in candidates(operatingSystem)) {
      if (fileExists(candidate)) return candidate;
    }
    return null;
  }

  List<String> candidates(DesktopOperatingSystem operatingSystem) {
    return switch (operatingSystem) {
      DesktopOperatingSystem.linux => _linuxCandidates(),
      DesktopOperatingSystem.windows => _windowsCandidates(),
      DesktopOperatingSystem.unsupported => const <String>[],
    };
  }

  List<String> _linuxCandidates() {
    const executableNames = <String>[
      'microsoft-edge-stable',
      'microsoft-edge',
      'google-chrome-stable',
      'google-chrome',
      'brave-browser',
      'brave',
      'chromium',
      'chromium-browser',
    ];
    const knownPaths = <String>[
      '/usr/bin/microsoft-edge-stable',
      '/usr/bin/microsoft-edge',
      '/usr/bin/google-chrome-stable',
      '/usr/bin/google-chrome',
      '/usr/bin/brave-browser',
      '/usr/bin/brave',
      '/usr/bin/chromium',
      '/usr/bin/chromium-browser',
      '/usr/local/bin/microsoft-edge',
      '/usr/local/bin/google-chrome',
      '/usr/local/bin/brave-browser',
      '/usr/local/bin/chromium',
      '/snap/bin/chromium',
    ];
    return _deduplicate(<String>[
      ...knownPaths,
      for (final directory in _pathDirectories(DesktopOperatingSystem.linux))
        for (final executable in executableNames)
          _join(directory, executable, DesktopOperatingSystem.linux),
    ]);
  }

  List<String> _windowsCandidates() {
    const relativePaths = <String>[
      r'Microsoft\Edge\Application\msedge.exe',
      r'Google\Chrome\Application\chrome.exe',
      r'BraveSoftware\Brave-Browser\Application\brave.exe',
      r'Chromium\Application\chrome.exe',
    ];
    const executableNames = <String>[
      'msedge.exe',
      'chrome.exe',
      'brave.exe',
      'chromium.exe',
    ];
    final installationRoots = <String?>[
      _environmentValue('PROGRAMFILES(X86)'),
      _environmentValue('PROGRAMFILES'),
      _environmentValue('LOCALAPPDATA'),
    ].whereType<String>();
    return _deduplicate(<String>[
      for (final root in installationRoots)
        for (final relativePath in relativePaths)
          _join(root, relativePath, DesktopOperatingSystem.windows),
      for (final directory in _pathDirectories(DesktopOperatingSystem.windows))
        for (final executable in executableNames)
          _join(directory, executable, DesktopOperatingSystem.windows),
    ]);
  }

  Iterable<String> _pathDirectories(DesktopOperatingSystem operatingSystem) {
    final value = _environmentValue('PATH');
    if (value == null || value.trim().isEmpty) return const <String>[];
    final separator = operatingSystem == DesktopOperatingSystem.windows
        ? ';'
        : ':';
    return value
        .split(separator)
        .map((part) => part.trim().replaceAll(RegExp(r'^"|"$'), ''))
        .where((part) => part.isNotEmpty);
  }

  String? _environmentValue(String name) {
    for (final entry in environment.entries) {
      if (entry.key.toUpperCase() == name.toUpperCase()) return entry.value;
    }
    return null;
  }

  static String _join(
    String parent,
    String child,
    DesktopOperatingSystem operatingSystem,
  ) {
    final separator = operatingSystem == DesktopOperatingSystem.windows
        ? r'\'
        : '/';
    return '${parent.replaceFirst(RegExp(r'[/\\]+$'), '')}$separator$child';
  }

  static List<String> _deduplicate(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      if (seen.add(value)) result.add(value);
    }
    return List<String>.unmodifiable(result);
  }
}

typedef CdpDebugPortProbe = Future<bool> Function(int port);
typedef CdpProcessProbe =
    bool Function(int processId, DesktopOperatingSystem operatingSystem);
typedef CdpProfileInUseProbe = Future<bool> Function(Directory profile);

/// Removes credential profiles left by a previous crashed BStream process.
///
/// A directory must have the exact prefix, marker and a non-active ownership
/// lock. Unmarked directories are never touched. PID and loopback-port probes
/// provide a second fail-safe before recursive deletion.
class CdpOrphanedProfileCollector {
  CdpOrphanedProfileCollector({
    Directory? temporaryRoot,
    CdpDebugPortProbe? debugPortProbe,
    CdpProcessProbe? processProbe,
    CdpProfileInUseProbe? profileInUseProbe,
  }) : temporaryRoot = (temporaryRoot ?? Directory.systemTemp).absolute,
       _debugPortProbe = debugPortProbe ?? _defaultDebugPortProbe,
       _processProbe = processProbe ?? _defaultProcessProbe,
       _profileInUseProbe = profileInUseProbe ?? _defaultProfileInUseProbe;

  static const profilePrefix = 'bstream_ytmusic_auth_';
  static const profileMarker = '.bstream-temporary-auth-profile';
  static const ownershipLock = '.bstream-auth-profile-owner.lock';

  final Directory temporaryRoot;
  final CdpDebugPortProbe _debugPortProbe;
  final CdpProcessProbe _processProbe;
  final CdpProfileInUseProbe _profileInUseProbe;

  static String markerDocument({
    required DateTime createdAt,
    int? processId,
    int? debugPort,
  }) => jsonEncode(<String, Object?>{
    'schema': 1,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'processId': ?processId,
    'debugPort': ?debugPort,
  });

  Future<int> collect(DesktopOperatingSystem operatingSystem) async {
    if (operatingSystem == DesktopOperatingSystem.unsupported ||
        !await temporaryRoot.exists()) {
      return 0;
    }
    var removed = 0;
    await for (final entity in temporaryRoot.list(followLinks: false)) {
      if (entity is! Directory || !_isOwnedCandidate(entity)) continue;
      final marker = File(
        '${entity.path}${Platform.pathSeparator}$profileMarker',
      );
      if (!await marker.exists()) continue;

      try {
        if (await _profileInUseProbe(entity)) continue;
        final metadata = await _readMarker(marker);
        final processId = _positiveInt(metadata?['processId']);
        final debugPort = _validPort(metadata?['debugPort']);
        if (processId != null && _processProbe(processId, operatingSystem)) {
          continue;
        }
        if (debugPort != null && await _debugPortProbe(debugPort)) continue;

        if (await _deleteOwnedProfile(
          profile: entity.absolute,
          expectedParent: temporaryRoot,
          prefix: profilePrefix,
          markerName: profileMarker,
        )) {
          removed += 1;
        }
      } on Object {
        // Recovery is best-effort and must not block a new isolated login.
      }
    }
    return removed;
  }

  bool _isOwnedCandidate(Directory directory) =>
      directory.parent.absolute.path == temporaryRoot.path &&
      directory.path.split(RegExp(r'[/\\]')).last.startsWith(profilePrefix);

  static Future<Map<String, Object?>?> _readMarker(File marker) async {
    try {
      final value = await marker.readAsString();
      return _objectMap(jsonDecode(value));
    } on Object {
      return null;
    }
  }

  static int? _positiveInt(Object? value) {
    if (value is! num) return null;
    final result = value.toInt();
    return result > 0 ? result : null;
  }

  static int? _validPort(Object? value) {
    final result = _positiveInt(value);
    return result != null && result <= 65535 ? result : null;
  }

  static bool _defaultProcessProbe(
    int processId,
    DesktopOperatingSystem operatingSystem,
  ) =>
      operatingSystem == DesktopOperatingSystem.linux &&
      Directory('/proc/$processId').existsSync();

  static Future<bool> _defaultProfileInUseProbe(Directory profile) async {
    RandomAccessFile? handle;
    var locked = false;
    try {
      handle = await File(
        '${profile.path}${Platform.pathSeparator}$ownershipLock',
      ).open(mode: FileMode.append);
      try {
        handle.lockSync(FileLock.exclusive);
        locked = true;
        return false;
      } on FileSystemException {
        return true;
      }
    } finally {
      if (handle != null) {
        if (locked) {
          try {
            handle.unlockSync();
          } on Object {
            // Continue closing the collector's probe handle.
          }
        }
        try {
          await handle.close();
        } on Object {
          // Recovery remains best-effort.
        }
      }
    }
  }

  static Future<bool> _defaultDebugPortProbe(int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 150),
      );
      return true;
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }
}

class SystemCdpBrowserLauncher implements CdpBrowserLauncher {
  SystemCdpBrowserLauncher({
    ChromiumExecutableLocator? executableLocator,
    CdpProcessStarter? processStarter,
    CdpOrphanedProfileCollector? orphanedProfileCollector,
  }) : executableLocator =
           executableLocator ?? ChromiumExecutableLocator.system(),
       orphanedProfileCollector =
           orphanedProfileCollector ?? CdpOrphanedProfileCollector(),
       _processStarter =
           processStarter ??
           ((executable, arguments) => Process.start(
             executable,
             arguments,
             mode: ProcessStartMode.normal,
             runInShell: false,
           ));

  final ChromiumExecutableLocator executableLocator;
  final CdpOrphanedProfileCollector orphanedProfileCollector;
  final CdpProcessStarter _processStarter;

  @override
  Future<CdpBrowserSession> launch({
    required DesktopOperatingSystem operatingSystem,
    required Duration startupTimeout,
  }) async {
    if (operatingSystem == DesktopOperatingSystem.unsupported) {
      throw const YouTubeMusicWebAuthException(
        'El inicio de sesión externo solo está disponible en Linux y Windows.',
      );
    }
    if (startupTimeout <= Duration.zero) {
      throw ArgumentError.value(startupTimeout, 'startupTimeout');
    }
    await orphanedProfileCollector.collect(operatingSystem);
    final executable = executableLocator.locate(operatingSystem);
    if (executable == null) {
      throw const YouTubeMusicWebAuthException(
        'No se encontró Microsoft Edge, Google Chrome, Brave o Chromium.',
      );
    }

    final profile = await Directory.systemTemp.createTemp(
      CdpOrphanedProfileCollector.profilePrefix,
    );
    final marker = File(
      '${profile.path}${Platform.pathSeparator}'
      '${CdpOrphanedProfileCollector.profileMarker}',
    );
    final ownerFile = File(
      '${profile.path}${Platform.pathSeparator}'
      '${CdpOrphanedProfileCollector.ownershipLock}',
    );
    Process? process;
    RandomAccessFile? ownershipLock;
    try {
      ownershipLock = await ownerFile.open(mode: FileMode.append);
      ownershipLock.lockSync(FileLock.exclusive);
      await marker.writeAsString(
        CdpOrphanedProfileCollector.markerDocument(createdAt: DateTime.now()),
      );
      if (operatingSystem == DesktopOperatingSystem.linux) {
        await _restrictLinuxProfilePermissions(profile);
      }
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      final port = reservation.port;
      await reservation.close();
      process = await _processStarter(executable, <String>[
        '--user-data-dir=${profile.absolute.path}',
        '--remote-debugging-address=127.0.0.1',
        '--remote-debugging-port=$port',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-sync',
        '--disable-extensions',
        '--disable-background-mode',
        if (operatingSystem == DesktopOperatingSystem.linux)
          '--password-store=basic',
        '--new-window',
        'about:blank',
      ]);
      await marker.writeAsString(
        CdpOrphanedProfileCollector.markerDocument(
          createdAt: DateTime.now(),
          processId: process.pid,
          debugPort: port,
        ),
      );
      // Browser diagnostics can contain visited URLs. Drain without logging.
      process.stdout.listen((_) {}, onError: (_) {});
      process.stderr.listen((_) {}, onError: (_) {});
      return _SystemCdpBrowserSession(
        process,
        ownershipLock,
        profileDirectory: profile.absolute,
        expectedTemporaryParent: Directory.systemTemp.absolute,
        profilePrefix: CdpOrphanedProfileCollector.profilePrefix,
        profileMarker: CdpOrphanedProfileCollector.profileMarker,
        devToolsHttpEndpoint: Uri(
          scheme: 'http',
          host: InternetAddress.loopbackIPv4.address,
          port: port,
        ),
      );
    } on Object {
      process?.kill();
      if (ownershipLock != null) {
        try {
          ownershipLock.unlockSync();
        } on Object {
          // Continue closing and deleting the just-created profile.
        }
        try {
          await ownershipLock.close();
        } on Object {
          // Continue deleting the just-created profile.
        }
      }
      await _deleteOwnedProfile(
        profile: profile.absolute,
        expectedParent: Directory.systemTemp.absolute,
        prefix: CdpOrphanedProfileCollector.profilePrefix,
        markerName: CdpOrphanedProfileCollector.profileMarker,
      );
      rethrow;
    }
  }

  Future<void> _restrictLinuxProfilePermissions(Directory profile) async {
    final executable = File('/bin/chmod').existsSync()
        ? '/bin/chmod'
        : '/usr/bin/chmod';
    final result = await Process.run(executable, <String>[
      '700',
      profile.absolute.path,
    ]);
    if (result.exitCode != 0) {
      throw const YouTubeMusicWebAuthException(
        'No se pudo proteger el perfil temporal del navegador.',
      );
    }
  }
}

class _SystemCdpBrowserSession implements CdpBrowserSession {
  _SystemCdpBrowserSession(
    Process process,
    this._ownershipLock, {
    required this.profileDirectory,
    required this.expectedTemporaryParent,
    required this.profilePrefix,
    required this.profileMarker,
    required this.devToolsHttpEndpoint,
  }) : _process = process,
       _closed = process.exitCode.then<void>((_) {});

  final Process _process;
  final RandomAccessFile _ownershipLock;
  final Directory profileDirectory;
  final Directory expectedTemporaryParent;
  final String profilePrefix;
  final String profileMarker;

  @override
  final Uri devToolsHttpEndpoint;

  final Future<void> _closed;
  Future<void>? _closeInFlight;
  var _ownershipLockReleased = false;

  @override
  Future<void> get closed => _closed;

  @override
  Future<void> close() {
    final existing = _closeInFlight;
    if (existing != null) return existing;
    final operation = _closeProcess();
    _closeInFlight = operation;
    return operation;
  }

  Future<void> _closeProcess() async {
    try {
      _process.kill();
      try {
        await _closed.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        _process.kill(ProcessSignal.sigkill);
        try {
          await _closed.timeout(const Duration(seconds: 2));
        } on Object {
          // Profile deletion reports failure while the browser holds files.
        }
      }
    } finally {
      await _releaseOwnershipLock();
    }
  }

  Future<void> _releaseOwnershipLock() async {
    if (_ownershipLockReleased) return;
    _ownershipLockReleased = true;
    try {
      _ownershipLock.unlockSync();
    } on Object {
      // The OS may already have released it after process shutdown.
    }
    try {
      await _ownershipLock.close();
    } on Object {
      // Deletion below remains the authoritative cleanup result.
    }
  }

  @override
  Future<bool> deleteTemporaryProfile() => _deleteOwnedProfile(
    profile: profileDirectory,
    expectedParent: expectedTemporaryParent,
    prefix: profilePrefix,
    markerName: profileMarker,
  );
}

Future<bool> _deleteOwnedProfile({
  required Directory profile,
  required Directory expectedParent,
  required String prefix,
  required String markerName,
}) async {
  final profileParent = profile.parent.absolute.path;
  final expectedParentPath = expectedParent.absolute.path;
  final marker = File('${profile.path}${Platform.pathSeparator}$markerName');
  final name = profile.path.split(RegExp(r'[/\\]')).last;
  if (profileParent != expectedParentPath ||
      !name.startsWith(prefix) ||
      !await marker.exists()) {
    return false;
  }
  // Chromium can acknowledge Browser.close just before its final profile
  // writer exits. Require several consecutive absent checks so that a late
  // writer cannot recreate an orphaned credential directory after cleanup.
  var consecutiveAbsentChecks = 0;
  for (var attempt = 0; attempt < 12; attempt++) {
    try {
      if (await profile.exists()) await profile.delete(recursive: true);
      await Future<void>.delayed(const Duration(milliseconds: 125));
      if (await profile.exists()) {
        consecutiveAbsentChecks = 0;
      } else {
        consecutiveAbsentChecks += 1;
        if (consecutiveAbsentChecks >= 3) return true;
      }
    } on Object {
      consecutiveAbsentChecks = 0;
      if (attempt == 11) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  return false;
}

class HttpCdpTargetConnector implements CdpTargetConnector {
  const HttpCdpTargetConnector();

  static const _maximumDiscoveryBytes = 1024 * 1024;

  @override
  Future<CdpTargetConnection> connect({
    required Uri devToolsHttpEndpoint,
    required Duration timeout,
  }) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout');
    }
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      try {
        final target = await _discoverPageTarget(devToolsHttpEndpoint);
        if (target != null) {
          final socket = await WebSocket.connect(
            target.webSocketUri.toString(),
          ).timeout(_remaining(deadline));
          socket.pingInterval = const Duration(seconds: 10);
          return _IoCdpTargetConnection(
            targetId: target.targetId,
            socket: socket,
          );
        }
      } on Object catch (error) {
        lastError = error;
      }
      final remaining = _remaining(deadline);
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < const Duration(milliseconds: 75)
            ? remaining
            : const Duration(milliseconds: 75),
      );
    }
    throw YouTubeMusicWebAuthException(
      lastError == null
          ? 'El navegador no publicó una pestaña de inicio de sesión.'
          : 'No se pudo conectar de forma privada con el navegador.',
    );
  }

  Future<_DiscoveredCdpTarget?> _discoverPageTarget(Uri endpoint) async {
    if (endpoint.scheme != 'http' ||
        !_isLoopbackHost(endpoint.host) ||
        endpoint.port <= 0) {
      throw const FormatException('Invalid local DevTools endpoint.');
    }
    final discoveryUri = endpoint.replace(path: '/json/list', query: null);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client.getUrl(discoveryUri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) return null;
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maximumDiscoveryBytes) {
          throw const FormatException('DevTools discovery response too large.');
        }
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! List) return null;
      for (final item in decoded) {
        final values = _objectMap(item);
        if (values == null || values['type'] != 'page') continue;
        final targetId = values['id']?.toString().trim();
        final rawWebSocket = values['webSocketDebuggerUrl']?.toString();
        final webSocketUri = Uri.tryParse(rawWebSocket ?? '');
        if (targetId == null ||
            targetId.isEmpty ||
            webSocketUri == null ||
            webSocketUri.scheme != 'ws' ||
            !_isLoopbackHost(webSocketUri.host) ||
            webSocketUri.port != endpoint.port ||
            !webSocketUri.path.startsWith('/devtools/page/')) {
          continue;
        }
        return _DiscoveredCdpTarget(targetId, webSocketUri);
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Duration _remaining(DateTime deadline) {
    final result = deadline.difference(DateTime.now());
    return result.isNegative ? Duration.zero : result;
  }
}

class _DiscoveredCdpTarget {
  const _DiscoveredCdpTarget(this.targetId, this.webSocketUri);

  final String targetId;
  final Uri webSocketUri;
}

class _CdpProtocolException implements Exception {
  const _CdpProtocolException(this.message);

  final String message;

  @override
  String toString() => 'CdpProtocolException($message)';
}

class _IoCdpTargetConnection implements CdpTargetConnection {
  _IoCdpTargetConnection({required this.targetId, required WebSocket socket})
    : _socket = socket {
    _subscription = socket.listen(
      _onMessage,
      onError: _onSocketError,
      onDone: _onSocketDone,
      cancelOnError: false,
    );
  }

  final WebSocket _socket;
  final _eventController = StreamController<CdpEvent>.broadcast(sync: true);
  final _closedCompleter = Completer<void>();
  final _pending = <int, Completer<Map<String, Object?>>>{};
  late final StreamSubscription<Object?> _subscription;
  var _nextCommandId = 0;
  var _isClosed = false;

  @override
  final String targetId;

  @override
  Stream<CdpEvent> get events => _eventController.stream;

  @override
  Future<void> get closed => _closedCompleter.future;

  @override
  Future<Map<String, Object?>> send(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    if (_isClosed) {
      return Future<Map<String, Object?>>.error(
        const _CdpProtocolException('The DevTools connection is closed.'),
      );
    }
    final id = ++_nextCommandId;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      _socket.add(
        jsonEncode(<String, Object?>{
          'id': id,
          'method': method,
          if (params.isNotEmpty) 'params': params,
        }),
      );
    } on Object catch (error, stackTrace) {
      _pending.remove(id);
      completer.completeError(error, stackTrace);
    }
    return completer.future;
  }

  void _onMessage(Object? rawMessage) {
    try {
      final String message;
      if (rawMessage is String) {
        message = rawMessage;
      } else if (rawMessage is List<int>) {
        message = utf8.decode(rawMessage);
      } else {
        return;
      }
      final decoded = _objectMap(jsonDecode(message));
      if (decoded == null) return;
      final rawId = decoded['id'];
      if (rawId is num) {
        final completer = _pending.remove(rawId.toInt());
        if (completer == null) return;
        final error = _objectMap(decoded['error']);
        if (error != null) {
          completer.completeError(
            _CdpProtocolException(
              error['message']?.toString() ?? 'DevTools command failed.',
            ),
          );
          return;
        }
        completer.complete(
          _objectMap(decoded['result']) ?? const <String, Object?>{},
        );
        return;
      }
      final method = decoded['method']?.toString();
      if (method == null || method.isEmpty || _eventController.isClosed) {
        return;
      }
      _eventController.add(
        CdpEvent(method, _objectMap(decoded['params']) ?? const {}),
      );
    } on Object {
      // Ignore malformed unsolicited messages from the debugging endpoint.
    }
  }

  void _onSocketError(Object error, StackTrace stackTrace) {
    _finishPending(
      const _CdpProtocolException('The DevTools connection was interrupted.'),
      stackTrace,
    );
  }

  void _onSocketDone() {
    _finishPending(
      const _CdpProtocolException('The DevTools connection was closed.'),
      StackTrace.current,
    );
  }

  void _finishPending(Object error, StackTrace stackTrace) {
    if (_isClosed) return;
    _isClosed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
    _pending.clear();
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
    if (!_eventController.isClosed) unawaited(_eventController.close());
  }

  @override
  Future<void> close() async {
    if (!_isClosed) {
      _isClosed = true;
      for (final completer in _pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(
            const _CdpProtocolException('The DevTools connection was closed.'),
          );
        }
      }
      _pending.clear();
      await _subscription.cancel();
      try {
        await _socket.close();
      } on Object {
        // The browser may already have closed the socket.
      }
      if (!_closedCompleter.isCompleted) _closedCompleter.complete();
      if (!_eventController.isClosed) await _eventController.close();
    }
  }
}

bool _isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1';
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, item) => MapEntry(key.toString(), item));
}

class CdpYouTubeMusicWebAuthPort implements DesktopYouTubeMusicWebAuthPort {
  CdpYouTubeMusicWebAuthPort({
    Uri? initialLoginUri,
    this.cookieCodec = const YouTubeMusicCookieCodec(),
    this.navigationPolicy = const YouTubeMusicNavigationPolicy(),
    DesktopOperatingSystem? operatingSystem,
    CdpBrowserLauncher? browserLauncher,
    CdpTargetConnector? targetConnector,
    this.startupTimeout = const Duration(seconds: 15),
    this.commandTimeout = const Duration(seconds: 5),
  }) : initialLoginUri = initialLoginUri ?? defaultInitialLoginUri,
       operatingSystem = operatingSystem ?? detectedOperatingSystem,
       browserLauncher = browserLauncher ?? SystemCdpBrowserLauncher(),
       targetConnector = targetConnector ?? const HttpCdpTargetConnector();

  static final Uri defaultInitialLoginUri = Uri.parse(
    'https://accounts.google.com/ServiceLogin?service=youtube&continue='
    'https%3A%2F%2Fmusic.youtube.com%2F',
  );
  static final Uri musicUri = Uri.parse('https://music.youtube.com/');

  static DesktopOperatingSystem get detectedOperatingSystem {
    if (Platform.isLinux) return DesktopOperatingSystem.linux;
    if (Platform.isWindows) return DesktopOperatingSystem.windows;
    return DesktopOperatingSystem.unsupported;
  }

  static bool get isSupportedPlatform =>
      detectedOperatingSystem != DesktopOperatingSystem.unsupported;

  static const String _configurationScript = r'''
(() => {
  const read = (name) => {
    try {
      if (window.ytcfg && typeof window.ytcfg.get === 'function') {
        const value = window.ytcfg.get(name);
        if (value !== undefined && value !== null) return value;
      }
    } catch (_) {}
    try {
      if (window.yt && window.yt.config_) return window.yt.config_[name];
    } catch (_) {}
    return null;
  };
  const context = read('INNERTUBE_CONTEXT');
  const client = context && context.client ? context.client : {};
  return JSON.stringify({
    visitorData: read('VISITOR_DATA') ?? client.visitorData,
    dataSyncId: read('DATASYNC_ID'),
    authUser: String(read('SESSION_INDEX') ?? '0'),
    delegatedPageId: read('DELEGATED_SESSION_ID'),
    apiKey: read('INNERTUBE_API_KEY'),
    clientVersion: read('INNERTUBE_CLIENT_VERSION') ?? client.clientVersion,
    clientName: read('INNERTUBE_CLIENT_NAME') ?? client.clientName,
    region: read('GL') ?? read('GEO') ?? client.gl ?? client.country
  });
})()
''';

  final Uri initialLoginUri;
  final YouTubeMusicCookieCodec cookieCodec;

  @override
  final YouTubeMusicNavigationPolicy navigationPolicy;

  final DesktopOperatingSystem operatingSystem;
  final CdpBrowserLauncher browserLauncher;
  final CdpTargetConnector targetConnector;
  final Duration startupTimeout;
  final Duration commandTimeout;

  final _navigationController = StreamController<Uri>.broadcast();
  final _browserClosedController = StreamController<void>.broadcast();
  CdpBrowserSession? _browserSession;
  CdpTargetConnection? _connection;
  StreamSubscription<CdpEvent>? _eventSubscription;
  Future<void>? _prepareInFlight;
  Future<YouTubeMusicWebCleanupResult>? _cleanupInFlight;
  Uri? _currentUri;
  String? _mainFrameId;
  final _knownSubframeIds = <String>{};
  var _prepared = false;
  var _closed = false;
  var _cleaningUp = false;
  var _cleanupCompleted = false;
  var _browserClosedEmitted = false;

  @override
  Stream<Uri> get navigationStream => _navigationController.stream;

  @override
  Stream<void> get browserClosedStream => _browserClosedController.stream;

  @override
  Uri? get currentUri => _currentUri;

  @override
  bool get isPrepared => _prepared;

  @override
  Future<void> prepare() {
    _ensureOpen();
    if (_prepared) return Future<void>.value();
    final existing = _prepareInFlight;
    if (existing != null) return existing;
    final operation = _prepare();
    _prepareInFlight = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_prepareInFlight, operation)) _prepareInFlight = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_prepareInFlight, operation)) _prepareInFlight = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _prepare() async {
    if (operatingSystem == DesktopOperatingSystem.unsupported) {
      throw const YouTubeMusicWebAuthException(
        'El inicio de sesión externo solo está disponible en Linux y Windows.',
      );
    }
    if (startupTimeout <= Duration.zero || commandTimeout <= Duration.zero) {
      throw ArgumentError('Desktop browser timeouts must be positive.');
    }
    if (_browserSession != null) {
      final removedStaleProfile = await _disposeResources(closeStreams: false);
      if (!removedStaleProfile) {
        throw const YouTubeMusicWebAuthException(
          'No se pudo eliminar el perfil temporal de la sesión anterior.',
        );
      }
    }
    try {
      final launchedSession = await browserLauncher.launch(
        operatingSystem: operatingSystem,
        startupTimeout: startupTimeout,
      );
      if (_closed) {
        await launchedSession.close();
        await launchedSession.deleteTemporaryProfile();
        throw StateError('The desktop authentication session is closed.');
      }
      _browserSession = launchedSession;
      _browserClosedEmitted = false;
      unawaited(
        launchedSession.closed.then(
          (_) => _handleBrowserClosed(launchedSession),
        ),
      );

      final connection = await targetConnector.connect(
        devToolsHttpEndpoint: launchedSession.devToolsHttpEndpoint,
        timeout: startupTimeout,
      );
      if (_closed) {
        await connection.close();
        throw StateError('The desktop authentication session is closed.');
      }
      _connection = connection;
      _eventSubscription = connection.events.listen(_handleCdpEvent);
      unawaited(_observeConnectionClosure(connection));
      await _send(connection, 'Page.enable');
      await _send(connection, 'Runtime.enable');
      await _send(connection, 'Network.enable');
      await _send(connection, 'Fetch.enable', <String, Object?>{
        'patterns': <Object?>[
          <String, Object?>{
            'urlPattern': '*',
            'resourceType': 'Document',
            'requestStage': 'Request',
          },
        ],
      });
      final frameTree = await _send(connection, 'Page.getFrameTree');
      final rootFrame = _objectMap(
        _objectMap(frameTree['frameTree'])?['frame'],
      );
      final rootFrameId = rootFrame?['id']?.toString().trim();
      if (rootFrameId == null || rootFrameId.isEmpty) {
        throw const YouTubeMusicWebAuthException(
          'El navegador no identificó el documento principal de acceso.',
        );
      }
      _mainFrameId = rootFrameId;
      _knownSubframeIds.clear();
      _rememberFrameTreeChildren(_objectMap(frameTree['frameTree']));
      await _navigate(connection, initialLoginUri);
      if (_closed || !identical(_connection, connection)) {
        throw const YouTubeMusicWebAuthException(
          'La pestaña privada se cerró durante la preparación.',
        );
      }
      _prepared = true;
    } on Object catch (error) {
      await _disposeResources(closeStreams: false);
      if (error is YouTubeMusicWebAuthException || error is ArgumentError) {
        rethrow;
      }
      throw const YouTubeMusicWebAuthException(
        'No se pudo abrir una sesión privada en el navegador.',
      );
    }
  }

  void _handleCdpEvent(CdpEvent event) {
    if (event.method == 'Fetch.requestPaused') {
      unawaited(_handlePausedRequest(event.params));
      return;
    }
    if (event.method == 'Page.frameNavigated') {
      final frame = _objectMap(event.params['frame']);
      if (frame == null) return;
      final frameId = frame['id']?.toString().trim();
      final parentId = frame['parentId']?.toString().trim();
      if (parentId == null || parentId.isEmpty) {
        if (frameId == null || frameId.isEmpty) return;
        _knownSubframeIds.clear();
        _mainFrameId = frameId;
        _publishRawNavigation(frame['url']);
      } else if (frameId != null &&
          frameId.isNotEmpty &&
          (parentId == _mainFrameId || _knownSubframeIds.contains(parentId))) {
        _knownSubframeIds.add(frameId);
      }
      return;
    }
    if (event.method == 'Page.frameAttached') {
      final frameId = event.params['frameId']?.toString().trim();
      final parentId = event.params['parentFrameId']?.toString().trim();
      if (frameId != null &&
          frameId.isNotEmpty &&
          parentId != null &&
          (parentId == _mainFrameId || _knownSubframeIds.contains(parentId))) {
        _knownSubframeIds.add(frameId);
      }
      return;
    }
    if (event.method == 'Page.frameDetached') {
      // CDP omits descendants here. Forget all subframe IDs so a detached
      // descendant can never retain trusted-subframe status.
      _knownSubframeIds.clear();
      return;
    }
    if (event.method == 'Page.navigatedWithinDocument') {
      if (event.params['frameId']?.toString() == _mainFrameId) {
        _publishRawNavigation(event.params['url']);
      }
    }
  }

  Future<void> _handlePausedRequest(Map<String, Object?> params) async {
    final connection = _connection;
    final requestId = params['requestId']?.toString();
    if (connection == null || requestId == null || requestId.isEmpty) return;
    final isDocument = params['resourceType'] == 'Document';
    final frameId = params['frameId']?.toString().trim();
    final isMainDocument = isDocument && frameId == _mainFrameId;
    var decision = YouTubeMusicNavigationDecision.allow;
    if (isDocument) {
      final isKnownSubframe =
          frameId != null && _knownSubframeIds.contains(frameId);
      if (!isMainDocument && !isKnownSubframe) {
        decision = YouTubeMusicNavigationDecision.cancel;
      } else {
        final request = _objectMap(params['request']);
        final uri = Uri.tryParse(request?['url']?.toString() ?? '');
        decision = navigationPolicy.evaluate(uri, isMainFrame: isMainDocument);
      }
    }
    try {
      if (decision == YouTubeMusicNavigationDecision.allow) {
        await _send(connection, 'Fetch.continueRequest', <String, Object?>{
          'requestId': requestId,
        });
      } else {
        await _send(connection, 'Fetch.failRequest', <String, Object?>{
          'requestId': requestId,
          'errorReason': 'BlockedByClient',
        });
      }
    } on Object {
      // The request disappears naturally when its tab or browser is closed.
    }
  }

  void _publishRawNavigation(Object? rawUrl) {
    final uri = Uri.tryParse(rawUrl?.toString() ?? '');
    if (uri != null) _publishNavigation(uri);
  }

  void _publishNavigation(Uri uri) {
    if (_currentUri == uri) return;
    _currentUri = uri;
    if (!_navigationController.isClosed) _navigationController.add(uri);
  }

  Future<void> _handleBrowserClosed(CdpBrowserSession session) async {
    if (!identical(_browserSession, session) || _cleaningUp || _closed) return;
    final wasPrepared = _prepared;
    _prepared = false;
    if (!wasPrepared) return;
    _emitBrowserClosed();
    await cleanup();
  }

  Future<void> _observeConnectionClosure(CdpTargetConnection connection) async {
    try {
      await connection.closed;
    } on Object {
      // An error completion still means the target is unusable.
    }
    await _handleConnectionLoss(connection);
  }

  Future<void> _handleConnectionLoss(CdpTargetConnection connection) async {
    if (!identical(_connection, connection)) return;
    _connection = null;
    final wasPrepared = _prepared;
    _prepared = false;
    if (_cleaningUp || _closed || !wasPrepared) return;
    _emitBrowserClosed();
    await cleanup();
  }

  Future<void> _invalidateTimedOutConnection(
    CdpTargetConnection connection,
  ) async {
    if (!identical(_connection, connection)) return;
    try {
      await connection.close().timeout(const Duration(seconds: 1));
    } on Object {
      // Invalidation below does not depend on a cooperative socket close.
    }
    await _handleConnectionLoss(connection);
  }

  void _emitBrowserClosed() {
    if (_browserClosedEmitted) return;
    _browserClosedEmitted = true;
    if (!_browserClosedController.isClosed) {
      _browserClosedController.add(null);
    }
  }

  void _rememberFrameTreeChildren(Map<String, Object?>? frameTree) {
    final childFrames = frameTree?['childFrames'];
    if (childFrames is! List) return;
    for (final rawChild in childFrames) {
      final childTree = _objectMap(rawChild);
      final childFrame = _objectMap(childTree?['frame']);
      final childId = childFrame?['id']?.toString().trim();
      final parentId = childFrame?['parentId']?.toString().trim();
      if (childId == null ||
          childId.isEmpty ||
          parentId == null ||
          parentId.isEmpty ||
          parentId != _mainFrameId && !_knownSubframeIds.contains(parentId)) {
        continue;
      }
      _knownSubframeIds.add(childId);
      _rememberFrameTreeChildren(childTree);
    }
  }

  @override
  Future<YouTubeMusicWebAuthData> waitForAuthenticatedSession({
    int maximumAttempts = 20,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    if (maximumAttempts <= 0 || retryDelay.isNegative) {
      throw ArgumentError('Invalid desktop authentication retry policy.');
    }
    final connection = _requireConnection();
    for (var attempt = 0; attempt < maximumAttempts; attempt++) {
      if (_closed || !identical(_connection, connection)) {
        throw const YouTubeMusicWebAuthException(
          'La pestaña privada de inicio de sesión se cerró.',
        );
      }
      final current = await _readCurrentUri(connection);
      if (_closed || !identical(_connection, connection)) {
        throw const YouTubeMusicWebAuthException(
          'La pestaña privada de inicio de sesión se cerró.',
        );
      }
      if (navigationPolicy.isYouTubeAuthDocument(current)) {
        if (!navigationPolicy.isYouTubeMusicDocument(current)) {
          await _navigate(connection, musicUri);
          if (attempt + 1 < maximumAttempts) {
            await Future<void>.delayed(retryDelay);
          }
          continue;
        }
        final authData = await _tryReadAuthData(connection);
        if (authData != null) return authData;
      }
      if (attempt + 1 < maximumAttempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
    throw const YouTubeMusicWebAuthException(
      'No se pudo verificar una sesión completa de YouTube Music.',
    );
  }

  Future<YouTubeMusicWebAuthData?> _tryReadAuthData(
    CdpTargetConnection connection,
  ) async {
    try {
      final evaluation =
          await _send(connection, 'Runtime.evaluate', <String, Object?>{
            'expression': _configurationScript,
            'returnByValue': true,
            'awaitPromise': true,
          });
      if (evaluation['exceptionDetails'] != null) return null;
      final remoteObject = _objectMap(evaluation['result']);
      final config = _decodeConfiguration(remoteObject?['value']);
      final visitorData = _nonEmptyString(config['visitorData']);
      final authUser = _nonEmptyString(config['authUser']);
      final apiKey = _nonEmptyString(config['apiKey']);
      final clientVersion = _nonEmptyString(config['clientVersion']);
      final clientName = _nonEmptyString(config['clientName']);
      if (visitorData == null ||
          authUser == null ||
          apiKey == null ||
          clientVersion == null ||
          clientName == null) {
        return null;
      }

      Map<String, Object?> cookieResult;
      try {
        cookieResult = await _send(
          connection,
          'Network.getCookies',
          <String, Object?>{
            'urls': <String>[musicUri.toString()],
          },
        );
      } on Object {
        cookieResult = await _send(connection, 'Network.getAllCookies');
      }
      final cookies = cookieResult['cookies'];
      if (cookies is! List) return null;
      final values = <String, String>{};
      final priorities = <String, int>{};
      for (final rawCookie in cookies) {
        final cookie = _objectMap(rawCookie);
        if (cookie == null) continue;
        final domain = cookie['domain']?.toString();
        if (!_isYouTubeDomain(domain)) continue;
        final name = _nonEmptyString(cookie['name']);
        final value = _nonEmptyString(cookie['value']);
        if (name == null || value == null) continue;
        if (_isSigningCookie(name) && cookie['secure'] != true) {
          throw const FormatException('Insecure YouTube Music cookie.');
        }
        final priority = _cookieDomainPriority(domain!);
        if (priority >= (priorities[name] ?? -1)) {
          values[name] = value;
          priorities[name] = priority;
        }
      }
      if (!cookieCodec.hasSigningCookie(values)) return null;
      return YouTubeMusicWebAuthData(
        cookieHeader: cookieCodec.encode(values),
        identity: YouTubeMusicAuthIdentity.fromJson(<String, Object?>{
          'visitorData': visitorData,
          'authUser': authUser,
          'dataSyncId': _normalizeDataSyncId(config['dataSyncId']),
          'delegatedPageId': _nonEmptyString(config['delegatedPageId']),
        }),
        apiKey: apiKey,
        clientVersion: clientVersion,
        clientName: clientName,
        region: _nonEmptyString(config['region']),
      );
    } on FormatException {
      return null;
    } on _CdpProtocolException {
      return null;
    }
  }

  Map<String, Object?> _decodeConfiguration(Object? raw) {
    Object? decoded = raw;
    for (var depth = 0; depth < 2 && decoded is String; depth++) {
      decoded = jsonDecode(decoded);
    }
    final result = _objectMap(decoded);
    if (result == null) {
      throw const FormatException('Invalid YouTube Music configuration.');
    }
    return result;
  }

  static String? _nonEmptyString(Object? value) {
    if (value == null) return null;
    final normalized = value.toString().trim();
    return normalized.isEmpty ? null : normalized;
  }

  static String? _normalizeDataSyncId(Object? value) {
    final normalized = _nonEmptyString(value);
    if (normalized == null) return null;
    final accountValue = normalized.split('||').first.trim();
    return accountValue.isEmpty ? null : accountValue;
  }

  static bool _isSigningCookie(String name) =>
      name == 'SAPISID' ||
      name == '__Secure-1PAPISID' ||
      name == '__Secure-3PAPISID';

  static bool _isYouTubeDomain(String? domain) {
    if (domain == null || domain.trim().isEmpty) return false;
    final normalized = domain
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^\.'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return normalized == 'youtube.com' || normalized.endsWith('.youtube.com');
  }

  static int _cookieDomainPriority(String domain) {
    final normalized = domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (normalized == 'music.youtube.com') return 2;
    if (normalized == 'youtube.com') return 1;
    return 0;
  }

  Future<Uri?> _readCurrentUri(CdpTargetConnection connection) async {
    try {
      final history = await _send(connection, 'Page.getNavigationHistory');
      final index = history['currentIndex'];
      final entries = history['entries'];
      if (index is! num || entries is! List) return _currentUri;
      final position = index.toInt();
      if (position < 0 || position >= entries.length) return _currentUri;
      final entry = _objectMap(entries[position]);
      final uri = Uri.tryParse(entry?['url']?.toString() ?? '');
      if (uri != null) _publishNavigation(uri);
      return uri;
    } on Object {
      return _currentUri;
    }
  }

  @override
  Future<void> navigate(Uri uri) async {
    _ensureOpen();
    await _navigate(_requireConnection(), uri);
  }

  Future<void> _navigate(CdpTargetConnection connection, Uri uri) async {
    if (navigationPolicy.evaluate(uri, isMainFrame: true) !=
        YouTubeMusicNavigationDecision.allow) {
      throw const YouTubeMusicWebAuthException(
        'YouTube Music intentó abrir una dirección no permitida.',
      );
    }
    final result = await _send(connection, 'Page.navigate', <String, Object?>{
      'url': uri.toString(),
    });
    if (result['errorText'] != null) {
      throw const YouTubeMusicWebAuthException(
        'El navegador no pudo abrir la dirección de inicio de sesión.',
      );
    }
    final frameId = result['frameId']?.toString();
    if (frameId != null && frameId.isNotEmpty) {
      if (_mainFrameId != frameId) _knownSubframeIds.clear();
      _mainFrameId = frameId;
    }
  }

  @override
  Future<bool> canGoBack() async {
    final connection = _requireConnection();
    final history = await _send(connection, 'Page.getNavigationHistory');
    final index = history['currentIndex'];
    return index is num && index.toInt() > 0;
  }

  @override
  Future<void> goBack() async {
    final connection = _requireConnection();
    final history = await _send(connection, 'Page.getNavigationHistory');
    final rawIndex = history['currentIndex'];
    final entries = history['entries'];
    if (rawIndex is! num || entries is! List) return;
    final targetIndex = rawIndex.toInt() - 1;
    if (targetIndex < 0 || targetIndex >= entries.length) return;
    final entry = _objectMap(entries[targetIndex]);
    final entryId = entry?['id'];
    final uri = Uri.tryParse(entry?['url']?.toString() ?? '');
    if (entryId is! num ||
        uri == null ||
        navigationPolicy.evaluate(uri, isMainFrame: true) !=
            YouTubeMusicNavigationDecision.allow) {
      throw const YouTubeMusicWebAuthException(
        'El historial contenía una dirección no permitida.',
      );
    }
    await _send(connection, 'Page.navigateToHistoryEntry', <String, Object?>{
      'entryId': entryId.toInt(),
    });
  }

  @override
  Future<void> bringToForeground() async {
    final connection = _requireConnection();
    final window = await _send(
      connection,
      'Browser.getWindowForTarget',
      <String, Object?>{'targetId': connection.targetId},
    );
    final windowId = window['windowId'];
    final bounds = _objectMap(window['bounds']);
    if (windowId is num && bounds?['windowState'] == 'minimized') {
      await _send(connection, 'Browser.setWindowBounds', <String, Object?>{
        'windowId': windowId.toInt(),
        'bounds': const <String, Object?>{'windowState': 'normal'},
      });
    }
    await _send(connection, 'Page.bringToFront');
  }

  @override
  Future<void> minimize() async {
    final connection = _requireConnection();
    final window = await _send(
      connection,
      'Browser.getWindowForTarget',
      <String, Object?>{'targetId': connection.targetId},
    );
    final windowId = window['windowId'];
    if (windowId is! num) {
      throw const YouTubeMusicWebAuthException(
        'No se pudo minimizar la ventana de inicio de sesión.',
      );
    }
    await _send(connection, 'Browser.setWindowBounds', <String, Object?>{
      'windowId': windowId.toInt(),
      'bounds': const <String, Object?>{'windowState': 'minimized'},
    });
  }

  @override
  Future<YouTubeMusicWebCleanupResult> cleanup() {
    if (_cleanupCompleted) {
      return Future<YouTubeMusicWebCleanupResult>.value(
        const YouTubeMusicWebCleanupResult(
          cookiesCleared: true,
          webStorageCleared: true,
          cacheCleared: true,
        ),
      );
    }
    final existing = _cleanupInFlight;
    if (existing != null) return existing;
    _closed = true;
    final operation = _cleanup();
    _cleanupInFlight = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_cleanupInFlight, operation)) _cleanupInFlight = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_cleanupInFlight, operation)) _cleanupInFlight = null;
        },
      ),
    );
    return operation;
  }

  Future<YouTubeMusicWebCleanupResult> _cleanup() async {
    final preparing = _prepareInFlight;
    // Once a browser/connection exists, dispose it immediately. Waiting for
    // preparation first can deadlock cleanup behind a CDP command that never
    // responds. If launch itself is still in flight, allow only one bounded
    // window for it to publish the owned session before the disposal pass.
    if (preparing != null && _browserSession == null && _connection == null) {
      try {
        await preparing.timeout(commandTimeout);
      } on Object {
        // The disposal pass below remains authoritative.
      }
    }
    final profileDeleted = await _disposeResources(closeStreams: true);
    _cleanupCompleted = profileDeleted;
    return YouTubeMusicWebCleanupResult(
      cookiesCleared: profileDeleted,
      webStorageCleared: profileDeleted,
      cacheCleared: profileDeleted,
    );
  }

  Future<bool> _disposeResources({required bool closeStreams}) async {
    _cleaningUp = true;
    _prepared = false;
    final subscription = _eventSubscription;
    _eventSubscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel().timeout(const Duration(seconds: 1));
      } on Object {
        // Continue closing the target and owned process.
      }
    }

    final connection = _connection;
    _connection = null;
    if (connection != null) {
      try {
        await connection
            .send('Browser.close')
            .timeout(const Duration(seconds: 1));
      } on Object {
        // A closed socket means the browser already stopped.
      }
      try {
        await connection.close().timeout(const Duration(seconds: 1));
      } on Object {
        // Continue with process and owned-profile cleanup.
      }
    }

    final session = _browserSession;
    var profileDeleted = true;
    if (session != null) {
      try {
        await session.close();
      } on Object {
        // Profile deletion below is the authoritative cleanup signal.
      }
      try {
        profileDeleted = await session.deleteTemporaryProfile();
      } on Object {
        profileDeleted = false;
      }
      if (profileDeleted) _browserSession = null;
    }
    _mainFrameId = null;
    _knownSubframeIds.clear();
    _currentUri = null;
    if (closeStreams) {
      if (!_navigationController.isClosed) await _navigationController.close();
      if (!_browserClosedController.isClosed) {
        await _browserClosedController.close();
      }
    }
    _cleaningUp = false;
    return profileDeleted;
  }

  Future<Map<String, Object?>> _send(
    CdpTargetConnection connection,
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    return connection
        .send(method, params)
        .timeout(
          commandTimeout,
          onTimeout: () async {
            await _invalidateTimedOutConnection(connection);
            throw _CdpProtocolException(
              'The DevTools command $method timed out.',
            );
          },
        );
  }

  CdpTargetConnection _requireConnection() {
    _ensureOpen();
    final connection = _connection;
    if (!_prepared || connection == null) {
      throw StateError('The desktop authentication browser is not prepared.');
    }
    return connection;
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('The desktop authentication session is closed.');
    }
  }
}
