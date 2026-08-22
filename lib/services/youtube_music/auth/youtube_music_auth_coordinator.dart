import 'youtube_music_account_client.dart';
import 'youtube_music_auth_models.dart';
import 'youtube_music_cookie_codec.dart';
import 'youtube_music_navigation_policy.dart';
import 'youtube_music_session_store.dart';

typedef YouTubeMusicUtcClock = DateTime Function();

/// Coordinates validation and persistence without exposing secrets to widgets.
class YouTubeMusicAuthCoordinator {
  YouTubeMusicAuthCoordinator({
    required YouTubeMusicSessionStore sessionStore,
    required YouTubeMusicAccountClient accountClient,
    YouTubeMusicCookieCodec cookieCodec = const YouTubeMusicCookieCodec(),
    YouTubeMusicNavigationPolicy navigationPolicy =
        const YouTubeMusicNavigationPolicy(),
    YouTubeMusicUtcClock? clock,
  }) : this._(
         sessionStore,
         accountClient,
         cookieCodec,
         navigationPolicy,
         clock ?? DateTime.now,
       );

  YouTubeMusicAuthCoordinator._(
    this._sessionStore,
    this._accountClient,
    this.cookieCodec,
    this.navigationPolicy,
    this._clock,
  );

  final YouTubeMusicSessionStore _sessionStore;
  final YouTubeMusicAccountClient _accountClient;
  final YouTubeMusicCookieCodec cookieCodec;
  final YouTubeMusicNavigationPolicy navigationPolicy;
  final YouTubeMusicUtcClock _clock;

  Future<YouTubeMusicSessionCredential?> restore() => _sessionStore.read();

  YouTubeMusicWebAuthData normalize(YouTubeMusicWebAuthData authData) {
    final canonicalCookie = cookieCodec.canonicalize(authData.cookieHeader);
    // Round-tripping applies all identity size/type checks without retaining
    // any unvalidated map or WebView value.
    final identity = YouTubeMusicAuthIdentity.fromJson(
      authData.identity.toJson(),
    );
    return YouTubeMusicWebAuthData(
      cookieHeader: canonicalCookie,
      identity: identity,
      apiKey: authData.apiKey,
      clientVersion: authData.clientVersion,
      clientName: authData.clientName,
    );
  }

  Future<List<YouTubeMusicAccountChannel>> discoverChannels(
    YouTubeMusicWebAuthData authData,
  ) async {
    final normalized = normalize(authData);
    final channels = await _accountClient.listChannels(normalized);
    return List<YouTubeMusicAccountChannel>.unmodifiable(channels);
  }

  Future<YouTubeMusicSessionCredential> validate(
    YouTubeMusicWebAuthData authData, {
    YouTubeMusicAccountChannel? expectedChannel,
  }) async {
    final normalized = normalize(authData);
    final profile = await _accountClient.validateAccount(normalized);
    if (expectedChannel != null &&
        profile.channelId != expectedChannel.profile.channelId) {
      throw const YouTubeMusicAccountException(
        YouTubeMusicAccountFailureKind.invalidResponse,
        'YouTube Music devolvió un canal distinto al seleccionado.',
      );
    }
    final credential = YouTubeMusicSessionCredential(
      cookieHeader: normalized.cookieHeader,
      identity: normalized.identity,
      profile: profile,
      validatedAt: _clock().toUtc(),
      apiKey: normalized.apiKey,
      clientVersion: normalized.clientVersion,
      clientName: normalized.clientName,
    );
    return credential;
  }

  Future<void> persist(YouTubeMusicSessionCredential credential) =>
      _sessionStore.write(credential);

  Uri validateChannelSignInUrl(Uri uri) {
    if (navigationPolicy.evaluate(uri, isMainFrame: true) !=
        YouTubeMusicNavigationDecision.allow) {
      throw const YouTubeMusicAccountException(
        YouTubeMusicAccountFailureKind.invalidResponse,
        'YouTube Music devolvió un enlace de cambio de canal no permitido.',
      );
    }
    return uri;
  }

  Future<void> logout() => _sessionStore.delete();
}
