import 'dart:async';
import 'dart:io';

/// Creates the [HttpClient] used for one transfer attempt.
///
/// A new client is requested for every retry. This keeps failed sockets out of
/// subsequent attempts and makes the transport straightforward to replace in
/// tests.
typedef HttpAudioClientFactory = HttpClient Function();

typedef HttpAudioTransferProgressCallback =
    void Function(HttpAudioTransferProgress progress);

/// Returns `true` when an in-flight transfer is no longer useful.
typedef HttpAudioTransferCancellationCallback = bool Function();

enum HttpAudioTransferFailureKind {
  httpStatus,
  invalidRange,
  invalidContent,
  invalidResponse,
  network,
  connectionTimeout,
  idleTimeout,
  totalTimeout,
  incomplete,
  cancelled,
  destinationBusy,
}

/// A transport/protocol failure produced by [HttpAudioTransfer].
///
/// File-system failures intentionally do not use this type. A
/// [FileSystemException] from directory creation, writing, flushing, or the
/// final rename is allowed to reach the caller unchanged.
class HttpAudioTransferException implements Exception {
  const HttpAudioTransferException(
    this.message, {
    required this.kind,
    this.statusCode,
    this.cause,
  });

  final String message;
  final HttpAudioTransferFailureKind kind;
  final int? statusCode;
  final Object? cause;

  /// A signed media URL should be resolved again for these HTTP statuses.
  bool get shouldRefreshUrl =>
      statusCode == HttpStatus.forbidden || statusCode == HttpStatus.gone;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'HttpAudioTransferException$status: $message';
  }
}

class HttpAudioTransferProgress {
  const HttpAudioTransferProgress({
    required this.transferredBytes,
    required this.totalBytes,
    required this.attempt,
    required this.resumed,
  });

  /// Bytes currently present in the partial file, including resumed bytes.
  final int transferredBytes;

  /// Complete entity length when supplied by Content-Length/Content-Range.
  final int? totalBytes;

  /// One-based network attempt number.
  final int attempt;

  /// Whether this attempt is appending to a pre-existing partial file.
  final bool resumed;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return null;
    }
    return (transferredBytes / total).clamp(0.0, 1.0);
  }
}

class HttpAudioTransferResult {
  const HttpAudioTransferResult({
    required this.file,
    required this.length,
    required this.attempts,
    required this.resumed,
  });

  final File file;
  final int length;
  final int attempts;

  /// Whether at least one successful response appended to a `.part` file.
  final bool resumed;
}

/// Downloads a direct audio URL to a temporary `.part` file and atomically
/// promotes it to [destination] only after the complete response is validated.
class HttpAudioTransfer {
  HttpAudioTransfer({
    HttpAudioClientFactory? clientFactory,
    this.connectionTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 20),
    this.totalTimeout = const Duration(minutes: 15),
    this.maxRetries = 2,
    this.retryDelay = const Duration(milliseconds: 250),
    this.cancellationPollInterval = const Duration(milliseconds: 50),
  }) : clientFactory = clientFactory ?? _createHttpClient {
    _requirePositive(connectionTimeout, 'connectionTimeout');
    _requirePositive(idleTimeout, 'idleTimeout');
    _requirePositive(totalTimeout, 'totalTimeout');
    _requirePositive(cancellationPollInterval, 'cancellationPollInterval');
    if (maxRetries < 0) {
      throw ArgumentError.value(maxRetries, 'maxRetries', 'Must be >= 0.');
    }
    if (retryDelay.isNegative) {
      throw ArgumentError.value(retryDelay, 'retryDelay', 'Must be >= 0.');
    }
  }

  final HttpAudioClientFactory clientFactory;

  /// Maximum time for opening a connection or receiving response headers.
  final Duration connectionTimeout;

  /// Maximum silence between response body chunks.
  final Duration idleTimeout;

  /// Wall-clock cap for HTTP work, retries, retry delays, and promotion.
  final Duration totalTimeout;

  /// Number of retries after the initial network attempt.
  final int maxRetries;
  final Duration retryDelay;
  final Duration cancellationPollInterval;

  static final Set<String> _activeDestinationPaths = <String>{};

  static File partialFileFor(File destination) =>
      File('${destination.path}.part');

  /// Transfers [uri] into [destination].
  ///
  /// `Range` is managed from the `.part` length and any caller-provided Range
  /// header is ignored. Strong ETag/Last-Modified validators are persisted in
  /// a small sidecar and sent as `If-Range`; a caller may also provide its own
  /// `If-Range` header. A legacy partial without either validator is retained
  /// until valid media bytes arrive, then safely restarted from byte zero.
  Future<HttpAudioTransferResult> download({
    required Uri uri,
    required File destination,
    Map<String, String> headers = const <String, String>{},
    HttpAudioTransferProgressCallback? onProgress,
    HttpAudioTransferCancellationCallback? isCancelled,
  }) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError.value(uri, 'uri', 'Only HTTP(S) URLs are supported.');
    }

    final destinationKey = _destinationKey(destination);
    if (!_activeDestinationPaths.add(destinationKey)) {
      return Future<HttpAudioTransferResult>.error(
        const HttpAudioTransferException(
          'Another audio transfer is already writing to this destination.',
          kind: HttpAudioTransferFailureKind.destinationBusy,
        ),
      );
    }

    final result = _HttpAudioTransferRun(
      owner: this,
      uri: uri,
      destination: destination,
      headers: Map<String, String>.unmodifiable(headers),
      onProgress: onProgress,
      isCancelled: isCancelled,
    ).run();
    return result.whenComplete(() {
      _activeDestinationPaths.remove(destinationKey);
    });
  }

  static void _requirePositive(Duration value, String name) {
    if (value <= Duration.zero) {
      throw ArgumentError.value(value, name, 'Must be greater than zero.');
    }
  }

  static String _destinationKey(File destination) {
    final absolutePath = destination.absolute.path;
    return Platform.isWindows ? absolutePath.toLowerCase() : absolutePath;
  }
}

