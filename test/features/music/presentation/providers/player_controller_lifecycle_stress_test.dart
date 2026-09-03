import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'native background auto-next records every track once without restarting the queue',
    () async {
      final player = _LifecyclePlayerService();
      final library = _LifecycleLibraryRepository();
      final container = _container(player, library: library);
      addTearDown(() async {
        container.dispose();
        await player.dispose();
      });
      // A short fixture keeps the real monotonic qualification threshold
      // practical while still proving that hundreds of position snapshots do
      // not count as listening time or create duplicate writes.
      final tracks = List.generate(
        6,
        (index) => _track(index, duration: const Duration(milliseconds: 25)),
      );

      await container.read(settingsControllerProvider.future);
      await container.read(playerControllerProvider.future);
      await _drainEvents();
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(
            tracks.first,
            queue: tracks,
            queueSourceId: PlayerController.playlistQueueSourceId('road-trip'),
          );

      // just_audio emits many position/duration snapshots for the same song.
      // They must not turn into duplicate history writes.
      for (var index = 0; index < 300; index++) {
        player.emit(
          _playingSnapshot(tracks.first, position: Duration(seconds: index)),
        );
      }
      await _waitUntil(
        () => library.playedTrackIds.lastOrNull == tracks.first.id,
        reason: 'The initial qualified playback was not recorded.',
      );
      expect(library.playedTrackIds, ['track-0']);

      // On Android the native queue advances while Flutter is backgrounded.
      // The sequence snapshot is the only signal received by the controller.
      for (final track in tracks.skip(1)) {
        for (var duplicate = 0; duplicate < 40; duplicate++) {
          player.emit(
            _playingSnapshot(
              track,
              position: Duration(milliseconds: duplicate * 250),
            ),
          );
        }
        await _waitUntil(
          () => library.playedTrackIds.lastOrNull == track.id,
          reason: 'The native transition to ${track.id} was not recorded.',
        );
      }

      expect(player.playLocalQueueCalls, 1);
      expect(library.playedTrackIds, tracks.map((track) => track.id));
      expect(library.playlistIds, everyElement('road-trip'));
      expect(container.read(playbackQueueProvider).currentIndex, 5);
      expect(player.activeSnapshotListeners, 1);
      expect(player.maximumSnapshotListeners, 1);
    },
  );

  test(
    'compressed long playback keeps a bounded listener and stable native queue',
    () async {
      final player = _LifecyclePlayerService();
      final library = _LifecycleLibraryRepository();
      final container = _container(player, library: library);
      addTearDown(() async {
        container.dispose();
        await player.dispose();
      });
      final tracks = List.generate(12, (index) => _track(index));

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(tracks.first, queue: tracks);

      // 360 transitions x 60 progress snapshots exercises 21,600 state
      // updates, a compressed equivalent of a multi-hour listening session.
      for (var transition = 1; transition <= 360; transition++) {
        final track = tracks[transition % tracks.length];
        for (var tick = 0; tick < 60; tick++) {
          player.emit(
            _playingSnapshot(track, position: Duration(seconds: tick * 6)),
          );
        }
        await _drainEvents();
      }

      expect(player.playLocalQueueCalls, 1);
      expect(player.activeSnapshotListeners, 1);
      expect(player.maximumSnapshotListeners, 1);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(container.read(playerControllerProvider).hasError, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test('controller rebuilds cancel their previous snapshot listener', () async {
    final player = _LifecyclePlayerService();
    final library = _LifecycleLibraryRepository();
    final container = _container(player, library: library);
    addTearDown(() async {
      container.dispose();
      await player.dispose();
    });

    await container.read(playerControllerProvider.future);
    for (var cycle = 0; cycle < 100; cycle++) {
      container.invalidate(playerControllerProvider);
      await container.read(playerControllerProvider.future);
      expect(player.activeSnapshotListeners, 1);
    }

    expect(player.maximumSnapshotListeners, 1);
    container.dispose();
    await _drainEvents();
    expect(player.activeSnapshotListeners, 0);
    expect(player.snapshotListenCount, player.snapshotCancelCount);
  });

  test(
    'restarting and cancelling the sleep timer leaves no old ticker',
    () async {
      final player = _LifecyclePlayerService();
      final container = _container(
        player,
        library: _LifecycleLibraryRepository(),
      );
      addTearDown(() async {
        container.dispose();
        await player.dispose();
      });
      await container.read(playerControllerProvider.future);
      final timer = container.read(sleepTimerControllerProvider.notifier);

      for (var cycle = 0; cycle < 250; cycle++) {
        timer.start(const Duration(milliseconds: 20));
      }
      timer.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      expect(player.stopCalls, 0);
      expect(container.read(sleepTimerControllerProvider).isActive, isFalse);
    },
  );

  test(
    'failure storms share one bounded retry budget per remote play request',
    () async {
      final player = _LifecyclePlayerService();
      final audioResolver = _LifecycleAudioResolver(
        failFirstRetryPerRequest: true,
      );
      final retryDelay = _ControlledLifecycleRetryDelay();
      final container = _container(
        player,
        library: _LifecycleLibraryRepository(),
        audioResolver: audioResolver,
        retryDelay: retryDelay.call,
      );
      addTearDown(() async {
        container.dispose();
        await player.dispose();
      });
      final tracks = List.generate(8, _remoteTrack);

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRemote(tracks.first, queue: tracks);

      for (var index = 0; index < tracks.length; index++) {
        if (index > 0) {
          await controller.playQueueIndex(index);
        }
        final track = tracks[index];
        for (var duplicate = 0; duplicate < 100; duplicate++) {
          player.emit(
            PlayerSnapshot(
              status: PlayerStatus.failed,
              title: track.title,
              artist: track.artist,
              trackId: track.id,
              sourceUrl: track.url,
              isRemote: true,
              errorMessage: 'HTTP 403 attempt $duplicate',
            ),
          );
        }
        final previousAttempts = index * 2;
        await _waitUntil(
          () => retryDelay.durations.length == previousAttempts + 1,
          reason: 'The first retry for ${track.id} did not enter backoff.',
        );
        retryDelay.releaseNext();
        await _waitUntil(
          () =>
              audioResolver.infoCalls == previousAttempts + 1 &&
              retryDelay.durations.length == previousAttempts + 2,
          reason: 'The final retry for ${track.id} did not enter backoff.',
        );
        retryDelay.releaseNext();
        await _waitUntil(
          () =>
              audioResolver.infoCalls == (index + 1) * 2 &&
              player.playedRemote.length == (index + 1) * 2,
          reason: 'The bounded recovery for ${track.id} did not finish.',
        );
        await _drainEvents();
        expect(audioResolver.infoCalls, (index + 1) * 2);
        expect(retryDelay.durations, hasLength((index + 1) * 2));
      }

      expect(player.playedRemote, hasLength(tracks.length * 2));
      expect(retryDelay.durations, [
        for (var index = 0; index < tracks.length; index++) ...const [
          Duration(seconds: 2),
          Duration(seconds: 5),
        ],
      ]);
      expect(player.activeSnapshotListeners, 1);
      expect(player.maximumSnapshotListeners, 1);
      expect(container.read(playerControllerProvider).hasError, isFalse);
    },
  );
}

ProviderContainer _container(
  _LifecyclePlayerService player, {
  required _LifecycleLibraryRepository library,
  AudioStreamResolver? audioResolver,
  RemotePlaybackRetryDelay? retryDelay,
}) {
  return ProviderContainer(
    overrides: [
      playerServiceProvider.overrideWithValue(player),
      settingsControllerProvider.overrideWith(_LifecycleSettingsController.new),
      libraryRepositoryProvider.overrideWithValue(library),
      playbackHistorySinkProvider.overrideWithValue(
        _LifecyclePlaybackHistorySink(library),
      ),
      if (audioResolver != null)
        audioStreamResolverProvider.overrideWithValue(audioResolver),
      if (retryDelay != null)
        remotePlaybackRetryDelayProvider.overrideWithValue(retryDelay),
      localTrackFileProbeProvider.overrideWithValue(
        (_) async => LocalTrackFileAvailability.present,
      ),
    ],
  );
}

class _LifecycleSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/bstream-lifecycle-test',
    language: AppLanguage.spanish,
    recommendationHistoryEnabled: true,
  );
}

