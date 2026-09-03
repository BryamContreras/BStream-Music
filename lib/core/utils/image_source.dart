import 'dart:io';

const deviceAudioArtworkScheme = 'bstream-local-artwork';

/// Creates a lightweight artwork reference for one device audio URI.
///
/// The reference does not contain or extract the embedded image. Android and
/// iOS resolve it only when an artwork widget becomes visible, keeping the
/// local catalog scan independent from the number and size of embedded covers.
String? deviceAudioArtworkSourceForUri(String? audioSource) {
  final normalized = audioSource?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  return Uri(
    scheme: deviceAudioArtworkScheme,
    host: 'audio',
    queryParameters: <String, String>{'uri': normalized},
  ).toString();
}

/// Returns the original device audio URI from an embedded-artwork reference.
String? deviceAudioUriFromArtworkSource(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      uri.scheme != deviceAudioArtworkScheme ||
      uri.host != 'audio') {
    return null;
  }
  final audioUri = uri.queryParameters['uri']?.trim();
  return audioUri == null || audioUri.isEmpty ? null : audioUri;
}

bool isDeviceAudioArtworkSource(String? source) =>
    deviceAudioUriFromArtworkSource(source) != null;

bool isNetworkImageSource(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return false;
  }
  return normalized.startsWith('http://') || normalized.startsWith('https://');
}

/// Returns one stable YouTube thumbnail variant so remote and downloaded
/// artwork use the same framing. YouTube's `maxresdefault`, `hq720`, and
/// signed `thumbnail` URLs can contain visibly different crops of the same
/// video, even when they share the same aspect ratio.
String? canonicalYouTubeThumbnailSource(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  if (!isNetworkImageSource(normalized)) {
    return normalized;
  }

  final uri = Uri.tryParse(normalized);
  final host = uri?.host.toLowerCase();
  if (uri == null || (host != 'i.ytimg.com' && host != 'img.youtube.com')) {
    return normalized;
  }

  final segments = uri.pathSegments;
  if (segments.length < 3 ||
      (segments[0] != 'vi' && segments[0] != 'vi_webp')) {
    return normalized;
  }
  final videoId = segments[1];
  return youtubeThumbnailSourceForVideoId(videoId) ?? normalized;
}

/// Returns fallback variants for YouTube videos whose high-resolution artwork
/// was never generated. Older uploads commonly expose `hqdefault` or `0.jpg`
/// while `hq720`/`maxresdefault` return 404.
List<String> youtubeThumbnailCandidates(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return const [];
  }
  if (!isNetworkImageSource(normalized)) {
    return [normalized];
  }

  final videoId = youtubeVideoIdFromThumbnailSource(normalized);
  if (videoId == null) {
    return [normalized];
  }

  final candidates = <String>[
    youtubeThumbnailSourceForVideoId(videoId)!,
    'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg',
    'https://i.ytimg.com/vi/$videoId/sddefault.jpg',
    'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
    'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
    'https://i.ytimg.com/vi/$videoId/0.jpg',
    'https://i.ytimg.com/vi/$videoId/default.jpg',
    normalized,
  ];
  return candidates.toSet().toList(growable: false);
}

/// Returns display/download candidates ordered from the sharpest known
/// rendition to the original source.
///
/// YouTube Music catalog artwork is commonly returned by Google's image CDN
/// with a small card-sized resize suffix. That size is fine in a search row,
/// but becomes visibly soft when a downloaded track opens in the full player.
/// Request a bounded square rendition while preserving the original URL as a
/// fallback in case a particular CDN resource does not support resizing.
List<String> artworkSourceCandidates(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return const [];
  }
  if (!isNetworkImageSource(normalized)) {
    return [normalized];
  }

  if (youtubeVideoIdFromThumbnailSource(normalized) != null) {
    return youtubeThumbnailCandidates(normalized);
  }

  final highResolution = highResolutionGoogleArtworkSource(normalized);
  if (highResolution == null || highResolution == normalized) {
    return [normalized];
  }
  return [highResolution, normalized];
}

