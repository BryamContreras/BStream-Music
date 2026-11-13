import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'atomic_audio_metadata_rewrite.dart';
import 'audio_metadata_fields.dart';
import 'vorbis_metadata_fields.dart';

const _maximumMetadata = 8 * 1024 * 1024;
const _maximumEntries = 4096;

/// Writes metadata without decoding audio or loading it into memory. Existing
/// unrelated ID3 frames, FLAC blocks, RIFF chunks and APE items are preserved.
/// Unsupported legacy/ambiguous layouts are left intact by the shared commit.
AudioMetadataWriteResult writeStandardAudioTags(
  File file,
  AudioMetadataTags tags,
) => rewriteAudioMetadataFile(
  file,
  rewrite: (input, output) {
    final plan = _plan(input, tags);
    if (plan == null) return AudioMetadataWriteResult.unsupported;
    if (!plan.changed(input)) return AudioMetadataWriteResult.unchanged;
    plan.write(input, output);
    return AudioMetadataWriteResult.written;
  },
  validate: (candidate) {
    final input = candidate.openSync();
    try {
      final plan = _plan(input, tags);
      return plan != null && !plan.changed(input);
    } on FormatException {
      return false;
    } finally {
      input.closeSync();
    }
  },
);

_Plan? _plan(RandomAccessFile input, AudioMetadataTags tags) {
  if (input.lengthSync() < 12) return null;
  final signature = _read(input, 0, 12);
  if (_ascii(signature, 0, 4) == 'fLaC') return _flac(input, tags);
  if (_ascii(signature, 0, 4) == 'RIFF' && _ascii(signature, 8, 4) == 'WAVE') {
    return _wave(input, tags);
  }
  if (_ascii(signature, 0, 4) == 'MAC ') return _ape(input, tags);
  if (_ascii(signature, 0, 3) == 'ID3' ||
      _mpegFrameLength(signature) != null ||
      signature.first == 0) {
    return _mp3(input, tags);
  }
  return null;
}

_Plan _mp3(RandomAccessFile input, AudioMetadataTags tags) {
  var offset = 0;
  var old = Uint8List(0);
  final header = _read(input, 0, 10);
  if (_ascii(header, 0, 3) == 'ID3') {
    final length = 10 + _synchsafe(header, 6);
    old = _read(input, 0, length);
    offset = length;
  }
  // Some encoders leave a small zero-filled prefix between ID3 and audio, or
  // before an untagged MPEG stream. Keep that prefix byte-for-byte.
  final prefixLength = (input.lengthSync() - offset).clamp(0, 64 * 1024);
  final prefix = _read(input, offset, prefixLength);
  var audioOffset = offset;
  while (audioOffset - offset < prefix.length &&
      prefix[audioOffset - offset] == 0) {
    audioOffset++;
  }
  final frame = _read(input, audioOffset, 4);
  final frameLength = _mpegFrameLength(frame);
  if (frameLength == null || audioOffset + frameLength > input.lengthSync()) {
    throw const FormatException('Missing MPEG audio after ID3');
  }
  // A second compatible frame rejects false positives from an arbitrary file
  // whose first four bytes happen to resemble an MPEG synchronization word.
  if (audioOffset + frameLength + 4 > input.lengthSync() ||
      _mpegFrameLength(_read(input, audioOffset + frameLength, 4)) == null) {
    throw const FormatException('Missing second MPEG frame');
  }
  return _Plan([_Patch(0, offset, _id3(old, tags))]);
}