class _LifecyclePlaybackHistorySink implements PlaybackHistorySink {
  const _LifecyclePlaybackHistorySink(this.library);

  final _LifecycleLibraryRepository library;

  @override
  Future<void> persist(PlaybackHistoryWrite write) async {
    final localTrackId = write.track.localTrackId;
    if (!write.isInitialQualification || localTrackId == null) {
      return;
    }
    await library.markPlayed(
      localTrackId,
      write.event.playedAt,
      playlistId: write.track.playlistId,
    );
  }
}

LocalTrack _track(int index, {Duration duration = const Duration(minutes: 6)}) {
  return LocalTrack(
    id: 'track-$index',
    title: 'Track $index',
    artist: 'BStream Music',
    filePath: 'track-$index.m4a',
    addedAt: DateTime(2026),
    duration: duration,
  );
}

TrackInfo _remoteTrack(int index) {
  return TrackInfo(
    id: 'remote-$index',
    title: 'Remote $index',
    artist: 'BStream Music',
    url: 'https://www.youtube.com/watch?v=remote-$index',
    thumbnailUrl: 'https://i.ytimg.com/vi/remote-$index/hqdefault.jpg',
    streamUrl: 'https://media.example/remote-$index-original.m4a',
  );
}

PlayerSnapshot _playingSnapshot(
  LocalTrack track, {
  required Duration position,
}) {
  return PlayerSnapshot(
    status: PlayerStatus.playing,
    title: track.title,
    artist: track.artist,
    trackId: track.id,
    sourceUrl: track.sourceUrl,
    position: position,
    duration: track.duration,
    isRemote: false,
  );
}

