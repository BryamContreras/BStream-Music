import 'dart:typed_data';

enum AudioMetadataWriteResult { written, unchanged, unsupported, failed }

/// Catalog data and an already-cached, bounded JPEG/PNG cover shared by writers.
class AudioMetadataTags {
  const AudioMetadataTags({
    required this.title,
    required this.artist,
    this.album,
    this.artworkBytes,
    this.artworkMimeType,
  });

  final String title;
  final String artist;
  final String? album;
  final Uint8List? artworkBytes;
  final String? artworkMimeType;
}
