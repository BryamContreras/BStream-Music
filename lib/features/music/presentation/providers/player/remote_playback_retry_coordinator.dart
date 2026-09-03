import 'dart:async';
import 'dart:io';

import '../../../../../core/errors/app_exception.dart';
import '../../../../../services/downloader/audio_stream_resolver.dart';
import '../../../domain/entities/track_info.dart';

typedef RemoteRetryCycle = Future<void> Function();
typedef RemoteRetryAttemptNotice = void Function(int attempt, int total);
typedef RemoteRetryTerminal =
    FutureOr<void> Function(Object error, StackTrace stackTrace);

/// Serializes a retry cycle for one logical remote selection.
///
/// The coordinator owns retry/recovery/load-attempt state but not Riverpod or
/// player I/O. Callers provide the retry cycle and publication callbacks,
/// which keeps terminal UI policy in the player controller while making
/// timing, coalescing and cancellation deterministic and independently
/// testable.
class RemotePlaybackRetryCoordinator {
  RemotePlaybackRetryCoordinator({
    this.backoffs = const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 5),
    ],
  });

  final List<Duration> backoffs;

  int? _recoveryRequestId;
  String? _recoveryQueueEntryId;
  Future<void>? _retryInFlight;
  String? _retryInFlightKey;
  int _loadAttemptSequence = 0;
  int? _activeLoadAttemptId;
  final Set<int> _handledLoadFailureAttempts = <int>{};
  String? _terminalFailureKey;
  String? _invalidatedCacheIdentity;
  int? _noticeRequestId;
  String? _notice;

  String? get recoveryQueueEntryId => _recoveryQueueEntryId;
  int? get activeLoadAttemptId => _activeLoadAttemptId;
  String? get invalidatedCacheIdentity => _invalidatedCacheIdentity;

  void resetForSelection() {
    _recoveryRequestId = null;
    _recoveryQueueEntryId = null;
    _activeLoadAttemptId = null;
    _handledLoadFailureAttempts.clear();
    _terminalFailureKey = null;
    _invalidatedCacheIdentity = null;
    clearNotice();
  }

  void resetLoadAndFailureState() {
    _recoveryRequestId = null;
    _recoveryQueueEntryId = null;
    _activeLoadAttemptId = null;
    _handledLoadFailureAttempts.clear();
    _terminalFailureKey = null;
  }

  void markInvalidatedCache(String identity) {
    _invalidatedCacheIdentity = identity;
  }

  String retryKey(String identity, int requestId, String? queueEntryId) {
    return '$requestId\u0000${queueEntryId ?? ''}\u0000$identity';
  }

  bool isRecoveryInFlight(int requestId, String? queueEntryId) {
    return _recoveryRequestId == requestId &&
        _recoveryQueueEntryId == queueEntryId;
  }

  void markRecoveryInFlight(int requestId, String? queueEntryId) {
    _recoveryRequestId = requestId;
    _recoveryQueueEntryId = queueEntryId;
  }

  void clearRecoveryInFlight(int requestId, String? queueEntryId) {
    if (isRecoveryInFlight(requestId, queueEntryId)) {
      _recoveryRequestId = null;
      _recoveryQueueEntryId = null;
    }
  }

  bool isRetryInFlight(String key) {
    return _retryInFlight != null && _retryInFlightKey == key;
  }

  bool isTerminalFailure(String key) => _terminalFailureKey == key;

  void markTerminalFailure(String key) {
    _terminalFailureKey = key;
  }

  void clearTerminalFailure() {
    _terminalFailureKey = null;
  }

  int beginLoadAttempt() {
    final attemptId = ++_loadAttemptSequence;
    _activeLoadAttemptId = attemptId;
    return attemptId;
  }

  void finishLoadAttempt(int attemptId) {
    if (_activeLoadAttemptId == attemptId) {
      _activeLoadAttemptId = null;
    }
    _handledLoadFailureAttempts.remove(attemptId);
  }

  void markActiveLoadFailureHandled() {
    final attemptId = _activeLoadAttemptId;
    if (attemptId != null) {
      _handledLoadFailureAttempts.add(attemptId);
    }
  }

  bool wasLoadFailureHandled(int attemptId) {
    return _handledLoadFailureAttempts.contains(attemptId);
  }

  void setNotice(int requestId, String message) {
    _noticeRequestId = requestId;
    _notice = message;
  }

  String? noticeFor(int requestId) {
    return _noticeRequestId == requestId ? _notice : null;
  }

  bool clearNotice([int? requestId]) {
    if (requestId != null && _noticeRequestId != requestId) {
      return false;
    }
    final hadNotice = _noticeRequestId != null;
    _noticeRequestId = null;
    _notice = null;
    return hadNotice;
  }

  bool noticeBelongsTo(int requestId) => _noticeRequestId == requestId;

  Future<void> run({
    required String key,
    required Object initialError,
    required StackTrace initialStackTrace,
    required bool Function() isCurrent,
    required bool Function(Object error) isCancellation,
    required bool Function(Object error) shouldRetry,
    required Future<void> Function(Duration duration) delay,
    required RemoteRetryAttemptNotice onAttempt,
    required RemoteRetryCycle runCycle,
    required void Function() onCancelled,
    required RemoteRetryTerminal onTerminal,
    required void Function() onStale,
  }) {
    final current = _retryInFlight;
    if (current != null && _retryInFlightKey == key) {
      return current;
    }

    late final Future<void> tracked;
    tracked =
        _run(
          initialError: initialError,
          initialStackTrace: initialStackTrace,
          isCurrent: isCurrent,
          isCancellation: isCancellation,
          shouldRetry: shouldRetry,
          delay: delay,
          onAttempt: onAttempt,
          runCycle: runCycle,
          onCancelled: onCancelled,
          onTerminal: onTerminal,
          onStale: onStale,
        ).whenComplete(() {
          if (identical(_retryInFlight, tracked)) {
            _retryInFlight = null;
            _retryInFlightKey = null;
          }
        });
    _retryInFlightKey = key;
    _retryInFlight = tracked;
    return tracked;
  }

  Future<void> _run({
    required Object initialError,
    required StackTrace initialStackTrace,
    required bool Function() isCurrent,
    required bool Function(Object error) isCancellation,
    required bool Function(Object error) shouldRetry,
    required Future<void> Function(Duration duration) delay,
    required RemoteRetryAttemptNotice onAttempt,
    required RemoteRetryCycle runCycle,
    required void Function() onCancelled,
    required RemoteRetryTerminal onTerminal,
    required void Function() onStale,
  }) async {
    var lastError = initialError;
    var lastStackTrace = initialStackTrace;
    var terminalCallbackStarted = false;

    Future<void> publishTerminal(Object error, StackTrace stackTrace) async {
      terminalCallbackStarted = true;
      await onTerminal(error, stackTrace);
    }

    try {
      for (var attempt = 0; attempt < backoffs.length; attempt++) {
        if (!isCurrent()) {
          return;
        }
        if (isCancellation(lastError)) {
          onCancelled();
          return;
        }
        if (!shouldRetry(lastError)) {
          await publishTerminal(lastError, lastStackTrace);
          return;
        }

        onAttempt(attempt + 1, backoffs.length);
        await delay(backoffs[attempt]);
        if (!isCurrent()) {
          return;
        }
        try {
          await runCycle();
          return;
        } catch (error, stackTrace) {
          lastError = error;
          lastStackTrace = stackTrace;
        }
      }

      if (isCancellation(lastError)) {
        onCancelled();
      } else if (isCurrent()) {
        await publishTerminal(lastError, lastStackTrace);
      }
    } catch (error, stackTrace) {
      if (terminalCallbackStarted) {
        rethrow;
      }
      if (isCurrent()) {
        await publishTerminal(error, stackTrace);
      }
    } finally {
      if (!isCurrent()) {
        onStale();
      }
    }
  }
}

