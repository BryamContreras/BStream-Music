import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('expanded artwork fade specifications', () {
    test('keep the artwork visible through the intended lower stops', () {
      _expectFadeGradient(
        expandedArtworkHeroEdgeFadeGradient,
        lastOpaqueStop: 0.66,
      );
      _expectFadeGradient(
        expandedArtworkHeroBlurFadeGradient,
        lastOpaqueStop: 0.70,
      );
      _expectFadeGradient(
        expandedArtworkHeroFocusFadeGradient,
        lastOpaqueStop: 0.68,
      );
      _expectFadeGradient(
        expandedArtworkBoundedEdgeFadeGradient,
        lastOpaqueStop: 0.84,
      );
      _expectFadeGradient(
        expandedArtworkBoundedFocusFadeGradient,
        lastOpaqueStop: 0.68,
      );
    });

    test('starts the bounded tone blend at the intended lower stop', () {
      expect(expandedArtworkBoundedToneFadeStops, const [0, 0.74, 1]);
      _expectStrictlyIncreasing(expandedArtworkBoundedToneFadeStops);
    });
  });
}

void _expectFadeGradient(
  LinearGradient gradient, {
  required double lastOpaqueStop,
}) {
  final stops = gradient.stops;
  expect(stops, isNotNull);
  expect(stops, hasLength(gradient.colors.length));
  _expectStrictlyIncreasing(stops!);

  final lastWhiteIndex = gradient.colors.lastIndexOf(Colors.white);
  expect(lastWhiteIndex, greaterThanOrEqualTo(0));
  expect(stops[lastWhiteIndex], lastOpaqueStop);

  for (
    var index = lastWhiteIndex + 1;
    index < gradient.colors.length;
    index++
  ) {
    expect(
      gradient.colors[index].a,
      lessThanOrEqualTo(gradient.colors[index - 1].a),
      reason: 'Alpha must not increase after the last fully opaque stop.',
    );
  }
  expect(gradient.colors.last.a, 0);
}

void _expectStrictlyIncreasing(List<double> stops) {
  for (var index = 1; index < stops.length; index++) {
    expect(
      stops[index],
      greaterThan(stops[index - 1]),
      reason: 'Gradient stops must be strictly increasing.',
    );
  }
}
