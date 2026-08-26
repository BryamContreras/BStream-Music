import 'dart:async';
import 'dart:io';

import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/downloader/fallback_audio_resolver.dart';
import 'package:bstream_music/services/media_session/desktop_media_session.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
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
    'playback option failure is non-fatal and preserves the current snapshot',
    () async {
      final player = _PlaybackOptionsFailingPlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      await container.read(playerControllerProvider.future);

      container.read(playerControllerProvider.notifier).setShuffleEnabled(true);
      await Future<void>.delayed(Duration.zero);

      final playerState = container.read(playerControllerProvider);
      expect(playerState.hasValue, isTrue);
      expect(playerState.hasError, isFalse);
      expect(playerState.value?.shuffleEnabled, isTrue);
      final failure = container.read(playerActionFailureProvider);
      expect(failure?.action, 'sync_playback_options');
      expect(failure?.error, isA<StateError>());
    },
  );

  test(
    'rapid playback option changes finish with the latest native value',
    () async {
      final player = _BlockingPlaybackOptionsPlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);

      controller.setShuffleEnabled(true);
      await player.firstShuffleRequest;
      controller.setShuffleEnabled(false);
      await _flushCompletion();

      expect(player.shuffleValues, isEmpty);
      player.releaseFirstShuffleRequest();
      await _waitUntil(
        () => player.shuffleValues.isNotEmpty && !player.shuffleValues.last,
      );

      expect(player.shuffleValues, [true, false]);
      expect(player.repeatModes.last, PlaybackRepeatMode.off);
      expect(
        container.read(playerControllerProvider).requireValue.shuffleEnabled,
        isFalse,
      );
    },
  );

  test(
    'a controller-managed mixed queue keeps native shuffle and repeat disabled',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      controller.setShuffleEnabled(true);
      controller.setRepeatMode(PlaybackRepeatMode.all);
      await _waitUntil(
        () =>
            player.shuffleValues.isNotEmpty &&
            player.shuffleValues.last &&
            player.repeatModes.isNotEmpty &&
            player.repeatModes.last == PlaybackRepeatMode.all,
      );

      final local = _track(1);
      final remote = _queuedRemoteTrack('mixed-option-remote');
      await controller.playRecommendation(
        RecommendationPlaybackItem(
          track: _queuedRemoteTrack('mixed-option-local'),
          localTrack: local,
        ),
        queue: [
          RecommendationPlaybackItem(
            track: _queuedRemoteTrack('mixed-option-local'),
            localTrack: local,
          ),
          RecommendationPlaybackItem(track: remote),
        ],
        queueSourceId: 'personalized-home:mixed-options',
      );

      expect(player.shuffleValues.last, isFalse);
      expect(player.repeatModes.last, PlaybackRepeatMode.off);
      final snapshot = container.read(playerControllerProvider).requireValue;
      expect(snapshot.shuffleEnabled, isTrue);
      expect(snapshot.repeatMode, PlaybackRepeatMode.all);
    },
  );

  test(
    'a personalized mixed shelf keeps downloaded and remote recommendations in one skippable queue',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final local = _track(1);
      const localCatalog = TrackInfo(
        id: 'LocalVideo01',
        title: 'Downloaded recommendation',
        artist: 'BStream',
        url: 'https://www.youtube.com/watch?v=LocalVideo01',
      );
      final remote = _queuedRemoteTrack('NextSong001');

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRecommendation(
        RecommendationPlaybackItem(track: localCatalog, localTrack: local),
        queue: [
          RecommendationPlaybackItem(track: localCatalog, localTrack: local),
          RecommendationPlaybackItem(track: remote),
        ],
        queueSourceId: 'personalized-home:continueListening',
      );

      expect(player.playedLocalIds, ['track-1']);
      expect(
        container.read(playbackQueueProvider).entries.map((item) => item.id),
        ['track-1', 'NextSong001'],
      );

      await controller.playNext();

      expect(player.playedRemote.map((track) => track.id), ['NextSong001']);
      expect(container.read(playbackQueueProvider).currentIndex, 1);
    },
  );

  test(
    'a stale outgoing snapshot cannot cancel a manual remote Next transition',
    () async {
      final player = _StaleOutgoingRemotePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final first = _queuedRemoteTrack('stale-transition-first');
      final second = _queuedRemoteTrack('stale-transition-second');

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRecommendation(
        RecommendationPlaybackItem(track: first),
        queue: [
          RecommendationPlaybackItem(track: first),
          RecommendationPlaybackItem(track: second),
        ],
        queueSourceId: 'personalized-home:stale-transition',
      );

      final next = controller.playNext();
      await player.outgoingSnapshotEmitted;
      expect(
        container.read(playbackQueueProvider).currentIndex,
        1,
        reason: 'The outgoing stopped snapshot must not revert the queue.',
      );
      expect(
        container.read(playerControllerProvider).value?.title,
        'Track stale-transition-second',
      );
      expect(
        container.read(playerControllerProvider).value?.thumbnailUrl,
        second.thumbnailUrl,
      );

      player.releaseReplacement();
      await next;
      expect(player.playedRemote.map((track) => track.id), [
        first.id,
        second.id,
      ]);
      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(
        container.read(playerControllerProvider).value?.title,
        'Track stale-transition-second',
      );
    },
  );

  test(
    'a catalog playlist preserves entry identity and plays local then remote',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final local = _track(1);
      final firstRemote = _queuedRemoteTrack('catalog-local-source');
      final secondRemote = _queuedRemoteTrack('catalog-stream-source');
      final queue = <CatalogPlaybackItem>[
        CatalogPlaybackItem(
          entryId: 'entry-a',
          localTrack: local,
          remoteTrack: firstRemote,
        ),
        CatalogPlaybackItem(entryId: 'entry-b', remoteTrack: secondRemote),
      ];

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playCatalogPlaylist(
        queue.first,
        queue: queue,
        playlistId: 'synced-1',
      );
      await controller.playNext();

      expect(player.playedLocalIds, [local.id]);
      expect(player.playedRemote.map((track) => track.id), [secondRemote.id]);
      expect(container.read(playbackQueueProvider).currentIndex, 1);
    },
  );

  test(
    'a catalog hybrid stays local and falls back after an asynchronous local failure',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final local = _track(1);
      final remote = _queuedRemoteTrack('catalog-local-fallback');
      final item = CatalogPlaybackItem(
        entryId: 'entry-hybrid',
        localTrack: local,
        remoteTrack: remote,
      );

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playCatalogPlaylist(
            item,
            queue: <CatalogPlaybackItem>[item],
            playlistId: 'synced-hybrid',
          );

      expect(player.playedLocalIds, <String>[local.id]);
      expect(player.playedRemote, isEmpty);
      expect(container.read(playerControllerProvider).value?.isRemote, isFalse);

      player.emit(
        PlayerSnapshot(
          status: PlayerStatus.failed,
          trackId: local.id,
          sourceUrl: local.filePath,
          isRemote: false,
          errorMessage: 'Local file became unavailable.',
        ),
      );
      await _waitUntil(
        () => player.playedRemote.isNotEmpty,
        reason: 'The catalog stream fallback never started.',
      );

      expect(player.playedRemote.map((track) => track.id), <String>[remote.id]);
      expect(container.read(playerControllerProvider).value?.isRemote, isTrue);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
    },
  );

  test(
    'a hybrid remembers a failed snapshot until its local play Future completes',
    () async {
      final player = _DelayedLocalPlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final local = _track(1);
      final remote = _queuedRemoteTrack('catalog-blocked-local-fallback');
      final item = CatalogPlaybackItem(
        entryId: 'entry-blocked-hybrid',
        localTrack: local,
        remoteTrack: remote,
      );

      await container.read(playerControllerProvider.future);
      final play = container
          .read(playerControllerProvider.notifier)
          .playCatalogPlaylist(
            item,
            queue: <CatalogPlaybackItem>[item],
            playlistId: 'synced-blocked-hybrid',
          );
      await _waitUntil(() => player.started.contains(local.id));

      player.emit(
        PlayerSnapshot(
          status: PlayerStatus.failed,
          trackId: local.id,
          sourceUrl: local.filePath,
          isRemote: false,
          errorMessage: 'The local backend rejected the file.',
        ),
      );
      player.complete(local.id);
      await play;
      await _waitUntil(
        () => player.playedRemote.isNotEmpty,
        reason: 'The deferred catalog stream fallback never started.',
      );

      expect(player.playedRemote.map((track) => track.id), <String>[remote.id]);
      expect(container.read(playerControllerProvider).value?.isRemote, isTrue);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
    },
  );

  test(
    'repeated Next taps coalesce while a remote recommendation is loading',
    () async {
      final player = _BlockingRemotePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final tracks = [
        _queuedRemoteTrack('recommendation-first'),
        _queuedRemoteTrack('recommendation-second'),
        _queuedRemoteTrack('recommendation-third'),
      ];

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRecommendation(
        RecommendationPlaybackItem(track: tracks.first),
        queue: tracks
            .map((track) => RecommendationPlaybackItem(track: track))
            .toList(growable: false),
        queueSourceId: 'personalized-home:becauseYouListened',
      );
      player.block('recommendation-second');

      final firstTap = controller.playNext();
      await _waitUntil(
        () => player.startedRemoteIds.contains('recommendation-second'),
      );
      final repeatedTap = controller.playNext();
      await _flushCompletion();

      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(
        container.read(playerControllerProvider).value?.title,
        'Track recommendation-second',
      );
      expect(player.startedRemoteIds, isNot(contains('recommendation-third')));

      player.release('recommendation-second');
      await Future.wait([firstTap, repeatedTap]);

      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(player.playedRemote.map((track) => track.id), [
        'recommendation-first',
        'recommendation-second',
      ]);
    },
  );

  test(
    'personalized queue grows in the background before reaching its end',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final tracks = [
        for (var index = 0; index < 7; index++)
          _queuedRemoteTrack('because-$index'),
      ];
      final expanded = [
        ...tracks,
        _queuedRemoteTrack('because-7'),
        _queuedRemoteTrack('because-8'),
      ];
      var extensionCalls = 0;

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRecommendation(
            RecommendationPlaybackItem(track: tracks[3]),
            queue: tracks
                .map((track) => RecommendationPlaybackItem(track: track))
                .toList(growable: false),
            queueSourceId: 'personalized-home:becauseYouListened',
            queueExtender: () async {
              extensionCalls++;
              return expanded
                  .map((track) => RecommendationPlaybackItem(track: track))
                  .toList(growable: false);
            },
          );
      await _waitUntil(
        () => container.read(playbackQueueProvider).entries.length == 9,
      );

      expect(extensionCalls, 1);
      expect(container.read(playbackQueueProvider).currentIndex, 3);
      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        expanded.map((track) => track.id),
      );
      expect(player.playedRemote.map((track) => track.id), ['because-3']);
    },
  );

  test(
    'Next at the end waits for personalized growth instead of wrapping',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final seed = _queuedRemoteTrack('end-seed');
      final next = _queuedRemoteTrack('end-next');
      final extension = Completer<List<RecommendationPlaybackItem>>();
      var extensionCalls = 0;

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRecommendation(
        RecommendationPlaybackItem(track: seed),
        queue: [RecommendationPlaybackItem(track: seed)],
        queueSourceId: 'personalized-home:becauseYouListened',
        queueExtender: () {
          extensionCalls++;
          return extension.future;
        },
      );
      await _waitUntil(() => extensionCalls == 1);

      final skip = controller.playNext();
      await _flushCompletion();
      expect(container.read(playbackQueueProvider).currentIndex, 0);

      extension.complete([
        RecommendationPlaybackItem(track: seed),
        RecommendationPlaybackItem(track: next),
      ]);
      await skip;

      expect(
        extensionCalls,
        2,
        reason:
            'The in-flight page is shared by Next; a second sequential request '
            'is allowed only after playback reaches the newly appended end.',
      );
      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(player.playedRemote.map((track) => track.id), [
        'end-seed',
        'end-next',
      ]);
    },
  );

  test(
    'a late recommendation page cannot replace a newer queue with the same source id',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final oldSeed = _queuedRemoteTrack('old-seed');
      final oldRelated = _queuedRemoteTrack('old-related');
      final replacement = _queuedRemoteTrack('new-seed');
      final extension = Completer<List<RecommendationPlaybackItem>>();
      var extensionStarted = false;

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRecommendation(
        RecommendationPlaybackItem(track: oldSeed),
        queue: [RecommendationPlaybackItem(track: oldSeed)],
        queueSourceId: 'personalized-home:becauseYouListened',
        queueExtender: () {
          extensionStarted = true;
          return extension.future;
        },
      );
      await _waitUntil(() => extensionStarted);

      await controller.playRecommendation(
        RecommendationPlaybackItem(track: replacement),
        queue: [RecommendationPlaybackItem(track: replacement)],
        queueSourceId: 'personalized-home:becauseYouListened',
      );
      extension.complete([
        RecommendationPlaybackItem(track: oldSeed),
        RecommendationPlaybackItem(track: oldRelated),
      ]);
      await _flushCompletion();

      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['new-seed'],
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(
        container.read(playerControllerProvider).value?.trackId,
        'new-seed',
      );
    },
  );

  test(
    'a Next suspended at the end cannot advance a replacement recommendation queue',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final oldSeed = _queuedRemoteTrack('pending-old-seed');
      final oldRelated = _queuedRemoteTrack('pending-old-related');
      final newSeed = _queuedRemoteTrack('pending-new-seed');
      final newNext = _queuedRemoteTrack('pending-new-next');
      final extension = Completer<List<RecommendationPlaybackItem>>();
      var extensionStarted = false;

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRecommendation(
        RecommendationPlaybackItem(track: oldSeed),
        queue: [RecommendationPlaybackItem(track: oldSeed)],
        queueSourceId: 'personalized-home:becauseYouListened',
        queueExtender: () {
          extensionStarted = true;
          return extension.future;
        },
      );
      await _waitUntil(() => extensionStarted);
      final suspendedNext = controller.playNext();
      await _flushCompletion();

      await controller.playRecommendation(
        RecommendationPlaybackItem(track: newSeed),
        queue: [
          RecommendationPlaybackItem(track: newSeed),
          RecommendationPlaybackItem(track: newNext),
        ],
        queueSourceId: 'personalized-home:becauseYouListened',
      );
      extension.complete([
        RecommendationPlaybackItem(track: oldSeed),
        RecommendationPlaybackItem(track: oldRelated),
      ]);
      await suspendedNext;

      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['pending-new-seed', 'pending-new-next'],
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(player.playedRemote.map((track) => track.id), [
        'pending-old-seed',
        'pending-new-seed',
      ]);
    },
  );

  for (final automatic in [false, true]) {
    test(
      'shuffle ${automatic ? 'automatic' : 'manual'} Next waits for an in-flight related page at the end',
      () async {
        final player = _FakePlayerService();
        final container = _container(player);
        addTearDown(container.dispose);
        final first = _queuedRemoteTrack(
          'shuffle-${automatic ? 'auto' : 'manual'}-first',
        );
        final second = _queuedRemoteTrack(
          'shuffle-${automatic ? 'auto' : 'manual'}-second',
        );
        final appended = _queuedRemoteTrack(
          'shuffle-${automatic ? 'auto' : 'manual'}-appended',
        );
        final extension = Completer<List<RecommendationPlaybackItem>>();
        var extensionStarted = false;

        await container.read(playerControllerProvider.future);
        final controller = container.read(playerControllerProvider.notifier)
          ..setShuffleEnabled(true);
        await controller.playRecommendation(
          RecommendationPlaybackItem(track: first),
          queue: [
            RecommendationPlaybackItem(track: first),
            RecommendationPlaybackItem(track: second),
          ],
          queueSourceId: 'personalized-home:becauseYouListened',
          queueExtender: () {
            extensionStarted = true;
            return extension.future;
          },
        );
        await _waitUntil(() => extensionStarted);
        await controller.playNext();
        expect(container.read(playbackQueueProvider).currentIndex, 1);

        final endTransition = controller.playNext(automatic: automatic);
        await _flushCompletion();
        expect(container.read(playbackQueueProvider).currentIndex, 1);

        extension.complete([
          RecommendationPlaybackItem(track: first),
          RecommendationPlaybackItem(track: second),
          RecommendationPlaybackItem(track: appended),
        ]);
        await endTransition;

        expect(container.read(playbackQueueProvider).currentIndex, 2);
        expect(player.playedRemote.last.id, appended.id);
      },
    );
  }

  for (final automatic in [false, true]) {
    test(
      'failed related growth keeps shuffle repeat-off ${automatic ? 'automatic stop' : 'manual wrap'} behavior',
      () async {
        final player = _FakePlayerService();
        final container = _container(player);
        addTearDown(container.dispose);
        final seed = _queuedRemoteTrack(
          'failed-growth-${automatic ? 'auto' : 'manual'}',
        );
        var extensionCalls = 0;

        await container.read(playerControllerProvider.future);
        final controller = container.read(playerControllerProvider.notifier)
          ..setShuffleEnabled(true);
        await controller.playRecommendation(
          RecommendationPlaybackItem(track: seed),
          queue: [RecommendationPlaybackItem(track: seed)],
          queueSourceId: 'personalized-home:becauseYouListened',
          queueExtender: () async {
            extensionCalls++;
            throw StateError('offline');
          },
        );
        await _waitUntil(() => extensionCalls == 1);
        await _flushCompletion();
        final startsBeforeNext = player.playedRemote.length;

        await controller.playNext(automatic: automatic);

        expect(extensionCalls, greaterThanOrEqualTo(2));
        expect(container.read(playbackQueueProvider).currentIndex, 0);
        expect(
          player.playedRemote.length,
          automatic ? startsBeforeNext : startsBeforeNext + 1,
        );
      },
    );
  }

  test(
    'crossfade settings configure immediately and preserve rapid changes',
    () async {
      final player = _CrossfadePlayerService();
      final settings = _CrossfadeSettingsController(
        const SettingsState(
          downloadDirectory: '/tmp/bstream-crossfade-test',
          language: AppLanguage.spanish,
          crossfadeEnabled: true,
          crossfadeDuration: Duration(seconds: 10),
        ),
      );
      final container = _container(player, settingsController: settings);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await _waitUntil(() => player.crossfadeConfigurations.isNotEmpty);
      expect(player.crossfadeConfigurations.single, (
        enabled: true,
        duration: const Duration(seconds: 10),
      ));

      settings.setUnrelatedLanguage(AppLanguage.english);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        player.crossfadeConfigurations,
        hasLength(1),
        reason: 'Unrelated settings must not rebuild the crossfade decks.',
      );

      final settingsNotifier = container.read(
        settingsControllerProvider.notifier,
      );
      await Future.wait([
        settingsNotifier.setCrossfadeEnabled(false),
        settingsNotifier.setCrossfadeDuration(const Duration(seconds: 7)),
        settingsNotifier.setCrossfadeEnabled(true),
      ]);
      await _waitUntil(() => player.crossfadeConfigurations.length == 4);

      expect(player.crossfadeConfigurations, [
        (enabled: true, duration: const Duration(seconds: 10)),
        (enabled: false, duration: const Duration(seconds: 10)),
        (enabled: false, duration: const Duration(seconds: 7)),
        (enabled: true, duration: const Duration(seconds: 7)),
      ]);
      expect(player.crossfadeEnabled, isTrue);
    },
  );

  test('changing only crossfade duration keeps the prepared deck', () async {
    final player = _CrossfadePlayerService();
    final settings = _CrossfadeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream-crossfade-duration-test',
        language: AppLanguage.spanish,
        crossfadeEnabled: true,
        crossfadeDuration: Duration(seconds: 5),
      ),
    );
    final container = _container(player, settingsController: settings);
    addTearDown(container.dispose);

    await container.read(playerControllerProvider.future);
    await _waitUntil(
      () =>
          player.crossfadeConfigurations.isNotEmpty &&
          player.crossfadePreparations.isNotEmpty,
    );
    player.crossfadePreparations.clear();

    await settings.setCrossfadeDuration(const Duration(seconds: 7));
    await _waitUntil(() => player.crossfadeConfigurations.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(player.crossfadeConfigurations.last, (
      enabled: true,
      duration: const Duration(seconds: 7),
    ));
    expect(
      player.crossfadePreparations,
      isEmpty,
      reason: 'The existing standby source is still valid for a new duration.',
    );
  });

  test('crossfade prepares the exact next local queue item', () async {
    final player = _CrossfadePlayerService();
    final container = _container(
      player,
      settingsController: _enabledCrossfadeSettings(),
    );
    addTearDown(container.dispose);

    await container.read(playerControllerProvider.future);
    await _waitUntil(() => player.crossfadeConfigurations.isNotEmpty);
    player.crossfadePreparations.clear();

    final tracks = [_track(1), _track(2), _track(3)];
    await container
        .read(playerControllerProvider.notifier)
        .playLocal(tracks[1], queue: tracks);
    await _waitUntil(
      () =>
          player.crossfadePreparations.isNotEmpty &&
          player.crossfadePreparations.last is LocalCrossfadePlaybackSource,
    );

    final prepared =
        player.crossfadePreparations.last as LocalCrossfadePlaybackSource;
    expect(prepared.track.id, 'track-3');
  });

  test(
    'remote crossfade reuses its cached source and handoff advances once',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bstream-controller-crossfade-',
      );
      addTearDown(() async {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });
      final cachedSuccessor = File('${directory.path}/second.m4a');
      await cachedSuccessor.writeAsBytes(const [1, 2, 3]);
      final cache = _CrossfadeRemotePlaybackCache(
        cachedTrackId: 'second',
        file: cachedSuccessor,
      );
      final player = _CrossfadePlayerService();
      final settings = _enabledCrossfadeSettings();
      final container = _container(
        player,
        remoteCache: cache,
        settingsController: settings,
      );
      addTearDown(container.dispose);
      final tracks = [
        _queuedRemoteTrack('first'),
        _queuedRemoteTrack('second'),
        _queuedRemoteTrack('third'),
      ];

      await container.read(playerControllerProvider.future);
      await _waitUntil(() => player.crossfadeConfigurations.isNotEmpty);
      player.crossfadePreparations.clear();
      var handoffIndexUpdates = 0;
      final queueSubscription = container.listen<PlaybackQueueState>(
        playbackQueueProvider,
        (_, next) {
          if (next.currentIndex == 1) {
            handoffIndexUpdates++;
          }
        },
      );
      addTearDown(queueSubscription.close);

      await container
          .read(playerControllerProvider.notifier)
          .playRemote(tracks.first, queue: tracks);
      await _waitUntil(
        () => player.crossfadePreparations
            .whereType<RemoteCrossfadePlaybackSource>()
            .isNotEmpty,
      );
      final prepared = player.crossfadePreparations
          .whereType<RemoteCrossfadePlaybackSource>()
          .first;
      expect(prepared.source.track.id, 'second');
      expect(prepared.source.uri, cachedSuccessor.uri);
      expect(cache.cachedLookups, contains('second'));
      expect(player.playedRemote.map((track) => track.id), ['first']);

      final preparationCount = player.crossfadePreparations.length;
      final cachedLookupCount = cache.cachedLookups.length;
      await settings.setCrossfadeDuration(const Duration(seconds: 7));
      await _waitUntil(() => player.crossfadeConfigurations.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        player.crossfadePreparations,
        hasLength(preparationCount),
        reason: 'A duration-only change must preserve the remote standby deck.',
      );
      expect(
        cache.cachedLookups,
        hasLength(cachedLookupCount),
        reason: 'A duration-only change must not restart remote prefetch.',
      );
      expect(player.preparedCrossfadeSource, same(prepared));

      player.emitCrossfadeHandoff(prepared.source);
      await _waitUntil(
        () => container.read(playbackQueueProvider).currentIndex == 1,
      );
      player.emitCrossfadeHandoff(prepared.source);
      await _flushCompletion();

      expect(handoffIndexUpdates, 1);
      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(player.playedRemote.map((track) => track.id), ['first']);
    },
  );

  test(
    'seek and reorder reprepare crossfade while stop invalidates it',
    () async {
      final player = _CrossfadePlayerService(
        supportsLocalQueueReplacement: true,
      );
      final container = _container(
        player,
        settingsController: _enabledCrossfadeSettings(),
      );
      addTearDown(container.dispose);
      final tracks = [_track(1), _track(2), _track(3)];

      await container.read(playerControllerProvider.future);
      await _waitUntil(() => player.crossfadeConfigurations.isNotEmpty);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playLocal(tracks.first, queue: tracks);
      await _waitUntil(
        () => player.preparedCrossfadeSource is LocalCrossfadePlaybackSource,
      );
      expect(
        (player.preparedCrossfadeSource! as LocalCrossfadePlaybackSource)
            .track
            .id,
        'track-2',
      );

      final preparationsBeforeSeek = player.crossfadePreparations.length;
      await controller.seek(Duration.zero);
      await _waitUntil(
        () => player.crossfadePreparations.length > preparationsBeforeSeek,
      );
      expect(player.seekCrossfadeInvalidations, 1);
      expect(player.currentSnapshot.position, Duration.zero);
      expect(
        (player.preparedCrossfadeSource! as LocalCrossfadePlaybackSource)
            .track
            .id,
        'track-2',
      );

      await controller.reorderQueue(2, 1);
      await _waitUntil(
        () =>
            player.preparedCrossfadeSource is LocalCrossfadePlaybackSource &&
            (player.preparedCrossfadeSource! as LocalCrossfadePlaybackSource)
                    .track
                    .id ==
                'track-3',
      );
      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['track-1', 'track-3', 'track-2'],
      );

      await controller.stop();
      await _flushCompletion();
      expect(player.stopCrossfadeInvalidations, 1);
      expect(player.preparedCrossfadeSource, isNull);
    },
  );

  test(
    'a stale local crossfade preparation cannot replace the latest plan',
    () async {
      final player = _BlockingCrossfadePlayerService(
        supportsLocalQueueReplacement: true,
      );
      final container = _container(
        player,
        settingsController: _enabledCrossfadeSettings(),
      );
      addTearDown(container.dispose);
      final tracks = [_track(1), _track(2)];

      await container.read(playerControllerProvider.future);
      await _waitUntil(() => player.crossfadeConfigurations.isNotEmpty);
      await _waitUntil(() => player.crossfadePreparations.isNotEmpty);
      player.blockNextNonNullPreparation();
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playLocal(tracks.first, queue: tracks);
      await player.blockedPreparation;
      final preparationsBeforeNavigation = player.crossfadePreparations.length;

      await controller.playQueueIndex(1);
      player.releaseBlockedPreparation();
      await _waitUntil(
        () =>
            player.crossfadePreparations.length >=
                preparationsBeforeNavigation + 2 &&
            player.crossfadePreparations.last == null,
      );

      expect(player.preparedCrossfadeSource, isNull);
    },
  );

  test(
    'a stale empty remote prefetch cannot clear the replacement native queue',
    () async {
      final player = _BlockingNativeCrossfadePlayerService();
      final cache = _TrackingRemotePlaybackCache();
      final container = _container(
        player,
        remoteCache: cache,
        settingsController: _enabledCrossfadeSettings(),
      );
      addTearDown(container.dispose);
      final oldQueue = [
        _queuedRemoteTrack('empty-old-first'),
        _queuedRemoteTrack('empty-old-last'),
      ];
      final replacement = [
        _queuedRemoteTrack('empty-new-first'),
        _queuedRemoteTrack('empty-new-next'),
      ];

      await container.read(playerControllerProvider.future);
      await _waitUntil(() => player.crossfadeConfigurations.isNotEmpty);
      await _waitUntil(() => player.crossfadePreparations.isNotEmpty);
      player.blockNextNullPreparation();
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRemote(oldQueue.last, queue: oldQueue);
      await player.blockedPreparation;

      await controller.playRemote(replacement.first, queue: replacement);
      player.releaseBlockedPreparation();
      await _waitUntil(
        () =>
            player.remoteWindows.isNotEmpty &&
            player.remoteWindows.last.isNotEmpty &&
            player.remoteWindows.last.first.track.id == replacement[1].id,
      );

      expect(player.remoteWindows.where((window) => window.isEmpty), isEmpty);
      expect(
        (player.preparedCrossfadeSource! as RemoteCrossfadePlaybackSource)
            .source
            .track
            .id,
        replacement[1].id,
      );
    },
  );

  test('only the latest concurrent seek reprepares crossfade', () async {
    final player = _CrossfadePlayerService(supportsLocalQueueReplacement: true);
    final container = _container(
      player,
      settingsController: _enabledCrossfadeSettings(),
    );
    addTearDown(container.dispose);
    final tracks = [_track(1), _track(2)];

    await container.read(playerControllerProvider.future);
    final controller = container.read(playerControllerProvider.notifier);
    await controller.playLocal(tracks.first, queue: tracks);
    await _waitUntil(() => player.preparedCrossfadeSource != null);
    final preparationsBeforeSeek = player.crossfadePreparations.length;
    player.blockSeeks = true;

    final first = controller.seek(const Duration(seconds: 25));
    final latest = controller.seek(Duration.zero);
    await _waitUntil(() => player.blockedSeeks.length == 2);
    player.blockedSeeks[0].complete();
    await _flushCompletion();
    expect(player.crossfadePreparations.length, preparationsBeforeSeek);
    player.blockedSeeks[1].complete();
    await Future.wait([first, latest]);
    await _waitUntil(
      () => player.crossfadePreparations.length > preparationsBeforeSeek,
    );

    expect(player.seekCrossfadeInvalidations, 2);
    expect(player.crossfadePreparations.length, preparationsBeforeSeek + 1);
    expect(
      (player.preparedCrossfadeSource! as LocalCrossfadePlaybackSource)
          .track
          .id,
      'track-2',
    );
  });

  test(
    'remote playback retries the complete resolver chain twice and then succeeds',
    () async {
      final player = _FakePlayerService();
      final retryDelay = _ControlledRetryDelay();
      final primary = _SequencedAudioResolver([
        const SocketException('primary offline cycle 1'),
        const SocketException('primary offline cycle 2'),
        const SocketException('primary offline cycle 3'),
      ]);
      final fallback = _SequencedAudioResolver([
        const SocketException('fallback offline cycle 1'),
        const SocketException('fallback offline cycle 2'),
        _ytDlpResolution('bounded-retry'),
      ]);
      final resolver = FallbackAudioResolver([primary, fallback]);
      final container = _container(
        player,
        audioResolver: resolver,
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);
      final track = _unresolvedRemoteTrack('bounded-retry');

      await container.read(playerControllerProvider.future);
      final play = container
          .read(playerControllerProvider.notifier)
          .playRemote(track, queue: [track, _queuedRemoteTrack('untouched')]);

      await _waitUntil(() => retryDelay.durations.length == 1);
      expect(primary.resolveCalls, 1);
      expect(fallback.resolveCalls, 1);
      expect(retryDelay.durations, const [Duration(seconds: 2)]);
      expect(container.read(playbackQueueProvider).currentIndex, 0);

      retryDelay.releaseNext();
      await _waitUntil(() => retryDelay.durations.length == 2);
      expect(primary.resolveCalls, 2);
      expect(fallback.resolveCalls, 2);
      expect(retryDelay.durations, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]);

      retryDelay.releaseNext();
      await play;

      expect(primary.resolveCalls, 3);
      expect(fallback.resolveCalls, 3);
      expect(player.playedRemote, hasLength(1));
      expect(
        player.playedRemote.single.streamSource,
        AudioStreamSource.ytDlp.name,
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(
        container.read(playerControllerProvider).requireValue.status,
        PlayerStatus.playing,
      );
    },
  );

  test('remote playback stops after exactly two complete retries', () async {
    final player = _FakePlayerService();
    final retryDelay = _ControlledRetryDelay();
    final primary = _SequencedAudioResolver([
      const SocketException('primary offline cycle 1'),
      const SocketException('primary offline cycle 2'),
      const SocketException('primary offline cycle 3'),
    ]);
    final fallback = _SequencedAudioResolver([
      const SocketException('fallback offline cycle 1'),
      const SocketException('fallback offline cycle 2'),
      const SocketException('fallback offline cycle 3'),
    ]);
    final container = _container(
      player,
      audioResolver: FallbackAudioResolver([primary, fallback]),
      retryDelay: retryDelay.call,
    );
    addTearDown(container.dispose);
    final track = _unresolvedRemoteTrack('retry-exhausted');

    await container.read(playerControllerProvider.future);
    final play = container
        .read(playerControllerProvider.notifier)
        .playRemote(track);

    await _waitUntil(() => retryDelay.durations.length == 1);
    retryDelay.releaseNext();
    await _waitUntil(() => retryDelay.durations.length == 2);
    retryDelay.releaseNext();
    await play;
    await _flushCompletion();

    expect(primary.resolveCalls, 3);
    expect(fallback.resolveCalls, 3);
    expect(retryDelay.durations, const [
      Duration(seconds: 2),
      Duration(seconds: 5),
    ]);
    expect(player.playedRemote, isEmpty);
    expect(container.read(playerControllerProvider).hasError, isTrue);
    expect(container.read(playbackQueueProvider).currentIndex, 0);

    await _flushCompletion();
    expect(primary.resolveCalls, 3, reason: 'a fourth cycle must not start');
    expect(fallback.resolveCalls, 3, reason: 'a fourth cycle must not start');
  });

  test(
    'a duplicate failed snapshot cannot reopen an exhausted retry budget',
    () async {
      final player = _RejectYoutubeExplodePlayerService();
      final retryDelay = _ControlledRetryDelay();
      final resolver = _ScriptedModeAwareAudioResolver(
        primaryOutcomes: [
          _youtubeExplodeResolution('terminal-duplicate-cycle-1'),
          _youtubeExplodeResolution('terminal-duplicate-cycle-2'),
          _youtubeExplodeResolution('terminal-duplicate-cycle-3'),
        ],
        fallbackOutcomes: const [
          SocketException('fallback offline cycle 1'),
          SocketException('fallback offline cycle 2'),
          SocketException('fallback offline cycle 3'),
        ],
      );
      final container = _container(
        player,
        audioResolver: resolver,
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);
      final track = _unresolvedRemoteTrack('terminal-duplicate');

      await container.read(playerControllerProvider.future);
      final play = container
          .read(playerControllerProvider.notifier)
          .playRemote(track);
      await _waitUntil(() => retryDelay.durations.length == 1);
      retryDelay.releaseNext();
      await _waitUntil(() => retryDelay.durations.length == 2);
      retryDelay.releaseNext();
      await play;
      await _waitUntil(() => container.read(playerControllerProvider).hasError);
      final terminalError = container.read(playerControllerProvider).error;

      expect(resolver.modes, const [
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
      ]);
      expect(retryDelay.durations, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]);
      expect(player.attemptedRemote, hasLength(3));

      player.emit(
        PlayerSnapshot(
          status: PlayerStatus.failed,
          title: track.title,
          artist: track.artist,
          trackId: track.id,
          sourceUrl: track.url,
          isRemote: true,
          errorMessage: 'duplicate terminal HTTP 503',
        ),
      );
      await _flushCompletion();

      expect(
        resolver.modes,
        hasLength(6),
        reason: 'the duplicate terminal snapshot must not start a fourth cycle',
      );
      expect(retryDelay.durations, hasLength(2));
      expect(player.attemptedRemote, hasLength(3));
      expect(container.read(playerControllerProvider).hasError, isTrue);
      expect(
        container.read(playerControllerProvider).error,
        same(terminalError),
      );
    },
  );

  test(
    'moving to a downloaded next item cancels a remote retry during backoff',
    () async {
      final player = _FakePlayerService();
      final retryDelay = _ControlledRetryDelay();
      final primary = _SequencedAudioResolver([
        const SocketException('primary offline'),
      ]);
      final fallback = _SequencedAudioResolver([
        const SocketException('fallback offline'),
      ]);
      final container = _container(
        player,
        audioResolver: FallbackAudioResolver([primary, fallback]),
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);
      final remote = _unresolvedRemoteTrack('cancelled-retry');
      final downloaded = _track(2);
      const downloadedCatalog = TrackInfo(
        id: 'Downloaded2',
        title: 'Downloaded successor',
        artist: 'BStream',
        url: 'https://www.youtube.com/watch?v=Downloaded2',
      );

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      final remotePlay = controller.playRecommendation(
        RecommendationPlaybackItem(track: remote),
        queue: [
          RecommendationPlaybackItem(track: remote),
          RecommendationPlaybackItem(
            track: downloadedCatalog,
            localTrack: downloaded,
          ),
        ],
        queueSourceId: 'personalized-home:offline-transition',
      );
      await _waitUntil(() => retryDelay.durations.length == 1);

      await controller.playNext();

      expect(player.playedLocalIds, [downloaded.id]);
      expect(container.read(playbackQueueProvider).currentIndex, 1);
      retryDelay.releaseNext();
      await remotePlay;
      await _flushCompletion();

      expect(primary.resolveCalls, 1);
      expect(fallback.resolveCalls, 1);
      expect(retryDelay.durations, const [Duration(seconds: 2)]);
      expect(player.playedRemote, isEmpty);
      expect(
        container.read(playerControllerProvider).value?.trackId,
        downloaded.id,
      );
    },
  );

  test('permanent remote errors do not enter playback backoff', () async {
    final player = _FakePlayerService();
    final retryDelay = _ControlledRetryDelay();
    final primary = _SequencedAudioResolver([
      const SocketException('primary unavailable'),
    ]);
    final fallback = _SequencedAudioResolver([
      StateError('Sign in to confirm you are not a bot; cookies required.'),
    ]);
    final container = _container(
      player,
      audioResolver: FallbackAudioResolver([primary, fallback]),
      retryDelay: retryDelay.call,
    );
    addTearDown(container.dispose);

    await container.read(playerControllerProvider.future);
    await container
        .read(playerControllerProvider.notifier)
        .playRemote(_unresolvedRemoteTrack('permanent-error'));

    expect(primary.resolveCalls, 1);
    expect(fallback.resolveCalls, 1);
    expect(retryDelay.durations, isEmpty);
    expect(container.read(playerControllerProvider).hasError, isTrue);
    expect(
      container.read(playerControllerProvider).error.toString(),
      contains('cookies'),
    );
  });

  test(
    'terminal remote failure retains canonical metadata for the attempted track',
    () async {
      final player = _FakePlayerService();
      final primary = _SequencedAudioResolver([
        const SocketException('primary unavailable'),
      ]);
      final fallback = _SequencedAudioResolver([
        StateError('Sign in required; cookies required.'),
      ]);
      final container = _container(
        player,
        audioResolver: FallbackAudioResolver([primary, fallback]),
      );
      addTearDown(container.dispose);
      final previous = _track(1);
      final attempted = _unresolvedRemoteTrack('canonical-terminal');

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playLocal(previous);
      await controller.playRemote(attempted);

      final result = container.read(playerControllerProvider);
      expect(result.hasError, isTrue);
      final snapshot = result.value;
      expect(snapshot, isNotNull);
      expect(snapshot!.status, PlayerStatus.failed);
      expect(snapshot.trackId, attempted.id);
      expect(snapshot.title, attempted.title);
      expect(snapshot.artist, attempted.artist);
      expect(snapshot.sourceUrl, attempted.url);
      expect(snapshot.trackId, isNot(previous.id));
    },
  );

  for (final permanentCode in const [
    'invalid_stream_url',
    'yt_dlp_managed_playback_too_large',
  ]) {
    test(
      'typed permanent error $permanentCode skips playback backoff',
      () async {
        final player = _FakePlayerService();
        final retryDelay = _ControlledRetryDelay();
        final primary = _SequencedAudioResolver([
          const SocketException('primary unavailable'),
        ]);
        final fallback = _SequencedAudioResolver([
          AppException('permanent resolver failure', code: permanentCode),
        ]);
        final container = _container(
          player,
          audioResolver: FallbackAudioResolver([primary, fallback]),
          retryDelay: retryDelay.call,
        );
        addTearDown(container.dispose);

        await container.read(playerControllerProvider.future);
        await container
            .read(playerControllerProvider.notifier)
            .playRemote(_unresolvedRemoteTrack('permanent-$permanentCode'));

        expect(primary.resolveCalls, 1);
        expect(fallback.resolveCalls, 1);
        expect(retryDelay.durations, isEmpty);
        expect(container.read(playerControllerProvider).hasError, isTrue);
        expect(
          container.read(playerControllerProvider).error.toString(),
          contains(permanentCode),
        );
      },
    );
  }

  test(
    'a superseded final retry exits silently without advancing LIVE',
    () async {
      final player = _FakePlayerService();
      final retryDelay = _ControlledRetryDelay();
      final primary = _SequencedAudioResolver([
        const SocketException('primary offline cycle 1'),
        const SocketException('primary offline cycle 2'),
        const SocketException('primary offline cycle 3'),
      ]);
      final fallback = _SequencedAudioResolver([
        const SocketException('fallback offline cycle 1'),
        const SocketException('fallback offline cycle 2'),
        const AppException(
          'managed playback was superseded',
          code: 'yt_dlp_managed_playback_superseded',
        ),
      ]);
      final container = _container(
        player,
        audioResolver: FallbackAudioResolver([primary, fallback]),
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);
      final track = _unresolvedRemoteTrack('superseded-final-retry');
      final next = _unresolvedRemoteTrack('must-not-advance-after-superseded');

      await container.read(playerControllerProvider.future);
      final play = container
          .read(playerControllerProvider.notifier)
          .playRemote(
            track,
            queue: [track, next],
            queueSourceId: PlayerController.liveQueueSourceId,
          );
      await _waitUntil(() => retryDelay.durations.length == 1);
      retryDelay.releaseNext();
      await _waitUntil(() => retryDelay.durations.length == 2);
      retryDelay.releaseNext();
      await play;
      await _flushCompletion();

      expect(primary.resolveCalls, 3);
      expect(fallback.resolveCalls, 3);
      expect(retryDelay.durations, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]);
      expect(container.read(playerControllerProvider).hasError, isFalse);
      expect(
        container.read(playerControllerProvider).requireValue.errorMessage,
        isNull,
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(player.playedRemote, isEmpty);
    },
  );

  test(
    'a canceled network handoff remains transient and exhausts both backoffs',
    () async {
      final player = _FakePlayerService();
      final retryDelay = _ControlledRetryDelay();
      final primary = _SequencedAudioResolver([
        const SocketException('connection canceled during network handoff'),
        const SocketException('connection canceled during network handoff'),
        const SocketException('connection canceled during network handoff'),
      ]);
      final fallback = _SequencedAudioResolver([
        const SocketException('connection canceled during network handoff'),
        const SocketException('connection canceled during network handoff'),
        const SocketException('connection canceled during network handoff'),
      ]);
      final container = _container(
        player,
        audioResolver: FallbackAudioResolver([primary, fallback]),
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      final play = container
          .read(playerControllerProvider.notifier)
          .playRemote(_unresolvedRemoteTrack('canceled-network-handoff'));
      await _waitUntil(() => retryDelay.durations.length == 1);
      retryDelay.releaseNext();
      await _waitUntil(() => retryDelay.durations.length == 2);
      retryDelay.releaseNext();
      await play;
      await _flushCompletion();

      expect(primary.resolveCalls, 3);
      expect(fallback.resolveCalls, 3);
      expect(retryDelay.durations, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]);
      expect(container.read(playerControllerProvider).hasError, isTrue);
      expect(
        container.read(playerControllerProvider).error.toString(),
        contains('connection canceled during network handoff'),
      );
    },
  );

  test(
    'a complete retry still tries yt-dlp when the backend rejects its primary URL',
    () async {
      final player = _RejectYoutubeExplodePlayerService();
      final retryDelay = _ControlledRetryDelay();
      final resolver = _ScriptedModeAwareAudioResolver(
        primaryOutcomes: [
          _youtubeExplodeResolution('backend-rejection'),
          _youtubeExplodeResolution('backend-rejection-retry'),
        ],
        fallbackOutcomes: [
          const SocketException('yt-dlp temporarily offline'),
          _ytDlpResolution('backend-rejection-fallback'),
        ],
      );
      final container = _container(
        player,
        audioResolver: resolver,
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);
      final track = _unresolvedRemoteTrack('backend-rejection');

      await container.read(playerControllerProvider.future);
      await container.read(playerControllerProvider.notifier).playRemote(track);
      await _waitUntil(() => retryDelay.durations.length == 1);

      expect(resolver.modes, const [
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
      ]);
      expect(retryDelay.durations, const [Duration(seconds: 2)]);

      retryDelay.releaseNext();
      await _waitUntil(
        () =>
            resolver.modes.length == 4 &&
            container.read(playerControllerProvider).value?.status ==
                PlayerStatus.playing,
      );

      expect(resolver.modes, const [
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
      ]);
      expect(player.attemptedRemote.map((entry) => entry.streamSource), [
        AudioStreamSource.youtubeExplode.name,
        AudioStreamSource.youtubeExplode.name,
        AudioStreamSource.ytDlp.name,
      ]);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(retryDelay.durations, hasLength(1));
    },
  );

  test(
    'a late original Future error cannot start a second retry budget after snapshot exhaustion',
    () async {
      final player = _BlockedOriginalPrimaryFailurePlayerService();
      final retryDelay = _ControlledRetryDelay();
      final resolver = _ScriptedModeAwareAudioResolver(
        primaryOutcomes: [
          _youtubeExplodeResolution('pending-original-cycle-1'),
          _youtubeExplodeResolution('pending-original-cycle-2'),
          _youtubeExplodeResolution('pending-original-cycle-3'),
        ],
        fallbackOutcomes: const [
          SocketException('fallback offline cycle 1'),
          SocketException('fallback offline cycle 2'),
          SocketException('fallback offline cycle 3'),
        ],
      );
      final container = _container(
        player,
        audioResolver: resolver,
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);
      final track = _unresolvedRemoteTrack('pending-original');

      await container.read(playerControllerProvider.future);
      final play = container
          .read(playerControllerProvider.notifier)
          .playRemote(track);

      await _waitUntil(() => retryDelay.durations.length == 1);
      retryDelay.releaseNext();
      await _waitUntil(() => retryDelay.durations.length == 2);
      retryDelay.releaseNext();
      await _waitUntil(
        () => container.read(playerControllerProvider).hasError,
        reason: 'the snapshot-owned retry budget did not reach exhaustion',
      );

      expect(resolver.modes, const [
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
      ]);
      expect(retryDelay.durations, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]);
      expect(player.attemptedRemote, hasLength(3));

      player.completeOriginalWithError();
      await play;
      await _flushCompletion();

      expect(
        resolver.modes,
        hasLength(6),
        reason: 'the late Future error must not start a fourth cycle',
      );
      expect(
        retryDelay.durations,
        hasLength(2),
        reason: 'the late Future error must not receive another retry budget',
      );
      expect(player.attemptedRemote, hasLength(3));
      expect(container.read(playbackQueueProvider).currentIndex, 0);
    },
  );

  test(
    'a late original Future success preserves the snapshot-owned retry budget',
    () async {
      final player = _BlockedOriginalPrimarySuccessPlayerService();
      final retryDelay = _ControlledRetryDelay();
      final resolver = _ScriptedModeAwareAudioResolver(
        primaryOutcomes: [
          _youtubeExplodeResolution('pending-original-success-cycle-1'),
          _youtubeExplodeResolution('pending-original-success-cycle-2'),
        ],
        fallbackOutcomes: const [
          SocketException('fallback offline before retry'),
        ],
      );
      final container = _container(
        player,
        audioResolver: resolver,
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);
      final track = _unresolvedRemoteTrack('pending-original-success');
      final next = _unresolvedRemoteTrack('must-not-live-advance');

      await container.read(playerControllerProvider.future);
      final play = container
          .read(playerControllerProvider.notifier)
          .playRemote(
            track,
            queue: [track, next],
            queueSourceId: PlayerController.liveQueueSourceId,
          );

      await _waitUntil(() => retryDelay.durations.length == 1);
      final retryingBeforeOriginalCompletes = container
          .read(playerControllerProvider)
          .requireValue;
      expect(retryingBeforeOriginalCompletes.status, PlayerStatus.loading);
      expect(retryingBeforeOriginalCompletes.errorMessage, contains('1/2'));

      player.completeOriginalSuccessfully();
      await play;
      await _flushCompletion();

      final retryingAfterOriginalCompletes = container
          .read(playerControllerProvider)
          .requireValue;
      expect(retryingAfterOriginalCompletes.status, PlayerStatus.loading);
      expect(
        retryingAfterOriginalCompletes.errorMessage,
        retryingBeforeOriginalCompletes.errorMessage,
        reason: 'the stale successful Future must not clear the retry notice',
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(player.attemptedRemote, hasLength(1));
      expect(resolver.modes, const [
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
      ]);

      retryDelay.releaseNext();
      await _waitUntil(
        () =>
            player.attemptedRemote.length == 2 &&
            container.read(playerControllerProvider).value?.status ==
                PlayerStatus.playing,
        reason: 'the snapshot-owned retry did not finish successfully',
      );

      expect(resolver.modes, const [
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
        AudioResolutionMode.primaryThenFallback,
      ]);
      expect(retryDelay.durations, const [Duration(seconds: 2)]);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(
        player.attemptedRemote.map((attempt) => attempt.id),
        everyElement(track.id),
      );
    },
  );

  test(
    'a failed snapshot from a pending retry preserves loading and does not advance LIVE',
    () async {
      final player = _PendingRetryFailurePlayerService();
      final retryDelay = _ControlledRetryDelay();
      final resolver = _ScriptedModeAwareAudioResolver(
        primaryOutcomes: [
          _youtubeExplodeResolution('pending-retry-cycle-1'),
          _youtubeExplodeResolution('pending-retry-cycle-2'),
        ],
        fallbackOutcomes: const [
          SocketException('fallback offline before retry'),
        ],
      );
      final container = _container(
        player,
        audioResolver: resolver,
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);
      final track = _unresolvedRemoteTrack('pending-retry-failure');
      final next = _unresolvedRemoteTrack('must-not-advance-during-retry');

      await container.read(playerControllerProvider.future);
      final play = container
          .read(playerControllerProvider.notifier)
          .playRemote(
            track,
            queue: [track, next],
            queueSourceId: PlayerController.liveQueueSourceId,
          );
      await _waitUntil(() => retryDelay.durations.length == 1);
      final noticeBeforeRetry = container
          .read(playerControllerProvider)
          .requireValue;
      expect(noticeBeforeRetry.status, PlayerStatus.loading);
      expect(noticeBeforeRetry.errorMessage, contains('1/2'));

      retryDelay.releaseNext();
      await player.retryAttemptStarted;
      await _flushCompletion();

      final whileRetryFutureIsPending = container
          .read(playerControllerProvider)
          .requireValue;
      expect(whileRetryFutureIsPending.status, PlayerStatus.loading);
      expect(
        whileRetryFutureIsPending.errorMessage,
        noticeBeforeRetry.errorMessage,
        reason: 'the duplicate backend failure must preserve the retry notice',
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(player.attemptedRemote, hasLength(2));
      expect(player.playedRemote, isEmpty);
      expect(retryDelay.durations, const [Duration(seconds: 2)]);

      player.completeRetrySuccessfully();
      await play;
      await _waitUntil(
        () =>
            container.read(playerControllerProvider).value?.status ==
            PlayerStatus.playing,
      );

      expect(resolver.modes, const [
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
        AudioResolutionMode.primaryThenFallback,
      ]);
      expect(retryDelay.durations, const [Duration(seconds: 2)]);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(player.playedRemote.single.id, track.id);
    },
  );

  test(
    'LIVE terminal failure advances once and a single-item LIVE queue does not loop',
    () async {
      final player = _FakePlayerService();
      final retryDelay = _ControlledRetryDelay();
      final resolver = _LiveRetryAudioResolver(successfulTrackId: 'live-next');
      final container = _container(
        player,
        audioResolver: resolver,
        retryDelay: retryDelay.call,
      );
      addTearDown(container.dispose);
      final failed = _unresolvedRemoteTrack('live-failed');
      final next = _unresolvedRemoteTrack('live-next');

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      final firstPlay = controller.playRemote(
        failed,
        queue: [failed, next],
        queueSourceId: PlayerController.liveQueueSourceId,
      );
      await _waitUntil(() => retryDelay.durations.length == 1);
      retryDelay.releaseNext();
      await _waitUntil(() => retryDelay.durations.length == 2);
      retryDelay.releaseNext();
      await firstPlay;
      await _waitUntil(
        () =>
            container.read(playbackQueueProvider).currentIndex == 1 &&
            player.playedRemote.map((track) => track.id).contains('live-next'),
      );

      expect(resolver.callsFor('live-failed'), 3);
      expect(resolver.callsFor('live-next'), 1);
      expect(player.playedRemote.map((track) => track.id), ['live-next']);

      final lone = _unresolvedRemoteTrack('live-lone-failure');
      final lonePlay = controller.playRemote(
        lone,
        queue: [lone],
        queueSourceId: PlayerController.liveQueueSourceId,
      );
      await _waitUntil(() => retryDelay.durations.length == 3);
      retryDelay.releaseNext();
      await _waitUntil(() => retryDelay.durations.length == 4);
      retryDelay.releaseNext();
      await lonePlay;
      await _flushCompletion();

      expect(resolver.callsFor('live-lone-failure'), 3);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(player.playedRemote.map((track) => track.id), ['live-next']);
      expect(retryDelay.durations, const [
        Duration(seconds: 2),
        Duration(seconds: 5),
        Duration(seconds: 2),
        Duration(seconds: 5),
      ]);
    },
  );

  test(
    'a later asynchronous outage starts another bounded recovery without skipping',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeMusicRepository([
        _remoteTrack(streamUrl: 'https://media.example/first.m4a'),
        _remoteTrack(streamUrl: 'https://media.example/refreshed.m4a'),
      ]);
      final container = _container(
        player,
        audioResolver: _FakeAudioResolverFromRepository(repository),
        retryDelay: (_) async {},
      );
      addTearDown(container.dispose);
      const searchTrack = TrackInfo(
        id: 'q8j3zwNhLNo',
        title: 'YO SOY TU TITAN',
        artist: 'Pamorkil',
        album: 'Titanes',
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
          position: Duration(minutes: 5, seconds: 12),
          isRemote: true,
          errorMessage: 'HTTP 403',
        ),
      );
      await _waitUntil(() => player.playedRemote.length == 2);

      expect(repository.infoCalls, 2);
      expect(player.playedRemote.last.streamUrl, contains('refreshed.m4a'));
      expect(player.lastSeekPosition, const Duration(minutes: 5, seconds: 12));
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

      expect(repository.infoCalls, 3);
      expect(player.playedRemote, hasLength(3));
      expect(container.read(playbackQueueProvider).currentIndex, 0);
    },
  );

  test(
    'a native skip invalidates an in-flight recovery for the previous track',
    () async {
      final player = _NativeRemoteQueuePlayerService();
      final repository = _DelayedRefreshMusicRepository(
        _remoteTrack(streamUrl: 'https://media.example/first.m4a'),
      );
      final cache = _TrackingRemotePlaybackCache();
      const first = TrackInfo(
        id: 'q8j3zwNhLNo',
        title: 'YO SOY TU TITAN',
        artist: 'Pamorkil',
        url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
        thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/hqdefault.jpg',
      );
      final second = _queuedRemoteTrack('second');
      final container = _container(
        player,
        audioResolver: _FakeAudioResolverFromRepository(repository),
        remoteCache: cache,
        retryDelay: (_) async {},
      );
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(first, queue: [first, second]);
      await _waitUntil(
        () =>
            player.remoteWindows.isNotEmpty &&
            player.remoteWindows.last.isNotEmpty,
      );
      final nextSource = player.remoteWindows.last.first;

      player.emit(
        player.currentSnapshot.copyWith(
          status: PlayerStatus.failed,
          errorMessage: 'HTTP 403',
        ),
      );
      await _waitUntil(() => repository.infoCalls == 2);

      player.emitNativeTransition(nextSource);
      await _waitUntil(
        () => container.read(playbackQueueProvider).currentIndex == 1,
        reason: 'native skip was blocked by the previous recovery',
      );
      repository.completeRefresh(
        _remoteTrack(streamUrl: 'https://media.example/refreshed.m4a'),
      );
      await _flushCompletion();

      expect(player.nativeRemoteStarts, 1);
      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(player.currentSnapshot.trackId, second.id);
    },
  );

  test('a later yt-dlp failure restarts the complete resolver chain', () async {
    final player = _RejectYoutubeExplodePlayerService();
    final resolver = _ModeAwareFallbackAudioResolver();
    final container = _container(
      player,
      audioResolver: resolver,
      retryDelay: (_) async {},
    );
    addTearDown(container.dispose);
    final observed = <AsyncValue<PlayerSnapshot>>[];
    final subscription = container.listen<AsyncValue<PlayerSnapshot>>(
      playerControllerProvider,
      (_, next) => observed.add(next),
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    const track = TrackInfo(
      id: 'q8j3zwNhLNo',
      title: 'Fallback test',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
    );

    await container.read(playerControllerProvider.future);
    await container.read(playerControllerProvider.notifier).playRemote(track);
    await _waitUntil(
      () => resolver.modes.length == 2 && player.attemptedRemote.length == 2,
    );

    expect(resolver.modes, [
      AudioResolutionMode.primaryThenFallback,
      AudioResolutionMode.fallbackOnly,
    ]);
    expect(player.attemptedRemote.map((entry) => entry.streamSource), [
      AudioStreamSource.youtubeExplode.name,
      AudioStreamSource.ytDlp.name,
    ]);
    expect(
      observed.any(
        (value) =>
            value.value?.errorMessage?.contains('youtube_explode_dart falló') ==
            true,
      ),
      isTrue,
    );
    final playing = container.read(playerControllerProvider).requireValue;
    expect(playing.status, PlayerStatus.playing);
    expect(playing.errorMessage, isNull);

    player.emit(
      player.currentSnapshot.copyWith(
        status: PlayerStatus.failed,
        errorMessage: 'HTTP 403 from yt-dlp fallback',
      ),
    );
    await _waitUntil(
      () => resolver.modes.length == 4 && player.attemptedRemote.length == 4,
    );

    expect(resolver.modes, const [
      AudioResolutionMode.primaryThenFallback,
      AudioResolutionMode.fallbackOnly,
      AudioResolutionMode.primaryThenFallback,
      AudioResolutionMode.fallbackOnly,
    ]);
    expect(
      container.read(playerControllerProvider).requireValue.status,
      PlayerStatus.playing,
    );
    expect(
      container.read(playerControllerProvider).requireValue.errorMessage,
      isNull,
    );
  });

  test(
    'a prepared yt-dlp fallback clears the primary error before playback starts',
    () async {
      final player = _ReadyYtDlpFallbackPlayerService();
      final resolver = _ModeAwareFallbackAudioResolver();
      final container = _container(player, audioResolver: resolver);
      addTearDown(container.dispose);
      const track = TrackInfo(
        id: 'ready-fallback',
        title: 'Prepared fallback',
        artist: 'Artist',
        url: 'https://www.youtube.com/watch?v=readyFallback',
      );

      await container.read(playerControllerProvider.future);
      await container.read(playerControllerProvider.notifier).playRemote(track);
      await _waitUntil(
        () => resolver.modes.length == 2 && player.attemptedRemote.length == 2,
      );

      final snapshot = container.read(playerControllerProvider).requireValue;
      expect(snapshot.status, PlayerStatus.stopped);
      expect(snapshot.duration, const Duration(minutes: 3));
      expect(snapshot.errorMessage, isNull);
      expect(resolver.modes, [
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
      ]);
    },
  );

  testWidgets('the mini player paints the primary error until yt-dlp starts', (
    tester,
  ) async {
    final fallbackGate = Completer<void>();
    final player = _RejectYoutubeExplodePlayerService();
    final resolver = _ModeAwareFallbackAudioResolver(
      fallbackGate: fallbackGate.future,
    );
    final container = _container(player, audioResolver: resolver);
    addTearDown(container.dispose);
    const track = TrackInfo(
      id: 'visible-fallback-error',
      title: 'Visible fallback error',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=visible-error',
    );

    await container.read(playerControllerProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(width: 720, child: MiniPlayer()),
            ),
          ),
        ),
      ),
    );

    final playFuture = container
        .read(playerControllerProvider.notifier)
        .playRemote(track);
    await tester.pump();

    expect(find.textContaining('youtube_explode_dart falló'), findsOneWidget);

    fallbackGate.complete();
    await playFuture;
    await tester.pumpAndSettle();

    expect(find.textContaining('youtube_explode_dart falló'), findsNothing);
    expect(
      container.read(playerControllerProvider).requireValue.status,
      PlayerStatus.playing,
    );
    await container
        .read(playerControllerProvider.notifier)
        .resetRecommendationHistoryTracking();
  });

  testWidgets('the full player shows three lines of the final yt-dlp error', (
    tester,
  ) async {
    const message =
        'ERROR: [youtube] Video unavailable\n'
        'The account must have access\n'
        'Check cookies and try again';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PlayerErrorMessage(message: message)),
      ),
    );

    final errorText = tester.widget<Text>(find.text(message));
    expect(errorText.maxLines, 3);
    expect(errorText.overflow, TextOverflow.ellipsis);
  });

  test(
    'a late primary Future error cannot replace a successful yt-dlp fallback',
    () async {
      final player = _LatePrimaryFailurePlayerService();
      final resolver = _ModeAwareFallbackAudioResolver();
      final container = _container(player, audioResolver: resolver);
      addTearDown(container.dispose);
      const track = TrackInfo(
        id: 'late-primary-error',
        title: 'Late primary error',
        artist: 'Artist',
        url: 'https://www.youtube.com/watch?v=late-primary-error',
      );

      await container.read(playerControllerProvider.future);
      final playFuture = container
          .read(playerControllerProvider.notifier)
          .playRemote(track);
      await _waitUntil(
        () => resolver.modes.length == 2 && player.attemptedRemote.length == 2,
      );
      expect(
        container.read(playerControllerProvider).requireValue.status,
        PlayerStatus.playing,
      );

      player.completePrimaryWithError();
      await playFuture;
      await _flushCompletion();

      final snapshot = container.read(playerControllerProvider).requireValue;
      expect(snapshot.status, PlayerStatus.playing);
      expect(snapshot.errorMessage, isNull);
      expect(resolver.modes, [
        AudioResolutionMode.primaryThenFallback,
        AudioResolutionMode.fallbackOnly,
      ]);
    },
  );

  test(
    'keeps the search artwork when the player backend reports another crop',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeMusicRepository([
        _remoteTrackWithThumbnail(
          streamUrl: 'https://media.example/track.m4a',
          thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/maxresdefault.jpg',
        ),
      ]);
      final container = _container(
        player,
        audioResolver: _FakeAudioResolverFromRepository(repository),
      );
      addTearDown(container.dispose);
      const searchTrack = TrackInfo(
        id: 'q8j3zwNhLNo',
        title: 'YO SOY TU TITAN',
        artist: 'Pamorkil',
        url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
        thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/hqdefault.jpg',
      );

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(searchTrack);

      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          trackId: 'q8j3zwNhLNo',
          sourceUrl: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
          thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/maxresdefault.jpg',
          isRemote: true,
        ),
      );
      await _flushCompletion();

      expect(
        container.read(playerControllerProvider).value?.thumbnailUrl,
        'https://i.ytimg.com/vi/q8j3zwNhLNo/hq720.jpg',
      );
    },
  );

  test(
    'late catalog metadata enriches an active shared link without reopening it',
    () async {
      final player = _FakePlayerService();
      final resolver = _ControlledAudioResolver();
      final container = _container(player, audioResolver: resolver);
      addTearDown(container.dispose);
      const fallback = TrackInfo(
        id: 'dQw4w9WgXcQ',
        title: 'CanciÃ³n compartida',
        artist: 'YouTube',
        url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        thumbnailUrl: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
      );
      const catalog = TrackInfo(
        id: 'dQw4w9WgXcQ',
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        artists: ['Rick Astley'],
        album: 'Whenever You Need Somebody',
        duration: Duration(minutes: 3, seconds: 33),
        url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        thumbnailUrl: 'https://img.test/rick-astley.jpg',
        metadataSource: TrackMetadataSource.youtubeMusic,
      );

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      final playback = controller.playRemote(fallback);
      await _waitUntil(() => resolver.resolveCalls == 1);

      expect(controller.enrichCurrentRemoteTrackMetadata(catalog), isTrue);
      resolver.complete(
        const AudioStreamResolution(
          source: AudioStreamSource.youtubeExplode,
          streamUrl: 'https://media.example/rick.m4a',
          videoId: 'dQw4w9WgXcQ',
        ),
      );
      await playback;

      expect(player.playedRemote, hasLength(1));
      expect(player.playedRemote.single.title, catalog.title);
      expect(player.playedRemote.single.artist, catalog.artist);
      expect(player.playedRemote.single.album, catalog.album);
      expect(
        player.playedRemote.single.metadataSource,
        TrackMetadataSource.youtubeMusic,
      );
      expect(
        container.read(playerControllerProvider).requireValue.title,
        catalog.title,
      );
      expect(
        container.read(playbackQueueProvider).entries.single.title,
        catalog.title,
      );
    },
  );

  test(
    'keeps bot and cookie playback failures visible without refreshing',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeMusicRepository([
        _remoteTrack(streamUrl: 'https://media.example/first.m4a'),
        _remoteTrack(streamUrl: 'https://media.example/unexpected.m4a'),
      ]);
      final container = _container(
        player,
        audioResolver: _FakeAudioResolverFromRepository(repository),
      );
      addTearDown(container.dispose);
      const searchTrack = TrackInfo(
        id: 'q8j3zwNhLNo',
        title: 'YO SOY TU TITAN',
        artist: 'Pamorkil',
        url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
        thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/hqdefault.jpg',
      );

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(searchTrack);

      expect(repository.infoCalls, 1);
      expect(player.playedRemote, hasLength(1));

      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.failed,
          trackId: 'q8j3zwNhLNo',
          sourceUrl: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
          isRemote: true,
          errorMessage:
              'Source error: Sign in to confirm you are not a bot. '
              'Use --cookies-from-browser or --cookies.',
        ),
      );
      await _flushCompletion();

      expect(repository.infoCalls, 1);
      expect(player.playedRemote, hasLength(1));
      expect(
        container.read(playerControllerProvider).value?.errorMessage,
        contains('cookies'),
      );
    },
  );

  test(
    'does not refresh a synchronous bot error from the player backend',
    () async {
      final player = _FakePlayerService(
        remotePlayError: StateError(
          'Source error: Sign in to confirm you are not a bot. Use --cookies.',
        ),
      );
      final repository = _FakeMusicRepository([
        _remoteTrack(streamUrl: 'https://media.example/first.m4a'),
        _remoteTrack(streamUrl: 'https://media.example/unexpected.m4a'),
      ]);
      final container = _container(
        player,
        audioResolver: _FakeAudioResolverFromRepository(repository),
      );
      addTearDown(container.dispose);
      const searchTrack = TrackInfo(
        id: 'q8j3zwNhLNo',
        title: 'YO SOY TU TITAN',
        artist: 'Pamorkil',
        url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
        thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/hqdefault.jpg',
      );

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(searchTrack);

      expect(repository.infoCalls, 1);
      expect(player.playedRemote, isEmpty);
      expect(container.read(playerControllerProvider).hasError, isTrue);
      expect(
        container.read(playerControllerProvider).error.toString(),
        contains('cookies'),
      );
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
    final container = _container(
      player,
      audioResolver: _FakeAudioResolverFromRepository(repository),
    );
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
      final remoteCache = _FakeRemotePlaybackCache(cachedFile);
      final container = _container(
        player,
        audioResolver: _FakeAudioResolverFromRepository(repository),
        remoteCache: remoteCache,
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
      expect(
        container.read(playerControllerProvider).value?.album,
        track.album,
      );

      player.emit(
        PlayerSnapshot(
          status: PlayerStatus.failed,
          title: track.title,
          artist: track.artist,
          trackId: cachedTrackId,
          sourceUrl: track.url,
          isRemote: false,
          errorMessage: 'decoder: invalid cached audio',
        ),
      );
      await _waitUntil(() => player.playedRemote.isNotEmpty);

      expect(repository.infoCalls, 1);
      expect(remoteCache.evictCalls, 1);
      expect(player.playedRemote.single.streamUrl, contains('refreshed.m4a'));
      expect(container.read(playerControllerProvider).value?.trackId, track.id);
    },
  );

  test(
    'a synchronous cached-file open error falls back to the network stream',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'bstream-player-invalid-cache-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final cachedFile = File('${temporaryDirectory.path}/invalid.m4a');
      await cachedFile.writeAsBytes(const [0, 1, 2, 3]);
      final player = _FakePlayerService(
        localPlayError: StateError('decoder failed to open cache'),
      );
      final remoteCache = _FakeRemotePlaybackCache(cachedFile);
      final track = _remoteTrack(
        streamUrl: 'https://media.example/network-fallback.m4a',
      );
      final container = _container(player, remoteCache: remoteCache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container.read(playerControllerProvider.notifier).playRemote(track);

      expect(player.playedLocalIds, hasLength(1));
      expect(player.playedRemote, [track]);
      expect(remoteCache.evictCalls, 1);
      expect(container.read(playerControllerProvider).hasError, isFalse);
    },
  );

  test(
    'a cache entry appearing after resolve still falls back when invalid',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'bstream-player-late-cache-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final cachedFile = File('${temporaryDirectory.path}/late-invalid.m4a');
      await cachedFile.writeAsBytes(const [0, 1, 2, 3]);
      final player = _FakePlayerService(
        localPlayError: StateError('late cache decoder failure'),
      );
      final remoteCache = _FakeRemotePlaybackCache(
        cachedFile,
        missesBeforeHit: 1,
      );
      final track = _remoteTrack(
        streamUrl: 'https://media.example/late-network-fallback.m4a',
      );
      final container = _container(player, remoteCache: remoteCache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container.read(playerControllerProvider.notifier).playRemote(track);

      expect(remoteCache.lookupCalls, 2);
      expect(remoteCache.evictCalls, 1);
      expect(player.playedRemote, [track]);
      expect(container.read(playerControllerProvider).hasError, isFalse);
    },
  );

  test(
    'native cached source appearing after resolve falls back to its network source',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'bstream-player-late-native-cache-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final cachedFile = File('${temporaryDirectory.path}/late-invalid.m4a');
      await cachedFile.writeAsBytes(const [0, 1, 2, 3]);
      final player = _NativeRemoteQueuePlayerService(failCachedOpen: true);
      final remoteCache = _FakeRemotePlaybackCache(
        cachedFile,
        missesBeforeHit: 2,
      );
      final track = _remoteTrack(
        streamUrl: 'https://media.example/native-network-fallback.m4a',
      );
      final container = _container(player, remoteCache: remoteCache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container.read(playerControllerProvider.notifier).playRemote(track);

      expect(remoteCache.lookupCalls, 3);
      expect(remoteCache.evictCalls, 1);
      expect(player.cachedOpenFailures, 1);
      expect(player.nativeRemoteStarts, 1);
      expect(player.nativeRemoteSources.single.uri.scheme, 'https');
      expect(container.read(playerControllerProvider).hasError, isFalse);
    },
  );

  test('a cache file removed during lookup falls back to streaming', () async {
    final player = _FakePlayerService();
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'bstream-missing-remote-cache-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final missingFile = File('${temporaryDirectory.path}/removed.m4a');
    final container = _container(
      player,
      remoteCache: _FakeRemotePlaybackCache(missingFile),
    );
    addTearDown(container.dispose);
    final track = _remoteTrack(
      streamUrl: 'https://media.example/direct-fallback.m4a',
    );

    await container.read(playerControllerProvider.future);
    await container.read(playerControllerProvider.notifier).playRemote(track);

    expect(player.playedLocalIds, isEmpty);
    expect(player.playedRemote, [track]);
    expect(container.read(playerControllerProvider).hasError, isFalse);
  });

  test(
    'remote cache retains current, three upcoming, and previous tracks',
    () async {
      final player = _FakePlayerService();
      final cache = _TrackingRemotePlaybackCache();
      final tracks = [
        _queuedRemoteTrack('first'),
        _queuedRemoteTrack('second'),
        _queuedRemoteTrack('third'),
        _queuedRemoteTrack('fourth'),
        _queuedRemoteTrack('fifth'),
        _queuedRemoteTrack('sixth'),
      ];
      final container = _container(player, remoteCache: cache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(tracks.first, queue: tracks);
      await _waitUntil(() => cache.warmedUrls.length >= 3);

      expect(cache.retainedWindows.last, [
        tracks[0].url,
        tracks[1].url,
        tracks[2].url,
        tracks[3].url,
        tracks[5].url,
      ]);
      expect(cache.warmedUrls.take(3), [
        tracks[1].url,
        tracks[2].url,
        tracks[3].url,
      ]);
      expect(player.stopCalls, 1);

      await container.read(playerControllerProvider.notifier).playNext();
      expect(player.stopCalls, 1);
      expect(cache.retainedWindows.last, [
        tracks[1].url,
        tracks[2].url,
        tracks[3].url,
        tracks[4].url,
        tracks[0].url,
      ]);

      await container.read(playerControllerProvider.notifier).stop();
      expect(cache.retainedWindows.last, isEmpty);
    },
  );

  test(
    'manual remote replacement protects the new source and active previous source',
    () async {
      final player = _FakePlayerService();
      final cache = _TrackingRemotePlaybackCache();
      final first = _queuedRemoteTrack('protected-first');
      final second = _queuedRemoteTrack('protected-second');
      final replacement = _queuedRemoteTrack('protected-replacement');
      final container = _container(player, remoteCache: cache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(first, queue: [first, second]);
      await _waitUntil(() => cache.warmedUrls.isNotEmpty);

      await container
          .read(playerControllerProvider.notifier)
          .playRemote(replacement);

      expect(cache.protectedWindows.last, [replacement.url, first.url]);
      expect(cache.retainedWindows.last, [replacement.url, first.url]);
    },
  );

  test('controller rebuild protects an active remote source URL', () async {
    final player = _FakePlayerService();
    final cache = _TrackingRemotePlaybackCache();
    const sourceUrl = 'https://www.youtube.com/watch?v=active-rebuild';
    player.emit(
      const PlayerSnapshot(
        status: PlayerStatus.playing,
        trackId: 'active-rebuild',
        sourceUrl: sourceUrl,
        isRemote: true,
      ),
    );
    final container = _container(player, remoteCache: cache);
    addTearDown(container.dispose);

    await container.read(playerControllerProvider.future);
    await _waitUntil(() => cache.preparedSources.isNotEmpty);

    expect(cache.preparedSources.last, [sourceUrl]);
  });

  test(
    'automatic remote transitions keep the service alive across four tracks',
    () async {
      final player = _FakePlayerService();
      final tracks = [
        _queuedRemoteTrack('first'),
        _queuedRemoteTrack('second'),
        _queuedRemoteTrack('third'),
        _queuedRemoteTrack('fourth'),
      ];
      final container = _container(player);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(tracks.first, queue: tracks);

      expect(player.stopCalls, 1);
      for (
        var expectedCount = 2;
        expectedCount <= tracks.length;
        expectedCount++
      ) {
        player.emit(
          player.currentSnapshot.copyWith(status: PlayerStatus.stopped),
        );
        await _waitUntil(() => player.playedRemote.length == expectedCount);
        expect(player.stopCalls, 1);
      }

      expect(
        player.playedRemote.map((track) => track.id),
        tracks.map((track) => track.id),
      );
    },
  );

  test(
    'native remote queue advances and refills without Dart completion',
    () async {
      final player = _NativeRemoteQueuePlayerService();
      final cache = _TrackingRemotePlaybackCache();
      final tracks = [
        _queuedRemoteTrack('first'),
        _queuedRemoteTrack('second'),
        _queuedRemoteTrack('third'),
        _queuedRemoteTrack('fourth'),
        _queuedRemoteTrack('fifth'),
        _queuedRemoteTrack('sixth'),
      ];
      final container = _container(player, remoteCache: cache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(tracks.first, queue: tracks);
      await _waitUntil(
        () =>
            player.remoteWindows.isNotEmpty &&
            player.remoteWindows.last.length == 3 &&
            player.remoteWindowFinalizations.length >= 6,
      );

      expect(player.nativeRemoteStarts, 1);
      expect(player.remoteWindows.last.map((source) => source.track.id), [
        'second',
        'third',
        'fourth',
      ]);

      for (var index = 1; index < tracks.length; index++) {
        final previousUpdateCount = player.remoteWindows.length;
        final nextSource = player.remoteWindows.last.firstWhere(
          (source) => source.track.id == tracks[index].id,
        );
        player.emitNativeTransition(nextSource);
        await _waitUntil(
          () => container.read(playbackQueueProvider).currentIndex == index,
        );
        if (index < tracks.length - 1) {
          await _waitUntil(
            () => player.remoteWindows.length > previousUpdateCount,
          );
          expect(
            player.remoteWindowFinalizations[previousUpdateCount],
            isFalse,
          );
          await _waitUntil(
            () =>
                player.remoteWindows.isNotEmpty &&
                player.remoteWindows.last.isNotEmpty &&
                player.remoteWindows.last.first.track.id ==
                    tracks[index + 1].id,
          );
        } else {
          await _waitUntil(
            () =>
                player.remoteWindows.isNotEmpty &&
                player.remoteWindows.last.isEmpty,
          );
        }
      }

      expect(player.nativeRemoteStarts, 1);
      expect(player.stopCalls, 1);
      expect(player.playedRemote.map((track) => track.id), ['first']);
    },
  );

  test(
    'a failed refill preserves the native successors already prepared',
    () async {
      final player = _NativeRemoteQueuePlayerService();
      final tracks = [
        _queuedRemoteTrack('first'),
        _queuedRemoteTrack('second'),
        _queuedRemoteTrack('third'),
        _queuedRemoteTrack('fourth'),
        _queuedRemoteTrack('fifth'),
      ];
      final cache = _TrackingRemotePlaybackCache(
        failCachedLookupUrl: tracks[2].url,
        failCachedLookupOnCall: 2,
      );
      final container = _container(player, remoteCache: cache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(tracks.first, queue: tracks);
      await _waitUntil(() => player.remoteWindows.length >= 6);
      final previousUpdateCount = player.remoteWindows.length;
      final nextSource = player.remoteWindows.last.firstWhere(
        (source) => source.track.id == 'second',
      );

      player.emitNativeTransition(nextSource);
      await _waitUntil(
        () => container.read(playbackQueueProvider).currentIndex == 1,
      );
      await _waitUntil(() => cache.cachedLookupCalls[tracks[2].url] == 2);
      await _flushCompletion();

      // No exact empty/short window is sent, so ExoPlayer retains third and
      // fourth while the failed resolver is retried later.
      expect(player.remoteWindows.length, previousUpdateCount);
    },
  );

  test(
    'remote queue entries keep their native identity after reordering',
    () async {
      final player = _NativeRemoteQueuePlayerService();
      final cache = _TrackingRemotePlaybackCache();
      final tracks = [
        _queuedRemoteTrack('stable-first'),
        _queuedRemoteTrack('stable-second'),
        _queuedRemoteTrack('stable-third'),
        _queuedRemoteTrack('stable-fourth'),
      ];
      final container = _container(player, remoteCache: cache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRemote(tracks.first, queue: tracks);
      await _waitUntil(
        () =>
            player.remoteWindows.isNotEmpty &&
            player.remoteWindows.last.length == 3,
      );
      final initialIds = {
        for (final source in player.remoteWindows.last)
          source.track.id: source.queueEntryId,
      };

      await controller.reorderQueue(2, 1);
      await _waitUntil(
        () =>
            player.remoteWindows.isNotEmpty &&
            player.remoteWindows.last
                    .map((source) => source.track.id)
                    .join(',') ==
                'stable-third,stable-second,stable-fourth',
      );

      for (final source in player.remoteWindows.last) {
        expect(source.queueEntryId, initialIds[source.track.id]);
      }
    },
  );

  test(
    'a native current entry remains mapped when a remote source inserts before it',
    () async {
      final player = _NativeRemoteQueuePlayerService();
      final cache = _TrackingRemotePlaybackCache();
      final tracks = [
        _queuedRemoteTrack('insert-first'),
        _queuedRemoteTrack('insert-current'),
        _queuedRemoteTrack('insert-third'),
      ];
      final inserted = _queuedRemoteTrack('insert-new');
      final container = _container(player, remoteCache: cache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRemote(
        tracks[1],
        queue: tracks,
        queueSourceId: 'remote-reconcile',
      );
      final nativeCurrent = player.nativeRemoteSources.single;

      await controller.syncRemoteQueueSource('remote-reconcile', [
        inserted,
        ...tracks,
      ]);
      expect(container.read(playbackQueueProvider).currentIndex, 2);

      player.emitNativeTransition(nativeCurrent);
      await _flushCompletion();

      expect(container.read(playbackQueueProvider).currentIndex, 2);
      expect(
        container.read(playerControllerProvider).value?.trackId,
        tracks[1].id,
      );
    },
  );

  test(
    'native remote shuffle advances through the same plan it prefetched',
    () async {
      final player = _NativeRemoteQueuePlayerService();
      final cache = _TrackingRemotePlaybackCache();
      final tracks = [
        _queuedRemoteTrack('first'),
        _queuedRemoteTrack('second'),
        _queuedRemoteTrack('third'),
        _queuedRemoteTrack('fourth'),
        _queuedRemoteTrack('fifth'),
        _queuedRemoteTrack('sixth'),
      ];
      final container = _container(player, remoteCache: cache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(tracks.first, queue: tracks);
      await _waitUntil(
        () =>
            player.remoteWindows.length >= 6 &&
            player.remoteWindows.last.length == 3 &&
            cache.warmedUrls.length == 3,
        reason: 'initial native remote window did not finish warming',
      );

      final previousWindowCount = player.remoteWindows.length;
      container.read(playerControllerProvider.notifier).setShuffleEnabled(true);
      await _waitUntil(
        () =>
            player.shuffleValues.isNotEmpty &&
            player.shuffleValues.last &&
            player.remoteWindows.length > previousWindowCount &&
            player.remoteWindows.last.length == 3,
        reason: 'shuffle plan did not replace the native remote window',
      );

      final prefetchedPlan = List<RemotePlaybackSource>.of(
        player.remoteWindows.last,
      );
      expect(
        prefetchedPlan.map((source) => source.track.id).toSet(),
        hasLength(3),
      );
      expect(
        prefetchedPlan.map((source) => source.track.id),
        isNot(contains('first')),
      );

      player.emitNativeTransition(prefetchedPlan.first);
      final expectedIndex = tracks.indexWhere(
        (track) => track.id == prefetchedPlan.first.track.id,
      );
      await _waitUntil(
        () =>
            container.read(playbackQueueProvider).currentIndex == expectedIndex,
        reason: 'native shuffle transition did not update the logical index',
      );
      await _waitUntil(
        () =>
            player.remoteWindows.isNotEmpty &&
            player.remoteWindows.last.isNotEmpty &&
            player.remoteWindows.last.first.queueEntryId ==
                prefetchedPlan[1].queueEntryId,
        reason: 'native shuffle refill did not consume the prefetched plan',
      );

      expect(player.nativeRemoteStarts, 1);
    },
  );

  test('native remote repeat all wraps inside the rolling queue', () async {
    final player = _NativeRemoteQueuePlayerService();
    final cache = _TrackingRemotePlaybackCache();
    final tracks = [
      _queuedRemoteTrack('first'),
      _queuedRemoteTrack('second'),
      _queuedRemoteTrack('third'),
      _queuedRemoteTrack('fourth'),
    ];
    final container = _container(player, remoteCache: cache);
    addTearDown(container.dispose);

    await container.read(playerControllerProvider.future);
    container
        .read(playerControllerProvider.notifier)
        .setRepeatMode(PlaybackRepeatMode.all);
    await container
        .read(playerControllerProvider.notifier)
        .playRemote(tracks[2], queue: tracks);
    await _waitUntil(
      () =>
          player.remoteWindows.isNotEmpty &&
          player.remoteWindows.last.length == 3,
    );

    expect(player.remoteWindows.last.map((source) => source.track.id), [
      'fourth',
      'first',
      'second',
    ]);

    player.emitNativeTransition(player.remoteWindows.last.first);
    await _waitUntil(
      () => container.read(playbackQueueProvider).currentIndex == 3,
    );
    await _waitUntil(
      () =>
          player.remoteWindows.isNotEmpty &&
          player.remoteWindows.last.isNotEmpty &&
          player.remoteWindows.last.first.track.id == 'first',
    );
    final first = player.remoteWindows.last.first;
    player.emitNativeTransition(first);
    await _waitUntil(
      () => container.read(playbackQueueProvider).currentIndex == 0,
    );

    expect(player.nativeRemoteStarts, 1);
  });

  test(
    'shuffle repeat all keeps a full native horizon across its cycle',
    () async {
      final player = _NativeRemoteQueuePlayerService();
      final cache = _TrackingRemotePlaybackCache();
      final tracks = [
        _queuedRemoteTrack('first'),
        _queuedRemoteTrack('second'),
        _queuedRemoteTrack('third'),
        _queuedRemoteTrack('fourth'),
      ];
      final container = _container(player, remoteCache: cache);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(tracks.first, queue: tracks);
      await _waitUntil(() => player.remoteWindows.length >= 6);

      final previousWindowCount = player.remoteWindows.length;
      final controller = container.read(playerControllerProvider.notifier);
      controller.setRepeatMode(PlaybackRepeatMode.all);
      controller.setShuffleEnabled(true);
      await _waitUntil(
        () =>
            player.remoteWindows.length > previousWindowCount &&
            player.remoteWindows.last.length == 3,
      );
      final initialPlan = List<RemotePlaybackSource>.of(
        player.remoteWindows.last,
      );

      player.emitNativeTransition(initialPlan.first);
      await _waitUntil(
        () =>
            player.remoteWindows.last.length == 3 &&
            player.remoteWindows.last[0].queueEntryId ==
                initialPlan[1].queueEntryId &&
            player.remoteWindows.last[1].queueEntryId ==
                initialPlan[2].queueEntryId,
        reason: 'shuffle repeat-all let the native horizon shrink at wrap',
      );

      expect(
        player.remoteWindows.last.map((source) => source.track.id).toSet(),
        hasLength(3),
      );
      expect(player.nativeRemoteStarts, 1);
    },
  );

  test(
    'a single remote repeat-all source is marked for native looping',
    () async {
      final player = _NativeRemoteQueuePlayerService();
      final track = _queuedRemoteTrack('only');
      final container = _container(
        player,
        remoteCache: _TrackingRemotePlaybackCache(),
      );
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      container
          .read(playerControllerProvider.notifier)
          .setRepeatMode(PlaybackRepeatMode.all);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(track, queue: [track]);

      expect(player.nativeRemoteSources.single.isOnlyLogicalQueueItem, isTrue);
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

  test('a superseded local request is not written to history', () async {
    final player = _DelayedLocalPlayerService();
    final repository = _FakeLibraryRepository();
    final container = _container(player, repository: repository);
    addTearDown(container.dispose);

    await container.read(playerControllerProvider.future);
    final controller = container.read(playerControllerProvider.notifier);
    final first = controller.playLocal(_track(1), queue: [_track(1)]);
    await _waitUntil(() => player.started.contains('track-1'));
    final second = controller.playLocal(_track(2), queue: [_track(2)]);
    await _waitUntil(() => player.started.contains('track-2'));

    player.complete('track-2');
    await second;
    player.complete('track-1');
    await first;

    await _waitUntil(() => repository.playMarks.length == 1);
    expect(repository.playMarks, [(trackId: 'track-2', playlistId: null)]);
  });

  test(
    'qualified playback refreshes personalized Home without reloading generic YouTube Home',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeLibraryRepository();
      var historyBuilds = 0;
      var personalizedHomeBuilds = 0;
      var youtubeHomeBuilds = 0;
      final container = _container(
        player,
        repository: repository,
        extraOverrides: [
          historyProvider.overrideWith((ref) async {
            historyBuilds += 1;
            return const <LocalTrack>[];
          }),
          homeRecommendationsProvider.overrideWith(
            () => _CountingHomeRecommendationsController(
              () => personalizedHomeBuilds += 1,
            ),
          ),
          youtubeMusicHomeRecommendationsProvider.overrideWith((ref) async {
            youtubeHomeBuilds += 1;
            return const <HomeRecommendationSection>[];
          }),
        ],
      );
      addTearDown(container.dispose);
      container
        ..listen(historyProvider, (_, _) {}, fireImmediately: true)
        ..listen(homeRecommendationsProvider, (_, _) {}, fireImmediately: true)
        ..listen(
          youtubeMusicHomeRecommendationsProvider,
          (_, _) {},
          fireImmediately: true,
        );

      await Future.wait([
        container.read(historyProvider.future),
        container.read(homeRecommendationsProvider.future),
        container.read(youtubeMusicHomeRecommendationsProvider.future),
      ]);
      expect(historyBuilds, 1);
      expect(personalizedHomeBuilds, 1);
      expect(youtubeHomeBuilds, 1);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(_track(1), queue: [_track(1)]);

      await _waitUntil(() => repository.playMarks.length == 1);
      await _waitUntil(
        () => historyBuilds == 2 && personalizedHomeBuilds == 2,
        reason: 'Qualified playback did not refresh history and Home.',
      );

      expect(youtubeHomeBuilds, 1);
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
    'a catalog-backed playlist entry streams when its downloaded file is missing',
    () async {
      final player = _FakePlayerService();
      final missingTrack = _track(1);
      final remote = _queuedRemoteTrack('catalog-fallback-1');
      final repository = _FakeLibraryRepository()
        ..localTracks.add(missingTrack);
      final container = _container(
        player,
        repository: repository,
        fileProbe: (_) async => LocalTrackFileAvailability.missing,
      );
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRecommendation(
            RecommendationPlaybackItem(
              track: remote,
              localTrack: missingTrack,
              logicalEntryId: 'playlist-entry-1',
            ),
            queue: [
              RecommendationPlaybackItem(
                track: remote,
                localTrack: missingTrack,
                logicalEntryId: 'playlist-entry-1',
              ),
            ],
            queueSourceId: PlayerController.playlistQueueSourceId(
              'synced-playlist',
            ),
          );

      expect(player.playedLocalIds, isEmpty);
      expect(player.playedRemote.map((track) => track.id), [remote.id]);
      expect(repository.localTracks, isEmpty);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(
        container.read(playbackQueueProvider).entries.single.id,
        remote.id,
      );
    },
  );

  test(
    'external audio uses the native queue without reconciliation or history',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeLibraryRepository();
      var fileProbeCalls = 0;
      final externalTracks = [
        _track(1).copyWith(
          id: 'external:1',
          filePath: 'content://media/external/audio/media/1',
          isExternal: true,
        ),
        _track(2).copyWith(
          id: 'external:2',
          filePath: 'content://media/external/audio/media/2',
          isExternal: true,
        ),
      ];
      final container = _container(
        player,
        repository: repository,
        fileProbe: (_) async {
          fileProbeCalls++;
          return LocalTrackFileAvailability.missing;
        },
      );
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(
            externalTracks[1],
            queue: externalTracks,
            queueSourceId: 'external-folder:request-1',
          );

      expect(player.playLocalQueueCalls, 1);
      expect(player.lastLocalQueue, externalTracks);
      expect(player.lastLocalQueueIndex, 1);
      expect(fileProbeCalls, 0);
      expect(repository.playMarks, isEmpty);
      expect(
        container.read(playerControllerProvider).value?.isExternal,
        isTrue,
      );

      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          trackId: 'external:1',
          isExternal: true,
        ),
      );
      await _flushCompletion();

      expect(repository.playMarks, isEmpty);
      expect(container.read(playbackQueueProvider).currentIndex, 0);
    },
  );

  test(
    'granted folder access expands an active external queue in place',
    () async {
      final player = _FakePlayerService(supportsLocalQueueReplacement: true);
      final repository = _FakeLibraryRepository();
      final selected = _track(2).copyWith(
        id: 'external:2',
        filePath: 'content://media/external/audio/media/2',
        isExternal: true,
      );
      final expanded = [
        _track(1).copyWith(
          id: 'external:1',
          filePath: 'content://media/external/audio/media/1',
          isExternal: true,
        ),
        selected,
        _track(3).copyWith(
          id: 'external:3',
          filePath: 'content://media/external/audio/media/3',
          isExternal: true,
        ),
      ];
      final container = _container(player, repository: repository);
      addTearDown(container.dispose);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(
            selected,
            queue: [selected],
            queueSourceId: 'external-folder:request-2',
          );

      final updated = await container
          .read(playerControllerProvider.notifier)
          .syncLocalQueueSource('external-folder:request-2', expanded);

      expect(updated, isTrue);
      expect(player.replaceLocalQueueCalls, 1);
      expect(player.lastLocalQueue, expanded);
      expect(player.lastLocalQueueIndex, 1);
      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['external:1', 'external:2', 'external:3'],
      );
      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(repository.playMarks, isEmpty);
    },
  );

  test('remote LIVE queue source is reported as active', () async {
    final player = _FakePlayerService();
    final container = _container(player);
    addTearDown(container.dispose);
    final tracks = [_queuedRemoteTrack('live-1'), _queuedRemoteTrack('live-2')];

    await container.read(playerControllerProvider.future);
    final controller = container.read(playerControllerProvider.notifier);
    await controller.playRemote(
      tracks.first,
      queue: tracks,
      queueSourceId: PlayerController.liveQueueSourceId,
    );

    expect(controller.isLiveQueueActive, isTrue);
    expect(
      container.read(playbackQueueProvider).entries.map((entry) => entry.id),
      ['live-1', 'live-2'],
    );
    expect(
      container
          .read(playbackQueueProvider)
          .entries
          .every((entry) => entry.isRemote),
      isTrue,
    );
    expect(container.read(playbackQueueProvider).currentIndex, 0);
  });

  test(
    'syncing an active remote LIVE queue appends tracks without restarting',
    () async {
      final player = _FakePlayerService();
      final container = _container(player);
      addTearDown(container.dispose);
      final first = _queuedRemoteTrack('live-1');
      final expanded = [first, _queuedRemoteTrack('live-2')];

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playRemote(
        first,
        queue: [first],
        queueSourceId: PlayerController.liveQueueSourceId,
      );
      final startsBeforeSync = player.playedRemote.length;

      final updated = await controller.syncRemoteQueueSource(
        PlayerController.liveQueueSourceId,
        expanded,
      );

      expect(updated, isTrue);
      expect(player.playedRemote, hasLength(startsBeforeSync));
      expect(player.currentSnapshot.trackId, 'live-1');
      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['live-1', 'live-2'],
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
      expect(controller.isLiveQueueActive, isTrue);
    },
  );

  test('clearing the active LIVE queue releases its source', () async {
    final player = _FakePlayerService();
    final container = _container(player);
    addTearDown(container.dispose);
    final track = _queuedRemoteTrack('live-1');

    await container.read(playerControllerProvider.future);
    final controller = container.read(playerControllerProvider.notifier);
    await controller.playRemote(
      track,
      queue: [track],
      queueSourceId: PlayerController.liveQueueSourceId,
    );

    final cleared = await controller.clearQueueSource(
      PlayerController.liveQueueSourceId,
    );

    expect(cleared, isTrue);
    expect(controller.isLiveQueueActive, isFalse);
    expect(container.read(playbackQueueProvider).entries, isEmpty);
    expect(container.read(playbackQueueProvider).currentIndex, -1);
  });

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
    'deleting the current local track stops before replacing the native queue',
    () async {
      final player = _FakePlayerService(supportsLocalQueueReplacement: true);
      final container = _container(player);
      addTearDown(container.dispose);
      final tracks = [_track(1), _track(2), _track(3)];

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(tracks[1], queue: tracks);

      await container
          .read(playerControllerProvider.notifier)
          .removeDeletedLocalTracks({'track-2'});

      expect(player.stopCalls, 1);
      expect(player.replaceLocalQueueCalls, 1);
      expect(player.nativeQueueMutationCalls, [
        'stop',
        'replace:track-1,track-3',
      ]);
      expect(player.lastLocalQueue?.map((track) => track.id), [
        'track-1',
        'track-3',
      ]);
      expect(player.lastLocalQueueIndex, 0);
      expect(player.currentSnapshot.status, PlayerStatus.stopped);
      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['track-1', 'track-3'],
      );
      expect(container.read(playbackQueueProvider).currentIndex, -1);
    },
  );

  test(
    'deleting a non-current local track keeps playback and replaces the native queue',
    () async {
      final player = _FakePlayerService(supportsLocalQueueReplacement: true);
      final container = _container(player);
      addTearDown(container.dispose);
      final tracks = [_track(1), _track(2), _track(3)];

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(tracks[1], queue: tracks);

      await container
          .read(playerControllerProvider.notifier)
          .removeDeletedLocalTracks({'track-3'});

      expect(player.stopCalls, 0);
      expect(player.replaceLocalQueueCalls, 1);
      expect(player.nativeQueueMutationCalls, ['replace:track-1,track-2']);
      expect(player.lastLocalQueue?.map((track) => track.id), [
        'track-1',
        'track-2',
      ]);
      expect(player.lastLocalQueueIndex, 1);
      expect(player.currentSnapshot.status, PlayerStatus.playing);
      expect(player.currentSnapshot.trackId, 'track-2');
      expect(container.read(playbackQueueProvider).currentIndex, 1);
    },
  );

  test('deleting the only local track clears the native queue', () async {
    final player = _FakePlayerService(supportsLocalQueueReplacement: true);
    final container = _container(player);
    addTearDown(container.dispose);
    final track = _track(1);

    await container.read(playerControllerProvider.future);
    await container
        .read(playerControllerProvider.notifier)
        .playLocal(track, queue: [track]);

    await container
        .read(playerControllerProvider.notifier)
        .removeDeletedLocalTracks({'track-1'});

    expect(player.stopCalls, 1);
    expect(player.replaceLocalQueueCalls, 1);
    expect(player.nativeQueueMutationCalls, ['stop', 'replace:']);
    expect(player.lastLocalQueue, isEmpty);
    expect(player.lastLocalQueueIndex, 0);
    expect(container.read(playbackQueueProvider).entries, isEmpty);
    expect(container.read(playbackQueueProvider).currentIndex, -1);
  });

  test(
    'deleting an unrelated local id leaves the active remote queue untouched',
    () async {
      final player = _FakePlayerService(supportsLocalQueueReplacement: true);
      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          trackId: 'previous-remote',
          isRemote: true,
        ),
      );
      final container = _container(player);
      addTearDown(container.dispose);
      final remoteTracks = [
        _queuedRemoteTrack('track-1'),
        _queuedRemoteTrack('remote-2'),
      ];

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playRemote(remoteTracks.first, queue: remoteTracks);
      await _flushCompletion();
      final snapshotBeforeDelete = container
          .read(playerControllerProvider)
          .value!;
      final queueBeforeDelete = container.read(playbackQueueProvider);

      // The library id intentionally collides with the current remote id. Its
      // media type, not the string alone, determines whether playback is local.
      await container
          .read(playerControllerProvider.notifier)
          .removeDeletedLocalTracks({'track-1'});

      final snapshotAfterDelete = container
          .read(playerControllerProvider)
          .value!;
      final queueAfterDelete = container.read(playbackQueueProvider);
      expect(player.stopCalls, 0);
      expect(player.replaceLocalQueueCalls, 0);
      expect(player.nativeQueueMutationCalls, isEmpty);
      expect(snapshotAfterDelete, same(snapshotBeforeDelete));
      expect(snapshotAfterDelete.status, PlayerStatus.playing);
      expect(snapshotAfterDelete.trackId, 'track-1');
      expect(snapshotAfterDelete.isRemote, isTrue);
      expect(queueAfterDelete, same(queueBeforeDelete));
      expect(queueAfterDelete.entries.map((entry) => entry.id), [
        'track-1',
        'remote-2',
      ]);
      expect(queueAfterDelete.entries.every((entry) => entry.isRemote), isTrue);
      expect(queueAfterDelete.currentIndex, 0);
    },
  );

  test('reordering the playback queue keeps the current item active', () async {
    final player = _FakePlayerService(supportsLocalQueueReplacement: true);
    final container = _container(player);
    addTearDown(container.dispose);

    await container.read(playerControllerProvider.future);
    await container
        .read(playerControllerProvider.notifier)
        .playLocal(_track(2), queue: [_track(1), _track(2), _track(3)]);

    await container.read(playerControllerProvider.notifier).reorderQueue(0, 2);

    final queue = container.read(playbackQueueProvider);
    expect(queue.entries.map((entry) => entry.id), [
      'track-2',
      'track-3',
      'track-1',
    ]);
    expect(queue.currentIndex, 0);
    expect(player.replaceLocalQueueCalls, 1);
    expect(player.lastLocalQueueIndex, 0);
  });

  test('local playback exposes persisted album metadata to lyrics', () async {
    final player = _FakePlayerService();
    final container = _container(player);
    addTearDown(container.dispose);
    final track = _track(1).copyWith(
      album: 'InnerTube album',
      artists: const ['First Artist', 'Second Artist'],
      metadataSource: TrackMetadataSource.youtubeMusic,
      sourceId: 'youtube-video-id',
    );

    await container.read(playerControllerProvider.future);
    await container.read(playerControllerProvider.notifier).playLocal(track);

    expect(container.read(playerControllerProvider).value?.album, track.album);
    expect(
      container.read(playbackQueueProvider).entries.single.album,
      track.album,
    );
    expect(container.read(currentLyricsLookupProvider)?.album, track.album);
  });

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

      final queue = container.read(playbackQueueProvider);
      expect(queue.entries.map((entry) => entry.id), ['track-1', 'track-2']);
      final logicalEntryIds = queue.entries
          .map((entry) => entry.logicalEntryId)
          .toList(growable: false);
      expect(logicalEntryIds, everyElement(isNotNull));
      expect(logicalEntryIds.toSet(), hasLength(2));
      expect(queue.currentIndex, 0);
    },
  );

  test(
    'queue-capable mobile service keeps an editable playlist native',
    () async {
      final player = _FakePlayerService(supportsLocalQueueReplacement: true);
      final repository = _FakeLibraryRepository()
        ..localTracks.addAll([_track(1), _track(2)])
        ..playlists.add(
          Playlist(
            id: 'native-playlist',
            name: 'Native playlist',
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
              'native-playlist',
            ),
          );

      expect(player.playLocalQueueCalls, 1);
      expect(player.playedLocalIds, ['track-1']);

      await container
          .read(playlistsControllerProvider.notifier)
          .addTrackToPlaylist('native-playlist', 'track-2');

      expect(player.replaceLocalQueueCalls, 1);
      expect(player.lastLocalQueue?.map((track) => track.id), [
        'track-1',
        'track-2',
      ]);
      expect(player.lastLocalQueueIndex, 0);

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.playing, trackId: 'track-2'),
      );
      await _waitUntil(
        () =>
            repository.playMarks.isNotEmpty &&
            repository.playMarks.last ==
                (trackId: 'track-2', playlistId: 'native-playlist'),
        reason: 'The native queue transition was not recorded in its playlist.',
      );

      expect(player.playLocalQueueCalls, 1);
      expect(repository.playMarks.last, (
        trackId: 'track-2',
        playlistId: 'native-playlist',
      ));
    },
  );

  test(
    'recent playback rebuilds its playlist and keeps context on automatic next',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeLibraryRepository()
        ..localTracks.addAll([_track(1), _track(2), _track(3)])
        ..playlists.add(
          Playlist(
            id: 'recent-playlist',
            name: 'Recent playlist',
            trackIds: const ['track-3', 'track-1', 'track-2'],
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
          ),
        );
      final container = _container(player, repository: repository);
      addTearDown(container.dispose);
      final historyTrack = _track(
        1,
      ).copyWith(lastPlayedPlaylistId: 'recent-playlist');

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playFromHistory(historyTrack, fallbackQueue: [historyTrack]);

      await _waitUntil(() => repository.playMarks.isNotEmpty);

      expect(player.playLocalQueueCalls, 0);
      expect(player.playedLocalIds, ['track-1']);
      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['track-3', 'track-1', 'track-2'],
      );
      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(repository.playMarks.last, (
        trackId: 'track-1',
        playlistId: 'recent-playlist',
      ));

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.stopped, trackId: 'track-1'),
      );
      await _waitUntil(
        () => repository.playMarks.any(
          (mark) =>
              mark.trackId == 'track-2' && mark.playlistId == 'recent-playlist',
        ),
        reason: 'The automatic next track was not recorded in its playlist.',
      );

      expect(player.playedLocalIds, ['track-1', 'track-2']);
      expect(container.read(playbackQueueProvider).currentIndex, 2);
      expect(repository.playMarks.last, (
        trackId: 'track-2',
        playlistId: 'recent-playlist',
      ));
    },
  );

  test(
    'native background track changes are recorded once with playlist context',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeLibraryRepository();
      final container = _container(player, repository: repository);
      addTearDown(container.dispose);
      final tracks = [_track(1), _track(2)];

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(
            tracks.first,
            queue: tracks,
            queueSourceId: PlayerController.playlistQueueSourceId(
              'background-playlist',
            ),
          );

      await _waitUntil(() => repository.playMarks.isNotEmpty);

      expect(repository.playMarks, [
        (trackId: 'track-1', playlistId: 'background-playlist'),
      ]);

      // just_audio advances its native sequence without calling playLocal on
      // the controller. The following snapshots also model the repeated
      // position/state notifications received while the app is backgrounded.
      player.emit(
        const PlayerSnapshot(status: PlayerStatus.playing, trackId: 'track-2'),
      );
      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          trackId: 'track-2',
          position: Duration(seconds: 1),
        ),
      );
      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          trackId: 'track-2',
          position: Duration(seconds: 2),
        ),
      );
      await _waitUntil(
        () => repository.playMarks.any(
          (mark) =>
              mark.trackId == 'track-2' &&
              mark.playlistId == 'background-playlist',
        ),
        reason: 'The native background transition was not recorded.',
      );

      expect(container.read(playbackQueueProvider).currentIndex, 1);
      expect(repository.playMarks, [
        (trackId: 'track-1', playlistId: 'background-playlist'),
        (trackId: 'track-2', playlistId: 'background-playlist'),
      ]);
    },
  );

  test(
    'notification selection is recorded when it starts playing, not while paused',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeLibraryRepository();
      final container = _container(player, repository: repository);
      addTearDown(container.dispose);
      final tracks = [_track(1), _track(2)];

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(tracks.first, queue: tracks);

      await _waitUntil(() => repository.playMarks.isNotEmpty);

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.paused, trackId: 'track-2'),
      );
      await _flushCompletion();
      expect(repository.playMarks.map((mark) => mark.trackId), ['track-1']);

      player.emit(
        const PlayerSnapshot(status: PlayerStatus.playing, trackId: 'track-2'),
      );
      player.emit(
        const PlayerSnapshot(
          status: PlayerStatus.playing,
          trackId: 'track-2',
          position: Duration(milliseconds: 500),
        ),
      );
      await _flushCompletion();

      expect(repository.playMarks.map((mark) => mark.trackId), [
        'track-1',
        'track-2',
      ]);
    },
  );

  test(
    'playing the same track standalone clears old playlist context',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeLibraryRepository();
      final container = _container(player, repository: repository);
      addTearDown(container.dispose);
      final track = _track(1);

      await container.read(playerControllerProvider.future);
      final controller = container.read(playerControllerProvider.notifier);
      await controller.playLocal(
        track,
        queue: [track],
        useNativeQueue: false,
        queueSourceId: PlayerController.playlistQueueSourceId('playlist-1'),
      );
      await _waitUntil(() => repository.playMarks.length == 1);
      await controller.playLocal(track, queue: [track]);
      await _waitUntil(() => repository.playMarks.length == 2);

      expect(repository.playMarks, [
        (trackId: 'track-1', playlistId: 'playlist-1'),
        (trackId: 'track-1', playlistId: null),
      ]);
    },
  );

  test(
    'legacy history without playlist context uses its fallback queue',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeLibraryRepository()
        ..localTracks.addAll([_track(1), _track(2)]);
      final container = _container(player, repository: repository);
      addTearDown(container.dispose);
      final legacyHistoryTrack = _track(2);

      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playFromHistory(
            legacyHistoryTrack,
            fallbackQueue: [_track(1), legacyHistoryTrack],
          );

      await _waitUntil(() => repository.playMarks.isNotEmpty);

      expect(player.playLocalQueueCalls, 1);
      expect(player.lastLocalQueue?.map((track) => track.id), [
        'track-1',
        'track-2',
      ]);
      expect(player.lastLocalQueueIndex, 1);
      expect(repository.playMarks.last.playlistId, isNull);
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

  test(
    'desktop media session retries initialization and publishes retained state',
    () async {
      final player = _FakePlayerService();
      final session = _FakeDesktopMediaSession(initializationFailures: 1);
      final container = _container(
        player,
        desktopSession: session,
        desktopSessionRetryBackoff: const <Duration>[Duration.zero],
      );
      addTearDown(container.dispose);

      container.read(desktopMediaSessionProvider);
      await container.read(playerControllerProvider.future);
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(_track(1), queue: [_track(1), _track(2)]);

      await _waitUntil(
        () =>
            session.initializationCalls == 2 &&
            session.states.any((state) => state.snapshot.trackId == 'track-1'),
      );

      expect(session.callbacks, isNotNull);
      expect(session.states.last.queue.map((entry) => entry.id), [
        'track-1',
        'track-2',
      ]);
      await session.callbacks!.pause();
      await session.callbacks!.play();
      expect(player.pauseCalls, 1);
      expect(player.resumeCalls, 1);
    },
  );
}

