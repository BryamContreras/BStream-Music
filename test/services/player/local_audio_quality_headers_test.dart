import 'dart:io';
import 'dart:typed_data';

import 'package:bstream_music/services/audio_sources/mp4_audio_format.dart';
import 'package:bstream_music/services/audio_sources/webm_audio_format.dart';
import 'package:bstream_music/services/player/local_audio_quality_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory fixtures;
  late LocalAudioQualityService service;

  setUp(() async {
    fixtures = await Directory.systemTemp.createTemp(
      'bstream_audio_quality_headers_',
    );
    service = LocalAudioQualityService();
  });

  tearDown(() async {
    service.dispose();
    // This exact directory was created by this test, never a workspace root.
    expect(
      fixtures.uri.pathSegments.where((part) => part.isNotEmpty).last,
      startsWith('bstream_audio_quality_headers_'),
    );
    await fixtures.delete(recursive: true);
  });

  Future<LocalAudioQuality?> read(
    List<int> bytes, [
    String name = 'audio',
  ]) async {
    final file = File('${fixtures.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(bytes);
    return service.read(file.path);
  }

  test(
    'WAV PCM stereo reports header rate, channels and encoded PCM bitrate',
    () async {
      final result = await read(_wave(rate: 44100, channels: 2), 'stereo.wav');
      expect(result?.codec, 'pcm_s16le');
      expect(result?.bitDepth, 16);
      expect(result?.sampleRate, 44100);
      expect(result?.channels, 2);
      expect(result?.bitrate, 1411200);
    },
  );

  test('PCM mono remains mono rather than assuming stereo', () async {
    final result = await read(_wave(rate: 48000, channels: 1), 'mono');
    expect(result?.codec, 'pcm_s16le');
    expect(result?.sampleRate, 48000);
    expect(result?.channels, 1);
    expect(result?.bitrate, 768000);
  });

  test(
    'FLAC STREAMINFO retains exact rate/channels without inventing bitrate',
    () async {
      final streamInfo = ByteData(34)
        ..setUint16(0, 4096)
        ..setUint16(2, 4096)
        ..setUint64(10, (96000 << 44) | (5 << 41) | (23 << 36) | 96000);
      final result = await read([
        ..._ascii('fLaC'),
        0x80,
        0,
        0,
        34,
        ...streamInfo.buffer.asUint8List(),
      ], 'surround.flac');
      expect(result?.codec, 'flac');
      expect(result?.bitDepth, 24);
      expect(result?.sampleRate, 96000);
      expect(result?.channels, 6);
      expect(result?.bitrate, isNull);
    },
  );

  test(
    'Ogg OpusHead uses 48 kHz coding rate, not advisory 44.1 kHz input',
    () async {
      final header = ByteData(19);
      header.buffer.asUint8List().setAll(0, _ascii('OpusHead'));
      header
        ..setUint8(8, 1)
        ..setUint8(9, 1)
        ..setUint16(10, 312, Endian.little)
        ..setUint32(12, 44100, Endian.little);
      final result = await read(
        _oggPage(header.buffer.asUint8List()),
        'opus.ogg',
      );
      expect(result?.codec, 'opus');
      expect(result?.sampleRate, 48000);
      expect(result?.channels, 1);
      expect(result?.bitrate, isNull);
    },
  );

  test('Ogg Vorbis reads the declared nominal bitrate', () async {
    final header = ByteData(30);
    header.buffer.asUint8List().setAll(0, [1, ..._ascii('vorbis')]);
    header
      ..setUint8(11, 2)
      ..setUint32(12, 44100, Endian.little)
      ..setInt32(20, 128000, Endian.little)
      ..setUint8(28, 0xb8)
      ..setUint8(29, 1);
    final result = await read(_oggPage(header.buffer.asUint8List()), 'vorbis');
    expect(result?.codec, 'vorbis');
    expect(result?.sampleRate, 44100);
    expect(result?.channels, 2);
    expect(result?.bitrate, 128000);
  });

  test('WebM reads Opus Tracks instead of false MPEG payload syncs', () async {
    final result = await read(
      _webm([
        ..._ebml(0x1941a469, Uint8List(300 * 1024)), // Skip attachments.
        ..._ebml(0x1654ae6b, _webmAudioTrack()),
        ..._ebml(0x1f43b675, _mpegFrame()),
      ]),
      'download.webm',
    );
    expect(result?.codec, 'opus');
    expect(result?.sampleRate, 48000);
    expect(result?.channels, 2);
    expect(result?.bitrate, isNull);
  });

  test(
    'WebM without an unambiguous audio track never claims MP1/MP2',
    () async {
      final unknown = await read(
        _webm([..._ebml(0x1f43b675, _mpegFrame())]),
        'missing-tracks.webm',
      );
      expect(unknown?.mimeType, 'audio/webm');
      expect(unknown?.codec, isNull);
      final multiple = await read(
        _webm([
          ..._ebml(0x1654ae6b, [..._webmAudioTrack(), ..._webmAudioTrack()]),
        ]),
        'multiple.webm',
      );
      expect(multiple?.codec, isNull);
      expect(multiple?.sampleRate, isNull);
      expect(multiple?.channels, isNull);
    },
  );

  test('isolated MPEG sync in unknown binary is not an audio format', () async {
    expect(
      await read([
        ...Uint8List(32),
        ..._mpegFrame(),
        ...Uint8List(32),
      ], 'binary'),
      isNull,
    );
  });

  test('WebM average rate skips audio payloads, large covers and tags', () {
    final prefix = _webm([
      ..._webmInfo(),
      ..._ebml(0x1654ae6b, _webmAudioTrack()),
    ]);
    final cover = _ebml(0x1941a469, Uint8List(500 * 1024));
    final firstCluster = _ebml(0x1f43b675, Uint8List(67500));
    final secondCluster = _ebml(0x1f43b675, Uint8List(101250));
    final tags = _ebml(0x1254c367, Uint8List(300 * 1024));
    var offset = prefix.length;
    final forbidden = <(int, int)>[];
    for (final (element, payloadSize) in [
      (cover, 500 * 1024),
      (firstCluster, 67500),
      (secondCluster, 101250),
      (tags, 300 * 1024),
    ]) {
      forbidden.add((
        offset + element.length - payloadSize,
        offset + element.length,
      ));
      offset += element.length;
    }
    final reader = _AuditedHeaderReader(
      Uint8List.fromList([
        ...prefix,
        ...cover,
        ...firstCluster,
        ...secondCluster,
        ...tags,
      ]),
      forbidden: forbidden,
    );
    final result = readWebmAudioFormat(reader);
    expect(result?.codec, 'opus');
    expect(result?.bitrate, 135000);
    expect(reader.bytesRead, lessThan(4096));
    expect(reader.reads, lessThan(1024));
  });

  test('WebM average uses declared timecode scale and late Info', () async {
    final result = await read(
      _webm([
        ..._ebml(0x1654ae6b, _webmAudioTrack()),
        ..._ebml(0x1f43b675, Uint8List(168750)),
        ..._webmInfo(ticks: 5000, timecodeScale: 2000000),
      ]),
      'late-info.webm',
    );
    expect(result?.codec, 'opus');
    expect(result?.bitrate, 135000);
  });

  test(
    'WebM video and multiple tracks do not invent an audio bitrate',
    () async {
      final result = await read(
        _webm([
          ..._webmInfo(),
          ..._ebml(0x1654ae6b, [
            ..._ebml(0xae, [
              ..._ebml(0x83, [1]),
              ..._ebml(0x86, _ascii('V_VP9')),
            ]),
            ..._webmAudioTrack(),
          ]),
          ..._ebml(0x1f43b675, Uint8List(168750)),
        ]),
        'video-and-audio.webm',
      );
      expect(result?.codec, 'opus');
      expect(result?.bitrate, isNull);
    },
  );

  test('WebM unbounded clusters keep track details without bitrate', () async {
    final result = await read(
      _webm([
        ..._webmInfo(),
        ..._ebml(0x1654ae6b, _webmAudioTrack()),
        0x1f,
        0x43,
        0xb6,
        0x75,
        0xff,
        ...Uint8List(168750),
      ]),
      'unbounded-cluster.webm',
    );
    expect(result?.codec, 'opus');
    expect(result?.bitrate, isNull);
  });

  test('WebM invalid duration and scale leave average unknown', () async {
    for (final (name, info) in [
      ('missing', _ebml(0x1549a966, [])),
      ('zero', _webmInfo(ticks: 0)),
      ('negative', _webmInfo(ticks: -1)),
      ('nan', _webmInfo(ticks: double.nan)),
      ('infinite', _webmInfo(ticks: double.infinity)),
      ('scale-zero', _webmInfo(timecodeScale: 0)),
      ('duplicate-info', [..._webmInfo(), ..._webmInfo()]),
      (
        'duplicate-duration',
        _ebml(0x1549a966, [
          ..._ebml(
            0x4489,
            (ByteData(8)..setFloat64(0, 10000)).buffer.asUint8List(),
          ),
          ..._ebml(
            0x4489,
            (ByteData(8)..setFloat64(0, 5000)).buffer.asUint8List(),
          ),
        ]),
      ),
    ]) {
      final result = await read(
        _webm([
          ...info,
          ..._ebml(0x1654ae6b, _webmAudioTrack()),
          ..._ebml(0x1f43b675, Uint8List(168750)),
        ]),
        '$name.webm',
      );
      expect(result?.codec, 'opus', reason: name);
      expect(result?.bitrate, isNull, reason: name);
    }
  });

  test('WebM global element budget stops before claiming a partial rate', () {
    final reader = _AuditedHeaderReader(
      Uint8List.fromList(
        _webm([
          ..._ebml(0x1654ae6b, _webmAudioTrack()),
          ..._webmInfo(),
          for (var index = 0; index < 600; index++) ..._ebml(0xec, []),
          ..._ebml(0x1f43b675, Uint8List(168750)),
        ]),
      ),
    );
    final result = readWebmAudioFormat(reader);
    expect(result?.codec, 'opus');
    expect(result?.bitrate, isNull);
    expect(reader.reads, lessThan(1024));
    expect(reader.bytesRead, lessThan(4096));
  });

  test(
    'MP3 without global CBR/VBR facts never reports its first-frame bitrate',
    () async {
      final result = await read(_mpegFrame(), 'audio.mp3');
      expect(result?.codec, 'mp3');
      expect(result?.sampleRate, 44100);
      expect(result?.channels, 2);
      expect(result?.bitrate, isNull);
    },
  );

  test(
    'MP3 explicit Info CBR and Xing counters report honest stream bitrate',
    () async {
      final cbr = _mpegFrame();
      cbr.setAll(36, _ascii('Info'));
      final first = await read(cbr, 'cbr.mp3');
      expect(first?.bitrate, 128000);
      final vbr = _mpegFrame();
      vbr.setAll(36, _ascii('Xing'));
      ByteData.sublistView(vbr)
        ..setUint32(40, 3)
        ..setUint32(44, 100)
        ..setUint32(48, 48000);
      // 40 MPEG-1 128kbps frames of417 bytes +60 160kbps frames of522
      // bytes: valid frame boundaries match the declared 48,000-byte stream.
      final second = await read([
        ...vbr,
        for (var frame = 0; frame < 39; frame++) ..._mpegFrame(),
        for (var frame = 0; frame < 60; frame++)
          ..._mpegFrame(bitrateIndex: 10, length: 522),
      ], 'vbr.mp3');
      expect(second?.sampleRate, 44100);
      expect(second?.bitrate, 147000);
    },
  );

  test(
    'AAC ADTS supplies sample rate and mono configuration without fake bitrate',
    () async {
      // AAC-LC, rate index4=44.1kHz, channel config1, seven-byte ADTS header.
      final result = await read([
        0xff,
        0xf1,
        0x50,
        0x40,
        0x01,
        0x7f,
        0xfc,
        0,
        0,
        0,
        0,
      ], 'adts');
      expect(result?.codec, 'aac');
      expect(result?.sampleRate, 44100);
      expect(result?.channels, 1);
      expect(result?.bitrate, isNull);
    },
  );

  test(
    'M4A AAC AudioSpecificConfig overrides misleading sample-entry defaults',
    () async {
      final result = await read(_mp4([_aacEntry()]), 'audio.m4a');
      expect(result?.codec, 'aac');
      expect(result?.sampleRate, 44100);
      expect(result?.channels, 2);
      expect(result?.bitrate, 256000);
    },
  );

  test(
    'M4A ALAC preserves lossless codec and does not guess compressed bitrate',
    () async {
      final config = ByteData(24)
        ..setUint32(0, 4096)
        ..setUint8(5, 24)
        ..setUint8(6, 40)
        ..setUint8(7, 10)
        ..setUint8(8, 14)
        ..setUint8(9, 2)
        ..setUint16(10, 255)
        ..setUint32(20, 44100);
      final entry = _sampleEntry('alac', 44100, 2, [
        ..._atom('alac', [0, 0, 0, 0, ...config.buffer.asUint8List()]),
      ], bitDepth: 16);
      final result = await read(_mp4([entry]), 'lossless.m4a');
      expect(result?.codec, 'alac');
      expect(result?.bitDepth, 24);
      expect(result?.sampleRate, 44100);
      expect(result?.channels, 2);
      expect(result?.bitrate, isNull);
    },
  );

  test(
    'MP4 FLAC uses STREAMINFO precision rather than the container sample size',
    () async {
      final streamInfo = ByteData(34)
        ..setUint64(10, (96000 << 44) | (1 << 41) | (23 << 36) | 96000);
      final entry = _sampleEntry('fLaC', 44100, 2, [
        ..._atom('dfLa', [
          0,
          0,
          0,
          0,
          0x80,
          0,
          0,
          34,
          ...streamInfo.buffer.asUint8List(),
        ]),
      ], bitDepth: 16);
      final result = await read(_mp4([entry]), 'hires-flac.mp4');
      expect(result?.codec, 'flac');
      expect(result?.bitDepth, 24);
      expect(result?.sampleRate, 96000);
      expect(result?.channels, 2);
      expect(result?.bitrate, isNull);
    },
  );

  test(
    'video facts and ambiguous multiple audio tracks do not become audio quality',
    () async {
      final visualHeader = ByteData(78)
        ..setUint16(6, 1)
        ..setUint16(24, 1920)
        ..setUint16(26, 1080)
        ..setUint32(28, 72 << 16)
        ..setUint32(32, 72 << 16)
        ..setUint16(40, 1)
        ..setUint16(74, 24)
        ..setUint16(76, 0xffff);
      final video = _atom('avc1', [
        ...visualHeader.buffer.asUint8List(),
        ..._atom('btrt', [..._u32(0), ..._u32(8000000), ..._u32(8000000)]),
      ]);
      final single = await read([
        ..._ftyp(),
        ..._atom('moov', [
          ..._track([video]),
          ..._track([_aacEntry()]),
        ]),
      ], 'av.mp4');
      expect(single?.codec, 'aac');
      expect(single?.bitrate, 256000);
      final multiple = await read(
        _mp4([_aacEntry(), _aacEntry()]),
        'multi.mp4',
      );
      expect(multiple?.mimeType, 'audio/mp4');
      expect(multiple?.codec, isNull);
      expect(multiple?.sampleRate, isNull);
      expect(multiple?.channels, isNull);
      expect(multiple?.bitrate, isNull);
    },
  );

  test(
    'large embedded cover metadata is skipped without consuming the read budget',
    () async {
      final cover = _atom(
        'udta',
        _atom('meta', [
          0,
          0,
          0,
          0,
          ..._atom(
            'ilst',
            _atom(
              'covr',
              _atom('data', [
                0,
                0,
                0,
                13,
                0,
                0,
                0,
                0,
                ...Uint8List(2 * 1024 * 1024),
              ]),
            ),
          ),
        ]),
      );
      final result = await read(
        _mp4([_aacEntry()], extraMoov: cover),
        'cover.m4a',
      );
      expect(result?.codec, 'aac');
      expect(result?.sampleRate, 44100);
      expect(result?.bitrate, 256000);
    },
  );

  test(
    'excessive box count stops at the bounded scan without guessed details',
    () async {
      final bytes = [
        ..._ftyp(),
        for (var index = 0; index < 600; index++) ..._atom('free', []),
        ..._audioMoov([_aacEntry()]),
      ];
      final result = await read(bytes, 'many-boxes.mp4');
      expect(result?.codec, isNull);
      expect(result?.sampleRate, isNull);
      expect(result?.bitrate, isNull);
    },
  );

  test(
    'malformed/truncated headers and extensions never invent audio facts',
    () async {
      expect(await read([1, 2, 3, 4, 5], 'not-a-song.mp3'), isNull);
      expect(
        await read(_wave(rate: 44100, channels: 2).sublist(0, 28), 'cut.wav'),
        isNull,
      );
      expect(
        await read([..._ascii('ID3'), 4, 0, 0, 127, 127, 127, 127], 'bad-tag'),
        isNull,
      );
      final noExtension = await read(_mp4([_aacEntry()]), 'without-extension');
      expect(noExtension?.codec, 'aac');
    },
  );
}

