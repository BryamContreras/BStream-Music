import '../../features/music/domain/entities/lyrics_document.dart';
import '../../features/music/domain/entities/lyrics_lookup.dart';

enum LyricsTimingQuality { none, uncertain, reliable, invalid }

/// A conservative timing check, not an estimate of how long vocals should last.
/// Intros, instrumental outros and short songs must not fail a coverage ratio.
LyricsTimingQuality lyricsTimingQuality(
  LyricsDocument document,
  LyricsLookup lookup,
) {
  final lines = document.lines.where((line) => line.text.trim().isNotEmpty);
  var count = 0;
  Duration? firstTime;
  var distinctTimes = false;
  final duration = lookup.duration ?? document.duration;
  for (final line in lines) {
    count++;
    if (line.timestamp.isNegative ||
        (duration != null &&
            line.timestamp > duration + const Duration(seconds: 8))) {
      return LyricsTimingQuality.invalid;
    }
    firstTime ??= line.timestamp;
    distinctTimes |= line.timestamp != firstTime;
  }
  if (count == 0) return LyricsTimingQuality.none;
  // A whole multi-verse response stamped 00:00 is plain text dressed as LRC.
  if (count > 1 && !distinctTimes && firstTime == Duration.zero) {
    return LyricsTimingQuality.invalid;
  }
  if (!distinctTimes || lyricsHaveUntimedVerses(document)) {
    return LyricsTimingQuality.uncertain;
  }
  return LyricsTimingQuality.reliable;
}

/// Some providers return full text but time only a subset of its verses.
/// Treat that as uncertain and let another provider supply full synchronization.
bool lyricsHaveUntimedVerses(LyricsDocument document) {
  final plain = document.plainLyrics;
  if (plain == null || plain.trim().isEmpty || document.lines.isEmpty) {
    return false;
  }
  final plainRows = plain.split('\n').where((line) => line.trim().isNotEmpty);
  final timedRows = document.lines.where((line) => line.text.trim().isNotEmpty);
  if (plainRows.length <= timedRows.length) return false;
  // Punctuation, whitespace and formatting differences are not missing verses.
  final plainText = _contentText(plain);
  final timedText = _contentText(timedRows.map((line) => line.text).join('\n'));
  return plainText.length > timedText.length + 16;
}

LyricsDocument lyricsWithoutTiming(LyricsDocument document) => LyricsDocument(
  provider: document.provider,
  providerId: document.providerId,
  trackName: document.trackName,
  artistName: document.artistName,
  albumName: document.albumName,
  duration: document.duration,
  plainLyrics: document.hasPlainLyrics
      ? document.plainLyrics
      : document.lines.map((line) => line.text).join('\n'),
);

/// Prefer a clearly fuller fallback over a fragment, not simply longer lyrics.
bool lyricsPlainFallbackIsFuller(
  LyricsDocument candidate,
  LyricsDocument current,
) {
  final currentText = current.plainLyrics?.trim() ?? '';
  final candidateText = candidate.plainLyrics?.trim() ?? '';
  final currentRows = currentText
      .split('\n')
      .where((row) => row.trim().isNotEmpty);
  final candidateRows = candidateText
      .split('\n')
      .where((row) => row.trim().isNotEmpty);
  return (currentRows.length <= 2 || _contentText(currentText).length < 80) &&
      candidateRows.length >= 4 &&
      _contentText(candidateText).length > _contentText(currentText).length * 2;
}

final _nonContent = RegExp(r'[^\p{L}\p{N}]', unicode: true);
String _contentText(String text) =>
    text.toLowerCase().replaceAll(_nonContent, '');