ProviderContainer _container(
  _FakePlayerService player, {
  _FakeLibraryRepository? repository,
  AudioStreamResolver? audioResolver,
  DesktopMediaSession? desktopSession,
  LocalTrackFileProbe? fileProbe,
  RemotePlaybackCache? remoteCache,
  SettingsController? settingsController,
  RemotePlaybackRetryDelay? retryDelay,
  List<Duration>? desktopSessionRetryBackoff,
  List<Override> extraOverrides = const [],
}) {
  final resolvedRepository = repository ?? _FakeLibraryRepository();
  final catalogDatabase = _FakeCatalogDatabase(resolvedRepository);
  return ProviderContainer(
    overrides: [
      playerServiceProvider.overrideWithValue(player),
      databaseServiceProvider.overrideWithValue(catalogDatabase),
      settingsControllerProvider.overrideWith(
        () =>
            settingsController ??
            _CrossfadeSettingsController(
              const SettingsState(
                downloadDirectory: '/tmp/bstream-player-test',
                language: AppLanguage.spanish,
                recommendationHistoryEnabled: true,
              ),
            ),
      ),
      if (audioResolver != null)
        audioStreamResolverProvider.overrideWithValue(audioResolver),
      if (retryDelay != null)
        remotePlaybackRetryDelayProvider.overrideWithValue(retryDelay),
      if (desktopSession != null)
        desktopMediaSessionFactoryProvider.overrideWithValue(
          () => desktopSession,
        ),
      if (desktopSessionRetryBackoff != null)
        desktopMediaSessionRetryBackoffProvider.overrideWithValue(
          desktopSessionRetryBackoff,
        ),
      remotePlaybackCacheProvider.overrideWithValue(
        remoteCache ??
            RemotePlaybackCache(policy: RemotePlaybackCachePolicy.disabled),
      ),
      libraryRepositoryProvider.overrideWithValue(resolvedRepository),
      playbackHistorySinkProvider.overrideWithValue(
        _FakePlaybackHistorySink(resolvedRepository),
      ),
      localTrackFileProbeProvider.overrideWithValue(
        fileProbe ?? (_) async => LocalTrackFileAvailability.present,
      ),
      ...extraOverrides,
    ],
  );
}

