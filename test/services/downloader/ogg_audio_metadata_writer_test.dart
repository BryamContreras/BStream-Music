import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:bstream_music/services/downloader/audio_metadata_fields.dart';
import 'package:bstream_music/services/downloader/download_audio_metadata_service.dart';
import 'package:bstream_music/services/downloader/ogg_audio_metadata_writer.dart';
import 'package:bstream_music/services/downloader/vorbis_metadata_fields.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('bstream-ogg-'));
  tearDown(() => directory.deleteSync(recursive: true));

  for (final opus in [true, false]) {
    for (final sharedSuffix in [true, false]) {
      test(
        '${opus ? 'Opus' : 'Vorbis'} preserves packets/granules with shared header=$sharedSuffix',
        () {
          final original = _fixture(opus: opus, sharedSuffix: sharedSuffix);
          final file = File('${directory.path}/song.ogg')
            ..writeAsBytesSync(original);
          final tags = _tags();
          final before = _inspect(original);
          expect(
            writeOggAudioTags(file, tags),
            AudioMetadataWriteResult.written,
          );
          final bytes = file.readAsBytesSync();
          final after = _inspect(bytes);
          _expectAudioUnchanged(before, after);
          final metadata = readMetadata(file, getImage: true);
          expect(metadata.title, 'Canci\u00f3n \u65e5\u672c\u8a9e');
          expect(metadata.artist, 'BStream Music');
          expect(metadata.album, '\u00c1lbum');
          expect(metadata.pictures, hasLength(1));
          expect(image.decodeImage(metadata.pictures.single.bytes)?.width, 4);
          final fields = _fields(after.packets[1], opus: opus);
          expect(fields, contains('GENRE=Instrumental'));
          expect(
            fields.where((value) => value.startsWith('TITLE=')),
            hasLength(1),
          );
          final changed = file.statSync();
          expect(
            writeOggAudioTags(file, tags),
            AudioMetadataWriteResult.unchanged,
          );
          expect(file.readAsBytesSync(), orderedEquals(bytes));
          expect(file.statSync().modified, changed.modified);
          _expectNoTemporaryFiles(directory);
        },
      );
    }
  }

  for (final opus in [true, false]) {
    test(
      '${opus ? 'Opus' : 'Vorbis'} repaginates large comments and artwork',
      () {
        final original = _fixture(
          opus: opus,
          largeComments: true,
          splitAudioPacket: true,
        );
        final file = File('${directory.path}/large.ogg')
          ..writeAsBytesSync(original);
        final bytes = Uint8List.fromList(
          image.encodePng(
            image.Image(width: 200, height: 200)
              ..clear(image.ColorRgb8(4, 8, 15)),
          ),
        );
        final tags = AudioMetadataTags(
          title: 'Large header',
          artist: 'BStream Music',
          artworkBytes: bytes,
          artworkMimeType: 'image/png',
        );
        expect(writeOggAudioTags(file, tags), AudioMetadataWriteResult.written);
        final after = _inspect(file.readAsBytesSync());
        _expectAudioUnchanged(_inspect(original), after);
        expect(
          _fields(after.packets[1], opus: opus),
          contains('ALBUM=Old album'),
        );
        // The independent package's duration scan assumes EOS is exactly 0x04;
        // a valid continued EOS page is 0x05. Check this layout's comments using
        // the packet reconstruction above instead of hiding that reader defect.
        final pictures = _fields(after.packets[1], opus: opus)
            .where((field) => field.startsWith('METADATA_BLOCK_PICTURE='))
            .toList();
        expect(pictures, hasLength(1));
        final picture = base64.decode(
          pictures.single.split('=').sublist(1).join('='),
        );
        expect(ByteData.sublistView(picture).getUint32(0), 3);
        expect(
          writeOggAudioTags(file, tags),
          AudioMetadataWriteResult.unchanged,
        );
        _expectNoTemporaryFiles(directory);
      },
    );
  }

  test(
    'preserves non-front artwork and replaces front cover without duplicating it',
    () {
      final tags = _tags();
      final front = encodeFlacPicture(tags);
      final back = Uint8List.fromList(front);
      ByteData.sublistView(back).setUint32(0, 4);
      final existing = _comments([
        'METADATA_BLOCK_PICTURE=${base64.encode(front)}',
        'METADATA_BLOCK_PICTURE=${base64.encode(back)}',
        'COVERART=obsolete',
        'COVERARTMIME=image/jpeg',
        'ALBUM=Keep this album',
      ]);
      final result = updateVorbisComments(
        existing,
        AudioMetadataTags(
          title: tags.title,
          artist: tags.artist,
          artworkBytes: tags.artworkBytes,
          artworkMimeType: tags.artworkMimeType,
        ),
        embedPicture: true,
      );
      final fields = _fields(
        Uint8List.fromList([...ascii.encode('OpusTags'), ...result]),
        opus: true,
      );
      final pictures = fields
          .where((value) => value.startsWith('METADATA_BLOCK_PICTURE='))
          .toList();
      expect(pictures, hasLength(2));
      expect(
        pictures,
        contains('METADATA_BLOCK_PICTURE=${base64.encode(back)}'),
      );
      expect(fields, contains('ALBUM=Keep this album'));
      expect(fields.any((value) => value.startsWith('COVERART')), isFalse);
      final data = ByteData.sublistView(front);
      final offset = 8 + ascii.encode('image/png').length + 4;
      expect(data.getUint32(offset), 4);
      expect(data.getUint32(offset + 4), 3);
      expect(data.getUint32(offset + 8), 24);
    },
  );

  test('preserves Opus opaque trailing header data', () {
    final original = _fixture(opus: true, opusTail: [1, 45, 67, 89]);
    final file = File('${directory.path}/padding.opus')
      ..writeAsBytesSync(original);
    expect(writeOggAudioTags(file, _tags()), AudioMetadataWriteResult.written);
    final packet = _inspect(file.readAsBytesSync()).packets[1];
    expect(packet.sublist(packet.length - 4), orderedEquals([1, 45, 67, 89]));
  });

  test(
    'shared worker detects Ogg content and reuses the cached cover',
    () async {
      final original = _fixture(opus: true);
      final file = File('${directory.path}/misleading.mp3')
        ..writeAsBytesSync(original);
      final tags = _tags();
      final cover = File('${directory.path}/cached-cover.png')
        ..writeAsBytesSync(tags.artworkBytes!);
      expect(
        await const DownloadAudioMetadataService().embed(
          filePath: file.path,
          title: tags.title,
          artist: tags.artist,
          album: tags.album,
          artworkPath: cover.path,
        ),
        AudioMetadataWriteResult.written,
      );
      final metadata = readMetadata(file, getImage: true);
      expect(metadata.title, tags.title);
      expect(metadata.artist, tags.artist);
      expect(metadata.album, tags.album);
      expect(metadata.pictures.single.bytes, orderedEquals(tags.artworkBytes!));
      _expectAudioUnchanged(
        _inspect(original),
        _inspect(file.readAsBytesSync()),
      );
      _expectNoTemporaryFiles(directory);
    },
  );

  test(
    'leaves malformed, truncated, multiplexed and chained streams untouched',
    () {
      final valid = _fixture(opus: true);
      final pages = _inspect(valid).pages;
      final corrupt = Uint8List.fromList(valid)..[valid.length - 1] ^= 1;
      final wrongSerial = Uint8List.fromList(valid);
      final lastStart = pages.last.start;
      ByteData.sublistView(
        wrongSerial,
      ).setUint32(lastStart + 14, 999, Endian.little);
      _fixChecksum(wrongSerial, lastStart, wrongSerial.length);
      final wrongSequence = Uint8List.fromList(valid);
      ByteData.sublistView(
        wrongSequence,
      ).setUint32(lastStart + 18, 19, Endian.little);
      _fixChecksum(wrongSequence, lastStart, wrongSequence.length);
      for (final bytes in [
        corrupt,
        valid.sublist(0, valid.length - 1),
        wrongSerial,
        wrongSequence,
        [...valid, ...valid],
        valid.sublist(0, lastStart),
      ]) {
        final file = File('${directory.path}/invalid.ogg')
          ..writeAsBytesSync(bytes);
        expect(
          writeOggAudioTags(file, _tags()),
          AudioMetadataWriteResult.unsupported,
        );
        expect(file.readAsBytesSync(), orderedEquals(bytes));
        _expectNoTemporaryFiles(directory);
      }
    },
  );

  test('rejects malformed or oversized comment vectors before replacement', () {
    for (final bytes in [
      Uint8List.fromList([255, 255, 255, 127]),
      Uint8List(8 * 1024 * 1024 + 1),
    ]) {
      expect(() => updateVorbisComments(bytes, _tags()), throwsFormatException);
    }
  });
}

