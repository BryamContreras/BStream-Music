import 'dart:ui';

import 'track_share_service.dart';
import 'youtube_music_link.dart';

abstract interface class YouTubeMusicPlaylistShareService {
  bool canShare({
    required String remotePlaylistId,
    required String playlistName,
  });

  Future<void> sharePlaylist({
    required String remotePlaylistId,
    required String playlistName,
    required String message,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  });
}

/// Shares the canonical public YouTube Music URL for a synchronized playlist.
///
/// The remote identifier is account data, but it is not a credential. Cookies,
/// visitor data and other session fields never participate in the generated
/// link.
class SharePlusYouTubeMusicPlaylistShareService
    implements YouTubeMusicPlaylistShareService {
  const SharePlusYouTubeMusicPlaylistShareService({
    this.gateway = const SharePlusTrackShareGateway(),
  });

  final TrackShareGateway gateway;

  @override
  bool canShare({
    required String remotePlaylistId,
    required String playlistName,
  }) {
    return canonicalYouTubeMusicPlaylistId(remotePlaylistId) != null &&
        playlistName.trim().isNotEmpty;
  }

  @override
  Future<void> sharePlaylist({
    required String remotePlaylistId,
    required String playlistName,
    required String message,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) {
    final canonicalId = canonicalYouTubeMusicPlaylistId(remotePlaylistId);
    final normalizedName = playlistName.trim();
    if (canonicalId == null || normalizedName.isEmpty) {
      throw const FormatException(
        'The playlist does not contain a shareable YouTube Music identity.',
      );
    }

    final shareUri = Uri.https(
      'music.youtube.com',
      '/playlist',
      <String, String>{'list': canonicalId},
    );
    final resolvedMessage = _includePlaylistName(
      message,
      normalizedName,
      separator: '\n',
    );
    final resolvedTitle = _includePlaylistName(
      title,
      normalizedName,
      separator: ': ',
    );

    return gateway.share(
      text: '$resolvedMessage\n\n$shareUri',
      title: resolvedTitle,
      subject: subject,
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  String _includePlaylistName(
    String value,
    String playlistName, {
    required String separator,
  }) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      return playlistName;
    }
    if (normalized.toLowerCase().contains(playlistName.toLowerCase())) {
      return normalized;
    }
    return '$normalized$separator$playlistName';
  }
}
