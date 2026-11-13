import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'atomic_audio_metadata_rewrite.dart';
import 'audio_metadata_fields.dart';

const _ebml = 0x1a45dfa3;
const _segment = 0x18538067;
const _seekHead = 0x114d9b74;
const _tracks = 0x1654ae6b;
const _cluster = 0x1f43b675;
const _tags = 0x1254c367;
const _void = 0xec;
const _crc = 0xbf;
const _tag = 0x7373;
const _targets = 0x63c0;
const _simpleTag = 0x67c8;
const _maximumMetadataBytes = 8 * 1024 * 1024;
const _maximumElements = 1000000;
const _segmentChildren = {
  _seekHead,
  0x1549a966, // Info
  _tracks,
  _cluster,
  0x1c53bb6b, // Cues
  0x1941a469, // Attachments (preserved in existing Matroska only).
  0x1043a770, // Chapters
  _tags,
};

/// Adds text tags to an audio-only WebM/Matroska stream without moving clusters.
///
/// Existing indexes retain their media offsets. Superseded tag slots become
/// Void elements and a trailing tag slot is reused. WebM does not standardize
/// cover attachments, so artwork stays in the app's separate cached image.
AudioMetadataWriteResult writeWebmAudioTags(File file, AudioMetadataTags tags) {
  _Layout? original;
  Uint8List? expectedTags;
  var expectedLength = 0;
  return rewriteAudioMetadataFile(
    file,
    rewrite: (input, output) {
      final layout = _inspect(input);
      original = layout;
      final edits = <String, String>{};
      for (final field in {
        'TITLE': tags.title,
        'ARTIST': tags.artist,
        'ALBUM': tags.album,
      }.entries) {
        final value = field.value?.trim();
        if (value == null || value.isEmpty) continue;
        if (utf8.encode(value).length > 65536) {
          throw const FormatException('Oversized WebM text tag');
        }
        edits[field.key] = value;
      }
      if (edits.isEmpty) return AudioMetadataWriteResult.unchanged;
      final tagBytes = _updatedTags(input, layout, edits);
      expectedTags = tagBytes;
      if (layout.tagSlots.length == 1 &&
          _sameBytes(
            _readElementBytes(input, layout.tagSlots.single),
            tagBytes,
          )) {
        return AudioMetadataWriteResult.unchanged;
      }

      // Reusing a trailing tag block also prevents file growth on repeated edits.
      final last = layout.children.last;
      final end = last.id == _tags ? last.start : layout.length;
      expectedLength = end + tagBytes.length;
      final patches = <_Patch>[];
      if (!layout.segment.unknownSize) {
        final size = expectedLength - layout.segment.payload;
        patches.add(
          _Patch(
            layout.segment.start + layout.segment.idWidth,
            _sizeBytes(size, width: layout.segment.sizeWidth),
          ),
        );
      }
      for (final slot in layout.tagSlots) {
        if (slot.start >= end) continue;
        patches.add(_Patch(slot.start, _voidBytes(slot.length)));
      }
      for (final head in layout.children.where(
        (part) => part.id == _seekHead,
      )) {
        final patched = _updateSeekHead(
          _readElementBytes(input, head),
          end - layout.segment.payload,
        );
        if (patched != null) patches.add(_Patch(head.start, patched));
      }
      patches.sort((a, b) => a.start.compareTo(b.start));
      var cursor = 0;
      for (final patch in patches) {
        if (patch.start < cursor || patch.start + patch.bytes.length > end) {
          throw const FormatException('Overlapping WebM edits');
        }
        copyAudioMetadataRange(
          input,
          output,
          start: cursor,
          length: patch.start - cursor,
        );
        output.writeFromSync(patch.bytes);
        cursor = patch.start + patch.bytes.length;
      }
      copyAudioMetadataRange(
        input,
        output,
        start: cursor,
        length: end - cursor,
      );
      output.writeFromSync(tagBytes);
      return AudioMetadataWriteResult.written;
    },
    validate: (candidate) {
      final input = candidate.openSync();
      try {
        final prepared = _inspect(input);
        final before = original!;
        if (prepared.length != expectedLength ||
            prepared.trackUid != before.trackUid ||
            prepared.clusters.length != before.clusters.length ||
            prepared.tagSlots.length != 1 ||
            !_sameBytes(
              _readElementBytes(input, prepared.tagSlots.single),
              expectedTags!,
            )) {
          return false;
        }
        for (var index = 0; index < before.clusters.length; index++) {
          final oldCluster = before.clusters[index];
          final newCluster = prepared.clusters[index];
          if (oldCluster.start != newCluster.start ||
              oldCluster.end != newCluster.end) {
            return false;
          }
        }
        return true;
      } finally {
        input.closeSync();
      }
    },
  );
}

