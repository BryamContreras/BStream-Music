import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:bstream_music/services/downloader/audio_metadata_fields.dart';
import 'package:bstream_music/services/downloader/download_audio_metadata_service.dart';
import 'package:bstream_music/services/downloader/webm_audio_metadata_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('bstream-webm-tags-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  for (final unknownSegment in [false, true]) {
    test(
      'writes portable text and preserves media/indexes (unknown=$unknownSegment)',
      () {
        final file = File('${directory.path}/audio.webm')
          ..writeAsBytesSync(_webm(unknownSegment: unknownSegment));
        final before = file.readAsBytesSync();
        expect(
          writeWebmAudioTags(
            file,
            const AudioMetadataTags(
              title: 'Canción 日本語 🎵',
              artist: 'Björk, 坂本龍一',
              album: 'Álbum',
            ),
          ),
          AudioMetadataWriteResult.written,
        );
        final after = file.readAsBytesSync();
        final metadata = readMetadata(file, getImage: true);
        expect(metadata.title, 'Canción 日本語 🎵');
        expect(metadata.artist, 'Björk, 坂本龍一');
        expect(metadata.album, 'Álbum');
        final tags = _textTags(after);
        final trackTags = tags
            .where((tag) => tag.level == 30 && tag.uid == _uid)
            .toList();
        expect(trackTags.single.values, {
          'TITLE': 'Canción 日本語 🎵',
          'ARTIST': 'Björk, 坂本龍一',
          'ALBUM': 'Álbum',
        });
        expect(tags.any((tag) => tag.values['GENRE'] == 'Electronic'), isTrue);
        expect(
          tags.any(
            (tag) =>
                tag.level == 50 &&
                tag.values['TITLE'] == 'Canonical album title',
          ),
          isTrue,
        );
        expect(
          tags.any(
            (tag) => tag.uid == 7 && tag.values['TITLE'] == 'Other track',
          ),
          isTrue,
        );
        _expectClustersUnchanged(before, after);
        _expectSeekReferencesValid(after);
        _expectCueReferenceValid(after);
        expect(
          _segmentChildren(after).where((part) => part.id == _tags),
          hasLength(1),
        );
        expect(directory.listSync().whereType<File>().length, 1);
      },
    );
  }

  test('reuses a trailing tag block and is idempotent without file growth', () {
    final file = File('${directory.path}/audio.webm')
      ..writeAsBytesSync(_webm());
    const tags = AudioMetadataTags(
      title: 'One',
      artist: 'Artist',
      album: 'Album',
    );
    expect(writeWebmAudioTags(file, tags), AudioMetadataWriteResult.written);
    final first = file.readAsBytesSync();
    expect(writeWebmAudioTags(file, tags), AudioMetadataWriteResult.unchanged);
    expect(file.readAsBytesSync(), orderedEquals(first));
    expect(
      writeWebmAudioTags(
        file,
        const AudioMetadataTags(title: 'Two', artist: 'Artist', album: 'Album'),
      ),
      AudioMetadataWriteResult.written,
    );
    final second = file.readAsBytesSync();
    expect(second.length, first.length);
    expect(
      _segmentChildren(second).where((part) => part.id == _tags),
      hasLength(1),
    );
    _expectClustersUnchanged(first, second);
    _expectSeekReferencesValid(second);
  });

  test(
    'a missing album preserves saved tags and artwork is not attached to WebM',
    () {
      final file = File('${directory.path}/audio.webm')
        ..writeAsBytesSync(_webm());
      expect(
        writeWebmAudioTags(
          file,
          AudioMetadataTags(
            title: 'New title',
            artist: 'New artist',
            artworkBytes: Uint8List.fromList([137, 80, 78, 71]),
            artworkMimeType: 'image/png',
          ),
        ),
        AudioMetadataWriteResult.written,
      );
      final after = file.readAsBytesSync();
      expect(
        _textTags(after).any((tag) => tag.values['ALBUM'] == 'Old album'),
        isTrue,
      );
      expect(
        _segmentChildren(after).any((part) => part.id == 0x1941a469),
        isFalse,
      );
    },
  );

  test(
    'drops only a too-small tag seek entry, keeping other references valid',
    () {
      final file = File('${directory.path}/audio.webm')
        ..writeAsBytesSync(_webm(narrowTagSeek: true, minimalTags: true));
      final before = file.readAsBytesSync();
      expect(
        writeWebmAudioTags(
          file,
          const AudioMetadataTags(title: 'Title', artist: 'Artist'),
        ),
        AudioMetadataWriteResult.written,
      );
      final after = file.readAsBytesSync();
      _expectClustersUnchanged(before, after);
      _expectSeekReferencesValid(after);
      final head = _segmentChildren(
        after,
      ).singleWhere((part) => part.id == _seekHead);
      expect(
        _elements(after, head.payload, head.end).any((part) => part.id == 0xec),
        isTrue,
      );
    },
  );

  test(
    'accepts an unknown-size terminal cluster and ends it before new tags',
    () {
      final file = File('${directory.path}/audio.webm')
        ..writeAsBytesSync(_webm(unknownCluster: true));
      final before = file.readAsBytesSync();
      expect(
        writeWebmAudioTags(
          file,
          const AudioMetadataTags(title: 'Title', artist: 'Artist'),
        ),
        AudioMetadataWriteResult.written,
      );
      final after = file.readAsBytesSync();
      final oldMedia = _segmentChildren(
        before,
      ).singleWhere((part) => part.id == _cluster);
      final newMedia = _segmentChildren(
        after,
      ).singleWhere((part) => part.id == _cluster);
      expect(newMedia.start, oldMedia.start);
      expect(newMedia.end, oldMedia.end);
      expect(
        after.sublist(newMedia.start, newMedia.end),
        orderedEquals(before.sublist(oldMedia.start, oldMedia.end)),
      );
      expect(
        _textTags(after).any((tag) => tag.values['TITLE'] == 'Title'),
        isTrue,
      );
    },
  );

  test('can add tags to a previously untagged WebM/Vorbis file', () {
    final file = File('${directory.path}/audio.webm')
      ..writeAsBytesSync(_webm(noTags: true, codec: 'A_VORBIS'));
    final before = file.readAsBytesSync();
    expect(
      writeWebmAudioTags(
        file,
        const AudioMetadataTags(title: 'Vorbis', artist: 'Artist'),
      ),
      AudioMetadataWriteResult.written,
    );
    _expectClustersUnchanged(before, file.readAsBytesSync());
    expect(_textTags(file.readAsBytesSync()).single.values, {
      'TITLE': 'Vorbis',
      'ARTIST': 'Artist',
    });
  });

  test(
    'leaves video, multi-track, corrupt, and checksum-sensitive files untouched',
    () {
      final cases = [
        _webm(trackType: 1),
        _webm(codec: 'A_AAC'),
        _webm(extraTrack: true),
        _webm(segmentCrc: true),
        _webm().sublist(0, _webm().length - 2),
        [0x1a, 0x45, 0xdf, 0xa3, 0x80],
      ];
      for (var index = 0; index < cases.length; index++) {
        final file = File('${directory.path}/bad-$index.webm')
          ..writeAsBytesSync(cases[index]);
        expect(
          writeWebmAudioTags(
            file,
            const AudioMetadataTags(title: 'Title', artist: 'Artist'),
          ),
          AudioMetadataWriteResult.unsupported,
          reason: 'case $index',
        );
        expect(file.readAsBytesSync(), orderedEquals(cases[index]));
      }
      expect(directory.listSync().whereType<File>().length, cases.length);
    },
  );

  test(
    'shared service detects WebM content and keeps missing artwork external',
    () async {
      final file = File('${directory.path}/download.audio')
        ..writeAsBytesSync(_webm());
      final before = file.readAsBytesSync();
      expect(
        await const DownloadAudioMetadataService().embed(
          filePath: file.path,
          title: 'Texto portátil 日本語',
          artist: 'BStream Music',
          album: 'Álbum',
          artworkPath: '${directory.path}/missing.png',
        ),
        AudioMetadataWriteResult.written,
      );
      final metadata = readMetadata(file, getImage: true);
      expect(metadata.title, 'Texto portátil 日本語');
      expect(metadata.artist, 'BStream Music');
      expect(metadata.album, 'Álbum');
      expect(metadata.pictures, isEmpty);
      final after = file.readAsBytesSync();
      expect(
        _segmentChildren(after).any((part) => part.id == 0x1941a469),
        isFalse,
      );
      _expectClustersUnchanged(before, after);
      _expectSeekReferencesValid(after);
      expect(directory.listSync().whereType<File>().length, 1);
    },
  );
}

