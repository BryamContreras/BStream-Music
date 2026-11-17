import 'dart:math' as math;

import 'package:bstream_music/services/player/player_equalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'stored curves survive round trips and malformed data stays bounded',
    () {
      for (final preset in EqualizerPreset.values) {
        final settings = EqualizerSettings(
          enabled: true,
          gainsDb: preset.gainsDb,
        );
        expect(EqualizerSettings.fromMap(settings.toMap()), settings);
        expect(settings.preampDb, lessThanOrEqualTo(0));
        expect(settings.outputGain, inInclusiveRange(0, 1));
      }
      final malformed = EqualizerSettings.fromMap({
        'enabled': true,
        'gainsDb': [double.nan, double.infinity, -99, 99, 'bad'],
      });
      expect(malformed.gainsDb, [0, 0, -12, 12, 0]);
      expect(
        EqualizerSettings.fromMap({
          'gainsDb': [1],
        }).isFlat,
        isTrue,
      );
      expect(EqualizerSettings.fromMap(null).enabled, isFalse);
    },
  );

  test('native bands interpolate in logarithmic frequency', () {
    const settings = EqualizerSettings(gainsDb: [-6, 0, 6, 0, -6]);
    expect(settings.gainAtFrequency(10), -6);
    expect(settings.gainAtFrequency(230), 0);
    expect(settings.gainAtFrequency(math.sqrt(230 * 910)), closeTo(3, 1e-9));
    expect(settings.gainAtFrequency(24000), -6);
  });

  test('customizing a preset preserves source curve and reserves headroom', () {
    final preset = EqualizerSettings(
      enabled: true,
      gainsDb: EqualizerPreset.rock.gainsDb,
    );
    final custom = preset.withBand(1, 9);
    expect(preset.preset, EqualizerPreset.rock);
    expect(custom.preset, EqualizerPreset.custom);
    expect(custom.preampDb, -9);
    expect(custom.outputGain, closeTo(0.354813, .000001));
    expect(custom.copyWith(enabled: false).outputGain, 1);
    expect(
      custom.copyWith(gainsDb: EqualizerPreset.flat.gainsDb).preset,
      EqualizerPreset.flat,
    );
  });
}
