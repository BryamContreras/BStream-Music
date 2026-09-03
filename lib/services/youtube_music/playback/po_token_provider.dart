import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../innertube_transport.dart';
import 'headless_inappwebview_runtime.dart';
import 'javascript_runtime.dart';
import 'po_token_binding.dart';

class YoutubePoTokenRequest {
  const YoutubePoTokenRequest({required this.videoId, this.clientName});

  final String videoId;
  final String? clientName;
}

class YoutubePoTokenRequirements {
  const YoutubePoTokenRequirements({
    required this.player,
    required this.gvs,
    this.playerBinding = YoutubePoTokenBinding.videoId,
    this.gvsBinding = YoutubePoTokenBinding.visitorData,
  });

  static const none = YoutubePoTokenRequirements(player: false, gvs: false);
  static const both = YoutubePoTokenRequirements(player: true, gvs: true);

  final bool player;
  final bool gvs;
  final YoutubePoTokenBinding playerBinding;
  final YoutubePoTokenBinding gvsBinding;

  bool get isRequired => player || gvs;
}

typedef YoutubePoTokenRequirementDetector =
    YoutubePoTokenRequirements Function(YoutubePoTokenRequest request);

class YoutubePoTokenData {
  const YoutubePoTokenData({
    required this.visitorData,
    required this.expiresAt,
    required this.playerBinding,
    required this.gvsBinding,
    this.usesWebsafeFallback = false,
    this.playerRequestPoToken,
    this.streamingDataPoToken,
  });

  final String visitorData;
  final String? playerRequestPoToken;
  final String? streamingDataPoToken;
  final DateTime expiresAt;
  final YoutubePoTokenBinding playerBinding;
  final YoutubePoTokenBinding gvsBinding;
  final bool usesWebsafeFallback;

  bool get hasPlayerToken => playerRequestPoToken?.isNotEmpty == true;
  bool get hasStreamingToken => streamingDataPoToken?.isNotEmpty == true;

  Map<String, Object?> toJson() => <String, Object?>{
    'available': hasPlayerToken || hasStreamingToken,
    'visitorData': visitorData,
    'playerRequestPoToken': playerRequestPoToken,
    'streamingDataPoToken': streamingDataPoToken,
    'expiresAtEpochMs': expiresAt.millisecondsSinceEpoch,
    'playerBinding': playerBinding.name,
    'gvsBinding': gvsBinding.name,
    'usesWebsafeFallback': usesWebsafeFallback,
  };
}

typedef YoutubeAssetLoader = Future<String> Function(String assetPath);
typedef YoutubePoTokenContinuation = bool Function();

/// Orchestrates Web BotGuard entirely from Dart.
///
/// HTTP stays outside the WebView and is routed through [InnerTubeTransport].
/// The WebView only executes the bundled harness and challenge interpreter.
class BotGuardPoTokenProvider {
  BotGuardPoTokenProvider({
    InnerTubeTransport? transport,
    YoutubeJavaScriptRuntimeFactory? runtimeFactory,
    YoutubeAssetLoader? assetLoader,
    YoutubePoTokenRequirementDetector? requirementDetector,
    DateTime Function()? clock,
    this.visitorDataTtl = const Duration(hours: 6),
    this.networkTimeout = const Duration(seconds: 15),
    this.javascriptTimeout = const Duration(seconds: 20),
    this.tokenExpiryMargin = const Duration(minutes: 10),
    this.maxTokenCacheEntries = 128,
    this.maxMintCacheEntries = 128,
    this.assetPath = 'assets/youtube/po_token.html',
  }) : _transport = transport ?? IoInnerTubeTransport(),
       _ownsTransport = transport == null,
       _runtimeFactory =
           runtimeFactory ?? (() => HeadlessInAppWebViewJavaScriptRuntime()),
       _assetLoader = assetLoader ?? rootBundle.loadString,
       _requirementDetector =
           requirementDetector ?? ((_) => YoutubePoTokenRequirements.both),
       _clock = clock ?? DateTime.now {
    if (visitorDataTtl <= Duration.zero) {
      throw ArgumentError.value(
        visitorDataTtl,
        'visitorDataTtl',
        'Must be positive.',
      );
    }
    if (networkTimeout <= Duration.zero) {
      throw ArgumentError.value(
        networkTimeout,
        'networkTimeout',
        'Must be positive.',
      );
    }
    if (javascriptTimeout <= Duration.zero) {
      throw ArgumentError.value(
        javascriptTimeout,
        'javascriptTimeout',
        'Must be positive.',
      );
    }
    if (tokenExpiryMargin.isNegative) {
      throw ArgumentError.value(
        tokenExpiryMargin,
        'tokenExpiryMargin',
        'Must not be negative.',
      );
    }
    if (maxTokenCacheEntries < 1 || maxMintCacheEntries < 1) {
      throw ArgumentError('PO token cache limits must be positive.');
    }
  }

  static final homepageUri = Uri.parse('https://www.youtube.com/');
  static final fallbackVisitorDataUri = Uri.parse(
    'https://music.youtube.com/sw.js_data',
  );
  static final attestationUri = Uri.parse(
    'https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false',
  );
  static final generateIntegrityTokenUri = Uri.parse(
    'https://jnn-pa.googleapis.com/'
    r'$rpc/google.internal.waa.v1.Waa/GenerateIT',
  );
  static final generateIntegrityTokenCompatibilityUri = Uri.parse(
    'https://www.youtube.com/api/jnn/v1/GenerateIT',
  );

  static const requestKey = 'O43z0dpjhgX20SCx4KAo';
  static const googleApiKey = 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw';
  static const fallbackWebClientVersion = '2.20260817.01.00';
  static const webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36';

  final InnerTubeTransport _transport;
  final bool _ownsTransport;
  final YoutubeJavaScriptRuntimeFactory _runtimeFactory;
  final YoutubeAssetLoader _assetLoader;
  final YoutubePoTokenRequirementDetector _requirementDetector;
  final DateTime Function() _clock;

  final Duration visitorDataTtl;
  final Duration networkTimeout;
  final Duration javascriptTimeout;
  final Duration tokenExpiryMargin;
  final int maxTokenCacheEntries;
  final int maxMintCacheEntries;
  final String assetPath;