int? _mpegFrameLength(Uint8List header) {
  if (header.length < 4 || header[0] != 0xff || (header[1] & 0xe0) != 0xe0) {
    return null;
  }
  final version = (header[1] >> 3) & 3;
  final layer = (header[1] >> 1) & 3;
  final bitrateIndex = header[2] >> 4;
  final rateIndex = (header[2] >> 2) & 3;
  if (version == 1 ||
      layer == 0 ||
      bitrateIndex == 0 ||
      bitrateIndex == 15 ||
      rateIndex == 3) {
    return null;
  }
  final rate =
      const [44100, 48000, 32000][rateIndex] >>
      (version == 3 ? 0 : (version == 2 ? 1 : 2));
  final table = version == 3
      ? switch (layer) {
          3 => const [
            0,
            32,
            64,
            96,
            128,
            160,
            192,
            224,
            256,
            288,
            320,
            352,
            384,
            416,
            448,
          ],
          2 => const [
            0,
            32,
            48,
            56,
            64,
            80,
            96,
            112,
            128,
            160,
            192,
            224,
            256,
            320,
            384,
          ],
          _ => const [
            0,
            32,
            40,
            48,
            56,
            64,
            80,
            96,
            112,
            128,
            160,
            192,
            224,
            256,
            320,
          ],
        }
      : (layer == 3
            ? const [
                0,
                32,
                48,
                56,
                64,
                80,
                96,
                112,
                128,
                144,
                160,
                176,
                192,
                224,
                256,
              ]
            : const [
                0,
                8,
                16,
                24,
                32,
                40,
                48,
                56,
                64,
                80,
                96,
                112,
                128,
                144,
                160,
              ]);
  final bitrate = table[bitrateIndex] * 1000;
  final padding = (header[2] >> 1) & 1;
  if (layer == 3) return (12 * bitrate ~/ rate + padding) * 4;
  return (version != 3 && layer == 1 ? 72 : 144) * bitrate ~/ rate + padding;
}

/// Reuses the same ID3 material for MPEG audio and the standard WAVE ID3 chunk.
/// Existing v2.3 tags stay v2.3, preserving their unknown frames verbatim.
Uint8List _id3(Uint8List existing, AudioMetadataTags tags) {
  var version = 4;
  final frames = <({String id, Uint8List bytes, Uint8List payload})>[];
  if (existing.isNotEmpty) {
    if (existing.length < 10 || _ascii(existing, 0, 3) != 'ID3') {
      throw const FormatException('Invalid ID3 header');
    }
    version = existing[3];
    if ((version != 3 && version != 4) ||
        existing[4] != 0 ||
        existing[5] != 0) {
      throw const FormatException('Unsupported ID3 flags or version');
    }
    final end = 10 + _synchsafe(existing, 6);
    if (end > existing.length || existing.length > _maximumMetadata) {
      throw const FormatException('Invalid ID3 extent');
    }
    var cursor = 10;
    while (cursor < end && existing[cursor] != 0) {
      if (frames.length >= _maximumEntries || cursor + 10 > end) {
        throw const FormatException('Invalid ID3 frame table');
      }
      final id = _ascii(existing, cursor, 4);
      if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(id)) {
        throw const FormatException('Invalid ID3 frame ID');
      }
      final length = version == 4
          ? _synchsafe(existing, cursor + 4)
          : _u32(existing, cursor + 4);
      // Frame-level encryption/compression/unsynchronization cannot be safely
      // edited without decoding that frame; leave those uncommon tags intact.
      if (length == 0 ||
          cursor + 10 + length > end ||
          existing[cursor + 9] != 0) {
        throw const FormatException('Unsupported ID3 frame encoding');
      }
      frames.add((
        id: id,
        bytes: Uint8List.sublistView(existing, cursor, cursor + 10 + length),
        payload: Uint8List.sublistView(
          existing,
          cursor + 10,
          cursor + 10 + length,
        ),
      ));
      cursor += 10 + length;
    }
    if (existing.sublist(cursor).any((byte) => byte != 0)) {
      throw const FormatException('Non-padding bytes after ID3 frames');
    }
  }
  final body = BytesBuilder(copy: false);
  final album = tags.album?.trim();
  for (final frame in frames) {
    if (frame.id == 'TIT2' ||
        frame.id == 'TPE1' ||
        (frame.id == 'TALB' && album != null && album.isNotEmpty) ||
        (frame.id == 'APIC' &&
            tags.artworkBytes != null &&
            _frontPicture(frame.payload))) {
      continue;
    }
    body.add(frame.bytes);
  }
  void text(String id, String value) {
    final encoded = version == 4
        ? Uint8List.fromList([3, ...utf8.encode(value)])
        : _utf16(value);
    body.add(_id3Frame(id, encoded, version));
  }

  text('TIT2', tags.title);
  text('TPE1', tags.artist);
  if (album != null && album.isNotEmpty) text('TALB', album);
  if (tags.artworkBytes != null) {
    final payload = BytesBuilder(copy: false)
      ..addByte(0)
      ..add(ascii.encode(tags.artworkMimeType!))
      ..add([0, 3, 0])
      ..add(tags.artworkBytes!);
    body.add(_id3Frame('APIC', payload.takeBytes(), version));
  }
  final bytes = body.takeBytes();
  if (bytes.length + 10 > _maximumMetadata) {
    throw const FormatException('ID3 metadata exceeds limit');
  }
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    version,
    0,
    0,
    ..._syncBytes(bytes.length),
    ...bytes,
  ]);
}

