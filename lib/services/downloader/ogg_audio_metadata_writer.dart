import 'dart:io';
import 'dart:typed_data';

import 'atomic_audio_metadata_rewrite.dart';
import 'audio_metadata_fields.dart';
import 'vorbis_metadata_fields.dart';

const _maximumHeaderBytes = 8 * 1024 * 1024;
const _opusHead = [79, 112, 117, 115, 72, 101, 97, 100];
const _opusTags = [79, 112, 117, 115, 84, 97, 103, 115];
const _vorbisHead = [1, 118, 111, 114, 98, 105, 115];
const _vorbisTags = [3, 118, 111, 114, 98, 105, 115];

/// Replaces only the comment packet; encoded audio packets and their sample
/// positions remain unchanged. Single logical Opus/Vorbis streams are accepted.
AudioMetadataWriteResult writeOggAudioTags(File file, AudioMetadataTags tags) {
  Uint8List? expectedPacket;
  Uint8List? identification;
  Uint8List? finalPage;
  var finalPageOffset = 0;
  var expectedLength = 0;
  return rewriteAudioMetadataFile(
    file,
    rewrite: (input, output) {
      final header = _readHeader(input);
      final comments = Uint8List.sublistView(
        header.commentPacket,
        header.prefixLength,
      );
      final length = vorbisCommentsLength(comments);
      final trailing = Uint8List.sublistView(comments, length);
      if (!header.opus && (trailing.length != 1 || trailing.single & 1 != 1)) {
        throw const FormatException('Invalid Vorbis comment framing');
      }
      final edited = updateVorbisComments(
        Uint8List.sublistView(comments, 0, length),
        tags,
        embedPicture: true,
      );
      final replacement =
          (BytesBuilder(copy: false)
                ..add(header.opus ? _opusTags : _vorbisTags)
                ..add(edited)
                ..add(trailing))
              .takeBytes();
      if (replacement.length > _maximumHeaderBytes) {
        throw const FormatException('Oversized Ogg comment packet');
      }
      if (_sameBytes(replacement, header.commentPacket)) {
        return AudioMetadataWriteResult.unchanged;
      }
      expectedPacket = replacement;
      identification = header.first.bytes;
      var sequence = 0;
      void emit(Uint8List bytes) {
        finalPageOffset = output.positionSync();
        output.writeFromSync(bytes);
        finalPage = bytes;
        sequence++;
      }

      emit(header.first.bytes);
      for (final bytes in _packetPages(
        replacement,
        serial: header.first.serial,
        firstSequence: sequence,
      )) {
        emit(bytes);
      }
      // A setup or audio packet may share the original comment's last page.
      // Give that suffix its own page, retaining its original sample position.
      final suffix = header.suffixSegments;
      if (suffix.isNotEmpty) {
        emit(
          _pageBytes(
            flags: header.last.flags & ~1,
            granule: header.last.granule,
            serial: header.first.serial,
            sequence: sequence,
            segments: suffix,
            payload: header.suffixPayload,
          ),
        );
      }
      while (input.positionSync() < input.lengthSync()) {
        final page = _readPage(input);
        header.stream.accept(page);
        if (sequence > 0xffffffff) {
          throw const FormatException('Ogg page sequence overflow');
        }
        final bytes = page.bytes;
        ByteData.sublistView(bytes).setUint32(18, sequence, Endian.little);
        _setChecksum(bytes);
        emit(bytes);
      }
      header.stream.finish(minimumPackets: header.opus ? 3 : 4);
      expectedLength = output.positionSync();
      return AudioMetadataWriteResult.written;
    },
    validate: (candidate) {
      if (candidate.lengthSync() != expectedLength) return false;
      final input = candidate.openSync();
      try {
        final header = _readHeader(input);
        if (!_sameBytes(header.first.bytes, identification!) ||
            !_sameBytes(header.commentPacket, expectedPacket!)) {
          return false;
        }
        input.setPositionSync(finalPageOffset);
        final last = _readPage(input);
        return _sameBytes(last.bytes, finalPage!) &&
            last.flags & 4 != 0 &&
            input.positionSync() == expectedLength;
      } finally {
        input.closeSync();
      }
    },
  );
}

