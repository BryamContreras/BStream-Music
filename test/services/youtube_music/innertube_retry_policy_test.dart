import 'dart:io';

import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = InnerTubeRetryPolicy();
  final now = DateTime.utc(2026, 8, 22, 12);

  test('retries only transient HTTP responses', () {
    expect(policy.shouldRetryStatus(HttpStatus.requestTimeout), isTrue);
    expect(policy.shouldRetryStatus(HttpStatus.tooManyRequests), isTrue);
    expect(policy.shouldRetryStatus(HttpStatus.internalServerError), isTrue);
    expect(policy.shouldRetryStatus(HttpStatus.serviceUnavailable), isTrue);
    expect(policy.shouldRetryStatus(HttpStatus.badRequest), isFalse);
    expect(policy.shouldRetryStatus(HttpStatus.unauthorized), isFalse);
    expect(policy.shouldRetryStatus(HttpStatus.notFound), isFalse);
  });

  test('honors Retry-After seconds and caps excessive waits', () {
    const short = InnerTubeHttpResponse(
      statusCode: HttpStatus.tooManyRequests,
      body: '',
      headers: {'retry-after': '3'},
    );
    const excessive = InnerTubeHttpResponse(
      statusCode: HttpStatus.tooManyRequests,
      body: '',
      headers: {'retry-after': '60'},
    );

    expect(
      policy.delayBeforeRetry(retryNumber: 1, response: short, now: now),
      const Duration(seconds: 3),
    );
    expect(
      policy.delayBeforeRetry(retryNumber: 1, response: excessive, now: now),
      const Duration(seconds: 8),
    );
  });

  test('parses HTTP-date Retry-After and falls back deterministically', () {
    final dated = InnerTubeHttpResponse(
      statusCode: HttpStatus.serviceUnavailable,
      body: '',
      headers: {
        'retry-after': HttpDate.format(now.add(const Duration(seconds: 4))),
      },
    );
    const malformed = InnerTubeHttpResponse(
      statusCode: HttpStatus.serviceUnavailable,
      body: '',
      headers: {'retry-after': 'later'},
    );

    expect(
      policy.delayBeforeRetry(retryNumber: 1, response: dated, now: now),
      const Duration(seconds: 4),
    );
    expect(
      policy.delayBeforeRetry(retryNumber: 2, response: malformed, now: now),
      const Duration(seconds: 1),
    );
  });
}