  _BotGuardGenerator? _generator;
  Future<_BotGuardGenerator>? _generatorFlight;
  final _tokenCache = <_TokenCacheKey, YoutubePoTokenData>{};
  final _tokenFlights = <_TokenCacheKey, Future<YoutubePoTokenData>>{};
  int _cacheEpoch = 0;
  bool _disposed = false;

  YoutubePoTokenRequirements requirementsFor(YoutubePoTokenRequest request) =>
      _requirementDetector(request);

  /// Returns `null` when the configurable detector says the client needs no
  /// PO token. Otherwise returns every token requested by that detector.
  Future<YoutubePoTokenData?> getTokensIfRequired({
    required String videoId,
    String? clientName,
    YoutubePoTokenContinuation? shouldContinue,
  }) {
    final request = YoutubePoTokenRequest(
      videoId: videoId,
      clientName: clientName,
    );
    final requirements = requirementsFor(request);
    if (!requirements.isRequired) {
      return Future<YoutubePoTokenData?>.value();
    }
    return getTokens(
      videoId: videoId,
      requirements: requirements,
      shouldContinue: shouldContinue,
    );
  }

  /// Generates PO tokens with explicit bindings.
  ///
  /// Player and GVS tokens are minted against the explicit bindings in
  /// [requirements]. Bindings remain part of the cache key so a visitor-bound
  /// token can never be reused as a video-bound token (or vice versa).
  Future<YoutubePoTokenData> getTokens({
    required String videoId,
    YoutubePoTokenRequirements requirements = YoutubePoTokenRequirements.both,
    YoutubePoTokenContinuation? shouldContinue,
  }) {
    if (_disposed) {
      return Future<YoutubePoTokenData>.error(
        StateError('The PO token provider is disposed.'),
      );
    }
    if (videoId.trim().isEmpty) {
      return Future<YoutubePoTokenData>.error(
        ArgumentError.value(videoId, 'videoId', 'Must not be blank.'),
      );
    }
    if (!requirements.isRequired) {
      return Future<YoutubePoTokenData>.error(
        ArgumentError.value(
          requirements,
          'requirements',
          'At least one token must be requested.',
        ),
      );
    }
    try {
      _throwIfCancelled(shouldContinue);
    } catch (error, stackTrace) {
      return Future<YoutubePoTokenData>.error(error, stackTrace);
    }

    final key = _TokenCacheKey(videoId, requirements);
    final cached = _tokenCache[key];
    if (cached != null && _clock().isBefore(cached.expiresAt)) {
      return Future<YoutubePoTokenData>.value(cached);
    }
    _tokenCache.remove(key);
    final pending = _tokenFlights[key];
    if (pending != null) {
      return _observeForCaller(pending, shouldContinue);
    }

    final cacheEpoch = _cacheEpoch;
    // A coalesced operation must not inherit one caller's cancellation state:
    // playback, prefetch and download can legitimately request the same token
    // concurrently. Each observer applies its own continuation before and
    // after the shared bounded operation.
    final next = _getTokens(videoId, requirements, null);
    _tokenFlights[key] = next;
    next.then<void>(
      (value) {
        if (identical(_tokenFlights[key], next)) {
          _tokenFlights.remove(key);
          if (!_disposed && cacheEpoch == _cacheEpoch) {
            _cacheToken(key, value);
          }
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_tokenFlights[key], next)) {
          _tokenFlights.remove(key);
        }
      },
    );
    return _observeForCaller(next, shouldContinue);
  }

  Future<T> _observeForCaller<T>(
    Future<T> operation,
    YoutubePoTokenContinuation? shouldContinue,
  ) async {
    _throwIfCancelled(shouldContinue);
    final value = await operation;
    _throwIfCancelled(shouldContinue);
    return value;
  }

  /// Discards the current attestation session and all minted tokens.
  ///
  /// A confirmed GVS rejection is stronger evidence than the advertised token
  /// expiry. Rebuilding here prevents repeatedly attaching a server-rejected
  /// token to every format and profile.
  Future<void> invalidate() {
    if (_disposed) return Future<void>.value();
    _cacheEpoch += 1;
    _tokenFlights.clear();
    return _invalidateGenerator();
  }

  Future<YoutubePoTokenData> _getTokens(
    String videoId,
    YoutubePoTokenRequirements requirements,
    YoutubePoTokenContinuation? shouldContinue,
  ) async {
    _throwIfCancelled(shouldContinue);
    try {
      final generator = await _ensureGenerator(shouldContinue);
      _throwIfCancelled(shouldContinue);
      return await _mint(generator, videoId, requirements, shouldContinue);
    } catch (error) {
      if (error is PoTokenCancelledException || !_canContinue(shouldContinue)) {
        rethrow;
      }
      if (error is PoTokenException && !error.retryable) {
        rethrow;
      }
      await _invalidateGenerator();
      _throwIfCancelled(shouldContinue);
      final generator = await _ensureGenerator(shouldContinue);
      _throwIfCancelled(shouldContinue);
      return _mint(generator, videoId, requirements, shouldContinue);
    }
  }

  Future<YoutubePoTokenData> _mint(
    _BotGuardGenerator generator,
    String videoId,
    YoutubePoTokenRequirements requirements,
    YoutubePoTokenContinuation? shouldContinue,
  ) async {
    _throwIfCancelled(shouldContinue);
    final visitorData = generator.visitorData;
    String identifierFor(YoutubePoTokenBinding binding) =>
        binding == YoutubePoTokenBinding.visitorData ? visitorData : videoId;

    String? playerToken;
    String? streamingToken;
    if (requirements.player) {
      playerToken = await generator.mint(
        identifierFor(requirements.playerBinding),
      );
      _throwIfCancelled(shouldContinue);
    }
    if (requirements.gvs) {
      final binding = identifierFor(requirements.gvsBinding);
      final playerBinding = identifierFor(requirements.playerBinding);
      streamingToken = binding == playerBinding && playerToken != null
          ? playerToken
          : await generator.mint(binding);
      _throwIfCancelled(shouldContinue);
    }
    return YoutubePoTokenData(
      visitorData: visitorData,
      playerRequestPoToken: playerToken,
      streamingDataPoToken: streamingToken,
      expiresAt: generator.expiresAt,
      playerBinding: requirements.playerBinding,
      gvsBinding: requirements.gvsBinding,
      usesWebsafeFallback: generator.usesWebsafeFallback,
    );
  }

  Future<String> _fetchFallbackVisitorData(
    YoutubePoTokenContinuation? shouldContinue,
  ) async {
    _throwIfCancelled(shouldContinue);
    final response = await _transport.get(
      fallbackVisitorDataUri,
      headers: const <String, String>{
        'accept': 'application/json',
        'user-agent': webUserAgent,
      },
      timeout: networkTimeout,
    );
    _throwIfCancelled(shouldContinue);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PoTokenException(
        'YouTube visitorData returned HTTP ${response.statusCode}.',
      );
    }
    return BotGuardResponseParser.parseVisitorData(response.body);
  }

  Future<_BotGuardGenerator> _ensureGenerator(
    YoutubePoTokenContinuation? shouldContinue,
  ) {
    if (_disposed) {
      return Future<_BotGuardGenerator>.error(
        StateError('The PO token provider is disposed.'),
      );
    }
    try {
      _throwIfCancelled(shouldContinue);
    } catch (error, stackTrace) {
      return Future<_BotGuardGenerator>.error(error, stackTrace);
    }
    final current = _generator;
    if (current != null && _clock().isBefore(current.expiresAt)) {
      return Future<_BotGuardGenerator>.value(current);
    }
    final pending = _generatorFlight;
    if (pending != null) {
      return pending.then((value) {
        _throwIfCancelled(shouldContinue);
        return value;
      });
    }
    late final Future<_BotGuardGenerator> next;
    next = (() async {
      _BotGuardGenerator? created;
      try {
        created = await _createGenerator(shouldContinue);
        if (!_canContinue(shouldContinue)) {
          await _disposeGeneratorSafely(created);
          created = null;
          throw const PoTokenCancelledException();
        }
        if (_disposed || !identical(_generatorFlight, next)) {
          await _disposeGeneratorSafely(created);
          created = null;
          throw StateError('BotGuard generator creation was invalidated.');
        }
        final previous = _generator;
        _generator = created;
        if (previous != null && !identical(previous, created)) {
          await _disposeGeneratorSafely(previous);
        }
        return created;
      } finally {
        if (identical(_generatorFlight, next)) {
          _generatorFlight = null;
        }
      }
    })();
    _generatorFlight = next;
    return next;
  }

  Future<_BotGuardGenerator> _createGenerator(
    YoutubePoTokenContinuation? shouldContinue,
  ) async {
    final bootstrap = await _fetchBootstrap(shouldContinue);
    try {
      return await _createGeneratorFromBootstrap(bootstrap, shouldContinue);
    } on _IntegrityTokenWithheldException catch (homepageError) {
      if (bootstrap.source != BotGuardBootstrapSource.homepage) rethrow;
      try {
        final fallback = await _fetchAttestationBootstrap(
          shouldContinue,
          clientVersion: _webClientVersion(bootstrap.youtubeConfig),
        );
        return await _createGeneratorFromBootstrap(fallback, shouldContinue);
      } catch (fallbackError, stackTrace) {
        if (fallbackError is PoTokenCancelledException ||
            !_canContinue(shouldContinue)) {
          rethrow;
        }
        Error.throwWithStackTrace(
          PoTokenException(
            'Homepage integrity was withheld and the attestation fallback '
            'did not produce a usable token.',
            cause: _BootstrapFailure(homepageError, fallbackError),
            retryable:
                fallbackError is! PoTokenException || fallbackError.retryable,
          ),
          stackTrace,
        );
      }
    }
  }

  Future<_BotGuardGenerator> _createGeneratorFromBootstrap(
    BotGuardBootstrap bootstrap,
    YoutubePoTokenContinuation? shouldContinue,
  ) async {
    final runtime = _runtimeFactory();
    try {
      _throwIfCancelled(shouldContinue);
      final interpreterJavascript = await _fetchInterpreter(
        bootstrap.challenge.interpreterTrustedResourceUrl,
        shouldContinue,
      );
      _throwIfCancelled(shouldContinue);
      final challenge = bootstrap.challenge.withInterpreterJavascript(
        interpreterJavascript,
      );
      final html = await _assetLoader(assetPath);
      _throwIfCancelled(shouldContinue);
      await runtime.initialize(
        html: html,
        baseUrl: Uri.parse('https://www.youtube.com/'),
      );
      _throwIfCancelled(shouldContinue);
      await runtime.callAsyncJavaScript(
        functionBody: _configureBotGuardFunction,
        arguments: <String, dynamic>{'youtubeConfig': bootstrap.youtubeConfig},
        timeout: javascriptTimeout,
      );
      _throwIfCancelled(shouldContinue);
      final botguardResponse = await runtime.callAsyncJavaScript(
        functionBody: _runBotGuardFunction,
        arguments: <String, dynamic>{'challengeData': challenge.toJson()},
        timeout: javascriptTimeout,
      );
      _throwIfCancelled(shouldContinue);
      if (botguardResponse == null ||
          (botguardResponse is String && botguardResponse.isEmpty)) {
        throw const PoTokenException(
          'BotGuard returned an invalid snapshot response.',
        );
      }

      final integrity = await _obtainIntegrityToken(<Object>[
        requestKey,
        botguardResponse,
      ], shouldContinue);
      _throwIfCancelled(shouldContinue);
      final bytes = integrity.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw const PoTokenException(
          'BotGuard did not return a usable integrity token.',
        );
      }
      await runtime.callAsyncJavaScript(
        functionBody: _createMinterFunction,
        arguments: <String, dynamic>{
          'integrityTokenBytes': bytes.toList(growable: false),
        },
        timeout: javascriptTimeout,
      );
      _throwIfCancelled(shouldContinue);
      return _BotGuardGenerator(
        runtime: runtime,
        visitorData: bootstrap.visitorData,
        expiresAt: _earliest(integrity.expiresAt, _clock().add(visitorDataTtl)),
        javascriptTimeout: javascriptTimeout,
        maxMintCacheEntries: maxMintCacheEntries,
      );
    } catch (error, stackTrace) {
      await runtime.dispose();
      Error.throwWithStackTrace(
        error is PoTokenException
            ? error
            : PoTokenException('Could not initialize BotGuard.', cause: error),
        stackTrace,
      );
    }
  }

  Future<BotGuardBootstrap> _fetchBootstrap(
    YoutubePoTokenContinuation? shouldContinue,
  ) async {
    _throwIfCancelled(shouldContinue);
    Object? homepageError;
    String? homepageClientVersion;
    try {
      final response = await _transport.get(
        homepageUri,
        headers: const <String, String>{
          'accept': '*/*',
          'accept-language': 'en-US,en;q=0.9',
          'user-agent': webUserAgent,
        },
        timeout: networkTimeout,
      );
      _throwIfCancelled(shouldContinue);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PoTokenException(
          'YouTube homepage returned HTTP ${response.statusCode}.',
        );
      }
      homepageClientVersion = BotGuardResponseParser.tryParseWebClientVersion(
        response.body,
      );
      return BotGuardResponseParser.parseHomepage(response.body);
    } catch (error) {
      if (error is PoTokenCancelledException || !_canContinue(shouldContinue)) {
        rethrow;
      }
      homepageError = error;
    }

    try {
      return await _fetchAttestationBootstrap(
        shouldContinue,
        clientVersion: homepageClientVersion,
      );
    } catch (fallbackError) {
      if (fallbackError is PoTokenCancelledException ||
          !_canContinue(shouldContinue)) {
        rethrow;
      }
      throw PoTokenException(
        'Could not obtain a coherent BotGuard bootstrap.',
        cause: _BootstrapFailure(homepageError, fallbackError),
      );
    }
  }

  Future<BotGuardBootstrap> _fetchAttestationBootstrap(
    YoutubePoTokenContinuation? shouldContinue, {
    String? clientVersion,
  }) async {
    _throwIfCancelled(shouldContinue);
    final visitorData = await _fetchFallbackVisitorData(shouldContinue);
    final effectiveClientVersion = clientVersion ?? fallbackWebClientVersion;
    final context = <String, Object?>{
      'client': <String, Object?>{
        'clientName': 'WEB',
        'clientVersion': effectiveClientVersion,
        'visitorData': visitorData,
      },
    };
    final response = await _transport.postJson(
      attestationUri,
      headers: <String, String>{
        'accept': 'application/json',
        'content-type': 'application/json',
        'origin': 'https://www.youtube.com',
        'user-agent': webUserAgent,
        'x-goog-api-key': googleApiKey,
        'x-goog-visitor-id': visitorData,
        'x-user-agent': 'grpc-web-javascript/0.1',
        'x-youtube-client-name': '1',
        'x-youtube-client-version': effectiveClientVersion,
      },
      body: <String, Object?>{
        'context': context,
        'engagementType': 'ENGAGEMENT_TYPE_UNBOUND',
      },
      timeout: networkTimeout,
    );
    _throwIfCancelled(shouldContinue);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PoTokenException(
        'YouTube attestation endpoint returned HTTP ${response.statusCode}.',
      );
    }
    return BotGuardBootstrap(
      visitorData: visitorData,
      eventId: '',
      youtubeConfig: <String, Object?>{
        'VISITOR_DATA': visitorData,
        'INNERTUBE_CONTEXT': context,
      },
      challenge: BotGuardResponseParser.parseAttestation(response.body),
      source: BotGuardBootstrapSource.attestationFallback,
    );
  }

  String? _webClientVersion(Map<String, Object?> youtubeConfig) {
    final context = youtubeConfig['INNERTUBE_CONTEXT'];
    final client = context is Map ? context['client'] : null;
    final value = client is Map ? client['clientVersion'] : null;
    final text = value is String ? value.trim() : '';
    return text.isEmpty ? null : text;
  }

  Future<String> _fetchInterpreter(
    String value,
    YoutubePoTokenContinuation? shouldContinue,
  ) async {
    _throwIfCancelled(shouldContinue);
    final uri = BotGuardResponseParser.parseTrustedInterpreterUri(value);
    final response = await _transport.get(
      uri,
      headers: const <String, String>{
        'accept': '*/*',
        'referer': 'https://www.youtube.com/',
        'user-agent': webUserAgent,
      },
      timeout: networkTimeout,
    );
    _throwIfCancelled(shouldContinue);
    final effectiveUri = response.effectiveUri;
    if (effectiveUri != null) {
      BotGuardResponseParser.parseTrustedInterpreterUri(
        effectiveUri.toString(),
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PoTokenException(
        'BotGuard interpreter returned HTTP ${response.statusCode}.',
      );
    }
    if (response.body.trim().isEmpty) {
      throw const PoTokenException('BotGuard interpreter is empty.');
    }
    return response.body;
  }

  Future<BotGuardIntegrityToken> _obtainIntegrityToken(
    Object body,
    YoutubePoTokenContinuation? shouldContinue,
  ) async {
    Object? lastError;
    var sawRetryableFailure = false;
    for (final uri in <Uri>[
      generateIntegrityTokenUri,
      generateIntegrityTokenCompatibilityUri,
    ]) {
      _throwIfCancelled(shouldContinue);
      try {
        final response = await _transport.postJson(
          uri,
          headers: const <String, String>{
            'accept': 'application/json',
            'content-type': 'application/json+protobuf',
            'user-agent': webUserAgent,
            'x-goog-api-key': googleApiKey,
            'x-user-agent': 'grpc-web-javascript/0.1',
          },
          body: body,
          timeout: networkTimeout,
        );
        _throwIfCancelled(shouldContinue);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw PoTokenException(
            'BotGuard GenerateIT returned HTTP ${response.statusCode}.',
          );
        }
        if (response.body.trim().isEmpty) {
          throw const PoTokenException(
            'BotGuard GenerateIT returned an empty body.',
          );
        }
        final parsed = BotGuardResponseParser.parseIntegrityToken(
          response.body,
          now: _clock(),
          expiryMargin: tokenExpiryMargin,
        );
        if (parsed.hasIntegrityToken) return parsed;
        lastError = const PoTokenException(
          'BotGuard GenerateIT withheld the integrity token.',
          retryable: false,
        );
      } catch (error) {
        if (error is PoTokenCancelledException ||
            !_canContinue(shouldContinue)) {
          rethrow;
        }
        lastError = error;
        if (error is! PoTokenException || error.retryable) {
          sawRetryableFailure = true;
        }
      }
    }
    if (!sawRetryableFailure &&
        lastError is PoTokenException &&
        !lastError.retryable) {
      throw _IntegrityTokenWithheldException(lastError);
    }
    throw PoTokenException(
      'Every BotGuard GenerateIT endpoint failed.',
      cause: lastError,
      retryable: sawRetryableFailure,
    );
  }

  bool _canContinue(YoutubePoTokenContinuation? shouldContinue) =>
      !_disposed && (shouldContinue?.call() ?? true);

  void _throwIfCancelled(YoutubePoTokenContinuation? shouldContinue) {
    if (!_canContinue(shouldContinue)) {
      throw const PoTokenCancelledException();
    }
  }

  DateTime _earliest(DateTime first, DateTime second) =>
      first.isBefore(second) ? first : second;

  void _cacheToken(_TokenCacheKey key, YoutubePoTokenData value) {
    _tokenCache.remove(key);
    _tokenCache[key] = value;
    while (_tokenCache.length > maxTokenCacheEntries) {
      _tokenCache.remove(_tokenCache.keys.first);
    }
  }

  Future<void> _invalidateGenerator() async {
    final pending = _generatorFlight;
    // Let a shared bootstrap publish its generator before retiring it. Clearing
    // the flight first would make every other waiter fail because one caller
    // observed a rejected token.
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // Creation owns cleanup for its partially initialized runtime.
      }
    }
    final current = _generator;
    _generator = null;
    if (identical(_generatorFlight, pending)) _generatorFlight = null;
    _tokenCache.clear();
    if (current != null) {
      await _disposeGeneratorSafely(current);
    }
  }

  Future<void> _disposeGeneratorSafely(_BotGuardGenerator generator) async {
    try {
      await generator.dispose();
    } catch (_) {
      // Cleanup must not create an unhandled asynchronous error or prevent
      // transport shutdown. The generator is marked disposed before IO.
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cacheEpoch += 1;
    _tokenFlights.clear();
    await _invalidateGenerator();
    if (_ownsTransport) {
      _transport.close();
    }
  }

  static const _runBotGuardFunction = r'''
    const result = await runBotGuard(challengeData);
    globalThis.__bstreamWebPoSignalOutput = result.webPoSignalOutput;
    return typeof result.botguardResponse === 'string'
      ? result.botguardResponse
      : JSON.stringify(result.botguardResponse);
  ''';

  static const _configureBotGuardFunction = r'''
    configureBotGuard(youtubeConfig);
    return true;
  ''';

  static const _createMinterFunction = r'''
    if (!globalThis.__bstreamWebPoSignalOutput) {
      throw new Error('BotGuard signal output is unavailable');
    }
    await createPoTokenMinter(
      globalThis.__bstreamWebPoSignalOutput,
      new Uint8Array(integrityTokenBytes)
    );
    return true;
  ''';
}

