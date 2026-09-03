/// A validated YouTube video identifier.
///
/// This is an original BStream implementation. It deliberately accepts only
/// known YouTube URL shapes so that arbitrary URLs cannot be mistaken for
/// playable videos.
final class InnerTubeVideoId {
  InnerTubeVideoId._(this.value);

  static final RegExp _validValue = RegExp(r'^[A-Za-z0-9_-]{11}$');

  static const Set<String> _youtubeHosts = <String>{
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'music.youtube.com',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  };

  static const Set<String> _shortHosts = <String>{'youtu.be', 'www.youtu.be'};

  final String value;

  factory InnerTubeVideoId(String value) => parse(value);

  static InnerTubeVideoId parse(String value) {
    final normalized = value.trim();
    if (!_validValue.hasMatch(normalized)) {
      throw FormatException('Invalid YouTube video ID: $value');
    }
    return InnerTubeVideoId._(normalized);
  }

  static InnerTubeVideoId? tryParse(String? value) {
    if (value == null) {
      return null;
    }
    final normalized = value.trim();
    return _validValue.hasMatch(normalized)
        ? InnerTubeVideoId._(normalized)
        : null;
  }

  /// Extracts an ID from a bare value or a canonical YouTube URL.
  ///
  /// Supported routes include watch, shorts, live, embed, v, youtu.be and
  /// attribution links. Unknown hosts and lookalike domains are rejected.
  static InnerTubeVideoId? extract(String input) {
    return _extract(input.trim(), remainingNestedLinks: 1);
  }

  static InnerTubeVideoId? _extract(
    String input, {
    required int remainingNestedLinks,
  }) {
    final direct = tryParse(input);
    if (direct != null) {
      return direct;
    }
    if (input.isEmpty) {
      return null;
    }

    var candidate = input;
    if (!candidate.contains('://') &&
        (_startsWithKnownHost(candidate, _youtubeHosts) ||
            _startsWithKnownHost(candidate, _shortHosts))) {
      candidate = 'https://$candidate';
    }

    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }

    final host = uri.host.toLowerCase();
    if (_shortHosts.contains(host)) {
      return uri.pathSegments.isEmpty ? null : tryParse(uri.pathSegments.first);
    }
    if (!_youtubeHosts.contains(host)) {
      return null;
    }

    final queryId = tryParse(uri.queryParameters['v']);
    if (queryId != null) {
      return queryId;
    }

    if (uri.pathSegments.length >= 2) {
      final route = uri.pathSegments.first.toLowerCase();
      if (route == 'shorts' ||
          route == 'live' ||
          route == 'embed' ||
          route == 'v') {
        return tryParse(uri.pathSegments[1]);
      }
    }

    if (remainingNestedLinks > 0 &&
        uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first.toLowerCase() == 'attribution_link') {
      final nestedPath = uri.queryParameters['u'];
      if (nestedPath != null && nestedPath.startsWith('/')) {
        return _extract(
          uri.resolve(nestedPath).toString(),
          remainingNestedLinks: remainingNestedLinks - 1,
        );
      }
    }
    return null;
  }

  static bool _startsWithKnownHost(String value, Set<String> hosts) {
    final lower = value.toLowerCase();
    return hosts.any((host) => lower == host || lower.startsWith('$host/'));
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InnerTubeVideoId && other.value == value;
  }

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
