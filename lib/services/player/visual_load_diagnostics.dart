import 'package:flutter/foundation.dart';

/// Opt-in timings for separating artwork lookup, transfer and local decoder
/// startup. Enable with --dart-define=BSTREAM_VISUAL_TIMINGS=true.
const bool visualLoadTimingsEnabled = bool.fromEnvironment(
  'BSTREAM_VISUAL_TIMINGS',
);

void logVisualLoad(
  String stage, {
  required String track,
  int? elapsedMs,
  int? bytes,
}) {
  if (!visualLoadTimingsEnabled) return;
  final details = <String>[
    DateTime.now().toIso8601String(),
    stage,
    'track=${track.hashCode.toRadixString(16)}',
    if (elapsedMs != null) 'elapsed=${elapsedMs}ms',
    if (bytes != null) 'bytes=$bytes',
  ];
  debugPrint('BStream visual: ${details.join(' ')}');
}