/// Classifies backend errors without depending on controller state.
abstract final class RemotePlaybackFailureClassifier {
  static const _permanentCodes = <String>{
    'invalid_stream_url',
    'missing_stream_url',
  };

  static const _transientCodes = <String>{
    'media_kit_open_failed',
    'playback_source_error',
    'transient_remote_playback',
  };

  static const _nonRefreshableMarkers = <String>[
    'sign in',
    'not a bot',
    'confirm you',
    'cookies',
    'login required',
    'private video',
    'video unavailable',
    'members-only',
    'region restricted',
    'drm',
    'invalid url',
    'empty url',
    'without a url',
    'sin una url',
    'permission denied',
    'no space left',
    'file too large',
    'unrecognized input',
    'parserexception',
    'decoder',
    'format is not supported',
    'requested format is not available',
    'no audio stream resolver is registered',
    'no fallback audio stream resolver is registered',
  ];

  static const _transientMarkers = <String>[
    'timed out',
    'timeout',
    'time out',
    'temporary',
    'temporarily',
    'try again',
    'connection',
    'network',
    'socket',
    'offline',
    'internet',
    'dns',
    'host lookup',
    'connection reset',
    'connection refused',
    'connection closed',
    'failed to load',
    'load failed',
    'source error',
    'stream error',
    'unable to download',
    'too many requests',
    'tardó demasiado',
    'tiempo de espera',
    'excedió el límite',
    'no respondió',
    'conexión',
    'sin conexión',
    'error de red',
    'temporalmente',
  ];

