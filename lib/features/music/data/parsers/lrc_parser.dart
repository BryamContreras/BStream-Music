import '../../domain/entities/lyric_line.dart';

class LrcParser {
  const LrcParser();

  List<LyricLine> parse(String? source) {
    if (source == null || source.trim().isEmpty) {
      return const [];
    }

    final normalized = source
        .replaceFirst('\uFEFF', '')
        .replaceAll('\r\n', '\n');
    final rows = normalized.split('\n');
    final offset = _globalOffset(rows);
    final parsed = <_IndexedLyricLine>[];
    var sourceIndex = 0;

    for (final row in rows) {
      final leadingTags = _leadingTags.firstMatch(row);
      if (leadingTags == null) {
        continue;
      }

      final tags = _tag.allMatches(leadingTags.group(1)!);
      final timestamps = <Duration>[];
      for (final tag in tags) {
        final timestamp = _parseTimestamp(tag.group(1)!);
        if (timestamp != null) {
          timestamps.add(timestamp);
        }
      }
      if (timestamps.isEmpty) {
        continue;
      }

      final text = leadingTags.group(2)!.trim();
      for (final timestamp in timestamps) {
        final shiftedMilliseconds = timestamp.inMilliseconds + offset;
        parsed.add(
          _IndexedLyricLine(
            line: LyricLine(
              timestamp: Duration(
                milliseconds: shiftedMilliseconds < 0 ? 0 : shiftedMilliseconds,
              ),
              text: text,
            ),
            sourceIndex: sourceIndex++,
          ),
        );
      }
    }

    parsed.sort((left, right) {
      final byTimestamp = left.line.timestamp.compareTo(right.line.timestamp);
      return byTimestamp != 0
          ? byTimestamp
          : left.sourceIndex.compareTo(right.sourceIndex);
    });
    return List.unmodifiable(parsed.map((entry) => entry.line));
  }

  int _globalOffset(List<String> rows) {
    var offset = 0;
    for (final row in rows) {
      for (final match in _offset.allMatches(row)) {
        offset = int.tryParse(match.group(1)!) ?? offset;
      }
    }
    return offset;
  }

  Duration? _parseTimestamp(String rawTag) {
    final tag = rawTag.trim();
    final parts = tag.split(':');
    if (parts.length != 2 && parts.length != 3) {
      return null;
    }

    final hasHours = parts.length == 3;
    final hours = hasHours ? int.tryParse(parts[0]) : 0;
    final minutes = int.tryParse(parts[hasHours ? 1 : 0]);
    final secondParts = parts.last.split(RegExp(r'[\.,]'));
    if (secondParts.length > 2) {
      return null;
    }
    final seconds = int.tryParse(secondParts.first);
    final milliseconds = secondParts.length == 1
        ? 0
        : _fractionMilliseconds(secondParts.last);

    if (hours == null ||
        minutes == null ||
        seconds == null ||
        hours < 0 ||
        minutes < 0 ||
        seconds < 0 ||
        seconds >= 60 ||
        (hasHours && minutes >= 60) ||
        milliseconds == null) {
      return null;
    }

    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: milliseconds,
    );
  }

  int? _fractionMilliseconds(String fraction) {
    if (fraction.isEmpty || fraction.length > 3) {
      return null;
    }
    final value = int.tryParse(fraction);
    if (value == null) {
      return null;
    }
    return switch (fraction.length) {
      1 => value * 100,
      2 => value * 10,
      _ => value,
    };
  }

  static final _leadingTags = RegExp(r'^\s*((?:\[[^\]]*\]\s*)+)(.*)$');
  static final _tag = RegExp(r'\[([^\]]*)\]');
  static final _offset = RegExp(
    r'\[\s*offset\s*:\s*([+-]?\d+)\s*\]',
    caseSensitive: false,
  );
}

class _IndexedLyricLine {
  const _IndexedLyricLine({required this.line, required this.sourceIndex});

  final LyricLine line;
  final int sourceIndex;
}
