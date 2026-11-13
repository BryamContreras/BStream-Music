import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'atomic_audio_metadata_rewrite.dart';
import 'audio_metadata_fields.dart';

enum M4aTagWriteResult { written, unchanged, unsupported, failed }

const _maximumMovieBytes = 16 * 1024 * 1024;
const _maximumFragmentBytes = 2 * 1024 * 1024;
const _maximumBoxes = 200000;

/// Writes portable iTunes-style tags while copying audio bytes unchanged.
///
/// This synchronous operation belongs in the shared background-work runner.
/// Only metadata and bounded fragment headers enter memory. Unsupported layouts
/// remain untouched; a prepared file replaces the source only after validation.
M4aTagWriteResult writeM4aTags(
  File file, {
  required String title,
  required String artist,
  String? album,
  Uint8List? artworkBytes,
  String? artworkMimeType,
}) {
  late _MovieFile original;
  late Uint8List movie;
  var delta = 0;
  final result = rewriteAudioMetadataFile(
    file,
    rewrite: (source, output) {
      original = _inspect(source);
      final edits = <String, Uint8List>{};
      void text(String type, String? value) {
        final normalized = value?.trim();
        if (normalized == null || normalized.isEmpty) return;
        if (normalized.length > 16384) throw const _UnsupportedM4a();
        edits[type] = _tag(type, 1, utf8.encode(normalized));
      }

      text('©nam', title);
      text('©ART', artist);
      text('©alb', album);
      if (artworkBytes != null) {
        if (artworkBytes.length > 4 * 1024 * 1024) {
          throw const _UnsupportedM4a();
        }
        final mime = artworkMimeType?.trim().toLowerCase();
        final jpeg =
            mime == 'image/jpeg' &&
            artworkBytes.length >= 3 &&
            artworkBytes[0] == 0xff &&
            artworkBytes[1] == 0xd8 &&
            artworkBytes[2] == 0xff;
        final png =
            mime == 'image/png' &&
            artworkBytes.length >= 8 &&
            _sameBytes(Uint8List.sublistView(artworkBytes, 0, 8), const [
              137,
              80,
              78,
              71,
              13,
              10,
              26,
              10,
            ]);
        if (!jpeg && !png) throw const _UnsupportedM4a();
        edits['covr'] = _tag('covr', jpeg ? 13 : 14, artworkBytes);
      }
      if (edits.isEmpty) return AudioMetadataWriteResult.unchanged;

      movie = _editMovie(original.movieBytes, edits);
      if (_sameBytes(movie, original.movieBytes)) {
        return AudioMetadataWriteResult.unchanged;
      }
      if (movie.length > _maximumMovieBytes) throw const _UnsupportedM4a();
      delta = movie.length - original.movie.size;
      movie = _patchChunkOffsets(movie, original, delta);

      for (final box in original.boxes) {
        if (identical(box, original.movie)) {
          output.writeFromSync(movie);
        } else {
          copyAudioMetadataRange(
            source,
            output,
            start: box.start,
            length: box.size,
          );
        }
      }
      return AudioMetadataWriteResult.written;
    },
    validate: (candidate) {
      final verification = candidate.openSync();
      try {
        final prepared = _inspect(verification);
        if (prepared.length != original.length + delta ||
            prepared.boxes.length != original.boxes.length ||
            !_sameBytes(prepared.movieBytes, movie)) {
          throw const _UnsupportedM4a();
        }
        for (var index = 0; index < original.boxes.length; index++) {
          final before = original.boxes[index];
          final after = prepared.boxes[index];
          final expectedStart = before.start >= original.movie.end
              ? before.start + delta
              : before.start;
          final expectedSize = identical(before, original.movie)
              ? movie.length
              : before.size;
          if (after.type != before.type ||
              after.start != expectedStart ||
              after.size != expectedSize) {
            throw const _UnsupportedM4a();
          }
        }
      } finally {
        verification.closeSync();
      }
      return true;
    },
  );
  return switch (result) {
    AudioMetadataWriteResult.written => M4aTagWriteResult.written,
    AudioMetadataWriteResult.unchanged => M4aTagWriteResult.unchanged,
    AudioMetadataWriteResult.unsupported => M4aTagWriteResult.unsupported,
    AudioMetadataWriteResult.failed => M4aTagWriteResult.failed,
  };
}

