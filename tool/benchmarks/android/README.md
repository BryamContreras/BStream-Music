# Android equalizer benchmark

This harness executes the **production** `BStreamEqualizerAudioProcessor` and
`BStreamEqualizerConfiguration` under Android ART with Media3 1.4.1. It does not
substitute a Dart or test implementation of the filters. It uses `app_process`
on an explicitly selected **emulator**, without installing another application
or adding dependencies to the shipped app.

The PowerShell runner uses an installed Android SDK, the Android Studio JBR,
and the dependency jars already in the Gradle cache. It writes build products
and measurements under `.dart_tool/eq-bench-android/<label>/`.

```powershell
# Export from the app's actual EqualizerPreset values; do not copy the curves.
# JSON is used by this Android harness, while the text format feeds portable C.
dart run tool/benchmarks/export_equalizer_presets.dart --json .dart_tool/eq-presets-ten.json
dart run tool/benchmarks/export_equalizer_presets.dart .dart_tool/eq-presets-final.txt

# The JSON shape is:
# { "frequencies": [31,62,...,16000], "presets": { "flat": [0,...,0], ... } }
./tool/benchmarks/android/run_equalizer_benchmark.ps1 `
  -Label baseline `
  -PresetFile .dart_tool/eq-presets-ten.json `
  -Repetitions 7 -AudioSeconds 3

# An optional directory with copies of the two production Java files makes a
# baseline reproducible after editing the working processor implementation.
./tool/benchmarks/android/run_equalizer_benchmark.ps1 `
  -Label saved-baseline `
  -SourceDirectory .dart_tool/eq-benchmark-baseline `
  -PresetFile .dart_tool/eq-presets-ten.json
```

Both exports read the same immutable ten-band preset definitions in the app
model. Keep that bank unchanged between baseline and optimized runs so retuning
a preset cannot be mistaken for a processing optimization. Omitting the output
path prints the selected format to stdout.

The scenario bank includes disabled/flat bypass, every band separately at
`+6` and `−6 dB`, all bands at `+6`, `+12` and `−6 dB`, alternating extremes,
every supplied preset, and two continuous adjustment scenarios at 80 ms
intervals. Each scenario runs at 48/96 kHz, stereo, PCM16/float32. Scenario
order is shuffled with the same fixed seed in repeated runs. Both encoding
paths receive a global warmup; each case then warms its own buffers and filter
state before the measured repetitions. No real-time sleeps or audio output
are involved: the test processes blocks as quickly as possible.

`results.jsonl` contains metadata, one row per case, and a completion record.
`results.csv` is a convenient table of the case rows. `raw.log` retains all
device output if a runtime or dependency error needs investigation.

## Reading the measurements

- **`medianCpuMsPerAudioSecond`:** thread CPU milliseconds needed to process
  one second of PCM, including Media3 queue/get-output calls and a small fixed
  checksum consumer. Configuration changes are included for the dynamic cases.
  This is the main throughput measure for before/after comparisons.
- **`equivalentSingleCorePercent`:** that CPU time divided by 10. For example,
  20 ms per audio second corresponds to 2% of one continuously available core.
  It is **not** a measurement of whole-app CPU use during playback.
- **`p95BlockWallUs`:** 95th percentile elapsed queue/get-output time for one
  10 ms PCM block. This excludes dynamic configuration preparation and the
  checksum consumer. Wall time can include emulator scheduling interruptions.
- **`blocksAtOrAbove10ms`:** observed block calls taking at least their 10 ms
  audio duration. This synthetic count is not an underrun measurement.
- **Allocation/GC fields:** ART process-wide runtime counters sampled around
  the measured repetitions; they also include small harness/runtime activity.
  Buffers, timing arrays and repetition windows are prepared before timing.
- **`bypassExact`:** disabled/flat output is checked byte for byte against the
  input block. Every scenario checks frame count, finite output and PCM range;
  `lastOutputPeak` is only the last block, not a peak measurement of a song.

Compare repeated runs on the same emulator and host with the same preset JSON,
repetitions and audio duration. Avoid concurrent heavy builds or benchmarks.
Keep raw results: short runs, JIT warmup, host load and virtualized scheduling
can otherwise make a small apparent improvement misleading. This benchmark
does not measure a phone's battery consumption, thermal behavior, the decoder,
Flutter rendering, offload savings, Bluetooth or speaker quality. Those require
separate end-to-end measurements on physical hardware.
