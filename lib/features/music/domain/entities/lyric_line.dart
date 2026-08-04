class LyricLine {
  const LyricLine({required this.timestamp, required this.text});

  final Duration timestamp;
  final String text;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is LyricLine &&
            runtimeType == other.runtimeType &&
            timestamp == other.timestamp &&
            text == other.text;
  }

  @override
  int get hashCode => Object.hash(timestamp, text);

  @override
  String toString() => 'LyricLine($timestamp, $text)';
}
