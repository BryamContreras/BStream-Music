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
        'gainsDb': [double.nan, double.infinity, -99, 99, 'bad', 0, 0, 0, 0, 0],
      });
      expect(malformed.gainsDb, [0, 0, -12, 12, 0, 0, 0, 0, 0, 0]);
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
    const settings = EqualizerSettings(
      gainsDb: [-6, 0, 6, 0, -6, 0, 0, 0, 0, -6],
    );
    expect(settings.gainAtFrequency(10), -6);
    expect(settings.gainAtFrequency(62), 0);
    expect(settings.gainAtFrequency(math.sqrt(62 * 125)), closeTo(3, 1e-9));
    expect(settings.gainAtFrequency(24000), -6);
  });

  test('five-band preferences migrate without replacing the saved curve', () {
    final migrated = EqualizerSettings.fromMap({
      'enabled': true,
      'gainsDb': [-6, 0, 6, 0, -6],
    });
    expect(migrated.enabled, isTrue);
    expect(migrated.gainsDb, hasLength(10));
    expect(migrated.gainsDb.first, -6);
    expect(migrated.gainsDb.last, -6);
    // 500 Hz sits between the old 230 Hz and 910 Hz controls.
    final t = math.log(500 / 230) / math.log(910 / 230);
    expect(migrated.gainsDb[4], closeTo(6 * t, 1e-9));
    expect(EqualizerSettings.fromMap(migrated.toMap()), migrated);
    for (final enabled in [true, false]) {
      final oldRock = EqualizerSettings.fromMap({
        'enabled': enabled,
        'gainsDb': [4, 1, -1.5, 2, 3.5],
      });
      expect(oldRock.enabled, enabled);
      expect(oldRock.preset, EqualizerPreset.custom);
      expect(oldRock.gainsDb.first, 4);
      expect(oldRock.gainsDb.last, 3.5);
      expect(oldRock.gainsDb, isNot(EqualizerPreset.rock.gainsDb));
      expect(EqualizerSettings.fromMap(oldRock.toMap()), oldRock);
    }
    final sanitized = EqualizerSettings.fromMap({
      'gainsDb': [double.nan, double.infinity, -99, 99, 'bad'],
    });
    expect(sanitized.gainsDb, hasLength(10));
    expect(
      sanitized.gainsDb.every((g) => g.isFinite && g >= -12 && g <= 12),
      isTrue,
    );
  });

  test('presets are distinct ten-band curves with half-dB manual steps', () {
    final seen = <String>{};
    for (final preset in EqualizerPreset.values) {
      final gains = preset.gainsDb;
      expect(gains, hasLength(equalizerBandFrequencies.length));
      expect(identical(gains, preset.gainsDb), isTrue);
      expect(() => gains[0] = 99, throwsUnsupportedError);
      for (final gain in gains) {
        expect(gain, inInclusiveRange(-6, 6));
        expect(gain * 2, (gain * 2).roundToDouble());
      }
      if (preset == EqualizerPreset.custom) continue;
      expect(seen.add(gains.join(',')), isTrue, reason: preset.name);
      expect(EqualizerSettings(gainsDb: gains).preset, preset);
    }
    expect(
      EqualizerPreset.smallSpeakers.gainsDb.take(2),
      everyElement(lessThan(0)),
    );
    expect(
      EqualizerPreset.vocal.gainsDb[6],
      greaterThan(EqualizerPreset.vocal.gainsDb[1]),
    );
  });

  test('customizing a preset preserves source curve and reserves headroom', () {
    final preset = EqualizerSettings(
      enabled: true,
      gainsDb: EqualizerPreset.rock.gainsDb,
    );
    final custom = preset.withBand(1, 9);
    expect(preset.preset, EqualizerPreset.rock);
    expect(custom.preset, EqualizerPreset.custom);
    expect(custom.preampDb, lessThan(-9));
    expect(
      custom.outputGain,
      closeTo(math.pow(10, custom.preampDb / 20), .000001),
    );
    expect(custom.copyWith(enabled: false).outputGain, 1);
    expect(
      custom.copyWith(gainsDb: EqualizerPreset.flat.gainsDb).preset,
      EqualizerPreset.flat,
    );
  });

  test(
    'headroom accounts for adjacent boosts and bypass keeps user volume',
    () {
      const single = EqualizerSettings(
        enabled: true,
        gainsDb: [0, 6, 0, 0, 0, 0, 0, 0, 0, 0],
      );
      const adjacent = EqualizerSettings(
        enabled: true,
        gainsDb: [6, 6, 0, 0, 0, 0, 0, 0, 0, 0],
      );
      const full = EqualizerSettings(
        enabled: true,
        gainsDb: [12, 12, 12, 12, 12, 12, 12, 12, 12, 12],
      );
      expect(single.preampDb, -6);
      expect(adjacent.preampDb, lessThan(-8));
      expect(
        const EqualizerSettings(
          gainsDb: [0, 0, 0, 0, 6, 6, 0, 0, 0, 0],
        ).preampDb,
        closeTo(-8.204714309118318, 1e-9),
      );
      expect(
        const EqualizerSettings(
          gainsDb: [6, 6, 6, 6, 6, 6, 6, 6, 6, 6],
        ).preampDb,
        closeTo(-10.977777129356811, 1e-9),
      );
      expect(full.preampDb, lessThan(-22));
      expect(full.preampDb, greaterThan(-24));
      expect(adjacent.copyWith(enabled: false).outputGain, 1);
      expect(const EqualizerSettings(enabled: true).outputGain, 1);
      expect(adjacent.withBand(2, -12).preampDb, adjacent.preampDb);
      expect(adjacent.preampDb, adjacent.copyWith().preampDb);
    },
  );
}
