import '../entities/catalog_playlist.dart';
import '../entities/catalog_track.dart';
import '../entities/playlist.dart';
import '../entities/playlist_entry.dart';

class PlaylistRevisionConflict implements Exception {
  const PlaylistRevisionConflict({
    required this.playlistId,
    required this.expected,
    required this.actual,
  });

  final String playlistId;
  final int expected;
  final int actual;

  @override
  String toString() =>
      'PlaylistRevisionConflict($playlistId, expected: $expected, '
      'actual: $actual)';
}

/// Local-first playlist API. Every mutation is transactional and increments
/// [Playlist.localRevision], allowing the sync layer to use compare-and-swap.
abstract interface class CatalogPlaylistRepository {
  Future<List<Playlist>> getCatalogPlaylists({bool includeDeleted = false});

  Future<CatalogPlaylist?> getCatalogPlaylist(
    String playlistId, {
    bool includeDeletedEntries = false,
  });

  Future<Playlist> createCatalogPlaylist({
    required String id,
    required String name,
    required DateTime now,
  });

  Future<Playlist> renameCatalogPlaylist({
    required String playlistId,
    required String name,
    required DateTime now,
  });

  Future<PlaylistEntry> appendCatalogEntry({
    required String playlistId,
    required String entryId,
    required CatalogTrack track,
    required DateTime now,
    String? localTrackId,
    PlaylistEntryOrigin origin = PlaylistEntryOrigin.local,
  });

  Future<void> replaceCatalogEntries({
    required String playlistId,
    required List<PlaylistEntry> entries,
    required DateTime now,
    int? expectedRevision,
  });

  Future<void> tombstoneCatalogEntry({
    required String playlistId,
    required String entryId,
    required DateTime now,
  });

  Future<void> tombstoneCatalogPlaylist({
    required String playlistId,
    required DateTime now,
    bool deleteRemote = false,
    String? remoteAccountKey,
  });
}