_Header _readHeader(RandomAccessFile input) {
  input.setPositionSync(0);
  final first = _readPage(input);
  final stream = _Stream();
  stream.accept(first);
  if (first.flags != 2 ||
      first.granule != 0 ||
      first.segments.last == 255 ||
      first.segments.where((value) => value < 255).length != 1) {
    throw const FormatException('Unsupported Ogg identification page');
  }
  final payload = first.payload;
  final opus = _startsWith(payload, _opusHead);
  if (opus) {
    if (payload.length < 19 ||
        payload[8] < 1 ||
        payload[8] > 15 ||
        payload[9] == 0 ||
        (payload[18] == 0 && (payload.length != 19 || payload[9] > 2))) {
      throw const FormatException('Invalid Opus identification packet');
    }
  } else if (!_startsWith(payload, _vorbisHead) ||
      payload.length != 30 ||
      ByteData.sublistView(payload).getUint32(7, Endian.little) != 0 ||
      payload[11] == 0 ||
      ByteData.sublistView(payload).getUint32(12, Endian.little) == 0 ||
      payload[29] & 1 != 1) {
    throw const FormatException('Unsupported Ogg codec');
  }
  final packet = BytesBuilder(copy: false);
  var packetLength = 0;
  while (input.positionSync() < input.lengthSync()) {
    final page = _readPage(input);
    stream.accept(page);
    var count = 0;
    var consumed = 0;
    var completed = false;
    for (final segment in page.segments) {
      count++;
      consumed += segment;
      if (segment < 255) {
        completed = true;
        break;
      }
    }
    packetLength += consumed;
    if (packetLength > _maximumHeaderBytes) {
      throw const FormatException('Oversized Ogg header');
    }
    packet.add(Uint8List.sublistView(page.payload, 0, consumed));
    if (!completed) {
      if (page.granule != -1 || page.flags & 4 != 0) {
        throw const FormatException('Invalid continued comment packet');
      }
      continue;
    }
    final bytes = packet.takeBytes();
    final prefix = opus ? _opusTags : _vorbisTags;
    if (!_startsWith(bytes, prefix)) {
      throw const FormatException('Missing Ogg comment header');
    }
    final suffix = Uint8List.sublistView(page.segments, count);
    if (suffix.isEmpty && (page.granule != 0 || page.flags & 4 != 0)) {
      throw const FormatException('Invalid comment-only page');
    }
    return _Header(
      first: first,
      last: page,
      stream: stream,
      opus: opus,
      prefixLength: prefix.length,
      commentPacket: bytes,
      suffixSegments: suffix,
      suffixPayload: Uint8List.sublistView(page.payload, consumed),
    );
  }
  throw const FormatException('Incomplete Ogg comment packet');
}

class _Header {
  const _Header({
    required this.first,
    required this.last,
    required this.stream,
    required this.opus,
    required this.prefixLength,
    required this.commentPacket,
    required this.suffixSegments,
    required this.suffixPayload,
  });

  final _Page first;
  final _Page last;
  final _Stream stream;
  final bool opus;
  final int prefixLength;
  final Uint8List commentPacket;
  final Uint8List suffixSegments;
  final Uint8List suffixPayload;
}

class _Stream {
  int? serial;
  int sequence = 0;
  int packets = 0;
  bool continued = false;
  bool ended = false;

  void accept(_Page page) {
    if (ended ||
        page.sequence != sequence ||
        (serial != null && page.serial != serial) ||
        (page.flags & 2 != 0) != (serial == null) ||
        (page.flags & 1 != 0) != continued) {
      throw const FormatException('Unsupported Ogg stream layout');
    }
    serial ??= page.serial;
    sequence++;
    packets += page.segments.where((value) => value < 255).length;
    continued = page.segments.last == 255;
    ended = page.flags & 4 != 0;
    if (ended && (continued || page.granule < 0)) {
      throw const FormatException('Invalid Ogg end page');
    }
  }

  void finish({required int minimumPackets}) {
    if (!ended || continued || packets < minimumPackets) {
      throw const FormatException('Incomplete Ogg audio stream');
    }
  }
}

class _Page {
  const _Page(this.bytes, this.segmentCount);

