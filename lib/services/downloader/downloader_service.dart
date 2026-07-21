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
