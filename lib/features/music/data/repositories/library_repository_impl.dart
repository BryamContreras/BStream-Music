import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/repositories/library_repository.dart';
import '../datasources/local_music_datasource.dart';

class LibraryRepositoryImpl implements LibraryRepository {
  const LibraryRepositoryImpl(this._localDataSource);

  final LocalMusicDataSource _localDataSource;

  @override
  Future<List<LocalTrack>> getLocalTracks() {
    return _localDataSource.getLocalTracks();
  }

  @override
  Future<void> saveLocalTrack(LocalTrack track) {
    return _localDataSource.saveLocalTrack(track);
  }

  @override
  Future<void> deleteLocalTrack(String trackId) {
    return _localDataSource.deleteLocalTrack(trackId);
  }

  @override
  Future<void> markPlayed(String trackId, DateTime playedAt) {
    return _localDataSource.markPlayed(trackId, playedAt);
  }

  @override
  Future<List<LocalTrack>> getHistory() {
    return _localDataSource.getHistory();
  }

  @override
  Future<List<Playlist>> getPlaylists() {
    return _localDataSource.getPlaylists();
  }

  @override
  Future<void> savePlaylist(Playlist playlist) {
    return _localDataSource.savePlaylist(playlist);
  }

  @override
  Future<void> deletePlaylist(String playlistId) {
    return _localDataSource.deletePlaylist(playlistId);
  }
}
