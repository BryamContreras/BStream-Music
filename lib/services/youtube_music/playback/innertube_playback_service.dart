import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../innertube_search_service.dart';
import 'ejs_solver.dart';
import 'innertube_client_profile.dart';
import 'innertube_client_router.dart';
import 'innertube_player_bootstrap.dart';
import 'innertube_player_response_parser.dart';
import 'innertube_stream_models.dart';
import 'innertube_stream_validator.dart';
import 'innertube_video_id.dart';
import 'javascript_runtime.dart';
import 'po_token_binding.dart';
import 'po_token_provider.dart';

typedef InnerTubeContinuation = bool Function();

typedef InnerTubePoTokenLoader =
    Future<YoutubePoTokenData> Function({
      required String videoId,
      required YoutubePoTokenRequirements requirements,
    });

typedef InnerTubeChallengeSolver =
    Future<String> Function(
      String playerUrl,
      EjsChallengeType type,
      String challenge,
    );

typedef InnerTubePlayerUrlLoader = Future<Uri> Function(String videoId);
typedef InnerTubeSignatureTimestampLoader = Future<int?> Function(Uri player);
typedef InnerTubePlaybackDelay = Future<void> Function(Duration duration);
typedef InnerTubeAudioFormatPredicate =
    bool Function(InnerTubeAudioFormat format);

Future<void> defaultInnerTubePlaybackDelay(Duration duration) =>
    Future<void>.delayed(duration);

final class InnerTubeResolvedAudio {
  const InnerTubeResolvedAudio({
    required this.videoId,
    required this.uri,
    required this.headers,
    required this.profile,
    required this.format,
    required this.expiresAt,
    required this.resolutionElapsed,
    required this.probe,
  });

  final String videoId;
  final Uri uri;
  final Map<String, String> headers;
  final InnerTubeClientProfile profile;
  final InnerTubeAudioFormat format;
  final DateTime expiresAt;
  final Duration resolutionElapsed;
  final InnerTubeStreamProbe probe;

  String get attemptKey => '${profile.key}:${format.itag}';

  String get extension => switch (format.container.toLowerCase()) {
    'mp4' => format.isAudioOnly ? 'm4a' : 'mp4',
    'webm' => 'webm',
    final value when value.isNotEmpty => value,
    _ => 'audio',
  };

  String? get codec => format.audioCodec;
}

final class InnerTubePlaybackFailure {
  const InnerTubePlaybackFailure({
    required this.profile,
    required this.kind,
    required this.error,
  });

  final InnerTubeClientProfile profile;
  final InnerTubeClientFailureKind kind;
  final Object error;
}

final class InnerTubePlaybackException implements Exception {
  InnerTubePlaybackException(
    this.videoId,
    Iterable<InnerTubePlaybackFailure> failures,
  ) : failures = List<InnerTubePlaybackFailure>.unmodifiable(failures);

  final String videoId;
  final List<InnerTubePlaybackFailure> failures;

  Object? get cause => failures.isEmpty ? null : failures.last.error;
  InnerTubeClientFailureKind? get kind =>
      failures.isEmpty ? null : failures.last.kind;

  /// At least one client proved the video playable and exposed a direct format
  /// carrying audio, but only as a muxed audio/video stream. The relaxed retry
  /// still performs the normal deep media validation before returning it.
  bool get canRetryWithMuxed {
    return failures.any((failure) {
      final error = failure.error;
      return error is InnerTubeClientResponseException &&
          error.muxedFallbackAvailable;
    });
  }

  @override
  String toString() {
    if (failures.isEmpty) {
      return 'No InnerTube playback client was available for $videoId.';
    }
    final clients = failures.map((failure) => failure.profile.key).join(', ');
    return 'No InnerTube client returned playable audio for $videoId '
        '(tried $clients). Last error: ${failures.last.error}';
  }
}

/// A media URL contains a player challenge but no EJS solver is available on
/// the current platform.
///
/// The challenge value itself is deliberately omitted so diagnostics never
/// disclose signed media URL material.
final class InnerTubeChallengeUnavailableException implements Exception {
  const InnerTubeChallengeUnavailableException(this.challengeType);

  final EjsChallengeType challengeType;

  @override
  String toString() =>
      'InnerTubeChallengeUnavailableException: No EJS solver is available '
      'for the ${challengeType.name} challenge.';
}

final class InnerTubeClientResponseException implements Exception {
  const InnerTubeClientResponseException(
    this.message, {
    this.statusCode,
    this.cause,
    this.affectsClientHealth = true,
    this.muxedFallbackAvailable = false,
  });

  final String message;
  final int? statusCode;
  final Object? cause;

  /// Whether this failure says anything about the client profile itself.
  ///
  /// Content-specific states such as private, region-blocked, or DRM-only
  /// videos must not put an otherwise healthy profile into cooldown.
  final bool affectsClientHealth;

  /// Whether this failure was caused only by an audio-only requirement while
  /// the same response contained a usable muxed format carrying audio.
  final bool muxedFallbackAvailable;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'InnerTubeClientResponseException: $message$status';
  }
}

