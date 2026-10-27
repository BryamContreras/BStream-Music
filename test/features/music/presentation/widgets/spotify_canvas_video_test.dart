import 'dart:async';

import 'package:bstream_music/features/music/presentation/widgets/spotify_canvas_video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  testWidgets(
    'intro fast-forward waits for the decode guard without recursion',
    (tester) async {
      final originalPlatform = VideoPlayerPlatform.instance;
      final platform = _SynchronousArtworkVideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);
      await tester.pumpWidget(_introArtworkHarness());
      await tester.pump();
      expect(platform.seeks, [animatedArtworkIntroOffset]);
      platform.speeds.clear();

      Finder opacityFinder() => find
          .descendant(
            of: find.byType(SpotifyCanvasVideo),
            matching: find.byType(AnimatedOpacity),
          )
          .first;

      // VideoPlayerController changes playbackSpeed synchronously, and this
      // backend also reports playing state synchronously from that operation.
      // The original code alternated 8x/1x recursively just after the offset.
      platform.position = Duration.zero;
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.speeds, isNotEmpty);
      expect(platform.speeds, everyElement(8));

      platform.position = const Duration(milliseconds: 8050);
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.speeds, isNotEmpty);
      expect(platform.speeds, everyElement(8));
      expect(tester.widget<AnimatedOpacity>(opacityFinder()).opacity, 0);
      expect(tester.takeException(), isNull);

      platform.position = const Duration(milliseconds: 8120);
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.speeds, everyElement(8));
      expect(tester.widget<AnimatedOpacity>(opacityFinder()).opacity, 0);

      platform.position = const Duration(milliseconds: 8121);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(platform.speeds.last, 1);
      expect(platform.speeds.length, lessThanOrEqualTo(4));
      expect(tester.widget<AnimatedOpacity>(opacityFinder()).opacity, 1);
      final video = tester.widget<VideoPlayer>(find.byType(VideoPlayer));
      expect(video.controller.value.playbackSpeed, 1);
      expect(video.controller.value.position, platform.position);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('successful intro seek waits for a frame without fast-forward', (
    tester,
  ) async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _SynchronousArtworkVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);
    await tester.pumpWidget(_introArtworkHarness());
    await tester.pump();
    expect(platform.seeks, [animatedArtworkIntroOffset]);
    platform.speeds.clear();

    for (final milliseconds in [8050, 8120]) {
      platform.position = Duration(milliseconds: milliseconds);
      await tester.pump(const Duration(milliseconds: 100));
      expect(platform.speeds, isNot(contains(8)));
      expect(tester.takeException(), isNull);
    }
    platform.position = const Duration(milliseconds: 8121);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    final video = tester.widget<VideoPlayer>(find.byType(VideoPlayer));
    expect(video.controller.value.playbackSpeed, 1);
    expect(platform.speeds, isNot(contains(8)));
    expect(
      tester
          .widget<AnimatedOpacity>(
            find
                .descendant(
                  of: find.byType(SpotifyCanvasVideo),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity,
      1,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('short artwork never reveals the intro or seeks past its end', (
    tester,
  ) async {
    final originalPlatform = VideoPlayerPlatform.instance;
    final platform = _SynchronousArtworkVideoPlatform(
      duration: const Duration(seconds: 9),
    );
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = originalPlatform);
    await tester.pumpWidget(_introArtworkHarness());
    await tester.pump(const Duration(milliseconds: 200));
    expect(platform.seeks, isEmpty);
    expect(find.byType(VideoPlayer), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  test('only portrait video receives the optional inset-artwork zoom', () {
    expect(effectivePortraitArtworkZoom(const Size(486, 648), 1.45), 1.45);
    expect(effectivePortraitArtworkZoom(const Size(768, 768), 1.45), 1.0);
    expect(effectivePortraitArtworkZoom(const Size(720, 1280), 1.0), 1.0);
    expect(effectivePortraitArtworkZoom(Size.zero, 1.45), 1.0);
  });

  test('accepts normal Canvas video sizes and rejects oversized frames', () {
    expect(isRemoteArtworkVideoSizeAllowed(const Size(720, 1280)), isTrue);
    expect(isRemoteArtworkVideoSizeAllowed(const Size(1080, 1920)), isTrue);
    expect(isRemoteArtworkVideoSizeAllowed(const Size(2160, 2160)), isFalse);
    expect(isRemoteArtworkVideoSizeAllowed(const Size(0, 720)), isFalse);
  });

  test('skips eight seconds only when artwork has enough video to loop', () {
    const skip = animatedArtworkIntroOffset;
    expect(skip, const Duration(seconds: 8));
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 25)),
      skip,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 50)),
      skip,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 11)),
      skip,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 10)),
      Duration.zero,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 7)),
      Duration.zero,
    );
    expect(
      effectiveArtworkVideoStartOffset(skip, const Duration(seconds: 6)),
      Duration.zero,
    );
    expect(
      effectiveArtworkVideoStartOffset(
        skip,
        const Duration(seconds: 6),
        durationHint: const Duration(minutes: 3),
      ),
      Duration.zero,
    );
    expect(
      effectiveArtworkVideoStartOffset(
        skip,
        const Duration(milliseconds: 1),
        durationHint: const Duration(minutes: 2),
      ),
      skip,
    );
    expect(
      effectiveArtworkVideoStartOffset(
        skip,
        const Duration(milliseconds: 1),
        durationHint: const Duration(seconds: 6),
      ),
      Duration.zero,
    );
    expect(
      effectiveArtworkVideoStartOffset(
        Duration.zero,
        const Duration(seconds: 25),
      ),
      Duration.zero,
    );
  });
}

Widget _introArtworkHarness() => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 360,
      height: 360,
      child: SpotifyCanvasVideo(
        url: Uri.file('fixture.mp4'),
        isPlaying: true,
        startOffset: animatedArtworkIntroOffset,
        durationHint: const Duration(seconds: 220),
      ),
    ),
  ),
);

class _SynchronousArtworkVideoPlatform extends VideoPlayerPlatform {
  _SynchronousArtworkVideoPlatform({
    this.duration = const Duration(seconds: 20),
  });

  final Duration duration;
  late final StreamController<VideoEvent> _events =
      StreamController<VideoEvent>(
        sync: true,
        onListen: () => scheduleMicrotask(() {
          _events.add(
            VideoEvent(
              eventType: VideoEventType.initialized,
              duration: duration,
              size: const Size(768, 768),
            ),
          );
        }),
      );
  final seeks = <Duration>[];
  final speeds = <double>[];
  Duration position = Duration.zero;

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
  Future<void> seekTo(int playerId, Duration target) {
    seeks.add(target);
    position = target;
    return SynchronousFuture(null);
  }

  @override
  Future<Duration> getPosition(int playerId) => SynchronousFuture(position);

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) {
    speeds.add(speed);
    _events.add(
      VideoEvent(
        eventType: VideoEventType.isPlayingStateUpdate,
        isPlaying: true,
      ),
    );
    return SynchronousFuture(null);
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const ColoredBox(color: Colors.green);

  @override
  Future<void> dispose(int playerId) => _events.close();
}
