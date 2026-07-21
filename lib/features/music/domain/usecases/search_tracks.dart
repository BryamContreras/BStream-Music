import '../entities/track_info.dart';
import '../repositories/music_repository.dart';

class SearchTracks {
  const SearchTracks(this._repository);

  final MusicRepository _repository;

  Future<List<TrackInfo>> call(String query) {
    final normalized = query.trim();
    if (normalized.isEmpty) {
      return Future.value(const []);
    }
    return _repository.search(normalized);
  }
}
