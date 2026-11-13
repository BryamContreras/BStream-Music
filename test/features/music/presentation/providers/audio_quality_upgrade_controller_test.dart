import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/audio_source_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/audio_sources/audio_network_monitor.dart';
import 'package:bstream_music/services/audio_sources/audio_source_policy.dart';
import 'package:bstream_music/services/audio_sources/audio_format_details.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/media_session/desktop_media_session.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final nativeQueue in [false, true]) {
    for (final selection in ['library', 'catalog']) {
      for (final scenario in [
        'improve',
        'already-high',
        'standard',
        'disabled',
        'lossless',
        'standard-low',
      ]) {
        test(
          '$selection download $scenario (nativeQueue=$nativeQueue)',
          () async {
            final directory = await Directory.systemTemp.createTemp(
              'bstream-owned-audio-',
            );
            addTearDown(() => directory.delete(recursive: true));
            final file = await File(
              '${directory.path}/owned.m4a',
            ).writeAsBytes([1, 2, 3]);
            final track = _track('owned-$scenario');
            final local = LocalTrack(
              id: 'download-${track.id}',
              title: track.title,
              artist: track.artist,
              filePath: file.path,
              addedAt: DateTime(2026),
              sourceId: track.id,
              sourceUrl: track.url,
              duration: track.duration,
              audioFormat: AudioFormatDetails(
                codec: scenario == 'lossless' ? 'pcm_s16le' : 'aac',
                mimeType: 'audio/mp4',
                bitrate: scenario == 'lossless'
                    ? null
                    : (scenario == 'improve' || scenario == 'standard-low'
                          ? 96000
                          : 320000),
                sampleRate: 44100,
                channels: 2,
              ),
            );
            final fixture = _Fixture(
              nativeQueue: nativeQueue,
              libraryTracks: [local],
              settings: _settings(
                jioSaavnEnabled: scenario != 'disabled',
                wifiAudioQuality: scenario.startsWith('standard')
                    ? AudioQualityProfile.standard
                    : AudioQualityProfile.high,
              ),
            );
            addTearDown(fixture.dispose);
            await fixture.ready();
            if (selection == 'library') {
              await fixture.controller.playLocal(local, queue: [local]);
            } else {
              await fixture.controller.playRemote(track);
            }
            expect(fixture.player.started.single.uri, file.uri);
            expect(
              fixture.player.started.single.track.streamBitrate,
              local.audioFormat!.bitrate,
            );
            expect(fixture.resolver.calls, 0);
            expect(fixture.player.localPlayCalls, 0);
            expect(fixture.player.currentSnapshot.status, PlayerStatus.playing);
            if (scenario == 'improve') {
              await _until(() => fixture.lookupRequests.isNotEmpty);
              fixture.player.emit(
                fixture.player.currentSnapshot.copyWith(
                  position: const Duration(seconds: 31),
                ),
              );
              fixture.complete(track.id, _upgrade(track.id));
              await _until(() => fixture.player.upgraded.isNotEmpty);
              expect(
                fixture.player.currentSnapshot.position,
                const Duration(seconds: 31),
              );
              expect(fixture.player.started, hasLength(1));
            } else {
              await _flush();
              expect(fixture.lookupRequests, isEmpty);
              expect(fixture.player.upgraded, isEmpty);
            }
            expect(await file.readAsBytes(), [1, 2, 3]);
          },
        );
      }
    }
  }

  for (final action in ['reorder', 'delete-file', 'delete-after-upgrade']) {
    test('a downloaded transport handles $action safely', () async {
      final directory = await Directory.systemTemp.createTemp(
        'bstream-download-queue-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/owned.m4a',
      ).writeAsBytes([1, 2, 3]);
      final track = _track('download-queue');
      final local = LocalTrack(
        id: 'download-local-id',
        title: track.title,
        artist: track.artist,
        filePath: file.path,
        addedAt: DateTime(2026),
        sourceId: track.id,
        sourceUrl: track.url,
        duration: track.duration,
        audioFormat: const AudioFormatDetails(codec: 'aac', bitrate: 96000),
      );
      final other = local.copyWith(
        id: 'other-local',
        sourceId: 'other-remote',
        sourceUrl: 'https://music.youtube.com/watch?v=other-remote',
      );
      final fixture = _Fixture(
        nativeQueue: false,
        libraryTracks: [local, other],
      );
      addTearDown(fixture.dispose);
      await fixture.ready();
      const source = PlayerController.downloadedLibraryQueueSourceId;
      await fixture.controller.playLocal(
        local,
        queue: [local, other],
        queueSourceId: source,
      );
      await _until(() => fixture.lookupRequests.isNotEmpty);
      fixture.player.emit(
        fixture.player.currentSnapshot.copyWith(
          position: const Duration(seconds: 31),
        ),
      );
      if (action == 'delete-file') {
        await fixture.controller.removeDeletedLocalTracks({local.id});
        expect(fixture.player.currentSnapshot.status, PlayerStatus.stopped);
        fixture.complete(track.id, _upgrade(track.id));
        await _flush();
        expect(fixture.player.upgraded, isEmpty);
        return;
      }
      if (action == 'reorder') {
        await fixture.controller.syncLocalQueueSource(source, [other, local]);
        expect(fixture.container.read(playbackQueueProvider).currentIndex, 1);
        expect(fixture.lookupRequests.single.shouldContinue!(), isTrue);
      }
      fixture.complete(track.id, _upgrade(track.id));
      await _until(() => fixture.player.upgraded.isNotEmpty);
      if (action == 'delete-after-upgrade') {
        await fixture.controller.removeDeletedLocalTracks({local.id});
      }
      expect(fixture.player.currentSnapshot.status, PlayerStatus.playing);
      expect(
        fixture.player.currentSnapshot.position,
        const Duration(seconds: 31),
      );
      expect(
        fixture.controller.currentRemoteTrackFor(track.url)?.streamSource,
        'jioSaavn',
      );
      expect(fixture.player.started, hasLength(1));
    });
  }

  test(
    'desktop uses its sole profile without reading or retrying the network',
    () async {
      var reads = 0;
      final fixture = _Fixture(
        singleProfile: true,
        nativeQueue: false,
        networkReader: () async {
          reads++;
          return AudioNetworkKind.unknown;
        },
      );
      addTearDown(fixture.dispose);
      await fixture.ready();
      final track = _track('desktop-single-profile');
      await fixture.controller.playRemote(track);
      await _until(() => fixture.lookupRequests.isNotEmpty);
      expect(reads, 0);
      fixture.complete(track.id, null);
      await _flush();
      for (var second = 1; second <= 12; second++) {
        fixture.player.emit(
          fixture.player.currentSnapshot.copyWith(
            position: Duration(seconds: second),
          ),
        );
      }
      await _flush();
      expect(fixture.lookupRequests, hasLength(1));
      expect(reads, 0);
    },
  );

  test(
    'desktop upgrade status has a logical queue identity before promotion',
    () async {
      final fixture = _Fixture(nativeQueue: false);
      addTearDown(fixture.dispose);
      await fixture.ready();
      final track = _track('desktop-status');
      await fixture.controller.playRemote(track);
      await _until(() => fixture.lookupRequests.isNotEmpty);

      expect(
        fixture.player.currentSnapshot.queueEntryId,
        isNull,
        reason: 'Decorating presentation must not alter the physical backend.',
      );
      final presented = fixture.container.read(playerControllerProvider).value!;
      final upgrade = fixture.container.read(audioQualityUpgradeStateProvider);
      expect(presented.queueEntryId, isNotNull);
      expect(presented.queueEntryId, upgrade.queueEntryId);
      expect(upgrade.active, isTrue);
      expect(fixture.player.upgraded, isEmpty);
      fixture.complete(track.id, null);
      await _flush();
    },
  );

  for (final unavailable in [
    AudioNetworkKind.unknown,
    AudioNetworkKind.offline,
  ]) {
    test(
      '$unavailable gets only two bounded network retries per selection',
      () async {
        var now = DateTime.utc(2026);
        var reads = 0;
        final fixture = _Fixture(
          networkReader: () async {
            reads++;
            return unavailable;
          },
          networkClock: () => now,
        );
        addTearDown(fixture.dispose);
        await fixture.ready();
        await fixture.controller.playRemote(_track('bounded-network'));
        await _until(() => reads == 1);
        await _flush();
        void tick() => fixture.player.emit(
          fixture.player.currentSnapshot.copyWith(
            position: const Duration(seconds: 1),
          ),
        );
        for (var index = 0; index < 8; index++) {
          tick();
        }
        await _flush();
        expect(reads, 1);

        now = now.add(const Duration(seconds: 3));
        tick();
        await _until(() => reads == 2);
        await _flush();
        now = now.add(const Duration(seconds: 7));
        tick();
        await _flush();
        expect(reads, 2);
        now = now.add(const Duration(seconds: 1));
        tick();
        await _until(() => reads == 3);
        await _flush();

        now = now.add(const Duration(hours: 1));
        for (var index = 0; index < 8; index++) {
          tick();
        }
        await _flush();
        expect(reads, 3);
        expect(fixture.lookupRequests, isEmpty);
        expect(fixture.player.upgraded, isEmpty);
        await fixture.controller.playRemote(_track('next-network-selection'));
        await _until(() => reads == 4);
        expect(fixture.lookupRequests, isEmpty);
      },
    );
  }

  test(
    'unknown startup can become a Wi-Fi upgrade without changing songs',
    () async {
      var now = DateTime.utc(2026);
      var reads = 0;
      final fixture = _Fixture(
        networkReader: () async =>
            ++reads == 1 ? AudioNetworkKind.unknown : AudioNetworkKind.wifi,
        networkClock: () => now,
      );
      addTearDown(fixture.dispose);
      await fixture.ready();
      final track = _track('network-recovers');
      await fixture.controller.playRemote(track);
      await _until(() => reads == 1);
      await _flush();
      expect(fixture.lookupRequests, isEmpty);

      now = now.add(const Duration(seconds: 3));
      fixture.player.emit(
        fixture.player.currentSnapshot.copyWith(
          position: const Duration(seconds: 4),
        ),
      );
      await _until(() => fixture.lookupRequests.isNotEmpty);
      expect(reads, 2);
      fixture.complete(track.id, _upgrade(track.id));
      await _until(() => fixture.player.upgraded.isNotEmpty);
      expect(fixture.player.currentSnapshot.trackId, track.id);
      expect(
        fixture.player.currentSnapshot.position,
        const Duration(seconds: 4),
      );
    },
  );

  test(
    'promotion waits for an already issued native queue update before using its new revision',
    () async {
      final fixture = _Fixture(
        settings: _settings(wifiAudioQuality: AudioQualityProfile.standard),
      );
      addTearDown(fixture.dispose);
      await fixture.ready();
      final native = fixture.player as _Player;
      final heldUpdate = Completer<void>();
      native.nextQueueMutationGate = heldUpdate;
      addTearDown(() {
        if (!heldUpdate.isCompleted) heldUpdate.complete();
      });
      final track = _track('held-native-update');
      await fixture.controller.playRemote(
        track,
        queue: [track, _track('successor')],
      );
      await _until(() => native.queueUpdateCalls > 0);
      fixture.settings.change(wifiAudioQuality: AudioQualityProfile.high);
      native.emit(
        native.currentSnapshot.copyWith(position: const Duration(seconds: 3)),
      );
      await _until(() => fixture.lookupRequests.isNotEmpty);
      fixture.complete(track.id, _upgrade(track.id));
      await _flush();
      expect(native.upgraded, isEmpty);
      expect(
        fixture.container.read(audioQualityUpgradeStateProvider).active,
        isTrue,
      );
      heldUpdate.complete();
      await _until(() => native.upgraded.isNotEmpty);
      expect(
        native.operations.indexOf('queue-update-finished'),
        lessThan(native.operations.indexOf('upgrade')),
      );
      expect(native.currentSnapshot.trackId, track.id);
      expect(native.currentSnapshot.position, const Duration(seconds: 3));
    },
  );

  test(
    'an upgrade clears unknown format details instead of inheriting the YouTube sample rate and channels',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.ready();
      final track = _track(
        'format-details',
      ).copyWith(streamSampleRate: 48000, streamChannels: 2);
      await fixture.controller.playRemote(track);
      await _until(() => fixture.lookupRequests.isNotEmpty);
      fixture.complete(track.id, _upgrade(track.id));
      await _until(() => fixture.player.upgraded.isNotEmpty);
      await _flush();
      final current = fixture.controller.currentRemoteTrackFor(track.url)!;
      expect(current.streamBitrate, 320000);
      expect(current.streamSampleRate, isNull);
      expect(current.streamChannels, isNull);
      expect(fixture.player.upgraded.single.track.streamSampleRate, isNull);
      expect(fixture.player.upgraded.single.track.streamChannels, isNull);
    },
  );

  test(
    'promotion and later catalog enrichment retain the actual new audio format',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.ready();
      final track = _track(
        'measured-format',
      ).copyWith(streamSampleRate: 48000, streamChannels: 2);
      await fixture.controller.playRemote(track);
      await _until(() => fixture.lookupRequests.isNotEmpty);
      fixture.complete(
        track.id,
        AudioStreamResolution(
          source: AudioStreamSource.jioSaavn,
          streamUrl: 'https://jio.example/${track.id}.m4a',
          streamExtension: 'm4a',
          streamMimeType: 'audio/mp4',
          codec: 'aac',
          bitrate: 325929,
          sampleRate: 44100,
          channels: 1,
          formatId: 'jio-${track.id}',
        ),
      );
      await _until(() => fixture.player.upgraded.isNotEmpty);
      await _flush();
      expect(
        fixture.controller.enrichCurrentRemoteTrackMetadata(
          track.copyWith(title: 'Updated catalog title'),
        ),
        isTrue,
      );
      final current = fixture.controller.currentRemoteTrackFor(track.url)!;
      final prepared = fixture.controller.preparedAudioSourceFor(track.url)!;
      for (final audible in [
        current,
        prepared.track,
        fixture.player.upgraded.single.track,
      ]) {
        expect(audible.streamSource, 'jioSaavn');
        expect(audible.streamCodec, 'aac');
        expect(audible.streamBitrate, 325929);
        expect(audible.streamSampleRate, 44100);
        expect(audible.streamChannels, 1);
      }
      expect(current.title, 'Updated catalog title');
      expect(fixture.player.started, hasLength(1));
    },
  );

  test(
    'replaying a previously upgraded track under disabled or standard policy starts from YouTube again',
    () async {
      for (final settings in [
        _settings(jioSaavnEnabled: false),
        _settings(wifiAudioQuality: AudioQualityProfile.standard),
      ]) {
        final fixture = _Fixture(settings: settings);
        await fixture.ready();
        final track = _track('replay-upgraded').copyWith(
          streamSource: 'jioSaavn',
          streamUrl: 'https://jio.example/old.m4a',
          streamBitrate: 320000,
          streamFormatId: 'old-jio',
        );
        await fixture.controller.playRemote(track);
        await _flush();
        expect(fixture.player.started.single.uri.host, 'yt.example');
        expect(fixture.player.started.single.track.streamSource, 'innerTube');
        expect(fixture.player.started.single.track.streamBitrate, 128000);
        expect(fixture.lookupRequests, isEmpty);
        expect(fixture.player.currentSnapshot.title, track.title);
        expect(fixture.player.currentSnapshot.trackId, track.id);
        await fixture.dispose();
      }
    },
  );

  test(
    'desktop cached audio retains remote identity and can upgrade without a native remote queue',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bstream-desktop-quality-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File(
        '${directory.path}/cached.m4a',
      ).writeAsBytes([1, 2, 3]);
      final fixture = _Fixture(nativeQueue: false, cache: _CachedFile(file));
      addTearDown(fixture.dispose);
      await fixture.ready();
      final track = _track('desktop-cached');
      await fixture.controller.playRemote(track);
      await _until(() => fixture.lookupRequests.isNotEmpty);
      expect(fixture.player, isNot(isA<NativeRemoteQueuePlayer>()));
      expect(fixture.player.started.single.uri, file.uri);
      expect(fixture.player.localPlayCalls, 0);
      expect(fixture.player.currentSnapshot.isRemote, isTrue);
      expect(fixture.player.currentSnapshot.trackId, track.id);
      fixture.player.emit(
        fixture.player.currentSnapshot.copyWith(
          position: const Duration(seconds: 27),
        ),
      );
      fixture.complete(track.id, _upgrade(track.id));
      await _until(() => fixture.player.upgraded.isNotEmpty);
      await _flush();
      expect(
        fixture.player.currentSnapshot.position,
        const Duration(seconds: 27),
      );
      expect(fixture.player.currentSnapshot.trackId, track.id);
      expect(
        fixture.controller.currentRemoteTrackFor(track.url)?.streamSource,
        'jioSaavn',
      );
      expect(fixture.player.started, hasLength(1));
    },
  );

  test(
    'YouTube starts before the optional lookup and the upgrade keeps logical metadata and position',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.ready();
      final first = _track('first');
      final second = _track('second');
      await fixture.controller.playRemote(first, queue: [first, second]);
      await _until(() => fixture.lookupRequests.isNotEmpty);
      expect(fixture.player.started.first.track.streamSource, 'innerTube');
      expect(fixture.player.currentSnapshot.status, PlayerStatus.playing);
      expect(fixture.player.upgraded, isEmpty);
      expect(
        fixture.container.read(audioQualityUpgradeStateProvider).active,
        isTrue,
      );
      final queueBefore = fixture.container.read(playbackQueueProvider);
      final entryBefore = fixture.player.currentSnapshot.queueEntryId;
      fixture.player.emit(
        fixture.player.currentSnapshot.copyWith(
          position: const Duration(seconds: 42),
        ),
      );

      fixture.complete(first.id, _upgrade(first.id));
      await _until(() => fixture.player.upgraded.isNotEmpty);
      await _flush();
      final snapshot = fixture.container.read(playerControllerProvider).value!;
      final current = fixture.controller.currentRemoteTrackFor(first.url)!;
      final queueAfter = fixture.container.read(playbackQueueProvider);
      expect(fixture.player.started, hasLength(1));
      expect(snapshot.status, PlayerStatus.playing);
      expect(snapshot.position, const Duration(seconds: 42));
      expect(snapshot.trackId, first.id);
      expect(snapshot.queueEntryId, entryBefore);
      expect(snapshot.title, first.title);
      expect(snapshot.artist, first.artist);
      expect(snapshot.album, first.album);
      expect(snapshot.thumbnailUrl, first.thumbnailUrl);
      expect(current.url, first.url);
      expect(current.id, first.id);
      expect(current.artists, first.artists);
      expect(current.artistBrowseIds, first.artistBrowseIds);
      expect(current.streamSource, 'jioSaavn');
      expect(current.streamBitrate, 320000);
      expect(
        queueAfter.entries.map((entry) => entry.id),
        queueBefore.entries.map((entry) => entry.id),
      );
      expect(queueAfter.currentIndex, queueBefore.currentIndex);
      expect(
        fixture.container.read(audioQualityUpgradeStateProvider).active,
        isFalse,
      );
    },
  );

  for (final network in [
    AudioNetworkKind.mobile,
    AudioNetworkKind.offline,
    AudioNetworkKind.unknown,
  ]) {
    test(
      '$network standard profile does not start a secondary lookup',
      () async {
        final fixture = _Fixture(network: network);
        addTearDown(fixture.dispose);
        await fixture.ready();
        await fixture.controller.playRemote(_track('standard'));
        await _flush();
        expect(fixture.player.currentSnapshot.status, PlayerStatus.playing);
        expect(fixture.lookupRequests, isEmpty);
        expect(fixture.player.upgraded, isEmpty);
        expect(
          fixture.container.read(audioQualityUpgradeStateProvider).active,
          isFalse,
        );
      },
    );
  }

  test(
    'disabled JioSaavn and an explicit standard Wi-Fi profile do not look up',
    () async {
      for (final state in [
        _settings(jioSaavnEnabled: false),
        _settings(wifiAudioQuality: AudioQualityProfile.standard),
      ]) {
        final fixture = _Fixture(settings: state);
        await fixture.ready();
        await fixture.controller.playRemote(_track('disabled'));
        await _flush();
        expect(fixture.lookupRequests, isEmpty);
        expect(fixture.player.upgraded, isEmpty);
        await fixture.dispose();
      }
    },
  );

  test('an explicit high mobile profile uses the same upgrade path', () async {
    final fixture = _Fixture(
      network: AudioNetworkKind.mobile,
      settings: _settings(mobileAudioQuality: AudioQualityProfile.high),
    );
    addTearDown(fixture.dispose);
    await fixture.ready();
    final track = _track('mobile-high');
    await fixture.controller.playRemote(track);
    await _until(() => fixture.lookupRequests.isNotEmpty);
    fixture.complete(track.id, _upgrade(track.id));
    await _until(() => fixture.player.upgraded.isNotEmpty);
    expect(fixture.player.currentSnapshot.trackId, track.id);
    expect(fixture.player.currentSnapshot.status, PlayerStatus.playing);
  });

  for (final outcome in [
    'missing',
    'error',
    'not-better',
    'backend-declines',
  ]) {
    test(
      '$outcome leaves the original source playing without restarting',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        await fixture.ready();
        final track = _track(outcome);
        await fixture.controller.playRemote(track);
        await _until(() => fixture.lookupRequests.isNotEmpty);
        fixture.player.emit(
          fixture.player.currentSnapshot.copyWith(
            position: const Duration(seconds: 14),
          ),
        );
        if (outcome == 'error') {
          fixture.fail(track.id, StateError('optional source unavailable'));
        } else if (outcome == 'not-better') {
          fixture.complete(
            track.id,
            AudioStreamResolution(
              source: AudioStreamSource.jioSaavn,
              streamUrl: 'https://cdn.example/low.m4a',
              bitrate: 96000,
            ),
          );
        } else {
          fixture.player.allowPromotion = outcome != 'backend-declines';
          fixture.complete(
            track.id,
            outcome == 'missing' ? null : _upgrade(track.id),
          );
        }
        await _until(
          () =>
              !fixture.container.read(audioQualityUpgradeStateProvider).active,
        );
        expect(fixture.player.currentSnapshot.status, PlayerStatus.playing);
        expect(
          fixture.player.currentSnapshot.position,
          const Duration(seconds: 14),
        );
        expect(fixture.player.started, hasLength(1));
        expect(fixture.player.upgraded, isEmpty);
        expect(
          fixture.controller.currentRemoteTrackFor(track.url)?.streamSource,
          'innerTube',
        );
        fixture.player.emit(
          fixture.player.currentSnapshot.copyWith(
            position: const Duration(seconds: 15),
          ),
        );
        await _flush();
        expect(
          fixture.lookupRequests,
          hasLength(1),
          reason:
              'Position ticks must not repeatedly search a missing upgrade.',
        );
      },
    );
  }

  test(
    'rapid skips cannot promote the delayed result of an old selection',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.ready();
      final tracks = [_track('old'), _track('middle'), _track('latest')];
      await fixture.controller.playRemote(tracks.first, queue: tracks);
      await _until(
        () =>
            fixture.lookupRequests.any((request) => request.track.id == 'old'),
      );
      await fixture.controller.playNext();
      await _until(() => fixture.player.currentSnapshot.trackId == 'middle');
      await fixture.controller.playNext();
      await _until(() => fixture.player.currentSnapshot.trackId == 'latest');
      await _until(
        () => fixture.lookupRequests.any(
          (request) => request.track.id == 'latest',
        ),
      );
      fixture.complete('old', _upgrade('old'));
      fixture.complete('middle', _upgrade('middle'));
      await _flush();
      expect(fixture.player.upgraded, isEmpty);
      expect(fixture.player.currentSnapshot.trackId, 'latest');
      fixture.complete('latest', _upgrade('latest'));
      await _until(() => fixture.player.upgraded.isNotEmpty);
      expect(fixture.player.upgraded.single.track.id, 'latest');
      expect(fixture.container.read(playbackQueueProvider).currentIndex, 2);
    },
  );

  for (final action in ['seek', 'pause', 'policy', 'network']) {
    test(
      '$action while looking up invalidates the pending promotion',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        await fixture.ready();
        final track = _track('cancel-$action');
        await fixture.controller.playRemote(track);
        await _until(() => fixture.lookupRequests.isNotEmpty);
        switch (action) {
          case 'seek':
            await fixture.controller.seek(const Duration(seconds: 51));
          case 'pause':
            await fixture.controller.pause();
          case 'policy':
            fixture.settings.change(jioSaavnEnabled: false);
          case 'network':
            fixture.networkChanges.add(AudioNetworkKind.mobile);
        }
        expect(fixture.lookupRequests.first.shouldContinue?.call(), isFalse);
        fixture.complete(track.id, _upgrade(track.id));
        await _flush();
        expect(fixture.player.upgraded, isEmpty);
        expect(fixture.player.started, hasLength(1));
        expect(
          fixture.controller.currentRemoteTrackFor(track.url)?.streamSource,
          'innerTube',
        );
        if (action == 'pause') {
          expect(fixture.player.currentSnapshot.status, PlayerStatus.paused);
        }
        if (action == 'seek') {
          expect(
            fixture.player.currentSnapshot.position,
            const Duration(seconds: 51),
          );
        }
      },
    );
  }
}

