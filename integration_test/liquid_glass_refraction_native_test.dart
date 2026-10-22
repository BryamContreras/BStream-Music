import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Opt-in native pixel test. It never opens the library or changes settings.
/// Build this target with `flutter build apk --profile`, using a build number
/// at least as high as the INSTALLED versionCode (split APKs can add 2000).
/// Install with `adb install -r` only; stop on any error, never uninstall.
/// Launch manually, forward its VM service port, then run the host driver with
/// VM_SERVICE_URL set: `dart run test_driver/liquid_glass_refraction_driver.dart`.
/// Do NOT use Flutter drive's automatic install: it uninstalls and retries on
/// downgrade/signature errors EVEN with --keep-app-running. Its default
/// teardown also uninstalls. Both paths erase the library and preferences.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native droplet displaces backdrop pixels while growing and moving',
    (tester) async {
      expect(
        ui.ImageFilter.isShaderFilterSupported,
        isTrue,
        reason: 'This native test must exercise a real runtime shader.',
      );
      await LiquidGlassSurface.warmUp();
      final captureKey = GlobalKey();
      const base = Size(76, 60);
      final lens =
          ValueNotifier<({Offset position, double scale, bool enabled})>((
            position: const Offset(104, 170),
            scale: 1,
            enabled: false,
          ));
      addTearDown(lens.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: captureKey,
            child: ValueListenableBuilder(
              valueListenable: lens,
              child: const CustomPaint(painter: _BackdropStripes()),
              builder: (context, value, child) => Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(child: child!),
                  Positioned(
                    left: value.position.dx,
                    top: value.position.dy,
                    width: base.width * 1.22 + 2,
                    height: base.height * 1.22 + 2,
                    child: LiquidGlassRefractiveLens(
                      baseSize: base,
                      scale: value.scale,
                      enabled: value.enabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final density = tester.view.devicePixelRatio;
      final results = <Map<String, Object>>[];
      for (final fixture in [
        (position: const Offset(104, 170), scale: 1.0),
        (position: const Offset(174, 280), scale: 1.22),
        (position: const Offset(-12, 360), scale: 1.12),
      ]) {
        lens.value = (
          position: fixture.position,
          scale: fixture.scale,
          enabled: false,
        );
        await tester.pumpAndSettle();
        final before = await _pixels(captureKey, density);
        lens.value = (
          position: fixture.position,
          scale: fixture.scale,
          enabled: true,
        );
        await tester.pumpAndSettle();
        final live = find.byKey(LiquidGlassRefractiveLens.backdropKey);
        expect(live, findsOneWidget);
        final renderer = tester.renderObject(live) as dynamic;
        expect(renderer.debugIsRefracting, isTrue);
        final after = await _pixels(captureKey, density);
        expect(after.width, before.width);
        expect(after.height, before.height);
        final lensBounds = Rect.fromLTWH(
          fixture.position.dx + 1 + base.width * (1.22 - fixture.scale) / 2,
          fixture.position.dy + 1 + base.height * (1.22 - fixture.scale) * 0.7,
          base.width * fixture.scale,
          base.height * fixture.scale,
        );
        var displaced = 0;
        var interiorDisplaced = 0;
        var exteriorChanges = 0;
        // Exclude the entire perimeter band: the old rim-only shader must not
        // pass merely because its outer contour already displaces pixels.
        final interiorBounds = lensBounds.deflate(
          lensBounds.shortestSide * 0.28,
        );
        for (var y = 0; y < after.height; y += 4) {
          for (var x = 0; x < after.width; x += 4) {
            final offset = (y * after.width + x) * 4;
            var largestDifference = 0;
            for (var channel = 0; channel < 3; channel++) {
              final difference =
                  (before.bytes[offset + channel] -
                          after.bytes[offset + channel])
                      .abs();
              if (difference > largestDifference) {
                largestDifference = difference;
              }
            }
            final point = Offset(x / density, y / density);
            if (lensBounds.deflate(2).contains(point) &&
                largestDifference > 120) {
              displaced++;
            }
            if (interiorBounds.contains(point) && largestDifference > 120) {
              interiorDisplaced++;
            }
            if (!lensBounds.inflate(2).contains(point) &&
                largestDifference > 8) {
              exteriorChanges++;
            }
          }
        }
        // A bevel or highlight cannot flip the strongly saturated stripe colours
        // by this amount. This verifies displaced background samples, not paint.
        expect(displaced, greaterThan(60));
        if (fixture.scale > 1) {
          expect(
            interiorDisplaced,
            greaterThan(20),
            reason: 'Movement must also bend the interior background image.',
          );
        }
        expect(
          exteriorChanges,
          0,
          reason: 'The real lens must stay tightly bounded.',
        );
        results.add({
          'scale': fixture.scale,
          'x': fixture.position.dx,
          'displacedSamples': displaced,
          'interiorDisplacedSamples': interiorDisplaced,
          'exteriorChanges': exteriorChanges,
        });
      }
      binding.reportData = {'nativeRefractiveLens': results};
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native droplet refracts actual icons and text, not their hit targets',
    (tester) async {
      expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
      await LiquidGlassSurface.warmUp();
      final captureKey = GlobalKey();
      const base = Size(76, 60);
      final lens = ValueNotifier<({double left, bool enabled})>((
        left: 12,
        enabled: false,
      ));
      addTearDown(lens.dispose);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: captureKey,
            child: ValueListenableBuilder(
              valueListenable: lens,
              // A retained, single set of real Flutter glyphs, as in the menu.
              child: Positioned(
                left: 20,
                top: 220,
                width: 320,
                height: 64,
                child: Row(
                  children: [
                    for (final (icon, label) in [
                      (Icons.home_rounded, 'Inicio'),
                      (Icons.folder_rounded, 'Local'),
                      (Icons.library_music_rounded, 'Biblioteca'),
                      (Icons.settings_rounded, 'Ajustes'),
                    ])
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => taps++,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(icon, size: 26, color: Colors.white),
                              const SizedBox(height: 4),
                              Text(
                                label,
                                maxLines: 1,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              builder: (context, value, controls) => Stack(
                fit: StackFit.expand,
                children: [
                  const Positioned.fill(
                    child: ColoredBox(color: Color(0xFF182431)),
                  ),
                  controls!,
                  Positioned(
                    left: value.left,
                    top: 210,
                    width: base.width * 1.22 + 2,
                    height: base.height * 1.22 + 2,
                    child: IgnorePointer(
                      child: LiquidGlassRefractiveLens(
                        baseSize: base,
                        scale: 1.22,
                        enabled: value.enabled,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final density = tester.view.devicePixelRatio;
      final results = <Map<String, Object>>[];
      for (final left in [12.0, 92.0, 52.0]) {
        lens.value = (left: left, enabled: false);
        await tester.pumpAndSettle();
        final before = await _pixels(captureKey, density);
        lens.value = (left: left, enabled: true);
        await tester.pumpAndSettle();
        final after = await _pixels(captureKey, density);
        final bounds = Rect.fromLTWH(
          left + 1,
          211,
          base.width * 1.22,
          base.height * 1.22,
        );
        var removedInk = 0;
        var addedInk = 0;
        var changedIconInk = 0;
        var changedTextInk = 0;
        var exteriorChanges = 0;
        for (var y = 0; y < after.height; y += 2) {
          for (var x = 0; x < after.width; x += 2) {
            final offset = (y * after.width + x) * 4;
            bool ink(Uint8List bytes) =>
                bytes[offset] > 180 &&
                bytes[offset + 1] > 180 &&
                bytes[offset + 2] > 180;
            final point = Offset(x / density, y / density);
            final wasInk = ink(before.bytes);
            final isInk = ink(after.bytes);
            if (bounds.deflate(2).contains(point) && wasInk != isInk) {
              if (wasInk) {
                removedInk++;
              } else {
                addedInk++;
              }
              if (point.dy < 257) {
                changedIconInk++;
              } else {
                changedTextInk++;
              }
            }
            if (!bounds.inflate(2).contains(point)) {
              for (var channel = 0; channel < 3; channel++) {
                if ((before.bytes[offset + channel] -
                            after.bytes[offset + channel])
                        .abs() >
                    8) {
                  exteriorChanges++;
                  break;
                }
              }
            }
          }
        }
        // Colour/tint changes cannot relocate ink from a white glyph onto the
        // dark material. Verify both departures and arrivals, for icons AND text.
        expect(removedInk, greaterThan(10));
        expect(addedInk, greaterThan(10));
        expect(changedIconInk, greaterThan(10));
        expect(changedTextInk, greaterThan(10));
        expect(exteriorChanges, 0);
        await tester.tapAt(const Offset(60, 246));
        expect(
          taps,
          results.length + 1,
          reason: 'The lens must not intercept the controls.',
        );
        results.add({
          'left': left,
          'removedInk': removedInk,
          'addedInk': addedInk,
          'changedIconInk': changedIconInk,
          'changedTextInk': changedTextInk,
          'exteriorChanges': exteriorChanges,
        });
      }
      binding.reportData = {
        ...?binding.reportData,
        'nativeRefractedControls': results,
      };
      expect(tester.takeException(), isNull);
    },
  );
}

Future<({Uint8List bytes, int width, int height})> _pixels(
  GlobalKey key,
  double density,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: density);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return (
      bytes: data.buffer.asUint8List(),
      width: image.width,
      height: image.height,
    );
  } finally {
    image.dispose();
  }
}

class _BackdropStripes extends CustomPainter {
  const _BackdropStripes();
  @override
  void paint(Canvas canvas, Size size) {
    const colours = [Color(0xFFFA1838), Color(0xFF19E657), Color(0xFF194DF4)];
    final paint = Paint();
    for (var column = 0; column * 7 < size.width; column++) {
      paint.color = colours[column % colours.length];
      canvas.drawRect(Rect.fromLTWH(column * 7, 0, 7, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_BackdropStripes oldDelegate) => false;
}
