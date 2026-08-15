class InnerTubeException implements Exception {
  const InnerTubeException(this.message);

  final String message;

  @override
  String toString() => 'InnerTubeException: $message';
}

class InnerTubeHttpException extends InnerTubeException {
  InnerTubeHttpException(this.statusCode, String body)
    : body = body.trim(),
      super('YouTube Music request failed with HTTP $statusCode.');

  final int statusCode;
  final String body;
}

class InnerTubeTimeoutException extends InnerTubeException {
  const InnerTubeTimeoutException() : super('YouTube Music request timed out.');
}

class InnerTubeFormatException extends InnerTubeException {
  const InnerTubeFormatException(super.message);
}

class InnerTubeTransportException extends InnerTubeException {
  InnerTubeTransportException(this.cause)
    : super('YouTube Music request could not be completed.');

  final Object cause;
}
