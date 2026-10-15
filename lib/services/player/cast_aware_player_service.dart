import 'dart:async';
import 'dart:io';

import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import '../casting/cast_coordinator.dart';
import 'player_service.dart';

/// Retains the existing local backend and all of its optional capabilities.
/// Remote transport takes ownership only after the receiver acknowledges a
/// load. The queue/controller and system media session still see ONE player.
class CastAwarePlayerService
    implements
        PlayerService,
        NativeRemoteQueuePlayer,
        CrossfadeCapablePlayer,
        SkipSilenceCapablePlayer {
  CastAwarePlayerService({required PlayerService local, required this.cast})
    // Preserve a named injection point for the local backend.
    // ignore: prefer_initializing_formals
    : _local = local {
    _localSubscription = _local.snapshotStream.listen(_onLocal);
    _castSubscription = cast.changes.listen(_onCast);
  }

  final PlayerService _local;
  final CastCoordinator cast;
  late final StreamSubscription<PlayerSnapshot> _localSubscription;
  late final StreamSubscription<CastState> _castSubscription;
  final _snapshots = StreamController<PlayerSnapshot>.broadcast();
  final Map<String, RemotePlaybackSource> _remoteSources = {};
  List<LocalTrack> _localQueue = const [];
  _CastSource? _source;
  PlayerSnapshot? _remoteSnapshot;
  bool _casting = false;
  bool _transitioning = false;
  bool _disposed = false;
  int _operation = 0;
  int _contentSequence = 0;
  double? _restoreVolume;
  Object? _lastLocalIdentity;

  bool get isCasting => _casting;
  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshots.stream;
  @override
  PlayerSnapshot get currentSnapshot =>
      _remoteSnapshot ?? _local.currentSnapshot;
  @override
  bool get supportsLocalQueueReplacement =>
      !_casting && _local.supportsLocalQueueReplacement;

  void _publish(PlayerSnapshot snapshot) {
    if (!_disposed) _snapshots.add(snapshot);
  }

  void _onLocal(PlayerSnapshot snapshot) {
    if (_casting || _transitioning || _disposed) return;
    _remoteSnapshot = null;
    // ExoPlayer/crossfade can advance without calling playRemoteSource again.
    final identity = (
      snapshot.trackId,
      snapshot.queueEntryId,
      snapshot.sourceUrl,
      snapshot.title,
      snapshot.artist,
      snapshot.thumbnailUrl,
    );
    if (identity != _lastLocalIdentity) {
      _lastLocalIdentity = identity;
      _source = _sourceForSnapshot(snapshot) ?? _source;
    }
    _publish(snapshot);
  }

  void _onCast(CastState state) {
    if (!_casting || _transitioning || _disposed) return;
    if (!state.connected || state.error != null) {
      // Loss of Wi-Fi/receiver never leaves local and remote decoders playing
      // together. Best effort return to the same song/time on this device.
      unawaited(disconnectCast().catchError((Object _) {}));
      return;
    }
    final previous = _remoteSnapshot;
    if (previous == null) return;
    if (previous.status == PlayerStatus.stopped) return;
    final status = switch (state.status) {
      CastPlaybackStatus.idle => PlayerStatus.paused,
      CastPlaybackStatus.loading => PlayerStatus.loading,
      CastPlaybackStatus.playing => PlayerStatus.playing,
      CastPlaybackStatus.paused => PlayerStatus.paused,
      CastPlaybackStatus.completed => PlayerStatus.completed,
    };
    _remoteSnapshot = previous.copyWith(
      status: status,
      position: state.position,
      duration: state.duration ?? previous.duration,
      volume: state.volume,
      errorMessage: null,
    );
    _publish(_remoteSnapshot!);
  }

  Future<void> connectCast(CastDevice device) async {
    if (_casting &&
        cast.state.device?.id == device.id &&
        cast.state.device?.protocol == device.protocol) {
      return;
    }
    if (_casting) await disconnectCast();
    var source = _source;
    var snapshot = _local.currentSnapshot;
    if (source == null ||
        snapshot.trackId == null ||
        snapshot.status == PlayerStatus.loading) {
      throw StateError('No ready media source to transmit.');
    }
    final operation = ++_operation;
    var autoplay = snapshot.status == PlayerStatus.playing;
    var pausedForCast = false;
    try {
      await cast.connect(device);
      if (_disposed || operation != _operation) {
        throw StateError('Cast connection was cancelled.');
      }
      _transitioning = true;
      // Disable ONLY the optional dual-deck preparation while casting. Its
      // setting is retained in the existing backend and restored on return.
      if (_local case final CrossfadeCapablePlayer crossfade) {
        await crossfade.prepareCrossfade(null);
      }
      _checkOperation(operation);
      // Connecting can take seconds while the existing queue keeps playing.
      // Native queue/crossfade transitions, Pause and Seek do not necessarily
      // increment our operation generation: re-read the actual current item.
      snapshot = _local.currentSnapshot;
      source = _sourceForSnapshot(snapshot);
      if (source == null ||
          (snapshot.status != PlayerStatus.playing &&
              snapshot.status != PlayerStatus.paused)) {
        throw StateError('No ready media source to transmit.');
      }
      autoplay = snapshot.status == PlayerStatus.playing;
      pausedForCast = true;
      await _local.pause();
      _checkOperation(operation);
      snapshot = _local.currentSnapshot;
      source = _sourceForSnapshot(snapshot) ?? source;
      _source = source;
      await _loadReceiver(source, snapshot.position, autoplay: autoplay);
      if (_disposed || operation != _operation) {
        throw StateError('Cast connection was cancelled.');
      }
      _casting = true;
      _remoteSnapshot = snapshot.copyWith(
        status: autoplay ? PlayerStatus.playing : PlayerStatus.paused,
        position: cast.state.position,
        volume: cast.state.volume,
        errorMessage: null,
      );
      if (operation == _operation) _transitioning = false;
      _publish(_remoteSnapshot!);
    } catch (_) {
      if (operation == _operation) _transitioning = false;
      if (!_casting) {
        await cast.disconnect().catchError((Object _) {});
      }
      if (!_disposed && operation == _operation && autoplay && pausedForCast) {
        await _local.resume();
      }
      rethrow;
    }
  }

  void _checkOperation(int operation) {
    if (_disposed || operation != _operation) {
      throw StateError('Cast operation was cancelled.');
    }
  }

  _CastSource? _sourceForSnapshot(PlayerSnapshot snapshot) {
    final remote = _remoteSources[snapshot.queueEntryId];
    if (remote != null) return _CastSource.remote(remote);
    for (final track in _localQueue) {
      if (track.id == snapshot.trackId) return _CastSource.local(track);
    }
    final source = _source;
    return source?.snapshot.trackId == snapshot.trackId ? source : null;
  }

  Future<void> _loadReceiver(
    _CastSource source,
    Duration position, {
    required bool autoplay,
  }) => cast.load(
    source: source.uri,
    headers: source.headers,
    mimeType: source.mimeType,
    title: source.snapshot.title ?? '',
    artist: source.snapshot.artist ?? '',
    duration: source.snapshot.duration,
    artworkUrl: _publicArtwork(source.snapshot.thumbnailUrl),
    contentId: 'bstream-${++_contentSequence}',
    position: position,
    autoplay: autoplay,
  );

  Future<bool> _playSource(_CastSource source) async {
    final operation = ++_operation;
    final previous = currentSnapshot;
    _source = source;
    if (!_casting) {
      _transitioning = false;
      return false;
    }
    _transitioning = true;
    _remoteSnapshot = source.snapshot.copyWith(
      status: PlayerStatus.loading,
      volume: previous.volume,
      shuffleEnabled: previous.shuffleEnabled,
      repeatMode: previous.repeatMode,
    );
    _publish(_remoteSnapshot!);
    try {
      await _loadReceiver(source, Duration.zero, autoplay: true);
      if (_disposed || operation != _operation) return true;
      _transitioning = false;
      _remoteSnapshot = _remoteSnapshot!.copyWith(
        status: PlayerStatus.playing,
        position: cast.state.position,
        volume: cast.state.volume,
      );
      _publish(_remoteSnapshot!);
      return true;
    } catch (_) {
      if (!_disposed && operation == _operation) {
        _transitioning = false;
        // Unsupported receiver codec/failed load falls back to the same song
        // locally, not to another queue item or a second active decoder.
        await disconnectCast();
      }
      // A successful local fallback is still successful playback. Publishing
      // the receiver's error to PlayerController would retry/restart a song
      // already playing correctly, or turn it into an unnecessary error.
      return true;
    }
  }

  Future<void> disconnectCast() async {
    final wasCasting = _casting;
    final source = _source;
    final snapshot = currentSnapshot;
    final operation = ++_operation;
    _casting = false;
    _transitioning = wasCasting;
    try {
      await cast.disconnect().catchError((Object _) {});
      if (!wasCasting ||
          source == null ||
          _disposed ||
          operation != _operation) {
        return;
      }
      final localSnapshot = _local.currentSnapshot;
      final alreadyLoaded =
          localSnapshot.trackId == source.snapshot.trackId &&
          localSnapshot.queueEntryId == source.snapshot.queueEntryId &&
          localSnapshot.sourceUrl == source.snapshot.sourceUrl;
      if (!alreadyLoaded) {
        // New cast song: load quietly, then seek before restoring the existing
        // LOCAL gain. The receiver's volume must not change the phone's gain.
        _restoreVolume ??= localSnapshot.volume;
        await _local.setVolume(0);
        _checkOperation(operation);
        await _restoreSource(source);
      }
      if (_disposed || operation != _operation) return;
      await _local.seek(snapshot.position);
      if (_disposed || operation != _operation) return;
      if (snapshot.status == PlayerStatus.playing ||
          snapshot.status == PlayerStatus.loading) {
        await _local.resume();
      } else {
        await _local.pause();
      }
    } finally {
      final restoreVolume = _restoreVolume;
      _restoreVolume = null;
      if (!_disposed && restoreVolume != null) {
        await _local.setVolume(restoreVolume);
      }
      if (!_disposed && operation == _operation) {
        _remoteSnapshot = null;
        _transitioning = false;
        _publish(_local.currentSnapshot);
      }
    }
  }

  Future<void> _restoreSource(_CastSource source) async {
    if (source.localTrack case final LocalTrack track) {
      final index = _localQueue.indexWhere((item) => item.id == track.id);
      if (index >= 0) {
        await _local.playLocalQueue(_localQueue, index);
      } else {
        await _local.playLocal(track);
      }
    } else if (source.remoteSource case final RemotePlaybackSource remote) {
      if (_local case final NativeRemoteQueuePlayer native) {
        await native.playRemoteSource(remote);
      } else {
        await _local.playRemote(remote.track);
      }
    }
  }

  @override
  Future<void> playRemote(TrackInfo track) async {
    final source = RemotePlaybackSource(
      track: track,
      uri: Uri.parse(track.streamUrl ?? track.url),
      queueEntryId: track.id,
      httpHeaders: track.httpHeaders,
    );
    await playRemoteSource(source);
  }

  @override
  Future<void> playRemoteSource(RemotePlaybackSource source) async {
    _remoteSources[source.queueEntryId] = source;
    _localQueue = const [];
    if (await _playSource(_CastSource.remote(source))) return;
    if (_local case final NativeRemoteQueuePlayer native) {
      await native.playRemoteSource(source);
    } else {
      await _local.playRemote(source.track);
    }
  }

  @override
  Future<void> updateRemoteQueue(
    List<RemotePlaybackSource> upcoming, {
    bool finalize = true,
  }) async {
    final currentKey = currentSnapshot.queueEntryId;
    final active = _remoteSources[currentKey];
    _remoteSources
      ..clear()
      ..addEntries(upcoming.map((item) => MapEntry(item.queueEntryId, item)));
    if (active != null) _remoteSources[currentKey!] = active;
    if (!_casting) {
      if (_local case final NativeRemoteQueuePlayer native) {
        await native.updateRemoteQueue(upcoming, finalize: finalize);
      }
    }
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    _localQueue = [track];
    if (!await _playSource(_CastSource.local(track))) {
      await _local.playLocal(track);
    }
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) async {
    if (initialIndex < 0 || initialIndex >= tracks.length) {
      throw RangeError.index(initialIndex, tracks);
    }
    _localQueue = List.of(tracks);
    if (!await _playSource(_CastSource.local(tracks[initialIndex]))) {
      await _local.playLocalQueue(tracks, initialIndex);
    }
  }

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {
    _localQueue = List.of(tracks);
    if (!_casting) await _local.replaceLocalQueue(tracks, preferredIndex);
  }

  @override
  Future<void> pause() async {
    if (_casting) {
      await cast.pause();
    } else {
      await _local.pause();
    }
  }

  @override
  Future<void> resume() async {
    if (_casting) {
      final source = _source;
      if (source != null &&
          (currentSnapshot.status == PlayerStatus.stopped ||
              currentSnapshot.status == PlayerStatus.completed)) {
        await _playSource(source);
      } else {
        await cast.play();
      }
    } else {
      await _local.resume();
    }
  }

  @override
  Future<void> togglePlayPause() =>
      currentSnapshot.status == PlayerStatus.playing ? pause() : resume();
  @override
  Future<void> seek(Duration position) =>
      _casting ? cast.seek(position) : _local.seek(position);
  @override
  Future<void> setVolume(double volume) async {
    if (_casting) {
      await cast.setVolume(volume);
    } else if (_restoreVolume != null) {
      _restoreVolume = volume.clamp(0, 1);
    } else {
      await _local.setVolume(volume);
    }
  }

  @override
  Future<void> stop() async {
    ++_operation;
    if (_casting) {
      _transitioning = true;
      try {
        await cast.stop();
        _remoteSnapshot = _remoteSnapshot?.copyWith(
          status: PlayerStatus.stopped,
          position: Duration.zero,
        );
        if (_remoteSnapshot != null) _publish(_remoteSnapshot!);
      } finally {
        _transitioning = false;
      }
    } else {
      _transitioning = false;
      await cast.disconnect().catchError((Object _) {});
      await _local.stop();
    }
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    await _local.setShuffleEnabled(enabled);
    if (_casting) {
      _remoteSnapshot = _remoteSnapshot?.copyWith(shuffleEnabled: enabled);
      if (_remoteSnapshot != null) _publish(_remoteSnapshot!);
    }
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {
    await _local.setRepeatMode(mode);
    if (_casting) {
      _remoteSnapshot = _remoteSnapshot?.copyWith(repeatMode: mode);
      if (_remoteSnapshot != null) _publish(_remoteSnapshot!);
    }
  }

  @override
  bool get crossfadeEnabled =>
      !_casting &&
      _local is CrossfadeCapablePlayer &&
      (_local as CrossfadeCapablePlayer).crossfadeEnabled;
  @override
  Future<void> configureCrossfade({
    required bool enabled,
    required Duration duration,
  }) async {
    if (_local case final CrossfadeCapablePlayer crossfade) {
      await crossfade.configureCrossfade(enabled: enabled, duration: duration);
    }
  }

  @override
  Future<void> prepareCrossfade(CrossfadePlaybackSource? source) async {
    if (_casting) return;
    if (_local case final CrossfadeCapablePlayer crossfade) {
      await crossfade.prepareCrossfade(source);
    }
  }

  @override
  bool get supportsSkipSilence =>
      _local is SkipSilenceCapablePlayer &&
      (_local as SkipSilenceCapablePlayer).supportsSkipSilence;
  @override
  bool get skipSilenceEnabled =>
      _local is SkipSilenceCapablePlayer &&
      (_local as SkipSilenceCapablePlayer).skipSilenceEnabled;
  @override
  Future<void> configureSkipSilence({required bool enabled}) async {
    if (_local case final SkipSilenceCapablePlayer player) {
      await player.configureSkipSilence(enabled: enabled);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_operation;
    await _castSubscription.cancel();
    await _localSubscription.cancel();
    await cast.disconnect().catchError((Object _) {});
    await _local.dispose();
    await _snapshots.close();
  }
}

class _CastSource {
  const _CastSource({
    required this.uri,
    required this.mimeType,
    required this.snapshot,
    this.headers = const {},
    this.localTrack,
    this.remoteSource,
  });
  final Uri uri;
  final String mimeType;
  final PlayerSnapshot snapshot;
  final Map<String, String> headers;
  final LocalTrack? localTrack;
  final RemotePlaybackSource? remoteSource;

  factory _CastSource.local(LocalTrack track) {
    final path = track.filePath;
    final parsed = Uri.tryParse(path);
    final uri =
        parsed != null &&
            (parsed.scheme == 'content' || parsed.scheme == 'file')
        ? parsed
        : Uri.file(path, windows: Platform.isWindows);
    return _CastSource(
      uri: uri,
      mimeType: castAudioMimeType(uri),
      localTrack: track,
      snapshot: PlayerSnapshot(
        status: PlayerStatus.loading,
        trackId: track.id,
        title: track.title,
        artist: track.artist,
        album: track.album,
        sourceUrl: track.filePath,
        thumbnailUrl: track.thumbnailUrl,
        duration: track.duration,
        isExternal: track.isExternal,
      ),
    );
  }
  factory _CastSource.remote(RemotePlaybackSource source) => _CastSource(
    uri: source.uri,
    mimeType:
        source.track.streamMimeType?.split(';').first.trim() ??
        castAudioMimeType(source.uri),
    headers: source.httpHeaders ?? source.track.httpHeaders ?? const {},
    remoteSource: source,
    snapshot: PlayerSnapshot(
      status: PlayerStatus.loading,
      trackId: source.track.id.isEmpty ? source.track.url : source.track.id,
      queueEntryId: source.queueEntryId,
      title: source.track.title,
      artist: source.track.artist,
      album: source.track.album,
      sourceUrl: source.track.url,
      thumbnailUrl: source.track.thumbnailUrl,
      duration: source.track.duration,
      isRemote: true,
    ),
  );
}

String castAudioMimeType(Uri source) {
  final hinted = source.queryParameters['mime'];
  if (hinted != null && hinted.startsWith('audio/')) {
    return hinted.split(';').first;
  }
  return switch (source.path.toLowerCase().split('.').last) {
    'mp3' => 'audio/mpeg',
    'ogg' || 'oga' || 'opus' => 'audio/ogg',
    'webm' => 'audio/webm',
    'flac' => 'audio/flac',
    'wav' => 'audio/wav',
    'aac' => 'audio/aac',
    _ => 'audio/mp4',
  };
}

Uri? _publicArtwork(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https')
      ? uri
      : null;
}
