import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../services/audio_sources/audio_network_monitor.dart';
import '../../../../services/audio_sources/audio_source_policy.dart';
import '../../../../services/downloader/audio_stream_resolver.dart';
import '../../../../services/jiosaavn/jiosaavn_audio_resolver.dart';
import '../../domain/entities/track_info.dart';
import 'music_providers.dart';

typedef AudioSourceUpgradeLookup =
    Future<AudioStreamResolution?> Function(
      TrackInfo track, {
      int? currentBitrate,
      bool Function()? shouldContinue,
    });

final audioSourceUsesSingleProfileProvider = Provider<bool>(
  (ref) => AppPlatform.isDesktop,
);

final audioSourcePolicyProvider = Provider<AudioSourcePolicy>((ref) {
  final settings = ref.watch(settingsControllerProvider).value;
  return AudioSourcePolicy(
    jioSaavnEnabled: settings?.jioSaavnEnabled ?? false,
    wifiAudioQuality: settings?.wifiAudioQuality ?? AudioQualityProfile.high,
    mobileAudioQuality:
        settings?.mobileAudioQuality ?? AudioQualityProfile.standard,
    useSingleProfile: ref.watch(audioSourceUsesSingleProfileProvider),
  );
});

final audioNetworkMonitorProvider = Provider<AudioNetworkMonitor>((ref) {
  final monitor = AudioNetworkMonitor();
  ref.onDispose(() => unawaited(monitor.dispose()));
  return monitor;
});

final jioSaavnAudioResolverProvider = Provider<JioSaavnAudioResolver>((ref) {
  final resolver = JioSaavnAudioResolver();
  ref.onDispose(() => unawaited(resolver.dispose()));
  return resolver;
});

final audioSourceUpgradeLookupProvider = Provider<AudioSourceUpgradeLookup>(
  (ref) => ref.watch(jioSaavnAudioResolverProvider).findUpgrade,
);

class AudioQualityUpgradeState {
  const AudioQualityUpgradeState({this.queueEntryId, this.active = false});

  final String? queueEntryId;
  final bool active;
}

final audioQualityUpgradeStateProvider =
    NotifierProvider<AudioQualityUpgradeNotifier, AudioQualityUpgradeState>(
      AudioQualityUpgradeNotifier.new,
    );

class AudioQualityUpgradeNotifier extends Notifier<AudioQualityUpgradeState> {
  @override
  AudioQualityUpgradeState build() => const AudioQualityUpgradeState();

  void begin(String queueEntryId) {
    state = AudioQualityUpgradeState(queueEntryId: queueEntryId, active: true);
  }

  void finish(String queueEntryId) {
    if (state.queueEntryId == queueEntryId) {
      state = const AudioQualityUpgradeState();
    }
  }
}