HttpClient _createHttpClient() => HttpClient();

class _HttpAudioTransferRun {
  _HttpAudioTransferRun({
    required this.owner,
    required this.uri,
    required this.destination,
    required this.headers,
    required this.onProgress,
    required this.isCancelled,
  }) : partFile = HttpAudioTransfer.partialFileFor(destination),
       validatorFile = File('${destination.path}.part.if-range');

  final HttpAudioTransfer owner;
  final Uri uri;
  final File destination;
  final File partFile;
  final File validatorFile;
  final Map<String, String> headers;
  final HttpAudioTransferProgressCallback? onProgress;
  final HttpAudioTransferCancellationCallback? isCancelled;

  final Completer<void> _terminalAbort = Completer<void>();
  Timer? _totalTimer;
  Timer? _cancellationTimer;
  HttpClient? _activeClient;
  HttpClientRequest? _activeRequest;
  HttpAudioTransferException? _terminalException;
  Object? _cancellationCallbackError;
  StackTrace? _cancellationCallbackStack;
  _EntityValidator? _entityValidator;
  bool _resumed = false;

  Future<HttpAudioTransferResult> run() async {
    _startWatchdogs();
    try {
      _pollCancellation();
      _throwIfTerminal();
      await destination.parent.create(recursive: true);

      _RetryableTransferFailure? lastFailure;
      StackTrace? lastStack;
      final maximumAttempts = owner.maxRetries + 1;

      for (var attempt = 1; attempt <= maximumAttempts; attempt++) {
        _throwIfTerminal();
        try {
          final completedLength = await _attempt(attempt);
          _pollCancellation();
          _throwIfTerminal();

          await partFile.rename(destination.path);
          _pollCancellation();
          if (_hasTerminalFailure) {
            // rename cannot be interrupted. If a watchdog fired while it was
            // pending, restore the just-created final file to `.part` before
            // surfacing cancellation/timeout.
            await File(destination.path).rename(partFile.path);
            _throwIfTerminal();
          }
          _stopWatchdogs();
          await _deleteValidatorAfterSuccess();
          return HttpAudioTransferResult(
            file: File(destination.path),
            length: completedLength,
            attempts: attempt,
            resumed: _resumed,
          );
        } on FileSystemException {
          rethrow;
        } on HttpAudioTransferException {
          rethrow;
        } catch (error, stackTrace) {
          _throwIfTerminal();
          if (error is _TransferCallbackFailure) {
            Error.throwWithStackTrace(error.error, error.stackTrace);
          }
          final failure = _asRetryableFailure(error);
          if (failure == null) {
            Error.throwWithStackTrace(error, stackTrace);
          }
          lastFailure = failure;
          lastStack = stackTrace;

          if (attempt >= maximumAttempts) {
            break;
          }
          await _waitBeforeRetry(attempt);
        }
      }

      final failure = lastFailure!;
      final error = HttpAudioTransferException(
        '${failure.message} Retry limit reached.',
        kind: failure.kind,
        statusCode: failure.statusCode,
        cause: failure.cause ?? failure,
      );
      Error.throwWithStackTrace(error, lastStack ?? StackTrace.current);
    } finally {
      _stopWatchdogs();
      _activeRequest = null;
      _activeClient?.close(force: true);
      _activeClient = null;
    }
  }

