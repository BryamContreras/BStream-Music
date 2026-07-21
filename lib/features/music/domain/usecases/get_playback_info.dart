import '../entities/track_info.dart';
import '../repositories/music_repository.dart';

class GetPlaybackInfo {
  const GetPlaybackInfo(this._repository);

  final MusicRepository _repository;

  Future<TrackInfo> call(String url) {
    return _repository.getPlaybackInfo(url);
  }
}
