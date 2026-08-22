import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/utils/bounded_byte_stream.dart';
import 'youtube_music_account_transport.dart';

/// Production HTTPS transport for authenticated InnerTube account calls.
///
/// Credentials are accepted only as request headers and are sent exclusively
/// to the exact `music.youtube.com` origin. Redirect following is disabled so
/// cookies cannot be forwarded to a redirect target.
class IoYouTubeMusicAccountTransport implements YouTubeMusicAccountTransport {
  IoYouTubeMusicAccountTransport({
    HttpClient? client,
    String? apiKey,
    Duration connectionTimeout = const Duration(seconds: 6),
    this.maxRequestBytes = 1024 * 1024,
    this.maxResponseBytes = 4 * 1024 * 1024,
  }) : _client = client ?? HttpClient(),
       _apiKey = _normalizeApiKey(apiKey) {
    if (connectionTimeout <= Duration.zero) {
      throw ArgumentError.value(
        connectionTimeout,
        'connectionTimeout',
        'Must be positive.',
      );
    }
    if (maxRequestBytes <= 0) {
      throw ArgumentError.value(
        maxRequestBytes,
        'maxRequestBytes',
        'Must be positive.',
      );
    }
    if (maxResponseBytes <= 0) {
      throw ArgumentError.value(
        maxResponseBytes,
        'maxResponseBytes',
        'Must be positive.',
      );
    }
    _client.connectionTimeout = connectionTimeout;
  }

  static const String _host = 'music.youtube.com';
  static const String _apiPrefix = '/youtubei/v1/';
  static final RegExp _safeEndpoint = RegExp(r'^[a-z0-9_]+(?:/[a-z0-9_]+)*$');

  final HttpClient _client;
  final String? _apiKey;
  final int maxRequestBytes;
  final int maxResponseBytes;
  bool _closed = false;

  @override
  Future<YouTubeMusicAccountResponse> send(
    YouTubeMusicAccountRequest request,
  ) async {
    if (_closed) {
      throw const YouTubeMusicAccountTransportException(
        delivery: YouTubeMusicRequestDelivery.notSent,
        retryableForRead: false,
      );
    }
    if (!_safeEndpoint.hasMatch(request.endpoint)) {
      throw const YouTubeMusicAccountTransportException(
        delivery: YouTubeMusicRequestDelivery.notSent,
        retryableForRead: false,
      );
    }

    late final List<int> encodedBody;
    try {
      encodedBody = utf8.encode(jsonEncode(request.body));
    } on Object {
      throw const YouTubeMusicAccountTransportException(
        delivery: YouTubeMusicRequestDelivery.notSent,
        retryableForRead: false,
      );
    }
    if (encodedBody.length > maxRequestBytes) {
      throw const YouTubeMusicAccountTransportException(
        delivery: YouTubeMusicRequestDelivery.notSent,
        retryableForRead: false,
      );
    }

    late final String? requestApiKey;
    try {
      requestApiKey = _normalizeApiKey(request.apiKey) ?? _apiKey;
    } on ArgumentError {
      throw const YouTubeMusicAccountTransportException(
        delivery: YouTubeMusicRequestDelivery.notSent,
        retryableForRead: false,
      );
    }
    final uri = _requestUri(request, apiKey: requestApiKey);
    HttpClientRequest? activeRequest;
    var dispatchStarted = false;
    try {
      final operation = () async {
        final httpRequest = await _client.postUrl(uri);
        activeRequest = httpRequest;
        httpRequest.followRedirects = false;
        httpRequest.headers.contentType = ContentType.json;
        httpRequest.headers.set(HttpHeaders.acceptHeader, 'application/json');
        for (final entry in request.headers.entries) {
          if (_isUnsafeCallerHeader(entry.key)) {
            continue;
          }
          httpRequest.headers.set(entry.key, entry.value);
        }
        httpRequest.contentLength = encodedBody.length;
        httpRequest.add(encodedBody);
        dispatchStarted = true;
        final httpResponse = await httpRequest.close();
        final responseBytes = await collectBoundedByteStream(
          httpResponse,
          maximumBytes: maxResponseBytes,
          declaredLength: httpResponse.contentLength < 0
              ? null
              : httpResponse.contentLength,
          idleTimeout: request.timeout,
          totalTimeout: request.timeout,
        );
        final bodyText = utf8.decode(responseBytes);
        final decodedBody = _decodeResponseBody(
          bodyText,
          statusCode: httpResponse.statusCode,
        );
        return YouTubeMusicAccountResponse(
          statusCode: httpResponse.statusCode,
          body: decodedBody,
          headers: _safeResponseHeaders(httpResponse.headers),
        );
      }();

      return await operation.timeout(
        request.timeout,
        onTimeout: () {
          activeRequest?.abort(
            TimeoutException('YouTube Music account request timed out.'),
          );
          throw TimeoutException('YouTube Music account request timed out.');
        },
      );
    } on ByteStreamLimitException {
      throw YouTubeMusicAccountTransportException(
        delivery: dispatchStarted
            ? YouTubeMusicRequestDelivery.possiblySent
            : YouTubeMusicRequestDelivery.notSent,
        retryableForRead: false,
      );
    } on FormatException {
      throw YouTubeMusicAccountTransportException(
        delivery: dispatchStarted
            ? YouTubeMusicRequestDelivery.possiblySent
            : YouTubeMusicRequestDelivery.notSent,
        retryableForRead: false,
      );
    } on TimeoutException {
      throw YouTubeMusicAccountTransportException(
        delivery: dispatchStarted
            ? YouTubeMusicRequestDelivery.possiblySent
            : YouTubeMusicRequestDelivery.notSent,
        retryableForRead: true,
      );
    } on SocketException {
      throw YouTubeMusicAccountTransportException(
        delivery: dispatchStarted
            ? YouTubeMusicRequestDelivery.possiblySent
            : YouTubeMusicRequestDelivery.notSent,
        retryableForRead: true,
      );
    } on HandshakeException {
      throw YouTubeMusicAccountTransportException(
        delivery: dispatchStarted
            ? YouTubeMusicRequestDelivery.possiblySent
            : YouTubeMusicRequestDelivery.notSent,
        retryableForRead: true,
      );
    } on HttpException {
      throw YouTubeMusicAccountTransportException(
        delivery: dispatchStarted
            ? YouTubeMusicRequestDelivery.possiblySent
            : YouTubeMusicRequestDelivery.notSent,
        retryableForRead: true,
      );
    } on YouTubeMusicAccountTransportException {
      rethrow;
    } on Object {
      throw YouTubeMusicAccountTransportException(
        delivery: dispatchStarted
            ? YouTubeMusicRequestDelivery.possiblySent
            : YouTubeMusicRequestDelivery.notSent,
        retryableForRead: false,
      );
    }
  }