AudioMetadataTags _tags() => AudioMetadataTags(
  title: 'Canci\u00f3n \u65e5\u672c\u8a9e',
  artist: 'BStream Music',
  album: '\u00c1lbum',
  artworkBytes: Uint8List.fromList(
    image.encodePng(
      image.Image(width: 4, height: 3)..clear(image.ColorRgb8(30, 120, 220)),
    ),
  ),
  artworkMimeType: 'image/png',
);

Uint8List _fixture({
  required bool opus,
  bool sharedSuffix = false,
  bool largeComments = false,
  bool splitAudioPacket = false,
  List<int> opusTail = const [],
}) {
  final head = opus
      ? Uint8List.fromList([
          ...ascii.encode('OpusHead'),
          1,
          2,
          56,
          1,
          128,
          187,
          0,
          0,
          0,
          0,
          0,
        ])
      : Uint8List(30);
  if (!opus) {
    head.setRange(0, 7, [1, ...ascii.encode('vorbis')]);
    head[11] = 2;
    ByteData.sublistView(head).setUint32(12, 48000, Endian.little);
    head[28] = 0xb8;
    head[29] = 1;
  }
  final comments = _comments([
    'TITLE=Old title',
    'title=Duplicate',
    'ARTIST=Old artist',
    'ALBUM=Old album',
    'GENRE=Instrumental',
    if (largeComments) 'DESCRIPTION=${'x' * 140000}',
  ]);
  final packet = Uint8List.fromList([
    if (opus)
      ...ascii.encode('OpusTags')
    else ...[
      3,
      ...ascii.encode('vorbis'),
    ],
    ...comments,
    if (opus) ...opusTail else 1,
  ]);
  final setup = Uint8List.fromList([5, ...ascii.encode('vorbis'), 42, 7]);
  final audio = splitAudioPacket
      ? Uint8List.fromList(List.generate(520, (index) => index % 251))
      : Uint8List.fromList(opus ? [248, 255, 254] : [0, 33, 44]);
  final output = BytesBuilder(copy: false);
  var sequence = 0;
  void page(
    List<int> segments,
    List<int> body, {
    int flags = 0,
    int granule = 0,
  }) => output.add(
    _page(segments, body, sequence: sequence++, flags: flags, granule: granule),
  );
  page(_lacing(head.length), head, flags: 2);
  final lacing = _lacing(packet.length);
  var segmentOffset = 0;
  var byteOffset = 0;
  while (segmentOffset < lacing.length) {
    final end = (segmentOffset + 255).clamp(0, lacing.length);
    final segments = lacing.sublist(segmentOffset, end);
    final size = segments.fold<int>(0, (sum, value) => sum + value);
    final isLast = end == lacing.length;
    if (isLast && sharedSuffix && !splitAudioPacket) {
      final suffix = opus ? audio : setup;
      page(
        [...segments, ..._lacing(suffix.length)],
        [...packet.sublist(byteOffset, byteOffset + size), ...suffix],
        flags: segmentOffset > 0 ? 1 : 0,
        granule: opus ? 960 : 0,
      );
    } else {
      page(
        segments,
        packet.sublist(byteOffset, byteOffset + size),
        flags: segmentOffset > 0 ? 1 : 0,
        granule: isLast ? 0 : -1,
      );
    }
    byteOffset += size;
    segmentOffset = end;
  }
  if (!opus && !sharedSuffix) page(_lacing(setup.length), setup);
  if (splitAudioPacket) {
    page([255], audio.sublist(0, 255), granule: -1);
    page([255, 10], audio.sublist(255), flags: 5, granule: 96000);
  } else {
    if (!sharedSuffix || !opus) {
      page(_lacing(audio.length), audio, granule: 48000);
    }
    page(_lacing(audio.length), audio, flags: 4, granule: 96000);
  }
  return output.takeBytes();
}

