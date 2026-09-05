import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('liquid glass lens localizes backdrop texture coordinates', () {
    final source = File(
      'shaders/liquid_glass_refraction.frag',
    ).readAsStringSync();

    expect(source, contains('vec2 coordinate = FlutterFragCoord().xy;'));
    expect(source, contains('uniform vec2 u_surface_origin_px;'));
    expect(
      source,
      contains('vec2 local_coordinate = coordinate - u_surface_origin_px;'),
    );
    expect(
      RegExp(
        r'^\s*vec2\s+local_coordinate\s*=\s*gl_FragCoord',
        multiLine: true,
      ).hasMatch(source),
      isFalse,
      reason: 'gl_FragCoord is screen-space under Impeller.',
    );
  });

  test('surface origin is resolved from its paint transform', () {
    final source = File(
      'lib/core/widgets/liquid_glass_surface.dart',
    ).readAsStringSync();

    expect(source, contains('renderObject.getTransformTo(null)'));
    expect(source, contains('filterConfig: positionAwareFilter'));
    expect(source, contains('..setFloat(4, surfaceOriginPx.dx)'));
    expect(source, contains('..setFloat(5, surfaceOriginPx.dy)'));
  });

  test('OpenGLES texture orientation remains version compatible', () {
    final source = File(
      'shaders/liquid_glass_refraction.frag',
    ).readAsStringSync();

    expect(
      source,
      contains(
        '#if defined(IMPELLER_TARGET_OPENGLES) && '
        '!defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)',
      ),
    );
  });

  test('refractive surfaces never reuse a grouped backdrop', () {
    final source = File(
      'lib/core/widgets/liquid_glass_surface.dart',
    ).readAsStringSync();

    expect(
      RegExp(
        r'final effectiveBackdropGroupKey = _usesRefraction\s*'
        r'\? null\s*:\s*widget\.backdropGroupKey;',
      ).hasMatch(source),
      isTrue,
      reason: 'Each runtime lens carries size- and shape-specific uniforms.',
    );
  });
}
