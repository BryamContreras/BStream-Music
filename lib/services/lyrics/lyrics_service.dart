import '../../features/music/domain/entities/lyrics_candidate.dart';
import '../../features/music/domain/entities/lyrics_document.dart';
import '../../features/music/domain/entities/lyrics_lookup.dart';

export 'lrclib_lyrics_service.dart' show LrclibLyricsService;

abstract class LyricsService {
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup);

  /// Returns plausible alternatives for explicit user selection.
  ///
  /// Implementations must keep this online-only: the returned lyric documents
  /// may be retained briefly in memory, but are never persisted to storage.
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  });

  /// Searches online using a title explicitly entered by the listener.
  ///
  /// The manual title replaces only the title used for discovery. Artist,
  /// album and duration from [context] remain available to rank and validate
  /// results. Implementations may override this to provide a less restrictive
  /// manual-search policy than [findSimilarLyrics].
  Future<List<LyricsCandidate>> searchLyricsByTitle(
    String title, {
    required LyricsLookup context,
    int limit = 8,
  }) {
    final manualTitle = title.trim();
    if (manualTitle.isEmpty || limit <= 0) {
      return Future.value(const <LyricsCandidate>[]);
    }
    return findSimilarLyrics(
      LyricsLookup(
        title: manualTitle,
        artist: context.artist,
        duration: context.duration,
        album: context.album,
        sourceId: context.sourceId,
      ),
      limit: limit,
    );
  }

  void dispose();
}

/// The lyrics request could not reach the remote service.
class LyricsConnectionException implements Exception {
  const LyricsConnectionException([this.cause]);

  final Object? cause;

  @override
  String toString() => 'LyricsConnectionException: $cause';
}
