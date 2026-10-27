import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bstream_music/services/player/fragmented_artwork_mp4.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fixtureDirectory = String.fromEnvironment('BSTREAM_APPLE_MP4_FIXTURES');
  for (final fixture in [
    ('apple-artwork-windows-square.mp4', 480),
    ('apple-artwork-windows-coldplay.mp4', 450),
  ]) {
    test('repairs real Apple fixture ${fixture.$1}', () async {
      final original = await File(
        '$fixtureDirectory/${fixture.$1}',
      ).readAsBytes();
      final repaired = repairedFragmentedArtworkMp4(original)!;
      expect(_duration(repaired, 'mdhd', 0), fixture.$2);
      expect(_decodeTimes(repaired).first, 0);
      _expectOnlyDurationFieldsChanged(original, repaired, 0);
    }, skip: fixtureDirectory.isEmpty);
  }

  for (final version in [0, 1]) {
    test('repairs version $version durations without changing media bytes', () {
      final input = _fixture(version: version);
      final original = Uint8List.fromList(input);
      final repaired = repairedFragmentedArtworkMp4(input)!;

      expect(_duration(repaired, 'mvhd', version), 500);
      expect(_duration(repaired, 'tkhd', version), 500);
      expect(_duration(repaired, 'mdhd', version), 12);
      expect(_decodeTimes(repaired), [0, 6]);
      expect(input, orderedEquals(original));
      _expectOnlyDurationFieldsChanged(original, repaired, version);
      expect(repairedFragmentedArtworkMp4(repaired), isNull);
    });
  }

  for (final source in _DurationSource.values) {
    test('derives fragmented duration from ${source.name}', () {
      final input = _fixture(source: source);
      final repaired = repairedFragmentedArtworkMp4(input)!;
      expect(_duration(repaired, 'mdhd', 0), 12);
      _expectOnlyDurationFieldsChanged(input, repaired, 0);
    });
  }

  test('keeps existing durations while repairing only zero fields', () {
    final input = _fixture();
    _data(input).setUint32(_durationOffset(input, 'mvhd', 0), 17);
    final repaired = repairedFragmentedArtworkMp4(input)!;
    expect(_duration(repaired, 'mvhd', 0), 17);
    expect(_duration(repaired, 'tkhd', 0), 10500);
    expect(_duration(repaired, 'mdhd', 0), 252);
    expect(_decodeTimes(repaired), [240, 246]);
    for (final type in ['mvhd', 'tkhd', 'mdhd']) {
      _data(input).setUint32(_durationOffset(input, type, 0), 17);
    }
    expect(repairedFragmentedArtworkMp4(input), isNull);
  });

  test('reads version-one trun with signed composition offsets', () {
    final input = _fixture(
      source: _DurationSource.tfhdDefault,
      compositionOffsets: true,
    );
    final repaired = repairedFragmentedArtworkMp4(input)!;
    expect(_duration(repaired, 'mdhd', 0), 12);
    expect(_decodeTimes(repaired), [0, 6]);
    _expectOnlyDurationFieldsChanged(input, repaired, 0);
  });

  test('rounds movie duration upward when track timescales differ', () {
    final input = _fixture();
    _data(input).setUint32(_payload(input, 'mvhd') + 12, 7);
    final repaired = repairedFragmentedArtworkMp4(input)!;
    expect(_duration(repaired, 'mvhd', 0), 4);
    expect(_duration(repaired, 'tkhd', 0), 4);
    expect(_duration(repaired, 'mdhd', 0), 12);
  });

  test('keeps timestamps for indexed, encrypted or unknown timelines', () {
    for (final input in [
      _fixture(index: true),
      _fixture(encrypted: true),
      _fixture(unknownRunBox: true),
      _fixture(compositionOffsets: true),
      _changed(
        _fixture(),
        (data) => data.setUint8(_payload(_fixture(), '4snf'), 1),
      ),
      _changed(
        _fixture(),
        (data) => data.setUint8(_payload(_fixture(), 'chrm'), 2),
      ),
    ]) {
      final repaired = repairedFragmentedArtworkMp4(input)!;
      expect(_duration(repaired, 'mdhd', 0), 252);
      expect(_decodeTimes(repaired), [240, 246]);
      _expectOnlyDurationFieldsChanged(input, repaired, 0);
    }
  });

  test('leaves extra tracks, edit lists and audio files unchanged', () {
    for (final input in [
      _fixture(extraTrack: true),
      _fixture(editList: true),
      _fixture(handler: 'soun'),
      _fixture(fragmented: false),
    ]) {
      final original = Uint8List.fromList(input);
      expect(repairedFragmentedArtworkMp4(input), isNull);
      expect(input, orderedEquals(original));
    }
  });

  test('rejects truncated, invalid and unsupported boxes without mutation', () {
    final valid = _fixture(version: 1);
    final invalid = <Uint8List>[
      for (final cut in [0, 7, 16, 33, valid.length - 1])
        Uint8List.sublistView(valid, 0, cut),
      _changed(valid, (data) => data.setUint32(0, 0xffffffff)),
      _changed(valid, (data) => data.setUint32(0, 0)),
      _changed(valid, (data) => data.setUint32(0, 1)),
      _changed(valid, (data) => data.setUint8(_payload(valid, 'mvhd'), 2)),
      _changed(
        valid,
        (data) => data.setUint32(_payload(valid, 'mdhd') + 20, 0),
      ),
      _changed(
        valid,
        (data) => data.setUint64(_payload(valid, 'tfdt') + 4, -1),
      ),
      _changed(
        valid,
        (data) => data.setUint64(_payload(valid, 'tfdt') + 4, 1000000),
      ),
      _changed(valid, (data) => data.setUint32(_payload(valid, 'trun') + 4, 0)),
      _changed(
        valid,
        (data) => data.setUint32(_payload(valid, 'tfhd'), 0x00010000),
      ),
      _changed(
        valid,
        (data) => data.setUint32(_payload(valid, 'trun'), 0x00800100),
      ),
    ];
    for (final input in invalid) {
      final original = Uint8List.fromList(input);
      expect(repairedFragmentedArtworkMp4(input), isNull);
      expect(input, orderedEquals(original));
    }
  });

  test('malformed byte fuzz never throws or changes the input', () {
    final random = Random(71903);
    for (var iteration = 0; iteration < 250; iteration++) {
      final input = _fixture(version: iteration.isEven ? 0 : 1);
      for (var change = 0; change < 6; change++) {
        input[random.nextInt(input.length)] = random.nextInt(256);
      }
      final original = Uint8List.fromList(input);
      repairedFragmentedArtworkMp4(input);
      expect(input, orderedEquals(original));
    }
    expect(
      repairedFragmentedArtworkMp4(Uint8List(maxFragmentedArtworkMp4Bytes + 1)),
      isNull,
    );
  });

  test(
    'file worker patches only duration bytes and preserves file size',
    () async {
      final directory = await Directory.systemTemp.createTemp('artwork_mp4_');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/artwork.mp4');
      final original = _fixture(version: 1);
      await file.writeAsBytes(original);

      expect(await repairFragmentedArtworkMp4(file), isTrue);
      final repaired = await file.readAsBytes();
      expect(_duration(repaired, 'mvhd', 1), 500);
      expect(_duration(repaired, 'mdhd', 1), 12);
      expect(_decodeTimes(repaired), [0, 6]);
      _expectOnlyDurationFieldsChanged(original, repaired, 1);
      expect(await repairFragmentedArtworkMp4(file), isFalse);
      expect(await file.readAsBytes(), orderedEquals(repaired));

      final truncated = Uint8List.sublistView(original, 0, original.length - 1);
      await file.writeAsBytes(truncated);
      expect(await repairFragmentedArtworkMp4(file), isFalse);
      expect(await file.readAsBytes(), orderedEquals(truncated));
    },
  );
}

