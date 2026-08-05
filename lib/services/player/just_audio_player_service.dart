import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/errors/app_exception.dart' as app_errors;
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/track_info.dart';
import 'player_service.dart';

class JustAudioPlayerService implements PlayerService {
  JustAudioPlayerService() {
    // The stock stream can publish five timeline snapshots per second for the
    // whole lifetime of the foreground service. Four updates per second keeps
    // short tracks smooth, while the 500 ms ceiling bounds background work for
    // very long mixes.
    _positionSubscription = _player
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 250),
          maxPeriod: const Duration(milliseconds: 500),
        )
        .listen((position) {
          _emit(_snapshot.copyWith(position: position));
        });
    _durationSubscription = _player.durationStream.listen((duration) {
      final watch = _remoteStartupWatch;
      if (watch != null && duration != null && !_loggedRemoteDuration) {
        _loggedRemoteDuration = true;
        developer.log(
          'duration available after ${watch.elapsedMilliseconds}ms: $duration',
          name: 'BStreamPlayback',
        );
      }
      _emit(_snapshot.copyWith(duration: duration));
    });
    _volumeSubscription = _player.volumeStream.listen((volume) {
      _emit(_snapshot.copyWith(volume: volume.clamp(0, 1).toDouble()));
    });
    _stateSubscription = _player.playerStateStream.listen((state) {
      // just_audio changes its native state to idle after a load error. Keep
      // the explicit failure until a new source is selected so the controller
      // and UI can process the error instead of seeing a misleading pause.
      if (_snapshot.status == PlayerStatus.failed) {
        return;
      }
      final watch = _remoteStartupWatch;
      if (watch != null) {
        developer.log(
          'state ${state.processingState.name}, playing=${state.playing}, elapsed=${watch.elapsedMilliseconds}ms',
          name: 'BStreamPlayback',
        );
        if (state.processingState == ProcessingState.ready && state.playing) {
          _remoteStartupWatch = null;
        }
      }
      final status = switch (state.processingState) {
        ProcessingState.loading || ProcessingState.buffering =>
          state.playing ? PlayerStatus.playing : PlayerStatus.loading,
        ProcessingState.completed => PlayerStatus.stopped,
        _ => state.playing ? PlayerStatus.playing : PlayerStatus.paused,
      };
      _emit(_snapshot.copyWith(status: status));
    });
    _playbackErrorSubscription = _player.errorStream.listen((error) {
      unawaited(
        _reportPlaybackFailure(error, _playbackGeneration, _activeRemoteTrack),
      );
    });
    _sequenceStateSubscription = _player.sequenceStateStream.listen((state) {
      final tag = state.currentSource?.tag;
      if (tag is! MediaItem) {
        return;
      }
      _emit(
        _snapshot.copyWith(
          title: tag.title,
          artist: tag.artist,
          trackId: tag.id,
          sourceUrl: tag.extras?['sourceUrl']?.toString(),
          thumbnailUrl: tag.artUri?.toString(),
          duration: tag.duration,
          isRemote: tag.extras?['isRemote'] == true,
        ),
      );
    });
  }

  final AudioPlayer _player = AudioPlayer(
    // Let yt-dlp's per-stream User-Agent pass through unchanged. A player-wide
    // User-Agent overrides that header in just_audio and can invalidate signed
    // YouTube media URLs on Android.
    useProxyForRequestHeaders: false,
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: Duration(seconds: 2),
        maxBufferDuration: Duration(seconds: 8),
        bufferForPlaybackDuration: Duration(milliseconds: 250),
        bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 750),
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: Duration(seconds: 1),
      ),
    ),
  );
  final _snapshotController = StreamController<PlayerSnapshot>.broadcast();

  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<Duration?> _durationSubscription;
  late final StreamSubscription<double> _volumeSubscription;
  late final StreamSubscription<PlayerState> _stateSubscription;
  late final StreamSubscription<PlayerException> _playbackErrorSubscription;
  late final StreamSubscription<SequenceState?> _sequenceStateSubscription;

  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  int _playbackGeneration = 0;
  int? _reportedFailureGeneration;
  int? _diagnosticGeneration;
  Future<String>? _diagnosticFuture;
  TrackInfo? _activeRemoteTrack;
  bool _shuffleEnabled = false;
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;
  List<String> _localQueueIds = const [];
  Stopwatch? _remoteStartupWatch;
  bool _loggedRemoteDuration = false;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  bool get supportsLocalQueueReplacement => true;

  @override
  Future<void> playRemote(TrackInfo track) async {
    final generation = ++_playbackGeneration;
    final source = track.streamUrl;
    if (source == null || source.isEmpty) {
      throw const app_errors.PlayerException(
        'No hay una URL reproducible. Obtén la informacion del track primero.',
        code: 'missing_stream_url',
      );
    }

    _activeRemoteTrack = track;
    _localQueueIds = const [];
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id.isEmpty ? track.url : track.id,
        sourceUrl: track.url,
        thumbnailUrl: track.thumbnailUrl,
        duration: track.duration,
        volume: _snapshot.volume,
        isRemote: true,
      ),
    );
    _remoteStartupWatch = Stopwatch()..start();
    _loggedRemoteDuration = track.duration != null;
    developer.log(
      'playRemote start, hasDuration=${track.duration != null}, '
      'hasHeaders=${track.httpHeaders?.isNotEmpty == true}, '
      'format=${track.streamExtension ?? 'unknown'}',
      name: 'BStreamPlayback',
    );
    try {
      await _player.setAudioSource(
        AudioSource.uri(
          _remoteSourceUri(track),
          headers: track.httpHeaders,
          tag: _remoteMediaItem(track),
        ),
        // Validate the signed URL before reporting that playback has started.
        // This turns HTTP/format failures into a catchable error instead of a
        // later, easily lost background event.
        preload: true,
      );
    } catch (error) {
      if (generation == _playbackGeneration) {
        final baseMessage = _playerErrorMessage(error);
        final message = await _diagnosticMessage(error, generation, track);
        if (message != baseMessage) {
          throw app_errors.PlayerException(
            message,
            code: 'playback_source_error',
            details: error,
          );
        }
      }
      rethrow;
    }
    if (generation != _playbackGeneration) {
      return;
    }
    developer.log(
      'setAudioSource returned after ${_remoteStartupWatch?.elapsedMilliseconds ?? 0}ms',
      name: 'BStreamPlayback',
    );
    await _applyPlaybackOptions();
    if (generation != _playbackGeneration) {
      return;
    }
    _startPlayback(generation);
    developer.log(
      'play requested after ${_remoteStartupWatch?.elapsedMilliseconds ?? 0}ms',
      name: 'BStreamPlayback',
    );
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    final generation = ++_playbackGeneration;
    _activeRemoteTrack = null;
    _localQueueIds = const [];
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.sourceUrl,
        thumbnailUrl: track.thumbnailPath ?? track.thumbnailUrl,
        duration: track.duration,
        volume: _snapshot.volume,
        isRemote: false,
      ),
    );
    await _player.setAudioSource(_localAudioSource(track));
    if (generation != _playbackGeneration) {
      return;
    }
    await _applyPlaybackOptions();
    if (generation != _playbackGeneration) {
      return;
    }
    _startPlayback(generation);
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) async {
    if (tracks.isEmpty) {
      return;
    }
    final generation = ++_playbackGeneration;
    _activeRemoteTrack = null;
    final safeIndex = initialIndex.clamp(0, tracks.length - 1);
    final current = tracks[safeIndex];
    _emit(
      PlayerSnapshot(
        status: PlayerStatus.loading,
        title: current.title,
        artist: current.artist,
        trackId: current.id,
        sourceUrl: current.sourceUrl,
        thumbnailUrl: current.thumbnailPath ?? current.thumbnailUrl,
        duration: current.duration,
        volume: _snapshot.volume,
        isRemote: false,
      ),
    );
    final queueIds = tracks.map((track) => track.id).toList(growable: false);
    if (_sameQueue(queueIds, _localQueueIds) &&
        _player.sequence.length == tracks.length) {
      await _player.seek(Duration.zero, index: safeIndex);
    } else {
      await _player.setAudioSources(
        tracks.map(_localAudioSource).toList(growable: false),
        initialIndex: safeIndex,
        initialPosition: Duration.zero,
      );
      _localQueueIds = queueIds;
    }
    await _applyPlaybackOptions();
    if (generation != _playbackGeneration) {
      return;
    }
    _startPlayback(generation);
  }

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {
    if (tracks.isEmpty) {
      _localQueueIds = const [];
      await _player.stop();
      await _player.clearAudioSources();
      _emit(
        PlayerSnapshot(
          status: PlayerStatus.stopped,
          volume: _snapshot.volume,
          shuffleEnabled: _shuffleEnabled,
          repeatMode: _repeatMode,
        ),
      );
      return;
    }

    final nextIds = tracks.map((track) => track.id).toList(growable: false);
    if (_sameQueue(nextIds, _localQueueIds) &&
        _player.sequence.length == tracks.length) {
      return;
    }

    final shouldKeepPlaying =
        _snapshot.status == PlayerStatus.playing ||
        (_snapshot.status == PlayerStatus.loading && _player.playing);
    final currentTrackId = _snapshot.trackId;
    final currentPosition = _player.position;
    final canUpdateIncrementally =
        _localQueueIds.isNotEmpty &&
        _player.sequence.length == _localQueueIds.length;

    if (canUpdateIncrementally) {
      final workingIds = List<String>.of(_localQueueIds);
      for (var index = 0; index < nextIds.length; index++) {
        final desiredId = nextIds[index];
        if (index < workingIds.length && workingIds[index] == desiredId) {
          continue;
        }

        final existingIndex = workingIds.indexOf(desiredId, index + 1);
        if (existingIndex >= 0) {
          await _player.moveAudioSource(existingIndex, index);
          final moved = workingIds.removeAt(existingIndex);
          workingIds.insert(index, moved);
        } else {
          await _player.insertAudioSource(
            index,
            _localAudioSource(tracks[index]),
          );
          workingIds.insert(index, desiredId);
        }
      }
      while (workingIds.length > nextIds.length) {
        await _player.removeAudioSourceAt(workingIds.length - 1);
        workingIds.removeLast();
      }
    } else {
      final retainedIndex = currentTrackId == null
          ? -1
          : nextIds.indexOf(currentTrackId);
      final safeIndex = retainedIndex >= 0
          ? retainedIndex
          : preferredIndex.clamp(0, tracks.length - 1).toInt();
      await _player.setAudioSources(
        tracks.map(_localAudioSource).toList(growable: false),
        initialIndex: safeIndex,
        initialPosition: retainedIndex >= 0 ? currentPosition : Duration.zero,
      );
    }

    _localQueueIds = nextIds;
    final retainedIndex = currentTrackId == null
        ? -1
        : nextIds.indexOf(currentTrackId);
    if (retainedIndex >= 0) {
      await _player.seek(currentPosition, index: retainedIndex);
    } else {
      final safeIndex = preferredIndex.clamp(0, tracks.length - 1).toInt();
      await _player.seek(Duration.zero, index: safeIndex);
    }
    await _applyPlaybackOptions();
    if (shouldKeepPlaying && !_player.playing) {
      _startPlayback(_playbackGeneration);
    } else if (!shouldKeepPlaying && _player.playing) {
      await _player.pause();
    }
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _emit(_snapshot.copyWith(status: PlayerStatus.paused));
  }

  @override
  Future<void> resume() async {
    _startPlayback(_playbackGeneration);
  }

  @override
  Future<void> togglePlayPause() {
    return _player.playing ? pause() : resume();
  }

  @override
  Future<void> stop() {
    _playbackGeneration++;
    _activeRemoteTrack = null;
    return _player.stop();
  }

  @override
  Future<void> seek(Duration position) {
    return _player.seek(position);
  }

  @override
  Future<void> setVolume(double volume) {
    final normalized = volume.clamp(0, 1).toDouble();
    _emit(_snapshot.copyWith(volume: normalized));
    return _player.setVolume(normalized);
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    _shuffleEnabled = enabled;
    _emit(_snapshot.copyWith(shuffleEnabled: enabled));
    await _applyPlaybackOptions();
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {
    _repeatMode = mode;
    _emit(_snapshot.copyWith(repeatMode: mode));
    await _applyPlaybackOptions();
  }

  @override
  Future<void> dispose() async {
    await _positionSubscription.cancel();
    await _durationSubscription.cancel();
    await _volumeSubscription.cancel();
    await _stateSubscription.cancel();
    await _playbackErrorSubscription.cancel();
    await _sequenceStateSubscription.cancel();
    await _player.dispose();
    await _snapshotController.close();
  }

  AudioSource _localAudioSource(LocalTrack track) {
    return AudioSource.file(track.filePath, tag: _localMediaItem(track));
  }

  Uri _remoteSourceUri(TrackInfo track) {
    final source = Uri.parse(track.streamUrl!);
    if (source.fragment.isNotEmpty || _hasKnownAudioExtension(source.path)) {
      return source;
    }

    final extension = _remoteExtension(track);
    return extension == null ? source : source.replace(fragment: '.$extension');
  }

  String? _remoteExtension(TrackInfo track) {
    final direct = track.streamExtension?.trim().toLowerCase();
    if (direct != null && direct.isNotEmpty) {
      return direct.replaceFirst('.', '');
    }

    final mime = track.streamMimeType?.split(';').first.trim().toLowerCase();
    return switch (mime) {
      'audio/mp4' => 'm4a',
      'audio/aac' => 'aac',
      'audio/mpeg' => 'mp3',
      'audio/webm' => 'webm',
      'audio/ogg' => 'ogg',
      'audio/wav' || 'audio/x-wav' => 'wav',
      _ => null,
    };
  }

  bool _hasKnownAudioExtension(String path) {
    return RegExp(
      r'\.(?:m4a|mp4|aac|mp3|webm|weba|ogg|oga|opus|wav)$',
      caseSensitive: false,
    ).hasMatch(path);
  }

  MediaItem _remoteMediaItem(TrackInfo track) {
    return MediaItem(
      id: track.id.isEmpty ? track.url : track.id,
      album: 'BStream Music',
      title: track.title,
      artist: track.artist,
      artUri: _artUri(track.thumbnailUrl),
      duration: track.duration,
      extras: {'sourceUrl': track.url, 'isRemote': true},
    );
  }

  MediaItem _localMediaItem(LocalTrack track) {
    return MediaItem(
      id: track.id,
      album: 'BStream Music',
      title: track.title,
      artist: track.artist,
      artUri: _artUri(track.thumbnailPath ?? track.thumbnailUrl),
      duration: track.duration,
      extras: {'sourceUrl': track.sourceUrl, 'isRemote': false},
    );
  }

  Uri? _artUri(String? source) {
    final normalized = source?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    if (normalized.startsWith('http://') || normalized.startsWith('https://')) {
      return Uri.tryParse(normalized);
    }
    if (normalized.startsWith('file://')) {
      return Uri.tryParse(normalized);
    }
    final file = File(normalized);
    return file.existsSync() ? file.uri : null;
  }

  Future<void> _applyPlaybackOptions() async {
    await _player.setShuffleModeEnabled(_shuffleEnabled);
    await _player.setLoopMode(_loopMode);
  }

  void _startPlayback(int generation) {
    // just_audio's play Future completes when playback is paused, stopped, or
    // reaches the end. Awaiting it would keep playRemote/playLocal pending for
    // the entire song and could overwrite a later completed state. Playback
    // state and failures remain authoritative through the subscriptions above.
    unawaited(_playAndReportFailure(generation));
  }

  Future<void> _playAndReportFailure(int generation) async {
    try {
      await _player.play();
    } catch (error, stackTrace) {
      await _reportPlaybackFailure(error, generation, _activeRemoteTrack);
      developer.log(
        'play request failed',
        name: 'BStreamPlayback',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _reportPlaybackFailure(
    Object error,
    int generation,
    TrackInfo? track,
  ) async {
    if (generation != _playbackGeneration ||
        _reportedFailureGeneration == generation) {
      return;
    }
    _reportedFailureGeneration = generation;

    final message = await _diagnosticMessage(error, generation, track);
    if (generation != _playbackGeneration) {
      return;
    }
    developer.log(
      'playback failed: $message',
      name: 'BStreamPlayback',
      error: error,
    );
    _emit(
      _snapshot.copyWith(status: PlayerStatus.failed, errorMessage: message),
    );
  }

  Future<String> _diagnosticMessage(
    Object error,
    int generation,
    TrackInfo? track,
  ) {
    final cachedGeneration = _diagnosticGeneration;
    final cachedFuture = _diagnosticFuture;
    if (cachedGeneration == generation && cachedFuture != null) {
      return cachedFuture;
    }

    final baseMessage = _playerErrorMessage(error);
    final future = _buildDiagnosticMessage(baseMessage, track);
    _diagnosticGeneration = generation;
    _diagnosticFuture = future;
    return future;
  }

  Future<String> _buildDiagnosticMessage(
    String baseMessage,
    TrackInfo? track,
  ) async {
    if (!_needsHttpDiagnostic(baseMessage) || track == null) {
      return baseMessage;
    }

    final detail = await _probeRemoteSource(track);
    return detail == null ? baseMessage : '$baseMessage: $detail';
  }

  bool _needsHttpDiagnostic(String message) {
    final normalized = message.trim().toLowerCase();
    return normalized.isEmpty || normalized.contains('source error');
  }

  Future<String?> _probeRemoteSource(TrackInfo track) async {
    final source = track.streamUrl?.trim();
    final uri = source == null ? null : Uri.tryParse(source);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 4);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 6));
      request.followRedirects = true;
      request.maxRedirects = 3;
      track.httpHeaders?.forEach((key, value) {
        final normalized = key.toLowerCase();
        if (normalized == 'host' ||
            normalized == 'content-length' ||
            normalized == 'range') {
          return;
        }
        request.headers.set(key, value);
      });
      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      final status = response.statusCode;
      final reason = response.reasonPhrase.trim();
      final statusText = reason.isEmpty
          ? 'HTTP $status'
          : 'HTTP $status ($reason)';

      // Read only the first response chunk. This is enough to recognize the
      // container while never downloading or retaining the audio stream.
      final firstChunk = await response.first;
      final signature = _mediaSignature(firstChunk);
      final signatureText = signature == null ? '' : '; detected $signature';

      if (status >= 400) {
        return statusText;
      }

      final contentType = response.headers.contentType?.mimeType;
      final typeText = contentType == null ? '' : '; content-type $contentType';
      return '$statusText$typeText$signatureText; ExoPlayer no pudo decodificar la respuesta';
    } on TimeoutException {
      return 'HTTP timeout';
    } on SocketException {
      return 'error de red';
    } on HttpException {
      return 'error HTTP';
    } catch (_) {
      return 'fallo al verificar la URL';
    } finally {
      client.close(force: true);
    }
  }

  String? _mediaSignature(List<int> bytes) {
    if (bytes.length >= 8 &&
        String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
      return 'MP4';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x1a &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xdf &&
        bytes[3] == 0xa3) {
      return 'WebM';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      return 'MP3';
    }
    if (bytes.isNotEmpty && bytes.first == 0x3c) {
      return 'HTML';
    }
    return null;
  }

  String _playerErrorMessage(Object error) {
    if (error is PlayerException) {
      final message = error.message?.trim();
      if (message != null && message.isNotEmpty) {
        return message;
      }
      return 'ExoPlayer error code ${error.code}';
    }
    final message = error.toString().trim();
    return message.isEmpty ? 'Error desconocido de reproduccion.' : message;
  }

  LoopMode get _loopMode {
    return switch (_repeatMode) {
      PlaybackRepeatMode.one => LoopMode.one,
      PlaybackRepeatMode.all => LoopMode.all,
      PlaybackRepeatMode.off => LoopMode.off,
    };
  }

  void _emit(PlayerSnapshot snapshot) {
    _snapshot = snapshot;
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  bool _sameQueue(List<String> left, List<String> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}
