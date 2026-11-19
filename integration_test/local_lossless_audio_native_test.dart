import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/player/local_audio_quality_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

/// Read-only tests of user-supplied FLAC fixtures with the shipped desktop
/// decoder. Pass absolute paths separated by | in BSTREAM_TEST_FLAC_FILES.
/// The last fixture should be genuine 24-bit/96 kHz for Hi-Res coverage.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const inputs = String.fromEnvironment('BSTREAM_TEST_FLAC_FILES');
  testWidgets(
    'local FLAC decoding preserves source resolution and supports seek',
    (tester) async {
      MediaKit.ensureInitialized();
      final player = Player();
      final native = player.platform as NativePlayer;
      final quality = LocalAudioQualityService();
      final errors = <String>[];
      final subscription = player.stream.error.listen(errors.add);
      final results = <Map<String, Object?>>[];
      try {
        // This gain belongs only to this test player, never to the system mixer.
        await player.setVolume(6);
        for (final path in inputs.split('|')) {
          final file = File(path);
          expect(await file.exists(), isTrue, reason: path);
          final format = await quality.read(path);
          expect(format?.codec, 'flac');
          expect(format?.bitDepth, isNotNull);
          final sameFormat = await quality.read(path);
          expect(
            sameFormat,
            same(format),
            reason: 'Active-file facts are cached',
          );

          await player.open(Media(file.uri.toString()));
          await _until(
            () =>
                player.state.playing &&
                player.state.position > const Duration(milliseconds: 250),
          );
          final codec = await native.getProperty('audio-codec-name');
          final sampleRate = await native.getProperty(
            'audio-params/samplerate',
          );
          final channels = await native.getProperty(
            'audio-params/channel-count',
          );
          expect(codec.toLowerCase(), contains('flac'));
          expect(int.tryParse(sampleRate), format!.sampleRate);
          expect(int.tryParse(channels), format.channels);
          await player.pause();
          await player.seek(const Duration(seconds: 2));
          await player.play();
          await _until(
            () => player.state.position > const Duration(milliseconds: 2250),
          );
          await player.pause();
          results.add({
            'file': file.path,
            ...format.toMap(),
            'nativeCodec': codec,
            'nativeSampleRate': sampleRate,
            'nativeSampleFormat': await native.getProperty(
              'audio-params/format',
            ),
            'hiRes': format.isHighResolution,
            'seekPositionMs': player.state.position.inMilliseconds,
          });
          await player.stop();
        }
        expect(errors, isEmpty);
        const reportPath = String.fromEnvironment('BSTREAM_TEST_FLAC_REPORT');
        if (reportPath.isNotEmpty) {
          await File(
            reportPath,
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
        }
        // ignore: avoid_print
        print('LOCAL_FLAC_NATIVE_OK: ${jsonEncode(results)}');
      } finally {
        quality.dispose();
        await subscription.cancel();
        await player.dispose();
      }
    },
    skip:
        inputs.isEmpty ||
        !(Platform.isWindows || Platform.isLinux || Platform.isMacOS),
  );
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Native FLAC playback timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}
