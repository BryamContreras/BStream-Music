import 'dart:async';

typedef YouTubeMusicAccountJson = Map<String, Object?>;

enum YouTubeMusicAccountRequestKind { read, mutation }

enum YouTubeMusicRequestDelivery {
  /// The transport knows that no request bytes reached the remote service.
  notSent,

  /// The transport cannot prove whether the service applied the request.
  possiblySent,
}

class YouTubeMusicSessionHeaderRequest {
  const YouTubeMusicSessionHeaderRequest({
    required this.endpoint,
    required this.kind,
  });

  final String endpoint;
  final YouTubeMusicAccountRequestKind kind;
}

/// Supplies the authenticated headers owned by the login/session subsystem.
///
/// Implementations may refresh derived authorization headers, but must not
/// perform account mutations. The gateway asks for fresh headers per attempt.
abstract interface class YouTubeMusicSessionHeadersProvider {
  Future<YouTubeMusicSessionHeaders> headersFor(
    YouTubeMusicSessionHeaderRequest request,
  );
}

class StaticYouTubeMusicSessionHeadersProvider
    implements YouTubeMusicSessionHeadersProvider {
  StaticYouTubeMusicSessionHeadersProvider(YouTubeMusicSessionHeaders headers)
    : _headers = headers;

  final YouTubeMusicSessionHeaders _headers;

  @override
  Future<YouTubeMusicSessionHeaders> headersFor(
    YouTubeMusicSessionHeaderRequest request,
  ) async => _headers;
}

class YouTubeMusicSessionHeaders {
  YouTubeMusicSessionHeaders(Map<String, String> values, {String? apiKey})
    : _values = Map<String, String>.unmodifiable(values),
      apiKey = _boundedOptionalValue(apiKey, 'apiKey', 512);

  final Map<String, String> _values;

  /// Current bootstrap API key. Kept outside the HTTP header map so the
  /// transport can add it as an InnerTube query parameter without logging it.
  final String? apiKey;

  Map<String, String> toTransportMap() => Map<String, String>.of(_values);

  Map<String, String> get redacted {
    return Map<String, String>.unmodifiable({
      for (final entry in _values.entries)
        entry.key: _isSensitiveHeader(entry.key) ? '<redacted>' : entry.value,
    });
  }

  @override
  String toString() => 'YouTubeMusicSessionHeaders($redacted)';
}

class YouTubeMusicAccountRequest {
  YouTubeMusicAccountRequest({
    required this.endpoint,
    required this.kind,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required this.timeout,
    this.apiKey,
  }) : headers = Map<String, String>.unmodifiable(headers),
       body = Map<String, Object?>.unmodifiable(body);

  /// InnerTube path relative to `/youtubei/v1/`, for example `browse`.
  final String endpoint;
  final YouTubeMusicAccountRequestKind kind;
  final Map<String, String> headers;
  final Map<String, Object?> body;
  final Duration timeout;
  final String? apiKey;

  @override
  String toString() {
    final redactedHeaders = <String, String>{
      for (final entry in headers.entries)
        entry.key: _isSensitiveHeader(entry.key) ? '<redacted>' : entry.value,
    };
    return 'YouTubeMusicAccountRequest('
        'endpoint: $endpoint, kind: $kind, headers: $redactedHeaders, '
        'bodyKeys: ${body.keys.toList(growable: false)}, timeout: $timeout)';
  }
}

class YouTubeMusicAccountResponse {
  YouTubeMusicAccountResponse({
    required this.statusCode,
    required this.body,
    Map<String, String> headers = const <String, String>{},
  }) : headers = Map<String, String>.unmodifiable(headers);

  final int statusCode;
  final Object? body;
  final Map<String, String> headers;

  @override
  String toString() =>
      'YouTubeMusicAccountResponse(statusCode: $statusCode, '
      'bodyType: ${body.runtimeType})';
}

abstract interface class YouTubeMusicAccountTransport {
  Future<YouTubeMusicAccountResponse> send(YouTubeMusicAccountRequest request);
}

class YouTubeMusicAccountTransportException implements Exception {
  const YouTubeMusicAccountTransportException({
    required this.delivery,
    required this.retryableForRead,
    this.cause,
  });

  final YouTubeMusicRequestDelivery delivery;
  final bool retryableForRead;
  final Object? cause;

  @override
  String toString() =>
      'YouTubeMusicAccountTransportException('
      'delivery: $delivery, retryableForRead: $retryableForRead)';
}

class YouTubeMusicAccountException implements Exception {
  const YouTubeMusicAccountException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'YouTubeMusicAccountException: $message'
      : 'YouTubeMusicAccountException($statusCode): $message';
}

typedef YouTubeMusicAccountRetryDelay =
    Future<void> Function(Duration duration);

Future<void> defaultYouTubeMusicAccountRetryDelay(Duration duration) =>
    Future<void>.delayed(duration);

class YouTubeMusicAccountReadRetryPolicy {
  const YouTubeMusicAccountReadRetryPolicy({
    this.maxAttempts = 3,
    this.backoff = const <Duration>[
      Duration(milliseconds: 300),
      Duration(milliseconds: 900),
    ],
  }) : assert(maxAttempts > 0);

  final int maxAttempts;
  final List<Duration> backoff;

  bool shouldRetryStatus(int statusCode) {
    return statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode >= 500;
  }

  Duration delayForRetry(int retryNumber) {
    if (retryNumber < 1 || retryNumber >= maxAttempts) {
      throw RangeError.range(retryNumber, 1, maxAttempts - 1, 'retryNumber');
    }
    if (retryNumber > backoff.length) {
      throw StateError(
        'The read retry policy needs at least ${maxAttempts - 1} delays.',
      );
    }
    return backoff[retryNumber - 1];
  }
}

bool _isSensitiveHeader(String name) {
  final normalized = name.toLowerCase();
  return normalized == 'authorization' ||
      normalized == 'cookie' ||
      normalized == 'set-cookie' ||
      normalized == 'x-goog-authuser' ||
      normalized == 'x-goog-pageid' ||
      normalized.contains('token') ||
      normalized.contains('secret') ||
      normalized.contains('visitor') ||
      normalized.contains('api-key') ||
      normalized.contains('apikey');
}

String? _boundedOptionalValue(String? value, String name, int maximumLength) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  if (normalized.length > maximumLength ||
      normalized.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
    throw ArgumentError.value(value, name, 'Invalid bounded value.');
  }
  return normalized;
}