/// Resolves direct media URLs through a maintained, ordered set of InnerTube
/// clients. Every selected URL is validated before it escapes this service.
class InnerTubePlaybackService {
  InnerTubePlaybackService({
    InnerTubeTransport? transport,
    InnerTubeStreamValidator? validator,
    InnerTubeClientRouter? router,
    this.parser = const InnerTubePlayerResponseParser(),
    this.visitorDataStore,
    EjsSolver? ejsSolver,
    BotGuardPoTokenProvider? poTokenProvider,
    InnerTubeChallengeSolver? challengeSolver,
    InnerTubePoTokenLoader? poTokenLoader,
    InnerTubePlayerUrlLoader? playerUrlLoader,
    InnerTubeSignatureTimestampLoader? signatureTimestampLoader,
    InnerTubePlayerBootstrapSource? playerBootstrap,
    this.language = 'en',
    this.region = 'US',
    this.requestTimeout = const Duration(seconds: 12),
    this.resolveTimeout = const Duration(seconds: 90),
    this.maxFormatsPerClient = 4,
    this.maxRequestAttempts = 2,
    this.ejsFailureCooldown = const Duration(minutes: 2),
    this.webPoFailureCooldown = const Duration(minutes: 2),
    this.retryDelay = defaultInnerTubePlaybackDelay,
    this.disposeChallengeDependencies = true,
    this.audioFormatPredicate,
    bool? bootstrapVisitorData,
    DateTime Function()? clock,
  }) : _transport = transport ?? IoInnerTubeTransport(),
       _ownsTransport = transport == null,
       _validator = validator ?? IoInnerTubeStreamValidator(),
       _router = router ?? InnerTubeClientRouter(),
       _ejsSolver = ejsSolver,
       _poTokenProvider = poTokenProvider,
       _injectedChallengeSolver = challengeSolver,
       _injectedPoTokenLoader = poTokenLoader,
       _injectedPlayerUrlLoader = playerUrlLoader,
       _injectedSignatureTimestampLoader = signatureTimestampLoader,
       _bootstrapVisitorData =
           bootstrapVisitorData ??
           transport == null || visitorDataStore != null,
       _clock = clock ?? DateTime.now {
    if (requestTimeout <= Duration.zero || resolveTimeout <= Duration.zero) {
      throw ArgumentError('Playback timeouts must be positive.');
    }
    if (maxFormatsPerClient < 1 || maxRequestAttempts < 1) {
      throw ArgumentError('Playback attempt limits must be positive.');
    }
    if (ejsFailureCooldown.isNegative) {
      throw ArgumentError.value(
        ejsFailureCooldown,
        'ejsFailureCooldown',
        'Must not be negative.',
      );
    }
    if (webPoFailureCooldown.isNegative) {
      throw ArgumentError.value(
        webPoFailureCooldown,
        'webPoFailureCooldown',
        'Must not be negative.',
      );
    }
    if (challengeSolver != null && ejsSolver != null) {
      throw ArgumentError('Provide challengeSolver or ejsSolver, not both.');
    }
    if (poTokenLoader != null && poTokenProvider != null) {
      throw ArgumentError(
        'Provide poTokenLoader or poTokenProvider, not both.',
      );
    }
    _playerBootstrap =
        playerBootstrap ??
        InnerTubePlayerBootstrapper(
          transport: _transport,
          requestTimeout: requestTimeout,
          language: language,
          region: region,
          clock: _clock,
        );
  }

  final InnerTubeTransport _transport;
  final bool _ownsTransport;
  final InnerTubeStreamValidator _validator;
  final InnerTubeClientRouter _router;
  final InnerTubePlayerResponseParser parser;
  final InnerTubeVisitorDataStore? visitorDataStore;
  final EjsSolver? _ejsSolver;
  final BotGuardPoTokenProvider? _poTokenProvider;
  final InnerTubeChallengeSolver? _injectedChallengeSolver;
  final InnerTubePoTokenLoader? _injectedPoTokenLoader;
  final InnerTubePlayerUrlLoader? _injectedPlayerUrlLoader;
  final InnerTubeSignatureTimestampLoader? _injectedSignatureTimestampLoader;
  final bool _bootstrapVisitorData;
  final DateTime Function() _clock;
  late final InnerTubePlayerBootstrapSource _playerBootstrap;

  final String language;
  final String region;
  final Duration requestTimeout;
  final Duration resolveTimeout;
  final int maxFormatsPerClient;
  final int maxRequestAttempts;
  final Duration ejsFailureCooldown;
  final Duration webPoFailureCooldown;
  final InnerTubePlaybackDelay retryDelay;
  final bool disposeChallengeDependencies;
  final InnerTubeAudioFormatPredicate? audioFormatPredicate;

  final Map<(String, bool, bool, String), Future<InnerTubeResolvedAudio>>
  _inFlight = {};
  String? _sessionVisitorData;
  DateTime? _ejsUnavailableUntil;
  Object? _ejsUnavailableError;
  DateTime? _webPoUnavailableUntil;
  Object? _webPoUnavailableError;
  bool _disposed = false;

  InnerTubeClientRouter get router => _router;

  bool get supportsJavaScript =>
      _injectedChallengeSolver != null || _ejsSolver != null;

  bool get supportsWebPo =>
      _injectedPoTokenLoader != null || _poTokenProvider != null;

  Future<InnerTubeResolvedAudio> resolve(
    String videoReference, {
    bool skipPrimary = false,
    bool requireAudioOnly = false,
    Set<String> excludedProfileKeys = const <String>{},
    InnerTubeContinuation? shouldContinue,
  }) {
    _ensureActive();
    final videoId = InnerTubeVideoId.extract(videoReference);
    if (videoId == null) {
      return Future<InnerTubeResolvedAudio>.error(
        FormatException('Not a valid YouTube video reference: $videoReference'),
      );
    }
    final exclusions = Set<String>.unmodifiable(
      excludedProfileKeys
          .map((key) => key.trim())
          .where((key) => key.isNotEmpty),
    );

    // Callback-bearing requests represent a particular player's generation;
    // do not let that callback cancel another caller sharing the same future.
    if (shouldContinue != null) {
      return _resolveWithTimeout(
        videoId,
        skipPrimary: skipPrimary,
        requireAudioOnly: requireAudioOnly,
        excludedProfileKeys: exclusions,
        shouldContinue: shouldContinue,
      );
    }
    final exclusionKey = (exclusions.toList()..sort()).join('\u0000');
    final key = (videoId.value, skipPrimary, requireAudioOnly, exclusionKey);
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _resolveWithTimeout(
      videoId,
      skipPrimary: skipPrimary,
      requireAudioOnly: requireAudioOnly,
      excludedProfileKeys: exclusions,
    );
    _inFlight[key] = future;
    unawaited(
      future.then<void>(
        (_) {
          if (identical(_inFlight[key], future)) _inFlight.remove(key);
        },
        onError: (Object _, StackTrace _) {
          if (identical(_inFlight[key], future)) _inFlight.remove(key);
        },
      ),
    );
    return future;
  }

