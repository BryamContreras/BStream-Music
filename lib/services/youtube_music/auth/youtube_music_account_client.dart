import 'youtube_music_auth_models.dart';

enum YouTubeMusicAccountFailureKind {
  unauthenticated,
  transient,
  invalidResponse,
  unavailable,
}

/// Sanitized account API error. The underlying response/body is never kept.
class YouTubeMusicAccountException implements Exception {
  const YouTubeMusicAccountException(this.kind, this.message);

  final YouTubeMusicAccountFailureKind kind;
  final String message;

  @override
  String toString() => 'YouTubeMusicAccountException($kind, $message)';
}

/// Port implemented by the authenticated InnerTube account service.
abstract interface class YouTubeMusicAccountClient {
  Future<YouTubeMusicAccountProfile> validateAccount(
    YouTubeMusicWebAuthData authData,
  );

  Future<List<YouTubeMusicAccountChannel>> listChannels(
    YouTubeMusicWebAuthData authData,
  );
}

/// Safe default until the authenticated InnerTube gateway is connected.
class UnconfiguredYouTubeMusicAccountClient
    implements YouTubeMusicAccountClient {
  const UnconfiguredYouTubeMusicAccountClient();

  Never _unavailable() => throw const YouTubeMusicAccountException(
    YouTubeMusicAccountFailureKind.unavailable,
    'La validación de cuenta de YouTube Music aún no está configurada.',
  );

  @override
  Future<List<YouTubeMusicAccountChannel>> listChannels(
    YouTubeMusicWebAuthData authData,
  ) async => _unavailable();

  @override
  Future<YouTubeMusicAccountProfile> validateAccount(
    YouTubeMusicWebAuthData authData,
  ) async => _unavailable();
}
