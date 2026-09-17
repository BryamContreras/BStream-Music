import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/wavy_playback_seek_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('visible rail reaches the timeline edges and uses that width', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();
    Duration? soughtPosition;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox(
              width: 200,
              height: 48,
              child: WavyPlaybackSeekBar(
                position: const Duration(seconds: 50),
                duration: const Duration(seconds: 100),
                isPlaying: false,
                waveColor: Colors.red,
                onSeek: (position) => soughtPosition = position,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await tester.runAsync(() => boundary.toImage());
    expect(image, isNotNull);
    final renderedImage = image!;
    final bytes = await tester.runAsync(
      () => renderedImage.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    expect(bytes, isNotNull);

    int alphaAt(int x, int y) =>
        bytes!.getUint8(((y * renderedImage.width) + x) * 4 + 3);

    expect(alphaAt(1, 1), 0);
    expect(alphaAt(198, 1), 0);
    expect(alphaAt(1, 24), greaterThan(alphaAt(1, 1)));
    expect(alphaAt(198, 24), greaterThan(alphaAt(198, 1)));

    final rect = tester.getRect(find.byType(WavyPlaybackSeekBar));
    await tester.tapAt(rect.topLeft + const Offset(4, 24));
    await tester.pump();
    expect(soughtPosition, greaterThan(Duration.zero));

    await tester.tapAt(rect.topRight + const Offset(-4, 24));
    await tester.pump();
    expect(soughtPosition, lessThan(const Duration(seconds: 100)));

    renderedImage.dispose();
  });

  testWidgets('passive progress line has no seeking gestures or slider role', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 240,
            child: WavyPlaybackProgressLine(
              value: 0.42,
              isPlaying: false,
              waveColor: Colors.teal,
              surfaceBrightness: Brightness.dark,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final progress = find.byType(WavyPlaybackProgressLine);
    expect(progress, findsOneWidget);
    expect(
      find.descendant(of: progress, matching: find.byType(GestureDetector)),
      findsNothing,
    );
    expect(
      find.descendant(of: progress, matching: find.byType(Semantics)),
      findsNothing,
    );
    expect(
      tester.getSemantics(progress).getSemanticsData().flagsCollection.isSlider,
      isFalse,
    );
    expect(tester.getSize(progress), const Size(240, 48));
    expect(tester.takeException(), isNull);

    semantics.dispose();
  });

  testWidgets(
    'small passive line clamps its wave inside the requested height',
    (tester) async {
      final boundaryKey = GlobalKey();

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: const SizedBox(
                width: 200,
                height: 40,
                child: Center(
                  child: WavyPlaybackProgressLine(
                    value: 0.75,
                    isPlaying: false,
                    waveColor: Colors.orange,
                    height: 16,
                    waveAmplitude: 100,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      final progress = find.byType(WavyPlaybackProgressLine);
      expect(tester.getSize(progress), const Size(200, 16));

      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      expect(image, isNotNull);
      final renderedImage = image!;
      final bytes = await tester.runAsync(
        () => renderedImage.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      expect(bytes, isNotNull);

      int alphaAt(int x, int y) =>
          bytes!.getUint8(((y * renderedImage.width) + x) * 4 + 3);

      for (var x = 0; x < renderedImage.width; x++) {
        expect(alphaAt(x, 0), 0);
        expect(alphaAt(x, renderedImage.height - 1), 0);
      }
      expect(tester.takeException(), isNull);

      renderedImage.dispose();
    },
  );

  testWidgets('reduced motion stops the passive wave animation', (
    tester,
  ) async {
    Widget harness({required bool disableAnimations}) {
      return MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: const Center(
            child: SizedBox(
              width: 240,
              child: WavyPlaybackProgressLine(
                value: 0.5,
                isPlaying: true,
                waveColor: Colors.purple,
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(harness(disableAnimations: false));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(harness(disableAnimations: true));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
