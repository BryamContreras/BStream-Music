import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/casting/cast_coordinator.dart';
import 'package:bstream_music/services/player/cast_aware_player_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const device = CastDevice(
    id: 'receiver',
    name: 'Living room',
    protocol: CastProtocol.googleCast,
  );
  final track = LocalTrack(
    id: 'local',
    title: 'Title',
    artist: 'Artist',
    filePath: '/music/test.mp3',
    addedAt: DateTime(2026),
  );
  const remoteTrack = TrackInfo(
    id: 'remote',
    title: 'Remote',
    artist: 'Artist',
    url: 'https://music.youtube.com/watch?v=remote',
    streamUrl: 'https://cdn.test/audio.webm',
    streamMimeType: 'audio/webm; codecs="opus"',
  );
  final remote = RemotePlaybackSource(
    track: remoteTrack,
    uri: Uri.parse(remoteTrack.streamUrl!),
    queueEntryId: 'occurrence-1',
    httpHeaders: const {'Authorization': 'test-only'},
  );
  late _LocalPlayer local;
  late _Cast cast;
  late CastAwarePlayerService player;
  setUp(() {
    local = _LocalPlayer();
    cast = _Cast();
    player = CastAwarePlayerService(local: local, cast: cast);
  });
  tearDown(() async {
    await player.dispose();
    await cast.dispose();
  });

  test('construction has no network discovery or cast session', () {
    expect(cast.connections, 0);
    expect(cast.loads, 0);
    expect(player.isCasting, false);
    expect(player.supportsLocalQueueReplacement, true);
  });
  test(
    'normal playback, native queue, skip silence and crossfade delegate unchanged',
    () async {
      await player.playLocal(track);
      expect(local.localPlays, 1);
      await player.configureCrossfade(
        enabled: true,
        duration: const Duration(seconds: 3),
      );
      await player.configureSkipSilence(enabled: true);
      expect(player.crossfadeEnabled, true);
      expect(player.skipSilenceEnabled, true);
      await player.playRemoteSource(remote);
      await player.updateRemoteQueue([remote]);
      expect(local.remotePlays, 1);
      expect(local.remoteUpdates, 1);
      expect(player.currentSnapshot.queueEntryId, 'occurrence-1');
    },
  );
  test(
    'receiver ACK required, preserves position and routes controls remotely',
    () async {
      await player.playLocal(track);
      await player.seek(const Duration(seconds: 27));
      await player.connectCast(device);
      expect(player.isCasting, true);
      expect(local.currentSnapshot.status, PlayerStatus.paused);
      expect(cast.lastPosition, const Duration(seconds: 27));
      expect(cast.lastMime, 'audio/mpeg');
      await player.pause();
      await player.resume();
      await player.seek(const Duration(seconds: 45));
      await player.setVolume(.42);
      expect(cast.pauses, 1);
      expect(cast.plays, 1);
      expect(cast.lastSeek, const Duration(seconds: 45));
      expect(cast.lastVolume, .42);
      expect(player.supportsLocalQueueReplacement, false);
    },
  );
  test(
    'cast failure restores local playback without declaring remote active',
    () async {
      await player.playLocal(track);
      cast.failLoad = true;
      await expectLater(player.connectCast(device), throwsStateError);
      expect(player.isCasting, false);
      expect(local.currentSnapshot.status, PlayerStatus.playing);
      expect(player.currentSnapshot.trackId, track.id);
    },
  );
  test('paused local track remains paused on receiver', () async {
    await player.playLocal(track);
    await player.pause();
    await player.connectCast(device);
    expect(cast.lastAutoplay, false);
    expect(player.currentSnapshot.status, PlayerStatus.paused);
  });
  test('remote MIME and headers remain actual, not hardcoded mp4', () async {
    await player.playRemoteSource(remote);
    await player.connectCast(device);
    expect(cast.lastMime, 'audio/webm');
    expect(cast.lastHeaders, {'Authorization': 'test-only'});
    expect(cast.lastSource, remote.uri);
    expect(player.currentSnapshot.isRemote, true);
  });
  test(
    'skip while casting does not start the phone decoder or prepare remote queue',
    () async {
      await player.playRemoteSource(remote);
      await player.connectCast(device);
      await player.playRemoteSource(
        RemotePlaybackSource(
          track: remoteTrack.copyWith(id: 'next'),
          uri: Uri.parse('https://cdn.test/next.webm'),
          queueEntryId: 'occurrence-2',
        ),
      );
      await player.updateRemoteQueue([remote]);
      expect(local.remotePlays, 1);
      expect(local.remoteUpdates, 0);
      expect(cast.loads, 2);
      expect(player.currentSnapshot.queueEntryId, 'occurrence-2');
    },
  );
  test('disconnect resumes latest cast song at receiver position', () async {
    await player.playLocal(track);
    await player.connectCast(device);
    final next = track.copyWith(
      id: 'next',
      title: 'Next',
      filePath: '/music/next.mp3',
    );
    await player.playLocal(next);
    cast.publish(
      CastState(
        device: device,
        status: CastPlaybackStatus.playing,
        position: const Duration(seconds: 38),
      ),
    );
    await player.disconnectCast();
    expect(player.isCasting, false);
    expect(local.currentSnapshot.trackId, 'next');
    expect(local.currentSnapshot.position, const Duration(seconds: 38));
    expect(local.currentSnapshot.status, PlayerStatus.playing);
  });
  test('stop is not overwritten by receiver idle status', () async {
    await player.playLocal(track);
    await player.connectCast(device);
    await player.stop();
    cast.publish(
      const CastState(device: device, status: CastPlaybackStatus.idle),
    );
    expect(player.currentSnapshot.status, PlayerStatus.stopped);
  });
  test(
    'obsolete connection cannot pause a newer song during crossfade cleanup',
    () async {
      await player.playLocal(track);
      final barrier = Completer<void>();
      local.prepareBarrier = barrier;
      final pending = player.connectCast(device);
      await Future<void>.delayed(Duration.zero);
      await player.playLocal(
        track.copyWith(id: 'next', filePath: '/music/next.mp3'),
      );
      barrier.complete();
      await expectLater(pending, throwsStateError);
      expect(local.currentSnapshot.trackId, 'next');
      expect(local.currentSnapshot.status, PlayerStatus.playing);
      expect(cast.loads, 0);
    },
  );
  test('empty player cannot cast or initialize a connection', () async {
    await expectLater(player.connectCast(device), throwsStateError);
    expect(cast.connections, 0);
  });
  test(
    'failed next cast load restores local exactly once and returns success',
    () async {
      await player.playRemoteSource(remote);
      await player.connectCast(device);
      cast.failLoad = true;
      final next = RemotePlaybackSource(
        track: remoteTrack.copyWith(id: 'next'),
        uri: Uri.parse('https://cdn.test/next.webm'),
        queueEntryId: 'next-occurrence',
      );
      await player.playRemoteSource(next);
      expect(player.isCasting, false);
      expect(local.remotePlays, 2);
      expect(player.currentSnapshot.trackId, 'next');
      expect(player.currentSnapshot.status, PlayerStatus.playing);
      expect(player.currentSnapshot.volume, 1);
    },
  );
  test(
    'unchanged local source returns by seek without reloading decoder',
    () async {
      await player.playLocal(track);
      await player.connectCast(device);
      await player.disconnectCast();
      expect(local.localPlays, 1);
    },
  );
  test('direct resume after cast stop reloads with a new occurrence', () async {
    await player.playLocal(track);
    await player.connectCast(device);
    await player.stop();
    await player.resume();
    expect(cast.loads, 2);
    expect(player.currentSnapshot.status, PlayerStatus.playing);
  });
  test(
    'slow connect follows native queue advance and honors user pause/seek',
    () async {
      final next = track.copyWith(
        id: 'next',
        title: 'Next',
        filePath: '/music/next.mp3',
      );
      await player.playLocalQueue([track, next], 0);
      final barrier = Completer<void>();
      cast.connectBarrier = barrier;
      final pending = player.connectCast(device);
      await Future<void>.delayed(Duration.zero);
      // Native playlist transitions do not call the wrapper's play methods.
      await local.playLocal(next);
      await player.seek(const Duration(seconds: 93));
      await player.pause();
      barrier.complete();
      await pending;
      expect(cast.lastSource, Uri.file(next.filePath));
      expect(cast.lastPosition, const Duration(seconds: 93));
      expect(cast.lastAutoplay, false);
      expect(player.currentSnapshot.trackId, 'next');
      expect(player.currentSnapshot.status, PlayerStatus.paused);
    },
  );
  test('mime inference covers downloaded formats and URL mime hints', () {
    expect(
      castAudioMimeType(Uri.parse('https://cdn.test/media?mime=audio%2Fwebm')),
      'audio/webm',
    );
    expect(castAudioMimeType(Uri.file('/music/test.flac')), 'audio/flac');
    expect(castAudioMimeType(Uri.file('/music/test.ogg')), 'audio/ogg');
  });
}

