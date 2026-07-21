import '../entities/playlist.dart';
import '../repositories/library_repository.dart';

class GetPlaylists {
  const GetPlaylists(this._repository);

  final LibraryRepository _repository;

  Future<List<Playlist>> call() {
    return _repository.getPlaylists();
  }
}