SettingsState _settings({
  bool jioSaavnEnabled = true,
  AudioQualityProfile wifiAudioQuality = AudioQualityProfile.high,
  AudioQualityProfile mobileAudioQuality = AudioQualityProfile.standard,
}) => SettingsState(
  downloadDirectory: '/tmp/bstream-quality-tests',
  language: AppLanguage.spanish,
  recommendationHistoryEnabled: false,
  jioSaavnEnabled: jioSaavnEnabled,
  wifiAudioQuality: wifiAudioQuality,
  mobileAudioQuality: mobileAudioQuality,
);

TrackInfo _track(String id) => TrackInfo(
  id: id,
  title: 'Catalog $id',
  artist: 'BStream Music',
  artists: const ['BStream Music'],
  artistBrowseIds: const ['catalog-artist'],
  album: 'Catalog album',
  url: 'https://music.youtube.com/watch?v=$id',
  thumbnailUrl: 'https://art.example/$id.jpg',
  duration: const Duration(minutes: 3),
  streamUrl: 'https://yt.example/$id.m4a',
  streamSource: 'innerTube',
  streamBitrate: 128000,
  streamCodec: 'aac',
  streamExtension: 'm4a',
  metadataSource: TrackMetadataSource.youtubeMusic,
);

AudioStreamResolution _upgrade(String id) => AudioStreamResolution(
  source: AudioStreamSource.jioSaavn,
  streamUrl: 'https://jio.example/$id.m4a',
  streamExtension: 'm4a',
  streamMimeType: 'audio/mp4',
  codec: 'aac',
  bitrate: 320000,
  formatId: 'jio-$id',
);