  Future<InnerTubeResolvedAudio> _resolveWithTimeout(
    InnerTubeVideoId videoId, {
    required bool skipPrimary,
    required bool requireAudioOnly,
    required Set<String> excludedProfileKeys,
    InnerTubeContinuation? shouldContinue,
  }) {
    var withinDeadline = true;
    bool continueResolution() =>
        withinDeadline && (shouldContinue?.call() ?? true);
    return _resolve(
      videoId,
      skipPrimary: skipPrimary,
      requireAudioOnly: requireAudioOnly,
      excludedProfileKeys: excludedProfileKeys,
      shouldContinue: continueResolution,
    ).timeout(
      resolveTimeout,
      onTimeout: () {
        // Future.timeout cannot cancel an arbitrary Dart Future. Mark the
        // underlying operation stale so that, after its current bounded I/O
        // completes, it cannot start another phase or mutate client health.
        withinDeadline = false;
        throw TimeoutException(
          'InnerTube playback resolution timed out for ${videoId.value}.',
          resolveTimeout,
        );
      },
    );
  }

  Future<InnerTubeResolvedAudio> _resolve(
    InnerTubeVideoId videoId, {
    required bool skipPrimary,
    required bool requireAudioOnly,
    required Set<String> excludedProfileKeys,
    InnerTubeContinuation? shouldContinue,
  }) async {
    final stopwatch = Stopwatch()..start();
    final failures = <InnerTubePlaybackFailure>[];
    final profiles = _router.candidates(
      skipPrimary: skipPrimary,
      excludedProfileKeys: excludedProfileKeys,
      supportsJavaScript: supportsJavaScript,
      supportsWebPo: supportsWebPo,
    );
    for (final profile in profiles) {
      _ensureCurrent(shouldContinue);
      // Re-read shared breakers for every profile. Another concurrent resolve
      // may have opened one while this resolve was awaiting its previous
      // profile.
      if (profile.capabilities.supportsWebPo && _isWebPoCoolingDown) {
        failures.add(
          InnerTubePlaybackFailure(
            profile: profile,
            kind: InnerTubeClientFailureKind.challengeUnavailable,
            error:
                _webPoUnavailableError ??
                const PoTokenException(
                  'Web PO token generation is temporarily unavailable.',
                ),
          ),
        );
        continue;
      }
      if (profile.capabilities.requiresPlayerJavaScript && _isEjsCoolingDown) {
        failures.add(
          InnerTubePlaybackFailure(
            profile: profile,
            kind: InnerTubeClientFailureKind.challengeUnavailable,
            error:
                _ejsUnavailableError ??
                const EjsSolverException(
                  'EJS challenge solving is temporarily unavailable.',
                ),
          ),
        );
        continue;
      }
      final attemptStopwatch = Stopwatch()..start();
      try {
        final resolved = await _resolveWithProfile(
          videoId,
          profile,
          requireAudioOnly: requireAudioOnly,
          shouldContinue: shouldContinue,
          totalStopwatch: stopwatch,
        );
        _ensureCurrent(shouldContinue);
        _router.recordSuccess(profile.key, attemptStopwatch.elapsed);
        developer.log(
          'resolved client=${profile.key}, video=${videoId.value}, '
          'itag=${resolved.format.itag}, '
          'elapsedMs=${stopwatch.elapsedMilliseconds}',
          name: 'BStreamInnerTube',
        );
        return resolved;
      } catch (error) {
        // Resolution may have timed out or been superseded while an awaited
        // phase was finishing. Never count that stale result as a client
        // failure, and do not continue into another fallback profile.
        _ensureCurrent(shouldContinue);
        final failureKind = _failureKind(error);
        if (profile.capabilities.supportsWebPo &&
            _isWebPoCapabilityFailure(error)) {
          _tripWebPoBreaker(error);
        }
        if (_isEjsCapabilityFailure(error)) {
          _tripEjsBreaker(error);
        }
        failures.add(
          InnerTubePlaybackFailure(
            profile: profile,
            kind: failureKind,
            error: error,
          ),
        );
        if (_affectsClientHealth(error)) {
          _router.recordFailure(profile.key, failureKind);
        }
        developer.log(
          'client failed client=${profile.key}, video=${videoId.value}, '
          'elapsedMs=${attemptStopwatch.elapsedMilliseconds}',
          name: 'BStreamInnerTube',
          error: error,
        );
      } finally {
        attemptStopwatch.stop();
      }
    }
    stopwatch.stop();
    throw InnerTubePlaybackException(videoId.value, failures);
  }

