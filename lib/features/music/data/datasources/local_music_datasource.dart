import '../../../../services/storage/local_database_service.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/playlist.dart';

class LocalMusicDataSource {
  const LocalMusicDataSource(this._databaseService);

  final LocalDatabaseService _databaseService;

  Future<List<LocalTrack>> getLocalTracks() {
    return _databaseService.getLocalTracks();
  }

  Future<void> saveLocalTrack(LocalTrack track) {
    return _databaseService.saveLocalTrack(track);
  }

  Future<void> deleteLocalTrack(String trackId) {
    return _databaseService.deleteLocalTrack(trackId);
  }

  Future<void> markPlayed(String trackId, DateTime playedAt) {
    return _databaseService.markPlayed(trackId, playedAt);
  }

  Future<List<LocalTrack>> getHistory() {
    return _databaseService.getHistory();
  }

  Future<List<Playlist>> getPlaylists() {
    return _databaseService.getPlaylists();
  }

  Future<void> savePlaylist(Playlist playlist) {
    return _databaseService.savePlaylist(playlist);
  }

  Future<void> deletePlaylist(String playlistId) {
    return _databaseService.deletePlaylist(playlistId);
  }
}
