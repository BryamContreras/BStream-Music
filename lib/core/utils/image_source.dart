import 'dart:io';

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
