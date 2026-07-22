import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../player/player_service.dart';
import 'desktop_media_session.dart';

class AudioServiceDesktopMediaSession implements DesktopMediaSession {
  _DesktopAudioHandler? _handler;
  DesktopMediaSessionState? _latestState;
  Timer? _positionTimer;

  bool _disposed = false;
  String? _lastTrackKey;
  String? _lastQueueKey;
  PlayerStatus? _lastStatus;
  bool? _lastShuffleEnabled;
  PlaybackRepeatMode? _lastRepeatMode;
  DateTime? _lastPositionUpdate;

  @override
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks) async {
    try {
      late final _DesktopAudioHandler handler;
      await AudioService.init(
        builder: () {
          handler = _DesktopAudioHandler(callbacks);
          return handler;
        },
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.bstream.bstream_music.audio',
          androidNotificationChannelName: 'BStream Music',
          androidNotificationChannelDescription: 'BStream Music playback',
          androidNotificationOngoing: true,
        ),
      );
      if (_disposed) {
        handler.publishIdle();
        return;
      }
      _handler = handler;
      final latestState = _latestState;
      if (latestState != null) {
        await _sync(latestState, force: true);
      }
    } catch (error) {
      debugPrint('Desktop audio service could not be initialized: $error');
    }
  }

  @override
  Future<void> update(DesktopMediaSessionState state) async {
    _latestState = state;
    if (_disposed || _handler == null) {
      return;
    }

    final snapshot = state.snapshot;
    final trackKey = _trackKey(snapshot);
    final queueKey = state.queueKey;
    final requiresImmediateSync =
        trackKey != _lastTrackKey ||
        queueKey != _lastQueueKey ||
        snapshot.status != _lastStatus ||
        snapshot.shuffleEnabled != _lastShuffleEnabled ||
        snapshot.repeatMode != _lastRepeatMode;

    if (requiresImmediateSync || _positionIsDue) {
      _positionTimer?.cancel();
      _positionTimer = null;
      await _sync(state, force: requiresImmediateSync);
      return;
    }

    _positionTimer ??= Timer(const Duration(milliseconds: 850), () {
      _positionTimer = null;
      final latestState = _latestState;
      if (latestState != null && !_disposed) {
        unawaited(_sync(latestState));
      }
    });
  }

  bool get _positionIsDue {
    final lastUpdate = _lastPositionUpdate;
    return lastUpdate == null ||
        DateTime.now().difference(lastUpdate) >=
            const Duration(milliseconds: 850);
  }

  Future<void> _sync(
    DesktopMediaSessionState state, {
    bool force = false,
  }) async {
    final handler = _handler;
    if (_disposed || handler == null) {
      return;
    }

    try {
      final snapshot = state.snapshot;
      if (!_hasTrack(snapshot)) {
        handler.publishIdle();
        _remember(state);
        return;
      }

      final trackKey = _trackKey(snapshot);
      if (force || trackKey != _lastTrackKey) {
        handler.mediaItem.add(
          MediaItem(
            id: snapshot.trackId ?? snapshot.sourceUrl ?? trackKey,
            title: snapshot.title?.trim().isNotEmpty == true
                ? snapshot.title!.trim()
                : 'BStream Music',
            artist: snapshot.artist?.trim(),
            album: 'BStream Music',
            duration: snapshot.duration,
            artUri: _artUri(snapshot.thumbnailUrl),
          ),
        );
      }

      final queueKey = state.queueKey;
      if (force || queueKey != _lastQueueKey) {
        handler.queue.add(
          state.queue
              .map(
                (item) => MediaItem(
                  id: item.id,
                  title: item.title,
                  artist: item.artist,
                  album: 'BStream Music',
                  artUri: _artUri(item.thumbnailUrl),
                ),
              )
              .toList(growable: false),
        );
      }

      handler.playbackState.add(
        PlaybackState(
          controls: [
            if (state.hasPrevious) MediaControl.skipToPrevious,
            snapshot.status == PlayerStatus.playing
                ? MediaControl.pause
                : MediaControl.play,
            if (state.hasNext) MediaControl.skipToNext,
            MediaControl.stop,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
          },
          processingState: _processingState(snapshot.status),
          playing: snapshot.status == PlayerStatus.playing,
          updatePosition: snapshot.position,
          bufferedPosition: snapshot.position,
          speed: 1,
          queueIndex:
              state.currentIndex >= 0 && state.currentIndex < state.queue.length
              ? state.currentIndex
              : null,
          repeatMode: _audioServiceRepeatMode(snapshot.repeatMode),
          shuffleMode: snapshot.shuffleEnabled
              ? AudioServiceShuffleMode.all
              : AudioServiceShuffleMode.none,
          errorCode: snapshot.status == PlayerStatus.failed ? 1 : null,
          errorMessage: snapshot.status == PlayerStatus.failed
              ? snapshot.errorMessage
              : null,
        ),
      );
      _lastPositionUpdate = DateTime.now();
      _remember(state);
    } catch (error) {
      debugPrint('Desktop audio service update failed: $error');
    }
  }

  void _remember(DesktopMediaSessionState state) {
    final snapshot = state.snapshot;
    _lastTrackKey = _trackKey(snapshot);
    _lastQueueKey = state.queueKey;
    _lastStatus = snapshot.status;
    _lastShuffleEnabled = snapshot.shuffleEnabled;
    _lastRepeatMode = snapshot.repeatMode;
  }

  bool _hasTrack(PlayerSnapshot snapshot) =>
      (snapshot.trackId?.isNotEmpty ?? false) ||
      (snapshot.title?.isNotEmpty ?? false);

  String _trackKey(PlayerSnapshot snapshot) =>
      '${snapshot.trackId}|${snapshot.title}|${snapshot.artist}|'
      '${snapshot.thumbnailUrl}|${snapshot.duration?.inMilliseconds}';

  Uri? _artUri(String? source) {
    final value = source?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(value)) {
      return Uri.file(File(value).absolute.path);
    }
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) {
      return uri;
    }
    return Uri.file(File(value).absolute.path);
  }

  AudioProcessingState _processingState(PlayerStatus status) =>
      switch (status) {
        PlayerStatus.idle => AudioProcessingState.idle,
        PlayerStatus.loading => AudioProcessingState.loading,
        PlayerStatus.playing ||
        PlayerStatus.paused => AudioProcessingState.ready,
        PlayerStatus.stopped => AudioProcessingState.idle,
        PlayerStatus.failed => AudioProcessingState.error,
      };

  AudioServiceRepeatMode _audioServiceRepeatMode(PlaybackRepeatMode mode) =>
      switch (mode) {
        PlaybackRepeatMode.off => AudioServiceRepeatMode.none,
        PlaybackRepeatMode.all => AudioServiceRepeatMode.all,
        PlaybackRepeatMode.one => AudioServiceRepeatMode.one,
      };

  @override
  Future<void> dispose() async {
    _disposed = true;
    _positionTimer?.cancel();
    _handler?.publishIdle();
    _handler = null;
  }
}

class _DesktopAudioHandler extends BaseAudioHandler with SeekHandler {
  _DesktopAudioHandler(this.callbacks);

  final DesktopMediaSessionCallbacks callbacks;

  void publishIdle() {
    queue.add(const []);
    mediaItem.add(null);
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }

  @override
  Future<void> play() => callbacks.play();

  @override
  Future<void> pause() => callbacks.pause();

  @override
  Future<void> stop() async {
    await callbacks.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => callbacks.next();

  @override
  Future<void> skipToPrevious() => callbacks.previous();

  @override
  Future<void> seek(Duration position) => callbacks.seek(position);

  @override
  Future<void> skipToQueueItem(int index) => callbacks.playQueueIndex(index);

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode mode) =>
      callbacks.setShuffleEnabled(mode != AudioServiceShuffleMode.none);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) =>
      callbacks.setRepeatMode(switch (mode) {
        AudioServiceRepeatMode.none => PlaybackRepeatMode.off,
        AudioServiceRepeatMode.one => PlaybackRepeatMode.one,
        AudioServiceRepeatMode.all ||
        AudioServiceRepeatMode.group => PlaybackRepeatMode.all,
      });
}
