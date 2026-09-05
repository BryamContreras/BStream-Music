import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/services/player/just_audio_player_service.dart';
import 'package:bstream_music/services/player/media_kit_player_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native crossfade keeps clock and queue order across handoffs', (
    tester,
  ) async {
    if (!Platform.isAndroid &&
        !Platform.isIOS &&
        !Platform.isWindows &&
        !Platform.isLinux &&
        !Platform.isMacOS) {
      return;
    }

    final directory = await Directory.systemTemp.createTemp(
      'bstream_native_crossfade_',
    );
    const trackDuration = Duration(milliseconds: 2600);
    const crossfadeDuration = Duration(milliseconds: 700);
    const crossfadeTrigger = Duration(milliseconds: 1950);
    final tracks = <LocalTrack>[];
    for (var index = 0; index < 4; index++) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        '${String.fromCharCode('a'.codeUnitAt(0) + index)}.wav',
      );
      await file.writeAsBytes(
        _toneWave(trackDuration, frequency: 220 + (index * 110)),
      );
      tracks.add(
        _track(
          'native-${String.fromCharCode('a'.codeUnitAt(0) + index)}',
          file.path,
          duration: trackDuration,
        ),
      );
    }

    final PlayerService service = Platform.isAndroid || Platform.isIOS
        ? JustAudioPlayerService()
        : MediaKitPlayerService();
    final crossfade = service as CrossfadeCapablePlayer;
    final observedTrackOrder = <String>[];
    final observedPositions = <String, List<Duration>>{};
    final snapshotSubscription = service.snapshotStream.listen((snapshot) {
      final trackId = snapshot.trackId;
      if (trackId == null) {
        return;
      }
      if (observedTrackOrder.isEmpty || observedTrackOrder.last != trackId) {
        observedTrackOrder.add(trackId);
      }
      observedPositions
          .putIfAbsent(trackId, () => <Duration>[])
          .add(snapshot.position);
    });
    try {
      await service.setVolume(0.35);
      await service.playLocalQueue(tracks, 0);
      await _waitUntil(
        () => service.currentSnapshot.duration != null,
        timeout: const Duration(seconds: 8),
      );
      await crossfade.configureCrossfade(
        enabled: true,
        duration: crossfadeDuration,
      );
      await service.seek(crossfadeTrigger);
      await crossfade.prepareCrossfade(LocalCrossfadePlaybackSource(tracks[1]));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await service.seek(Duration.zero);
      expect(service.currentSnapshot.trackId, tracks.first.id);
      expect(service.currentSnapshot.position, Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(service.currentSnapshot.trackId, tracks.first.id);

      await Future.wait<void>([
        service.seek(const Duration(milliseconds: 1200)),
        service.seek(const Duration(milliseconds: 600)),
        service.seek(Duration.zero),
      ]);
      expect(service.currentSnapshot.trackId, tracks.first.id);
      expect(service.currentSnapshot.position, Duration.zero);

      for (var nextIndex = 1; nextIndex < tracks.length; nextIndex++) {
        final next = tracks[nextIndex];
        await service.seek(crossfadeTrigger);
        await crossfade.prepareCrossfade(LocalCrossfadePlaybackSource(next));
        await _waitUntil(
          () => service.currentSnapshot.trackId == next.id,
          timeout: const Duration(seconds: 8),
          diagnostic: () {
            final snapshot = service.currentSnapshot;
            return 'expected=${next.id}, track=${snapshot.trackId}, '
                'observed=$observedTrackOrder, position=${snapshot.position}, '
                'duration=${snapshot.duration}, status=${snapshot.status}, '
                'error=${snapshot.errorMessage}, '
                'crossfadeEnabled=${crossfade.crossfadeEnabled}';
          },
        );

        final handoffPosition = service.currentSnapshot.position;
        expect(
          handoffPosition.inMilliseconds,
          greaterThanOrEqualTo(250),
          reason: '${next.id} must keep the clock of the audible standby deck',
        );
        expect(service.currentSnapshot.status, PlayerStatus.playing);
        expect(service.currentSnapshot.volume, closeTo(0.35, 0.001));

        await Future<void>.delayed(const Duration(milliseconds: 300));
        final afterSettle = service.currentSnapshot;
        expect(
          afterSettle.trackId,
          next.id,
          reason: '${next.id} must not be replaced by the following item',
        );
        expect(
          afterSettle.position.inMilliseconds,
          greaterThanOrEqualTo(handoffPosition.inMilliseconds - 150),
          reason: '${next.id} restarted after its crossfade handoff',
        );

        final samples = observedPositions[next.id] ?? const <Duration>[];
        expect(
          samples.any(
            (position) => position < const Duration(milliseconds: 200),
          ),
          isFalse,
          reason: '${next.id} published a near-zero position after promotion',
        );
      }

      expect(
        observedTrackOrder,
        orderedEquals(tracks.map((track) => track.id)),
        reason: 'Repeated crossfades must promote every item exactly once',
      );

      await service.stop();
      expect(service.currentSnapshot.status, PlayerStatus.stopped);
    } finally {
      await snapshotSubscription.cancel();
      await service.dispose();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  });
}

LocalTrack _track(String id, String path, {required Duration duration}) =>
    LocalTrack(
      id: id,
      title: id,
      artist: 'BStream integration test',
      filePath: path,
      duration: duration,
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

Uint8List _toneWave(Duration duration, {required int frequency}) {
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
  for (var sample = 0; sample < sampleCount; sample++) {
    final phase = 2 * math.pi * frequency * sample / sampleRate;
    final value = (math.sin(phase) * 2800).round();
    data.setInt16(44 + (sample * 2), value, Endian.little);
  }
  return bytes;
}
