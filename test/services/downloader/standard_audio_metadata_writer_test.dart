import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:bstream_music/services/downloader/audio_metadata_fields.dart';
import 'package:bstream_music/services/downloader/download_audio_metadata_service.dart';
import 'package:bstream_music/services/downloader/standard_audio_metadata_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  late Directory directory;
  late AudioMetadataTags tags;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('bstream-standard-tags-');
    tags = AudioMetadataTags(
      title: 'Canción 日本語 🎵',
      artist: 'Björk, 坂本龍一',
      album: 'Álbum de prueba',
      artworkBytes: image.encodePng(image.Image(width: 8, height: 8)),
      artworkMimeType: 'image/png',
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'download service dispatches all four containers in its background worker',
    () async {
      const service = DownloadAudioMetadataService();
      final cover = File('${directory.path}/cached-cover.png')
        ..writeAsBytesSync(tags.artworkBytes!);
      for (final format in ['mp3', 'flac', 'wav', 'ape']) {
        final before = _fixture(format, unrelated: true);
        final file = File('${directory.path}/download.$format')
          ..writeAsBytesSync(before);
        expect(
          await service.embed(
            filePath: file.path,
            title: tags.title,
            artist: tags.artist,
            album: tags.album,
            artworkPath: cover.path,
          ),
          AudioMetadataWriteResult.written,
          reason: format,
        );
        final metadata = readMetadata(file, getImage: true);
        expect(metadata.title, tags.title, reason: format);
        expect(metadata.artist, tags.artist, reason: format);
        expect(metadata.album, tags.album, reason: format);
        expect(
          metadata.pictures.single.bytes,
          orderedEquals(tags.artworkBytes!),
          reason: format,
        );
        expect(
          _audio(format, file.readAsBytesSync()),
          orderedEquals(_audio(format, before)),
          reason: format,
        );
      }
      expect(directory.listSync(), hasLength(5));
    },
  );

  for (final format in ['mp3', 'flac', 'wav', 'ape']) {
    test('$format embeds portable Unicode tags and cover, preserving audio', () {
      final before = _fixture(format);
      // Detection deliberately does not depend on a trusted filename extension.
      final file = File('${directory.path}/audio.data')
        ..writeAsBytesSync(before);
      expect(
        writeStandardAudioTags(file, tags),
        AudioMetadataWriteResult.written,
      );
      final metadata = readMetadata(file, getImage: true);
      expect(metadata.title, tags.title);
      expect(metadata.artist, tags.artist);
      expect(metadata.album, tags.album);
      expect(metadata.pictures, hasLength(1));
      expect(metadata.pictures.single.bytes, orderedEquals(tags.artworkBytes!));
      final after = file.readAsBytesSync();
      expect(_audio(format, after), orderedEquals(_audio(format, before)));
      expect(
        writeStandardAudioTags(file, tags),
        AudioMetadataWriteResult.unchanged,
      );
      expect(file.readAsBytesSync(), orderedEquals(after));
      expect(directory.listSync(), hasLength(1));
    });

    test(
      '$format keeps unrelated fields and existing optional album/cover',
      () {
        final file = File('${directory.path}/audio.$format')
          ..writeAsBytesSync(_fixture(format, unrelated: true));
        expect(
          writeStandardAudioTags(file, tags),
          AudioMetadataWriteResult.written,
        );
        final before = file.readAsBytesSync();
        expect(_contains(before, _unknown), isTrue);
        const replacement = AudioMetadataTags(
          title: 'Second title',
          artist: 'Second artist',
        );
        expect(
          writeStandardAudioTags(file, replacement),
          AudioMetadataWriteResult.written,
        );
        final after = file.readAsBytesSync();
        final metadata = readMetadata(file, getImage: true);
        expect(metadata.title, replacement.title);
        expect(metadata.artist, replacement.artist);
        expect(metadata.album, tags.album);
        expect(
          metadata.pictures.single.bytes,
          orderedEquals(tags.artworkBytes!),
        );
        expect(_contains(after, _unknown), isTrue);
        expect(_audio(format, after), orderedEquals(_audio(format, before)));
        expect(
          writeStandardAudioTags(file, replacement),
          AudioMetadataWriteResult.unchanged,
        );
      },
    );
  }

  test('MP3 preserves v2.3 frames and small zero-filled encoder prefixes', () {
    final tag = _id3v3();
    final before = Uint8List.fromList([...tag, ...Uint8List(192), ..._mpeg]);
    final file = File('${directory.path}/legacy.mp3')..writeAsBytesSync(before);
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.written,
    );
    final bytes = file.readAsBytesSync();
    expect(bytes[3], 3);
    expect(_contains(bytes, _unknown), isTrue);
    expect(_audio('mp3', bytes), orderedEquals(before.sublist(tag.length)));
    final metadata = readMetadata(file, getImage: true);
    expect(metadata.title, tags.title);
    expect(metadata.artist, tags.artist);
    expect(metadata.pictures.single.bytes, orderedEquals(tags.artworkBytes!));
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.unchanged,
    );
  });

  test('MP3 creates an ID3 tag before an untagged zero-prefixed stream', () {
    final before = Uint8List.fromList([...Uint8List(192), ..._mpeg]);
    final file = File('${directory.path}/untagged.mp3')
      ..writeAsBytesSync(before);
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.written,
    );
    expect(_audio('mp3', file.readAsBytesSync()), orderedEquals(before));
    expect(readMetadata(file).title, tags.title);
  });

  test('FLAC keeps seek tables and every non-front-cover metadata block', () {
    final before = _fixture('flac', unrelated: true);
    final file = File('${directory.path}/seek.flac')..writeAsBytesSync(before);
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.written,
    );
    final after = file.readAsBytesSync();
    final oldBlocks = _flacBlocks(before);
    final newBlocks = _flacBlocks(after);
    for (final block in oldBlocks.where(
      (b) => b.$1 == 0 || b.$1 == 2 || b.$1 == 3,
    )) {
      expect(
        newBlocks.any((b) => b.$1 == block.$1 && _same(b.$2, block.$2)),
        isTrue,
      );
    }
    expect(newBlocks.where((b) => b.$1 == 4), hasLength(1));
  });

  test('WAVE keeps odd unknown chunks and moves ID3 after legacy INFO', () {
    final info = _chunk(
      'LIST',
      Uint8List.fromList([
        ...ascii.encode('INFO'),
        ..._chunk('INAM', Uint8List.fromList(ascii.encode('Old name\u0000'))),
      ]),
    );
    final oldTag = _chunk('ID3 ', _id3v3());
    final chunks = _waveChunks(unrelated: true);
    final body = Uint8List.fromList([...oldTag, ...chunks, ...info]);
    final before = _riff(body);
    final file = File('${directory.path}/legacy.wav')..writeAsBytesSync(before);
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.written,
    );
    final after = file.readAsBytesSync();
    final lists = _riffChunks(after);
    expect(lists.last.$1, 'id3 ');
    expect(lists.where((c) => c.$1.toLowerCase() == 'id3 '), hasLength(1));
    expect(_contains(after, info), isTrue);
    expect(_contains(after, _unknown), isTrue);
    expect(readMetadata(file, getImage: true).title, tags.title);
    expect(_audio('wav', after), orderedEquals(_audio('wav', before)));
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.unchanged,
    );
  });

  test('APE upgrades a legacy text tag and keeps its trailing ID3v1', () {
    final oldTag = _apeTag(version: 1000, unrelated: true);
    final trailing = Uint8List.fromList([
      ...ascii.encode('TAG'),
      ...Uint8List(125),
    ]);
    final before = Uint8List.fromList([
      ..._apeAudio(legacy: true),
      ...oldTag,
      ...trailing,
    ]);
    final file = File('${directory.path}/legacy.ape')..writeAsBytesSync(before);
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.written,
    );
    final after = file.readAsBytesSync();
    expect(after.sublist(after.length - 128), orderedEquals(trailing));
    expect(_audio('ape', after), orderedEquals(_audio('ape', before)));
    expect(_contains(after, _unknown), isTrue);
    expect(readMetadata(file, getImage: true).title, tags.title);
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.unchanged,
    );
  });

  test(
    'APE accepts a matching optional header and preserves unknown binary items',
    () {
      final footerTag = _apeTag(unrelated: true);
      final footer = Uint8List.fromList(
        footerTag.sublist(footerTag.length - 32),
      );
      ByteData.sublistView(footer).setUint32(20, 0x80000000, Endian.little);
      final header = Uint8List.fromList(footer);
      ByteData.sublistView(header).setUint32(20, 0xa0000000, Endian.little);
      final before = Uint8List.fromList([
        ..._apeAudio(),
        ...header,
        ...footerTag.sublist(0, footerTag.length - 32),
        ...footer,
      ]);
      final file = File('${directory.path}/header.ape')
        ..writeAsBytesSync(before);
      expect(
        writeStandardAudioTags(file, tags),
        AudioMetadataWriteResult.written,
      );
      final after = file.readAsBytesSync();
      expect(_contains(after, _unknown), isTrue);
      expect(_audio('ape', after), orderedEquals(_audio('ape', before)));
    },
  );

  test('APE legacy non-UTF8 values remain intact as binary items', () {
    final oldTag = _apeTag(version: 1000, unrelated: true, invalidText: true);
    final file = File('${directory.path}/legacy-bytes.ape')
      ..writeAsBytesSync([..._apeAudio(legacy: true), ...oldTag]);
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.written,
    );
    final after = file.readAsBytesSync();
    final key = ascii.encode('Genre\u0000');
    final offset = _indexOf(after, key);
    expect(offset, greaterThan(8));
    final data = ByteData.sublistView(after);
    expect(data.getUint32(offset - 8, Endian.little), 2);
    expect(data.getUint32(offset - 4, Endian.little), 2);
    expect(after.sublist(offset + key.length, offset + key.length + 2), [
      255,
      0,
    ]);
    expect(_contains(after, _unknown), isTrue);
    expect(readMetadata(file, getImage: true).title, tags.title);
    expect(
      writeStandardAudioTags(file, tags),
      AudioMetadataWriteResult.unchanged,
    );
  });

  test('malformed and unsupported layouts stay byte-for-byte unchanged', () {
    final unsafeId3 = Uint8List.fromList(_id3v3())..[5] = 0x80;
    final invalidFlac = Uint8List.fromList(_fixture('flac'))..[5] = 0xff;
    final badRiff = Uint8List.fromList(_fixture('wav'))..[4] = 0;
    final badApe = Uint8List.fromList(_fixture('ape'))..[8] = 0xff;
    final oversizedId3 = Uint8List.fromList([
      ...ascii.encode('ID3'),
      4,
      0,
      0,
      127,
      127,
      127,
      127,
      ..._mpeg,
    ]);
    for (final before in [
      Uint8List(20),
      Uint8List.fromList([...unsafeId3, ..._mpeg]),
      invalidFlac,
      badRiff,
      badApe,
      oversizedId3,
      Uint8List.fromList([...ascii.encode('RIFF'), ...Uint8List(8)]),
    ]) {
      final file = File('${directory.path}/unsafe.audio')
        ..writeAsBytesSync(before);
      expect(
        writeStandardAudioTags(file, tags),
        AudioMetadataWriteResult.unsupported,
      );
      expect(file.readAsBytesSync(), orderedEquals(before));
      expect(directory.listSync(), hasLength(1));
    }
  });
}