_CrossfadeSettingsController _enabledCrossfadeSettings() {
  return _CrossfadeSettingsController(
    const SettingsState(
      downloadDirectory: '/tmp/bstream-crossfade-test',
      language: AppLanguage.spanish,
      crossfadeEnabled: true,
    ),
  );
}

LocalTrack _track(int index) {
  return LocalTrack(
    id: 'track-$index',
    title: 'Track $index',
    artist: 'BStream Music',
    filePath: 'track-$index.mp3',
    addedAt: DateTime(2026),
    duration: const Duration(milliseconds: 10),
  );
}

Future<void> _flushCompletion() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 15));
}

Future<void> _waitUntil(
  bool Function() predicate, {
  String reason = 'Timed out waiting for asynchronous playback recovery.',
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail(reason);
}

TrackInfo _remoteTrack({required String streamUrl}) {
  return _remoteTrackWithThumbnail(
    streamUrl: streamUrl,
    thumbnailUrl: 'https://i.ytimg.com/vi/q8j3zwNhLNo/hqdefault.jpg',
  );
}

TrackInfo _remoteTrackWithThumbnail({
  required String streamUrl,
  required String thumbnailUrl,
}) {
  return TrackInfo(
    id: 'q8j3zwNhLNo',
    title: 'YO SOY TU TITAN',
    artist: 'Pamorkil',
    url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
    thumbnailUrl: thumbnailUrl,
    streamUrl: streamUrl,
    httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
  );
}

TrackInfo _queuedRemoteTrack(String id) {
  return TrackInfo(
    id: id,
    title: 'Track $id',
    artist: 'BStream',
    url: 'https://www.youtube.com/watch?v=$id',
    thumbnailUrl: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
    streamUrl: 'https://media.example/$id.m4a',
  );
}

TrackInfo _unresolvedRemoteTrack(String id) {
  return TrackInfo(
    id: id,
    title: 'Track $id',
    artist: 'BStream',
    url: 'https://www.youtube.com/watch?v=$id',
    thumbnailUrl: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
  );
}

AudioStreamResolution _youtubeExplodeResolution(String id) {
  return AudioStreamResolution(
    source: AudioStreamSource.youtubeExplode,
    streamUrl: 'https://media.example/$id.webm',
    streamExtension: 'webm',
    streamMimeType: 'audio/webm',
  );
}

AudioStreamResolution _ytDlpResolution(String id) {
  return AudioStreamResolution(
    source: AudioStreamSource.ytDlp,
    streamUrl: 'https://media.example/$id.m4a',
    streamExtension: 'm4a',
    streamMimeType: 'audio/mp4',
  );
}

class _ControlledRetryDelay {
  final List<Duration> durations = [];
  final List<Completer<void>> _gates = [];
  int _nextGate = 0;

  Future<void> call(Duration duration) {
    durations.add(duration);
    final gate = Completer<void>();
    _gates.add(gate);
    return gate.future;
  }

  void releaseNext() {
    if (_nextGate >= _gates.length) {
      throw StateError('No playback retry delay is waiting.');
    }
    final gate = _gates[_nextGate++];
    if (!gate.isCompleted) {
      gate.complete();
    }
  }
}

class _SequencedAudioResolver implements AudioStreamResolver {
  _SequencedAudioResolver(this.outcomes);

  final List<Object> outcomes;
  int resolveCalls = 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    if (resolveCalls >= outcomes.length) {
      throw StateError('Unexpected resolver call ${resolveCalls + 1}.');
    }
    final outcome = outcomes[resolveCalls++];
    if (outcome is AudioStreamResolution) {
      return outcome;
    }
    throw outcome;
  }

  @override
  Future<void> dispose() async {}
}

