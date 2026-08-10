import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../features/music/data/parsers/lrc_parser.dart';
import '../../features/music/domain/entities/lyrics_candidate.dart';
import '../../features/music/domain/entities/lyrics_document.dart';
import '../../features/music/domain/entities/lyrics_lookup.dart';
import 'lrclib_exceptions.dart';
import 'lrclib_models.dart';
import 'lrclib_request_pacing.dart';
import 'lrclib_transport.dart';
import 'lyrics_service.dart';

export 'lrclib_exceptions.dart';

typedef LrclibDelay = Future<void> Function(Duration duration);
typedef LrclibClock = DateTime Function();

class LrclibLyricsService implements LyricsService {
  factory LrclibLyricsService({
    required String userAgent,
    LrclibTransport? transport,
    Uri? apiBaseUri,
    Duration requestTimeout = const Duration(seconds: 6),
    Duration exactRequestTimeout = const Duration(milliseconds: 1500),
    Duration lookupTimeout = const Duration(seconds: 9),
    Duration cacheTtl = const Duration(minutes: 15),
    int maxCacheEntries = 24,
    LrcParser parser = const LrcParser(),
    LrclibDelay? delay,
    LrclibClock? clock,
    LrclibMonotonicClock? monotonicClock,
  }) {
    final normalizedUserAgent = userAgent.trim();
    if (normalizedUserAgent.isEmpty) {
      throw ArgumentError.value(userAgent, 'userAgent', 'Must not be empty.');
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'Must be positive.',
      );
    }
    if (lookupTimeout <= Duration.zero) {
      throw ArgumentError.value(
        lookupTimeout,
        'lookupTimeout',
        'Must be positive.',
      );
    }
    if (exactRequestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        exactRequestTimeout,
        'exactRequestTimeout',
        'Must be positive.',
      );
    }
    if (cacheTtl < Duration.zero) {
      throw ArgumentError.value(cacheTtl, 'cacheTtl', 'Must not be negative.');
    }
    if (maxCacheEntries <= 0) {
      throw ArgumentError.value(
        maxCacheEntries,
        'maxCacheEntries',
        'Must be positive.',
      );
    }

    final monotonicWatch = Stopwatch()..start();
    return LrclibLyricsService._(
      userAgent: normalizedUserAgent,
      transport:
          transport ?? IoLrclibTransport(connectionTimeout: requestTimeout),
      apiBaseUri: apiBaseUri ?? Uri.parse('https://lrclib.net/api'),
      requestTimeout: requestTimeout,
      exactRequestTimeout: exactRequestTimeout,
      lookupTimeout: lookupTimeout,
      cacheTtl: cacheTtl,
      maxCacheEntries: maxCacheEntries,
      parser: parser,
      delay: delay ?? Future<void>.delayed,
      clock: clock ?? DateTime.now,
      monotonicClock: monotonicClock ?? () => monotonicWatch.elapsed,
    );
  }

  LrclibLyricsService._({
    required String userAgent,
    required LrclibTransport transport,
    required Uri apiBaseUri,
    required Duration requestTimeout,
    required Duration exactRequestTimeout,
    required Duration lookupTimeout,
    required Duration cacheTtl,
    required int maxCacheEntries,
    required LrcParser parser,
    required LrclibDelay delay,
    required LrclibClock clock,
    required LrclibMonotonicClock monotonicClock,
  }) : this._initialized(
         userAgent,
         transport,
         apiBaseUri,
         requestTimeout,
         exactRequestTimeout,
         lookupTimeout,
         cacheTtl,
         maxCacheEntries,
         parser,
         delay,
         clock,
         monotonicClock,
       );

  LrclibLyricsService._initialized(
    this._userAgent,
    this._transport,
    this._apiBaseUri,
    this._requestTimeout,
    this._exactRequestTimeout,
    this._lookupTimeout,
    this._cacheTtl,
    this._maxCacheEntries,
    this._parser,
    this._delay,
    this._clock,
    this._monotonicClock,
  );

  static const _minimumCandidateScore = 0.62;
  static const _strongCandidateScore = 0.83;
  static const _maxLookupRequests = 6;
  static const _maxSimilarTitleRequests = 4;
  static const _minimumRequestSpacing = Duration(milliseconds: 250);

  final String _userAgent;
  final LrclibTransport _transport;
  final Uri _apiBaseUri;
  final Duration _requestTimeout;
  final Duration _exactRequestTimeout;
  final Duration _lookupTimeout;
  final Duration _cacheTtl;
  final int _maxCacheEntries;
  final LrcParser _parser;
  final LrclibDelay _delay;
  final LrclibClock _clock;
  final LrclibMonotonicClock _monotonicClock;
  final Map<String, _CacheEntry> _cache = {};

  bool _disposed = false;
  DateTime? _rateLimitedUntil;

  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) {
    _ensureActive();
    if (!lookup.isValid) {
      throw ArgumentError.value(lookup, 'lookup', 'Title must not be empty.');
    }

    final now = _clock();
    _removeExpiredEntries(now);
    final key = _cacheKey(lookup);
    final cached = _cache.remove(key);
    if (cached != null && !cached.isExpired(now, _cacheTtl)) {
      _cache[key] = cached;
      return cached.future;
    }

    final completer = Completer<LyricsDocument?>();
    final entry = _CacheEntry(future: completer.future, createdAt: now);
    _cache[key] = entry;
    _trimCache();

    final request = _findUncached(lookup);
    unawaited(
      request.then<void>(
        (document) {
          entry.completed = true;
          if (_cacheTtl == Duration.zero && identical(_cache[key], entry)) {
            _cache.remove(key);
          }
          completer.complete(document);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_cache[key], entry)) {
            _cache.remove(key);
          }
          completer.completeError(error, stackTrace);
        },
      ),
    );
    return completer.future;
  }

  @override
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  }) async {
    _ensureActive();
    if (!lookup.isValid) {
      throw ArgumentError.value(lookup, 'lookup', 'Title must not be empty.');
    }
    if (limit <= 0) {
      return const [];
    }

    final identities = _searchIdentities(lookup);
    if (identities.isEmpty) {
      return const [];
    }
    final queries = _similarTitleQueries(lookup, identities);
    final records = <LrclibRecord>[];
    var candidates = <LrclibScoredRecord>[];
    final budget = LrclibRequestBudget(_lookupTimeout, _monotonicClock);
    final pacer = LrclibRequestPacer(_minimumRequestSpacing, _monotonicClock);

    Future<List<LrclibRecord>> requestSearch(String query) async {
      final wait = _requestSlotWait(budget, pacer);
      if (wait != null) {
        await wait;
      }
      return _search(
        _endpoint('search', {'q': query}),
        timeout: budget.timeoutFor(_requestTimeout),
      );
    }

    for (var index = 0; index < queries.length; index++) {
      records.addAll(await requestSearch(queries[index]));
      candidates = _scoreSimilarRecords(lookup, identities, records);
      // Similar lyrics are a picker, not an automatic selection. Keep
      // collecting a small useful set instead of stopping after the first
      // strong result.
      final usefulTarget = limit < 3 ? limit : 3;
      if (candidates.length >= limit ||
          (candidates.length >= usefulTarget &&
              candidates.any(
                (candidate) => candidate.score >= _strongCandidateScore,
              ))) {
        break;
      }
    }

    final usefulTarget = limit < 3 ? limit : 3;
    if (candidates.length < usefulTarget) {
      final artist = _reliableContextArtist(lookup);
      if (artist != null && !_containsEquivalentQuery(queries, artist)) {
        final artistRecords = await requestSearch(artist);
        final artistCandidates = _scoreSimilarRecords(
          lookup,
          identities,
          artistRecords,
          allowArtistOnly: true,
        );
        candidates = [...candidates, ...artistCandidates];
      }
    }
    return _toLyricsCandidates(candidates, limit: limit);
  }

  @override
  Future<List<LyricsCandidate>> searchLyricsByTitle(
    String title, {
    required LyricsLookup context,
    int limit = 8,
  }) async {
    _ensureActive();
    if (limit <= 0) {
      return const [];
    }
    final manualTitle = _cleanQueryText(title);
    if (manualTitle.isEmpty) {
      return const [];
    }

    final records = await _search(_endpoint('search', {'q': manualTitle}));
    final candidates = <LrclibScoredRecord>[];
    for (final record in records) {
      final document = record.toDocument(_parser);
      if (!document.hasPlainLyrics && !document.hasSyncedLyrics) {
        continue;
      }
      final score = _manualCandidateScore(manualTitle, context, record);
      if (score != null) {
        candidates.add(LrclibScoredRecord(record: record, score: score));
      }
    }
    return _toLyricsCandidates(candidates, limit: limit);
  }

  Future<LyricsDocument?> _findUncached(LyricsLookup lookup) async {
    final identities = _searchIdentities(lookup);
    if (identities.isEmpty) {
      return null;
    }
    final primaryIdentity = identities.first;
    final requestedUris = <String>{};
    var requestCount = 0;
    LrclibScoredRecord? best;
    final budget = LrclibRequestBudget(_lookupTimeout, _monotonicClock);
    final pacer = LrclibRequestPacer(_minimumRequestSpacing, _monotonicClock);

    Future<LrclibResponse?> requestExact(
      Map<String, String> queryParameters,
    ) async {
      final uri = _endpoint('get', queryParameters);
      if (requestCount >= _maxLookupRequests ||
          !requestedUris.add(uri.toString())) {
        return null;
      }
      final wait = _requestSlotWait(budget, pacer);
      if (wait != null) {
        await wait;
      }
      requestCount++;
      final available = budget.timeoutFor(_requestTimeout);
      final timeout = available < _exactRequestTimeout
          ? available
          : _exactRequestTimeout;
      return _get(uri, timeout: timeout);
    }

    Future<List<LrclibRecord>?> requestSearch(
      Map<String, String> queryParameters,
    ) async {
      final uri = _endpoint('search', queryParameters);
      if (requestCount >= _maxLookupRequests ||
          !requestedUris.add(uri.toString())) {
        return null;
      }
      final wait = _requestSlotWait(budget, pacer);
      if (wait != null) {
        await wait;
      }
      requestCount++;
      return _search(uri, timeout: budget.timeoutFor(_requestTimeout));
    }

    void remember(LrclibScoredRecord? candidate) {
      if (candidate != null &&
          (best == null || candidate.isBetterThan(best!))) {
        best = candidate;
      }
    }

    var broadAttempted = false;
    final duration = lookup.duration;
    if (duration != null &&
        duration > Duration.zero &&
        primaryIdentity.artist.isNotEmpty) {
      final exactParameters = {
        'track_name': primaryIdentity.title,
        'artist_name': primaryIdentity.artist,
        'duration': duration.inSeconds.toString(),
      };
      try {
        final exactResponse = await requestExact(exactParameters);
        if (exactResponse != null &&
            exactResponse.statusCode == HttpStatus.ok) {
          final exact = _recordFromObject(_decodeJson(exactResponse));
          if (exact != null) {
            final validated = _bestMatch(lookup, identities, [exact]);
            final document = validated?.record.toDocument(_parser);
            if (document?.hasContent ?? false) {
              return document;
            }
          }
        } else if (exactResponse != null &&
            exactResponse.statusCode != HttpStatus.badRequest &&
            exactResponse.statusCode != HttpStatus.notFound) {
          throw LrclibHttpException(
            exactResponse.statusCode,
            exactResponse.body,
          );
        }
      } on LyricsConnectionException catch (error) {
        if (error.cause is! TimeoutException ||
            _requestTimeout <= _exactRequestTimeout) {
          rethrow;
        }
        // The exact endpoint can stall while full-text search remains healthy.
        // Abort it quickly and use one normalized broad query instead of
        // blocking the lyrics screen for the per-request timeout.
        final broadIdentity = _broadSearchIdentity(identities);
        final broad = await requestSearch({'q': _broadQuery(broadIdentity)});
        broadAttempted = true;
        if (broad != null) {
          final broadMatch = _bestMatch(lookup, identities, broad);
          if (broadMatch != null && broadMatch.score >= _strongCandidateScore) {
            return broadMatch.record.toDocument(_parser);
          }
          remember(broadMatch);
        }
      }
    }

    for (final identity in identities) {
      final structuredLimit = broadAttempted
          ? _maxLookupRequests
          : _maxLookupRequests - 1;
      if (requestCount >= structuredLimit) {
        break;
      }
      final structuredParameters = {'track_name': identity.title};
      if (identity.artist.isNotEmpty) {
        structuredParameters['artist_name'] = identity.artist;
      }
      final structured = await requestSearch(structuredParameters);
      if (structured == null) {
        continue;
      }
      final structuredMatch = _bestMatch(lookup, identities, structured);
      if (structuredMatch != null &&
          structuredMatch.score >= _strongCandidateScore) {
        return structuredMatch.record.toDocument(_parser);
      }
      remember(structuredMatch);
    }

    if (!broadAttempted) {
      final broadIdentity = _broadSearchIdentity(identities);
      final broad = await requestSearch({'q': _broadQuery(broadIdentity)});
      if (broad != null) {
        remember(_bestMatch(lookup, identities, broad));
      }
    }
    return best?.record.toDocument(_parser);
  }

  Future<List<LrclibRecord>> _search(Uri uri, {Duration? timeout}) async {
    final response = await _get(uri, timeout: timeout);
    if (response.statusCode == HttpStatus.notFound ||
        response.statusCode == HttpStatus.noContent) {
      return const [];
    }
    if (response.statusCode != HttpStatus.ok) {
      throw LrclibHttpException(response.statusCode, response.body);
    }
    final decoded = _decodeJson(response);
    if (decoded is! List) {
      throw const LrclibFormatException(
        'LRCLIB returned a non-list search response.',
      );
    }
    return decoded
        .map(_recordFromObject)
        .whereType<LrclibRecord>()
        .where((record) => record.toDocument(_parser).hasContent)
        .toList(growable: false);
  }

  LrclibScoredRecord? _bestMatch(
    LyricsLookup lookup,
    List<LrclibSearchIdentity> identities,
    List<LrclibRecord> candidates,
  ) {
    LrclibScoredRecord? best;
    for (final record in candidates) {
      double? recordScore;
      for (final identity in identities) {
        final score = _candidateScore(lookup, identity, record);
        if (score != null && (recordScore == null || score > recordScore)) {
          recordScore = score;
        }
      }
      if (recordScore == null || recordScore < _minimumCandidateScore) {
        continue;
      }
      final candidate = LrclibScoredRecord(record: record, score: recordScore);
      if (best == null || candidate.isBetterThan(best)) {
        best = candidate;
      }
    }
    return best;
  }

  double? _candidateScore(
    LyricsLookup lookup,
    LrclibSearchIdentity identity,
    LrclibRecord candidate,
  ) {
    final titleScore = _titleSimilarity(identity.title, candidate.trackName);
    final hasArtist = identity.artist.isNotEmpty;
    final artistScore = hasArtist
        ? _artistSimilarity(identity.artist, candidate.artistName)
        : 0.5;
    if (titleScore < (hasArtist ? 0.52 : 0.82) ||
        (hasArtist && artistScore < 0.35) ||
        _hasNumberConflict(identity.title, candidate.trackName)) {
      return null;
    }

    final durationScore = _durationScore(lookup.duration, candidate.duration);
    if (!hasArtist &&
        (lookup.duration == null ||
            candidate.duration == null ||
            durationScore < 0.75)) {
      return null;
    }
    if (durationScore == 0 &&
        lookup.duration != null &&
        candidate.duration != null) {
      return null;
    }
    final albumScore = _albumScore(lookup.album, candidate.albumName);
    // A base-title fallback must not erase the requested version semantics.
    final versionPenalty = _versionPenalty(
      lookup.title,
      candidate.trackName,
      matchedTitle: identity.title,
    );
    final score =
        titleScore * 0.52 +
        artistScore * 0.27 +
        durationScore * 0.16 +
        albumScore * 0.05 -
        versionPenalty;
    return score.clamp(0.0, 1.0);
  }

  List<LrclibScoredRecord> _scoreSimilarRecords(
    LyricsLookup lookup,
    List<LrclibSearchIdentity> identities,
    Iterable<LrclibRecord> records, {
    bool allowArtistOnly = false,
  }) {
    final candidates = <LrclibScoredRecord>[];
    for (final record in records) {
      // Instrumental records count as content for automatic lookup, but they
      // are not useful in a list where the listener explicitly wants lyrics.
      final document = record.toDocument(_parser);
      if (!document.hasPlainLyrics && !document.hasSyncedLyrics) {
        continue;
      }
      final score = _similarCandidateScore(
        lookup,
        identities,
        record,
        allowArtistOnly: allowArtistOnly,
      );
      if (score != null) {
        candidates.add(LrclibScoredRecord(record: record, score: score));
      }
    }
    return candidates;
  }

  List<LyricsCandidate> _toLyricsCandidates(
    List<LrclibScoredRecord> candidates, {
    required int limit,
  }) {
    candidates.sort((left, right) {
      if (left.isBetterThan(right)) {
        return -1;
      }
      if (right.isBetterThan(left)) {
        return 1;
      }
      return 0;
    });

    final unique = <String, LyricsCandidate>{};
    for (final candidate in candidates) {
      final record = candidate.record;
      final key = [
        _normalizeText(record.trackName),
        _normalizeText(record.artistName),
        record.duration?.inSeconds.toString() ?? '',
      ].join('|');
      unique.putIfAbsent(
        key,
        () => LyricsCandidate(
          document: record.toDocument(_parser),
          similarity: candidate.score,
        ),
      );
      if (unique.length >= limit) {
        break;
      }
    }
    return unique.values.toList(growable: false);
  }

  List<String> _similarTitleQueries(
    LyricsLookup lookup,
    List<LrclibSearchIdentity> identities,
  ) {
    final contextArtist = _reliableContextArtist(lookup);
    final rawContextArtist = _cleanArtist(lookup.artist);
    final titleIdentities = identities
        .where((identity) {
          return contextArtist == null ||
              _artistSimilarity(contextArtist, identity.title) < 0.40;
        })
        .toList(growable: false);
    if (titleIdentities.isEmpty) {
      return const [];
    }
    final orderedIdentities = List<LrclibSearchIdentity>.of(titleIdentities)
      ..sort((left, right) {
        if (contextArtist != null) {
          final leftArtist = left.artist.isEmpty
              ? 0.0
              : _artistSimilarity(contextArtist, left.artist);
          final rightArtist = right.artist.isEmpty
              ? 0.0
              : _artistSimilarity(contextArtist, right.artist);
          if ((leftArtist - rightArtist).abs() >= 0.12) {
            return rightArtist.compareTo(leftArtist);
          }
        }
        final leftWords = _normalizeText(left.title).split(' ').length;
        final rightWords = _normalizeText(right.title).split(' ').length;
        return leftWords.compareTo(rightWords);
      });
    final queries = <String>[];
    final keys = <String>{};
    void addQuery(String value) {
      if (queries.length >= _maxSimilarTitleRequests) {
        return;
      }
      final query = _cleanQueryText(value);
      if (query.isEmpty ||
          (contextArtist != null &&
              _queryEquivalenceKey(query) ==
                  _queryEquivalenceKey(contextArtist)) ||
          !keys.add(_queryEquivalenceKey(query))) {
        return;
      }
      queries.add(query);
    }

    for (final identity in orderedIdentities) {
      final isUnreliableContextIdentity =
          contextArtist == null &&
          rawContextArtist.isNotEmpty &&
          _queryEquivalenceKey(identity.artist) ==
              _queryEquivalenceKey(rawContextArtist);
      final safeIdentity =
          _isLikelyChannelArtist(identity.artist) || isUnreliableContextIdentity
          ? LrclibSearchIdentity(title: identity.title, artist: '')
          : identity;
      if (safeIdentity.artist.isNotEmpty) {
        addQuery(_broadQuery(safeIdentity));
      }
      // A stale uploader/channel is the most common reason a combined FTS
      // query returns nothing. Title-only remains safe because candidates are
      // still validated locally against title, artist and duration.
      addQuery(safeIdentity.title);
      if (queries.length >= _maxSimilarTitleRequests) {
        break;
      }
    }
    return queries;
  }

  bool _containsEquivalentQuery(Iterable<String> queries, String candidate) {
    final key = _queryEquivalenceKey(candidate);
    return queries.any((query) => _queryEquivalenceKey(query) == key);
  }

  String _queryEquivalenceKey(String query) {
    final tokens = _normalizeText(
      query,
    ).split(' ').where((token) => token.isNotEmpty).toSet().toList()..sort();
    return tokens.join(' ');
  }

  String _requestEquivalenceKey(String value) {
    return _cleanQueryText(
      value,
    ).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String? _reliableContextArtist(LyricsLookup lookup) {
    final artist = _cleanArtist(lookup.artist);
    if (artist.isEmpty || _isLikelyChannelArtist(lookup.artist)) {
      return null;
    }
    final variants = _queryArtistVariants(artist);
    return variants.isEmpty ? artist : variants.first;
  }

  double? _manualCandidateScore(
    String manualTitle,
    LyricsLookup context,
    LrclibRecord candidate,
  ) {
    final titleScore = _titleSimilarity(manualTitle, candidate.trackName);
    if (titleScore < 0.5) {
      return null;
    }

    final artist = _reliableContextArtist(context);
    final artistScore = artist == null
        ? 0.5
        : _artistSimilarity(artist, candidate.artistName);
    final durationScore = _durationScore(context.duration, candidate.duration);
    // A manually entered exact or near-exact title may intentionally select a
    // cover or another version. Reject a conflicting artist/duration only
    // when the title itself is not sufficiently convincing.
    if (artist != null &&
        artistScore < 0.12 &&
        durationScore == 0 &&
        titleScore < 0.82) {
      return null;
    }

    final score =
        titleScore * 0.76 +
        artistScore * 0.14 +
        durationScore * 0.08 +
        _albumScore(context.album, candidate.albumName) * 0.02 -
        _versionPenalty(manualTitle, candidate.trackName) * 0.2;
    final normalized = score.clamp(0.0, 1.0);
    return normalized < 0.45 ? null : normalized;
  }

  double? _similarCandidateScore(
    LyricsLookup lookup,
    List<LrclibSearchIdentity> identities,
    LrclibRecord candidate, {
    bool allowArtistOnly = false,
  }) {
    if (allowArtistOnly) {
      final artist = _reliableContextArtist(lookup);
      if (artist == null) {
        return null;
      }
      final artistScore = _artistSimilarity(artist, candidate.artistName);
      if (artistScore < 0.72) {
        return null;
      }
      var titleScore = 0.0;
      for (final identity in identities) {
        final score = _titleSimilarity(identity.title, candidate.trackName);
        if (score > titleScore) {
          titleScore = score;
        }
      }
      // An artist-only LRCLIB query may return an entire discography. It is a
      // recovery query, not permission to show unrelated songs.
      if (titleScore <= 0.42) {
        return null;
      }
      final score =
          0.18 +
          artistScore * 0.34 +
          titleScore * 0.28 +
          _durationScore(lookup.duration, candidate.duration) * 0.12 +
          _albumScore(lookup.album, candidate.albumName) * 0.08;
      return score.clamp(0.0, 1.0);
    }

    double? best;
    for (final identity in identities) {
      final titleScore = _titleSimilarity(identity.title, candidate.trackName);
      // 0.42 is the cap used by _textSimilarity for a single generic shared
      // token (for example "Titan" versus "Titan Hardcore"). Requiring a
      // little more keeps suggestions broad without admitting that case.
      if (titleScore <= 0.42) {
        continue;
      }
      final hasArtist = identity.artist.isNotEmpty;
      final artistScore = hasArtist
          ? _artistSimilarity(identity.artist, candidate.artistName)
          : 0.5;
      final durationScore = _durationScore(lookup.duration, candidate.duration);
      // A manual suggestion may be a little broader than auto-match, but an
      // unrelated artist still needs a convincing title. Duration is only a
      // secondary ordering signal because covers and edits can differ widely.
      if (hasArtist &&
          artistScore < 0.25 &&
          titleScore < 0.82 &&
          durationScore < 0.75) {
        continue;
      }
      final score =
          titleScore * 0.66 +
          artistScore * 0.18 +
          durationScore * 0.11 +
          _albumScore(lookup.album, candidate.albumName) * 0.05 -
          _versionPenalty(identity.title, candidate.trackName) * 0.3;
      final normalized = score.clamp(0.0, 1.0);
      if (normalized >= 0.43 && (best == null || normalized > best)) {
        best = normalized;
      }
    }

    return best;
  }

  double _durationScore(Duration? expected, Duration? actual) {
    if (expected == null || actual == null) {
      return 0.5;
    }
    final difference = (expected - actual).abs().inMilliseconds / 1000;
    if (difference <= 1) {
      return 1;
    }
    if (difference <= 3) {
      return 0.95;
    }
    if (difference <= 8) {
      return 0.75;
    }
    if (difference <= 15) {
      return 0.35;
    }
    // Music videos may contain a short intro or credits which are absent from
    // the album recording. A small score keeps an otherwise exact match in
    // consideration without allowing a substantially different version.
    if (difference <= 30) {
      return 0.1;
    }
    return 0;
  }

  double _versionPenalty(
    String expected,
    String actual, {
    String? matchedTitle,
  }) {
    final expectedTags = _versionTags(
      _hasQualifiedKaraokePresentation(expected)
          ? _withoutKaraokePresentation(expected)
          : expected,
    );
    final actualTags = _versionTags(
      _hasQualifiedKaraokePresentation(actual)
          ? _withoutKaraokePresentation(actual)
          : actual,
    );
    if (matchedTitle != null &&
        _hasBareEnclosedKaraoke(expected) &&
        _versionTags(matchedTitle).contains('karaoke')) {
      expectedTags.add('karaoke');
    }
    if (expectedTags.isEmpty && actualTags.isEmpty) {
      return 0;
    }
    if (expectedTags.isNotEmpty && actualTags.isNotEmpty) {
      if (expectedTags.length == actualTags.length &&
          expectedTags.containsAll(actualTags)) {
        return 0;
      }
      if (expectedTags.containsAll(actualTags) ||
          actualTags.containsAll(expectedTags)) {
        return 0.14;
      }
      return 0.24;
    }
    return 0.14;
  }

  Set<String> _versionTags(String value) {
    final normalized = _normalizeText(value);
    final tags = <String>{};
    const singleWordTags = {
      'remix',
      'live',
      'acoustic',
      'acustico',
      'instrumental',
      'karaoke',
      'nightcore',
      'slowed',
      'remaster',
      'remastered',
    };
    final tokens = normalized.split(' ').toSet();
    tags.addAll(tokens.intersection(singleWordTags));
    if (normalized.contains('sped up')) {
      tags.add('sped up');
    }
    if (normalized.contains('radio edit')) {
      tags.add('radio edit');
    }
    return tags;
  }

  bool _hasNumberConflict(String expected, String actual) {
    Set<String> semanticNumbers(String value) {
      final normalized = _normalizeText(value);
      final values = <String>{};
      final explicitNumbers = RegExp(r'\b\d+\b');
      values.addAll(explicitNumbers.allMatches(normalized).map((m) => m[0]!));
      final labeled = RegExp(
        r'\b(?:part|parte|pt|vol|volume|no|number|chapter|capitulo)\s+'
        r'([ivxlcdm]+)\b',
      );
      values.addAll(labeled.allMatches(normalized).map((m) => m[1]!));
      return values;
    }

    final expectedNumbers = semanticNumbers(expected);
    final actualNumbers = semanticNumbers(actual);
    return expectedNumbers.isNotEmpty &&
        actualNumbers.isNotEmpty &&
        expectedNumbers.intersection(actualNumbers).isEmpty;
  }

  double _albumScore(String? expected, String? actual) {
    final normalizedExpected = meaningfulLrclibMetadata(expected);
    final normalizedActual = meaningfulLrclibMetadata(actual);
    if (normalizedExpected == null || normalizedActual == null) {
      return 0.5;
    }
    return _textSimilarity(normalizedExpected, normalizedActual);
  }

  double _titleSimilarity(String expected, String actual) {
    var best = 0.0;
    for (final expectedVariant in _titleVariants(expected)) {
      for (final actualVariant in _titleVariants(actual)) {
        final score = _textSimilarity(expectedVariant, actualVariant);
        if (score > best) {
          best = score;
        }
      }
    }
    return best;
  }

  double _artistSimilarity(String expected, String actual) {
    var best = 0.0;
    for (final expectedVariant in _queryArtistVariants(expected)) {
      for (final actualVariant in _queryArtistVariants(actual)) {
        final score = _textSimilarity(expectedVariant, actualVariant);
        if (score > best) {
          best = score;
        }
      }
    }
    return best;
  }

  List<String> _titleVariants(String value) {
    final variants = <String>{};
    for (final queryVariant in _queryTitleVariants(value)) {
      variants.add(queryVariant);
      final segments = _splitTitleSegments(queryVariant);
      if (segments.length >= 2) {
        variants.addAll(segments);
      }
    }
    return variants.toList(growable: false);
  }

  double _textSimilarity(String left, String right) {
    final normalizedLeft = _normalizeText(left);
    final normalizedRight = _normalizeText(right);
    if (normalizedLeft.isEmpty || normalizedRight.isEmpty) {
      return 0;
    }
    if (normalizedLeft == normalizedRight) {
      return 1;
    }
    final compactLeft = normalizedLeft.replaceAll(' ', '');
    final compactRight = normalizedRight.replaceAll(' ', '');
    if (compactLeft.length >= 4 && compactLeft == compactRight) {
      return 0.98;
    }

    final leftTokens = normalizedLeft
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList();
    final rightTokens = normalizedRight
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList();
    final leftCounts = _tokenCounts(leftTokens);
    final rightCounts = _tokenCounts(rightTokens);
    var intersection = 0;
    for (final entry in leftCounts.entries) {
      final rightCount = rightCounts[entry.key] ?? 0;
      intersection += entry.value < rightCount ? entry.value : rightCount;
    }
    final dice = (2 * intersection) / (leftTokens.length + rightTokens.length);
    final coverage =
        intersection /
        (leftTokens.length < rightTokens.length
            ? leftTokens.length
            : rightTokens.length);
    var score = dice > coverage * 0.9 ? dice : coverage * 0.9;

    final remainingLeft = List<String>.of(leftTokens);
    final remainingRight = List<String>.of(rightTokens);
    for (final token in List<String>.of(remainingLeft)) {
      final matchingIndex = remainingRight.indexOf(token);
      if (matchingIndex >= 0) {
        remainingLeft.remove(token);
        remainingRight.removeAt(matchingIndex);
      }
    }
    var fuzzyWeight = intersection.toDouble();
    while (remainingLeft.isNotEmpty && remainingRight.isNotEmpty) {
      var bestLeft = -1;
      var bestRight = -1;
      var bestPair = 0.0;
      for (var leftIndex = 0; leftIndex < remainingLeft.length; leftIndex++) {
        for (
          var rightIndex = 0;
          rightIndex < remainingRight.length;
          rightIndex++
        ) {
          final pair = _editSimilarity(
            remainingLeft[leftIndex],
            remainingRight[rightIndex],
          );
          if (pair > bestPair) {
            bestPair = pair;
            bestLeft = leftIndex;
            bestRight = rightIndex;
          }
        }
      }
      if (bestPair < 0.78) {
        break;
      }
      fuzzyWeight += bestPair;
      remainingLeft.removeAt(bestLeft);
      remainingRight.removeAt(bestRight);
    }
    final fuzzyDice =
        (2 * fuzzyWeight) / (leftTokens.length + rightTokens.length);
    if (fuzzyDice > score) {
      score = fuzzyDice;
    }

    if (score >= 0.7 &&
        normalizedLeft.length >= 4 &&
        normalizedRight.length >= 4) {
      final ordered = _editSimilarity(normalizedLeft, normalizedRight);
      score = score * 0.84 + ordered * 0.16;
    }

    // A single shared word is weak evidence for a multi-word song title
    // (for example "Titán" versus "Titán Hardcore"). Repeated words retain
    // their multiplicity instead of collapsing into a Set.
    final shorterLength = leftTokens.length < rightTokens.length
        ? leftTokens.length
        : rightTokens.length;
    if (shorterLength == 1 && leftTokens.length != rightTokens.length) {
      score = score.clamp(0.0, 0.42);
    }
    return score;
  }

  Map<String, int> _tokenCounts(Iterable<String> tokens) {
    final counts = <String, int>{};
    for (final token in tokens) {
      counts.update(token, (count) => count + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  double _editSimilarity(String left, String right) {
    if (left == right) {
      return 1;
    }
    if (left.length < 4 || right.length < 4) {
      return 0;
    }
    final previous = List<int>.generate(right.length + 1, (index) => index);
    final current = List<int>.filled(right.length + 1, 0);
    for (var leftIndex = 1; leftIndex <= left.length; leftIndex++) {
      current[0] = leftIndex;
      for (var rightIndex = 1; rightIndex <= right.length; rightIndex++) {
        final substitution =
            previous[rightIndex - 1] +
            (left.codeUnitAt(leftIndex - 1) == right.codeUnitAt(rightIndex - 1)
                ? 0
                : 1);
        final insertion = current[rightIndex - 1] + 1;
        final deletion = previous[rightIndex] + 1;
        current[rightIndex] = [
          substitution,
          insertion,
          deletion,
        ].reduce((best, value) => value < best ? value : best);
      }
      for (var index = 0; index < previous.length; index++) {
        previous[index] = current[index];
      }
    }
    final longest = left.length > right.length ? left.length : right.length;
    return 1 - previous[right.length] / longest;
  }

  String _normalizeText(String value) {
    var normalized = _foldForComparison(_stripPresentationBlocks(value));
    normalized = normalized.replaceAll(
      RegExp(r'\b(?:ft|featuring)\b', caseSensitive: false),
      'feat',
    );
    final buffer = StringBuffer();
    var needsSpace = false;
    for (final rune in normalized.runes) {
      if (_isIgnoredComparisonRune(rune) || _isVariationRune(rune)) {
        continue;
      }
      final character = String.fromCharCode(rune);
      if (_isComparisonSeparator(rune) || character.trim().isEmpty) {
        needsSpace = buffer.isNotEmpty;
        continue;
      }
      if (needsSpace) {
        buffer.write(' ');
        needsSpace = false;
      }
      buffer.writeCharCode(rune);
    }
    return buffer.toString().trim();
  }

  String _foldForComparison(String value) {
    var folded = value.toLowerCase();
    const latinGroups = <String, String>{
      'a': 'àáâãäåāăąǎǟǡǻȁȃȧạảấầẩẫậắằẳẵặ',
      'b': 'ḃḅḇɓ',
      'c': 'çćĉċč',
      'd': 'ďđḋḍḏḓð',
      'e': 'èéêëēĕėęěȅȇȩẹẻẽếềểễệ',
      'f': 'ḟƒ',
      'g': 'ĝğġģǧǵḡ',
      'h': 'ĥħȟḣḥḧḩḫ',
      'i': 'ìíîïĩīĭįıǐȉȋịỉİ',
      'j': 'ĵǰ',
      'k': 'ķǩḱḳḵ',
      'l': 'ĺļľŀłḷḹḻḽ',
      'm': 'ḿṁṃ',
      'n': 'ñńņňŉŋǹṅṇṉṋ',
      'o': 'òóôõöøōŏőơǒǫǭǿȍȏȫȭȯȱọỏốồổỗộớờởỡợ',
      'p': 'ṕṗ',
      'r': 'ŕŗřȑȓṙṛṝṟ',
      's': 'śŝşšșṡṣṥṧṩ',
      't': 'ţťŧțṫṭṯṱ',
      'u': 'ùúûüũūŭůűųưǔǖǘǚǜȕȗụủứừửữự',
      'v': 'ṽṿ',
      'w': 'ŵẁẃẅẇẉ',
      'y': 'ýÿŷȳẏỳỵỷỹ',
      'z': 'źżžẑẓẕ',
    };
    for (final entry in latinGroups.entries) {
      for (final rune in entry.value.runes) {
        folded = folded.replaceAll(String.fromCharCode(rune), entry.key);
      }
    }
    const replacements = <String, String>{
      'æ': 'ae',
      'ǽ': 'ae',
      'œ': 'oe',
      'ß': 'ss',
      'þ': 'th',
      'ά': 'α',
      'έ': 'ε',
      'ή': 'η',
      'ί': 'ι',
      'ϊ': 'ι',
      'ΐ': 'ι',
      'ό': 'ο',
      'ύ': 'υ',
      'ϋ': 'υ',
      'ΰ': 'υ',
      'ώ': 'ω',
      'ё': 'е',
    };
    replacements.forEach((source, target) {
      folded = folded.replaceAll(source, target);
    });
    return folded;
  }

  List<LrclibSearchIdentity> _searchIdentities(LyricsLookup lookup) {
    final normalizedTitle = _cleanQueryText(lookup.title);
    final cleanedTitle = normalizedTitle.isEmpty
        ? lookup.title.trim()
        : normalizedTitle;
    final cleanedArtist = _cleanArtist(lookup.artist);
    final identities = <LrclibSearchIdentity>[];

    void addIdentityVariants(
      String title,
      String artist, {
      bool preferTitleOnlyAfterPrimary = false,
    }) {
      final titleVariants = _queryTitleVariants(title);
      if (titleVariants.isEmpty) {
        return;
      }
      final artistVariants = artist.isEmpty
          ? const ['']
          : _queryArtistVariants(artist);
      final safeArtists = artistVariants.isEmpty ? const [''] : artistVariants;

      // Interleave title and artist fallbacks so one noisy field cannot spend
      // the complete network budget before another logical identity is tried.
      identities.add(
        LrclibSearchIdentity(
          title: titleVariants.first,
          artist: safeArtists.first,
        ),
      );
      if (preferTitleOnlyAfterPrimary && safeArtists.first.isNotEmpty) {
        for (final titleVariant in titleVariants) {
          identities.add(LrclibSearchIdentity(title: titleVariant, artist: ''));
        }
      }
      for (final titleVariant in titleVariants.skip(1)) {
        identities.add(
          LrclibSearchIdentity(title: titleVariant, artist: safeArtists.first),
        );
      }
      for (final artistVariant in safeArtists.skip(1)) {
        identities.add(
          LrclibSearchIdentity(
            title: titleVariants.first,
            artist: artistVariant,
          ),
        );
      }
    }

    // Some official YouTube titles use pictographs as semantic separators,
    // for example ARTIST❌ARTIST 👀💙SONG. Recover that identity before the
    // decorations are removed from outgoing LRCLIB queries.
    final decorated = _decoratedIdentity(lookup.title, cleanedArtist);
    if (decorated != null) {
      addIdentityVariants(decorated.title, decorated.primaryArtist);
      if (_normalizeText(decorated.allArtists) !=
          _normalizeText(decorated.primaryArtist)) {
        addIdentityVariants(decorated.title, decorated.allArtists);
      }
    }

    for (final enclosed in _enclosedIdentities(lookup.title, cleanedArtist)) {
      addIdentityVariants(enclosed.title, enclosed.artist);
    }

    final leadingDoublePipe = RegExp(
      r'^(.+?)\s*\|{2,}\s*.+$',
    ).firstMatch(lookup.title);
    if (leadingDoublePipe != null && cleanedArtist.isNotEmpty) {
      addIdentityVariants(leadingDoublePipe.group(1)!, cleanedArtist);
    }

    final channelLikeArtist = _isLikelyChannelArtist(lookup.artist);
    final segments = _splitTitleSegments(
      lookup.title,
      artistHint: channelLikeArtist ? '' : cleanedArtist,
    );
    final hasDurationBackedTitleFallback =
        segments.length < 2 &&
        cleanedArtist.isNotEmpty &&
        lookup.duration != null &&
        lookup.duration! > Duration.zero;
    var unreliableArtist = channelLikeArtist;
    var matchingArtistIndex = -1;
    var matchingArtistScore = 0.0;
    if (cleanedArtist.isNotEmpty) {
      for (var index = 0; index < segments.length; index++) {
        final score = _artistSimilarity(cleanedArtist, segments[index]);
        if (score > matchingArtistScore) {
          matchingArtistScore = score;
          matchingArtistIndex = index;
        }
      }
    }
    // "Grupo Barak" and "BARAK" are common metadata differences; the
    // similarity floor still rejects an unrelated uploader while allowing a
    // contained lead-artist name to orient the split.
    final hasAlignedArtist = !channelLikeArtist && matchingArtistScore >= 0.40;
    unreliableArtist =
        unreliableArtist ||
        (cleanedArtist.isNotEmpty && segments.length >= 2 && !hasAlignedArtist);

    void addAlignedSplitIdentities() {
      if (!hasAlignedArtist || segments.length < 2) {
        return;
      }
      final splitArtist = segments[matchingArtistIndex];
      if (matchingArtistIndex == 0) {
        for (var end = segments.length; end > 1; end--) {
          addIdentityVariants(
            _joinTitleSegments(segments.sublist(1, end)),
            splitArtist,
          );
        }
      } else if (matchingArtistIndex == segments.length - 1) {
        for (var start = 0; start < matchingArtistIndex; start++) {
          addIdentityVariants(
            _joinTitleSegments(segments.sublist(start, matchingArtistIndex)),
            splitArtist,
          );
        }
      } else {
        addIdentityVariants(
          _joinTitleSegments(segments.sublist(matchingArtistIndex + 1)),
          splitArtist,
        );
        addIdentityVariants(
          _joinTitleSegments(segments.sublist(0, matchingArtistIndex)),
          splitArtist,
        );
      }
    }

    void addConventionalSplitIdentities() {
      // Conventional Artist - Title, progressively dropping trailing
      // presentation segments without knowing their language.
      for (var end = segments.length; end > 1; end--) {
        addIdentityVariants(
          _joinTitleSegments(segments.sublist(1, end)),
          segments.first,
        );
      }
      // Also support Title - Artist and its multi-separator forms.
      for (var start = 0; start < segments.length - 1; start++) {
        addIdentityVariants(
          _joinTitleSegments(segments.sublist(start, segments.length - 1)),
          segments.last,
        );
      }
    }

    // A side which agrees with yt-dlp metadata is the highest-confidence
    // interpretation. For an ambiguous two-sided YouTube title, the common
    // Artist - Title form is tried first, except for semantic continuations
    // such as "Love - Part II". The unsplit form is always retained.
    addAlignedSplitIdentities();
    final hasKaraokePresentationNoise = segments.any((segment) {
      final stripped = _withoutKaraokePresentation(segment);
      return stripped.isNotEmpty &&
          _normalizeText(stripped) != _normalizeText(segment);
    });
    final preserveWholeFirst =
        (!hasKaraokePresentationNoise &&
            _looksLikeTitleContinuation(segments)) ||
        (!hasAlignedArtist &&
            cleanedArtist.isNotEmpty &&
            !_isLikelyChannelArtist(lookup.artist));
    if (!hasAlignedArtist && segments.length >= 2 && !preserveWholeFirst) {
      addConventionalSplitIdentities();
    }
    if (segments.length == 1 &&
        _normalizeText(segments.single) != _normalizeText(cleanedTitle)) {
      addIdentityVariants(
        segments.single,
        cleanedArtist,
        preferTitleOnlyAfterPrimary: channelLikeArtist,
      );
    }
    addIdentityVariants(
      cleanedTitle,
      cleanedArtist,
      // Uploader names are unbounded ("Fans Music", labels, repost channels),
      // so reserve the duration-backed title-only variants inside the network
      // budget instead of appending them after every artist-bound variant.
      preferTitleOnlyAfterPrimary:
          channelLikeArtist || hasDurationBackedTitleFallback,
    );

    if (segments.length >= 2) {
      if (!hasAlignedArtist && preserveWholeFirst) {
        addConventionalSplitIdentities();
      }

      // Each adjacent pair covers mixed forms such as Artist | Song | Label
      // while deduplication below keeps the request plan bounded.
      for (var index = 0; index < segments.length - 1; index++) {
        addIdentityVariants(segments[index + 1], segments[index]);
        addIdentityVariants(segments[index], segments[index + 1]);
      }
    }

    // Channel names are frequently copied into the artist field. When that
    // metadata is suspicious, allow LRCLIB to search the best title variants
    // without forcing the channel to match an artist.
    if (cleanedArtist.isEmpty) {
      addIdentityVariants(cleanedTitle, '');
    } else if (unreliableArtist) {
      for (final identity in List<LrclibSearchIdentity>.of(identities)) {
        identities.add(LrclibSearchIdentity(title: identity.title, artist: ''));
      }
    }

    final unique = <String, LrclibSearchIdentity>{};
    for (final identity in identities) {
      if (identity.title.isEmpty) {
        continue;
      }
      final key =
          '${_requestEquivalenceKey(identity.title)}|'
          '${_requestEquivalenceKey(identity.artist)}';
      unique.putIfAbsent(key, () => identity);
    }
    return unique.values.toList(growable: false);
  }

  List<String> _queryTitleVariants(String value) {
    final cleaned = _cleanQueryText(value);
    if (cleaned.isEmpty) {
      return const [];
    }

    final variants = <String>{};
    final doublePipe = RegExp(r'^(.+?)\s*\|{2,}\s*(.+)$').firstMatch(cleaned);
    if (doublePipe != null) {
      final leadingTitle = _trimEdgeSeparators(doublePipe.group(1)!);
      if (leadingTitle.isNotEmpty) {
        variants.add(leadingTitle);
      }
    }
    variants.add(cleaned);
    final karaokeCleaned = _withoutKaraokePresentation(cleaned);
    if (_normalizeText(karaokeCleaned) != _normalizeText(cleaned)) {
      final composed = _withoutTechnicalPresentationSuffix(karaokeCleaned);
      if (composed.isNotEmpty) {
        variants.add(composed);
      }
    }

    var variantIndex = 0;
    while (variantIndex < variants.length) {
      final candidate = variants.elementAt(variantIndex++);
      final withoutKaraokePresentation = _withoutKaraokePresentation(candidate);
      if (withoutKaraokePresentation.isNotEmpty) {
        variants.add(withoutKaraokePresentation);
      }

      final canonicalFeaturing = candidate
          .replaceAll(
            RegExp(r'\b(?:ft|featuring)\.?\s*', caseSensitive: false),
            'feat. ',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (canonicalFeaturing.isNotEmpty) {
        variants.add(canonicalFeaturing);
      }

      final withoutFeaturing = candidate
          .replaceFirst(
            RegExp(
              r'\s*[\(\[]?\s*(?:feat(?:uring)?|ft|w/)\.?\s*[^\)\]]+'
              r'[\)\]]?\s*$',
              caseSensitive: false,
            ),
            ' ',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (withoutFeaturing.isNotEmpty) {
        variants.add(withoutFeaturing);
      }

      final withoutBlocks = candidate
          .replaceAll(
            RegExp(
              r'\s*(?:\([^()]*\)|\[[^\[\]]*\]|【[^【】]*】|'
              r'「[^「」]*」|『[^『』]*』|《[^《》]*》|〈[^〈〉]*〉)\s*',
            ),
            ' ',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (withoutBlocks.isNotEmpty) {
        variants.add(withoutBlocks);
      }

      final withoutTechnicalSuffix = _withoutTechnicalPresentationSuffix(
        candidate,
      );
      if (withoutTechnicalSuffix.isNotEmpty) {
        variants.add(withoutTechnicalSuffix);
      }
    }
    return variants.toList(growable: false);
  }

  String _withoutTechnicalPresentationSuffix(String value) {
    return value
        .replaceFirst(
          RegExp(
            r'(?:\s+(?:#\w+|\d{3,4}p|[248]k|hd|uhd))+$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  List<String> _queryArtistVariants(String value) {
    final cleaned = _cleanArtist(value);
    if (cleaned.isEmpty) {
      return const [];
    }
    final variants = <String>{};
    final explicitCollaboration = RegExp(
      r'(?:\s+|[\(\[]\s*)'
      r'(?:(?:feat(?:uring)?|ft|f/|w/|con|com|with|vs)(?:\.\s*|\s+)'
      r'|(?:x|×)\s+)',
      caseSensitive: false,
    ).firstMatch(cleaned);
    if (explicitCollaboration != null) {
      final primary = _trimEdgeSeparators(
        cleaned.substring(0, explicitCollaboration.start),
      );
      if (primary.isNotEmpty) {
        // LRCLIB commonly stores featured artists in trackName and only the
        // lead artist in artistName, so this must precede the full credit.
        variants.add(primary);
      }
    }
    final canonicalFeaturing = cleaned
        .replaceFirst(
          RegExp(r'\b(?:ft|featuring)\.?\s*', caseSensitive: false),
          'feat. ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (canonicalFeaturing.isNotEmpty) {
      variants.add(canonicalFeaturing);
    }
    variants.add(cleaned);

    final joinedCollaboration = RegExp(
      r'\s+(?:&|×|\+|/|;)\s+',
    ).firstMatch(cleaned);
    if (joinedCollaboration != null) {
      final primary = _trimEdgeSeparators(
        cleaned.substring(0, joinedCollaboration.start),
      );
      if (primary.isNotEmpty) {
        variants.add(primary);
      }
    }
    final comma = cleaned.indexOf(',');
    if (comma > 0) {
      final primary = _trimEdgeSeparators(cleaned.substring(0, comma));
      if (primary.isNotEmpty) {
        variants.add(primary);
      }
    }
    return variants.toList(growable: false);
  }

  List<LrclibSearchIdentity> _enclosedIdentities(
    String value,
    String artistHint,
  ) {
    final identities = <LrclibSearchIdentity>[];
    final patterns = <RegExp>[
      RegExp(r'「([^「」]+)」'),
      RegExp(r'『([^『』]+)』'),
      RegExp(r'【([^【】]+)】'),
      RegExp(r'《([^《》]+)》'),
      RegExp(r'〈([^〈〉]+)〉'),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(value)) {
        final title = _cleanQueryText(match.group(1)!);
        final prefix = _cleanArtist(value.substring(0, match.start));
        final suffix = _cleanArtist(value.substring(match.end));
        final ambiguousTitle = _isAmbiguousPresentationTitle(title);
        if (title.isEmpty ||
            ((_isPresentationSegment(title) || _isKaraokePresentation(title)) &&
                !ambiguousTitle)) {
          continue;
        }
        final prefixScore = artistHint.isEmpty || prefix.isEmpty
            ? 0.0
            : _artistSimilarity(artistHint, prefix);
        final suffixScore = artistHint.isEmpty || suffix.isEmpty
            ? 0.0
            : _artistSimilarity(artistHint, suffix);
        if (prefix.isNotEmpty &&
            (prefixScore >= 0.45 ||
                (!ambiguousTitle &&
                    _isPresentationSegment(value.substring(match.end))))) {
          identities.add(LrclibSearchIdentity(title: title, artist: prefix));
        }
        if (suffix.isNotEmpty && suffixScore >= 0.45) {
          identities.add(LrclibSearchIdentity(title: title, artist: suffix));
        }
      }
    }
    return identities;
  }

  LrclibDecoratedIdentity? _decoratedIdentity(String value, String artistHint) {
    final segments = _splitOnDecorativeSymbols(value)
        .map(_trimEdgeSeparators)
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2) {
      return null;
    }

    final title = _cleanQueryText(segments.last);
    final artistSegments = segments
        .take(segments.length - 1)
        .map(_cleanArtist)
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (title.isEmpty || artistSegments.isEmpty) {
      return null;
    }

    var primaryArtist = artistSegments.first;
    var bestHintScore = 0.0;
    for (final artist in artistSegments) {
      final score = artistHint.isEmpty
          ? 0.0
          : _textSimilarity(artistHint, artist);
      if (score > bestHintScore) {
        bestHintScore = score;
        primaryArtist = artist;
      }
    }
    if ((artistHint.isNotEmpty && bestHintScore < 0.40) ||
        (artistHint.isEmpty && artistSegments.length < 2)) {
      return null;
    }

    return LrclibDecoratedIdentity(
      title: title,
      primaryArtist: primaryArtist,
      allArtists: artistSegments.join(', '),
    );
  }

  List<String> _splitOnDecorativeSymbols(String value) {
    final segments = <String>[];
    final buffer = StringBuffer();
    void flush() {
      final segment = buffer.toString().trim();
      if (segment.isNotEmpty) {
        segments.add(segment);
      }
      buffer.clear();
    }

    for (final rune in value.runes) {
      if (_isDecorativeRune(rune) || _isVariationRune(rune)) {
        flush();
      } else {
        buffer.writeCharCode(rune);
      }
    }
    flush();
    return segments;
  }

  List<String> _splitTitleSegments(String value, {String artistHint = ''}) {
    List<String> splitAtMatches(Iterable<RegExpMatch> matches) {
      final segments = <String>[];
      var start = 0;
      for (final match in matches) {
        final segment = _cleanQueryText(value.substring(start, match.start));
        if (segment.isNotEmpty) {
          segments.add(segment);
        }
        start = match.end;
      }
      final trailing = _cleanQueryText(value.substring(start));
      if (trailing.isNotEmpty) {
        segments.add(trailing);
      }

      var preservedTitleIndex = -1;
      if (segments.length >= 2 && artistHint.isNotEmpty) {
        var alignedArtistIndex = -1;
        var alignedArtistScore = 0.0;
        for (var index = 0; index < segments.length; index++) {
          final score = _artistSimilarity(artistHint, segments[index]);
          if (score > alignedArtistScore) {
            alignedArtistScore = score;
            alignedArtistIndex = index;
          }
        }
        if (alignedArtistScore >= 0.40) {
          for (final index in [
            alignedArtistIndex - 1,
            alignedArtistIndex + 1,
          ]) {
            if (index >= 0 &&
                index < segments.length &&
                _isAmbiguousPresentationTitle(segments[index])) {
              final hasOtherSubstantiveTitle = [
                for (var other = 0; other < segments.length; other++)
                  if (other != alignedArtistIndex &&
                      other != index &&
                      !_isPresentationSegment(segments[other]))
                    segments[other],
              ].isNotEmpty;
              if (!hasOtherSubstantiveTitle) {
                preservedTitleIndex = index;
              }
              break;
            }
          }
        }
      }
      return [
        for (var index = 0; index < segments.length; index++)
          if (index == preservedTitleIndex ||
              !_isPresentationSegment(segments[index]))
            segments[index],
      ];
    }

    final strongSeparators = RegExp(
      r'\s*(?:\|+|//+)\s*|\s+(?:/|[-\u2013\u2014:：•·])\s+',
    ).allMatches(value).toList();
    if (strongSeparators.isNotEmpty) {
      return splitAtMatches(strongSeparators);
    }

    // A compact dash is ambiguous (blink-182 is not a split). Use it when an
    // adjacent side agrees with the known artist, or when it is the only dash;
    // the unsplit identity is still kept first if metadata cannot confirm it.
    final compactDashes = RegExp(r'[-\u2013\u2014]').allMatches(value).toList();
    RegExpMatch? selected;
    var bestArtistScore = 0.0;
    for (final dash in compactDashes) {
      final left = _cleanQueryText(value.substring(0, dash.start));
      final right = _cleanQueryText(value.substring(dash.end));
      if (left.isEmpty || right.isEmpty || artistHint.isEmpty) {
        continue;
      }
      final score = [
        _artistSimilarity(artistHint, left),
        _artistSimilarity(artistHint, right),
      ].reduce((best, value) => value > best ? value : best);
      if (score > bestArtistScore) {
        bestArtistScore = score;
        selected = dash;
      }
    }
    if (selected == null && compactDashes.length == 1) {
      selected = compactDashes.single;
    }
    if (selected == null ||
        (compactDashes.length > 1 && bestArtistScore < 0.72)) {
      return const [];
    }
    return splitAtMatches([selected]);
  }

  String _joinTitleSegments(Iterable<String> segments) {
    return segments
        .map(_trimEdgeSeparators)
        .where((part) => part.isNotEmpty)
        .join(' - ');
  }

  bool _looksLikeTitleContinuation(List<String> segments) {
    if (segments.length != 2) {
      return false;
    }
    final continuation = _normalizeText(segments.last);
    if (continuation.isEmpty) {
      return false;
    }
    return RegExp(
          r'^(?:part|parte|pt|vol|volume|chapter|capitulo|act|movement|'
          r'episode|episodio)\b',
        ).hasMatch(continuation) ||
        RegExp(r'^(?:[ivxlcdm]+|\d+)$').hasMatch(continuation) ||
        _versionTags(segments.last).isNotEmpty;
  }

  String _cleanArtist(String value) {
    final cleaned = _stripChannelSuffix(_cleanQueryText(value));
    final normalized = _normalizeText(cleaned);
    if (const {
      'unknown',
      'unknown artist',
      'desconocido',
      'artista desconocido',
      'n a',
      'na',
    }.contains(normalized)) {
      return '';
    }
    return cleaned;
  }

  String _stripChannelSuffix(String value) {
    var cleaned = value.trim();
    final patterns = <RegExp>[
      RegExp(r'\s*-\s*topic$', caseSensitive: false),
      RegExp(r'vevo$', caseSensitive: false),
      RegExp(r'\s+(?:official|oficial)$', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final stripped = cleaned.replaceFirst(pattern, '').trim();
      if (stripped.length >= 2) {
        cleaned = stripped;
      }
    }
    return cleaned;
  }

  String _cleanQueryText(String value) {
    var cleaned =
        _stripPresentationBlocks(_replaceDecorativeSymbolsWithSpaces(value))
            .replaceFirst(
              RegExp(
                r'\s*(?://+|\|)\s*(?:(?:official|oficial)\s+)?(?:music\s+)?(?:video|vídeo|audio|lyrics?|letra|visuali[sz]er|videolyric|video\s*lyric)\b.*$',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceFirst(
              RegExp(
                r'\s+[-\u2013\u2014]\s+(?:(?:(?:official|oficial)\s+)'
                r'(?:music\s+)?(?:video|vídeo|audio|lyrics?|letra)|'
                r'lyric\s+video|video\s+lyrics?|visuali[sz]er|videolyric)\b.*$',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceFirst(
              RegExp(
                r'\s+(?:(?:(?:official|oficial)\s+)(?:music\s+)?'
                r'(?:video|vídeo|audio|lyrics?|letra)|lyric\s+video|'
                r'video\s+lyrics?|visuali[sz]er|videolyric)\s*$',
                caseSensitive: false,
              ),
              ' ',
            )
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    cleaned = _truncateAtPresentationSegment(
      cleaned,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned
        .replaceAll(RegExp(r'^["“”«»]+'), '')
        .replaceAll(RegExp(r'["“”«»]+$'), '')
        .trim();
  }

  String _stripPresentationBlocks(String value) {
    return _stripEnclosedBlocks(
      value,
      shouldRemove: (content) =>
          content.isEmpty || _isPresentationSegment(content),
    );
  }

  String _withoutKaraokePresentation(String value) {
    // "Karaoke" can be the complete song title. Only enclosed labels and
    // explicitly official separated suffixes are safe discovery fallbacks.
    var cleaned = _stripEnclosedBlocks(
      value,
      shouldRemove: (content) =>
          content.isEmpty || _isKaraokePresentation(content),
    );
    final separators = RegExp(
      r'\s*(?:\|+|//+)\s*|\s+[-\u2013\u2014]\s+',
    ).allMatches(cleaned).toList(growable: false);
    for (final separator in separators.reversed) {
      final suffix = cleaned.substring(separator.end).trim();
      if (_isExplicitKaraokePresentationSuffix(suffix)) {
        cleaned = cleaned.substring(0, separator.start).trim();
        break;
      }
    }
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  bool _hasQualifiedKaraokePresentation(String value) {
    final stripped = _withoutKaraokePresentation(value);
    return stripped.isNotEmpty &&
        _normalizeText(stripped) != _normalizeText(value);
  }

  bool _hasBareEnclosedKaraoke(String value) {
    final matches = RegExp(
      r'\(([^()]*)\)|\[([^\[\]]*)\]|（([^（）]*)）|【([^【】]*)】|'
      r'「([^「」]*)」|『([^『』]*)』|《([^《》]*)》|〈([^〈〉]*)〉',
    ).allMatches(value);
    for (final match in matches) {
      final content = [
        for (var group = 1; group <= 8; group++) match.group(group),
      ].whereType<String>().first.trim();
      if (_normalizeText(content) == 'karaoke') {
        return true;
      }
    }
    return false;
  }

  String _stripEnclosedBlocks(
    String value, {
    required bool Function(String content) shouldRemove,
  }) {
    var cleaned = value;
    for (var pass = 0; pass < 4; pass++) {
      var changed = false;
      final next = cleaned.replaceAllMapped(
        RegExp(r'\(([^()]*)\)|\[([^\[\]]*)\]|（([^（）]*)）|【([^【】]*)】'),
        (match) {
          final content = [
            for (var group = 1; group <= 4; group++) match.group(group),
          ].whereType<String>().first.trim();
          if (!shouldRemove(content)) {
            return match.group(0)!;
          }
          changed = true;
          return ' ';
        },
      );
      cleaned = next;
      if (!changed) {
        break;
      }
    }
    return cleaned;
  }

  bool _isKaraokePresentation(String value) {
    final tokens = _normalizeText(
      value,
    ).split(' ').where((token) => token.isNotEmpty).toList(growable: false);
    if (!tokens.contains('karaoke')) {
      return false;
    }
    if (tokens.first == 'with' || tokens.first == 'con') {
      return false;
    }
    const allowedTokens = {
      'karaoke',
      'version',
      'track',
      'pista',
      'video',
      'lyric',
      'lyrics',
      'letra',
      'instrumental',
      'with',
      'con',
      'sing',
      'along',
      'official',
      'oficial',
      'music',
      'hd',
      'uhd',
      '4k',
      '8k',
      'guide',
      'melody',
      'guia',
    };
    return tokens.every(allowedTokens.contains);
  }

  bool _isExplicitKaraokePresentationSuffix(String value) {
    if (!_isKaraokePresentation(value)) {
      return false;
    }
    final tokens = _normalizeText(value).split(' ').toSet();
    return tokens.contains('official') || tokens.contains('oficial');
  }

  bool _isAmbiguousPresentationTitle(String value) {
    final normalized = _normalizeText(value);
    return const {
      'karaoke',
      'lyric',
      'lyrics',
      'letra',
      'letras',
    }.contains(normalized);
  }

  String _truncateAtPresentationSegment(String value) {
    final separators = RegExp(r'\s*(?:\|+|//+)\s*').allMatches(value).toList();
    for (var index = 0; index < separators.length; index++) {
      final separator = separators[index];
      final end = index + 1 < separators.length
          ? separators[index + 1].start
          : value.length;
      final segment = value.substring(separator.end, end);
      if (_isPresentationSegment(segment)) {
        return value.substring(0, separator.start).trim();
      }
    }
    return value;
  }

  bool _isPresentationSegment(String value) {
    final normalized = _normalizeText(value);
    if (normalized.isEmpty) {
      return false;
    }
    const labels = {
      'official',
      'oficial',
      'official video',
      'video official',
      'video oficial',
      'oficial video',
      'official music video',
      'official clip',
      'video musical oficial',
      'music video',
      'mv',
      'video',
      'audio',
      'official audio',
      'audio oficial',
      'lyric',
      'lyrics',
      'lyric video',
      'video lyric',
      'video lyrics',
      'letra',
      'letras',
      'videolyric',
      'visualizer',
      'visualiser',
      'hd',
      'uhd',
      '4k',
      '8k',
      '720p',
      '1080p',
      '2160p',
    };
    if (labels.contains(normalized)) {
      return true;
    }
    final tokens = normalized
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    const presentationTokens = {
      'official',
      'oficial',
      'music',
      'video',
      'audio',
      'lyric',
      'lyrics',
      'letra',
      'letras',
      'visualizer',
      'visualiser',
      'videolyric',
      'clip',
      'hd',
      'uhd',
      '4k',
      '8k',
      'subtitulado',
      'subtitulos',
      'espanol',
    };
    const presentationKinds = {
      'official',
      'oficial',
      'video',
      'audio',
      'lyric',
      'lyrics',
      'letra',
      'letras',
      'visualizer',
      'visualiser',
      'videolyric',
      'clip',
    };
    if (tokens.any(presentationKinds.contains) &&
        tokens.every(presentationTokens.contains)) {
      return true;
    }
    return labels.any(
      (label) =>
          normalized.startsWith('$label ') &&
          RegExp(
            r'\b(?:hd|uhd|4k|8k|subtitulado|subtitulos|espanol)\b',
          ).hasMatch(normalized),
    );
  }

  String _replaceDecorativeSymbolsWithSpaces(String value) {
    final buffer = StringBuffer();
    var needsSpace = false;
    for (final rune in value.runes) {
      if (_isDecorativeRune(rune) || _isVariationRune(rune)) {
        needsSpace = buffer.isNotEmpty;
        continue;
      }
      if (needsSpace) {
        buffer.write(' ');
        needsSpace = false;
      }
      buffer.writeCharCode(rune);
    }
    return buffer.toString();
  }

  String _trimEdgeSeparators(String value) {
    return value
        .replaceAll(RegExp(r'^[\s|,:;·•/\\]+'), '')
        .replaceAll(RegExp(r'[\s|,:;·•/\\]+$'), '')
        .trim();
  }

  bool _isLikelyChannelArtist(String value) {
    if (value.isEmpty) {
      return false;
    }
    final normalized = _normalizeText(value);
    if (RegExp(
          r'(?:^|\s)(?:topic|official|oficial|lyrics|letras|records|channel|canal|radio)$',
        ).hasMatch(normalized) ||
        RegExp(r'vevo$', caseSensitive: false).hasMatch(value.trim())) {
      return true;
    }
    return normalized.split(' ').length >= 2 && normalized.endsWith(' karaoke');
  }

  bool _isIgnoredComparisonRune(int rune) =>
      (rune >= 0x0300 && rune <= 0x036f) ||
      (rune >= 0x0591 && rune <= 0x05bd) ||
      rune == 0x05bf ||
      (rune >= 0x05c1 && rune <= 0x05c2) ||
      (rune >= 0x05c4 && rune <= 0x05c5) ||
      rune == 0x05c7 ||
      (rune >= 0x0610 && rune <= 0x061a) ||
      rune == 0x0640 ||
      (rune >= 0x064b && rune <= 0x065f) ||
      rune == 0x0670 ||
      (rune >= 0x06d6 && rune <= 0x06ed) ||
      (rune >= 0x1ab0 && rune <= 0x1aff) ||
      (rune >= 0x1dc0 && rune <= 0x1dff) ||
      (rune >= 0x20d0 && rune <= 0x20ff) ||
      (rune >= 0xfe20 && rune <= 0xfe2f);

  bool _isVariationRune(int rune) =>
      rune == 0x200d || rune == 0x20e3 || rune == 0xfe0e || rune == 0xfe0f;

  bool _isDecorativeRune(int rune) =>
      rune == 0x00a9 ||
      rune == 0x00ae ||
      rune == 0x2122 ||
      (rune >= 0x2300 && rune <= 0x23ff) ||
      (rune >= 0x2600 && rune <= 0x27ff) ||
      (rune >= 0x2b00 && rune <= 0x2bff) ||
      (rune >= 0x1f000 && rune <= 0x1faff);

  bool _isComparisonSeparator(int rune) {
    return _isDecorativeRune(rune) ||
        (rune >= 0x0021 && rune <= 0x002f) ||
        (rune >= 0x003a && rune <= 0x0040) ||
        (rune >= 0x005b && rune <= 0x0060) ||
        (rune >= 0x007b && rune <= 0x007e) ||
        (rune >= 0x00a0 && rune <= 0x00bf) ||
        (rune >= 0x2000 && rune <= 0x206f) ||
        (rune >= 0x2e00 && rune <= 0x2e7f) ||
        (rune >= 0xfe10 && rune <= 0xfe1f) ||
        (rune >= 0xfe30 && rune <= 0xfe4f) ||
        (rune >= 0xff01 && rune <= 0xff0f) ||
        (rune >= 0xff1a && rune <= 0xff20) ||
        (rune >= 0xff3b && rune <= 0xff40) ||
        (rune >= 0xff5b && rune <= 0xff65);
  }

  String _broadQuery(LrclibSearchIdentity identity) {
    return [
      if (identity.artist.isNotEmpty) identity.artist,
      identity.title,
    ].join(' ');
  }

  LrclibSearchIdentity _broadSearchIdentity(
    List<LrclibSearchIdentity> identities,
  ) {
    final withArtist = identities
        .where((identity) => identity.artist.isNotEmpty)
        .toList(growable: false);
    final candidates = withArtist.isEmpty ? identities : withArtist;
    var best = candidates.first;
    var bestTokenCount = _normalizeText(_broadQuery(best)).split(' ').length;
    for (final identity in candidates.skip(1)) {
      final tokenCount = _normalizeText(
        _broadQuery(identity),
      ).split(' ').length;
      if (tokenCount < bestTokenCount) {
        best = identity;
        bestTokenCount = tokenCount;
      }
    }
    return best;
  }

  Future<void>? _requestSlotWait(
    LrclibRequestBudget budget,
    LrclibRequestPacer pacer,
  ) {
    final wait = pacer.waitBeforeNextRequest;
    if (wait <= Duration.zero) {
      if (budget.isExpired) {
        throw LyricsConnectionException(
          TimeoutException('LRCLIB lookup exceeded its foreground budget.'),
        );
      }
      pacer.markRequestStarted();
      return null;
    }
    if (wait >= budget.remaining) {
      throw LyricsConnectionException(
        TimeoutException('LRCLIB lookup exceeded its foreground budget.'),
      );
    }
    return () async {
      await _delay(wait);
      if (budget.isExpired) {
        throw LyricsConnectionException(
          TimeoutException('LRCLIB lookup exceeded its foreground budget.'),
        );
      }
      pacer.markRequestStarted();
    }();
  }

  Future<LrclibResponse> _get(Uri uri, {Duration? timeout}) async {
    final now = _clock();
    final cooldown = _rateLimitedUntil;
    if (cooldown != null && cooldown.isAfter(now)) {
      throw LrclibRateLimitException(retryAfter: cooldown.difference(now));
    }

    final response = await _performGet(uri, timeout: timeout);
    if (response.statusCode != HttpStatus.tooManyRequests) {
      return response;
    }

    final retryAfter = _retryAfter(response);
    if (retryAfter != null) {
      _rateLimitedUntil = _clock().add(retryAfter);
    }
    // Never sleep through Retry-After on the lyrics screen. Keeping the
    // cooldown in memory respects LRCLIB without leaving the UI loading for a
    // minute; a later explicit retry can proceed once the window expires.
    throw LrclibRateLimitException(retryAfter: retryAfter);
  }

  Future<LrclibResponse> _performGet(Uri uri, {Duration? timeout}) async {
    final effectiveTimeout = timeout == null || timeout > _requestTimeout
        ? _requestTimeout
        : timeout;
    try {
      return await _transport
          .get(
            uri,
            headers: {'User-Agent': _userAgent, 'Accept': 'application/json'},
            timeout: effectiveTimeout,
          )
          .timeout(effectiveTimeout);
    } on SocketException catch (error) {
      throw LyricsConnectionException(error);
    } on TimeoutException catch (error) {
      throw LyricsConnectionException(error);
    } on FormatException catch (error) {
      throw LrclibFormatException(error.message);
    }
  }

  Duration? _retryAfter(LrclibResponse response) {
    final raw = response.header(HttpHeaders.retryAfterHeader)?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final seconds = int.tryParse(raw);
    if (seconds != null) {
      return Duration(seconds: seconds < 0 ? 0 : seconds);
    }
    try {
      final retryAt = HttpDate.parse(raw);
      final difference = retryAt.difference(_clock());
      return difference.isNegative ? Duration.zero : difference;
    } on FormatException {
      return null;
    }
  }

  Object? _decodeJson(LrclibResponse response) {
    try {
      return jsonDecode(response.body);
    } on FormatException catch (error) {
      throw LrclibFormatException('Invalid LRCLIB JSON: ${error.message}');
    }
  }

  LrclibRecord? _recordFromObject(Object? value) {
    if (value is! Map) {
      return null;
    }
    final record = LrclibRecord.fromJson(
      value.map((key, data) => MapEntry(key.toString(), data)),
    );
    if (record.trackName.isEmpty || record.artistName.isEmpty) {
      return null;
    }
    return record;
  }

  Uri _endpoint(String endpoint, Map<String, String> queryParameters) {
    final pathSegments = [
      ..._apiBaseUri.pathSegments.where((segment) => segment.isNotEmpty),
      endpoint,
    ];
    return _apiBaseUri.replace(
      pathSegments: pathSegments,
      queryParameters: queryParameters,
      fragment: '',
    );
  }

  String _cacheKey(LyricsLookup lookup) {
    return [
      _normalizeText(lookup.sourceId ?? ''),
      _normalizeText(lookup.title),
      _normalizeText(lookup.artist),
      _normalizeText(lookup.album ?? ''),
      lookup.duration?.inSeconds.toString() ?? '',
    ].join('|');
  }

  void _removeExpiredEntries(DateTime now) {
    _cache.removeWhere((_, entry) => entry.isExpired(now, _cacheTtl));
  }

  void _trimCache() {
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('LrclibLyricsService has been disposed.');
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _cache.clear();
    _transport.close();
  }
}

class _CacheEntry {
  _CacheEntry({required this.future, required this.createdAt});

  final Future<LyricsDocument?> future;
  final DateTime createdAt;
  bool completed = false;

  bool isExpired(DateTime now, Duration ttl) =>
      completed && now.difference(createdAt) >= ttl;
}
