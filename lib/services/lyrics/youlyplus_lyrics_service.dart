import '../../core/utils/background_work.dart';
import '../../features/music/domain/entities/lyric_line.dart';
import '../../features/music/domain/entities/lyrics_document.dart';
import '../../features/music/domain/entities/lyrics_lookup.dart';
import 'remote_lyrics_parsing.dart';
import 'remote_lyrics_service_base.dart';

/// Public YouLy+ / LyricsPlus V2 endpoint. The current player has line timing,
/// not a word model, so word/syllable responses retain their parent line time.
/// API: https://github.com/ibratabian17/LyricsPlus/blob/gelato/docs/endpoints.md
class YouLyPlusLyricsService extends RemoteLyricsServiceBase {
  YouLyPlusLyricsService({
    required super.userAgent,
    super.transport,
    Uri? apiBaseUri,
    super.requestTimeout,
    super.cacheTtl,
    super.maxCacheEntries,
    super.clock,
  }) : _apiBaseUri =
           apiBaseUri ?? Uri.parse('https://lyricsplus.prjktla.my.id');

  final Uri _apiBaseUri;

  @override
  String get provider => 'LyricsPlus';

  @override
  Iterable<Uri> requestUris(LyricsLookup lookup) =>
      remoteLyricsLookupVariants(lookup).map(requestUri);

  @override
  Uri requestUri(LyricsLookup lookup) => _apiBaseUri
      .resolve('v2/lyrics/get')
      .replace(
        queryParameters: {
          'title': lookup.title.trim(),
          'artist': lookup.artist.trim(),
          'album': ?lyricsString(lookup.album),
          if (lookup.duration case final duration?)
            'duration': (duration.inMilliseconds / 1000).toString(),
        },
      );

  @override
  Future<LyricsDocument?> parseResponse(String body, LyricsLookup lookup) =>
      parseJsonInBackground(body, _YouLyPlusParseJob(lookup).parse);
}

class _YouLyPlusParseJob {
  const _YouLyPlusParseJob(this.lookup);

  final LyricsLookup lookup;

  LyricsDocument? parse(Object? value) {
    final json = lyricsJsonObject(value);
    if (json['instrumental'] == true) return null;
    final rawLines = json['lyrics'];
    if (rawLines is! List && rawLines is! String) {
      throw const FormatException('YouLyPlus response has no lyrics list.');
    }
    if (rawLines is List && rawLines.length > maximumLyricLines) {
      throw const FormatException('Too many lyric lines.');
    }
    final metadata = json['metadata'] is Map
        ? lyricsJsonObject(json['metadata'])
        : const <String, Object?>{};
    final processing = json['processingTime'] is Map
        ? lyricsJsonObject(json['processingTime'])
        : const <String, Object?>{};
    final selected = processing['selectedSongMetadata'] is Map
        ? lyricsJsonObject(processing['selectedSongMetadata'])
        : const <String, Object?>{};
    final title =
        lyricsString(selected['title']) ?? lyricsString(metadata['title']);
    final artist =
        lyricsString(selected['artist']) ?? lyricsString(metadata['artist']);
    final album =
        lyricsString(selected['album']) ?? lyricsString(metadata['album']);
    final duration =
        _milliseconds(selected['durationMs']) ??
        lyricsClockTime(selected['duration']) ??
        lyricsClockTime(metadata['totalDuration']);
    final type = lyricsString(json['type'])?.toLowerCase();
    final synchronized = type == 'word' || type == 'line' || type == 'syllable';
    final lines = <LyricLine>[];
    final plain = <String>[];
    final rows = rawLines is String
        ? [
            <String, Object?>{'text': rawLines},
          ]
        : rawLines as List;
    for (final rawLine in rows) {
      final line = rawLine is String
          ? <String, Object?>{'text': rawLine}
          : lyricsJsonObject(rawLine);
      final text = _lineText(line);
      if (text.isEmpty) continue;
      if (RegExp(r'<(?:\w+:)?tt(?:\s|>)').hasMatch(text)) {
        final embedded = parseRemoteLyricsTtml(text);
        lines.addAll(embedded.lines);
        plain.addAll(embedded.plainLines);
        continue;
      }
      // Some mirrors wrap valid LRC in a None response. Do not discard real
      // timestamps, but never invent them from the usual all-zero None rows.
      final embedded = parseRemoteLyricsLrc(text);
      if (embedded.lines.isNotEmpty) {
        lines.addAll(embedded.lines);
        plain.addAll(embedded.plainLines);
        continue;
      }
      plain.add(text);
      if (!synchronized) continue;
      final timestamp = _milliseconds(line['time']) ?? _firstSyllableTime(line);
      if (timestamp == null) {
        // Missing times are a partial/plain payload, not an instrumental hit.
        if (line['time'] == null) continue;
        throw const FormatException('YouLyPlus line has invalid timing.');
      }
      lines.add(LyricLine(timestamp: timestamp, text: text));
    }
    final identity = Uri(
      queryParameters: {
        'title': title ?? lookup.title,
        'artist': artist ?? lookup.artist,
        'album': ?(album ?? lookup.album),
        'duration': ?(duration ?? lookup.duration)?.inMilliseconds.toString(),
      },
    ).query;
    return buildRemoteLyricsDocument(
      provider: 'LyricsPlus',
      providerId: 'youlyplus:$identity',
      lookup: lookup,
      lines: lines,
      plainLines: plain,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    );
  }

  String _lineText(Map<String, Object?> line) {
    final text = lyricsString(line['text']);
    if (text != null) return text;
    if (line['syllabus'] case final List syllables) {
      if (syllables.length > maximumLyricLines) {
        throw const FormatException('Too many lyric syllables.');
      }
      return syllables
          .map((raw) {
            final syllable = lyricsJsonObject(raw);
            final text = syllable['text'];
            return text is String ? text : '';
          })
          .join()
          .trim();
    }
    return '';
  }

  Duration? _firstSyllableTime(Map<String, Object?> line) {
    if (line['syllabus'] case final List syllables) {
      Duration? first;
      for (final raw in syllables) {
        final time = _milliseconds(lyricsJsonObject(raw)['time']);
        if (time != null && (first == null || time < first)) first = time;
      }
      return first;
    }
    return null;
  }

  Duration? _milliseconds(Object? value) {
    final time = value is num ? value : double.tryParse('$value');
    if (time == null || !time.isFinite || time < 0 || time > 21600000) {
      return null;
    }
    return Duration(microseconds: (time * 1000).round());
  }
}
