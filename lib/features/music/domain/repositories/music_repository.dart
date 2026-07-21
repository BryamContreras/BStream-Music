import '../entities/download_options.dart';
import '../entities/download_result.dart';
import '../entities/track_info.dart';

abstract class MusicRepository {
  Future<TrackInfo> getInfo(String url);
  Future<TrackInfo> getPlaybackInfo(String url);
  Future<List<TrackInfo>> search(String query);
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options);
}
