import '../entities/local_track.dart';
import '../repositories/library_repository.dart';

class GetLibraryTracks {
  const GetLibraryTracks(this._repository);

  final LibraryRepository _repository;

  Future<List<LocalTrack>> call() {
    return _repository.getLocalTracks();
  }
}