List<int> _ascii(String text) => text.codeUnits;

List<int> _ebml(int id, List<int> payload) {
  final idWidth = (id.bitLength + 7) ~/ 8;
  var sizeWidth = 1;
  while (payload.length >= (1 << (7 * sizeWidth)) - 1) {
    sizeWidth++;
  }
  return [
    for (var index = idWidth - 1; index >= 0; index--)
      (id >> (8 * index)) & 255,
    for (var index = sizeWidth - 1; index >= 0; index--)
      ((payload.length | (1 << (7 * sizeWidth))) >> (8 * index)) & 255,
    ...payload,
  ];
}

List<int> _webm(List<int> payload) => [
  ..._ebml(0x1a45dfa3, _ebml(0x4282, _ascii('webm'))),
  0x18, 0x53, 0x80, 0x67, 0xff, // Segment with unknown length.
  ...payload,
];

List<int> _webmAudioTrack() => _ebml(0xae, [
  ..._ebml(0x83, [2]),
  ..._ebml(0x86, _ascii('A_OPUS')),
  ..._ebml(0xe1, [
    ..._ebml(0xb5, (ByteData(8)..setFloat64(0, 44100)).buffer.asUint8List()),
    ..._ebml(0x9f, [2]),
  ]),
]);

List<int> _webmInfo({double ticks = 10000, int? timecodeScale}) =>
    _ebml(0x1549a966, [
      if (timecodeScale != null) ..._ebml(0x2ad7b1, _u32(timecodeScale)),
      ..._ebml(
        0x4489,
        (ByteData(8)..setFloat64(0, ticks)).buffer.asUint8List(),
      ),
    ]);

