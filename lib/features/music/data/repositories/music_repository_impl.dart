import '../../domain/entities/download_options.dart';
import '../../domain/entities/download_result.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/repositories/music_repository.dart';
import '../datasources/remote_music_datasource.dart';

class MusicRepositoryImpl implements MusicRepository {
  const MusicRepositoryImpl(this._remoteDataSource);

  final RemoteMusicDataSource _remoteDataSource;

  @override
  Future<TrackInfo> getInfo(String url) {
    return _remoteDataSource.getInfo(url);
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) {
    return _remoteDataSource.getPlaybackInfo(url);
  }

  @override
  Future<List<TrackInfo>> search(String query) {
    return _remoteDataSource.search(query);
  }

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    return _remoteDataSource.downloadAudio(url, options);
  }
}