class _LookupRequest {
  const _LookupRequest(this.track, this.shouldContinue, this.gate);
  final TrackInfo track;
  final bool Function()? shouldContinue;
  final Completer<AudioStreamResolution?> gate;
}

class _Fixture {
  _Fixture({
    AudioNetworkKind network = AudioNetworkKind.wifi,
    SettingsState? settings,
    bool nativeQueue = true,
    bool singleProfile = false,
    RemotePlaybackCache? cache,
    AudioNetworkReader? networkReader,
    DateTime Function()? networkClock,
    List<LocalTrack> libraryTracks = const [],
  }) : settings = _Settings(settings ?? _settings()),
       player = nativeQueue ? _Player() : _DesktopPlayer() {
    monitor = AudioNetworkMonitor(
      reader: networkReader ?? () async => network,
      changes: networkChanges.stream,
      clock: networkClock,
    );
    container = ProviderContainer(
      overrides: [
        audioSourceUsesSingleProfileProvider.overrideWithValue(singleProfile),
        playerControllerProvider.overrideWith(
          () => PlayerController(
            remotePrefetchCoordinator: RemotePrefetchCoordinator(
              additionalWarmupDelay: Duration.zero,
            ),
          ),
        ),
        playerServiceProvider.overrideWithValue(player),
        settingsControllerProvider.overrideWith(() => this.settings),
        audioNetworkMonitorProvider.overrideWithValue(monitor),
        audioSourceUpgradeLookupProvider.overrideWithValue((
          track, {
          currentBitrate,
          shouldContinue,
        }) {
          final gate = Completer<AudioStreamResolution?>();
          lookupRequests.add(_LookupRequest(track, shouldContinue, gate));
          return gate.future;
        }),
        audioStreamResolverProvider.overrideWithValue(resolver),
        libraryRepositoryProvider.overrideWithValue(_Library(libraryTracks)),
        databaseServiceProvider.overrideWithValue(_Database()),
        remotePlaybackCacheProvider.overrideWithValue(
          cache ??
              RemotePlaybackCache(policy: RemotePlaybackCachePolicy.disabled),
        ),
        playbackHistorySinkProvider.overrideWithValue(_History()),
        desktopMediaSessionFactoryProvider.overrideWithValue(() => _Session()),
      ],
    );
  }
  final _BasePlayer player;
  final resolver = _YtResolver();
  final _Settings settings;
  final lookupRequests = <_LookupRequest>[];
  final networkChanges = StreamController<AudioNetworkKind>.broadcast(
    sync: true,
  );
  late final AudioNetworkMonitor monitor;
  late final ProviderContainer container;
  PlayerController get controller =>
      container.read(playerControllerProvider.notifier);
  Future<void> ready() async {
    await container.read(settingsControllerProvider.future);
    await container.read(playerControllerProvider.future);
  }

