import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/lyrics_gradient_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'ambient paint is bounded at 120 Hz and does not rebuild lyrics',
    (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      var foregroundBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (context, enabled, child) =>
                TickerMode(enabled: enabled, child: child!),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const LyricsGradientBackground(
                  color: Color(0xFF10B8A0),
                  animated: true,
                ),
                Builder(
                  builder: (context) {
                    foregroundBuilds++;
                    return const Center(child: Text('Lyrics'));
                  },
                ),
              ],
            ),
          ),
        ),
      );
      final painter = _painter(tester);
      var paintRequests = 0;
      void onPaint() => paintRequests++;
      painter.addListener(onPaint);
      addTearDown(() => painter.removeListener(onPaint));

      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(microseconds: 8334));
      }
      expect(paintRequests, inInclusiveRange(12, 16));
      expect(foregroundBuilds, 1);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);

      visible.value = false;
      await tester.pump();
      final hiddenCount = paintRequests;
      await tester.pump(const Duration(seconds: 5));
      expect(paintRequests, hiddenCount);

      visible.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(paintRequests, greaterThan(hiddenCount));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final pausedCount = paintRequests;
      await tester.pump(const Duration(seconds: 5));
      expect(paintRequests, pausedCount);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(paintRequests, greaterThan(pausedCount));
      expect(foregroundBuilds, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion renders the static gradient without a clock', (
    tester,
  ) async {
    var reduced = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: const LyricsGradientBackground(
                color: Color(0xFF10B8A0),
                animated: true,
              ),
            );
          },
        ),
      ),
    );
    var notifications = 0;
    _painter(tester).addListener(() => notifications++);
    await tester.pumpAndSettle();
    expect(notifications, 0);
    expect(tester.binding.transientCallbackCount, 0);
    update(() => reduced = false);
    await tester.pump();
    _painter(tester).addListener(() => notifications++);
    await tester.pump(const Duration(seconds: 2));
    expect(notifications, greaterThan(0));
    update(() => reduced = true);
    await tester.pumpAndSettle();
    final stopped = notifications;
    await tester.pump(const Duration(seconds: 2));
    expect(notifications, stopped);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('random drift keeps both fields within the cover palette', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const coverColor = Color(0xFF10B8A0);
    final capture = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: capture,
          child: const LyricsGradientBackground(
            color: coverColor,
            animated: true,
          ),
        ),
      ),
    );
    final frames = <List<Color>>[];
    for (var step = 0; step < 8; step++) {
      if (step > 0) await tester.pump(const Duration(seconds: 8));
      final colors = await _sample(tester, capture);
      frames.add(colors);
      for (final color in colors) {
        final hueDistance =
            ((HSLColor.fromColor(color).hue -
                            HSLColor.fromColor(coverColor).hue +
                            180) %
                        360 -
                    180)
                .abs();
        expect(hueDistance, lessThan(6));
      }
      // The center stays colored while the two brighter fields move.
      expect(colors[1].computeLuminance(), greaterThan(.1));
    }
    expect(
      frames.skip(1).any((colors) => colors[0] != frames.first[0]),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('light fields visibly move within two seconds under the veil', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final cover in const [
      (name: 'red', color: Color(0xFFB52227)),
      (name: 'teal', color: Color(0xFF10B8A0)),
      (name: 'gray', color: Color(0xFF808080)),
    ]) {
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: capture,
            child: Stack(
              fit: StackFit.expand,
              children: [
                LyricsGradientBackground(color: cover.color, animated: true),
                const ColoredBox(color: Color(0x52000000)),
              ],
            ),
          ),
        ),
      );
      final before = await _grid(tester, capture, '${cover.name}-start');
      await tester.pump(const Duration(seconds: 2));
      final after = await _grid(tester, capture, '${cover.name}-two-seconds');
      final lightness =
          before.map((color) => HSLColor.fromColor(color).lightness).toList()
            ..sort();
      expect(
        lightness.last - lightness.first,
        greaterThan(.12),
        reason: '${cover.name}: distinguish the moving light from the base',
      );
      var moved = 0;
      for (var pixel = 0; pixel < before.length; pixel++) {
        final a = before[pixel];
        final b = after[pixel];
        if ((a.r - b.r).abs() > 12 / 255 ||
            (a.g - b.g).abs() > 12 / 255 ||
            (a.b - b.b).abs() > 12 / 255) {
          moved++;
        }
      }
      expect(
        moved / before.length,
        greaterThan(.2),
        reason: '${cover.name}: motion must be visible across the background',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}

CustomPainter _painter(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find.descendant(
        of: find.byType(LyricsGradientBackground),
        matching: find.byType(CustomPaint),
      ),
    )
    .painter!;

Future<List<Color>> _sample(WidgetTester tester, GlobalKey capture) async =>
    (await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(capture),
      );
      final image = await boundary.toImage();
      try {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [
          for (final position in const [
            Offset(.05, .05),
            Offset(.5, .5),
            Offset(.95, .95),
          ])
            () {
              final pixel =
                  ((image.height * position.dy).floor() * image.width +
                      (image.width * position.dx).floor()) *
                  4;
              return Color.fromARGB(
                data.getUint8(pixel + 3),
                data.getUint8(pixel),
                data.getUint8(pixel + 1),
                data.getUint8(pixel + 2),
              );
            }(),
        ];
      } finally {
        image.dispose();
      }
    }))!;

Future<List<Color>> _grid(
  WidgetTester tester,
  GlobalKey capture,
  String name,
) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(capture),
  );
  final image = await boundary.toImage();
  try {
    const captureImages = bool.fromEnvironment('CAPTURE_LYRICS_GRADIENT');
    if (captureImages) {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File(
        '.dart_tool/lyrics-motion-$name.png',
      ).writeAsBytes(png.buffer.asUint8List());
    }
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final colors = <Color>[];
    for (var y = 10; y < image.height; y += 20) {
      for (var x = 10; x < image.width; x += 20) {
        final pixel = (y * image.width + x) * 4;
        colors.add(
          Color.fromARGB(
            data.getUint8(pixel + 3),
            data.getUint8(pixel),
            data.getUint8(pixel + 1),
            data.getUint8(pixel + 2),
          ),
        );
      }
    }
    return colors;
  } finally {
    image.dispose();
  }
}))!;
