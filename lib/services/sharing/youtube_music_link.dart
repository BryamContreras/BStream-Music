/// A validated public YouTube/YouTube Music link that BStream can open.
///
/// This parser intentionally accepts only HTTPS links from the canonical
/// YouTube hosts. It never keeps cookies, query parameters unrelated to the
/// catalog identity, or signed playback URLs.
enum YouTubeMusicLinkKind { track, playlist, album, mix }

final class YouTubeMusicLink {
  const YouTubeMusicLink._({
    required this.kind,
    required this.uri,
    this.videoId,
    this.collectionId,
    this.playlistId,
  });

  final YouTubeMusicLinkKind kind;
  final Uri uri;
  final String? videoId;
  final String? collectionId;
  final String? playlistId;

  bool get isTrack => kind == YouTubeMusicLinkKind.track;
  bool get isCollection => !isTrack;

  /// Browse IDs used by the anonymous InnerTube collection endpoints.
  String? get browseId {
    if (collectionId == null) return null;
    if (kind == YouTubeMusicLinkKind.playlist &&
        collectionId!.startsWith('VL')) {
      return collectionId;
    }
    return collectionId;
  }

  @override
  String toString() => 'YouTubeMusicLink($kind, $videoId, $collectionId)';
}

class YouTubeMusicLinkCodec {
  const YouTubeMusicLinkCodec();

  static final RegExp _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final RegExp _identity = RegExp(r'^[A-Za-z0-9_-]{1,200}$');
  static const _hosts = <String>{
    'music.youtube.com',
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtu.be',
  };

  YouTubeMusicLink? tryDecode(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final authority = uri.toString().split('/').elementAtOrNull(2) ?? '';
    if (scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        authority.contains(':') ||
        uri.fragment.isNotEmpty ||
        !_hosts.contains(uri.host.toLowerCase())) {
      return null;
    }

    final host = uri.host.toLowerCase();
    final path = uri.path;
    final queryVideo = _validVideo(uri.queryParameters['v']);
    if (host == 'youtu.be') {
      final video = _validVideo(uri.pathSegments.firstOrNull);
      return video == null
          ? null
          : YouTubeMusicLink._(
              kind: YouTubeMusicLinkKind.track,
              uri: uri,
              videoId: video,
            );
    }

    if (path == '/watch' && queryVideo != null) {
      return YouTubeMusicLink._(
        kind: YouTubeMusicLinkKind.track,
        uri: uri,
        videoId: queryVideo,
      );
    }

    final pathSegments = uri.pathSegments;
    if (pathSegments.length == 2 &&
        const {'shorts', 'embed', 'live'}.contains(pathSegments.first)) {
      final video = _validVideo(pathSegments[1]);
      if (video != null) {
        return YouTubeMusicLink._(
          kind: YouTubeMusicLinkKind.track,
          uri: uri,
          videoId: video,
        );
      }
    }

    final playlist = _validIdentity(uri.queryParameters['list']);
    if ((path == '/playlist' || path == '/playlist/') && playlist != null) {
      return _collection(
        uri,
        playlist,
        playlist.startsWith('RD')
            ? YouTubeMusicLinkKind.mix
            : YouTubeMusicLinkKind.playlist,
      );
    }

    final segments = pathSegments;
    if (segments.length >= 2 && segments.first == 'browse') {
      final browseId = _validIdentity(segments[1]);
      if (browseId == null) return null;
      final kind = browseId.startsWith('MPRE')
          ? YouTubeMusicLinkKind.album
          : browseId.startsWith('RD')
          ? YouTubeMusicLinkKind.mix
          : browseId.startsWith('VL')
          ? YouTubeMusicLinkKind.playlist
          : null;
      if (kind == null) return null;
      return _collection(uri, browseId, kind);
    }

    return null;
  }

  YouTubeMusicLink? _collection(
    Uri uri,
    String identity,
    YouTubeMusicLinkKind kind,
  ) {
    final playlistId =
        kind == YouTubeMusicLinkKind.playlist ||
            kind == YouTubeMusicLinkKind.mix
        ? identity.startsWith('VL')
              ? identity.substring(2)
              : identity
        : null;
    final isPlaylistLike =
        kind == YouTubeMusicLinkKind.playlist ||
        kind == YouTubeMusicLinkKind.mix;
    final collectionId = isPlaylistLike && !identity.startsWith('VL')
        ? 'VL$identity'
        : identity;
    return YouTubeMusicLink._(
      kind: kind,
      uri: uri,
      collectionId: collectionId,
      playlistId: playlistId,
    );
  }

  String? _validVideo(String? value) {
    return value != null && _videoId.hasMatch(value) ? value : null;
  }

  String? _validIdentity(String? value) {
    return value != null && _identity.hasMatch(value) ? value : null;
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
  T? elementAtOrNull(int index) => index < length ? this[index] : null;
}
