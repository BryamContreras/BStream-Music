import 'youtube_music_auth_models.dart';
import 'youtube_music_cookie_codec.dart';
import 'youtube_music_sid_auth_signer.dart';

/// Adds credentials only to the exact YouTube Music web origin.
class YouTubeMusicAuthHeaderFactory {
  YouTubeMusicAuthHeaderFactory({
    YouTubeMusicSidAuthSigner? signer,
    this.cookieCodec = const YouTubeMusicCookieCodec(),
  }) : signer = signer ?? YouTubeMusicSidAuthSigner();

  static final Uri origin = Uri.parse('https://music.youtube.com');

  final YouTubeMusicSidAuthSigner signer;
  final YouTubeMusicCookieCodec cookieCodec;

  Map<String, String> create(
    Uri requestUri,
    YouTubeMusicSessionCredential credential,
  ) {
    if (!_isExactOrigin(requestUri)) return const <String, String>{};
    final canonicalCookie = cookieCodec.canonicalize(credential.cookieHeader);
    final headers = <String, String>{
      'Authorization': signer.sign(canonicalCookie),
      'Cookie': canonicalCookie,
      'Origin': origin.toString(),
      'X-Origin': origin.toString(),
      'X-Goog-AuthUser': credential.identity.authUser,
      'X-Goog-Visitor-Id': credential.identity.visitorData,
      'X-Youtube-Bootstrap-Logged-In': 'true',
    };
    final pageId = credential.identity.delegatedPageId?.trim();
    if (pageId != null && pageId.isNotEmpty) {
      headers['X-Goog-PageId'] = pageId;
    }
    return Map<String, String>.unmodifiable(headers);
  }

  bool _isExactOrigin(Uri uri) =>
      uri.scheme.toLowerCase() == origin.scheme &&
      uri.host.toLowerCase() == origin.host &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);
}