_Layout _inspect(RandomAccessFile input) {
  final length = input.lengthSync();
  final header = _readElement(input, 0, length);
  if (header.id != _ebml || header.unknownSize || header.length > 65536) {
    throw const FormatException('Missing EBML header');
  }
  final headerBytes = _readElementBytes(input, header);
  var documentType = '';
  for (final child in _children(
    headerBytes,
    header.headerLength,
    headerBytes.length,
  )) {
    if (child.id == 0x4282) {
      documentType = utf8.decode(_payload(headerBytes, child));
    } else if (child.id == 0x42f7 && _uint(_payload(headerBytes, child)) != 1) {
      throw const FormatException('Unsupported EBML read version');
    } else if (child.id == 0x4285 && _uint(_payload(headerBytes, child)) > 4) {
      throw const FormatException('Unsupported WebM read version');
    } else if (child.id == 0x42f2 && _uint(_payload(headerBytes, child)) != 4) {
      throw const FormatException('Unsupported EBML ID length');
    } else if (child.id == 0x42f3 && _uint(_payload(headerBytes, child)) != 8) {
      throw const FormatException('Unsupported EBML size length');
    }
  }
  if (documentType != 'webm' && documentType != 'matroska') {
    throw const FormatException('Not WebM/Matroska');
  }
  var cursor = header.end;
  var segment = _readElement(input, cursor, length);
  while (segment.id == _void) {
    cursor = segment.end;
    segment = _readElement(input, cursor, length);
  }
  if (segment.id != _segment || segment.end != length) {
    throw const FormatException('Multiple or truncated WebM segments');
  }
  final children = <_Element>[];
  final tagSlots = <_Element>[];
  final clusters = <_Element>[];
  var trackUid = 0;
  var totalMetadata = 0;
  cursor = segment.payload;
  while (cursor < segment.end) {
    if (children.length >= 100000) {
      throw const FormatException('Too many WebM elements');
    }
    var child = _readElement(input, cursor, segment.end);
    if (child.id == _crc) {
      // A Segment CRC covers the edited tags too. Do not leave a stale checksum.
      throw const FormatException(
        'Segment checksum requires a full CRC rewrite',
      );
    }
    if (child.unknownSize) {
      if (child.id != _cluster) {
        throw const FormatException('Unknown WebM metadata size');
      }
      child = child.withEnd(_unknownClusterEnd(input, child, segment.end));
    }
    if (child.id == _tracks) {
      if (trackUid != 0) throw const FormatException('Multiple track sections');
      trackUid = _audioTrackUid(_readElementBytes(input, child));
    } else if (child.id == _tags) {
      totalMetadata += child.length;
      if (totalMetadata > _maximumMetadataBytes) {
        throw const FormatException('Oversized WebM metadata');
      }
      tagSlots.add(child);
    } else if (child.id == _cluster) {
      clusters.add(child);
    } else if (child.id == _seekHead && child.length > _maximumMetadataBytes) {
      throw const FormatException('Oversized WebM seek index');
    }
    children.add(child);
    cursor = child.end;
  }
  if (trackUid == 0 || clusters.isEmpty) {
    throw const FormatException('Missing WebM audio track/media');
  }
  final byPosition = {
    for (final child in children) child.start - segment.payload: child.id,
  };
  for (final head in children.where((child) => child.id == _seekHead)) {
    _validateSeekHead(_readElementBytes(input, head), byPosition);
  }
  return _Layout(length, segment, children, tagSlots, clusters, trackUid);
}

int _unknownClusterEnd(RandomAccessFile input, _Element cluster, int end) {
  var cursor = cluster.payload;
  var count = 0;
  while (cursor < end) {
    if (++count > _maximumElements) {
      throw const FormatException('Too many WebM blocks');
    }
    final child = _readElement(input, cursor, end);
    if (_segmentChildren.contains(child.id)) return cursor;
    if (child.unknownSize) {
      throw const FormatException('Unknown WebM block size');
    }
    cursor = child.end;
  }
  return cursor;
}

