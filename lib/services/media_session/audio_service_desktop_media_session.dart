import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../../core/platform/app_platform.dart';
import '../../core/theme/app_colors.dart';
import '../player/notification_artwork_service.dart';
import '../player/player_service.dart';
import 'desktop_media_session.dart';

@visibleForTesting
PlaybackState buildAudioServicePlaybackState(DesktopMediaSessionState state) {
  final snapshot = state.snapshot;
  final controls = <MediaControl>[
    if (state.hasPrevious) MediaControl.skipToPrevious,
    snapshot.status == PlayerStatus.playing
        ? MediaControl.pause
        : MediaControl.play,
    if (state.hasNext) MediaControl.skipToNext,
    MediaControl.stop,
  ];
  final compactActions = <int>[
    for (var index = 0; index < controls.length; index++)
      if (controls[index].action != MediaAction.stop) index,
  ].take(3).toList(growable: false);

  return PlaybackState(
    controls: controls,
    androidCompactActionIndices: compactActions,
    systemActions: const {
      MediaAction.seek,
      MediaAction.seekForward,
      MediaAction.seekBackward,
    },
    processingState: switch (snapshot.status) {
      PlayerStatus.idle => AudioProcessingState.idle,
      PlayerStatus.loading => AudioProcessingState.loading,
      PlayerStatus.playing || PlayerStatus.paused => AudioProcessingState.ready,
      PlayerStatus.completed => AudioProcessingState.completed,
      PlayerStatus.stopped => AudioProcessingState.idle,
      PlayerStatus.failed => AudioProcessingState.error,
    },
    playing: snapshot.status == PlayerStatus.playing,
    updatePosition: snapshot.position,
    bufferedPosition: snapshot.position,
    speed: 1,
    queueIndex:
        state.currentIndex >= 0 && state.currentIndex < state.queue.length
        ? state.currentIndex
        : null,
    repeatMode: switch (snapshot.repeatMode) {
      PlaybackRepeatMode.off => AudioServiceRepeatMode.none,
      PlaybackRepeatMode.all => AudioServiceRepeatMode.all,
      PlaybackRepeatMode.one => AudioServiceRepeatMode.one,
    },
    shuffleMode: snapshot.shuffleEnabled
        ? AudioServiceShuffleMode.all
        : AudioServiceShuffleMode.none,
    errorCode: snapshot.status == PlayerStatus.failed ? 1 : null,
    errorMessage: snapshot.status == PlayerStatus.failed
        ? snapshot.errorMessage
        : null,
  );
}

@visibleForTesting
class AudioServiceMediaSessionCallbackBridge {
  DesktopMediaSessionCallbacks? _callbacks;

  void attach(DesktopMediaSessionCallbacks callbacks) {
    _callbacks = callbacks;
  }

  bool detach(DesktopMediaSessionCallbacks callbacks) {
    if (identical(_callbacks, callbacks)) {
      _callbacks = null;
      return true;
    }
    return false;
  }

  Future<void> play() => _callbacks?.play() ?? Future<void>.value();

  Future<void> pause() => _callbacks?.pause() ?? Future<void>.value();

  Future<void> stop() => _callbacks?.stop() ?? Future<void>.value();

  Future<void> next() => _callbacks?.next() ?? Future<void>.value();

  Future<void> previous() => _callbacks?.previous() ?? Future<void>.value();

  Future<void> seek(Duration position) =>
      _callbacks?.seek(position) ?? Future<void>.value();

  Future<void> playQueueIndex(int index) =>
      _callbacks?.playQueueIndex(index) ?? Future<void>.value();

  Future<void> setShuffleEnabled(bool enabled) =>
      _callbacks?.setShuffleEnabled(enabled) ?? Future<void>.value();

  Future<void> setRepeatMode(PlaybackRepeatMode mode) =>
      _callbacks?.setRepeatMode(mode) ?? Future<void>.value();
}

class AudioServiceDesktopMediaSession implements DesktopMediaSession {
  static Future<_DesktopAudioHandler>? _handlerInitialization;

  _DesktopAudioHandler? _handler;
  DesktopMediaSessionCallbacks? _callbacks;
  DesktopMediaSessionState? _latestState;
  Timer? _positionTimer;

  bool _disposed = false;
  String? _lastTrackKey;
  String? _lastQueueKey;
  PlayerStatus? _lastStatus;
  bool? _lastShuffleEnabled;
  PlaybackRepeatMode? _lastRepeatMode;
  DateTime? _lastPositionUpdate;