class _ControlledAudioResolver implements AudioStreamResolver {
  final Completer<AudioStreamResolution> _resolution =
      Completer<AudioStreamResolution>();
  int resolveCalls = 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) {
    resolveCalls += 1;
    return _resolution.future;
  }

  void complete(AudioStreamResolution resolution) {
    if (!_resolution.isCompleted) {
      _resolution.complete(resolution);
    }
  }

  @override
  Future<void> dispose() async {}
}

class _ScriptedModeAwareAudioResolver
    implements AudioStreamResolver, FallbackAwareAudioStreamResolver {
  _ScriptedModeAwareAudioResolver({
    required this.primaryOutcomes,
    required this.fallbackOutcomes,
  });

  final List<Object> primaryOutcomes;
  final List<Object> fallbackOutcomes;
  final List<AudioResolutionMode> modes = [];
  int _primaryIndex = 0;
  int _fallbackIndex = 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) {
    return resolveWithMode(track);
  }

  @override
  Future<AudioStreamResolution> resolveWithMode(
    TrackInfo track, {
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
    AudioResolverFailureCallback? onResolverFailure,
    AudioResolverContinuationCallback? shouldContinue,
  }) async {
    modes.add(mode);
    if (shouldContinue != null && !shouldContinue()) {
      throw const AudioStreamResolverException(
        'Audio stream resolution was superseded.',
      );
    }
    final outcomes = mode == AudioResolutionMode.primaryThenFallback
        ? primaryOutcomes
        : fallbackOutcomes;
    final index = mode == AudioResolutionMode.primaryThenFallback
        ? _primaryIndex++
        : _fallbackIndex++;
    if (index >= outcomes.length) {
      throw StateError('Unexpected $mode resolver call ${index + 1}.');
    }
    final outcome = outcomes[index];
    if (outcome is AudioStreamResolution) {
      return outcome;
    }
    throw outcome;
  }

  @override
  Future<void> dispose() async {}
}

