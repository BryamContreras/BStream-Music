import '../../features/music/domain/entities/lyrics_candidate.dart';
import '../../features/music/domain/entities/lyrics_document.dart';
import '../../features/music/domain/entities/lyrics_lookup.dart';
import 'lyrics_document_quality.dart';
import 'lyrics_service.dart';

/// Tries enabled providers in priority order, never speculatively in parallel.
/// Plain/partially timed lyrics and instrumental flags do not stop a search for
/// full synchronization. Lower priorities are queried only when needed.
class FallbackLyricsService implements LyricsService {
  FallbackLyricsService({
    required Iterable<LyricsService> providers,
    this.disposeProviders = true,
  }) : _providers = List.unmodifiable(providers);

  final List<LyricsService> _providers;
  final bool disposeProviders;
  final _inFlight = <LyricsLookup, Future<LyricsDocument?>>{};
  bool _disposed = false;

  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) {
    _ensureActive();
    if (!lookup.isValid) {
      throw ArgumentError.value(lookup, 'lookup', 'Title must not be empty.');
    }
    final existing = _inFlight[lookup];
    if (existing != null) return existing;
    late final Future<LyricsDocument?> operation;
    operation = _findLyrics(lookup).whenComplete(() {
      if (identical(_inFlight[lookup], operation)) _inFlight.remove(lookup);
    });
    _inFlight[lookup] = operation;
    return operation;
  }

  Future<LyricsDocument?> _findLyrics(LyricsLookup lookup) async {
    LyricsDocument? instrumental;
    LyricsDocument? plain;
    LyricsDocument? uncertain;
    Object? firstError;
    StackTrace? firstStack;
    var receivedResponse = false;
    for (final provider in _providers) {
      _ensureActive();
      LyricsDocument? document;
      try {
        document = await provider.findLyrics(lookup);
        receivedResponse = true;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
      }
      _ensureActive();
      if (document == null) continue;
      if (document.instrumental) {
        instrumental ??= document;
        continue;
      }
      switch (lyricsTimingQuality(document, lookup)) {
        case LyricsTimingQuality.reliable:
          return document;
        case LyricsTimingQuality.uncertain:
          uncertain ??= document;
          // If text contains more verses than timestamps, keep all the text
          // rather than displaying only the synchronized fragment at the end.
          if (!lyricsHaveUntimedVerses(document)) continue;
          break;
        case LyricsTimingQuality.invalid:
        case LyricsTimingQuality.none:
          break;
      }
      final readable = document.hasSyncedLyrics
          ? lyricsWithoutTiming(document)
          : document;
      if (readable.hasPlainLyrics &&
          (plain == null || lyricsPlainFallbackIsFuller(readable, plain))) {
        plain = readable;
      }
    }
    if (plain != null) return plain;
    if (uncertain != null) return uncertain;
    if (instrumental != null) return instrumental;
    if (!receivedResponse && firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
    return null;
  }

  @override
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  }) => _findCandidates(
    (provider, remaining) =>
        provider.findSimilarLyrics(lookup, limit: remaining),
    limit: limit,
  );

  @override
  Future<List<LyricsCandidate>> searchLyricsByTitle(
    String title, {
    required LyricsLookup context,
    int limit = 8,
  }) {
    _ensureActive();
    if (title.trim().isEmpty) return Future.value(const []);
    return _findCandidates(
      (provider, remaining) => provider.searchLyricsByTitle(
        title,
        context: context,
        limit: remaining,
      ),
      limit: limit,
    );
  }

  Future<List<LyricsCandidate>> _findCandidates(
    Future<List<LyricsCandidate>> Function(LyricsService, int) search, {
    required int limit,
  }) async {
    _ensureActive();
    if (limit <= 0) return const [];
    final candidates = <LyricsCandidate>[];
    final seen = <String>{};
    Object? firstError;
    StackTrace? firstStack;
    var receivedResponse = false;
    for (final provider in _providers) {
      _ensureActive();
      List<LyricsCandidate> results;
      try {
        results = await search(provider, limit - candidates.length);
        receivedResponse = true;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStack ??= stackTrace;
        _ensureActive();
        continue;
      }
      _ensureActive();
      for (final candidate in results) {
        final document = candidate.document;
        if (document.instrumental ||
            (!document.hasSyncedLyrics && !document.hasPlainLyrics)) {
          continue;
        }
        final identity = [
          document.provider,
          document.providerId ?? document.trackName,
          document.artistName,
          document.duration?.inMilliseconds ?? '',
        ].join('\u0000');
        if (!seen.add(identity)) continue;
        candidates.add(candidate);
        if (candidates.length == limit) return List.unmodifiable(candidates);
      }
    }
    if (candidates.isEmpty && !receivedResponse && firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
    return List.unmodifiable(candidates);
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('The lyrics provider selection was closed.');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _inFlight.clear();
    if (disposeProviders) {
      for (final provider in _providers.toSet()) {
        provider.dispose();
      }
    }
  }
}
