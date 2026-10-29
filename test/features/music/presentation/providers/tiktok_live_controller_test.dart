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
import 'package:bstream_music/services/player/media_kit_player_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show Media;
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
    'finishing LIVE clears its published batch and starts a fresh one',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LiveHarness(
        search: (query) async =>
            query == 'sin resultados' ? const [] : [_remoteTrack(query)],
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      harness.service.emit(_playEvent('sin resultados'));
      harness.service.emit(_playEvent('primera'));
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.length == 2 &&
            harness.liveState.liveQueue.first.status ==
                LiveQueueItemStatus.failed &&
            harness.player.remotePlayCalls == 1,
      );

      harness.player.completeLivePlayback();

      expect(harness.liveState.liveQueue, isEmpty);
      expect(harness.player.stopCalls, 0);
      expect(harness.player.clearQueueSourceCalls, 0);
      harness.service.emit(_playEvent('segunda'));
      await _waitUntil(() => harness.player.remotePlayCalls == 2);
      expect(harness.liveState.liveQueue.single.remoteTrack?.id, 'segunda');
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        'segunda',
      ]);
    },
  );

  test(
    'finishing LIVE also clears requests that failed after its last queue update',
    () async {
      SharedPreferences.setMockInitialValues({});
      final laterSearch = Completer<List<TrackInfo>>();
      final harness = _LiveHarness(
        search: (query) => query == 'fallida'
            ? laterSearch.future
            : Future.value([_remoteTrack(query)]),
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.service.emit(_playEvent('sonando'));
      await _waitUntil(() => harness.player.remotePlayCalls == 1);
      harness.service.emit(_playEvent('fallida'));
      await _waitUntil(() => harness.liveState.liveQueue.length == 2);
      laterSearch.complete(const []);
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.last.status ==
            LiveQueueItemStatus.failed,
      );
      expect(harness.player.remoteQueueSyncCalls, 0);

      harness.player.completeLivePlayback();

      expect(harness.liveState.liveQueue, isEmpty);
    },
  );

  test(
    'finishing downloaded LIVE clears its batch without deleting library tracks',
    () async {
      SharedPreferences.setMockInitialValues({});
      final localTrack = LocalTrack(
        id: 'downloaded-live',
        title: remoteTrack.title,
        artist: remoteTrack.artist,
        filePath: r'C:\music\downloaded-live.m4a',
        addedAt: DateTime(2026),
      );
      final harness = _LiveHarness(
        search: (_) async => const [remoteTrack],
        downloadResult: LocalTrackDownloadResult(
          track: localTrack,
          remoteTrack: remoteTrack,
          reusedExisting: true,
        ),
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.controller.setSaveRequestsToLibrary(true);
      harness.service.emit(_playEvent('descargada'));
      await _waitUntil(() => harness.player.localPlayCalls == 1);

      harness.player.completeLivePlayback();

      expect(harness.liveState.liveQueue, isEmpty);
      expect(harness.player.lastLocalTrack, same(localTrack));
      expect(harness.player.stopCalls, 0);
      await harness.controller.setSaveRequestsToLibrary(false);
      expect(harness.liveState.saveRequestsToLibrary, isFalse);
    },
  );

  test(
    'finishing LIVE preserves a pending request and its resolution generation',
    () async {
      SharedPreferences.setMockInitialValues({});
      final laterSearch = Completer<List<TrackInfo>>();
      final harness = _LiveHarness(
        search: (query) => query == 'pendiente'
            ? laterSearch.future
            : Future.value([_remoteTrack(query)]),
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.service.emit(_playEvent('sonando'));
      harness.service.emit(_playEvent('pendiente'));
      await _waitUntil(
        () =>
            harness.player.remotePlayCalls == 1 &&
            harness.liveState.liveQueue.length == 2,
      );
      final pendingId = harness.liveState.liveQueue.last.id;

      harness.player.completeLivePlayback();

      expect(harness.liveState.liveQueue.single.id, pendingId);
      expect(harness.liveState.liveQueue.single.isPending, isTrue);
      laterSearch.complete([_remoteTrack('nueva')]);
      await _waitUntil(() => harness.player.remotePlayCalls == 2);
      expect(harness.liveState.liveQueue.single.id, pendingId);
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        'nueva',
      ]);
    },
  );

  test(
    'requests resolving during restoration wait before interrupting the normal queue',
    () async {
      SharedPreferences.setMockInitialValues({});
      final laterSearch = Completer<List<TrackInfo>>();
      final harness = _LiveHarness(
        search: (query) => query == 'pendiente'
            ? laterSearch.future
            : Future.value([_remoteTrack(query)]),
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.service.emit(_playEvent('sonando'));
      harness.service.emit(_playEvent('pendiente'));
      await _waitUntil(
        () =>
            harness.player.remotePlayCalls == 1 &&
            harness.liveState.liveQueue.length == 2,
      );

      harness.player.beginLiveRestoration();
      laterSearch.complete([_remoteTrack('nueva')]);
      await _waitUntil(() => harness.liveState.liveQueue.single.isReady);
      await _pumpEventQueue();
      expect(harness.player.remotePlayCalls, 1);
      expect(harness.player.isLiveQueueActive, isFalse);

      harness.player.finishLiveRestoration();
      await _waitUntil(() => harness.player.remotePlayCalls == 2);
      expect(harness.player.lastRemoteTrack?.id, 'nueva');
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        'nueva',
      ]);
      expect(harness.player.isLiveQueueActive, isTrue);
    },
  );

  test(
    'manual LIVE selection waits for restoration and ignores a cleared request',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LiveHarness(
        search: (query) async => [_remoteTrack(query)],
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.service.emit(_playEvent('sonando'));
      await _waitUntil(() => harness.player.remotePlayCalls == 1);
      final completedId = harness.liveState.liveQueue.single.id;

      harness.player.beginLiveRestoration();
      final selecting = harness.controller.playLiveQueueItem(completedId);
      await _pumpEventQueue();
      expect(harness.player.remotePlayCalls, 1);
      harness.player.finishLiveRestoration();
      await selecting;

      expect(harness.player.remotePlayCalls, 1);
      expect(harness.liveState.liveQueue, isEmpty);
    },
  );

  test(
    'finishing a batch preserves ready requests not published to the player yet',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LiveHarness(
        search: (query) async => [_remoteTrack(query)],
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.service.emit(_playEvent('publicada'));
      await _waitUntil(() => harness.player.remotePlayCalls == 1);

      harness.player.holdLiveQueueSynchronization();
      harness.service.emit(_playEvent('lista sin publicar'));
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.length == 2 &&
            harness.liveState.liveQueue.every((item) => item.isReady),
      );
      await _pumpEventQueue();
      expect(harness.player.remoteQueueSyncCalls, 0);

      harness.player.beginLiveRestoration();
      expect(
        harness.liveState.liveQueue.single.remoteTrack?.id,
        'lista sin publicar',
      );
      harness.player.finishLiveRestoration();
      await _waitUntil(() => harness.player.remotePlayCalls == 2);
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        'lista sin publicar',
      ]);
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
    '!stop pauses an active LIVE source without removing its requests',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LiveHarness(
        search: (query) async => [_remoteTrack(query)],
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      harness.service.emit(_playEvent('Activa'));
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.singleOrNull?.isReady == true &&
            harness.player.isLiveQueueActive,
      );
      final requestIds = [
        for (final item in harness.liveState.liveQueue) item.id,
      ];

      harness.service.emit(_commandEvent('stop', '!stop'));
      await _waitUntil(() => harness.player.pauseCalls == 1);

      expect(harness.liveState.liveQueue.map((item) => item.id), requestIds);
      expect(harness.player.pauseCalls, 1);
      expect(harness.player.stopCalls, 0);
      expect(harness.player.clearQueueSourceCalls, 0);
    },
  );

  test('!stop does not pause playback outside the LIVE source', () async {
    SharedPreferences.setMockInitialValues({});
    final harness = _LiveHarness(search: (_) async => const []);
    addTearDown(harness.dispose);
    await harness.initialize();

    expect(harness.player.isLiveQueueActive, isFalse);
    harness.service.emit(_commandEvent('stop', '!stop'));
    await _waitUntil(() => harness.liveState.lastCommand?.action == 'stop');
    await _pumpEventQueue();

    expect(harness.player.pauseCalls, 0);
    expect(harness.liveState.liveQueue, isEmpty);
  });

  test(
    'removing a pending middle request ignores late search results',
    () async {
      SharedPreferences.setMockInitialValues({});
      final pending = Completer<List<TrackInfo>>();
      final harness = _LiveHarness(
        search: (query) => query == 'Pendiente'
            ? pending.future
            : Future.value([_remoteTrack(query)]),
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      for (final query in ['Primera', 'Pendiente', 'Tercera']) {
        harness.service.emit(_playEvent(query));
      }
      await _waitUntil(
        () =>
            harness.repository.searchCalls == 3 &&
            harness.liveState.liveQueue.first.isReady,
      );
      final removedId = harness.liveState.liveQueue[1].id;
      await harness.controller.removeLiveQueueItem(removedId);
      // Repeated taps on the same row are harmless.
      await harness.controller.removeLiveQueueItem(removedId);
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.length == 2 &&
            harness.liveState.liveQueue.every((item) => item.isReady) &&
            harness.player.lastRemoteQueue?.length == 2,
      );
      pending.complete([_remoteTrack('late-result')]);
      await _pumpEventQueue();
      expect(harness.liveState.liveQueue.map((item) => item.query), [
        'Primera',
        'Tercera',
      ]);
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        'Primera',
        'Tercera',
      ]);
      expect(harness.player.remotePlayCalls, 1);
    },
  );

  test(
    'rapid row removals do not restore an already removed request',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LiveHarness(
        search: (query) async => [_remoteTrack(query)],
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      for (final query in ['Primera', 'Segunda', 'Tercera']) {
        harness.service.emit(_playEvent(query));
      }
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.length == 3 &&
            harness.liveState.liveQueue.every((item) => item.isReady) &&
            harness.player.lastRemoteQueue?.length == 3,
      );
      final removedIds = harness.liveState.liveQueue
          .skip(1)
          .map((item) => item.id)
          .toList();
      await Future.wait(removedIds.map(harness.controller.removeLiveQueueItem));
      expect(harness.liveState.liveQueue.single.query, 'Primera');
      expect(harness.player.lastRemoteQueue?.single.id, 'Primera');
      expect(harness.player.remotePlayCalls, 1);
    },
  );

  test(
    'removing one duplicate request keeps its shared playback entry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LiveHarness(
        search: (_) async => [_remoteTrack('shared')],
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.service.emit(_playEvent('Pedido uno'));
      harness.service.emit(_playEvent('Pedido dos'));
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.length == 2 &&
            harness.liveState.liveQueue.every((item) => item.isReady),
      );
      await harness.controller.removeLiveQueueItem(
        harness.liveState.liveQueue.first.id,
      );
      expect(harness.liveState.liveQueue.single.query, 'Pedido dos');
      expect(harness.player.lastRemoteQueue?.single.id, 'shared');
      expect(harness.player.remotePlayCalls, 1);
    },
  );

  for (final saveToLibrary in [false, true]) {
    test(
      '${saveToLibrary ? 'downloaded' : 'remote'} row removals preserve playback order and restore the normal queue',
      () async {
        final harness = _RealLiveHarness(saveToLibrary: saveToLibrary);
        addTearDown(harness.dispose);
        await harness.initialize();
        await harness.player.playRemote(_remoteTrack('normal-original'));
        await harness.player.seek(const Duration(seconds: 42));
        for (final query in ['live-a', 'live-b', 'live-c', 'live-d']) {
          harness.service.emit(_playEvent(query));
        }
        await _waitUntil(
          () =>
              harness.liveState.liveQueue.length == 4 &&
              harness.liveState.liveQueue.every((item) => item.isReady) &&
              harness.queue.entries.length == 4,
        );
        await harness.player.playNext();
        await harness.player.seek(const Duration(seconds: 19));
        String itemId(String query) => harness.liveState.liveQueue
            .firstWhere((item) => item.query == query)
            .id;

        await harness.live.removeLiveQueueItem(itemId('live-c'));
        expect(harness.queue.entries.map((entry) => entry.id), [
          'live-a',
          'live-b',
          'live-d',
        ]);
        expect(harness.backend.currentSnapshot.trackId, 'live-b');
        expect(
          harness.backend.currentSnapshot.position,
          const Duration(seconds: 19),
        );

        // Retire the current request, then remove an earlier row while it finishes.
        await harness.live.removeLiveQueueItem(itemId('live-b'));
        await harness.live.removeLiveQueueItem(itemId('live-a'));
        expect(harness.liveState.liveQueue.single.query, 'live-d');
        expect(harness.queue.entries.map((entry) => entry.id), [
          'live-b',
          'live-d',
        ]);
        expect(harness.queue.currentIndex, 0);
        expect(harness.backend.currentSnapshot.trackId, 'live-b');
        expect(
          harness.backend.currentSnapshot.position,
          const Duration(seconds: 19),
        );

        harness.backend.completeCurrent();
        await _waitUntil(
          () =>
              harness.backend.currentSnapshot.trackId == 'live-d' &&
              harness.queue.entries.length == 1,
        );
        harness.backend.completeCurrent();
        await _waitUntil(
          () =>
              !harness.player.isLiveQueueActive &&
              harness.backend.currentSnapshot.trackId == 'normal-original' &&
              harness.backend.currentSnapshot.position ==
                  const Duration(seconds: 42),
        );
        expect(harness.liveState.liveQueue, isEmpty);
        expect(harness.backend.currentSnapshot.status, PlayerStatus.playing);
      },
    );
  }

  test(
    '!revoke removes only the last ready request and syncs the remaining queue',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LiveHarness(
        search: (query) async => [_remoteTrack(query)],
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      harness.service.emit(_playEvent('Primera lista'));
      harness.service.emit(_playEvent('Ultima lista'));
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.length == 2 &&
            harness.liveState.liveQueue.every((item) => item.isReady) &&
            harness.player.lastRemoteQueue?.length == 2,
      );
      final remainingId = harness.liveState.liveQueue.first.id;
      final syncCallsBeforeRevoke = harness.player.remoteQueueSyncCalls;

      harness.service.emit(_commandEvent('revoke', '!revoke'));
      await _waitUntil(
        () =>
            harness.liveState.liveQueue.length == 1 &&
            harness.player.remoteQueueSyncCalls == syncCallsBeforeRevoke + 1,
      );

      expect(harness.liveState.liveQueue.single.id, remainingId);
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        'Primera lista',
      ]);
      expect(harness.player.pauseCalls, 0);
      expect(harness.player.stopCalls, 0);
      expect(harness.player.clearQueueSourceCalls, 0);
      expect(harness.player.isLiveQueueActive, isTrue);
    },
  );

  test('!revoke hides the playing request without interrupting it', () async {
    SharedPreferences.setMockInitialValues({});
    final harness = _LiveHarness(
      search: (query) async => [_remoteTrack(query)],
    );
    addTearDown(harness.dispose);
    await harness.initialize();

    harness.service.emit(_playEvent('Sonando'));
    await _waitUntil(
      () =>
          harness.liveState.liveQueue.singleOrNull?.isReady == true &&
          harness.player.isLiveQueueActive,
    );

    harness.service.emit(_commandEvent('revoke', '!revoke'));
    await _waitUntil(() => harness.liveState.liveQueue.isEmpty);

    expect(harness.player.remotePlayCalls, 1);
    expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
      'Sonando',
    ]);
    expect(harness.player.pauseCalls, 0);
    expect(harness.player.stopCalls, 0);
    expect(harness.player.clearQueueSourceCalls, 0);

    harness.service.emit(_playEvent('Siguiente'));
    await _waitUntil(
      () =>
          harness.liveState.liveQueue.singleOrNull?.isReady == true &&
          harness.player.lastRemoteQueue?.length == 2,
    );
    expect(harness.player.remotePlayCalls, 1);
    expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
      'Sonando',
      'Siguiente',
    ]);

    harness.player.simulateRemoteTrack(_remoteTrack('Siguiente'));
    await _waitUntil(() => harness.player.lastRemoteQueue?.length == 1);
    expect(harness.player.lastRemoteQueue?.single.id, 'Siguiente');
  });

  test(
    '!revoke cancels the last pending request without blocking a later one',
    () async {
      SharedPreferences.setMockInitialValues({});
      final revokedSearch = Completer<List<TrackInfo>>();
      final harness = _LiveHarness(
        search: (query) {
          if (query == 'Pendiente revocado') {
            return revokedSearch.future;
          }
          return Future.value([_remoteTrack(query)]);
        },
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      harness.service.emit(_playEvent('Primera conservada'));
      await _waitUntil(
        () => harness.liveState.liveQueue.singleOrNull?.isReady == true,
      );
      harness.service.emit(_playEvent('Pendiente revocado'));
      await _waitUntil(
        () =>
            harness.repository.searchCalls == 2 &&
            harness.liveState.liveQueue.length == 2 &&
            harness.liveState.liveQueue.last.status ==
                LiveQueueItemStatus.resolving,
      );

      harness.service.emit(_commandEvent('revoke', '!revoke'));
      await _waitUntil(() => harness.liveState.liveQueue.length == 1);
      harness.service.emit(_playEvent('Posterior aceptado'));
      await _waitUntil(
        () =>
            harness.repository.searchCalls == 3 &&
            harness.liveState.liveQueue.length == 2 &&
            harness.liveState.liveQueue.last.isReady &&
            harness.player.lastRemoteQueue?.length == 2,
      );

      expect(harness.liveState.liveQueue.map((item) => item.query), [
        'Primera conservada',
        'Posterior aceptado',
      ]);
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        'Primera conservada',
        'Posterior aceptado',
      ]);

      revokedSearch.complete([_remoteTrack('demasiado-tarde')]);
      await _pumpEventQueue();
      expect(
        harness.liveState.liveQueue.map((item) => item.query),
        isNot(contains('Pendiente revocado')),
      );
      expect(
        harness.liveState.readyRemoteTracks.map((track) => track.id),
        isNot(contains('demasiado-tarde')),
      );
    },
  );

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
    'LIVE consumes its remote requests then resumes the interrupted queue and position',
    () async {
      SharedPreferences.setMockInitialValues({});
      final liveService = _FakeTikTokLiveCommandService();
      final playerService = _LiveAppendPlayerService();
      final resolver = _LiveAppendAudioResolver(
        source: AudioStreamSource.innerTube,
        succeeds: (_, _) => true,
      );
      final repository = _SearchMusicRepository(
        (query) async => [_remoteTrack(query)],
      );
      final container = ProviderContainer(
        overrides: [
          tiktokLiveCommandServiceProvider.overrideWithValue(liveService),
          searchTracksProvider.overrideWithValue(SearchTracks(repository)),
          playerServiceProvider.overrideWithValue(playerService),
          audioStreamResolverProvider.overrideWithValue(resolver),
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
      final controller = container.read(playerControllerProvider.notifier);
      final normal = [_remoteTrack('normal-a'), _remoteTrack('normal-b')];
      await controller.playRemote(
        normal.first,
        queue: normal,
        queueSourceId: 'normal-queue',
      );
      await controller.seek(const Duration(seconds: 42));

      liveService.emit(_playEvent('live-a'));
      liveService.emit(_playEvent('live-b'));
      await _waitUntil(
        () =>
            container.read(playbackQueueProvider).entries.length == 2 &&
            controller.isLiveQueueActive &&
            container
                .read(tiktokLiveControllerProvider)
                .requireValue
                .liveQueue
                .every((item) => item.isReady),
      );
      expect(playerService.currentSnapshot.trackId, 'live-a');
      playerService.completeCurrent();
      await _waitUntil(() => playerService.currentSnapshot.trackId == 'live-b');
      playerService.completeCurrent();
      await _waitUntil(
        () =>
            !controller.isLiveQueueActive &&
            playerService.currentSnapshot.trackId == 'normal-a',
      );
      await controller.waitForLiveQueueRestoration();
      expect(
        playerService.currentSnapshot.position,
        const Duration(seconds: 42),
      );

      expect(
        container.read(tiktokLiveControllerProvider).requireValue.liveQueue,
        isEmpty,
      );
      expect(
        container.read(playbackQueueProvider).entries.map((item) => item.title),
        normal.map((track) => track.title),
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(playerService.playedRemoteIds, [
        'normal-a',
        'live-a',
        'live-b',
        'normal-a',
      ]);
      expect(playerService.currentSnapshot.status, PlayerStatus.playing);
      expect(
        container.read(playerControllerProvider).requireValue.wantsToPlay,
        isTrue,
      );
      await controller.playNext();
      expect(playerService.currentSnapshot.trackId, 'normal-b');
    },
  );

  for (final saveToLibrary in [false, true]) {
    for (final completionFirst in [false, true]) {
      for (final hasNormalQueue in [false, true]) {
        final mode = saveToLibrary ? 'downloaded' : 'remote';
        test(
          '$mode native EOF (completed first=$completionFirst, normal queue=$hasNormalQueue) clears LIVE and restores playback automatically',
          () async {
            final native = _LiveMediaKitBackend();
            final playerService = MediaKitPlayerService(backend: native);
            final harness = _RealLiveHarness(
              saveToLibrary: saveToLibrary,
              playerService: playerService,
            );
            addTearDown(() async {
              await harness.dispose();
              await playerService.dispose();
            });
            await harness.initialize();
            if (hasNormalQueue) {
              final normal = [
                _remoteTrack('native-normal-a'),
                _remoteTrack('native-normal-b'),
              ];
              await harness.player.playRemote(
                normal.last,
                queue: normal,
                queueSourceId: 'native-normal-queue',
              );
              await harness.player.seek(const Duration(seconds: 42));
              // Let the source clock reach the controller before LIVE captures
              // the interrupted occurrence and its resume position.
              await _pumpEventQueue();
            }

            harness.service.emit(_playEvent('native-live-a'));
            harness.service.emit(_playEvent('native-live-b'));
            await _waitUntil(
              () =>
                  harness.liveState.liveQueue.length == 2 &&
                  harness.liveState.liveQueue.every((item) => item.isReady) &&
                  harness.queue.entries.length == 2 &&
                  playerService.currentSnapshot.trackId == 'native-live-a',
            );
            await _pumpEventQueue();
            native.completeCurrent(completionFirst: completionFirst);
            await _waitUntil(
              () => playerService.currentSnapshot.trackId == 'native-live-b',
            );
            await _pumpEventQueue();
            native.completeCurrent(completionFirst: completionFirst);
            await _waitUntil(() => !harness.player.isLiveQueueActive);
            await harness.player.waitForLiveQueueRestoration();
            await _pumpEventQueue();

            expect(harness.liveState.liveQueue, isEmpty);
            if (hasNormalQueue) {
              expect(harness.queue.entries.map((entry) => entry.id), [
                'native-normal-a',
                'native-normal-b',
              ]);
              expect(harness.queue.currentIndex, 1);
              final restored = harness.container
                  .read(playerControllerProvider)
                  .requireValue;
              expect(restored.trackId, 'native-normal-b');
              expect(restored.status, PlayerStatus.playing);
              expect(restored.wantsToPlay, isTrue);
              expect(restored.position, const Duration(seconds: 42));
              expect(native.openedSources, hasLength(4));
            } else {
              expect(harness.queue.entries, isEmpty);
              final idle = harness.container
                  .read(playerControllerProvider)
                  .requireValue;
              expect(idle.trackId, isNull);
              expect(idle.status, PlayerStatus.idle);
              expect(idle.wantsToPlay, isFalse);
              expect(native.openedSources, hasLength(2));
            }
          },
        );
      }
    }
  }

  for (final completionFirst in [false, true]) {
    test(
      'an explicit selection supersedes native LIVE EOF (completed first=$completionFirst)',
      () async {
        final native = _LiveMediaKitBackend();
        final playerService = MediaKitPlayerService(backend: native);
        final harness = _RealLiveHarness(playerService: playerService);
        addTearDown(() async {
          await harness.dispose();
          await playerService.dispose();
        });
        await harness.initialize();
        await harness.player.playRemote(_remoteTrack('superseded-normal'));
        harness.service.emit(_playEvent('superseded-live'));
        await _waitUntil(
          () => playerService.currentSnapshot.trackId == 'superseded-live',
        );
        await _pumpEventQueue();
        native.completeCurrent(completionFirst: completionFirst);
        await harness.player.playRemote(_remoteTrack('manual-choice'));
        await _pumpEventQueue();

        expect(native.openedSources, hasLength(3));
        expect(playerService.currentSnapshot.trackId, 'manual-choice');
        expect(playerService.currentSnapshot.status, PlayerStatus.playing);
        expect(harness.queue.entries.single.id, 'manual-choice');
        expect(harness.player.isLiveQueueActive, isFalse);
      },
    );
  }

  for (final action in ['pause', 'stop', 'native pause']) {
    test(
      'native EOF respects $action instead of resuming normal playback',
      () async {
        final native = _LiveMediaKitBackend();
        final playerService = MediaKitPlayerService(backend: native);
        final harness = _RealLiveHarness(playerService: playerService);
        addTearDown(() async {
          await harness.dispose();
          await playerService.dispose();
        });
        await harness.initialize();
        await harness.player.playRemote(_remoteTrack('pause-normal'));
        await harness.player.seek(const Duration(seconds: 42));
        await _pumpEventQueue();
        harness.service.emit(_playEvent('pause-live'));
        await _waitUntil(
          () => playerService.currentSnapshot.trackId == 'pause-live',
        );
        await _pumpEventQueue();
        if (action == 'stop') {
          await harness.player.stop();
        } else if (action == 'native pause') {
          await native.pause();
        } else {
          await harness.player.pause();
        }
        await _pumpEventQueue();
        native.completeCurrent(completionFirst: false);
        await _pumpEventQueue();

        expect(native.openedSources, hasLength(2));
        expect(
          harness.liveState.liveQueue.single.remoteTrack?.id,
          'pause-live',
        );
        expect(harness.player.isLiveQueueActive, isTrue);
        expect(
          harness.container
              .read(playerControllerProvider)
              .requireValue
              .wantsToPlay,
          isFalse,
        );
      },
    );
  }

  for (final saveToLibrary in [false, true]) {
    final mode = saveToLibrary ? 'downloaded' : 'remote';
    test(
      '$mode inactive revoke prevents an identical fresh request inheriting the removed seek position',
      () async {
        final harness = _RealLiveHarness(saveToLibrary: saveToLibrary);
        addTearDown(harness.dispose);
        await harness.initialize();
        harness.service.emit(_playEvent('consumed'));
        harness.service.emit(_playEvent('duplicate'));
        await _waitUntil(
          () =>
              harness.liveState.liveQueue.length == 2 &&
              harness.liveState.liveQueue.every((item) => item.isReady) &&
              harness.queue.entries.length == 2,
        );
        await harness.player.playNext();
        await harness.player.seek(const Duration(seconds: 19));
        await harness.player.playRemote(_remoteTrack('manual-normal'));
        await harness.live.revokeLastLiveQueueItem();
        expect(harness.liveState.liveQueue, hasLength(1));
        expect(harness.backend.currentSnapshot.trackId, 'manual-normal');

        harness.service.emit(_playEvent('duplicate'));
        await _waitUntil(
          () =>
              harness.player.isLiveQueueActive &&
              harness.liveState.liveQueue.length == 2 &&
              harness.liveState.liveQueue.every((item) => item.isReady) &&
              harness.backend.currentSnapshot.trackId == 'duplicate',
        );
        await _pumpEventQueue();
        expect(harness.queue.currentIndex, 1);
        expect(harness.backend.currentSnapshot.position, Duration.zero);
        expect(harness.backend.currentSnapshot.status, PlayerStatus.playing);
      },
    );

    test(
      '$mode LIVE resumes its interrupted cursor on !play and returns to the new normal queue',
      () async {
        final harness = _RealLiveHarness(saveToLibrary: saveToLibrary);
        addTearDown(harness.dispose);
        await harness.initialize();
        await harness.player.playRemote(_remoteTrack('original-normal'));
        await harness.player.seek(const Duration(seconds: 42));

        harness.service.emit(_playEvent('live-a'));
        harness.service.emit(_playEvent('live-b'));
        await _waitUntil(
          () =>
              harness.liveState.liveQueue.length == 2 &&
              harness.liveState.liveQueue.every((item) => item.isReady) &&
              harness.queue.entries.length == 2,
        );
        await harness.player.playNext();
        await harness.player.seek(const Duration(seconds: 19));
        expect(harness.backend.currentSnapshot.trackId, 'live-b');

        // The same video in an unrelated normal queue must not be mistaken
        // for the LIVE source just because its metadata matches a request.
        final replacement = [
          _remoteTrack('replacement-first'),
          _remoteTrack('live-b'),
          _remoteTrack('replacement-last'),
        ];
        await harness.player.playRemote(
          replacement[1],
          queue: replacement,
          queueSourceId: 'replacement-normal',
        );
        await harness.player.seek(const Duration(seconds: 8));
        expect(harness.player.isLiveQueueActive, isFalse);
        expect(harness.liveState.liveQueue, hasLength(2));

        harness.service.emit(_playEvent('live-c'));
        await _waitUntil(
          () =>
              harness.player.isLiveQueueActive &&
              harness.queue.entries.length == 3 &&
              harness.backend.currentSnapshot.trackId == 'live-b' &&
              harness.backend.currentSnapshot.position ==
                  const Duration(seconds: 19),
        );
        expect(harness.queue.currentIndex, 1);
        expect(harness.queue.entries.map((item) => item.id), [
          'live-a',
          'live-b',
          'live-c',
        ]);
        expect(harness.backend.currentSnapshot.status, PlayerStatus.playing);

        harness.backend.completeCurrent();
        await _waitUntil(
          () => harness.backend.currentSnapshot.trackId == 'live-c',
        );
        harness.backend.completeCurrent();
        await _waitUntil(() => !harness.player.isLiveQueueActive);
        await harness.player.waitForLiveQueueRestoration();
        expect(harness.liveState.liveQueue, isEmpty);
        expect(harness.backend.currentSnapshot.trackId, 'live-b');
        expect(
          harness.backend.currentSnapshot.position,
          const Duration(seconds: 8),
        );
        expect(harness.backend.currentSnapshot.status, PlayerStatus.playing);
        expect(harness.queue.currentIndex, 1);
        expect(
          harness.queue.entries.map((item) => item.id),
          replacement.map((track) => track.id),
        );
        expect(
          harness.backend.playedRemoteIds.where(
            (id) => id == 'original-normal',
          ),
          hasLength(1),
        );
      },
    );
  }

  test(
    'LIVE completion actively resumes a previously paused normal song',
    () async {
      final harness = _RealLiveHarness();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.player.playRemote(_remoteTrack('paused-normal'));
      await harness.player.seek(const Duration(seconds: 31));
      await harness.player.pause();
      harness.service.emit(_playEvent('live-a'));
      await _waitUntil(
        () => harness.backend.currentSnapshot.trackId == 'live-a',
      );
      harness.backend.completeCurrent();
      await _waitUntil(() => !harness.player.isLiveQueueActive);
      await harness.player.waitForLiveQueueRestoration();
      expect(harness.liveState.liveQueue, isEmpty);
      expect(harness.backend.currentSnapshot.trackId, 'paused-normal');
      expect(
        harness.backend.currentSnapshot.position,
        const Duration(seconds: 31),
      );
      expect(harness.backend.currentSnapshot.status, PlayerStatus.playing);
      expect(
        harness.container
            .read(playerControllerProvider)
            .requireValue
            .wantsToPlay,
        isTrue,
      );
    },
  );

  for (final disconnect in [false, true]) {
    test(
      '${disconnect ? 'disconnect' : 'clear LIVE'} discards an inactive LIVE cursor without stopping normal playback',
      () async {
        final harness = _RealLiveHarness();
        addTearDown(harness.dispose);
        await harness.initialize();
        harness.service.emit(_playEvent('live-a'));
        await _waitUntil(
          () => harness.backend.currentSnapshot.trackId == 'live-a',
        );
        await harness.player.seek(const Duration(seconds: 19));
        await harness.player.playRemote(_remoteTrack('manual-normal'));
        await harness.player.seek(const Duration(seconds: 8));
        if (disconnect) {
          await harness.live.disconnect();
        } else {
          await harness.live.clearLiveQueue();
        }
        expect(harness.liveState.liveQueue, isEmpty);
        expect(harness.backend.currentSnapshot.trackId, 'manual-normal');
        expect(harness.backend.currentSnapshot.status, PlayerStatus.playing);
        expect(
          harness.backend.currentSnapshot.position,
          const Duration(seconds: 8),
        );

        harness.service.emit(_playEvent('live-a'));
        await _waitUntil(
          () =>
              harness.player.isLiveQueueActive &&
              harness.liveState.liveQueue.singleOrNull?.isReady == true &&
              harness.backend.currentSnapshot.trackId == 'live-a',
        );
        expect(harness.backend.currentSnapshot.position, Duration.zero);
      },
    );
  }

  test(
    'a LIVE request resolved during real restoration waits and preserves the original return queue',
    () async {
      SharedPreferences.setMockInitialValues({});
      final liveService = _FakeTikTokLiveCommandService();
      final playerService = _LiveAppendPlayerService();
      final resolver = _LiveAppendAudioResolver(
        source: AudioStreamSource.innerTube,
        succeeds: (_, _) => true,
      );
      final repository = _SearchMusicRepository(
        (query) async => [_remoteTrack(query)],
      );
      final container = ProviderContainer(
        overrides: [
          tiktokLiveCommandServiceProvider.overrideWithValue(liveService),
          searchTracksProvider.overrideWithValue(SearchTracks(repository)),
          playerServiceProvider.overrideWithValue(playerService),
          audioStreamResolverProvider.overrideWithValue(resolver),
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
      final restorationGate = Completer<void>();
      addTearDown(() async {
        if (!restorationGate.isCompleted) restorationGate.complete();
        container.dispose();
        await liveService.close();
        await playerService.close();
      });
      await container.read(playerControllerProvider.future);
      await container.read(tiktokLiveControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      final normal = [_remoteTrack('normal-a'), _remoteTrack('normal-b')];
      await controller.playRemote(normal.first, queue: normal);
      await controller.seek(const Duration(seconds: 42));
      liveService.emit(_playEvent('live-a'));
      await _waitUntil(() => playerService.currentSnapshot.trackId == 'live-a');
      playerService.remotePlayGates['normal-a'] = restorationGate.future;

      playerService.completeCurrent();
      await _waitUntil(
        () =>
            !controller.isLiveQueueActive &&
            container
                .read(tiktokLiveControllerProvider)
                .requireValue
                .liveQueue
                .isEmpty &&
            !playerService.remotePlayGates.containsKey('normal-a'),
      );
      liveService.emit(_playEvent('live-b'));
      await _waitUntil(
        () =>
            container
                .read(tiktokLiveControllerProvider)
                .requireValue
                .liveQueue
                .singleOrNull
                ?.isReady ==
            true,
      );
      await _pumpEventQueue();
      expect(playerService.playedRemoteIds, ['normal-a', 'live-a']);
      expect(controller.isLiveQueueActive, isFalse);

      restorationGate.complete();
      await _waitUntil(() => playerService.currentSnapshot.trackId == 'live-b');
      expect(playerService.playedRemoteIds, [
        'normal-a',
        'live-a',
        'normal-a',
        'live-b',
      ]);
      expect(
        container
            .read(tiktokLiveControllerProvider)
            .requireValue
            .liveQueue
            .single
            .remoteTrack
            ?.id,
        'live-b',
      );

      playerService.completeCurrent();
      await _waitUntil(
        () =>
            !controller.isLiveQueueActive &&
            playerService.currentSnapshot.trackId == 'normal-a',
      );
      await controller.waitForLiveQueueRestoration();
      expect(
        playerService.currentSnapshot.position,
        const Duration(seconds: 42),
      );
      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        normal.map((track) => track.id),
      );
      expect(
        container.read(tiktokLiveControllerProvider).requireValue.liveQueue,
        isEmpty,
      );
    },
  );

  test(
    'a terminally failed LIVE batch is cleared before a later request starts',
    () async {
      SharedPreferences.setMockInitialValues({});
      final liveService = _FakeTikTokLiveCommandService();
      final playerService = _LiveAppendPlayerService();
      final playerController = _TrackingLivePlayerController();
      final primary = _LiveAppendAudioResolver(
        source: AudioStreamSource.innerTube,
        succeeds: (trackId, call) =>
            trackId == 'live-a' ? call == 1 : trackId == 'live-b',
      );
      final fallback = _LiveAppendAudioResolver(
        source: AudioStreamSource.innerTubeFallback,
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
            primary.callsFor('live-a') == 3 &&
            fallback.callsFor('live-a') == 3 &&
            container
                .read(tiktokLiveControllerProvider)
                .requireValue
                .liveQueue
                .isEmpty &&
            !playerController.isLiveQueueActive,
      );

      expect(playerController.publicRemoteStarts, ['live-a']);
      expect(playerService.playedRemoteIds, ['live-a']);
      expect(retryDurations, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]);

      liveService.emit(_playEvent('live-b'));
      await _waitUntil(() => playerService.playedRemoteIds.length == 2);

      final live = container.read(tiktokLiveControllerProvider).requireValue;
      expect(live.liveQueue, hasLength(1));
      expect(live.liveQueue.every((item) => item.isReady), isTrue);
      expect(live.liveQueue.single.remoteTrack?.id, 'live-b');
      expect(playerController.publicRemoteStarts, ['live-a', 'live-b']);
      expect(playerController.remoteQueueSyncCalls, 0);
      expect(primary.callsFor('live-a'), 3);
      expect(fallback.callsFor('live-a'), 3);
      expect(primary.callsFor('live-b'), 1);
      expect(fallback.callsFor('live-b'), 0);
      expect(playerService.playedRemoteIds, ['live-a', 'live-b']);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
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

TikTokLiveEvent _commandEvent(String action, String text) {
  return TikTokLiveEvent(
    type: 'command',
    command: TikTokLiveChatCommand(action: action, user: 'viewer', text: text),
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

class _RealLiveHarness {
  _RealLiveHarness({bool saveToLibrary = false, PlayerService? playerService}) {
    SharedPreferences.setMockInitialValues({
      'tiktokLive.saveRequestsToLibrary': saveToLibrary,
    });
    final repository = _SearchMusicRepository(
      (query) async => [_remoteTrack(query)],
    );
    container = ProviderContainer(
      overrides: [
        tiktokLiveCommandServiceProvider.overrideWithValue(service),
        searchTracksProvider.overrideWithValue(SearchTracks(repository)),
        playerServiceProvider.overrideWithValue(playerService ?? backend),
        audioStreamResolverProvider.overrideWithValue(
          _LiveAppendAudioResolver(
            source: AudioStreamSource.innerTube,
            succeeds: (_, _) => true,
          ),
        ),
        remotePlaybackCacheProvider.overrideWithValue(
          RemotePlaybackCache(policy: RemotePlaybackCachePolicy.disabled),
        ),
        settingsControllerProvider.overrideWith(
          _LiveAppendSettingsController.new,
        ),
        playbackHistorySinkProvider.overrideWithValue(
          const _NoopPlaybackHistorySink(),
        ),
        localTrackFileProbeProvider.overrideWithValue(
          (_) async => LocalTrackFileAvailability.present,
        ),
        localTrackDownloadHelperProvider.overrideWith(
          (ref) => _CountingLocalTrackDownloadHelper(
            ref,
            download: (track) async => LocalTrackDownloadResult(
              track: LocalTrack(
                id: track.id,
                title: track.title,
                artist: track.artist,
                filePath: 'C:/bstream-live-test/${track.id}.m4a',
                addedAt: DateTime(2026),
                sourceUrl: track.url,
                duration: track.duration,
              ),
              remoteTrack: track,
              reusedExisting: false,
            ),
          ),
        ),
      ],
    );
  }

  final service = _FakeTikTokLiveCommandService();
  final backend = _LiveAppendPlayerService();
  late final ProviderContainer container;

  PlayerController get player =>
      container.read(playerControllerProvider.notifier);
  TikTokLiveController get live =>
      container.read(tiktokLiveControllerProvider.notifier);
  TikTokLiveState get liveState =>
      container.read(tiktokLiveControllerProvider).requireValue;
  PlaybackQueueState get queue => container.read(playbackQueueProvider);

  Future<void> initialize() async {
    await container.read(playerControllerProvider.future);
    await container.read(tiktokLiveControllerProvider.future);
  }

  Future<void> dispose() async {
    container.dispose();
    await service.close();
    await backend.close();
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

  @override
  Future<void> disconnect() async {}

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
  int pauseCalls = 0;
  int stopCalls = 0;
  int clearQueueSourceCalls = 0;
  bool _liveQueueActive = false;
  final _liveCompletionListeners = <void Function()>[];
  Completer<void>? _liveRestoration;

  @override
  void addLiveQueueCompletionListener(void Function() listener) {
    _liveCompletionListeners.add(listener);
  }

  @override
  void removeLiveQueueCompletionListener(void Function() listener) {
    _liveCompletionListeners.remove(listener);
  }

  @override
  Future<void> waitForLiveQueueRestoration() =>
      _liveRestoration?.future ?? Future<void>.value();

  void holdLiveQueueSynchronization() {
    _liveRestoration ??= Completer<void>();
  }

  void beginLiveRestoration() {
    holdLiveQueueSynchronization();
    _liveQueueActive = false;
    for (final listener in List.of(_liveCompletionListeners)) {
      listener();
    }
  }

  void finishLiveRestoration() {
    _liveRestoration?.complete();
    _liveRestoration = null;
  }

  void completeLivePlayback() {
    beginLiveRestoration();
    finishLiveRestoration();
  }

  @override
  bool get isLiveQueueActive => _liveQueueActive;

  @override
  Future<PlayerSnapshot> build() async {
    return const PlayerSnapshot(status: PlayerStatus.idle);
  }

  @override
  Future<void> resumeRemoteLiveQueue(List<TrackInfo> tracks) => playRemote(
    tracks.first,
    queue: tracks,
    queueSourceId: PlayerController.liveQueueSourceId,
  );

  @override
  Future<void> resumeLocalLiveQueue(List<LocalTrack> tracks) => playLocal(
    tracks.first,
    queue: tracks,
    useNativeQueue: false,
    queueSourceId: PlayerController.liveQueueSourceId,
  );

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
    if (queueSourceId == PlayerController.liveQueueSourceId) {
      _liveQueueActive = true;
    }
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
    if (sourceId == PlayerController.liveQueueSourceId) {
      _liveQueueActive = true;
    }
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
    if (queueSourceId == PlayerController.liveQueueSourceId) {
      _liveQueueActive = true;
    }
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

  @override
  Future<void> pause() async {
    pauseCalls++;
    final snapshot = state.value;
    if (snapshot != null) {
      state = AsyncData(snapshot.copyWith(status: PlayerStatus.paused));
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _liveQueueActive = false;
    final snapshot = state.value;
    if (snapshot != null) {
      state = AsyncData(snapshot.copyWith(status: PlayerStatus.stopped));
    }
  }

  @override
  Future<bool> clearQueueSource(String sourceId) async {
    clearQueueSourceCalls++;
    if (sourceId == PlayerController.liveQueueSourceId) {
      _liveQueueActive = false;
    }
    return true;
  }

  void simulateRemoteTrack(TrackInfo track) {
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
}

class _TrackingLivePlayerController extends PlayerController {
  final List<String> publicRemoteStarts = [];
  int remoteQueueSyncCalls = 0;

  @override
  Future<void> resumeRemoteLiveQueue(List<TrackInfo> tracks) {
    publicRemoteStarts.add(tracks.first.id);
    return super.resumeRemoteLiveQueue(tracks);
  }

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

/// Emits the two independent native EOF streams instead of manufacturing a
/// PlayerSnapshot.completed. This exercises the real desktop adapter and the
/// controller/TikTok cleanup together, including either stream delivery order.
class _LiveMediaKitBackend implements MediaKitPlayerBackend {
  final _positions = StreamController<Duration>.broadcast();
  final _durations = StreamController<Duration>.broadcast();
  final _volumes = StreamController<double>.broadcast();
  final _bufferings = StreamController<bool>.broadcast();
  final _playings = StreamController<bool>.broadcast();
  final _completions = StreamController<bool>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final List<String> openedSources = [];

  @override
  bool completed = false;

  void completeCurrent({required bool completionFirst}) {
    // media_kit updates Player.state before forwarding either independent
    // stream event. A playing=false EOF must not masquerade as a user pause.
    completed = true;
    if (completionFirst) {
      _completions.add(true);
      _playings.add(false);
    } else {
      _playings.add(false);
      _completions.add(true);
    }
  }

  @override
  Stream<Duration> get positionStream => _positions.stream;
  @override
  Stream<Duration> get durationStream => _durations.stream;
  @override
  Stream<double> get volumeStream => _volumes.stream;
  @override
  Stream<bool> get bufferingStream => _bufferings.stream;
  @override
  Stream<bool> get playingStream => _playings.stream;
  @override
  Stream<bool> get completedStream => _completions.stream;
  @override
  Stream<String> get errorStream => _errors.stream;
  @override
  Object? get platform => null;

  @override
  void abandonPendingOperations() {}

  @override
  Future<void> open(Media media, {required bool play}) async {
    completed = false;
    openedSources.add(media.uri);
  }

  @override
  Future<void> pause() async => _playings.add(false);
  @override
  Future<void> play() async => _playings.add(true);
  @override
  Future<void> stop() async => _playings.add(false);
  @override
  Future<void> seek(Duration position) async {
    completed = false;
    _positions.add(position);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> dispose() async {
    await Future.wait<void>([
      _positions.close(),
      _durations.close(),
      _volumes.close(),
      _bufferings.close(),
      _playings.close(),
      _completions.close(),
      _errors.close(),
    ]);
  }
}

class _LiveAppendPlayerService extends PlayerService {
  final _snapshots = StreamController<PlayerSnapshot>.broadcast();
  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  final List<String> playedRemoteIds = [];
  final Map<String, Future<void>> remotePlayGates = {};

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshots.stream;

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  bool get supportsLocalQueueReplacement => false;

  @override
  Future<void> playRemote(TrackInfo track) async {
    final gate = remotePlayGates.remove(track.id);
    if (gate != null) await gate;
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

  void completeCurrent() {
    _snapshot = _snapshot.copyWith(
      status: PlayerStatus.completed,
      position: _snapshot.duration ?? _snapshot.position,
    );
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    _snapshot = PlayerSnapshot(
      status: PlayerStatus.playing,
      title: track.title,
      artist: track.artist,
      trackId: track.id,
      sourceUrl: track.filePath,
      duration: track.duration,
    );
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) async {
    await playLocal(tracks[initialIndex]);
  }

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {}

  @override
  Future<void> pause() async {
    _snapshot = _snapshot.copyWith(status: PlayerStatus.paused);
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> resume() async {
    _snapshot = _snapshot.copyWith(status: PlayerStatus.playing);
    _snapshots.add(_snapshot);
  }

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
    _snapshots.add(_snapshot);
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
