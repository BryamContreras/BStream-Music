import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../innertube_transport.dart';
import 'javascript_runtime.dart';

enum EjsChallengeType { n, sig }

class EjsModuleSpec {
  const EjsModuleSpec({
    required this.name,
    required this.uri,
    required this.sha256,
    this.assetPath,
  });

  final String name;
  final Uri uri;
  final String sha256;
  final String? assetPath;
}

/// Immutable upstream EJS 0.8.0 modules used by the solver.
const ejsVersion = '0.8.0';

final ejsModuleSpecs = <EjsModuleSpec>[
  EjsModuleSpec(
    name: 'lib',
    uri: Uri.parse(
      'https://github.com/yt-dlp/ejs/releases/download/0.8.0/yt.solver.lib.min.js',
    ),
    sha256: 'c55987fe697e5b9ee18830163f7af85327e9bb5c3e674b969d38c8d205eaa577',
    assetPath: 'assets/youtube/ejs/0.8.0/yt.solver.lib.min.js.b64',
  ),
  EjsModuleSpec(
    name: 'core',
    uri: Uri.parse(
      'https://github.com/yt-dlp/ejs/releases/download/0.8.0/yt.solver.core.min.js',
    ),
    sha256: '18da6ce0758b416e7ae645084f4f8801f9f9d59d6c477c05eaa0ff94ebd8cc00',
    assetPath: 'assets/youtube/ejs/0.8.0/yt.solver.core.min.js.b64',
  ),
];

/// Restricts dynamically executed player code to YouTube's HTTPS origin.
bool isTrustedYouTubeUri(Uri uri) {
  final host = uri.host.toLowerCase();
  return uri.scheme == 'https' &&
      (!uri.hasPort || uri.port == 443) &&
      (host == 'youtube.com' || host.endsWith('.youtube.com'));
}

bool isTrustedYouTubePlayerUri(Uri uri) =>
    isTrustedYouTubeUri(uri) && uri.path.endsWith('/base.js');

abstract interface class EjsModuleSource {
  Future<String> load();

  void close();
}

typedef EjsAssetLoader = Future<String> Function(String assetPath);

Future<String> _loadEjsAsset(String assetPath) =>
    rootBundle.loadString(assetPath);

/// Loads the exact pinned release modules from Base64-encoded Flutter assets.
///
/// Decoded module bytes are verified before execution. If an asset is absent
/// or fails verification, [fallback] is used; the default solver wires this to
/// the independently checksum-verified remote source. This source owns and
/// closes its fallback.
class BundledEjsModuleSource implements EjsModuleSource {
  BundledEjsModuleSource({
    EjsAssetLoader? assetLoader,
    List<EjsModuleSpec>? modules,
    this.fallback,
  }) : _assetLoader = assetLoader ?? _loadEjsAsset,
       modules = List<EjsModuleSpec>.unmodifiable(modules ?? ejsModuleSpecs) {
    if (this.modules.isEmpty) {
      throw ArgumentError.value(modules, 'modules', 'Must not be empty.');
    }
  }

  final EjsAssetLoader _assetLoader;
  final List<EjsModuleSpec> modules;
  final EjsModuleSource? fallback;

  String? _cached;
  Future<String>? _inFlight;
  bool _closed = false;