class _Cast extends CastCoordinator {
  Completer<void>? connectBarrier;
  final controller = StreamController<CastState>.broadcast(sync: true);
  CastState snapshot = const CastState();
  int connections = 0, loads = 0, pauses = 0, plays = 0;
  bool failLoad = false;
  String? lastMime;
  Uri? lastSource;
  Map<String, String>? lastHeaders;
  Duration? lastPosition, lastSeek;
  double? lastVolume;
  bool? lastAutoplay;
  @override
  Stream<CastState> get changes => controller.stream;
  @override
  CastState get state => snapshot;
  void publish(CastState value) {
    snapshot = value;
    controller.add(value);
  }

  @override
  Future<void> connect(CastDevice device) async {
    connections++;
    await connectBarrier?.future;
    publish(CastState(device: device));
  }

  @override
  Future<void> disconnect() async {
    publish(const CastState());
  }

  @override
  Future<void> load({
    required Uri source,
    required String mimeType,
    required String title,
    required String artist,
    required String contentId,
    Map<String, String> headers = const {},
    Uri? artworkUrl,
    Duration? duration,
    Duration position = Duration.zero,
    bool autoplay = true,
  }) async {
    loads++;
    lastMime = mimeType;
    lastSource = source;
    lastHeaders = headers;
    lastPosition = position;
    lastAutoplay = autoplay;
    if (failLoad) throw StateError('receiver rejected codec');
    publish(
      CastState(
        device: snapshot.device,
        contentId: contentId,
        position: position,
        duration: duration,
        status: autoplay
            ? CastPlaybackStatus.playing
            : CastPlaybackStatus.paused,
      ),
    );
  }

