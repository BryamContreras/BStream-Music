import 'dart:io';
import 'dart:typed_data';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/services/player/just_audio_player_service.dart';
import 'package:bstream_music/services/player/media_kit_player_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native backend performs a two-deck handoff', (tester) async {
    if (!Platform.isAndroid &&
        !Platform.isWindows &&
        !Platform.isLinux &&
        !Platform.isMacOS) {
      return;
    }

    final directory = await Directory.systemTemp.createTemp(
      'bstream_native_crossfade_',
    );
    final firstFile = File('${directory.path}${Platform.pathSeparator}a.wav');
    final secondFile = File('${directory.path}${Platform.pathSeparator}b.wav');
    await firstFile.writeAsBytes(_silentWave(const Duration(seconds: 2)));
    await secondFile.writeAsBytes(_silentWave(const Duration(seconds: 2)));

    final first = _track('native-a', firstFile.path);
    final second = _track('native-b', secondFile.path);
    final PlayerService service = Platform.isAndroid
        ? JustAudioPlayerService()
        : MediaKitPlayerService();
    final crossfade = service as CrossfadeCapablePlayer;
    try {
      await service.setVolume(0.35);
      await service.playLocalQueue([first, second], 0);
      await _waitUntil(
        () => service.currentSnapshot.duration != null,
        timeout: const Duration(seconds: 8),
      );
      await service.seek(const Duration(milliseconds: 1450));
      await crossfade.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 700),
      );
      await crossfade.prepareCrossfade(LocalCrossfadePlaybackSource(second));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await service.seek(Duration.zero);
      expect(service.currentSnapshot.trackId, first.id);
      expect(service.currentSnapshot.position, Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(service.currentSnapshot.trackId, first.id);

      await Future.wait<void>([
        service.seek(const Duration(milliseconds: 1200)),
        service.seek(const Duration(milliseconds: 600)),
        service.seek(Duration.zero),
      ]);
      expect(service.currentSnapshot.trackId, first.id);
      expect(service.currentSnapshot.position, Duration.zero);

      await service.seek(const Duration(milliseconds: 1450));
      await crossfade.prepareCrossfade(LocalCrossfadePlaybackSource(second));

      await _waitUntil(
        () => service.currentSnapshot.trackId == second.id,
        timeout: const Duration(seconds: 8),
        diagnostic: () {
          final snapshot = service.currentSnapshot;
          return 'track=${snapshot.trackId}, position=${snapshot.position}, '
              'duration=${snapshot.duration}, status=${snapshot.status}, '
              'crossfadeEnabled=${crossfade.crossfadeEnabled}';
        },
      );
      expect(service.currentSnapshot.status, PlayerStatus.playing);
      expect(service.currentSnapshot.volume, closeTo(0.35, 0.001));

      await service.stop();
      expect(service.currentSnapshot.status, PlayerStatus.stopped);
    } finally {
      await service.dispose();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });
}

LocalTrack _track(String id, String path) => LocalTrack(
  id: id,
  title: id,
  artist: 'BStream integration test',
  filePath: path,
  duration: const Duration(seconds: 2),
  addedAt: DateTime(2026),
);

Future<void> _waitUntil(
  bool Function() condition, {
  required Duration timeout,
  String Function()? diagnostic,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed >= timeout) {
      final details = diagnostic?.call();
      fail(
        'Native crossfade did not reach the expected state in $timeout'
        '${details == null ? '.' : ': $details'}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Uint8List _silentWave(Duration duration) {
  const sampleRate = 8000;
  const channelCount = 1;
  const bitsPerSample = 16;
  final sampleCount = sampleRate * duration.inMilliseconds ~/ 1000;
  final dataLength = sampleCount * channelCount * bitsPerSample ~/ 8;
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(bytes);

  void ascii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes[offset + index] = value.codeUnitAt(index);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channelCount, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(
    28,
    sampleRate * channelCount * bitsPerSample ~/ 8,
    Endian.little,
  );
  data.setUint16(32, channelCount * bitsPerSample ~/ 8, Endian.little);
  data.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, dataLength, Endian.little);
  return bytes;
}