enum BotGuardBootstrapSource { homepage, attestationFallback }

class BotGuardBootstrap {
  const BotGuardBootstrap({
    required this.visitorData,
    required this.eventId,
    required this.youtubeConfig,
    required this.challenge,
    required this.source,
  });

  final String visitorData;
  final String eventId;
  final Map<String, Object?> youtubeConfig;
  final BotGuardChallenge challenge;
  final BotGuardBootstrapSource source;
}

class BotGuardChallenge {
  const BotGuardChallenge({
    required this.interpreterTrustedResourceUrl,
    required this.interpreterHash,
    required this.program,
    required this.globalName,
    this.clientExperimentsStateBlob,
    this.interpreterJavascript,
  });

  final String? interpreterJavascript;
  final String interpreterTrustedResourceUrl;
  final String interpreterHash;
  final String program;
  final String globalName;
  final String? clientExperimentsStateBlob;

  BotGuardChallenge withInterpreterJavascript(String value) =>
      BotGuardChallenge(
        interpreterTrustedResourceUrl: interpreterTrustedResourceUrl,
        interpreterHash: interpreterHash,
        program: program,
        globalName: globalName,
        clientExperimentsStateBlob: clientExperimentsStateBlob,
        interpreterJavascript: value,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'interpreterJavascript': <String, Object?>{
      'privateDoNotAccessOrElseSafeScriptWrappedValue': interpreterJavascript,
      'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue':
          interpreterTrustedResourceUrl,
    },
    'interpreterHash': interpreterHash,
    'program': program,
    'globalName': globalName,
    'clientExperimentsStateBlob': clientExperimentsStateBlob,
  };
}

