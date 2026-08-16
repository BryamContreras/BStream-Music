import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/player/just_audio_player_service.dart';
import 'package:bstream_music/services/player/notification_artwork_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaItem remoteItem(String id, String queueEntryId) {
    return MediaItem(
      id: id,
      title: 'Track $id',
      extras: {
        'isRemote': true,
        'queueEntryId': queueEntryId,
        'sourceUrl': 'https://www.youtube.com/watch?v=$id',
      },
    );
  }

  test('an error from a preloaded successor does not fail current track', () {
    final tags = [
      remoteItem('track-a', 'remote:1:0'),
      remoteItem('track-b', 'remote:1:1'),
    ];
    const snapshot = PlayerSnapshot(
      status: PlayerStatus.playing,
      trackId: 'track-a',
      queueEntryId: 'remote:1:0',
      sourceUrl: 'https://www.youtube.com/watch?v=track-a',
      isRemote: true,
    );

    expect(
      justAudioErrorBelongsToSnapshot(
        PlayerException(1, 'HTTP 403', 1),
        sequenceTags: tags,
        currentIndex: 0,
        snapshot: snapshot,
      ),
      isFalse,
    );
  });

  test('a late error from replaced track is not relabeled as new track', () {
    final oldSequence = [remoteItem('track-a', 'remote:1:0')];
    const pendingNewTrack = PlayerSnapshot(
      status: PlayerStatus.loading,
      trackId: 'track-b',
      queueEntryId: 'remote:2:0',
      sourceUrl: 'https://www.youtube.com/watch?v=track-b',
      isRemote: true,
    );

    expect(
      justAudioErrorBelongsToSnapshot(
        PlayerException(1, 'old source failed', 0),
        sequenceTags: oldSequence,
        currentIndex: 0,
        snapshot: pendingNewTrack,
      ),
      isFalse,
    );
  });

  test('an attributed failure for the active source remains visible', () {
    final tags = [
      remoteItem('track-a', 'remote:1:0'),
      remoteItem('track-b', 'remote:1:1'),
    ];
    const snapshot = PlayerSnapshot(
      status: PlayerStatus.playing,
      trackId: 'track-b',
      queueEntryId: 'remote:1:1',
      sourceUrl: 'https://www.youtube.com/watch?v=track-b',
      isRemote: true,
    );

    expect(
      justAudioErrorBelongsToSnapshot(
        PlayerException(1, 'decoder failed', 1),
        sequenceTags: tags,
        currentIndex: 1,
        snapshot: snapshot,
      ),
      isTrue,
    );
  });

  test('unattributed platform failures are never assigned to current song', () {
    const snapshot = PlayerSnapshot(
      status: PlayerStatus.playing,
      trackId: 'track-a',
    );

    expect(
      justAudioErrorBelongsToSnapshot(
        PlayerException(1, 'backend failed', null),
        sequenceTags: const [],
        currentIndex: null,
        snapshot: snapshot,
      ),
      isFalse,
    );
  });

  test(
    'hung source A cannot block B or overwrite it when A completes late',
    () async {
      final fixture = await _Fixture.create();
      final backend = fixture.backend..blockNextSourceLoad = true;
      try {
        final first = fixture.service.playRemoteSource(_remoteSource('a'));
        await _waitUntil(() => backend.sourceLoadCalls.length == 1);

        final second = fixture.service.playRemoteSource(_remoteSource('b'));
        await _waitUntil(() => backend.sourceLoadCalls.length == 2);
        await Future.wait([first, second]);
        await _waitUntil(
          () => fixture.service.currentSnapshot.status == PlayerStatus.playing,
        );

        expect(_queueEntryId(backend), 'remote:b');
        expect(fixture.service.currentSnapshot.trackId, 'b');

        backend.completeSourceLoad(0);
        await _drainEvents();
        expect(_queueEntryId(backend), 'remote:b');
        expect(fixture.service.currentSnapshot.trackId, 'b');
        expect(fixture.service.currentSnapshot.status, PlayerStatus.playing);

        // There is no identity in index:null. Even after B is ready, a delayed
        // error from A must not be relabeled as B.
        backend.emitError(PlayerException(9, 'late A error', null));
        await _drainEvents();
        expect(fixture.service.currentSnapshot.trackId, 'b');
        expect(fixture.service.currentSnapshot.status, PlayerStatus.playing);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'stop finishes while source load never completes and remains final',
    () async {
      final fixture = await _Fixture.create();
      final backend = fixture.backend..blockNextSourceLoad = true;
      try {
        final play = fixture.service.playRemoteSource(_remoteSource('a'));
        await _waitUntil(() => backend.sourceLoadCalls.length == 1);

        final stop = fixture.service.stop();
        await Future.wait([play, stop]);
        expect(fixture.service.currentSnapshot.status, PlayerStatus.stopped);
        expect(backend.playing, isFalse);

        backend.completeSourceLoad(0);
        await _drainEvents();
        expect(backend.sequence, isEmpty);
        expect(backend.playing, isFalse);
        expect(fixture.service.currentSnapshot.status, PlayerStatus.stopped);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'a current setAudioSources Future failure still reaches its caller',
    () async {
      final fixture = await _Fixture.create();
      fixture.backend.failNextSourceLoad = PlayerException(7, 'bad source', 0);
      try {
        await expectLater(
          fixture.service.playLocalQueue([_localTrack('local-a')], 0),
          throwsA(isA<PlayerException>()),
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'uses the loaded media duration when remote catalog metadata omits it',
    () async {
      final fixture = await _Fixture.create();
      final backend = fixture.backend
        ..nextSourceLoadDuration = const Duration(minutes: 3, seconds: 47);
      try {
        await fixture.service.playRemoteSource(_remoteSource('quick-pick'));

        expect(
          fixture.service.currentSnapshot.duration,
          const Duration(minutes: 3, seconds: 47),
        );

        await fixture.service.seek(const Duration(seconds: 42));
        expect(backend.seekCalls, 1);
        expect(backend.position, const Duration(seconds: 42));
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'same-item sequence metadata cannot erase a detected remote duration',
    () async {
      final fixture = await _Fixture.create();
      final backend = fixture.backend;
      try {
        await fixture.service.playRemoteSource(_remoteSource('quick-pick'));
        backend.emitDuration(const Duration(minutes: 4, seconds: 5));
        await _drainEvents();

        expect(
          fixture.service.currentSnapshot.duration,
          const Duration(minutes: 4, seconds: 5),
        );

        // Quick-pick MediaItems have no catalog duration. just_audio can
        // publish their sequence tag after ExoPlayer has detected the real
        // duration; that late tag must not disable the seek bar again.
        backend.emitSequenceState();
        await _drainEvents();

        expect(
          fixture.service.currentSnapshot.duration,
          const Duration(minutes: 4, seconds: 5),
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'a native queue transition never reuses the previous duration',
    () async {
      final fixture = await _Fixture.create();
      final backend = fixture.backend;
      try {
        await fixture.service.playRemoteSource(_remoteSource('quick-pick-a'));
        await fixture.service.updateRemoteQueue([
          _remoteSource('quick-pick-b'),
        ]);
        backend.emitDuration(const Duration(minutes: 3));
        expect(
          fixture.service.currentSnapshot.duration,
          const Duration(minutes: 3),
        );

        backend.emitSequenceState(currentIndex: 1);
        await _drainEvents();

        expect(fixture.service.currentSnapshot.trackId, 'quick-pick-b');
        expect(fixture.service.currentSnapshot.duration, isNull);

        backend.emitDuration(const Duration(minutes: 4, seconds: 11));
        expect(
          fixture.service.currentSnapshot.duration,
          const Duration(minutes: 4, seconds: 11),
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'source deadline interrupts the native load before late completion',
    () async {
      final deadline = Completer<void>();
      final fixture = await _Fixture.create(
        operationDeadline: (_) => deadline.future,
      );
      final backend = fixture.backend..blockNextSourceLoad = true;
      try {
        final play = fixture.service.playRemoteSource(_remoteSource('a'));
        await _waitUntil(() => backend.sourceLoadCalls.length == 1);
        deadline.complete();

        await expectLater(play, throwsA(isA<TimeoutException>()));
        expect(fixture.service.currentSnapshot.status, PlayerStatus.failed);
        backend.completeSourceLoad(0);
        await _drainEvents();
        expect(backend.sequence, isEmpty);
        expect(fixture.service.currentSnapshot.status, PlayerStatus.failed);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'stop cancels incremental replace before any post-await mutation',
    () async {
      final fixture = await _Fixture.create();
      final backend = fixture.backend;
      try {
        await fixture.service.playLocalQueue([
          _localTrack('local-a'),
          _localTrack('local-b'),
        ], 0);
        backend.blockMoves = true;
        final seekCallsBefore = backend.seekCalls;
        final replacement = fixture.service.replaceLocalQueue([
          _localTrack('local-b'),
          _localTrack('local-a'),
        ], 0);
        await backend.moveStarted.future;

        await Future.wait([replacement, fixture.service.stop()]);
        expect(fixture.service.currentSnapshot.status, PlayerStatus.stopped);
        backend.releaseMove.complete();
        await _drainEvents();

        expect(backend.seekCalls, seekCallsBefore);
        expect(backend.playing, isFalse);
        expect(fixture.service.currentSnapshot.status, PlayerStatus.stopped);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'local replacement cannot overlap or overwrite a newer remote source',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bstream_just_audio_race_',
      );
      final artwork = NotificationArtworkService(
        cacheDirectoryProvider: () async => directory,
      );
      final backend = _BlockingAudioPlayer();
      final service = JustAudioPlayerService(
        audioPlayer: backend,
        notificationArtworkService: artwork,
      );
      final localA = _localTrack('local-a');
      final localB = _localTrack('local-b');

      try {
        await service.playLocalQueue([localA, localB], 0);
        backend.blockMoves = true;

        final replacement = service.replaceLocalQueue([localB, localA], 0);
        await backend.moveStarted.future;

        const remoteTrack = TrackInfo(
          id: 'remote-c',
          title: 'Remote C',
          artist: 'Remote artist',
          url: 'https://www.youtube.com/watch?v=remote-c',
          streamUrl: 'https://media.example/remote-c.webm',
          streamExtension: 'webm',
        );
        final remotePlayback = service.playRemoteSource(
          RemotePlaybackSource(
            track: remoteTrack,
            uri: Uri.parse(remoteTrack.streamUrl!),
            queueEntryId: 'remote:2:0',
          ),
        );

        await Future<void>.delayed(Duration.zero);
        expect(backend.setAudioSourcesCalls, 1);
        expect(backend.maximumConcurrentQueueMutations, 1);

        backend.releaseMove.complete();
        await Future.wait([replacement, remotePlayback]);

        expect(backend.maximumConcurrentQueueMutations, 1);
        expect(backend.setAudioSourcesCalls, 2);
        expect(backend.sequence, hasLength(1));
        final tag = backend.sequence.single.tag;
        expect(tag, isA<MediaItem>());
        expect((tag as MediaItem).extras?['queueEntryId'], 'remote:2:0');
        expect(service.currentSnapshot.queueEntryId, 'remote:2:0');
        expect(service.currentSnapshot.isRemote, isTrue);
      } finally {
        if (!backend.releaseMove.isCompleted) {
          backend.releaseMove.complete();
        }
        await service.dispose();
        await artwork.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );
}

RemotePlaybackSource _remoteSource(String id) => RemotePlaybackSource(
  track: TrackInfo(
    id: id,
    title: 'Remote $id',
    artist: 'Remote artist',
    url: 'https://www.youtube.com/watch?v=$id',
    streamUrl: 'https://media.example/$id.webm',
    streamExtension: 'webm',
  ),
  uri: Uri.parse('https://media.example/$id.webm'),
  queueEntryId: 'remote:$id',
);

String? _queueEntryId(_BlockingAudioPlayer backend) {
  if (backend.sequence.isEmpty) return null;
  return (backend.sequence.single.tag as MediaItem).extras?['queueEntryId']
      ?.toString();
}

Future<void> _drainEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Condition did not become true.');
}

class _Fixture {
  _Fixture(this.directory, this.artwork, this.backend, this.service);

  final Directory directory;
  final NotificationArtworkService artwork;
  final _BlockingAudioPlayer backend;
  final JustAudioPlayerService service;

  static Future<_Fixture> create({
    JustAudioOperationDeadline? operationDeadline,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'bstream_just_audio_deadline_',
    );
    final artwork = NotificationArtworkService(
      cacheDirectoryProvider: () async => directory,
    );
    final backend = _BlockingAudioPlayer();
    final service = JustAudioPlayerService(
      audioPlayer: backend,
      notificationArtworkService: artwork,
      operationDeadline: operationDeadline,
    );
    return _Fixture(directory, artwork, backend, service);
  }

  Future<void> dispose() async {
    if (!backend.releaseMove.isCompleted) backend.releaseMove.complete();
    for (final call in backend.sourceLoadCalls) {
      if (!call.completer.isCompleted) call.completer.complete();
    }
    await service.dispose();
    await artwork.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

LocalTrack _localTrack(String id) {
  return LocalTrack(
    id: id,
    title: 'Track $id',
    artist: 'Local artist',
    filePath: 'C:\\music\\$id.mp3',
    addedAt: DateTime(2026),
  );
}

class _BlockingAudioPlayer extends AudioPlayer {
  final _errors = StreamController<PlayerException>.broadcast(sync: true);
  final _states = StreamController<PlayerState>.broadcast(sync: true);
  final _durations = StreamController<Duration?>.broadcast(sync: true);
  final _sequenceStates = StreamController<SequenceState>.broadcast(sync: true);
  final List<AudioSource> _sources = [];
  final List<_SourceLoadCall> sourceLoadCalls = [];

  final Completer<void> moveStarted = Completer<void>();
  final Completer<void> releaseMove = Completer<void>();
  bool blockMoves = false;
  bool blockNextSourceLoad = false;
  PlayerException? failNextSourceLoad;
  Duration? nextSourceLoadDuration;
  bool _playing = false;
  int? _currentIndex;
  Duration _position = Duration.zero;
  int _activeQueueMutations = 0;
  int maximumConcurrentQueueMutations = 0;
  int setAudioSourcesCalls = 0;
  int seekCalls = 0;
  int _sourceRevision = 0;

  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) => const Stream<Duration>.empty();

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  Stream<double> get volumeStream => const Stream<double>.empty();

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<PlayerException> get errorStream => _errors.stream;

  @override
  Stream<SequenceState> get sequenceStateStream => _sequenceStates.stream;

  @override
  List<IndexedAudioSource> get sequence =>
      _sources.expand((source) => source.sequence).toList(growable: false);

  @override
  int? get currentIndex => _currentIndex;

  @override
  bool get playing => _playing;

  @override
  Duration get position => _position;

  Future<T> _queueMutation<T>(Future<T> Function() action) async {
    _activeQueueMutations++;
    if (_activeQueueMutations > maximumConcurrentQueueMutations) {
      maximumConcurrentQueueMutations = _activeQueueMutations;
    }
    try {
      return await action();
    } finally {
      _activeQueueMutations--;
    }
  }

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> audioSources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) {
    return _queueMutation(() async {
      setAudioSourcesCalls++;
      final revision = ++_sourceRevision;
      final call = _SourceLoadCall(
        List<AudioSource>.of(audioSources),
        revision,
        initialIndex,
        initialPosition,
      );
      sourceLoadCalls.add(call);
      final failure = failNextSourceLoad;
      failNextSourceLoad = null;
      if (failure != null) throw failure;
      if (blockNextSourceLoad) {
        blockNextSourceLoad = false;
        await call.completer.future;
      }
      if (revision != _sourceRevision) return null;
      _sources
        ..clear()
        ..addAll(call.sources);
      _currentIndex = _sources.isEmpty ? null : (call.initialIndex ?? 0);
      _position = call.initialPosition ?? Duration.zero;
      final duration = nextSourceLoadDuration;
      nextSourceLoadDuration = null;
      return duration;
    });
  }

  void completeSourceLoad(int index) =>
      sourceLoadCalls[index].completer.complete();

  void emitError(PlayerException error) => _errors.add(error);

  void emitDuration(Duration? duration) => _durations.add(duration);

  void emitSequenceState({int? currentIndex}) {
    if (currentIndex != null) {
      _currentIndex = currentIndex;
    }
    final currentSequence = sequence;
    _sequenceStates.add(
      SequenceState(
        sequence: currentSequence,
        currentIndex: _currentIndex,
        shuffleIndices: List<int>.generate(
          currentSequence.length,
          (index) => index,
        ),
        shuffleModeEnabled: false,
        loopMode: LoopMode.off,
      ),
    );
  }

  @override
  Future<void> moveAudioSource(int currentIndex, int newIndex) {
    return _queueMutation(() async {
      if (blockMoves) {
        if (!moveStarted.isCompleted) {
          moveStarted.complete();
        }
        await releaseMove.future;
      }
      final moved = _sources.removeAt(currentIndex);
      _sources.insert(newIndex, moved);
    });
  }

  @override
  Future<void> insertAudioSource(int index, AudioSource audioSource) {
    return _queueMutation(() async => _sources.insert(index, audioSource));
  }

  @override
  Future<void> removeAudioSourceAt(int index) {
    return _queueMutation(() async => _sources.removeAt(index));
  }

  @override
  Future<void> removeAudioSourceRange(int start, int end) {
    return _queueMutation(() async => _sources.removeRange(start, end));
  }

  @override
  Future<void> clearAudioSources() {
    return _queueMutation(() async {
      _sources.clear();
      _currentIndex = null;
    });
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seekCalls++;
    _position = position ?? Duration.zero;
    if (index != null) {
      _currentIndex = index;
    }
  }

  @override
  Future<void> play() async {
    _playing = true;
    _states.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _states.add(PlayerState(false, ProcessingState.ready));
  }

  @override
  Future<void> stop() async {
    _sourceRevision++;
    _playing = false;
    _states.add(PlayerState(false, ProcessingState.idle));
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setLoopMode(LoopMode mode) async {}

  @override
  Future<void> setShuffleModeEnabled(bool enabled) async {}

  @override
  Future<void> dispose() async {
    // AudioPlayer derives internal subjects from these streams. End them
    // before the base class closes those subjects.
    await _durations.close();
    await _sequenceStates.close();
    await super.dispose();
    await _errors.close();
    await _states.close();
  }
}

class _SourceLoadCall {
  _SourceLoadCall(
    this.sources,
    this.revision,
    this.initialIndex,
    this.initialPosition,
  );

  final List<AudioSource> sources;
  final int revision;
  final int? initialIndex;
  final Duration? initialPosition;
  final completer = Completer<void>();
}
