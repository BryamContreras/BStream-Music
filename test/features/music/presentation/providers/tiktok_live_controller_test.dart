import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/domain/usecases/search_tracks.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
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
    expect(harness.repository.searchCalls, 1);

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
  }) : repository = _SearchMusicRepository(search),
       service = _FakeTikTokLiveCommandService(),
       player = _RecordingPlayerController() {
    container = ProviderContainer(
      overrides: [
        tiktokLiveCommandServiceProvider.overrideWithValue(service),
        searchTracksProvider.overrideWithValue(SearchTracks(repository)),
        localTrackDownloadHelperProvider.overrideWith(
          (ref) =>
              _CountingLocalTrackDownloadHelper(ref, result: downloadResult),
        ),
        playerControllerProvider.overrideWith(() => player),
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
  _CountingLocalTrackDownloadHelper(super.ref, {this.result});

  final LocalTrackDownloadResult? result;
  int calls = 0;

  @override
  Future<LocalTrackDownloadResult> resolveForLibrary(
    TrackInfo track, {
    String? taskId,
    void Function(TrackInfo track)? onResolved,
    void Function()? onDownloadStarted,
  }) async {
    calls++;
    onResolved?.call(track);
    onDownloadStarted?.call();
    return result ??
        (throw StateError('Remote-only LIVE mode must not download tracks.'));
  }
}

class _RecordingPlayerController extends PlayerController {
  int remotePlayCalls = 0;
  int localPlayCalls = 0;
  TrackInfo? lastRemoteTrack;
  List<TrackInfo>? lastRemoteQueue;
  String? lastQueueSourceId;
  LocalTrack? lastLocalTrack;
  List<LocalTrack>? lastLocalQueue;
  bool? lastUseNativeQueue;
  String? lastLocalQueueSourceId;

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