class _LiveRetryAudioResolver
    implements AudioStreamResolver, FallbackAwareAudioStreamResolver {
  _LiveRetryAudioResolver({required this.successfulTrackId});

  final String successfulTrackId;
  final Map<String, int> _calls = {};

  int callsFor(String trackId) => _calls[trackId] ?? 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) {
    return resolveWithMode(track);
  }

  @override
  Future<AudioStreamResolution> resolveWithMode(
    TrackInfo track, {
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
    AudioResolverFailureCallback? onResolverFailure,
    AudioResolverContinuationCallback? shouldContinue,
  }) async {
    _calls.update(track.id, (value) => value + 1, ifAbsent: () => 1);
    if (shouldContinue != null && !shouldContinue()) {
      throw const AudioStreamResolverException(
        'Audio stream resolution was superseded.',
      );
    }
    if (track.id == successfulTrackId) {
      return _ytDlpResolution(track.id);
    }
    throw SocketException('offline for ${track.id}');
  }

  @override
  Future<void> dispose() async {}
}

class _FakePlayerService implements PlayerService {
  _FakePlayerService({
    this.supportsLocalQueueReplacement = false,
    this.remotePlayError,
    this.localPlayError,
  });

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
  List<LocalTrack>? lastLocalQueue;
  int? lastLocalQueueIndex;
  int replaceLocalQueueCalls = 0;
  final List<String> nativeQueueMutationCalls = [];

