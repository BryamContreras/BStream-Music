import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/media_session/desktop_media_session.dart';
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
    'an asynchronous remote failure refreshes its stream once without skipping the song',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeMusicRepository([
        _remoteTrack(streamUrl: 'https://media.example/first.m4a'),
        _remoteTrack(streamUrl: 'https://media.example/refreshed.m4a'),
      ]);
      final container = _container(player, musicRepository: repository);
      addTearDown(container.dispose);
      const searchTrack = TrackInfo(
        id: 'q8j3zwNhLNo',
        title: 'YO SOY TU TITAN',
        artist: 'Pamorkil',
        url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
        thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/hqdefault.jpg',
      );
      const nextTrack = TrackInfo(
        id: 'next-video',
        title: 'Next song',
        artist: 'Artist',
        url: 'https://www.youtube.com/watch?v=next-video',
      );

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(searchTrack, queue: const [searchTrack, nextTrack]);

      expect(repository.infoCalls, 1);
      expect(player.playedRemote.map((track) => track.streamUrl), [
        'https://media.example/first.m4a',
      ]);

      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.failed,
          trackId: 'q8j3zwNhLNo',
          sourceUrl: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
          isRemote: true,
          errorMessage: 'HTTP 403',
        ),
      );
      await _waitUntil(() => player.playedRemote.length == 2);

      expect(repository.infoCalls, 2);
      expect(player.playedRemote.last.streamUrl, contains('refreshed.m4a'));
      expect(container.read(playbackQueueProvider).currentIndex, 0);

      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.failed,
          trackId: 'q8j3zwNhLNo',
          sourceUrl: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
          isRemote: true,
          errorMessage: 'HTTP 403 again',
        ),
      );
      await _flushCompletion();

      expect(repository.infoCalls, 2);
      expect(player.playedRemote, hasLength(2));
      expect(container.read(playbackQueueProvider).currentIndex, 0);
    },
  );

  test('a late failure from the previous remote track is ignored', () async {
    final player = _FakePlayerService();
    final repository = _FakeMusicRepository([
      const TrackInfo(
        id: 'unexpected-refresh',
        title: 'Unexpected refresh',
        artist: 'Artist',
        url: 'https://www.youtube.com/watch?v=unexpected-refresh',
        streamUrl: 'https://media.example/unexpected.m4a',
      ),
    ]);
    final container = _container(player, musicRepository: repository);
    addTearDown(container.dispose);
    const first = TrackInfo(
      id: 'remote-a',
      title: 'Remote A',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=remote-a',
      thumbnailUrl: 'https://i.ytimg.com/vi/remote-a/hqdefault.jpg',
      streamUrl: 'https://media.example/a.m4a',
    );
    const second = TrackInfo(
      id: 'remote-b',
      title: 'Remote B',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=remote-b',
      thumbnailUrl: 'https://i.ytimg.com/vi/remote-b/hqdefault.jpg',
      streamUrl: 'https://media.example/b.m4a',
    );

    await container.read(playerControllerProvider.future);
    final controller = container.read(playerControllerProvider.notifier);
    await controller.playRemote(first, queue: const [first, second]);
    await controller.playQueueIndex(1);

    player.emit(
      const PlayerSnapshot(
        status: PlayerStatus.failed,
        title: 'Remote A',
        artist: 'Artist',
        trackId: 'remote-a',
        sourceUrl: 'https://www.youtube.com/watch?v=remote-a',
        isRemote: true,
        errorMessage: 'late HTTP 403',
      ),
    );
    await _flushCompletion();

    expect(repository.infoCalls, 0);
    expect(player.playedRemote.map((track) => track.id), [
      'remote-a',
      'remote-b',
    ]);
    expect(container.read(playbackQueueProvider).currentIndex, 1);
    expect(container.read(playerControllerProvider).value?.trackId, 'remote-b');
  });

  test(
    'a downloaded remote cache keeps the remote identity and can fall back to streaming',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'bstream-player-cache-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final cachedFile = File('${temporaryDirectory.path}/cached.m4a');
      await cachedFile.writeAsBytes(const [0, 1, 2, 3]);

      final player = _FakePlayerService();
      final repository = _FakeMusicRepository([
        _remoteTrack(streamUrl: 'https://media.example/refreshed.m4a'),
      ]);
      final container = _container(
        player,
        musicRepository: repository,
        remoteCache: _FakeRemotePlaybackCache(cachedFile),
      );
      addTearDown(container.dispose);
      const track = TrackInfo(
        id: 'q8j3zwNhLNo',
        title: 'YO SOY TU TITAN',
        artist: 'Pamorkil',
        url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
        thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/hqdefault.jpg',
        streamUrl: 'https://media.example/original.m4a',
      );

      await container.read(playerControllerProvider.future);
      await container.read(playerControllerProvider.notifier).playRemote(track);

      final cachedTrackId = player.playedLocalIds.single;
      expect(cachedTrackId, startsWith('remote-cache:'));
      expect(container.read(playerControllerProvider).value?.trackId, track.id);
      expect(container.read(playerControllerProvider).value?.isRemote, isTrue);

      player.emit(
        PlayerSnapshot(
          status: PlayerStatus.failed,
          title: track.title,
          artist: track.artist,
          trackId: cachedTrackId,
          sourceUrl: track.url,
          isRemote: false,
          errorMessage: 'cached file became unavailable',
        ),
      );
      await _waitUntil(() => player.playedRemote.isNotEmpty);

      expect(repository.infoCalls, 1);
      expect(player.playedRemote.single.streamUrl, contains('refreshed.m4a'));
      expect(container.read(playerControllerProvider).value?.trackId, track.id);
    },
  );

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
    'a missing local track is purged instead of being sent to the player',
    () async {
      final player = _FakePlayerService();
      final missingTrack = _track(1);
      final repository = _FakeLibraryRepository()
        ..localTracks.add(missingTrack)
        ..playlists.add(
          Playlist(
            id: 'playlist-1',
            name: 'Playlist',
            trackIds: [missingTrack.id],
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        );
      final container = _container(
        player,
        repository: repository,
        fileProbe: (_) async => LocalTrackFileAvailability.missing,
      );
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(missingTrack, queue: [missingTrack, _track(2)]);

      expect(player.playLocalQueueCalls, 0);
      expect(player.playedLocalIds, isEmpty);
      expect(repository.localTracks, isEmpty);
      expect(repository.playlists.single.trackIds, isEmpty);
      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['track-2'],
      );
      expect(container.read(playbackQueueProvider).currentIndex, -1);
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
  MusicRepository? musicRepository,
  DesktopMediaSession? desktopSession,
  LocalTrackFileProbe? fileProbe,
  RemotePlaybackCache? remoteCache,
}) {
  return ProviderContainer(
    overrides: [
      playerServiceProvider.overrideWithValue(player),
      if (musicRepository != null)
        musicRepositoryProvider.overrideWithValue(musicRepository),
      if (desktopSession != null)
        desktopMediaSessionFactoryProvider.overrideWithValue(
          () => desktopSession,
        ),
      if (remoteCache != null)
        remotePlaybackCacheProvider.overrideWithValue(remoteCache),
      libraryRepositoryProvider.overrideWithValue(
        repository ?? _FakeLibraryRepository(),
      ),
      localTrackFileProbeProvider.overrideWithValue(
        fileProbe ?? (_) async => LocalTrackFileAvailability.present,
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

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for asynchronous playback recovery.');
}

TrackInfo _remoteTrack({required String streamUrl}) {
  return TrackInfo(
    id: 'q8j3zwNhLNo',
    title: 'YO SOY TU TITAN',
    artist: 'Pamorkil',
    url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
    thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/hqdefault.jpg',
    streamUrl: streamUrl,
    httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
  );
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
  final List<TrackInfo> playedRemote = [];

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
        sourceUrl: track.sourceUrl,
        isRemote: false,
      ),
    );
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
        trackId: track.id.isEmpty ? track.url : track.id,
        sourceUrl: track.url,
        isRemote: true,
      ),
    );
  }

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

