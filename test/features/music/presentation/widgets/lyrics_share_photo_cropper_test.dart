import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_share_photo_cropper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'wide photos remain covered while zooming and dragging to edges',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final image = await _image(tester, 1200, 600);
      addTearDown(image.dispose);
      Rect? result;
      await _open(tester, image, .75, (crop) => result = crop);

      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('lyrics-photo-crop-zoom')),
      );
      slider.onChanged!(2);
      await tester.pump();
      await tester.drag(
        find.byKey(const ValueKey('lyrics-photo-crop-frame')),
        const Offset(-1000, -1000),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('lyrics-photo-crop-confirm')));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.width, closeTo(.1875, .000001));
      expect(result!.height, closeTo(.5, .000001));
      expect(result!.right, closeTo(1, .000001));
      expect(result!.bottom, closeTo(1, .000001));
      expect(
        result!.width * image.width / (result!.height * image.height),
        .75,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('portrait crop survives rotation and reset, and back cancels', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final image = await _image(tester, 300, 900);
    addTearDown(image.dispose);
    Rect? result;
    var completed = false;
    await _open(tester, image, 1, (crop) {
      result = crop;
      completed = true;
    });
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.pump();
    final sliderFinder = find.byKey(const ValueKey('lyrics-photo-crop-zoom'));
    expect(tester.widget<Slider>(sliderFinder).value, closeTo(1.1, .000001));

    await tester.binding.setSurfaceSize(const Size(820, 390));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(sliderFinder).value, closeTo(1.1, .000001));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('lyrics-photo-crop-reset')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('lyrics-photo-crop-confirm')));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(result!.left, closeTo(0, .000001));
    expect(result!.top, closeTo(1 / 3, .000001));
    expect(result!.width, closeTo(1, .000001));
    expect(result!.height, closeTo(1 / 3, .000001));

    completed = false;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
    // The crop route has closed, but ownership stays with the caller.
    expect(image.width, 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening a photo preserves the selected source area', (
    tester,
  ) async {
    final image = await _image(tester, 300, 900);
    addTearDown(image.dispose);
    const previous = Rect.fromLTWH(.1, .4, .5, 1 / 6);
    Rect? result;
    await _open(
      tester,
      image,
      1,
      (crop) => result = crop,
      initialCrop: previous,
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-photo-crop-confirm')));
    await tester.pumpAndSettle();
    expect(result!.left, closeTo(previous.left, .000001));
    expect(result!.top, closeTo(previous.top, .000001));
    expect(result!.width, closeTo(previous.width, .000001));
    expect(result!.height, closeTo(previous.height, .000001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel completes after the departing route releases the photo', (
    tester,
  ) async {
    final image = await _image(tester, 300, 200);
    var disposed = false;
    addTearDown(() {
      if (!disposed) image.dispose();
    });
    await _open(tester, image, 1, (crop) {
      expect(crop, isNull);
      image.dispose();
      disposed = true;
    });

    await tester.tap(find.byType(CloseButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(disposed, isFalse);
    expect(find.byType(LyricsSharePhotoCropper), findsOneWidget);
    await tester.pumpAndSettle();
    expect(disposed, isTrue);
    expect(find.byType(LyricsSharePhotoCropper), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<ui.Image> _image(WidgetTester tester, int width, int height) async {
  late ui.Image image;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.teal, BlendMode.src);
    final picture = recorder.endRecording();
    try {
      image = await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  });
  return image;
}

Future<void> _open(
  WidgetTester tester,
  ui.Image image,
  double aspectRatio,
  ValueChanged<Rect?> onResult, {
  Rect? initialCrop,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appStringsProvider.overrideWithValue(
          const AppStrings(AppLanguage.spanish),
        ),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onResult(
                  await showLyricsSharePhotoCropper(
                    context: context,
                    image: image,
                    aspectRatio: aspectRatio,
                    initialCrop: initialCrop,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