  @override
  final bool supportsLocalQueueReplacement;
  final Object? remotePlayError;
  final Object? localPlayError;

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
    final error = localPlayError;
    if (error != null) {
      throw error;
    }
    emit(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id,
        sourceUrl: track.sourceUrl,
        isRemote: false,
        isExternal: track.isExternal,
      ),
    );
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) async {
    playLocalQueueCalls++;
    lastLocalQueue = List.unmodifiable(tracks);
    lastLocalQueueIndex = initialIndex;
    await playLocal(tracks[initialIndex]);
  }

  @override
  Future<void> playRemote(TrackInfo track) async {
    final error = remotePlayError;
    if (error != null) {
      throw error;
    }
    playedRemote.add(track);
    emit(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id.isEmpty ? track.url : track.id,
        sourceUrl: track.url,
        isRemote: true,
      ),
    );
  }

  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {
    replaceLocalQueueCalls++;
    lastLocalQueue = List.unmodifiable(tracks);
    lastLocalQueueIndex = preferredIndex;
    nativeQueueMutationCalls.add(
      'replace:${tracks.map((track) => track.id).join(',')}',
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
    nativeQueueMutationCalls.add('stop');
    emit(_snapshot.copyWith(status: PlayerStatus.stopped));
  }

  @override
  Future<void> togglePlayPause() async {}
}

