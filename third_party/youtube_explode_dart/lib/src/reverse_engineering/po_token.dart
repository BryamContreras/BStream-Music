import '../videos/video_id.dart';
import '../videos/youtube_api_client.dart';

/// PO tokens and visitor data associated with one InnerTube player request.
///
/// The two tokens have different bindings: [playerRequestPoToken] belongs in
/// the player request, while [streamingDataPoToken] belongs in media URLs.
class YoutubePoTokenContext {
  const YoutubePoTokenContext({
    this.visitorData,
    this.playerRequestPoToken,
    this.streamingDataPoToken,
    this.expiresAt,
  });

  final String? visitorData;
  final String? playerRequestPoToken;
  final String? streamingDataPoToken;
  final DateTime? expiresAt;

  bool get isExpired =>
      expiresAt != null && !expiresAt!.isAfter(DateTime.now());
}

/// Supplies platform-specific PO tokens for an InnerTube client.
///
/// Providers should return null when the selected client does not need a token
/// or when the platform cannot generate the token. The caller must then keep
/// its normal client/fallback chain alive.
abstract interface class YoutubePoTokenProvider {
  Future<YoutubePoTokenContext?> getToken(
    VideoId videoId,
    YoutubeApiClient client,
  );

  void dispose() {}
}
