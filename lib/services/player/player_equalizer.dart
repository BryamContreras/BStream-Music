import 'dart:math' as math;

import 'package:just_audio/bstream_equalizer_tuning.dart';

/// Shared tuning; native engines process samples on their own audio threads.
const equalizerBandFrequencies = bstreamEqualizerFrequencies;
const _legacyBandFrequencies = <double>[60, 230, 910, 3600, 14000];
const _flatGains = <double>[0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
const equalizerMinGainDb = -12.0;
const equalizerMaxGainDb = 12.0;

enum EqualizerPreset {
  flat,
  acoustic,
  bassBoost,
  bassCut,
  vocal,
  trebleBoost,
  trebleCut,
  loudness,
  spokenWord,
  electronic,
  rock,
  hipHop,
  jazz,
  classical,
  smallSpeakers,
  lateNight,
  custom;

  /// BStream curves tuned explicitly for the ten octave-spaced controls.
  /// These immutable starting points describe tonal balance, not a speaker
  /// correction or a loudness compressor. Saved custom curves stay unchanged.
  List<double> get gainsDb => switch (this) {
    flat || custom => _flatGains,
    acoustic => const [1, 1.5, 1, 0, -0.5, 0.5, 1.5, 2, 1.5, 0.5],
    bassBoost => const [4, 5, 3, 1, 0, 0, 0, 0, 0, 0],
    bassCut => const [-5, -4, -3, -1, 0, 0, 0, 0, 0, 0],
    vocal => const [-3, -2, -1, 0, 1, 2.5, 3, 1.5, 0, -1],
    trebleBoost => const [0, 0, 0, 0, 0, 0, 0.5, 1.5, 3, 4],
    trebleCut => const [0, 0, 0, 0, 0, 0, -0.5, -1.5, -3, -4],
    loudness => const [3, 3, 1.5, 0, -1, -1, 0, 1, 2, 2.5],
    spokenWord => const [-5, -4, -2, -0.5, 1, 2, 3, 1.5, -1, -2],
    electronic => const [4, 3, 1, -0.5, -1, 0, 1, 1.5, 2.5, 2],
    rock => const [3, 2, 1, 0, -1, -0.5, 1, 2, 2.5, 1.5],
    hipHop => const [4, 4, 2.5, 1, -1, -0.5, 0, 1, 1.5, 1],
    jazz => const [1.5, 1, 0.5, 0, -0.5, 0.5, 1, 1.5, 2, 1],
    classical => const [1.5, 1, 0.5, 0, 0, 0, 0.5, 1, 1.5, 1.5],
    smallSpeakers => const [-5, -3, 0, 2, 1.5, 0.5, 0.5, 0, -0.5, -1],
    lateNight => const [-2, -1, 0, 0.5, 1, 1.5, 1, 0.5, -1, -2],
  };
}

/// Preserve the previous curve on a logarithmic frequency axis rather than
/// assigning its five saved gains to five unrelated new center frequencies.
List<double> _resampleLegacyCurve(List<double> values) => List.unmodifiable([
  for (final frequency in equalizerBandFrequencies)
    _gainAtFrequency(frequency, _legacyBandFrequencies, values),
]);

double _gainAtFrequency(
  double hz,
  List<double> frequencies,
  List<double> values,
) {
  if (!hz.isFinite || hz <= frequencies.first) return values.first;
  for (var i = 1; i < frequencies.length; i++) {
    if (hz <= frequencies[i]) {
      final start = math.log(frequencies[i - 1]);
      final end = math.log(frequencies[i]);
      final t = (math.log(hz) - start) / (end - start);
      return values[i - 1] + (values[i] - values[i - 1]) * t;
    }
  }
  return values.last;
}

class EqualizerSettings {
  const EqualizerSettings({this.enabled = false, this.gainsDb = _flatGains});

  final bool enabled;
  final List<double> gainsDb;

  EqualizerSettings get normalized => copyWith();

  EqualizerSettings copyWith({bool? enabled, List<double>? gainsDb}) {
    final values = gainsDb ?? this.gainsDb;
    return EqualizerSettings(
      enabled: enabled ?? this.enabled,
      gainsDb: List<double>.unmodifiable(
        List<double>.generate(equalizerBandFrequencies.length, (index) {
          final value = index < values.length ? values[index] : 0.0;
          return value.isFinite
              ? value.clamp(equalizerMinGainDb, equalizerMaxGainDb)
              : 0.0;
        }),
      ),
    );
  }

  EqualizerSettings withBand(int index, double gain) {
    RangeError.checkValidIndex(index, equalizerBandFrequencies);
    final values = List<double>.of(normalized.gainsDb)..[index] = gain;
    return copyWith(gainsDb: values);
  }

  EqualizerPreset get preset {
    final values = normalized.gainsDb;
    for (final preset in EqualizerPreset.values) {
      if (preset == EqualizerPreset.custom) continue;
      final candidate = preset.gainsDb;
      var matches = true;
      for (var i = 0; i < values.length; i++) {
        if ((values[i] - candidate[i]).abs() >= 0.05) {
          matches = false;
          break;
        }
      }
      if (matches) return preset;
    }
    return EqualizerPreset.custom;
  }

  bool get isFlat => normalized.gainsDb.every((v) => v.abs() < 0.01);

  /// Reserved headroom for the combined response of boosted bands.
  double get preampDb => bstreamEqualizerPreampDb(normalized.gainsDb);

  double get outputGain => enabled ? math.pow(10, preampDb / 20).toDouble() : 1;

  /// Adapt the curve to a platform's actual native band centers.
  double gainAtFrequency(double hz) {
    return _gainAtFrequency(hz, equalizerBandFrequencies, normalized.gainsDb);
  }

  Map<String, Object> toMap() => {
    'enabled': enabled,
    'gainsDb': normalized.gainsDb,
  };

  static EqualizerSettings fromMap(Object? value) {
    if (value is! Map) return const EqualizerSettings();
    final raw = value['gainsDb'];
    final List<double> gains;
    if (raw is List &&
        (raw.length == equalizerBandFrequencies.length ||
            raw.length == _legacyBandFrequencies.length)) {
      final bounded = raw.map((v) {
        final gain = v is num ? v.toDouble() : 0.0;
        return gain.isFinite
            ? gain.clamp(equalizerMinGainDb, equalizerMaxGainDb)
            : 0.0;
      }).toList();
      gains = raw.length == _legacyBandFrequencies.length
          ? _resampleLegacyCurve(bounded)
          : bounded;
    } else {
      gains = _flatGains;
    }
    return EqualizerSettings(
      enabled: value['enabled'] == true,
      gainsDb: gains,
    ).normalized;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! EqualizerSettings ||
        other.enabled != enabled ||
        other.gainsDb.length != gainsDb.length) {
      return false;
    }
    for (var i = 0; i < gainsDb.length; i++) {
      if (gainsDb[i] != other.gainsDb[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll(gainsDb));
}

abstract interface class EqualizerCapablePlayer {
  bool get supportsEqualizer;
  Future<void> configureEqualizer(EqualizerSettings settings);
}
