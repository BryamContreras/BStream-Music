import '../../features/music/domain/entities/download_options.dart';
import '../../features/music/domain/entities/download_result.dart';
import '../../features/music/domain/entities/track_info.dart';
import '../../platform_channels/android_ytdl_channel.dart';
import 'downloader_service.dart';

class AndroidDownloaderService implements DownloaderService {
  AndroidDownloaderService(this._channel);

  final AndroidYtdlChannel _channel;
  bool _initialized = false;

  @override
  Stream<DownloadProgress> get progressStream => _channel.progressStream;

  @override
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    await _channel.initYtdl();
    _initialized = true;
  }

  @override
  Future<TrackInfo> getInfo(String url) async {
    await initialize();
    return _channel.getInfo(url);
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) async {
    await initialize();
    return _channel.getPlaybackInfo(url);
  }

  @override
  Future<List<TrackInfo>> search(String query) async {
    await initialize();
    return _channel.search(query);
  }

  @override
  Future<DownloadResult> downloadAudio(
    String url,
    DownloadOptions options,
  ) async {
    await initialize();
    return _channel.downloadAudio(url, options);
  }
}