Future<void> _drainEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(
  bool Function() predicate, {
  required String reason,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail(reason);
}

class _LifecyclePlayerService implements PlayerService {
  _LifecyclePlayerService() {
    _snapshots = StreamController<PlayerSnapshot>.broadcast(
      onListen: () {
        snapshotListenCount++;
        activeSnapshotListeners++;
        if (activeSnapshotListeners > maximumSnapshotListeners) {
          maximumSnapshotListeners = activeSnapshotListeners;
        }
      },
      onCancel: () {
        snapshotCancelCount++;
        activeSnapshotListeners--;
      },
    );
  }

  late final StreamController<PlayerSnapshot> _snapshots;
  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  int snapshotListenCount = 0;
  int snapshotCancelCount = 0;
  int activeSnapshotListeners = 0;
  int maximumSnapshotListeners = 0;
  int playLocalQueueCalls = 0;
  int stopCalls = 0;
  final List<TrackInfo> playedRemote = [];

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  bool get supportsLocalQueueReplacement => false;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshots.stream;

  void emit(PlayerSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    emit(_playingSnapshot(track, position: Duration.zero));
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) async {
    playLocalQueueCalls++;
    await playLocal(tracks[initialIndex]);
  }

  @override
  Future<void> playRemote(TrackInfo track) async {
    playedRemote.add(track);
    emit(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.url,
        duration: track.duration,
        isRemote: true,
      ),
    );
  }

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {}

  @override
  Future<void> pause() async {
    emit(_snapshot.copyWith(status: PlayerStatus.paused));
  }

  @override
  Future<void> resume() async {
    emit(_snapshot.copyWith(status: PlayerStatus.playing));
  }

  @override
  Future<void> togglePlayPause() async {
    if (_snapshot.status == PlayerStatus.playing) {
      await pause();
    } else {
      await resume();
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    emit(_snapshot.copyWith(status: PlayerStatus.stopped));
  }

  @override
  Future<void> seek(Duration position) async {
    emit(_snapshot.copyWith(position: position));
  }

  @override
  Future<void> setVolume(double volume) async {
    emit(_snapshot.copyWith(volume: volume));
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    emit(_snapshot.copyWith(shuffleEnabled: enabled));
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {
    emit(_snapshot.copyWith(repeatMode: mode));
  }

  @override
  Future<void> dispose() async {
    if (!_snapshots.isClosed) {
      await _snapshots.close();
    }
  }
}

class _LifecycleLibraryRepository implements LibraryRepository {
  final List<String> playedTrackIds = [];
  final List<String?> playlistIds = [];

  @override
  Future<void> markPlayed(
    String trackId,
    DateTime playedAt, {
    String? playlistId,
  }) async {
    playedTrackIds.add(trackId);
    playlistIds.add(playlistId);
  }

  @override
  Future<void> deleteLocalTrack(String trackId) async {}

  @override
  Future<void> deletePlaylist(String playlistId) async {}

  @override
  Future<List<LocalTrack>> getHistory() async => const [];

  @override
  Future<List<LocalTrack>> getLocalTracks() async => const [];

  @override
  Future<List<Playlist>> getPlaylists() async => const [];

  @override
  Future<Set<String>> purgeMissingLocalTracks(List<LocalTrack> tracks) async =>
      const {};

  @override
  Future<void> saveLocalTrack(LocalTrack track) async {}

  @override
  Future<void> savePlaylist(Playlist playlist) async {}
}

class _ControlledLifecycleRetryDelay {
  final List<Duration> durations = [];
  final List<Completer<void>> _gates = [];
  int _nextGate = 0;

  Future<void> call(Duration duration) {
    durations.add(duration);
    final gate = Completer<void>();
    _gates.add(gate);
    return gate.future;
  }

  void releaseNext() {
    if (_nextGate >= _gates.length) {
      throw StateError('No lifecycle retry delay is waiting.');
    }
    _gates[_nextGate++].complete();
  }
}

class _LifecycleAudioResolver implements AudioStreamResolver {
  _LifecycleAudioResolver({this.failFirstRetryPerRequest = false});

  final bool failFirstRetryPerRequest;
  int infoCalls = 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    infoCalls++;
    if (failFirstRetryPerRequest && infoCalls.isOdd) {
      throw const SocketException('HTTP 503 on the first bounded retry');
    }
    final uri = Uri.parse(track.url);
    final id = uri.queryParameters['v'] ?? 'unknown';
    return AudioStreamResolution(
      source: AudioStreamSource.innerTubeFallback,
      streamUrl: 'https://media.example/$id-refreshed.m4a',
      streamExtension: 'm4a',
      streamMimeType: 'audio/mp4',
    );
  }

  @override
  Future<void> dispose() async {}
}