  Future<int> _attempt(int attempt) async {
    final requestedOffset = await _resumeOffset();
    final client = owner.clientFactory();
    _activeClient = client;
    client.autoUncompress = false;
    client.connectionTimeout = _phaseTimeout(owner.connectionTimeout);

    try {
      final request = await _awaitConnectionPhase(
        client.getUrl(uri),
        'Timed out while connecting to the audio host.',
      );
      _activeRequest = request;

      for (final entry in headers.entries) {
        // The Range value is derived from the actual .part length. Accepting a
        // caller-provided value could append bytes at the wrong offset.
        if (entry.key.toLowerCase() == HttpHeaders.rangeHeader) {
          continue;
        }
        request.headers.set(entry.key, entry.value);
      }
      if (requestedOffset > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$requestedOffset-');
        if (!_containsHeader(headers, HttpHeaders.ifRangeHeader) &&
            _entityValidator != null) {
          request.headers.set(
            HttpHeaders.ifRangeHeader,
            _entityValidator!.value,
          );
        }
      }

      final response = await _awaitConnectionPhase(
        request.close(),
        'Timed out while waiting for audio response headers.',
      );
      _pollCancellation();
      _throwIfTerminal();

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          requestedOffset > 0) {
        final remoteLength = _parseUnsatisfiedContentRangeTotal(
          response.headers.value(HttpHeaders.contentRangeHeader),
        );
        await response.drain<void>();
        if (remoteLength == requestedOffset &&
            _hasStrongResumeIdentity &&
            _strongResumeIdentityMatches(response.headers)) {
          _resumed = true;
          _reportProgress(
            transferredBytes: requestedOffset,
            totalBytes: remoteLength,
            attempt: attempt,
            resumed: true,
          );
          return requestedOffset;
        }
        if (remoteLength != null && remoteLength <= requestedOffset) {
          // Length equality alone does not identify the representation: an
          // unrelated stale `.part` can have exactly the same size. Without a
          // strong ETag, fetch the entity again and validate its bytes. A
          // shorter remote entity always requires the same clean restart.
          await _discardPartialForRestart();
          throw _RetryableTransferFailure(
            remoteLength < requestedOffset
                ? 'The remote audio is shorter than the saved partial.'
                : 'HTTP 416 did not strongly identify the saved partial.',
            kind: HttpAudioTransferFailureKind.invalidRange,
            statusCode: HttpStatus.requestedRangeNotSatisfiable,
          );
        }
      }

      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        final failure = HttpAudioTransferException(
          response.reasonPhrase.isEmpty
              ? 'The audio server rejected the request.'
              : 'The audio server rejected the request: '
                    '${response.reasonPhrase}.',
          kind: HttpAudioTransferFailureKind.httpStatus,
          statusCode: response.statusCode,
        );
        if (_isRetryableHttpStatus(response.statusCode)) {
          throw _RetryableTransferFailure(
            failure.message,
            kind: failure.kind,
            statusCode: response.statusCode,
            cause: failure,
          );
        }
        throw failure;
      }

      final plan = _ResponsePlan.fromResponse(
        response,
        requestedOffset: requestedOffset,
      );
      _validateContentType(response.headers);
      final responseValidator = _extractResponseValidator(response.headers);
      if (response.statusCode == HttpStatus.partialContent &&
          _entityValidator != null &&
          !_entityValidator!.matches(response.headers)) {
        throw const HttpAudioTransferException(
          'The remote audio entity changed during range continuation.',
          kind: HttpAudioTransferFailureKind.invalidRange,
        );
      }
      _entityValidator = response.statusCode == HttpStatus.ok
          ? responseValidator
          : responseValidator ?? _entityValidator;
      _reportProgress(
        transferredBytes: plan.startingBytes,
        totalBytes: plan.totalBytes,
        attempt: attempt,
        resumed: plan.append,
      );
      _pollCancellation();
      _throwIfTerminal();

