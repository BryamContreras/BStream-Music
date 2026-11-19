import 'dart:math' as math;

/// Shared by the app settings and the PCM bridge, without loading a player.
const bstreamEqualizerFrequencies = <double>[
  31,
  62,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

List<double>? _lastGains;
double _lastPreamp = 0;

/// Reserve headroom for overlapping Q=1 boosts. Cuts are ignored, so they
/// cannot reduce the margin. Native Java/C use the same control-rate formula.
/// This is a conservative response estimate, not a sample peak limiter.
double bstreamEqualizerPreampDb(List<double> gains) {
  final previous = _lastGains;
  if (previous != null && previous.length == gains.length) {
    var same = true;
    for (var i = 0; i < gains.length; i++) {
      if (previous[i] != gains[i]) {
        same = false;
        break;
      }
    }
    if (same) return _lastPreamp;
  }
  var positiveCount = 0;
  var total = 0.0;
  final amplitudes = <double>[];
  for (final gain in gains) {
    if (gain >= .01) {
      positiveCount++;
      total += gain;
      amplitudes.add(math.pow(10, gain / 20).toDouble());
    } else {
      amplitudes.add(1);
    }
  }
  var peak = total;
  if (positiveCount > 1) {
    double response(double frequency) {
      var sum = 0.0;
      for (var i = 0; i < gains.length; i++) {
        if (gains[i] < .01) continue;
        final ratio = frequency / bstreamEqualizerFrequencies[i];
        final squared = ratio * ratio;
        final distance = (1 - squared) * (1 - squared);
        sum += 10 /
            math.ln10 *
            math.log(
              (distance + squared * amplitudes[i]) /
                  (distance + squared / amplitudes[i]),
            );
      }
      return sum;
    }

    peak = 0;
    final start = math.log(bstreamEqualizerFrequencies.first);
    final span = math.log(bstreamEqualizerFrequencies.last) - start;
    for (var sample = 0; sample <= 256; sample++) {
      peak = math.max(peak, response(math.exp(start + span * sample / 256)));
    }
    for (final frequency in bstreamEqualizerFrequencies) {
      peak = math.max(peak, response(frequency));
    }
    peak = math.min(total, peak + .1);
  }
  _lastGains = List.unmodifiable(gains);
  _lastPreamp = peak > 0 ? -peak : 0;
  return _lastPreamp;
}
