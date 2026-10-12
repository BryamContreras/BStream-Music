/// Describes only the audio format details known for the active source.
/// A container or file extension is not used to guess a bitrate.
String? playbackAudioQualityLabel({
  String? codec,
  String? mimeType,
  String? extension,
  int? bitrate,
  String? localSource,
}) {
  final normalizedCodec = codec?.trim().toLowerCase() ?? '';
  final format = switch (normalizedCodec) {
    'mp4a' || 'aac' => 'AAC',
    'opus' => 'Opus',
    'vorbis' => 'Vorbis',
    'mp3' || 'mpga' => 'MP3',
    'flac' => 'FLAC',
    'alac' => 'ALAC',
    'pcm' => 'PCM',
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
  final rate = bitrate != null && bitrate > 0
      ? '${(bitrate / 1000).round()} kbps'
      : null;
  if (format == null) return rate;
  return rate == null ? format : '$format \u00B7 $rate';
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