      final received = await _consumeResponse(
        response,
        request: request,
        plan: plan,
        attempt: attempt,
        validator: _entityValidator,
      );

      if (plan.expectedResponseBytes != null &&
          received != plan.expectedResponseBytes) {
        if (received < plan.expectedResponseBytes!) {
          throw _RetryableTransferFailure(
            'The audio response ended before all declared bytes arrived.',
            kind: HttpAudioTransferFailureKind.incomplete,
          );
        }
        throw const HttpAudioTransferException(
          'The audio response exceeded its declared byte range.',
          kind: HttpAudioTransferFailureKind.invalidResponse,
        );
      }

      final completedLength = plan.startingBytes + received;
      final total = plan.totalBytes;
      if (total != null && completedLength != total) {
        if (completedLength < total) {
          throw _RetryableTransferFailure(
            'The audio response did not complete the advertised entity.',
            kind: HttpAudioTransferFailureKind.incomplete,
          );
        }
        throw const HttpAudioTransferException(
          'The downloaded audio is larger than the advertised entity.',
          kind: HttpAudioTransferFailureKind.invalidResponse,
        );
      }
      if (completedLength == 0) {
        throw const HttpAudioTransferException(
          'The audio server returned an empty response.',
          kind: HttpAudioTransferFailureKind.invalidContent,
        );
      }