class _FakeRemotePlaybackCache extends RemotePlaybackCache {
  _FakeRemotePlaybackCache(this.file);

  final File file;

  @override
  Future<File?> cachedFile(TrackInfo track) async => file;
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

class _FakeMusicRepository implements MusicRepository {
  _FakeMusicRepository(this.responses);

  final List<TrackInfo> responses;
  int infoCalls = 0;

  @override
  Future<TrackInfo> getInfo(String url) async {
    final index = infoCalls.clamp(0, responses.length - 1);
    infoCalls++;
    return responses[index];
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) => getInfo(url);

  @override
  Future<List<TrackInfo>> search(String query) {
    throw UnimplementedError();
  }

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    throw UnimplementedError();
  }
}

class _FakeLibraryRepository implements LibraryRepository {
  final List<LocalTrack> localTracks = [];
  final List<Playlist> playlists = [];

  @override
  Future<void> deleteLocalTrack(String trackId) async {}

  @override
  Future<Set<String>> purgeMissingLocalTracks(List<LocalTrack> tracks) async {
    final candidates = {for (final track in tracks) track.id: track.filePath};
    final removedIds = localTracks
        .where((track) => candidates[track.id] == track.filePath)
        .map((track) => track.id)
        .toSet();
    localTracks.removeWhere((track) => removedIds.contains(track.id));
    for (var index = 0; index < playlists.length; index++) {
      final playlist = playlists[index];
      playlists[index] = playlist.copyWith(
        trackIds: playlist.trackIds
            .where((id) => !removedIds.contains(id))
            .toList(growable: false),
      );
    }
    return removedIds;
  }

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
