import '../../features/music/domain/entities/track_info.dart';
import '../audio_sources/audio_source_policy.dart';

/// A catalog candidate is never substituted for the application's own metadata.
/// These fields are only used to establish which encoded recording to request.
class JioSaavnSong {
  const JioSaavnSong({
    required this.id,
    required this.title,
    required this.artists,
    required this.duration,
    required this.supports320,
    required this.explicit,
    this.album,
    this.encryptedMediaUrl,
  });

  final String id;
  final String title;
  final List<String> artists;
  final Duration duration;
  final bool supports320;
  final bool explicit;
  final String? album;
  final String? encryptedMediaUrl;

  static JioSaavnSong? fromJson(Object? value) {
    if (value is! Map) return null;
    final info = value['more_info'];
    if (info is! Map) return null;
    final id = _text(value['id']);
    final title = _text(value['title']);
    final seconds = int.tryParse('${info['duration']}');
    if (id == null ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) ||
        title == null ||
        title.length > 1024 ||
        seconds == null ||
        seconds <= 0 ||
        seconds > 24 * 60 * 60) {
      return null;
    }
    final artists = <String>[];
    final artistMap = info['artistMap'] ?? info['artist_map'];
    if (artistMap is Map) {
      final primary = artistMap['primary_artists'];
      if (primary is List) {
        for (final artist in primary.take(20)) {
          final name = artist is Map ? _text(artist['name']) : null;
          if (name != null) artists.add(decodeJioSaavnText(name));
        }
      }
    }
    if (artists.isEmpty) {
      final primary = _text(info['primary_artists']);
      if (primary != null) artists.addAll(primary.split(','));
    }
    if (artists.isEmpty) return null;
    return JioSaavnSong(
      id: id,
      title: decodeJioSaavnText(title),
      artists: List.unmodifiable(artists),
      duration: Duration(seconds: seconds),
      supports320: '${info['320kbps']}'.toLowerCase() == 'true',
      explicit: const {
        '1',
        'true',
      }.contains('${value['explicit_content']}'.toLowerCase()),
      album: switch (_text(info['album'])) {
        final album? => decodeJioSaavnText(album),
        _ => null,
      },
      encryptedMediaUrl: _text(info['encrypted_media_url']),
    );
  }
}

/// Conservative identity checks for an optional mid-song source upgrade.
/// A missed match keeps the known recording playing instead of guessing.
class JioSaavnRecordingMatcher {
  const JioSaavnRecordingMatcher();

  List<String> searchQueries(TrackInfo track) {
    final title = _recordingTitle(track.title, track.artist).searchable;
    final artist = _artistNames(track).firstOrNull;
    if (title.isEmpty || artist == null || artist.isEmpty) return const [];
    return {'$title $artist', title}.take(2).toList(growable: false);
  }

  List<JioSaavnSong> rankedMatches(
    TrackInfo track,
    Iterable<JioSaavnSong> candidates, {
    bool allowMissingDuration = false,
  }) {
    final duration = track.duration;
    final wanted = _recordingTitle(track.title, track.artist);
    final artists = _artistNames(track);
    if (duration == null ||
        duration <= Duration.zero ||
        wanted.core.isEmpty ||
        artists.isEmpty) {
      return const [];
    }
    final ranked = <({JioSaavnSong song, int score})>[];
    for (final song in candidates) {
      final candidate = _recordingTitle(song.title, song.artists.join(', '));
      if (candidate.core != wanted.core ||
          candidate.version != wanted.version ||
          (wanted.version.contains('explicit') && !song.explicit) ||
          (wanted.version.contains('clean') && song.explicit)) {
        continue;
      }
      // Catalog runtimes have whole-second precision. Larger differences can
      // be video intros, a different edit or silence that shifts the timeline.
      final difference = song.duration == Duration.zero
          ? null
          : (duration - song.duration).abs();
      if (difference == null
          ? !allowMissingDuration
          : difference > audioUpgradeDurationTolerance) {
        continue;
      }
      final shared = song.artists
          .map(_identity)
          .where((name) => artists.contains(name));
      if (shared.isEmpty) continue;
      final candidateAlbum = _recordingTitle(song.album ?? '', '').version;
      if (candidateAlbum.isNotEmpty && candidateAlbum != wanted.version) {
        continue;
      }
      final albumMatch =
          track.album?.trim().isNotEmpty == true &&
          _identity(track.album!) == _identity(song.album ?? '');
      ranked.add((
        song: song,
        score:
            10000 -
            (difference?.inMilliseconds ??
                audioUpgradeDurationTolerance.inMilliseconds + 1000) +
            (albumMatch ? 500 : 0) +
            (artists.first == _identity(song.artists.first) ? 250 : 0),
      ));
    }
    var eligible = ranked;
    final requestedAlbum = _identity(track.album ?? '');
    if (requestedAlbum.isNotEmpty) {
      final sameRelease = ranked
          .where((entry) => _identity(entry.song.album ?? '') == requestedAlbum)
          .toList(growable: false);
      if (sameRelease.isNotEmpty) eligible = sameRelease;
    }
    final knownReleases = eligible
        .map((entry) => _identity(entry.song.album ?? ''))
        .where((album) => album.isNotEmpty)
        .toSet();
    // Equal names and close runtimes can still belong to different masters.
    // A known requested release resolves that ambiguity; otherwise decline.
    if (knownReleases.length > 1) return const [];
    if (!wanted.version.contains('clean') &&
        !wanted.version.contains('explicit') &&
        eligible.map((entry) => entry.song.explicit).toSet().length > 1) {
      // The originating catalog did not identify an edition. Never choose
      // clean versus uncensored merely from the provider's result order.
      return const [];
    }
    eligible.sort((left, right) {
      final score = right.score.compareTo(left.score);
      return score == 0 ? left.song.id.compareTo(right.song.id) : score;
    });
    return List.unmodifiable(eligible.map((entry) => entry.song));
  }
}