_MovieFile _inspect(RandomAccessFile source) {
  final length = source.lengthSync();
  final boxes = <_Box>[];
  var position = 0;
  while (position < length) {
    if (boxes.length >= _maximumBoxes) throw const _UnsupportedM4a();
    final box = _fileBox(source, position, length);
    // Unknown top-level structures can contain absolute indexes. Leave them
    // untouched rather than guessing how to relocate their references.
    if (!const {
      'ftyp',
      'moov',
      'moof',
      'mdat',
      'sidx',
      'styp',
      'free',
      'skip',
      'wide',
    }.contains(box.type)) {
      throw const _UnsupportedM4a();
    }
    boxes.add(box);
    position = box.end;
  }
  final movie = _one(boxes, 'moov');
  final type = _one(boxes, 'ftyp');
  if (type.start > movie.start || type.payloadLength < 8) {
    throw const _UnsupportedM4a();
  }
  if (movie.size > _maximumMovieBytes ||
      !boxes.any((box) => box.type == 'mdat' && box.payloadLength > 0)) {
    throw const _UnsupportedM4a();
  }
  final movieBytes = _read(source, movie.start, movie.size);
  final result = _MovieFile(length, boxes, movie, movieBytes);
  final root = _memoryBoxes(movieBytes, 0, movieBytes.length).single;
  final children = _memoryBoxes(movieBytes, root.payload, root.end);
  final tracks = children.where((box) => box.type == 'trak').toList();
  if (tracks.isEmpty) throw const _UnsupportedM4a();
  for (final track in tracks) {
    final trackChildren = _memoryBoxes(movieBytes, track.payload, track.end);
    final media = _one(trackChildren, 'mdia');
    final mediaChildren = _memoryBoxes(movieBytes, media.payload, media.end);
    final handler = _one(mediaChildren, 'hdlr');
    if (handler.payloadLength < 12 ||
        _type(movieBytes, handler.payload + 8) != 'soun') {
      throw const _UnsupportedM4a();
    }
    final information = _one(mediaChildren, 'minf');
    final informationChildren = _memoryBoxes(
      movieBytes,
      information.payload,
      information.end,
    );
    final table = _one(informationChildren, 'stbl');
    final tableChildren = _memoryBoxes(movieBytes, table.payload, table.end);
    _one(tableChildren, 'stsd');
    if (tableChildren
            .where((box) => box.type == 'stco' || box.type == 'co64')
            .length !=
        1) {
      throw const _UnsupportedM4a();
    }
  }
  _walkMovie(movieBytes, root, (box) {
    if (box.type == 'stco' || box.type == 'co64') {
      _chunkOffsets(movieBytes, box, (offset, width) {
        final value = _unsigned(movieBytes, offset, width);
        if (!result.containsMediaOffset(value)) throw const _UnsupportedM4a();
      });
    }
  });
  final fragments = boxes.where((box) => box.type == 'moof').toList();
  if (fragments.isNotEmpty) {
    if (!children.any((box) => box.type == 'mvex') ||
        boxes.any(
          (box) =>
              const {'moof', 'mdat', 'sidx'}.contains(box.type) &&
              box.start < movie.end,
        )) {
      throw const _UnsupportedM4a();
    }
    for (final fragment in fragments) {
      if (fragment.size > _maximumFragmentBytes) {
        throw const _UnsupportedM4a();
      }
      _validateFragment(
        _read(source, fragment.start, fragment.size),
        fragment.start,
        result,
      );
    }
  }
  for (final index in boxes.where((box) => box.type == 'sidx')) {
    // A relative index stays byte-for-byte valid only if it and all indexed
    // segments are after the resized movie. Progressive files need no sidx.
    if (fragments.isEmpty || index.start < movie.end) {
      throw const _UnsupportedM4a();
    }
    _validateSegmentIndex(source, index, length);
  }
  return result;
}

