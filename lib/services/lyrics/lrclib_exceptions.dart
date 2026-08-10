class LrclibException implements Exception {
  const LrclibException(this.message);

  final String message;

  @override
  String toString() => 'LrclibException: $message';
}

class LrclibHttpException extends LrclibException {
  LrclibHttpException(this.statusCode, String body)
    : body = body.trim(),
      super('LRCLIB request failed with HTTP $statusCode.');

  final int statusCode;
  final String body;
}

class LrclibRateLimitException extends LrclibException {
  const LrclibRateLimitException({this.retryAfter})
    : super('LRCLIB rate limit was reached.');

  final Duration? retryAfter;
}

class LrclibFormatException extends LrclibException {
  const LrclibFormatException(super.message);
}
