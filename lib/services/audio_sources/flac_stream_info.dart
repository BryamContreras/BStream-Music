import 'dart:typed_data';

/// The technical fields shared by local FLAC files and remote range probes.
class FlacStreamInfo {
  const FlacStreamInfo._({
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
    required this.sampleCount,
  });

  static const prefixLength = 42;

  final int sampleRate;
  final int channels;
  final int bitDepth;
  final int sampleCount;

  static FlacStreamInfo? fromPrefix(Uint8List prefix) {
    if (prefix.length < prefixLength ||
        ByteData.sublistView(prefix).getUint32(0) != 0x664c6143 || // fLaC
        prefix[4] & 0x7f != 0 ||
        prefix[5] != 0 ||
        prefix[6] != 0 ||
        prefix[7] != 34) {
      return null;
    }
    return fromBlock(Uint8List.sublistView(prefix, 8, prefixLength));
  }

  static FlacStreamInfo? fromBlock(Uint8List block) {
    if (block.length != 34) return null;
    final data = ByteData.sublistView(block);
    // The first twenty bits are the sample rate. The following three and
    // five bits encode channel count and sample precision minus one.
    final packed = data.getUint64(10);
    return FlacStreamInfo._(
      sampleRate: (packed >> 44) & 0xfffff,
      channels: ((packed >> 41) & 7) + 1,
      bitDepth: ((packed >> 36) & 31) + 1,
      sampleCount: packed & 0xfffffffff,
    );
  }
}