class BotGuardIntegrityToken {
  const BotGuardIntegrityToken({
    required this.bytes,
    required this.websafeFallbackToken,
    required this.expiresAt,
  });

  final Uint8List? bytes;
  final String? websafeFallbackToken;
  final DateTime expiresAt;

  bool get hasIntegrityToken => bytes != null;
  bool get usesWebsafeFallback => bytes == null;
}

class BotGuardResponseParser {
  const BotGuardResponseParser._();

  /// Parses the current YouTube homepage bootstrap without executing page JS.
  ///
  /// `ytcfg.set` contains strict JSON. `window.ytAtN`, however, is a JavaScript
  /// object whose `R` property is a quoted, `\\xHH`-escaped JSON string. The
  /// purpose-built scanner below accepts only those data constructs; it never
  /// evaluates arbitrary homepage source.
  static BotGuardBootstrap parseHomepage(String raw) {
    try {
      final config = _extractYoutubeConfig(raw);
      final eventId = _requiredString(config['EVENT_ID'], 'EVENT_ID');
      final directVisitorData = _nonEmptyString(config['VISITOR_DATA']);
      final context = config['INNERTUBE_CONTEXT'];
      final contextClient = context is Map ? context['client'] : null;
      final contextVisitorData = contextClient is Map
          ? _nonEmptyString(contextClient['visitorData'])
          : null;
      final visitorData = directVisitorData ?? contextVisitorData;
      if (visitorData == null) {
        throw const FormatException('Homepage visitorData is missing.');
      }
      final attestationJson = _extractYtAtNResponse(raw);
      final attestation = jsonDecode(attestationJson);
      if (attestation is! Map) {
        throw const FormatException('ytAtN R payload is not an object.');
      }
      return BotGuardBootstrap(
        visitorData: visitorData,
        eventId: eventId,
        youtubeConfig: Map<String, Object?>.from(config),
        challenge: _parseChallengeMap(attestation),
        source: BotGuardBootstrapSource.homepage,
      );
    } catch (error) {
      throw PoTokenException(
        'Invalid YouTube homepage BotGuard bootstrap.',
        cause: error,
      );
    }
  }