int _audioTrackUid(Uint8List bytes) {
  final parent = _elementAt(bytes, 0, bytes.length);
  var uid = 0;
  var entries = 0;
  for (final entry in _children(bytes, parent.payload, parent.end)) {
    if (entry.id != 0xae) continue;
    if (++entries != 1) throw const FormatException('Multiple WebM tracks');
    var type = 0;
    var number = 0;
    var codec = '';
    for (final child in _children(bytes, entry.payload, entry.end)) {
      if (child.id == 0x73c5) uid = _uint(_payload(bytes, child));
      if (child.id == 0xd7) number = _uint(_payload(bytes, child));
      if (child.id == 0x83) type = _uint(_payload(bytes, child));
      if (child.id == 0x86) codec = utf8.decode(_payload(bytes, child));
      if (child.id == 0x6d80) {
        throw const FormatException('Encrypted/compressed WebM track');
      }
    }
    if (type != 2 ||
        number <= 0 ||
        (codec != 'A_OPUS' && codec != 'A_VORBIS')) {
      throw const FormatException('Unsupported WebM track');
    }
  }
  if (entries != 1 || uid == 0) {
    throw const FormatException('Missing audio track UID');
  }
  return uid;
}

Uint8List _updatedTags(
  RandomAccessFile input,
  _Layout layout,
  Map<String, String> edits,
) {
  final children = BytesBuilder(copy: false);
  for (final slot in layout.tagSlots) {
    final bytes = _readElementBytes(input, slot);
    final parent = _elementAt(bytes, 0, bytes.length);
    for (final child in _children(bytes, parent.payload, parent.end)) {
      if (child.id == _crc || child.id == _void) continue;
      if (child.id != _tag) {
        children.add(_raw(bytes, child));
        continue;
      }
      final parts = _children(bytes, child.payload, child.end);
      final targets = parts.where((part) => part.id == _targets).toList();
      if (targets.length > 1) {
        throw const FormatException('Duplicate tag targets');
      }
      if (targets.isNotEmpty &&
          !_targetsAudio(bytes, targets.single, layout.trackUid)) {
        children.add(_raw(bytes, child));
        continue;
      }
      final kept = BytesBuilder(copy: false);
      var simpleTags = 0;
      for (final part in parts) {
        if (part.id == _crc) continue;
        if (part.id == _simpleTag) {
          final name = _simpleName(bytes, part);
          if (edits.containsKey(name)) continue;
          simpleTags++;
        }
        kept.add(_raw(bytes, part));
      }
      if (simpleTags > 0) children.add(_element(_tag, kept.takeBytes()));
    }
  }
  final managed = BytesBuilder(copy: false)
    ..add(
      _element(_targets, [
        ..._element(0x68ca, [30]),
        ..._element(0x63ca, ascii.encode('TRACK')),
        ..._element(0x63c5, _uintBytes(layout.trackUid, width: 8)),
      ]),
    );
  for (final edit in edits.entries) {
    managed.add(
      _element(_simpleTag, [
        ..._element(0x45a3, ascii.encode(edit.key)),
        ..._element(0x4487, utf8.encode(edit.value)),
      ]),
    );
  }
  // Readers that do not interpret Targets commonly choose the first TITLE.
  // Put the current track first while retaining album/chapter/other-track tags.
  final updated = _element(_tags, [
    ..._element(_tag, managed.takeBytes()),
    ...children.takeBytes(),
  ]);
  if (updated.length > _maximumMetadataBytes) {
    throw const FormatException('Oversized updated WebM metadata');
  }
  return updated;
}

bool _targetsAudio(Uint8List bytes, _Element targets, int uid) {
  var level = 50;
  var explicitAlbum = false;
  final trackUids = <int>[];
  for (final child in _children(bytes, targets.payload, targets.end)) {
    if (child.id == 0x68ca) {
      level = _uint(_payload(bytes, child));
      explicitAlbum = level == 50;
    }
    if (child.id == 0x63ca &&
        utf8.decode(_payload(bytes, child)).toUpperCase() == 'ALBUM') {
      explicitAlbum = true;
    }
    if (child.id == 0x63c5) trackUids.add(_uint(_payload(bytes, child)));
    if (child.id == 0x63c4 || child.id == 0x63c6 || child.id == 0x63c9) {
      return false;
    }
  }
  return !explicitAlbum &&
      (level == 30 || level == 50) &&
      (trackUids.isEmpty ||
          trackUids.every((value) => value == 0 || value == uid));
}

