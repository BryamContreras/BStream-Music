import '../../core/utils/background_work.dart';
import '../../features/music/domain/entities/lyrics_document.dart';
import '../../features/music/domain/entities/lyrics_lookup.dart';
import 'remote_lyrics_parsing.dart';
import 'remote_lyrics_service_base.dart';

/// Better Lyrics' documented cache-first TTML API plus public Kugou fallback.
/// No shared secrets or revalidation/cache-bypass endpoints are used. A TTML
/// cache miss may return 401; the documented Kugou endpoint needs no API key.
/// See https://docs.betterlyrics.org/docs/authentication.
class BetterLyricsService extends RemoteLyricsServiceBase {
  BetterLyricsService({
    required super.userAgent,
    super.transport,
    Uri? apiBaseUri,
    super.requestTimeout,
    super.cacheTtl,
    super.maxCacheEntries,
    super.clock,
  }) : _apiBaseUri = apiBaseUri ?? Uri.parse('https://api.betterlyrics.org');

  final Uri _apiBaseUri;

  @override
  String get provider => 'Better Lyrics';

  @override
  Iterable<Uri> requestUris(LyricsLookup lookup) sync* {
    yield requestUri(lookup);
    final normalized = normalizedRemoteLyricsLookup(lookup);
    if (normalized != lookup) yield requestUri(normalized);
    // The documented Kugou endpoint is public, requires no key and provides
    // line timing when cached TTML is absent. No revalidation/cache bypass.
    yield requestUri(normalized).replace(path: '/kugou/getLyrics');
  }

  @override
  bool canTryAfterFailure(RemoteLyricsHttpException error, Uri next) =>
      error.statusCode == 401 && next.path == '/kugou/getLyrics';

  @override
  Uri requestUri(LyricsLookup lookup) => _apiBaseUri
      .resolve('getLyrics')
      .replace(
        queryParameters: {
          's': lookup.title.trim(),
          'a': lookup.artist.trim(),
          // The cache key includes ALL four documented metadata parameters.
          'al': lookup.album?.trim() ?? '',
          'd': lookup.duration?.inSeconds.toString() ?? '',
        },
      );

  @override
  Future<LyricsDocument?> parseResponse(String body, LyricsLookup lookup) =>
      parseJsonInBackground(body, _BetterLyricsParseJob(lookup).parse);
}

class _BetterLyricsParseJob {
  const _BetterLyricsParseJob(this.lookup);

  final LyricsLookup lookup;

  LyricsDocument? parse(Object? value) {
    final json = lyricsJsonObject(value);
    if (json['instrumental'] == true) return null;
    if (json['score'] case final num score) {
      if (!score.isFinite || score < 0.8) return null;
    }
    final metadata = json['metadata'] is Map
        ? lyricsJsonObject(json['metadata'])
        : const <String, Object?>{};
    final title =
        lyricsString(metadata['title']) ?? lyricsString(json['songName']);
    final artist =
        lyricsString(metadata['artist']) ?? lyricsString(json['artistName']);
    final album =
        lyricsString(metadata['album']) ?? lyricsString(json['albumName']);
    final duration = lyricsClockTime(metadata['duration'] ?? json['duration']);
    final source = json['ttml'] ?? json['lyrics'];
    if (source is! String) {
      throw const FormatException('Better Lyrics response has no TTML string.');
    }
    if (source.trim().isEmpty) return null;
    if (json['provider'] == 'kugou') {
      final text = parseRemoteLyricsLrc(source);
      return buildRemoteLyricsDocument(
        provider: 'Better Lyrics',
        providerId:
            'betterlyrics:kugou:${Uri(queryParameters: {'s': lookup.title, 'a': lookup.artist}).query}',
        lookup: lookup,
        lines: text.lines,
        plainLines: text.plainLines,
        title: title,
        artist: artist,
        album: album,
        duration: duration,
      );
    }
    final text = parseRemoteLyricsTtml(source);
    return buildRemoteLyricsDocument(
      provider: 'Better Lyrics',
      providerId:
          'betterlyrics:${Uri(queryParameters: {'s': title ?? lookup.title, 'a': artist ?? lookup.artist, 'al': album ?? lookup.album ?? '', 'd': (duration ?? lookup.duration)?.inSeconds.toString() ?? ''}).query}',
      lookup: lookup,
      lines: text.lines,
      plainLines: text.plainLines,
      title: title,
      artist: artist,
      album: album,
      duration: duration,
    );
  }
}
