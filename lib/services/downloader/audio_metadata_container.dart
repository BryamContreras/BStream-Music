import 'dart:io';

enum AudioMetadataContainer { mp4, standard, ogg, webm, unsupported }

/// Routes by file contents. An extension alone must never select a writer for
/// a different container, and audio-only MP4 can reuse the existing M4A writer.
AudioMetadataContainer detectAudioMetadataContainer(File file) {
  final input = file.openSync();
  try {
    final bytes = input.readSync(32);
    bool marker(int offset, List<int> signature) {
      if (offset + signature.length > bytes.length) return false;
      for (var index = 0; index < signature.length; index++) {
        if (bytes[offset + index] != signature[index]) return false;
      }
      return true;
    }

    if (marker(4, const [0x66, 0x74, 0x79, 0x70])) {
      return AudioMetadataContainer.mp4;
    }
    if (marker(0, const [0x4f, 0x67, 0x67, 0x53])) {
      return AudioMetadataContainer.ogg;
    }
    if (marker(0, const [0x1a, 0x45, 0xdf, 0xa3])) {
      return AudioMetadataContainer.webm;
    }
    if (marker(0, const [0x49, 0x44, 0x33]) ||
        marker(0, const [0x66, 0x4c, 0x61, 0x43]) ||
        marker(0, const [0x4d, 0x41, 0x43, 0x20]) ||
        (marker(0, const [0x52, 0x49, 0x46, 0x46]) &&
            marker(8, const [0x57, 0x41, 0x56, 0x45])) ||
        (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0) ||
        (bytes.isNotEmpty && bytes.first == 0)) {
      // Some MP3 encoders put bounded zero padding before the first frame. The
      // standard writer verifies actual consecutive MPEG frames before editing.
      return AudioMetadataContainer.standard;
    }
    return AudioMetadataContainer.unsupported;
  } finally {
    input.closeSync();
  }
}