  static final _refreshableHttpStatus = RegExp(
    r'\b(?:http(?:\s+(?:status|error))?\s*)?'
    r'(?:403|408|425|429|500|502|503|504)\b',
  );

  static bool shouldRefresh(Object error) => _shouldRefresh(error, depth: 0);

  static bool _shouldRefresh(Object error, {required int depth}) {
    if (depth > 4) {
      return false;
    }
    if (isCancellation(error)) {
      return false;
    }
    if (_isProgrammingFailure(error)) {
      return false;
    }
    if (error is AudioStreamResolverException) {
      final cause = error.cause;
      return cause == null
          ? shouldRefreshMessage(error.message)
          : _shouldRefresh(cause, depth: depth + 1);
    }
    if (error is TimeoutException ||
        error is SocketException ||
        error is HttpException ||
        error is HandshakeException) {
      return true;
    }
    if (error is AppException) {
      final code = error.code?.trim().toLowerCase();
      if (code != null && _permanentCodes.contains(code)) {
        return false;
      }
      if (_containsNonRefreshableMarker(error.message)) {
        return false;
      }
      final details = error.details;
      if (details != null && !identical(details, error)) {
        if (_isProgrammingFailure(details)) {
          return false;
        }
        if (_shouldRefresh(details, depth: depth + 1)) {
          return true;
        }
      }
      if (code != null && _transientCodes.contains(code)) {
        return true;
      }
      return false;
    }
    return shouldRefreshMessage(error.toString());
  }

  static bool isCancellation(Object error) {
    if (error is AudioStreamResolverException && error.cause != null) {
      return isCancellation(error.cause!);
    }
    if (error is AppException) {
      final code = error.code?.trim().toLowerCase() ?? '';
      if (code == 'downloader_disposed') {
        return true;
      }
    }
    return isCancellationMessage(error.toString());
  }

  static bool isCancellationMessage(String? rawMessage) {
    final message = rawMessage?.trim().toLowerCase() ?? '';
    return message.contains('audio stream resolution was superseded') ||
        message.contains('playback resolution was superseded') ||
        message.contains('reemplazada por una solicitud más reciente') ||
        message.contains('reemplazada por una pista más reciente');
  }

  static bool shouldRecover(TrackInfo track, Object error) {
    if (isCancellation(error) || _containsProgrammingFailure(error)) {
      return false;
    }
    return shouldRefresh(error) ||
        (isPrimaryInnerTubeStream(track) &&
            _isPrimaryBackendFallbackCandidate(error));
  }

  static bool isPrimaryInnerTubeStream(TrackInfo track) {
    return track.streamSource == AudioStreamSource.innerTube.name;
  }

  static bool isFallbackInnerTubeStream(TrackInfo track) {
    return track.streamSource == AudioStreamSource.innerTubeFallback.name;
  }

  static bool shouldRefreshMessage(String? rawMessage) {
    final message = rawMessage?.trim().toLowerCase() ?? '';
    if (message.isEmpty) {
      return false;
    }
    if (_containsNonRefreshableMarker(message)) {
      return false;
    }
    return _containsTransientMarker(message);
  }

  static bool _isProgrammingFailure(Object error) {
    return error is Error || error is FormatException;
  }

  static bool _containsProgrammingFailure(Object error, {int depth = 0}) {
    if (_isProgrammingFailure(error)) {
      return true;
    }
    if (depth > 4) {
      return false;
    }
    if (error is AudioStreamResolverException && error.cause != null) {
      return _containsProgrammingFailure(error.cause!, depth: depth + 1);
    }
    if (error is AppException && error.details != null) {
      return _containsProgrammingFailure(error.details!, depth: depth + 1);
    }
    return false;
  }

  static bool _containsNonRefreshableMarker(String rawMessage) {
    final message = rawMessage.trim().toLowerCase();
    return _nonRefreshableMarkers.any(message.contains);
  }

  static bool _containsTransientMarker(String rawMessage) {
    final message = rawMessage.trim().toLowerCase();
    return _transientMarkers.any(message.contains) ||
        _refreshableHttpStatus.hasMatch(message);
  }

  static bool _isPrimaryBackendFallbackCandidate(Object error) {
    final message = error.toString().trim().toLowerCase();
    const fallbackMarkers = <String>[
      'source error',
      'playback_source_error',
      'media_kit_open_failed',
      'format is not supported',
      'unsupported codec',
      'decoder',
      'failed to open',
      'cannot open',
    ];
    return fallbackMarkers.any(message.contains);
  }
}
