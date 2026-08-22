import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/domain/usecases/search_tracks.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/downloader/fallback_audio_resolver.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const remoteTrack = TrackInfo(
    id: 'remote-live-track',
    title: 'Cancion LIVE',
    artist: 'Artista LIVE',
    url: 'https://www.youtube.com/watch?v=remote-live-track',
    duration: Duration(minutes: 3),
  );

  test(
    'defaults to remote-only LIVE requests and persists library mode',
    () async {
      SharedPreferences.setMockInitialValues({});
      final firstService = _FakeTikTokLiveCommandService();
      final firstContainer = ProviderContainer(
        overrides: [
          tiktokLiveCommandServiceProvider.overrideWithValue(firstService),
        ],
      );

      try {
        final initial = await firstContainer.read(
          tiktokLiveControllerProvider.future,
        );
        expect(initial.saveRequestsToLibrary, isFalse);

        await firstContainer
            .read(tiktokLiveControllerProvider.notifier)
            .setSaveRequestsToLibrary(true);

        expect(
          firstContainer
              .read(tiktokLiveControllerProvider)
              .requireValue
              .saveRequestsToLibrary,
          isTrue,
        );
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getBool('tiktokLive.saveRequestsToLibrary'), isTrue);
      } finally {
        firstContainer.dispose();
        await firstService.close();
      }

      final secondService = _FakeTikTokLiveCommandService();
      final secondContainer = ProviderContainer(
        overrides: [
          tiktokLiveCommandServiceProvider.overrideWithValue(secondService),
        ],
      );
      addTearDown(() async {
        secondContainer.dispose();
        await secondService.close();
      });

      final restored = await secondContainer.read(
        tiktokLiveControllerProvider.future,
      );
      expect(restored.saveRequestsToLibrary, isTrue);
    },
  );

  test(
    'remote LIVE request skips downloads and starts the owned remote queue',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LiveHarness(search: (_) async => const [remoteTrack]);
      addTearDown(harness.dispose);
      await harness.initialize();

      expect(harness.liveState.saveRequestsToLibrary, isFalse);
      harness.service.emit(_playEvent('Cancion LIVE'));

      await _waitUntil(() {
        final live = harness.liveState;
        return live.liveQueue.length == 1 &&
            live.liveQueue.single.isReady &&
            harness.player.remotePlayCalls == 1;
      });

      final item = harness.liveState.liveQueue.single;
      expect(item.saveToLibrary, isFalse);
      expect(item.status, LiveQueueItemStatus.ready);
      expect(item.remoteTrack, remoteTrack);
      expect(item.localTrack, isNull);
      expect(harness.downloadHelper.calls, 0);
      expect(harness.player.lastRemoteTrack, remoteTrack);
      expect(harness.player.lastRemoteQueue, const [remoteTrack]);
      expect(
        harness.player.lastQueueSourceId,
        PlayerController.liveQueueSourceId,
      );
    },
  );

  test(
    'library LIVE mode downloads and starts the owned local queue',
    () async {
      SharedPreferences.setMockInitialValues({});
      final localTrack = LocalTrack(
        id: 'local-live-track',
        title: remoteTrack.title,
        artist: remoteTrack.artist,
        filePath: r'C:\music\local-live-track.m4a',
        addedAt: DateTime(2026),
        sourceUrl: remoteTrack.url,
        duration: remoteTrack.duration,
      );
      final harness = _LiveHarness(
        search: (_) async => const [remoteTrack],
        downloadResult: LocalTrackDownloadResult(
          track: localTrack,
          remoteTrack: remoteTrack,
          reusedExisting: false,
        ),
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.controller.setSaveRequestsToLibrary(true);
      expect(harness.liveState.saveRequestsToLibrary, isTrue);
      harness.service.emit(_playEvent('Cancion descargada'));

      await _waitUntil(() {
        final live = harness.liveState;
        return live.liveQueue.length == 1 &&
            live.liveQueue.single.isReady &&
            harness.player.localPlayCalls == 1;
      });

      final item = harness.liveState.liveQueue.single;
      expect(item.saveToLibrary, isTrue);
      expect(item.status, LiveQueueItemStatus.ready);
      expect(item.remoteTrack, remoteTrack);
      expect(item.localTrack, same(localTrack));
      expect(harness.downloadHelper.calls, 1);
      expect(harness.player.lastLocalTrack, same(localTrack));
      expect(harness.player.lastLocalQueue, [same(localTrack)]);
      expect(harness.player.lastUseNativeQueue, isFalse);
      expect(
        harness.player.lastLocalQueueSourceId,
        PlayerController.liveQueueSourceId,
      );
    },
  );

  test(
    'library LIVE skips a failed download and plays only the next ready track',
    () async {
      SharedPreferences.setMockInitialValues({});
      final downloadedTrack = LocalTrack(
        id: 'local-ready',
        title: 'Cancion lista',
        artist: 'Artista LIVE',
        filePath: r'C:\music\local-ready.m4a',
        addedAt: DateTime(2026),
        sourceUrl: 'https://www.youtube.com/watch?v=lista',
        duration: const Duration(minutes: 3),
      );
      final harness = _LiveHarness(
        search: (query) async => [_remoteTrack(query)],
        download: (track) async {
          if (track.id == 'fallara') {
            throw StateError('La descarga fallo por falta de conexion.');
          }
          return LocalTrackDownloadResult(
            track: downloadedTrack,
            remoteTrack: track,
            reusedExisting: false,
          );
        },
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.controller.setSaveRequestsToLibrary(true);
      harness.service.emit(_playEvent('fallara'));
      harness.service.emit(_playEvent('lista'));

      await _waitUntil(() {
        final queue = harness.liveState.liveQueue;
        return queue.length == 2 &&
            queue.first.status == LiveQueueItemStatus.failed &&
            queue.last.isReady &&
            harness.player.localPlayCalls == 1;
      });

      final queue = harness.liveState.liveQueue;
      expect(queue.first.localTrack, isNull);
      expect(queue.last.localTrack, same(downloadedTrack));
      expect(harness.downloadHelper.calls, 2);
      expect(harness.player.localPlayCalls, 1);
      expect(harness.player.lastLocalTrack, same(downloadedTrack));
      expect(harness.player.lastLocalQueue, [same(downloadedTrack)]);
      expect(
        harness.player.lastLocalQueueSourceId,
        PlayerController.liveQueueSourceId,
      );
    },
  );

  test('clearing the LIVE queue invalidates an in-flight search', () async {
    SharedPreferences.setMockInitialValues({});
    final searchCompletion = Completer<List<TrackInfo>>();
    final harness = _LiveHarness(search: (_) => searchCompletion.future);
    addTearDown(harness.dispose);
    await harness.initialize();

    harness.service.emit(_playEvent('Busqueda lenta'));
    await _waitUntil(
      () =>
          harness.repository.searchCalls == 1 &&
          harness.liveState.liveQueue.length == 1,
    );

    await harness.controller.clearLiveQueue();
    searchCompletion.complete(const [remoteTrack]);
    await _pumpEventQueue();

    expect(harness.liveState.liveQueue, isEmpty);
    expect(harness.player.remotePlayCalls, 0);
    expect(harness.downloadHelper.calls, 0);
  });

  test(
    'resolves concurrently but commits and publishes in acceptance order',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = Completer<List<TrackInfo>>();
      final second = Completer<List<TrackInfo>>();
      final third = Completer<List<TrackInfo>>();
      final gates = <String, Completer<List<TrackInfo>>>{
        'Primera': first,
        'Segunda': second,
        'Tercera': third,
      };
      final harness = _LiveHarness(search: (query) => gates[query]!.future);
      addTearDown(harness.dispose);
      await harness.initialize();

      harness.service.emit(_playEvent('Primera'));
      harness.service.emit(_playEvent('Segunda'));
      harness.service.emit(_playEvent('Tercera'));
      await _waitUntil(
        () =>
            harness.repository.searchCalls ==
            TikTokLiveController.maxConcurrentResolutions,
      );

      second.complete([_remoteTrack('second')]);
      third.complete([_remoteTrack('third')]);
      await _pumpEventQueue();

      expect(
        harness.liveState.liveQueue.map((item) => item.status),
        everyElement(LiveQueueItemStatus.resolving),
      );
      expect(harness.player.remotePlayCalls, 0);

      first.complete([_remoteTrack('first')]);
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.every((item) => item.isReady) &&
            harness.player.lastRemoteQueue?.length == 3,
      );

      expect(harness.liveState.liveQueue.map((item) => item.remoteTrack?.id), [
        'first',
        'second',
        'third',
      ]);
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        'first',
        'second',
        'third',
      ]);
      expect(harness.player.remotePlayCalls, 1);
    },
  );

  test('never exceeds three concurrent LIVE resolutions', () async {
    SharedPreferences.setMockInitialValues({});
    final gates = <String, Completer<List<TrackInfo>>>{};
    var active = 0;
    var maximumActive = 0;
    final harness = _LiveHarness(
      search: (query) async {
        active++;
        maximumActive = math.max(maximumActive, active);
        final gate = Completer<List<TrackInfo>>();
        gates[query] = gate;
        try {
          return await gate.future;
        } finally {
          active--;
        }
      },
    );
    addTearDown(harness.dispose);
    await harness.initialize();

    for (var index = 0; index < 10; index++) {
      harness.service.emit(_playEvent('Pedido $index'));
    }
    await _waitUntil(
      () =>
          harness.repository.searchCalls ==
          TikTokLiveController.maxConcurrentResolutions,
    );

    while (harness.repository.searchCalls < 10) {
      final pending = gates.entries.firstWhere(
        (entry) => !entry.value.isCompleted,
      );
      final previousCalls = harness.repository.searchCalls;
      pending.value.complete([_remoteTrack(pending.key)]);
      await _waitUntil(
        () => harness.repository.searchCalls == previousCalls + 1,
      );
    }
    for (final entry in gates.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete([_remoteTrack(entry.key)]);
      }
    }
    await _waitUntil(
      () => harness.liveState.liveQueue.every((item) => item.isReady),
    );

    expect(maximumActive, TikTokLiveController.maxConcurrentResolutions);
    expect(harness.repository.searchCalls, 10);
  });

  test(
    'a silent player failure marks the first item failed and starts the next',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LiveHarness(
        search: (query) async => [_remoteTrack(query)],
        silentlyFailRemoteTrackIds: const {'fallara'},
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      harness.service.emit(_playEvent('fallara'));
      harness.service.emit(_playEvent('funciona'));
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.length == 2 &&
            harness.liveState.liveQueue.first.status ==
                LiveQueueItemStatus.failed &&
            harness.liveState.liveQueue.last.isReady &&
            harness.player.lastRemoteTrack?.id == 'funciona',
      );

      expect(harness.player.remotePlayCalls, 2);
      expect(harness.liveState.readyRemoteTracks.map((track) => track.id), [
        'funciona',
      ]);
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        'funciona',
      ]);
    },
  );

  test(
    'a late LIVE request advances past an exhausted remote without reopening it',
    () async {
      SharedPreferences.setMockInitialValues({});
      final liveService = _FakeTikTokLiveCommandService();
      final playerService = _LiveAppendPlayerService();
      final playerController = _TrackingLivePlayerController();
      final primary = _LiveAppendAudioResolver(
        source: AudioStreamSource.youtubeExplode,
        succeeds: (trackId, call) =>
            trackId == 'live-a' ? call == 1 : trackId == 'live-b',
      );
      final fallback = _LiveAppendAudioResolver(
        source: AudioStreamSource.ytDlp,
        succeeds: (_, _) => false,
      );
      final retryDurations = <Duration>[];
      final repository = _SearchMusicRepository(
        (query) async => [_remoteTrack(query)],
      );
      final container = ProviderContainer(
        overrides: [
          tiktokLiveCommandServiceProvider.overrideWithValue(liveService),
          searchTracksProvider.overrideWithValue(SearchTracks(repository)),
          playerServiceProvider.overrideWithValue(playerService),
          playerControllerProvider.overrideWith(() => playerController),
          audioStreamResolverProvider.overrideWithValue(
            FallbackAudioResolver([primary, fallback]),
          ),
          remotePlaybackRetryDelayProvider.overrideWithValue((duration) async {
            retryDurations.add(duration);
          }),
          remotePlaybackCacheProvider.overrideWithValue(
            RemotePlaybackCache(policy: RemotePlaybackCachePolicy.disabled),
          ),
          settingsControllerProvider.overrideWith(
            _LiveAppendSettingsController.new,
          ),
          playbackHistorySinkProvider.overrideWithValue(
            const _NoopPlaybackHistorySink(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await liveService.close();
        await playerService.close();
      });

      await container.read(playerControllerProvider.future);
      await container.read(tiktokLiveControllerProvider.future);
      liveService.emit(_playEvent('live-a'));
      await _waitUntil(
        () =>
            container
                    .read(tiktokLiveControllerProvider)
                    .requireValue
                    .liveQueue
                    .singleOrNull
                    ?.isReady ==
                true &&
            playerService.playedRemoteIds.length == 1,
      );

      playerService.failCurrent('HTTP 503 while travelling');
      await _waitUntil(
        () =>
            container.read(playerControllerProvider).hasError &&
            primary.callsFor('live-a') == 3 &&
            fallback.callsFor('live-a') == 3,
      );

      expect(playerController.publicRemoteStarts, ['live-a']);
      expect(playerService.playedRemoteIds, ['live-a']);
      expect(retryDurations, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]);

      liveService.emit(_playEvent('live-b'));
      await _waitUntil(
        () =>
            playerController.remoteQueueSyncCalls == 1 &&
            playerService.playedRemoteIds.length == 2,
      );

      final live = container.read(tiktokLiveControllerProvider).requireValue;
      expect(live.liveQueue, hasLength(2));
      expect(live.liveQueue.every((item) => item.isReady), isTrue);
      expect(playerController.publicRemoteStarts, ['live-a']);
      expect(playerController.remoteQueueSyncCalls, 1);
      expect(primary.callsFor('live-a'), 3);
      expect(fallback.callsFor('live-a'), 3);
      expect(primary.callsFor('live-b'), 1);
      expect(fallback.callsFor('live-b'), 0);
      expect(playerService.playedRemoteIds, ['live-a', 'live-b']);
      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(
        container.read(playerControllerProvider).requireValue.trackId,
        'live-b',
      );
    },
  );

  test(
    'deadline fails FIFO items but retains their non-cancellable worker slots',
    () async {
      SharedPreferences.setMockInitialValues({});
      final gates = <String, Completer<List<TrackInfo>>>{};
      final harness = _LiveHarness(
        searchDeadline: const Duration(milliseconds: 30),
        search: (query) {
          final gate = Completer<List<TrackInfo>>();
          gates[query] = gate;
          return gate.future;
        },
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      for (var index = 0; index < 4; index++) {
        harness.service.emit(_playEvent('Lenta $index'));
      }
      await _waitUntil(
        () =>
            harness.repository.searchCalls ==
            TikTokLiveController.maxConcurrentResolutions,
      );
      await _waitUntil(
        () => harness.liveState.liveQueue
            .take(TikTokLiveController.maxConcurrentResolutions)
            .every((item) => item.status == LiveQueueItemStatus.failed),
      );

      expect(
        harness.repository.searchCalls,
        TikTokLiveController.maxConcurrentResolutions,
      );
      expect(
        harness.liveState.liveQueue.last.status,
        LiveQueueItemStatus.resolving,
      );

      gates['Lenta 0']!.complete([_remoteTrack('late-zero')]);
      await _waitUntil(
        () =>
            harness.repository.searchCalls ==
            TikTokLiveController.maxConcurrentResolutions + 1,
      );

      await harness.controller.clearLiveQueue();
      for (final gate in gates.values) {
        if (!gate.isCompleted) {
          gate.complete(const []);
        }
      }
      await _pumpEventQueue();
      expect(harness.liveState.liveQueue, isEmpty);
      expect(harness.player.remotePlayCalls, 0);
    },
  );

  test('search deadline does not expire an active library download', () async {
    SharedPreferences.setMockInitialValues({});
    final downloadGate = Completer<void>();
    final localTrack = LocalTrack(
      id: 'slow-download',
      title: 'Descarga legitima',
      artist: 'Artista LIVE',
      filePath: r'C:\music\slow-download.m4a',
      addedAt: DateTime(2026),
      sourceUrl: remoteTrack.url,
      duration: remoteTrack.duration,
    );
    final harness = _LiveHarness(
      searchDeadline: const Duration(milliseconds: 20),
      search: (_) async => const [remoteTrack],
      downloadResult: LocalTrackDownloadResult(
        track: localTrack,
        remoteTrack: remoteTrack,
        reusedExisting: false,
      ),
      downloadGate: downloadGate.future,
    );
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.controller.setSaveRequestsToLibrary(true);

    harness.service.emit(_playEvent('Descarga lenta'));
    await _waitUntil(
      () =>
          harness.liveState.liveQueue.length == 1 &&
          harness.liveState.liveQueue.single.status ==
              LiveQueueItemStatus.downloading,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(
      harness.liveState.liveQueue.single.status,
      LiveQueueItemStatus.downloading,
    );
    expect(harness.player.localPlayCalls, 0);

    downloadGate.complete();
    await _waitUntil(
      () =>
          harness.liveState.liveQueue.single.isReady &&
          harness.player.localPlayCalls == 1,
    );
  });

  test('disconnect invalidates all concurrent in-flight searches', () async {
    SharedPreferences.setMockInitialValues({});
    final searchCompletion = Completer<List<TrackInfo>>();
    final harness = _LiveHarness(search: (_) => searchCompletion.future);
    addTearDown(harness.dispose);
    await harness.initialize();

    for (
      var index = 0;
      index < TikTokLiveController.maxConcurrentResolutions;
      index++
    ) {
      harness.service.emit(_playEvent('Desconexion $index'));
    }
    await _waitUntil(
      () =>
          harness.repository.searchCalls ==
          TikTokLiveController.maxConcurrentResolutions,
    );

    await harness.controller.disconnect();
    searchCompletion.complete(const [remoteTrack]);
    await _pumpEventQueue();

    expect(harness.liveState.status, TikTokLiveStatus.disconnected);
    expect(harness.liveState.liveQueue, isEmpty);
    expect(harness.player.remotePlayCalls, 0);
  });

  test(
    'rejects changing playback mode while the LIVE queue is not empty',
    () async {
      SharedPreferences.setMockInitialValues({});
      final searchCompletion = Completer<List<TrackInfo>>();
      final harness = _LiveHarness(search: (_) => searchCompletion.future);
      addTearDown(harness.dispose);
      await harness.initialize();

      harness.service.emit(_playEvent('Mantener en cola'));
      await _waitUntil(() => harness.liveState.liveQueue.isNotEmpty);

      await harness.controller.setSaveRequestsToLibrary(true);

      expect(harness.liveState.saveRequestsToLibrary, isFalse);
      expect(
        harness.liveState.message,
        'Limpia la cola LIVE antes de cambiar el modo.',
      );
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('tiktokLive.saveRequestsToLibrary'), isNull);

      await harness.controller.clearLiveQueue();
      searchCompletion.complete(const []);
      await _pumpEventQueue();
    },
  );

  test('bounds the LIVE queue and pending music backlog', () async {
    SharedPreferences.setMockInitialValues({});
    final searchCompletion = Completer<List<TrackInfo>>();
    final harness = _LiveHarness(search: (_) => searchCompletion.future);
    addTearDown(harness.dispose);
    await harness.initialize();

    for (var index = 0; index <= TikTokLiveController.maxQueueItems; index++) {
      harness.service.emit(_playEvent('Pedido $index'));
    }

    await _waitUntil(
      () =>
          harness.liveState.liveQueue.length ==
              TikTokLiveController.maxQueueItems &&
          harness.liveState.message.contains('Cola LIVE llena'),
    );

    expect(
      harness.liveState.liveQueue,
      hasLength(TikTokLiveController.maxQueueItems),
    );
    expect(
      harness.liveState.commandsHandled,
      TikTokLiveController.maxQueueItems,
    );
    expect(
      harness.liveState.message,
      contains('${TikTokLiveController.maxQueueItems}'),
    );
    expect(
      harness.repository.searchCalls,
      TikTokLiveController.maxConcurrentResolutions,
    );

    await harness.controller.clearLiveQueue();
    searchCompletion.complete(const []);
    await _pumpEventQueue();
  });
}

TikTokLiveEvent _playEvent(String query) {
  return TikTokLiveEvent(
    type: 'command',
    command: TikTokLiveChatCommand(
      action: 'play',
      query: query,
      user: 'viewer',
      text: '!play $query',
    ),
  );
}

TrackInfo _remoteTrack(String id) {
  return TrackInfo(
    id: id,
    title: 'Cancion $id',
    artist: 'Artista LIVE',
    url: 'https://www.youtube.com/watch?v=$id',
    duration: const Duration(minutes: 3),
  );
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed >= timeout) {
      fail('Timed out waiting for the asynchronous LIVE operation.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> _pumpEventQueue() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _LiveHarness {
  _LiveHarness({
    required Future<List<TrackInfo>> Function(String) search,
    LocalTrackDownloadResult? downloadResult,
    Future<LocalTrackDownloadResult> Function(TrackInfo)? download,
    Duration searchDeadline = const Duration(seconds: 30),
    Set<String> silentlyFailRemoteTrackIds = const {},
    Future<void>? downloadGate,
  }) : repository = _SearchMusicRepository(search),
       service = _FakeTikTokLiveCommandService(),
       player = _RecordingPlayerController(
         silentlyFailRemoteTrackIds: silentlyFailRemoteTrackIds,
       ) {
    container = ProviderContainer(
      overrides: [
        tiktokLiveCommandServiceProvider.overrideWithValue(service),
        searchTracksProvider.overrideWithValue(SearchTracks(repository)),
        localTrackDownloadHelperProvider.overrideWith(
          (ref) => _CountingLocalTrackDownloadHelper(
            ref,
            result: downloadResult,
            download: download,
            beforeResult: downloadGate,
          ),
        ),
        playerControllerProvider.overrideWith(() => player),
        tiktokLiveControllerProvider.overrideWith(
          () => TikTokLiveController(searchDeadline: searchDeadline),
        ),
      ],
    );
  }

  final _SearchMusicRepository repository;
  final _FakeTikTokLiveCommandService service;
  final _RecordingPlayerController player;
  late final ProviderContainer container;
  late final _CountingLocalTrackDownloadHelper downloadHelper;

  TikTokLiveController get controller =>
      container.read(tiktokLiveControllerProvider.notifier);

  TikTokLiveState get liveState =>
      container.read(tiktokLiveControllerProvider).requireValue;

  Future<void> initialize() async {
    await container.read(playerControllerProvider.future);
    await container.read(tiktokLiveControllerProvider.future);
    downloadHelper =
        container.read(localTrackDownloadHelperProvider)
            as _CountingLocalTrackDownloadHelper;
  }

  Future<void> dispose() async {
    container.dispose();
    await service.close();
  }
}

class _FakeTikTokLiveCommandService extends TikTokLiveCommandService {
  final _events = StreamController<TikTokLiveEvent>.broadcast();

  @override
  Stream<TikTokLiveEvent> get events => _events.stream;

  void emit(TikTokLiveEvent event) => _events.add(event);

  Future<void> close() => _events.close();
}

class _SearchMusicRepository implements MusicRepository {
  _SearchMusicRepository(this._search);

  final Future<List<TrackInfo>> Function(String query) _search;
  int searchCalls = 0;

  @override
  Future<List<TrackInfo>> search(String query) {
    searchCalls++;
    return _search(query);
  }

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) =>
      throw UnsupportedError('Downloads are not expected in these tests.');

  @override
  Future<TrackInfo> getInfo(String url) =>
      throw UnsupportedError('Track info lookup is not expected.');

  @override
  Future<TrackInfo> getPlaybackInfo(String url) =>
      throw UnsupportedError('Playback info lookup is not expected.');
}

class _CountingLocalTrackDownloadHelper extends LocalTrackDownloadHelper {
  _CountingLocalTrackDownloadHelper(
    super.ref, {
    this.result,
    this.download,
    this.beforeResult,
  });

  final LocalTrackDownloadResult? result;
  final Future<LocalTrackDownloadResult> Function(TrackInfo)? download;
  final Future<void>? beforeResult;
  int calls = 0;

  @override
  Future<LocalTrackDownloadResult> resolveForLibrary(
    TrackInfo track, {
    String? taskId,
    void Function(TrackInfo track)? onResolved,
    void Function()? onDownloadStarted,
    bool allowConcurrentDownload = false,
  }) async {
    calls++;
    onResolved?.call(track);
    onDownloadStarted?.call();
    final wait = beforeResult;
    if (wait != null) {
      await wait;
    }
    final download = this.download;
    if (download != null) {
      return download(track);
    }
    return result ??
        (throw StateError('Remote-only LIVE mode must not download tracks.'));
  }
}

class _RecordingPlayerController extends PlayerController {
  _RecordingPlayerController({this.silentlyFailRemoteTrackIds = const {}});

  final Set<String> silentlyFailRemoteTrackIds;
  int remotePlayCalls = 0;
  int localPlayCalls = 0;
  TrackInfo? lastRemoteTrack;
  List<TrackInfo>? lastRemoteQueue;
  String? lastQueueSourceId;
  LocalTrack? lastLocalTrack;
  List<LocalTrack>? lastLocalQueue;
  bool? lastUseNativeQueue;
  String? lastLocalQueueSourceId;
  int remoteQueueSyncCalls = 0;

  @override
  Future<PlayerSnapshot> build() async {
    return const PlayerSnapshot(status: PlayerStatus.idle);
  }

  @override
  Future<void> playRemote(
    TrackInfo track, {
    List<TrackInfo>? queue,
    String? queueSourceId,
  }) async {
    remotePlayCalls++;
    lastRemoteTrack = track;
    lastRemoteQueue = queue == null ? null : List.unmodifiable(queue);
    lastQueueSourceId = queueSourceId;
    if (silentlyFailRemoteTrackIds.contains(track.id)) {
      state = AsyncError(
        StateError('Fallo silencioso al abrir ${track.id}.'),
        StackTrace.current,
      );
      return;
    }
    state = AsyncData(
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
  Future<bool> syncRemoteQueueSource(
    String sourceId,
    List<TrackInfo> tracks,
  ) async {
    remoteQueueSyncCalls++;
    lastRemoteQueue = List.unmodifiable(tracks);
    lastQueueSourceId = sourceId;
    return true;
  }

  @override
  Future<void> playLocal(
    LocalTrack track, {
    List<LocalTrack>? queue,
    bool useNativeQueue = true,
    String? queueSourceId,
  }) async {
    localPlayCalls++;
    lastLocalTrack = track;
    lastLocalQueue = queue == null ? null : List.unmodifiable(queue);
    lastUseNativeQueue = useNativeQueue;
    lastLocalQueueSourceId = queueSourceId;
    state = AsyncData(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.filePath,
        duration: track.duration,
      ),
    );
  }
}

class _TrackingLivePlayerController extends PlayerController {
  final List<String> publicRemoteStarts = [];
  int remoteQueueSyncCalls = 0;

  @override
  Future<void> playRemote(
    TrackInfo track, {
    List<TrackInfo>? queue,
    String? queueSourceId,
  }) {
    publicRemoteStarts.add(track.id);
    return super.playRemote(track, queue: queue, queueSourceId: queueSourceId);
  }

  @override
  Future<bool> syncRemoteQueueSource(String sourceId, List<TrackInfo> tracks) {
    remoteQueueSyncCalls++;
    return super.syncRemoteQueueSource(sourceId, tracks);
  }
}

class _LiveAppendSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async {
    return const SettingsState(
      downloadDirectory: '/tmp/bstream-live-append-test',
      language: AppLanguage.spanish,
      recommendationHistoryEnabled: false,
    );
  }
}

class _NoopPlaybackHistorySink implements PlaybackHistorySink {
  const _NoopPlaybackHistorySink();

  @override
  Future<void> persist(PlaybackHistoryWrite write) async {}
}

class _LiveAppendAudioResolver implements AudioStreamResolver {
  _LiveAppendAudioResolver({required this.source, required this.succeeds});

  final AudioStreamSource source;
  final bool Function(String trackId, int call) succeeds;
  final Map<String, int> _calls = {};

  int callsFor(String trackId) => _calls[trackId] ?? 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    final call = (_calls[track.id] ?? 0) + 1;
    _calls[track.id] = call;
    if (!succeeds(track.id, call)) {
      throw SocketException('${source.name} offline for ${track.id}');
    }
    return AudioStreamResolution(
      source: source,
      streamUrl: 'https://media.example/${track.id}-$call.m4a',
      streamExtension: 'm4a',
      streamMimeType: 'audio/mp4',
      videoId: track.id,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _LiveAppendPlayerService extends PlayerService {
  final _snapshots = StreamController<PlayerSnapshot>.broadcast();
  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  final List<String> playedRemoteIds = [];

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshots.stream;

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  bool get supportsLocalQueueReplacement => false;

  @override
  Future<void> playRemote(TrackInfo track) async {
    playedRemoteIds.add(track.id);
    _snapshot = PlayerSnapshot(
      status: PlayerStatus.playing,
      title: track.title,
      artist: track.artist,
      trackId: track.id,
      sourceUrl: track.url,
      duration: track.duration,
      isRemote: true,
    );
    _snapshots.add(_snapshot);
  }

  void failCurrent(String message) {
    _snapshot = _snapshot.copyWith(
      status: PlayerStatus.failed,
      errorMessage: message,
    );
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    throw UnsupportedError('Local playback is not expected.');
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) async {
    throw UnsupportedError('Local playback is not expected.');
  }

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> stop() async {
    _snapshot = _snapshot.copyWith(status: PlayerStatus.stopped);
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> seek(Duration position) async {
    _snapshot = _snapshot.copyWith(position: position);
  }

  @override
  Future<void> setVolume(double volume) async {
    _snapshot = _snapshot.copyWith(volume: volume);
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {}

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {}

  @override
  Future<void> dispose() => close();

  Future<void> close() => _snapshots.close();
}
