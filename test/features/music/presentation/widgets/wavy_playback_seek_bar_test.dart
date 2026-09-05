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
}