class _AuditedHeaderReader implements AudioFormatHeaderReader {
  _AuditedHeaderReader(this.bytes, {this.forbidden = const []});
  final Uint8List bytes;
  final List<(int, int)> forbidden;
  int reads = 0;
  int bytesRead = 0;

  @override
  int get length => bytes.length;

  @override
  Uint8List? read(int offset, int count) {
    for (final (start, end) in forbidden) {
      if (offset < end && offset + count > start) {
        throw StateError('Probe read an audio or metadata payload.');
      }
    }
    reads++;
    bytesRead += count;
    if (offset < 0 ||
        offset + count > length ||
        reads > 1024 ||
        bytesRead > 256 * 1024) {
      return null;
    }
    return Uint8List.sublistView(bytes, offset, offset + count);
  }
}

List<int> _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

List<int> _wave({required int rate, required int channels}) {
  final bytes = Uint8List(44 + 1024);
  bytes.setAll(0, _ascii('RIFF'));
  bytes.setAll(8, _ascii('WAVEfmt '));
  bytes.setAll(36, _ascii('data'));
  ByteData.sublistView(bytes)
    ..setUint32(4, bytes.length - 8, Endian.little)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * channels * 2, Endian.little)
    ..setUint16(32, channels * 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(40, 1024, Endian.little);
  return bytes;
}

