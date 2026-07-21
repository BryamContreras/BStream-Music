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

class PlaylistsController extends AsyncNotifier<List<Playlist>> {
  final _uuid = const Uuid();

  @override
  Future<List<Playlist>> build() async {
    return _sorted(await ref.watch(getPlaylistsProvider).call());
  }

  Future<void> create(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final playlist = Playlist(
      id: _uuid.v4(),
      name: normalized,
      trackIds: const [],
      createdAt: now,
      updatedAt: now,
    );
    await ref.read(libraryRepositoryProvider).savePlaylist(playlist);
    state = AsyncData(_sorted([playlist, ...?state.value]));
  }

  Future<void> renamePlaylist(String playlistId, String name) async {
    if (playlistId == Playlist.favoritesId) {
      return;
    }
    final normalized = name.trim();
    if (normalized.isEmpty) {
      return;
    }
    final playlists = await future;
    final index = playlists.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) {
      return;
    }

    final updated = playlists[index].copyWith(
      name: normalized,
      updatedAt: DateTime.now(),
    );
    await ref.read(libraryRepositoryProvider).savePlaylist(updated);

    final next = [...playlists];
    next[index] = updated;
    state = AsyncData(_sorted(next));
  }

  Future<void> deletePlaylist(String playlistId) async {
    if (playlistId == Playlist.favoritesId) {
      return;
    }
    final playlists = await future;
    final next = playlists
        .where((playlist) => playlist.id != playlistId)
        .toList(growable: false);
    if (next.length == playlists.length) {
      return;
    }

    await ref.read(libraryRepositoryProvider).deletePlaylist(playlistId);
    state = AsyncData(_sorted(next));
  }

  Future<void> addTrackToPlaylist(String playlistId, String trackId) async {
    final playlists = await future;
    final index = playlists.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0 || trackId.trim().isEmpty) {
      return;
    }

    final playlist = playlists[index];
    if (playlist.trackIds.contains(trackId)) {
      return;
    }

    final updated = Playlist(
      id: playlist.id,
      name: playlist.name,
      trackIds: [...playlist.trackIds, trackId],
      createdAt: playlist.createdAt,
      updatedAt: DateTime.now(),
    );
    await ref.read(libraryRepositoryProvider).savePlaylist(updated);

    final next = [...playlists];
    next[index] = updated;
    state = AsyncData(_sorted(next));
    await _syncActivePlaybackQueue(updated);
  }

  Future<void> removeTrackFromPlaylist(
    String playlistId,
    String trackId,
  ) async {
    final playlists = await future;
    final index = playlists.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0 || trackId.trim().isEmpty) {
      return;
    }

    final playlist = playlists[index];
    if (!playlist.trackIds.contains(trackId)) {
      return;
    }

    final updated = Playlist(
      id: playlist.id,
      name: playlist.name,
      trackIds: playlist.trackIds
          .where((id) => id != trackId)
          .toList(growable: false),
      createdAt: playlist.createdAt,
      updatedAt: DateTime.now(),
    );
    await ref.read(libraryRepositoryProvider).savePlaylist(updated);

    final next = [...playlists];
    next[index] = updated;
    state = AsyncData(_sorted(next));
  }

  Future<bool> toggleFavorite(String trackId) async {
    final normalized = trackId.trim();
    if (normalized.isEmpty) {
      return false;
    }

    final playlists = await future;
    final index = playlists.indexWhere((playlist) => playlist.isFavorites);
    final now = DateTime.now();

    if (index < 0) {
      final favorites = Playlist(
        id: Playlist.favoritesId,
        name: ref.read(appStringsProvider).favorites,
        trackIds: [normalized],
        createdAt: now,
        updatedAt: now,
      );
      await ref.read(libraryRepositoryProvider).savePlaylist(favorites);
      state = AsyncData(_sorted([favorites, ...playlists]));
      return true;
    }

    final favorites = playlists[index];
    final wasFavorite = favorites.trackIds.contains(normalized);
    final updated = favorites.copyWith(
      trackIds: wasFavorite
          ? favorites.trackIds
                .where((id) => id != normalized)
                .toList(growable: false)
          : [...favorites.trackIds, normalized],
      updatedAt: now,
    );
    await ref.read(libraryRepositoryProvider).savePlaylist(updated);

    final next = [...playlists];
    next[index] = updated;
    state = AsyncData(_sorted(next));
    return !wasFavorite;
  }

  Future<void> removeTrackFromAllPlaylists(String trackId) async {
    final playlists = await future;
    final next = <Playlist>[];
    var changed = false;

    for (final playlist in playlists) {
      if (!playlist.trackIds.contains(trackId)) {
        next.add(playlist);
        continue;
      }

      changed = true;
      final updated = Playlist(
        id: playlist.id,
        name: playlist.name,
        trackIds: playlist.trackIds
            .where((id) => id != trackId)
            .toList(growable: false),
        createdAt: playlist.createdAt,
        updatedAt: DateTime.now(),
      );
      await ref.read(libraryRepositoryProvider).savePlaylist(updated);
      next.add(updated);
    }

    if (!changed) {
      return;
    }

    state = AsyncData(_sorted(next));
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

  Future<void> _syncActivePlaybackQueue(Playlist playlist) async {
    final sourceId = PlayerController.playlistQueueSourceId(playlist.id);
    final player = ref.read(playerControllerProvider.notifier);
    if (!player.isLocalQueueSourceActive(sourceId)) {
      return;
    }

    final localTracks = await ref
        .read(libraryRepositoryProvider)
        .getLocalTracks();
    final tracksById = {for (final track in localTracks) track.id: track};
    final orderedTracks = playlist.trackIds
        .map((id) => tracksById[id])
        .whereType<LocalTrack>()
        .toList(growable: false);
    player.syncLocalQueueSource(sourceId, orderedTracks);
  }
}
