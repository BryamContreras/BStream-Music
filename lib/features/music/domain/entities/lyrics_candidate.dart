import 'lyrics_document.dart';

/// A possible LRCLIB match that still needs confirmation from the listener.
///
/// The complete document stays in memory so choosing a result never requires
/// writing lyrics to local storage or making another network request.
class LyricsCandidate {
  const LyricsCandidate({required this.document, required this.similarity});

  final LyricsDocument document;
  final double similarity;

  String get trackName => document.trackName;

  String get artistName => document.artistName;

  Duration? get duration => document.duration;

  bool get isSynced => document.hasSyncedLyrics;
}