  @override
  Future<void> play() async {
    plays++;
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
  }

  @override
  Future<void> setVolume(double volume) async {
    lastVolume = volume;
  }

  @override
  Future<void> stop() async {
    publish(CastState(device: snapshot.device));
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    await controller.close();
  }
}

class _LocalPlayer
    implements
        PlayerService,
        NativeRemoteQueuePlayer,
        CrossfadeCapablePlayer,
        SkipSilenceCapablePlayer {
  final controller = StreamController<PlayerSnapshot>.broadcast(sync: true);
  PlayerSnapshot snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  int localPlays = 0, remotePlays = 0, remoteUpdates = 0;
  Completer<void>? prepareBarrier;
  @override
  bool crossfadeEnabled = false;
  @override
  bool skipSilenceEnabled = false;
  @override
  bool get supportsSkipSilence => true;
  @override
  bool get supportsLocalQueueReplacement => true;
  @override
  PlayerSnapshot get currentSnapshot => snapshot;
  @override
  Stream<PlayerSnapshot> get snapshotStream => controller.stream;
  void publish(PlayerSnapshot value) {
    snapshot = value;
    controller.add(value);
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    localPlays++;
    publish(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        trackId: track.id,
        title: track.title,
        artist: track.artist,
        sourceUrl: track.filePath,
      ),
    );
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) =>
      playLocal(tracks[initialIndex]);
  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {}
  @override
  Future<void> playRemote(TrackInfo track) async {}
  @override
  Future<void> playRemoteSource(RemotePlaybackSource source) async {
    remotePlays++;
    publish(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        trackId: source.track.id,
        queueEntryId: source.queueEntryId,
        title: source.track.title,
        artist: source.track.artist,
        sourceUrl: source.track.url,
        isRemote: true,
      ),
    );
  }

  @override
  Future<void> updateRemoteQueue(
    List<RemotePlaybackSource> upcoming, {
    bool finalize = true,
  }) async {
    remoteUpdates++;
  }

  @override
  Future<void> pause() async {
    publish(snapshot.copyWith(status: PlayerStatus.paused));
  }

  @override
  Future<void> resume() async {
    publish(snapshot.copyWith(status: PlayerStatus.playing));
  }

  @override
  Future<void> stop() async {
    publish(snapshot.copyWith(status: PlayerStatus.stopped));
  }

  @override
  Future<void> seek(Duration position) async {
    publish(snapshot.copyWith(position: position));
  }

  @override
  Future<void> setVolume(double volume) async {
    publish(snapshot.copyWith(volume: volume));
  }

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {
    publish(snapshot.copyWith(repeatMode: mode));
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    publish(snapshot.copyWith(shuffleEnabled: enabled));
  }

  @override
  Future<void> togglePlayPause() async {}
  @override
  Future<void> configureCrossfade({
    required bool enabled,
    required Duration duration,
  }) async {
    crossfadeEnabled = enabled;
  }

  @override
  Future<void> prepareCrossfade(CrossfadePlaybackSource? source) async {
    await prepareBarrier?.future;
  }

  @override
  Future<void> configureSkipSilence({required bool enabled}) async {
    skipSilenceEnabled = enabled;
  }

  @override
  Future<void> dispose() => controller.close();
}
