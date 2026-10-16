import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/player/local_audio_quality_service.dart';

/// Small, process-local metadata cache. It does no work until the visible
/// player's quality footer requests a local source.
final localPlaybackAudioQualityServiceProvider =
    Provider<LocalAudioQualityService>((ref) {
      final service = LocalAudioQualityService();
      ref.onDispose(service.dispose);
      return service;
    });

/// Source-keyed futures prevent a slow old file from overwriting the new song.
/// Leaving the player or disabling the setting releases the subscription; the
/// service retains only its bounded metadata cache, without polling or timers.
final localPlaybackAudioQualityProvider = FutureProvider.autoDispose
    .family<LocalAudioQuality?, String>((ref, source) {
      return ref.watch(localPlaybackAudioQualityServiceProvider).read(source);
    });