  @override
  Future<String> load() {
    if (_closed) {
      return Future<String>.error(
        StateError('The EJS module source is closed.'),
      );
    }
    final cached = _cached;
    if (cached != null) return Future<String>.value(cached);
    final pending = _inFlight;
    if (pending != null) return pending;
    final next = _loadWithFallback();
    _inFlight = next;
    unawaited(
      next.then<void>(
        (_) {
          if (identical(_inFlight, next)) _inFlight = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_inFlight, next)) _inFlight = null;
        },
      ),
    );
    return next;
  }

  Future<String> _loadWithFallback() async {
    try {
      final bundle = await _loadBundledModules();
      _cached = bundle;
      return bundle;
    } catch (assetError, assetStackTrace) {
      final fallbackSource = fallback;
      if (fallbackSource == null) {
        Error.throwWithStackTrace(assetError, assetStackTrace);
      }
      try {
        final bundle = await fallbackSource.load();
        _cached = bundle;
        return bundle;
      } catch (fallbackError) {
        throw EjsSolverException(
          'Bundled EJS modules and the remote fallback both failed.',
          cause: (asset: assetError, fallback: fallbackError),
        );
      }
    }
  }

  Future<String> _loadBundledModules() async {
    final source = <String>[];
    for (final module in modules) {
      final assetPath = module.assetPath;
      if (assetPath == null || assetPath.isEmpty) {
        throw EjsSolverException(
          'EJS ${module.name} has no bundled asset path.',
        );
      }
      final encoded = await _assetLoader(assetPath);
      late final String body;
      try {
        final compact = encoded.replaceAll(RegExp(r'\s'), '');
        body = utf8.decode(base64Decode(compact));
      } on FormatException catch (error) {
        throw EjsSolverException(
          'Bundled EJS ${module.name} is not valid Base64 UTF-8.',
          cause: error,
        );
      }
      _verifyEjsModule(module, body);
      _appendEjsModule(source, module, body);
    }
    return source.join('\n');
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    fallback?.close();
  }
}

/// Downloads, verifies and caches the pinned EJS modules.
class RemoteEjsModuleSource implements EjsModuleSource {
  RemoteEjsModuleSource({
    InnerTubeTransport? transport,
    List<EjsModuleSpec>? modules,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _transport = transport ?? IoInnerTubeTransport(),
       _ownsTransport = transport == null,
       modules = List<EjsModuleSpec>.unmodifiable(modules ?? ejsModuleSpecs) {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'Must be positive.',
      );
    }
    if (this.modules.isEmpty) {
      throw ArgumentError.value(modules, 'modules', 'Must not be empty.');
    }
  }

  final InnerTubeTransport _transport;
  final bool _ownsTransport;
  final List<EjsModuleSpec> modules;
  final Duration requestTimeout;

  String? _cached;
  Future<String>? _inFlight;
  bool _closed = false;

  @override
  Future<String> load() {
    if (_closed) {
      return Future<String>.error(
        StateError('The EJS module source is closed.'),
      );
    }
    final cached = _cached;
    if (cached != null) {
      return Future<String>.value(cached);
    }
    final pending = _inFlight;
    if (pending != null) {
      return pending;
    }
    final next = _loadModules();
    _inFlight = next;
    unawaited(
      next.then<void>(
        (_) {
          if (identical(_inFlight, next)) {
            _inFlight = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_inFlight, next)) {
            _inFlight = null;
          }
        },
      ),
    );
    return next;
  }

  Future<String> _loadModules() async {
    final source = <String>[];
    for (final module in modules) {
      final response = await _transport.get(
        module.uri,
        headers: const <String, String>{
          'accept': 'application/javascript,text/javascript,*/*;q=0.1',
          'user-agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/131.0.0.0 Safari/537.36',
        },
        timeout: requestTimeout,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw EjsSolverException(
          'EJS ${module.name} returned HTTP ${response.statusCode}.',
        );
      }
      _verifyEjsModule(module, response.body);
      _appendEjsModule(source, module, response.body);
    }
    final bundle = source.join('\n');
    _cached = bundle;
    return bundle;
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_ownsTransport) {
      _transport.close();
    }
  }
}

