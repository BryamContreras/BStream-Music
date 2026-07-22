import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/media_session/desktop_media_session.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'sleep timer is disabled by default and keeps its selected duration',
    () {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final controller = container.read(sleepTimerControllerProvider.notifier);

      expect(container.read(sleepTimerControllerProvider).isActive, isFalse);

      controller.selectDuration(const Duration(minutes: 45));
      controller.setEnabled(true);
      expect(container.read(sleepTimerControllerProvider).isActive, isTrue);
      expect(
        container.read(sleepTimerControllerProvider).selectedDuration,
        const Duration(minutes: 45),
      );

      controller.cancel();
      expect(container.read(sleepTimerControllerProvider).isActive, isFalse);
      expect(
        container.read(sleepTimerControllerProvider).selectedDuration,
        const Duration(minutes: 45),
      );
    },
  );

  test('sleep timer stops playback when it expires', () async {
    final player = _FakePlayerService();
    final container = _container(player);
    addTearDown(container.dispose);
    await container.read(playerControllerProvider.future);

    container
        .read(sleepTimerControllerProvider.notifier)
        .start(const Duration(milliseconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    expect(player.stopCalls, 1);
    expect(container.read(sleepTimerControllerProvider).isActive, isFalse);
  });

  test(
    'automatic completion does not replay a single track with repeat off',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(_track(1), queue: [_track(1)]);

      expect(player.playLocalQueueCalls, 1);

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.stopped, trackId: 'track-1'),
      );
      await _flushCompletion();

      expect(player.playLocalQueueCalls, 1);
    },
  );

  test(
    'shuffle with repeat off stops after every queued track has played',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final tracks = [_track(1), _track(2), _track(3)];

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(tracks.first, queue: tracks);
      container.read(playerControllerProvider.notifier).toggleShuffle();

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.playing, trackId: 'track-2'),
      );
      await _flushCompletion();
      player.emit(
        const PlayerSnapshot(status: PlayerStatus.playing, trackId: 'track-3'),
      );
      await _flushCompletion();
      player.emit(
        const PlayerSnapshot(status: PlayerStatus.stopped, trackId: 'track-3'),
      );
      await _flushCompletion();

      expect(player.playLocalQueueCalls, 1);
    },
  );

  test(
    'repeat all replays a single track after automatic completion',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      container.read(playerControllerProvider.notifier).cycleRepeatMode();
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(_track(1), queue: [_track(1)]);

      expect(player.playLocalQueueCalls, 1);

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.stopped, trackId: 'track-1'),
      );
      await _flushCompletion();

      expect(player.playLocalQueueCalls, 2);
    },
  );

  test(
    'replacing local queue keeps current playback and appends next track',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(_track(1), queue: [_track(1)]);

      container.read(playerControllerProvider.notifier).replaceLocalQueue([
        _track(1),
        _track(2),
      ], currentTrackId: 'track-1');

      expect(player.playLocalQueueCalls, 1);

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.stopped, trackId: 'track-1'),
      );
      await _flushCompletion();

      expect(player.playLocalQueueCalls, 2);
      expect(player.currentSnapshot.trackId, 'track-2');
    },
  );

  test(
    'controller-managed LIVE queue skips a failed gap and plays the next ready track',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(
            _track(1),
            queue: [_track(1), _track(2)],
            useNativeQueue: false,
          );

      expect(player.playLocalQueueCalls, 0);
      expect(player.playedLocalIds, ['track-1']);

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.stopped, trackId: 'track-1'),
      );
      await _flushCompletion();
      expect(player.playedLocalIds, ['track-1', 'track-2']);

      container.read(playerControllerProvider.notifier).replaceLocalQueue([
        _track(1),
        _track(2),
        _track(4),
      ], currentTrackId: 'track-2');

      final queue = container.read(playbackQueueProvider);
      expect(queue.entries.map((entry) => entry.id), [
        'track-1',
        'track-2',
        'track-4',
      ]);
      expect(queue.currentIndex, 1);

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.stopped, trackId: 'track-2'),
      );
      await _flushCompletion();

      expect(player.playedLocalIds, ['track-1', 'track-2', 'track-4']);
      expect(container.read(playbackQueueProvider).currentIndex, 2);
    },
  );

  test(
    'adding a track to the active playlist extends its playback queue',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeLibraryRepository()
        ..localTracks.addAll([_track(1), _track(2)])
        ..playlists.add(
          Playlist(
            id: 'dynamic-playlist',
            name: 'Dynamic playlist',
            trackIds: const ['track-1'],
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        );
      final container = _container(player, repository: repository);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container.read(playlistsControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(
            _track(1),
            queue: [_track(1)],
            useNativeQueue: false,
            queueSourceId: PlayerController.playlistQueueSourceId(
              'dynamic-playlist',
            ),
          );

      await container
          .read(playlistsControllerProvider.notifier)
          .addTrackToPlaylist('dynamic-playlist', 'track-2');

      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['track-1', 'track-2'],
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
    },
  );

  test(
    'desktop media session mirrors playback and routes system commands',
    () async {
      final player = _FakePlayerService();
      final session = _FakeDesktopMediaSession();
      final container = _container(player, desktopSession: session);
      var containerDisposed = false;
      addTearDown(() {
        if (!containerDisposed) {
          container.dispose();
        }
      });

      container.read(desktopMediaSessionProvider);
      await container.read(playerControllerProvider.future);
      await _flushCompletion();

      final controller = container.read(playerControllerProvider.notifier);
      await controller.playLocal(_track(1), queue: [_track(1), _track(2)]);
      await _flushCompletion();

      expect(session.callbacks, isNotNull);
      expect(session.states, isNotEmpty);
      expect(session.states.last.snapshot.trackId, 'track-1');
      expect(session.states.last.queue.map((entry) => entry.id), [
        'track-1',
        'track-2',
      ]);
      expect(session.states.last.currentIndex, 0);

      final callbacks = session.callbacks!;
      await callbacks.pause();
      await callbacks.play();
      expect(player.pauseCalls, 1);
      expect(player.resumeCalls, 1);

      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          trackId: 'track-1',
          title: 'Track 1',
          artist: 'BStream Music',
          position: Duration(seconds: 50),
          duration: Duration(minutes: 1),
        ),
      );
      await _flushCompletion();
      await callbacks.seekBy(const Duration(seconds: 15));
      expect(player.lastSeekPosition, const Duration(minutes: 1));
      await callbacks.seekBy(const Duration(seconds: -90));
      expect(player.lastSeekPosition, Duration.zero);

      await callbacks.setShuffleEnabled(true);
      await _flushCompletion();
      final shuffleUpdateCount = player.shuffleValues.length;
      await callbacks.setShuffleEnabled(true);
      await _flushCompletion();
      expect(player.shuffleValues.length, shuffleUpdateCount);
      expect(player.shuffleValues.last, isTrue);

      await callbacks.setRepeatMode(PlaybackRepeatMode.one);
      await _flushCompletion();
      final repeatUpdateCount = player.repeatModes.length;
      await callbacks.setRepeatMode(PlaybackRepeatMode.one);
      await _flushCompletion();
      expect(player.repeatModes.length, repeatUpdateCount);
      expect(player.repeatModes.last, PlaybackRepeatMode.one);

      await callbacks.playQueueIndex(1);
      expect(player.currentSnapshot.trackId, 'track-2');
      await callbacks.previous();
      expect(player.currentSnapshot.trackId, 'track-1');

      await callbacks.stop();
      await _flushCompletion();
      expect(player.stopCalls, 1);
      expect(container.read(playbackQueueProvider).currentIndex, 0);

      await callbacks.play();
      expect(player.currentSnapshot.trackId, 'track-1');

      container.dispose();
      containerDisposed = true;
      await _flushCompletion();
      expect(session.disposed, isTrue);
    },
  );
}