  Future<InnerTubeResolvedAudio> _resolveWithProfile(
    InnerTubeVideoId videoId,
    InnerTubeClientProfile profile, {
    required bool requireAudioOnly,
    required InnerTubeContinuation? shouldContinue,
    required Stopwatch totalStopwatch,
  }) async {
    var prepared = await _preparePlayerRequest(
      videoId,
      profile,
      shouldContinue: shouldContinue,
    );
    var response = await _requestPlayer(
      videoId,
      profile,
      visitorData: prepared.visitorData,
      playerPoToken: prepared.tokens?.playerRequestPoToken,
      signatureTimestamp: prepared.signatureTimestamp,
      encryptedHostFlags: prepared.encryptedHostFlags,
      clientVersion: prepared.clientVersion,
      embeddedPlayerEncryptedContext: prepared.embeddedPlayerEncryptedContext,
      shouldContinue: shouldContinue,
    );
    if (_isBotChallenge(response)) {
      prepared = await _preparePlayerRequest(
        videoId,
        profile,
        shouldContinue: shouldContinue,
        forceRefresh: true,
        forcePlayerPo:
            profile.capabilities.playerPoToken ==
            InnerTubePoTokenRequirement.optional,
      );
      response = await _requestPlayer(
        videoId,
        profile,
        visitorData: prepared.visitorData,
        playerPoToken: prepared.tokens?.playerRequestPoToken,
        signatureTimestamp: prepared.signatureTimestamp,
        encryptedHostFlags: prepared.encryptedHostFlags,
        clientVersion: prepared.clientVersion,
        embeddedPlayerEncryptedContext: prepared.embeddedPlayerEncryptedContext,
        shouldContinue: shouldContinue,
      );
    }
    _ensureCurrent(shouldContinue);
    if (response.videoId != null && response.videoId != videoId.value) {
      throw InnerTubeClientResponseException(
        'The player response belongs to a different video.',
      );
    }
    if (!response.playability.isPlayable) {
      throw InnerTubeClientResponseException(
        response.playability.reason ??
            response.playability.subreason ??
            'The video is ${response.playability.rawStatus}.',
        affectsClientHealth: _playabilityAffectsClientHealth(response),
      );
    }
    final candidates = _orderedAudioFormats(
      response.audioFormats,
      requireAudioOnly: requireAudioOnly,
    );
    if (candidates.isEmpty) {
      final unsupportedFormatAvailable = response.audioFormats.any(
        (format) =>
            format.sourceUri != null &&
            format.hasAudio &&
            !format.hasDrm &&
            (!requireAudioOnly || format.isAudioOnly) &&
            !_acceptsAudioFormat(format),
      );
      final muxedFallbackAvailable =
          requireAudioOnly &&
          response.audioFormats.any(
            (format) =>
                format.sourceUri != null &&
                format.hasAudio &&
                !format.hasDrm &&
                !format.isAudioOnly &&
                _acceptsAudioFormat(format),
          );
      throw InnerTubeClientResponseException(
        unsupportedFormatAvailable
            ? 'The player response contains no audio format supported by '
                  'this platform.'
            : response.hasDrm
            ? 'The player response only exposes DRM-protected media.'
            : muxedFallbackAvailable
            ? 'The player response only exposes direct muxed audio.'
            : 'The player response contains no direct audio format.',
        affectsClientHealth:
            !unsupportedFormatAvailable &&
            !response.hasDrm &&
            !muxedFallbackAvailable,
        muxedFallbackAvailable: muxedFallbackAvailable,
      );
    }

    Object? lastError;
    var tokens = prepared.tokens;
    for (final format in candidates.take(maxFormatsPerClient)) {
      _ensureCurrent(shouldContinue);
      try {
        var uri = await _finalizeFormatUri(
          videoId.value,
          format,
          playerUrl: prepared.playerUrl,
          shouldContinue: shouldContinue,
        );
        _ensureCurrent(shouldContinue);
        if (tokens?.streamingDataPoToken case final token?
            when token.isNotEmpty) {
          uri = _replaceQueryParameter(uri, 'pot', token);
        }
        final headers = _mediaHeaders(profile);
        try {
          final probe = await _validator.validate(
            uri,
            headers: headers,
            contentLength: format.contentLength,
          );
          _ensureCurrent(shouldContinue);
          return InnerTubeResolvedAudio(
            videoId: videoId.value,
            uri: uri,
            headers: headers,
            profile: profile,
            format: format,
            expiresAt: _expiryFor(
              uri,
              response.expiresIn,
              poTokenExpiresAt: tokens?.expiresAt,
            ),
            resolutionElapsed: totalStopwatch.elapsed,
            probe: probe,
          );
        } on InnerTubeStreamValidationException catch (error) {
          // Modern Web GVS enforcement can bind the token either to videoId or
          // to visitorData. Try the alternate binding on the same media URL
          // before discarding the complete client response.
          if (!profile.capabilities.supportsWebPo ||
              !error.isPoTokenRejection ||
              tokens == null ||
              profile.capabilities.streamingDataPoTokenBindings.length < 2) {
            rethrow;
          }
          final alternate = await _loadPoTokens(
            videoId.value,
            profile,
            profile.capabilities.streamingDataPoTokenBindings[1],
            shouldContinue: shouldContinue,
          );
          _ensureCurrent(shouldContinue);
          final alternateToken = alternate.streamingDataPoToken;
          if (alternateToken == null || alternateToken.isEmpty) rethrow;
          if (alternateToken == tokens.streamingDataPoToken) rethrow;
          uri = _replaceQueryParameter(uri, 'pot', alternateToken);
          final probe = await _validator.validate(
            uri,
            headers: headers,
            contentLength: format.contentLength,
          );
          _ensureCurrent(shouldContinue);
          return InnerTubeResolvedAudio(
            videoId: videoId.value,
            uri: uri,
            headers: headers,
            profile: profile,
            format: format,
            expiresAt: _expiryFor(
              uri,
              response.expiresIn,
              poTokenExpiresAt: alternate.expiresAt,
            ),
            resolutionElapsed: totalStopwatch.elapsed,
            probe: probe,
          );
        }
      } catch (error) {
        lastError = error;
        if (_isPoTokenRejection(error) && profile.capabilities.supportsWebPo) {
          await _poTokenProvider?.invalidate();
          break;
        }
      }
    }
    throw InnerTubeClientResponseException(
      'Every direct audio format was rejected.',
      cause: lastError,
    );
  }