/// EJS 0.8.0 `n`/signature challenge solver with bounded TTL caches.
class EjsSolver {
  EjsSolver({
    required YoutubeJavaScriptRuntime runtime,
    InnerTubeTransport? transport,
    EjsModuleSource? moduleSource,
    this.playerRequestTimeout = const Duration(seconds: 15),
    this.cacheTtl = const Duration(hours: 6),
    this.maxCacheEntries = 32,
    DateTime Function()? clock,
    this.disposeRuntime = true,
  }) : // Keep the public argument name free of the private-field underscore.
       // ignore: prefer_initializing_formals
       _runtime = runtime,
       _transport = transport ?? IoInnerTubeTransport(),
       _ownsTransport = transport == null,
       _moduleSource =
           moduleSource ??
           BundledEjsModuleSource(
             fallback: RemoteEjsModuleSource(transport: transport),
           ),
       _ownsModuleSource = moduleSource == null,
       _clock = clock ?? DateTime.now {
    if (playerRequestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        playerRequestTimeout,
        'playerRequestTimeout',
        'Must be positive.',
      );
    }
    if (cacheTtl <= Duration.zero) {
      throw ArgumentError.value(cacheTtl, 'cacheTtl', 'Must be positive.');
    }
    if (maxCacheEntries <= 0) {
      throw ArgumentError.value(
        maxCacheEntries,
        'maxCacheEntries',
        'Must be positive.',
      );
    }
  }

  final YoutubeJavaScriptRuntime _runtime;
  final InnerTubeTransport _transport;
  final bool _ownsTransport;
  final EjsModuleSource _moduleSource;
  final bool _ownsModuleSource;
  final DateTime Function() _clock;

  final Duration playerRequestTimeout;
  final Duration cacheTtl;
  final int maxCacheEntries;
  final bool disposeRuntime;

  final _playerCache = <String, _CacheEntry<String>>{};
  final _preprocessedPlayerCache = <String, _CacheEntry<String>>{};
  final _solutionCache =
      <(String, EjsChallengeType, String), _CacheEntry<String>>{};

  Future<void>? _runtimeReady;
  Future<void> _queueTail = Future<void>.value();
  bool _disposed = false;

  Future<String> solve(
    String playerUrl,
    EjsChallengeType type,
    String challenge,
  ) async {
    final result = await solveBulk(playerUrl, <EjsChallengeType, List<String>>{
      type: <String>[challenge],
    });
    final value = result[challenge];
    if (value == null) {
      throw EjsSolverException('EJS did not solve challenge "$challenge".');
    }
    return value;
  }

  /// Reads the signature timestamp from the same player source later used for
  /// `s`/`n` solving.
  ///
  /// Keeping both values behind this cache prevents a player request from
  /// advertising one generation while its media URL is solved with another.
  Future<int?> signatureTimestamp(String playerUrl) {
    return _enqueue(() async {
      final uri = _validatedPlayerUri(playerUrl);
      final player = await _loadRawPlayer(uri, playerUrl);
      return _extractSignatureTimestamp(player);
    });
  }

  /// Drops every cached artifact derived from one player generation.
  ///
  /// Callers use this after a solver/CDN rejection before performing one
  /// bounded rebuild. Other player generations and the pinned EJS modules are
  /// intentionally preserved.
  Future<void> invalidatePlayer(String playerUrl) {
    return _enqueue(() async {
      _playerCache.remove(playerUrl);
      _preprocessedPlayerCache.remove(playerUrl);
      _solutionCache.removeWhere((key, _) => key.$1 == playerUrl);
    });
  }

  /// Solves a group of challenges in one EJS invocation.
  ///
  /// Calls are serialized because EJS mutates its global VM state. Concurrent
  /// identical calls naturally coalesce behind the first call and then reuse
  /// its cache entry.
  Future<Map<String, String?>> solveBulk(
    String playerUrl,
    Map<EjsChallengeType, List<String>> requests,
  ) {
    return _enqueue(() => _solveBulk(playerUrl, requests));
  }

  Future<Map<String, String?>> _solveBulk(
    String playerUrl,
    Map<EjsChallengeType, List<String>> requests,
  ) async {
    final uri = _validatedPlayerUri(playerUrl);

    final results = <String, String?>{};
    final uncached = <EjsChallengeType, List<String>>{};
    for (final entry in requests.entries) {
      final missing = <String>[];
      for (final challenge in entry.value) {
        final cached = _readCache(_solutionCache, (
          playerUrl,
          entry.key,
          challenge,
        ));
        if (cached == null) {
          missing.add(challenge);
        } else {
          results[challenge] = cached;
        }
      }
      if (missing.isNotEmpty) {
        uncached[entry.key] = missing;
      }
    }
    if (uncached.isEmpty) {
      return results;
    }

    await _ensureRuntime();
    var isPreprocessed = false;
    var player = _readCache(_preprocessedPlayerCache, playerUrl);
    if (player != null) {
      isPreprocessed = true;
    } else {
      player = _readCache(_playerCache, playerUrl);
      player ??= await _loadRawPlayer(uri, playerUrl);
    }

    final requestEntries = uncached.entries.toList(growable: false);
    final input = <String, dynamic>{
      'type': isPreprocessed ? 'preprocessed' : 'player',
      if (isPreprocessed) 'preprocessed_player': player else 'player': player,
      if (!isPreprocessed) 'output_preprocessed': true,
      'requests': <Map<String, dynamic>>[
        for (final entry in requestEntries)
          <String, dynamic>{'type': entry.key.name, 'challenges': entry.value},
      ],
    };
    final rawResult = await _callSolverWithRuntimeRecovery(input);
    final decoded = _decodeResult(rawResult);
    if (decoded['type'] != 'result') {
      throw EjsSolverException(
        'Unexpected EJS response type: ${decoded['type']}.',
      );
    }

    final preprocessed = decoded['preprocessed_player'];
    if (preprocessed is String && preprocessed.isNotEmpty) {
      _writeCache(_preprocessedPlayerCache, playerUrl, preprocessed);
    }

    final responses = decoded['responses'];
    if (responses is! List) {
      throw const EjsSolverException('EJS response did not contain responses.');
    }
    for (var index = 0; index < responses.length; index++) {
      final response = responses[index];
      if (response is! Map || response['type'] != 'result') {
        throw EjsSolverException('Unexpected EJS item at index $index.');
      }
      if (index >= requestEntries.length) {
        throw const EjsSolverException(
          'EJS returned too many response groups.',
        );
      }
      final data = response['data'];
      if (data is! Map) {
        throw EjsSolverException(
          'EJS item $index did not contain result data.',
        );
      }
      final requestType = requestEntries[index].key;
      for (final challenge in requestEntries[index].value) {
        final value = data[challenge];
        if (value is! String) {
          throw EjsSolverException(
            'EJS did not return a string result for "$challenge".',
          );
        }
        if (value.isEmpty) {
          throw EjsSolverException(
            'EJS returned an empty result for "$challenge".',
          );
        }
        // An unchanged `n` is not a successful transform: keeping it would
        // poison the cache and make every later CDN probe fail identically.
        if (requestType == EjsChallengeType.n && value == challenge) {
          throw EjsSolverException(
            'EJS returned an unchanged n challenge for "$challenge".',
          );
        }
        results[challenge] = value;
        _writeCache(_solutionCache, (playerUrl, requestType, challenge), value);
      }
    }
    for (final entry in requestEntries) {
      for (final challenge in entry.value) {
        results.putIfAbsent(challenge, () => null);
      }
    }
    return results;
  }

  Uri _validatedPlayerUri(String playerUrl) {
    final uri = Uri.tryParse(playerUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(
        playerUrl,
        'playerUrl',
        'Must be an absolute URL.',
      );
    }
    if (!isTrustedYouTubePlayerUri(uri)) {
      throw EjsSolverException(
        'Refusing to execute a player script outside the trusted YouTube '
        'HTTPS origin.',
      );
    }
    return uri;
  }

  Future<String> _loadRawPlayer(Uri uri, String playerUrl) async {
    final cached = _readCache(_playerCache, playerUrl);
    if (cached != null) return cached;
    final response = await _transport.get(
      uri,
      headers: const <String, String>{
        'accept': '*/*',
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/131.0.0.0 Safari/537.36',
      },
      timeout: playerRequestTimeout,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw EjsSolverException(
        'YouTube player returned HTTP ${response.statusCode}.',
      );
    }
    final effectiveUri = response.effectiveUri ?? uri;
    if (!isTrustedYouTubePlayerUri(effectiveUri)) {
      throw const EjsSolverException(
        'The YouTube player request redirected to an untrusted origin.',
      );
    }
    _writeCache(_playerCache, playerUrl, response.body);
    return response.body;
  }

  int? _extractSignatureTimestamp(String player) {
    final match = RegExp(
      r'(?:signatureTimestamp|sts)\s*[:=]\s*([0-9]{5})',
    ).firstMatch(player);
    return int.tryParse(match?.group(1) ?? '');
  }

  Future<Object?> _callSolverWithRuntimeRecovery(
    Map<String, dynamic> input,
  ) async {
    Future<Object?> invoke() => _runtime.callAsyncJavaScript(
      functionBody: _solveFunction,
      arguments: <String, dynamic>{'ejsInput': input},
      timeout: playerRequestTimeout,
    );

    try {
      return await invoke();
    } on YoutubeJavaScriptRuntimeException {
      // The headless runtime deliberately retires a renderer after a timeout
      // or process crash. Its new document is empty, so reinstall the pinned
      // modules once before surfacing the failure to the client ladder.
      _runtimeReady = null;
      await _ensureRuntime();
      return invoke();
    }
  }

  Future<void> _ensureRuntime() {
    final ready = _runtimeReady;
    if (ready != null) {
      return ready;
    }
    final next = () async {
      await _runtime.initialize();
      final modules = await _moduleSource.load();
      await _runtime.callAsyncJavaScript(
        functionBody: _installModulesFunction,
        arguments: <String, dynamic>{'ejsModules': modules},
        timeout: playerRequestTimeout,
      );
    }();
    _runtimeReady = next;
    unawaited(
      next.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_runtimeReady, next)) {
            _runtimeReady = null;
          }
        },
      ),
    );
    return next;
  }

  Map<String, dynamic> _decodeResult(Object? raw) {
    Object? value = raw;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException catch (error) {
        throw EjsSolverException('EJS returned invalid JSON.', cause: error);
      }
    }
    if (value is! Map) {
      throw const EjsSolverException('EJS returned an invalid result object.');
    }
    return Map<String, dynamic>.from(value);
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _queueTail;
    _queueTail = () async {
      try {
        await previous;
      } catch (_) {
        // A failed request must not poison subsequent queued requests.
      }
      if (_disposed) {
        completer.completeError(StateError('The EJS solver is disposed.'));
        return;
      }
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  T? _readCache<K, T>(Map<K, _CacheEntry<T>> cache, K key) {
    final entry = cache[key];
    if (entry == null) {
      return null;
    }
    if (!_clock().isBefore(entry.expiresAt)) {
      cache.remove(key);
      return null;
    }
    cache.remove(key);
    cache[key] = entry;
    return entry.value;
  }

  void _writeCache<K, T>(Map<K, _CacheEntry<T>> cache, K key, T value) {
    cache.remove(key);
    cache[key] = _CacheEntry<T>(value, _clock().add(cacheTtl));
    while (cache.length > maxCacheEntries) {
      cache.remove(cache.keys.first);
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    if (_ownsModuleSource) {
      _moduleSource.close();
    }
    if (_ownsTransport) {
      _transport.close();
    }
    if (disposeRuntime) {
      await _runtime.dispose();
    }
  }

  static const _installModulesFunction = r'''
    (0, eval)(ejsModules);
    if (typeof globalThis.jsc !== 'function') {
      throw new Error('EJS did not expose jsc');
    }
    return true;
  ''';

  static const _solveFunction = r'''
    if (typeof globalThis.jsc !== 'function') {
      throw new Error('EJS is not initialized');
    }
    return JSON.stringify(globalThis.jsc(ejsInput));
  ''';
}

class EjsSolverException implements Exception {
  const EjsSolverException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'EjsSolverException: $message'
      : 'EjsSolverException: $message ($cause)';
}

void _verifyEjsModule(EjsModuleSpec module, String body) {
  final actualHash = sha256.convert(utf8.encode(body)).toString();
  if (actualHash != module.sha256.toLowerCase()) {
    throw EjsSolverException('EJS ${module.name} failed SHA-256 verification.');
  }
}

void _appendEjsModule(List<String> source, EjsModuleSpec module, String body) {
  source.add(body);
  if (module.name == 'lib') {
    source.add('Object.assign(globalThis, lib);');
  }
}

class _CacheEntry<T> {
  const _CacheEntry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;
}
