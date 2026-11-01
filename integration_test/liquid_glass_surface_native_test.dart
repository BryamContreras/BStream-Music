import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Build as a profile APK with an isolated application ID and install manually
/// with adb install -r. This fixture uses no application settings or library.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('retained native glass samples the current backdrop', (
    tester,
  ) async {
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
    await LiquidGlassSurface.warmUp();
    final captureKey = GlobalKey();
    const glassKey = ValueKey('retained-native-glass');
    final color = ValueNotifier(Colors.blue);
    addTearDown(color.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          brightness: Brightness.dark,
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ValueListenableBuilder(
                valueListenable: color,
                builder: (context, value, _) => ColoredBox(color: value),
              ),
              Center(
                child: RepaintBoundary(
                  child: SizedBox(
                    width: 280,
                    height: 64,
                    child: LiquidGlassSurface(
                      key: glassKey,
                      borderRadius: BorderRadius.circular(32),
                      blurSigma: 8,
                      child: const Center(child: Text('Live glass')),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final renderer =
        tester.renderObject(find.byKey(LiquidGlassSurface.backdropKey))
            as dynamic;
    expect(renderer.debugIsRefracting, isTrue);
    final capture =
        captureKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    // WidgetTester.layers uses debugLayer, which is null in a profile APK.
    // Read the actual capture subtree without relying on debug-only APIs.
    // ignore: invalid_use_of_protected_member
    final captureLayer = capture.layer!;
    final filters = _layersIn(
      captureLayer,
    ).whereType<BackdropFilterLayer>().toList();
    expect(filters, hasLength(2));
    // ignore: invalid_use_of_protected_member
    final outer = filters.first.engineLayer;
    // ignore: invalid_use_of_protected_member
    final inner = filters.last.engineLayer;
    expect(outer, isNotNull);
    expect(inner, isNotNull);
    final density = tester.view.devicePixelRatio;
    final width = (tester.getSize(find.byKey(captureKey)).width * density)
        .round();
    final bounds = tester.getRect(find.byKey(glassKey)).deflate(8);
    final region = Rect.fromLTRB(
      bounds.left * density,
      bounds.top * density,
      bounds.right * density,
      bounds.bottom * density,
    );
    var previous = await _pixels(captureKey, density);
    final changes = <int>[];
    for (final next in [Colors.red, Colors.green, Colors.blue]) {
      color.value = next;
      await tester.pumpAndSettle();
      expect(renderer.debugIsRefracting, isTrue);
      // ignore: invalid_use_of_protected_member
      expect(filters.first.engineLayer, same(outer));
      // ignore: invalid_use_of_protected_member
      expect(filters.last.engineLayer, same(inner));
      final current = await _pixels(captureKey, density);
      var changed = 0;
      for (var y = region.top.ceil(); y < region.bottom.floor(); y++) {
        for (var x = region.left.ceil(); x < region.right.floor(); x++) {
          final index = (y * width + x) * 4;
          if ((previous[index] - current[index]).abs() > 8 ||
              (previous[index + 1] - current[index + 1]).abs() > 8 ||
              (previous[index + 2] - current[index + 2]).abs() > 8) {
            changed++;
          }
        }
      }
      expect(changed, greaterThan(1000));
      changes.add(changed);
      previous = current;
    }
    binding.reportData = {
      ...?binding.reportData,
      'nativeRetainedLiveGlass': {'changedInteriorPixels': changes},
    };
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('native glass retains bounded refraction after repeated pauses', (
    tester,
  ) async {
    expect(ui.ImageFilter.isShaderFilterSupported, isTrue);
    await LiquidGlassSurface.warmUp();
    final captureKey = GlobalKey();
    final enabled = ValueNotifier(true);
    final position = ValueNotifier(const Offset(40, 320));
    final refracts = ValueNotifier(true);
    final liveBackdrop = ValueNotifier(true);
    final opacity = ValueNotifier(1.0);
    final platform = ValueNotifier(TargetPlatform.android);
    addTearDown(enabled.dispose);
    addTearDown(position.dispose);
    addTearDown(refracts.dispose);
    addTearDown(liveBackdrop.dispose);
    addTearDown(opacity.dispose);
    addTearDown(platform.dispose);
    final results = <Map<String, Object>>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          brightness: Brightness.dark,
        ),
        home: RepaintBoundary(
          key: captureKey,
          child: LiquidGlassEffectsScope(
            enabled: enabled,
            child: ValueListenableBuilder(
              valueListenable: position,
              child: const CustomPaint(painter: _Stripes()),
              builder: (context, offset, backdrop) => Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(child: backdrop!),
                  Positioned(
                    left: offset.dx,
                    top: offset.dy,
                    width: 280,
                    height: 64,
                    child: ListenableBuilder(
                      listenable: Listenable.merge([
                        refracts,
                        liveBackdrop,
                        opacity,
                        platform,
                      ]),
                      builder: (context, _) => Theme(
                        data: Theme.of(
                          context,
                        ).copyWith(platform: platform.value),
                        child: Opacity(
                          opacity: opacity.value,
                          child: LiquidGlassSurface(
                            borderRadius: BorderRadius.circular(32),
                            adaptiveEdgeEnabled: refracts.value,
                            blurSigma: liveBackdrop.value ? 8 : 0,
                            // Prefer bounded input over the shell's larger envelope.
                            backdropEnvelope: const Rect.fromLTWH(
                              -40,
                              0,
                              360,
                              64,
                            ),
                            child: const Center(child: Text('Liquid Glass')),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (final offset in [
      const Offset(40, 320),
      const Offset(80.25, 540.5),
      const Offset(-24, 420),
    ]) {
      position.value = offset;
      await tester.pumpAndSettle();
      final renderer =
          tester.renderObject(find.byKey(LiquidGlassSurface.backdropKey))
              as dynamic;
      expect(renderer.debugUsesBoundedInput, isTrue);
      expect(renderer.debugIsRefracting, isTrue);
      final bounds = renderer.debugResolvedBounds as Rect;
      final density = tester.view.devicePixelRatio;
      expect(bounds.size, Size(280 * density, 64 * density));
      final before = await _pixels(captureKey, density);
      enabled.value = false;
      await tester.pumpAndSettle();
      expect(renderer.debugEffectsEnabled, isFalse);
      enabled.value = true;
      await tester.pumpAndSettle();
      expect(
        tester.renderObject(find.byKey(LiquidGlassSurface.backdropKey)),
        same(renderer),
      );
      expect(renderer.debugIsRefracting, isTrue);
      final restored = await _pixels(captureKey, density);
      final restorationChanges = _changedPixels(before, restored);
      expect(
        restorationChanges,
        lessThanOrEqualTo(48),
        // Native mask/raster-cache quantization may move a few AA pixels.
        reason: 'Restored glass must retain its optical geometry.',
      );
      refracts.value = false;
      await tester.pumpAndSettle();
      final blurred = await _pixels(captureKey, density);
      final refractedPixels = _changedPixels(restored, blurred);
      expect(
        refractedPixels,
        greaterThan(100),
        reason: 'Native refraction must remain visible.',
      );
      results.add({
        'xDp': offset.dx,
        'yDp': offset.dy,
        'boundedWidthPx': bounds.width,
        'boundedHeightPx': bounds.height,
        'restorationChangedPixels': restorationChanges,
        'refractedPixels': refractedPixels,
      });
      refracts.value = true;
    }
    final fades = <Map<String, Object>>[];
    position.value = const Offset(40, 320);
    for (final alpha in [0.75, 0.5, 0.25]) {
      opacity.value = alpha;
      platform.value = TargetPlatform.windows;
      refracts.value = true;
      liveBackdrop.value = false;
      await tester.pumpAndSettle();
      final original = await _pixels(captureKey, tester.view.devicePixelRatio);
      platform.value = TargetPlatform.android;
      refracts.value = true;
      liveBackdrop.value = true;
      await tester.pumpAndSettle();
      final fading =
          tester.renderObject(find.byKey(LiquidGlassSurface.backdropKey))
              as dynamic;
      expect(fading.debugIsRefracting, isFalse);
      final bounded = await _pixels(captureKey, tester.view.devicePixelRatio);
      final changes = _changedPixels(original, bounded);
      final error = _meanError(original, bounded);
      expect(
        changes,
        lessThan(500),
        reason: 'Fades must retain their foreground optics.',
      );
      expect(
        error,
        lessThan(0.25),
        reason: 'Fades must preserve tint, controls and painted optics.',
      );
      fades.add({
        'opacity': alpha,
        'changedPixels': changes,
        'meanChannelError': error,
      });
    }
    opacity.value = 1;
    await tester.pumpAndSettle();
    final settled =
        tester.renderObject(find.byKey(LiquidGlassSurface.backdropKey))
            as dynamic;
    expect(settled.debugIsRefracting, isTrue);
    expect(settled.debugUsesBoundedInput, isTrue);
    binding.reportData = {
      ...?binding.reportData,
      'nativeBoundedGlass': results,
      'nativeGlassFadesWithPausedBackdrop': fades,
    };
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

Iterable<Layer> _layersIn(Layer layer) sync* {
  yield layer;
  if (layer is ContainerLayer) {
    for (
      var child = layer.firstChild;
      child != null;
      child = child.nextSibling
    ) {
      yield* _layersIn(child);
    }
  }
}

Future<Uint8List> _pixels(GlobalKey key, double density) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: density);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return Uint8List.fromList(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  } finally {
    image.dispose();
  }
}

int _changedPixels(Uint8List first, Uint8List second) {
  expect(first.length, second.length);
  var changed = 0;
  for (var i = 0; i < first.length; i += 4) {
    if ((first[i] - second[i]).abs() > 8 ||
        (first[i + 1] - second[i + 1]).abs() > 8 ||
        (first[i + 2] - second[i + 2]).abs() > 8) {
      changed++;
    }
  }
  return changed;
}

double _meanError(Uint8List first, Uint8List second) {
  var error = 0;
  for (var i = 0; i < first.length; i += 4) {
    for (var channel = 0; channel < 3; channel++) {
      error += (first[i + channel] - second[i + channel]).abs();
    }
  }
  return error / (first.length / 4 * 3);
}

class _Stripes extends CustomPainter {
  const _Stripes();

  @override
  void paint(Canvas canvas, Size size) {
    const colors = [Color(0xff1648be), Color(0xffed8419), Color(0xff1ba074)];
    final paint = Paint();
    for (var x = 0.0; x < size.width; x += 24) {
      paint.color = colors[(x / 24).floor() % colors.length];
      canvas.drawRect(Rect.fromLTWH(x, 0, 24, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => false;
}
