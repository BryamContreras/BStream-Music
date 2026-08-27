import 'package:bstream_music/features/music/presentation/providers/mini_player_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('default mini player mode by platform', () {
    const expectations = <TargetPlatform, MiniPlayerMode>{
      TargetPlatform.android: MiniPlayerMode.capsule,
      TargetPlatform.linux: MiniPlayerMode.standard,
      TargetPlatform.windows: MiniPlayerMode.standard,
      TargetPlatform.macOS: MiniPlayerMode.standard,
    };

    for (final entry in expectations.entries) {
      test('${entry.key.name} defaults to ${entry.value.name}', () {
        expect(defaultMiniPlayerModeForPlatform(entry.key), entry.value);
        expect(MiniPlayerMode.fromCode(null, platform: entry.key), entry.value);
        expect(
          MiniPlayerMode.fromCode('unknown', platform: entry.key),
          entry.value,
        );
      });
    }
  });

  test('stored mini player modes override every platform default', () {
    for (final platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      expect(
        MiniPlayerMode.fromCode('default', platform: platform),
        MiniPlayerMode.standard,
      );
      expect(
        MiniPlayerMode.fromCode('capsule', platform: platform),
        MiniPlayerMode.capsule,
      );
    }
  });
}
