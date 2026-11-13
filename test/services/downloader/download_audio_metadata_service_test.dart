import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:bstream_music/services/downloader/download_audio_metadata_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late DownloadAudioMetadataService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bstream-audio-tags-');
    service = DownloadAudioMetadataService();
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'embeds Unicode catalog tags and a readable cover without changing audio',
    () async {
      final file = await _audioFile(directory, _m4a());
      final before = await file.readAsBytes();
      final cover = await _coverFile(directory, png: true);

      expect(
        await service.embed(
          filePath: file.path,
          title: 'M\u00fasica del coraz\u00f3n \u{1f3b5}',
          artist: 'Bj\u00f6rk, \u5742\u672c\u9f8d\u4e00',
          album: '\u00c1lbum de prueba',
          artworkPath: cover.path,
        ),
        AudioMetadataWriteResult.written,
      );

      final after = await file.readAsBytes();
      final metadata = readMetadata(file, getImage: true);
      expect(metadata.title, 'M\u00fasica del coraz\u00f3n \u{1f3b5}');
      expect(metadata.artist, 'Bj\u00f6rk, \u5742\u672c\u9f8d\u4e00');
      expect(metadata.album, '\u00c1lbum de prueba');
      expect(metadata.duration, const Duration(seconds: 2));
      expect(
        _tagText(after, '\u00a9nam'),
        'M\u00fasica del coraz\u00f3n \u{1f3b5}',
      );
      expect(
        _tagText(after, '\u00a9ART'),
        'Bj\u00f6rk, \u5742\u672c\u9f8d\u4e00',
      );
      expect(_tagText(after, '\u00a9alb'), '\u00c1lbum de prueba');
      expect(image.decodeImage(_tagData(after, 'covr')), isNotNull);
      _expectMediaPreserved(before, after);
      _expectNoTemporaryFiles(directory, [file, cover]);
    },
  );

  for (final moovFirst in [true, false]) {
    for (final wideOffsets in [true, false]) {
      test(
        'preserves chunk targets (moovFirst=$moovFirst, co64=$wideOffsets)',
        () async {
          final file = await _audioFile(
            directory,
            _m4a(moovFirst: moovFirst, wideOffsets: wideOffsets),
          );
          final before = await file.readAsBytes();
          final result = await service.embed(
            filePath: file.path,
            title: 'New title',
            artist: 'New artist',
          );
          expect(result, AudioMetadataWriteResult.written);
          final after = await file.readAsBytes();
          final table = _find(after, wideOffsets ? 'co64' : 'stco');
          final target = wideOffsets
              ? _data(after).getUint64(table.payload + 8)
              : _data(after).getUint32(table.payload + 8);
          final mdat = _top(after).singleWhere((box) => box.type == 'mdat');
          expect(target, mdat.payload);
          expect(
            after.sublist(target, target + _aacPayload.length),
            orderedEquals(_aacPayload),
          );
          _expectMediaPreserved(before, after);
          expect(readMetadata(file).title, 'New title');
          _expectNoTemporaryFiles(directory, [file]);
        },
      );
    }
  }

  test(
    'detects audio MP4 by content and preserves ALAC codec configuration',
    () async {
      final bytes = _m4a(codec: 'alac');
      final file = File(p.join(directory.path, 'lossless.mp4'))
        ..writeAsBytesSync(bytes);
      final configuration = _find(bytes, 'stsd');
      expect(
        await service.embed(
          filePath: file.path,
          title: 'Lossless title',
          artist: 'Artist',
        ),
        AudioMetadataWriteResult.written,
      );
      final after = file.readAsBytesSync();
      final prepared = _find(after, 'stsd');
      expect(
        after.sublist(prepared.start, prepared.end),
        bytes.sublist(configuration.start, configuration.end),
      );
      expect(readMetadata(file).title, 'Lossless title');
      _expectMediaPreserved(bytes, after);
      expect(
        await service.embed(
          filePath: file.path,
          title: 'Lossless title',
          artist: 'Artist',
        ),
        AudioMetadataWriteResult.unchanged,
      );
    },
  );

  test('uses the actual container even when the extension differs', () async {
    final file = File(p.join(directory.path, 'audio.webm'))
      ..writeAsBytesSync(_m4a());
    expect(
      await service.embed(
        filePath: file.path,
        title: 'Detected MP4',
        artist: 'Artist',
      ),
      AudioMetadataWriteResult.written,
    );
    expect(_tagText(file.readAsBytesSync(), '\u00a9nam'), 'Detected MP4');
  });

  for (final header in ['extended', 'to-end']) {
    test(
      'preserves a valid $header media box without changing samples',
      () async {
        final file = await _audioFile(directory, _m4a(mdatHeader: header));
        final before = await file.readAsBytes();
        expect(
          await service.embed(
            filePath: file.path,
            title: 'Tagged media',
            artist: 'Artist',
          ),
          AudioMetadataWriteResult.written,
        );
        final after = await file.readAsBytes();
        expect(_tagText(after, '\u00a9nam'), 'Tagged media');
        final mdat = _top(after).singleWhere((box) => box.type == 'mdat');
        expect(
          _data(after).getUint32(_find(after, 'stco').payload + 8),
          mdat.payload,
        );
        _expectMediaPreserved(before, after);
      },
    );
  }

  test('retains fragment-relative media and index offsets', () async {
    final file = await _audioFile(directory, _fragmentedM4a());
    final before = await file.readAsBytes();
    expect(
      await service.embed(
        filePath: file.path,
        title: 'A fragmented song',
        artist: 'Artist',
      ),
      AudioMetadataWriteResult.written,
    );
    final after = await file.readAsBytes();
    final moof = _find(after, 'moof');
    final mdat = _find(after, 'mdat');
    final trun = _find(after, 'trun');
    expect(moof.start + _data(after).getInt32(trun.payload + 8), mdat.payload);
    final index = _find(after, 'sidx');
    expect(index.end + _data(after).getUint32(index.payload + 16), moof.start);
    for (final type in ['moof', 'sidx']) {
      final oldBox = _find(before, type);
      final newBox = _find(after, type);
      expect(
        after.sublist(newBox.start, newBox.end),
        orderedEquals(before.sublist(oldBox.start, oldBox.end)),
      );
    }
    expect(_tagText(after, '\u00a9nam'), 'A fragmented song');
    _expectMediaPreserved(before, after);
  });

  test(
    'conservatively leaves unsafe fragment and external layouts untouched',
    () async {
      for (final bytes in [
        _fragmentedM4a(absoluteBase: true),
        Uint8List.fromList([
          ..._fragmentedM4a(),
          ..._box('mfra', _box('tfra', Uint8List(16))),
        ]),
        _m4a(externalReference: true),
      ]) {
        final file = await _audioFile(directory, bytes);
        expect(
          await service.embed(
            filePath: file.path,
            title: 'A title',
            artist: 'An artist',
          ),
          AudioMetadataWriteResult.unsupported,
        );
        expect(await file.readAsBytes(), orderedEquals(bytes));
        _expectNoTemporaryFiles(directory, [file]);
      }
    },
  );

  test(
    'rejects fragment data offsets outside media without rewriting',
    () async {
      for (final beforeMedia in [true, false]) {
        final bytes = _fragmentedM4a();
        final moof = _find(bytes, 'moof');
        final mdat = _find(bytes, 'mdat');
        _data(bytes).setInt32(
          _find(bytes, 'trun').payload + 8,
          beforeMedia ? 0 : mdat.end - moof.start + 1,
        );
        final file = await _audioFile(directory, bytes);
        expect(
          await service.embed(
            filePath: file.path,
            title: 'A title',
            artist: 'An artist',
          ),
          AudioMetadataWriteResult.unsupported,
        );
        expect(await file.readAsBytes(), orderedEquals(bytes));
        _expectNoTemporaryFiles(directory, [file]);
      }
    },
  );

  test(
    'requires the audio sample description and complete sample table',
    () async {
      for (final missing in ['stsd', 'stbl']) {
        final bytes = _replaceBoxes(_m4a(), {missing: _box('free', [])});
        if (missing == 'stsd') {
          // Keep the remaining chunk pointer valid so rejection specifically
          // exercises the missing sample description rather than a stale offset.
          _data(bytes).setUint32(
            _find(bytes, 'stco').payload + 8,
            _find(bytes, 'mdat').payload,
          );
        }
        final file = await _audioFile(directory, bytes);
        expect(
          await service.embed(
            filePath: file.path,
            title: 'A title',
            artist: 'An artist',
          ),
          AudioMetadataWriteResult.unsupported,
        );
        expect(await file.readAsBytes(), orderedEquals(bytes));
        _expectNoTemporaryFiles(directory, [file]);
      }
    },
  );

  test(
    'reuses a cached WebP image as a portable embedded JPEG or PNG',
    () async {
      final file = await _audioFile(directory, _m4a());
      final cover = File('${directory.path}/cover.webp');
      await cover.writeAsBytes(
        base64Decode('UklGRh4AAABXRUJQVlA4TBEAAAAvB8ABAAdQ0IKUrP+BiOh/AAA='),
      );
      expect(image.decodeWebP(await cover.readAsBytes()), isNotNull);
      expect(
        await service.embed(
          filePath: file.path,
          title: 'A title',
          artist: 'An artist',
          artworkPath: cover.path,
        ),
        AudioMetadataWriteResult.written,
      );
      final bytes = await file.readAsBytes();
      final picture = _tagData(bytes, 'covr');
      final decoded = image.decodeImage(picture);
      expect(decoded, isNotNull);
      expect(decoded!.width, lessThanOrEqualTo(512));
      expect(decoded.height, lessThanOrEqualTo(512));
      final covr = _find(bytes, 'covr');
      final data = _top(bytes, covr.payload, covr.end).single;
      expect(_data(bytes).getUint32(data.payload), anyOf(13, 14));
      _expectNoTemporaryFiles(directory, [file, cover]);
    },
  );

  test(
    'bounds a large cached cover while preserving its aspect ratio',
    () async {
      final file = await _audioFile(directory, _m4a());
      final picture = image.Image(width: 1200, height: 600);
      image.fill(picture, color: image.ColorRgb8(180, 30, 90));
      final cover = File('${directory.path}/large-cover.png')
        ..writeAsBytesSync(image.encodePng(picture));
      expect(
        await service.embed(
          filePath: file.path,
          title: 'A title',
          artist: 'An artist',
          artworkPath: cover.path,
        ),
        AudioMetadataWriteResult.written,
      );
      final decoded = image.decodeImage(
        _tagData(await file.readAsBytes(), 'covr'),
      )!;
      expect(decoded.width, lessThanOrEqualTo(512));
      expect(decoded.height, lessThanOrEqualTo(512));
      expect(decoded.width / decoded.height, closeTo(2, .02));
      _expectNoTemporaryFiles(directory, [file, cover]);
    },
  );

  test(
    'preserves unrelated tags and an existing album when no album is supplied',
    () async {
      final unknown = _box('zzzz', [1, 7, 9, 11, 255]);
      final file = await _audioFile(
        directory,
        _m4a(
          tags: [
            ..._textTag('\u00a9nam', 'Old title'),
            ..._textTag('\u00a9ART', 'Old artist'),
            ..._textTag('\u00a9alb', 'Album already stored'),
            ..._textTag('\u00a9lyr', 'Existing lyrics'),
            ...unknown,
          ],
        ),
      );
      final before = await file.readAsBytes();
      expect(
        await service.embed(
          filePath: file.path,
          title: 'New title',
          artist: 'New artist',
        ),
        AudioMetadataWriteResult.written,
      );
      final after = await file.readAsBytes();
      expect(_tagText(after, '\u00a9alb'), 'Album already stored');
      expect(_tagText(after, '\u00a9lyr'), 'Existing lyrics');
      final retained = _find(after, 'zzzz');
      expect(
        after.sublist(retained.start, retained.end),
        orderedEquals(unknown),
      );
      expect(_all(after).where((box) => box.type == '\u00a9nam'), hasLength(1));
      _expectMediaPreserved(before, after);
    },
  );

  test(
    'repeating the same metadata does not rewrite or append duplicate pictures',
    () async {
      final file = await _audioFile(directory, _m4a());
      final cover = await _coverFile(directory);
      Future<AudioMetadataWriteResult> embed() => service.embed(
        filePath: file.path,
        title: 'A title',
        artist: 'An artist',
        album: 'An album',
        artworkPath: cover.path,
      );
      expect(await embed(), AudioMetadataWriteResult.written);
      final first = await file.readAsBytes();
      final modifiedAt = await file.lastModified();
      expect(await embed(), AudioMetadataWriteResult.unchanged);
      expect(await file.readAsBytes(), orderedEquals(first));
      expect(await file.lastModified(), modifiedAt);
      expect(_all(first).where((box) => box.type == 'covr'), hasLength(1));
      _expectNoTemporaryFiles(directory, [file, cover]);
    },
  );

  test(
    'handles concurrent identical writes without leaving duplicate tags',
    () async {
      final file = await _audioFile(directory, _m4a());
      Future<AudioMetadataWriteResult> embed() => service.embed(
        filePath: file.path,
        title: 'Same title',
        artist: 'Same artist',
      );
      expect(await Future.wait([embed(), embed()]), [
        AudioMetadataWriteResult.written,
        AudioMetadataWriteResult.unchanged,
      ]);
      final bytes = await file.readAsBytes();
      expect(_all(bytes).where((box) => box.type == '\u00a9nam'), hasLength(1));
      expect(_tagText(bytes, '\u00a9nam'), 'Same title');
      _expectNoTemporaryFiles(directory, [file]);
    },
  );

  test(
    'an unavailable or malformed artwork file does not block text tags',
    () async {
      for (final badArtwork in [
        null,
        '${directory.path}/missing.png',
        '${directory.path}/invalid.jpg',
      ]) {
        if (badArtwork?.endsWith('invalid.jpg') == true) {
          await File(badArtwork!).writeAsBytes([1, 2, 3, 4]);
        }
        final file = await _audioFile(directory, _m4a());
        final before = await file.readAsBytes();
        expect(
          await service.embed(
            filePath: file.path,
            title: 'A title',
            artist: 'An artist',
            artworkPath: badArtwork,
          ),
          AudioMetadataWriteResult.written,
        );
        final after = await file.readAsBytes();
        expect(_tagText(after, '\u00a9nam'), 'A title');
        expect(_all(after).where((box) => box.type == 'covr'), isEmpty);
        _expectMediaPreserved(before, after);
      }
    },
  );

  test(
    'unsupported containers and malformed files remain byte-for-byte intact',
    () async {
      final valid = _m4a();
      final invalidOffset = Uint8List.fromList(valid);
      _data(
        invalidOffset,
      ).setUint32(_find(invalidOffset, 'stco').payload + 8, 0xfffffffe);
      final inputs = <(String, List<int>)>[
        ('track.webm', [0x1a, 0x45, 0xdf, 0xa3, 1, 2, 3, 4]),
        ('track.opus', [...ascii.encode('OggS'), ...Uint8List(40)]),
        ('empty.m4a', []),
        ('invalid-offset.m4a', invalidOffset),
        ('truncated.m4a', valid.sublist(0, valid.length - 3)),
        (
          'invalid-size.m4a',
          Uint8List.fromList(valid)..buffer.asByteData().setUint32(0, 7),
        ),
      ];
      for (final (name, bytes) in inputs) {
        final file = File('${directory.path}/$name');
        await file.writeAsBytes(bytes);
        final result = await service.embed(
          filePath: file.path,
          title: 'A title',
          artist: 'An artist',
        );
        expect(
          result,
          anyOf(
            AudioMetadataWriteResult.unsupported,
            AudioMetadataWriteResult.failed,
          ),
        );
        expect(await file.readAsBytes(), orderedEquals(bytes));
      }
      _expectNoTemporaryFiles(directory, [
        for (final (name, _) in inputs) File('${directory.path}/$name'),
      ]);
    },
  );
}

