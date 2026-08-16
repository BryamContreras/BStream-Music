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
  test(
    'resolves a LIVE burst with bounded concurrency and keeps playback FIFO',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LoadHarness();
      addTearDown(harness.dispose);
      await harness.initialize();

      for (var index = 0; index < 12; index++) {
        harness.service.emit(
          _playEvent('Pedido $index', viewer: 'viewer$index'),
        );
      }

      await _pumpUntil(
        () =>
            harness.repository.startedQueries.length ==
            TikTokLiveController.maxConcurrentResolutions,
      );
      expect(harness.repository.startedQueries, const [
        'Pedido 0',
        'Pedido 1',
        'Pedido 2',
      ]);
      expect(
        harness.repository.maxActiveSearches,
        TikTokLiveController.maxConcurrentResolutions,
      );

      // Finish the first window in reverse order. A fast later lookup must not
      // jump ahead of the oldest request when automatic playback starts.
      harness.repository.complete('Pedido 2');
      await _pumpUntil(
        () => harness.repository.startedQueries.contains('Pedido 3'),
      );
      expect(harness.player.remotePlayCalls, 0);

      harness.repository.complete('Pedido 1');
      await _pumpUntil(
        () => harness.repository.startedQueries.contains('Pedido 4'),
      );
      expect(harness.player.remotePlayCalls, 0);

      harness.repository.complete('Pedido 0');
      await _pumpUntil(() => harness.player.remotePlayCalls == 1);
      expect(harness.player.firstRemoteTrack?.id, 'track-0');

      // Keep completing every active search in reverse order. This exercises
      // multiple scheduler windows without real network delays or wall clocks.
      while (harness.repository.completedQueries.length < 12) {
        final pending = harness.repository.pendingQueries.toList().reversed;
        expect(pending, isNotEmpty);
        final startedBefore = harness.repository.startedQueries.length;
        for (final query in pending) {
          harness.repository.complete(query);
        }
        await _pumpUntil(
          () =>
              harness.repository.completedQueries.length == 12 ||
              harness.repository.startedQueries.length > startedBefore,
        );
      }

      await _pumpUntil(
        () => harness.liveState.liveQueue.every((item) => item.isReady),
      );

      expect(harness.repository.startedQueries, [
        for (var index = 0; index < 12; index++) 'Pedido $index',
      ]);
      expect(
        harness.repository.maxActiveSearches,
        TikTokLiveController.maxConcurrentResolutions,
      );
      expect(harness.liveState.commandsHandled, 12);
      expect(harness.liveState.liveQueue, hasLength(12));
      expect(harness.liveState.readyRemoteTracks.map((track) => track.id), [
        for (var index = 0; index < 12; index++) 'track-$index',
      ]);
      expect(harness.player.remotePlayCalls, 1);
      expect(harness.player.lastRemoteQueue?.map((track) => track.id), [
        for (var index = 0; index < 12; index++) 'track-$index',
      ]);
    },
  );

  test(
    'clear cancels every active lookup and drops the remaining burst',
    () async {
      SharedPreferences.setMockInitialValues({});
      final harness = _LoadHarness();
      addTearDown(harness.dispose);
      await harness.initialize();

      for (var index = 0; index < 12; index++) {
        harness.service.emit(
          _playEvent('Pedido $index', viewer: 'viewer$index'),
        );
      }
      await _pumpUntil(
        () =>
            harness.repository.startedQueries.length ==
            TikTokLiveController.maxConcurrentResolutions,
      );

      await harness.controller.clearLiveQueue();
      for (final query in harness.repository.pendingQueries.toList()) {
        harness.repository.complete(query);
      }
      await _pumpEvents();

      expect(harness.liveState.liveQueue, isEmpty);
      expect(
        harness.repository.startedQueries,
        hasLength(TikTokLiveController.maxConcurrentResolutions),
      );
      expect(harness.player.remotePlayCalls, 0);
      expect(harness.player.lastRemoteQueue, isNull);
    },
  );
}