Uint8List _oggPage(Uint8List packet) {
  final page = Uint8List(28 + packet.length);
  page.setAll(0, _ascii('OggS'));
  page[5] = 2; // Beginning of logical stream.
  ByteData.sublistView(page).setUint32(14, 1, Endian.little);
  page[26] = 1;
  page[27] = packet.length;
  page.setAll(28, packet);
  var crc = 0;
  for (final byte in page) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc =
          ((crc << 1) ^ (crc & 0x80000000 != 0 ? 0x04c11db7 : 0)) & 0xffffffff;
    }
  }
  ByteData.sublistView(page).setUint32(22, crc, Endian.little);
  return page;
}

Uint8List _mpegFrame({int bitrateIndex = 9, int length = 417}) =>
    Uint8List(length)..setAll(0, [0xff, 0xfb, bitrateIndex << 4, 0]);

List<int> _atom(String type, List<int> payload) => [
  ..._u32(payload.length + 8),
  ..._ascii(type),
  ...payload,
];

List<int> _descriptor(int type, List<int> payload) => [
  type,
  payload.length,
  ...payload,
];

List<int> _sampleEntry(
  String type,
  int rate,
  int channels,
  List<int> children, {
  int bitDepth = 16,
}) {
  final header = ByteData(28)
    ..setUint16(6, 1)
    ..setUint16(16, channels)
    ..setUint16(18, bitDepth)
    ..setUint32(24, rate << 16);
  return _atom(type, [...header.buffer.asUint8List(), ...children]);
}