void _walkMovie(
  Uint8List bytes,
  _Box box,
  void Function(_Box) visit, [
  int depth = 0,
  bool audioSampleEntry = false,
]) {
  if (depth > 24) throw const _UnsupportedM4a();
  if (const {
    'saio',
    'saiz',
    'senc',
    'sinf',
    'tenc',
    'pssh',
    'enca',
    'encv',
    'iloc',
    'mfra',
    'tfra',
    'uuid',
  }.contains(box.type)) {
    throw const _UnsupportedM4a();
  }
  visit(box);
  var childStart = box.payload;
  if (box.type == 'meta') {
    childStart += _metaPrefixLength(bytes, box);
  } else if (box.type == 'stsd' || box.type == 'dref') {
    if (box.payloadLength < 8 || _u32(bytes, box.payload) != 0) {
      throw const _UnsupportedM4a();
    }
    childStart += 8;
  } else if (audioSampleEntry && (box.type == 'mp4a' || box.type == 'alac')) {
    if (box.payloadLength < 28 ||
        _u16(bytes, box.payload + 6) != 1 ||
        _u16(bytes, box.payload + 8) != 0) {
      throw const _UnsupportedM4a();
    }
    childStart += 28;
  } else if (!const {
    'moov',
    'trak',
    'mdia',
    'minf',
    'stbl',
    'dinf',
    'edts',
    'mvex',
    'udta',
    'ilst',
  }.contains(box.type)) {
    return;
  }
  final children = _memoryBoxes(bytes, childStart, box.end);
  if (box.type == 'stsd') {
    if (_u32(bytes, box.payload + 4) != children.length ||
        children.isEmpty ||
        children.any((entry) => entry.type != 'mp4a' && entry.type != 'alac')) {
      throw const _UnsupportedM4a();
    }
  }
  if (box.type == 'dref') {
    if (_u32(bytes, box.payload + 4) != children.length ||
        children.length != 1 ||
        children.single.type != 'url ' ||
        children.single.payloadLength != 4 ||
        _u32(bytes, children.single.payload) != 1) {
      throw const _UnsupportedM4a();
    }
  }
  for (final child in children) {
    _walkMovie(bytes, child, visit, depth + 1, box.type == 'stsd');
  }
}

void _validateFragment(Uint8List bytes, int fragmentStart, _MovieFile file) {
  final movie = _memoryBoxes(bytes, 0, bytes.length).single;
  final children = _memoryBoxes(bytes, movie.payload, movie.end);
  if (children.any((box) => box.type != 'mfhd' && box.type != 'traf')) {
    throw const _UnsupportedM4a();
  }
  final tracks = children.where((box) => box.type == 'traf').toList();
  if (tracks.isEmpty) throw const _UnsupportedM4a();
  for (final track in tracks) {
    final entries = _memoryBoxes(bytes, track.payload, track.end);
    if (entries.any(
      (box) =>
          !const {'tfhd', 'tfdt', 'trun', 'sbgp', 'free'}.contains(box.type),
    )) {
      throw const _UnsupportedM4a();
    }
    final header = _one(entries, 'tfhd');
    if (header.payloadLength < 8) throw const _UnsupportedM4a();
    final flags = _u32(bytes, header.payload);
    if ((flags & 0xff000000) != 0 ||
        (flags & 1) != 0 ||
        ((flags & 0x020000) == 0 && tracks.length != 1)) {
      throw const _UnsupportedM4a();
    }
    var expectedHeaderLength = 8;
    for (final mask in const [2, 8, 16, 32]) {
      if ((flags & mask) != 0) expectedHeaderLength += 4;
    }
    if ((flags & ~0x03003b) != 0 ||
        header.payloadLength != expectedHeaderLength) {
      throw const _UnsupportedM4a();
    }
    final runs = entries.where((box) => box.type == 'trun').toList();
    if (runs.isEmpty ||
        runs.first.payloadLength < 12 ||
        (_u32(bytes, runs.first.payload) & 1) == 0) {
      throw const _UnsupportedM4a();
    }
    var totalSamples = 0;
    for (final run in runs) {
      if (run.payloadLength < 8) throw const _UnsupportedM4a();
      final runFlags = _u32(bytes, run.payload);
      if ((runFlags >> 24) > 1 || (runFlags & 0x00fff0fa) != 0) {
        throw const _UnsupportedM4a();
      }
      final samples = _u32(bytes, run.payload + 4);
      totalSamples += samples;
      var expected = 8;
      if ((runFlags & 1) != 0) {
        expected += 4;
        if (run.payloadLength < 12) throw const _UnsupportedM4a();
        final offset = ByteData.sublistView(bytes).getInt32(run.payload + 8);
        final target = fragmentStart + offset;
        if (target < fragmentStart + bytes.length ||
            !file.containsMediaOffset(target)) {
          throw const _UnsupportedM4a();
        }
      }
      if ((runFlags & 4) != 0) expected += 4;
      for (final mask in const [0x100, 0x200, 0x400, 0x800]) {
        if ((runFlags & mask) != 0) expected += samples * 4;
      }
      if (expected != run.payloadLength) throw const _UnsupportedM4a();
    }
    for (final grouping in entries.where((box) => box.type == 'sbgp')) {
      _validateSampleToGroup(bytes, grouping, totalSamples);
    }
  }
}

