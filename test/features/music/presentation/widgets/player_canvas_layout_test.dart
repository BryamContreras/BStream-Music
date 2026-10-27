import 'dart:async';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/playback_visual_cache_provider.dart';
import 'package:bstream_music/features/music/presentation/providers/spotify_canvas_provider.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/spotify_canvas_video.dart';
import 'package:bstream_music/services/player/playback_visual_cache.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/spotify_canvas/spotify_canvas_resolver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  for (final style in [PlayerStyle.bstreamMusic, PlayerStyle.appleMusic]) {
    for (final scenario in [
      (
        name: 'desktop',
        platform: TargetPlatform.windows,
        size: const Size(1200, 800),
        artworkStyle: PlayerArtworkStyle.expanded,
        expandedBleed: true,
      ),
      (
        name: 'Android landscape tablet',
        platform: TargetPlatform.android,
        size: const Size(1200, 800),
        artworkStyle: PlayerArtworkStyle.expanded,
        expandedBleed: true,
      ),
      (
        name: 'iPad landscape',
        platform: TargetPlatform.iOS,
        size: const Size(1024, 768),
        artworkStyle: PlayerArtworkStyle.expanded,
        expandedBleed: true,
      ),
      (
        name: 'landscape phone',
        platform: TargetPlatform.android,
        size: const Size(844, 390),
        artworkStyle: PlayerArtworkStyle.expanded,
        expandedBleed: false,
      ),
      (
        name: 'portrait tablet',
        platform: TargetPlatform.android,
        size: const Size(800, 1200),
        artworkStyle: PlayerArtworkStyle.expanded,
        expandedBleed: false,
      ),
      (
        name: 'desktop classic artwork',
        platform: TargetPlatform.windows,
        size: const Size(1200, 800),
        artworkStyle: PlayerArtworkStyle.classic,
        expandedBleed: false,
      ),
    ]) {
      testWidgets('$style Canvas framing on ${scenario.name}', (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final originalVideoPlatform = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = _LayoutVideoPlatform();
        addTearDown(() => VideoPlayerPlatform.instance = originalVideoPlatform);
        final cache = _CompletedCanvasCache();
        final container = ProviderContainer(
          overrides: [
            databaseServiceProvider.overrideWith(
              (ref) => throw StateError('Layout fixture cannot use user data'),
            ),
            playbackVisualCacheProvider.overrideWith((ref) => cache),
            spotifyCanvasResolverProvider.overrideWithValue(
              _FixtureCanvasResolver(),
            ),
            playerServiceProvider.overrideWithValue(_LayoutAudio()),
            playerControllerProvider.overrideWith(_LayoutPlayer.new),
            settingsControllerProvider.overrideWith(_LayoutSettings.new),
            playlistsControllerProvider.overrideWith(_LayoutPlaylists.new),
            libraryTracksProvider.overrideWith(
              (ref) async => const <LocalTrack>[],
            ),
            favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: ThemeData(platform: scenario.platform),
              home: Scaffold(
                body: PlayerPanel(
                  style: style,
                  artworkStyle: scenario.artworkStyle,
                  spotifyCanvasEnabled: true,
                  animatedArtworkEnabled: false,
                  drawBackground: false,
                  trackTransitionsEnabled: false,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        final surface = find.byKey(const ValueKey('player-artwork-surface'));
        final viewport = find.byKey(const ValueKey('player-canvas-viewport'));
        expect(find.byType(SpotifyCanvasVideo), findsOneWidget);
        expect(
          tester
              .widget<SpotifyCanvasVideo>(find.byType(SpotifyCanvasVideo))
              .startOffset,
          Duration.zero,
        );
        expect(viewport, findsOneWidget);
        final coverRect = tester.getRect(surface);
        final videoRect = tester.getRect(viewport);
        if (scenario.expandedBleed) {
          expect(videoRect.left, lessThan(coverRect.left));
          expect(videoRect.top, lessThan(coverRect.top));
          expect(videoRect.right, greaterThan(coverRect.right));
          expect(videoRect.bottom, greaterThan(coverRect.bottom));
          expect(videoRect.width / coverRect.width, lessThanOrEqualTo(1.061));
          expect(videoRect.height / coverRect.height, lessThanOrEqualTo(1.061));
        } else {
          expect(videoRect, coverRect);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }, skip: AppPlatform.current == AppPlatformType.linux);
    }
  }
}

const _snapshot = PlayerSnapshot(
  status: PlayerStatus.paused,
  title: 'Canvas layout fixture',
  artist: 'BStream Music',
  trackId: 'canvas-layout-fixture',
  thumbnailUrl: '/fixture/cover.jpg',
  duration: Duration(minutes: 3),
);

class _CompletedCanvasCache extends PlaybackVisualCache {
  @override
  void activate({
    required String trackKey,
    required String? coverSource,
    String? coverFallbackSource,
    required Uri? videoUrl,
  }) {}

  @override
  Uri? videoFileFor(String trackKey, Uri? url) =>
      url == null ? null : Uri.file('/fixture/canvas.mp4');
}

class _FixtureCanvasResolver extends SpotifyCanvasResolver {
  @override
  Future<Uri?> resolve(SpotifyCanvasTrack track) async =>
      Uri.https('canvaz.scdn.co', '/fixture.mp4');
}

class _LayoutPlayer extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => _snapshot;
}

class _LayoutSettings extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '',
    language: AppLanguage.spanish,
    spotifyCanvasEnabled: true,
  );
}

class _LayoutPlaylists extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => const [];
}

class _LayoutAudio implements PlayerService {
  @override
  Stream<PlayerSnapshot> get snapshotStream => Stream.value(_snapshot);

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LayoutVideoPlatform extends VideoPlayerPlatform {
  late final StreamController<VideoEvent> _events =
      StreamController<VideoEvent>(
        sync: true,
        onListen: () => scheduleMicrotask(() {
          _events.add(
            VideoEvent(
              eventType: VideoEventType.initialized,
              duration: const Duration(seconds: 20),
              size: const Size(720, 1280),
            ),
          );
        }),
      );

  @override
  Future<void> init() => SynchronousFuture(null);

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) =>
      SynchronousFuture(1);

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events.stream;

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) => SynchronousFuture(null);

  @override
  Future<void> setVolume(int playerId, double volume) =>
      SynchronousFuture(null);

  @override
  Future<void> setLooping(int playerId, bool looping) =>
      SynchronousFuture(null);

  @override
  Future<void> play(int playerId) => SynchronousFuture(null);

  @override
  Future<void> pause(int playerId) => SynchronousFuture(null);

  @override
  Future<Duration> getPosition(int playerId) =>
      SynchronousFuture(const Duration(seconds: 1));

  @override
  Future<void> seekTo(int playerId, Duration position) =>
      SynchronousFuture(null);

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.green);

  @override
  Future<void> dispose(int playerId) => _events.close();
}
