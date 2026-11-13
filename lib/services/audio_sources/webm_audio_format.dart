import 'dart:typed_data';

import 'audio_format_details.dart';
import 'mp4_audio_format.dart';

/// Reads audio declarations and cluster sizes without scanning media blocks.
/// The caller's shared reader bounds bytes and seeks over clusters/attachments.
AudioFormatDetails? readWebmAudioFormat(AudioFormatHeaderReader reader) {
  const container = AudioFormatDetails(mimeType: 'audio/webm');
  final scan = _WebmScan(reader);
  AudioFormatDetails? declared;
  try {
    final header = _element(scan, 0, reader.length);
    if (header.id != 0x1a45dfa3 || header.unknownSize) return null;
    String? documentType;
    for (final child in _children(scan, header.payload, header.end)) {
      if (child.id == 0x4282) {
        documentType = _text(scan, child);
      }
    }
    if (documentType != 'webm' && documentType != 'matroska') return null;
    var offset = header.end;
    for (var count = 0; count < 16; count++) {
      final segment = _element(scan, offset, reader.length);
      if (segment.id == 0xec && !segment.unknownSize) {
        offset = segment.end;
        continue;
      }
      if (segment.id != 0x18538067) return container;
      var trackGroups = 0;
      var infoGroups = 0;
      var singleAudioTrack = false;
      var clusterBytes = 0;
      var consistentInfo = true;
      double? durationTicks;
      var timecodeScale = 1000000; // Matroska's default nanoseconds per tick.
      for (final child in _children(scan, segment.payload, segment.end)) {
        if (child.id == 0x1654ae6b) {
          final tracks = _audioTrack(scan, child);
          declared = tracks.format;
          singleAudioTrack = tracks.singleAudioTrack;
          trackGroups++;
        } else if (child.id == 0x1549a966) {
          infoGroups++;
          var durationFields = 0;
          var scaleFields = 0;
          for (final field in _children(scan, child.payload, child.end)) {
            if (field.id == 0x4489) {
              durationTicks = _float(scan, field);
              durationFields++;
            }
            if (field.id == 0x2ad7b1) {
              timecodeScale = _uint(scan, field);
              scaleFields++;
            }
          }
          consistentInfo =
              consistentInfo && durationFields == 1 && scaleFields <= 1;
        } else if (child.id == 0x1f43b675) {
          // Read only the outer element's size. Artwork, tags, Cues and other
          // metadata are excluded; cluster payloads are never read or decoded.
          clusterBytes += child.end - child.payload;
        }
      }
      final format = declared;
      final durationNs = (durationTicks ?? 0) * timecodeScale;
      if (format != null &&
          trackGroups == 1 &&
          singleAudioTrack &&
          infoGroups == 1 &&
          consistentInfo &&
          timecodeScale > 0 &&
          durationNs.isFinite &&
          durationNs > 0 &&
          clusterBytes > 0) {
        // The cluster area includes a small amount of block framing. This is
        // the average encoded media rate, independent from embedded artwork.
        final bitrate = clusterBytes * 8 * 1000000000 / durationNs;
        if (bitrate.isFinite && bitrate >= 1 && bitrate <= 0x7fffffff) {
          return AudioFormatDetails(
            codec: format.codec,
            mimeType: format.mimeType,
            sampleRate: format.sampleRate,
            channels: format.channels,
            bitrate: bitrate.round(),
          );
        }
      }
      return format ?? container;
    }
  } on FormatException {
    // Recognized containers never fall through to a raw MPEG sync scan.
  }
  return declared ?? container;
}

({AudioFormatDetails? format, bool singleAudioTrack}) _audioTrack(
  _WebmScan reader,
  _WebmElement tracks,
) {
  AudioFormatDetails? result;
  var audioTracks = 0;
  var trackCount = 0;
  for (final entry in _children(reader, tracks.payload, tracks.end)) {
    if (entry.id != 0xae) continue;
    trackCount++;
    int? type;
    String? codec;
    int? sampleRate;
    var channels = 1; // Matroska's declared default when Channels is omitted.
    for (final field in _children(reader, entry.payload, entry.end)) {
      if (field.id == 0x83) type = _uint(reader, field);
      if (field.id == 0x86) codec = _text(reader, field);
      if (field.id == 0xe1) {
        for (final audio in _children(reader, field.payload, field.end)) {
          if (audio.id == 0xb5) sampleRate = _rate(reader, audio);
          if (audio.id == 0x9f) channels = _uint(reader, audio);
        }
      }
    }
    if (type != 2) continue;
    if (++audioTracks > 1) {
      return (format: null, singleAudioTrack: false);
    }
    final format = switch (codec) {
      'A_OPUS' => 'opus',
      'A_VORBIS' => 'vorbis',
      'A_AAC' => 'aac',
      'A_FLAC' => 'flac',
      'A_MPEG/L3' => 'mp3',
      'A_MPEG/L2' => 'mp2',
      'A_MPEG/L1' => 'mp1',
      _ => null,
    };
    result = AudioFormatDetails.fromMap({
      'codec': format,
      'mimeType': 'audio/webm',
      // Opus's coded timebase is always 48 kHz; input rates are advisory.
      'sampleRate': format == 'opus' ? 48000 : sampleRate,
      'channels': channels,
    });
  }
  return (
    format: result,
    singleAudioTrack: trackCount == 1 && audioTracks == 1,
  );
}