enum _DurationSource { perSample, tfhdDefault, trexDefault }

Uint8List _fixture({
  int version = 0,
  _DurationSource source = _DurationSource.perSample,
  bool compositionOffsets = false,
  bool extraTrack = false,
  bool editList = false,
  bool fragmented = true,
  bool index = false,
  bool encrypted = false,
  bool unknownRunBox = false,
  String handler = 'vide',
}) {
  final movie = Uint8List(version == 0 ? 100 : 112);
  final track = Uint8List(version == 0 ? 84 : 96);
  final media = Uint8List(version == 0 ? 24 : 36);
  movie[0] = track[0] = media[0] = version;
  _data(movie).setUint32(version == 0 ? 12 : 20, 1000);
  _data(track).setUint32(version == 0 ? 12 : 20, 1);
  _data(media).setUint32(version == 0 ? 12 : 20, 24);
  final handlerBytes = Uint8List(24)..setRange(8, 12, ascii.encode(handler));
  final description = Uint8List.fromList([
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    ..._box(encrypted ? 'encv' : 'avc1', [
      ...Uint8List(78),
      ..._box('4snf', Uint8List(89)),
      ..._box('chrm', [1, 1]),
    ]),
  ]);
  final trackBox = _box('trak', [
    ..._box('tkhd', track),
    if (editList) ..._box('edts', []),
    ..._box('mdia', [
      ..._box('mdhd', media),
      ..._box('hdlr', handlerBytes),
      ..._box(
        'minf',
        _box('stbl', [
          ..._box('stsd', description),
          ..._box('stts', Uint8List(8)),
          ..._box('stsc', Uint8List(8)),
          ..._box('stsz', Uint8List(12)),
          ..._box('stco', Uint8List(8)),
        ]),
      ),
    ]),
  ]);
  final defaults = Uint8List(24);
  _data(defaults)
    ..setUint32(4, 1)
    ..setUint32(8, 1)
    ..setUint32(12, source == _DurationSource.trexDefault ? 2 : 0)
    ..setUint32(16, 1);
  final bytes = <int>[
    ..._box('ftyp', [...ascii.encode('iso6'), 0, 0, 0, 1]),
    if (index) ..._box('sidx', Uint8List(24)),
    ..._box('moov', [
      ..._box('mvhd', movie),
      ...trackBox,
      if (extraTrack) ...trackBox,
      ..._box('mvex', _box('trex', defaults)),
    ]),
  ];
  for (var fragment = 0; fragment < (fragmented ? 2 : 0); fragment++) {
    final header = Uint8List(source == _DurationSource.tfhdDefault ? 12 : 8);
    _data(header)
      ..setUint32(0, 0x020000 | (source == _DurationSource.tfhdDefault ? 8 : 0))
      ..setUint32(4, 1);
    if (source == _DurationSource.tfhdDefault) {
      _data(header).setUint32(8, 2);
    }
    final decodeTime = Uint8List(version == 0 ? 8 : 12)..[0] = version;
    if (version == 0) {
      _data(decodeTime).setUint32(4, 240 + fragment * 6);
    } else {
      _data(decodeTime).setUint64(4, 240 + fragment * 6);
    }
    final sampleFields =
        (source == _DurationSource.perSample ? 1 : 0) +
        (compositionOffsets ? 1 : 0);
    final run = Uint8List(8 + 3 * sampleFields * 4);
    _data(run)
      ..setUint32(
        0,
        (compositionOffsets ? 0x01000800 : 0) |
            (source == _DurationSource.perSample ? 0x100 : 0),
      )
      ..setUint32(4, 3);
    var cursor = 8;
    for (var sample = 0; sample < 3; sample++) {
      if (source == _DurationSource.perSample) {
        _data(run).setUint32(cursor, sample + 1);
        cursor += 4;
      }
      if (compositionOffsets) {
        _data(run).setInt32(cursor, sample == 0 ? 0 : (sample == 1 ? 2 : -2));
        cursor += 4;
      }
    }
    bytes.addAll([
      ..._box(
        'moof',
        _box('traf', [
          ..._box('tfhd', header),
          ..._box('tfdt', decodeTime),
          ..._box('trun', run),
          if (unknownRunBox) ..._box('senc', Uint8List(8)),
        ]),
      ),
      ..._box('mdat', List.generate(16, (index) => index + fragment)),
    ]);
  }
  if (!fragmented) bytes.addAll(_box('mdat', [1, 2, 3, 4]));
  return Uint8List.fromList(bytes);
}