  /// Reads the current WEB identity even when the homepage challenge itself
  /// is absent or malformed, so the att/get fallback does not depend on a
  /// stale monthly version.
  static String? tryParseWebClientVersion(String raw) {
    try {
      final config = _extractYoutubeConfig(raw);
      final context = config['INNERTUBE_CONTEXT'];
      final client = context is Map ? context['client'] : null;
      final value =
          _nonEmptyString(config['INNERTUBE_CONTEXT_CLIENT_VERSION']) ??
          (client is Map ? _nonEmptyString(client['clientVersion']) : null);
      if (value == null ||
          value.length > 64 ||
          !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value)) {
        return null;
      }
      return value;
    } catch (_) {
      return null;
    }
  }

  static BotGuardChallenge parseAttestation(String raw) {
    try {
      final root = jsonDecode(raw);
      if (root is! Map) {
        throw const FormatException('Attestation root is not an object.');
      }
      return _parseChallengeMap(root);
    } catch (error) {
      throw PoTokenException(
        'Invalid YouTube attestation response.',
        cause: error,
      );
    }
  }

  static Uri parseTrustedInterpreterUri(String value) {
    try {
      final uri = Uri.parse(value.startsWith('//') ? 'https:$value' : value);
      final host = uri.host.toLowerCase();
      final trustedHost =
          host == 'google.com' ||
          host.endsWith('.google.com') ||
          host == 'youtube.com' ||
          host.endsWith('.youtube.com') ||
          host == 'googleapis.com' ||
          host.endsWith('.googleapis.com') ||
          host == 'gstatic.com' ||
          host.endsWith('.gstatic.com');
      if (uri.scheme != 'https' ||
          host.isEmpty ||
          !trustedHost ||
          uri.userInfo.isNotEmpty ||
          (uri.hasPort && uri.port != 443) ||
          uri.fragment.isNotEmpty) {
        throw const FormatException('Interpreter URL is not trusted.');
      }
      return uri;
    } catch (error) {
      throw PoTokenException('Invalid BotGuard interpreter URL.', cause: error);
    }
  }

  static BotGuardIntegrityToken parseIntegrityToken(
    String raw, {
    required DateTime now,
    Duration expiryMargin = const Duration(minutes: 10),
  }) {
    try {
      final data = jsonDecode(raw);
      if (data is! List || data.length < 2) {
        throw FormatException(
          'Integrity token response is invalid: ${_jsonShape(data)}.',
        );
      }
      final integrityValue = _nonEmptyString(data[0]);
      final fallbackValue = data.length > 3 ? _nonEmptyString(data[3]) : null;
      if (integrityValue == null && fallbackValue == null) {
        throw FormatException(
          'Integrity token response contains no token: ${_jsonShape(data)}.',
        );
      }
      if (fallbackValue != null &&
          !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(fallbackValue)) {
        throw const FormatException('Websafe fallback token is malformed.');
      }
      final ttlValue = data[1];
      final ttlSeconds = ttlValue is num ? ttlValue.toInt() : 3600;
      final adjusted = Duration(seconds: ttlSeconds) - expiryMargin;
      final lifetime = adjusted < const Duration(minutes: 1)
          ? const Duration(minutes: 1)
          : adjusted;
      return BotGuardIntegrityToken(
        bytes: integrityValue == null
            ? null
            : Uint8List.fromList(_decodeYoutubeBase64(integrityValue)),
        websafeFallbackToken: integrityValue == null ? fallbackValue : null,
        expiresAt: now.add(lifetime),
      );
    } catch (error) {
      throw PoTokenException(
        'Invalid BotGuard integrity-token response.',
        cause: error,
      );
    }
  }

  static String parseVisitorData(String raw) {
    try {
      final cleaned = raw.startsWith(")]}'") ? raw.substring(4) : raw;
      final root = jsonDecode(cleaned);
      final named = _findNamedVisitorData(root);
      if (named != null && named.isNotEmpty) {
        return named;
      }
      final fixed = _atPath(root, const <int>[0, 2, 0, 0, 13]);
      if (fixed is String && fixed.isNotEmpty) {
        return fixed;
      }
      throw const FormatException('visitorData was not found.');
    } catch (error) {
      throw PoTokenException(
        'Invalid YouTube visitorData response.',
        cause: error,
      );
    }
  }

  static String? _findNamedVisitorData(Object? value) {
    if (value is Map) {
      final direct = value['visitorData'] ?? value['visitor_data'];
      if (direct is String && direct.isNotEmpty) {
        return direct;
      }
      for (final nested in value.values) {
        final found = _findNamedVisitorData(nested);
        if (found != null) {
          return found;
        }
      }
    } else if (value is List) {
      for (final nested in value) {
        final found = _findNamedVisitorData(nested);
        if (found != null) {
          return found;
        }
      }
    }
    return null;
  }

  static Object? _atPath(Object? root, List<int> path) {
    Object? value = root;
    for (final index in path) {
      if (value is! List || index < 0 || index >= value.length) {
        return null;
      }
      value = value[index];
    }
    return value;
  }

  static BotGuardChallenge _parseChallengeMap(Map<dynamic, dynamic> root) {
    final value = root['bgChallenge'];
    if (value is! Map) {
      throw const FormatException('bgChallenge is missing.');
    }
    final interpreter = value['interpreterUrl'];
    if (interpreter is! Map) {
      throw const FormatException('interpreterUrl is missing.');
    }
    return BotGuardChallenge(
      interpreterTrustedResourceUrl: _requiredString(
        interpreter['privateDoNotAccessOrElseTrustedResourceUrlWrappedValue'],
        'interpreterUrl',
      ),
      interpreterHash: _requiredString(
        value['interpreterHash'],
        'interpreterHash',
      ),
      program: _requiredString(value['program'], 'program'),
      globalName: _requiredString(value['globalName'], 'globalName'),
      clientExperimentsStateBlob: _nonEmptyString(
        value['clientExperimentsStateBlob'],
      ),
    );
  }

  static Map<String, Object?> _extractYoutubeConfig(String raw) {
    const marker = 'ytcfg.set';
    final merged = <String, Object?>{};
    var cursor = 0;
    while (cursor < raw.length) {
      final markerIndex = raw.indexOf(marker, cursor);
      if (markerIndex < 0) break;
      final callStart = raw.indexOf('(', markerIndex + marker.length);
      if (callStart < 0) break;
      var objectStart = callStart + 1;
      while (objectStart < raw.length &&
          _isWhitespace(raw.codeUnitAt(objectStart))) {
        objectStart += 1;
      }
      if (objectStart >= raw.length || raw.codeUnitAt(objectStart) != 0x7b) {
        cursor = callStart + 1;
        continue;
      }
      try {
        final objectEnd = _findJsonObjectEnd(raw, objectStart);
        final decoded = jsonDecode(raw.substring(objectStart, objectEnd + 1));
        if (decoded is Map) {
          merged.addAll(Map<String, Object?>.from(decoded));
        }
        cursor = objectEnd + 1;
      } catch (_) {
        cursor = objectStart + 1;
      }
    }
    if (merged.isEmpty) {
      throw const FormatException('ytcfg.set JSON was not found.');
    }
    return merged;
  }

  static int _findJsonObjectEnd(String raw, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = start; index < raw.length; index += 1) {
      final code = raw.codeUnitAt(index);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (code == 0x5c) {
          escaped = true;
        } else if (code == 0x22) {
          inString = false;
        }
        continue;
      }
      if (code == 0x22) {
        inString = true;
      } else if (code == 0x7b) {
        depth += 1;
      } else if (code == 0x7d) {
        depth -= 1;
        if (depth == 0) return index;
        if (depth < 0) break;
      }
    }
    throw const FormatException('Unterminated ytcfg.set JSON object.');
  }

  static String _extractYtAtNResponse(String raw) {
    const marker = 'window.ytAtN';
    var searchFrom = 0;
    while (searchFrom < raw.length) {
      final markerIndex = raw.indexOf(marker, searchFrom);
      if (markerIndex < 0) break;
      final callStart = raw.indexOf('(', markerIndex + marker.length);
      if (callStart < 0) break;
      var index = callStart + 1;
      while (index < raw.length && _isWhitespace(raw.codeUnitAt(index))) {
        index += 1;
      }
      if (index >= raw.length || raw.codeUnitAt(index) != 0x7b) {
        searchFrom = callStart + 1;
        continue;
      }
      index += 1;
      while (index < raw.length) {
        index = _skipWhitespaceAndCommas(raw, index);
        if (index >= raw.length || raw.codeUnitAt(index) == 0x7d) break;
        late final String key;
        final code = raw.codeUnitAt(index);
        if (code == 0x22 || code == 0x27) {
          final parsed = _readJsString(raw, index);
          key = parsed.value;
          index = parsed.nextIndex;
        } else {
          final start = index;
          while (index < raw.length && _isIdentifier(raw.codeUnitAt(index))) {
            index += 1;
          }
          if (index == start) break;
          key = raw.substring(start, index);
        }
        while (index < raw.length && _isWhitespace(raw.codeUnitAt(index))) {
          index += 1;
        }
        if (index >= raw.length || raw.codeUnitAt(index) != 0x3a) break;
        index += 1;
        while (index < raw.length && _isWhitespace(raw.codeUnitAt(index))) {
          index += 1;
        }
        if (key == 'R') {
          if (index >= raw.length ||
              (raw.codeUnitAt(index) != 0x22 &&
                  raw.codeUnitAt(index) != 0x27)) {
            throw const FormatException('ytAtN R is not a string.');
          }
          return _readJsString(raw, index).value;
        }
        index = _skipJsValue(raw, index);
      }
      searchFrom = callStart + 1;
    }
    throw const FormatException('window.ytAtN R payload was not found.');
  }

  static int _skipJsValue(String raw, int index) {
    var depth = 0;
    while (index < raw.length) {
      final code = raw.codeUnitAt(index);
      if (code == 0x22 || code == 0x27) {
        index = _readJsString(raw, index).nextIndex;
        continue;
      }
      if (code == 0x7b || code == 0x5b || code == 0x28) {
        depth += 1;
      } else if (code == 0x7d || code == 0x5d || code == 0x29) {
        if (depth == 0) return index;
        depth -= 1;
      } else if (code == 0x2c && depth == 0) {
        return index + 1;
      }
      index += 1;
    }
    return index;
  }

  static _JsString _readJsString(String raw, int start) {
    final quote = raw.codeUnitAt(start);
    final output = StringBuffer();
    var index = start + 1;
    while (index < raw.length) {
      final code = raw.codeUnitAt(index++);
      if (code == quote) return _JsString(output.toString(), index);
      if (code != 0x5c) {
        output.writeCharCode(code);
        continue;
      }
      if (index >= raw.length) break;
      final escaped = raw.codeUnitAt(index++);
      switch (escaped) {
        case 0x78: // xHH
          output.writeCharCode(_readHex(raw, index, 2));
          index += 2;
        case 0x75: // uHHHH
          output.writeCharCode(_readHex(raw, index, 4));
          index += 4;
        case 0x6e:
          output.write('\n');
        case 0x72:
          output.write('\r');
        case 0x74:
          output.write('\t');
        case 0x62:
          output.write('\b');
        case 0x66:
          output.write('\f');
        case 0x76:
          output.writeCharCode(0x0b);
        case 0x30:
          output.writeCharCode(0);
        case 0x0a:
          break;
        case 0x0d:
          if (index < raw.length && raw.codeUnitAt(index) == 0x0a) index += 1;
        default:
          output.writeCharCode(escaped);
      }
    }
    throw const FormatException('Unterminated JavaScript string.');
  }

  static int _readHex(String raw, int start, int length) {
    if (start + length > raw.length) {
      throw const FormatException('Truncated JavaScript hex escape.');
    }
    final value = int.tryParse(raw.substring(start, start + length), radix: 16);
    if (value == null) {
      throw const FormatException('Invalid JavaScript hex escape.');
    }
    return value;
  }

  static int _skipWhitespaceAndCommas(String raw, int index) {
    while (index < raw.length) {
      final code = raw.codeUnitAt(index);
      if (!_isWhitespace(code) && code != 0x2c) break;
      index += 1;
    }
    return index;
  }

  static bool _isWhitespace(int code) =>
      code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d;

  static bool _isIdentifier(int code) =>
      (code >= 0x41 && code <= 0x5a) ||
      (code >= 0x61 && code <= 0x7a) ||
      (code >= 0x30 && code <= 0x39) ||
      code == 0x5f ||
      code == 0x24;

  static String? _nonEmptyString(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }

  static String _jsonShape(Object? value) {
    if (value is List) {
      return 'array(length=${value.length}, '
          'types=${value.map((item) => item.runtimeType).join(',')})';
    }
    if (value is Map) {
      return 'object(keys=${value.keys.join(',')})';
    }
    return value == null ? 'null' : value.runtimeType.toString();
  }

  static String _requiredString(Object? value, String name) {
    if (value is! String || value.isEmpty) {
      throw FormatException('$name is missing.');
    }
    return value;
  }

  static List<int> _decodeYoutubeBase64(String value) {
    var normalized = value
        .replaceAll('-', '+')
        .replaceAll('_', '/')
        .replaceAll('.', '=');
    normalized += '=' * ((4 - normalized.length % 4) % 4);
    return base64.decode(normalized);
  }
}

