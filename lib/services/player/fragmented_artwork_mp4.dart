import 'dart:io';
import 'dart:typed_data';

import '../../core/utils/background_work.dart';

const maxFragmentedArtworkMp4Bytes = 16 * 1024 * 1024;
const _maxArtworkSeconds = 600;
const _maxArtworkSamples = 100000;

/// Supplies missing global duration metadata for completed Apple artwork.
/// Windows Media Foundation can otherwise treat its fragmented MP4 as empty.
/// Simple self-contained streams also lose the HLS-only initial time offset.
/// The caller scopes this to Windows artwork, before publishing the cache file.
/// I/O errors after writing begins propagate so the caller discards that file.
Future<bool> repairFragmentedArtworkMp4(File file) {
  final path = file.path;
  return runBackgroundWork(
    () => _repairFile(path),
    debugName: 'Repair artwork MP4 duration',
  );
}

bool _repairFile(String path) {
  RandomAccessFile? output;
  var writing = false;
  try {
    final file = File(path);
    final length = file.lengthSync();
    if (length < 24 || length > maxFragmentedArtworkMp4Bytes) return false;
    final bytes = file.readAsBytesSync();
    if (bytes.length != length) return false;
    final repairs = _durationRepairs(bytes);
    if (repairs.isEmpty) return false;
    final data = ByteData.sublistView(bytes);
    for (final repair in repairs) {
      repair.write(data);
    }
    // Append mode opens without truncation. RandomAccessFile.setPosition
    // lets us replace only the validated timing fields, preserving media.
    output = file.openSync(mode: FileMode.append);
    if (output.lengthSync() != length) return false;
    for (final repair in repairs) {
      output.setPositionSync(repair.offset);
      writing = true;
      output.writeFromSync(bytes, repair.offset, repair.offset + repair.width);
    }
    output.flushSync();
    return true;
  } on FileSystemException {
    if (writing) rethrow;
    return false;
  } finally {
    if (writing) {
      output?.closeSync();
    } else {
      try {
        output?.closeSync();
      } on FileSystemException {
        // No file bytes have changed yet.
      }
    }
  }
}

/// Returns a copy with repaired timing metadata, or null for unchanged,
/// malformed or unsupported files. Neither input bytes nor media boxes change.
Uint8List? repairedFragmentedArtworkMp4(Uint8List bytes) {
  final repairs = _durationRepairs(bytes);
  if (repairs.isEmpty) return null;
  final result = Uint8List.fromList(bytes);
  final data = ByteData.sublistView(result);
  for (final repair in repairs) {
    repair.write(data);
  }
  return result;
}

List<_TimingPatch> _durationRepairs(Uint8List bytes) {
  if (bytes.length < 24 || bytes.length > maxFragmentedArtworkMp4Bytes) {
    return const [];
  }
  try {
    return _Mp4Durations(ByteData.sublistView(bytes)).repairs();
  } on _UnsupportedMp4 {
    return const [];
  }
}

class _Mp4Durations {
  _Mp4Durations(this.data);

  final ByteData data;
  int _sampleCount = 0;
  int _boxCount = 0;