class _PlaybackOptionsFailingPlayerService extends _FakePlayerService {
  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    throw StateError('native shuffle unavailable');
  }
}

class _BlockingPlaybackOptionsPlayerService extends _FakePlayerService {
  final Completer<void> _firstShuffleStarted = Completer<void>();
  final Completer<void> _releaseFirstShuffle = Completer<void>();
  var _didBlockFirstShuffle = false;

  Future<void> get firstShuffleRequest => _firstShuffleStarted.future;

  void releaseFirstShuffleRequest() {
    if (!_releaseFirstShuffle.isCompleted) {
      _releaseFirstShuffle.complete();
    }
  }

  @override
  Future<void> setShuffleEnabled(bool enabled) async {
    if (enabled && !_didBlockFirstShuffle) {
      _didBlockFirstShuffle = true;
      _firstShuffleStarted.complete();
      await _releaseFirstShuffle.future;
    }
    await super.setShuffleEnabled(enabled);
  }
}

class _CrossfadePlayerService extends _FakePlayerService
    implements CrossfadeCapablePlayer {
  _CrossfadePlayerService({super.supportsLocalQueueReplacement});

  final List<({bool enabled, Duration duration})> crossfadeConfigurations = [];
  final List<CrossfadePlaybackSource?> crossfadePreparations = [];
  CrossfadePlaybackSource? preparedCrossfadeSource;
  int seekCrossfadeInvalidations = 0;
  int stopCrossfadeInvalidations = 0;
  bool _crossfadeEnabled = false;
  bool blockSeeks = false;
  final List<Completer<void>> blockedSeeks = [];

  @override
  bool get crossfadeEnabled => _crossfadeEnabled;

  @override
  Future<void> configureCrossfade({
    required bool enabled,
    required Duration duration,
  }) async {
    crossfadeConfigurations.add((enabled: enabled, duration: duration));
    _crossfadeEnabled = enabled;
    if (!enabled) {
      preparedCrossfadeSource = null;
    }
  }

  @override
  Future<void> prepareCrossfade(CrossfadePlaybackSource? source) async {
    crossfadePreparations.add(source);
    preparedCrossfadeSource = source;
  }

  void emitCrossfadeHandoff(RemotePlaybackSource source) {
    final track = source.track;
    emit(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id.isEmpty ? track.url : track.id,
        queueEntryId: source.queueEntryId,
        sourceUrl: track.url,
        thumbnailUrl: track.thumbnailUrl,
        duration: track.duration,
        isRemote: true,
      ),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    seekCrossfadeInvalidations++;
    preparedCrossfadeSource = null;
    if (blockSeeks) {
      final gate = Completer<void>();
      blockedSeeks.add(gate);
      await gate.future;
    }
    await super.seek(position);
  }

  @override
  Future<void> stop() async {
    stopCrossfadeInvalidations++;
    preparedCrossfadeSource = null;
    await super.stop();
  }
}

class _BlockingCrossfadePlayerService extends _CrossfadePlayerService {
  _BlockingCrossfadePlayerService({super.supportsLocalQueueReplacement});

  Completer<void>? _blockedPreparationStarted;
  Completer<void>? _blockedPreparationRelease;
  bool _blockPending = false;

  Future<void> get blockedPreparation => _blockedPreparationStarted!.future;

  void blockNextNonNullPreparation() {
    _blockedPreparationStarted = Completer<void>();
    _blockedPreparationRelease = Completer<void>();
    _blockPending = true;
  }

  void releaseBlockedPreparation() {
    final release = _blockedPreparationRelease;
    if (release != null && !release.isCompleted) {
      release.complete();
    }
  }

  @override
  Future<void> prepareCrossfade(CrossfadePlaybackSource? source) async {
    final started = _blockedPreparationStarted;
    final release = _blockedPreparationRelease;
    if (source != null && _blockPending && started != null && release != null) {
      _blockPending = false;
      started.complete();
      await release.future;
    }
    await super.prepareCrossfade(source);
  }
}

class _CrossfadeSettingsController extends SettingsController {
  _CrossfadeSettingsController(this.initialState);

  final SettingsState initialState;

  @override
  Future<SettingsState> build() async => initialState;

  @override
  Future<void> setCrossfadeEnabled(bool enabled) {
    final current = state.asData?.value ?? initialState;
    state = AsyncData(current.copyWith(crossfadeEnabled: enabled));
    return Future<void>.value();
  }

  @override
  Future<void> setCrossfadeDuration(Duration duration) {
    final current = state.asData?.value ?? initialState;
    state = AsyncData(current.copyWith(crossfadeDuration: duration));
    return Future<void>.value();
  }

  void setUnrelatedLanguage(AppLanguage language) {
    final current = state.asData?.value ?? initialState;
    state = AsyncData(current.copyWith(language: language));
  }
}

class _DelayedLocalPlayerService extends _FakePlayerService {
  final Map<String, Completer<void>> _gates = {};
  final List<String> started = [];
  int _generation = 0;

  void complete(String trackId) => _gates[trackId]!.complete();

  @override
  Future<void> playLocal(LocalTrack track) async {
    final generation = ++_generation;
    started.add(track.id);
    final gate = Completer<void>();
    _gates[track.id] = gate;
    await gate.future;
    if (generation != _generation) {
      return;
    }
    await super.playLocal(track);
  }
}

class _BlockingRemotePlayerService extends _FakePlayerService {
  final Set<String> _blockedIds = <String>{};
  final Map<String, Completer<void>> _gates = <String, Completer<void>>{};
  final List<String> startedRemoteIds = <String>[];

  void block(String trackId) {
    _blockedIds.add(trackId);
    _gates[trackId] = Completer<void>();
  }

  void release(String trackId) {
    final gate = _gates[trackId];
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  @override
  Future<void> playRemote(TrackInfo track) async {
    startedRemoteIds.add(track.id);
    if (_blockedIds.contains(track.id)) {
      await _gates[track.id]!.future;
    }
    await super.playRemote(track);
  }
}

class _StaleOutgoingRemotePlayerService extends _FakePlayerService {
  final Completer<void> _outgoingSnapshotEmitted = Completer<void>();
  final Completer<void> _releaseReplacement = Completer<void>();

  Future<void> get outgoingSnapshotEmitted => _outgoingSnapshotEmitted.future;

  void releaseReplacement() {
    if (!_releaseReplacement.isCompleted) {
      _releaseReplacement.complete();
    }
  }

  @override
  Future<void> playRemote(TrackInfo track) async {
    if (playedRemote.isNotEmpty) {
      emit(
        currentSnapshot.copyWith(status: PlayerStatus.stopped, isRemote: false),
      );
      _outgoingSnapshotEmitted.complete();
      await _releaseReplacement.future;
    }
    await super.playRemote(track);
  }
}

class _RejectYoutubeExplodePlayerService extends _FakePlayerService {
  final List<TrackInfo> attemptedRemote = [];

  @override
  Future<void> playRemote(TrackInfo track) async {
    attemptedRemote.add(track);
    if (track.streamSource == AudioStreamSource.youtubeExplode.name) {
      emit(
        PlayerSnapshot(
          status: PlayerStatus.failed,
          trackId: track.id,
          sourceUrl: track.url,
          isRemote: true,
          errorMessage: 'Source error: format is not supported',
        ),
      );
      throw Exception('Source error: format is not supported');
    }
    await super.playRemote(track);
  }
}

class _ReadyYtDlpFallbackPlayerService
    extends _RejectYoutubeExplodePlayerService {
  @override
  Future<void> playRemote(TrackInfo track) async {
    if (track.streamSource == AudioStreamSource.youtubeExplode.name) {
      return super.playRemote(track);
    }
    attemptedRemote.add(track);
    playedRemote.add(track);
    emit(
      PlayerSnapshot(
        status: PlayerStatus.stopped,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id,
        sourceUrl: track.url,
        duration: const Duration(minutes: 3),
        isRemote: true,
      ),
    );
  }
}

class _LatePrimaryFailurePlayerService extends _FakePlayerService {
  final List<TrackInfo> attemptedRemote = [];
  final Completer<void> _primaryCompletion = Completer<void>();