const _aacPayload = <int>[
  0x21,
  0x10,
  0x04,
  0x60,
  0x8c,
  0x1c,
  0x21,
  0x10,
  0x04,
  0x60,
  0x8c,
  0x1c,
];

Future<File> _audioFile(Directory directory, List<int> bytes) async =>
    File('${directory.path}/track.m4a')..writeAsBytesSync(bytes);

Future<File> _coverFile(Directory directory, {bool png = false}) async {
  final picture = image.Image(width: 8, height: 8);
  image.fill(picture, color: image.ColorRgb8(32, 160, 100));
  return File('${directory.path}/cover.${png ? 'png' : 'jpg'}')
    ..writeAsBytesSync(
      png ? image.encodePng(picture) : image.encodeJpg(picture),
    );
}

Uint8List _m4a({
  String codec = 'mp4a',
  bool moovFirst = true,
  bool wideOffsets = false,
  List<int>? tags,
  String mdatHeader = 'normal',
  bool externalReference = false,
}) {
  final ftyp = _box('ftyp', [
    ...ascii.encode('M4A '),
    0,
    0,
    0,
    0,
    ...ascii.encode('isommp42'),
  ]);
  final movie = Uint8List(100);
  _data(movie)
    ..setUint32(12, 1000)
    ..setUint32(16, 2000)
    ..setUint32(20, 0x00010000)
    ..setUint16(24, 0x0100)
    ..setUint32(96, 2);
  final track = Uint8List(84);
  _data(track)
    ..setUint32(0, 7)
    ..setUint32(12, 1)
    ..setUint32(20, 2000)
    ..setUint16(36, 0x0100);
  final media = Uint8List(24);
  _data(media)
    ..setUint32(12, 48000)
    ..setUint32(16, 96000);
  final handler = Uint8List(24)..setRange(8, 12, ascii.encode('soun'));
  final entry = Uint8List(28);
  _data(entry)
    ..setUint16(6, 1)
    ..setUint16(16, 2)
    ..setUint16(18, 16)
    ..setUint32(24, 48000 << 16);
  final esds = _box('esds', [
    0,
    0,
    0,
    0,
    3,
    0x19,
    0,
    1,
    0,
    4,
    0x11,
    0x40,
    0x15,
    0,
    0,
    0,
    0,
    1,
    0xf4,
    0,
    0,
    1,
    0xf4,
    0,
    5,
    2,
    0x11,
    0x90,
    6,
    1,
    2,
  ]);
  final description = _box('stsd', [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    ..._box(codec, [
      ...entry,
      if (codec == 'alac') ..._box('alac', Uint8List(28)) else ...esds,
    ]),
  ]);
  final offsets = Uint8List(wideOffsets ? 16 : 12)
    ..buffer.asByteData().setUint32(4, 1);
  final moov = _box('moov', [
    ..._box('mvhd', movie),
    ..._box('trak', [
      ..._box('tkhd', track),
      ..._box('mdia', [
        ..._box('mdhd', media),
        ..._box('hdlr', handler),
        ..._box('minf', [
          ..._box('smhd', Uint8List(8)),
          ..._box(
            'dinf',
            _box('dref', [
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              1,
              ..._box('url ', [
                0,
                0,
                0,
                externalReference ? 0 : 1,
                if (externalReference)
                  ...ascii.encode('https://invalid.test/external-audio'),
                if (externalReference) 0,
              ]),
            ]),
          ),
          ..._box('stbl', [
            ...description,
            ..._box('stts', [
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              2,
              0,
              0,
              0xbb,
              0x80,
            ]),
            ..._box('stsc', [
              0,
              0,
              0,
              0,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              1,
              0,
              0,
              0,
              2,
              0,
              0,
              0,
              1,
            ]),
            ..._box('stsz', [0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 2]),
            ..._box(wideOffsets ? 'co64' : 'stco', offsets),
          ]),
        ]),
      ]),
    ]),
    if (tags != null)
      ..._box(
        'udta',
        _box('meta', [
          0,
          0,
          0,
          0,
          ..._box('hdlr', [
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            ...ascii.encode('mdir'),
            ...Uint8List(13),
          ]),
          ..._box('ilst', tags),
        ]),
      ),
  ]);
  final mdat = _mediaBox(_aacPayload, header: mdatHeader);
  final output = Uint8List.fromList([
    ...ftyp,
    if (moovFirst) ...moov,
    ...mdat,
    if (!moovFirst) ...moov,
  ]);
  final table = _find(output, wideOffsets ? 'co64' : 'stco');
  final mediaBox = _top(output).singleWhere((box) => box.type == 'mdat');
  if (wideOffsets) {
    _data(output).setUint64(table.payload + 8, mediaBox.payload);
  } else {
    _data(output).setUint32(table.payload + 8, mediaBox.payload);
  }
  return output;
}