Uint8List _comments(List<String> fields) {
  final vendor = utf8.encode('Original vendor');
  final out = BytesBuilder(copy: false)
    ..add(_u32(vendor.length))
    ..add(vendor)
    ..add(_u32(fields.length));
  for (final field in fields) {
    final bytes = utf8.encode(field);
    out
      ..add(_u32(bytes.length))
      ..add(bytes);
  }
  return out.takeBytes();
}

List<String> _fields(Uint8List packet, {required bool opus}) {
  final data = ByteData.sublistView(packet);
  var offset = opus ? 8 : 7;
  final vendorLength = data.getUint32(offset, Endian.little);
  offset += 4 + vendorLength;
  final count = data.getUint32(offset, Endian.little);
  offset += 4;
  final result = <String>[];
  for (var index = 0; index < count; index++) {
    final length = data.getUint32(offset, Endian.little);
    offset += 4;
    result.add(utf8.decode(packet.sublist(offset, offset + length)));
    offset += length;
  }
  return result;
}

List<int> _lacing(int length) => [
  ...List.filled(length ~/ 255, 255),
  length % 255,
];
Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();
Uint8List _page(
  List<int> lacing,
  List<int> body, {
  required int sequence,
  int flags = 0,
  int granule = 0,
}) {
  final bytes = Uint8List(27 + lacing.length + body.length);
  bytes.setRange(0, 4, ascii.encode('OggS'));
  bytes[5] = flags;
  ByteData.sublistView(bytes)
    ..setInt64(6, granule, Endian.little)
    ..setUint32(14, 719, Endian.little)
    ..setUint32(18, sequence, Endian.little);
  bytes[26] = lacing.length;
  bytes.setRange(27, 27 + lacing.length, lacing);
  bytes.setRange(27 + lacing.length, bytes.length, body);
  _fixChecksum(bytes, 0, bytes.length);
  return bytes;
}