  void complete(String id, AudioStreamResolution? result) {
    for (final request in lookupRequests.where(
      (request) => request.track.id == id && !request.gate.isCompleted,
    )) {
      request.gate.complete(result);
    }
  }

  void fail(String id, Object error) {
    for (final request in lookupRequests.where(
      (request) => request.track.id == id && !request.gate.isCompleted,
    )) {
      request.gate.completeError(error);
    }
  }

  Future<void> dispose() async {
    container.dispose();
    for (final request in lookupRequests) {
      if (!request.gate.isCompleted) request.gate.complete(null);
    }
    await monitor.dispose();
    await networkChanges.close();
    await player.dispose();
  }
}

class _Settings extends SettingsController {
  _Settings(this.initial);
  final SettingsState initial;
  @override
  Future<SettingsState> build() async => initial;
  void change({bool? jioSaavnEnabled, AudioQualityProfile? wifiAudioQuality}) =>
      state = AsyncData(
        state.requireValue.copyWith(
          jioSaavnEnabled: jioSaavnEnabled,
          wifiAudioQuality: wifiAudioQuality,
        ),
      );
}

class _BasePlayer implements PlayerService, AudioSourceUpgradePlayer {
  final _events = StreamController<PlayerSnapshot>.broadcast(sync: true);
  PlayerSnapshot _snapshot = const PlayerSnapshot(status: PlayerStatus.idle);
  final started = <RemotePlaybackSource>[];
  final upgraded = <RemotePlaybackSource>[];
  final operations = <String>[];
  bool allowPromotion = true;
  int localPlayCalls = 0;
  @override
  PlayerSnapshot get currentSnapshot => _snapshot;
  @override
  Stream<PlayerSnapshot> get snapshotStream => _events.stream;
  @override
  bool get supportsLocalQueueReplacement => false;
  void emit(PlayerSnapshot value) {
    _snapshot = value;
    _events.add(value);
  }