Uint8List _fragmentedM4a({bool absoluteBase = false}) {
  final regular = _m4a();
  final ftyp = _find(regular, 'ftyp');
  final oldMoov = _find(regular, 'moov');
  var movie = Uint8List.sublistView(regular, oldMoov.start, oldMoov.end);
  movie = _replaceBoxes(movie, {
    'stco': _box('stco', Uint8List(8)),
    'stts': _box('stts', Uint8List(8)),
    'stsc': _box('stsc', Uint8List(8)),
    'stsz': _box('stsz', Uint8List(12)),
  });
  final defaults = Uint8List(24);
  _data(defaults)
    ..setUint32(4, 1)
    ..setUint32(8, 1)
    ..setUint32(12, 48000)
    ..setUint32(16, 6);
  movie = _box('moov', [
    ...movie.sublist(8),
    ..._box('mvex', _box('trex', defaults)),
  ]);
  final header = Uint8List(absoluteBase ? 16 : 8);
  _data(header)
    ..setUint32(0, absoluteBase ? 1 : 0x020000)
    ..setUint32(4, 1);
  final run = Uint8List(28);
  _data(run)
    ..setUint32(0, 0x301)
    ..setUint32(4, 2)
    ..setUint32(12, 48000)
    ..setUint32(16, 6)
    ..setUint32(20, 48000)
    ..setUint32(24, 6);
  final fragment = _box('moof', [
    ..._box('mfhd', [0, 0, 0, 0, 0, 0, 0, 1]),
    ..._box('traf', [
      ..._box('tfhd', header),
      ..._box('tfdt', Uint8List(8)),
      ..._box('trun', run),
    ]),
  ]);
  _data(
    fragment,
  ).setUint32(_find(fragment, 'trun').payload + 8, fragment.length + 8);
  final mdat = _mediaBox(_aacPayload);
  final reference = Uint8List(36);
  _data(reference)
    ..setUint32(4, 1)
    ..setUint32(8, 48000)
    ..setUint16(22, 1)
    ..setUint32(24, fragment.length + mdat.length)
    ..setUint32(28, 96000)
    ..setUint32(32, 0x90000000);
  final index = _box('sidx', reference);
  final output = Uint8List.fromList([
    ...regular.sublist(ftyp.start, ftyp.end),
    ...movie,
    ...index,
    ...fragment,
    ...mdat,
  ]);
  if (absoluteBase) {
    _data(
      output,
    ).setUint64(_find(output, 'tfhd').payload + 8, _find(output, 'moof').start);
  }
  return output;
}