bool _frontPicture(Uint8List payload) {
  if (payload.length < 4) throw const FormatException('Invalid APIC');
  final mimeEnd = payload.indexOf(0, 1);
  if (mimeEnd < 0 || mimeEnd + 1 >= payload.length) {
    throw const FormatException('Invalid APIC MIME');
  }
  return payload[mimeEnd + 1] == 3;
}

Uint8List _utf16(String value) {
  final output = ByteData((value.codeUnits.length + 1) * 2 + 1);
  output.setUint8(0, 1);
  output.setUint16(1, 0xfeff, Endian.little);
  for (var i = 0; i < value.codeUnits.length; i++) {
    output.setUint16(3 + 2 * i, value.codeUnitAt(i), Endian.little);
  }
  return output.buffer.asUint8List();
}

Uint8List _id3Frame(String id, Uint8List payload, int version) =>
    Uint8List.fromList([
      ...ascii.encode(id),
      ...(version == 4 ? _syncBytes(payload.length) : _uint32(payload.length)),
      0,
      0,
      ...payload,
    ]);

_Plan _flac(RandomAccessFile input, AudioMetadataTags tags) {
  final blocks = <({int type, Uint8List data})>[];
  var cursor = 4;
  var commentSeen = false;
  var last = false;
  var existingComments = Uint8List(0);
  while (!last) {
    if (cursor > _maximumMetadata || blocks.length >= _maximumEntries) {
      throw const FormatException('FLAC metadata exceeds limit');
    }
    final header = _read(input, cursor, 4);
    final type = header[0] & 0x7f;
    final length = (header[1] << 16) | (header[2] << 8) | header[3];
    last = (header[0] & 0x80) != 0;
    if (cursor + 4 + length > _maximumMetadata ||
        type == 127 ||
        (blocks.isEmpty && (type != 0 || length != 34)) ||
        (blocks.isNotEmpty && type == 0)) {
      throw const FormatException('Invalid FLAC block');
    }
    final data = _read(input, cursor + 4, length);
    if (type == 4) {
      if (commentSeen) throw const FormatException('Duplicate FLAC comments');
      existingComments = data;
      commentSeen = true;
    }
    blocks.add((type: type, data: data));
    cursor += 4 + length;
  }
  if (cursor >= input.lengthSync()) {
    throw const FormatException('Missing FLAC audio');
  }
  final stream = ByteData.sublistView(blocks.first.data);
  final packed = stream.getUint64(10);
  if ((packed >> 44) == 0) {
    throw const FormatException('Invalid FLAC sample rate');
  }
  final comments = updateVorbisComments(existingComments, tags);
  final updated = <({int type, Uint8List data})>[];
  for (final block in blocks) {
    if (block.type == 4) continue;
    if (block.type == 6 && tags.artworkBytes != null) {
      if (block.data.length < 4) {
        throw const FormatException('Invalid FLAC picture');
      }
      if (_u32(block.data, 0) == 3) continue;
    }
    updated.add(block);
  }
  updated.add((type: 4, data: comments));
  if (tags.artworkBytes != null) {
    updated.add((type: 6, data: encodeFlacPicture(tags)));
  }
  final result = BytesBuilder(copy: false)..add(ascii.encode('fLaC'));
  for (var i = 0; i < updated.length; i++) {
    final block = updated[i];
    result.add([
      block.type | (i == updated.length - 1 ? 0x80 : 0),
      (block.data.length >> 16) & 0xff,
      (block.data.length >> 8) & 0xff,
      block.data.length & 0xff,
    ]);
    result.add(block.data);
  }
  return _Plan([_Patch(0, cursor, result.takeBytes())]);
}