  @override
  Future<void> playRemote(TrackInfo track) async {
    attemptedRemote.add(track);
    if (track.streamSource == AudioStreamSource.youtubeExplode.name) {
      emit(
        PlayerSnapshot(
          status: PlayerStatus.failed,
          trackId: track.id,
          sourceUrl: track.url,
          isRemote: true,
          errorMessage: 'HTTP 403 from primary stream',
        ),
      );
      await _primaryCompletion.future;
      return;
    }
    await super.playRemote(track);
  }

  void completePrimaryWithError() {
    _primaryCompletion.completeError(Exception('Late HTTP 403'));
  }
}

class _BlockedOriginalPrimaryFailurePlayerService extends _FakePlayerService {
  final List<TrackInfo> attemptedRemote = [];
  final Completer<void> _originalCompletion = Completer<void>();

  @override
  Future<void> playRemote(TrackInfo track) async {
    attemptedRemote.add(track);
    if (attemptedRemote.length == 1) {
      emit(
        PlayerSnapshot(
          status: PlayerStatus.failed,
          title: track.title,
          artist: track.artist,
          trackId: track.id,
          sourceUrl: track.url,
          isRemote: true,
          errorMessage: 'HTTP 503 while the original open is still pending',
        ),
      );
      await _originalCompletion.future;
      return;
    }
    throw SocketException(
      'HTTP 503 from retry primary ${attemptedRemote.length}',
    );
  }

  void completeOriginalWithError() {
    if (!_originalCompletion.isCompleted) {
      _originalCompletion.completeError(
        const SocketException('late HTTP 503 from the original open Future'),
      );
    }
  }
}

class _BlockedOriginalPrimarySuccessPlayerService extends _FakePlayerService {
  final List<TrackInfo> attemptedRemote = [];
  final Completer<void> _originalCompletion = Completer<void>();

  @override
  Future<void> playRemote(TrackInfo track) async {
    attemptedRemote.add(track);
    if (attemptedRemote.length == 1) {
      emit(
        PlayerSnapshot(
          status: PlayerStatus.failed,
          title: track.title,
          artist: track.artist,
          trackId: track.id,
          sourceUrl: track.url,
          isRemote: true,
          errorMessage: 'HTTP 503 while the original open is still pending',
        ),
      );
      await _originalCompletion.future;
      return;
    }
    await super.playRemote(track);
  }

  void completeOriginalSuccessfully() {
    if (!_originalCompletion.isCompleted) {
      _originalCompletion.complete();
    }
  }
}

class _PendingRetryFailurePlayerService extends _FakePlayerService {
  final List<TrackInfo> attemptedRemote = [];
  final Completer<void> _retryAttemptStarted = Completer<void>();
  final Completer<void> _retryCompletion = Completer<void>();

  Future<void> get retryAttemptStarted => _retryAttemptStarted.future;

  @override
  Future<void> playRemote(TrackInfo track) async {
    attemptedRemote.add(track);
    if (attemptedRemote.length == 1) {
      throw const SocketException('HTTP 503 from the initial primary source');
    }
    if (attemptedRemote.length != 2) {
      throw StateError('Unexpected remote attempt ${attemptedRemote.length}.');
    }
    emit(
      PlayerSnapshot(
        status: PlayerStatus.failed,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.url,
        isRemote: true,
        errorMessage: 'HTTP 503 while retry Future is pending',
      ),
    );
    if (!_retryAttemptStarted.isCompleted) {
      _retryAttemptStarted.complete();
    }
    await _retryCompletion.future;
    await super.playRemote(track);
  }

  void completeRetrySuccessfully() {
    if (!_retryCompletion.isCompleted) {
      _retryCompletion.complete();
    }
  }
}

class _ModeAwareFallbackAudioResolver
    implements AudioStreamResolver, FallbackAwareAudioStreamResolver {
  _ModeAwareFallbackAudioResolver({this.fallbackGate});

  final Future<void>? fallbackGate;
  final List<AudioResolutionMode> modes = [];

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) {
    return resolveWithMode(track);
  }

  @override
  Future<AudioStreamResolution> resolveWithMode(
    TrackInfo track, {
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
    AudioResolverFailureCallback? onResolverFailure,
    AudioResolverContinuationCallback? shouldContinue,
  }) async {
    modes.add(mode);
    if (mode == AudioResolutionMode.fallbackOnly && fallbackGate != null) {
      await fallbackGate;
    }
    return switch (mode) {
      AudioResolutionMode.primaryThenFallback => const AudioStreamResolution(
        source: AudioStreamSource.youtubeExplode,
        streamUrl: 'https://media.example/primary.webm',
        streamExtension: 'webm',
        streamMimeType: 'audio/webm',
        formatId: '251',
        codec: 'opus',
      ),
      AudioResolutionMode.fallbackOnly => const AudioStreamResolution(
        source: AudioStreamSource.ytDlp,
        streamUrl: 'https://media.example/fallback.m4a',
        streamExtension: 'm4a',
        streamMimeType: 'audio/mp4',
        formatId: '140',
        codec: 'mp4a.40.2',
      ),
    };
  }

  @override
  Future<void> dispose() async {}
}

class _NativeRemoteQueuePlayerService extends _FakePlayerService
    implements NativeRemoteQueuePlayer {
  _NativeRemoteQueuePlayerService({this.failCachedOpen = false});

  bool failCachedOpen;
  int cachedOpenFailures = 0;
  int nativeRemoteStarts = 0;
  final List<RemotePlaybackSource> nativeRemoteSources = [];
  final List<List<RemotePlaybackSource>> remoteWindows = [];
  final List<bool> remoteWindowFinalizations = [];

  @override
  Future<void> playRemoteSource(RemotePlaybackSource source) async {
    if (failCachedOpen && source.uri.scheme == 'file') {
      failCachedOpen = false;
      cachedOpenFailures++;
      throw StateError('simulated native cache decoder failure');
    }
    nativeRemoteStarts++;
    nativeRemoteSources.add(source);
    playedRemote.add(source.track);
    emit(_remoteSnapshot(source));
  }

  @override
  Future<void> updateRemoteQueue(
    List<RemotePlaybackSource> upcoming, {
    bool finalize = true,
  }) async {
    remoteWindows.add(List.unmodifiable(upcoming));
    remoteWindowFinalizations.add(finalize);
  }

  void emitNativeTransition(RemotePlaybackSource source) {
    emit(_remoteSnapshot(source));
  }

  PlayerSnapshot _remoteSnapshot(RemotePlaybackSource source) {
    final track = source.track;
    return PlayerSnapshot(
      status: PlayerStatus.playing,
      title: track.title,
      artist: track.artist,
      trackId: track.id.isEmpty ? track.url : track.id,
      queueEntryId: source.queueEntryId,
      sourceUrl: track.url,
      thumbnailUrl: track.thumbnailUrl,
      duration: track.duration,
      isRemote: true,
    );
  }
}

class _BlockingNativeCrossfadePlayerService
    extends _NativeRemoteQueuePlayerService
    implements CrossfadeCapablePlayer {
  final List<({bool enabled, Duration duration})> crossfadeConfigurations = [];
  final List<CrossfadePlaybackSource?> crossfadePreparations = [];
  CrossfadePlaybackSource? preparedCrossfadeSource;
  bool _crossfadeEnabled = false;
  Completer<void>? _blockedPreparationStarted;
  Completer<void>? _blockedPreparationRelease;
  bool _blockPending = false;

  Future<void> get blockedPreparation => _blockedPreparationStarted!.future;

  void blockNextNullPreparation() {
    _blockedPreparationStarted = Completer<void>();
    _blockedPreparationRelease = Completer<void>();
    _blockPending = true;
  }

  void releaseBlockedPreparation() {
    final release = _blockedPreparationRelease;
    if (release != null && !release.isCompleted) {
      release.complete();
    }
  }

  @override
  bool get crossfadeEnabled => _crossfadeEnabled;

  @override
  Future<void> configureCrossfade({
    required bool enabled,
    required Duration duration,
  }) async {
    crossfadeConfigurations.add((enabled: enabled, duration: duration));
    _crossfadeEnabled = enabled;
    if (!enabled) {
      preparedCrossfadeSource = null;
    }
  }

  @override
  Future<void> prepareCrossfade(CrossfadePlaybackSource? source) async {
    final started = _blockedPreparationStarted;
    final release = _blockedPreparationRelease;
    if (source == null && _blockPending && started != null && release != null) {
      _blockPending = false;
      started.complete();
      await release.future;
    }
    crossfadePreparations.add(source);
    preparedCrossfadeSource = source;
  }
}

class _FakeRemotePlaybackCache extends RemotePlaybackCache {
  _FakeRemotePlaybackCache(this.file, {this.missesBeforeHit = 0})
    : super(policy: RemotePlaybackCachePolicy.disabled);

  final File file;
  final int missesBeforeHit;
  int lookupCalls = 0;
  int evictCalls = 0;

  @override
  Future<File?> cachedFile(TrackInfo track) async {
    lookupCalls++;
    return lookupCalls <= missesBeforeHit ? null : file;
  }

  @override
  Future<void> evict(TrackInfo track) async {
    evictCalls++;
  }
}

class _CrossfadeRemotePlaybackCache extends RemotePlaybackCache {
  _CrossfadeRemotePlaybackCache({
    required this.cachedTrackId,
    required this.file,
  }) : super(policy: RemotePlaybackCachePolicy.android);

  final String cachedTrackId;
  final File file;
  final List<String> cachedLookups = [];

  @override
  Future<File?> cachedFile(TrackInfo track) async {
    cachedLookups.add(track.id);
    return track.id == cachedTrackId ? file : null;
  }

  @override
  Future<File?> warmResolved(
    TrackInfo track, {
    bool cancelOnSearchChange = false,
  }) async {
    return null;
  }

  @override
  Future<void> retainOnlyTracks(Iterable<TrackInfo> tracks) async {}

  @override
  void protectPlaybackWindow(Iterable<TrackInfo> tracks) {}

  @override
  Future<void> prepareSession({
    Iterable<String> protectedSourceUrls = const <String>[],
  }) async {}
}

class _TrackingRemotePlaybackCache extends RemotePlaybackCache {
  _TrackingRemotePlaybackCache({
    this.failCachedLookupUrl,
    this.failCachedLookupOnCall,
  }) : super(policy: RemotePlaybackCachePolicy.android);

  final List<List<String>> retainedWindows = [];
  final List<List<String>> protectedWindows = [];
  final List<List<String>> preparedSources = [];
  final List<String> warmedUrls = [];
  final Map<String, int> cachedLookupCalls = {};
  final String? failCachedLookupUrl;
  final int? failCachedLookupOnCall;

  @override
  Future<File?> cachedFile(TrackInfo track) async {
    final calls = (cachedLookupCalls[track.url] ?? 0) + 1;
    cachedLookupCalls[track.url] = calls;
    if (track.url == failCachedLookupUrl && calls == failCachedLookupOnCall) {
      throw StateError('simulated cache lookup failure');
    }
    return null;
  }

  @override
  Future<void> retainOnlyTracks(Iterable<TrackInfo> tracks) async {
    retainedWindows.add(tracks.map((track) => track.url).toList());
  }

  @override
  void protectPlaybackWindow(Iterable<TrackInfo> tracks) {
    protectedWindows.add(tracks.map((track) => track.url).toList());
  }

  @override
  Future<void> prepareSession({
    Iterable<String> protectedSourceUrls = const <String>[],
  }) async {
    preparedSources.add(protectedSourceUrls.toList());
  }

  @override
  Future<File?> warmResolved(
    TrackInfo track, {
    bool cancelOnSearchChange = false,
  }) async {
    warmedUrls.add(track.url);
    return File('remote-cache-${track.id}.m4a');
  }
}

class _FakeDesktopMediaSession implements DesktopMediaSession {
  _FakeDesktopMediaSession({this.initializationFailures = 0});

  final int initializationFailures;
  DesktopMediaSessionCallbacks? callbacks;
  final List<DesktopMediaSessionState> states = [];
  bool disposed = false;
  int initializationCalls = 0;

  @override
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks) async {
    initializationCalls++;
    if (initializationCalls <= initializationFailures) {
      throw StateError('native media session unavailable');
    }
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

class _DelayedRefreshMusicRepository extends _FakeMusicRepository {
  _DelayedRefreshMusicRepository(TrackInfo initial) : super([initial]);

  final Completer<TrackInfo> _refresh = Completer<TrackInfo>();

  @override
  Future<TrackInfo> getInfo(String url) {
    infoCalls++;
    if (infoCalls == 1) {
      return Future<TrackInfo>.value(responses.first);
    }
    return _refresh.future;
  }

  void completeRefresh(TrackInfo track) {
    if (!_refresh.isCompleted) {
      _refresh.complete(track);
    }
  }
}

/// Wraps a [_FakeMusicRepository] as an [AudioStreamResolver] for the
/// player tests. It reuses the same response pool and call counter so the
/// existing assertions on `infoCalls` keep working.
class _FakeAudioResolverFromRepository implements AudioStreamResolver {
  _FakeAudioResolverFromRepository(this._repository);

  final _FakeMusicRepository _repository;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    final response = await _repository.getPlaybackInfo(track.url);
    return AudioStreamResolution(
      source: AudioStreamSource.ytDlp,
      streamUrl: response.streamUrl ?? '',
      streamExtension: response.streamExtension,
      streamMimeType: response.streamMimeType,
      httpHeaders: response.httpHeaders == null
          ? null
          : Map<String, String>.unmodifiable(response.httpHeaders!),
      videoId: track.id.isEmpty ? null : track.id,
      formatId: response.extractor,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _FakeCatalogDatabase extends LocalDatabaseService {
  _FakeCatalogDatabase(this._repository);

  final _FakeLibraryRepository _repository;
  final Map<String, List<PlaylistEntry>> _entriesByPlaylist = {};

  @override
  Future<List<Playlist>> getCatalogPlaylists({
    bool includeDeleted = false,
  }) async {
    for (final playlist in _repository.playlists) {
      _seedEntries(playlist);
    }
    return _repository.playlists
        .where((playlist) => includeDeleted || playlist.deletedAt == null)
        .toList(growable: false);
  }

  @override
  Future<CatalogPlaylist?> getCatalogPlaylist(
    String playlistId, {
    bool includeDeletedEntries = false,
  }) async {
    final playlist = _repository.playlists
        .where((candidate) => candidate.id == playlistId)
        .firstOrNull;
    if (playlist == null) {
      return null;
    }
    _seedEntries(playlist);
    final entries = _entriesByPlaylist[playlistId]!;
    return CatalogPlaylist(
      playlist: playlist,
      entries: entries.where(
        (entry) => includeDeletedEntries || !entry.isDeleted,
      ),
    );
  }

  @override
  Future<PlaylistEntry> appendCatalogEntry({
    required String playlistId,
    required String entryId,
    required CatalogTrack track,
    required DateTime now,
    String? localTrackId,
    PlaylistEntryOrigin origin = PlaylistEntryOrigin.local,
  }) async {
    final playlistIndex = _repository.playlists.indexWhere(
      (playlist) => playlist.id == playlistId,
    );
    if (playlistIndex < 0) {
      throw StateError('Missing fake catalog playlist: $playlistId');
    }
    final playlist = _repository.playlists[playlistIndex];
    _seedEntries(playlist);
    final entries = _entriesByPlaylist[playlistId]!;
    final entry = PlaylistEntry(
      id: entryId,
      playlistId: playlistId,
      track: track,
      localTrackId: localTrackId,
      position: entries.where((entry) => !entry.isDeleted).length,
      origin: origin,
      createdAt: now,
      updatedAt: now,
    );
    entries.add(entry);
    _repository.playlists[playlistIndex] = playlist.copyWith(
      trackIds: <String>[...playlist.trackIds, ?localTrackId],
      updatedAt: now,
      localRevision: playlist.localRevision + 1,
    );
    return entry;
  }

  void _seedEntries(Playlist playlist) {
    if (_entriesByPlaylist.containsKey(playlist.id)) {
      return;
    }
    final localById = <String, LocalTrack>{
      for (final track in _repository.localTracks) track.id: track,
    };
    final entries = <PlaylistEntry>[];
    for (var position = 0; position < playlist.trackIds.length; position++) {
      final localTrackId = playlist.trackIds[position];
      final local = localById[localTrackId];
      if (local == null) {
        continue;
      }
      entries.add(
        PlaylistEntry(
          id: 'fake:${playlist.id}:$position',
          playlistId: playlist.id,
          track: CatalogTrack.local(
            localTrackId: local.id,
            title: local.title,
            artists: local.artists.isEmpty
                ? <String>[local.artist]
                : local.artists,
            artistBrowseIds: local.artistBrowseIds,
            album: local.album,
            duration: local.duration,
            thumbnailUrl: local.thumbnailUrl,
            sourceUrl: local.sourceUrl,
          ),
          localTrackId: local.id,
          position: entries.length,
          createdAt: playlist.createdAt,
          updatedAt: playlist.updatedAt,
        ),
      );
    }
    _entriesByPlaylist[playlist.id] = entries;
  }
}

class _FakeLibraryRepository implements LibraryRepository {
  final List<LocalTrack> localTracks = [];
  final List<Playlist> playlists = [];
  final List<({String trackId, String? playlistId})> playMarks = [];

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
  Future<void> markPlayed(
    String trackId,
    DateTime playedAt, {
    String? playlistId,
  }) async {
    playMarks.add((trackId: trackId, playlistId: playlistId));
  }

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

class _FakePlaybackHistorySink implements PlaybackHistorySink {
  _FakePlaybackHistorySink(this.repository);

  final _FakeLibraryRepository repository;
  final List<PlaybackHistoryWrite> writes = [];

  @override
  Future<void> persist(PlaybackHistoryWrite write) async {
    writes.add(write);
    final trackId = write.track.localTrackId;
    if (write.isInitialQualification && trackId != null) {
      await repository.markPlayed(
        trackId,
        write.event.playedAt,
        playlistId: write.track.playlistId,
      );
    }
  }
}

class _CountingHomeRecommendationsController
    extends HomeRecommendationsController {
  _CountingHomeRecommendationsController(this.onBuild);

  final void Function() onBuild;

  @override
  Future<List<HomeRecommendationSection>> build() async {
    onBuild();
    return const <HomeRecommendationSection>[];
  }
}