final _unknown = Uint8List.fromList(utf8.encode('KEEP-UNRELATED-METADATA-123'));
final _mpeg = Uint8List.fromList([
  for (var frame = 0; frame < 3; frame++) ...[
    0xff,
    0xfb,
    0x90,
    0x64,
    ...List.generate(413, (i) => (i + frame) & 0xff),
  ],
]);
final _pcm = Uint8List.fromList(List.generate(88, (i) => (i * 7) & 0xff));
final _flacAudio = Uint8List.fromList([
  0xff,
  0xf8,
  ...List.generate(100, (i) => i),
]);

Uint8List _fixture(String format, {bool unrelated = false}) => switch (format) {
  'mp3' => Uint8List.fromList([if (unrelated) ..._id3v3(), ..._mpeg]),
  'flac' => _flac(unrelated: unrelated),
  'wav' => _riff(_waveChunks(unrelated: unrelated)),
  'ape' => Uint8List.fromList([
    ..._apeAudio(),
    if (unrelated) ..._apeTag(unrelated: true),
  ]),
  _ => throw ArgumentError(format),
};

Uint8List _id3v3() {
  final frame = Uint8List.fromList([
    ...ascii.encode('PRIV'),
    ..._u32(_unknown.length),
    0,
    0,
    ..._unknown,
  ]);
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    ..._sync(frame.length),
    ...frame,
  ]);
}

