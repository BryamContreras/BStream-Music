part of 'music_providers.dart';

final playlistsControllerProvider =
    AsyncNotifierProvider<PlaylistsController, List<Playlist>>(
      PlaylistsController.new,
    );

final favoriteTrackIdsProvider = Provider<Set<String>>((ref) {
  final playlists = ref.watch(playlistsControllerProvider).value;
  if (playlists == null) {
    return const <String>{};
  }
  final favorites = playlists
      .where((playlist) => playlist.isFavorites)
      .firstOrNull;
  return favorites == null
      ? const <String>{}
      : Set<String>.unmodifiable(favorites.trackIds);
});

enum PlaylistDeleteScope { localOnly, youtubeMusicToo }

class PlaylistDeleteOptions {
  const PlaylistDeleteOptions({
    required this.isYouTubeMusicLinked,
    required this.canDeleteFromYouTubeMusic,
    this.remoteAccountKey,
  });

  final bool isYouTubeMusicLinked;
  final bool canDeleteFromYouTubeMusic;
  final String? remoteAccountKey;
}

class PlaylistsController extends AsyncNotifier<List<Playlist>> {
  final _uuid = const Uuid();

  @override
  Future<List<Playlist>> build() async {
    return _sorted(
      await ref.watch(databaseServiceProvider).getCatalogPlaylists(),
    );
  }

