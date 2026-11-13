import 'dart:typed_data';

import '../audio_sources/audio_format_details.dart';
import '../audio_sources/mp4_audio_format.dart';
import 'jiosaavn_http_transport.dart';

/// Reuses the rendition verification prefix and reads only the MP4 movie header.
/// Large media/artwork boxes are skipped by their declared size, never fetched.
Future<AudioFormatDetails?> probeJioSaavnAudioFormat(
  Uri uri, {
  required JioSaavnHttpTransport transport,
  required JioSaavnHttpResponse prefix,
  required int fileLength,
  required bool Function() shouldContinue,
}) async {
  const maximumBytes = 256 * 1024;
  const timeBudget = Duration(seconds: 2);
  final elapsed = Stopwatch()..start();
  bool current() => elapsed.elapsed < timeBudget && shouldContinue();
  var remaining = maximumBytes - prefix.body.length;
  var requests = 0;

  Future<Uint8List?> read(int offset, int count) async {
    if (!current() || offset < 0 || count < 0 || offset + count > fileLength) {
      return null;
    }
    if (offset + count <= prefix.body.length) {
      return Uint8List.sublistView(prefix.body, offset, offset + count);
    }
    final cached = (prefix.body.length - offset).clamp(0, count);
    final seekOffset = offset + cached, seekCount = count - cached;
    // A truncated initial prefix cannot establish reliable seek offsets.
    if (prefix.body.length < fileLength.clamp(0, 4096) ||
        seekCount > remaining ||
        requests >= 5) {
      return null;
    }
    requests++;
    remaining -= seekCount;
    final response = await transport.get(
      uri,
      headers: {
        'Range': 'bytes=$seekOffset-${offset + count - 1}',
        'Accept-Encoding': 'identity',
        'User-Agent': 'Mozilla/5.0',
      },
      maximumBytes: seekCount,
      readPrefix: true,
      timeout: timeBudget - elapsed.elapsed,
    );
    if (!current() ||
        response.statusCode != 206 ||
        response.body.length != seekCount) {
      return null;
    }
    final range = RegExp(
      r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$',
    ).firstMatch(response.headers['content-range']?.trim() ?? '');
    if (range == null ||
        int.tryParse(range.group(1)!) != seekOffset ||
        int.tryParse(range.group(2)!) != offset + count - 1 ||
        int.tryParse(range.group(3)!) != fileLength) {
      return null;
    }
    if (cached == 0) return response.body;
    return Uint8List(count)
      ..setRange(0, cached, prefix.body, offset)
      ..setRange(cached, count, response.body);
  }

  try {
    for (
      var offset = 0, boxes = 0;
      offset + 8 <= fileLength && boxes < 16 && current();
      boxes++
    ) {
      final header = await read(offset, 8);
      if (header == null) return null;
      var size = ByteData.sublistView(header).getUint32(0);
      var headerSize = 8;
      if (size == 1) {
        final extended = await read(offset + 8, 8);
        if (extended == null) return null;
        size = ByteData.sublistView(extended).getUint64(0);
        headerSize = 16;
      } else if (size == 0) {
        size = fileLength - offset;
      }
      if (size < headerSize || size > fileLength - offset) return null;
      if (String.fromCharCodes(header.sublist(4, 8)) == 'moov') {
        // A complete moov can be parsed independently of mdat and chunk offsets.
        // Refuse oversized headers instead of turning an optional label into a
        // large download. Missing facts never prevent the verified upgrade.
        final cached = (prefix.body.length - offset).clamp(0, size);
        if (size > maximumBytes || size - cached > remaining) return null;
        final bytes = await read(offset, size);
        return bytes == null ? null : readMp4AudioFormatBytes(bytes);
      }
      offset += size;
    }
  } on Object {
    // Unsupported/malformed headers and CDN seek failures are optional details.
  }
  return null;
}