Uint8List _flac({required bool unrelated}) {
  final stream = ByteData(34)
    ..setUint16(0, 4096)
    ..setUint16(2, 4096);
  stream.setUint64(10, (44100 << 44) | (1 << 41) | (15 << 36) | 88200);
  final blocks = <(int, Uint8List)>[
    (0, stream.buffer.asUint8List()),
    if (unrelated) (2, _unknown),
    if (unrelated) (3, Uint8List(18)),
  ];
  return Uint8List.fromList([
    ...ascii.encode('fLaC'),
    for (var i = 0; i < blocks.length; i++) ...[
      blocks[i].$1 | (i == blocks.length - 1 ? 0x80 : 0),
      (blocks[i].$2.length >> 16) & 0xff,
      (blocks[i].$2.length >> 8) & 0xff,
      blocks[i].$2.length & 0xff,
      ...blocks[i].$2,
    ],
    ..._flacAudio,
  ]);
}

Uint8List _waveChunks({required bool unrelated}) {
  final format = ByteData(16)
    ..setUint16(0, 1, Endian.little)
    ..setUint16(2, 1, Endian.little)
    ..setUint32(4, 44100, Endian.little)
    ..setUint32(8, 88200, Endian.little)
    ..setUint16(12, 2, Endian.little)
    ..setUint16(14, 16, Endian.little);
  return Uint8List.fromList([
    ..._chunk('fmt ', format.buffer.asUint8List()),
    if (unrelated) ..._chunk('JUNK', _unknown),
    ..._chunk('data', _pcm),
  ]);
}