List<int> _aacEntry() {
  final decoder = _descriptor(4, [
    0x40, 0x15, 0, 0, 0,
    ..._u32(256000), ..._u32(256000),
    ..._descriptor(5, [0x12, 0x10]), // AAC-LC, 44.1kHz, stereo.
  ]);
  final esds = _atom('esds', [
    0,
    0,
    0,
    0,
    ..._descriptor(3, [
      0,
      1,
      0,
      ...decoder,
      ..._descriptor(6, [2]),
    ]),
  ]);
  return _sampleEntry('mp4a', 48000, 1, esds);
}

List<int> _ftyp() =>
    _atom('ftyp', [..._ascii('M4A '), ..._u32(0), ..._ascii('M4A isom')]);

List<int> _audioMoov(
  List<List<int>> entries, {
  List<int> extraMoov = const [],
}) => _atom('moov', [...extraMoov, ..._track(entries)]);

List<int> _track(List<List<int>> entries) => _atom(
  'trak',
  _atom(
    'mdia',
    _atom(
      'minf',
      _atom(
        'stbl',
        _atom('stsd', [
          0,
          0,
          0,
          0,
          ..._u32(entries.length),
          for (final entry in entries) ...entry,
        ]),
      ),
    ),
  ),
);

List<int> _mp4(List<List<int>> entries, {List<int> extraMoov = const []}) => [
  ..._ftyp(),
  ..._audioMoov(entries, extraMoov: extraMoov),
];
