enum InnerTubePlayability {
  playable,
  loginRequired,
  ageRestricted,
  regionRestricted,
  privateVideo,
  membersOnly,
  liveStreamOffline,
  drmProtected,
  unavailable,
  unplayable,
  error,
  unknown,
}

final class InnerTubePlayabilityStatus {
  const InnerTubePlayabilityStatus({
    required this.value,
    required this.rawStatus,
    this.reason,
    this.subreason,
  });

  final InnerTubePlayability value;
  final String rawStatus;
  final String? reason;
  final String? subreason;

  bool get isPlayable => value == InnerTubePlayability.playable;

  bool get maySucceedWithAnotherClient {
    return switch (value) {
      InnerTubePlayability.playable => false,
      InnerTubePlayability.privateVideo => false,
      InnerTubePlayability.membersOnly => false,
      InnerTubePlayability.drmProtected => false,
      InnerTubePlayability.loginRequired => true,
      InnerTubePlayability.ageRestricted => true,
      InnerTubePlayability.regionRestricted => true,
      InnerTubePlayability.liveStreamOffline => true,
      InnerTubePlayability.unavailable => true,
      InnerTubePlayability.unplayable => true,
      InnerTubePlayability.error => true,
      InnerTubePlayability.unknown => true,
    };
  }
}

enum InnerTubeFormatSource { formats, adaptiveFormats }

final class InnerTubeAudioTrack {
  const InnerTubeAudioTrack({this.id, this.displayName, this.isDefault});

  final String? id;
  final String? displayName;
  final bool? isDefault;
}

/// The URL and signature metadata from signatureCipher or cipher.
final class InnerTubeStreamCipher {
  const InnerTubeStreamCipher({
    required this.uri,
    this.encryptedSignature,
    this.signature,
    this.signatureParameter = 'signature',
  });

  final Uri? uri;

  /// The encrypted s parameter that still needs player-JavaScript deciphering.
  final String? encryptedSignature;

  /// An already usable sig/signature value, when supplied by the response.
  final String? signature;
  final String signatureParameter;

  bool get requiresSignatureDecipher {
    return encryptedSignature != null && encryptedSignature!.isNotEmpty;
  }

  Uri? get resolvedUri {
    final baseUri = uri;
    if (baseUri == null || requiresSignatureDecipher) {
      return null;
    }
    final plainSignature = signature;
    if (plainSignature == null || plainSignature.isEmpty) {
      return baseUri;
    }
    return baseUri.replace(
      queryParameters: <String, dynamic>{
        ...baseUri.queryParametersAll,
        signatureParameter: plainSignature,
      },
    );
  }
}

/// A format carrying audio, from either formats or adaptiveFormats.
final class InnerTubeAudioFormat {
  InnerTubeAudioFormat({
    required this.source,
    required this.itag,
    required this.mimeType,
    required this.container,
    required List<String> codecs,
    this.uri,
    this.cipher,
    this.bitrate,
    this.averageBitrate,
    this.contentLength,
    this.approxDuration,
    this.audioSampleRate,
    this.audioChannels,
    this.audioQuality,
    this.qualityLabel,
    this.audioTrack,
    this.isDrc = false,
    this.isDrm = false,
  }) : codecs = List<String>.unmodifiable(codecs);

  final InnerTubeFormatSource source;
  final int itag;
  final Uri? uri;
  final InnerTubeStreamCipher? cipher;
  final String mimeType;
  final String container;
  final List<String> codecs;
  final int? bitrate;
  final int? averageBitrate;
  final int? contentLength;
  final Duration? approxDuration;
  final int? audioSampleRate;
  final int? audioChannels;
  final String? audioQuality;
  final String? qualityLabel;
  final InnerTubeAudioTrack? audioTrack;
  final bool isDrc;
  final bool isDrm;

  String get mime => mimeType;

  Uri? get sourceUri => uri ?? cipher?.uri;

  Uri? get resolvedUri => uri ?? cipher?.resolvedUri;

  bool get hasResolvedUri => resolvedUri != null;

  bool get requiresSignatureDecipher {
    return cipher?.requiresSignatureDecipher ?? false;
  }

  bool get isDefaultAudio => audioTrack?.isDefault ?? true;

  bool get hasDrm => isDrm;

  bool get isAudioOnly => mimeType.toLowerCase().startsWith('audio/');

  bool get hasAudio => isAudioOnly || audioCodec != null;

  String? get audioCodec {
    if (codecs.isEmpty) {
      return null;
    }
    if (isAudioOnly && codecs.length == 1) {
      return codecs.first;
    }
    for (final codec in codecs.reversed) {
      if (_isKnownAudioCodec(codec)) {
        return codec;
      }
    }
    return isAudioOnly ? codecs.last : null;
  }

  bool get isMp4Aac {
    final codec = audioCodec?.toLowerCase();
    return container == 'mp4' &&
        codec != null &&
        (codec.startsWith('mp4a') || codec.startsWith('aac'));
  }

  int get effectiveBitrate => averageBitrate ?? bitrate ?? 0;
}

