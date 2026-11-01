import 'dart:ui' as ui;

import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paused glass lets a fading page retain its native subtree', (
    tester,
  ) async {
    final opacity = ValueNotifier(0.75);
    addTearDown(opacity.dispose);
    const boundaryKey = ValueKey('retained-fading-page');
    var resolutions = 0;
    await tester.pumpWidget(
      _harness(
        child: ValueListenableBuilder(
          valueListenable: opacity,
          child: RepaintBoundary(
            key: boundaryKey,
            child: LiquidGlassSurface.debugBackdropLayerHost(
              pauseBackdropDuringOpacity: true,
              devicePixelRatio: 1,
              viewportSize: const Size(800, 600),
              blurFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              resolveMaterial: (_, _) {
                resolutions++;
                return ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2);
              },
            ),
          ),
          builder: (context, value, child) =>
              Opacity(opacity: value, child: child),
        ),
      ),
    );
    _compose(tester);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(boundaryKey),
    );
    final layer = boundary.debugLayer!;
    final native = _engineLayer(layer);
    expect(native, isNotNull);
    for (final alpha in [0.5, 0.25, 0.6]) {
      opacity.value = alpha;
      await tester.pump();
      _compose(tester);
      expect(_engineLayer(layer), same(native));
    }
    expect(resolutions, 0);
    opacity.value = 1;
    await tester.pump();
    _compose(tester);
    expect(resolutions, greaterThan(0));
    expect(_engineLayer(layer), isNot(same(native)));
    final filters = tester.layers.whereType<BackdropFilterLayer>().toList();
    expect(_engineLayer(filters.first), isNotNull);
    expect(_engineLayer(filters.last), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unchanged native filters retain their engine layers', (
    tester,
  ) async {
    final blur = ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8);
    var material = ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2);
    await tester.pumpWidget(
      _harness(
        child: RepaintBoundary(
          child: LiquidGlassSurface.debugBackdropLayerHost(
            devicePixelRatio: 1,
            viewportSize: const Size(800, 600),
            blurFilter: blur,
            resolveMaterial: (_, _) => material,
          ),
        ),
      ),
    );
    _compose(tester);
    final filters = tester.layers.whereType<BackdropFilterLayer>().toList();
    final firstOuter = _engineLayer(filters.first);
    final firstInner = _engineLayer(filters.last);
    expect(firstOuter, isNotNull);
    expect(firstInner, isNotNull);
    for (var frame = 0; frame < 3; frame++) {
      _compose(tester);
      expect(_engineLayer(filters.first), same(firstOuter));
      expect(_engineLayer(filters.last), same(firstInner));
    }

    // A late material change still has to invalidate its retained parent on
    // this frame, even when neither layout nor foreground paint ran again.
    material = ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5);
    _compose(tester);
    expect(_engineLayer(filters.first), isNot(same(firstOuter)));
    expect(_engineLayer(filters.last), isNot(same(firstInner)));
    final updatedOuter = _engineLayer(filters.first);
    final updatedInner = _engineLayer(filters.last);
    _compose(tester);
    expect(_engineLayer(filters.first), same(updatedOuter));
    expect(_engineLayer(filters.last), same(updatedInner));
    expect(tester.takeException(), isNull);
  });

  testWidgets('fading native host pauses captures and preserves foreground', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    await tester.pumpWidget(
      _harness(
        child: Opacity(
          opacity: 0.5,
          child: LiquidGlassSurface.debugBackdropLayerHost(
            pauseBackdropDuringOpacity: true,
            devicePixelRatio: 1,
            viewportSize: const Size(800, 600),
            blurFilter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
            resolveMaterial: (bounds, bounded) {
              calls.add((bounds, bounded));
              return ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2);
            },
          ),
        ),
      ),
    );
    _compose(tester);
    expect(calls, isEmpty);
    final layers = tester.layers.whereType<BackdropFilterLayer>().toList();
    expect(layers, hasLength(2));
    expect(_engineLayer(layers.first), isNull);
    expect(_engineLayer(layers.last), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paused native host retains content and resolves fresh bounds', (
    tester,
  ) async {
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    final calls = <(Rect, bool)>[];
    final contentKey = GlobalKey();
    await tester.pumpWidget(
      _harness(
        child: ValueListenableBuilder(
          valueListenable: enabled,
          child: SizedBox(key: contentKey),
          builder: (context, active, child) => Transform.translate(
            offset: active ? Offset.zero : const Offset(0, -200),
            child: LiquidGlassSurface.debugBackdropLayerHost(
              enabled: active,
              devicePixelRatio: 1,
              viewportSize: const Size(800, 600),
              blurFilter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
              resolveMaterial: (bounds, bounded) {
                calls.add((bounds, bounded));
                return ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2);
              },
              child: child!,
            ),
          ),
        ),
      ),
    );
    _compose(tester);
    final content = contentKey.currentContext!.findRenderObject();
    expect(tester.layers.whereType<BackdropFilterLayer>(), hasLength(2));
    for (var cycle = 0; cycle < 3; cycle++) {
      enabled.value = false;
      await tester.pump();
      final pausedCalls = calls.length;
      _compose(tester);
      expect(calls, hasLength(pausedCalls));
      expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
      expect(contentKey.currentContext!.findRenderObject(), same(content));
      enabled.value = true;
      await tester.pump();
      _compose(tester);
      expect(calls.length, greaterThan(pausedCalls));
      expect(calls.last, (const Rect.fromLTWH(0, 0, 120, 60), true));
      expect(tester.layers.whereType<BackdropFilterLayer>(), hasLength(2));
      expect(contentKey.currentContext!.findRenderObject(), same(content));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop lens is bounded on its very first composed frame', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    await tester.pumpWidget(_harness(child: _host(calls)));
    _compose(tester);

    expect(calls, isNotEmpty);
    expect(calls.last.$2, isTrue);
    expect(calls.last.$1, const Rect.fromLTWH(0, 0, 120, 60));
    final layers = tester.layers.whereType<BackdropFilterLayer>().toList();
    expect(layers, hasLength(2));
    expect(layers.first.blendMode, BlendMode.srcOver);
    expect(layers.last.blendMode, BlendMode.src);
    expect(layers.every((layer) => layer.backdropKey == null), isTrue);
  });

  testWidgets('fractional physical origin is retained without changing size', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    await tester.pumpWidget(
      _harness(
        child: Transform.translate(
          offset: const Offset(0.375, 0.625),
          child: _host(calls),
        ),
      ),
    );
    _compose(tester);

    expect(calls.last.$2, isTrue);
    expect(calls.last.$1, const Rect.fromLTWH(0.375, 0.625, 120, 60));
  });

  testWidgets('clipped lens retains its full SDF size and negative origin', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    await tester.pumpWidget(
      _harness(
        child: ClipRect(
          child: Transform.translate(
            offset: const Offset(-32, 0),
            child: _host(calls),
          ),
        ),
      ),
    );
    _compose(tester);

    expect(calls.last.$2, isTrue);
    expect(calls.last.$1, const Rect.fromLTWH(-32, 0, 120, 60));
  });

  testWidgets('scaled first frame uses the original material and group', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    final group = BackdropKey();
    await tester.pumpWidget(
      _harness(
        child: Transform.scale(
          scale: 0.8,
          child: _host(calls, backdropGroupKey: group),
        ),
      ),
    );
    _compose(tester);

    expect(calls.last.$2, isFalse);
    final outer = tester.layers.whereType<BackdropFilterLayer>().first;
    expect(outer.backdropKey, same(group));
    expect(outer.filter.toString(), contains('5.0'));
  });

  testWidgets('retained glass responds to paint-only scale and recovery', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    final scale = ValueNotifier<double>(1);
    addTearDown(scale.dispose);
    var childBuilds = 0;
    final retained = RepaintBoundary(
      child: Builder(
        builder: (context) {
          childBuilds++;
          return _host(calls);
        },
      ),
    );
    await tester.pumpWidget(
      _harness(
        child: ValueListenableBuilder<double>(
          valueListenable: scale,
          child: retained,
          builder: (context, value, child) =>
              Transform.scale(scale: value, child: child),
        ),
      ),
    );
    _compose(tester);
    expect(calls.last.$2, isTrue);
    expect(childBuilds, 1);

    scale.value = 0.91;
    await tester.pump();
    _compose(tester);
    expect(calls.last.$2, isFalse);
    expect(childBuilds, 1);

    scale.value = 1;
    await tester.pump();
    _compose(tester);
    expect(calls.last.$2, isTrue);
    expect(childBuilds, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained glass tracks paint-only clipping translations', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    final translation = ValueNotifier<double>(0);
    addTearDown(translation.dispose);
    var childBuilds = 0;
    final retained = RepaintBoundary(
      child: Builder(
        builder: (context) {
          childBuilds++;
          return _host(calls);
        },
      ),
    );
    await tester.pumpWidget(
      _harness(
        child: ClipRect(
          child: ValueListenableBuilder<double>(
            valueListenable: translation,
            child: retained,
            builder: (context, value, child) =>
                Transform.translate(offset: Offset(value, 0), child: child),
          ),
        ),
      ),
    );
    _compose(tester);
    expect(calls.last.$1.left, 0);
    translation.value = -21.25;
    await tester.pump();
    _compose(tester);
    expect(calls.last.$2, isTrue);
    expect(calls.last.$1.left, -21.25);
    expect(calls.last.$1.size, const Size(120, 60));
    expect(childBuilds, 1);
  });

  testWidgets('removing a retained lens releases its layers cleanly', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    await tester.pumpWidget(_harness(child: _host(calls)));
    _compose(tester);
    expect(calls, isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('foreground supports IntrinsicWidth in a loose-height Column', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    const foregroundKey = ValueKey('intrinsic-glass-foreground');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IntrinsicWidth(
                  child: _host(
                    calls,
                    child: const Padding(
                      key: foregroundKey,
                      padding: EdgeInsets.all(12),
                      child: Text('Menú del reproductor'),
                    ),
                  ),
                ),
                const Text('Outside glass'),
              ],
            ),
          ),
        ),
      ),
    );
    _compose(tester);

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(foregroundKey)).height, greaterThan(24));
    expect(tester.getSize(find.byKey(foregroundKey)).width, greaterThan(100));
    expect(calls.last.$2, isTrue);
  });

  testWidgets('render proxy preserves foreground dry layout and intrinsics', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    final childKey = GlobalKey();
    await tester.pumpWidget(
      _harness(
        child: _host(
          calls,
          child: SizedBox(key: childKey, width: 72, height: 28),
        ),
      ),
    );
    final child = childKey.currentContext!.findRenderObject()! as RenderBox;
    final host = child.parent! as RenderBox;
    expect(
      host.getDryLayout(BoxConstraints.loose(const Size(200, 200))),
      const Size(72, 28),
    );
    expect(host.getMinIntrinsicWidth(28), 72);
    expect(host.getMaxIntrinsicHeight(72), 28);
  });

  testWidgets(
    'shader failure does not run a second blur in the native target',
    (tester) async {
      var available = true;
      await tester.pumpWidget(
        _harness(
          child: LiquidGlassSurface.debugBackdropLayerHost(
            devicePixelRatio: 1,
            viewportSize: const Size(800, 600),
            blurFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            materialIsRefractive: () => available,
            resolveMaterial: (_, _) {
              // Mirrors a fragment shader throwing during filter creation.
              available = false;
              return ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8);
            },
          ),
        ),
      );
      _compose(tester);

      final filters = tester.layers.whereType<BackdropFilterLayer>().toList();
      expect(filters, hasLength(2));
      expect(_engineLayer(filters.first), isNotNull);
      expect(_engineLayer(filters.last), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('foreground state and focus survive shader readiness changes', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    var available = false;
    final controller = TextEditingController(text: 'Original');
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: _host(
                calls,
                materialIsRefractive: () => available,
                child: TextField(controller: controller, focusNode: focus),
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    final fieldState = tester.state(find.byType(EditableText));
    controller.text = 'Conservar contenido';

    available = true;
    _compose(tester);
    expect(tester.state(find.byType(EditableText)), same(fieldState));
    expect(controller.text, 'Conservar contenido');
    expect(focus.hasFocus, isTrue);
    expect(
      _engineLayer(tester.layers.whereType<BackdropFilterLayer>().last),
      isNotNull,
    );

    available = false;
    _compose(tester);
    expect(tester.state(find.byType(EditableText)), same(fieldState));
    expect(focus.hasFocus, isTrue);
    expect(
      _engineLayer(tester.layers.whereType<BackdropFilterLayer>().last),
      isNull,
    );
  });

  testWidgets('partial-opacity frames restore the original layer topology', (
    tester,
  ) async {
    final calls = <(Rect, bool)>[];
    final alpha = ValueNotifier<double>(1);
    addTearDown(alpha.dispose);
    var builds = 0;
    final retained = RepaintBoundary(
      child: Builder(
        builder: (context) {
          builds++;
          return _host(
            calls,
            child: const ColoredBox(
              color: Color(0x6600aa44),
              child: Center(child: Text('Keep this foreground')),
            ),
          );
        },
      ),
    );
    await tester.pumpWidget(
      _harness(
        child: ValueListenableBuilder<double>(
          valueListenable: alpha,
          child: retained,
          builder: (context, value, child) =>
              Opacity(opacity: value, child: child),
        ),
      ),
    );
    _compose(tester);
    expect(calls.last.$2, isTrue);

    alpha.value = 0.55;
    await tester.pump();
    _compose(tester);
    expect(calls.last.$2, isFalse);
    final filters = tester.layers.whereType<BackdropFilterLayer>().toList();
    expect(filters.first.filter.toString(), contains('5.0'));
    expect(_engineLayer(filters.last), isNull);
    expect(find.text('Keep this foreground'), findsOneWidget);

    alpha.value = 1;
    await tester.pump();
    _compose(tester);
    expect(calls.last.$2, isTrue);
    expect(
      _engineLayer(tester.layers.whereType<BackdropFilterLayer>().last),
      isNotNull,
    );
    expect(builds, 1);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(
  List<(Rect, bool)> calls, {
  BackdropKey? backdropGroupKey,
  bool Function()? materialIsRefractive,
  Widget child = const SizedBox.expand(),
}) => LiquidGlassSurface.debugBackdropLayerHost(
  devicePixelRatio: 1,
  viewportSize: const Size(800, 600),
  blurFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
  backdropGroupKey: backdropGroupKey,
  materialIsRefractive: materialIsRefractive,
  child: child,
  resolveMaterial: (bounds, bounded) {
    calls.add((bounds, bounded));
    return ui.ImageFilter.blur(
      sigmaX: bounded ? 2 : 5,
      sigmaY: bounded ? 2 : 5,
    );
  },
);

Widget _harness({required Widget child}) => Directionality(
  textDirection: TextDirection.ltr,
  child: ColoredBox(
    color: Colors.blue,
    child: Center(child: SizedBox(width: 120, height: 60, child: child)),
  ),
);

void _compose(WidgetTester tester) {
  // Build the retained layer tree explicitly too. This ensures geometry is
  // resolved when an ancestor transform changes without repainting the lens.
  final root = tester.layers.first;
  final builder = ui.SceneBuilder();
  // Match ContainerLayer.buildScene: propagate always-needs-scene descendants
  // before adding retained ancestors, including when no widget rebuilt.
  // ignore: invalid_use_of_protected_member
  root.updateSubtreeNeedsAddToScene();
  // Intentional compositor invocation: normal widget pumping may retain the
  // boundary, while this regression specifically exercises its layer tree.
  // ignore: invalid_use_of_protected_member
  root.addToScene(builder);
  builder.build().dispose();
}

ui.EngineLayer? _engineLayer(Layer layer) {
  // Inspect whether a native filter was actually submitted, not merely whether
  // its reusable Dart wrapper is retained in the layer tree.
  // ignore: invalid_use_of_protected_member
  return layer.engineLayer;
}
