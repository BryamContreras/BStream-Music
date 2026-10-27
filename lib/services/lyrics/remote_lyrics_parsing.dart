import 'package:xml/xml.dart';

import '../../features/music/data/parsers/lrc_parser.dart';
import '../../features/music/domain/entities/lyric_line.dart';
import '../../features/music/domain/entities/lyrics_document.dart';
import '../../features/music/domain/entities/lyrics_lookup.dart';

const maximumLyricLines = 8000;

class RemoteLyricsText {
  const RemoteLyricsText({required this.lines, required this.plainLines});

  final List<LyricLine> lines;
  final List<String> plainLines;
}

RemoteLyricsText parseRemoteLyricsLrc(String source) {
  final lines = const LrcParser().parse(source);
  final plain = <String>[];
  for (final row in source.split('\n')) {
    if (RegExp(
      r'^\s*\[(?:ar|ti|al|by|offset|length|re|ve):',
      caseSensitive: false,
    ).hasMatch(row)) {
      continue;
    }
    final text = row
        .replaceFirst(RegExp(r'^\s*(?:\[\d[^\]]*\]\s*)+'), '')
        .trim();
    if (text.isNotEmpty) plain.add(text);
  }
  return RemoteLyricsText(lines: lines, plainLines: plain);
}

/// Shared TTML reduction, invoked inside each adapter's background parse job.
RemoteLyricsText parseRemoteLyricsTtml(String source) {
  if (RegExp(
    r'<!\s*(?:DOCTYPE|ENTITY)',
    caseSensitive: false,
  ).hasMatch(source)) {
    throw const FormatException('Lyrics TTML declarations are not supported.');
  }
  final document = XmlDocument.parse(source);
  if (document.rootElement.name.local != 'tt') {
    throw const FormatException('Expected a TTML document.');
  }
  bool isCompanion(XmlElement element) => element.attributes.any(
    (attribute) =>
        attribute.name.local == 'role' &&
        const {'x-translation', 'x-transliteration'}.contains(attribute.value),
  );
  String lyricText(XmlNode node) {
    if (node is XmlText || node is XmlCDATA) return node.value ?? '';
    if (node is! XmlElement) return '';
    if (isCompanion(node) || node.name.local == 'rt') return '';
    if (node.name.local == 'br') return '\n';
    return node.children.map(lyricText).join();
  }

  final lines = <LyricLine>[];
  final plain = <String>[];
  for (final body in document.rootElement.childElements.where(
    (element) => element.name.local == 'body',
  )) {
    for (final paragraph in body.descendantElements.where(
      (element) => element.name.local == 'p',
    )) {
      if (paragraph.ancestors.whereType<XmlElement>().any(isCompanion)) {
        continue;
      }
      if (plain.length >= maximumLyricLines) {
        throw const FormatException('Too many lyric lines.');
      }
      final text = lyricText(paragraph).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      plain.add(text);
      final begin = paragraph.getAttribute('begin');
      Duration? time = lyricsClockTime(begin);
      if (begin != null && time == null) {
        throw const FormatException('TTML line has invalid timing.');
      }
      if (time == null) {
        for (final span in paragraph.descendantElements) {
          if (isCompanion(span) ||
              span.ancestors.whereType<XmlElement>().any(isCompanion)) {
            continue;
          }
          final candidate = lyricsClockTime(span.getAttribute('begin'));
          if (candidate != null && (time == null || candidate < time)) {
            time = candidate;
          }
        }
      }
      if (time != null) lines.add(LyricLine(timestamp: time, text: text));
    }
  }
  return RemoteLyricsText(lines: lines, plainLines: plain);
}

/// Search adaptations are deliberately conservative: presentation labels may
/// disappear, recording qualifiers (live/remix/cover/etc.) may not.
LyricsLookup normalizedRemoteLyricsLookup(LyricsLookup lookup) {
  final artist = lookup.artist
      .replaceFirst(RegExp(r'\s*-\s*topic$', caseSensitive: false), '')
      .replaceFirst(RegExp(r'VEVO$', caseSensitive: false), '')
      .replaceFirst(
        RegExp(r'\s+(?:feat\.?|ft\.?|featuring)\s+.+$', caseSensitive: false),
        '',
      )
      .trim();
  return LyricsLookup(
    title: _canonicalTitle(lookup.title, artist),
    artist: artist.isEmpty ? lookup.artist : artist,
    album: lookup.album,
    duration: lookup.duration,
    sourceId: lookup.sourceId,
  );
}

