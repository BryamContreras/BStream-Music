import '../jiosaavn/jiosaavn_recording_matcher.dart';
import 'audio_extension.dart';

/// URL and catalog mappings for the public Monochrome direct-audio index.
abstract final class MonochromeAudioSource {
  static const resultLimit = 20;
  static final _numericTrackId = RegExp(r'^[0-9]{1,32}$');

  static Uri searchUri(Uri base, String query) => base.replace(
    pathSegments: [
      ...base.pathSegments.where((part) => part.isNotEmpty),
      'search',
      'tracks',
    ],
    queryParameters: {
      ...base.queryParametersAll,
      'q': query,
      'limit': '$resultLimit',
    },
  );

  static Uri streamUri(Uri base, String id) {
    if (!_numericTrackId.hasMatch(id)) {
      throw ArgumentError('Expected a numeric Monochrome track id.');
    }
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((part) => part.isNotEmpty),
        'track',
        id,
      ],
    );
  }

  static Iterable<JioSaavnSong> parseSearch(Object? response) sync* {
    if (response is! Map) return;
    final data = response['data'];
    final rows = response['tracks'] ?? (data is Map ? data['tracks'] : null);
    if (rows is! List) return;
    for (final row in rows.take(resultLimit)) {
      final track = _parseTrack(row);
      if (track != null) yield track;
    }
  }

  static JioSaavnSong? _parseTrack(Object? value) {
    if (value is! Map || value['playable'] == false) return null;
    final id = _trackId(value['trackId']) ?? _trackId(value['id']);
    final title = audioExtensionText(value['title']);
    final duration = int.tryParse('${value['duration']}');
    if (id == null ||
        title == null ||
        duration == null ||
        duration <= 0 ||
        duration > Duration.millisecondsPerDay) {
      return null;
    }
    final artists = _artists(
      value['artistNames'] ?? value['artists'] ?? value['artist'],
    );
    if (artists.isEmpty) return null;
    final release = value['album'] ?? value['release'];
    return JioSaavnSong(
      id: id,
      title: title,
      artists: artists,
      duration: Duration(milliseconds: duration),
      supports320: false,
      explicit: value['explicit'] == true,
      album:
          audioExtensionText(
            release is Map ? release['title'] ?? release['name'] : release,
          ) ??
          audioExtensionText(value['albumTitle'] ?? value['releaseTitle']),
    );
  }

  static String? _trackId(Object? value) {
    final id = value is int ? value.toString() : audioExtensionText(value);
    return id != null && _numericTrackId.hasMatch(id) ? id : null;
  }

  static List<String> _artists(Object? value) {
    final names = value is List ? value.take(20) : [value];
    return List.unmodifiable([
      for (final artist in names)
        if (audioExtensionText(artist is Map ? artist['name'] : artist)
            case final String name)
          name,
    ]);
  }
}