/// Roll-recovery mappings describe samples, never absolute byte locations.
/// They therefore remain valid when a relative-addressed fragment moves as a
/// whole. Other grouping schemes need their own validation before admission.
void _validateSampleToGroup(Uint8List bytes, _Box box, int totalSamples) {
  if (box.payloadLength < 12) throw const _UnsupportedM4a();
  final versionAndFlags = _u32(bytes, box.payload);
  final version = versionAndFlags >> 24;
  if (version > 1 || (versionAndFlags & 0x00ffffff) != 0) {
    throw const _UnsupportedM4a();
  }
  final groupingType = _type(bytes, box.payload + 4);
  if (groupingType != 'roll' && groupingType != 'prol') {
    throw const _UnsupportedM4a();
  }
  final countPosition = box.payload + (version == 0 ? 8 : 12);
  if (countPosition + 4 > box.end) throw const _UnsupportedM4a();
  final count = _u32(bytes, countPosition);
  final entriesStart = countPosition + 4;
  if (box.end - entriesStart != count * 8) throw const _UnsupportedM4a();
  var mappedSamples = 0;
  for (var index = 0; index < count; index++) {
    mappedSamples += _u32(bytes, entriesStart + index * 8);
    if (mappedSamples > totalSamples) throw const _UnsupportedM4a();
  }
}

void _validateSegmentIndex(RandomAccessFile source, _Box box, int fileLength) {
  if (box.payloadLength < 24 || box.size > _maximumFragmentBytes) {
    throw const _UnsupportedM4a();
  }
  final bytes = _read(source, box.payload, box.payloadLength);
  final version = bytes[0];
  if (version > 1 || (bytes[1] | bytes[2] | bytes[3]) != 0) {
    throw const _UnsupportedM4a();
  }
  final firstOffsetPosition = version == 0 ? 16 : 20;
  final countPosition = version == 0 ? 22 : 30;
  final tablePosition = countPosition + 2;
  if (bytes.length < tablePosition || _u32(bytes, 8) == 0) {
    throw const _UnsupportedM4a();
  }
  final firstOffset = _unsigned(
    bytes,
    firstOffsetPosition,
    version == 0 ? 4 : 8,
  );
  final count = _u16(bytes, countPosition);
  if (firstOffset < 0 || bytes.length != tablePosition + count * 12) {
    throw const _UnsupportedM4a();
  }
  var target = box.end + firstOffset;
  if (target < box.end || target > fileLength) throw const _UnsupportedM4a();
  for (var index = 0; index < count; index++) {
    final reference = _u32(bytes, tablePosition + index * 12);
    // Hierarchical indexes need a separate graph validation.
    if ((reference & 0x80000000) != 0) throw const _UnsupportedM4a();
    target += reference & 0x7fffffff;
    if (target > fileLength) throw const _UnsupportedM4a();
  }
}

