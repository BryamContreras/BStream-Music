import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('unsupported renderer retains native lens in $direction', (
      tester,
    ) async {
      // The widget-test renderer has no shader ImageFilter support. An opt-in
      // must leave its original native clip and full-sigma blur untouched.
      expect(ui.ImageFilter.isShaderFilterSupported, isFalse);
      final envelope = direction == TextDirection.ltr
          ? const Rect.fromLTWH(0, 0, 360, 64)
          : const Rect.fromLTWH(-120, 0, 360, 64);
      await tester.pumpWidget(_harness(envelope, direction: direction));

      final backdrop = find.byKey(LiquidGlassSurface.backdropKey);
      expect(tester.getSize(backdrop), const Size(240, 64));
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.byType(ClipRect), findsNothing);
      expect(
        find.ancestor(of: backdrop, matching: find.byType(ClipRRect)),
        findsOneWidget,
      );
      expect(
        tester.widget<BackdropFilter>(backdrop).filter.toString(),
        contains('blur(8.0, 8.0'),
      );
      expect(find.byKey(LiquidGlassSurface.shadowKey), findsOneWidget);
      expect(find.byKey(LiquidGlassSurface.opticsKey), findsOneWidget);
      expect(find.byKey(LiquidGlassSurface.surfaceTintKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('fallback preserves live lens layout during a morph', (
    tester,
  ) async {
    for (final width in [320.0, 280.0, 240.0, 200.0, 320.0]) {
      await tester.pumpWidget(
        _harness(const Rect.fromLTWH(0, 0, 360, 64), width: width),
      );
      await tester.pump(const Duration(milliseconds: 8));
      expect(
        tester.getSize(find.byKey(LiquidGlassSurface.backdropKey)),
        Size(width, 64),
      );
      expect(find.text('Controls'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('zero-sigma opt-in does not introduce a backdrop filter', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const Rect.fromLTWH(-60, 0, 360, 64), sigma: 0),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ClipRRect), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shell margins crop only the shadow, not the live backdrop', (
    tester,
  ) async {
    const insets = EdgeInsets.fromLTRB(8, 5, 8, 8);
    await tester.pumpWidget(
      _harness(const Rect.fromLTWH(-60, 0, 360, 64), shadowClipInsets: insets),
    );
    final shadowClip = find.ancestor(
      of: find.byKey(LiquidGlassSurface.shadowKey),
      matching: find.byType(ClipRect),
    );
    expect(shadowClip, findsOneWidget);
    final clip = tester.widget<ClipRect>(shadowClip);
    expect(clip.clipBehavior, Clip.hardEdge);
    expect(
      clip.clipper!.getClip(const Size(240, 64)),
      const Rect.fromLTRB(-8, -5, 248, 72),
    );
    expect(
      find.ancestor(
        of: find.byKey(LiquidGlassSurface.backdropKey),
        matching: find.byType(ClipRect),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'fixed envelope masks every shader output with premultiplied coverage',
    () {
      final shader = File(
        'shaders/liquid_glass_refraction.frag',
      ).readAsStringSync();
      expect(shader, contains('uniform float u_shape_mask;'));
      expect(shader, contains('clamp(0.5 - signed_distance, 0.0, 1.0)'));
      expect(
        shader,
        contains(
          'frag_color = sample_material(material_coordinate) * shape_coverage;',
        ),
      );
      expect(
        shader,
        contains('frag_color = clamp(color, 0.0, 1.0) * shape_coverage;'),
      );
      expect(shader, contains('if (shape_coverage <= 0.0)'));
      expect(shader, isNot(contains('color.a *= shape_coverage')));

      for (final density in [1.0, 1.5, 2.0, 3.0, 4.0]) {
        double coverage(double logicalDistance) =>
            (0.5 - logicalDistance * density).clamp(0, 1);
        expect(coverage(-0.5 / density), 1);
        expect(coverage(0), 0.5);
        expect(coverage(0.5 / density), 0);
      }
    },
  );

  test('envelope preflights shader and restores native clip on failure', () {
    final source = File(
      'lib/core/widgets/liquid_glass_surface.dart',
    ).readAsStringSync();
    expect(source, contains('shader.setFloat(17, 1);'));
    expect(source, contains('ui.ImageFilter.shader(shader);'));
    expect(
      source,
      contains('..setFloat(17, widget.lensBounds == null ? 0 : 1)'),
    );
    expect(source, contains('constraints.isTight'));
    expect(source, contains('MatrixUtils.getAsTranslation(transform) == null'));
    expect(
      source,
      contains(
        'return const ui.ColorFilter.mode(Color(0x00000000), BlendMode.src);',
      ),
    );
    expect(source, contains('widget.onEnvelopeFailure?.call();'));
    expect(source, contains('WidgetsBinding.instance.addPostFrameCallback'));
    expect(
      source,
      contains('widget.lensBounds ?? (Offset.zero & renderObject.size)'),
    );
  });
}

Widget _harness(
  Rect envelope, {
  TextDirection direction = TextDirection.ltr,
  double width = 240,
  double sigma = 8,
  EdgeInsets? shadowClipInsets,
}) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.android),
  home: Directionality(
    textDirection: direction,
    child: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: 64,
          child: LiquidGlassSurface(
            backdropEnvelope: envelope,
            shadowClipInsets: shadowClipInsets,
            blurSigma: sigma,
            borderRadius: BorderRadius.circular(32),
            backdropMotion: true,
            child: const Center(child: Text('Controls')),
          ),
        ),
      ),
    ),
  ),
);