ProviderContainer _container(
  _FakePlayerService player, {
  _FakeLibraryRepository? repository,
  DesktopMediaSession? desktopSession,
}) {
  return ProviderContainer(
    overrides: [
      playerServiceProvider.overrideWithValue(player),
      if (desktopSession != null)
        desktopMediaSessionFactoryProvider.overrideWithValue(
          () => desktopSession,
        ),
      libraryRepositoryProvider.overrideWithValue(
        repository ?? _FakeLibraryRepository(),
      ),
    ],
  );
}

LocalTrack _track(int index) {
  return LocalTrack(
    id: 'track-$index',
    title: 'Track $index',
    artist: 'BStream Music',
    filePath: 'track-$index.mp3',
    addedAt: DateTime(2026),
  );
}

Future<void> _flushCompletion() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakePlayerService implements PlayerService {
  final _controller = StreamController<PlayerSnapshot>.broadcast();
  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  int playLocalQueueCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  Duration? lastSeekPosition;
  final List<bool> shuffleValues = [];
  final List<PlaybackRepeatMode> repeatModes = [];
  final List<String> playedLocalIds = [];

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _controller.stream;

  void emit(PlayerSnapshot snapshot) {
    _snapshot = snapshot;
    _controller.add(snapshot);
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    emit(_snapshot.copyWith(status: PlayerStatus.paused));
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    playedLocalIds.add(track.id);
    emit(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
      ),
    );
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) async {
    playLocalQueueCalls++;
    await playLocal(tracks[initialIndex]);
  }

  @override
  Future<void> playRemote(track) async {}

  @override
  Future<void> resume() async {
    resumeCalls++;
    emit(_snapshot.copyWith(status: PlayerStatus.playing));
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeekPosition = position;
    emit(_snapshot.copyWith(position: position));
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {
    repeatModes.add(mode);
    emit(_snapshot.copyWith(repeatMode: mode));
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    shuffleValues.add(enabled);
    emit(_snapshot.copyWith(shuffleEnabled: enabled));
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    stopCalls++;
    emit(_snapshot.copyWith(status: PlayerStatus.stopped));
  }

  @override
  Future<void> togglePlayPause() async {}
}

class _FakeDesktopMediaSession implements DesktopMediaSession {
  DesktopMediaSessionCallbacks? callbacks;
  final List<DesktopMediaSessionState> states = [];
  bool disposed = false;

  @override
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks) async {
    this.callbacks = callbacks;
  }

  @override
  Future<void> update(DesktopMediaSessionState state) async {
    states.add(state);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeLibraryRepository implements LibraryRepository {
  final List<LocalTrack> localTracks = [];
  final List<Playlist> playlists = [];

  @override
  Future<void> deleteLocalTrack(String trackId) async {}

  @override
  Future<void> deletePlaylist(String playlistId) async {}

  @override
  Future<List<LocalTrack>> getHistory() async => const [];

  @override
  Future<List<LocalTrack>> getLocalTracks() async => List.of(localTracks);

  @override
  Future<List<Playlist>> getPlaylists() async => List.of(playlists);

  @override
  Future<void> markPlayed(String trackId, DateTime playedAt) async {}

  @override
  Future<void> saveLocalTrack(LocalTrack track) async {}

  @override
  Future<void> savePlaylist(Playlist playlist) async {
    final index = playlists.indexWhere((entry) => entry.id == playlist.id);
    if (index < 0) {
      playlists.add(playlist);
    } else {
      playlists[index] = playlist;
    }
  }
}
