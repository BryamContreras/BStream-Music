import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/spotify_canvas_video.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/playback_visual_cache_provider.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/services/player/playback_visual_cache.dart';
import 'package:bstream_music/services/player/fragmented_artwork_mp4.dart';
import 'package:bstream_music/services/player/artwork_video_rendering.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player/video_player.dart';

/// Run with a local Canvas fixture, never the user's music database:
/// flutter test integration_test/spotify_canvas_native_test.dart -d windows
/// --dart-define=BSTREAM_CANVAS_TEST_FILE=absolute-path-to-mp4
/// Add BSTREAM_CANVAS_TEST_LOOKUP=true to exercise the online player pipeline,
/// and BSTREAM_CANVAS_TEST_UNKNOWN_DURATION=true for missing native metadata.
/// BSTREAM_CANVAS_TEST_APPLE=true exercises Animated Artwork instead of Canvas.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  configureArtworkVideoRendering();
  const path = String.fromEnvironment('BSTREAM_CANVAS_TEST_FILE');

  testWidgets('cached artwork advances and becomes visible on Windows', (
    tester,
  ) async {
    final original = File(path);
    expect(await original.exists(), isTrue);
    final fixtureDirectory = await Directory.systemTemp.createTemp(
      'bstream_native_artwork_',
    );
    addTearDown(() => fixtureDirectory.delete(recursive: true));
    final file = await original.copy('${fixtureDirectory.path}/fixture.mp4');
    if (_appleArtwork) await repairFragmentedArtworkMp4(file);
    final controller = VideoPlayerController.file(
      file,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await controller.initialize().timeout(const Duration(seconds: 12));
      debugPrint('Native Canvas initialized: ${controller.value}');
      expect(controller.value.isInitialized, isTrue);
      expect(controller.value.duration, greaterThan(Duration.zero));
      expect(isRemoteArtworkVideoSizeAllowed(controller.value.size), isTrue);
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
      await _waitUntil(
        tester,
        () => controller.value.position > Duration.zero,
        () => 'Native Canvas did not advance: ${controller.value}',
      );
      expect(controller.value.hasError, isFalse);
    } finally {
      await controller.dispose();
    }

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 600,
              child: RepaintBoundary(
                key: boundaryKey,
                child: SpotifyCanvasVideo(
                  url: file.uri,
                  isPlaying: true,
                  startOffset: _appleArtwork
                      ? animatedArtworkIntroOffset
                      : Duration.zero,
                  durationHint: _snapshot.duration ?? Duration.zero,
                  autoFitInsetArtwork: _appleArtwork,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _waitUntil(
      tester,
      () => find.byType(VideoPlayer).evaluate().isNotEmpty,
      () => 'Production Canvas never created the video surface.',
    );
    final video = tester.widget<VideoPlayer>(find.byType(VideoPlayer));
    final texture = tester.widget<Texture>(
      find.descendant(
        of: find.byType(VideoPlayer),
        matching: find.byType(Texture),
      ),
    );
    expect(texture.filterQuality, FilterQuality.medium);
    await _waitUntil(
      tester,
      () => video.controller.value.position > Duration.zero,
      () => 'Production Canvas did not advance: ${video.controller.value}',
    );
    await _waitUntil(
      tester,
      () => _videoVisible(tester),
      () => 'Artwork has a timeline but remains hidden.',
    );
    await tester.pump(const Duration(milliseconds: 400));
    final opacity = tester.widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byType(VideoPlayer),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    );
    expect(opacity.opacity, 1);
    expect(video.controller.value.volume, 0);
    expect(video.controller.value.isLooping, !_appleArtwork);
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final frame = await boundary.toImage(pixelRatio: 1);
    try {
      final rgba = (await frame.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var darkest = 255;
      var lightest = 0;
      for (var y = 1; y < 10; y++) {
        for (var x = 1; x < 10; x++) {
          final offset =
              ((frame.height * y ~/ 10) * frame.width + frame.width * x ~/ 10) *
              4;
          final luminance =
              (rgba.getUint8(offset) +
                  rgba.getUint8(offset + 1) +
                  rgba.getUint8(offset + 2)) ~/
              3;
          darkest = luminance < darkest ? luminance : darkest;
          lightest = luminance > lightest ? luminance : lightest;
        }
      }
      debugPrint('Native Canvas pixel range: $darkest..$lightest');
      final png = (await frame.toByteData(format: ui.ImageByteFormat.png))!;
      final coverFrame = File(
        '${original.parent.path}/windows-${_appleArtwork ? 'artwork' : 'canvas'}-render.png',
      );
      await coverFrame.writeAsBytes(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
      _fixtureCoverPath = coverFrame.path;
      expect(
        lightest - darkest,
        greaterThan(20),
        reason: 'The native texture must show actual video, not a flat frame.',
      );
    } finally {
      frame.dispose();
    }
    if (_appleArtwork) {
      final duration = video.controller.value.duration;
      await video.controller.seekTo(
        duration - const Duration(milliseconds: 700),
      );
      await _waitUntil(
        tester,
        () =>
            video.controller.value.position >
                animatedArtworkIntroOffset +
                    const Duration(milliseconds: 120) &&
            video.controller.value.position <
                duration - const Duration(seconds: 2) &&
            _videoVisible(tester),
        () => 'Artwork did not resume its loop: ${video.controller.value}',
      );
      expect(video.controller.value.isPlaying, isTrue);
      expect(video.controller.value.hasError, isFalse);
      debugPrint(
        'Animated Artwork resumed its loop: ${video.controller.value.position}',
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    if (const bool.fromEnvironment('BSTREAM_CANVAS_TEST_LOOKUP')) {
      final directory = await Directory.systemTemp.createTemp(
        'bstream_canvas_native_',
      );
      final cache = PlaybackVisualCache(directory: () async => directory);
      final container = ProviderContainer(
        overrides: [
          databaseServiceProvider.overrideWith(
            (ref) => throw StateError(
              'Canvas fixture must not access the user database.',
            ),
          ),
          playbackVisualCacheProvider.overrideWith((ref) => cache),
          playerServiceProvider.overrideWithValue(_CanvasAudioStub()),
          playerControllerProvider.overrideWith(_CanvasPlayer.new),
          settingsControllerProvider.overrideWith(_CanvasSettings.new),
          playlistsControllerProvider.overrideWith(_CanvasPlaylists.new),
          libraryTracksProvider.overrideWith(
            (ref) async => const <LocalTrack>[],
          ),
          favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
        ],
      );
      try {
        for (final style in PlayerStyle.values) {
          final panelBoundary = GlobalKey();
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: ThemeData.dark(),
                home: Scaffold(
                  body: RepaintBoundary(
                    key: panelBoundary,
                    child: PlayerPanel(
                      style: style,
                      artworkStyle: PlayerArtworkStyle.expanded,
                      spotifyCanvasEnabled: !_appleArtwork,
                      appleAnimatedArtworkEnabled: _appleArtwork,
                      animatedArtworkEnabled: false,
                      drawBackground: false,
                      trackTransitionsEnabled: false,
                    ),
                  ),
                ),
              ),
            ),
          );
          await _waitUntil(
            tester,
            () => find.byType(VideoPlayer).evaluate().isNotEmpty,
            () =>
                'Full player $style did not load a Canvas; cache revision=${cache.revision}',
          );
          final nativeVideo = tester.widget<VideoPlayer>(
            find.byType(VideoPlayer).first,
          );
          await _waitUntil(
            tester,
            () =>
                nativeVideo.controller.value.position > Duration.zero &&
                _videoVisible(tester),
            () =>
                'Full player $style Canvas did not advance: ${nativeVideo.controller.value}',
          );
          debugPrint(
            'Full player $style Canvas visible: ${nativeVideo.controller.value.position}',
          );
          expect(nativeVideo.controller.value.hasError, isFalse);
          if (_appleArtwork) {
            expect(
              nativeVideo.controller.value.position,
              greaterThan(animatedArtworkIntroOffset),
            );
          } else if (style != PlayerStyle.classicVinyl) {
            final surface = find.byKey(
              const ValueKey('player-artwork-surface'),
            );
            final viewport = find.byKey(
              const ValueKey('player-canvas-viewport'),
            );
            final coverRect = tester.getRect(surface);
            final videoRect = tester.getRect(viewport);
            expect(videoRect.left, lessThan(coverRect.left));
            expect(videoRect.top, lessThan(coverRect.top));
          }
          await tester.pump(const Duration(milliseconds: 300));
          final panel =
              panelBoundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final panelImage = await panel.toImage(pixelRatio: 1);
          try {
            final png = (await panelImage.toByteData(
              format: ui.ImageByteFormat.png,
            ))!;
            await File(
              '${original.parent.path}/windows-${_appleArtwork ? 'artwork' : 'canvas'}-${style.name}.png',
            ).writeAsBytes(
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
            );
          } finally {
            panelImage.dispose();
          }
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        container.dispose();
        await directory.delete(recursive: true);
      }
    }
  }, skip: path.isEmpty || !Platform.isWindows);
}

bool _videoVisible(WidgetTester tester) {
  final opacity = find.ancestor(
    of: find.byType(VideoPlayer).first,
    matching: find.byType(AnimatedOpacity),
  );
  return opacity.evaluate().isNotEmpty &&
      tester.widget<AnimatedOpacity>(opacity.first).opacity == 1;
}

const _baseSnapshot = PlayerSnapshot(
  status: PlayerStatus.playing,
  title: 'vampire',
  artist: 'Olivia Rodrigo',
  album: 'GUTS',
  duration: bool.fromEnvironment('BSTREAM_CANVAS_TEST_UNKNOWN_DURATION')
      ? null
      : Duration(seconds: 220),
  trackId: 'native-canvas-fixture',
);

String? _fixtureCoverPath;
PlayerSnapshot get _snapshot => _fixtureCoverPath == null
    ? _baseSnapshot
    : _baseSnapshot.copyWith(thumbnailUrl: _fixtureCoverPath);

const _appleArtwork = bool.fromEnvironment('BSTREAM_CANVAS_TEST_APPLE');

class _CanvasPlayer extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => _snapshot;
}

class _CanvasSettings extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '',
    language: AppLanguage.spanish,
    spotifyCanvasEnabled: !_appleArtwork,
    appleAnimatedArtworkEnabled: _appleArtwork,
  );
}

class _CanvasPlaylists extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => const [];
}

class _CanvasAudioStub implements PlayerService {
  @override
  Stream<PlayerSnapshot> get snapshotStream => Stream.value(_snapshot);

  @override
  PlayerSnapshot get currentSnapshot => _snapshot;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready,
  String Function() diagnostic,
) async {
  final timer = Stopwatch()..start();
  while (!ready() && timer.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: diagnostic());
}