  List<_TimingPatch> repairs() {
    final top = _boxes(0, data.lengthInBytes);
    _one(top, _ftyp);
    final movie = _one(top, _moov);
    final fragments = top.where((box) => box.type == _moof).toList();
    if (fragments.isEmpty || !top.any((box) => box.type == _mdat)) {
      throw const _UnsupportedMp4();
    }
    final children = _children(movie);
    final movieHeader = _one(children, _mvhd);
    final movieVersion = _version(movieHeader, 100, 112);
    final movieScale = _u32(
      movieHeader.payload + (movieVersion == 0 ? 12 : 20),
    );
    if (movieScale == 0) throw const _UnsupportedMp4();
    final movieDuration = _durationField(movieHeader, movieVersion, 16, 24);

    // Artwork has one video track. Edit lists and additional tracks need a
    // different timeline calculation; leave those files byte-for-byte intact.
    final track = _one(children, _trak);
    final trackBoxes = _children(track);
    if (trackBoxes.any((box) => box.type == _edts)) {
      throw const _UnsupportedMp4();
    }
    final trackHeader = _one(trackBoxes, _tkhd);
    final trackVersion = _version(trackHeader, 84, 96);
    final trackId = _u32(trackHeader.payload + (trackVersion == 0 ? 12 : 20));
    if (trackId == 0) throw const _UnsupportedMp4();
    final trackDuration = _durationField(trackHeader, trackVersion, 20, 28);
    final media = _children(_one(trackBoxes, _mdia));
    final handler = _one(media, _hdlr);
    if (_version(handler, 24, 0) != 0 || _u32(handler.payload + 8) != _vide) {
      throw const _UnsupportedMp4();
    }
    final mediaHeader = _one(media, _mdhd);
    final mediaVersion = _version(mediaHeader, 24, 36);
    final mediaScale = _u32(
      mediaHeader.payload + (mediaVersion == 0 ? 12 : 20),
    );
    if (mediaScale == 0) throw const _UnsupportedMp4();
    final mediaDuration = _durationField(mediaHeader, mediaVersion, 16, 24);

    final extendsBoxes = _children(_one(children, _mvex));
    if (extendsBoxes.any((box) => box.type == _mehd)) {
      throw const _UnsupportedMp4();
    }
    final defaults = _one(extendsBoxes, _trex);
    if (_version(defaults, 24, 0) != 0 ||
        _u32(defaults.payload + 4) != trackId) {
      throw const _UnsupportedMp4();
    }
    final defaultDuration = _u32(defaults.payload + 12);
    final maximumTicks = mediaScale * _maxArtworkSeconds;
    var canRebase =
        movieDuration.value == 0 &&
        trackDuration.value == 0 &&
        mediaDuration.value == 0 &&
        _only(top, {_ftyp, _moov, _moof, _mdat, _free, _skip}) &&
        _only(children, {_mvhd, _trak, _mvex, _udta, _free}) &&
        _only(trackBoxes, {_tkhd, _mdia, _free}) &&
        _only(media, {_mdhd, _hdlr, _minf}) &&
        _only(extendsBoxes, {_trex}) &&
        _selfContainedVideo(media);
    final decodeTimes = <_DurationField>[];
    int? initialDecodeTime;
    int? firstPresentation;
    var lastPresentation = 0;
    var end = 0;
    for (final fragment in fragments) {
      final fragmentBoxes = _children(fragment);
      final runBoxes = _children(_one(fragmentBoxes, _traf));
      canRebase =
          canRebase &&
          _only(fragmentBoxes, {_mfhd, _traf}) &&
          _only(runBoxes, {_tfhd, _tfdt, _trun});
      final header = _one(runBoxes, _tfhd);
      if (_version(header, 8, 0) != 0) throw const _UnsupportedMp4();
      final flags = _flags(header);
      if (flags & ~0x02003b != 0 || _u32(header.payload + 4) != trackId) {
        throw const _UnsupportedMp4();
      }
      var cursor = header.payload + 8;
      if (flags & 1 != 0) cursor += 8;
      if (flags & 2 != 0) cursor += 4;
      final sampleDuration = flags & 8 != 0
          ? _fieldU32(header, cursor)
          : defaultDuration;
      if (flags & 8 != 0) cursor += 4;
      if (flags & 0x10 != 0) cursor += 4;
      if (flags & 0x20 != 0) cursor += 4;
      if (cursor != header.end) throw const _UnsupportedMp4();

      final decodeTime = _one(runBoxes, _tfdt);
      final decodeVersion = _version(decodeTime, 8, 12);
      var runEnd = decodeVersion == 0
          ? _u32(decodeTime.payload + 4)
          : _u64(decodeTime.payload + 4);
      if (runEnd < end || runEnd > maximumTicks) {
        throw const _UnsupportedMp4();
      }
      if (initialDecodeTime == null) {
        initialDecodeTime = runEnd;
      } else if (runEnd != end) {
        canRebase = false;
      }
      decodeTimes.add(
        _DurationField(
          decodeTime.payload + 4,
          decodeVersion == 0 ? 4 : 8,
          runEnd,
        ),
      );
      final runs = runBoxes.where((box) => box.type == _trun).toList();
      if (runs.isEmpty) throw const _UnsupportedMp4();
      for (final run in runs) {
        final runVersion = _version(run, 8, 8);
        final runFlags = _flags(run);
        if (runFlags & ~0x000f05 != 0 || runFlags & 0x404 == 0x404) {
          throw const _UnsupportedMp4();
        }
        final count = _u32(run.payload + 4);
        _sampleCount += count;
        if (count == 0 || _sampleCount > _maxArtworkSamples) {
          throw const _UnsupportedMp4();
        }
        var sample = run.payload + 8;
        if (runFlags & 1 != 0) sample += 4;
        if (runFlags & 4 != 0) sample += 4;
        final fields = [
          0x100,
          0x200,
          0x400,
          0x800,
        ].where((flag) => runFlags & flag != 0).length;
        if (sample + count * fields * 4 != run.end) {
          throw const _UnsupportedMp4();
        }
        for (var index = 0; index < count; index++) {
          final duration = runFlags & 0x100 != 0
              ? _u32(sample)
              : sampleDuration;
          if (duration == 0 || duration > maximumTicks - runEnd) {
            throw const _UnsupportedMp4();
          }
          final compositionOffset = runFlags & 0x800 == 0
              ? 0
              : runVersion == 0
              ? _u32(sample + (fields - 1) * 4)
              : data.getInt32(sample + (fields - 1) * 4, Endian.big);
          final presentation = runEnd + compositionOffset;
          if (firstPresentation == null || presentation < firstPresentation) {
            firstPresentation = presentation;
          }
          final presentationEnd = presentation + duration;
          if (presentationEnd > lastPresentation) {
            lastPresentation = presentationEnd;
          }
          runEnd += duration;
          sample += fields * 4;
        }
      }
      end = runEnd;
    }
    if (end == 0) throw const _UnsupportedMp4();
    // HLS masters commonly start decoding at 10s. Rebase only when the
    // complete decode/presentation ranges agree, without indexes, edits or
    // encryption that would also require timeline changes. Signed B-frame
    // composition offsets remain untouched and cannot become negative here.
    final base = initialDecodeTime!;
    final rebase =
        canRebase &&
        base > 0 &&
        firstPresentation == base &&
        lastPresentation == end;
    final duration = rebase ? end - base : end;
    final movieTicks =
        ((BigInt.from(duration) * BigInt.from(movieScale) +
                    BigInt.from(mediaScale - 1)) ~/
                BigInt.from(mediaScale))
            .toInt();
    return [
      if (movieDuration.value == 0) movieDuration.repair(movieTicks),
      if (trackDuration.value == 0) trackDuration.repair(movieTicks),
      if (mediaDuration.value == 0) mediaDuration.repair(duration),
      if (rebase)
        for (final decode in decodeTimes)
          _TimingPatch(decode.offset, decode.width, decode.value - base),
    ];
  }

