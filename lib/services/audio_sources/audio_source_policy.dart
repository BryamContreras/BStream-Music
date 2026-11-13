enum AudioQualityProfile { standard, high }

enum AudioNetworkKind { wifi, mobile, offline, unknown }

/// YouTube Music remains the mandatory first source. Optional providers may
/// improve its audio only when the current connection's profile permits it.
class AudioSourcePolicy {
  const AudioSourcePolicy({
    this.jioSaavnEnabled = true,
    this.wifiAudioQuality = AudioQualityProfile.high,
    this.mobileAudioQuality = AudioQualityProfile.standard,
    this.useSingleProfile = false,
  });

  final bool jioSaavnEnabled;
  final AudioQualityProfile wifiAudioQuality;
  final AudioQualityProfile mobileAudioQuality;

  /// Desktop has one quality choice for every connection, including VPNs or
  /// platforms that cannot identify their active transport.
  final bool useSingleProfile;

  AudioQualityProfile profileFor(AudioNetworkKind network) {
    if (!jioSaavnEnabled) return AudioQualityProfile.standard;
    if (useSingleProfile) return wifiAudioQuality;
    return switch (network) {
      AudioNetworkKind.wifi => wifiAudioQuality,
      AudioNetworkKind.mobile => mobileAudioQuality,
      // Unknown or disconnected transport must not opt into extra data use.
      AudioNetworkKind.offline ||
      AudioNetworkKind.unknown => AudioQualityProfile.standard,
    };
  }

  bool allowsUpgrade(AudioNetworkKind network) =>
      profileFor(network) == AudioQualityProfile.high;

  String get cacheKey =>
      '${jioSaavnEnabled ? 1 : 0}:${wifiAudioQuality.name}:'
      '${mobileAudioQuality.name}:${useSingleProfile ? 1 : 0}';
}