/// Upgrades a Google/YouTube Music image CDN URL to the largest size decoded
/// by the app's artwork widgets. Non-CDN artwork is returned unchanged.
String? highResolutionGoogleArtworkSource(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(normalized);
  if (uri == null || !isNetworkImageSource(normalized)) {
    return normalized;
  }

  final host = uri.host.toLowerCase();
  if (host != 'lh3.googleusercontent.com' &&
      host != 'yt3.googleusercontent.com' &&
      host != 'yt3.ggpht.com') {
    return normalized;
  }

  const rendition = '=w1280-h1280-l90-rj';
  final resizedSuffix = RegExp(r'=(?:w\d+-h\d+|s\d+)(?:-[A-Za-z0-9]+)*$');
  final path = resizedSuffix.hasMatch(uri.path)
      ? uri.path.replaceFirst(resizedSuffix, rendition)
      : '${uri.path}$rendition';
  return uri.replace(path: path).toString();
}

/// Requests a rendition close to the decoded size used by a widget.
///
/// Google image URLs embedded in YouTube Music frequently point at a 120 px
/// card rendition, while other flows upgrade every image to 1280 px. Both are
/// poor defaults for a scrolling list. A few stable buckets keep cache reuse
/// high while avoiding oversized transfers and soft upscaling.
String? sizedGoogleArtworkSource(String? source, int requestedWidth) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty || requestedWidth <= 0) {
    return normalized;
  }
  final uri = Uri.tryParse(normalized);
  if (uri == null || !isNetworkImageSource(normalized)) {
    return normalized;
  }

  final host = uri.host.toLowerCase();
  if (host != 'lh3.googleusercontent.com' &&
      host != 'yt3.googleusercontent.com' &&
      host != 'yt3.ggpht.com') {
    return normalized;
  }

  final target = switch (requestedWidth) {
    <= 128 => 128,
    <= 256 => 256,
    <= 384 => 384,
    <= 640 => 640,
    _ => 1280,
  };
  final resizedSuffix = RegExp(r'=(?:w\d+-h\d+|s\d+)((?:-[A-Za-z0-9]+)*)$');
  final match = resizedSuffix.firstMatch(uri.path);
  final modifiers = match?.group(1);
  final suffix = '=w$target-h$target${modifiers ?? '-l90-rj'}';
  final path = match == null
      ? '${uri.path}$suffix'
      : uri.path.replaceRange(match.start, match.end, suffix);
  return uri.replace(path: path).toString();
}

String? youtubeVideoIdFromThumbnailSource(String? source) {
  final normalized = source?.trim();
  if (normalized == null || !isNetworkImageSource(normalized)) {
    return null;
  }

  final uri = Uri.tryParse(normalized);
  final host = uri?.host.toLowerCase();
  if (uri == null || (host != 'i.ytimg.com' && host != 'img.youtube.com')) {
    return null;
  }

  final segments = uri.pathSegments;
  if (segments.length < 3 ||
      (segments[0] != 'vi' && segments[0] != 'vi_webp')) {
    return null;
  }
  final videoId = segments[1];
  return RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId) ? videoId : null;
}

/// Builds the same thumbnail URL when only the YouTube video id is available.
/// This keeps player metadata and search metadata on one stable artwork source
/// even if the extractor reports a different thumbnail URL later.
String? youtubeThumbnailSourceForVideoId(String? videoId) {
  final normalized = videoId?.trim();
  if (normalized == null ||
      !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(normalized)) {
    return null;
  }
  return 'https://i.ytimg.com/vi/$normalized/hq720.jpg';
}

File? imageFileFromSource(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }

  final uri = Uri.tryParse(normalized);
  if (uri != null && uri.scheme == 'file') {
    return File.fromUri(uri);
  }

  if (isNetworkImageSource(normalized)) {
    return null;
  }

  return File(normalized);
}