List<String> _artistNames(TrackInfo track) {
  final names = track.artists.isNotEmpty
      ? track.artists
      : track.artist.split(
          RegExp(r',|;|\s+(?:feat\.?|ft\.?|featuring|&|x)\s+'),
        );
  return names
      .map(_identity)
      .where(
        (name) =>
            name.isNotEmpty &&
            !const {'unknown', 'unknown artist', 'desconocido'}.contains(name),
      )
      .toList(growable: false);
}

class _RecordingTitle {
  const _RecordingTitle(this.core, this.version, this.searchable);

  final String core;
  final String version;
  final String searchable;
}

final _versionWords = RegExp(
  r'\b(remix|live|acoustic|instrumental|karaoke|cover|remaster(?:ed)?|demo|'
  r'sped\s+up|slowed|nightcore|radio\s+edit|extended|clean|explicit|duet|'
  r'piano\s+version|ambient\s+version|techno)\b',
);
final _packagingWords = RegExp(
  r'\b(official\s+(?:music\s+)?(?:audio|video)|music\s+video|lyrics?|'
  r'visualizer|hd|hq|4k|audio\s+oficial|video\s+oficial)\b',
);

_RecordingTitle _recordingTitle(String title, String artist) {
  var text = decodeJioSaavnText(title).toLowerCase();
  final versions = <String>{};
  text = text.replaceAllMapped(RegExp(r'\([^)]*\)|\[[^\]]*\]'), (match) {
    final inner = _identity(
      match.group(0)!.substring(1, match.group(0)!.length - 1),
    );
    if (_versionWords.hasMatch(inner)) {
      versions.add(inner.replaceAll('remastered', 'remaster'));
      return ' ';
    }
    if (_packagingWords.hasMatch(inner) ||
        RegExp(r'^(from|feat|ft|featuring|con|with)\b').hasMatch(inner)) {
      return ' ';
    }
    return ' $inner ';
  });
  final split = text.split(RegExp(r'\s+[-\u2013\u2014]\s+'));
  if (split.length == 2 && _identity(split.first) == _identity(artist)) {
    text = split.last;
  }
  final suffix = RegExp(r'\s+[-\u2013\u2014]\s+(.+)$').firstMatch(text);
  if (suffix != null && _versionWords.hasMatch(_identity(suffix.group(1)!))) {
    versions.add(
      _identity(suffix.group(1)!).replaceAll('remastered', 'remaster'),
    );
    text = text.substring(0, suffix.start);
  }
  text = text.replaceAll(_packagingWords, ' ');
  final normalized = _identity(text);
  for (final marker in _versionWords.allMatches(normalized)) {
    versions.add(marker.group(0)!.replaceAll('remastered', 'remaster'));
  }
  final core = normalized
      .replaceAll(_versionWords, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final ordered = versions.toList()..sort();
  return _RecordingTitle(
    core,
    ordered.join('|'),
    [core, ...ordered].join(' ').trim(),
  );
}

String _identity(String value) {
  var text = decodeJioSaavnText(value).toLowerCase();
  const groups = {
    'a': 'àáâãäåāăą',
    'c': 'çćĉċč',
    'd': 'ďđ',
    'e': 'èéêëēĕėęě',
    'i': 'ìíîïĩīĭįı',
    'n': 'ñńņň',
    'o': 'òóôõöøōŏő',
    'r': 'ŕŗř',
    's': 'śŝşš',
    't': 'ţťŧ',
    'u': 'ùúûüũūŭůűų',
    'y': 'ýÿŷ',
    'z': 'źżž',
  };
  for (final group in groups.entries) {
    for (final letter in group.value.split('')) {
      text = text.replaceAll(letter, group.key);
    }
  }
  return text
      .replaceAll(RegExp(r'[\u0300-\u036f]'), '')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
}

String decodeJioSaavnText(String value) => value.replaceAllMapped(
  RegExp(
    r'&(?:#([0-9]{1,7})|#x([0-9a-fA-F]{1,6})|(amp|quot|apos|lt|gt|nbsp));',
  ),
  (match) {
    final decimal = match.group(1);
    final hex = match.group(2);
    if (decimal != null || hex != null) {
      final number = int.tryParse(
        decimal ?? hex!,
        radix: decimal != null ? 10 : 16,
      );
      if (number != null &&
          number > 0 &&
          number <= 0x10ffff &&
          (number < 0xd800 || number > 0xdfff)) {
        return String.fromCharCode(number);
      }
      return ' ';
    }
    return const {
      'amp': '&',
      'quot': '"',
      'apos': "'",
      'lt': '<',
      'gt': '>',
      'nbsp': ' ',
    }[match.group(3)]!;
  },
);

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
