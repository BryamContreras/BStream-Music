import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/recommendations/recommendation_storage_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses 40 percent for short tracks and caps the threshold at 30s', () {
    expect(
      QualifiedPlaybackHistoryTracker.qualificationThreshold(
        const Duration(seconds: 10),
      ),
      const Duration(seconds: 4),
    );
    expect(
      QualifiedPlaybackHistoryTracker.qualificationThreshold(
        const Duration(minutes: 4),
      ),
      const Duration(seconds: 30),
    );
    expect(
      QualifiedPlaybackHistoryTracker.qualificationThreshold(null),
      const Duration(seconds: 30),
    );
  });

  test(
    'counts only monotonic playing time and ignores a seek-like update',
    () async {
      final writes = <PlaybackHistoryWrite>[];
      final tracker = _tracker(writes);
      await tracker.setEnabled(true);
      final track = _track(duration: const Duration(milliseconds: 500));

      tracker.update(track: track, status: PlayerStatus.playing);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // A player position can jump here; the tracker deliberately receives no
      // media position and therefore cannot turn a seek into listened time.
      tracker.update(track: track, status: PlayerStatus.playing);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(writes, isEmpty);

      await _waitUntil(() => writes.isNotEmpty);
      expect(writes, hasLength(1));
      expect(writes.single.event.listenedMs, greaterThanOrEqualTo(200));
      expect(writes.single.event.videoId, 'abcdefghijk');
      expect(writes.single.event.artistBrowseIds, ['UC-artist']);
      expect(writes.single.isInitialQualification, isTrue);

      await tracker.dispose();
    },
  );

  test('pause time is excluded and completion reuses the session id', () async {
    final writes = <PlaybackHistoryWrite>[];
    var nextSession = 0;
    final tracker = _tracker(
      writes,
      sessionIdFactory: () => 'session-${++nextSession}',
    );
    await tracker.setEnabled(true);
    final track = _track(duration: const Duration(seconds: 1));

    tracker.update(track: track, status: PlayerStatus.playing);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    tracker.update(track: track, status: PlayerStatus.paused);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(writes, isEmpty);

    tracker.update(track: track, status: PlayerStatus.playing);
    await _waitUntil(() => writes.isNotEmpty);
    expect(writes.single.event.sessionId, 'session-1');
    expect(writes.single.event.completed, isFalse);

    tracker.update(track: track, status: PlayerStatus.completed);
    await _waitUntil(() => writes.length == 2);
    expect(writes.last.event.sessionId, 'session-1');
    expect(writes.last.event.completed, isTrue);
    expect(writes.last.isInitialQualification, isFalse);

    tracker.update(track: track, status: PlayerStatus.playing);
    await _waitUntil(() => writes.length == 3);
    expect(writes.last.event.sessionId, 'session-2');

    await tracker.dispose();
  });

  test('disabled tracking discards partial listening', () async {
    final writes = <PlaybackHistoryWrite>[];
    final tracker = _tracker(writes);
    final track = _track(duration: const Duration(milliseconds: 500));

    await tracker.setEnabled(true);
    tracker.update(track: track, status: PlayerStatus.playing);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tracker.setEnabled(false);
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(writes, isEmpty);

    await tracker.setEnabled(true);
    tracker.update(track: track, status: PlayerStatus.playing);
    await _waitUntil(() => writes.isNotEmpty);
    expect(writes, hasLength(1));

    await tracker.dispose();
  });

  test('a terminal skip updates the qualified session listened time', () async {
    final writes = <PlaybackHistoryWrite>[];
    final tracker = _tracker(writes);
    await tracker.setEnabled(true);
    final track = _track(duration: const Duration(milliseconds: 500));

    tracker.update(track: track, status: PlayerStatus.playing);
    await _waitUntil(() => writes.isNotEmpty);
    final qualifiedMs = writes.single.event.listenedMs;
    await Future<void>.delayed(const Duration(milliseconds: 80));

    tracker.update(track: track, status: PlayerStatus.stopped);
    await _waitUntil(() => writes.length == 2);

    expect(writes.last.event.sessionId, writes.first.event.sessionId);
    expect(writes.last.event.listenedMs, greaterThan(qualifiedMs));
    expect(writes.last.event.completed, isFalse);
    expect(writes.last.isInitialQualification, isFalse);

    await tracker.dispose();
  });
}

QualifiedPlaybackHistoryTracker _tracker(
  List<PlaybackHistoryWrite> writes, {
  String Function()? sessionIdFactory,
}) {
  return QualifiedPlaybackHistoryTracker(
    onWrite: (write) async => writes.add(write),
    sessionIdFactory: sessionIdFactory ?? () => 'session',
  );
}

PlaybackHistoryTrack _track({required Duration duration}) {
  return PlaybackHistoryTrack(
    logicalKey: 'remote:queue:0',
    trackId: 'abcdefghijk',
    videoId: 'abcdefghijk',
    title: 'Track',
    artists: const ['Artist'],
    artistBrowseIds: const ['UC-artist'],
    album: 'Album',
    thumbnailUrl: 'https://example.test/art.jpg',
    duration: duration,
    source: PlaybackEventSource.streaming,
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for the qualified playback write.');
}
