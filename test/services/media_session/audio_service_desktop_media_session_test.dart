import 'dart:async';

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

    test('publishes transport actions without a stop button', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.playing, queueLength: 2),
      );

      expect(state.controls.map((control) => control.action), const [
        MediaAction.custom,
        MediaAction.skipToPrevious,
        MediaAction.pause,
        MediaAction.skipToNext,
        MediaAction.custom,
      ]);
      expect(state.controls.first.customAction?.name, notificationRepeatAction);
      expect(
        state.controls.last.customAction?.name,
        notificationFavoriteAction,
      );
      expect(state.androidCompactActionIndices, const [1, 2, 3]);
      expect(
        state.controls.map((control) => control.action),
        isNot(contains(MediaAction.stop)),
      );
    });

    test('uses only play as a compact action for a single paused item', () {
      final state = buildAudioServicePlaybackState(_state(PlayerStatus.paused));

      expect(state.controls.map((control) => control.action), const [
        MediaAction.custom,
        MediaAction.play,
        MediaAction.custom,
      ]);
      expect(state.androidCompactActionIndices, const [1]);
    });

    test(
      'repeat controls reflect all three modes and translated next action',
      () {
        const labels = DesktopMediaControlLabels(
          repeatQueue: 'Repetir cola',
          repeatOne: 'Repetir una',
          disableRepeat: 'Desactivar repetir',
        );
        for (final entry in [
          (PlaybackRepeatMode.off, 'bstream_widget_repeat', labels.repeatQueue),
          (
            PlaybackRepeatMode.all,
            'bstream_notification_repeat_all',
            labels.repeatOne,
          ),
          (
            PlaybackRepeatMode.one,
            'bstream_notification_repeat_one',
            labels.disableRepeat,
          ),
        ]) {
          final state = buildAudioServicePlaybackState(
            _state(
              PlayerStatus.playing,
              repeatMode: entry.$1,
              controlLabels: labels,
            ),
          );
          final repeat = state.controls.first;
          expect(repeat.customAction?.name, notificationRepeatAction);
          expect(repeat.androidIcon, 'drawable/${entry.$2}');
          expect(repeat.label, entry.$3);
        }
      },
    );

    test('favorite control switches its heart and translated action', () {
      const labels = DesktopMediaControlLabels(
        addToFavorites: 'Añadir a favoritos',
        removeFromFavorites: 'Quitar de favoritos',
      );
      final add = buildAudioServicePlaybackState(
        _state(PlayerStatus.paused, controlLabels: labels),
      ).controls.last;
      final remove = buildAudioServicePlaybackState(
        _state(PlayerStatus.paused, isFavorite: true, controlLabels: labels),
      ).controls.last;
      expect(add.customAction?.name, notificationFavoriteAction);
      expect(remove.customAction?.name, notificationFavoriteAction);
      expect(add.androidIcon, 'drawable/bstream_widget_heart_outline');
      expect(remove.androidIcon, 'drawable/bstream_widget_heart_filled');
      expect(add.label, labels.addToFavorites);
      expect(remove.label, labels.removeFromFavorites);
    });

    test('does not advertise favorites for external audio', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.paused, isExternal: true),
      );
      expect(
        state.controls.map((control) => control.customAction?.name),
        isNot(contains(notificationFavoriteAction)),
      );
      expect(state.androidCompactActionIndices, [1]);
    });

    test('recreated translated labels compare by their values', () {
      const first = DesktopMediaControlLabels(repeatQueue: 'Repetir cola');
      final second = DesktopMediaControlLabels(repeatQueue: 'Repetir cola');
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first, isNot(const DesktopMediaControlLabels()));
    });

    test('retains playback intent while the next stream is loading', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.loading, playWhenReady: true),
      );

      expect(state.processingState, AudioProcessingState.loading);
      expect(state.playing, isTrue);
      expect(_primaryTransport(state).action, MediaAction.pause);
      expect(state.errorCode, isNull);
      expect(state.errorMessage, isNull);
    });

    test('does not turn an explicitly paused load into active playback', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.loading, playWhenReady: false),
      );

      expect(state.processingState, AudioProcessingState.loading);
      expect(state.playing, isFalse);
      expect(_primaryTransport(state).action, MediaAction.play);
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
      expect(_primaryTransport(state).action, MediaAction.pause);
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
      expect(_primaryTransport(state).action, MediaAction.play);
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
        expect(_primaryTransport(state).action, MediaAction.pause);
      },
    );

    test('reports final completion without keeping playback active', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.completed, playWhenReady: false),
      );

      expect(state.processingState, AudioProcessingState.completed);
      expect(state.playing, isFalse);
      expect(_primaryTransport(state).action, MediaAction.play);
    });

    test('honors pause intent even before the player status settles', () {
      final state = buildAudioServicePlaybackState(
        _state(PlayerStatus.playing, playWhenReady: false),
      );

      expect(state.processingState, AudioProcessingState.ready);
      expect(state.playing, isFalse);
      expect(_primaryTransport(state).action, MediaAction.play);
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
        expect(_primaryTransport(state).action, MediaAction.play);
      }
    });
  });

  group('AudioServiceMediaSessionCallbackBridge', () {
    test(
      'routes repeated repeat/favorite commands without dropping presses',
      () async {
        final calls = <String>[];
        final bridge = AudioServiceMediaSessionCallbackBridge();
        bridge.attach(_callbacks('active', calls));
        await bridge.customAction(notificationRepeatAction);
        await bridge.customAction(notificationRepeatAction);
        await bridge.customAction(notificationFavoriteAction);
        await bridge.customAction('unknown');
        expect(calls, [
          'active:cycleRepeat',
          'active:cycleRepeat',
          'active:favorite',
        ]);
      },
    );

    test(
      'restores custom actions through the existing cold-start backlog',
      () async {
        final calls = <String>[];
        final bridge = AudioServiceMediaSessionCallbackBridge();
        final repeat = bridge.customAction(notificationRepeatAction);
        final favorite = bridge.customAction(notificationFavoriteAction);
        bridge.attach(_callbacks('restored', calls));
        await Future.wait([repeat, favorite]);
        expect(calls, ['restored:cycleRepeat', 'restored:favorite']);
      },
    );
    test('attaching a restored session does not start playback', () {
      final calls = <String>[];
      final bridge = AudioServiceMediaSessionCallbackBridge();

      bridge.attach(_callbacks('restored', calls));

      expect(calls, isEmpty);
    });

    test('retains the first cold-start play until callbacks attach', () async {
      final calls = <String>[];
      final bridge = AudioServiceMediaSessionCallbackBridge();
      var completed = false;
      final play = bridge.play().then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(calls, isEmpty);

      bridge.attach(_callbacks('restored', calls));
      await play;
      bridge.attach(_callbacks('replacement', calls));

      expect(calls, ['restored:play']);
    });

    test('cold-start pause is not blocked by a pending play', () async {
      final calls = <String>[];
      final bridge = AudioServiceMediaSessionCallbackBridge();
      final releasePlay = Completer<void>();
      final play = bridge.play();
      final pause = bridge.pause();

      bridge.attach(
        _callbacks('restored', calls, playBarrier: releasePlay.future),
      );
      await pause;
      expect(calls, ['restored:play', 'restored:pause']);
      releasePlay.complete();
      await play;
    });

    test('bounds the cold-start command backlog', () async {
      final calls = <String>[];
      final bridge = AudioServiceMediaSessionCallbackBridge();
      final commands = List.generate(9, (_) => bridge.next());
      // The oldest excess command is retired even if startup never finishes.
      await commands.first;

      bridge.attach(_callbacks('restored', calls));
      await Future.wait(commands);

      expect(calls, List.filled(8, 'restored:next'));
    });

    test('expires a cold-start intent instead of playing it later', () async {
      final calls = <String>[];
      final bridge = AudioServiceMediaSessionCallbackBridge(
        startupCommandTimeout: Duration.zero,
      );

      await bridge.play();
      bridge.attach(_callbacks('restored', calls));
      expect(calls, isEmpty);
      await bridge.play();

      expect(calls, ['restored:play']);
    });

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
      await bridge.customAction(notificationRepeatAction);
      await bridge.customAction(notificationFavoriteAction);

      expect(calls, ['active:next']);
    });
  });
}

