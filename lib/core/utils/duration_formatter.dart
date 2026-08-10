String formatDuration(Duration? duration) {
  if (duration == null) {
    return '--:--';
  }

  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');

  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '${duration.inMinutes}:$seconds';
}

/// Adds every known duration in a collection without changing persisted data.
/// A null result means that none of the tracks exposed a duration.
Duration? sumKnownDurations(Iterable<Duration?> durations) {
  var total = Duration.zero;
  var hasDuration = false;
  for (final duration in durations) {
    if (duration == null) {
      continue;
    }
    total += duration;
    hasDuration = true;
  }
  return hasDuration ? total : null;
}

/// Formats collection summaries without exposing seconds once an hour is
/// reached. Under an hour the `mm:ss min` form keeps the precise duration.
String formatCollectionDuration(Duration? duration) {
  if (duration == null) {
    return '--:-- min';
  }

  final hours = duration.inHours;
  if (hours > 0) {
    final minutes = duration.inMinutes.remainder(60);
    return '$hours h $minutes min';
  }

  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '${duration.inMinutes}:$seconds min';
}