String _simpleName(Uint8List bytes, _Element simpleTag) {
  String? name;
  for (final child in _children(bytes, simpleTag.payload, simpleTag.end)) {
    if (child.id == 0x45a3) {
      if (name != null) throw const FormatException('Duplicate tag names');
      name = utf8.decode(_payload(bytes, child)).toUpperCase();
    }
  }
  if (name == null) throw const FormatException('Missing tag name');
  return name;
}

void _validateSeekHead(Uint8List bytes, Map<int, int> positions) {
  final head = _elementAt(bytes, 0, bytes.length);
  for (final seek in _children(bytes, head.payload, head.end)) {
    if (seek.id == _void) continue;
    if (seek.id != 0x4dbb) {
      throw const FormatException('Unsupported seek index element');
    }
    int? id;
    int? offset;
    for (final child in _children(bytes, seek.payload, seek.end)) {
      if (child.id == 0x53ab) id = _uint(_payload(bytes, child));
      if (child.id == 0x53ac) offset = _uint(_payload(bytes, child));
    }
    if (id == null || offset == null || positions[offset] != id) {
      throw const FormatException('Invalid WebM seek target');
    }
  }
}

Uint8List? _updateSeekHead(Uint8List bytes, int tagsOffset) {
  final head = _elementAt(bytes, 0, bytes.length);
  Uint8List? patched;
  for (final seek in _children(bytes, head.payload, head.end)) {
    if (seek.id != 0x4dbb) continue;
    final fields = _children(bytes, seek.payload, seek.end);
    final ids = fields.where((field) => field.id == 0x53ab).toList();
    if (ids.length != 1 || _uint(_payload(bytes, ids.single)) != _tags) {
      continue;
    }
    final offsets = fields.where((field) => field.id == 0x53ac).toList();
    if (offsets.length != 1) {
      throw const FormatException('Duplicate seek offsets');
    }
    final offset = offsets.single;
    final width = offset.end - offset.payload;
    patched ??= Uint8List.fromList(bytes);
    if (width < 8 && tagsOffset >= (1 << (8 * width))) {
      // A SeekHead is optional. Keep the remaining references and all offsets,
      // rather than resizing the entry and shifting the media to fit this one.
      patched.setRange(seek.start, seek.end, _voidBytes(seek.length));
    } else {
      patched.setRange(
        offset.payload,
        offset.end,
        _uintBytes(tagsOffset, width: width),
      );
    }
  }
  return patched;
}

_Element _readElement(RandomAccessFile input, int start, int end) {
  if (start < 0 || start >= end) {
    throw const FormatException('Missing EBML element');
  }
  input.setPositionSync(start);
  final bytes = input.readSync((end - start).clamp(0, 12));
  return _elementAt(
    bytes,
    0,
    bytes.length,
    absoluteStart: start,
    parentEnd: end,
  );
}

_Element _elementAt(
  Uint8List bytes,
  int start,
  int end, {
  int? absoluteStart,
  int? parentEnd,
}) {
  var cursor = start;
  final idWidth = _vintWidth(bytes, cursor, end, maximum: 4);
  if (cursor + idWidth >= end) throw const FormatException('Truncated EBML ID');
  var id = 0;
  for (var index = 0; index < idWidth; index++) {
    id = (id << 8) | bytes[cursor++];
  }
  final sizeWidth = _vintWidth(bytes, cursor, end);
  if (cursor + sizeWidth > end) {
    throw const FormatException('Truncated EBML size');
  }
  var size = bytes[cursor++] & ((1 << (8 - sizeWidth)) - 1);
  for (var index = 1; index < sizeWidth; index++) {
    size = (size << 8) | bytes[cursor++];
  }
  final unknown = size == (1 << (7 * sizeWidth)) - 1;
  final position = absoluteStart ?? start;
  final payload = position + cursor - start;
  final boundary = parentEnd ?? end;
  final elementEnd = unknown ? boundary : payload + size;
  if (elementEnd > boundary || elementEnd < payload) {
    throw const FormatException('Truncated EBML payload');
  }
  return _Element(
    id,
    position,
    payload,
    elementEnd,
    idWidth,
    sizeWidth,
    unknown,
  );
}