      return completedLength;
    } finally {
      _activeRequest = null;
      client.close(force: true);
      if (identical(_activeClient, client)) {
        _activeClient = null;
      }
    }
  }

  Future<int> _consumeResponse(
    HttpClientResponse response, {
    required HttpClientRequest request,
    required _ResponsePlan plan,
    required int attempt,
    required _EntityValidator? validator,
  }) async {
    RandomAccessFile? output;
    var outputClosed = false;
    var receivedBytes = 0;
    var writtenBytes = 0;
    var validatorCommitted = false;
    final sniffPayload = plan.startingBytes == 0;
    final pendingChunks = <List<int>>[];
    final prefix = <int>[];

    Future<void> openOutput() async {
      if (output != null) {
        return;
      }
      if (plan.append) {
        final currentLength = await _partialLength();
        if (currentLength != plan.startingBytes) {
          throw const HttpAudioTransferException(
            'The partial file changed while the range request was active.',
            kind: HttpAudioTransferFailureKind.invalidRange,
          );
        }
      }
      output = await partFile.open(
        mode: plan.append ? FileMode.append : FileMode.write,
      );
    }

    Future<void> writeChunk(List<int> chunk) async {
      await output!.writeFrom(chunk);
      if (plan.append) {
        _resumed = true;
      }
      if (!validatorCommitted) {
        await _commitValidatorForPartial(validator);
        validatorCommitted = true;
      }
      writtenBytes += chunk.length;
      _reportProgress(
        transferredBytes: plan.startingBytes + writtenBytes,
        totalBytes: plan.totalBytes,
        attempt: attempt,
        resumed: plan.append,
      );
    }

    if (!sniffPayload) {
      await openOutput();
    }

    final stream = response.timeout(
      owner.idleTimeout,
      onTimeout: (sink) {
        final failure = _RetryableTransferFailure(
          'The audio response was idle for too long.',
          kind: HttpAudioTransferFailureKind.idleTimeout,
        );
        request.abort(failure, StackTrace.current);
        sink.addError(failure);
        sink.close();
      },
    );

    try {
      await for (final chunk in stream) {
        _pollCancellation();
        _throwIfTerminal();
        if (chunk.isEmpty) {
          continue;
        }
        final expectedBytes = plan.expectedResponseBytes;
        if (expectedBytes != null &&
            chunk.length > expectedBytes - receivedBytes) {
          throw const HttpAudioTransferException(
            'The audio response exceeded its declared byte range.',
            kind: HttpAudioTransferFailureKind.invalidResponse,
          );
        }
        receivedBytes += chunk.length;

        if (output == null) {
          pendingChunks.add(chunk);
          _appendPrefix(prefix, chunk);
          final disposition = _inspectPayloadPrefix(prefix);
          if (disposition == _PayloadDisposition.html) {
            throw const HttpAudioTransferException(
              'The audio URL returned HTML instead of media bytes.',
              kind: HttpAudioTransferFailureKind.invalidContent,
            );
          }
          if (disposition == _PayloadDisposition.json) {
            throw const HttpAudioTransferException(
              'The audio URL returned JSON instead of media bytes.',
              kind: HttpAudioTransferFailureKind.invalidContent,
            );
          }
          if (disposition == _PayloadDisposition.emptyOrWhitespace) {
            throw const HttpAudioTransferException(
              'The audio URL returned text instead of media bytes.',
              kind: HttpAudioTransferFailureKind.invalidContent,
            );
          }
          if (disposition == _PayloadDisposition.undecided) {
            continue;
          }

          await openOutput();
          for (final pending in pendingChunks) {
            await writeChunk(pending);
          }
          pendingChunks.clear();
          continue;
        }

        await writeChunk(chunk);
      }

      if (output == null) {
        final disposition = _inspectPayloadPrefix(prefix, endOfStream: true);
        if (disposition != _PayloadDisposition.media) {
          throw const HttpAudioTransferException(
            'The audio URL did not return media bytes.',
            kind: HttpAudioTransferFailureKind.invalidContent,
          );
        }
        await openOutput();
        for (final pending in pendingChunks) {
          await writeChunk(pending);
        }
      }

      await output!.flush();
      await output!.close();
      outputClosed = true;
      return receivedBytes;
    } finally {
      if (output != null && !outputClosed) {
        await output!.close();
      }
    }
  }

  Future<int> _partialLength() async {
    if (!await partFile.exists()) {
      return 0;
    }
    return partFile.length();
  }

  Future<int> _resumeOffset() async {
    final length = await _partialLength();
    if (length == 0) {
      _entityValidator = null;
      await _deleteValidatorIfPresent();
      return 0;
    }

    if (_containsHeader(headers, HttpHeaders.ifRangeHeader)) {
      return length;
    }
    _entityValidator ??= await _readPartialValidator();
    if (_entityValidator == null) {
      // A partial without a representation validator cannot be appended to
      // safely: the URL may now identify different bytes. Keep it untouched
      // until a valid 200 body is sniffed, then restart it from byte zero.
      return 0;
    }
    return length;
  }

  bool get _hasStrongResumeIdentity {
    final callerIfRange = _headerValue(headers, HttpHeaders.ifRangeHeader);
    if (callerIfRange != null) {
      return _isStrongEntityTag(callerIfRange);
    }
    final persisted = _entityValidator;
    return persisted != null &&
        persisted.kind == _ValidatorKind.etag &&
        _isStrongEntityTag(persisted.value);
  }

  bool _strongResumeIdentityMatches(HttpHeaders responseHeaders) {
    final callerIfRange = _headerValue(headers, HttpHeaders.ifRangeHeader);
    final expected = callerIfRange != null && _isStrongEntityTag(callerIfRange)
        ? callerIfRange
        : _entityValidator?.kind == _ValidatorKind.etag &&
              _isStrongEntityTag(_entityValidator!.value)
        ? _entityValidator!.value
        : null;
    final responseEtag = responseHeaders.value(HttpHeaders.etagHeader)?.trim();
    return expected != null && responseEtag == expected;
  }

  Future<void> _discardPartialForRestart() async {
    if (await partFile.exists()) {
      await partFile.delete();
    }
    await _deleteValidatorIfPresent();
    _entityValidator = null;
  }

  Future<_EntityValidator?> _readPartialValidator() async {
    if (!await validatorFile.exists()) {
      return null;
    }
    final validator = _EntityValidator.tryParse(
      await validatorFile.readAsString(),
    );
    if (validator == null) {
      await validatorFile.delete();
    }
    return validator;
  }

  Future<void> _commitValidatorForPartial(_EntityValidator? validator) async {
    if (validator == null) {
      await _deleteValidatorIfPresent();
      return;
    }
    await validatorFile.writeAsString(validator.serialize(), flush: true);
  }

  Future<void> _deleteValidatorIfPresent() async {
    if (await validatorFile.exists()) {
      await validatorFile.delete();
    }
  }

  Future<void> _deleteValidatorAfterSuccess() async {
    try {
      await _deleteValidatorIfPresent();
    } on FileSystemException {
      // The media file has already been atomically promoted. A stale tiny
      // validator is harmless and will be removed before the next fresh GET;
      // do not turn a completed download into a false failure.
    }
  }

  Future<T> _awaitConnectionPhase<T>(
    Future<T> operation,
    String timeoutMessage,
  ) async {
    final timeout = _phaseTimeout(owner.connectionTimeout);
    final timedOperation = operation.timeout(
      timeout,
      onTimeout: () {
        final failure = _RetryableTransferFailure(
          timeoutMessage,
          kind: HttpAudioTransferFailureKind.connectionTimeout,
        );
        _abortAttempt(failure);
        throw failure;
      },
    );

    return Future.any(<Future<T>>[
      timedOperation,
      _terminalAbort.future.then<T>((_) {
        _throwIfTerminal();
        throw StateError('Unreachable terminal transfer state.');
      }),
    ]);
  }

  Duration _phaseTimeout(Duration requested) {
    // The global watchdog is the authoritative total timeout. A phase should
    // never get a longer standalone timeout than that complete-transfer cap.
    return requested < owner.totalTimeout ? requested : owner.totalTimeout;
  }

  Future<void> _waitBeforeRetry(int failedAttempt) async {
    if (owner.retryDelay == Duration.zero) {
      _throwIfTerminal();
      return;
    }
    final exponent = (failedAttempt - 1).clamp(0, 4).toInt();
    final multiplier = 1 << exponent;
    final delay = owner.retryDelay * multiplier;
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(delay),
      _terminalAbort.future,
    ]);
    _throwIfTerminal();
  }

  _RetryableTransferFailure? _asRetryableFailure(Object error) {
    if (error is _RetryableTransferFailure) {
      return error;
    }
    if (error is SocketException ||
        error is HttpException ||
        error is TlsException) {
      return _RetryableTransferFailure(
        'A network error interrupted the audio transfer.',
        kind: HttpAudioTransferFailureKind.network,
        cause: error,
      );
    }
    if (error is TimeoutException) {
      return _RetryableTransferFailure(
        'A network operation timed out during the audio transfer.',
        kind: HttpAudioTransferFailureKind.network,
        cause: error,
      );
    }
    return null;
  }

  void _startWatchdogs() {
    _totalTimer = Timer(owner.totalTimeout, () {
      _requestTerminalAbort(
        const HttpAudioTransferException(
          'The total audio transfer timeout elapsed.',
          kind: HttpAudioTransferFailureKind.totalTimeout,
        ),
      );
    });
    if (isCancelled != null) {
      _cancellationTimer = Timer.periodic(
        owner.cancellationPollInterval,
        (_) => _pollCancellation(),
      );
    }
  }

  void _stopWatchdogs() {
    _totalTimer?.cancel();
    _totalTimer = null;
    _cancellationTimer?.cancel();
    _cancellationTimer = null;
  }

  void _pollCancellation() {
    if (_terminalException != null ||
        _cancellationCallbackError != null ||
        isCancelled == null) {
      return;
    }
    try {
      if (isCancelled!()) {
        _requestTerminalAbort(
          const HttpAudioTransferException(
            'The audio transfer was cancelled.',
            kind: HttpAudioTransferFailureKind.cancelled,
          ),
        );
      }
    } catch (error, stackTrace) {
      _cancellationCallbackError = error;
      _cancellationCallbackStack = stackTrace;
      _abortActive(error, stackTrace);
      if (!_terminalAbort.isCompleted) {
        _terminalAbort.complete();
      }
    }
  }

  void _throwIfTerminal() {
    final callbackError = _cancellationCallbackError;
    if (callbackError != null) {
      Error.throwWithStackTrace(
        callbackError,
        _cancellationCallbackStack ?? StackTrace.current,
      );
    }
    final terminalException = _terminalException;
    if (terminalException != null) {
      throw terminalException;
    }
  }

  bool get _hasTerminalFailure =>
      _terminalException != null || _cancellationCallbackError != null;

  void _requestTerminalAbort(HttpAudioTransferException exception) {
    if (_terminalException != null || _cancellationCallbackError != null) {
      return;
    }
    _terminalException = exception;
    _abortActive(exception, StackTrace.current);
    if (!_terminalAbort.isCompleted) {
      _terminalAbort.complete();
    }
  }

  void _abortAttempt(Object error) {
    _abortActive(error, StackTrace.current);
  }

  void _abortActive(Object error, [StackTrace? stackTrace]) {
    _activeRequest?.abort(error, stackTrace);
    _activeClient?.close(force: true);
  }

  void _reportProgress({
    required int transferredBytes,
    required int? totalBytes,
    required int attempt,
    required bool resumed,
  }) {
    try {
      onProgress?.call(
        HttpAudioTransferProgress(
          transferredBytes: transferredBytes,
          totalBytes: totalBytes,
          attempt: attempt,
          resumed: resumed,
        ),
      );
    } catch (error, stackTrace) {
      throw _TransferCallbackFailure(error, stackTrace);
    }
  }
}

