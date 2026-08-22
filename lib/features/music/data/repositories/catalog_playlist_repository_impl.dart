import '../../../../services/storage/local_database_service.dart';
import '../../domain/entities/catalog_playlist.dart';
import '../../domain/entities/catalog_track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/playlist_entry.dart';
import '../../domain/repositories/catalog_playlist_repository.dart';

class CatalogPlaylistRepositoryImpl implements CatalogPlaylistRepository {
  const CatalogPlaylistRepositoryImpl(this._database);

  final LocalDatabaseService _database;

  @override
  Future<List<Playlist>> getCatalogPlaylists({bool includeDeleted = false}) =>
      _database.getCatalogPlaylists(includeDeleted: includeDeleted);

  @override
  Future<CatalogPlaylist?> getCatalogPlaylist(
    String playlistId, {
    bool includeDeletedEntries = false,
  }) => _database.getCatalogPlaylist(
    playlistId,
    includeDeletedEntries: includeDeletedEntries,
  );

  @override
  Future<Playlist> createCatalogPlaylist({
    required String id,
    required String name,
    required DateTime now,
  }) => _database.createCatalogPlaylist(id: id, name: name, now: now);

  @override
  Future<Playlist> renameCatalogPlaylist({
    required String playlistId,
    required String name,
    required DateTime now,
  }) => _database.renameCatalogPlaylist(
    playlistId: playlistId,
    name: name,
    now: now,
  );

  @override
  Future<PlaylistEntry> appendCatalogEntry({
    required String playlistId,
    required String entryId,
    required CatalogTrack track,
    required DateTime now,
    String? localTrackId,
    PlaylistEntryOrigin origin = PlaylistEntryOrigin.local,
  }) => _database.appendCatalogEntry(
    playlistId: playlistId,
    entryId: entryId,
    track: track,
    now: now,
    localTrackId: localTrackId,
    origin: origin,
  );

  @override
  Future<void> replaceCatalogEntries({
    required String playlistId,
    required List<PlaylistEntry> entries,
    required DateTime now,
    int? expectedRevision,
  }) => _database.replaceCatalogEntries(
    playlistId: playlistId,
    entries: entries,
    now: now,
    expectedRevision: expectedRevision,
  );

  @override
  Future<void> tombstoneCatalogEntry({
    required String playlistId,
    required String entryId,
    required DateTime now,
  }) => _database.tombstoneCatalogEntry(
    playlistId: playlistId,
    entryId: entryId,
    now: now,
  );

  @override
  Future<void> tombstoneCatalogPlaylist({
    required String playlistId,
    required DateTime now,
    bool deleteRemote = false,
    String? remoteAccountKey,
  }) => _database.tombstoneCatalogPlaylist(
    playlistId: playlistId,
    now: now,
    deleteRemote: deleteRemote,
    remoteAccountKey: remoteAccountKey,
  );
}
