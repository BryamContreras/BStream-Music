import '../entities/local_track.dart';
import '../entities/playlist.dart';

abstract class LibraryRepository {
  Future<List<LocalTrack>> getLocalTracks();
  Future<void> saveLocalTrack(LocalTrack track);
  Future<void> deleteLocalTrack(String trackId);
  Future<void> markPlayed(String trackId, DateTime playedAt);
  Future<List<LocalTrack>> getHistory();
  Future<List<Playlist>> getPlaylists();
  Future<void> savePlaylist(Playlist playlist);
  Future<void> deletePlaylist(String playlistId);
}