  Future<void> _start(
    RemotePlaybackSource source, {
    bool includeQueueId = true,
  }) async {
    started.add(source);
    final track = source.track;
    emit(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        playWhenReady: true,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id,
        queueEntryId: includeQueueId ? source.queueEntryId : null,
        sourceUrl: track.url,
        thumbnailUrl: track.thumbnailUrl,
        duration: track.duration,
        isRemote: true,
      ),
    );
  }

  @override
  Future<bool> upgradeRemoteSource(
    RemotePlaybackSource source, {
    bool Function()? shouldContinue,
  }) async {
    if (!allowPromotion ||
        shouldContinue?.call() == false ||
        (_snapshot.queueEntryId != null &&
            source.queueEntryId != _snapshot.queueEntryId)) {
      return false;
    }
    upgraded.add(source);
    operations.add('upgrade');
    emit(_snapshot);
    return true;
  }

  @override
  Future<void> pause() async => emit(
    _snapshot.copyWith(status: PlayerStatus.paused, playWhenReady: false),
  );
  @override
  Future<void> resume() async => emit(
    _snapshot.copyWith(status: PlayerStatus.playing, playWhenReady: true),
  );
  @override
  Future<void> seek(Duration position) async =>
      emit(_snapshot.copyWith(position: position));
  @override
  Future<void> stop() async => emit(
    _snapshot.copyWith(status: PlayerStatus.stopped, playWhenReady: false),
  );
  @override
  Future<void> setVolume(double volume) async =>
      emit(_snapshot.copyWith(volume: volume));
  @override
  Future<void> setShuffleEnabled(bool enabled) async =>
      emit(_snapshot.copyWith(shuffleEnabled: enabled));
  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async =>
      emit(_snapshot.copyWith(repeatMode: mode));
  @override
  Future<void> togglePlayPause() async =>
      _snapshot.wantsToPlay ? pause() : resume();
  @override
  Future<void> dispose() async => _events.close();
  @override
  Future<void> playRemote(TrackInfo track) => _start(
    RemotePlaybackSource(
      track: track,
      uri: Uri.parse(track.streamUrl!),
      queueEntryId: 'desktop-${track.id}',
    ),
    includeQueueId: false,
  );
  @override
  Future<void> playLocal(LocalTrack track) {
    localPlayCalls++;
    throw StateError('No cached local fallback in this fixture');
  }

  @override
  Future<void> playLocalQueue(List<LocalTrack> tracks, int initialIndex) =>
      throw StateError('No local queue in this fixture');
  @override
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {}
}

