import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/platform_channels/android_ytdl_channel.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/downloader/fallback_audio_resolver.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_explode_audio_resolver.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_explode_runtime.dart';
import 'package:bstream_music/services/downloader/desktop_tool_locator.dart';
import 'package:bstream_music/services/player/just_audio_player_service.dart';
import 'package:bstream_music/services/player/media_kit_player_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _liveTests = bool.fromEnvironment(
  'BSTREAM_LIVE_TESTS',
  defaultValue: false,
);
const _probeOnly = bool.fromEnvironment(
  'BSTREAM_PROBE_ONLY',
  defaultValue: false,
);
const _videoUrls = String.fromEnvironment(
  'BSTREAM_TEST_VIDEO_URLS',
  defaultValue: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('youtube_explode resolves and plays on the native target', (
    tester,
  ) async {
    if (!_liveTests) {
      return;
    }
    expect(
      AppPlatform.isWindows || AppPlatform.isAndroid,
      isTrue,
      reason: 'This integration test targets Windows and Android only.',
    );

    final runtime = YoutubeExplodeRuntime(
      platform: AppPlatform.current,
      androidChannel: AppPlatform.isAndroid ? AndroidYtdlChannel() : null,
      denoExecutable: AppPlatform.isDesktop
          ? findBundledDenoExecutable()
          : null,
    );
    final resolver = YoutubeExplodeAudioResolver(runtime: runtime);
    final PlayerService player = AppPlatform.isWindows
        ? MediaKitPlayerService()
        : JustAudioPlayerService();
    final snapshots = <PlayerSnapshot>[];
    final subscription = player.snapshotStream.listen((snapshot) {
      snapshots.add(snapshot);
      developer.log(
        'status=${snapshot.status.name}, position=${snapshot.position}, '
        'duration=${snapshot.duration}, error=${snapshot.errorMessage ?? ''}',
        name: 'BStreamLivePlayback',
      );
    });

    try {
      for (final url in _requestedUrls()) {
        final source = await _resolve(resolver, url);
        expect(source.source, AudioStreamSource.youtubeExplode);
        expect(source.streamUrl, startsWith('http'));
        expect(source.streamExtension, isNotEmpty);

        final track = TrackInfo(
          id: url,
          title: 'BStream live integration test',
          artist: 'BStream Music',
          url: url,
          streamUrl: source.streamUrl,
          streamExtension: source.streamExtension,
          streamMimeType: source.streamMimeType,
          streamSource: source.source.name,
          streamFormatId: source.formatId,
          streamCodec: source.codec,
          httpHeaders: source.httpHeaders,
        );

        if (_probeOnly) {
          debugPrint('probe-only ${await _probeStream(track)}');
          continue;
        }
        await _playAndExercise(player, track, snapshots, url);
      }
    } finally {
      await subscription.cancel();
      await player.dispose();
      await resolver.dispose();
      await runtime.dispose();
    }
  });

  testWidgets('production player controller keeps youtube_explode as source', (
    tester,
  ) async {
    if (!_liveTests) {
      return;
    }
    expect(
      AppPlatform.isWindows || AppPlatform.isAndroid,
      isTrue,
      reason: 'This integration test targets Windows and Android only.',
    );

    final runtime = YoutubeExplodeRuntime(
      platform: AppPlatform.current,
      androidChannel: AppPlatform.isAndroid ? AndroidYtdlChannel() : null,
      denoExecutable: AppPlatform.isDesktop
          ? findBundledDenoExecutable()
          : null,
    );
    final primary = YoutubeExplodeAudioResolver(runtime: runtime);
    final unexpectedFallback = _UnexpectedFallbackResolver();
    final resolver = FallbackAudioResolver([primary, unexpectedFallback]);
    final container = ProviderContainer(
      overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
    );
    try {
      await container.read(playerControllerProvider.future);
      final url = _requestedUrls().first;
      final track = TrackInfo(
        id: url,
        title: 'BStream controller integration test',
        artist: 'BStream Music',
        url: url,
      );
      await container.read(remotePlaybackCacheProvider).evict(track);

      await container.read(playerControllerProvider.notifier).playRemote(track);
      final snapshot = await _waitForControllerSnapshot(
        container,
        (snapshot) => snapshot.status == PlayerStatus.playing,
      );

      expect(snapshot.status, PlayerStatus.playing);
      expect(unexpectedFallback.called, isFalse);
      await container.read(playerServiceProvider).stop();
    } finally {
      await container.read(playerServiceProvider).dispose();
      container.dispose();
      await resolver.dispose();
      await runtime.dispose();
    }
  });
}