Iterable<LyricsLookup> remoteLyricsLookupVariants(LyricsLookup lookup) sync* {
  final seen = <LyricsLookup>{lookup};
  yield lookup;
  final normalized = normalizedRemoteLyricsLookup(lookup);
  if (seen.add(normalized)) yield normalized;
  if (lyricsString(normalized.album) != null) {
    final withoutAlbum = LyricsLookup(
      title: normalized.title,
      artist: normalized.artist,
      duration: normalized.duration,
      sourceId: normalized.sourceId,
    );
    if (seen.add(withoutAlbum)) yield withoutAlbum;
  }
}

String _canonicalTitle(String value, String artist) {
  var title = value.trim();
  final presentation = RegExp(
    r'^(?:(?:official|oficial|music|video|vídeo|audio|lyrics?|letras?|'
    r'visuali[sz]er|hd|hq|4k|8k|1080p|720p)\s*)+$',
    caseSensitive: false,
  );
  title = title.replaceAllMapped(RegExp(r'\(([^()]*)\)|\[([^\[\]]*)\]'), (
    match,
  ) {
    final content = (match[1] ?? match[2]!).trim();
    final feature = RegExp(
      r'^(?:feat\.?|ft\.?|featuring)\s+\S',
      caseSensitive: false,
    ).hasMatch(content);
    return presentation.hasMatch(content) ||
            (feature && !_recordingQualifier.hasMatch(content))
        ? ' '
        : match[0]!;
  });
  final separated = title.split(RegExp(r'\s+[-–—]\s+|\s*[|/]\s*'));
  if (separated.length > 1) {
    var modified = false;
    if (presentation.hasMatch(separated.last.trim())) {
      separated.removeLast();
      modified = true;
    }
    if (separated.length > 1 &&
        _identityText(separated.first) == _identityText(artist)) {
      separated.removeAt(0);
      modified = true;
    } else if (separated.length > 1 &&
        _identityText(separated.last) == _identityText(artist)) {
      separated.removeLast();
      modified = true;
    }
    if (modified) title = separated.join(' - ');
  }
  final featureSuffix = RegExp(
    r'\s+(?:feat\.?|ft\.?|featuring)\s+.+$',
    caseSensitive: false,
  ).firstMatch(title);
  if (featureSuffix != null &&
      !_recordingQualifier.hasMatch(featureSuffix[0]!)) {
    title = title.substring(0, featureSuffix.start);
  }
  title = title.replaceFirst(
    RegExp(
      r'\s+(?:official|oficial)\s+(?:music\s+)?(?:video|vídeo|audio|lyrics?)\s*$',
      caseSensitive: false,
    ),
    '',
  );
  final cleaned = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  return cleaned.isEmpty ? value.trim() : cleaned;
}

final _recordingQualifier = RegExp(
  r'\b(?:live|remix|acoustic|remaster(?:ed)?|cover|instrumental|karaoke|'
  r'extended|edit|sped|slowed|mono|stereo)\b',
  caseSensitive: false,
);

Map<String, Object?> lyricsJsonObject(Object? value) {
  if (value is! Map) throw const FormatException('Expected a lyrics object.');
  return Map<String, Object?>.from(value);
}

String? lyricsString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// Parses clock times used by TTML and LyricsPlus metadata. Numeric values
/// are seconds; line/word milliseconds are handled separately by that adapter.
Duration? lyricsClockTime(Object? raw) {
  if (raw is num) {
    if (!raw.isFinite || raw < 0 || raw > 6 * 60 * 60) return null;
    return Duration(microseconds: (raw * 1000000).round());
  }
  if (raw is! String || raw.trim().isEmpty) return null;
  final text = raw.trim();
  final unit = RegExp(r'^(\d+(?:\.\d+)?)(ms|s|m|h)$').firstMatch(text);
  if (unit != null) {
    final scale = switch (unit[2]) {
      'ms' => 0.001,
      'm' => 60,
      'h' => 3600,
      _ => 1,
    };
    return lyricsClockTime(double.parse(unit[1]!) * scale);
  }
  final parts = text.split(':');
  if (parts.length > 3) return null;
  var seconds = 0.0;
  for (var i = 0; i < parts.length; i++) {
    final value = double.tryParse(parts[i]);
    if (value == null || !value.isFinite || value < 0) return null;
    if (i > 0 && value >= 60) return null;
    seconds = seconds * 60 + value;
  }
  return lyricsClockTime(seconds);
}

