import 'youtube_music_auth_models.dart';

class YouTubeMusicWebAuthException implements Exception {
  const YouTubeMusicWebAuthException(this.message);

  final String message;

  @override
  String toString() => 'YouTubeMusicWebAuthException($message)';
}

class YouTubeMusicWebCleanupResult {
  const YouTubeMusicWebCleanupResult({
    required this.cookiesCleared,
    required this.webStorageCleared,
    required this.cacheCleared,
  });

  final bool cookiesCleared;
  final bool webStorageCleared;
  final bool cacheCleared;

  bool get completed => cookiesCleared && webStorageCleared && cacheCleared;
}

/// Testable browser boundary used by the standalone login page.
abstract interface class YouTubeMusicWebAuthPort {
  Future<void> prepare();

  Future<YouTubeMusicWebAuthData> waitForAuthenticatedSession({
    int maximumAttempts = 20,
    Duration retryDelay = const Duration(milliseconds: 500),
  });

  Future<void> navigate(Uri uri);

  Future<bool> canGoBack();

  Future<void> goBack();

  Future<YouTubeMusicWebCleanupResult> cleanup();
}