Uint8List _editMovie(Uint8List bytes, Map<String, Uint8List> edits) {
  final root = _memoryBoxes(bytes, 0, bytes.length).single;
  final children = _memoryBoxes(bytes, root.payload, root.end);
  final locations = <({_Box? userData, _Box metadata})>[];
  for (final child in children) {
    if (child.type == 'meta' && _isItunesMeta(bytes, child)) {
      locations.add((userData: null, metadata: child));
    } else if (child.type == 'udta') {
      for (final entry in _memoryBoxes(bytes, child.payload, child.end)) {
        if (entry.type == 'meta' && _isItunesMeta(bytes, entry)) {
          locations.add((userData: child, metadata: entry));
        }
      }
    }
  }
  if (locations.length > 1) throw const _UnsupportedM4a();
  if (locations.isNotEmpty) {
    final location = locations.single;
    final metadata = _editMeta(bytes, location.metadata, edits);
    if (location.userData == null) {
      return _replaceChild(bytes, root, location.metadata, metadata);
    }
    final userData = location.userData!;
    return _replaceChild(
      bytes,
      root,
      userData,
      _replaceChild(bytes, userData, location.metadata, metadata),
    );
  }
  final metadata = _newMeta(edits.values);
  final users = children.where((box) => box.type == 'udta').toList();
  if (users.isNotEmpty) {
    final user = users.first;
    return _replaceChild(
      bytes,
      root,
      user,
      _appendChild(bytes, user, metadata),
    );
  }
  return _appendChild(bytes, root, _box('udta', metadata));
}

bool _isItunesMeta(Uint8List bytes, _Box metadata) {
  final prefix = _metaPrefixLength(bytes, metadata);
  final children = _memoryBoxes(bytes, metadata.payload + prefix, metadata.end);
  final handlers = children.where((box) => box.type == 'hdlr').toList();
  if (handlers.length > 1) throw const _UnsupportedM4a();
  if (handlers.isEmpty) return true;
  final handler = handlers.single;
  if (handler.payloadLength < 12) throw const _UnsupportedM4a();
  return _type(bytes, handler.payload + 8) == 'mdir';
}

Uint8List _editMeta(
  Uint8List bytes,
  _Box metadata,
  Map<String, Uint8List> edits,
) {
  final prefix = _metaPrefixLength(bytes, metadata);
  final children = _memoryBoxes(bytes, metadata.payload + prefix, metadata.end);
  final lists = children.where((box) => box.type == 'ilst').toList();
  if (lists.length > 1) throw const _UnsupportedM4a();
  final result = BytesBuilder();
  result.add(
    Uint8List.sublistView(bytes, metadata.payload, metadata.payload + prefix),
  );
  var hasHandler = false;
  for (final child in children) {
    if (child.type == 'hdlr') hasHandler = true;
    result.add(
      child.type == 'ilst'
          ? _editTags(bytes, child, edits)
          : _raw(bytes, child),
    );
  }
  if (!hasHandler) {
    _requireAppendable(children);
    result.add(_metadataHandler());
  }
  if (lists.isEmpty) {
    _requireAppendable(children);
    result.add(_box('ilst', _concatenate(edits.values)));
  }
  return _rebox(metadata, result.takeBytes());
}

Uint8List _editTags(Uint8List bytes, _Box list, Map<String, Uint8List> edits) {
  final children = _memoryBoxes(bytes, list.payload, list.end);
  final emitted = <String>{};
  final output = BytesBuilder();
  for (final child in children) {
    final replacement = edits[child.type];
    if (replacement == null) {
      output.add(_raw(bytes, child));
    } else if (emitted.add(child.type)) {
      output.add(replacement);
    }
  }
  if (edits.keys.any((type) => !emitted.contains(type))) {
    _requireAppendable(children);
  }
  for (final entry in edits.entries) {
    if (emitted.add(entry.key)) output.add(entry.value);
  }
  return _rebox(list, output.takeBytes());
}

