import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../services/audio_sources/audio_extension_resolver.dart';
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
      AudioSourcePreference? sourcePreference,
      bool Function()? shouldContinue,
    });

final audioSourceUsesSingleProfileProvider = Provider<bool>(
  (ref) => AppPlatform.isDesktop,
);

final audioSourcePolicyProvider = Provider<AudioSourcePolicy>((ref) {
  final settings = ref.watch(settingsControllerProvider).value;
  final enabledExtensions = settings?.audioExtensions.where(
    (item) => item.enabled,
  );
  return AudioSourcePolicy(
    jioSaavnEnabled: settings?.jioSaavnEnabled ?? false,
    audioExtensionRevision:
        enabledExtensions == null || enabledExtensions.isEmpty
        ? null
        : Object.hashAll(enabledExtensions.map((item) => item.manifestUri)),
    wifiAudioQuality: settings?.wifiAudioQuality ?? AudioQualityProfile.high,
    mobileAudioQuality:
        settings?.mobileAudioQuality ?? AudioQualityProfile.standard,
    wifiAudioSourcePreference:
        settings?.wifiAudioSourcePreference ??
        const AudioSourcePreference.automatic(),
    mobileAudioSourcePreference:
        settings?.mobileAudioSourcePreference ??
        const AudioSourcePreference.automatic(),
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
  (ref) => _audioSourceUpgradeLookup(ref),
);

final downloadAudioSourceUpgradeLookupProvider =
    Provider<AudioSourceUpgradeLookup>(
      (ref) => _audioSourceUpgradeLookup(ref, forDownload: true),
    );

final audioExtensionResolverProvider = Provider<AudioExtensionResolver>((ref) {
  final resolver = AudioExtensionResolver();
  ref.onDispose(() => unawaited(resolver.dispose()));
  return resolver;
});

AudioSourceUpgradeLookup _audioSourceUpgradeLookup(
  Ref ref, {
  bool forDownload = false,
}) {
  return (track, {currentBitrate, sourcePreference, shouldContinue}) async {
    final settings = ref.read(settingsControllerProvider).value;
    if (settings == null || shouldContinue?.call() == false) return null;
    final preference =
        sourcePreference ?? const AudioSourcePreference.automatic();
    final extensions = preference.orderedExtensions(
      settings.audioExtensions,
      forDownload: forDownload,
    );
    if (extensions.isNotEmpty) {
      bool canUseExtensions() =>
          shouldContinue?.call() != false &&
          identical(
            settings.audioExtensions,
            ref.read(settingsControllerProvider).value?.audioExtensions,
          );
      final candidate = await ref
          .read(audioExtensionResolverProvider)
          .findUpgrade(
            track,
            extensions: extensions,
            forDownload: forDownload,
            shouldContinue: canUseExtensions,
          );
      if (candidate != null && canUseExtensions()) return candidate;
    }
    bool canUseJioSaavn() =>
        shouldContinue?.call() != false &&
        ref.read(settingsControllerProvider).value?.jioSaavnEnabled == true;
    if (!canUseJioSaavn()) return null;
    final candidate = await ref
        .read(jioSaavnAudioResolverProvider)
        .findUpgrade(
          track,
          currentBitrate: currentBitrate,
          shouldContinue: canUseJioSaavn,
        );
    return canUseJioSaavn() ? candidate : null;
  };
}

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
