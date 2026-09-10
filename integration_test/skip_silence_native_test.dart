import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/player/just_audio_player_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android silence skipping protects musical detail and keeps margins',
    (tester) async {
      if (!Platform.isAndroid) {
        return;
      }

      final directory = await Directory.systemTemp.createTemp(
        'bstream_native_skip_silence_',
      );
      try {
        final warmUp = await _writeTrack(directory, 'warm-up', const [
          _WaveSegment.tone(Duration(milliseconds: 750), peak: 2800),
        ]);
        final musicalPause =
            await _writeTrack(directory, 'four-second-pause', const [
              _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
              _WaveSegment.silence(Duration(seconds: 4)),
              _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
            ]);
        final quietInstrumentation =
            await _writeTrack(directory, 'quiet-instrumentation', const [
              _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
              _WaveSegment.tone(Duration(seconds: 5), peak: 80),
              _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
            ]);
        final reverbTail = await _writeTrack(directory, 'reverb-tail', const [
          _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
          _WaveSegment.decay(
            Duration(seconds: 4),
            initialPeak: 4096,
            finalPeak: 16,
          ),
          _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
        ]);
        final longEmptyGap =
            await _writeTrack(directory, 'long-empty-gap', const [
              _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
              _WaveSegment.silence(Duration(seconds: 10)),
              _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
            ]);
        final longEmptyIntro =
            await _writeTrack(directory, 'long-empty-intro', const [
              _WaveSegment.silence(Duration(seconds: 10)),
              _WaveSegment.tone(Duration(milliseconds: 500), peak: 2800),
            ]);
        final longEmptyOutro =
            await _writeTrack(directory, 'long-empty-outro', const [
              _WaveSegment.tone(Duration(milliseconds: 500), peak: 2800),
              _WaveSegment.silence(Duration(seconds: 10)),
            ]);

        // The Android emulator may run its virtual AudioTrack clock faster
        // than wall time. Warm it once, then compare ON and OFF on the same
        // device instead of assuming a 1:1 host clock.
        await _measurePlayback(warmUp, skipSilenceEnabled: false);

        final pauseBaselineElapsed = await _measurePlayback(
          musicalPause,
          skipSilenceEnabled: false,
        );
        final pauseElapsed = await _measurePlayback(
          musicalPause,
          skipSilenceEnabled: true,
        );
        _expectPreserved(
          baseline: pauseBaselineElapsed,
          enabled: pauseElapsed,
          reason: 'A four-second compositional pause must not be shortened.',
        );

        final quietBaselineElapsed = await _measurePlayback(
          quietInstrumentation,
          skipSilenceEnabled: false,
        );
        final quietElapsed = await _measurePlayback(
          quietInstrumentation,
          skipSilenceEnabled: true,
        );
        _expectPreserved(
          baseline: quietBaselineElapsed,
          enabled: quietElapsed,
          reason: 'Very quiet instrumentation must remain audible.',
        );

        final reverbBaselineElapsed = await _measurePlayback(
          reverbTail,
          skipSilenceEnabled: false,
        );
        final reverbElapsed = await _measurePlayback(
          reverbTail,
          skipSilenceEnabled: true,
        );
        _expectPreserved(
          baseline: reverbBaselineElapsed,
          enabled: reverbElapsed,
          reason: 'A decaying four-second reverb tail must remain intact.',
        );

        final baselineElapsed = await _measurePlayback(
          longEmptyGap,
          skipSilenceEnabled: false,
        );
        final shortenedElapsed = await _measurePlayback(
          longEmptyGap,
          skipSilenceEnabled: true,
        );
        _expectLongSilenceShortened(
          baseline: baselineElapsed,
          enabled: shortenedElapsed,
          location: 'inside a track',
        );

        final introBaselineElapsed = await _measurePlayback(
          longEmptyIntro,
          skipSilenceEnabled: false,
        );
        final shortenedIntroElapsed = await _measurePlayback(
          longEmptyIntro,
          skipSilenceEnabled: true,
        );
        _expectLongSilenceShortened(
          baseline: introBaselineElapsed,
          enabled: shortenedIntroElapsed,
          location: 'at the beginning of a track',
        );

        final outroBaselineElapsed = await _measurePlayback(
          longEmptyOutro,
          skipSilenceEnabled: false,
        );
        final shortenedOutroElapsed = await _measurePlayback(
          longEmptyOutro,
          skipSilenceEnabled: true,
        );
        _expectLongSilenceShortened(
          baseline: outroBaselineElapsed,
          enabled: shortenedOutroElapsed,
          location: 'at the end of a track',
        );
      } finally {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'Android silence skipping hands a long empty outro to crossfade safely',
    (tester) async {
      if (!Platform.isAndroid) {
        return;
      }

      final directory = await Directory.systemTemp.createTemp(
        'bstream_native_skip_silence_crossfade_',
      );
      try {
        final outgoing =
            await _writeTrack(directory, 'silent-outro-crossfade', const [
              _WaveSegment.tone(Duration(milliseconds: 500), peak: 2800),
              _WaveSegment.silence(Duration(seconds: 10)),
            ]);
        final incoming = await _writeTrack(
          directory,
          'crossfade-successor',
          const [_WaveSegment.tone(Duration(milliseconds: 2600), peak: 3500)],
        );

        final baselineElapsed = await _measureCrossfadeHandoff(
          outgoing,
          incoming,
          skipSilenceEnabled: false,
        );
        final shortenedElapsed = await _measureCrossfadeHandoff(
          outgoing,
          incoming,
          skipSilenceEnabled: true,
        );
        _expectLongSilenceShortened(
          baseline: baselineElapsed,
          enabled: shortenedElapsed,
          location: 'before a native crossfade',
        );
      } finally {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  testWidgets(
    'Android silence skipping remains music-safe over a slow streaming CDN',
    (tester) async {
      if (!Platform.isAndroid) {
        return;
      }

      final musicalPauseBytes = _stereoWave(const [
        _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
        _WaveSegment.silence(Duration(seconds: 4)),
        _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
      ]);
      final longGapBytes = _stereoWave(const [
        _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
        _WaveSegment.silence(Duration(seconds: 10)),
        _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
      ]);
      final server = await _ThrottledWaveServer.start({
        '/four-second-pause.wav': musicalPauseBytes,
        '/long-empty-gap.wav': longGapBytes,
      });
      try {
        final pauseBaseline = await _measureRemotePlayback(
          server.uriFor('/four-second-pause.wav'),
          id: 'slow-four-second-pause',
          duration: const Duration(milliseconds: 4500),
          skipSilenceEnabled: false,
        );
        final pauseEnabled = await _measureRemotePlayback(
          server.uriFor('/four-second-pause.wav'),
          id: 'slow-four-second-pause',
          duration: const Duration(milliseconds: 4500),
          skipSilenceEnabled: true,
        );
        _expectPreserved(
          baseline: pauseBaseline,
          enabled: pauseEnabled,
          reason:
              'A slow CDN must not turn a four-second musical pause into '
              'skippable silence.',
        );

        final gapBaseline = await _measureRemotePlayback(
          server.uriFor('/long-empty-gap.wav'),
          id: 'slow-long-empty-gap',
          duration: const Duration(milliseconds: 10500),
          skipSilenceEnabled: false,
        );
        final gapEnabled = await _measureRemotePlayback(
          server.uriFor('/long-empty-gap.wav'),
          id: 'slow-long-empty-gap',
          duration: const Duration(milliseconds: 10500),
          skipSilenceEnabled: true,
        );
        _expectLongSilenceShortened(
          baseline: gapBaseline,
          enabled: gapEnabled,
          location: 'inside a slowly streamed track',
        );
        expect(
          server.completedResponses,
          greaterThanOrEqualTo(4),
          reason: 'Every remote playback must consume a valid HTTP response.',
        );
      } finally {
        await server.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'Android publishes accelerated silence progress again after a backward seek',
    (tester) async {
      if (!Platform.isAndroid) {
        return;
      }

      final longGapBytes = _stereoWave(const [
        _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
        _WaveSegment.silence(Duration(seconds: 60)),
        _WaveSegment.tone(Duration(milliseconds: 250), peak: 2800),
      ]);
      final server = await _ThrottledWaveServer.start({
        '/clock-sync-long-gap.wav': longGapBytes,
      });
      final service = JustAudioPlayerService();
      final snapshots = <PlayerSnapshot>[];
      final subscription = service.snapshotStream.listen(snapshots.add);
      final track = TrackInfo(
        id: 'clock-sync-long-gap',
        title: 'clock-sync-long-gap',
        artist: 'BStream clock integration test',
        url: server.uriFor('/clock-sync-long-gap.wav').toString(),
        streamUrl: server.uriFor('/clock-sync-long-gap.wav').toString(),
        streamExtension: 'wav',
        streamMimeType: 'audio/wav',
        duration: const Duration(milliseconds: 60500),
      );
      try {
        await service.setVolume(0.01);
        await service.configureSkipSilence(enabled: true);
        await service.playRemote(track);
        await _waitUntil(
          () => service.currentSnapshot.status == PlayerStatus.playing,
          timeout: const Duration(seconds: 12),
          diagnostic: () => service.currentSnapshot.toString(),
        );

        Future<void> expectAcceleratedProgress(String phase) async {
          final start = service.currentSnapshot.position;
          final phaseWatch = Stopwatch()..start();
          final observations = <({Duration wall, Duration position})>[
            (wall: Duration.zero, position: start),
          ];
          final phaseSubscription = service.snapshotStream.listen((snapshot) {
            if (snapshot.status == PlayerStatus.playing) {
              observations.add((
                wall: phaseWatch.elapsed,
                position: snapshot.position,
              ));
            }
          });
          try {
            await _waitUntil(
              () =>
                  service.currentSnapshot.position - start >=
                  const Duration(seconds: 8),
              timeout: const Duration(seconds: 6),
              diagnostic: () => '$phase: ${service.currentSnapshot}',
            );

            var acceleratedUpdates = 0;
            var previous = observations.first;
            for (final observation in observations.skip(1)) {
              final sourceDelta = observation.position - previous.position;
              if (sourceDelta <= Duration.zero) {
                continue;
              }
              final wallDelta = observation.wall - previous.wall;
              if (sourceDelta - wallDelta >=
                  const Duration(milliseconds: 150)) {
                acceleratedUpdates++;
              }
              previous = observation;
            }
            expect(
              acceleratedUpdates,
              greaterThanOrEqualTo(2),
              reason:
                  '$phase must publish multiple accelerated clock updates, '
                  'not one delayed discontinuity. Observations: $observations',
            );
            expect(
              service.currentSnapshot.status,
              PlayerStatus.playing,
              reason:
                  '$phase must be measured before the synthetic track ends.',
            );
          } finally {
            await phaseSubscription.cancel();
          }
        }

        await expectAcceleratedProgress('initial scan');
        final snapshotsBeforeSeek = snapshots.length;
        await service.seek(const Duration(milliseconds: 250));
        expect(
          snapshots
              .skip(snapshotsBeforeSeek)
              .any(
                (snapshot) =>
                    snapshot.position >= const Duration(milliseconds: 200) &&
                    snapshot.position <= const Duration(milliseconds: 1500),
              ),
          isTrue,
          reason:
              'The backward seek target must be published before rescanning.',
        );
        await expectAcceleratedProgress('scan after backward seek');

        expect(
          snapshots.where((snapshot) => snapshot.status == PlayerStatus.failed),
          isEmpty,
          reason: 'Clock synchronization must not introduce playback errors.',
        );
      } finally {
        await subscription.cancel();
        await service.dispose();
        await server.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

void _expectLongSilenceShortened({
  required Duration baseline,
  required Duration enabled,
  required String location,
}) {
  expect(
    enabled.inMilliseconds,
    greaterThanOrEqualTo(600),
    reason:
        'Silence $location must retain the configured margins around audible '
        'content.',
  );
  expect(
    enabled.inMilliseconds,
    lessThanOrEqualTo((baseline.inMilliseconds * 0.40).round()),
    reason: 'Genuinely long empty silence $location should be shortened.',
  );
  expect(
    baseline - enabled,
    greaterThanOrEqualTo(const Duration(seconds: 2)),
    reason: 'The native processor must measurably remove silence $location.',
  );
}

void _expectPreserved({
  required Duration baseline,
  required Duration enabled,
  required String reason,
}) {
  final tolerance = math.max(700, (baseline.inMilliseconds * 0.25).round());
  expect(
    (enabled - baseline).abs(),
    lessThanOrEqualTo(Duration(milliseconds: tolerance)),
    reason: reason,
  );
  expect(
    enabled.inMilliseconds,
    greaterThanOrEqualTo((baseline.inMilliseconds * 0.75).round()),
    reason: reason,
  );
}

Future<Duration> _measurePlayback(
  LocalTrack track, {
  required bool skipSilenceEnabled,
}) async {
  final service = JustAudioPlayerService();
  final snapshots = <PlayerSnapshot>[];
  final subscription = service.snapshotStream.listen(snapshots.add);
  try {
    await service.setVolume(0.01);
    await service.configureSkipSilence(enabled: skipSilenceEnabled);
    await service.playLocal(track);
    await _waitUntil(
      () => service.currentSnapshot.status == PlayerStatus.playing,
      timeout: const Duration(seconds: 8),
      diagnostic: () => service.currentSnapshot.toString(),
    );

    final watch = Stopwatch()..start();
    await _waitUntil(
      () => service.currentSnapshot.status == PlayerStatus.completed,
      timeout: (track.duration ?? Duration.zero) + const Duration(seconds: 8),
      diagnostic: () => service.currentSnapshot.toString(),
    );
    watch.stop();
    final maxPosition = snapshots.fold<Duration>(
      Duration.zero,
      (maximum, snapshot) =>
          snapshot.position > maximum ? snapshot.position : maximum,
    );
    // ignore: avoid_print
    print(
      'skip-silence ${track.id}: enabled=$skipSilenceEnabled, '
      'elapsed=${watch.elapsed}, duration=${service.currentSnapshot.duration}, '
      'position=${service.currentSnapshot.position}, maxPosition=$maxPosition',
    );

    var lastPosition = Duration.zero;
    for (final snapshot in snapshots.where(
      (snapshot) => snapshot.trackId == track.id,
    )) {
      expect(
        snapshot.position + const Duration(milliseconds: 150),
        greaterThanOrEqualTo(lastPosition),
        reason:
            'Skip silence must not make the visible playback clock jump back.',
      );
      if (snapshot.position > lastPosition) {
        lastPosition = snapshot.position;
      }
    }
    final declaredDuration = track.duration;
    if (declaredDuration != null) {
      expect(
        maxPosition + const Duration(milliseconds: 150),
        greaterThanOrEqualTo(declaredDuration),
        reason: 'Skip silence must preserve the original media timeline.',
      );
    }
    expect(
      snapshots.where((snapshot) => snapshot.status == PlayerStatus.failed),
      isEmpty,
      reason: 'Native playback emitted a failure state.',
    );
    return watch.elapsed;
  } finally {
    await subscription.cancel();
    await service.dispose();
  }
}

Future<Duration> _measureRemotePlayback(
  Uri uri, {
  required String id,
  required Duration duration,
  required bool skipSilenceEnabled,
}) async {
  final service = JustAudioPlayerService();
  final snapshots = <PlayerSnapshot>[];
  final subscription = service.snapshotStream.listen(snapshots.add);
  final track = TrackInfo(
    id: id,
    title: id,
    artist: 'BStream slow CDN integration test',
    url: uri.toString(),
    streamUrl: uri.toString(),
    streamExtension: 'wav',
    streamMimeType: 'audio/wav',
    duration: duration,
  );
  try {
    await service.setVolume(0.01);
    await service.configureSkipSilence(enabled: skipSilenceEnabled);
    await service.playRemote(track);
    await _waitUntil(
      () => service.currentSnapshot.status == PlayerStatus.playing,
      timeout: const Duration(seconds: 12),
      diagnostic: () => service.currentSnapshot.toString(),
    );

    final watch = Stopwatch()..start();
    await _waitUntil(
      () => service.currentSnapshot.status == PlayerStatus.completed,
      timeout: duration + const Duration(seconds: 15),
      diagnostic: () => service.currentSnapshot.toString(),
    );
    watch.stop();
    // ignore: avoid_print
    print(
      'slow-stream skip-silence $id: enabled=$skipSilenceEnabled, '
      'elapsed=${watch.elapsed}, snapshot=${service.currentSnapshot}',
    );

    var lastPosition = Duration.zero;
    for (final snapshot in snapshots.where(
      (snapshot) => snapshot.trackId == id,
    )) {
      expect(
        snapshot.position + const Duration(milliseconds: 150),
        greaterThanOrEqualTo(lastPosition),
        reason: 'A slow response must not make the media timeline jump back.',
      );
      if (snapshot.position > lastPosition) {
        lastPosition = snapshot.position;
      }
    }
    expect(
      lastPosition + const Duration(milliseconds: 150),
      greaterThanOrEqualTo(duration),
      reason: 'Skipping must keep the original remote media timeline.',
    );
    expect(
      snapshots.where((snapshot) => snapshot.status == PlayerStatus.failed),
      isEmpty,
      reason: 'Slow streaming must not emit a playback failure.',
    );
    return watch.elapsed;
  } finally {
    await subscription.cancel();
    await service.dispose();
  }
}

Future<Duration> _measureCrossfadeHandoff(
  LocalTrack outgoing,
  LocalTrack incoming, {
  required bool skipSilenceEnabled,
}) async {
  final service = JustAudioPlayerService();
  final crossfade = service as CrossfadeCapablePlayer;
  final snapshots = <PlayerSnapshot>[];
  final subscription = service.snapshotStream.listen(snapshots.add);
  try {
    await service.setVolume(0.01);
    await service.configureSkipSilence(enabled: skipSilenceEnabled);
    await service.playLocalQueue([outgoing, incoming], 0);
    await _waitUntil(
      () => service.currentSnapshot.duration != null,
      timeout: const Duration(seconds: 8),
      diagnostic: () => service.currentSnapshot.toString(),
    );
    await service.pause();
    await crossfade.configureCrossfade(
      enabled: true,
      duration: const Duration(milliseconds: 700),
    );
    await crossfade.prepareCrossfade(LocalCrossfadePlaybackSource(incoming));
    await service.seek(Duration.zero);

    final watch = Stopwatch()..start();
    await service.resume();
    await _waitUntil(
      () => service.currentSnapshot.trackId == incoming.id,
      timeout: const Duration(seconds: 15),
      diagnostic: () => service.currentSnapshot.toString(),
    );
    watch.stop();

    // ignore: avoid_print
    print(
      'skip-silence crossfade: enabled=$skipSilenceEnabled, '
      'elapsed=${watch.elapsed}, snapshot=${service.currentSnapshot}',
    );
    expect(service.currentSnapshot.status, PlayerStatus.playing);
    final handoffPosition = service.currentSnapshot.position;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(service.currentSnapshot.trackId, incoming.id);
    expect(
      service.currentSnapshot.position,
      greaterThanOrEqualTo(handoffPosition),
      reason: 'The promoted deck must keep advancing after the handoff.',
    );
    expect(
      service.currentSnapshot.position,
      greaterThanOrEqualTo(const Duration(milliseconds: 250)),
      reason: 'The successor must remain audible instead of restarting.',
    );
    expect(
      snapshots.where((snapshot) => snapshot.status == PlayerStatus.failed),
      isEmpty,
      reason: 'Silence processing must not introduce a crossfade failure.',
    );
    expect(
      snapshots.map((snapshot) => snapshot.trackId).whereType<String>().fold(
        <String>[],
        (order, id) {
          if (order.isEmpty || order.last != id) {
            order.add(id);
          }
          return order;
        },
      ),
      orderedEquals([outgoing.id, incoming.id]),
      reason: 'The silent outro must promote its successor exactly once.',
    );
    return watch.elapsed;
  } finally {
    await subscription.cancel();
    await service.dispose();
  }
}

Future<LocalTrack> _writeTrack(
  Directory directory,
  String id,
  List<_WaveSegment> segments,
) async {
  final duration = segments.fold(
    Duration.zero,
    (total, segment) => total + segment.duration,
  );
  final file = File('${directory.path}${Platform.pathSeparator}$id.wav');
  await file.writeAsBytes(_stereoWave(segments));
  return LocalTrack(
    id: id,
    title: id,
    artist: 'BStream integration test',
    filePath: file.path,
    duration: duration,
    addedAt: DateTime(2026),
  );
}

Future<void> _waitUntil(
  bool Function() condition, {
  required Duration timeout,
  String Function()? diagnostic,
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed >= timeout) {
      fail(
        'Native playback did not reach the expected state in $timeout: '
        '${diagnostic?.call()}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Uint8List _stereoWave(List<_WaveSegment> segments) {
  const sampleRate = 8000;
  const channelCount = 2;
  const bitsPerSample = 16;
  final frameCount = segments.fold<int>(
    0,
    (total, segment) =>
        total + (sampleRate * segment.duration.inMicroseconds ~/ 1000000),
  );
  final dataLength = frameCount * channelCount * bitsPerSample ~/ 8;
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

  var outputFrame = 0;
  for (final segment in segments) {
    final segmentFrames =
        sampleRate * segment.duration.inMicroseconds ~/ 1000000;
    for (var localFrame = 0; localFrame < segmentFrames; localFrame++) {
      final progress = segmentFrames <= 1
          ? 1.0
          : localFrame / (segmentFrames - 1);
      final peak = segment.isDecay
          ? segment.initialPeak *
                math.exp(
                  -math.log(segment.initialPeak / segment.finalPeak) * progress,
                )
          : segment.initialPeak.toDouble();
      final phase = 2 * math.pi * 440 * outputFrame / sampleRate;
      final sample = (math.sin(phase) * peak).round();
      for (var channel = 0; channel < channelCount; channel++) {
        final sampleOffset = 44 + ((outputFrame * channelCount + channel) * 2);
        data.setInt16(sampleOffset, sample, Endian.little);
      }
      outputFrame++;
    }
  }
  return bytes;
}

final class _ThrottledWaveServer {
  _ThrottledWaveServer._(this._server, this._tracks) {
    _subscription = _server.listen(_handleRequest);
  }

  static Future<_ThrottledWaveServer> start(
    Map<String, Uint8List> tracks,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _ThrottledWaveServer._(server, tracks);
  }

  static const _chunkBytes = 4096;
  static const _jitter = <Duration>[
    Duration(milliseconds: 35),
    Duration(milliseconds: 80),
    Duration(milliseconds: 45),
    Duration(milliseconds: 110),
    Duration(milliseconds: 55),
  ];

  final HttpServer _server;
  final Map<String, Uint8List> _tracks;
  late final StreamSubscription<HttpRequest> _subscription;
  int completedResponses = 0;

  Uri uriFor(String path) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server.port,
    path: path,
  );

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final bytes = _tracks[request.uri.path];
    if (bytes == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final range = _parseRange(request.headers.value(HttpHeaders.rangeHeader));
    if (range != null && range.start >= bytes.length) {
      request.response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
      await request.response.close();
      return;
    }

    final start = range?.start ?? 0;
    final endInclusive = math.min(
      range?.endInclusive ?? bytes.length - 1,
      bytes.length - 1,
    );
    final response = request.response;
    response
      ..bufferOutput = false
      ..headers.contentType = ContentType('audio', 'wav')
      ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentLength = endInclusive - start + 1;
    if (range != null) {
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$endInclusive/${bytes.length}',
        );
    }
    if (request.method == 'HEAD') {
      await response.close();
      completedResponses++;
      return;
    }

    var offset = start;
    var chunkIndex = 0;
    try {
      while (offset <= endInclusive) {
        final next = math.min(offset + _chunkBytes, endInclusive + 1);
        response.add(Uint8List.sublistView(bytes, offset, next));
        await response.flush();
        offset = next;
        if (offset <= endInclusive) {
          await Future<void>.delayed(_jitter[chunkIndex % _jitter.length]);
          chunkIndex++;
        }
      }
      await response.close();
      completedResponses++;
    } on HttpException {
      // ExoPlayer may close a range as soon as it has enough buffered data.
    } on SocketException {
      // The server is intentionally force-closed during test teardown.
    }
  }

  _ByteRange? _parseRange(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    if (start == null) return null;
    final rawEnd = match.group(2)!;
    return _ByteRange(start, rawEnd.isEmpty ? null : int.tryParse(rawEnd));
  }
}

final class _ByteRange {
  const _ByteRange(this.start, this.endInclusive);

  final int start;
  final int? endInclusive;
}

final class _WaveSegment {
  const _WaveSegment.tone(this.duration, {required int peak})
    : initialPeak = peak,
      finalPeak = peak,
      isDecay = false;

  const _WaveSegment.silence(this.duration)
    : initialPeak = 0,
      finalPeak = 0,
      isDecay = false;

  const _WaveSegment.decay(
    this.duration, {
    required this.initialPeak,
    required this.finalPeak,
  }) : assert(initialPeak > 0),
       assert(finalPeak > 0),
       isDecay = true;

  final Duration duration;
  final int initialPeak;
  final int finalPeak;
  final bool isDecay;
}
