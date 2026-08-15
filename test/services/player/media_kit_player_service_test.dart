import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/player/media_kit_player_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test(
    'a hung open cannot block a newer selection or overwrite it late',
    () async {
      final backend = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(backend: backend);
      addTearDown(service.dispose);

      final first = service.playRemote(_track('a'));
      await _waitUntil(() => backend.openCalls.length == 1);

      final second = service.playRemote(_track('b'));
      await _waitUntil(() => backend.openCalls.length == 2);
      backend.completeOpen(1);
      await Future.wait([first, second]);

      expect(backend.abandonCalls, 1);
      expect(backend.currentSourceId, 'b');
      expect(service.currentSnapshot.trackId, 'b');
      expect(service.currentSnapshot.status, PlayerStatus.playing);

      // A is still alive, but belongs to a retired backend and cannot replace B.
      backend.completeOpen(0);
      backend.emitErrorForSession(0, 'late failure from a');
      await _drainEvents();
      expect(backend.currentSourceId, 'b');
      expect(service.currentSnapshot.trackId, 'b');
      expect(service.currentSnapshot.status, PlayerStatus.playing);

      backend.emitErrorForSession(1, 'current failure from b');
      await _drainEvents();
      expect(service.currentSnapshot.status, PlayerStatus.failed);
      expect(service.currentSnapshot.errorMessage, 'current failure from b');
    },
  );

  test(
    'stop finishes while open never completes and wins late completion',
    () async {
      final backend = _FakeMediaKitBackend();
      final service = MediaKitPlayerService(backend: backend);
      addTearDown(service.dispose);

      final play = service.playRemote(_track('a'));
      await _waitUntil(() => backend.openCalls.length == 1);
      final stop = service.stop();
      await Future.wait([play, stop]);

      expect(backend.abandonCalls, 1);
      expect(backend.stopCalls, 1);
      expect(backend.currentSourceId, isNull);
      expect(service.currentSnapshot.status, PlayerStatus.stopped);

      backend.completeOpen(0);
      await _drainEvents();
      expect(backend.currentSourceId, isNull);
      expect(service.currentSnapshot.status, PlayerStatus.stopped);
    },
  );

  test(
    'deadline retires a hung native open and publishes its failure',
    () async {
      final backend = _FakeMediaKitBackend();
      final deadline = Completer<void>();
      final service = MediaKitPlayerService(
        backend: backend,
        operationTimeout: const Duration(seconds: 1),
        operationDeadline: (_) => deadline.future,
      );
      addTearDown(service.dispose);

      final play = service.playRemote(_track('a'));
      await _waitUntil(() => backend.openCalls.length == 1);
      deadline.complete();

      await expectLater(play, throwsA(isA<TimeoutException>()));
      expect(backend.abandonCalls, 1);
      expect(service.currentSnapshot.status, PlayerStatus.failed);

      backend.completeOpen(0);
      await _drainEvents();
      expect(backend.currentSourceId, isNull);
      expect(service.currentSnapshot.status, PlayerStatus.failed);
    },
  );

  test('dispose finishes while an open remains hung', () async {
    final backend = _FakeMediaKitBackend();
    final service = MediaKitPlayerService(backend: backend);

    final play = service.playRemote(_track('a'));
    await _waitUntil(() => backend.openCalls.length == 1);
    await service.dispose();
    await play;

    expect(backend.abandonCalls, 1);
    expect(backend.disposed, isTrue);
  });
}

TrackInfo _track(String id) => TrackInfo(
  id: id,
  title: 'Track $id',
  artist: 'Artist',
  url: 'https://www.youtube.com/watch?v=$id',
  streamUrl: 'https://media.example/$id.m4a',
);

Future<void> _drainEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition did not become true.');
}

class _OpenCall {
  _OpenCall(this.media, this.session);
  final Media media;
  final int session;
  final completer = Completer<void>();
}

class _FakeMediaKitBackend implements MediaKitPlayerBackend {
  final positions = StreamController<Duration>.broadcast();
  final durations = StreamController<Duration>.broadcast();
  final volumes = StreamController<double>.broadcast();
  final bufferings = StreamController<bool>.broadcast();
  final playings = StreamController<bool>.broadcast();
  final completions = StreamController<bool>.broadcast();
  final errors = StreamController<String>.broadcast();
  final openCalls = <_OpenCall>[];

  int session = 0;
  int abandonCalls = 0;
  int stopCalls = 0;
  String? currentSourceId;
  bool disposed = false;

  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration> get durationStream => durations.stream;
  @override
  Stream<double> get volumeStream => volumes.stream;
  @override
  Stream<bool> get bufferingStream => bufferings.stream;
  @override
  Stream<bool> get playingStream => playings.stream;
  @override
  Stream<bool> get completedStream => completions.stream;
  @override
  Stream<String> get errorStream => errors.stream;
  @override
  Object? get platform => null;

  @override
  void abandonPendingOperations() {
    abandonCalls++;
    session++;
    currentSourceId = null;
  }

  @override
  Future<void> open(Media media, {required bool play}) {
    final call = _OpenCall(media, session);
    openCalls.add(call);
    return call.completer.future;
  }

  void completeOpen(int index) {
    final call = openCalls[index];
    if (call.session == session) currentSourceId = _id(call.media);
    call.completer.complete();
  }

  void emitErrorForSession(int sourceSession, String message) {
    if (sourceSession == session) errors.add(message);
  }

  String _id(Media media) =>
      Uri.parse(media.uri).pathSegments.last.split('.').first;

  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> stop() async {
    stopCalls++;
    currentSourceId = null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await Future.wait<void>([
      positions.close(),
      durations.close(),
      volumes.close(),
      bufferings.close(),
      playings.close(),
      completions.close(),
      errors.close(),
    ]);
  }
}
