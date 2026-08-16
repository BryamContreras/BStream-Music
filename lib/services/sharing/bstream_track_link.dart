import '../../features/music/domain/entities/track_info.dart';

/// A stable BStream link backed by a canonical YouTube video identity.
///
/// Stream URLs are deliberately never represented here: Google Video URLs
/// are signed, short lived, and may contain request credentials.
final class BStreamTrackLink {
  const BStreamTrackLink({required this.videoId});

  final String videoId;

  Uri get appUri => Uri(
    scheme: BStreamTrackLinkCodec.scheme,
    host: BStreamTrackLinkCodec.host,
    pathSegments: [videoId],
  );

  Uri get youtubeFallbackUri =>
      Uri.https('www.youtube.com', '/watch', <String, String>{'v': videoId});
}

/// Encodes and validates the public link contract used by BStream Music.
class BStreamTrackLinkCodec {
  const BStreamTrackLinkCodec();

  static const scheme = 'bstreammusic';
  static const host = 'track';
  static final RegExp _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

  BStreamTrackLink decode(Uri uri) {
    final decoded = tryDecode(uri);
    if (decoded == null) {
      throw FormatException('Invalid BStream Music track link.', uri);
    }
    return decoded;
  }

  BStreamTrackLink? tryDecode(Uri uri) {
    if (uri.scheme.toLowerCase() != scheme ||
        uri.host.toLowerCase() != host ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length != 1) {
      return null;
    }
    final videoId = uri.pathSegments.single;
    return _videoIdPattern.hasMatch(videoId)
        ? BStreamTrackLink(videoId: videoId)
        : null;
  }

  BStreamTrackLink fromTrack(TrackInfo track) {
    final link = tryFromTrack(track);
    if (link == null) {
      throw const FormatException(
        'The track does not contain a shareable YouTube identity.',
      );
    }
    return link;
  }

  BStreamTrackLink? tryFromTrack(TrackInfo track) {
    // Prefer the canonical catalog URL. An id is used only when the URL is
    // absent or not a recognized YouTube reference.
    final videoId = extractVideoId(track.url) ?? extractVideoId(track.id);
    return videoId == null ? null : BStreamTrackLink(videoId: videoId);
  }

  String? extractVideoId(String candidate) {
    final normalized = candidate.trim();
    if (_videoIdPattern.hasMatch(normalized)) {
      return normalized;
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        (uri.scheme.toLowerCase() != 'https' &&
            uri.scheme.toLowerCase() != 'http')) {
      return null;
    }

    final normalizedHost = uri.host.toLowerCase();
    if (normalizedHost == 'youtu.be') {
      return _validVideoId(uri.pathSegments.firstOrNull);
    }
    final isYouTubeHost =
        normalizedHost == 'youtube.com' ||
        normalizedHost.endsWith('.youtube.com') ||
        normalizedHost == 'youtube-nocookie.com' ||
        normalizedHost.endsWith('.youtube-nocookie.com');
    if (!isYouTubeHost) {
      return null;
    }

    if (uri.path == '/watch') {
      return _validVideoId(uri.queryParameters['v']);
    }
    if (uri.pathSegments.length == 2 &&
        const {'shorts', 'embed', 'live'}.contains(uri.pathSegments.first)) {
      return _validVideoId(uri.pathSegments[1]);
    }
    return null;
  }

  String? _validVideoId(String? candidate) {
    return candidate != null && _videoIdPattern.hasMatch(candidate)
        ? candidate
        : null;
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
