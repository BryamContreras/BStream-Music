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

  test('contains an optional notification artwork warmup failure', () async {
    final asynchronousErrors = <Object>[];
    var attempts = 0;

    await runZonedGuarded(() async {
      final artwork = NotificationArtworkService(
        serverBinder: () {
          attempts++;
          return Future<HttpServer>.error(StateError('loopback unavailable'));
        },
      );
      final service = JustAudioPlayerService(
        audioPlayer: _BlockingAudioPlayer(),
        notificationArtworkService: artwork,
      );
      await _drainEvents();
      await service.dispose();
      await artwork.dispose();
    }, (error, _) => asynchronousErrors.add(error));

    expect(attempts, 1);
    expect(asynchronousErrors, isEmpty);
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

  test('loads an iOS Media Library item as a URI, not a file path', () async {
    final fixture = await _Fixture.create();
    const mediaLibraryURI = 'ipod-library://item/item.m4a?id=42';
    try {
      await fixture.service.playLocalQueue([
        _localTrack('ios-media', filePath: mediaLibraryURI),
      ], 0);

      final source = fixture.backend.sourceLoadCalls.single.sources.single;
      expect(source, isA<UriAudioSource>());
      expect((source as UriAudioSource).uri.toString(), mediaLibraryURI);
    } finally {
      await fixture.dispose();
    }
  });

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

  group('dual-deck crossfade', () {
    test(
      'skip silence stays synchronized across an active crossfade',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.service.configureSkipSilence(enabled: true);
          expect(fixture.primary.skipSilenceCalls, [true]);

          await fixture.playAndPrepare(masterVolume: 0.72);
          expect(fixture.standby.skipSilenceCalls.last, isTrue);
          expect(fixture.service.crossfadeEnabled, isTrue);

          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _waitUntil(
            () => fixture.standby.volumeCalls.any((volume) => volume > 0),
            attempts: 500,
          );

          await fixture.service.configureSkipSilence(enabled: false);
          expect(
            fixture.primary.skipSilenceCalls.last,
            isTrue,
            reason: 'AudioSink changes are deferred while both decks play.',
          );
          expect(fixture.standby.skipSilenceCalls.last, isTrue);

          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          await _waitUntil(
            () =>
                fixture.primary.skipSilenceCalls.last == false &&
                fixture.standby.skipSilenceCalls.last == false,
          );

          expect(fixture.service.skipSilenceEnabled, isFalse);
          expect(fixture.service.crossfadeEnabled, isTrue);
          expect(fixture.primary.seekCalls, 0);
          expect(fixture.standby.seekCalls, 0);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('a transient deck failure is retried before crossfade', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.72);
        fixture.standby.skipSilenceFailuresRemaining = 1;

        await fixture.service.configureSkipSilence(enabled: true);

        expect(fixture.primary.appliedSkipSilenceEnabled, isTrue);
        expect(fixture.standby.appliedSkipSilenceEnabled, isTrue);
        expect(
          fixture.standby.skipSilenceCalls.where((enabled) => enabled),
          hasLength(2),
        );

        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
          attempts: 700,
        );
        expect(fixture.service.crossfadeEnabled, isTrue);
        expect(fixture.primary.seekCalls, 0);
        expect(fixture.standby.seekCalls, 0);
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'a persistent deck failure discards only standby and retries next time',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.72);
          fixture.standby.skipSilenceFailuresRemaining = 2;

          await fixture.service.configureSkipSilence(enabled: true);

          expect(fixture.primary.appliedSkipSilenceEnabled, isTrue);
          expect(fixture.standby.appliedSkipSilenceEnabled, isFalse);
          expect(fixture.standby.disposeCalls, 1);
          expect(fixture.service.crossfadeEnabled, isTrue);
          expect(
            fixture.service.currentSnapshot.queueEntryId,
            'remote:current',
          );
          expect(fixture.primary.seekCalls, 0);

          await fixture.service.prepareCrossfade(
            RemoteCrossfadePlaybackSource(_remoteSource('next')),
          );
          final replacement = fixture.factoryPlayers.single;
          expect(replacement.appliedSkipSilenceEnabled, isTrue);

          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(replacement.playCalls, 1);
          expect(fixture.service.crossfadeEnabled, isTrue);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('crossfade waits for an in-flight skip silence write', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.72);
        fixture.primary.blockNextSkipSilence = true;

        final configuration = fixture.service.configureSkipSilence(
          enabled: true,
        );
        await fixture.primary.skipSilenceWriteStarted.future;
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _drainEvents();

        expect(fixture.standby.playCalls, 0);
        expect(
          fixture.standby.volumeCalls.where((volume) => volume > 0),
          isEmpty,
        );

        fixture.primary.releaseSkipSilenceWrite.complete();
        await configuration;
        await _waitUntil(
          () => fixture.standby.volumeCalls.any((volume) => volume > 0),
          attempts: 500,
        );
        expect(fixture.service.crossfadeEnabled, isTrue);
      } finally {
        if (!fixture.primary.releaseSkipSilenceWrite.isCompleted) {
          fixture.primary.releaseSkipSilenceWrite.complete();
        }
        await fixture.dispose();
      }
    });

    test(
      'a waiting crossfade resumes after applying the newest setting',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.72);
          fixture.primary.blockNextSkipSilence = true;

          final obsolete = fixture.service.configureSkipSilence(enabled: true);
          await fixture.primary.skipSilenceWriteStarted.future;
          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _drainEvents();

          await fixture.service.configureSkipSilence(enabled: false);
          fixture.primary.emitCompleted();
          await _drainEvents();
          expect(fixture.standby.playCalls, 0);

          fixture.primary.releaseSkipSilenceWrite.complete();
          await obsolete;
          await _waitUntil(
            () =>
                fixture.primary.skipSilenceCalls.last == false &&
                fixture.standby.skipSilenceCalls.last == false,
          );
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(fixture.standby.playCalls, 1);
          expect(fixture.service.skipSilenceEnabled, isFalse);
          expect(fixture.service.crossfadeEnabled, isTrue);
        } finally {
          if (!fixture.primary.releaseSkipSilenceWrite.isCompleted) {
            fixture.primary.releaseSkipSilenceWrite.complete();
          }
          await fixture.dispose();
        }
      },
    );

    test(
      'a setting superseding the recovery flush still resumes crossfade',
      () async {
        final fixture = await _CrossfadeFixture.create();
        final flushStarted = Completer<void>();
        final releaseFlush = Completer<void>();
        try {
          await fixture.playAndPrepare(masterVolume: 0.72);
          fixture.primary.blockNextSkipSilence = true;

          final first = fixture.service.configureSkipSilence(enabled: true);
          await fixture.primary.skipSilenceWriteStarted.future;
          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await fixture.service.configureSkipSilence(enabled: false);
          fixture.primary.emitCompleted();
          fixture.primary.queueSkipSilenceWriteBlock(
            started: flushStarted,
            release: releaseFlush,
          );
          fixture.primary.releaseSkipSilenceWrite.complete();

          await flushStarted.future;
          final latest = fixture.service.configureSkipSilence(enabled: true);
          releaseFlush.complete();
          await Future.wait([first, latest]);

          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(fixture.service.skipSilenceEnabled, isTrue);
          expect(fixture.primary.skipSilenceCalls.last, isTrue);
          expect(fixture.standby.skipSilenceCalls.last, isTrue);
          expect(fixture.standby.playCalls, 1);
        } finally {
          if (!fixture.primary.releaseSkipSilenceWrite.isCompleted) {
            fixture.primary.releaseSkipSilenceWrite.complete();
          }
          if (!releaseFlush.isCompleted) releaseFlush.complete();
          await fixture.dispose();
        }
      },
    );

    test(
      'a stale failed silence write cannot discard the prepared deck',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.72);
          fixture.primary.blockNextSkipSilence = true;
          fixture.standby.skipSilenceFailuresRemaining = 2;

          final obsolete = fixture.service.configureSkipSilence(enabled: true);
          await fixture.primary.skipSilenceWriteStarted.future;
          final latest = fixture.service.configureSkipSilence(enabled: false);
          fixture.primary.releaseSkipSilenceWrite.complete();
          await Future.wait([obsolete, latest]);

          expect(fixture.service.skipSilenceEnabled, isFalse);
          expect(fixture.primary.appliedSkipSilenceEnabled, isFalse);
          expect(fixture.standby.appliedSkipSilenceEnabled, isFalse);
          expect(
            fixture.standby.disposeCalls,
            0,
            reason: 'Only the newest setting may invalidate a standby deck.',
          );

          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(fixture.service.crossfadeEnabled, isTrue);
        } finally {
          if (!fixture.primary.releaseSkipSilenceWrite.isCompleted) {
            fixture.primary.releaseSkipSilenceWrite.complete();
          }
          await fixture.dispose();
        }
      },
    );

    test(
      'a hung silence write quarantines crossfade but not player controls',
      () async {
        final fixture = await _CrossfadeFixture.create(
          skipSilenceWriteTimeout: const Duration(milliseconds: 40),
        );
        try {
          await fixture.playAndPrepare(masterVolume: 0.72);
          fixture.primary.blockNextSkipSilence = true;

          final configuration = fixture.service.configureSkipSilence(
            enabled: true,
          );
          await fixture.primary.skipSilenceWriteStarted.future;
          await configuration.timeout(const Duration(seconds: 1));

          expect(fixture.service.skipSilenceEnabled, isTrue);
          expect(fixture.service.crossfadeEnabled, isTrue);
          expect(fixture.standby.disposeCalls, 1);
          expect(fixture.primary.skipSilenceCalls, [false, true]);
          await fixture.service
              .setVolume(0.63)
              .timeout(const Duration(seconds: 1));

          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _drainEvents();
          expect(fixture.standby.playCalls, 0);

          fixture.primary.releaseSkipSilenceWrite.complete();
          await _waitUntil(() => fixture.primary.skipSilenceCalls.length >= 4);
          expect(
            fixture.primary.skipSilenceCalls,
            containsAllInOrder([true, false, true]),
          );
          await fixture.service.prepareCrossfade(
            RemoteCrossfadePlaybackSource(_remoteSource('next')),
          );
          final replacement = fixture.factoryPlayers.single;
          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(replacement.playCalls, 1);
        } finally {
          if (!fixture.primary.releaseSkipSilenceWrite.isCompleted) {
            fixture.primary.releaseSkipSilenceWrite.complete();
          }
          await fixture.dispose();
        }
      },
    );

    test(
      'a late native rollback is force-resynchronized after settling',
      () async {
        final fixture = await _CrossfadeFixture.create(
          skipSilenceWriteTimeout: const Duration(milliseconds: 40),
        );
        try {
          await fixture.playCurrent(masterVolume: 0.72);
          fixture.primary.blockNextSkipSilence = true;
          fixture.primary.skipSilenceFailuresRemaining = 1;

          final configuration = fixture.service.configureSkipSilence(
            enabled: true,
          );
          await fixture.primary.skipSilenceWriteStarted.future;
          await configuration.timeout(const Duration(seconds: 1));

          expect(fixture.service.skipSilenceEnabled, isTrue);
          expect(fixture.primary.appliedSkipSilenceEnabled, isTrue);
          expect(fixture.primary.skipSilenceCalls, [true]);

          fixture.primary.releaseSkipSilenceWrite.complete();
          await _waitUntil(
            () =>
                fixture.primary.skipSilenceCalls.length >= 3 &&
                fixture.primary.appliedSkipSilenceEnabled,
          );
          expect(
            fixture.primary.skipSilenceCalls,
            containsAllInOrder([true, false, true]),
          );
          expect(fixture.standby.skipSilenceCalls, isEmpty);
        } finally {
          if (!fixture.primary.releaseSkipSilenceWrite.isCompleted) {
            fixture.primary.releaseSkipSilenceWrite.complete();
          }
          await fixture.dispose();
        }
      },
    );

    test('completed is restored when crossfade startup is cancelled', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(
          masterVolume: 0.72,
          crossfadeDuration: const Duration(seconds: 5),
          trackDuration: const Duration(seconds: 10),
        );
        fixture.primary.blockNextSkipSilence = true;
        final configuration = fixture.service.configureSkipSilence(
          enabled: true,
        );
        await fixture.primary.skipSilenceWriteStarted.future;

        fixture.primary.emitPosition(const Duration(seconds: 5));
        fixture.primary.emitCompleted();
        final disable = fixture.service.configureCrossfade(
          enabled: false,
          duration: const Duration(seconds: 5),
        );
        fixture.primary.releaseSkipSilenceWrite.complete();
        await Future.wait([configuration, disable]);
        await _drainEvents();

        expect(fixture.service.currentSnapshot.status, PlayerStatus.completed);
        expect(
          fixture.service.currentSnapshot.position,
          const Duration(seconds: 10),
        );
        expect(fixture.standby.playCalls, 0);
        expect(fixture.primary.seekCalls, 0);
      } finally {
        if (!fixture.primary.releaseSkipSilenceWrite.isCompleted) {
          fixture.primary.releaseSkipSilenceWrite.complete();
        }
        await fixture.dispose();
      }
    });

    test('an immediate promotion failure restores the outgoing deck', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.service.configureSkipSilence(enabled: true);
        await fixture.playAndPrepare(
          masterVolume: 0.72,
          crossfadeDuration: const Duration(seconds: 5),
          trackDuration: const Duration(seconds: 10),
        );

        fixture.primary.emitPosition(const Duration(seconds: 5));
        await _waitUntil(
          () => fixture.standby.volumeCalls.any((volume) => volume > 0),
          attempts: 500,
        );
        fixture.primary.failNextVolumeWrite = true;
        fixture.primary.emitCompleted();

        await _waitUntil(
          () =>
              fixture.service.currentSnapshot.status ==
                  PlayerStatus.completed &&
              fixture.standby.disposeCalls == 1,
          attempts: 500,
        );
        expect(fixture.primary.volumeCalls.last, closeTo(0.72, 0.001));
        expect(fixture.service.crossfadeEnabled, isTrue);
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
      } finally {
        await fixture.dispose();
      }
    });

    test('a late play failure follows the deck after promotion', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.service.configureSkipSilence(enabled: true);
        await fixture.playAndPrepare(
          masterVolume: 0.72,
          crossfadeDuration: const Duration(seconds: 5),
          trackDuration: const Duration(seconds: 10),
        );
        fixture.standby.blockNextPlay = true;
        fixture.standby.failBlockedPlay = true;

        fixture.primary.emitPosition(const Duration(seconds: 5));
        await fixture.standby.playStarted.future;
        fixture.primary.emitCompleted();
        await _waitUntil(
          () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
          attempts: 500,
        );

        fixture.standby.releasePlay.complete();
        await _waitUntil(
          () => fixture.service.currentSnapshot.status == PlayerStatus.failed,
          attempts: 500,
        );
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:next');
        expect(fixture.service.crossfadeEnabled, isTrue);
      } finally {
        if (!fixture.standby.releasePlay.isCompleted) {
          fixture.standby.releasePlay.complete();
        }
        await fixture.dispose();
      }
    });

    test(
      'a late play failure cannot fail a newer source on the same deck',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.service.configureSkipSilence(enabled: true);
          await fixture.playAndPrepare(
            masterVolume: 0.72,
            crossfadeDuration: const Duration(seconds: 5),
            trackDuration: const Duration(seconds: 10),
          );
          fixture.standby.blockNextPlay = true;
          fixture.standby.failBlockedPlay = true;

          fixture.primary.emitPosition(const Duration(seconds: 5));
          await fixture.standby.playStarted.future;
          fixture.primary.emitCompleted();
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 500,
          );

          await fixture.service.playRemoteSource(_remoteSource('replacement'));
          expect(
            fixture.service.currentSnapshot.queueEntryId,
            'remote:replacement',
          );
          fixture.standby.releasePlay.complete();
          await _drainEvents();

          expect(
            fixture.service.currentSnapshot.queueEntryId,
            'remote:replacement',
          );
          expect(
            fixture.service.currentSnapshot.status,
            isNot(PlayerStatus.failed),
          );
        } finally {
          if (!fixture.standby.releasePlay.isCompleted) {
            fixture.standby.releasePlay.complete();
          }
          await fixture.dispose();
        }
      },
    );

    test(
      'a source advancing during diagnostics rejects the older play failure',
      () async {
        final diagnosticStarted = Completer<void>();
        final releaseDiagnostic = Completer<void>();
        final fixture = await _CrossfadeFixture.create(
          remoteDiagnosticProbe: (_) async {
            if (!diagnosticStarted.isCompleted) diagnosticStarted.complete();
            await releaseDiagnostic.future;
            return 'delayed diagnostic';
          },
        );
        try {
          final next = _remoteSource('next');
          final third = _remoteSource('third');

          await fixture.service.configureSkipSilence(enabled: true);
          await fixture.service.playRemoteSource(_remoteSource('current'));
          await fixture.service.updateRemoteQueue([next, third]);
          await fixture.service.setVolume(0.72);
          await fixture.service.configureCrossfade(
            enabled: true,
            duration: const Duration(seconds: 5),
          );
          fixture.primary.emitDuration(const Duration(seconds: 10));
          await fixture.service.prepareCrossfade(
            RemoteCrossfadePlaybackSource(next),
          );
          fixture.standby.blockNextPlay = true;
          fixture.standby.blockedPlayFailure = StateError(
            'Source error: decoder failed',
          );

          fixture.primary.emitPosition(const Duration(seconds: 5));
          await fixture.standby.playStarted.future;
          fixture.primary.emitCompleted();
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 500,
          );

          fixture.standby.releasePlay.complete();
          await diagnosticStarted.future.timeout(const Duration(seconds: 2));
          fixture.standby.emitSequenceState(currentIndex: 2);
          await _waitUntil(
            () =>
                fixture.service.currentSnapshot.queueEntryId == 'remote:third',
          );
          releaseDiagnostic.complete();
          await _drainEvents();

          expect(fixture.service.currentSnapshot.queueEntryId, 'remote:third');
          expect(
            fixture.service.currentSnapshot.status,
            isNot(PlayerStatus.failed),
          );
        } finally {
          if (!fixture.standby.releasePlay.isCompleted) {
            fixture.standby.releasePlay.complete();
          }
          if (!releaseDiagnostic.isCompleted) releaseDiagnostic.complete();
          await fixture.dispose();
        }
      },
    );

    test(
      'native advance wins safely while crossfade awaits a silence write',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.72);
          fixture.primary.blockNextSkipSilence = true;
          final configuration = fixture.service.configureSkipSilence(
            enabled: true,
          );
          await fixture.primary.skipSilenceWriteStarted.future;

          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          fixture.primary.emitSequenceState(currentIndex: 1);
          fixture.primary.releaseSkipSilenceWrite.complete();
          await configuration;
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
          );
          await _drainEvents();

          expect(fixture.standby.playCalls, 0);
          expect(fixture.primary.seekCalls, 0);
          expect(fixture.service.crossfadeEnabled, isTrue);
        } finally {
          if (!fixture.primary.releaseSkipSilenceWrite.isCompleted) {
            fixture.primary.releaseSkipSilenceWrite.complete();
          }
          await fixture.dispose();
        }
      },
    );

    test(
      'completed outgoing shortens a crossfade waiting on a silence write',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(
            masterVolume: 0.72,
            crossfadeDuration: const Duration(seconds: 5),
            trackDuration: const Duration(seconds: 10),
          );
          fixture.primary.blockNextSkipSilence = true;
          final configuration = fixture.service.configureSkipSilence(
            enabled: true,
          );
          await fixture.primary.skipSilenceWriteStarted.future;

          fixture.primary.emitPosition(const Duration(seconds: 5));
          fixture.primary.emitCompleted();
          fixture.primary.releaseSkipSilenceWrite.complete();
          await configuration;

          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 500,
          );
          expect(fixture.standby.playCalls, 1);
          expect(fixture.service.crossfadeEnabled, isTrue);
        } finally {
          if (!fixture.primary.releaseSkipSilenceWrite.isCompleted) {
            fixture.primary.releaseSkipSilenceWrite.complete();
          }
          await fixture.dispose();
        }
      },
    );

    test(
      'skip silence position leap cannot miss the crossfade handoff',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.service.configureSkipSilence(enabled: true);
          await fixture.playAndPrepare(masterVolume: 0.72);

          // Media3 reports skipped frames on the source timeline, so a long
          // silent tail can jump over both the configured window and the normal
          // 350 ms late-start safety gate in a single position event.
          fixture.primary.emitPosition(const Duration(milliseconds: 800));

          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(fixture.standby.playCalls, 1);
          expect(fixture.service.crossfadeEnabled, isTrue);
          expect(fixture.primary.seekCalls, 0);
          expect(fixture.standby.seekCalls, 0);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test(
      'a skipped silent tail accelerates an active long crossfade',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.service.configureSkipSilence(enabled: true);
          await fixture.playAndPrepare(
            masterVolume: 0.72,
            crossfadeDuration: const Duration(seconds: 5),
            trackDuration: const Duration(seconds: 10),
          );

          fixture.primary.emitPosition(const Duration(seconds: 5));
          await _waitUntil(
            () => fixture.standby.volumeCalls.any((volume) => volume > 0),
            attempts: 500,
          );
          fixture.primary.emitCompleted();

          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 500,
          );
          expect(fixture.standby.playCalls, 1);
          expect(fixture.service.crossfadeEnabled, isTrue);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test(
      'a native queue advance accelerates an active long crossfade',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.service.configureSkipSilence(enabled: true);
          await fixture.playAndPrepare(
            masterVolume: 0.72,
            crossfadeDuration: const Duration(seconds: 5),
            trackDuration: const Duration(seconds: 10),
          );

          fixture.primary.emitPosition(const Duration(seconds: 5));
          await _waitUntil(
            () => fixture.standby.volumeCalls.any((volume) => volume > 0),
            attempts: 500,
          );
          fixture.primary.emitSequenceState(currentIndex: 1);

          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 500,
          );
          expect(fixture.primary.volumeCalls.last, 0);
          expect(fixture.standby.playCalls, 1);
          expect(fixture.service.crossfadeEnabled, isTrue);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test(
      'promotes the prepared deck without seeking or reopening it',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.72);

          expect(fixture.standby.setAudioSourcesCalls, 1);
          expect(_queueEntryId(fixture.standby), 'remote:next');
          expect(fixture.standby.currentIndex, 1);
          expect(fixture.standby.volumeCalls.first, 0);
          expect(fixture.standby.playCalls, 0);

          fixture.standby.emitPosition(const Duration(milliseconds: 850));
          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );

          expect(fixture.primary.seekCalls, 0);
          expect(fixture.primary.currentIndex, 0);
          expect(fixture.primary.volumeCalls.last, closeTo(0, 1e-9));
          expect(fixture.standby.seekCalls, 0);
          expect(fixture.standby.setAudioSourcesCalls, 1);
          expect(fixture.standby.currentIndex, 1);
          expect(fixture.standby.position, const Duration(milliseconds: 850));
          expect(
            fixture.service.currentSnapshot.position,
            const Duration(milliseconds: 850),
          );
          expect(fixture.standby.volumeCalls.last, closeTo(0.72, 1e-9));
          expect(fixture.primary.disposeCalls, 0);
          expect(fixture.standby.disposeCalls, 0);

          fixture.standby.emitPosition(const Duration(milliseconds: 910));
          fixture.primary.emitPosition(const Duration(milliseconds: 125));
          await _drainEvents();
          expect(
            fixture.service.currentSnapshot.position,
            const Duration(milliseconds: 910),
            reason: 'Only the promoted deck may publish the active timeline.',
          );

          await fixture.service.updateRemoteQueue([_remoteSource('third')]);
          expect(fixture.standby.setAudioSourcesCalls, 1);
          expect(fixture.standby.seekCalls, 0);
          expect(fixture.standby.sequence, hasLength(3));
          expect(fixture.standby.currentIndex, 1);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('a volume change during the fade governs both decks', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.8);
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.standby.volumeCalls.any((volume) => volume > 0.05),
          attempts: 500,
        );

        await fixture.service.setVolume(0.35);
        final primaryChangeIndex = fixture.primary.volumeCalls.length;
        final standbyChangeIndex = fixture.standby.volumeCalls.length;
        expect(fixture.service.currentSnapshot.volume, closeTo(0.35, 1e-9));

        await _waitUntil(
          () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
          attempts: 700,
        );
        for (final volume in fixture.primary.volumeCalls.skip(
          primaryChangeIndex,
        )) {
          expect(volume, inInclusiveRange(0, 0.35));
        }
        for (final volume in fixture.standby.volumeCalls.skip(
          standbyChangeIndex,
        )) {
          expect(volume, inInclusiveRange(0, 0.35));
        }
        expect(fixture.service.currentSnapshot.volume, closeTo(0.35, 1e-9));
        expect(fixture.primary.volumeCalls.last, closeTo(0, 1e-9));
        expect(fixture.standby.volumeCalls.last, closeTo(0.35, 1e-9));
      } finally {
        await fixture.dispose();
      }
    });

    test('reuses the outgoing deck for the following crossfade', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.69);
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
          attempts: 700,
        );

        await fixture.service.prepareCrossfade(
          RemoteCrossfadePlaybackSource(_remoteSource('third')),
        );

        expect(fixture.factoryPlayers, isEmpty);
        expect(fixture.primary.setAudioSourcesCalls, 2);
        expect(fixture.primary.currentIndex, 2);
        expect(_queueEntryId(fixture.primary), 'remote:third');
        expect(fixture.standby.setAudioSourcesCalls, 1);
        expect(fixture.primary.stopCalls, 0);

        fixture.standby.emitDuration(const Duration(milliseconds: 800));
        fixture.primary.emitPosition(const Duration(milliseconds: 875));
        fixture.standby.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.service.currentSnapshot.queueEntryId == 'remote:third',
          attempts: 700,
        );

        expect(fixture.factoryPlayers, isEmpty);
        expect(fixture.primary.seekCalls, 0);
        expect(
          fixture.primary.stopCalls,
          0,
          reason: 'The cancelled retirement must not stop the reused deck.',
        );
        expect(fixture.primary.setAudioSourcesCalls, 2);
        expect(fixture.standby.setAudioSourcesCalls, 1);
        expect(
          fixture.service.currentSnapshot.position,
          const Duration(milliseconds: 875),
        );
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'controller-managed local playback promotes singleton B without reload',
      () async {
        final fixture = await _CrossfadeFixture.create();
        final trackA = _localTrack('a');
        final trackB = _localTrack('b');
        final trackC = _localTrack('c');
        try {
          await fixture.service.setShuffleEnabled(true);
          await fixture.service.playLocal(trackA);
          await fixture.service.setVolume(0.63);
          await fixture.service.configureCrossfade(
            enabled: true,
            duration: const Duration(milliseconds: 400),
          );
          fixture.primary.emitDuration(const Duration(milliseconds: 800));
          await _drainEvents();

          await fixture.service.prepareCrossfade(
            LocalCrossfadePlaybackSource(trackB),
          );
          expect(fixture.standby.sequence, hasLength(1));
          expect(fixture.standby.currentIndex, 0);
          expect(_trackId(fixture.standby), 'b');

          fixture.standby.emitPosition(const Duration(milliseconds: 840));
          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _waitUntil(
            () => fixture.service.currentSnapshot.trackId == 'b',
            attempts: 700,
          );

          expect(fixture.primary.seekCalls, 0);
          expect(fixture.standby.seekCalls, 0);
          expect(fixture.standby.setAudioSourcesCalls, 1);
          expect(
            fixture.service.currentSnapshot.position,
            const Duration(milliseconds: 840),
          );

          await fixture.service.replaceLocalQueue([trackA, trackB, trackC], 1);
          expect(fixture.standby.setAudioSourcesCalls, 1);
          expect(fixture.standby.seekCalls, 0);
          expect(fixture.standby.sequence, hasLength(3));
          expect(fixture.standby.currentIndex, 1);
          expect(fixture.standby.position, const Duration(milliseconds: 840));
        } finally {
          await fixture.dispose();
        }
      },
    );

    test(
      'native shuffle preserves the exact duplicate occurrence after swap',
      () async {
        final fixture = await _CrossfadeFixture.create();
        final tracks = [_localTrack('a'), _localTrack('b'), _localTrack('a')];
        try {
          await fixture.service.playLocalQueue(tracks, 1);
          await fixture.service.setShuffleEnabled(true);
          fixture.primary.setShuffleOrderForTest([1, 2, 0]);
          await fixture.service.configureCrossfade(
            enabled: true,
            duration: const Duration(milliseconds: 400),
          );
          fixture.primary.emitDuration(const Duration(milliseconds: 800));
          await _drainEvents();

          await fixture.service.prepareCrossfade(
            LocalCrossfadePlaybackSource(tracks[0]),
          );
          expect(fixture.standby.currentIndex, 2);
          expect(_trackId(fixture.standby), 'a');
          expect(fixture.standby.shuffleIndices, [1, 2, 0]);
          expect(fixture.standby.nextIndex, 0);

          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _waitUntil(
            () => fixture.service.currentSnapshot.trackId == 'a',
            attempts: 700,
          );
          expect(fixture.standby.nextIndex, 0);
          expect(fixture.primary.seekCalls, 0);
          expect(fixture.standby.seekCalls, 0);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('repeat changes target both decks while promotion races', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.62);
        fixture.primary.blockNextLoopMode = true;

        final optionChange = fixture.service.setRepeatMode(
          PlaybackRepeatMode.one,
        );
        await _waitUntil(
          () => fixture.primary.loopModeWriteStarted.isCompleted,
        );

        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
          attempts: 700,
        );
        expect(fixture.standby.appliedLoopMode, LoopMode.one);

        fixture.primary.releaseLoopModeWrite.complete();
        await optionChange;
        expect(fixture.primary.appliedLoopMode, LoopMode.one);
        expect(fixture.standby.appliedLoopMode, LoopMode.one);
      } finally {
        await fixture.dispose();
      }
    });

    test('disabling before the fade releases the prepared standby', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.6);
        expect(fixture.standby.disposeCalls, 0);

        await fixture.service.configureCrossfade(
          enabled: false,
          duration: const Duration(milliseconds: 400),
        );

        expect(fixture.service.crossfadeEnabled, isFalse);
        expect(fixture.standby.stopCalls, greaterThanOrEqualTo(1));
        expect(fixture.standby.disposeCalls, 1);
        expect(fixture.primary.volumeCalls.last, closeTo(0.6, 1e-9));
        fixture.primary.emitPosition(const Duration(milliseconds: 700));
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
      } finally {
        await fixture.dispose();
      }
    });

    test('disabling during a fade completes exactly one handoff', () async {
      final fixture = await _CrossfadeFixture.create();
      final observedTrackIds = <String?>[];
      final subscription = fixture.service.snapshotStream.listen(
        (snapshot) => observedTrackIds.add(snapshot.trackId),
      );
      try {
        await fixture.playAndPrepare(masterVolume: 0.7);
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.standby.volumeCalls.any((volume) => volume > 0),
          attempts: 500,
        );

        await fixture.service.configureCrossfade(
          enabled: false,
          duration: const Duration(milliseconds: 400),
        );
        expect(fixture.service.crossfadeEnabled, isTrue);

        await _waitUntil(
          () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
          attempts: 700,
        );
        expect(fixture.service.crossfadeEnabled, isFalse);
        expect(
          observedTrackIds.where((trackId) => trackId == 'next'),
          hasLength(1),
        );
        expect(fixture.primary.volumeCalls.last, closeTo(0, 1e-9));
        expect(fixture.standby.volumeCalls.last, closeTo(0.7, 1e-9));
      } finally {
        await subscription.cancel();
        await fixture.dispose();
      }
    });

    test('a failed fade still honors a disable made during overlap', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.64);
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.standby.volumeCalls.any((volume) => volume > 0),
          attempts: 500,
        );

        await fixture.service.configureCrossfade(
          enabled: false,
          duration: const Duration(milliseconds: 400),
        );
        expect(fixture.service.crossfadeEnabled, isTrue);
        fixture.standby.emitError(
          PlayerException(31, 'standby failed during overlap', 0),
        );

        await _waitUntil(() => fixture.standby.disposeCalls == 1);
        expect(fixture.service.crossfadeEnabled, isFalse);
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
        expect(fixture.primary.volumeCalls.last, closeTo(0.64, 1e-9));
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
      } finally {
        await fixture.dispose();
      }
    });

    test('a seek during a deferred disable keeps crossfade off', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.66);
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.standby.volumeCalls.any((volume) => volume > 0),
          attempts: 500,
        );

        await fixture.service.configureCrossfade(
          enabled: false,
          duration: const Duration(milliseconds: 400),
        );
        expect(fixture.service.crossfadeEnabled, isTrue);
        await fixture.service.seek(Duration.zero);

        expect(fixture.service.crossfadeEnabled, isFalse);
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
        expect(fixture.service.currentSnapshot.position, Duration.zero);
        expect(fixture.primary.currentIndex, 0);
        expect(fixture.primary.position, Duration.zero);
        expect(fixture.primary.volumeCalls.last, closeTo(0.66, 1e-9));
        expect(fixture.standby.disposeCalls, 1);
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
      } finally {
        await fixture.dispose();
      }
    });

    test('pause and resume before the fade do not freeze its ramp', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.58);
        await fixture.service.pause();
        await fixture.service.resume();

        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(() => fixture.standby.playCalls == 1);
        await _waitUntil(
          () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
          attempts: 700,
        );
        expect(fixture.service.currentSnapshot.status, PlayerStatus.playing);
      } finally {
        await fixture.dispose();
      }
    });

    test('the outgoing timeline keeps updating during the overlap', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.5);
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.standby.volumeCalls.any((volume) => volume > 0),
          attempts: 500,
        );

        fixture.primary.emitPosition(const Duration(milliseconds: 525));
        await _drainEvents();
        expect(
          fixture.service.currentSnapshot.position,
          const Duration(milliseconds: 525),
        );
      } finally {
        await fixture.dispose();
      }
    });

    test('stop invalidates blocked preparation and its late load', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playCurrent(masterVolume: 0.65);
        fixture.standby.blockNextSourceLoad = true;
        final preparation = fixture.service.prepareCrossfade(
          RemoteCrossfadePlaybackSource(_remoteSource('next')),
        );
        await _waitUntil(() => fixture.standby.sourceLoadCalls.length == 1);

        await fixture.service.stop();
        expect(fixture.service.currentSnapshot.status, PlayerStatus.stopped);
        expect(fixture.standby.disposeCalls, 1);

        fixture.standby.completeSourceLoad(0);
        await preparation;
        await _drainEvents();
        expect(fixture.service.currentSnapshot.status, PlayerStatus.stopped);
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
        expect(fixture.standby.playCalls, 0);
      } finally {
        await fixture.dispose();
      }
    });

    test('seek invalidates standby and prevents a late handoff', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.55);

        await fixture.service.seek(const Duration(milliseconds: 250));
        expect(fixture.standby.disposeCalls, 1);
        expect(fixture.primary.position, const Duration(milliseconds: 250));

        fixture.primary.emitPosition(const Duration(milliseconds: 700));
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
        expect(fixture.standby.playCalls, 0);
        expect(fixture.primary.volumeCalls.last, closeTo(0.55, 1e-9));
      } finally {
        await fixture.dispose();
      }
    });

    test('rapid seeks commit only the latest target', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.56);

        await Future.wait([
          fixture.service.seek(const Duration(milliseconds: 600)),
          fixture.service.seek(const Duration(milliseconds: 200)),
          fixture.service.seek(Duration.zero),
        ]);

        expect(fixture.primary.seekCalls, 1);
        expect(fixture.primary.position, Duration.zero);
        expect(fixture.service.currentSnapshot.position, Duration.zero);
        expect(fixture.standby.disposeCalls, 1);
        expect(fixture.standby.playCalls, 0);
      } finally {
        await fixture.dispose();
      }
    });

    test('seek to zero during overlap restores the current track', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.55);
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.standby.volumeCalls.any((volume) => volume > 0),
          attempts: 500,
        );

        await fixture.service.seek(Duration.zero);

        expect(fixture.standby.disposeCalls, 1);
        expect(fixture.primary.position, Duration.zero);
        expect(fixture.service.currentSnapshot.position, Duration.zero);
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
        expect(fixture.primary.volumeCalls.last, closeTo(0.55, 1e-9));
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'dispose invalidates blocked standby without a late handoff',
      () async {
        final fixture = await _CrossfadeFixture.create();
        await fixture.playCurrent(masterVolume: 0.5);
        fixture.standby.blockNextSourceLoad = true;
        final preparation = fixture.service.prepareCrossfade(
          RemoteCrossfadePlaybackSource(_remoteSource('next')),
        );
        await _waitUntil(() => fixture.standby.sourceLoadCalls.length == 1);

        final lastTrackId = fixture.service.currentSnapshot.trackId;
        await fixture.service.dispose();
        expect(fixture.primary.disposeCalls, 1);
        expect(fixture.standby.disposeCalls, 1);

        fixture.standby.completeSourceLoad(0);
        await preparation;
        await _drainEvents();
        expect(fixture.service.currentSnapshot.trackId, lastTrackId);
        expect(fixture.standby.playCalls, 0);

        await fixture.dispose(serviceAlreadyDisposed: true);
      },
    );

    test(
      'dispose waits for an overlapping ramp before releasing decks',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.6);
          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _waitUntil(
            () => fixture.standby.volumeCalls.any((volume) => volume > 0),
            attempts: 500,
          );

          await fixture.service.dispose().timeout(const Duration(seconds: 1));

          expect(fixture.primary.disposeCalls, 1);
          expect(fixture.standby.disposeCalls, 1);
        } finally {
          await fixture.dispose(serviceAlreadyDisposed: true);
        }
      },
    );
  });
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
  final index = backend.currentIndex ?? 0;
  return (backend.sequence[index].tag as MediaItem).extras?['queueEntryId']
      ?.toString();
}