Uint8List _riff(Uint8List chunks) => Uint8List.fromList([
  ...ascii.encode('RIFF'),
  ..._u32(chunks.length + 4, little: true),
  ...ascii.encode('WAVE'),
  ...chunks,
]);

Uint8List _chunk(String id, Uint8List data) => Uint8List.fromList([
  ...ascii.encode(id),
  ..._u32(data.length, little: true),
  ...data,
  if (data.length.isOdd) 0,
]);

Uint8List _apeAudio({bool legacy = false}) {
  final payload = Uint8List.fromList(List.generate(120, (i) => (i * 3) & 0xff));
  if (legacy) {
    final header = ByteData(32);
    header.setUint16(4, 3970, Endian.little);
    header.setUint16(6, 2000, Endian.little);
    header.setUint16(8, 2, Endian.little);
    header.setUint16(10, 2, Endian.little);
    header.setUint32(12, 44100, Endian.little);
    header.setUint32(24, 1, Endian.little);
    header.setUint32(28, 1024, Endian.little);
    return Uint8List.fromList([
      ...ascii.encode('MAC '),
      ...header.buffer.asUint8List().sublist(4),
      ..._u32(36, little: true),
      ...payload,
    ]);
  }
  final descriptor = ByteData(52)
    ..setUint16(4, 3990, Endian.little)
    ..setUint32(8, 52, Endian.little)
    ..setUint32(12, 24, Endian.little)
    ..setUint32(16, 4, Endian.little)
    ..setUint32(24, payload.length, Endian.little);
  final header = ByteData(24)
    ..setUint16(0, 2000, Endian.little)
    ..setUint32(4, 1024, Endian.little)
    ..setUint32(8, 1024, Endian.little)
    ..setUint32(12, 1, Endian.little)
    ..setUint16(16, 16, Endian.little)
    ..setUint16(18, 2, Endian.little)
    ..setUint32(20, 44100, Endian.little);
  return Uint8List.fromList([
    ...ascii.encode('MAC '),
    ...descriptor.buffer.asUint8List().sublist(4),
    ...header.buffer.asUint8List(),
    ..._u32(80, little: true),
    ...payload,
  ]);
}

