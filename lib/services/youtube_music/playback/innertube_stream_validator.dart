import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Opens the exact GoogleVideo URL that will be handed to the player.
///
/// YouTube can return a valid first chunk and reject a later ranged request
/// when a GVS PO token is missing or bound to the wrong identifier. Cold-start
/// access can extend to roughly two MiB, so the probe starts after three MiB
/// instead of checking only byte zero.
abstract interface class InnerTubeStreamValidator {
  Future<InnerTubeStreamProbe> validate(
    Uri uri, {
    required Map<String, String> headers,
    int? contentLength,
  });
}

final class InnerTubeStreamProbe {
  const InnerTubeStreamProbe({
    required this.statusCode,
    required this.elapsed,
    required this.probedOffset,
    required this.receivedBytes,
    this.contentLength,
  });

  final int statusCode;
  final Duration elapsed;
  final int probedOffset;
  final int receivedBytes;
  final int? contentLength;
}

final class InnerTubeStreamValidationException implements Exception {
  const InnerTubeStreamValidationException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  final String message;
  final int? statusCode;
  final Object? cause;

  bool get shouldRefreshUrl =>
      statusCode == HttpStatus.forbidden ||
      statusCode == HttpStatus.gone ||
      statusCode == HttpStatus.tooManyRequests;

  /// Only a forbidden response plausibly indicates a GVS token with the wrong
  /// content binding. Gone/rate-limit responses require refresh or backoff,
  /// not an immediate second token request against the same URL.
  bool get isPoTokenRejection => statusCode == HttpStatus.forbidden;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'InnerTubeStreamValidationException: $message$status';
  }
}

typedef InnerTubeHttpClientFactory = HttpClient Function();

final class IoInnerTubeStreamValidator implements InnerTubeStreamValidator {
  IoInnerTubeStreamValidator({
    this.timeout = const Duration(seconds: 8),
    this.deepProbeOffset = 3 * 1024 * 1024,
    this.probeBytes = 32 * 1024,
    InnerTubeHttpClientFactory? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
    if (deepProbeOffset < 0) {
      throw ArgumentError.value(
        deepProbeOffset,
        'deepProbeOffset',
        'Must not be negative.',
      );
    }
    if (probeBytes < 1) {
      throw ArgumentError.value(probeBytes, 'probeBytes', 'Must be positive.');
    }
  }

  final Duration timeout;
  final int deepProbeOffset;
  final int probeBytes;
  final InnerTubeHttpClientFactory _clientFactory;

  @override
  Future<InnerTubeStreamProbe> validate(
    Uri uri, {
    required Map<String, String> headers,
    int? contentLength,
  }) async {
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw ArgumentError.value(uri, 'uri', 'Must be an HTTP(S) URL.');
    }

    final client = _clientFactory()..connectionTimeout = timeout;
    final stopwatch = Stopwatch()..start();
    try {
      return await _validate(
        client,
        uri,
        headers: headers,
        contentLength: contentLength,
        stopwatch: stopwatch,
      ).timeout(
        timeout,
        onTimeout: () => throw InnerTubeStreamValidationException(
          'The media probe timed out.',
          cause: TimeoutException('Media probe timed out.', timeout),
        ),
      );
    } on InnerTubeStreamValidationException {
      rethrow;
    } catch (error) {
      throw InnerTubeStreamValidationException(
        'The resolved media URL could not be opened.',
        cause: error,
      );
    } finally {
      stopwatch.stop();
      client.close(force: true);
    }
  }

  Future<InnerTubeStreamProbe> _validate(
    HttpClient client,
    Uri uri, {
    required Map<String, String> headers,
    required int? contentLength,
    required Stopwatch stopwatch,
  }) async {
    var requestedOffset = contentLength != null && contentLength > 0
        ? deepProbeOffset.clamp(0, contentLength - 1)
        : deepProbeOffset;
    var requestedEnd = contentLength != null && contentLength > 0
        ? (requestedOffset + probeBytes - 1).clamp(
            requestedOffset,
            contentLength - 1,
          )
        : requestedOffset + probeBytes - 1;

    Future<HttpClientResponse> openRange() async {
      final request = await client.getUrl(uri);
      _copyHeaders(headers, request.headers);
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$requestedOffset-$requestedEnd',
      );
      return request.close();
    }