Uint8List _patchChunkOffsets(Uint8List movie, _MovieFile original, int delta) {
  if (delta == 0) return movie;
  final result = Uint8List.fromList(movie);
  final root = _memoryBoxes(result, 0, result.length).single;
  final data = ByteData.sublistView(result);
  _walkMovie(result, root, (box) {
    if (box.type != 'stco' && box.type != 'co64') return;
    _chunkOffsets(result, box, (position, width) {
      final value = _unsigned(result, position, width);
      if (!original.containsMediaOffset(value)) throw const _UnsupportedM4a();
      final moved = value >= original.movie.end ? value + delta : value;
      if (moved < 0 || (width == 4 && moved > 0xffffffff)) {
        throw const _UnsupportedM4a();
      }
      if (width == 4) {
        data.setUint32(position, moved);
      } else {
        data.setUint64(position, moved);
      }
    });
  });
  return result;
}

void _chunkOffsets(Uint8List bytes, _Box box, void Function(int, int) visit) {
  if (box.payloadLength < 8 || _u32(bytes, box.payload) != 0) {
    throw const _UnsupportedM4a();
  }
  final width = box.type == 'stco' ? 4 : 8;
  final count = _u32(bytes, box.payload + 4);
  if (box.payloadLength != 8 + count * width) throw const _UnsupportedM4a();
  for (var index = 0; index < count; index++) {
    visit(box.payload + 8 + index * width, width);
  }
}

Uint8List _replaceChild(
  Uint8List bytes,
  _Box parent,
  _Box child,
  Uint8List replacement,
) {
  final payload = BytesBuilder()
    ..add(Uint8List.sublistView(bytes, parent.payload, child.start))
    ..add(replacement)
    ..add(Uint8List.sublistView(bytes, child.end, parent.end));
  return _rebox(parent, payload.takeBytes());
}

Uint8List _appendChild(Uint8List bytes, _Box parent, Uint8List child) {
  _requireAppendable(_memoryBoxes(bytes, parent.payload, parent.end));
  return _rebox(
    parent,
    _concatenate([
      Uint8List.sublistView(bytes, parent.payload, parent.end),
      child,
    ]),
  );
}

void _requireAppendable(List<_Box> children) {
  if (children.isNotEmpty && children.last.extendsToEnd) {
    throw const _UnsupportedM4a();
  }
}

Uint8List _newMeta(Iterable<Uint8List> tags) => _box(
  'meta',
  _concatenate([
    Uint8List(4),
    _metadataHandler(),
    _box('ilst', _concatenate(tags)),
  ]),
);

Uint8List _metadataHandler() => _box(
  'hdlr',
  _concatenate([
    Uint8List(8),
    latin1.encode('mdir'),
    Uint8List(12),
    Uint8List(1),
  ]),
);

Uint8List _tag(String type, int kind, List<int> value) {
  final fields = ByteData(8)..setUint32(0, kind);
  return _box(
    type,
    _box('data', _concatenate([fields.buffer.asUint8List(), value])),
  );
}

Uint8List _box(String type, List<int> payload, {bool extended = false}) {
  final size = payload.length + (extended ? 16 : 8);
  if (!extended && size > 0xffffffff) throw const _UnsupportedM4a();
  final header = ByteData(extended ? 16 : 8)..setUint32(0, extended ? 1 : size);
  final bytes = header.buffer.asUint8List();
  bytes.setRange(4, 8, latin1.encode(type));
  if (extended) header.setUint64(8, size);
  return _concatenate([bytes, payload]);
}

Uint8List _rebox(_Box original, List<int> payload) =>
    _box(original.type, payload, extended: original.headerSize == 16);

Uint8List _concatenate(Iterable<List<int>> values) {
  final builder = BytesBuilder();
  for (final value in values) {
    builder.add(value);
  }
  return builder.takeBytes();
}