Iterable<_WebmElement> _children(_WebmScan reader, int offset, int end) sync* {
  while (offset < end) {
    final child = _element(reader, offset, end);
    if (child.unknownSize) {
      throw const FormatException('Unbounded EBML child');
    }
    yield child;
    offset = child.end;
  }
}

_WebmElement _element(_WebmScan reader, int offset, int end) {
  if (--reader.remainingElements < 0) {
    throw const FormatException('Too many EBML elements');
  }
  if (offset < 0 || offset >= end) {
    throw const FormatException('Missing EBML element');
  }
  final first = reader.read(offset, 1);
  if (first == null || first.isEmpty) {
    throw const FormatException('Truncated EBML element');
  }
  final idWidth = _width(first, 0, 4);
  if (offset + idWidth >= end) {
    throw const FormatException('Truncated EBML ID');
  }
  final prefix = reader.read(offset, idWidth + 1);
  if (prefix == null) throw const FormatException('Truncated EBML header');
  final sizeWidth = _width(prefix, idWidth, 8);
  if (offset + idWidth + sizeWidth > end) {
    throw const FormatException('Truncated EBML size');
  }
  final bytes = sizeWidth == 1
      ? prefix
      : reader.read(offset, idWidth + sizeWidth);
  if (bytes == null) throw const FormatException('Truncated EBML size');
  var id = 0;
  for (var index = 0; index < idWidth; index++) {
    id = id << 8 | bytes[index];
  }
  if (idWidth + sizeWidth > bytes.length) {
    throw const FormatException('Truncated EBML size');
  }
  var size = bytes[idWidth] & ((1 << (8 - sizeWidth)) - 1);
  for (var index = 1; index < sizeWidth; index++) {
    size = size << 8 | bytes[idWidth + index];
  }
  final unknown = size == (1 << (7 * sizeWidth)) - 1;
  final payload = offset + idWidth + sizeWidth;
  final elementEnd = unknown ? end : payload + size;
  if (elementEnd > end) throw const FormatException('Truncated EBML payload');
  return _WebmElement(id, payload, elementEnd, unknown);
}

int _width(Uint8List bytes, int offset, int maximum) {
  if (offset >= bytes.length) throw const FormatException('Missing EBML size');
  for (var width = 1; width <= maximum; width++) {
    if (bytes[offset] & (1 << (8 - width)) != 0) return width;
  }
  throw const FormatException('Invalid EBML integer');
}

String _text(_WebmScan reader, _WebmElement element) {
  final count = element.end - element.payload;
  if (count > 128) throw const FormatException('Oversized EBML string');
  final bytes = reader.read(element.payload, count);
  if (bytes == null) throw const FormatException('Truncated EBML string');
  return String.fromCharCodes(bytes);
}

int _uint(_WebmScan reader, _WebmElement element) {
  final count = element.end - element.payload;
  if (count < 1 || count > 8) {
    throw const FormatException('Invalid EBML integer');
  }
  final bytes = reader.read(element.payload, count);
  if (bytes == null) throw const FormatException('Truncated EBML integer');
  var result = 0;
  for (final byte in bytes) {
    result = result << 8 | byte;
  }
  return result;
}

double? _float(_WebmScan reader, _WebmElement element) {
  final count = element.end - element.payload;
  if (count != 4 && count != 8) return null;
  final bytes = reader.read(element.payload, count);
  if (bytes == null) return null;
  final data = ByteData.sublistView(bytes);
  final rate = count == 4 ? data.getFloat32(0) : data.getFloat64(0);
  return rate.isFinite && rate > 0 ? rate : null;
}

int? _rate(_WebmScan reader, _WebmElement element) {
  final rate = _float(reader, element);
  return rate != null && rate <= 0x7fffffff && rate == rate.round()
      ? rate.round()
      : null;
}

class _WebmScan {
  _WebmScan(this.reader);
  final AudioFormatHeaderReader reader;
  int remainingElements = 256;

  Uint8List? read(int offset, int count) => reader.read(offset, count);
}

class _WebmElement {
  const _WebmElement(this.id, this.payload, this.end, this.unknownSize);
  final int id;
  final int payload;
  final int end;
  final bool unknownSize;
}
