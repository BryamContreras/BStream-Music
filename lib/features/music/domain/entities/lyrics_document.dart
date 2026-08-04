import 'lyric_line.dart';

class LyricsDocument {
  const LyricsDocument({
    required this.provider,
    required this.trackName,
    required this.artistName,
    this.providerId,
    this.albumName,
    this.duration,
    this.instrumental = false,
    this.plainLyrics,
    this.syncedLyrics,
    this.lines = const [],
  });

  final String provider;
  final String? providerId;
  final String trackName;
  final String artistName;
  final String? albumName;
  final Duration? duration;
  final bool instrumental;
  final String? plainLyrics;
  final String? syncedLyrics;
  final List<LyricLine> lines;

  bool get hasSyncedLyrics => lines.isNotEmpty;

  bool get hasPlainLyrics => plainLyrics?.trim().isNotEmpty ?? false;

  bool get hasContent => instrumental || hasSyncedLyrics || hasPlainLyrics;
}
