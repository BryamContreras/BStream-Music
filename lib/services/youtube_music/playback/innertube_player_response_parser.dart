import 'innertube_stream_models.dart';

/// Parses the public shape of an InnerTube player JSON response.
///
/// Original BStream parser kept independent from external extractor code.
final class InnerTubePlayerResponseParser {
  const InnerTubePlayerResponseParser();

  InnerTubeParsedPlayerResponse parse(
    Map<String, dynamic> payload, {
    required String clientId,
  }) {
    final normalizedClientId = clientId.trim();
    if (normalizedClientId.isEmpty) {
      throw ArgumentError.value(clientId, 'clientId', 'Must not be empty.');
    }

    final playabilityData = _asMap(payload['playabilityStatus']);
    final playability = _parsePlayability(playabilityData);
    final streamingData = _asMap(payload['streamingData']);
    final responseHasDrm =
        _hasDrmMetadata(streamingData) ||
        playability.value == InnerTubePlayability.drmProtected;

    final formats = _parseFormats(
      streamingData?['formats'],
      source: InnerTubeFormatSource.formats,
      responseHasDrm: responseHasDrm,
    );
    final adaptiveFormats = _parseFormats(
      streamingData?['adaptiveFormats'],
      source: InnerTubeFormatSource.adaptiveFormats,
      responseHasDrm: responseHasDrm,
    );
    final details = _asMap(payload['videoDetails']);

    return InnerTubeParsedPlayerResponse(
      clientId: normalizedClientId,
      playability: playability,
      videoId: _text(details?['videoId']),
      title: _text(details?['title']),
      author: _text(details?['author']),
      duration: _secondsDuration(details?['lengthSeconds']),
      expiresIn: _secondsDuration(streamingData?['expiresInSeconds']),
      formats: formats,
      adaptiveFormats: adaptiveFormats,
      hlsManifestUri: _httpUri(streamingData?['hlsManifestUrl']),
      dashManifestUri: _httpUri(streamingData?['dashManifestUrl']),
      hasDrm:
          responseHasDrm ||
          formats.any((format) => format.isDrm) ||
          adaptiveFormats.any((format) => format.isDrm),
      isLive: _boolean(details?['isLiveContent']) ?? false,
    );
  }

  InnerTubePlayabilityStatus _parsePlayability(Map<dynamic, dynamic>? value) {
    final rawStatus = _text(value?['status'])?.toUpperCase() ?? 'UNKNOWN';
    final reason =
        _readableText(value?['reason']) ?? _readableText(value?['messages']);

    final errorScreen = _asMap(value?['errorScreen']);
    final errorRenderer = _asMap(errorScreen?['playerErrorMessageRenderer']);
    final subreason =
        _readableText(errorRenderer?['subreason']) ??
        _readableText(errorRenderer?['reason']) ??
        _readableText(value?['subreason']);
    final message = <String>[
      reason ?? '',
      subreason ?? '',
    ].join(' ').trim().toLowerCase();

    final result = switch (rawStatus) {
      'OK' => InnerTubePlayability.playable,
      'LIVE_STREAM_OFFLINE' => InnerTubePlayability.liveStreamOffline,
      'CONTENT_CHECK_REQUIRED' ||
      'AGE_CHECK_REQUIRED' => InnerTubePlayability.ageRestricted,
      'LOGIN_REQUIRED' => _classifyFailureMessage(
        message,
        fallback: InnerTubePlayability.loginRequired,
      ),
      'UNPLAYABLE' => _classifyFailureMessage(
        message,
        fallback: InnerTubePlayability.unplayable,
      ),
      'ERROR' => _classifyFailureMessage(
        message,
        fallback: InnerTubePlayability.error,
      ),
      'DRM' || 'DRM_REQUIRED' => InnerTubePlayability.drmProtected,
      'UNAVAILABLE' => _classifyFailureMessage(
        message,
        fallback: InnerTubePlayability.unavailable,
      ),
      _ => _classifyFailureMessage(
        message,
        fallback: InnerTubePlayability.unknown,
      ),
    };

    return InnerTubePlayabilityStatus(
      value: result,
      rawStatus: rawStatus,
      reason: reason,
      subreason: subreason,
    );
  }

  InnerTubePlayability _classifyFailureMessage(
    String message, {
    required InnerTubePlayability fallback,
  }) {
    if (message.contains('private')) {
      return InnerTubePlayability.privateVideo;
    }
    if (message.contains('member')) {
      return InnerTubePlayability.membersOnly;
    }
    if (message.contains('age') || message.contains('confirm your identity')) {
      return InnerTubePlayability.ageRestricted;
    }
    if (message.contains('country') ||
        message.contains('region') ||
        message.contains('location')) {
      return InnerTubePlayability.regionRestricted;
    }
    if (message.contains('drm') ||
        message.contains('digital rights management')) {
      return InnerTubePlayability.drmProtected;
    }
    if (message.contains('live stream') && message.contains('offline')) {
      return InnerTubePlayability.liveStreamOffline;
    }
    if (message.contains('unavailable')) {
      return InnerTubePlayability.unavailable;
    }
    return fallback;
  }

