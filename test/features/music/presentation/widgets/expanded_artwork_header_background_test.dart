import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/expanded_artwork_header_background.dart';
import 'package:bstream_music/features/music/presentation/widgets/reflected_artwork_image.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _captureKey = ValueKey('expanded-header-capture');
const _size = Size(321.25, 620.5);
const _artworkHeight = 360.25;

void main() {
  testWidgets(
    'shares one decoded photo and matching crop with its reflection',
    (tester) async {
      final file = await _createArtwork(tester);
      await _mount(tester, file, Brightness.dark);

      expect(find.byType(SourceImage), findsOneWidget);
      final source = tester.widget<SourceImage>(find.byType(SourceImage));
      expect(source.cacheWidth, 1024);
      final reflection = tester.widget<ProgressiveReflectedArtworkImage>(
        find.byType(ProgressiveReflectedArtworkImage),
      );
      final photoFinder = _photoFinder();
      expect(photoFinder, findsOneWidget);
      final photo = tester.widget<RawImage>(photoFinder);
      expect(photo.image!.isCloneOf(reflection.image), isTrue);
      expect(photo.fit, BoxFit.cover);
      expect(photo.alignment, Alignment.center);
      expect(reflection.alignment, photo.alignment);

      final origin = tester.getTopLeft(find.byKey(_captureKey));
      expect(
        tester.getRect(photoFinder).shift(-origin),
        reflection.artworkRect,
        reason: 'The reflected edge must continue the foreground crop.',
      );
      expect(reflection.artworkRect.width, _size.width);
      expect(reflection.artworkRect.height, _artworkHeight);
      expect(tester.takeException(), isNull);
    },
  );

  for (final preserveAspectRatio in [false, true]) {
    testWidgets(
      'keeps the small blurred raster through unrelated rebuilds (complete photo=$preserveAspectRatio)',
      (tester) async {
        final file = await _createArtwork(tester);
        await _mount(
          tester,
          file,
          Brightness.dark,
          preserveArtworkAspectRatio: preserveAspectRatio,
        );
        final reflectionFinder = find.byType(ProgressiveReflectedArtworkImage);
        final rasterFinder = find.descendant(
          of: reflectionFinder,
          matching: find.byType(RawImage),
        );
        final raster = tester.widget<RawImage>(rasterFinder).image!;
        expect(raster.width, lessThanOrEqualTo(240));
        expect(raster.height, lessThanOrEqualTo(2048));

        await tester.pumpWidget(
          _frame(
            file,
            Brightness.dark,
            preserveArtworkAspectRatio: preserveAspectRatio,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<RawImage>(rasterFinder).image, same(raster));
        expect(raster.debugDisposed, isFalse);

        await tester.pumpWidget(const SizedBox.shrink());
        expect(raster.debugDisposed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('shares an upper portrait crop on wide headers', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final file = await _createArtwork(tester);
    await _mount(
      tester,
      file,
      Brightness.dark,
      size: const Size(1024, 700),
      artworkHeight: 440,
    );
    final reflection = tester.widget<ProgressiveReflectedArtworkImage>(
      find.byType(ProgressiveReflectedArtworkImage),
    );
    final photo = tester.widget<RawImage>(_photoFinder());
    expect(photo.alignment, const Alignment(0, -0.5));
    expect(reflection.alignment, photo.alignment);
    expect(reflection.artworkRect, const Rect.fromLTWH(0, 0, 1024, 440));
    expect(photo.image!.isCloneOf(reflection.image), isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final width in [600.0, 1080.0]) {
    testWidgets(
      'an explicit crop preserves the original upper edge at $width px',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final file = await _createArtwork(tester);
        await _mount(
          tester,
          file,
          Brightness.dark,
          size: Size(width, 700),
          artworkHeight: 440,
          alignment: Alignment.topCenter,
        );
        final photo = tester.widget<RawImage>(_photoFinder());
        final reflection = tester.widget<ProgressiveReflectedArtworkImage>(
          find.byType(ProgressiveReflectedArtworkImage),
        );
        final imageSize = Size(
          photo.image!.width.toDouble(),
          photo.image!.height.toDouble(),
        );
        final fitted = applyBoxFit(photo.fit!, imageSize, Size(width, 440));
        final sourceCrop = photo.alignment
            .resolve(TextDirection.ltr)
            .inscribe(fitted.source, Offset.zero & imageSize);
        expect(sourceCrop.top, 0);
        expect(sourceCrop.height, lessThan(imageSize.height));
        expect(reflection.alignment, Alignment.topCenter);
        expect(reflection.artworkRect, Rect.fromLTWH(0, 0, width, 440));
        expect(photo.image!.isCloneOf(reflection.image), isTrue);
        expect(find.byType(SourceImage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [600.0, 1080.0]) {
    for (final sourceSize in [
      const Size(960, 540),
      const Size(384, 384),
      const Size(384, 768),
    ]) {
      testWidgets(
        'desktop gives $sourceSize photos a larger crop at $width px',
        (tester) async {
          tester.view.physicalSize = const Size(1280, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final file = await _createArtwork(tester, size: sourceSize);
          await _mount(
            tester,
            file,
            Brightness.dark,
            size: Size(width, 700),
            artworkHeight: 440,
            preserveArtworkAspectRatio: true,
          );
          final photo = tester.widget<RawImage>(_photoFinder());
          final reflection = tester.widget<ProgressiveReflectedArtworkImage>(
            find.byType(ProgressiveReflectedArtworkImage),
          );
          final imageSize = Size(
            photo.image!.width.toDouble(),
            photo.image!.height.toDouble(),
          );
          final photoBounds = tester.getRect(_photoFinder());
          final fitted = applyBoxFit(photo.fit!, imageSize, photoBounds.size);
          final sourceCrop = photo.alignment
              .resolve(TextDirection.ltr)
              .inscribe(fitted.source, Offset.zero & imageSize);
          // Narrow photos get a visible enlargement while retaining the
          // upper composition and matching the same reflected source crop.
          expect(sourceCrop.left, closeTo(0, 0.01));
          expect(sourceCrop.top, lessThanOrEqualTo(imageSize.height * 0.06));
          expect(sourceCrop.width, closeTo(imageSize.width, 0.01));
          expect(
            sourceCrop.height,
            greaterThanOrEqualTo(imageSize.height / 1.80 - 0.01),
          );
          final contained = applyBoxFit(
            BoxFit.contain,
            imageSize,
            Size(width, 440),
          ).destination;
          if (contained.width < width) {
            expect(
              photoBounds.width,
              greaterThanOrEqualTo((contained.width * 1.75).clamp(0.0, width)),
            );
          } else {
            expect(photoBounds.width, closeTo(contained.width, 0.01));
            expect(sourceCrop.height, closeTo(imageSize.height, 0.01));
          }
          expect(photoBounds.width, lessThanOrEqualTo(width));
          expect(photoBounds.height, lessThanOrEqualTo(440));
          expect(reflection.alignment, photo.alignment);
          final origin = tester.getTopLeft(find.byKey(_captureKey));
          expect(reflection.artworkRect, photoBounds.shift(-origin));
          expect(photo.image!.isCloneOf(reflection.image), isTrue);
          expect(find.byType(SourceImage), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final layout in [
    (size: _size, artworkHeight: _artworkHeight),
    (size: const Size(1024, 700), artworkHeight: 440.0),
  ]) {
    testWidgets(
      'keeps the upper artist join minimal at width ${layout.size.width}',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final file = await _createArtwork(tester);
        await _mount(
          tester,
          file,
          Brightness.dark,
          size: layout.size,
          artworkHeight: layout.artworkHeight,
          artworkTopInset: 44,
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_captureKey),
        );
        final pixels = (await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final data = await image.toByteData();
            return _Pixels(
              image.width,
              image.height,
              data!.buffer.asUint8List(),
            );
          } finally {
            image.dispose();
          }
        }))!;
        // The fixture has a crisp teal/gray edge one third across its square.
        // Four pixels below the inset it must already be the focused photo,
        // rather than the blurred reflection filling the old upper margin.
        final scaledWidth = math.max(layout.size.width, layout.artworkHeight);
        final colorEdge =
            scaledWidth / 3 - (scaledWidth - layout.size.width) / 2;
        final left = (colorEdge - 4).floor();
        final right = (colorEdge + 4).ceil();
        expect(
          pixels.at(right, 48, 0) - pixels.at(left, 48, 0),
          greaterThan(100),
        );
        expect(find.byType(SourceImage), findsOneWidget);
        expect(find.byType(ShaderMask), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'continues the photo behind the system inset without an upper seam',
    (tester) async {
      final file = await _createArtwork(tester);
      await _mount(tester, file, Brightness.dark, artworkTopInset: 44);
      final photoFinder = _photoFinder();
      final reflection = tester.widget<ProgressiveReflectedArtworkImage>(
        find.byType(ProgressiveReflectedArtworkImage),
      );
      expect(reflection.artworkRect.top, 44);
      final origin = tester.getTopLeft(find.byKey(_captureKey));
      expect(
        tester.getRect(photoFinder).shift(-origin),
        reflection.artworkRect,
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_captureKey),
      );
      final pixels = (await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final data = await image.toByteData();
          return _Pixels(image.width, image.height, data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      }))!;
      for (final fraction in [0.2, 0.5, 0.8]) {
        final x = (pixels.width * fraction).floor();
        for (var y = 40; y < 95; y++) {
          expect(pixels.at(x, y, 3), 255);
          for (var channel = 0; channel < 3; channel++) {
            expect(
              (pixels.at(x, y, channel) - pixels.at(x, y - 1, channel)).abs(),
              lessThanOrEqualTo(8),
            );
          }
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'fades into the $brightness body without a lower horizontal seam',
      (tester) async {
        final file = await _createArtwork(tester);
        await _mount(tester, file, brightness);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_captureKey),
        );
        final pixels = (await tester.runAsync(() async {
          // Fractional layout and raster coordinates expose one-row fringes.
          final image = await boundary.toImage(pixelRatio: 1.25);
          try {
            final data = await image.toByteData();
            return _Pixels(
              image.width,
              image.height,
              data!.buffer.asUint8List(),
            );
          } finally {
            image.dispose();
          }
        }))!;

        final base = _baseColor(brightness);
        final expected = [
          (base.r * 255).round(),
          (base.g * 255).round(),
          (base.b * 255).round(),
        ];
        for (final fraction in [0.1, 0.5, 0.9]) {
          final x = (pixels.width * fraction).floor();
          for (var channel = 0; channel < 3; channel += 1) {
            expect(
              pixels.at(x, pixels.height - 1, channel),
              closeTo(expected[channel], 2),
              reason: 'The photo mask must be transparent at its lower edge.',
            );
          }
          var largestJump = 0;
          for (
            var y = (pixels.height * 0.65).floor();
            y < pixels.height;
            y += 1
          ) {
            for (var channel = 0; channel < 3; channel += 1) {
              largestJump = math.max(
                largestJump,
                (pixels.at(x, y, channel) - pixels.at(x, y - 1, channel)).abs(),
              );
            }
            expect(pixels.at(x, y, 3), 255);
          }
          expect(
            largestJump,
            lessThanOrEqualTo(8),
            reason: 'The reflection must blend continuously into the body.',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Finder _photoFinder() => find.byWidgetPredicate((widget) {
  if (widget is! RawImage) return false;
  return widget.key != const ValueKey('progressive-reflected-artwork-raster');
});

Color _baseColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFF111718)
    : const Color(0xFFF4F7F8);

Widget _frame(
  File file,
  Brightness brightness, {
  Size size = _size,
  double artworkHeight = _artworkHeight,
  double artworkTopInset = 0,
  Alignment? alignment,
  bool preserveArtworkAspectRatio = false,
}) => ProviderScope(
  child: MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: _captureKey,
          child: SizedBox.fromSize(
            size: size,
            child: ColoredBox(
              color: _baseColor(brightness),
              child: ExpandedArtworkHeaderBackground(
                artworkSource: file.path,
                artworkHeight: artworkHeight,
                artworkTopInset: artworkTopInset,
                alignment: alignment,
                preserveArtworkAspectRatio: preserveArtworkAspectRatio,
                keyPrefix: 'artist-test',
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _mount(
  WidgetTester tester,
  File file,
  Brightness brightness, {
  Size size = _size,
  double artworkHeight = _artworkHeight,
  double artworkTopInset = 0,
  Alignment? alignment,
  bool preserveArtworkAspectRatio = false,
}) async {
  await tester.pumpWidget(
    _frame(
      file,
      brightness,
      size: size,
      artworkHeight: artworkHeight,
      artworkTopInset: artworkTopInset,
      alignment: alignment,
      preserveArtworkAspectRatio: preserveArtworkAspectRatio,
    ),
  );
  await tester.runAsync(
    () => precacheImage(
      ResizeImage(FileImage(file), width: 1024),
      tester.element(find.byType(ExpandedArtworkHeaderBackground)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<File> _createArtwork(
  WidgetTester tester, {
  Size size = const Size(384, 384),
}) async {
  final directory = Directory.systemTemp.createTempSync('bstream-artist-hero-');
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    directory.deleteSync(recursive: true);
  });
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(size.width / 384, size.height / 384);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 384, 384),
      Paint()..color = const Color(0xFFE0E1E3),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 128, 384),
      Paint()..color = const Color(0xFF28B8BE),
    );
    canvas.drawRect(
      const Rect.fromLTWH(256, 0, 128, 384),
      Paint()..color = const Color(0xFFF38082),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 360, 384, 24),
      Paint()..color = Colors.white,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return File('${directory.path}/artist.png')
        ..writeAsBytesSync(png!.buffer.asUint8List());
    } finally {
      image.dispose();
      picture.dispose();
    }
  }))!;
}

class _Pixels {
  const _Pixels(this.width, this.height, this.bytes);

  final int width;
  final int height;
  final Uint8List bytes;

  int at(int x, int y, int channel) => bytes[(y * width + x) * 4 + channel];
}