_Plan _wave(RandomAccessFile input, AudioMetadataTags tags) {
  final length = input.lengthSync();
  if (_u32(_read(input, 4, 4), 0, little: true) + 8 != length) {
    throw const FormatException('Unsupported RIFF extent');
  }
  var cursor = 12;
  var count = 0;
  var formatSeen = false;
  var audioSeen = false;
  var oldId3 = Uint8List(0);
  _Patch? removeId3;
  while (cursor < length) {
    if (count++ >= _maximumEntries) {
      throw const FormatException('Too many RIFF chunks');
    }
    final header = _read(input, cursor, 8);
    final id = _ascii(header, 0, 4);
    final size = _u32(header, 4, little: true);
    final end = cursor + 8 + size + (size & 1);
    if (end > length) throw const FormatException('Truncated RIFF chunk');
    if (id == 'fmt ') {
      if (formatSeen || size < 16) {
        throw const FormatException('Invalid WAVE format');
      }
      final format = ByteData.sublistView(_read(input, cursor + 8, 16));
      final codec = format.getUint16(0, Endian.little);
      if (![1, 3, 0xfffe].contains(codec) ||
          format.getUint16(2, Endian.little) == 0 ||
          format.getUint32(4, Endian.little) == 0 ||
          format.getUint16(12, Endian.little) == 0 ||
          (codec == 0xfffe && size < 40)) {
        throw const FormatException('Unsupported WAVE encoding');
      }
      formatSeen = true;
    } else if (id == 'data') {
      if (audioSeen || size == 0) {
        throw const FormatException('Ambiguous WAVE audio');
      }
      audioSeen = true;
    } else if (id == 'ID3 ' || id == 'id3 ') {
      if (removeId3 != null) {
        throw const FormatException('Duplicate WAVE ID3 chunks');
      }
      oldId3 = _read(input, cursor + 8, size);
      removeId3 = _Patch(cursor, end, Uint8List(0));
    }
    cursor = end;
  }
  if (!formatSeen || !audioSeen) {
    throw const FormatException('Missing WAVE audio');
  }
  final id3 = _id3(oldId3, tags);
  final chunk = Uint8List.fromList([
    ...ascii.encode('id3 '),
    ..._uint32(id3.length, little: true),
    ...id3,
    if (id3.length.isOdd) 0,
  ]);
  // Place ID3 last so Unicode values are authoritative if legacy LIST/INFO
  // chunks coexist. Keep those chunks (including unknown fields) untouched.
  if (removeId3 != null && removeId3.end == length) {
    final newLength = length - (removeId3.end - removeId3.start) + chunk.length;
    if (newLength > 0xffffffff + 8) {
      throw const FormatException('RIFF overflow');
    }
    return _Plan([
      _Patch(4, 8, _uint32(newLength - 8, little: true)),
      _Patch(removeId3.start, removeId3.end, chunk),
    ]);
  }
  final newLength =
      length +
      chunk.length -
      (removeId3 == null ? 0 : removeId3.end - removeId3.start);
  if (newLength > 0xffffffff + 8) throw const FormatException('RIFF overflow');
  return _Plan([
    _Patch(4, 8, _uint32(newLength - 8, little: true)),
    ?removeId3,
    _Patch(length, length, chunk),
  ]);
}

