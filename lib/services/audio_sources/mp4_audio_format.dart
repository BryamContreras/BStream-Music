import 'dart:typed_data';

import 'audio_format_details.dart';

/// A seekable, bounded header source. Readers must never decode audio payloads.
abstract interface class AudioFormatHeaderReader {
  int get length;
  Uint8List? read(int offset, int count);
}

/// Parses one complete MP4 header or moov box without copying its bytes.
AudioFormatDetails? readMp4AudioFormatBytes(Uint8List bytes) =>
    readMp4AudioFormat(_BytesHeaderReader(bytes));

class _BytesHeaderReader implements AudioFormatHeaderReader {
  _BytesHeaderReader(this.bytes);
  final Uint8List bytes;
  int remaining = 256 * 1024;
  int reads = 0;

  @override
  int get length => bytes.length;

  @override
  Uint8List? read(int offset, int count) {
    if (offset < 0 ||
        count < 0 ||
        count > 65536 ||
        count > remaining ||
        offset + count > bytes.length ||
        ++reads > 1024) {
      return null;
    }
    remaining -= count;
    return Uint8List.sublistView(bytes, offset, offset + count);
  }
}

String _ascii(Uint8List bytes, int offset, int length) =>
    offset < 0 || offset + length > bytes.length
    ? ''
    : String.fromCharCodes(bytes.sublist(offset, offset + length));
ByteData _data(Uint8List bytes) => ByteData.sublistView(bytes);

const _aacRates = [
  96000,
  88200,
  64000,
  48000,
  44100,
  32000,
  24000,
  22050,
  16000,
  12000,
  11025,
  8000,
  7350,
];
const _aacChannels = [0, 1, 2, 3, 4, 5, 6, 8];

/// The AAC frequency index is shared by AudioSpecificConfig and ADTS headers.
int? aacSampleRateForIndex(int index) =>
    index >= 0 && index < _aacRates.length ? _aacRates[index] : null;

/// Configuration zero is a program configuration element, not assumed stereo.
int? aacChannelCountForConfiguration(int configuration) =>
    configuration > 0 && configuration < _aacChannels.length
    ? _aacChannels[configuration]
    : null;

class _Atom {
  const _Atom(this.type, this.payload, this.end);
  final String type;
  final int payload;
  final int end;
}

_Atom? _atom(AudioFormatHeaderReader reader, int offset, int end) {
  if (offset + 8 > end) return null;
  final header = reader.read(offset, 8);
  if (header == null) return null;
  var size = _data(header).getUint32(0), headerSize = 8;
  if (size == 1) {
    final extended = reader.read(offset + 8, 8);
    if (extended == null) return null;
    size = _data(extended).getUint64(0);
    headerSize = 16;
  } else if (size == 0) {
    size = end - offset;
  }
  if (size < headerSize || offset + size > end) return null;
  return _Atom(_ascii(header, 4, 4), offset + headerSize, offset + size);
}

AudioFormatDetails? readMp4AudioFormat(AudioFormatHeaderReader reader) {
  final formats = <AudioFormatDetails>[];
  var boxes = 0;
  void walk(int start, int end, int depth) {
    if (depth > 8) return;
    for (var offset = start; offset + 8 <= end && boxes++ < 512;) {
      final atom = _atom(reader, offset, end);
      if (atom == null) return;
      if (const {'moov', 'trak', 'mdia', 'minf', 'stbl'}.contains(atom.type)) {
        walk(atom.payload, atom.end, depth + 1);
      } else if (atom.type == 'stsd') {
        final header = reader.read(atom.payload, 8);
        if (header == null) return;
        var entryOffset = atom.payload + 8;
        final count = _data(header).getUint32(4).clamp(0, 32);
        for (var i = 0; i < count && boxes++ < 512; i++) {
          final entry = _atom(reader, entryOffset, atom.end);
          if (entry == null) break;
          final quality = _readAudioSampleEntry(reader, entry);
          if (quality != null) formats.add(quality);
          entryOffset = entry.end;
        }
      }
      offset = atom.end;
    }
  }

  walk(0, reader.length, 0);
  // A file can contain multiple audio tracks/sample descriptions. Without
  // knowing the selected decoder track, do not choose one arbitrarily.
  return formats.length == 1
      ? formats.single
      : const AudioFormatDetails(mimeType: 'audio/mp4');
}

