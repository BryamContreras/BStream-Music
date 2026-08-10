import 'package:bstream_music/core/utils/duration_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formats collection durations with seconds below one hour', () {
    expect(
      formatCollectionDuration(const Duration(minutes: 14, seconds: 37)),
      '14:37 min',
    );
  });

  test('formats collection durations as hours and minutes after one hour', () {
    expect(
      formatCollectionDuration(
        const Duration(hours: 1, minutes: 14, seconds: 37),
      ),
      '1 h 14 min',
    );
  });

  test('sums known durations and ignores unavailable values', () {
    expect(
      sumKnownDurations(const [
        Duration(minutes: 4, seconds: 23),
        null,
        Duration(minutes: 3, seconds: 24),
      ]),
      const Duration(minutes: 7, seconds: 47),
    );
    expect(sumKnownDurations(const <Duration?>[]), isNull);
  });
}
