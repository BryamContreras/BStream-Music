import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bstream_music/services/player/local_audio_quality_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android selects PCM precision and retains playback features', (
    tester,
  ) async {
    if (!Platform.isAndroid) return;
    final directory = await Directory.systemTemp.createTemp('audio_precision_');
    final standard = File('${directory.path}/standard.wav');
    final hiRes = File('${directory.path}/hires.wav');
    await standard.writeAsBytes(_wave(bits: 16, rate: 44100));
    await hiRes.writeAsBytes(_wave(bits: 24, rate: 96000));
    final effect = BStreamEqualizer();
    final player = AudioPlayer(
      audioPipeline: AudioPipeline(androidAudioEffects: [effect]),
      useProxyForRequestHeaders: false,
    );
    const pcm16 = 2;
    const pcmFloat = 4;
    const pcm24 = 21;
    const pcm32 = 22;
    final formats = LocalAudioQualityService();

    Future<BStreamEqualizerStatus> waitForAudio(
      int rate,
      List<int> encodings, {
      int afterFrames = 0,
    }) async {
      final deadline = Stopwatch()..start();
      while (deadline.elapsed < const Duration(seconds: 8)) {
        final status = await effect.readStatus();
        if (status.configured &&
            status.sampleRate == rate &&
            encodings.contains(status.pcmEncoding) &&
            status.lastAudioTrackSampleRate == rate &&
            status.lastAudioTrackEncoding ==
                (encodings.contains(pcm16) ? pcm16 : pcmFloat) &&
            status.processedFrames > afterFrames) {
          return status;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      throw StateError('Expected native PCM encodings $encodings at $rate Hz');
    }

    try {
      await player.setVolume(.06);
      await effect.configure(
        enabled: true,
        gainsDb: const [0, 0, 0, 0, -3, 0, 0, 0, 0, 0],
      );
      await player.setAudioSources([
        AudioSource.file(standard.path),
        AudioSource.file(hiRes.path),
      ]);
      unawaited(player.play());
      final standardStatus = await waitForAudio(44100, [pcm16]);
      expect(standardStatus.enabled, isTrue);
      await player.seek(Duration.zero, index: 1);
      final high = await waitForAudio(96000, [
        pcmFloat,
        pcm24,
        pcm32,
      ], afterFrames: standardStatus.processedFrames);
      expect(high.enabled, isTrue);
      expect(high.appliedRevision, high.revision);

      await player.seek(const Duration(seconds: 1));
      final skipTime = Stopwatch()..start();
      await player.setSkipSilenceEnabled(true);
      final compatible = await waitForAudio(96000, [
        pcm16,
      ], afterFrames: high.processedFrames);
      expect(compatible.enabled, isTrue);
      expect(player.currentIndex, 1);
      expect(player.position, greaterThan(const Duration(milliseconds: 900)));
      expect(player.playing, isTrue);
      await player.processingStateStream
          .firstWhere((state) => state == ProcessingState.completed)
          .timeout(const Duration(seconds: 8));
      expect(skipTime.elapsed, lessThan(const Duration(seconds: 8)));
      // ignore: avoid_print
      print(
        '24-bit WAV: float output at 96000 Hz; skip and EQ active through '
        'PCM16; 10 seconds of source time played in ${skipTime.elapsed}.',
      );

      await player.setSkipSilenceEnabled(false);
      await player.seek(Duration.zero, index: 1);
      unawaited(player.play());
      await waitForAudio(96000, [
        pcmFloat,
        pcm24,
        pcm32,
      ], afterFrames: compatible.processedFrames);
      await player.setSpeed(1.25);
      await waitForAudio(96000, [
        pcm16,
      ], afterFrames: compatible.processedFrames);
      final beforeSpeedReset = (await effect.readStatus()).processedFrames;
      await player.setSpeed(1);
      await waitForAudio(96000, [
        pcmFloat,
        pcm24,
        pcm32,
      ], afterFrames: beforeSpeedReset);

      // Files are passed in from the test device without packaging user media.
      const inputs = String.fromEnvironment('BSTREAM_ANDROID_TEST_FLAC');
      for (final path in inputs.split('|').where((part) => part.isNotEmpty)) {
        final format = await formats.read(path);
        expect(format?.codec, 'flac');
        expect(format?.bitDepth, anyOf(16, 24));
        final before = (await effect.readStatus()).processedFrames;
        await player.setFilePath(path);
        unawaited(player.play());
        final precision = await waitForAudio(
          format!.sampleRate!,
          format.bitDepth == 16 ? [pcm16] : [pcmFloat, pcm24, pcm32],
          afterFrames: before,
        );
        // ignore: avoid_print
        print(
          'FLAC ${path.split('/').last}: ${format.toMap()} '
          'EQ PCM=${precision.pcmEncoding}, EQ active=${precision.enabled}, '
          'AudioTrack PCM=${precision.lastAudioTrackEncoding}, '
          'rate=${precision.lastAudioTrackSampleRate}',
        );
        await player.pause();
      }
    } finally {
      formats.dispose();
      await player.dispose();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

// Two seconds of tone, eight seconds of silence and one second of tone.
Uint8List _wave({required int bits, required int rate}) {
  final bytesPerSample = bits ~/ 8;
  final dataSize = 11 * rate * bytesPerSample;
  final bytes = Uint8List(44 + dataSize);
  final header = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  header.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, 'WAVEfmt '.codeUnits);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * bytesPerSample, Endian.little);
  header.setUint16(32, bytesPerSample, Endian.little);
  header.setUint16(34, bits, Endian.little);
  bytes.setRange(36, 40, 'data'.codeUnits);
  header.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < 11 * rate; i++) {
    if (i >= 2 * rate && i < 10 * rate) continue;
    final sample = (math.sin(i * 2 * math.pi * 440 / rate) * (1 << (bits - 4)))
        .round();
    for (var byte = 0; byte < bytesPerSample; byte++) {
      bytes[44 + i * bytesPerSample + byte] = (sample >> (8 * byte)) & 0xff;
    }
  }
  return bytes;
}
