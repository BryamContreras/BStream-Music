import 'dart:async';
import 'dart:io';

import 'innertube_transport.dart';

typedef InnerTubeRetryDelay = Future<void> Function(Duration duration);
typedef InnerTubeRetryClock = DateTime Function();

Future<void> defaultInnerTubeRetryDelay(Duration duration) =>
    Future<void>.delayed(duration);

DateTime defaultInnerTubeRetryClock() => DateTime.now().toUtc();

/// Bounded retry policy for anonymous YouTube Music catalog requests.
///
/// Authentication/client configuration failures are deliberately excluded:
/// [InnerTubeSearchService] handles those by rotating the bootstrap identity.
/// Only failures that are likely to recover without changing the request are
/// retried here.
class InnerTubeRetryPolicy {
  const InnerTubeRetryPolicy({
    this.maxAttempts = 3,
    this.backoff = const <Duration>[
      Duration(milliseconds: 350),
      Duration(seconds: 1),
    ],
    this.maximumRetryAfter = const Duration(seconds: 8),
  }) : assert(maxAttempts > 0);

  final int maxAttempts;
  final List<Duration> backoff;
  final Duration maximumRetryAfter;

  bool shouldRetryStatus(int statusCode) {
    return statusCode == HttpStatus.requestTimeout ||
        statusCode == 425 ||
        statusCode == HttpStatus.tooManyRequests ||
        statusCode >= HttpStatus.internalServerError;
  }

  Duration delayBeforeRetry({
    required int retryNumber,
    InnerTubeHttpResponse? response,
    required DateTime now,
  }) {
    if (retryNumber < 1 || retryNumber >= maxAttempts) {
      throw RangeError.range(retryNumber, 1, maxAttempts - 1, 'retryNumber');
    }
    if (retryNumber > backoff.length) {
      throw StateError(
        'InnerTube retry policy needs at least ${maxAttempts - 1} '
        'backoff values.',
      );
    }
    final retryAfter = response == null
        ? null
        : _parseRetryAfter(response.headers['retry-after'], now);
    if (retryAfter != null) {
      return retryAfter > maximumRetryAfter ? maximumRetryAfter : retryAfter;
    }
    return backoff[retryNumber - 1];
  }

  Duration? _parseRetryAfter(String? rawValue, DateTime now) {
    final value = rawValue?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
    }
    try {
      final retryAt = HttpDate.parse(value).toUtc();
      final difference = retryAt.difference(now.toUtc());
      return difference.isNegative ? Duration.zero : difference;
    } on Object {
      return null;
    }
  }
}
