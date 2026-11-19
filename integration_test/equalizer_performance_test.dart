// Opt-in, real Windows libmpv benchmark. Run with flutter drive --profile
// --driver test_driver/integration_test.dart --target this file and
// --dart-define=BSTREAM_EQ_BENCHMARK=true. Writes repeatable raw JSON results.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bstream_music/services/player/media_kit_equalizer.dart';
import 'package:bstream_music/services/player/player_equalizer.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('measure native desktop EQ CPU during timed PCM playback', (
    tester,
  ) async {
    if (!Platform.isWindows ||
        !const bool.fromEnvironment('BSTREAM_EQ_BENCHMARK')) {
      return;
    }
    MediaKit.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp('bstream_eq_perf_');
    final clock = _ProcessCpuClock();
    final player = Player();
    final native = player.platform as NativePlayer;
    final rows = <Map<String, Object>>[];
    const flat = EqualizerSettings(enabled: true);
    final cases = <(String, EqualizerSettings)>[
      ('off', const EqualizerSettings()),
      ('flat', flat),
      ('one_band', flat.withBand(5, 6)),
      (
        'bass_boost',
        EqualizerSettings(
          enabled: true,
          gainsDb: EqualizerPreset.bassBoost.gainsDb,
        ),
      ),
      (
        'all_boost',
        EqualizerSettings(enabled: true, gainsDb: List.filled(10, 6)),
      ),
      (
        'alternating',
        EqualizerSettings(
          enabled: true,
          gainsDb: List.generate(10, (i) => i.isEven ? 12 : -12),
        ),
      ),
    ];
    try {
      await native.setProperty('ao', 'null');
      await player.setVolume(0);
      for (final rate in [48000, 96000]) {
        final wave = File('${directory.path}/stereo-$rate.wav');
        await wave.writeAsBytes(_wave(rate, 150));
        await player.open(Media(wave.uri.toString()));
        await _waitUntil(() => player.state.position.inMilliseconds > 500);
        // Warm the decoder and filter backend before measuring steady playback.
        await MediaKitEqualizerFilter.apply(native, cases.last.$2);
        await Future<void>.delayed(const Duration(seconds: 2));
        for (var repeat = 0; repeat < 3; repeat++) {
          // Reverse order on alternate repeats to reduce warmup/order bias.
          for (final entry in repeat.isEven ? cases : cases.reversed) {
            final (name, settings) = entry;
            final updateWatch = Stopwatch()..start();
            await MediaKitEqualizerFilter.apply(native, settings);
            final configureUs = updateWatch.elapsedMicroseconds;
            await Future<void>.delayed(const Duration(milliseconds: 400));
            final position = player.state.position;
            final startedCpu = clock.microseconds;
            final wall = Stopwatch()..start();
            await Future<void>.delayed(const Duration(seconds: 3));
            final cpuUs = clock.microseconds - startedCpu;
            final wallUs = wall.elapsedMicroseconds;
            final playedUs = (player.state.position - position).inMicroseconds;
            expect(player.state.playing, isTrue);
            expect(playedUs, greaterThan(2000000));
            rows.add({
              'engine': 'windows-mpv',
              'sample_rate': rate,
              'channels': 2,
              'case': name,
              'repeat': repeat,
              'process_cpu_us': cpuUs,
              'wall_us': wallUs,
              'played_us': playedUs,
              'cpu_percent_one_core': 100 * cpuUs / wallUs,
              'configure_us': configureUs,
            });
          }
        }
      }
      final result = {
        'scope':
            'whole benchmark process CPU; null audio, no music UI or network',
        'mode': 'profile',
        'os': Platform.operatingSystemVersion,
        'processors': Platform.numberOfProcessors,
        'mpv': await native.getProperty('mpv-version'),
        'ffmpeg': await native.getProperty('ffmpeg-version'),
        'audio_params': await native.getProperty('audio-params'),
        'rows': rows,
      };
      const out = String.fromEnvironment('BSTREAM_EQ_BENCHMARK_OUT');
      if (out.isNotEmpty) {
        await File(
          out,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      }
      binding.reportData = result;
      // ignore: avoid_print
      print('BSTREAM_EQ_BENCHMARK ${jsonEncode(result)}');
    } finally {
      clock.dispose();
      await player.dispose();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

Future<void> _waitUntil(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      throw StateError('The native player did not advance.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

final class _FileTime extends Struct {
  @Uint32()
  external int low;
  @Uint32()
  external int high;
  int get ticks => high * 0x100000000 + low;
}

class _ProcessCpuClock {
  _ProcessCpuClock() {
    final kernel = DynamicLibrary.open('kernel32.dll');
    _process = kernel
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetCurrentProcess',
        )();
    _read = kernel
        .lookupFunction<
          Int32 Function(
            Pointer<Void>,
            Pointer<_FileTime>,
            Pointer<_FileTime>,
            Pointer<_FileTime>,
            Pointer<_FileTime>,
          ),
          int Function(
            Pointer<Void>,
            Pointer<_FileTime>,
            Pointer<_FileTime>,
            Pointer<_FileTime>,
            Pointer<_FileTime>,
          )
        >('GetProcessTimes');
  }
  late final Pointer<Void> _process;
  late final int Function(
    Pointer<Void>,
    Pointer<_FileTime>,
    Pointer<_FileTime>,
    Pointer<_FileTime>,
    Pointer<_FileTime>,
  )
  _read;
  final _times = calloc<_FileTime>(4);
  int get microseconds {
    if (_read(_process, _times, _times + 1, _times + 2, _times + 3) == 0) {
      throw StateError('GetProcessTimes failed.');
    }
    return ((_times + 2).ref.ticks + (_times + 3).ref.ticks) ~/ 10;
  }

  void dispose() => calloc.free(_times);
}

Uint8List _wave(int rate, int seconds) {
  final frames = rate * seconds;
  final bytes = Uint8List(44 + frames * 4);
  final data = ByteData.sublistView(bytes);
  void ascii(int at, String value) =>
      bytes.setRange(at, at + value.length, value.codeUnits);
  ascii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  for (var i = 0; i < frames; i++) {
    final left = (6000 * math.sin(2 * math.pi * 1000 * i / rate)).round();
    final right = (6000 * math.sin(2 * math.pi * 250 * i / rate)).round();
    data.setInt16(44 + i * 4, left, Endian.little);
    data.setInt16(46 + i * 4, right, Endian.little);
  }
  return bytes;
}
