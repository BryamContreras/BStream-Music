import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/media_session/desktop_media_session.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    'an asynchronous remote failure refreshes its stream once without skipping the song',
    () async {
      final player = _FakePlayerService();
      final repository = _FakeMusicRepository([
        _remoteTrack(streamUrl: 'https://media.example/first.m4a'),
        _remoteTrack(streamUrl: 'https://media.example/refreshed.m4a'),
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

      expect(repository.infoCalls, 2);
      expect(player.playedRemote, hasLength(2));
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

  test(
    'a rejected youtube_explode stream shows its error and switches to yt-dlp once',
    () async {
      final player = _RejectYoutubeExplodePlayerService();
      final resolver = _ModeAwareFallbackAudioResolver();
      final container = _container(player, audioResolver: resolver);
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
              value.value?.errorMessage?.contains(
                'youtube_explode_dart falló',
              ) ==
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
      await _flushCompletion();

      expect(resolver.modes, hasLength(2));
      expect(
        container.read(playerControllerProvider).requireValue.errorMessage,
        contains('yt-dlp fallback'),
      );
    },
  );

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

    expect(repository.playMarks, [(trackId: 'track-2', playlistId: null)]);
  });

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

      expect(
        container.read(playbackQueueProvider).entries.map((entry) => entry.id),
        ['track-1', 'track-2'],
      );
      expect(container.read(playbackQueueProvider).currentIndex, 0);
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
      await _flushCompletion();

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
      await _flushCompletion();

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
      await _flushCompletion();

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
      await controller.playLocal(track, queue: [track]);

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
}

ProviderContainer _container(
  _FakePlayerService player, {
  _FakeLibraryRepository? repository,
  AudioStreamResolver? audioResolver,
  DesktopMediaSession? desktopSession,
  LocalTrackFileProbe? fileProbe,
  RemotePlaybackCache? remoteCache,
}) {
  return ProviderContainer(
    overrides: [
      playerServiceProvider.overrideWithValue(player),
      if (audioResolver != null)
        audioStreamResolverProvider.overrideWithValue(audioResolver),
      if (desktopSession != null)
        desktopMediaSessionFactoryProvider.overrideWithValue(
          () => desktopSession,
        ),
      remotePlaybackCacheProvider.overrideWithValue(
        remoteCache ??
            RemotePlaybackCache(policy: RemotePlaybackCachePolicy.disabled),
      ),
      libraryRepositoryProvider.overrideWithValue(
        repository ?? _FakeLibraryRepository(),
      ),
      localTrackFileProbeProvider.overrideWithValue(
        fileProbe ?? (_) async => LocalTrackFileAvailability.present,
      ),
    ],
  );
}

LocalTrack _track(int index) {
  return LocalTrack(
    id: 'track-$index',
    title: 'Track $index',
    artist: 'BStream Music',
    filePath: 'track-$index.mp3',
    addedAt: DateTime(2026),
  );
}

Future<void> _flushCompletion() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
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
  DesktopMediaSessionCallbacks? callbacks;
  final List<DesktopMediaSessionState> states = [];
  bool disposed = false;

  @override
  Future<void> initialize(DesktopMediaSessionCallbacks callbacks) async {
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
