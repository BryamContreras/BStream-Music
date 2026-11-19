import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/player/player_equalizer.dart';

/// Export the actual app preset bank for native DSP benchmarks. Each line is
/// `presetName gain31Hz gain62Hz ... gain16kHz`, using decimal dB values. With
/// `--json`, export the frequency/preset object consumed by the Android runner.
///
/// Run from the project root:
/// dart run tool/benchmarks/export_equalizer_presets.dart [--json] [output-path]
void main(List<String> arguments) {
  final jsonOutput = arguments.contains('--json');
  final paths = arguments.where((argument) => argument != '--json').toList();
  if (paths.length > 1 ||
      paths.any((argument) => argument.startsWith('--')) ||
      arguments.where((argument) => argument == '--json').length > 1) {
    stderr.writeln(
      'Usage: export_equalizer_presets.dart [--json] [output-path]',
    );
    exitCode = 64;
    return;
  }
  final presets = {
    for (final preset in EqualizerPreset.values)
      if (preset != EqualizerPreset.custom) preset.name: preset.gainsDb,
  };
  final String output;
  if (jsonOutput) {
    final document = {
      'frequencies': equalizerBandFrequencies,
      'presets': presets,
    };
    output = '${const JsonEncoder.withIndent('  ').convert(document)}\n';
  } else {
    final bank = StringBuffer();
    for (final entry in presets.entries) {
      bank.writeln('${entry.key} ${entry.value.join(' ')}');
    }
    output = bank.toString();
  }
  if (paths.isEmpty) {
    stdout.write(output);
  } else {
    File(paths.single).writeAsStringSync(output);
  }
}
