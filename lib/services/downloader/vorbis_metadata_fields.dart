import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'audio_metadata_fields.dart';

const _maximumCommentsBytes = 8 * 1024 * 1024;
const _maximumCommentCount = 100000;

/// Updates the common comment payload used by FLAC, Vorbis and Ogg Opus.
/// Container framing bytes are deliberately left to the corresponding writer.
Uint8List updateVorbisComments(
  Uint8List existing,
  AudioMetadataTags tags, {
  bool embedPicture = false,
}) {
  final parsed = existing.isEmpty
      ? _Comments(Uint8List.fromList(utf8.encode('BStream Music')), const [])
      : _readComments(existing, requireEnd: true);
  final edits = <String, Uint8List>{};
  void text(String key, String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return;
    if (normalized.length > 16384) {
      throw const FormatException('Oversized Vorbis text tag');
    }
    edits[key] = Uint8List.fromList(utf8.encode('$key=$normalized'));
  }

  text('TITLE', tags.title);
  text('ARTIST', tags.artist);
  text('ALBUM', tags.album);
  final newPicture = embedPicture && tags.artworkBytes != null;
  if (newPicture) {
    edits['METADATA_BLOCK_PICTURE'] = Uint8List.fromList(
      utf8.encode(
        'METADATA_BLOCK_PICTURE=${base64.encode(encodeFlacPicture(tags))}',
      ),
    );
  }
  final fields = <Uint8List>[];
  final applied = <String>{};
  for (final field in parsed.fields) {
    final equals = field.indexOf(0x3d);
    final key = equals < 0
        ? ''
        : String.fromCharCodes(field.sublist(0, equals)).toUpperCase();
    if (newPicture && (key == 'COVERART' || key == 'COVERARTMIME')) continue;
    var replacement = edits[key];
    if (key == 'METADATA_BLOCK_PICTURE' &&
        replacement != null &&
        !_isFrontCover(field, equals + 1)) {
      replacement = null;
    }
    if (replacement == null) {
      fields.add(field);
    } else if (applied.add(key)) {
      fields.add(replacement);
    }
  }
  for (final entry in edits.entries) {
    if (applied.add(entry.key)) fields.add(entry.value);
  }
  if (fields.length > _maximumCommentCount) {
    throw const FormatException('Too many Vorbis comments');
  }
  final output = BytesBuilder(copy: false)
    ..add(_little32(parsed.vendor.length))
    ..add(parsed.vendor)
    ..add(_little32(fields.length));
  var length = parsed.vendor.length + 8;
  for (final field in fields) {
    length += 4 + field.length;
    if (length > _maximumCommentsBytes) {
      throw const FormatException('Oversized Vorbis comments');
    }
    output
      ..add(_little32(field.length))
      ..add(field);
  }
  return output.takeBytes();
}

/// Locates the end of vendor/count/fields before Ogg framing or Opus padding.
int vorbisCommentsLength(Uint8List bytes) =>
    _readComments(bytes, requireEnd: false).length;

/// Front-cover PICTURE payload, shared by FLAC blocks and Ogg base64 comments.
/// The image's header is inspected without decoding its pixels again.
Uint8List encodeFlacPicture(AudioMetadataTags tags) {
  final bytes = tags.artworkBytes;
  final mime = tags.artworkMimeType;
  if (bytes == null || bytes.isEmpty || bytes.length > 4 * 1024 * 1024) {
    throw const FormatException('Invalid embedded picture size');
  }
  final decoder = image.findDecoderForData(bytes);
  if (decoder == null ||
      (mime != 'image/png' && mime != 'image/jpeg') ||
      (mime == 'image/png' && decoder.format != image.ImageFormat.png) ||
      (mime == 'image/jpeg' && decoder.format != image.ImageFormat.jpg)) {
    throw const FormatException('Unsupported embedded picture format');
  }
  final info = decoder.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 4 * 1024 * 1024) {
    throw const FormatException('Invalid embedded picture dimensions');
  }
  var depth = 24;
  var palette = 0;
  if (info is image.JpegInfo) depth = info.numComponents * 8;
  if (info is image.PngInfo) {
    final channels = switch (info.colorType) {
      0 || 3 => 1,
      2 => 3,
      4 => 2,
      6 => 4,
      _ => throw const FormatException('Invalid PNG color type'),
    };
    depth = channels * info.bits;
    if (info.colorType == 3) palette = (info.palette?.length ?? 0) ~/ 3;
  }
  if (depth <= 0) throw const FormatException('Invalid picture bit depth');
  final mimeBytes = ascii.encode(mime!);
  return (BytesBuilder(copy: false)
        ..add(_big32(3))
        ..add(_big32(mimeBytes.length))
        ..add(mimeBytes)
        ..add(_big32(0))
        ..add(_big32(info.width))
        ..add(_big32(info.height))
        ..add(_big32(depth))
        ..add(_big32(palette))
        ..add(_big32(bytes.length))
        ..add(bytes))
      .takeBytes();
}

bool _isFrontCover(Uint8List field, int valueOffset) {
  try {
    final picture = base64.decode(
      ascii.decode(Uint8List.sublistView(field, valueOffset)),
    );
    return picture.length >= 4 &&
        ByteData.sublistView(picture).getUint32(0) == 3;
  } on Object {
    // Keep unknown and malformed unmanaged artwork rather than discard it.
    return false;
  }
}

_Comments _readComments(Uint8List bytes, {required bool requireEnd}) {
  if (bytes.length > _maximumCommentsBytes) {
    throw const FormatException('Oversized Vorbis comments');
  }
  final data = ByteData.sublistView(bytes);
  var offset = 0;
  int integer() {
    if (offset + 4 > bytes.length) {
      throw const FormatException('Truncated Vorbis comments');
    }
    final value = data.getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  Uint8List vector() {
    final length = integer();
    if (length > bytes.length - offset) {
      throw const FormatException('Truncated Vorbis comment vector');
    }
    final value = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return value;
  }

  final vendor = vector();
  final count = integer();
  if (count > _maximumCommentCount || count > (bytes.length - offset) ~/ 4) {
    throw const FormatException('Invalid Vorbis comment count');
  }
  final fields = <Uint8List>[];
  for (var index = 0; index < count; index++) {
    fields.add(vector());
  }
  if (requireEnd && offset != bytes.length) {
    throw const FormatException('Unexpected Vorbis comment tail');
  }
  return _Comments(vendor, fields, offset);
}

class _Comments {
  const _Comments(this.vendor, this.fields, [this.length = 0]);

  final Uint8List vendor;
  final List<Uint8List> fields;
  final int length;
}

Uint8List _little32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

Uint8List _big32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
