import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/utils/bounded_byte_stream.dart';

class InnerTubeHttpResponse {
  const InnerTubeHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

abstract interface class InnerTubeTransport {
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  });

  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  });

  void close();
}

class IoInnerTubeTransport implements InnerTubeTransport {
  IoInnerTubeTransport({
    HttpClient? client,
    Duration connectionTimeout = const Duration(seconds: 6),
    this.maxResponseBytes = 4 * 1024 * 1024,
  }) : _client = client ?? HttpClient() {
    if (connectionTimeout <= Duration.zero) {
      throw ArgumentError.value(
        connectionTimeout,
        'connectionTimeout',
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

  final HttpClient _client;
  final int maxResponseBytes;
  bool _closed = false;

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) {
    return _send(
      uri,
      headers: headers,
      timeout: timeout,
      openRequest: _client.getUrl,
    );
  }

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) {
    return _send(
      uri,
      headers: headers,
      timeout: timeout,
      openRequest: _client.postUrl,
      body: body,
    );
  }

  Future<InnerTubeHttpResponse> _send(
    Uri uri, {
    required Map<String, String> headers,
    required Future<HttpClientRequest> Function(Uri uri) openRequest,
    Duration? timeout,
    Object? body,
  }) async {
    if (_closed) {
      throw StateError('The InnerTube transport is closed.');
    }

    HttpClientRequest? activeRequest;
    final operation = () async {
      final request = await openRequest(uri);
      activeRequest = request;
      headers.forEach(request.headers.set);
      if (body != null) {
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final responseTimeout = timeout ?? const Duration(seconds: 15);
      late final List<int> bytes;
      try {
        bytes = await collectBoundedByteStream(
          response,
          maximumBytes: maxResponseBytes,
          declaredLength: response.contentLength < 0
              ? null
              : response.contentLength,
          idleTimeout: responseTimeout,
          totalTimeout: responseTimeout,
        );
      } on ByteStreamLimitException catch (error) {
        throw FormatException(error.toString());
      }
      return InnerTubeHttpResponse(
        statusCode: response.statusCode,
        body: utf8.decode(bytes),
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