Uint8List _apeTag({
  int version = 2000,
  required bool unrelated,
  bool invalidText = false,
}) {
  final items = Uint8List.fromList([
    if (unrelated) ...[
      ..._u32(_unknown.length, little: true),
      ..._u32(2, little: true),
      ...ascii.encode('PRIVATE BINARY'),
      0,
      ..._unknown,
    ],
    if (invalidText) ...[
      ..._u32(2, little: true),
      ..._u32(0, little: true),
      ...ascii.encode('Genre'),
      0,
      255,
      0,
    ],
  ]);
  return Uint8List.fromList([
    ...items,
    ...ascii.encode('APETAGEX'),
    ..._u32(version, little: true),
    ..._u32(items.length + 32, little: true),
    ..._u32((unrelated ? 1 : 0) + (invalidText ? 1 : 0), little: true),
    ...Uint8List(12),
  ]);
}

Uint8List _audio(String format, Uint8List bytes) {
  switch (format) {
    case 'mp3':
      final start = String.fromCharCodes(bytes.sublist(0, 3)) == 'ID3'
          ? 10 + _syncValue(bytes.sublist(6, 10))
          : 0;
      return Uint8List.sublistView(bytes, start);
    case 'flac':
      var cursor = 4;
      var last = false;
      while (!last) {
        last = (bytes[cursor] & 0x80) != 0;
        cursor +=
            4 +
            (bytes[cursor + 1] << 16) +
            (bytes[cursor + 2] << 8) +
            bytes[cursor + 3];
      }
      return Uint8List.sublistView(bytes, cursor);
    case 'wav':
      return _riffChunks(bytes).singleWhere((chunk) => chunk.$1 == 'data').$2;
    case 'ape':
      var end = bytes.length;
      if (String.fromCharCodes(bytes.sublist(end - 128, end - 125)) == 'TAG') {
        end -= 128;
      }
      if (String.fromCharCodes(bytes.sublist(end - 32, end - 24)) ==
          'APETAGEX') {
        final size = ByteData.sublistView(
          bytes,
        ).getUint32(end - 20, Endian.little);
        final flags = ByteData.sublistView(
          bytes,
        ).getUint32(end - 12, Endian.little);
        end -= size + ((flags & 0x80000000) != 0 ? 32 : 0);
      }
      return Uint8List.sublistView(bytes, 0, end);
    default:
      throw ArgumentError(format);
  }
}

List<(int, Uint8List)> _flacBlocks(Uint8List bytes) {
  final blocks = <(int, Uint8List)>[];
  var cursor = 4;
  var last = false;
  while (!last) {
    last = (bytes[cursor] & 0x80) != 0;
    final type = bytes[cursor] & 0x7f;
    final size =
        (bytes[cursor + 1] << 16) +
        (bytes[cursor + 2] << 8) +
        bytes[cursor + 3];
    blocks.add((
      type,
      Uint8List.sublistView(bytes, cursor + 4, cursor + 4 + size),
    ));
    cursor += 4 + size;
  }
  return blocks;
}

List<(String, Uint8List)> _riffChunks(Uint8List bytes) {
  final chunks = <(String, Uint8List)>[];
  var cursor = 12;
  while (cursor < bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(cursor, cursor + 4));
    final size = ByteData.sublistView(
      bytes,
    ).getUint32(cursor + 4, Endian.little);
    chunks.add((
      id,
      Uint8List.sublistView(bytes, cursor + 8, cursor + 8 + size),
    ));
    cursor += 8 + size + (size & 1);
  }
  return chunks;
}

Uint8List _u32(int value, {bool little = false}) =>
    (ByteData(4)..setUint32(0, value, little ? Endian.little : Endian.big))
        .buffer
        .asUint8List();
List<int> _sync(int value) => [
  (value >> 21) & 127,
  (value >> 14) & 127,
  (value >> 7) & 127,
  value & 127,
];
int _syncValue(List<int> bytes) =>
    bytes.fold(0, (value, byte) => (value << 7) | byte);
bool _same(List<int> a, List<int> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
bool _contains(List<int> haystack, List<int> needle) {
  return _indexOf(haystack, needle) >= 0;
}

int _indexOf(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    if (_same(haystack.sublist(i, i + needle.length), needle)) return i;
  }
  return -1;
}
