import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../../core/utils/background_work.dart';
import 'audio_metadata_container.dart';
import 'audio_metadata_fields.dart';
import 'm4a_metadata_writer.dart';
import 'ogg_audio_metadata_writer.dart';
import 'standard_audio_metadata_writer.dart';
import 'webm_audio_metadata_writer.dart';

export 'audio_metadata_fields.dart' show AudioMetadataWriteResult;

/// Adds portable tags to completed, owned downloads before library publication.
/// Uses already-resolved metadata and cached artwork, with no network requests.
class DownloadAudioMetadataService {
  const DownloadAudioMetadataService();

  // Downloads can finish concurrently. Serialize tagging so cover decoding and
  // file replacement never compete for memory or rewrite the same file twice.
  static Future<void> _tail = Future<void>.value();

  Future<AudioMetadataWriteResult> embed({
    required String filePath,
    required String title,
    required String artist,
    String? album,
    String? artworkPath,
  }) async {
    if (title.length > 16384 ||
        artist.length > 16384 ||
        (album?.length ?? 0) > 16384) {
      return AudioMetadataWriteResult.unsupported;
    }
    final previous = _tail;
    final completed = Completer<void>();
    _tail = completed.future;
    try {
      await previous;
      final job = _MetadataJob(
        filePath: filePath,
        title: title,
        artist: artist,
        album: album,
        artworkPath: artworkPath,
      );
      return await runBackgroundWork(
        job.run,
        debugName: 'Write downloaded audio metadata',
      );
    } on Object {
      // Optional tags must not turn a completed transfer into a failed download.
      return AudioMetadataWriteResult.failed;
    } finally {
      completed.complete();
    }
  }
}

class _MetadataJob {
  const _MetadataJob({
    required this.filePath,
    required this.title,
    required this.artist,
    required this.album,
    required this.artworkPath,
  });

  final String filePath;
  final String title;
  final String artist;
  final String? album;
  final String? artworkPath;

  AudioMetadataWriteResult run() {
    final file = File(filePath);
    final container = detectAudioMetadataContainer(file);
    if (container == AudioMetadataContainer.unsupported) {
      return AudioMetadataWriteResult.unsupported;
    }
    // WebM supports text tags but not image attachments. Its cached artwork
    // remains external; do not decode an image that this container cannot use.
    final artwork = container == AudioMetadataContainer.webm
        ? null
        : _readCover(artworkPath);
    final tags = AudioMetadataTags(
      title: title,
      artist: artist,
      album: album,
      artworkBytes: artwork?.bytes,
      artworkMimeType: artwork?.mimeType,
    );
    return switch (container) {
      AudioMetadataContainer.mp4 => switch (writeM4aTags(
        file,
        title: tags.title,
        artist: tags.artist,
        album: tags.album,
        artworkBytes: tags.artworkBytes,
        artworkMimeType: tags.artworkMimeType,
      )) {
        M4aTagWriteResult.written => AudioMetadataWriteResult.written,
        M4aTagWriteResult.unchanged => AudioMetadataWriteResult.unchanged,
        M4aTagWriteResult.unsupported => AudioMetadataWriteResult.unsupported,
        M4aTagWriteResult.failed => AudioMetadataWriteResult.failed,
      },
      AudioMetadataContainer.standard => writeStandardAudioTags(file, tags),
      AudioMetadataContainer.ogg => writeOggAudioTags(file, tags),
      AudioMetadataContainer.webm => writeWebmAudioTags(file, tags),
      AudioMetadataContainer.unsupported =>
        AudioMetadataWriteResult.unsupported,
    };
  }
}

typedef _Cover = ({Uint8List bytes, String mimeType});

_Cover? _readCover(String? path) {
  if (path == null || path.isEmpty) return null;
  try {
    final file = File(path);
    final size = file.lengthSync();
    if (size <= 0 || size > 10 * 1024 * 1024) return null;
    final bytes = file.readAsBytesSync();
    final decoder = image.findDecoderForData(bytes);
    if (decoder == null) return null;
    final format = decoder.format;
    if (format != image.ImageFormat.jpg &&
        format != image.ImageFormat.png &&
        format != image.ImageFormat.webp) {
      return null;
    }
    final info = decoder.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > 4 * 1024 * 1024) {
      return null;
    }
    // Reuse small JPEG/PNG thumbnails byte-for-byte. MP4 artwork cannot use WebP.
    if (info.width <= 512 &&
        info.height <= 512 &&
        bytes.length <= 512 * 1024 &&
        format != image.ImageFormat.webp) {
      return (
        bytes: bytes,
        mimeType: format == image.ImageFormat.jpg ? 'image/jpeg' : 'image/png',
      );
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) return null;
    // Bound both pixel work and the bytes added to each audio file. A 320 px
    // alpha cover fits within 512 KiB even when PNG compression is ineffective.
    final maximum = decoded.hasAlpha ? 320 : 512;
    final ratio =
        maximum /
        (decoded.width > decoded.height ? decoded.width : decoded.height);
    final resized = ratio < 1
        ? image.copyResize(
            decoded,
            width: (decoded.width * ratio).round().clamp(1, maximum),
            height: (decoded.height * ratio).round().clamp(1, maximum),
            interpolation: image.Interpolation.average,
          )
        : decoded;
    return decoded.hasAlpha
        ? (bytes: image.encodePng(resized), mimeType: 'image/png')
        : (
            bytes: image.encodeJpg(resized, quality: 88),
            mimeType: 'image/jpeg',
          );
  } on Object {
    // A missing or corrupt cover does not prevent writing the text tags.
    return null;
  }
}
