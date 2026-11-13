/// Technical details of the selected audio stream, not the device's audio output.
/// Missing values deliberately remain unknown rather than assuming stereo/48k.
class AudioFormatDetails {
  const AudioFormatDetails({
    this.codec,
    this.mimeType,
    this.sampleRate,
    this.bitrate,
    this.channels,
  });

  final String? codec;
  final String? mimeType;
  final int? sampleRate;
  final int? bitrate;
  final int? channels;

  bool get isLossless {
    final name = codec?.trim().toLowerCase();
    final mime = mimeType?.split(';').first.trim().toLowerCase();
    return name == 'flac' ||
        name == 'alac' ||
        name == 'pcm' ||
        name?.startsWith('pcm_') == true ||
        const {
          'audio/flac',
          'audio/x-flac',
          'audio/alac',
          'audio/x-alac',
        }.contains(mime);
  }

  static AudioFormatDetails? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    String? text(Object? value) {
      if (value is! String) return null;
      final result = value.trim().toLowerCase();
      return result.isEmpty ||
              result.length > 128 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(result)
          ? null
          : result;
    }

    int? integer(Object? value, int maximum) {
      if (value is! num ||
          !value.isFinite ||
          value != value.truncateToDouble()) {
        return null;
      }
      return value > 0 && value <= maximum ? value.toInt() : null;
    }

    final result = AudioFormatDetails(
      codec: text(map['codec']),
      mimeType: text(map['mimeType']),
      sampleRate: integer(map['sampleRate'], 0x7fffffff),
      bitrate: integer(map['bitrate'], 0x7fffffff),
      channels: integer(map['channels'], 64),
    );
    return result.codec == null &&
            result.mimeType == null &&
            result.sampleRate == null &&
            result.bitrate == null &&
            result.channels == null
        ? null
        : result;
  }

  Map<String, Object?> toMap() => {
    'codec': codec,
    'mimeType': mimeType,
    'sampleRate': sampleRate,
    'bitrate': bitrate,
    'channels': channels,
  };

  @override
  bool operator ==(Object other) =>
      other is AudioFormatDetails &&
      codec == other.codec &&
      mimeType == other.mimeType &&
      sampleRate == other.sampleRate &&
      bitrate == other.bitrate &&
      channels == other.channels;

  @override
  int get hashCode =>
      Object.hash(codec, mimeType, sampleRate, bitrate, channels);
}