const _uid = -3118299282658040821; // Unsigned UID d4b99290e7f8640b.
const _tags = 0x1254c367;
const _seekHead = 0x114d9b74;
const _cluster = 0x1f43b675;

Uint8List _webm({
  bool unknownSegment = false,
  bool unknownCluster = false,
  bool narrowTagSeek = false,
  bool minimalTags = false,
  bool noTags = false,
  bool extraTrack = false,
  bool segmentCrc = false,
  int trackType = 2,
  String codec = 'A_OPUS',
}) {
  final header = _element(0x1a45dfa3, [
    ..._element(0x4286, [1]),
    ..._element(0x42f7, [1]),
    ..._element(0x42f2, [4]),
    ..._element(0x42f3, [8]),
    ..._element(0x4282, ascii.encode('webm')),
    ..._element(0x4285, [2]),
  ]);
  final track = _element(0xae, [
    ..._element(0xd7, [1]),
    ..._element(0x73c5, _uint(_uid, 8)),
    ..._element(0x83, [trackType]),
    ..._element(0x86, ascii.encode(codec)),
    ..._element(0x63a2, [
      ...ascii.encode('OpusHead'),
      1,
      1,
      ...List.filled(9, 0),
    ]),
  ]);
  final tracks = _element(0x1654ae6b, [...track, if (extraTrack) ...track]);
  final tags = noTags
      ? Uint8List(0)
      : _element(_tags, [
          ..._tag({
            'TITLE': 'Old title',
            if (!minimalTags) ...{
              'ARTIST': 'Old artist',
              'ALBUM': 'Old album',
              'GENRE': 'Electronic',
            },
          }),
          if (!minimalTags)
            ..._tag({'TITLE': 'Canonical album title'}, level: 50),
          if (!minimalTags) ..._tag({'TITLE': 'Other track'}, uid: 7),
        ]);
  final clusterPayload = [
    ..._element(0xe7, [0]),
    ..._element(0xa3, [
      0x81,
      0,
      0,
      0x80,
      ...List.generate(420, (i) => i & 255),
    ]),
  ];
  final cluster = _element(_cluster, clusterPayload, unknown: unknownCluster);
  Uint8List seek(int tagPosition, int trackPosition) => _element(_seekHead, [
    if (!noTags)
      ..._element(0x4dbb, [
        ..._element(0x53ab, _uint(_tags, 4)),
        ..._element(0x53ac, _uint(tagPosition, narrowTagSeek ? 1 : 4)),
      ]),
    ..._element(0x4dbb, [
      ..._element(0x53ab, _uint(0x1654ae6b, 4)),
      ..._element(0x53ac, _uint(trackPosition, 4)),
    ]),
  ]);
  final headSize = seek(0, 0).length;
  final trackPosition = headSize + (segmentCrc ? 6 : 0);
  final tagPosition = trackPosition + tracks.length;
  final clusterPosition = tagPosition + tags.length;
  final cues = unknownCluster
      ? Uint8List(0)
      : _element(0x1c53bb6b, [
          ..._element(0xbb, [
            ..._element(0xb3, [0]),
            ..._element(0xb7, [
              ..._element(0xf7, [1]),
              ..._element(0xf1, _uint(clusterPosition, 4)),
            ]),
          ]),
        ]);
  return Uint8List.fromList([
    ...header,
    ..._element(
      0x18538067,
      [
        ...seek(tagPosition, trackPosition),
        if (segmentCrc) ..._element(0xbf, [0, 0, 0, 0]),
        ...tracks,
        ...tags,
        ...cluster,
        ...cues,
      ],
      width: 8,
      unknown: unknownSegment,
    ),
  ]);
}