_Plan _ape(RandomAccessFile input, AudioMetadataTags tags) {
  final length = input.lengthSync();
  var tagEnd = length;
  if (length >= 128 && _ascii(_read(input, length - 128, 3), 0, 3) == 'TAG') {
    tagEnd -= 128;
  }
  var tagStart = tagEnd;
  final items = <({String key, Uint8List bytes})>[];
  if (tagEnd >= 32 &&
      _ascii(_read(input, tagEnd - 32, 8), 0, 8) == 'APETAGEX') {
    final footer = _read(input, tagEnd - 32, 32);
    final version = _u32(footer, 8, little: true);
    final size = _u32(footer, 12, little: true);
    final count = _u32(footer, 16, little: true);
    final flags = _u32(footer, 20, little: true);
    if ((version != 1000 && version != 2000) ||
        size < 32 ||
        size > _maximumMetadata ||
        size > tagEnd ||
        count > _maximumEntries ||
        (flags & 0x7fffffff) != 0) {
      throw const FormatException('Unsupported APEv2 footer');
    }
    tagStart = tagEnd - size;
    final data = _read(input, tagStart, size - 32);
    var cursor = 0;
    for (var i = 0; i < count; i++) {
      if (cursor + 10 > data.length) {
        throw const FormatException('Truncated APE item');
      }
      final valueLength = _u32(data, cursor, little: true);
      final keyEnd = data.indexOf(0, cursor + 8);
      if (keyEnd < cursor + 10 ||
          keyEnd > cursor + 8 + 255 ||
          keyEnd + 1 + valueLength > data.length) {
        throw const FormatException('Invalid APE item extent');
      }
      final keyBytes = Uint8List.sublistView(data, cursor + 8, keyEnd);
      if (keyBytes.any((byte) => byte < 0x20 || byte > 0x7e)) {
        throw const FormatException('Invalid APE key');
      }
      final end = keyEnd + 1 + valueLength;
      var itemBytes = Uint8List.sublistView(data, cursor, end);
      if (version == 1000 && (_u32(data, cursor + 4, little: true) & 6) == 0) {
        try {
          utf8.decode(Uint8List.sublistView(data, keyEnd + 1, end));
        } on FormatException {
          // APEv1 permits legacy byte strings (for example Genre=0xff).
          // APEv2 text must be UTF-8. Preserve such values byte-for-byte as
          // binary rather than publishing an invalid tag or guessing a locale.
          itemBytes = Uint8List.fromList(itemBytes);
          ByteData.sublistView(itemBytes).setUint32(
            4,
            (_u32(itemBytes, 4, little: true) & ~6) | 2,
            Endian.little,
          );
        }
      }
      items.add((key: ascii.decode(keyBytes), bytes: itemBytes));
      cursor = end;
    }
    if (cursor != data.length) {
      throw const FormatException('Unexpected APE tag bytes');
    }
    if ((flags & 0x80000000) != 0) {
      if (tagStart < 32) throw const FormatException('Missing APE header');
      final header = _read(input, tagStart - 32, 32);
      if (_ascii(header, 0, 8) != 'APETAGEX' ||
          _u32(header, 8, little: true) != version ||
          _u32(header, 12, little: true) != size ||
          _u32(header, 16, little: true) != count ||
          _u32(header, 20, little: true) != 0xa0000000) {
        throw const FormatException('Invalid APE header');
      }
      tagStart -= 32;
    }
  }
  _validateApeAudio(input, tagStart);
  final output = BytesBuilder(copy: false);
  var count = 0;
  final album = tags.album?.trim();
  for (final item in items) {
    final key = item.key.toUpperCase();
    if (key == 'TITLE' ||
        key == 'ARTIST' ||
        (key == 'ALBUM' && album != null && album.isNotEmpty) ||
        (key == 'COVER ART (FRONT)' && tags.artworkBytes != null)) {
      continue;
    }
    output.add(item.bytes);
    count++;
  }
  void add(String key, List<int> value, {int flags = 0}) {
    output.add(_uint32(value.length, little: true));
    output.add(_uint32(flags, little: true));
    output.add(ascii.encode(key));
    output.addByte(0);
    output.add(value);
    count++;
  }

  add('TITLE', utf8.encode(tags.title));
  add('ARTIST', utf8.encode(tags.artist));
  if (album != null && album.isNotEmpty) add('ALBUM', utf8.encode(album));
  if (tags.artworkBytes != null) {
    add('Cover Art (Front)', [
      ...ascii.encode(
        tags.artworkMimeType == 'image/png' ? 'cover.png' : 'cover.jpg',
      ),
      0,
      ...tags.artworkBytes!,
    ], flags: 2);
  }
  if (output.length + 32 > _maximumMetadata) {
    throw const FormatException('APE metadata exceeds limit');
  }
  final size = output.length + 32;
  output.add(ascii.encode('APETAGEX'));
  output.add(_uint32(2000, little: true));
  output.add(_uint32(size, little: true));
  output.add(_uint32(count, little: true));
  output.add(Uint8List(12));
  return _Plan([_Patch(tagStart, tagEnd, output.takeBytes())]);
}

