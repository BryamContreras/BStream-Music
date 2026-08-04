import 'dart:async';
import 'dart:convert';
import 'dart:io';

class LrclibResponse {
  LrclibResponse({
    required this.statusCode,
    required this.body,
    Map<String, String> headers = const {},
  }) : headers = Map.unmodifiable(
         headers.map((name, value) => MapEntry(name.toLowerCase(), value)),
       );

  final int statusCode;
  final String body;
  final Map<String, String> headers;

  String? header(String name) => headers[name.toLowerCase()];
}

abstract class LrclibTransport {
  Future<LrclibResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  });

  void close();
}

class IoLrclibTransport implements LrclibTransport {
  IoLrclibTransport({
    HttpClient? client,
    Duration connectionTimeout = const Duration(seconds: 6),
  }) : _client = client ?? HttpClient() {
    if (connectionTimeout <= Duration.zero) {
      throw ArgumentError.value(
        connectionTimeout,
        'connectionTimeout',
        'Must be positive.',
      );
    }
    _client.connectionTimeout = connectionTimeout;
  }

  final HttpClient _client;
  bool _closed = false;

  @override
  Future<LrclibResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    if (_closed) {
      throw StateError('The LRCLIB transport is closed.');
    }

    HttpClientRequest? activeRequest;
    final operation = () async {
      final request = await _client.getUrl(uri);
      activeRequest = request;
      headers.forEach(request.headers.set);
      final response = await request.close();
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name] = values.join(', ');
      });
      return LrclibResponse(
        statusCode: response.statusCode,
        body: await response.transform(utf8.decoder).join(),
        headers: responseHeaders,
      );
    }();
    if (timeout == null) {
      return operation;
    }
    try {
      return await operation.timeout(timeout);
    } on TimeoutException catch (error) {
      activeRequest?.abort(error);
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _client.close(force: true);
  }
}