class _ResponsePlan {
  const _ResponsePlan({
    required this.startingBytes,
    required this.expectedResponseBytes,
    required this.totalBytes,
    required this.append,
  });

  final int startingBytes;
  final int? expectedResponseBytes;
  final int? totalBytes;
  final bool append;

  factory _ResponsePlan.fromResponse(
    HttpClientResponse response, {
    required int requestedOffset,
  }) {
    if (response.statusCode == HttpStatus.ok) {
      final length = response.contentLength < 0 ? null : response.contentLength;
      return _ResponsePlan(
        startingBytes: 0,
        expectedResponseBytes: length,
        totalBytes: length,
        append: false,
      );
    }

    final rawContentRange = response.headers.value(
      HttpHeaders.contentRangeHeader,
    );
    final contentRange = rawContentRange == null
        ? null
        : _ParsedContentRange.tryParse(rawContentRange);
    if (contentRange == null) {
      throw const HttpAudioTransferException(
        'A 206 response did not contain a valid Content-Range header.',
        kind: HttpAudioTransferFailureKind.invalidRange,
      );
    }
    if (contentRange.start != requestedOffset) {
      throw HttpAudioTransferException(
        'Content-Range started at ${contentRange.start}, but '
        '$requestedOffset was requested.',
        kind: HttpAudioTransferFailureKind.invalidRange,
      );
    }

    final rangeLength = contentRange.end - contentRange.start + 1;
    if (response.contentLength >= 0 && response.contentLength != rangeLength) {
      throw const HttpAudioTransferException(
        'Content-Length does not match the declared Content-Range.',
        kind: HttpAudioTransferFailureKind.invalidRange,
      );
    }

    return _ResponsePlan(
      startingBytes: requestedOffset,
      expectedResponseBytes: rangeLength,
      totalBytes: contentRange.total,
      append: requestedOffset > 0,
    );
  }
}