Uint8List _tag(Map<String, String> values, {int? level, int? uid}) =>
    _element(0x7373, [
      ..._element(0x63c0, [
        if (level != null) ..._element(0x68ca, [level]),
        if (uid != null) ..._element(0x63c5, _uint(uid, 8)),
      ]),
      for (final value in values.entries)
        ..._element(0x67c8, [
          ..._element(0x45a3, ascii.encode(value.key)),
          ..._element(0x4487, utf8.encode(value.value)),
        ]),
    ]);

List<_ParsedElement> _segmentChildren(Uint8List bytes) {
  final top = _elements(bytes, 0, bytes.length);
  final segment = top.singleWhere((part) => part.id == 0x18538067);
  return _elements(bytes, segment.payload, segment.end);
}

List<_TextTag> _textTags(Uint8List bytes) {
  final result = <_TextTag>[];
  for (final container in _segmentChildren(
    bytes,
  ).where((part) => part.id == _tags)) {
    for (final tag in _elements(
      bytes,
      container.payload,
      container.end,
    ).where((part) => part.id == 0x7373)) {
      var level = 50;
      int? uid;
      final values = <String, String>{};
      for (final part in _elements(bytes, tag.payload, tag.end)) {
        if (part.id == 0x63c0) {
          for (final target in _elements(bytes, part.payload, part.end)) {
            if (target.id == 0x68ca) level = _decodeUint(bytes, target);
            if (target.id == 0x63c5) uid = _decodeUint(bytes, target);
          }
        } else if (part.id == 0x67c8) {
          final fields = _elements(bytes, part.payload, part.end);
          final name = fields.singleWhere((field) => field.id == 0x45a3);
          final value = fields.singleWhere((field) => field.id == 0x4487);
          values[utf8.decode(bytes.sublist(name.payload, name.end))] = utf8
              .decode(bytes.sublist(value.payload, value.end));
        }
      }
      result.add(_TextTag(level, uid, values));
    }
  }
  return result;
}