String? _trackId(_BlockingAudioPlayer backend) {
  if (backend.sequence.isEmpty) return null;
  final index = backend.currentIndex ?? 0;
  return (backend.sequence[index].tag as MediaItem).id;
}

Future<void> _drainEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<void> _waitUntil(bool Function() predicate, {int attempts = 100}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
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

class _CrossfadeFixture {
  _CrossfadeFixture(
    this.directory,
    this.artwork,
    this.primary,
    this.standby,
    this.factoryPlayers,
    this.service,
  );

  final Directory directory;
  final NotificationArtworkService artwork;
  final _BlockingAudioPlayer primary;
  final _BlockingAudioPlayer standby;
  final List<_BlockingAudioPlayer> factoryPlayers;
  final JustAudioPlayerService service;

  static Future<_CrossfadeFixture> create({
    Duration skipSilenceWriteTimeout = const Duration(seconds: 2),
    JustAudioRemoteDiagnosticProbe? remoteDiagnosticProbe,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'bstream_just_audio_crossfade_',
    );
    final artwork = NotificationArtworkService(
      cacheDirectoryProvider: () async => directory,
    );
    final primary = _BlockingAudioPlayer();
    final standby = _BlockingAudioPlayer();
    final factoryPlayers = <_BlockingAudioPlayer>[];
    final service = JustAudioPlayerService(
      audioPlayer: primary,
      crossfadeAudioPlayer: standby,
      supportsSkipSilence: true,
      skipSilenceWriteTimeout: skipSilenceWriteTimeout,
      remoteDiagnosticProbe: remoteDiagnosticProbe,
      crossfadePlayerFactory: () {
        final player = _BlockingAudioPlayer();
        factoryPlayers.add(player);
        return player;
      },
      notificationArtworkService: artwork,
      operationTimeout: const Duration(seconds: 2),
    );
    return _CrossfadeFixture(
      directory,
      artwork,
      primary,
      standby,
      factoryPlayers,
      service,
    );
  }

  Future<void> playCurrent({
    required double masterVolume,
    Duration crossfadeDuration = const Duration(milliseconds: 400),
    Duration trackDuration = const Duration(milliseconds: 800),
  }) async {
    await service.playRemoteSource(_remoteSource('current'));
    await service.updateRemoteQueue([_remoteSource('next')]);
    await service.setVolume(masterVolume);
    await service.configureCrossfade(
      enabled: true,
      duration: crossfadeDuration,
    );
    primary.emitDuration(trackDuration);
    await _drainEvents();
  }

  Future<void> playAndPrepare({
    required double masterVolume,
    Duration crossfadeDuration = const Duration(milliseconds: 400),
    Duration trackDuration = const Duration(milliseconds: 800),
  }) async {
    await playCurrent(
      masterVolume: masterVolume,
      crossfadeDuration: crossfadeDuration,
      trackDuration: trackDuration,
    );
    await service.prepareCrossfade(
      RemoteCrossfadePlaybackSource(_remoteSource('next')),
    );
  }

  Future<void> dispose({bool serviceAlreadyDisposed = false}) async {
    if (!primary.releaseMove.isCompleted) primary.releaseMove.complete();
    if (!standby.releaseMove.isCompleted) standby.releaseMove.complete();
    for (final backend in [primary, standby, ...factoryPlayers]) {
      if (!backend.releasePlay.isCompleted) backend.releasePlay.complete();
      for (final call in backend.sourceLoadCalls) {
        if (!call.completer.isCompleted) call.completer.complete();
      }
    }
    if (!serviceAlreadyDisposed) await service.dispose();
    for (final player in factoryPlayers) {
      if (player.disposeCalls == 0) {
        await player.dispose();
      }
    }
    await artwork.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

LocalTrack _localTrack(String id, {String? filePath}) {
  return LocalTrack(
    id: id,
    title: 'Track $id',
    artist: 'Local artist',
    filePath: filePath ?? 'C:\\music\\$id.mp3',
    addedAt: DateTime(2026),
  );
}

class _BlockingAudioPlayer extends AudioPlayer {
  final _errors = StreamController<PlayerException>.broadcast(sync: true);
  final _states = StreamController<PlayerState>.broadcast(sync: true);
  final _durations = StreamController<Duration?>.broadcast(sync: true);
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _volumes = StreamController<double>.broadcast(sync: true);
  final _sequenceStates = StreamController<SequenceState>.broadcast(sync: true);
  final List<AudioSource> _sources = [];
  final List<_SourceLoadCall> sourceLoadCalls = [];
  final List<double> volumeCalls = [];
  final List<bool> skipSilenceCalls = [];
  bool appliedSkipSilenceEnabled = false;

  final Completer<void> moveStarted = Completer<void>();
  final Completer<void> releaseMove = Completer<void>();
  bool blockMoves = false;
  bool blockNextSourceLoad = false;
  bool blockNextLoopMode = false;
  bool blockNextSkipSilence = false;
  bool blockNextPlay = false;
  bool failBlockedPlay = false;
  Object? blockedPlayFailure;
  int skipSilenceFailuresRemaining = 0;
  bool blockNextIndexedSeekAfterMutation = false;
  bool holdNextIndexedSeekInBuffering = false;
  bool failNextSeekAfterMutation = false;
  bool failNextVolumeWrite = false;
  PlayerException? failNextSourceLoad;
  Duration? nextSourceLoadDuration;
  bool _playing = false;
  ProcessingState _processingState = ProcessingState.idle;
  int? _currentIndex;
  bool _shuffleModeEnabled = false;
  List<int> _shuffleIndices = const [];
  LoopMode _loopMode = LoopMode.off;
  Duration _position = Duration.zero;
  int _activeQueueMutations = 0;
  int maximumConcurrentQueueMutations = 0;
  int setAudioSourcesCalls = 0;
  int seekCalls = 0;
  int playCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  int _sourceRevision = 0;
  final Completer<void> indexedSeekMutationStarted = Completer<void>();
  final Completer<void> releaseIndexedSeekMutation = Completer<void>();
  final Completer<void> loopModeWriteStarted = Completer<void>();
  final Completer<void> releaseLoopModeWrite = Completer<void>();
  final Completer<void> skipSilenceWriteStarted = Completer<void>();
  final Completer<void> releaseSkipSilenceWrite = Completer<void>();
  Completer<void>? _queuedSkipSilenceWriteStarted;
  Completer<void>? _queuedSkipSilenceWriteRelease;
  final Completer<void> playStarted = Completer<void>();
  final Completer<void> releasePlay = Completer<void>();
  void Function(Duration position)? onUnindexedSeek;
  void Function(double volume)? onSetVolume;

  @override
  Stream<Duration> createPositionStream({
    int steps = 800,
    Duration minPeriod = const Duration(milliseconds: 200),
    Duration maxPeriod = const Duration(milliseconds: 200),
  }) => _positions.stream;

  @override
  Stream<Duration?> get durationStream => _durations.stream;

  @override
  Stream<double> get volumeStream => _volumes.stream;

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {
    skipSilenceCalls.add(enabled);
    final previous = appliedSkipSilenceEnabled;
    // Match just_audio's public setter: its Dart-side value changes before the
    // Android method-channel Future completes and rolls back if that call
    // eventually fails.
    appliedSkipSilenceEnabled = enabled;
    try {
      final queuedRelease = _queuedSkipSilenceWriteRelease;
      final queuedStarted = _queuedSkipSilenceWriteStarted;
      if (queuedRelease != null) {
        _queuedSkipSilenceWriteRelease = null;
        _queuedSkipSilenceWriteStarted = null;
        if (queuedStarted != null && !queuedStarted.isCompleted) {
          queuedStarted.complete();
        }
        await queuedRelease.future;
      } else if (blockNextSkipSilence) {
        blockNextSkipSilence = false;
        if (!skipSilenceWriteStarted.isCompleted) {
          skipSilenceWriteStarted.complete();
        }
        await releaseSkipSilenceWrite.future;
      }
      if (skipSilenceFailuresRemaining > 0) {
        skipSilenceFailuresRemaining--;
        throw StateError('skip silence setter failed');
      }
    } catch (_) {
      appliedSkipSilenceEnabled = previous;
      rethrow;
    }
  }

  void queueSkipSilenceWriteBlock({
    required Completer<void> started,
    required Completer<void> release,
  }) {
    _queuedSkipSilenceWriteStarted = started;
    _queuedSkipSilenceWriteRelease = release;
  }

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<PlayerException> get errorStream => _errors.stream;

  @override
  Stream<SequenceState> get sequenceStateStream => _sequenceStates.stream;

  @override
  SequenceState get sequenceState => SequenceState(
    sequence: sequence,
    currentIndex: _currentIndex,
    shuffleIndices: shuffleIndices,
    shuffleModeEnabled: _shuffleModeEnabled,
    loopMode: _loopMode,
  );

  @override
  List<IndexedAudioSource> get sequence =>
      _sources.expand((source) => source.sequence).toList(growable: false);

  @override
  int? get currentIndex => _currentIndex;

  @override
  List<int> get shuffleIndices => _shuffleIndices.length == sequence.length
      ? List<int>.of(_shuffleIndices)
      : List<int>.generate(sequence.length, (index) => index);

  @override
  int? get nextIndex {
    final current = _currentIndex;
    if (current == null) return null;
    final order = _shuffleModeEnabled
        ? shuffleIndices
        : List<int>.generate(sequence.length, (index) => index);
    final position = order.indexOf(current);
    return position >= 0 && position + 1 < order.length
        ? order[position + 1]
        : null;
  }

  void setShuffleOrderForTest(List<int> indices) {
    _shuffleIndices = List<int>.of(indices);
  }

  LoopMode get appliedLoopMode => _loopMode;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => _processingState;

  @override
  PlayerState get playerState => PlayerState(_playing, _processingState);

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
      if (shuffleOrder != null) {
        shuffleOrder
          ..clear()
          ..insert(0, _sources.length)
          ..shuffle(initialIndex: call.initialIndex);
        _shuffleIndices = List<int>.of(shuffleOrder.indices);
      } else {
        _shuffleIndices = List<int>.generate(_sources.length, (index) => index);
      }
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

  void emitPosition(Duration position) {
    _position = position;
    _positions.add(position);
  }

  void emitReady() {
    _processingState = ProcessingState.ready;
    _states.add(PlayerState(_playing, _processingState));
  }

  void emitBuffering() {
    _processingState = ProcessingState.buffering;
    _states.add(PlayerState(_playing, _processingState));
  }

  void emitCompleted() {
    _processingState = ProcessingState.completed;
    _states.add(PlayerState(_playing, _processingState));
  }

  void emitSequenceState({int? currentIndex}) {
    if (currentIndex != null) {
      _currentIndex = currentIndex;
    }
    _sequenceStates.add(sequenceState);
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
      final active = _currentIndex;
      if (active == currentIndex) {
        _currentIndex = newIndex;
      } else if (active != null &&
          currentIndex < active &&
          newIndex >= active) {
        _currentIndex = active - 1;
      } else if (active != null &&
          currentIndex > active &&
          newIndex <= active) {
        _currentIndex = active + 1;
      }
    });
  }

  @override
  Future<void> insertAudioSource(int index, AudioSource audioSource) {
    return _queueMutation(() async {
      _sources.insert(index, audioSource);
      final active = _currentIndex;
      if (active != null && index <= active) {
        _currentIndex = active + 1;
      }
    });
  }

  @override
  Future<void> removeAudioSourceAt(int index) {
    return _queueMutation(() async {
      _sources.removeAt(index);
      final active = _currentIndex;
      if (active != null && index < active) {
        _currentIndex = active - 1;
      }
    });
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
      if (holdNextIndexedSeekInBuffering) {
        holdNextIndexedSeekInBuffering = false;
        _processingState = ProcessingState.buffering;
        _states.add(PlayerState(_playing, _processingState));
      } else {
        emitReady();
      }
    }
    if (index == null) {
      onUnindexedSeek?.call(_position);
    }
    if (index != null && blockNextIndexedSeekAfterMutation) {
      blockNextIndexedSeekAfterMutation = false;
      if (!indexedSeekMutationStarted.isCompleted) {
        indexedSeekMutationStarted.complete();
      }
      await releaseIndexedSeekMutation.future;
    }
    if (failNextSeekAfterMutation) {
      failNextSeekAfterMutation = false;
      emitSequenceState();
      throw StateError('seek failed after native index mutation');
    }
  }

  @override
  Future<void> play() async {
    playCalls++;
    _playing = true;
    emitReady();
    if (blockNextPlay) {
      blockNextPlay = false;
      if (!playStarted.isCompleted) playStarted.complete();
      await releasePlay.future;
      final failure = blockedPlayFailure;
      blockedPlayFailure = null;
      if (failure != null) {
        throw failure;
      }
      if (failBlockedPlay) {
        throw StateError('delayed play failed');
      }
    }
  }

  @override
  Future<void> pause() async {
    _playing = false;
    emitReady();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _sourceRevision++;
    _playing = false;
    _processingState = ProcessingState.idle;
    _states.add(PlayerState(false, _processingState));
  }

  @override
  Future<void> setVolume(double volume) async {
    volumeCalls.add(volume);
    onSetVolume?.call(volume);
    if (failNextVolumeWrite) {
      failNextVolumeWrite = false;
      throw StateError('volume write failed');
    }
    _volumes.add(volume);
  }

  @override
  Future<void> setLoopMode(LoopMode mode) async {
    if (blockNextLoopMode) {
      blockNextLoopMode = false;
      if (!loopModeWriteStarted.isCompleted) {
        loopModeWriteStarted.complete();
      }
      await releaseLoopModeWrite.future;
    }
    _loopMode = mode;
  }

  @override
  Future<void> setShuffleModeEnabled(bool enabled) async {
    _shuffleModeEnabled = enabled;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (!releaseIndexedSeekMutation.isCompleted) {
      releaseIndexedSeekMutation.complete();
    }
    if (!releaseLoopModeWrite.isCompleted) {
      releaseLoopModeWrite.complete();
    }
    if (!releaseSkipSilenceWrite.isCompleted) {
      releaseSkipSilenceWrite.complete();
    }
    // AudioPlayer derives internal subjects from these streams. End them
    // before the base class closes those subjects.
    await _durations.close();
    await _positions.close();
    await _volumes.close();
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