  List<InnerTubeAudioFormat> _parseFormats(
    Object? value, {
    required InnerTubeFormatSource source,
    required bool responseHasDrm,
  }) {
    if (value is! List) {
      return const <InnerTubeAudioFormat>[];
    }

    final parsed = <InnerTubeAudioFormat>[];
    for (final candidate in value) {
      final data = _asMap(candidate);
      if (data == null) {
        continue;
      }
      final format = _parseFormat(
        data,
        source: source,
        responseHasDrm: responseHasDrm,
      );
      if (format != null) {
        parsed.add(format);
      }
    }
    return parsed;
  }

  InnerTubeAudioFormat? _parseFormat(
    Map<dynamic, dynamic> data, {
    required InnerTubeFormatSource source,
    required bool responseHasDrm,
  }) {
    final itag = _positiveInt(data['itag']);
    final mime = _parseMimeType(_text(data['mimeType']));
    if (itag == null || mime == null) {
      return null;
    }
    if (!mime.mimeType.startsWith('audio/') &&
        !mime.codecs.any(_looksLikeAudioCodec)) {
      return null;
    }

    final directUri = _httpUri(data['url']);
    final cipher = _parseCipher(
      _text(data['signatureCipher']) ?? _text(data['cipher']),
    );
    final sourceUri = directUri ?? cipher?.uri;
    final audioTrack = _parseAudioTrack(data['audioTrack']);
    final audioQuality = _text(data['audioQuality']);
    final isDrc =
        (_boolean(data['isDrc']) ?? false) ||
        (_boolean(data['isDrcFormat']) ?? false) ||
        _containsDrc(audioTrack?.id) ||
        _containsDrc(audioTrack?.displayName) ||
        _containsDrc(audioQuality);

    var contentLength = _positiveInt(data['contentLength']);
    contentLength ??= _positiveInt(sourceUri?.queryParameters['clen']);

    return InnerTubeAudioFormat(
      source: source,
      itag: itag,
      uri: directUri,
      cipher: cipher,
      mimeType: mime.mimeType,
      container: mime.container,
      codecs: mime.codecs,
      bitrate: _positiveInt(data['bitrate']),
      averageBitrate: _positiveInt(data['averageBitrate']),
      contentLength: contentLength,
      approxDuration: _millisecondsDuration(data['approxDurationMs']),
      audioSampleRate: _positiveInt(data['audioSampleRate']),
      audioChannels: _positiveInt(data['audioChannels']),
      audioQuality: audioQuality,
      qualityLabel: _text(data['qualityLabel']) ?? _text(data['quality']),
      audioTrack: audioTrack,
      isDrc: isDrc,
      isDrm: responseHasDrm || _hasDrmMetadata(data),
    );
  }

  InnerTubeAudioTrack? _parseAudioTrack(Object? value) {
    final data = _asMap(value);
    if (data == null) {
      return null;
    }
    final id = _text(data['id']);
    final displayName = _readableText(data['displayName']);
    final isDefault = _boolean(data['audioIsDefault']);
    if (id == null && displayName == null && isDefault == null) {
      return null;
    }
    return InnerTubeAudioTrack(
      id: id,
      displayName: displayName,
      isDefault: isDefault,
    );
  }

  InnerTubeStreamCipher? _parseCipher(String? rawValue) {
    if (rawValue == null || rawValue.isEmpty) {
      return null;
    }
    Map<String, String> values;
    try {
      values = Uri.splitQueryString(rawValue);
    } on FormatException {
      return null;
    }

    final uri = _httpUri(values['url']);
    final encryptedSignature = _text(values['s']);
    final signature = _text(values['sig']) ?? _text(values['signature']);
    var signatureParameter = _text(values['sp']) ?? 'signature';
    if (!_safeQueryParameter.hasMatch(signatureParameter)) {
      signatureParameter = 'signature';
    }
    if (uri == null && encryptedSignature == null && signature == null) {
      return null;
    }
    return InnerTubeStreamCipher(
      uri: uri,
      encryptedSignature: encryptedSignature,
      signature: signature,
      signatureParameter: signatureParameter,
    );
  }

