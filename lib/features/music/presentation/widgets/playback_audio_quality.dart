/// Describes only the audio format details known for the active source.
/// A container or file extension is not used to guess a bitrate, sample rate
/// or channel count. Unknown details are omitted instead of showing defaults.
String? playbackAudioQualityLabel({
  String? codec,
  String? mimeType,
  String? extension,
  int? bitrate,
  int? sampleRate,
  int? channels,
  String stereoLabel = 'Stereo',
  String monoLabel = 'Mono',
  String Function(int)? channelCountLabel,
  String? localSource,
}) {
  final normalizedCodec = codec?.trim().toLowerCase() ?? '';
  final format = switch (normalizedCodec) {
    'mp4a' || 'aac' => 'AAC',
    'opus' => 'Opus',
    'vorbis' => 'Vorbis',
    'mp3' || 'mpga' => 'MP3',
    'mp2' => 'MP2',
    'mp1' => 'MP1',
    'flac' => 'FLAC',
    'alac' => 'ALAC',
    'pcm' => 'PCM',
    'ac-3' => 'AC-3',
    'e-ac-3' => 'E-AC-3',
    'amr' => 'AMR',
    'amr-wb' => 'AMR-WB',
    'alaw' => 'A-law',
    'mulaw' => '\u00b5-law',
    _ when normalizedCodec.startsWith('mp4a.') => 'AAC',
    _ when normalizedCodec.startsWith('opus') => 'Opus',
    _ when normalizedCodec.startsWith('vorbis') => 'Vorbis',
    _ when normalizedCodec.startsWith('flac') => 'FLAC',
    _ when normalizedCodec.startsWith('alac') => 'ALAC',
    _ when normalizedCodec.startsWith('pcm_') => 'PCM',
    _ =>
      _formatFromExtension(extension) ??
          _formatFromMimeType(mimeType) ??
          _formatFromLocalSource(localSource),
  };
  final bitrateLabel = bitrate != null && bitrate > 0
      ? '${(bitrate / 1000).round()} kbps'
      : null;
  final sampleRateLabel = sampleRate != null && sampleRate > 0
      ? _sampleRateLabel(sampleRate)
      : null;
  final channelLabel = switch (channels) {
    1 => monoLabel,
    2 => stereoLabel,
    final count? when count > 2 =>
      channelCountLabel?.call(count) ?? '$count channels',
    _ => null,
  };
  final details = [?format, ?sampleRateLabel, ?bitrateLabel].join(' \u00B7 ');
  if (channelLabel != null && channelLabel.trim().isNotEmpty) {
    return details.isEmpty ? channelLabel : '$details - $channelLabel';
  }
  return details.isEmpty ? null : details;
}

String _sampleRateLabel(int rate) {
  final wholeKilohertz = rate ~/ 1000;
  final remainder = rate % 1000;
  if (remainder == 0) return '$wholeKilohertz kHz';
  final fraction = remainder
      .toString()
      .padLeft(3, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '$wholeKilohertz.$fraction kHz';
}

String? _formatFromLocalSource(String? source) {
  if (source == null || source.isEmpty) return null;
  final path = Uri.tryParse(source)?.path ?? source;
  final fileName = path.split(RegExp(r'[\\/]')).last;
  final extensionStart = fileName.lastIndexOf('.');
  if (extensionStart < 0) return null;
  return _formatFromExtension(fileName.substring(extensionStart + 1));
}

String? _formatFromExtension(String? extension) {
  return switch (extension?.trim().toLowerCase().replaceFirst('.', '')) {
    'm4a' || 'mp4' => 'M4A',
    'aac' => 'AAC',
    'mp3' => 'MP3',
    'webm' || 'weba' => 'WebM',
    'opus' => 'Opus',
    'ogg' || 'oga' => 'Ogg',
    'flac' => 'FLAC',
    'alac' => 'ALAC',
    'wav' || 'wave' => 'WAV',
    'aiff' || 'aif' => 'AIFF',
    'wma' => 'WMA',
    _ => null,
  };
}

String? _formatFromMimeType(String? mimeType) {
  return switch (mimeType?.split(';').first.trim().toLowerCase()) {
    'audio/mp4' || 'audio/x-m4a' => 'M4A',
    'audio/aac' => 'AAC',
    'audio/mpeg' => 'MP3',
    'audio/webm' => 'WebM',
    'audio/opus' => 'Opus',
    'audio/ogg' => 'Ogg',
    'audio/flac' || 'audio/x-flac' => 'FLAC',
    'audio/wav' || 'audio/x-wav' => 'WAV',
    _ => null,
  };
}
