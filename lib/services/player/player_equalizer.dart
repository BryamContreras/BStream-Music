import 'dart:math' as math;

/// Shared tuning; native engines process samples on their own audio threads.
const equalizerBandFrequencies = <double>[60, 230, 910, 3600, 14000];
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

  /// Five-band starting curves inspired by BitChord's preset categories.
  /// The native implementation and band mapping are owned by BStream.
  List<double> get gainsDb => switch (this) {
    flat || custom => const [0, 0, 0, 0, 0],
    acoustic => const [3, 1, 1.5, 2.5, 1],
    bassBoost => const [6, 3, 0, 0, 0],
    bassCut => const [-6, -3, 0, 0, 0],
    vocal => const [-3, 0, 3.5, 2, -1],
    trebleBoost => const [0, 0, 0, 2.5, 5],
    trebleCut => const [0, 0, 0, -2.5, -5],
    loudness => const [6, 2, -1.5, 0.5, 5],
    spokenWord => const [-5, 0, 4, 2.5, -2],
    electronic => const [5, 1.5, 0, 2, 4],
    rock => const [4, 1, -1.5, 2, 3.5],
    hipHop => const [6, 2, -1, 1.5, 2.5],
    jazz => const [3, 1, 1, 1.5, 2.5],
    classical => const [3, 1, 0, 1.5, 3],
    smallSpeakers => const [5, 3, 0.5, -0.5, -2],
    lateNight => const [3, 0.5, 1.5, 0, -3],
  };
}

class EqualizerSettings {
  const EqualizerSettings({
    this.enabled = false,
    this.gainsDb = const [0, 0, 0, 0, 0],
  });

  final bool enabled;
  final List<double> gainsDb;

  EqualizerSettings get normalized => copyWith();

  EqualizerSettings copyWith({bool? enabled, List<double>? gainsDb}) {
    final values = gainsDb ?? this.gainsDb;
    return EqualizerSettings(
      enabled: enabled ?? this.enabled,
      gainsDb: List<double>.unmodifiable(
        List<double>.generate(5, (index) {
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
      if (List<bool>.generate(
        5,
        (i) => (values[i] - preset.gainsDb[i]).abs() < 0.05,
      ).every((v) => v)) {
        return preset;
      }
    }
    return EqualizerPreset.custom;
  }

  bool get isFlat => normalized.gainsDb.every((v) => v.abs() < 0.01);

  /// Reserved headroom for the strongest boosted band.
  double get preampDb {
    final boost = normalized.gainsDb.fold<double>(0, math.max);
    return boost > 0 ? -boost : 0;
  }

  double get outputGain => enabled ? math.pow(10, preampDb / 20).toDouble() : 1;

  /// Adapt the curve to a platform's actual native band centers.
  double gainAtFrequency(double hz) {
    final values = normalized.gainsDb;
    if (!hz.isFinite || hz <= equalizerBandFrequencies.first) {
      return values.first;
    }
    for (var i = 1; i < equalizerBandFrequencies.length; i++) {
      if (hz <= equalizerBandFrequencies[i]) {
        final start = math.log(equalizerBandFrequencies[i - 1]);
        final end = math.log(equalizerBandFrequencies[i]);
        final t = (math.log(hz) - start) / (end - start);
        return values[i - 1] + (values[i] - values[i - 1]) * t;
      }
    }
    return values.last;
  }

  Map<String, Object> toMap() => {
    'enabled': enabled,
    'gainsDb': normalized.gainsDb,
  };

  static EqualizerSettings fromMap(Object? value) {
    if (value is! Map) return const EqualizerSettings();
    final raw = value['gainsDb'];
    final gains = raw is List && raw.length == 5
        ? raw.map((v) => v is num ? v.toDouble() : 0.0).toList()
        : const <double>[0, 0, 0, 0, 0];
    return EqualizerSettings(
      enabled: value['enabled'] == true,
      gainsDb: gains,
    ).normalized;
  }

  @override
  bool operator ==(Object other) =>
      other is EqualizerSettings &&
      other.enabled == enabled &&
      other.gainsDb.length == gainsDb.length &&
      List<bool>.generate(
        gainsDb.length,
        (i) => gainsDb[i] == other.gainsDb[i],
      ).every((v) => v);

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll(gainsDb));
}

abstract interface class EqualizerCapablePlayer {
  bool get supportsEqualizer;
  Future<void> configureEqualizer(EqualizerSettings settings);
}