Uint8List _replaceBoxes(Uint8List bytes, Map<String, Uint8List> replacements) {
  final result = BytesBuilder();
  for (final box in _top(bytes)) {
    final replacement = replacements[box.type];
    if (replacement != null) {
      result.add(replacement);
    } else if (const {
      'moov',
      'trak',
      'mdia',
      'minf',
      'stbl',
    }.contains(box.type)) {
      result.add(
        _box(
          box.type,
          _replaceBoxes(
            Uint8List.sublistView(bytes, box.payload, box.end),
            replacements,
          ),
        ),
      );
    } else {
      result.add(Uint8List.sublistView(bytes, box.start, box.end));
    }
  }
  return result.takeBytes();
}

Uint8List _mediaBox(List<int> payload, {String header = 'normal'}) {
  if (header == 'extended') {
    final bytes = Uint8List(payload.length + 16);
    _data(bytes)
      ..setUint32(0, 1)
      ..setUint64(8, bytes.length);
    bytes.setRange(4, 8, ascii.encode('mdat'));
    bytes.setRange(16, bytes.length, payload);
    return bytes;
  }
  final bytes = _box('mdat', payload);
  if (header == 'to-end') _data(bytes).setUint32(0, 0);
  return bytes;
}

Uint8List _box(String type, List<int> payload) {
  final bytes = Uint8List(payload.length + 8);
  _data(bytes).setUint32(0, bytes.length);
  bytes.setRange(4, 8, latin1.encode(type));
  bytes.setRange(8, bytes.length, payload);
  return bytes;
}