Uint8List _box(String type, List<int> payload) {
  final result = Uint8List(8 + payload.length);
  _data(result).setUint32(0, result.length);
  result.setRange(4, 8, ascii.encode(type));
  result.setRange(8, result.length, payload);
  return result;
}

ByteData _data(Uint8List bytes) => ByteData.sublistView(bytes);

int _payload(Uint8List bytes, String type) {
  final tag = ascii.encode(type);
  for (var offset = 4; offset + 4 <= bytes.length; offset++) {
    if (List.generate(
      4,
      (index) => bytes[offset + index],
    ).indexed.every((entry) => entry.$2 == tag[entry.$1])) {
      return offset + 4;
    }
  }
  throw StateError('Missing box $type');
}

int _durationOffset(Uint8List bytes, String type, int version) =>
    _payload(bytes, type) +
    (type == 'tkhd' ? (version == 0 ? 20 : 28) : (version == 0 ? 16 : 24));

int _duration(Uint8List bytes, String type, int version) {
  final offset = _durationOffset(bytes, type, version);
  return version == 0
      ? _data(bytes).getUint32(offset)
      : _data(bytes).getUint64(offset);
}

Uint8List _changed(Uint8List bytes, void Function(ByteData) change) {
  final result = Uint8List.fromList(bytes);
  change(_data(result));
  return result;
}

List<int> _decodeTimes(Uint8List bytes) => [
  for (final offset in _payloads(bytes, 'tfdt'))
    if (bytes[offset] == 0)
      _data(bytes).getUint32(offset + 4)
    else
      _data(bytes).getUint64(offset + 4),
];

List<int> _payloads(Uint8List bytes, String type) {
  final tag = ascii.encode(type);
  return [
    for (var offset = 4; offset + 4 <= bytes.length; offset++)
      if (List.generate(
        4,
        (index) => bytes[offset + index],
      ).indexed.every((entry) => entry.$2 == tag[entry.$1]))
        offset + 4,
  ];
}

void _expectOnlyDurationFieldsChanged(
  Uint8List original,
  Uint8List repaired,
  int version,
) {
  expect(repaired.length, original.length);
  final allowed = <int>{
    for (final type in ['mvhd', 'tkhd', 'mdhd'])
      for (var index = 0; index < (version == 0 ? 4 : 8); index++)
        _durationOffset(original, type, version) + index,
    for (final payload in _payloads(original, 'tfdt'))
      for (var index = 0; index < (original[payload] == 0 ? 4 : 8); index++)
        payload + 4 + index,
  };
  for (var index = 0; index < original.length; index++) {
    if (repaired[index] != original[index]) {
      expect(allowed.contains(index), isTrue, reason: 'Changed byte $index');
    }
  }
}
