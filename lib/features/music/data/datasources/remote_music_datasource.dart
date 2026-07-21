import '../../../../services/downloader/downloader_service.dart';
import '../../domain/entities/download_options.dart';
import '../../domain/entities/download_result.dart';
import '../../domain/entities/track_info.dart';

class RemoteMusicDataSource {
  const RemoteMusicDataSource(this._downloaderService);

  final DownloaderService _downloaderService;

  Stream<DownloadProgress> get progressStream =>
      _downloaderService.progressStream;

  Future<TrackInfo> getInfo(String url) {
    return _downloaderService.getInfo(url);
  }

  Future<TrackInfo> getPlaybackInfo(String url) {
    return _downloaderService.getPlaybackInfo(url);
  }

  Future<List<TrackInfo>> search(String query) {
    return _downloaderService.search(query);
  }

  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    return _downloaderService.downloadAudio(url, options);
  }
}