    var response = await openRange();
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      final remoteLength = _parseUnsatisfiedContentRangeTotal(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      // A stream can legitimately be shorter than the fixed deep offset when
      // the player response did not advertise its size (or advertised a stale
      // one). Prove access to the actual tail instead of rejecting it solely
      // because bytes after EOF cannot exist.
      if (remoteLength != null &&
          remoteLength > 0 &&
          requestedOffset >= remoteLength &&
          requestedOffset != remoteLength - 1) {
        await response.drain<void>();
        contentLength = remoteLength;
        requestedOffset = remoteLength - 1;
        requestedEnd = requestedOffset;
        response = await openRange();
      }
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw InnerTubeStreamValidationException(
        'The resolved media URL was rejected.',
        statusCode: response.statusCode,
      );
    }

    final mimeType = response.headers.contentType?.mimeType.toLowerCase();
    if (_isTextual(mimeType)) {
      await response.drain<void>();
      throw InnerTubeStreamValidationException(
        'The resolved URL returned non-media content.',
        statusCode: response.statusCode,
      );
    }

    var actualOffset = 0;
    if (response.statusCode == HttpStatus.partialContent) {
      final range = response.headers.value(HttpHeaders.contentRangeHeader);
      final parsed = _parseContentRange(range);
      if (parsed == null || parsed.start != requestedOffset) {
        await response.drain<void>();
        throw InnerTubeStreamValidationException(
          'The media server returned an invalid byte range.',
          statusCode: response.statusCode,
        );
      }
      actualOffset = parsed.start;
      contentLength ??= parsed.total;
    }

    // A server that ignores Range returns 200. Consume through the requested
    // offset so this remains a deep probe instead of silently becoming a
    // byte-zero check.
    final bytesNeeded = response.statusCode == HttpStatus.partialContent
        ? 1
        : requestedOffset + 1;
    final prefix = <int>[];
    var received = 0;
    final iterator = StreamIterator<List<int>>(response);
    try {
      while (received < bytesNeeded && await iterator.moveNext()) {
        final chunk = iterator.current;
        if (chunk.isEmpty) continue;
        if (prefix.length < 512) {
          prefix.addAll(chunk.take(512 - prefix.length));
        }
        received += chunk.length;
      }
    } finally {
      await iterator.cancel();
    }
    if (received < bytesNeeded) {
      throw InnerTubeStreamValidationException(
        'The media response ended before the deep probe offset.',
        statusCode: response.statusCode,
      );
    }
    // A 206 that begins beyond byte zero contains arbitrary media payload, not
    // a file prefix. Bytes such as '<', '{', or '[' are therefore perfectly
    // valid there and must not be mistaken for an HTML/JSON challenge.
    if ((response.statusCode != HttpStatus.partialContent ||
            actualOffset == 0) &&
        _looksLikeText(prefix)) {
      throw InnerTubeStreamValidationException(
        'The resolved URL returned a challenge instead of media.',
        statusCode: response.statusCode,
      );
    }

    return InnerTubeStreamProbe(
      statusCode: response.statusCode,
      elapsed: stopwatch.elapsed,
      probedOffset: response.statusCode == HttpStatus.partialContent
          ? actualOffset
          : requestedOffset,
      receivedBytes: received,
      contentLength: contentLength,
    );
  }

  void _copyHeaders(Map<String, String> source, HttpHeaders target) {
    for (final entry in source.entries) {
      final name = entry.key.trim().toLowerCase();
      if (name.isEmpty ||
          name == HttpHeaders.hostHeader ||
          name == HttpHeaders.contentLengthHeader ||
          name == HttpHeaders.rangeHeader) {
        continue;
      }
      target.set(entry.key, entry.value);
    }
  }

  bool _isTextual(String? mimeType) =>
      mimeType == 'text/html' ||
      mimeType == 'application/json' ||
      mimeType == 'application/xml' ||
      mimeType == 'text/xml';

  bool _looksLikeText(List<int> bytes) {
    if (bytes.isEmpty) return true;
    final first = bytes.firstWhere((byte) => byte > 0x20, orElse: () => 0);
    if (first != 0x3c && first != 0x7b && first != 0x5b) return false;
    final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
    return text.startsWith('<') || text.startsWith('{') || text.startsWith('[');
  }

  _ContentRange? _parseContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    final total = match.group(3) == '*' ? null : int.tryParse(match.group(3)!);
    if (start == null ||
        end == null ||
        end < start ||
        (total != null && (total <= 0 || end >= total))) {
      return null;
    }
    return _ContentRange(start: start, end: end, total: total);
  }

  int? _parseUnsatisfiedContentRangeTotal(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^bytes\s+\*/(\d+)$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}

final class _ContentRange {
  const _ContentRange({
    required this.start,
    required this.end,
    required this.total,
  });

  final int start;
  final int end;
  final int? total;
}