void _expectClustersUnchanged(Uint8List before, Uint8List after) {
  final oldClusters = _segmentChildren(
    before,
  ).where((part) => part.id == _cluster).toList();
  final newClusters = _segmentChildren(
    after,
  ).where((part) => part.id == _cluster).toList();
  expect(newClusters.length, oldClusters.length);
  for (var index = 0; index < oldClusters.length; index++) {
    final old = oldClusters[index];
    final next = newClusters[index];
    expect(next.start, old.start);
    expect(
      after.sublist(next.start, next.end),
      orderedEquals(before.sublist(old.start, old.end)),
    );
  }
}

void _expectSeekReferencesValid(Uint8List bytes) {
  final segment = _elements(
    bytes,
    0,
    bytes.length,
  ).singleWhere((part) => part.id == 0x18538067);
  final children = _segmentChildren(bytes);
  for (final head in children.where((part) => part.id == _seekHead)) {
    for (final seek in _elements(
      bytes,
      head.payload,
      head.end,
    ).where((part) => part.id == 0x4dbb)) {
      final fields = _elements(bytes, seek.payload, seek.end);
      final id = _decodeUint(
        bytes,
        fields.singleWhere((part) => part.id == 0x53ab),
      );
      final offset = _decodeUint(
        bytes,
        fields.singleWhere((part) => part.id == 0x53ac),
      );
      expect(
        children
            .singleWhere((part) => part.start == segment.payload + offset)
            .id,
        id,
      );
    }
  }
}

void _expectCueReferenceValid(Uint8List bytes) {
  final segment = _elements(
    bytes,
    0,
    bytes.length,
  ).singleWhere((part) => part.id == 0x18538067);
  final children = _segmentChildren(bytes);
  final cues = children.singleWhere((part) => part.id == 0x1c53bb6b);
  final point = _elements(bytes, cues.payload, cues.end).single;
  final trackPositions = _elements(
    bytes,
    point.payload,
    point.end,
  ).singleWhere((part) => part.id == 0xb7);
  final position = _elements(
    bytes,
    trackPositions.payload,
    trackPositions.end,
  ).singleWhere((part) => part.id == 0xf1);
  expect(
    segment.payload + _decodeUint(bytes, position),
    children.singleWhere((part) => part.id == _cluster).start,
  );
}

int _decodeUint(Uint8List bytes, _ParsedElement element) => bytes
    .sublist(element.payload, element.end)
    .fold(0, (value, byte) => (value << 8) | byte);

// An independent fixture parser also resolves unknown Cluster boundaries.
List<_ParsedElement> _elements(Uint8List bytes, int start, int end) {
  final result = <_ParsedElement>[];
  while (start < end) {
    final original = start;
    var width = 1;
    while ((bytes[start] & (1 << (8 - width))) == 0) {
      width++;
    }
    var id = 0;
    for (var index = 0; index < width; index++) {
      id = (id << 8) | bytes[start++];
    }
    width = 1;
    while ((bytes[start] & (1 << (8 - width))) == 0) {
      width++;
    }
    var size = bytes[start++] & ((1 << (8 - width)) - 1);
    for (var index = 1; index < width; index++) {
      size = (size << 8) | bytes[start++];
    }
    final unknown = size == (1 << (7 * width)) - 1;
    var stop = unknown ? end : start + size;
    if (unknown && id == _cluster) {
      var scan = start;
      while (scan < end) {
        final marker = bytes[scan];
        if (marker == 0x12 &&
            bytes[scan + 1] == 0x54 &&
            bytes[scan + 2] == 0xc3 &&
            bytes[scan + 3] == 0x67) {
          stop = scan;
          break;
        }
        final fields = _elements(bytes, scan, end);
        scan = fields.first.end;
      }
    }
    result.add(_ParsedElement(id, original, start, stop));
    start = stop;
  }
  return result;
}

Uint8List _uint(int value, int width) {
  final bytes = Uint8List(width);
  for (var index = width - 1; index >= 0; index--) {
    bytes[index] = value & 255;
    value >>= 8;
  }
  return bytes;
}

Uint8List _element(
  int id,
  List<int> payload, {
  int? width,
  bool unknown = false,
}) {
  final idBytes = _uint(id, (id.bitLength + 7) ~/ 8);
  width ??= 1;
  while (payload.length >= (1 << (7 * width!)) - 1) {
    width++;
  }
  final size = _uint(unknown ? (1 << (7 * width)) - 1 : payload.length, width);
  size[0] |= 1 << (8 - width);
  return Uint8List.fromList([...idBytes, ...size, ...payload]);
}

class _ParsedElement {
  const _ParsedElement(this.id, this.start, this.payload, this.end);
  final int id;
  final int start;
  final int payload;
  final int end;
}

class _TextTag {
  const _TextTag(this.level, this.uid, this.values);
  final int level;
  final int? uid;
  final Map<String, String> values;
}