/// Whether AVFoundation can consume this direct YouTube representation.
///
/// iOS playback is backed by AVPlayer through just_audio. Keep the accepted
/// set deliberately narrow: MP4/M4A carrying AAC works for both audio-only and
/// muxed fallback representations, while WebM/Opus is not a portable
/// AVFoundation input format. The application enables this predicate only on
/// iOS; Android and desktop keep their existing broader decoder support.
bool isAvFoundationCompatibleInnerTubeAudio(InnerTubeAudioFormat format) {
  final container = format.container.trim().toLowerCase();
  final codec = format.audioCodec?.trim().toLowerCase();
  final declaresAac =
      codec?.startsWith('mp4a') == true || codec?.startsWith('aac') == true;
  if (container == 'aac') {
    return declaresAac ||
        (codec == null &&
            format.mimeType.trim().toLowerCase().startsWith('audio/aac'));
  }
  if (!declaresAac) {
    return false;
  }
  return container == 'mp4' || container == 'm4a';
}

final class InnerTubeParsedPlayerResponse {
  InnerTubeParsedPlayerResponse({
    required this.clientId,
    required this.playability,
    required List<InnerTubeAudioFormat> formats,
    required List<InnerTubeAudioFormat> adaptiveFormats,
    this.videoId,
    this.title,
    this.author,
    this.duration,
    this.expiresIn,
    this.hlsManifestUri,
    this.dashManifestUri,
    this.hasDrm = false,
    this.isLive = false,
  }) : formats = List<InnerTubeAudioFormat>.unmodifiable(formats),
       adaptiveFormats = List<InnerTubeAudioFormat>.unmodifiable(
         adaptiveFormats,
       ),
       audioFormats = List<InnerTubeAudioFormat>.unmodifiable(
         <InnerTubeAudioFormat>[...formats, ...adaptiveFormats],
       );

  final String clientId;
  final InnerTubePlayabilityStatus playability;
  final String? videoId;
  final String? title;
  final String? author;
  final Duration? duration;
  final Duration? expiresIn;
  final List<InnerTubeAudioFormat> formats;
  final List<InnerTubeAudioFormat> adaptiveFormats;
  final List<InnerTubeAudioFormat> audioFormats;
  final Uri? hlsManifestUri;
  final Uri? dashManifestUri;
  final bool hasDrm;
  final bool isLive;

  bool get isPlayable => playability.isPlayable;

  InnerTubeAudioFormat? selectPreferredAudio({
    bool allowDrm = false,
    bool requireResolvedUri = false,
    bool preferAudioOnly = true,
  }) {
    return selectPreferredInnerTubeAudio(
      audioFormats,
      allowDrm: allowDrm,
      requireResolvedUri: requireResolvedUri,
      preferAudioOnly: preferAudioOnly,
    );
  }
}

/// Selects an audio stream deterministically.
///
/// Explicit default-language tracks win first, then unknown-language tracks,
/// non-DRC variants, audio-only formats and finally MP4/AAC. Within the
/// resulting group the highest effective bitrate wins.
InnerTubeAudioFormat? selectPreferredInnerTubeAudio(
  Iterable<InnerTubeAudioFormat> formats, {
  bool allowDrm = false,
  bool requireResolvedUri = false,
  bool preferAudioOnly = true,
}) {
  var candidates = formats
      .where(
        (format) =>
            format.hasAudio &&
            (requireResolvedUri
                ? format.hasResolvedUri
                : format.sourceUri != null),
      )
      .toList(growable: false);

  if (!allowDrm) {
    candidates = candidates
        .where((format) => !format.isDrm)
        .toList(growable: false);
  }
  if (candidates.isEmpty) {
    return null;
  }

  candidates = _preferWhere(
    candidates,
    (format) => format.audioTrack?.isDefault == true,
  );
  if (!candidates.any((format) => format.audioTrack?.isDefault == true)) {
    candidates = _preferWhere(
      candidates,
      (format) => format.audioTrack?.isDefault != false,
    );
  }
  candidates = _preferWhere(candidates, (format) => !format.isDrc);
  if (preferAudioOnly) {
    candidates = _preferWhere(candidates, (format) => format.isAudioOnly);
  }
  candidates = _preferWhere(candidates, (format) => format.isMp4Aac);

  candidates.sort(_comparePreferredFormats);
  return candidates.first;
}

List<InnerTubeAudioFormat> _preferWhere(
  List<InnerTubeAudioFormat> formats,
  bool Function(InnerTubeAudioFormat format) predicate,
) {
  final preferred = formats.where(predicate).toList(growable: false);
  return preferred.isEmpty ? formats : preferred;
}

int _comparePreferredFormats(
  InnerTubeAudioFormat left,
  InnerTubeAudioFormat right,
) {
  var comparison = right.effectiveBitrate.compareTo(left.effectiveBitrate);
  if (comparison != 0) {
    return comparison;
  }
  comparison = (right.audioSampleRate ?? 0).compareTo(
    left.audioSampleRate ?? 0,
  );
  if (comparison != 0) {
    return comparison;
  }
  comparison = (right.audioChannels ?? 0).compareTo(left.audioChannels ?? 0);
  if (comparison != 0) {
    return comparison;
  }
  comparison = (right.contentLength ?? 0).compareTo(left.contentLength ?? 0);
  if (comparison != 0) {
    return comparison;
  }
  comparison = (right.hasResolvedUri ? 1 : 0).compareTo(
    left.hasResolvedUri ? 1 : 0,
  );
  if (comparison != 0) {
    return comparison;
  }
  return right.itag.compareTo(left.itag);
}

bool _isKnownAudioCodec(String value) {
  final codec = value.trim().toLowerCase();
  return codec.startsWith('mp4a') ||
      codec.startsWith('aac') ||
      codec.startsWith('opus') ||
      codec.startsWith('vorbis') ||
      codec.startsWith('ac-3') ||
      codec.startsWith('ec-3') ||
      codec.startsWith('dts') ||
      codec.startsWith('flac');
}
