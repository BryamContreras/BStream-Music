import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart';

import '../player/player_service.dart';
import 'desktop_media_session.dart';

class WindowsSmtcMediaSession implements DesktopMediaSession {
  SMTCWindows? _smtc;
  DesktopMediaSessionCallbacks? _callbacks;
  DesktopMediaSessionState? _latestState;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _timelineTimer;

  bool _disposed = false;
  bool _enabled = false;
  String? _lastTrackKey;
  PlayerStatus? _lastStatus;
  String? _lastQueueKey;
  bool? _lastShuffleEnabled;
  PlaybackRepeatMode? _lastRepeatMode;
  DateTime? _lastTimelineUpdate;

  @override
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks) async {
    _callbacks = callbacks;
    try {
      await SMTCWindows.initialize();
      if (_disposed) {
        return;
      }

      final smtc = SMTCWindows(
        enabled: false,
        config: const SMTCConfig(
          playEnabled: true,
          pauseEnabled: true,
          stopEnabled: true,
          nextEnabled: true,
          prevEnabled: true,
          fastForwardEnabled: true,
          rewindEnabled: true,
        ),
      );
      _smtc = smtc;
      _subscriptions.addAll([
        smtc.buttonPressStream.listen(_handleButton),
        smtc.shuffleChangeStream.listen((enabled) {
          _runCallback(() => callbacks.setShuffleEnabled(enabled));
        }),
        smtc.repeatModeChangeStream.listen((mode) {
          _runCallback(
            () => callbacks.setRepeatMode(_fromSmtcRepeatMode(mode)),
          );
        }),
      ]);

      final latestState = _latestState;
      if (latestState != null) {
        await _sync(latestState, force: true);
      }
    } catch (error) {
      debugPrint('Windows SMTC could not be initialized: $error');
    }
  }

  @override
  Future<void> update(DesktopMediaSessionState state) async {
    _latestState = state;
    final smtc = _smtc;
    if (_disposed || smtc == null) {
      return;
    }

    final snapshot = state.snapshot;
    final trackKey = _trackKey(snapshot);
    final queueKey = state.queueKey;
    final requiresImmediateSync =
        trackKey != _lastTrackKey ||
        snapshot.status != _lastStatus ||
        queueKey != _lastQueueKey ||
        snapshot.shuffleEnabled != _lastShuffleEnabled ||
        snapshot.repeatMode != _lastRepeatMode;

    if (requiresImmediateSync || _timelineIsDue) {
      _timelineTimer?.cancel();
      _timelineTimer = null;
      await _sync(state, force: requiresImmediateSync);
      return;
    }

    _timelineTimer ??= Timer(const Duration(milliseconds: 850), () {
      _timelineTimer = null;
      final latestState = _latestState;
      if (latestState != null && !_disposed) {
        unawaited(_sync(latestState));
      }
    });
  }

  bool get _timelineIsDue {
    final lastUpdate = _lastTimelineUpdate;
    return lastUpdate == null ||
        DateTime.now().difference(lastUpdate) >=
            const Duration(milliseconds: 850);
  }

  Future<void> _sync(
    DesktopMediaSessionState state, {
    bool force = false,
  }) async {
    final smtc = _smtc;
    if (_disposed || smtc == null) {
      return;
    }

    try {
      final snapshot = state.snapshot;
      final hasTrack = _hasTrack(snapshot);
      if (!hasTrack) {
        if (_enabled) {
          await smtc.clearMetadata();
          await smtc.disableSmtc();
          _enabled = false;
        }
        _remember(state);
        return;
      }

      if (!_enabled) {
        await smtc.enableSmtc();
        _enabled = true;
      }

      final trackKey = _trackKey(snapshot);
      if (force || trackKey != _lastTrackKey) {
        await smtc.updateMetadata(
          MusicMetadata(
            title: snapshot.title?.trim(),
            artist: snapshot.artist?.trim(),
            album: 'BStream Music',
            albumArtist: snapshot.artist?.trim(),
            thumbnail: _thumbnailUri(snapshot.thumbnailUrl),
          ),
        );
      }

      final queueKey = state.queueKey;
      if (force || queueKey != _lastQueueKey) {
        await smtc.updateConfig(
          SMTCConfig(
            playEnabled: true,
            pauseEnabled: true,
            stopEnabled: true,
            nextEnabled: state.hasNext,
            prevEnabled: state.hasPrevious,
            fastForwardEnabled: true,
            rewindEnabled: true,
          ),
        );
      }

      if (force || snapshot.status != _lastStatus) {
        await smtc.setPlaybackStatus(_toSmtcStatus(snapshot.status));
      }
      if (force || snapshot.shuffleEnabled != _lastShuffleEnabled) {
        await smtc.setShuffleEnabled(snapshot.shuffleEnabled);
      }
      if (force || snapshot.repeatMode != _lastRepeatMode) {
        await smtc.setRepeatMode(_toSmtcRepeatMode(snapshot.repeatMode));
      }

      final duration = snapshot.duration ?? Duration.zero;
      final end = math.max(
        duration.inMilliseconds,
        snapshot.position.inMilliseconds,
      );
      await smtc.updateTimeline(
        PlaybackTimeline(
          startTimeMs: 0,
          endTimeMs: end,
          positionMs: snapshot.position.inMilliseconds.clamp(0, end).toInt(),
          minSeekTimeMs: 0,
          maxSeekTimeMs: end,
        ),
      );
      _lastTimelineUpdate = DateTime.now();
      _remember(state);
    } catch (error) {
      debugPrint('Windows SMTC update failed: $error');
    }
  }

  void _handleButton(PressedButton button) {
    final callbacks = _callbacks;
    if (callbacks == null) {
      return;
    }
    switch (button) {
      case PressedButton.play:
        _runCallback(callbacks.play);
        break;
      case PressedButton.pause:
        _runCallback(callbacks.pause);
        break;
      case PressedButton.next:
        _runCallback(callbacks.next);
        break;
      case PressedButton.previous:
        _runCallback(callbacks.previous);
        break;
      case PressedButton.fastForward:
        _runCallback(() => callbacks.seekBy(const Duration(seconds: 10)));
        break;
      case PressedButton.rewind:
        _runCallback(() => callbacks.seekBy(const Duration(seconds: -10)));
        break;
      case PressedButton.stop:
        _runCallback(callbacks.stop);
        break;
      case PressedButton.record:
      case PressedButton.channelUp:
      case PressedButton.channelDown:
        break;
    }
  }

  void _runCallback(DesktopMediaAction callback) {
    unawaited(
      callback().catchError((Object error) {
        debugPrint('Windows SMTC command failed: $error');
      }),
    );
  }

  void _remember(DesktopMediaSessionState state) {
    final snapshot = state.snapshot;
    _lastTrackKey = _trackKey(snapshot);
    _lastStatus = snapshot.status;
    _lastQueueKey = state.queueKey;
    _lastShuffleEnabled = snapshot.shuffleEnabled;
    _lastRepeatMode = snapshot.repeatMode;
  }

  String _trackKey(PlayerSnapshot snapshot) =>
      '${snapshot.trackId}|${snapshot.title}|${snapshot.artist}|'
      '${snapshot.thumbnailUrl}|${snapshot.duration?.inMilliseconds}';

  bool _hasTrack(PlayerSnapshot snapshot) =>
      (snapshot.trackId?.isNotEmpty ?? false) ||
      (snapshot.title?.isNotEmpty ?? false);

  String? _thumbnailUri(String? source) {
    final value = source?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(value)) {
      return Uri.file(File(value).absolute.path).toString();
    }
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) {
      return uri.toString();
    }
    return Uri.file(File(value).absolute.path).toString();
  }

  PlaybackStatus _toSmtcStatus(PlayerStatus status) => switch (status) {
    PlayerStatus.idle => PlaybackStatus.closed,
    PlayerStatus.loading => PlaybackStatus.changing,
    PlayerStatus.playing => PlaybackStatus.playing,
    PlayerStatus.paused => PlaybackStatus.paused,
    PlayerStatus.stopped || PlayerStatus.failed => PlaybackStatus.stopped,
  };

  RepeatMode _toSmtcRepeatMode(PlaybackRepeatMode mode) => switch (mode) {
    PlaybackRepeatMode.off => RepeatMode.none,
    PlaybackRepeatMode.all => RepeatMode.list,
    PlaybackRepeatMode.one => RepeatMode.track,
  };

  PlaybackRepeatMode _fromSmtcRepeatMode(RepeatMode mode) => switch (mode) {
    RepeatMode.none => PlaybackRepeatMode.off,
    RepeatMode.list => PlaybackRepeatMode.all,
    RepeatMode.track => PlaybackRepeatMode.one,
  };

  @override
  Future<void> dispose() async {
    _disposed = true;
    _timelineTimer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final smtc = _smtc;
    _smtc = null;
    if (smtc != null) {
      try {
        await smtc.disableSmtc();
        await smtc.dispose();
      } catch (error) {
        debugPrint('Windows SMTC disposal failed: $error');
      }
    }
  }
}
