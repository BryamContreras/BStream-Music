import '../../features/music/domain/entities/download_options.dart';
import '../../features/music/domain/entities/download_result.dart';
import '../../features/music/domain/entities/track_info.dart';

abstract class DownloaderService {
  Stream<DownloadProgress> get progressStream;

  Future<void> initialize();
  Future<TrackInfo> getInfo(String url);
  Future<TrackInfo> getPlaybackInfo(String url);
  Future<List<TrackInfo>> search(String query);
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options);
}

/// A local media resource prepared by an extractor-managed downloader.
///
/// Unlike a direct GoogleVideo URL, this resource has already been fetched
/// with the downloader's chunking, retries, active client and signature
/// handling.
class ManagedPlaybackResource {
  const ManagedPlaybackResource({
    required this.filePath,
    this.extension,
    this.mimeType,
    this.formatId,
    this.codec,
  });

  final String filePath;
  final String? extension;
  final String? mimeType;
  final String? formatId;
  final String? codec;

  String get uri => Uri.file(filePath).toString();
}

/// Optional capability used for the final, transport-safe playback fallback.
///
/// Keeping this separate from [DownloaderService] means alternate/test
/// downloaders can continue returning direct URLs when managed playback is not
/// available.
abstract interface class ManagedPlaybackDownloader {
  Future<ManagedPlaybackResource> prepareManagedPlayback(String url);
}