String _identityText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp('[áàâäãå]'), 'a')
    .replaceAll(RegExp('[éèêë]'), 'e')
    .replaceAll(RegExp('[íìîï]'), 'i')
    .replaceAll(RegExp('[óòôöõ]'), 'o')
    .replaceAll(RegExp('[úùûü]'), 'u')
    .replaceAll(RegExp(r'\p{M}+', unicode: true), '')
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r'\b(?:feat\.?|ft\.?|featuring)\b'), ' ')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// Reject conflicting upstream metadata, including live/remix versions. An
/// absent field is not fabricated: exact endpoints sometimes omit identity.
bool lyricsMetadataMatches(
  LyricsLookup lookup, {
  String? title,
  String? artist,
  Duration? duration,
}) {
  final normalized = normalizedRemoteLyricsLookup(lookup);
  if (title != null &&
      _identityText(_canonicalTitle(title, normalized.artist)) !=
          _identityText(normalized.title)) {
    return false;
  }
  if (artist != null && lookup.artist.trim().isNotEmpty) {
    final actual = _identityText(artist).split(' ').toSet();
    final expected = _identityText(normalized.artist).split(' ').toSet();
    // "Chino & Nacho" / "Chino, Nacho" describe the same performers.
    actual.remove('and');
    expected.remove('and');
    final primarySeparator = RegExp(
      r',|&|;|\b(?:feat\.?|ft\.?|featuring)\b',
      caseSensitive: false,
    );
    final samePrimary =
        _identityText(artist.split(primarySeparator).first) ==
        _identityText(normalized.artist.split(primarySeparator).first);
    final samePerformers =
        actual.length == expected.length && actual.containsAll(expected);
    if (!samePerformers && !samePrimary) {
      return false;
    }
  }
  final expectedDuration = lookup.duration;
  if (duration != null && expectedDuration != null) {
    if ((duration - expectedDuration).inMilliseconds.abs() > 8000) return false;
  }
  return true;
}

LyricsDocument? buildRemoteLyricsDocument({
  required String provider,
  required String providerId,
  required LyricsLookup lookup,
  required List<LyricLine> lines,
  required List<String> plainLines,
  String? title,
  String? artist,
  String? album,
  Duration? duration,
}) {
  if (!lyricsMetadataMatches(
    lookup,
    title: title,
    artist: artist,
    duration: duration,
  )) {
    return null;
  }
  final cleanedLines =
      lines.where((line) => line.text.trim().isNotEmpty).toList()
        ..sort((left, right) => left.timestamp.compareTo(right.timestamp));
  if (cleanedLines.length > maximumLyricLines ||
      plainLines.length > maximumLyricLines) {
    throw const FormatException('Too many lyric lines.');
  }
  final trackDuration = lookup.duration ?? duration;
  if (trackDuration != null && cleanedLines.isNotEmpty) {
    // Do not silently synchronize a longer live version onto a studio track.
    if (cleanedLines.last.timestamp >
        trackDuration + const Duration(seconds: 8)) {
      return null;
    }
  }
  final plain = plainLines.where((line) => line.trim().isNotEmpty).join('\n');
  if (cleanedLines.isEmpty && plain.trim().isEmpty) return null;
  return LyricsDocument(
    provider: provider,
    providerId: providerId,
    trackName: title ?? lookup.title,
    artistName: artist ?? lookup.artist,
    albumName: album ?? lookup.album,
    duration: duration ?? lookup.duration,
    plainLyrics: plain.trim().isEmpty
        ? cleanedLines.map((line) => line.text).join('\n')
        : plain,
    syncedLyrics: cleanedLines.isEmpty
        ? null
        : cleanedLines
              .map((line) => '${_lrcTime(line.timestamp)}${line.text}')
              .join('\n'),
    lines: List.unmodifiable(cleanedLines),
  );
}

String _lrcTime(Duration time) {
  final minutes = time.inMinutes.toString().padLeft(2, '0');
  final seconds = (time.inSeconds % 60).toString().padLeft(2, '0');
  final millis = (time.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '[$minutes:$seconds.$millis]';
}