DesktopMediaSessionState _state(
  PlayerStatus status, {
  int queueLength = 1,
  bool? playWhenReady,
  String? errorMessage,
  PlaybackRepeatMode repeatMode = PlaybackRepeatMode.off,
  bool isFavorite = false,
  bool isExternal = false,
  DesktopMediaControlLabels controlLabels = const DesktopMediaControlLabels(),
}) {
  return DesktopMediaSessionState(
    snapshot: PlayerSnapshot(
      status: status,
      playWhenReady: playWhenReady,
      errorMessage: errorMessage,
      repeatMode: repeatMode,
      isExternal: isExternal,
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
    isFavorite: isFavorite,
    controlLabels: controlLabels,
  );
}

DesktopMediaSessionCallbacks _callbacks(
  String name,
  List<String> calls, {
  Future<void>? playBarrier,
}) {
  return DesktopMediaSessionCallbacks(
    play: () async {
      calls.add('$name:play');
      await playBarrier;
    },
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
    cycleRepeatMode: () async => calls.add('$name:cycleRepeat'),
    toggleFavorite: () async => calls.add('$name:favorite'),
  );
}

MediaControl _primaryTransport(PlaybackState state) =>
    state.controls.firstWhere(
      (control) =>
          control.action == MediaAction.play ||
          control.action == MediaAction.pause,
    );