void _validateApeAudio(RandomAccessFile input, int audioEnd) {
  final descriptor = _read(input, 0, 52);
  final data = ByteData.sublistView(descriptor);
  final version = data.getUint16(4, Endian.little);
  if (version >= 3800 && version < 3980) {
    final flags = data.getUint16(8, Endian.little);
    final frames = data.getUint32(24, Endian.little);
    var headerLength = 32 + ((flags & 4) != 0 ? 4 : 0);
    var seekBytes = frames * 4;
    if ((flags & 16) != 0) {
      seekBytes = _u32(_read(input, headerLength, 4), 0, little: true) * 4;
      headerLength += 4;
    }
    final start = headerLength + seekBytes + data.getUint32(16, Endian.little);
    if (frames == 0 ||
        data.getUint16(10, Endian.little) == 0 ||
        data.getUint32(12, Endian.little) == 0 ||
        seekBytes < frames * 4 ||
        start >= audioEnd ||
        start + data.getUint32(20, Endian.little) >= audioEnd) {
      throw const FormatException('Invalid legacy Monkey audio');
    }
    return;
  }
  final descriptorLength = data.getUint32(8, Endian.little);
  final headerLength = data.getUint32(12, Endian.little);
  if (version < 3980 ||
      version > 3990 ||
      descriptorLength < 52 ||
      headerLength < 24 ||
      descriptorLength + headerLength > audioEnd) {
    throw const FormatException('Unsupported Monkey audio descriptor');
  }
  final audioStart =
      descriptorLength +
      headerLength +
      data.getUint32(16, Endian.little) +
      data.getUint32(20, Endian.little);
  final audioSize =
      data.getUint32(24, Endian.little) +
      (data.getUint32(28, Endian.little) << 32);
  if (audioStart >= audioEnd ||
      audioSize == 0 ||
      audioStart + audioSize + data.getUint32(32, Endian.little) > audioEnd) {
    throw const FormatException('Truncated Monkey audio frames');
  }
  final header = ByteData.sublistView(_read(input, descriptorLength, 24));
  if (header.getUint32(4, Endian.little) == 0 ||
      header.getUint32(12, Endian.little) == 0 ||
      header.getUint16(18, Endian.little) == 0 ||
      header.getUint32(20, Endian.little) == 0) {
    throw const FormatException('Invalid Monkey audio format');
  }
}

class _Patch {
  const _Patch(this.start, this.end, this.bytes);
  final int start;
  final int end;
  final Uint8List bytes;
}

class _Plan {
  const _Plan(this.patches);
  final List<_Patch> patches;

  bool changed(RandomAccessFile input) {
    for (final patch in patches) {
      if (patch.end - patch.start != patch.bytes.length ||
          !_equal(_read(input, patch.start, patch.bytes.length), patch.bytes)) {
        return true;
      }
    }
    return false;
  }

  void write(RandomAccessFile input, RandomAccessFile output) {
    var cursor = 0;
    for (final patch in patches) {
      if (patch.start < cursor || patch.end < patch.start) {
        throw const FormatException('Invalid metadata patch');
      }
      copyAudioMetadataRange(
        input,
        output,
        start: cursor,
        length: patch.start - cursor,
      );
      output.writeFromSync(patch.bytes);
      cursor = patch.end;
    }
    copyAudioMetadataRange(
      input,
      output,
      start: cursor,
      length: input.lengthSync() - cursor,
    );
  }
}

Uint8List _read(RandomAccessFile input, int start, int length) {
  if (start < 0 ||
      length < 0 ||
      length > _maximumMetadata ||
      start + length > input.lengthSync()) {
    throw const FormatException('Invalid bounded metadata range');
  }
  input.setPositionSync(start);
  final bytes = input.readSync(length);
  if (bytes.length != length) throw const FormatException('Truncated metadata');
  return bytes;
}

String _ascii(Uint8List bytes, int offset, int length) =>
    String.fromCharCodes(Uint8List.sublistView(bytes, offset, offset + length));

int _u32(Uint8List bytes, int offset, {bool little = false}) =>
    ByteData.sublistView(
      bytes,
    ).getUint32(offset, little ? Endian.little : Endian.big);

Uint8List _uint32(int value, {bool little = false}) =>
    (ByteData(4)..setUint32(0, value, little ? Endian.little : Endian.big))
        .buffer
        .asUint8List();

int _synchsafe(Uint8List bytes, int offset) {
  var result = 0;
  for (var i = 0; i < 4; i++) {
    final value = bytes[offset + i];
    if (value > 127) throw const FormatException('Invalid synchsafe integer');
    result = (result << 7) | value;
  }
  return result;
}

List<int> _syncBytes(int value) => [
  (value >> 21) & 127,
  (value >> 14) & 127,
  (value >> 7) & 127,
  value & 127,
];

bool _equal(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}
