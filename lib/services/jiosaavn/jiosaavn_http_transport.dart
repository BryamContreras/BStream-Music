import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class JioSaavnHttpResponse {
  const JioSaavnHttpResponse({
    required this.statusCode,
    required this.body,
    this.headers = const {},
  });

  final int statusCode;
  final Uint8List body;
  final Map<String, String> headers;
}

/// Small, injectable transport shared by API requests and bounded CDN probes.
abstract interface class JioSaavnHttpTransport {
  Future<JioSaavnHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maximumBytes = 512 * 1024,
    bool readPrefix = false,
    Duration? timeout,
  });

  Future<void> close();
}

class IoJioSaavnHttpTransport implements JioSaavnHttpTransport {
  IoJioSaavnHttpTransport({
    HttpClient? client,
    this.requestTimeout = const Duration(seconds: 6),
  }) : _client = client ?? HttpClient() {
    _client
      ..connectionTimeout = const Duration(seconds: 4)
      ..autoUncompress = false;
  }

  final HttpClient _client;
  final Duration requestTimeout;

  @override
  Future<JioSaavnHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maximumBytes = 512 * 1024,
    bool readPrefix = false,
    Duration? timeout,
  }) async {
    final limit = timeout ?? requestTimeout;
    final expiration = TimeoutException(
      'JioSaavn request exceeded deadline',
      limit,
    );
    if (limit <= Duration.zero) throw expiration;
    HttpClientRequest? activeRequest;
    StreamIterator<List<int>>? activeBody;
    var expired = false;
    Future<JioSaavnHttpResponse> load() async {
      final request = await _client.getUrl(uri);
      activeRequest = request;
      if (expired) {
        request.abort(expiration);
        throw expiration;
      }
      request.followRedirects = false;
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      HttpClientResponse response;
      try {
        response = await request.close();
      } on Object {
        request.abort();
        rethrow;
      }
      if (!readPrefix && response.contentLength > maximumBytes) {
        request.abort();
        throw const FormatException('JioSaavn response exceeds size limit');
      }
      final output = BytesBuilder(copy: false);
      final body = StreamIterator(response);
      activeBody = body;
      try {
        if (expired) throw expiration;
        while (await body.moveNext()) {
          final chunk = body.current;
          final remaining = maximumBytes - output.length;
          if (chunk.length > remaining) {
            if (!readPrefix) {
              throw const FormatException(
                'JioSaavn response exceeds size limit',
              );
            }
            output.add(chunk.sublist(0, remaining));
            request.abort();
            break;
          }
          output.add(chunk);
          if (readPrefix && output.length == maximumBytes) {
            request.abort();
            break;
          }
        }
      } on Object {
        request.abort();
        rethrow;
      } finally {
        await body.cancel();
        activeBody = null;
      }
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      });
      return JioSaavnHttpResponse(
        statusCode: response.statusCode,
        body: output.takeBytes(),
        headers: Map.unmodifiable(responseHeaders),
      );
    }

    return load().timeout(
      limit,
      onTimeout: () {
        expired = true;
        // Stop a stalled/dripping response, rather than only stop awaiting it.
        // If connection creation is still pending, load aborts it as soon as the
        // HttpClient exposes the request, without closing unrelated requests.
        activeRequest?.abort(expiration);
        activeBody?.cancel().ignore();
        throw expiration;
      },
    );
  }

  @override
  Future<void> close() async => _client.close(force: true);
}