  bool _only(List<_Box> boxes, Set<int> types) =>
      boxes.every((box) => types.contains(box.type));

  bool _selfContainedVideo(List<_Box> media) {
    try {
      final minf = _children(_one(media, _minf));
      if (!_only(minf, {_vmhd, _dinf, _stbl, _free})) return false;
      final samples = _children(_one(minf, _stbl));
      if (!_only(samples, {_stsd, _stts, _stsc, _stsz, _stco, _co64, _stss})) {
        return false;
      }
      for (final table in samples.where((box) => box.type != _stsd)) {
        final sizeTable = table.type == _stsz;
        final expected = sizeTable ? 12 : 8;
        if (table.end - table.payload != expected ||
            _u32(table.payload) != 0 ||
            _u32(table.payload + (sizeTable ? 8 : 4)) != 0) {
          return false;
        }
      }
      final description = _one(samples, _stsd);
      if (_version(description, 8, 0) != 0 ||
          _u32(description.payload + 4) != 1) {
        return false;
      }
      final entries = _boxes(description.payload + 8, description.end);
      if (entries.length != 1 ||
          (entries.single.type != _avc1 && entries.single.type != _avc3) ||
          entries.single.end - entries.single.payload < 78) {
        return false;
      }
      final codecBoxes = _boxes(
        entries.single.payload + 78,
        entries.single.end,
      );
      return codecBoxes.every((box) {
        // Apple's H.264 descriptions contain reserved 4snf padding and a
        // two-byte chroma descriptor. Neither carries timeline indexes. Only
        // accept the observed all-zero padding, not an unknown 4snf payload.
        if (box.type == _fourSnf) {
          return data.buffer
              .asUint8List(
                data.offsetInBytes + box.payload,
                box.end - box.payload,
              )
              .every((value) => value == 0);
        }
        if (box.type == _chrm) {
          return box.end - box.payload == 2 &&
              data.getUint8(box.payload) == 1 &&
              data.getUint8(box.payload + 1) == 1;
        }
        return {_avcC, _pasp, _btrt, _colr, _clap, _fiel}.contains(box.type);
      });
    } on _UnsupportedMp4 {
      return false;
    }
  }

  _DurationField _durationField(_Box box, int version, int v0, int v1) {
    final offset = box.payload + (version == 0 ? v0 : v1);
    return _DurationField(
      offset,
      version == 0 ? 4 : 8,
      version == 0 ? _u32(offset) : _u64(offset),
    );
  }