  bool _hasDrmMetadata(Map<dynamic, dynamic>? data) {
    if (data == null) {
      return false;
    }
    if (_boolean(data['isDrm']) == true ||
        _text(data['drmTrackType']) != null) {
      return true;
    }
    for (final key in const <String>[
      'licenseInfos',
      'licenseInfo',
      'drmFamilies',
    ]) {
      final value = data[key];
      if (value is List && value.isNotEmpty) {
        return true;
      }
      if (value is Map && value.isNotEmpty) {
        return true;
      }
      if (value == true || (value is String && _text(value) != null)) {
        return true;
      }
    }
    return false;
  }
}

final RegExp _safeQueryParameter = RegExp(r'^[A-Za-z0-9_.~-]+$');

final class _MimeInfo {
  const _MimeInfo({
    required this.mimeType,
    required this.container,
    required this.codecs,
  });

  final String mimeType;
  final String container;
  final List<String> codecs;
}

_MimeInfo? _parseMimeType(String? value) {
  if (value == null) {
    return null;
  }
  final segments = value.split(';');
  final mimeType = segments.first.trim().toLowerCase();
  if (!mimeType.contains('/')) {
    return null;
  }

  final codecMatch = RegExp(
    r'''codecs\s*=\s*(?:"([^"]*)"|'([^']*)'|([^;\s]+))''',
    caseSensitive: false,
  ).firstMatch(value);
  final encodedCodecs =
      codecMatch?.group(1) ??
      codecMatch?.group(2) ??
      codecMatch?.group(3) ??
      '';
  final codecs = encodedCodecs
      .split(',')
      .map((codec) => codec.trim())
      .where((codec) => codec.isNotEmpty)
      .toList(growable: false);

  final rawContainer = mimeType.split('/').last.toLowerCase();
  final container = switch (rawContainer) {
    'x-m4a' || 'm4a' => 'mp4',
    'x-mpegurl' || 'vnd.apple.mpegurl' => 'mpegurl',
    _ => rawContainer,
  };
  return _MimeInfo(mimeType: mimeType, container: container, codecs: codecs);
}

bool _looksLikeAudioCodec(String value) {
  final codec = value.toLowerCase();
  return codec.startsWith('mp4a') ||
      codec.startsWith('aac') ||
      codec.startsWith('opus') ||
      codec.startsWith('vorbis') ||
      codec.startsWith('ac-3') ||
      codec.startsWith('ec-3') ||
      codec.startsWith('dts') ||
      codec.startsWith('flac');
}

bool _containsDrc(String? value) {
  if (value == null) {
    return false;
  }
  return RegExp(
    r'(^|[._\s-])drc($|[._\s-])',
    caseSensitive: false,
  ).hasMatch(value);
}

Map<dynamic, dynamic>? _asMap(Object? value) {
  return value is Map ? value : null;
}

String? _text(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is! String && value is! num && value is! bool) {
    return null;
  }
  final normalized = value.toString().trim();
  return normalized.isEmpty ? null : normalized;
}

String? _readableText(Object? value, [int depth = 0]) {
  if (depth > 6) {
    return null;
  }
  final direct = _text(value);
  if (direct != null) {
    return direct;
  }
  if (value is List) {
    final parts = value
        .map((item) => _readableText(item, depth + 1))
        .whereType<String>()
        .toList(growable: false);
    return parts.isEmpty ? null : parts.join(' ');
  }
  if (value is Map) {
    for (final key in const <String>[
      'simpleText',
      'text',
      'reason',
      'subreason',
      'title',
      'runs',
    ]) {
      final result = _readableText(value[key], depth + 1);
      if (result != null) {
        return result;
      }
    }
    for (final nested in value.values) {
      final result = _readableText(nested, depth + 1);
      if (result != null) {
        return result;
      }
    }
  }
  return null;
}

int? _positiveInt(Object? value) {
  if (value == null) {
    return null;
  }
  final parsed = switch (value) {
    int number => number,
    num number when number.isFinite => number.toInt(),
    _ => int.tryParse(value.toString().trim()),
  };
  return parsed != null && parsed > 0 ? parsed : null;
}

bool? _boolean(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value == 1 ? true : (value == 0 ? false : null);
  }
  final normalized = value?.toString().trim().toLowerCase();
  return switch (normalized) {
    'true' || '1' => true,
    'false' || '0' => false,
    _ => null,
  };
}

Duration? _secondsDuration(Object? value) {
  final seconds = _positiveInt(value);
  return seconds == null ? null : Duration(seconds: seconds);
}

Duration? _millisecondsDuration(Object? value) {
  final milliseconds = _positiveInt(value);
  return milliseconds == null ? null : Duration(milliseconds: milliseconds);
}

Uri? _httpUri(Object? value) {
  final text = _text(value);
  if (text == null) {
    return null;
  }
  final normalized = text.startsWith('//') ? 'https:$text' : text;
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}