  final Uint8List bytes;
  final int segmentCount;

  int get flags => bytes[5];
  int get granule => ByteData.sublistView(bytes).getInt64(6, Endian.little);
  int get serial => ByteData.sublistView(bytes).getUint32(14, Endian.little);
  int get sequence => ByteData.sublistView(bytes).getUint32(18, Endian.little);
  Uint8List get segments => Uint8List.sublistView(bytes, 27, 27 + segmentCount);
  Uint8List get payload => Uint8List.sublistView(bytes, 27 + segmentCount);
}

_Page _readPage(RandomAccessFile input) {
  final header = input.readSync(27);
  if (header.length != 27 ||
      !_startsWith(header, const [79, 103, 103, 83]) ||
      header[4] != 0 ||
      header[5] & ~7 != 0 ||
      header[26] == 0) {
    throw const FormatException('Invalid Ogg page header');
  }
  final segments = input.readSync(header[26]);
  if (segments.length != header[26]) {
    throw const FormatException('Truncated Ogg lacing table');
  }
  var length = 0;
  for (final segment in segments) {
    length += segment;
  }
  final payload = input.readSync(length);
  if (payload.length != length) {
    throw const FormatException('Truncated Ogg page');
  }
  final bytes =
      (BytesBuilder(copy: false)
            ..add(header)
            ..add(segments)
            ..add(payload))
          .takeBytes();
  final data = ByteData.sublistView(bytes);
  final expected = data.getUint32(22, Endian.little);
  data.setUint32(22, 0, Endian.little);
  final actual = _checksum(bytes);
  data.setUint32(22, expected, Endian.little);
  if (actual != expected) throw const FormatException('Invalid Ogg checksum');
  return _Page(bytes, segments.length);
}

Iterable<Uint8List> _packetPages(
  Uint8List packet, {
  required int serial,
  required int firstSequence,
}) sync* {
  var offset = 0;
  var sequence = firstSequence;
  var continued = false;
  var finished = false;
  while (!finished) {
    final start = offset;
    final segments = <int>[];
    while (segments.length < 255) {
      final remaining = packet.length - offset;
      if (remaining < 255) {
        segments.add(remaining);
        offset += remaining;
        finished = true;
        break;
      }
      segments.add(255);
      offset += 255;
    }
    yield _pageBytes(
      flags: continued ? 1 : 0,
      granule: finished ? 0 : -1,
      serial: serial,
      sequence: sequence++,
      segments: segments,
      payload: Uint8List.sublistView(packet, start, offset),
    );
    continued = true;
  }
}

Uint8List _pageBytes({
  required int flags,
  required int granule,
  required int serial,
  required int sequence,
  required List<int> segments,
  required Uint8List payload,
}) {
  final bytes = Uint8List(27 + segments.length + payload.length);
  bytes.setRange(0, 4, const [79, 103, 103, 83]);
  bytes[5] = flags;
  final data = ByteData.sublistView(bytes)
    ..setInt64(6, granule, Endian.little)
    ..setUint32(14, serial, Endian.little)
    ..setUint32(18, sequence, Endian.little);
  bytes[26] = segments.length;
  bytes.setRange(27, 27 + segments.length, segments);
  bytes.setRange(27 + segments.length, bytes.length, payload);
  data.setUint32(22, _checksum(bytes), Endian.little);
  return bytes;
}

void _setChecksum(Uint8List bytes) {
  final data = ByteData.sublistView(bytes)..setUint32(22, 0, Endian.little);
  data.setUint32(22, _checksum(bytes), Endian.little);
}

final _crcTable = Uint32List.fromList(
  List.generate(256, (index) {
    var value = index << 24;
    for (var bit = 0; bit < 8; bit++) {
      value =
          ((value << 1) ^ ((value & 0x80000000 != 0) ? 0x04c11db7 : 0)) &
          0xffffffff;
    }
    return value;
  }),
);

int _checksum(Uint8List bytes) {
  var value = 0;
  for (final byte in bytes) {
    value =
        ((value << 8) ^ _crcTable[((value >> 24) ^ byte) & 0xff]) & 0xffffffff;
  }
  return value;
}

bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}