AudioFormatDetails? _readAudioSampleEntry(
  AudioFormatHeaderReader reader,
  _Atom entry,
) {
  if (!const {
    'mp4a',
    'alac',
    'Opus',
    'fLaC',
    '.mp3',
    'mp3 ',
  }.contains(entry.type)) {
    return null;
  }
  final header = reader.read(entry.payload, 28);
  if (header == null || entry.payload + 28 > entry.end) return null;
  final data = _data(header), version = data.getUint16(8);
  String? codec = switch (entry.type) {
    'alac' => 'alac',
    'Opus' => 'opus',
    'fLaC' => 'flac',
    '.mp3' || 'mp3 ' => 'mp3',
    _ => null,
  };
  if (version > 1) {
    return AudioFormatDetails(codec: codec, mimeType: 'audio/mp4');
  }
  var channels = data.getUint16(16);
  var sampleRate = data.getUint32(24) >> 16;
  int? bitrate;
  var offset = entry.payload + (version == 1 ? 44 : 28);
  for (var count = 0; offset + 8 <= entry.end && count < 64; count++) {
    final atom = _atom(reader, offset, entry.end);
    if (atom == null) break;
    if (atom.type == 'esds') {
      final bytes = reader.read(
        atom.payload,
        (atom.end - atom.payload).clamp(0, 4096),
      );
      final config = bytes == null ? null : _decoderConfig(bytes);
      if (config != null) {
        codec = config.codec;
        bitrate = config.bitrate;
        sampleRate = config.sampleRate ?? sampleRate;
        channels = config.channels ?? channels;
      }
    } else if (atom.type == 'dOps') {
      final bytes = reader.read(atom.payload, 11);
      if (bytes != null) channels = bytes[1];
      sampleRate = 48000;
    } else if (atom.type == 'btrt' && bitrate == null) {
      final bytes = reader.read(atom.payload, 12);
      if (bytes != null) bitrate = _data(bytes).getUint32(8);
    }
    offset = atom.end;
  }
  return AudioFormatDetails.fromMap({
    'codec': codec,
    'mimeType': 'audio/mp4',
    'sampleRate': sampleRate,
    'channels': channels,
    'bitrate': bitrate,
  });
}

class _DecoderConfig {
  const _DecoderConfig(
    this.codec,
    this.bitrate,
    this.sampleRate,
    this.channels,
  );
  final String? codec;
  final int? bitrate;
  final int? sampleRate;
  final int? channels;
}

_DecoderConfig? _decoderConfig(Uint8List bytes) {
  _DecoderConfig? walk(int start, int end, int depth) {
    if (depth > 4) return null;
    for (
      var offset = start, count = 0;
      offset + 2 <= end && count < 32;
      count++
    ) {
      final tag = bytes[offset++];
      var length = 0, finished = false;
      for (var i = 0; i < 4 && offset < end; i++) {
        final next = bytes[offset++];
        length = length << 7 | next & 127;
        if (next & 128 == 0) {
          finished = true;
          break;
        }
      }
      if (!finished || offset + length > end) return null;
      final limit = offset + length;
      if (tag == 3 && length >= 3) {
        final flags = bytes[offset + 2];
        var nested = offset + 3;
        if (flags & 128 != 0) nested += 2;
        if (flags & 64 != 0) {
          if (nested >= limit) return null;
          nested += 1 + bytes[nested];
        }
        if (flags & 32 != 0) nested += 2;
        final result = nested <= limit ? walk(nested, limit, depth + 1) : null;
        if (result != null) return result;
      } else if (tag == 4 && length >= 13) {
        final objectType = bytes[offset];
        final codec = switch (objectType) {
          0x40 || 0x66 || 0x67 || 0x68 => 'aac',
          0x69 || 0x6b => 'mp3',
          _ => null,
        };
        final bitrate = _data(bytes).getUint32(offset + 9);
        int? rate, channels;
        final nested = offset + 13;
        if (codec == 'aac' && nested + 2 < limit && bytes[nested] == 5) {
          var pos = nested + 1, configLength = 0;
          for (var i = 0; i < 4 && pos < limit; i++) {
            final next = bytes[pos++];
            configLength = configLength << 7 | next & 127;
            if (next & 128 == 0) break;
          }
          if (pos + configLength <= limit) {
            final config = _aacConfig(
              Uint8List.sublistView(bytes, pos, pos + configLength),
            );
            rate = config?.$1;
            channels = config?.$2;
          }
        }
        return _DecoderConfig(
          codec,
          bitrate > 0 ? bitrate : null,
          rate,
          channels,
        );
      }
      offset = limit;
    }
    return null;
  }

  return bytes.length < 6 ? null : walk(4, bytes.length, 0);
}

(int?, int?)? _aacConfig(Uint8List bytes) {
  var position = 0;
  int? bits(int count) {
    if (position + count > bytes.length * 8) return null;
    var result = 0;
    for (var i = 0; i < count; i++, position++) {
      result =
          result << 1 | ((bytes[position >> 3] >> (7 - (position & 7))) & 1);
    }
    return result;
  }

  int? frequency() {
    final index = bits(4);
    if (index == 15) return bits(24);
    return index != null && index < _aacRates.length ? _aacRates[index] : null;
  }

  var objectType = bits(5);
  if (objectType == 31) {
    final extension = bits(6);
    if (extension == null) return null;
    objectType = extension + 32;
  }
  var rate = frequency();
  final configuration = bits(4);
  int? channels =
      configuration != null &&
          configuration > 0 &&
          configuration < _aacChannels.length
      ? _aacChannels[configuration]
      : null;
  if (objectType == 5 || objectType == 29) {
    rate = frequency() ?? rate;
    if (objectType == 29) channels = 2;
  }
  return (rate, channels);
}
