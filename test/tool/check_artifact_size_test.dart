import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_artifact_size.dart' as artifact_size;

void main() {
  group('parseSizeBudgetMiB', () {
    test('accepts a positive finite budget', () {
      expect(artifact_size.parseSizeBudgetMiB('55'), 55);
      expect(artifact_size.parseSizeBudgetMiB('0.25'), 0.25);
    });

    test('rejects NaN and infinity', () {
      expect(artifact_size.parseSizeBudgetMiB('NaN'), isNull);
      expect(artifact_size.parseSizeBudgetMiB('Infinity'), isNull);
      expect(artifact_size.parseSizeBudgetMiB('-Infinity'), isNull);
    });

    test('rejects non-positive and malformed budgets', () {
      expect(artifact_size.parseSizeBudgetMiB('0'), isNull);
      expect(artifact_size.parseSizeBudgetMiB('-1'), isNull);
      expect(artifact_size.parseSizeBudgetMiB('not-a-number'), isNull);
    });
  });
}