List<String> _requestedUrls() {
  return _videoUrls
      .split(',')
      .map((url) => url.trim())
      .where((url) => url.isNotEmpty)
      .toList(growable: false);
}

Future<AudioStreamResolution> _resolve(
  YoutubeExplodeAudioResolver resolver,
  String url,
) async {
  final stopwatch = Stopwatch()..start();
  try {
    final result = await resolver
        .resolve(
          TrackInfo(
            id: url,
            title: 'BStream live integration test',
            artist: 'BStream Music',
            url: url,
          ),
        )
        .timeout(const Duration(seconds: 90));
    developer.log(
      'resolved ${_safeSource(url)} in ${stopwatch.elapsedMilliseconds}ms; '
      'format=${result.formatId}, extension=${result.streamExtension}, '
      'codec=${result.codec}',
      name: 'BStreamLivePlayback',
    );
    return result;
  } catch (error, stackTrace) {
    developer.log(
      'resolve failed for ${_safeSource(url)} after '
      '${stopwatch.elapsedMilliseconds}ms',
      name: 'BStreamLivePlayback',
      error: error,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

Future<void> _playAndExercise(
  PlayerService player,
  TrackInfo track,
  List<PlayerSnapshot> snapshots,
  String sourceUrl,
) async {
  snapshots.clear();
  var probe = 'not-run';
  try {
    probe = await _probeStream(track);
    developer.log('preplay probe $probe', name: 'BStreamLivePlayback');
    final playingFuture = _waitForSnapshot(
      player.snapshotStream,
      (snapshot) => snapshot.status == PlayerStatus.playing,
    );
    await player.playRemote(track).timeout(const Duration(seconds: 60));
    final playing = await playingFuture;
    expect(playing.status, PlayerStatus.playing);
    final progressed = await _waitForSnapshot(
      player.snapshotStream,
      (snapshot) => snapshot.position > Duration.zero,
    );
    expect(progressed.position, greaterThan(Duration.zero));
    developer.log(
      'playing format=${track.streamExtension ?? 'unknown'}, '
      'duration=${playing.duration ?? progressed.duration ?? track.duration}, '
      'position=${progressed.position}',
      name: 'BStreamLivePlayback',
    );

    final pausedFuture = _waitForSnapshot(
      player.snapshotStream,
      (snapshot) => snapshot.status == PlayerStatus.paused,
    );
    await player.pause().timeout(const Duration(seconds: 15));
    final paused = await pausedFuture;
    expect(paused.status, PlayerStatus.paused);

    final resumedFuture = _waitForSnapshot(
      player.snapshotStream,
      (snapshot) => snapshot.status == PlayerStatus.playing,
    );
    await player.resume().timeout(const Duration(seconds: 15));
    final resumed = await resumedFuture;
    expect(resumed.status, PlayerStatus.playing);

    const target = Duration(seconds: 2);
    final seekFuture = _waitForSnapshot(
      player.snapshotStream,
      (snapshot) => snapshot.position >= target,
    );
    await player.seek(target).timeout(const Duration(seconds: 15));
    final seeked = await seekFuture;
    expect(seeked.position, greaterThanOrEqualTo(target));

    final stoppedFuture = _waitForSnapshot(
      player.snapshotStream,
      (snapshot) => snapshot.status == PlayerStatus.stopped,
    );
    await player.stop().timeout(const Duration(seconds: 15));
    final stopped = await stoppedFuture;
    expect(stopped.status, PlayerStatus.stopped);
  } catch (error, stackTrace) {
    final current = player.currentSnapshot;
    final detail = _sanitizeError(current.errorMessage ?? error.toString());
    throw StateError(
      'Native playback failed for ${_safeSource(sourceUrl)}: $detail; '
      'probe=$probe\n'
      '$stackTrace',
    );
  }
}

Future<String> _probeStream(TrackInfo track) async {
  final source = track.streamUrl;
  if (source == null || source.trim().isEmpty) {
    return 'missing-url';
  }
  final uri = Uri.tryParse(source);
  if (uri == null) {
    return 'invalid-url';
  }
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..idleTimeout = const Duration(seconds: 6);
  try {
    final results = <String>[];
    for (final range in const ['bytes=0-15', 'bytes=0-']) {
      final request = await client.getUrl(uri);
      for (final entry
          in track.httpHeaders?.entries ?? const <MapEntry<String, String>>[]) {
        final name = entry.key.trim().toLowerCase();
        if (name == 'content-length' || name == 'host' || name == 'range') {
          continue;
        }
        request.headers.set(entry.key, entry.value);
      }
      request.headers.set(HttpHeaders.rangeHeader, range);
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      List<int> bytes = const [];
      try {
        bytes = await response.first.timeout(const Duration(seconds: 8));
      } on StateError {
        // Some rejected range requests close without a response body.
      }
      results.add(
        '$range=${response.statusCode}/'
        '${response.headers.contentType?.mimeType ?? 'none'}/'
        '${bytes.length}/'
        '${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}',
      );
    }
    return results.join('; ');
  } catch (error) {
    return 'error=${_sanitizeError(error.toString())}';
  } finally {
    client.close(force: true);
  }
}

Future<PlayerSnapshot> _waitForSnapshot(
  Stream<PlayerSnapshot> snapshots,
  bool Function(PlayerSnapshot snapshot) predicate,
) async {
  try {
    return await snapshots
        .firstWhere(predicate)
        .timeout(const Duration(seconds: 60));
  } on StateError catch (error) {
    return PlayerSnapshot(
      status: PlayerStatus.failed,
      errorMessage: error.toString(),
    );
  } on TimeoutException catch (error) {
    return PlayerSnapshot(
      status: PlayerStatus.failed,
      errorMessage: error.toString(),
    );
  }
}

Future<PlayerSnapshot> _waitForControllerSnapshot(
  ProviderContainer container,
  bool Function(PlayerSnapshot snapshot) predicate,
) async {
  for (var attempt = 0; attempt < 600; attempt++) {
    final state = container.read(playerControllerProvider);
    final error = state.error;
    if (error != null) {
      throw StateError(
        'PlayerController failed: ${_sanitizeError(error.toString())}',
      );
    }
    final snapshot = state.value;
    if (snapshot != null && predicate(snapshot)) {
      return snapshot;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('PlayerController did not reach the expected state.');
}

String _safeSource(String source) {
  final uri = Uri.tryParse(source);
  if (uri == null) {
    return 'invalid-source';
  }
  return uri.host.isEmpty ? uri.scheme : '${uri.scheme}://${uri.host}';
}

String _sanitizeError(String value) {
  return value.replaceAllMapped(
    RegExp(r'(https?://[^\s?#]+)(?:\?[^\s#]*)?(?:#[^\s]*)?'),
    (match) => match.group(1)!,
  );
}

class _UnexpectedFallbackResolver implements AudioStreamResolver {
  bool called = false;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    called = true;
    throw StateError(
      'The live integration test reached the fallback resolver.',
    );
  }

  @override
  Future<void> dispose() async {}
}