class _ParsedContentRange {
  const _ParsedContentRange({
    required this.start,
    required this.end,
    required this.total,
  });

  final int start;
  final int end;
  final int total;

  static final RegExp _pattern = RegExp(
    r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
    caseSensitive: false,
  );

  static _ParsedContentRange? tryParse(String value) {
    final match = _pattern.firstMatch(value.trim());
    if (match == null) {
      return null;
    }
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final total = int.tryParse(match.group(3)!);
    if (start == null ||
        end == null ||
        start < 0 ||
        end < start ||
        total == null ||
        total <= 0 ||
        end >= total) {
      return null;
    }
    return _ParsedContentRange(start: start, end: end, total: total);
  }
}

bool _containsHeader(Map<String, String> headers, String name) => headers.keys
    .any((headerName) => headerName.toLowerCase() == name.toLowerCase());

String? _headerValue(Map<String, String> headers, String name) {
  final normalizedName = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == normalizedName) {
      return entry.value.trim();
    }
  }
  return null;
}

bool _isStrongEntityTag(String value) {
  final normalized = value.trim();
  if (normalized.length < 2 ||
      normalized.startsWith('W/') ||
      !normalized.startsWith('"') ||
      !normalized.endsWith('"')) {
    return false;
  }
  return normalized
      .substring(1, normalized.length - 1)
      .runes
      .every(
        (value) =>
            value == 0x21 ||
            (value >= 0x23 && value <= 0x7e) ||
            (value >= 0x80 && value <= 0xff),
      );
}

