import 'dart:io';
import 'dart:math' as math;

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/services/player/media_kit_equalizer.dart';
import 'package:bstream_music/services/player/media_kit_player_service.dart';
import 'package:bstream_music/services/player/player_equalizer.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

/// Checks the shipped libmpv/FFmpeg filter chain, then actual dual-deck playback.
/// Run with BSTREAM_HEADLESS_AUDIO=true on runners without an audio device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop native equalizer preserves other filters and playback', (
    tester,
  ) async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    MediaKit.ensureInitialized();
    final directory = await Directory.systemTemp.createTemp(
      'bstream_equalizer_',
    );
    final file = File('${directory.path}${Platform.pathSeparator}tone.wav');
    await file.writeAsBytes(_toneWave());
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.debug),
    );
    final nativeErrors = <String>[];
    final nativeLogs = <String>[];
    final errors = player.stream.error.listen(nativeErrors.add);
    final logs = player.stream.log.listen((log) {
      nativeLogs.add('${log.prefix}/${log.level}: ${log.text}');
      if (nativeLogs.length > 120) nativeLogs.removeAt(0);
    });
    final service = MediaKitPlayerService();
    try {
      final native = player.platform as NativePlayer;
      Future<String> diagnostics() async {
        final properties = <String>[];
        for (final property in [
          'mpv-version',
          'ffmpeg-version',
          'path',
          'ao',
          'pause',
          'time-pos',
          'audio-params',
          'audio-out-params',
          'af',
        ]) {
          properties.add('$property=${await native.getProperty(property)}');
        }
        return 'state=${player.state}\n${properties.join('\n')}\nerrors=$nativeErrors\n${nativeLogs.join('\n')}';
      }

      if (const bool.fromEnvironment('BSTREAM_HEADLESS_AUDIO')) {
        await native.setProperty('ao', 'null');
      }
      // Keep fixture playback silent even when the real device is available.
      await player.setVolume(0);
      await native.command([
        'af',
        'add',
        '@integration-other:lavfi=[equalizer=f=1000:t=q:w=1:g=0:r=f64]',
      ]);
      const boosted = EqualizerSettings(
        enabled: true,
        gainsDb: [6, 6, 4, 3, 2, 2, 1, 1, 3, 4],
      );
      await MediaKitEqualizerFilter.apply(native, boosted);
      await player.open(Media(file.uri.toString()));
      await _waitUntil(
        () => player.state.position > const Duration(milliseconds: 300),
        diagnostics: diagnostics,
      );
      final before = player.state.position;
      final filters = await native.getProperty('af');
      expect(filters, contains('@integration-other:'));
      expect(filters, contains(MediaKitEqualizerFilter.graph(boosted)!));

      const cut = EqualizerSettings(
        enabled: true,
        gainsDb: [-6, -6, -4, -3, -1, 0, -1, -2, -3, -4],
      );
      await MediaKitEqualizerFilter.apply(native, cut);
      expect(
        await native.getProperty('af'),
        contains(MediaKitEqualizerFilter.graph(cut)!),
      );
      expect(
        player.state.position,
        greaterThanOrEqualTo(before - const Duration(milliseconds: 100)),
      );
      expect(player.state.playing, isTrue);
      await MediaKitEqualizerFilter.apply(native, const EqualizerSettings());
      final bypassed = await native.getProperty('af');
      expect(bypassed, contains('@integration-other:'));
      expect(MediaKitEqualizerFilter.containsFilter(bypassed), isFalse);
      await player.stop();

      expect(service.supportsEqualizer, isTrue);
      const logicalVolume = bool.fromEnvironment('BSTREAM_HEADLESS_AUDIO')
          ? .35
          : 0.0;
      await service.setVolume(logicalVolume);
      await service.configureEqualizer(boosted);
      LocalTrack track(String id) => LocalTrack(
        id: id,
        title: 'Equalizer native fixture',
        artist: 'BStream integration test',
        filePath: file.path,
        duration: const Duration(seconds: 4),
        addedAt: DateTime(2026),
      );
      await service.playLocal(track('first'));
      await _waitUntil(() => service.currentSnapshot.position > Duration.zero);
      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 500),
      );
      await service.pause();
      await service.seek(const Duration(milliseconds: 3550));
      await service.prepareCrossfade(
        LocalCrossfadePlaybackSource(track('second')),
      );
      await service.configureEqualizer(cut);
      await service.resume();
      await _waitUntil(() => service.currentSnapshot.trackId == 'second');
      expect(service.currentSnapshot.status, PlayerStatus.playing);
      expect(service.currentSnapshot.volume, closeTo(logicalVolume, .001));
      await service.configureEqualizer(const EqualizerSettings());
      await service.stop();
    } finally {
      if (nativeErrors.isNotEmpty) {
        debugPrint('EQUALIZER_NATIVE_ERRORS: $nativeErrors');
      }
      await errors.cancel();
      await logs.cancel();
      await service.dispose();
      await player.dispose();
      if (await file.exists()) await file.delete();
      if (await directory.exists()) await directory.delete();
    }
  });
}

Future<void> _waitUntil(
  bool Function() condition, {
  Future<String> Function()? diagnostics,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 8)) {
      fail(
        'Native equalizer playback timed out.\n${diagnostics == null ? '' : await diagnostics()}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Uint8List _toneWave() {
  const rate = 48000;
  const samples = rate * 4;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  void ascii(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  ascii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var sample = 0; sample < samples; sample++) {
    data.setInt16(
      44 + sample * 2,
      (2000 * math.sin(2 * math.pi * 910 * sample / rate)).round(),
      Endian.little,
    );
  }
  return bytes;
}