  Future<_PreparedPlayerRequest> _preparePlayerRequest(
    InnerTubeVideoId videoId,
    InnerTubeClientProfile profile, {
    required InnerTubeContinuation? shouldContinue,
    bool forceRefresh = false,
    bool forcePlayerPo = false,
  }) async {
    if (forceRefresh) {
      _playerBootstrap.invalidate();
      if (profile.capabilities.supportsWebPo) {
        await _poTokenProvider?.invalidate();
      }
    }

    var visitorData = forceRefresh ? null : await _readVisitorData();
    InnerTubePlayerBootstrap? bootstrap;
    final embedded = profile.isEmbedded;
    final bootstrapPage = _bootstrapPageFor(profile);
    final needsPlayerBootstrap =
        profile.capabilities.requiresPlayerJavaScript &&
        _injectedPlayerUrlLoader == null;
    final needsVisitorBootstrap =
        visitorData == null &&
        _bootstrapVisitorData &&
        !profile.capabilities.supportsWebPo;
    final requiresBootstrap = needsPlayerBootstrap || embedded;
    if (requiresBootstrap || needsVisitorBootstrap) {
      try {
        bootstrap = await _playerBootstrap.load(
          videoId.value,
          forceRefresh: forceRefresh,
          page: bootstrapPage,
          userAgent: profile.userAgent,
        );
        _ensureCurrent(shouldContinue);
      } catch (error, stackTrace) {
        _ensureCurrent(shouldContinue);
        if (requiresBootstrap) rethrow;
        developer.log(
          'optional visitor bootstrap failed client=${profile.key}, '
          'video=${videoId.value}',
          name: 'BStreamInnerTube',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // A page can transiently omit jsUrl while still exposing other ytcfg
    // values. Refresh the complete snapshot once so player URL, STS, visitor
    // identity and dynamic client metadata always come from one generation.
    if (needsPlayerBootstrap && bootstrap?.playerUrl == null) {
      bootstrap = await _playerBootstrap.load(
        videoId.value,
        forceRefresh: true,
        page: bootstrapPage,
        userAgent: profile.userAgent,
      );
      _ensureCurrent(shouldContinue);
    }

    final freshVisitor = bootstrap?.visitorData;
    if (!profile.capabilities.supportsWebPo &&
        freshVisitor != null &&
        freshVisitor.isNotEmpty) {
      visitorData = freshVisitor;
      await _persistVisitorData(freshVisitor);
    }

    YoutubePoTokenData? tokens;
    if (profile.capabilities.supportsWebPo) {
      tokens = await _loadPoTokens(
        videoId.value,
        profile,
        profile.capabilities.streamingDataPoTokenBindings.first,
        shouldContinue: shouldContinue,
        forcePlayerPo: forcePlayerPo,
      );
      visitorData = tokens.visitorData;
      await _persistVisitorData(visitorData);
    }
    _ensureCurrent(shouldContinue);

    Uri? playerUrl;
    int? signatureTimestamp;
    if (profile.capabilities.requiresPlayerJavaScript) {
      playerUrl = _injectedPlayerUrlLoader != null
          ? await _injectedPlayerUrlLoader(videoId.value)
          : bootstrap?.playerUrl;
      if (playerUrl == null) {
        throw const InnerTubeClientResponseException(
          'The YouTube page did not contain a player URL after refresh.',
        );
      }
      _ensureCurrent(shouldContinue);
      signatureTimestamp = bootstrap?.signatureTimestamp;
      if (signatureTimestamp == null) {
        final injected = _injectedSignatureTimestampLoader;
        if (injected != null) {
          signatureTimestamp = await injected(playerUrl);
        } else if (_ejsSolver != null) {
          signatureTimestamp = await _ejsSolver.signatureTimestamp(
            playerUrl.toString(),
          );
        }
      }
    }

    return _PreparedPlayerRequest(
      visitorData: visitorData,
      tokens: tokens,
      playerUrl: playerUrl,
      signatureTimestamp: signatureTimestamp,
      encryptedHostFlags: embedded ? bootstrap?.encryptedHostFlags : null,
      clientVersion: _matchingBootstrapVersion(profile, bootstrap),
      embeddedPlayerEncryptedContext: embedded
          ? bootstrap?.embeddedPlayerEncryptedContext
          : null,
    );
  }

  Future<InnerTubeParsedPlayerResponse> _requestPlayer(
    InnerTubeVideoId videoId,
    InnerTubeClientProfile profile, {
    required String? visitorData,
    required String? playerPoToken,
    required int? signatureTimestamp,
    required String? encryptedHostFlags,
    required String? clientVersion,
    required String? embeddedPlayerEncryptedContext,
    required InnerTubeContinuation? shouldContinue,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < maxRequestAttempts; attempt += 1) {
      _ensureCurrent(shouldContinue);
      try {
        final safeEncryptedHostFlags =
            encryptedHostFlags != null && encryptedHostFlags.isNotEmpty
            ? encryptedHostFlags
            : null;
        final context = _playerContext(
          profile,
          visitorData: visitorData,
          clientVersion: clientVersion,
          embeddedPlayerEncryptedContext: embeddedPlayerEncryptedContext,
        );
        final body = <String, Object?>{
          'context': context,
          'videoId': videoId.value,
          'playbackContext': <String, Object?>{
            'contentPlaybackContext': <String, Object?>{
              'html5Preference': 'HTML5_PREF_WANTS',
              'signatureTimestamp': ?signatureTimestamp,
              'encryptedHostFlags': ?safeEncryptedHostFlags,
            },
          },
          'contentCheckOk': true,
          'racyCheckOk': true,
          'videoCheckOk': true,
          if (playerPoToken != null && playerPoToken.isNotEmpty)
            'serviceIntegrityDimensions': <String, Object?>{
              'poToken': playerPoToken,
            },
        };
        final headers = <String, String>{
          ...profile.requestHeaders,
          'Accept-Language': _acceptLanguageHeader,
          if (profile.isEmbedded) 'Referer': 'https://www.reddit.com/',
          if (clientVersion != null && clientVersion.isNotEmpty)
            'X-YouTube-Client-Version': clientVersion,
          if (visitorData != null && visitorData.isNotEmpty)
            'X-Goog-Visitor-Id': visitorData,
        };
        final raw = await _transport.postJson(
          profile.playerEndpoint,
          headers: headers,
          body: body,
          timeout: requestTimeout,
        );
        _ensureCurrent(shouldContinue);
        if (raw.statusCode < 200 || raw.statusCode >= 300) {
          throw InnerTubeClientResponseException(
            'The player endpoint rejected the request.',
            statusCode: raw.statusCode,
          );
        }
        final decoded = jsonDecode(raw.body);
        if (decoded is! Map) {
          throw const InnerTubeClientResponseException(
            'The player endpoint returned an invalid JSON object.',
          );
        }
        return parser.parse(
          Map<String, dynamic>.from(decoded),
          clientId: profile.key,
        );
      } catch (error) {
        lastError = error;
        if (attempt + 1 >= maxRequestAttempts || !_isRetryable(error)) rethrow;
        await retryDelay(Duration(milliseconds: 200 * (attempt + 1)));
        _ensureCurrent(shouldContinue);
      }
    }
    throw InnerTubeClientResponseException(
      'The player request failed.',
      cause: lastError,
    );
  }

  List<InnerTubeAudioFormat> _orderedAudioFormats(
    List<InnerTubeAudioFormat> formats, {
    required bool requireAudioOnly,
  }) {
    final remaining = formats
        .where(
          (format) =>
              format.sourceUri != null &&
              format.hasAudio &&
              !format.hasDrm &&
              _acceptsAudioFormat(format) &&
              (!requireAudioOnly || format.isAudioOnly),
        )
        .toList(growable: true);
    final result = <InnerTubeAudioFormat>[];
    while (remaining.isNotEmpty) {
      final preferred = selectPreferredInnerTubeAudio(remaining);
      if (preferred == null) break;
      result.add(preferred);
      remaining.remove(preferred);
    }
    return result;
  }

  bool _acceptsAudioFormat(InnerTubeAudioFormat format) =>
      audioFormatPredicate?.call(format) ?? true;

  Future<Uri> _finalizeFormatUri(
    String videoId,
    InnerTubeAudioFormat format, {
    required Uri? playerUrl,
    required InnerTubeContinuation? shouldContinue,
  }) async {
    var uri = format.sourceUri;
    if (uri == null) {
      throw const InnerTubeClientResponseException(
        'The selected audio format has no URL.',
      );
    }
    final cipher = format.cipher;
    final encryptedSignature = cipher?.encryptedSignature;
    final n = uri.queryParameters['n'];
    final challenges = <EjsChallengeType, List<String>>{
      if (encryptedSignature != null && encryptedSignature.isNotEmpty)
        EjsChallengeType.sig: <String>[encryptedSignature],
      if (n != null && n.isNotEmpty) EjsChallengeType.n: <String>[n],
    };
    final solutions = challenges.isEmpty
        ? const <String, String>{}
        : await _solveChallenges(
            videoId,
            challenges,
            playerUrl: playerUrl,
            shouldContinue: shouldContinue,
          );
    if (encryptedSignature != null && encryptedSignature.isNotEmpty) {
      final signature = solutions[encryptedSignature];
      if (signature == null || signature.isEmpty) {
        throw const InnerTubeClientResponseException(
          'The player signature challenge was not solved.',
        );
      }
      _ensureCurrent(shouldContinue);
      uri = _replaceQueryParameter(uri, cipher!.signatureParameter, signature);
    } else if (cipher?.signature case final signature?
        when signature.isNotEmpty) {
      uri = _replaceQueryParameter(uri, cipher!.signatureParameter, signature);
    }

    if (n != null && n.isNotEmpty) {
      final solved = solutions[n];
      if (solved == null || solved.isEmpty || solved == n) {
        throw const InnerTubeClientResponseException(
          'The player n challenge was not transformed.',
        );
      }
      _ensureCurrent(shouldContinue);
      uri = _replaceQueryParameter(uri, 'n', solved);
    }
    return uri;
  }

  Future<Map<String, String>> _solveChallenges(
    String videoId,
    Map<EjsChallengeType, List<String>> challenges, {
    required Uri? playerUrl,
    required InnerTubeContinuation? shouldContinue,
  }) async {
    final injected = _injectedChallengeSolver;
    final solver = _ejsSolver;
    if (injected == null && solver == null) {
      throw InnerTubeChallengeUnavailableException(challenges.keys.first);
    }
    final effectivePlayerUrl = playerUrl ?? await _loadPlayerUrl(videoId);
    _ensureCurrent(shouldContinue);

    if (injected != null) {
      final results = <String, String>{};
      for (final entry in challenges.entries) {
        for (final challenge in entry.value) {
          final result = await injected(
            effectivePlayerUrl.toString(),
            entry.key,
            challenge,
          );
          _ensureCurrent(shouldContinue);
          if (result.isEmpty) {
            throw const InnerTubeClientResponseException(
              'The player challenge solver returned an empty value.',
            );
          }
          results[challenge] = result;
        }
      }
      return results;
    }

    Future<Map<String, String?>> solve() =>
        solver!.solveBulk(effectivePlayerUrl.toString(), challenges);

    Map<String, String?> raw;
    try {
      raw = await solve();
    } on EjsSolverException {
      await solver!.invalidatePlayer(effectivePlayerUrl.toString());
      _ensureCurrent(shouldContinue);
      raw = await solve();
    }
    _ensureCurrent(shouldContinue);
    final results = <String, String>{};
    for (final entry in challenges.entries) {
      for (final challenge in entry.value) {
        final result = raw[challenge];
        if (result == null || result.isEmpty) {
          throw const InnerTubeClientResponseException(
            'EJS returned an incomplete challenge batch.',
          );
        }
        results[challenge] = result;
      }
    }
    return results;
  }

  Future<Uri> _loadPlayerUrl(
    String videoId, {
    InnerTubePlayerBootstrapPage page = InnerTubePlayerBootstrapPage.web,
    String? userAgent,
  }) async {
    final injected = _injectedPlayerUrlLoader;
    if (injected != null) return injected(videoId);
    var bootstrap = await _playerBootstrap.load(
      videoId,
      page: page,
      userAgent: userAgent,
    );
    var playerUrl = bootstrap.playerUrl;
    if (playerUrl == null) {
      bootstrap = await _playerBootstrap.load(
        videoId,
        forceRefresh: true,
        page: page,
        userAgent: userAgent,
      );
      playerUrl = bootstrap.playerUrl;
    }
    if (playerUrl == null) {
      throw const InnerTubeClientResponseException(
        'The YouTube page did not contain a player URL after refresh.',
      );
    }
    return playerUrl;
  }

  Future<YoutubePoTokenData> _loadPoTokens(
    String videoId,
    InnerTubeClientProfile profile,
    YoutubePoTokenBinding gvsBinding, {
    InnerTubeContinuation? shouldContinue,
    bool forcePlayerPo = false,
  }) {
    final requirements = YoutubePoTokenRequirements(
      player: _shouldMintPoToken(
        profile.capabilities.playerPoToken,
        includeOptional: forcePlayerPo,
      ),
      gvs: _shouldMintPoToken(profile.capabilities.streamingDataPoToken),
      playerBinding: profile.capabilities.playerPoTokenBinding,
      gvsBinding: gvsBinding,
    );
    final injected = _injectedPoTokenLoader;
    if (injected != null) {
      return injected(videoId: videoId, requirements: requirements);
    }
    final provider = _poTokenProvider;
    if (provider == null) {
      throw const InnerTubeClientResponseException(
        'This client requires a Web PO token runtime.',
      );
    }
    return provider.getTokens(
      videoId: videoId,
      requirements: requirements,
      shouldContinue: shouldContinue,
    );
  }

  bool _shouldMintPoToken(
    InnerTubePoTokenRequirement requirement, {
    bool includeOptional = false,
  }) {
    return requirement == InnerTubePoTokenRequirement.required ||
        requirement == InnerTubePoTokenRequirement.recommended ||
        (includeOptional &&
            requirement == InnerTubePoTokenRequirement.optional);
  }

  InnerTubePlayerBootstrapPage _bootstrapPageFor(
    InnerTubeClientProfile profile,
  ) {
    if (profile.isEmbedded) return InnerTubePlayerBootstrapPage.embedded;
    if (profile.clientName == 'MWEB') {
      return InnerTubePlayerBootstrapPage.mobile;
    }
    if (profile.clientName == 'TVHTML5') {
      return InnerTubePlayerBootstrapPage.tv;
    }
    if (profile.host == 'music.youtube.com') {
      return InnerTubePlayerBootstrapPage.music;
    }
    return InnerTubePlayerBootstrapPage.web;
  }

  String? _matchingBootstrapVersion(
    InnerTubeClientProfile profile,
    InnerTubePlayerBootstrap? bootstrap,
  ) {
    if (!profile.allowDynamicClientVersion) return null;
    final version = bootstrap?.clientVersion;
    if (version == null || version.isEmpty) return null;
    final name = bootstrap?.clientName;
    final id = bootstrap?.clientId;
    if (name == null && id == null) return null;
    if (name != null && name != profile.clientName) return null;
    if (id != null && id != profile.clientId) return null;
    return version;
  }

  Map<String, Object?> _playerContext(
    InnerTubeClientProfile profile, {
    required String? visitorData,
    required String? clientVersion,
    required String? embeddedPlayerEncryptedContext,
  }) {
    final base = profile.buildContext(
      language: language,
      region: region,
      visitorData: visitorData,
    );
    final client = <String, Object?>{
      ...Map<String, Object?>.from(base['client']! as Map),
      if (clientVersion != null && clientVersion.isNotEmpty)
        'clientVersion': clientVersion,
    };
    return <String, Object?>{
      ...base,
      'client': client,
      if (profile.isEmbedded)
        'thirdParty': <String, Object?>{
          'embedUrl': 'https://www.reddit.com/',
          if (embeddedPlayerEncryptedContext != null &&
              embeddedPlayerEncryptedContext.isNotEmpty)
            'embeddedPlayerContext': <String, Object?>{
              'embeddedPlayerEncryptedContext': embeddedPlayerEncryptedContext,
              'ancestorOriginsSupported': false,
            },
        },
    };
  }

  String get _acceptLanguageHeader {
    final normalized = language.trim();
    if (normalized.isEmpty) return 'en-US,en;q=0.9';
    if (normalized.contains('-')) {
      return '$normalized,${normalized.split('-').first};q=0.9';
    }
    return '$normalized-$region,$normalized;q=0.9';
  }

  Future<String?> _readVisitorData() async {
    final inMemory = _sessionVisitorData?.trim();
    if (inMemory != null && inMemory.isNotEmpty) return inMemory;
    try {
      final value = (await visitorDataStore?.read())?.trim();
      if (value == null || value.isEmpty) return null;
      _sessionVisitorData = value;
      return value;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistVisitorData(String value) async {
    _sessionVisitorData = value;
    try {
      await visitorDataStore?.write(value);
    } catch (_) {
      // Persistence is an optimization; the current request already owns the
      // same visitor identity through its token response.
    }
  }

  Map<String, String> _mediaHeaders(InnerTubeClientProfile profile) =>
      Map<String, String>.unmodifiable(<String, String>{
        HttpHeaders.acceptHeader: '*/*',
        HttpHeaders.userAgentHeader: profile.userAgent,
        'Origin': profile.origin,
        HttpHeaders.refererHeader: '${profile.origin}/',
      });

  Uri _replaceQueryParameter(Uri uri, String key, String value) {
    final parameters = <String, dynamic>{
      for (final entry in uri.queryParametersAll.entries)
        entry.key: entry.value.length == 1 ? entry.value.single : entry.value,
      key: value,
    };
    return uri.replace(queryParameters: parameters);
  }

  DateTime _expiryFor(
    Uri uri,
    Duration? expiresIn, {
    DateTime? poTokenExpiresAt,
  }) {
    final now = _clock();
    DateTime? signedExpiry;
    final epoch = int.tryParse(uri.queryParameters['expire'] ?? '');
    if (epoch != null && epoch > 0) {
      signedExpiry = DateTime.fromMillisecondsSinceEpoch(
        epoch * 1000,
        isUtc: true,
      ).toLocal();
    }
    final responseExpiry = expiresIn == null ? null : now.add(expiresIn);
    DateTime? earliest;
    for (final candidate in <DateTime?>[
      signedExpiry,
      responseExpiry,
      poTokenExpiresAt,
    ]) {
      if (candidate != null &&
          (earliest == null || candidate.isBefore(earliest))) {
        earliest = candidate;
      }
    }
    final safe = (earliest ?? now.add(const Duration(hours: 1))).subtract(
      const Duration(seconds: 30),
    );
    return safe.isAfter(now) ? safe : now;
  }

  bool _isBotChallenge(InnerTubeParsedPlayerResponse response) {
    final text = _normalizedPlayabilityText(response);
    return text.contains("confirm you're not a bot") ||
        text.contains('sign in to confirm you are not a bot') ||
        text.contains('unusual traffic') ||
        text.contains('automated queries') ||
        text.contains('confirma que no eres un bot') ||
        text.contains('confirmar que no eres un bot') ||
        text.contains('tráfico inusual') ||
        text.contains('trafico inusual') ||
        text.contains('consultas automatizadas');
  }

  bool _playabilityAffectsClientHealth(InnerTubeParsedPlayerResponse response) {
    if (_isBotChallenge(response)) return true;
    final status = response.playability.rawStatus.toUpperCase();
    if (const <String>{
      'AGE_CHECK_REQUIRED',
      'CONTENT_CHECK_REQUIRED',
      'LIVE_STREAM_OFFLINE',
      'LOGIN_REQUIRED',
      'VIDEO_NOT_FOUND',
    }.contains(status)) {
      return false;
    }
    final text = _normalizedPlayabilityText(response);
    return !const <String>[
      'age-restricted',
      'copyright',
      'members-only',
      'private video',
      'subscribers-only',
      'unavailable in your country',
      'verifica tu edad',
      'vídeo privado',
      'video privado',
      'no está disponible en tu país',
      'no esta disponible en tu pais',
      'solo para miembros',
    ].any(text.contains);
  }

  String _normalizedPlayabilityText(InnerTubeParsedPlayerResponse response) =>
      <String>[
        response.playability.rawStatus,
        response.playability.reason ?? '',
        response.playability.subreason ?? '',
      ].join(' ').toLowerCase().replaceAll('’', "'");

  bool _isPoTokenRejection(Object error) {
    if (error is InnerTubeStreamValidationException) {
      return error.isPoTokenRejection;
    }
    if (error is InnerTubeClientResponseException) {
      final cause = error.cause;
      return cause != null &&
          !identical(cause, error) &&
          _isPoTokenRejection(cause);
    }
    return false;
  }

  bool get _isEjsCoolingDown {
    final unavailableUntil = _ejsUnavailableUntil;
    if (unavailableUntil == null) return false;
    if (_clock().isBefore(unavailableUntil)) return true;
    _ejsUnavailableUntil = null;
    _ejsUnavailableError = null;
    return false;
  }

  void _tripEjsBreaker(Object error) {
    _ejsUnavailableError = error;
    _ejsUnavailableUntil = _clock().add(ejsFailureCooldown);
  }

  bool _isEjsCapabilityFailure(Object error) {
    if (error is InnerTubeChallengeUnavailableException ||
        error is EjsSolverException ||
        error is YoutubeJavaScriptRuntimeException) {
      return true;
    }
    if (error is InnerTubeClientResponseException) {
      final cause = error.cause;
      return cause != null &&
          !identical(cause, error) &&
          _isEjsCapabilityFailure(cause);
    }
    return false;
  }

  bool get _isWebPoCoolingDown {
    final unavailableUntil = _webPoUnavailableUntil;
    if (unavailableUntil == null) return false;
    if (_clock().isBefore(unavailableUntil)) return true;
    _webPoUnavailableUntil = null;
    _webPoUnavailableError = null;
    return false;
  }

  void _tripWebPoBreaker(Object error) {
    _webPoUnavailableError = error;
    _webPoUnavailableUntil = _clock().add(webPoFailureCooldown);
  }

  bool _isWebPoCapabilityFailure(Object error) {
    if (error is PoTokenCancelledException) return false;
    if (error is PoTokenException) return true;
    if (error is InnerTubeClientResponseException) {
      final cause = error.cause;
      return cause != null &&
          !identical(cause, error) &&
          _isWebPoCapabilityFailure(cause);
    }
    return false;
  }

  bool _isRetryable(Object error) {
    if (error is TimeoutException || error is SocketException) return true;
    if (error is InnerTubeClientResponseException) {
      final status = error.statusCode;
      return status == HttpStatus.tooManyRequests ||
          (status != null && status >= HttpStatus.internalServerError);
    }
    return false;
  }

  InnerTubeClientFailureKind _failureKind(Object error) {
    if (error is TimeoutException) return InnerTubeClientFailureKind.timeout;
    if (error is PoTokenException) {
      return InnerTubeClientFailureKind.challengeUnavailable;
    }
    if (error is InnerTubeStreamValidationException) {
      return error.statusCode == HttpStatus.forbidden
          ? InnerTubeClientFailureKind.rejected
          : InnerTubeClientFailureKind.unavailable;
    }
    if (error is InnerTubeClientResponseException) {
      if (error.statusCode == HttpStatus.forbidden) {
        return InnerTubeClientFailureKind.rejected;
      }
      final cause = error.cause;
      if (cause != null && !identical(cause, error)) {
        return _failureKind(cause);
      }
      return InnerTubeClientFailureKind.invalidResponse;
    }
    if (error is InnerTubeChallengeUnavailableException ||
        error is EjsSolverException ||
        error is YoutubeJavaScriptRuntimeException ||
        error is UnsupportedError ||
        error is StateError) {
      return InnerTubeClientFailureKind.challengeUnavailable;
    }
    return InnerTubeClientFailureKind.unavailable;
  }

  bool _affectsClientHealth(Object error) {
    if (_isEjsCapabilityFailure(error) || _isWebPoCapabilityFailure(error)) {
      return false;
    }
    if (error is! InnerTubeClientResponseException) return true;
    if (!error.affectsClientHealth) return false;
    final cause = error.cause;
    return cause == null || identical(cause, error)
        ? true
        : _affectsClientHealth(cause);
  }

  void _ensureCurrent(InnerTubeContinuation? shouldContinue) {
    if (shouldContinue != null && !shouldContinue()) {
      throw const InnerTubeClientResponseException(
        'Playback resolution was superseded.',
      );
    }
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('The InnerTube playback service is disposed.');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _inFlight.clear();
    if (_ownsTransport) _transport.close();
    if (disposeChallengeDependencies) {
      await _ejsSolver?.dispose();
      await _poTokenProvider?.dispose();
    }
  }
}

final class _PreparedPlayerRequest {
  const _PreparedPlayerRequest({
    required this.visitorData,
    required this.tokens,
    required this.playerUrl,
    required this.signatureTimestamp,
    required this.encryptedHostFlags,
    required this.clientVersion,
    required this.embeddedPlayerEncryptedContext,
  });

  final String? visitorData;
  final YoutubePoTokenData? tokens;
  final Uri? playerUrl;
  final int? signatureTimestamp;
  final String? encryptedHostFlags;
  final String? clientVersion;
  final String? embeddedPlayerEncryptedContext;
}