int _metaPrefixLength(Uint8List bytes, _Box box) {
  if (box.payloadLength >= 4 && _u32(bytes, box.payload) == 0) return 4;
  if (box.payloadLength == 0) return 0;
  _memoryBoxes(bytes, box.payload, box.end);
  return 0;
}

List<_Box> _memoryBoxes(Uint8List bytes, int start, int end) {
  if (start < 0 || end > bytes.length || start > end) {
    throw const _UnsupportedM4a();
  }
  final result = <_Box>[];
  var offset = start;
  while (offset < end) {
    if (result.length >= _maximumBoxes || end - offset < 8) {
      throw const _UnsupportedM4a();
    }
    final shortSize = _u32(bytes, offset);
    final headerSize = shortSize == 1 ? 16 : 8;
    if (end - offset < headerSize) throw const _UnsupportedM4a();
    final size = shortSize == 0
        ? end - offset
        : shortSize == 1
        ? _unsigned(bytes, offset + 8, 8)
        : shortSize;
    if (size < headerSize || size > end - offset) throw const _UnsupportedM4a();
    result.add(
      _Box(offset, size, headerSize, _type(bytes, offset + 4), shortSize == 0),
    );
    offset += size;
  }
  return result;
}

_Box _fileBox(RandomAccessFile source, int start, int end) {
  if (end - start < 8) throw const _UnsupportedM4a();
  final header = _read(source, start, end - start >= 16 ? 16 : 8);
  final shortSize = _u32(header, 0);
  final headerSize = shortSize == 1 ? 16 : 8;
  if (header.length < headerSize) throw const _UnsupportedM4a();
  final size = shortSize == 0
      ? end - start
      : shortSize == 1
      ? _unsigned(header, 8, 8)
      : shortSize;
  if (size < headerSize || size > end - start) throw const _UnsupportedM4a();
  return _Box(start, size, headerSize, _type(header, 4), shortSize == 0);
}

Uint8List _read(RandomAccessFile source, int position, int count) {
  source.setPositionSync(position);
  final bytes = source.readSync(count);
  if (bytes.length != count) throw const _UnsupportedM4a();
  return bytes;
}

Uint8List _raw(Uint8List bytes, _Box box) =>
    Uint8List.sublistView(bytes, box.start, box.end);
_Box _one(List<_Box> boxes, String type) {
  final found = boxes.where((box) => box.type == type).toList();
  if (found.length != 1) throw const _UnsupportedM4a();
  return found.single;
}

int _u16(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint16(offset);
int _u32(Uint8List bytes, int offset) =>
    ByteData.sublistView(bytes).getUint32(offset);
int _unsigned(Uint8List bytes, int offset, int width) => width == 4
    ? _u32(bytes, offset)
    : ByteData.sublistView(bytes).getUint64(offset);
String _type(Uint8List bytes, int offset) =>
    latin1.decode(Uint8List.sublistView(bytes, offset, offset + 4));
bool _sameBytes(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

class _Box {
  const _Box(
    this.start,
    this.size,
    this.headerSize,
    this.type,
    this.extendsToEnd,
  );
  final int start;
  final int size;
  final int headerSize;
  final String type;
  final bool extendsToEnd;
  int get end => start + size;
  int get payload => start + headerSize;
  int get payloadLength => size - headerSize;
}

class _MovieFile {
  _MovieFile(this.length, this.boxes, this.movie, this.movieBytes)
    : _mediaBoxes = boxes
          .where((box) => box.type == 'mdat')
          .toList(growable: false);
  final int length;
  final List<_Box> boxes;
  final _Box movie;
  final Uint8List movieBytes;
  final List<_Box> _mediaBoxes;

  bool containsMediaOffset(int offset) {
    var low = 0;
    var high = _mediaBoxes.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      final media = _mediaBoxes[middle];
      if (offset < media.payload) {
        high = middle;
      } else if (offset >= media.end) {
        low = middle + 1;
      } else {
        return true;
      }
    }
    return false;
  }
}

class _UnsupportedM4a extends FormatException {
  const _UnsupportedM4a() : super('Unsupported MP4 audio layout');
}
