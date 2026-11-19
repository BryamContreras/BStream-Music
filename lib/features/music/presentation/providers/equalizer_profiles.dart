import 'package:flutter/foundation.dart';

import '../../../../services/player/player_equalizer.dart';

typedef EqualizerProfileChange = ({
  EqualizerSettings equalizer,
  EqualizerProfiles profiles,
});

/// Preset selection and the saved manual curve belong to preferences, not DSP.
/// Native engines continue receiving only the active ten-band curve.
@immutable
class EqualizerProfiles {
  const EqualizerProfiles({this.customCurve, this.selectedPreset});

  final EqualizerSettings? customCurve;
  final EqualizerPreset? selectedPreset;

  EqualizerPreset selectedFor(EqualizerSettings active) =>
      selectedPreset ?? active.preset;

  EqualizerProfiles remember(EqualizerSettings active) => EqualizerProfiles(
    customCurve: active.copyWith(enabled: false),
    selectedPreset: EqualizerPreset.custom,
  );

  EqualizerProfileChange withBand(
    EqualizerSettings active,
    int index,
    double gain,
  ) {
    final next = active.withBand(index, gain);
    return (equalizer: next, profiles: remember(next));
  }

  EqualizerProfileChange choose(
    EqualizerSettings active,
    EqualizerPreset preset,
  ) {
    final saved =
        customCurve ??
        (active.preset == EqualizerPreset.custom
            ? active.copyWith(enabled: false)
            : const EqualizerSettings());
    return (
      equalizer: active.copyWith(
        enabled: true,
        gainsDb: preset == EqualizerPreset.custom
            ? saved.gainsDb
            : preset.gainsDb,
      ),
      profiles: EqualizerProfiles(customCurve: saved, selectedPreset: preset),
    );
  }

  EqualizerProfiles updating(
    EqualizerSettings previous,
    EqualizerSettings next,
  ) {
    if (listEquals(previous.gainsDb, next.gainsDb)) return this;
    return next.preset == EqualizerPreset.custom
        ? remember(next)
        : choose(previous, next.preset).profiles;
  }

  Map<String, Object> toMap() => {
    if (customCurve != null) 'customGainsDb': customCurve!.normalized.gainsDb,
    if (selectedPreset != null) 'selectedPreset': selectedPreset!.name,
  };

  static EqualizerProfiles fromMap(Object? value, EqualizerSettings active) {
    EqualizerSettings? custom;
    EqualizerPreset? selected;
    if (value is Map) {
      final gains = value['customGainsDb'];
      if (gains is List &&
          (gains.length == equalizerBandFrequencies.length ||
              gains.length == 5)) {
        // Reuse the active-curve codec, including its legacy five-band migration.
        custom = EqualizerSettings.fromMap({'gainsDb': gains});
      }
      for (final preset in EqualizerPreset.values) {
        if (preset.name == value['selectedPreset']) selected = preset;
      }
    }
    custom ??= active.preset == EqualizerPreset.custom
        ? active.copyWith(enabled: false)
        : null;
    if (selected == EqualizerPreset.custom) {
      if (custom == null || !listEquals(custom.gainsDb, active.gainsDb)) {
        selected = null;
      }
    } else if (selected != active.preset) {
      selected = null;
    }
    return EqualizerProfiles(customCurve: custom, selectedPreset: selected);
  }

  @override
  bool operator ==(Object other) =>
      other is EqualizerProfiles &&
      other.customCurve == customCurve &&
      other.selectedPreset == selectedPreset;

  @override
  int get hashCode => Object.hash(customCurve, selectedPreset);
}
