import 'dart:async';
import 'dart:ui' as ui;

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
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  for (final style in [
    PlayerStyle.bstreamMusic,
    PlayerStyle.appleMusic,
    PlayerStyle.spotifyMusic,
  ]) {
    testWidgets('$style video covers the upper still artwork after loading', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final originalVideoPlatform = VideoPlayerPlatform.instance;
      final videoPlatform = _LayoutVideoPlatform(position: Duration.zero);
      VideoPlayerPlatform.instance = videoPlatform;
      addTearDown(() => VideoPlayerPlatform.instance = originalVideoPlatform);
      final container = _canvasTestContainer(_CompletedCanvasCache());
      addTearDown(container.dispose);
      final captureKey = GlobalKey();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(
                  size: Size(390, 820),
                  padding: EdgeInsets.only(top: 47, bottom: 34),
                  viewPadding: EdgeInsets.only(top: 47, bottom: 34),
                ),
                child: RepaintBoundary(
                  key: captureKey,
                  child: ColoredBox(
                    color: const Color(0xFF763C2F),
                    child: PlayerPanel(
                      style: style,
                      artworkStyle: PlayerArtworkStyle.expanded,
                      spotifyCanvasEnabled: true,
                      animatedArtworkEnabled: false,
                      drawBackground: false,
                      trackTransitionsEnabled: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final video = find.byType(SpotifyCanvasVideo);
      expect(video, findsOneWidget);
      final opacity = find.descendant(
        of: video,
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(opacity.first).opacity, 0);
      final videoRect = tester.getRect(
        find.byKey(const ValueKey('player-expanded-artwork-video-fade')),
      );
      final points = <Offset>[
        for (final xFraction in [.2, .8])
          for (final y in [12.0, 22.0, 40.0])
            Offset(
              videoRect.left + videoRect.width * xFraction,
              videoRect.top + y,
            ),
      ];
      final loadingPixels = await _capturePixels(tester, captureKey, points);

      videoPlatform.position = const Duration(seconds: 1);
      for (var attempt = 0; attempt < 10; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (tester.widget<AnimatedOpacity>(opacity.first).opacity == 1) break;
      }
      expect(tester.widget<AnimatedOpacity>(opacity.first).opacity, 1);
      await tester.pump(const Duration(milliseconds: 300));
      final readyPixels = await _capturePixels(tester, captureKey, points);
      final expected = <int>[
        (Colors.cyan.r * 255).round(),
        (Colors.cyan.g * 255).round(),
        (Colors.cyan.b * 255).round(),
        255,
      ];
      for (var point = 0; point < points.length; point++) {
        for (var channel = 0; channel < 4; channel++) {
          expect(
            readyPixels[point][channel],
            closeTo(expected[channel], 1),
            reason:
                'The decoded video must cover the still artwork near the '
                'system bar at ${points[point]}, channel $channel.',
          );
        }
        expect(
          [
            for (var channel = 0; channel < 3; channel++)
              (loadingPixels[point][channel] - expected[channel]).abs(),
          ].any((difference) => difference > 32),
          isTrue,
          reason:
              'The still fallback must remain visible before a video frame.',
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }, skip: AppPlatform.current == AppPlatformType.linux);
  }

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
        final container = _canvasTestContainer(cache);
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

  for (final style in [
    PlayerStyle.bstreamMusic,
    PlayerStyle.appleMusic,
    PlayerStyle.spotifyMusic,
  ]) {
    for (final scenario in [
      (
        name: 'Android portrait',
        platform: TargetPlatform.android,
        size: const Size(390, 820),
        brightness: Brightness.dark,
        fullHero: true,
      ),
      (
        name: 'iPhone portrait with a light app theme',
        platform: TargetPlatform.iOS,
        size: const Size(390, 820),
        brightness: Brightness.light,
        fullHero: true,
      ),
      (
        name: 'dark desktop',
        platform: TargetPlatform.windows,
        size: const Size(1200, 800),
        brightness: Brightness.dark,
        fullHero: false,
      ),
      (
        name: 'light desktop',
        platform: TargetPlatform.windows,
        size: const Size(1200, 800),
        brightness: Brightness.light,
        fullHero: false,
      ),
    ]) {
      testWidgets('$style Canvas leaves no lower edge on ${scenario.name}', (
        tester,
      ) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final originalVideoPlatform = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = _LayoutVideoPlatform();
        addTearDown(() => VideoPlayerPlatform.instance = originalVideoPlatform);
        final cache = _CompletedCanvasCache();
        final container = _canvasTestContainer(cache);
        addTearDown(container.dispose);
        final captureKey = GlobalKey();

        Widget harness({required bool canvasEnabled}) {
          return UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: ThemeData(
                platform: scenario.platform,
                brightness: scenario.brightness,
              ),
              home: Scaffold(
                body: RepaintBoundary(
                  key: captureKey,
                  child: ColoredBox(
                    color: scenario.brightness == Brightness.dark
                        ? const Color(0xFF321E38)
                        : const Color(0xFFF8E3CF),
                    child: PlayerPanel(
                      style: style,
                      artworkStyle: PlayerArtworkStyle.expanded,
                      spotifyCanvasEnabled: canvasEnabled,
                      animatedArtworkEnabled: false,
                      drawBackground: false,
                      trackTransitionsEnabled: false,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        await tester.pumpWidget(harness(canvasEnabled: true));
        await tester.pump();
        // Initialization and the resolver finish on different microtasks.
        // Wait for an advancing fake frame before finishing its reveal.
        final videoOpacity = find.descendant(
          of: find.byType(SpotifyCanvasVideo),
          matching: find.byType(AnimatedOpacity),
        );
        for (var attempt = 0; attempt < 10; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (videoOpacity.evaluate().isNotEmpty &&
              tester.widget<AnimatedOpacity>(videoOpacity.first).opacity == 1) {
            break;
          }
        }
        expect(tester.widget<AnimatedOpacity>(videoOpacity.first).opacity, 1);
        await tester.pump(const Duration(milliseconds: 300));
        final fade = find.byKey(
          ValueKey(
            scenario.fullHero
                ? 'player-expanded-artwork-video-fade'
                : 'player-bounded-artwork-video-fade',
          ),
        );
        expect(fade, findsOneWidget);
        expect(find.byType(SpotifyCanvasVideo), findsOneWidget);
        final videoRect = tester.getRect(fade);
        final artworkRect = tester.getRect(
          find.byKey(const ValueKey('player-artwork-surface')),
        );
        if (!scenario.fullHero) {
          expect(videoRect.bottom, greaterThan(artworkRect.bottom));
        }
        final points = <Offset>[
          // A fully opaque point proves that the video was actually shown.
          Offset(videoRect.center.dx, videoRect.top + videoRect.height * .4),
          for (final xFraction in [.25, .5, .75])
            for (final yFraction in [.975, .985, .995])
              Offset(
                videoRect.left + videoRect.width * xFraction,
                videoRect.top + videoRect.height * yFraction,
              ),
          // A fractional mask boundary can leak one unmasked video row even
          // when the preceding rows are fully transparent.
          for (final xFraction in [.25, .5, .75])
            for (final y in [
              videoRect.bottom.floorToDouble(),
              videoRect.bottom.ceilToDouble(),
            ])
              Offset(videoRect.left + videoRect.width * xFraction, y),
          // Also cover the still artwork's boundary after Canvas overscan.
          Offset(artworkRect.center.dx, artworkRect.bottom - 1),
        ];
        final withCanvas = await _capturePixels(tester, captureKey, points);

        await tester.pumpWidget(harness(canvasEnabled: false));
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(SpotifyCanvasVideo), findsNothing);
        final withoutCanvas = await _capturePixels(tester, captureKey, points);
        expect(
          [
            for (var channel = 0; channel < 3; channel++)
              (withCanvas.first[channel] - withoutCanvas.first[channel]).abs(),
          ].any((difference) => difference > 32),
          isTrue,
          reason:
              'The opaque cyan video must be visible above its fade: '
              '${withCanvas.first} versus ${withoutCanvas.first}.',
        );
        for (var point = 1; point < points.length; point++) {
          for (var channel = 0; channel < 4; channel++) {
            expect(
              withCanvas[point][channel],
              closeTo(withoutCanvas[point][channel], 1),
              reason:
                  'Canvas must be transparent before its physical lower '
                  'edge at ${points[point]}, channel $channel.',
            );
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }, skip: AppPlatform.current == AppPlatformType.linux);
    }
  }
}

ProviderContainer _canvasTestContainer(PlaybackVisualCache cache) {
  return ProviderContainer(
    overrides: [
      databaseServiceProvider.overrideWith(
        (ref) => throw StateError('Layout fixture cannot use user data'),
      ),
      playbackVisualCacheProvider.overrideWith((ref) => cache),
      spotifyCanvasResolverProvider.overrideWithValue(_FixtureCanvasResolver()),
      playerServiceProvider.overrideWithValue(_LayoutAudio()),
      playerControllerProvider.overrideWith(_LayoutPlayer.new),
      settingsControllerProvider.overrideWith(_LayoutSettings.new),
      playlistsControllerProvider.overrideWith(_LayoutPlaylists.new),
      libraryTracksProvider.overrideWith((ref) async => const <LocalTrack>[]),
      favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
    ],
  );
}

Future<List<List<int>>> _capturePixels(
  WidgetTester tester,
  GlobalKey captureKey,
  List<Offset> globalPoints,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureKey),
  );
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
  try {
    final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    return [
      for (final globalPoint in globalPoints)
        () {
          final point = boundary.globalToLocal(globalPoint);
          final x = point.dx.floor();
          final y = point.dy.floor();
          expect(x, inInclusiveRange(0, image.width - 1));
          expect(y, inInclusiveRange(0, image.height - 1));
          final offset = (y * image.width + x) * 4;
          return [
            for (var channel = 0; channel < 4; channel++)
              bytes.getUint8(offset + channel),
          ];
        }(),
    ];
  } finally {
    image.dispose();
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
  _LayoutVideoPlatform({this.position = const Duration(seconds: 1)});

  Duration position;

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
  Future<Duration> getPosition(int playerId) => SynchronousFuture(position);

  @override
  Future<void> seekTo(int playerId, Duration position) =>
      SynchronousFuture(null);

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.cyan);

  @override
  Future<void> dispose(int playerId) => _events.close();
}
