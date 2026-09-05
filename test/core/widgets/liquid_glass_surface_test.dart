import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;
import 'dart:ui' as ui;

import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'static surface uses a continuous clip with neutral bounded optics',
    (tester) async {
      await tester.pumpWidget(_harness(child: const Text('Contenido')));

      final surface = find.byType(LiquidGlassSurface);
      final backdrop = find.descendant(
        of: surface,
        matching: find.byKey(LiquidGlassSurface.backdropKey),
      );

      expect(find.byType(ClipRRect), findsOneWidget);
      expect(backdrop, findsOneWidget);
      expect(
        find.descendant(
          of: surface,
          matching: find.byKey(LiquidGlassSurface.opticsKey),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: surface,
          matching: find.byKey(LiquidGlassSurface.adaptiveEdgeKey),
        ),
        findsNothing,
        reason:
            'Refraction must be composed into the material filter instead of '
            'capturing the backdrop through a second edge layer.',
      );
      expect(
        find.descendant(
          of: surface,
          matching: find.byKey(LiquidGlassSurface.shadowKey),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: surface,
          matching: find.byKey(LiquidGlassHoverTarget.effectKey),
        ),
        findsNothing,
      );
      expect(find.byType(LiquidGlassHoverTarget), findsNothing);
      expect(find.byType(BackdropFilter), findsOneWidget);
      final materialFilter = tester.widget<BackdropFilter>(backdrop);
      expect(materialFilter.enabled, isTrue);
      expect(materialFilter.filter.toString(), contains('blur(22.0, 22.0'));
      expect(materialFilter.filter.toString(), contains('clamp'));
      expect(
        find.ancestor(of: backdrop, matching: find.byType(ClipRRect)),
        findsOneWidget,
      );

      final shadowLayer = tester.widget<CustomPaint>(
        find.byKey(LiquidGlassSurface.shadowKey),
      );
      expect(
        shadowLayer.child,
        isA<ClipRRect>(),
        reason:
            'Exterior depth must wrap the continuously clipped sheet instead '
            'of darkening the translucent center.',
      );
      final materialStack = tester.widget<Stack>(
        find.descendant(of: surface, matching: find.byType(Stack)).first,
      );
      expect(materialStack.children, hasLength(4));
      expect(
        (materialStack.children[1] as Positioned).child.key,
        LiquidGlassSurface.surfaceTintKey,
        reason: 'The neutral tint must remain directly above the backdrop.',
      );
      expect(materialStack.children[2], isA<RepaintBoundary>());
      expect(
        materialStack.children.last,
        isA<Positioned>(),
        reason: 'Perimeter optics must remain above content and tint.',
      );

      final tint = tester.widget<DecoratedBox>(
        find.byKey(LiquidGlassSurface.surfaceTintKey),
      );
      final tintColor = (tint.decoration as BoxDecoration).color!;
      expect(
        tintColor.r == tintColor.g && tintColor.g == tintColor.b,
        isTrue,
        reason: 'The glass sheet must not carry an application tint.',
      );
      expect(find.text('Contenido'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('edge preference never creates a second backdrop capture', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(adaptiveEdgeEnabled: true, child: const SizedBox.expand()),
    );

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);

    await tester.pumpWidget(
      _harness(adaptiveEdgeEnabled: false, child: const SizedBox.expand()),
    );

    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
  });

  testWidgets('perimeter optics keeps a colour-preserving convex face', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(child: const SizedBox.expand()));

    final paints = _paintOptics(tester);
    expect(paints, hasLength(3));

    final face = paints[0];
    expect(face.style, PaintingStyle.fill);
    expect(face.blendMode, BlendMode.softLight);
    expect(face.shader, isNotNull);

    final outerRim = paints[1];
    expect(outerRim.style, PaintingStyle.stroke);
    expect(outerRim.strokeWidth, closeTo(0.9, 0.000001));
    expect(outerRim.blendMode, BlendMode.softLight);
    expect(outerRim.maskFilter, isNull);
    expect(outerRim.shader, isNotNull);

    final innerRim = paints[2];
    expect(innerRim.style, PaintingStyle.stroke);
    expect(innerRim.strokeWidth, closeTo(0.8, 0.000001));
    expect(innerRim.blendMode, BlendMode.softLight);
    expect(innerRim.maskFilter, isNull);
    expect(innerRim.shader, isNotNull);
  });

  testWidgets('android perimeter optics avoids unstable soft-light blending', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        child: const SizedBox.expand(),
      ),
    );

    final paints = _paintOptics(tester);
    expect(paints, hasLength(3));
    expect(paints[0].blendMode, BlendMode.srcOver);
    expect(paints[1].blendMode, BlendMode.srcOver);
    expect(paints[2].blendMode, BlendMode.srcOver);
  });

  testWidgets('adaptive tint calms both light and dark backdrops', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        brightness: Brightness.light,
        child: const Text('Contenido claro'),
      ),
    );
    await tester.pumpAndSettle();

    final lightTint = _surfaceTintDecoration(tester).color!;
    expect(lightTint, const Color(0xFFFAFAFA).withValues(alpha: 0.4));
    expect(
      find.byKey(LiquidGlassSurface.surfaceTintKey),
      findsOneWidget,
      reason: 'One tint must cover the blur and the refractive edge.',
    );

    await tester.pumpWidget(
      _harness(
        brightness: Brightness.dark,
        child: const Text('Contenido oscuro'),
      ),
    );
    await tester.pumpAndSettle();

    final darkTint = _surfaceTintDecoration(tester).color!;
    expect(darkTint, const Color(0xFF121212).withValues(alpha: 0.4));
  });

  testWidgets('dark hover droplet preserves backdrop chroma at full reveal', (
    tester,
  ) async {
    await tester.pumpWidget(
      _hoverHarness(
        brightness: Brightness.dark,
        disableAnimations: true,
        child: const SizedBox.expand(),
      ),
    );

    final target = find.byType(LiquidGlassHoverTarget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();

    final painter = _hoverPainter(tester);
    expect(painter.visibility, 1);
    expect(painter.debugShadowColor, Colors.black.withValues(alpha: 0.1));
    expect(painter.debugFillGradientColors, <Color>[
      Colors.white.withValues(alpha: 0.028),
      Colors.transparent,
      Colors.black.withValues(alpha: 0.065),
    ]);
    expect(painter.debugRimGradientColors, <Color>[
      Colors.white.withValues(alpha: 0.22),
      Colors.white.withValues(alpha: 0.035),
      Colors.white.withValues(alpha: 0.13),
    ]);
    expect(painter.debugInnerRimColor, Colors.black.withValues(alpha: 0.1));
    final strongestWhiteFillAlpha = painter.debugFillGradientColors
        .where((color) => color.r == 1 && color.g == 1 && color.b == 1)
        .map((color) => color.a)
        .fold<double>(0, math.max);
    expect(
      strongestWhiteFillAlpha,
      lessThan(0.03),
      reason:
          'The convex hover may shade the material, but its light-facing fill '
          'must not wash away the local backdrop chroma.',
    );
  });

  testWidgets(
    'hover droplet keeps a four-layer convex treatment without recapturing',
    (tester) async {
      await tester.pumpWidget(
        _hoverHarness(
          brightness: Brightness.dark,
          disableAnimations: true,
          child: const SizedBox.expand(),
        ),
      );

      final target = find.byType(LiquidGlassHoverTarget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump();

      expect(
        find.descendant(of: target, matching: find.byType(BackdropFilter)),
        findsNothing,
        reason:
            'Hover depth must shade the parent glass instead of sampling it '
            'through a second blur.',
      );
      final paints = _paintHover(tester);
      expect(paints, hasLength(4));

      expect(paints[0].style, PaintingStyle.fill);
      expect(
        paints[0].maskFilter.toString(),
        contains('MaskFilter.blur(BlurStyle.outer, 4.2)'),
      );
      expect(paints[0].shader, isNull);

      expect(paints[1].style, PaintingStyle.fill);
      expect(paints[1].shader, isNotNull);
      expect(paints[1].maskFilter, isNull);

      expect(paints[2].style, PaintingStyle.stroke);
      expect(paints[2].strokeWidth, closeTo(0.85, 0.000001));
      expect(paints[2].blendMode, BlendMode.softLight);
      expect(paints[2].shader, isNotNull);

      expect(paints[3].style, PaintingStyle.stroke);
      expect(paints[3].strokeWidth, closeTo(0.7, 0.000001));
      expect(paints[3].shader, isNull);
      expect(paints[3].color.a, closeTo(0.1, 0.000001));
      expect(paints[3].color.r, 0);
      expect(paints[3].color.g, 0);
      expect(paints[3].color.b, 0);
    },
  );

  testWidgets('dark optical tuning leaves the light hover palette unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      _hoverHarness(
        brightness: Brightness.light,
        disableAnimations: true,
        child: const SizedBox.expand(),
      ),
    );

    final target = find.byType(LiquidGlassHoverTarget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();

    final painter = _hoverPainter(tester);
    expect(painter.debugShadowColor, Colors.black.withValues(alpha: 0.075));
    expect(painter.debugFillGradientColors, <Color>[
      Colors.white.withValues(alpha: 0.11),
      Colors.transparent,
      Colors.black.withValues(alpha: 0.045),
    ]);
    expect(painter.debugRimGradientColors, <Color>[
      Colors.white.withValues(alpha: 0.28),
      Colors.white.withValues(alpha: 0.05),
      Colors.white.withValues(alpha: 0.16),
    ]);
    expect(painter.debugInnerRimColor, Colors.black.withValues(alpha: 0.065));
  });

  testWidgets(
    'soft shadow stays outside and does not darken the glass center',
    (tester) async {
      await tester.pumpWidget(
        _harness(brightness: Brightness.light, child: const SizedBox.expand()),
      );

      final lightShadowPaints = _paintShadow(tester);
      expect(lightShadowPaints, hasLength(2));
      expect(
        lightShadowPaints.map((paint) => paint.maskFilter?.toString()),
        containsAll([
          ui.MaskFilter.blur(ui.BlurStyle.outer, 14).toString(),
          ui.MaskFilter.blur(ui.BlurStyle.outer, 3.4).toString(),
        ]),
        reason:
            'Both the reflected halo and drop shadow must stay outside the '
            'translucent center.',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        _harness(brightness: Brightness.dark, child: const SizedBox.expand()),
      );

      final darkShadowPaints = _paintShadow(tester);
      expect(darkShadowPaints, hasLength(2));
      expect(
        darkShadowPaints.map((paint) => paint.maskFilter?.toString()),
        containsAll([
          ui.MaskFilter.blur(ui.BlurStyle.outer, 14).toString(),
          ui.MaskFilter.blur(ui.BlurStyle.outer, 3.4).toString(),
        ]),
        reason: 'Dark glass must not gain an interior fill from either halo.',
      );
    },
  );

  testWidgets('zero sigma keeps the neutral optics without a backdrop filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(blurSigma: 0, child: const Center(child: Text('Control'))),
    );

    expect(find.byKey(LiquidGlassSurface.backdropKey), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
    expect(find.byKey(LiquidGlassSurface.opticsKey), findsOneWidget);
    expect(find.byKey(LiquidGlassSurface.shadowKey), findsOneWidget);
    expect(find.text('Control'), findsOneWidget);
  });

  testWidgets('supports an edge-to-edge surface with square outer bounds', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(borderRadius: BorderRadius.zero, child: const SizedBox.expand()),
    );

    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
    expect(clip.borderRadius, BorderRadius.zero);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edge-to-edge chrome can omit only its boxed perimeter layers', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        borderRadius: BorderRadius.zero,
        perimeterOpticsEnabled: false,
        child: const Text('Encabezado'),
      ),
    );

    expect(find.byKey(LiquidGlassSurface.backdropKey), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
    expect(find.byKey(LiquidGlassSurface.opticsKey), findsNothing);
    expect(find.byKey(LiquidGlassSurface.shadowKey), findsNothing);
    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
    expect(clip.borderRadius, BorderRadius.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bottom edge treatment uses the same single material capture', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        borderRadius: BorderRadius.zero,
        edgeTreatment: LiquidGlassEdgeTreatment.bottom,
        child: const Text('Encabezado integrado'),
      ),
    );

    final surface = find.byType(LiquidGlassSurface);
    final backdrop = find.descendant(
      of: surface,
      matching: find.byKey(LiquidGlassSurface.backdropKey),
    );
    expect(backdrop, findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
    expect(
      find.descendant(
        of: surface,
        matching: find.byKey(LiquidGlassSurface.opticsKey),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: surface,
        matching: find.byKey(LiquidGlassSurface.shadowKey),
      ),
      findsNothing,
      reason: 'Integrated chrome must not cast a floating rectangular shadow.',
    );

    final materialFilter = tester.widget<BackdropFilter>(backdrop);
    expect(materialFilter.enabled, isTrue);
    expect(materialFilter.filter.toString(), contains('blur('));
    expect(materialFilter.filter.toString(), contains('clamp'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'single native material filter refreshes only when its inputs change',
    (tester) async {
      await tester.pumpWidget(
        _harness(blurSigma: 22, child: const Text('Primero')),
      );

      final initialMaterial = tester
          .widget<BackdropFilter>(find.byKey(LiquidGlassSurface.backdropKey))
          .filter;

      await tester.pumpWidget(
        _harness(blurSigma: 22, child: const Text('Segundo')),
      );

      expect(
        identical(
          tester
              .widget<BackdropFilter>(
                find.byKey(LiquidGlassSurface.backdropKey),
              )
              .filter,
          initialMaterial,
        ),
        isTrue,
        reason:
            'A child or parent rebuild must not recreate the material filter.',
      );

      await tester.pumpWidget(
        _harness(blurSigma: 18, child: const Text('Nuevo sigma')),
      );
      final resizedMaterial = tester
          .widget<BackdropFilter>(find.byKey(LiquidGlassSurface.backdropKey))
          .filter;
      expect(identical(resizedMaterial, initialMaterial), isFalse);

      await tester.pumpWidget(
        _harness(
          blurSigma: 18,
          backdropMotion: true,
          child: const Text('Material en movimiento'),
        ),
      );
      final movingMaterial = tester.widget<BackdropFilter>(
        find.byKey(LiquidGlassSurface.backdropKey),
      );
      expect(movingMaterial.enabled, isTrue);
      expect(identical(movingMaterial.filter, resizedMaterial), isTrue);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
    },
  );

  testWidgets('single capture carries the supplied group key when safe', (
    tester,
  ) async {
    final sharedBackdrop = BackdropKey();
    await tester.pumpWidget(
      _harness(
        backdropGroupKey: sharedBackdrop,
        child: const Text('Vidrio agrupado'),
      ),
    );

    final material = tester.widget<BackdropFilter>(
      find.byKey(LiquidGlassSurface.backdropKey),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(material.backdropGroupKey, same(sharedBackdrop));
    expect(material.enabled, isTrue);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
  });

  testWidgets('android retains its shared capture throughout motion', (
    tester,
  ) async {
    final sharedBackdrop = BackdropKey();
    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        backdropGroupKey: sharedBackdrop,
        child: const Text('Android'),
      ),
    );

    final restingMaterial = tester.widget<BackdropFilter>(
      find.byKey(LiquidGlassSurface.backdropKey),
    );
    final restingFilter = restingMaterial.filter;
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(restingMaterial.backdropGroupKey, same(sharedBackdrop));
    expect(restingMaterial.enabled, isTrue);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);

    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        backdropGroupKey: sharedBackdrop,
        backdropMotion: true,
        child: const Text('Android con bounds móviles'),
      ),
    );
    final movingMaterial = tester.widget<BackdropFilter>(
      find.byKey(LiquidGlassSurface.backdropKey),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(movingMaterial.backdropGroupKey, same(sharedBackdrop));
    expect(movingMaterial.enabled, isTrue);
    expect(identical(movingMaterial.filter, restingFilter), isTrue);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);

    await tester.pumpWidget(
      _harness(
        platform: TargetPlatform.android,
        backdropGroupKey: sharedBackdrop,
        child: const Text('Android otra vez en reposo'),
      ),
    );
    final settledMaterial = tester.widget<BackdropFilter>(
      find.byKey(LiquidGlassSurface.backdropKey),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(settledMaterial.backdropGroupKey, same(sharedBackdrop));
    expect(settledMaterial.enabled, isTrue);
    expect(identical(settledMaterial.filter, restingFilter), isTrue);
  });

  testWidgets(
    'grouped sheets reuse one native blur without separate rim captures',
    (tester) async {
      final sharedBackdrop = BackdropKey();
      await tester.pumpWidget(
        _baseHarness(
          platform: TargetPlatform.windows,
          child: Row(
            children: [
              Expanded(
                child: LiquidGlassSurface(
                  blurSigma: 12,
                  backdropGroupKey: sharedBackdrop,
                  child: const Text('Mini reproductor'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LiquidGlassSurface(
                  blurSigma: 12,
                  backdropGroupKey: sharedBackdrop,
                  child: const Text('Navegación'),
                ),
              ),
            ],
          ),
        ),
      );

      final groupedBlurs = tester
          .widgetList<BackdropFilter>(
            find.byKey(LiquidGlassSurface.backdropKey),
          )
          .toList(growable: false);
      expect(groupedBlurs, hasLength(2));
      expect(
        identical(groupedBlurs.first.filter, groupedBlurs.last.filter),
        isTrue,
        reason:
            'Equal grouped sheets should submit the same immutable filter to '
            'the engine instead of allocating one native blur per sheet.',
      );
      expect(find.byType(BackdropFilter), findsNWidgets(2));
      expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
    },
  );

  testWidgets('motion preserves the active single material filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(adaptiveEdgeEnabled: true, child: const Text('En reposo')),
    );
    final restingFilter = tester
        .widget<BackdropFilter>(find.byKey(LiquidGlassSurface.backdropKey))
        .filter;

    await tester.pumpWidget(
      _harness(backdropMotion: true, child: const Text('En movimiento')),
    );
    final movingMaterial = tester.widget<BackdropFilter>(
      find.byKey(LiquidGlassSurface.backdropKey),
    );
    expect(movingMaterial.enabled, isTrue);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(identical(movingMaterial.filter, restingFilter), isTrue);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);

    await tester.pumpWidget(_harness(child: const Text('Otra vez en reposo')));
    expect(
      identical(
        tester
            .widget<BackdropFilter>(find.byKey(LiquidGlassSurface.backdropKey))
            .filter,
        restingFilter,
      ),
      isTrue,
      reason: 'Settling must retain the same native material filter.',
    );
  });

  testWidgets('mouse hover reveals a local pill without rebuilding its child', (
    tester,
  ) async {
    var childBuilds = 0;
    var childPaints = 0;
    await tester.pumpWidget(
      _hoverHarness(
        child: _BuildCounter(
          onBuild: () => childBuilds += 1,
          child: CustomPaint(
            painter: _PaintCounter(onPaint: () => childPaints += 1),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    expect(childBuilds, 1);
    expect(childPaints, 1);
    expect(
      find.byKey(LiquidGlassHoverTarget.effectKey),
      findsNothing,
      reason: 'Idle touch-first chrome must not materialize a hover layer.',
    );

    final target = find.byType(LiquidGlassHoverTarget);
    final rect = tester.getRect(target);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(rect.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 280));

    var painter = _hoverPainter(tester);
    expect(painter.pointerKind, PointerDeviceKind.mouse);
    expect(painter.isHovered, isTrue);
    expect(painter.animationStatus, AnimationStatus.completed);
    expect(painter.visibility, 1);
    expect(childBuilds, 1);
    expect(
      childPaints,
      2,
      reason:
          'Materializing the isolated hover layer may paint the retained '
          'child once, but animation ticks must not repaint it.',
    );

    await mouse.moveTo(rect.bottomRight + const Offset(20, 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 340));
    painter = _hoverPainter(tester);
    expect(painter.isHovered, isFalse);
    expect(painter.visibility, 0);
    expect(childBuilds, 1);
    expect(childPaints, 2);
  });

  testWidgets('touch press and tap never activate the hover pill', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _hoverHarness(
        disableAnimations: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps += 1,
          child: const SizedBox.expand(),
        ),
      ),
    );
    expect(find.byKey(LiquidGlassHoverTarget.effectKey), findsNothing);

    final rect = tester.getRect(find.byType(LiquidGlassHoverTarget));
    final touch = await tester.startGesture(
      rect.center,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();

    expect(find.byKey(LiquidGlassHoverTarget.effectKey), findsNothing);

    await touch.moveTo(rect.center + const Offset(18, -12));
    await tester.pump();
    expect(find.byKey(LiquidGlassHoverTarget.effectKey), findsNothing);

    await touch.up();
    await tester.pump();
    expect(taps, 0, reason: 'The drag intentionally exceeded touch slop.');
    expect(find.byKey(LiquidGlassHoverTarget.effectKey), findsNothing);

    await tester.tap(find.byType(LiquidGlassHoverTarget));
    await tester.pump();
    expect(taps, 1);
    expect(find.byKey(LiquidGlassHoverTarget.effectKey), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion reveals mouse hover immediately', (tester) async {
    await tester.pumpWidget(
      _hoverHarness(disableAnimations: true, child: const SizedBox.expand()),
    );

    final target = find.byType(LiquidGlassHoverTarget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();

    expect(_hoverPainter(tester).visibility, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('hover observation does not consume child gestures', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _hoverHarness(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps += 1,
          child: const Center(child: Text('Tocar')),
        ),
      ),
    );

    await tester.tap(find.text('Tocar'));
    await tester.pumpAndSettle();

    expect(taps, 1);
    expect(find.byKey(LiquidGlassHoverTarget.effectKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final platform in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    testWidgets('renders with Flutter primitives on ${platform.name}', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          platform: platform,
          child: const Center(child: Text('Glass')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LiquidGlassSurface), findsOneWidget);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
      expect(find.byType(ClipRRect), findsOneWidget);
      expect(find.byKey(LiquidGlassSurface.shadowKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

LiquidGlassHoverPainter _hoverPainter(WidgetTester tester) {
  return tester
          .widget<CustomPaint>(find.byKey(LiquidGlassHoverTarget.effectKey))
          .painter!
      as LiquidGlassHoverPainter;
}

BoxDecoration _surfaceTintDecoration(WidgetTester tester) {
  return tester
          .widget<DecoratedBox>(find.byKey(LiquidGlassSurface.surfaceTintKey))
          .decoration
      as BoxDecoration;
}

List<ui.Paint> _paintShadow(WidgetTester tester) {
  final shadowPaint = tester.widget<CustomPaint>(
    find.byKey(LiquidGlassSurface.shadowKey),
  );
  final recorder = _RRectPaintRecordingCanvas();
  shadowPaint.painter!.paint(
    recorder,
    tester.getSize(find.byKey(LiquidGlassSurface.shadowKey)),
  );
  expect(
    recorder.superellipsePaints.every(
      (paint) => paint.style == PaintingStyle.fill,
    ),
    isTrue,
  );
  return recorder.superellipsePaints;
}

List<ui.Paint> _paintOptics(WidgetTester tester) {
  final opticsPaint = tester.widget<CustomPaint>(
    find.byKey(LiquidGlassSurface.opticsKey),
  );
  final recorder = _RRectPaintRecordingCanvas();
  opticsPaint.painter!.paint(
    recorder,
    tester.getSize(find.byKey(LiquidGlassSurface.opticsKey)),
  );
  return recorder.superellipsePaints;
}

List<ui.Paint> _paintHover(WidgetTester tester) {
  final hoverPaint = tester.widget<CustomPaint>(
    find.byKey(LiquidGlassHoverTarget.effectKey),
  );
  final recorder = _RRectPaintRecordingCanvas();
  hoverPaint.painter!.paint(
    recorder,
    tester.getSize(find.byKey(LiquidGlassHoverTarget.effectKey)),
  );
  return recorder.superellipsePaints;
}

class _RRectPaintRecordingCanvas implements ui.Canvas {
  final List<ui.Paint> superellipsePaints = <ui.Paint>[];

  @override
  void drawRRect(ui.RRect rrect, ui.Paint paint) {
    superellipsePaints.add(paint);
  }

  @override
  void drawRSuperellipse(ui.RSuperellipse rsuperellipse, ui.Paint paint) {
    superellipsePaints.add(paint);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _harness({
  required Widget child,
  double blurSigma = 22,
  double intensity = 1,
  BackdropKey? backdropGroupKey,
  bool adaptiveEdgeEnabled = true,
  bool backdropMotion = false,
  bool perimeterOpticsEnabled = true,
  LiquidGlassEdgeTreatment edgeTreatment = LiquidGlassEdgeTreatment.perimeter,
  BorderRadiusGeometry borderRadius = const BorderRadius.all(
    Radius.circular(24),
  ),
  TargetPlatform platform = TargetPlatform.windows,
  Brightness brightness = Brightness.dark,
}) {
  return _baseHarness(
    platform: platform,
    brightness: brightness,
    child: LiquidGlassSurface(
      blurSigma: blurSigma,
      intensity: intensity,
      backdropGroupKey: backdropGroupKey,
      adaptiveEdgeEnabled: adaptiveEdgeEnabled,
      backdropMotion: backdropMotion,
      perimeterOpticsEnabled: perimeterOpticsEnabled,
      edgeTreatment: edgeTreatment,
      borderRadius: borderRadius,
      child: child,
    ),
  );
}

Widget _hoverHarness({
  required Widget child,
  bool disableAnimations = false,
  Brightness brightness = Brightness.dark,
}) {
  return _baseHarness(
    disableAnimations: disableAnimations,
    brightness: brightness,
    child: LiquidGlassHoverTarget(child: child),
  );
}

Widget _baseHarness({
  required Widget child,
  bool disableAnimations = false,
  TargetPlatform platform = TargetPlatform.android,
  Brightness brightness = Brightness.dark,
}) {
  return MaterialApp(
    theme: ThemeData(
      brightness: brightness,
      platform: platform,
      colorSchemeSeed: const Color(0xFF44A7FF),
    ),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(800, 600),
        disableAnimations: disableAnimations,
      ),
      child: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF083452), Color(0xFF611849)],
                  ),
                ),
              ),
            ),
            Center(child: SizedBox(width: 320, height: 120, child: child)),
          ],
        ),
      ),
    ),
  );
}

class _BuildCounter extends StatelessWidget {
  const _BuildCounter({required this.onBuild, required this.child});

  final VoidCallback onBuild;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return child;
  }
}

class _PaintCounter extends CustomPainter {
  const _PaintCounter({required this.onPaint});

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}