_EntityValidator? _extractResponseValidator(HttpHeaders headers) {
  final etag = headers.value(HttpHeaders.etagHeader)?.trim();
  if (etag != null && _isStrongEntityTag(etag)) {
    return _EntityValidator(_ValidatorKind.etag, etag);
  }
  final lastModified = headers.value(HttpHeaders.lastModifiedHeader)?.trim();
  return lastModified == null || lastModified.isEmpty
      ? null
      : _EntityValidator(_ValidatorKind.lastModified, lastModified);
}

enum _ValidatorKind { etag, lastModified }

class _EntityValidator {
  const _EntityValidator(this.kind, this.value);

  final _ValidatorKind kind;
  final String value;

  bool matches(HttpHeaders headers) {
    final headerName = switch (kind) {
      _ValidatorKind.etag => HttpHeaders.etagHeader,
      _ValidatorKind.lastModified => HttpHeaders.lastModifiedHeader,
    };
    final responseValue = headers.value(headerName)?.trim();
    return responseValue == null || responseValue == value;
  }

  String serialize() => '${kind.name}\n$value';

  static _EntityValidator? tryParse(String serialized) {
    final separator = serialized.indexOf('\n');
    if (separator <= 0 || separator == serialized.length - 1) {
      return null;
    }
    final kindName = serialized.substring(0, separator);
    final value = serialized.substring(separator + 1);
    final kind = switch (kindName) {
      'etag' => _ValidatorKind.etag,
      'lastModified' => _ValidatorKind.lastModified,
      _ => null,
    };
    if (kind == null || value.contains('\n') || value.contains('\r')) {
      return null;
    }
    return _EntityValidator(kind, value);
  }
}

int? _parseUnsatisfiedContentRangeTotal(String? value) {
  if (value == null) {
    return null;
  }
  final match = RegExp(
    r'^bytes\s+\*/(\d+)$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

void _validateContentType(HttpHeaders headers) {
  final value = headers.value(HttpHeaders.contentTypeHeader);
  if (value == null) {
    return;
  }
  final mimeType = value.split(';').first.trim().toLowerCase();
  if (mimeType == 'text/html' ||
      mimeType == 'application/xhtml+xml' ||
      mimeType == 'application/json' ||
      mimeType == 'text/json' ||
      mimeType.endsWith('+json')) {
    throw HttpAudioTransferException(
      'The audio URL returned $mimeType instead of media bytes.',
      kind: HttpAudioTransferFailureKind.invalidContent,
    );
  }
}

const int _maximumSniffBytes = 512;

enum _PayloadDisposition { undecided, media, html, json, emptyOrWhitespace }

void _appendPrefix(List<int> prefix, List<int> chunk) {
  if (prefix.length >= _maximumSniffBytes) {
    return;
  }
  final remaining = _maximumSniffBytes - prefix.length;
  prefix.addAll(chunk.take(remaining));
}

_PayloadDisposition _inspectPayloadPrefix(
  List<int> bytes, {
  bool endOfStream = false,
}) {
  var index = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf) {
    index = 3;
  }
  while (index < bytes.length && _isAsciiWhitespace(bytes[index])) {
    index++;
  }
  if (index >= bytes.length) {
    if (endOfStream || bytes.length >= _maximumSniffBytes) {
      return _PayloadDisposition.emptyOrWhitespace;
    }
    return _PayloadDisposition.undecided;
  }

  final first = bytes[index];
  if (first == 0x3c) {
    return _PayloadDisposition.html;
  }
  if (first == 0x7b || first == 0x5b) {
    return _PayloadDisposition.json;
  }
  return _PayloadDisposition.media;
}

bool _isAsciiWhitespace(int value) =>
    value == 0x20 || value == 0x09 || value == 0x0a || value == 0x0d;

class _RetryableTransferFailure implements Exception {
  const _RetryableTransferFailure(
    this.message, {
    required this.kind,
    this.statusCode,
    this.cause,
  });

  final String message;
  final HttpAudioTransferFailureKind kind;
  final int? statusCode;
  final Object? cause;
}

bool _isRetryableHttpStatus(int statusCode) =>
    statusCode == 408 ||
    statusCode == 425 ||
    statusCode == HttpStatus.tooManyRequests ||
    statusCode >= HttpStatus.internalServerError;

class _TransferCallbackFailure implements Exception {
  const _TransferCallbackFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