  Future<void> create(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return;
    }
    final playlist = await ref
        .read(databaseServiceProvider)
        .createCatalogPlaylist(
          id: _uuid.v4(),
          name: normalized,
          now: DateTime.now(),
        );
    state = AsyncData(_sorted(<Playlist>[playlist, ...?state.value]));
    _invalidateCatalogProviders();
    _requestYouTubeMusicSync();
  }

  CatalogTrack _catalogTrackForLocal(LocalTrack track) {
    final artists = track.artists.isEmpty
        ? <String>[track.artist]
        : track.artists;
    final videoId = track.sourceId?.trim();
    if (videoId != null && videoId.isNotEmpty) {
      return CatalogTrack.youtube(
        videoId: videoId,
        title: track.title,
        artists: artists,
        artistBrowseIds: track.artistBrowseIds,
        album: track.album,
        duration: track.duration,
        thumbnailUrl: track.catalogThumbnailUrl ?? track.thumbnailUrl,
        sourceUrl: track.sourceUrl,
      );
    }
    return CatalogTrack.local(
      localTrackId: track.id,
      title: track.title,
      artists: artists,
      artistBrowseIds: track.artistBrowseIds,
      album: track.album,
      duration: track.duration,
      thumbnailUrl: track.thumbnailUrl,
      sourceUrl: track.sourceUrl,
    );
  }

  /// Adds a catalog entry without forcing an audio download first.
  Future<PlaylistEntry?> addRemoteTrackToPlaylist(
    String playlistId,
    TrackInfo track,
  ) async {
    final videoId = _youtubeVideoId(track);
    if (videoId == null) {
      return null;
    }
    final artists = track.artists.isEmpty
        ? <String>[track.artist]
        : track.artists;
    final entry = await ref
        .read(databaseServiceProvider)
        .appendCatalogEntry(
          playlistId: playlistId,
          entryId: _uuid.v4(),
          track: CatalogTrack.youtube(
            videoId: videoId,
            title: track.title,
            artists: artists,
            artistBrowseIds: track.artistBrowseIds,
            album: track.album,
            duration: track.duration,
            thumbnailUrl: track.catalogThumbnailUrl ?? track.thumbnailUrl,
            sourceUrl: track.url,
          ),
          now: DateTime.now(),
        );
    await _reloadCatalogState();
    await _syncActivePlaybackQueueById(playlistId);
    _requestYouTubeMusicSync();
    return entry;
  }

  Future<void> removeCatalogEntry(String playlistId, String entryId) async {
    await ref
        .read(databaseServiceProvider)
        .tombstoneCatalogEntry(
          playlistId: playlistId,
          entryId: entryId,
          now: DateTime.now(),
        );
    await _reloadCatalogState();
    await _syncActivePlaybackQueueById(playlistId);
    _requestYouTubeMusicSync();
  }

  Future<void> renamePlaylist(String playlistId, String name) async {
    if (playlistId == Playlist.favoritesId) {
      return;
    }
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return;
    }
    await ref
        .read(databaseServiceProvider)
        .renameCatalogPlaylist(
          playlistId: playlistId,
          name: normalized,
          now: DateTime.now(),
        );
    await _reloadCatalogState();
    _requestYouTubeMusicSync();
  }

  Future<PlaylistDeleteOptions> playlistDeleteOptions(String playlistId) async {
    final bindings = await SqlitePlaylistSyncStore(
      ref.read(databaseServiceProvider),
      conflictIdFactory: const Uuid().v4,
    ).listBindings();
    final matches = bindings
        .where(
          (binding) =>
              binding.key.playlistId == playlistId &&
              binding.remotePlaylistId != null,
        )
        .toList(growable: false);
    if (matches.isEmpty) {
      return const PlaylistDeleteOptions(
        isYouTubeMusicLinked: false,
        canDeleteFromYouTubeMusic: false,
      );
    }
    final auth = ref.read(youtubeMusicAuthControllerProvider);
    final activeAccountKey = auth.profile?.accountKey.trim();
    final activeBinding =
        matches.length == 1 &&
        auth.isAuthenticated &&
        activeAccountKey != null &&
        activeAccountKey.isNotEmpty &&
        matches.single.key.accountKey == activeAccountKey;
    return PlaylistDeleteOptions(
      isYouTubeMusicLinked: true,
      canDeleteFromYouTubeMusic: activeBinding && matches.single.isEditable,
      remoteAccountKey: activeBinding ? activeAccountKey : null,
    );
  }

  Future<void> deletePlaylist(
    String playlistId, {
    PlaylistDeleteScope scope = PlaylistDeleteScope.localOnly,
  }) async {
    if (playlistId == Playlist.favoritesId) {
      return;
    }
    var deleteRemote = false;
    String? remoteAccountKey;
    if (scope == PlaylistDeleteScope.youtubeMusicToo) {
      final options = await playlistDeleteOptions(playlistId);
      if (!options.canDeleteFromYouTubeMusic) {
        throw StateError(
          'The active account cannot delete this YouTube Music playlist.',
        );
      }
      deleteRemote = true;
      remoteAccountKey = options.remoteAccountKey;
    }
    await ref
        .read(databaseServiceProvider)
        .tombstoneCatalogPlaylist(
          playlistId: playlistId,
          now: DateTime.now(),
          deleteRemote: deleteRemote,
          remoteAccountKey: remoteAccountKey,
        );
    await _reloadCatalogState();
    await ref
        .read(playerControllerProvider.notifier)
        .clearQueueSource(PlayerController.playlistQueueSourceId(playlistId));
    _requestYouTubeMusicSync();
  }

  Future<void> addTrackToPlaylist(String playlistId, String trackId) async {
    await addTracksToPlaylist(playlistId, [trackId]);
  }

  Future<int> addTracksToPlaylist(
    String playlistId,
    Iterable<String> trackIds,
  ) async {
    final requestedIds = trackIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (requestedIds.isEmpty) {
      return 0;
    }

    final database = ref.read(databaseServiceProvider);
    final catalog = await database.getCatalogPlaylist(playlistId);
    if (catalog == null) {
      return 0;
    }
    final existingIds = catalog.entries
        .where((entry) => !entry.isDeleted)
        .map((entry) => entry.localTrackId)
        .whereType<String>()
        .toSet();
    final additions = requestedIds.where(existingIds.add).toList();
    if (additions.isEmpty) return 0;

    final localTracks = await ref
        .read(libraryRepositoryProvider)
        .getLocalTracks();
    final byId = <String, LocalTrack>{
      for (final track in localTracks) track.id: track,
    };
    var added = 0;
    for (final trackId in additions) {
      final track = byId[trackId];
      if (track == null) continue;
      await database.appendCatalogEntry(
        playlistId: playlistId,
        entryId: _uuid.v4(),
        track: _catalogTrackForLocal(track),
        localTrackId: track.id,
        now: DateTime.now(),
      );
      added += 1;
    }
    if (added == 0) return 0;
    await _reloadCatalogState();
    await _syncActivePlaybackQueueById(playlistId);
    _requestYouTubeMusicSync();
    return added;
  }

  Future<void> removeTrackFromPlaylist(
    String playlistId,
    String trackId,
  ) async {
    await removeTracksFromPlaylist(playlistId, [trackId]);
  }

  Future<int> removeTracksFromPlaylist(
    String playlistId,
    Iterable<String> trackIds,
  ) async {
    final requestedIds = trackIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (requestedIds.isEmpty) {
      return 0;
    }

    final database = ref.read(databaseServiceProvider);
    final catalog = await database.getCatalogPlaylist(playlistId);
    if (catalog == null) return 0;
    final matches = catalog.entries
        .where(
          (entry) =>
              !entry.isDeleted &&
              entry.localTrackId != null &&
              requestedIds.contains(entry.localTrackId),
        )
        .toList(growable: false);
    for (final entry in matches) {
      await database.tombstoneCatalogEntry(
        playlistId: playlistId,
        entryId: entry.id,
        now: DateTime.now(),
      );
    }
    if (matches.isEmpty) return 0;
    await _reloadCatalogState();
    await _syncActivePlaybackQueueById(playlistId);
    _requestYouTubeMusicSync();
    return matches.length;
  }

  Future<bool> toggleFavorite(String trackId) async {
    final normalized = trackId.trim();
    if (normalized.isEmpty) {
      return false;
    }

    final database = ref.read(databaseServiceProvider);
    final playlists = await database.getCatalogPlaylists();
    final index = playlists.indexWhere((playlist) => playlist.isFavorites);
    final now = DateTime.now();

    if (index < 0) {
      await database.createCatalogPlaylist(
        id: Playlist.favoritesId,
        name: ref.read(appStringsProvider).favorites,
        now: now,
      );
    }
    final favorites = await database.getCatalogPlaylist(Playlist.favoritesId);
    if (favorites == null) return false;
    final matching = favorites.entries
        .where((entry) => !entry.isDeleted && entry.localTrackId == normalized)
        .toList(growable: false);
    final wasFavorite = matching.isNotEmpty;
    if (wasFavorite) {
      for (final entry in matching) {
        await database.tombstoneCatalogEntry(
          playlistId: Playlist.favoritesId,
          entryId: entry.id,
          now: now,
        );
      }
    } else {
      final localTracks = await ref
          .read(libraryRepositoryProvider)
          .getLocalTracks();
      final track = localTracks
          .where((item) => item.id == normalized)
          .firstOrNull;
      if (track == null) return false;
      await database.appendCatalogEntry(
        playlistId: Playlist.favoritesId,
        entryId: _uuid.v4(),
        track: _catalogTrackForLocal(track),
        localTrackId: track.id,
        now: now,
      );
    }
    await _reloadCatalogState();
    await _syncActivePlaybackQueueById(Playlist.favoritesId);
    _requestYouTubeMusicSync();
    return !wasFavorite;
  }

  Future<void> removeTrackFromAllPlaylists(String trackId) async {
    await removeTracksFromAllPlaylists([trackId]);
  }

  Future<void> removeTracksFromAllPlaylists(Iterable<String> trackIds) async {
    final requestedIds = trackIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (requestedIds.isEmpty) {
      return;
    }

    final database = ref.read(databaseServiceProvider);
    final playlists = await database.getCatalogPlaylists();
    final changedIds = <String>[];
    for (final playlist in playlists) {
      final catalog = await database.getCatalogPlaylist(playlist.id);
      if (catalog == null) continue;
      final matches = catalog.entries
          .where(
            (entry) =>
                !entry.isDeleted &&
                entry.localTrackId != null &&
                requestedIds.contains(entry.localTrackId),
          )
          .toList(growable: false);
      for (final entry in matches) {
        await database.tombstoneCatalogEntry(
          playlistId: playlist.id,
          entryId: entry.id,
          now: DateTime.now(),
        );
      }
      if (matches.isNotEmpty) changedIds.add(playlist.id);
    }
    if (changedIds.isEmpty) return;
    await _reloadCatalogState();
    for (final playlistId in changedIds) {
      await _syncActivePlaybackQueueById(playlistId);
    }
    _requestYouTubeMusicSync();
  }

  Future<void> reloadFromRepository({bool syncActiveQueue = true}) async {
    final playlists = _sorted(
      await ref.read(databaseServiceProvider).getCatalogPlaylists(),
    );
    state = AsyncData(playlists);
    _invalidateCatalogProviders();
    if (!syncActiveQueue) {
      return;
    }
    for (final playlist in playlists) {
      await _syncActivePlaybackQueueById(playlist.id);
    }
  }

  Future<void> _reloadCatalogState() async {
    final playlists = _sorted(
      await ref.read(databaseServiceProvider).getCatalogPlaylists(),
    );
    state = AsyncData(playlists);
    _invalidateCatalogProviders();
  }

  void _invalidateCatalogProviders() {
    ref
      ..invalidate(catalogPlaylistsProvider)
      ..invalidate(catalogPlaylistProvider);
  }

  void _requestYouTubeMusicSync() {
    ref
        .read(youtubeMusicPlaylistSyncControllerProvider.notifier)
        .requestAutomaticSync();
  }

  String? _youtubeVideoId(TrackInfo track) {
    final direct = track.id.trim();
    if (direct.isNotEmpty) {
      return direct;
    }
    final uri = Uri.tryParse(track.url);
    if (uri == null) {
      return null;
    }
    final queryId = uri.queryParameters['v']?.trim();
    if (queryId != null && queryId.isNotEmpty) {
      return queryId;
    }
    if (uri.host.toLowerCase() == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      final pathId = uri.pathSegments.first.trim();
      return pathId.isEmpty ? null : pathId;
    }
    return null;
  }

  List<Playlist> _sorted(Iterable<Playlist> playlists) {
    final result = playlists.toList(growable: false);
    result.sort((left, right) {
      if (left.isFavorites != right.isFavorites) {
        return left.isFavorites ? -1 : 1;
      }
      return right.updatedAt.compareTo(left.updatedAt);
    });
    return result;
  }

  Future<void> _syncActivePlaybackQueueById(String playlistId) async {
    final sourceId = PlayerController.playlistQueueSourceId(playlistId);
    final player = ref.read(playerControllerProvider.notifier);
    if (!player.isLocalQueueSourceActive(sourceId)) {
      return;
    }

    final catalog = await ref
        .read(databaseServiceProvider)
        .getCatalogPlaylist(playlistId);
    if (catalog == null) {
      await player.clearQueueSource(sourceId);
      return;
    }
    final localTracks = await ref
        .read(libraryRepositoryProvider)
        .getLocalTracks();
    final items = catalogPlaylistPlaybackItems(catalog, localTracks);
    if (items.isEmpty) {
      await player.clearQueueSource(sourceId);
      return;
    }
    await player.syncCatalogPlaylistSource(sourceId, items);
  }
}
