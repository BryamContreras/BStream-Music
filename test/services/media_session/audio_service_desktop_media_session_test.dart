import 'package:audio_service/audio_service.dart';
import 'package:bstream_music/services/media_session/audio_service_desktop_media_session.dart';
import 'package:bstream_music/services/media_session/desktop_media_session.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildAudioServicePlaybackState', () {
    test('keeps natural completion distinct from an explicit stop', () {
      final completed = buildAudioServicePlaybackState(
        _state(PlayerStatus.completed),
      );
      final stopped = buildAudioServicePlaybackState(
        _state(PlayerStatus.stopped),
      );

      expect(completed.processingState, AudioProcessingState.completed);
      expect(completed.playing, isFalse);
      expect(stopped.processingState, AudioProcessingState.idle);
      expect(stopped.playing, isFalse);
    });

    test('publishes previous, pause and next as compact actions', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.playing, queueLength: 2),
      );

      expect(state.controls.map((control) => control.action), const [
        MediaAction.skipToPrevious,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.stop,
      ]);
      expect(state.androidCompactActionIndices, const [0, 1, 2]);
      expect(
        state.androidCompactActionIndices!.map(
          (index) => state.controls[index].action,
        ),
        isNot(contains(MediaAction.stop)),
      );
    });

    test('uses only play as a compact action for a single paused item', () {
      final state = buildAudioServicePlaybackState(_state(PlayerStatus.paused));

      expect(state.controls.map((control) => control.action), const [
        MediaAction.play,
        MediaAction.stop,
      ]);
      expect(state.androidCompactActionIndices, const [0]);
    });
  });

  group('AudioServiceMediaSessionCallbackBridge', () {
    test('replaces callbacks and ignores a stale detach', () async {
      final calls = <String>[];
      final bridge = AudioServiceMediaSessionCallbackBridge();
      final first = _callbacks('first', calls);
      final second = _callbacks('second', calls);

      bridge.attach(first);
      await bridge.play();

      bridge.attach(second);
      expect(bridge.detach(first), isFalse);
      await bridge.pause();
      await bridge.seek(const Duration(seconds: 12));

      expect(calls, ['first:play', 'second:pause', 'second:seek:12000']);
    });

    test('detaching the active callbacks makes commands harmless', () async {
      final calls = <String>[];
      final bridge = AudioServiceMediaSessionCallbackBridge();
      final callbacks = _callbacks('active', calls);

      bridge.attach(callbacks);
      await bridge.next();
      expect(bridge.detach(callbacks), isTrue);
      await bridge.next();
      await bridge.stop();
      await bridge.setShuffleEnabled(true);
      await bridge.setRepeatMode(PlaybackRepeatMode.one);

      expect(calls, ['active:next']);
    });
  });
}

DesktopMediaSessionState _state(PlayerStatus status, {int queueLength = 1}) {
  return DesktopMediaSessionState(
    snapshot: PlayerSnapshot(
      status: status,
      trackId: 'track-1',
      title: 'Track 1',
      artist: 'Artist',
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 3),
    ),
    queue: [
      for (var index = 0; index < queueLength; index++)
        DesktopMediaQueueItem(
          id: 'track-$index',
          title: 'Track $index',
          artist: 'Artist',
        ),
    ],
    currentIndex: 0,
  );
}

DesktopMediaSessionCallbacks _callbacks(String name, List<String> calls) {
  return DesktopMediaSessionCallbacks(
    play: () async => calls.add('$name:play'),
    pause: () async => calls.add('$name:pause'),
    togglePlayPause: () async => calls.add('$name:toggle'),
    next: () async => calls.add('$name:next'),
    previous: () async => calls.add('$name:previous'),
    stop: () async => calls.add('$name:stop'),
    seek: (position) async =>
        calls.add('$name:seek:${position.inMilliseconds}'),
    seekBy: (position) async =>
        calls.add('$name:seekBy:${position.inMilliseconds}'),
    setShuffleEnabled: (enabled) async => calls.add('$name:shuffle:$enabled'),
    setRepeatMode: (mode) async => calls.add('$name:repeat:${mode.name}'),
    playQueueIndex: (index) async => calls.add('$name:index:$index'),
  );
}