  Uri _requestUri(
    YouTubeMusicAccountRequest request, {
    required String? apiKey,
  }) {
    final continuation = request.body['continuation'];
    final query = <String, String>{
      'prettyPrint': 'false',
      'key': ?apiKey,
      if (continuation is String &&
          continuation.isNotEmpty) ...<String, String>{
        'continuation': continuation,
        'ctoken': continuation,
      },
    };
    return Uri.https(_host, '$_apiPrefix${request.endpoint}', query);
  }

  /// Releases the underlying sockets. The gateway does not own transport
  /// lifetime, so the application composition root calls this explicitly.
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _client.close(force: true);
  }
}

String? _normalizeApiKey(String? apiKey) {
  final normalized = apiKey?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  if (normalized.length > 512 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(normalized)) {
    throw ArgumentError.value(apiKey, 'apiKey', 'Invalid InnerTube API key.');
  }
  return normalized;
}

bool _isUnsafeCallerHeader(String name) {
  final normalized = name.toLowerCase();
  return normalized == HttpHeaders.hostHeader ||
      normalized == HttpHeaders.contentLengthHeader ||
      normalized == HttpHeaders.transferEncodingHeader ||
      normalized == HttpHeaders.connectionHeader;
}

Map<String, String> _safeResponseHeaders(HttpHeaders headers) {
  final values = <String, String>{};
  for (final name in const <String>[
    HttpHeaders.retryAfterHeader,
    HttpHeaders.contentTypeHeader,
    HttpHeaders.dateHeader,
  ]) {
    final value = headers.value(name);
    if (value != null) {
      values[name] = value;
    }
  }
  return values;
}

Object? _decodeResponseBody(String body, {required int statusCode}) {
  if (body.trim().isEmpty) {
    return const <String, Object?>{};
  }
  try {
    return jsonDecode(body);
  } on FormatException {
    if (statusCode >= 200 && statusCode < 300) {
      rethrow;
    }
    // Do not retain an HTML/error body that may echo account data.
    return null;
  }
}
