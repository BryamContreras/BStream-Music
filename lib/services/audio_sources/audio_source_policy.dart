import 'audio_extension.dart';

/// Maximum difference between runtimes for upgrading the same recording.
const audioUpgradeDurationTolerance = Duration(seconds: 3);

enum AudioQualityProfile { standard, high }

enum AudioNetworkKind { wifi, mobile, offline, unknown }

/// Priority for optional audio, after the standard YouTube Music source.
class AudioSourcePreference {
  const AudioSourcePreference.automatic()
    : isJioSaavnOnly = false,
      preferredExtensionUri = null;

  const AudioSourcePreference.jioSaavn()
    : isJioSaavnOnly = true,
      preferredExtensionUri = null;

  const AudioSourcePreference.audioExtension(Uri uri)
    : isJioSaavnOnly = false,
      preferredExtensionUri = uri;

  final bool isJioSaavnOnly;
  final Uri? preferredExtensionUri;

  String? get code =>
      isJioSaavnOnly ? 'jioSaavn' : preferredExtensionUri?.toString();

  static AudioSourcePreference fromCode(String? code) {
    if (code == 'jioSaavn') return const AudioSourcePreference.jioSaavn();
    final uri = audioExtensionHttpsUri(code);
    return uri == null
        ? const AudioSourcePreference.automatic()
        : AudioSourcePreference.audioExtension(uri);
  }

  bool hasSource({
    required bool jioSaavnEnabled,
    required bool hasExtensions,
  }) => jioSaavnEnabled || (!isJioSaavnOnly && hasExtensions);

  List<AudioExtension> orderedExtensions(
    List<AudioExtension> installed, {
    required bool forDownload,
  }) {
    if (isJioSaavnOnly) return const [];
    final eligible = installed.where(
      (source) => source.enabled && (!forDownload || source.allowDownloads),
    );
    if (preferredExtensionUri == null) return eligible.toList(growable: false);
    return [
      ...eligible.where(
        (source) => source.manifestUri == preferredExtensionUri,
      ),
      ...eligible.where(
        (source) => source.manifestUri != preferredExtensionUri,
      ),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is AudioSourcePreference &&
      other.isJioSaavnOnly == isJioSaavnOnly &&
      other.preferredExtensionUri == preferredExtensionUri;

  @override
  int get hashCode => Object.hash(isJioSaavnOnly, preferredExtensionUri);
}

/// YouTube Music remains the mandatory first source. Optional providers may
/// improve its audio only when the current connection's profile permits it.
class AudioSourcePolicy {
  const AudioSourcePolicy({
    this.jioSaavnEnabled = true,
    this.audioExtensionRevision,
    this.wifiAudioQuality = AudioQualityProfile.high,
    this.mobileAudioQuality = AudioQualityProfile.standard,
    this.wifiAudioSourcePreference = const AudioSourcePreference.automatic(),
    this.mobileAudioSourcePreference = const AudioSourcePreference.automatic(),
    this.useSingleProfile = false,
  });

  final bool jioSaavnEnabled;
  final int? audioExtensionRevision;
  bool get hasHighQualitySource =>
      jioSaavnEnabled || audioExtensionRevision != null;
  final AudioQualityProfile wifiAudioQuality;
  final AudioQualityProfile mobileAudioQuality;
  final AudioSourcePreference wifiAudioSourcePreference;
  final AudioSourcePreference mobileAudioSourcePreference;

  /// Desktop has one quality choice for every connection, including VPNs or
  /// platforms that cannot identify their active transport.
  final bool useSingleProfile;

  AudioSourcePreference sourcePreferenceFor(AudioNetworkKind network) =>
      !useSingleProfile && network == AudioNetworkKind.mobile
      ? mobileAudioSourcePreference
      : wifiAudioSourcePreference;

  AudioQualityProfile profileFor(AudioNetworkKind network) {
    if (!sourcePreferenceFor(network).hasSource(
      jioSaavnEnabled: jioSaavnEnabled,
      hasExtensions: audioExtensionRevision != null,
    )) {
      return AudioQualityProfile.standard;
    }
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

  bool canUseExtensions(AudioNetworkKind network) =>
      audioExtensionRevision != null &&
      allowsUpgrade(network) &&
      !sourcePreferenceFor(network).isJioSaavnOnly;

  bool get canUseAnyExtension =>
      canUseExtensions(AudioNetworkKind.wifi) ||
      (!useSingleProfile && canUseExtensions(AudioNetworkKind.mobile));

  String get cacheKey =>
      '${jioSaavnEnabled ? 1 : 0}:${wifiAudioQuality.name}:'
      '${mobileAudioQuality.name}:${useSingleProfile ? 1 : 0}:'
      '${audioExtensionRevision ?? ""}:'
      '${wifiAudioSourcePreference.hashCode}:${mobileAudioSourcePreference.hashCode}';
}
