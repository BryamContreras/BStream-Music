import 'playlist.dart';
import 'playlist_entry.dart';

class CatalogPlaylist {
  CatalogPlaylist({
    required this.playlist,
    required Iterable<PlaylistEntry> entries,
  }) : entries = List<PlaylistEntry>.unmodifiable(entries);

  final Playlist playlist;
  final List<PlaylistEntry> entries;
}