final class _JsString {
  const _JsString(this.value, this.nextIndex);

  final String value;
  final int nextIndex;
}

final class _BootstrapFailure {
  const _BootstrapFailure(this.homepage, this.fallback);

  final Object? homepage;
  final Object fallback;

  @override
  String toString() => 'homepage: $homepage; fallback: $fallback';
}

class PoTokenException implements Exception {
  const PoTokenException(this.message, {this.cause, this.retryable = true});

  final String message;
  final Object? cause;
  final bool retryable;

  @override
  String toString() => cause == null
      ? 'PoTokenException: $message'
      : 'PoTokenException: $message ($cause)';
}

final class _IntegrityTokenWithheldException extends PoTokenException {
  const _IntegrityTokenWithheldException(Object cause)
    : super(
        'Every BotGuard GenerateIT endpoint withheld the integrity token.',
        cause: cause,
        retryable: false,
      );
}

final class PoTokenCancelledException extends PoTokenException {
  const PoTokenCancelledException()
    : super('PO-token generation was cancelled.');
}

class _BotGuardGenerator {
  _BotGuardGenerator({
    required this.runtime,
    required this.visitorData,
    required this.expiresAt,
    required this.javascriptTimeout,
    required this.maxMintCacheEntries,
  });

  final YoutubeJavaScriptRuntime runtime;
  final String visitorData;
  final DateTime expiresAt;
  final Duration javascriptTimeout;
  final int maxMintCacheEntries;
  final _mintCache = <String, String>{};
  final _mintFlights = <String, Future<String>>{};
  Future<void> _runtimeTail = Future<void>.value();
  bool _disposed = false;