int _vintWidth(Uint8List bytes, int start, int end, {int maximum = 8}) {
  if (start >= end) throw const FormatException('Missing EBML integer');
  for (var width = 1; width <= maximum; width++) {
    if (bytes[start] & (1 << (8 - width)) != 0) return width;
  }
  throw const FormatException('Invalid EBML integer');
}

List<_Element> _children(Uint8List bytes, int start, int end) {
  final children = <_Element>[];
  while (start < end) {
    if (children.length >= 100000) {
      throw const FormatException('Too many metadata elements');
    }
    final child = _elementAt(bytes, start, end);
    if (child.unknownSize) {
      throw const FormatException('Unbounded metadata element');
    }
    children.add(child);
    start = child.end;
  }
  return children;
}

Uint8List _readElementBytes(RandomAccessFile input, _Element element) {
  if (element.length > _maximumMetadataBytes) {
    throw const FormatException('Oversized EBML metadata');
  }
  input.setPositionSync(element.start);
  final bytes = input.readSync(element.length);
  if (bytes.length != element.length) {
    throw const FormatException('Truncated EBML metadata');
  }
  return bytes;
}

Uint8List _raw(Uint8List bytes, _Element element) =>
    Uint8List.sublistView(bytes, element.start, element.end);
Uint8List _payload(Uint8List bytes, _Element element) =>
    Uint8List.sublistView(bytes, element.payload, element.end);

int _uint(List<int> bytes) {
  if (bytes.isEmpty || bytes.length > 8) {
    throw const FormatException('Invalid EBML unsigned integer');
  }
  var value = 0;
  for (final byte in bytes) {
    value = (value << 8) | byte;
  }
  return value;
}

Uint8List _uintBytes(int value, {int? width}) {
  width ??= ((value.bitLength + 7) ~/ 8).clamp(1, 8);
  if (width < 1 ||
      width > 8 ||
      (value < 0 && width != 8) ||
      (width < 8 && value >= (1 << (8 * width)))) {
    throw const FormatException('EBML integer overflow');
  }
  final result = Uint8List(width);
  for (var index = width - 1; index >= 0; index--) {
    result[index] = value & 255;
    value >>= 8;
  }
  return result;
}

Uint8List _sizeBytes(int size, {int? width}) {
  if (size < 0) throw const FormatException('Negative EBML size');
  if (width != null && size >= (1 << (7 * width)) - 1) {
    throw const FormatException('Fixed EBML size overflow');
  }
  width ??= 1;
  while (width! <= 8 && size >= (1 << (7 * width)) - 1) {
    if (width == 8) throw const FormatException('EBML size overflow');
    width++;
  }
  final bytes = _uintBytes(size, width: width);
  bytes[0] |= 1 << (8 - width);
  return bytes;
}

Uint8List _element(int id, List<int> payload) => Uint8List.fromList([
  ..._uintBytes(id),
  ..._sizeBytes(payload.length),
  ...payload,
]);

Uint8List _voidBytes(int totalLength) {
  for (var width = 1; width <= 8; width++) {
    final payloadLength = totalLength - 1 - width;
    if (payloadLength >= 0 && payloadLength < (1 << (7 * width)) - 1) {
      return Uint8List(totalLength)
        ..[0] = _void
        ..setRange(1, 1 + width, _sizeBytes(payloadLength, width: width));
    }
  }
  throw const FormatException('Invalid WebM Void size');
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class _Layout {
  const _Layout(
    this.length,
    this.segment,
    this.children,
    this.tagSlots,
    this.clusters,
    this.trackUid,
  );
  final int length;
  final _Element segment;
  final List<_Element> children;
  final List<_Element> tagSlots;
  final List<_Element> clusters;
  final int trackUid;
}

class _Element {
  const _Element(
    this.id,
    this.start,
    this.payload,
    this.end,
    this.idWidth,
    this.sizeWidth,
    this.unknownSize,
  );
  final int id;
  final int start;
  final int payload;
  final int end;
  final int idWidth;
  final int sizeWidth;
  final bool unknownSize;
  int get length => end - start;
  int get headerLength => payload - start;
  _Element withEnd(int value) =>
      _Element(id, start, payload, value, idWidth, sizeWidth, unknownSize);
}

class _Patch {
  const _Patch(this.start, this.bytes);
  final int start;
  final Uint8List bytes;
}
