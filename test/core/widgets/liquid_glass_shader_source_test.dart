import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scrolling never substitutes reduced blur or disables the lens', () {
    final source = File(
      'lib/core/widgets/liquid_glass_surface.dart',
    ).readAsStringSync();
    final start = source.indexOf('final backdrop = _LiquidGlassBackdrop(');
    final sheet = source.substring(
      start,
      source.indexOf('return RepaintBoundary', start),
    );
    expect(sheet, contains('blurSigma: blurSigma,'));
    expect(
      sheet,
      contains('refractionEnabled: hasOpticalEdge && adaptiveEdgeEnabled,'),
    );
    expect(source, isNot(contains('motionBlurSigma')));
    expect(source, isNot(contains('refractionEnabledDuringMotion')));
  });

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

  test('calm lens pixels skip edge normal calculations', () {
    final source = File(
      'shaders/liquid_glass_refraction.frag',
    ).readAsStringSync();
    final main = source.substring(source.indexOf('void main()'));
    final calmReturn = main.indexOf('return;');
    final normalCalculation = main.indexOf(
      'shape_normal = rounded_rect_normal(',
    );

    expect(calmReturn, greaterThanOrEqualTo(0));
    expect(normalCalculation, greaterThan(calmReturn));
  });

  test('zero dispersion keeps one sample and spectral mode keeps seven', () {
    final source = File(
      'shaders/liquid_glass_refraction.frag',
    ).readAsStringSync();
    final main = source.substring(source.indexOf('void main()'));
    final refractedSample = main.indexOf('vec4 green = sample_material(');
    final spectralStart = main.indexOf('if (u_chromatic_aberration > 0.0)');
    final spectralEnd = main.indexOf('// Build the bevel');

    expect(refractedSample, greaterThan(0));
    expect(spectralStart, greaterThan(refractedSample));
    expect(spectralEnd, greaterThan(spectralStart));
    expect(main.substring(0, spectralStart), contains('vec4 color = green;'));
    expect(
      RegExp(
        r'sample_material\(',
      ).allMatches(main.substring(refractedSample, spectralStart)),
      hasLength(1),
    );
    expect(
      RegExp(
        r'sample_material\(',
      ).allMatches(main.substring(spectralStart, spectralEnd)),
      hasLength(6),
    );
    // With coincident taps the original weights preserve every channel.
    expect(3 / 3.5 + 1 / 7, closeTo(1, 1e-12));
    expect(1 / 7 + 3 / 3.5, closeTo(1, 1e-12));
    expect(3 / 3, 1);
    expect(7 / 7, 1);
  });

  test('non-overlapping siblings share capture without a second lens', () {
    final source = File(
      'lib/core/widgets/liquid_glass_surface.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('final effectiveBackdropGroupKey = widget.backdropGroupKey;'),
    );
    final shader = File(
      'shaders/liquid_glass_refraction.frag',
    ).readAsStringSync();
    expect(shader, isNot(contains('u_secondary_')));
    expect(shader, isNot(contains('u_lens_count')));
  });

  test(
    'discarded exterior skips the lens but retains the complete visible rim',
    () {
      final source = File(
        'shaders/liquid_glass_refraction.frag',
      ).readAsStringSync();
      final main = source.substring(source.indexOf('void main()'));
      final exteriorGuard = main.indexOf('const float clip_gutter = 2.0;');
      final opticalStart = main.indexOf('vec2 half_size = surface_size * 0.5;');
      expect(exteriorGuard, greaterThan(0));
      expect(opticalStart, greaterThan(exteriorGuard));
      final guard = main.substring(exteriorGuard, opticalStart);
      expect(guard, contains('lessThan(local_coordinate, vec2(-clip_gutter))'));
      expect(
        guard,
        contains(
          'greaterThan(local_coordinate, surface_size + vec2(clip_gutter))',
        ),
      );
      expect(guard, contains('frag_color = vec4(0.0);'));
      expect(guard, contains('return;'));
      expect(source, contains('u_chromatic_aberration'));
      expect(
        source,
        contains('vec4 purple = sample_material(refracted - dispersed);'),
      );
    },
  );

  test('rounded-rectangle SDF computes length only at rounded corners', () {
    final source = File(
      'shaders/liquid_glass_refraction.frag',
    ).readAsStringSync();
    final start = source.indexOf('float rounded_rect_distance(');
    final sdf = source.substring(start, source.indexOf('vec2 safe_normalize'));
    expect(sdf, contains('if (corner.x > 0.0 && corner.y > 0.0)'));
    expect(sdf, contains('return length(corner) - radius;'));
    expect(sdf, contains('return max(corner.x, corner.y) - radius;'));
    expect(source, contains('radius_for(centered, minimum_size)'));
    expect(
      source,
      contains(
        'float distance_amount = -circle_map(lens_progress) * refraction_amount;',
      ),
    );
  });

  test(
    'piecewise SDF equals the original over sides, corners and zero axes',
    () {
      // For two positive components the interior term is zero. Otherwise the
      // positive-part vector has at most one nonzero component, so its length
      // plus min(max(x,y),0) is exactly max(x,y), including either zero axis.
      const boundaries = <double>[
        -1024,
        -64,
        -1,
        -0.000001,
        -0.0,
        0.0,
        0.000001,
        1,
        64,
        1024,
      ];
      const radii = <double>[0, 0.5, 1, 12, 32.5, 64, 200];
      var checks = 0;
      void verify(double x, double y, double radius) {
        final original = _originalCornerDistance(x, y, radius);
        final optimized = _piecewiseCornerDistance(x, y, radius);
        final tolerance = 1e-12 * math.max(1, original.abs());
        if ((optimized - original).abs() > tolerance) {
          fail(
            'SDF differs at corner ($x, $y), radius $radius: '
            '$optimized instead of $original.',
          );
        }
        checks++;
      }

      for (final radius in radii) {
        for (final x in boundaries) {
          for (final y in boundaries) {
            verify(x, y, radius);
          }
        }
        // Explicit equality checks cover the branch boundaries without allowing
        // a floating-point tolerance to hide a changed sign or radius offset.
        expect(_piecewiseCornerDistance(0, 0, radius), -radius);
        expect(_piecewiseCornerDistance(0, 4, radius), 4 - radius);
        expect(_piecewiseCornerDistance(4, 0, radius), 4 - radius);
        expect(_piecewiseCornerDistance(0, -4, radius), -radius);
        expect(_piecewiseCornerDistance(-4, 0, radius), -radius);
      }

      final random = math.Random(0xB57EAD);
      for (var sample = 0; sample < 40000; sample++) {
        verify(
          (random.nextDouble() - 0.5) * 2048,
          (random.nextDouble() - 0.5) * 2048,
          random.nextDouble() * 200,
        );
      }
      expect(checks, 40700);
    },
  );
}

double _originalCornerDistance(double x, double y, double radius) {
  final positiveX = math.max(x, 0.0);
  final positiveY = math.max(y, 0.0);
  final outside = math.sqrt(positiveX * positiveX + positiveY * positiveY);
  final inside = math.min(math.max(x, y), 0.0);
  return outside - radius + inside;
}

double _piecewiseCornerDistance(double x, double y, double radius) {
  if (x > 0 && y > 0) return math.sqrt(x * x + y * y) - radius;
  return math.max(x, y) - radius;
}
