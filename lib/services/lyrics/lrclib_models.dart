import '../../features/music/data/parsers/lrc_parser.dart';
import '../../features/music/domain/entities/lyrics_document.dart';

class LrclibRecord {
  const LrclibRecord({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.instrumental,
    this.albumName,
    this.duration,
    this.plainLyrics,
    this.syncedLyrics,
  });

  factory LrclibRecord.fromJson(Map<String, dynamic> json) {
    return LrclibRecord(
      id: _string(json['id']),
      trackName: _string(json['trackName']) ?? _string(json['name']) ?? '',
      artistName: _string(json['artistName']) ?? '',
      albumName: _string(json['albumName']),
      duration: _duration(json['duration']),
      instrumental: json['instrumental'] == true,
      plainLyrics: _string(json['plainLyrics']),
      syncedLyrics: _string(json['syncedLyrics']),
    );
  }

  final String? id;
  final String trackName;
  final String artistName;
  final String? albumName;
  final Duration? duration;
  final bool instrumental;
  final String? plainLyrics;
  final String? syncedLyrics;

  bool get hasSyncedLyrics => syncedLyrics?.trim().isNotEmpty ?? false;

  LyricsDocument toDocument(LrcParser parser) {
    return LyricsDocument(
      provider: 'LRCLIB',
      providerId: id,
      trackName: trackName,
      artistName: artistName,
      albumName: albumName,
      duration: duration,
      instrumental: instrumental,
      plainLyrics: plainLyrics,
      syncedLyrics: syncedLyrics,
      lines: List.unmodifiable(parser.parse(syncedLyrics)),
    );
  }

  static String? _string(Object? value) {
    if (value == null) {
      return null;
    }
    final normalized = value.toString().trim();
    return normalized.isEmpty ? null : normalized;
  }

  static Duration? _duration(Object? value) {
    final seconds = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (seconds == null || !seconds.isFinite || seconds <= 0) {
      return null;
    }
    return Duration(milliseconds: (seconds * 1000).round());
  }
}

class LrclibScoredRecord {
  const LrclibScoredRecord({required this.record, required this.score});

  final LrclibRecord record;
  final double score;

  // LRCLIB often keeps a plain exact mirror alongside a synchronized upload
  // whose title includes the artist (for example, "Artist - Title"). Prefer
  // the synchronized record when the match is still close, instead of
  // discarding timing merely because one title is a few tokens shorter.
  static const _syncedPreferenceTolerance = 0.14;

  bool isBetterThan(LrclibScoredRecord other) {
    final difference = score - other.score;
    if (record.hasSyncedLyrics != other.record.hasSyncedLyrics) {
      if (record.hasSyncedLyrics) {
        return difference >= -_syncedPreferenceTolerance;
      }
      return difference > _syncedPreferenceTolerance;
    }
    if (difference.abs() > 0.0001) {
      return difference > 0;
    }
    return record.hasSyncedLyrics && !other.record.hasSyncedLyrics;
  }
}

class LrclibSearchIdentity {
  const LrclibSearchIdentity({required this.title, required this.artist});

  final String title;
  final String artist;
}

class LrclibDecoratedIdentity {
  const LrclibDecoratedIdentity({
    required this.title,
    required this.primaryArtist,
    required this.allArtists,
  });

  final String title;
  final String primaryArtist;
  final String allArtists;
}

String? meaningfulLrclibMetadata(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  final comparable = normalized
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  if (const {
    'unknown',
    'unknown album',
    'desconocido',
    'album desconocido',
    'n a',
    'na',
  }.contains(comparable)) {
    return null;
  }
  return normalized;
}