  bool get usesWebsafeFallback => false;

  Future<String> mint(String identifier) {
    if (_disposed) {
      return Future<String>.error(
        StateError('BotGuard generator is disposed.'),
      );
    }
    final cached = _mintCache[identifier];
    if (cached != null) {
      return Future<String>.value(cached);
    }
    final pending = _mintFlights[identifier];
    if (pending != null) {
      return pending;
    }
    final next = _mint(identifier);
    _mintFlights[identifier] = next;
    next.then<void>(
      (value) {
        if (identical(_mintFlights[identifier], next)) {
          _mintFlights.remove(identifier);
          _cacheMint(identifier, value);
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_mintFlights[identifier], next)) {
          _mintFlights.remove(identifier);
        }
      },
    );
    return next;
  }

  void _cacheMint(String identifier, String value) {
    _mintCache.remove(identifier);
    _mintCache[identifier] = value;
    while (_mintCache.length > maxMintCacheEntries) {
      _mintCache.remove(_mintCache.keys.first);
    }
  }

  Future<String> _mint(String identifier) {
    return _serializeRuntime(() async {
      final raw = await runtime.callAsyncJavaScript(
        functionBody: _mintFunction,
        arguments: <String, dynamic>{
          'identifierBytes': utf8.encode(identifier),
        },
        timeout: javascriptTimeout,
      );
      if (raw is! List) {
        throw const PoTokenException(
          'BotGuard returned invalid PO-token bytes.',
        );
      }
      final bytes = <int>[];
      for (final value in raw) {
        if (value is! num || value < 0 || value > 255) {
          throw const PoTokenException(
            'BotGuard returned invalid PO-token bytes.',
          );
        }
        bytes.add(value.toInt());
      }
      return base64Url.encode(bytes).replaceAll('=', '');
    });
  }

  Future<T> _serializeRuntime<T>(Future<T> Function() operation) async {
    final previous = _runtimeTail;
    final release = Completer<void>();
    _runtimeTail = release.future;
    try {
      await previous;
      if (_disposed) {
        throw StateError('BotGuard generator is disposed.');
      }
      return await operation();
    } finally {
      release.complete();
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _runtimeTail;
    await runtime.dispose();
  }

  static const _mintFunction = r'''
    const value = await obtainPoToken(new Uint8Array(identifierBytes));
    return Array.from(value);
  ''';
}

class _TokenCacheKey {
  const _TokenCacheKey(this.videoId, this.requirements);

  final String videoId;
  final YoutubePoTokenRequirements requirements;

  @override
  bool operator ==(Object other) =>
      other is _TokenCacheKey &&
      other.videoId == videoId &&
      other.requirements.player == requirements.player &&
      other.requirements.gvs == requirements.gvs &&
      other.requirements.playerBinding == requirements.playerBinding &&
      other.requirements.gvsBinding == requirements.gvsBinding;

  @override
  int get hashCode => Object.hash(
    videoId,
    requirements.player,
    requirements.gvs,
    requirements.playerBinding,
    requirements.gvsBinding,
  );
}
