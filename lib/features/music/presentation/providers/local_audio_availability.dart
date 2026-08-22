import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/local_track.dart';

typedef LocalAudioUsabilityProbe = Future<bool> Function(String path);

/// Checks the audio payload itself, independently from cached artwork.
///
/// An existing but empty file is not a usable download. Keeping the probe
/// injectable also lets playlist rows remain deterministic in widget tests.
Future<bool> probeUsableLocalAudio(String path) async {
  final normalized = path.trim();
  if (normalized.isEmpty) return false;
  try {
    final file = File(normalized);
    return await file.exists() && await file.length() > 0;
  } catch (_) {
    return false;
  }
}

final localAudioUsabilityProbeProvider = Provider<LocalAudioUsabilityProbe>(
  (ref) => probeUsableLocalAudio,
);

/// Availability of one library audio file.
///
/// [LocalTrack] is deliberately the family key instead of only [LocalTrack.filePath].
/// A completed download reloads the library with a fresh entity, so a previous
/// negative result cannot remain cached for a newly published file.
final localTrackAudioAvailabilityProvider = FutureProvider.autoDispose
    .family<bool, LocalTrack>((ref, track) {
      return ref.watch(localAudioUsabilityProbeProvider)(track.filePath);
    });