  int _version(_Box box, int minimumV0, int minimumV1) {
    if (box.end - box.payload < 4) throw const _UnsupportedMp4();
    final version = data.getUint8(box.payload);
    final minimum = switch (version) {
      0 => minimumV0,
      1 => minimumV1,
      _ => 0,
    };
    if (minimum == 0 || box.end - box.payload < minimum) {
      throw const _UnsupportedMp4();
    }
    return version;
  }

  int _flags(_Box box) => _u32(box.payload) & 0xffffff;

  int _fieldU32(_Box box, int offset) {
    if (offset + 4 > box.end) throw const _UnsupportedMp4();
    return _u32(offset);
  }

  int _u32(int offset) => data.getUint32(offset, Endian.big);

  int _u64(int offset) {
    final value = data.getUint64(offset, Endian.big);
    if (value < 0) throw const _UnsupportedMp4();
    return value;
  }

  List<_Box> _children(_Box box) => _boxes(box.payload, box.end);

  List<_Box> _boxes(int start, int end) {
    final boxes = <_Box>[];
    var cursor = start;
    while (cursor < end) {
      if (++_boxCount > 8192) throw const _UnsupportedMp4();
      if (end - cursor < 8) throw const _UnsupportedMp4();
      var size = _u32(cursor);
      final type = _u32(cursor + 4);
      var header = 8;
      if (size == 1) {
        if (end - cursor < 16) throw const _UnsupportedMp4();
        size = _u64(cursor + 8);
        header = 16;
      }
      if (size == 0 && type == _mdat && end == data.lengthInBytes) {
        size = end - cursor;
      }
      if (size < header || size > end - cursor) {
        throw const _UnsupportedMp4();
      }
      boxes.add(_Box(type, cursor + header, cursor + size));
      cursor += size;
    }
    return boxes;
  }

  _Box _one(List<_Box> boxes, int type) {
    final matches = boxes.where((box) => box.type == type).toList();
    if (matches.length != 1) throw const _UnsupportedMp4();
    return matches.single;
  }
}

class _Box {
  const _Box(this.type, this.payload, this.end);
  final int type;
  final int payload;
  final int end;
}

class _DurationField {
  const _DurationField(this.offset, this.width, this.value);
  final int offset;
  final int width;
  final int value;

  _TimingPatch repair(int duration) {
    if (duration <= 0 || (width == 4 && duration > 0xffffffff)) {
      throw const _UnsupportedMp4();
    }
    return _TimingPatch(offset, width, duration);
  }
}

class _TimingPatch {
  const _TimingPatch(this.offset, this.width, this.duration);
  final int offset;
  final int width;
  final int duration;

  void write(ByteData data) {
    if (width == 4) {
      data.setUint32(offset, duration, Endian.big);
    } else {
      data.setUint64(offset, duration, Endian.big);
    }
  }
}

class _UnsupportedMp4 implements Exception {
  const _UnsupportedMp4();
}

const _ftyp = 0x66747970;
const _moov = 0x6d6f6f76;
const _mvhd = 0x6d766864;
const _trak = 0x7472616b;
const _tkhd = 0x746b6864;
const _edts = 0x65647473;
const _mdia = 0x6d646961;
const _mdhd = 0x6d646864;
const _hdlr = 0x68646c72;
const _vide = 0x76696465;
const _mvex = 0x6d766578;
const _trex = 0x74726578;
const _mehd = 0x6d656864;
const _moof = 0x6d6f6f66;
const _traf = 0x74726166;
const _tfhd = 0x74666864;
const _tfdt = 0x74666474;
const _trun = 0x7472756e;
const _mdat = 0x6d646174;
const _free = 0x66726565;
const _skip = 0x736b6970;
const _udta = 0x75647461;
const _minf = 0x6d696e66;
const _mfhd = 0x6d666864;
const _vmhd = 0x766d6864;
const _dinf = 0x64696e66;
const _stbl = 0x7374626c;
const _stsd = 0x73747364;
const _stts = 0x73747473;
const _stsc = 0x73747363;
const _stsz = 0x7374737a;
const _stco = 0x7374636f;
const _co64 = 0x636f3634;
const _stss = 0x73747373;
const _avc1 = 0x61766331;
const _avc3 = 0x61766333;
const _avcC = 0x61766343;
const _pasp = 0x70617370;
const _btrt = 0x62747274;
const _colr = 0x636f6c72;
const _clap = 0x636c6170;
const _fiel = 0x6669656c;
const _fourSnf = 0x34736e66;
const _chrm = 0x6368726d;