Uint8List _textTag(String type, String value) =>
    _box(type, _box('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(value)]));
ByteData _data(Uint8List bytes) => ByteData.sublistView(bytes);

class _Atom {
  const _Atom(this.type, this.start, this.payload, this.end);
  final String type;
  final int start;
  final int payload;
  final int end;
}

Iterable<_Atom> _top(Uint8List bytes, [int start = 0, int? end]) sync* {
  var cursor = start;
  final limit = end ?? bytes.length;
  while (cursor < limit) {
    if (limit - cursor < 8) {
      throw const FormatException('Truncated atom header');
    }
    var size = _data(bytes).getUint32(cursor);
    var header = 8;
    if (size == 1) {
      if (limit - cursor < 16) {
        throw const FormatException('Truncated extended header');
      }
      size = _data(bytes).getUint64(cursor + 8);
      header = 16;
    } else if (size == 0) {
      size = limit - cursor;
    }
    if (size < header || size > limit - cursor) {
      throw const FormatException('Invalid atom bounds');
    }
    yield _Atom(
      latin1.decode(bytes.sublist(cursor + 4, cursor + 8)),
      cursor,
      cursor + header,
      cursor + size,
    );
    cursor += size;
  }
}

Iterable<_Atom> _all(Uint8List bytes, [int start = 0, int? end]) sync* {
  for (final box in _top(bytes, start, end)) {
    yield box;
    if (const {
      'moov',
      'trak',
      'mdia',
      'minf',
      'stbl',
      'udta',
      'ilst',
      'moof',
      'traf',
      'mvex',
    }.contains(box.type)) {
      yield* _all(bytes, box.payload, box.end);
    } else if (box.type == 'meta') {
      yield* _all(bytes, box.payload + 4, box.end);
    }
  }
}

_Atom _find(Uint8List bytes, String type) =>
    _all(bytes).singleWhere((box) => box.type == type);
Uint8List _tagData(Uint8List bytes, String type) {
  final tag = _find(bytes, type);
  final data = _top(
    bytes,
    tag.payload,
    tag.end,
  ).singleWhere((box) => box.type == 'data');
  return Uint8List.sublistView(bytes, data.payload + 8, data.end);
}

String _tagText(Uint8List bytes, String type) =>
    utf8.decode(_tagData(bytes, type));
void _expectMediaPreserved(Uint8List before, Uint8List after) {
  final oldMedia = _top(before).where((box) => box.type == 'mdat').toList();
  final newMedia = _top(after).where((box) => box.type == 'mdat').toList();
  expect(newMedia, hasLength(oldMedia.length));
  for (var index = 0; index < oldMedia.length; index++) {
    expect(
      after.sublist(newMedia[index].payload, newMedia[index].end),
      orderedEquals(
        before.sublist(oldMedia[index].payload, oldMedia[index].end),
      ),
    );
  }
}

void _expectNoTemporaryFiles(Directory directory, List<File> allowed) {
  expect(directory.listSync().map((entry) => p.normalize(entry.path)).toSet(), {
    for (final file in allowed) p.normalize(file.path),
  });
}
