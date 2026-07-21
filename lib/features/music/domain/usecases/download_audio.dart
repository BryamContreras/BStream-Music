import '../entities/download_options.dart';
import '../entities/download_result.dart';
import '../repositories/music_repository.dart';

class DownloadAudio {
  const DownloadAudio(this._repository);

  final MusicRepository _repository;

  Future<DownloadResult> call(String url, DownloadOptions options) {
    return _repository.downloadAudio(url, options);
  }
}
