import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QueueNavigationState', () {
    test('keeps current item stable while reordering around it', () {
      final state = QueueNavigationState<String>()
        ..replaceItems(const ['a', 'b', 'c'])
        ..currentIndex = 1;

      expect(state.reorder(0, 2), isTrue);

      expect(state.items, const ['b', 'c', 'a']);
      expect(state.currentIndex, 0);
      expect(state.items[state.currentIndex], 'b');
    });

    test('shuffle visits each item once before automatic stop', () {
      final state =
          QueueNavigationState<String>(
              random: math.Random(7),
              lookAheadDepth: 3,
            )
            ..replaceItems(const ['a', 'b', 'c', 'd'])
            ..currentIndex = 0
            ..shuffleEnabled = true
            ..repeatMode = PlaybackRepeatMode.off
            ..resetShuffleHistory();
      final visited = <int>{0};

      while (true) {
        final next = state.nextIndex(automatic: true);
        if (next < 0) {
          break;
        }
        expect(visited.add(next), isTrue);
        state
          ..currentIndex = next
          ..markCurrentIndexPlayed();
      }

      expect(visited, {0, 1, 2, 3});
    });
  });

  group('RemotePrefetchPlanner', () {
    test(
      'builds a bounded sequential window and retains the previous track',
      () {
        final tracks = List<TrackInfo>.generate(5, _track);

        final plan = RemotePrefetchPlanner.build(
          queue: tracks,
          currentIndex: 1,
          queueGeneration: 4,
          shuffleEnabled: false,
          shufflePlan: const [],
          repeatMode: PlaybackRepeatMode.off,
          actualPreviousTrack: tracks.first,
          depth: 2,
        );

        expect(plan, isNotNull);
        expect(plan!.currentQueueEntryId, 'remote:4:1');
        expect(plan.upcoming.map((entry) => entry.index), [2, 3]);
        expect(plan.cacheWindow, [tracks[1], tracks[2], tracks[3], tracks[0]]);
      },
    );

    test('does not create a native window across a downloaded queue item', () {
      final first = _track(0);
      final third = _track(2);

      final plan = RemotePrefetchPlanner.build(
        queue: [first, null, third],
        currentIndex: 0,
        queueGeneration: 1,
        shuffleEnabled: false,
        shufflePlan: const [],
        repeatMode: PlaybackRepeatMode.all,
        actualPreviousTrack: null,
      );

      expect(plan, isNotNull);
      expect(plan!.upcoming, isEmpty);
      expect(plan.cacheWindow, [first, third]);
    });

    test('keeps the safe remote prefix before a downloaded queue item', () {
      final first = _track(0);
      final second = _track(1);
      final fourth = _track(3);

      final plan = RemotePrefetchPlanner.build(
        queue: [first, second, null, fourth],
        currentIndex: 0,
        queueGeneration: 1,
        shuffleEnabled: false,
        shufflePlan: const [],
        repeatMode: PlaybackRepeatMode.off,
        actualPreviousTrack: null,
      );

      expect(plan, isNotNull);
      expect(plan!.upcoming.map((entry) => entry.track), [second]);
      expect(plan.cacheWindow, [first, second, fourth]);
    });
  });

  group('PlaybackIdentity', () {
    test('uses a canonical video id from common YouTube URLs', () {
      expect(
        PlaybackIdentity.canonicalYoutubeVideoId(
          url: 'https://youtu.be/abcdefghijk?t=2',
        ),
        'abcdefghijk',
      );
      expect(
        PlaybackIdentity.canonicalYoutubeVideoId(
          url: 'https://music.youtube.com/watch?v=12345678901',
        ),
        '12345678901',
      );
    });

    test('prefers queue identity when matching a pending snapshot', () {
      const pending = PlayerSnapshot(
        status: PlayerStatus.loading,
        queueEntryId: 'remote:1:2',
        trackId: 'track',
      );
      const matching = PlayerSnapshot(
        status: PlayerStatus.playing,
        queueEntryId: 'remote:1:2',
        trackId: 'different-backend-id',
      );
      const stale = PlayerSnapshot(
        status: PlayerStatus.playing,
        queueEntryId: 'remote:1:1',
        trackId: 'track',
      );

      expect(
        PlaybackIdentity.snapshotMatchesPending(matching, pending),
        isTrue,
      );
      expect(PlaybackIdentity.snapshotMatchesPending(stale, pending), isFalse);
    });
  });

  group('RemotePlaybackRetryCoordinator', () {
    test(
      'coalesces duplicate retries for the same logical selection',
      () async {
        final gate = Completer<void>();
        final coordinator = RemotePlaybackRetryCoordinator(
          backoffs: const [Duration.zero],
        );
        var cycles = 0;

        Future<void> start() => coordinator.run(
          key: 'selection',
          initialError: StateError('offline'),
          initialStackTrace: StackTrace.current,
          isCurrent: () => true,
          isCancellation: (_) => false,
          shouldRetry: (_) => true,
          delay: (_) => gate.future,
          onAttempt: (_, _) {},
          runCycle: () async {
            cycles++;
          },
          onCancelled: () {},
          onTerminal: (_, _) {},
          onStale: () {},
        );

        final first = start();
        final duplicate = start();
        expect(identical(first, duplicate), isTrue);

        gate.complete();
        await first;
        expect(cycles, 1);
      },
    );

    test('publishes non-refreshable failures without delaying', () async {
      final coordinator = RemotePlaybackRetryCoordinator();
      Object? terminalError;
      var delayCalls = 0;

      await coordinator.run(
        key: 'terminal',
        initialError: ArgumentError('invalid'),
        initialStackTrace: StackTrace.current,
        isCurrent: () => true,
        isCancellation: (_) => false,
        shouldRetry: (_) => false,
        delay: (_) async {
          delayCalls++;
        },
        onAttempt: (_, _) {},
        runCycle: () async {},
        onCancelled: () {},
        onTerminal: (error, _) {
          terminalError = error;
        },
        onStale: () {},
      );

      expect(terminalError, isA<ArgumentError>());
      expect(delayCalls, 0);
    });

    test('does not invoke a failing terminal callback twice', () async {
      final coordinator = RemotePlaybackRetryCoordinator();
      var terminalCalls = 0;

      await expectLater(
        coordinator.run(
          key: 'terminal-callback',
          initialError: ArgumentError('invalid'),
          initialStackTrace: StackTrace.current,
          isCurrent: () => true,
          isCancellation: (_) => false,
          shouldRetry: (_) => false,
          delay: (_) async {},
          onAttempt: (_, _) {},
          runCycle: () async {},
          onCancelled: () {},
          onTerminal: (_, _) {
            terminalCalls++;
            throw StateError('terminal publication failed');
          },
          onStale: () {},
        ),
        throwsStateError,
      );

      expect(terminalCalls, 1);
    });
  });

  group('RemotePlaybackFailureClassifier', () {
    test('rejects programming and malformed-data failures', () {
      final typeError = _captureTypeError();

      expect(typeError, isA<TypeError>());
      expect(RemotePlaybackFailureClassifier.shouldRefresh(typeError), isFalse);
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          StateError('HTTP 503 must not turn a programming error transient'),
        ),
        isFalse,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          ArgumentError('connection reset'),
        ),
        isFalse,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          const FormatException('HTTP 503'),
        ),
        isFalse,
      );
    });

    test('accepts typed transient transport failures and wrapped causes', () {
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          const SocketException('offline'),
        ),
        isTrue,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          TimeoutException('manifest timed out'),
        ),
        isTrue,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          const HttpException('service unavailable'),
        ),
        isTrue,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          const AudioStreamResolverException(
            'all resolvers failed',
            cause: SocketException('connection reset'),
          ),
        ),
        isTrue,
      );
    });

    test('requires an explicit transient application error taxonomy', () {
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          const PlayerException(
            'native source failed',
            code: 'playback_source_error',
          ),
        ),
        isTrue,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          PlayerException(
            'HTTP 503',
            code: 'playback_source_error',
            details: StateError('programming failure'),
          ),
        ),
        isFalse,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          const AppException('HTTP 503', code: 'unknown_error'),
        ),
        isFalse,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          const DownloaderException(
            'connection reset by peer',
            code: 'playback_source_error',
          ),
        ),
        isTrue,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefresh(
          const DownloaderException(
            'Private video',
            code: 'playback_source_error',
          ),
        ),
        isFalse,
      );
    });

    test('uses a positive taxonomy for untyped backend messages', () {
      expect(
        RemotePlaybackFailureClassifier.shouldRefreshMessage('HTTP 503'),
        isTrue,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefreshMessage(
          'HTTP 403 from an expired signed stream URL',
        ),
        isTrue,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRefreshMessage('random error'),
        isFalse,
      );
      expect(RemotePlaybackFailureClassifier.shouldRefreshMessage(''), isFalse);
      expect(
        RemotePlaybackFailureClassifier.shouldRefreshMessage(
          'Source error: format is not supported',
        ),
        isFalse,
      );
    });

    test('treats a superseded InnerTube resolution as cancellation', () {
      expect(
        RemotePlaybackFailureClassifier.isCancellation(
          Exception('Playback resolution was superseded.'),
        ),
        isTrue,
      );
    });

    test('allows a known primary format rejection to use fallback once', () {
      final primary = _track(
        7,
      ).copyWith(streamSource: AudioStreamSource.innerTube.name);
      final fallback = primary.copyWith(
        streamSource: AudioStreamSource.innerTubeFallback.name,
      );

      expect(
        RemotePlaybackFailureClassifier.isPrimaryInnerTubeStream(primary),
        isTrue,
      );
      expect(
        RemotePlaybackFailureClassifier.isFallbackInnerTubeStream(fallback),
        isTrue,
      );

      expect(
        RemotePlaybackFailureClassifier.shouldRecover(
          primary,
          Exception('Source error: format is not supported'),
        ),
        isTrue,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRecover(
          primary,
          StateError('Source error: format is not supported'),
        ),
        isFalse,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRecover(
          fallback,
          Exception('Source error: format is not supported'),
        ),
        isFalse,
      );
      expect(
        RemotePlaybackFailureClassifier.shouldRecover(
          primary,
          PlayerException(
            'Source error',
            code: 'playback_source_error',
            details: StateError('programming failure'),
          ),
        ),
        isFalse,
      );
    });
  });

  group('RecommendationQueueExtensionCoordinator', () {
    test('rejects a late continuation after the source changes', () async {
      final firstResult = Completer<List<RecommendationPlaybackItem>>();
      final coordinator = RecommendationQueueExtensionCoordinator()
        ..configure(sourceId: 'first', extender: () => firstResult.future);
      var syncCalls = 0;
      final operation = coordinator.maybeExtend(
        sourceIsActive: true,
        atQueueEnd: true,
        remaining: 0,
        threshold: 3,
        currentLength: () => 1,
        isDisposed: () => false,
        synchronize: (_, _) async {
          syncCalls++;
          return true;
        },
        onError: (_) {},
      );

      coordinator.configure(
        sourceId: 'second',
        extender: () async => const <RecommendationPlaybackItem>[],
      );
      firstResult.complete([
        RecommendationPlaybackItem(track: _track(0)),
        RecommendationPlaybackItem(track: _track(1)),
      ]);

      expect(await operation, isFalse);
      expect(syncCalls, 0);
      expect(coordinator.sourceId, 'second');
    });
  });
}

TrackInfo _track(int index) {
  final id = index.toString().padLeft(11, '0');
  return TrackInfo(
    id: id,
    title: 'Track $index',
    artist: 'Artist',
    url: 'https://music.youtube.com/watch?v=$id',
  );
}

Object _captureTypeError() {
  try {
    final Object value = 'not an int';
    value as int;
  } catch (error) {
    return error;
  }
  throw StateError('The invalid cast unexpectedly succeeded.');
}
