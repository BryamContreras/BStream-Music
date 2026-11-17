import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/home_loading_content.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _captureKey = ValueKey('loading-capture');

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('loading shimmer paints movement in $brightness', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(brightness: brightness));
      final before = await _pixels(tester);
      final bounds = tester.getRect(find.byType(HomeLoadingContent));
      await tester.pump(const Duration(milliseconds: 600));
      final after = await _pixels(tester);

      expect(listEquals(after, before), isFalse);
      expect(tester.getRect(find.byType(HomeLoadingContent)), bounds);
      expect(find.bySemanticsLabel('Loading recommendations'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reduced motion stays static and can be changed live', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(reducedMotion: true));
    final before = await _pixels(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(listEquals(await _pixels(tester), before), isTrue);
    expect(tester.binding.transientCallbackCount, 0);

    await tester.pumpWidget(_harness());
    final enabled = await _pixels(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(listEquals(await _pixels(tester), enabled), isFalse);

    await tester.pumpWidget(_harness(reducedMotion: true));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'hidden and background loading stop requesting animation frames',
    (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await tester.pumpWidget(_harness());
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(_harness(tickerEnabled: false));
      final hidden = await _pixels(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(listEquals(await _pixels(tester), hidden), isTrue);
      expect(tester.binding.transientCallbackCount, 0);

      await tester.pumpWidget(_harness());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.binding.transientCallbackCount, 0);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      final resumed = await _pixels(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(listEquals(await _pixels(tester), resumed), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _harness({
  Brightness brightness = Brightness.light,
  bool reducedMotion = false,
  bool tickerEnabled = true,
}) => MaterialApp(
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    ),
  ),
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(360, 700),
      disableAnimations: reducedMotion,
    ),
    child: TickerMode(
      enabled: tickerEnabled,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 360,
          height: 700,
          child: RepaintBoundary(
            key: _captureKey,
            child: const SingleChildScrollView(
              child: HomeLoadingContent(label: 'Loading recommendations'),
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<Uint8List> _pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return Uint8List.fromList(pixels!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  }))!;
}
