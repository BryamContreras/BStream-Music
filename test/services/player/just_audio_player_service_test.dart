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
      'prepares a silent standby and hands off within master volume',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.72);

          expect(fixture.standby.setAudioSourcesCalls, 1);
          expect(_queueEntryId(fixture.standby), 'remote:next');
          expect(fixture.standby.volumeCalls.first, 0);
          expect(fixture.standby.playCalls, 0);

          final primaryFadeCallStart = fixture.primary.volumeCalls.length;
          final standbyFadeCallStart = fixture.standby.volumeCalls.length;
          fixture.primary.emitPosition(const Duration(milliseconds: 400));
          await _waitUntil(() => fixture.standby.playCalls == 1);
          await _waitUntil(
            () =>
                fixture.primary.volumeCalls.any((volume) => volume < 0.72) &&
                fixture.standby.volumeCalls.any((volume) => volume > 0),
            attempts: 500,
          );

          bool hasAudibleEarlyOverlap() {
            final outgoing = fixture.primary.volumeCalls
                .skip(primaryFadeCallStart)
                .toList(growable: false);
            final incoming = fixture.standby.volumeCalls
                .skip(standbyFadeCallStart)
                .toList(growable: false);
            final count = outgoing.length < incoming.length
                ? outgoing.length
                : incoming.length;
            for (var index = 0; index < count; index++) {
              if (outgoing[index] > 0.72 * 0.8 &&
                  incoming[index] > 0.72 * 0.2) {
                return true;
              }
            }
            return false;
          }

          await _waitUntil(hasAudibleEarlyOverlap, attempts: 500);

          for (final volume in fixture.primary.volumeCalls.skip(
            primaryFadeCallStart,
          )) {
            expect(volume, inInclusiveRange(0, 0.72));
          }
          for (final volume in fixture.standby.volumeCalls.skip(
            standbyFadeCallStart,
          )) {
            expect(volume, inInclusiveRange(0, 0.72));
          }

          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(fixture.service.currentSnapshot.volume, closeTo(0.72, 1e-9));
          expect(fixture.primary.currentIndex, 1);
          expect(fixture.primary.volumeCalls.last, closeTo(0.72, 1e-9));
          expect(
            fixture.primary.volumeCalls.any(
              (volume) => volume > 0 && volume < 0.72,
            ),
            isTrue,
            reason: 'The synchronized primary must settle in without a jump.',
          );
          expect(
            fixture.standby.volumeCalls.any(
              (volume) => volume > 0 && volume < 0.72,
            ),
            isTrue,
            reason: 'The prepared deck must settle out instead of being muted.',
          );
          final primarySettleStart = fixture.primary.volumeCalls.lastIndexWhere(
            (volume) => volume.abs() <= 0.001,
          );
          final standbySettleStart = fixture.standby.volumeCalls.lastIndexWhere(
            (volume) => (volume - 0.72).abs() <= 0.001,
          );
          final primarySettle = fixture.primary.volumeCalls.sublist(
            primarySettleStart,
          );
          final standbySettle = fixture.standby.volumeCalls.sublist(
            standbySettleStart,
          );
          final settleSampleCount = primarySettle.length < standbySettle.length
              ? primarySettle.length
              : standbySettle.length;
          expect(settleSampleCount, greaterThan(2));
          for (var index = 0; index < settleSampleCount; index++) {
            expect(
              primarySettle[index] + standbySettle[index],
              closeTo(0.72, 0.003),
              reason: 'Settle gains must remain complementary.',
            );
          }
          expect(fixture.standby.disposeCalls, 0);
          await _waitUntil(() => fixture.standby.disposeCalls == 1);
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
        expect(fixture.primary.volumeCalls.last, closeTo(0.35, 1e-9));
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'keeps B audible and realigns drift after the primary reports ready',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.68);
          fixture.primary.holdNextIndexedSeekInBuffering = true;
          fixture.primary.emitPosition(const Duration(milliseconds: 400));

          await _waitUntil(
            () => fixture.primary.processingState == ProcessingState.buffering,
            attempts: 700,
          );
          fixture.standby.emitPosition(const Duration(milliseconds: 850));
          await Future<void>.delayed(const Duration(milliseconds: 400));

          expect(
            fixture.service.currentSnapshot.queueEntryId,
            'remote:current',
          );
          expect(fixture.primary.volumeCalls.last, closeTo(0, 1e-9));
          expect(fixture.standby.volumeCalls.last, closeTo(0.68, 0.002));
          expect(fixture.standby.disposeCalls, 0);

          fixture.primary.emitReady();
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(fixture.primary.volumeCalls.last, closeTo(0.68, 1e-9));
          expect(fixture.primary.seekCalls, 2);
          expect(fixture.primary.position, const Duration(milliseconds: 850));
          expect(
            fixture.service.currentSnapshot.position,
            const Duration(milliseconds: 850),
          );
          expect(fixture.standby.disposeCalls, 0);
          await _waitUntil(
            () => fixture.standby.disposeCalls == 1,
            attempts: 700,
          );
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('keeps B authoritative beyond the old readiness timeout', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.67);
        fixture.primary.holdNextIndexedSeekInBuffering = true;
        fixture.primary.emitPosition(const Duration(milliseconds: 400));

        await _waitUntil(
          () => fixture.primary.processingState == ProcessingState.buffering,
          attempts: 700,
        );
        await Future<void>.delayed(const Duration(milliseconds: 1200));

        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
        expect(fixture.primary.volumeCalls.last, closeTo(0, 1e-9));
        expect(fixture.standby.volumeCalls.last, closeTo(0.67, 0.002));
        expect(fixture.standby.disposeCalls, 0);

        fixture.primary.emitReady();
        await _waitUntil(
          () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
          attempts: 700,
        );
        expect(fixture.primary.processingState, ProcessingState.ready);
        expect(fixture.primary.volumeCalls.last, closeTo(0.67, 1e-9));
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'remeasures fresh drift when B advances during the correction seek',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.69);
          var advancedDuringCorrection = false;
          double? primaryGainDuringCorrection;
          double? standbyGainDuringCorrection;
          fixture.primary
            ..holdNextIndexedSeekInBuffering = true
            ..onUnindexedSeek = (_) {
              if (advancedDuringCorrection) return;
              advancedDuringCorrection = true;
              primaryGainDuringCorrection = fixture.primary.volumeCalls.last;
              standbyGainDuringCorrection = fixture.standby.volumeCalls.last;
              fixture.standby.emitPosition(const Duration(milliseconds: 1200));
            };
          fixture.primary.emitPosition(const Duration(milliseconds: 400));

          await _waitUntil(
            () => fixture.primary.processingState == ProcessingState.buffering,
            attempts: 700,
          );
          fixture.standby.emitPosition(const Duration(milliseconds: 850));
          expect(fixture.primary.volumeCalls.last, closeTo(0, 1e-9));
          expect(fixture.standby.volumeCalls.last, closeTo(0.69, 0.002));
          fixture.primary.emitReady();

          await _waitUntil(
            () =>
                fixture.primary.seekCalls >= 3 &&
                fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(advancedDuringCorrection, isTrue);
          expect(primaryGainDuringCorrection, closeTo(0, 1e-9));
          expect(standbyGainDuringCorrection, closeTo(0.69, 0.002));
          expect(fixture.primary.seekCalls, 3);
          expect(fixture.primary.position, const Duration(milliseconds: 1200));
          expect(
            fixture.service.currentSnapshot.position,
            const Duration(milliseconds: 1200),
          );
          expect(fixture.primary.volumeCalls.last, closeTo(0.69, 1e-9));
        } finally {
          await fixture.dispose();
        }
      },
    );

    test(
      'uses a gapless terminal cutover when clock drift never converges',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.71);
          fixture.primary
            ..holdNextIndexedSeekInBuffering = true
            ..onUnindexedSeek = (position) {
              fixture.standby.emitPosition(
                position + const Duration(milliseconds: 100),
              );
            };
          fixture.primary.emitPosition(const Duration(milliseconds: 400));

          await _waitUntil(
            () => fixture.primary.processingState == ProcessingState.buffering,
            attempts: 700,
          );
          fixture.standby.emitPosition(const Duration(milliseconds: 850));
          fixture.primary.emitReady();

          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(fixture.primary.seekCalls, 4);
          expect(fixture.primary.volumeCalls.last, closeTo(0.71, 1e-9));
          expect(fixture.standby.volumeCalls.last, closeTo(0, 1e-9));
          expect(
            fixture.standby.stopCalls,
            0,
            reason: 'B must not stop before A owns the terminal gain.',
          );
          await _waitUntil(() => fixture.standby.stopCalls > 0, attempts: 700);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test(
      'restores B and retries if A loses readiness during terminal cutover',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          const master = 0.73;
          var readinessDropped = false;
          await fixture.playAndPrepare(masterVolume: master);
          fixture.primary
            ..holdNextIndexedSeekInBuffering = true
            ..onUnindexedSeek = (position) {
              fixture.standby.emitPosition(
                position + const Duration(milliseconds: 100),
              );
            }
            ..onSetVolume = (volume) {
              if (!readinessDropped &&
                  fixture.primary.seekCalls == 4 &&
                  (volume - master).abs() <= 0.001) {
                readinessDropped = true;
                fixture.primary.emitBuffering();
              }
            };
          fixture.primary.emitPosition(const Duration(milliseconds: 400));

          await _waitUntil(
            () => fixture.primary.processingState == ProcessingState.buffering,
            attempts: 700,
          );
          fixture.standby.emitPosition(const Duration(milliseconds: 850));
          fixture.primary.emitReady();
          await _waitUntil(
            () =>
                readinessDropped &&
                fixture.primary.volumeCalls.last.abs() <= 0.001 &&
                (fixture.standby.volumeCalls.last - master).abs() <= 0.002,
            attempts: 700,
          );

          expect(
            fixture.service.currentSnapshot.queueEntryId,
            'remote:current',
          );
          expect(fixture.standby.stopCalls, 0);

          fixture.primary
            ..onUnindexedSeek = null
            ..onSetVolume = null
            ..emitReady();
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 700,
          );
          expect(fixture.primary.processingState, ProcessingState.ready);
          expect(fixture.primary.volumeCalls.last, closeTo(master, 1e-9));
        } finally {
          await fixture.dispose();
        }
      },
    );

    test(
      'restores B and retries if A buffers during an intermediate settle gain',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          const master = 0.74;
          var readinessDropped = false;
          double? interruptedGain;
          await fixture.playAndPrepare(masterVolume: master);
          fixture.primary.onSetVolume = (volume) {
            if (!readinessDropped &&
                fixture.primary.currentIndex == 1 &&
                volume > 0.02 &&
                volume < master - 0.02) {
              readinessDropped = true;
              interruptedGain = volume;
              fixture.primary.emitBuffering();
            }
          };
          fixture.primary.emitPosition(const Duration(milliseconds: 400));

          await _waitUntil(
            () =>
                readinessDropped &&
                fixture.primary.volumeCalls.last.abs() <= 0.001 &&
                (fixture.standby.volumeCalls.last - master).abs() <= 0.002,
            attempts: 700,
          );
          expect(interruptedGain, isNotNull);
          expect(interruptedGain, inExclusiveRange(0, master));
          expect(fixture.standby.stopCalls, 0);
          expect(fixture.standby.disposeCalls, 0);

          fixture.primary
            ..onSetVolume = null
            ..emitReady();
          await _waitUntil(
            () =>
                fixture.service.currentSnapshot.queueEntryId == 'remote:next' &&
                (fixture.primary.volumeCalls.last - master).abs() <= 0.001 &&
                fixture.standby.volumeCalls.last.abs() <= 0.001,
            attempts: 700,
          );
          expect(fixture.primary.processingState, ProcessingState.ready);
          expect(fixture.standby.stopCalls, 0);
        } finally {
          await fixture.dispose();
        }
      },
    );

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
        expect(fixture.primary.volumeCalls.last, closeTo(0.7, 1e-9));
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

    test(
      'a post-seek promotion failure keeps metadata authoritative',
      () async {
        final fixture = await _CrossfadeFixture.create();
        try {
          await fixture.playAndPrepare(masterVolume: 0.61);
          fixture.primary.failNextSeekAfterMutation = true;
          fixture.primary.emitPosition(const Duration(milliseconds: 400));

          await _waitUntil(
            () => fixture.standby.disposeCalls == 1,
            attempts: 700,
          );
          await _waitUntil(
            () => fixture.service.currentSnapshot.queueEntryId == 'remote:next',
            attempts: 200,
          );
          expect(fixture.primary.currentIndex, 1);
          expect(fixture.service.currentSnapshot.queueEntryId, 'remote:next');
          expect(fixture.service.currentSnapshot.trackId, 'next');
          expect(fixture.service.currentSnapshot.position, Duration.zero);
          expect(fixture.service.currentSnapshot.volume, closeTo(0.61, 1e-9));
          expect(fixture.primary.volumeCalls.last, closeTo(0.61, 1e-9));
        } finally {
          await fixture.dispose();
        }
      },
    );

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

    test('seek to zero wins over an indexed promotion in flight', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.59);
        fixture.primary.blockNextIndexedSeekAfterMutation = true;
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.primary.indexedSeekMutationStarted.isCompleted,
          attempts: 700,
        );
        expect(fixture.primary.currentIndex, 1);
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');

        final seek = fixture.service.seek(Duration.zero);
        await _drainEvents();
        fixture.primary.releaseIndexedSeekMutation.complete();
        await seek;

        expect(fixture.primary.currentIndex, 0);
        expect(fixture.primary.position, Duration.zero);
        expect(fixture.service.currentSnapshot.position, Duration.zero);
        expect(fixture.service.currentSnapshot.queueEntryId, 'remote:current');
        expect(fixture.primary.volumeCalls.last, closeTo(0.59, 1e-9));
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

    test('dispose waits for a promotion mutation already in flight', () async {
      final fixture = await _CrossfadeFixture.create();
      try {
        await fixture.playAndPrepare(masterVolume: 0.59);
        fixture.primary.blockNextIndexedSeekAfterMutation = true;
        fixture.primary.emitPosition(const Duration(milliseconds: 400));
        await _waitUntil(
          () => fixture.primary.indexedSeekMutationStarted.isCompleted,
          attempts: 700,
        );

        var disposeCompleted = false;
        final dispose = fixture.service.dispose().whenComplete(
          () => disposeCompleted = true,
        );
        await _drainEvents();
        expect(disposeCompleted, isFalse);
        expect(fixture.primary.disposeCalls, 0);
        expect(fixture.standby.disposeCalls, 0);

        fixture.primary.releaseIndexedSeekMutation.complete();
        await dispose.timeout(const Duration(seconds: 1));
        expect(fixture.primary.disposeCalls, 1);
        expect(fixture.standby.disposeCalls, 1);
      } finally {
        await fixture.dispose(serviceAlreadyDisposed: true);
      }
    });
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
  return (backend.sequence.single.tag as MediaItem).extras?['queueEntryId']
      ?.toString();
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
    this.service,
  );

  final Directory directory;
  final NotificationArtworkService artwork;
  final _BlockingAudioPlayer primary;
  final _BlockingAudioPlayer standby;
  final JustAudioPlayerService service;

  static Future<_CrossfadeFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'bstream_just_audio_crossfade_',
    );
    final artwork = NotificationArtworkService(
      cacheDirectoryProvider: () async => directory,
    );
    final primary = _BlockingAudioPlayer();
    final standby = _BlockingAudioPlayer();
    final service = JustAudioPlayerService(
      audioPlayer: primary,
      crossfadeAudioPlayer: standby,
      notificationArtworkService: artwork,
      operationTimeout: const Duration(seconds: 2),
    );
    return _CrossfadeFixture(directory, artwork, primary, standby, service);
  }

  Future<void> playCurrent({required double masterVolume}) async {
    await service.playRemoteSource(_remoteSource('current'));
    await service.updateRemoteQueue([_remoteSource('next')]);
    await service.setVolume(masterVolume);
    await service.configureCrossfade(
      enabled: true,
      duration: const Duration(milliseconds: 400),
    );
    primary.emitDuration(const Duration(milliseconds: 800));
    await _drainEvents();
  }

  Future<void> playAndPrepare({required double masterVolume}) async {
    await playCurrent(masterVolume: masterVolume);
    await service.prepareCrossfade(
      RemoteCrossfadePlaybackSource(_remoteSource('next')),
    );
  }

  Future<void> dispose({bool serviceAlreadyDisposed = false}) async {
    if (!primary.releaseMove.isCompleted) primary.releaseMove.complete();
    if (!standby.releaseMove.isCompleted) standby.releaseMove.complete();
    for (final backend in [primary, standby]) {
      for (final call in backend.sourceLoadCalls) {
        if (!call.completer.isCompleted) call.completer.complete();
      }
    }
    if (!serviceAlreadyDisposed) await service.dispose();
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

  final Completer<void> moveStarted = Completer<void>();
  final Completer<void> releaseMove = Completer<void>();
  bool blockMoves = false;
  bool blockNextSourceLoad = false;
  bool blockNextIndexedSeekAfterMutation = false;
  bool holdNextIndexedSeekInBuffering = false;
  bool failNextSeekAfterMutation = false;
  PlayerException? failNextSourceLoad;
  Duration? nextSourceLoadDuration;
  bool _playing = false;
  ProcessingState _processingState = ProcessingState.idle;
  int? _currentIndex;
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
  Stream<PlayerState> get playerStateStream => _states.stream;

  @override
  Stream<PlayerException> get errorStream => _errors.stream;

  @override
  Stream<SequenceState> get sequenceStateStream => _sequenceStates.stream;

  @override
  SequenceState get sequenceState => SequenceState(
    sequence: sequence,
    currentIndex: _currentIndex,
    shuffleIndices: List<int>.generate(sequence.length, (index) => index),
    shuffleModeEnabled: false,
    loopMode: LoopMode.off,
  );

  @override
  List<IndexedAudioSource> get sequence =>
      _sources.expand((source) => source.sequence).toList(growable: false);

  @override
  int? get currentIndex => _currentIndex;

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
    _volumes.add(volume);
  }

  @override
  Future<void> setLoopMode(LoopMode mode) async {}

  @override
  Future<void> setShuffleModeEnabled(bool enabled) async {}

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (!releaseIndexedSeekMutation.isCompleted) {
      releaseIndexedSeekMutation.complete();
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