class _Player extends _BasePlayer implements NativeRemoteQueuePlayer {
  Completer<void>? nextQueueMutationGate;
  int queueUpdateCalls = 0;
  @override
  Future<void> playRemoteSource(RemotePlaybackSource source) => _start(source);
  @override
  Future<void> updateRemoteQueue(
    List<RemotePlaybackSource> upcoming, {
    bool finalize = true,
  }) async {
    queueUpdateCalls++;
    final gate = nextQueueMutationGate;
    nextQueueMutationGate = null;
    if (gate != null) await gate.future;
    operations.add('queue-update-finished');
  }
}

class _DesktopPlayer extends _BasePlayer {}

class _CachedFile extends RemotePlaybackCache {
  _CachedFile(this.file) : super(policy: RemotePlaybackCachePolicy.disabled);
  final File file;
  @override
  Future<File?> cachedFile(TrackInfo track) async => file;
}

class _YtResolver implements AudioStreamResolver {
  int calls = 0;
  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    calls++;
    return AudioStreamResolution(
      source: AudioStreamSource.innerTube,
      streamUrl: 'https://yt.example/${track.id}.m4a',
      streamExtension: 'm4a',
      streamMimeType: 'audio/mp4',
      codec: 'aac',
      bitrate: 128000,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _Library implements LibraryRepository {
  _Library([this.tracks = const []]);
  final List<LocalTrack> tracks;
  @override
  Future<List<LocalTrack>> getLocalTracks() async => tracks;
  @override
  Future<List<LocalTrack>> getHistory() async => const [];
  @override
  Future<List<Playlist>> getPlaylists() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Database extends LocalDatabaseService {
  @override
  Future<List<Playlist>> getCatalogPlaylists({
    bool includeDeleted = false,
  }) async => const [];
}

class _History implements PlaybackHistorySink {
  @override
  Future<void> persist(PlaybackHistoryWrite write) async {}
}

class _Session implements DesktopMediaSession {
  @override
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks) async {}
  @override
  Future<void> update(DesktopMediaSessionState state) async {}
  @override
  Future<void> dispose() async {}
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 15));
}

Future<void> _until(bool Function() condition) async {
  for (var index = 0; index < 100; index++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the audio quality coordinator');
}
