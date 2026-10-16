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

    test('retains playback intent while the next stream is loading', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.loading, playWhenReady: true),
      );

      expect(state.processingState, AudioProcessingState.loading);
      expect(state.playing, isTrue);
      expect(state.controls.first.action, MediaAction.pause);
      expect(state.errorCode, isNull);
      expect(state.errorMessage, isNull);
    });

    test('does not turn an explicitly paused load into active playback', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.loading, playWhenReady: false),
      );

      expect(state.processingState, AudioProcessingState.loading);
      expect(state.playing, isFalse);
      expect(state.controls.first.action, MediaAction.play);
    });

    test('reports a recoverable stream error as active loading', () {
      final state = buildAudioServicePlaybackState(
        _state(
          PlayerStatus.failed,
          playWhenReady: true,
          errorMessage: 'A temporary network failure',
        ),
      );

      expect(state.processingState, AudioProcessingState.loading);
      expect(state.playing, isTrue);
      expect(state.controls.first.action, MediaAction.pause);
      expect(state.errorCode, isNull);
      expect(state.errorMessage, isNull);
    });

    test('releases playback intent when stream recovery is exhausted', () {
      final state = buildAudioServicePlaybackState(
        _state(
          PlayerStatus.failed,
          playWhenReady: false,
          errorMessage: 'Recovery exhausted',
        ),
      );

      expect(state.processingState, AudioProcessingState.error);
      expect(state.playing, isFalse);
      expect(state.controls.first.action, MediaAction.play);
      expect(state.errorCode, 1);
      expect(state.errorMessage, 'Recovery exhausted');
    });

    test(
      'keeps foreground playback while a completed item has a successor',
      () {
        final state = buildAudioServicePlaybackState(
          _state(PlayerStatus.completed, playWhenReady: true, queueLength: 2),
        );

        expect(state.processingState, AudioProcessingState.loading);
        expect(state.playing, isTrue);
        expect(state.controls[1].action, MediaAction.pause);
      },
    );

    test('reports final completion without keeping playback active', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.completed, playWhenReady: false),
      );

      expect(state.processingState, AudioProcessingState.completed);
      expect(state.playing, isFalse);
      expect(state.controls.first.action, MediaAction.play);
    });

    test('honors pause intent even before the player status settles', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.playing, playWhenReady: false),
      );

      expect(state.processingState, AudioProcessingState.ready);
      expect(state.playing, isFalse);
      expect(state.controls.first.action, MediaAction.play);
    });

    test('keeps automatic gaps active until a deliberate pause or stop', () {
      final states = [
        for (final status in [
          PlayerStatus.playing,
          PlayerStatus.loading,
          PlayerStatus.failed,
          PlayerStatus.completed,
          PlayerStatus.loading,
          PlayerStatus.playing,
        ])
          buildAudioServicePlaybackState(_state(status, playWhenReady: true)),
      ];

      expect(states.every((state) => state.playing), isTrue);
      expect(
        states.map((state) => state.processingState),
        isNot(contains(AudioProcessingState.idle)),
      );
      for (final status in [PlayerStatus.paused, PlayerStatus.stopped]) {
        final state = buildAudioServicePlaybackState(
          _state(status, playWhenReady: false),
        );
        expect(state.playing, isFalse);
        expect(state.controls.first.action, MediaAction.play);
      }
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

DesktopMediaSessionState _state(
  PlayerStatus status, {
  int queueLength = 1,
  bool? playWhenReady,
  String? errorMessage,
}) {
  return DesktopMediaSessionState(
    snapshot: PlayerSnapshot(
      status: status,
      playWhenReady: playWhenReady,
      errorMessage: errorMessage,
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