  static Future<void> ensureInitialized() async {
    await _recoverableHandler();
  }

  static Future<_DesktopAudioHandler> _recoverableHandler() async {
    final initialization = _ensureHandler();
    try {
      return await initialization;
    } catch (_) {
      // AudioService initialization can fail transiently while Android is
      // restoring the process. Do not permanently cache a rejected Future.
      if (identical(_handlerInitialization, initialization)) {
        _handlerInitialization = null;
      }
      rethrow;
    }
  }

  static Future<_DesktopAudioHandler> _ensureHandler() {
    return _handlerInitialization ??= () async {
      late final _DesktopAudioHandler handler;
      await AudioService.init(
        builder: () {
          handler = _DesktopAudioHandler();
          return handler;
        },
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.bstream.bstream_music.audio',
          androidNotificationChannelName: 'BStream Music',
          androidNotificationChannelDescription: 'BStream Music playback',
          notificationColor: AppColors.brandGreen,
          androidNotificationIcon: 'drawable/ic_stat_bstream_music',
          androidShowNotificationBadge: true,
          androidNotificationOngoing: true,
          artDownscaleWidth: 320,
          artDownscaleHeight: 320,
        ),
      );
      return handler;
    }();
  }

  @override
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks) async {
    _callbacks = callbacks;
    try {
      final handler = await _recoverableHandler();
      if (_disposed) {
        handler.publishIdle();
        return;
      }
      handler.attach(callbacks);
      _handler = handler;
      final latestState = _latestState;
      if (latestState != null) {
        await _sync(latestState, force: true);
      }
    } catch (error, stackTrace) {
      debugPrint(
        'Desktop audio service could not be initialized: $error\n$stackTrace',
      );
      rethrow;
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
            album: snapshot.album?.trim().isNotEmpty == true
                ? snapshot.album!.trim()
                : 'BStream Music',
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
                  album: item.album?.trim().isNotEmpty == true
                      ? item.album!.trim()
                      : 'BStream Music',
                  artUri: _artUri(item.thumbnailUrl),
                ),
              )
              .toList(growable: false),
        );
      }

      handler.playbackState.add(buildAudioServicePlaybackState(state));
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
      '${snapshot.trackId}|${snapshot.title}|${snapshot.artist}|${snapshot.album}|'
      '${snapshot.thumbnailUrl}|${snapshot.duration?.inMilliseconds}';

  Uri? _artUri(String? source) {
    final value = source?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    if (AppPlatform.isAndroid) {
      final notificationUri = NotificationArtworkService.instance.uriFor(value);
      if (notificationUri != null) {
        return notificationUri;
      }
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

  @override
  Future<void> dispose() async {
    _disposed = true;
    _positionTimer?.cancel();
    final handler = _handler;
    final callbacks = _callbacks;
    if (handler != null && callbacks != null) {
      if (handler.detach(callbacks)) {
        handler.publishIdle();
      }
    }
    _handler = null;
    _callbacks = null;
  }
}

class _DesktopAudioHandler extends BaseAudioHandler with SeekHandler {
  final _callbacks = AudioServiceMediaSessionCallbackBridge();

  void attach(DesktopMediaSessionCallbacks callbacks) {
    _callbacks.attach(callbacks);
  }

  bool detach(DesktopMediaSessionCallbacks callbacks) =>
      _callbacks.detach(callbacks);

  void publishIdle() {
    queue.add(const []);
    mediaItem.add(null);
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }

  @override
  Future<void> play() => _callbacks.play();

  @override
  Future<void> pause() => _callbacks.pause();

  @override
  Future<void> stop() async {
    await _callbacks.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => _callbacks.next();

  @override
  Future<void> skipToPrevious() => _callbacks.previous();

  @override
  Future<void> seek(Duration position) => _callbacks.seek(position);

  @override
  Future<void> skipToQueueItem(int index) => _callbacks.playQueueIndex(index);

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode mode) =>
      _callbacks.setShuffleEnabled(mode != AudioServiceShuffleMode.none);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) =>
      _callbacks.setRepeatMode(switch (mode) {
        AudioServiceRepeatMode.none => PlaybackRepeatMode.off,
        AudioServiceRepeatMode.one => PlaybackRepeatMode.one,
        AudioServiceRepeatMode.all ||
        AudioServiceRepeatMode.group => PlaybackRepeatMode.all,
      });
}