int _crc(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte << 24;
    for (var bit = 0; bit < 8; bit++) {
      crc =
          ((crc << 1) ^ ((crc & 0x80000000) != 0 ? 0x04c11db7 : 0)) &
          0xffffffff;
    }
  }
  return crc;
}

void _fixChecksum(Uint8List bytes, int start, int end) {
  final data = ByteData.sublistView(bytes)
    ..setUint32(start + 22, 0, Endian.little);
  data.setUint32(start + 22, _crc(bytes.sublist(start, end)), Endian.little);
}

_StreamData _inspect(Uint8List bytes) {
  final packets = <Uint8List>[];
  final pages = <_PageData>[];
  final granules = <int>[];
  final builder = BytesBuilder(copy: false);
  var offset = 0;
  var sequence = 0;
  var continued = false;
  while (offset < bytes.length) {
    final data = ByteData.sublistView(bytes);
    expect(ascii.decode(bytes.sublist(offset, offset + 4)), 'OggS');
    expect(data.getUint32(offset + 18, Endian.little), sequence++);
    expect(bytes[offset + 5] & 1 != 0, continued);
    final count = bytes[offset + 26];
    final segments = bytes.sublist(offset + 27, offset + 27 + count);
    final bodyStart = offset + 27 + count;
    final end = bodyStart + segments.fold<int>(0, (sum, value) => sum + value);
    final expected = data.getUint32(offset + 22, Endian.little);
    final checksumBytes = Uint8List.fromList(bytes.sublist(offset, end));
    ByteData.sublistView(checksumBytes).setUint32(22, 0, Endian.little);
    expect(_crc(checksumBytes), expected);
    var bodyOffset = bodyStart;
    var complete = 0;
    for (final segment in segments) {
      builder.add(bytes.sublist(bodyOffset, bodyOffset + segment));
      bodyOffset += segment;
      if (segment < 255) {
        packets.add(builder.takeBytes());
        granules.add(-1);
        complete++;
      }
    }
    if (complete > 0) {
      granules[granules.length - 1] = data.getInt64(offset + 6, Endian.little);
    }
    pages.add(_PageData(offset));
    continued = segments.last == 255;
    offset = end;
  }
  expect(builder.length, 0);
  return _StreamData(packets, granules, pages);
}

void _expectAudioUnchanged(_StreamData before, _StreamData after) {
  expect(after.packets.length, before.packets.length);
  for (var index = 0; index < before.packets.length; index++) {
    if (index == 1) continue;
    expect(after.packets[index], orderedEquals(before.packets[index]));
    expect(after.granules[index], before.granules[index]);
  }
}

void _expectNoTemporaryFiles(Directory directory) => expect(
  directory.listSync().where((file) => file.path.endsWith('.tmp')),
  isEmpty,
);

class _PageData {
  const _PageData(this.start);
  final int start;
}

class _StreamData {
  const _StreamData(this.packets, this.granules, this.pages);
  final List<Uint8List> packets;
  final List<int> granules;
  final List<_PageData> pages;
}