TikTokLiveEvent _playEvent(String query, {required String viewer}) {
  return TikTokLiveEvent(
    type: 'command',
    command: TikTokLiveChatCommand(
      action: 'play',
      query: query,
      user: viewer,
      text: '!play $query',
    ),
  );
}

Future<void> _pumpUntil(
  bool Function() condition, {
  int maximumPumps = 200,
}) async {
  for (var pump = 0; pump < maximumPumps; pump++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition was not reached after $maximumPumps event-loop pumps.');
}

Future<void> _pumpEvents([int pumps = 20]) async {
  for (var pump = 0; pump < pumps; pump++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _LoadHarness {
  _LoadHarness()
    : repository = _ControlledSearchRepository(),
      service = _FakeTikTokLiveCommandService(),
      player = _RecordingPlayerController() {
    container = ProviderContainer(
      overrides: [
        tiktokLiveCommandServiceProvider.overrideWithValue(service),
        searchTracksProvider.overrideWithValue(SearchTracks(repository)),
        playerControllerProvider.overrideWith(() => player),
      ],
    );
  }

  final _ControlledSearchRepository repository;
  final _FakeTikTokLiveCommandService service;
  final _RecordingPlayerController player;
  late final ProviderContainer container;

  TikTokLiveController get controller =>
      container.read(tiktokLiveControllerProvider.notifier);

  TikTokLiveState get liveState =>
      container.read(tiktokLiveControllerProvider).requireValue;

  Future<void> initialize() async {
    await container.read(playerControllerProvider.future);
    await container.read(tiktokLiveControllerProvider.future);
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

class _ControlledSearchRepository implements MusicRepository {
  final _completers = <String, Completer<List<TrackInfo>>>{};
  final startedQueries = <String>[];
  final completedQueries = <String>{};
  int activeSearches = 0;
  int maxActiveSearches = 0;

  Iterable<String> get pendingQueries =>
      startedQueries.where((query) => !completedQueries.contains(query));

  @override
  Future<List<TrackInfo>> search(String query) {
    final completer = Completer<List<TrackInfo>>();
    expect(_completers.containsKey(query), isFalse);
    _completers[query] = completer;
    startedQueries.add(query);
    activeSearches++;
    if (activeSearches > maxActiveSearches) {
      maxActiveSearches = activeSearches;
    }
    return completer.future.whenComplete(() => activeSearches--);
  }

  void complete(String query) {
    final completer = _completers[query];
    if (completer == null || completer.isCompleted) {
      return;
    }
    final index = int.parse(query.substring('Pedido '.length));
    completedQueries.add(query);
    completer.complete([
      TrackInfo(
        id: 'track-$index',
        title: query,
        artist: 'Viewer $index',
        url: 'https://www.youtube.com/watch?v=track$index',
        duration: const Duration(minutes: 3),
      ),
    ]);
  }

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) =>
      throw UnsupportedError('Downloads are not used by this load harness.');

  @override
  Future<TrackInfo> getInfo(String url) =>
      throw UnsupportedError('Track info is not used by this load harness.');

  @override
  Future<TrackInfo> getPlaybackInfo(String url) =>
      throw UnsupportedError('Playback info is not used by this load harness.');
}

class _RecordingPlayerController extends PlayerController {
  int remotePlayCalls = 0;
  TrackInfo? firstRemoteTrack;
  List<TrackInfo>? lastRemoteQueue;

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
    firstRemoteTrack ??= track;
    lastRemoteQueue = queue == null ? null : List.unmodifiable(queue);
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
    lastRemoteQueue = List.unmodifiable(tracks);
    return true;
  }

  @override
  Future<void> playLocal(
    LocalTrack track, {
    List<LocalTrack>? queue,
    bool useNativeQueue = true,
    String? queueSourceId,
  }) {
    throw UnsupportedError('Local playback is not used by this load harness.');
  }
}
