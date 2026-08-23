// ignore_for_file: prefer_initializing_formals

import '../../../features/music/domain/entities/playlist.dart';
import '../../../features/music/domain/repositories/catalog_playlist_repository.dart';
import 'playlist_sync_engine.dart';
import 'playlist_sync_models.dart';
import 'playlist_sync_store.dart';
import 'youtube_music_playlist_gateway.dart';

typedef LocalPlaylistIdFactory = String Function();

class PlaylistAccountSyncResult {
  PlaylistAccountSyncResult({
    required this.results,
    required this.importedRemoteCount,
    required this.linkedLocalCount,
    this.bootstrapError,
  });

  final Map<PlaylistSyncKey, PlaylistSyncResult> results;
  final int importedRemoteCount;
  final int linkedLocalCount;
  final Object? bootstrapError;
}

/// Bootstraps one account by immutable IDs, then runs every binding.
///
/// It never matches names and never treats absence during the initial import as
/// a deletion. Local unbound playlists become private remote playlists, while
/// unbound remote playlists receive a new local UUID. YouTube Music's system
/// Liked Music collection is bound to BStream's reserved Favorites playlist
/// and is never imported as a second local playlist.
class PlaylistAccountSyncCoordinator {
  const PlaylistAccountSyncCoordinator({
    required CatalogPlaylistRepository playlists,
    required PlaylistSyncStore store,
    required PlaylistSyncEngine engine,
    required YouTubeMusicPlaylistCatalogGateway catalogGateway,
    required LocalPlaylistIdFactory localPlaylistIdFactory,
    required DateTime Function() clock,
    bool Function()? canPersist,
  }) : _playlists = playlists,
       _store = store,
       _engine = engine,
       _catalogGateway = catalogGateway,
       _localPlaylistIdFactory = localPlaylistIdFactory,
       _clock = clock,
       _canPersist = canPersist;

  final CatalogPlaylistRepository _playlists;
  final PlaylistSyncStore _store;
  final PlaylistSyncEngine _engine;
  final YouTubeMusicPlaylistCatalogGateway _catalogGateway;
  final LocalPlaylistIdFactory _localPlaylistIdFactory;
  final DateTime Function() _clock;
  final bool Function()? _canPersist;

  Future<PlaylistAccountSyncResult> syncAll(
    String accountKey, {
    PlaylistSyncTrigger trigger = PlaylistSyncTrigger.manual,
    PlaylistSyncMode newBindingMode = PlaylistSyncMode.automatic,
  }) async {
    final normalizedAccount = accountKey.trim();
    if (normalizedAccount.isEmpty) {
      throw ArgumentError.value(accountKey, 'accountKey', 'Must not be empty.');
    }
    _ensurePersistenceAllowed();
    final allExistingBindings = await _store.listBindings();
    _ensurePersistenceAllowed();
    final existingBindings = allExistingBindings
        .where((binding) => binding.key.accountKey == normalizedAccount)
        .toList(growable: false);
    List<RemotePlaylistSummary> remotes;
    Object? bootstrapError;
    try {
      remotes = await _catalogGateway.listRemotePlaylists(
        accountKey: normalizedAccount,
      );
    } catch (error) {
      remotes = const <RemotePlaylistSummary>[];
      bootstrapError = error;
    }
    _ensurePersistenceAllowed();

    var linkedLocalCount = 0;
    var importedRemoteCount = 0;
    if (bootstrapError == null) {
      final bindingByLocal = <String, PlaylistSyncBinding>{
        for (final binding in existingBindings) binding.key.playlistId: binding,
      };
      final bindingByRemote = <String, PlaylistSyncBinding>{
        for (final binding in existingBindings)
          if (binding.remotePlaylistId != null)
            binding.remotePlaylistId!: binding,
      };
      // A local playlist belongs to the account that imported or uploaded it.
      // Switching accounts must not silently copy it to the new account.
      final globallyBoundLocalIds = allExistingBindings
          .map((binding) => binding.key.playlistId)
          .toSet();
      final remoteById = <String, RemotePlaylistSummary>{
        for (final remote in remotes) remote.remotePlaylistId: remote,
      };
      final now = _clock();

      // Refresh capabilities only by an already persisted remote ID.
      for (final binding in existingBindings) {
        _ensurePersistenceAllowed();
        final remoteId = binding.remotePlaylistId;
        final summary = remoteId == null ? null : remoteById[remoteId];
        if (summary != null) {
          await _store.upsertBinding(
            binding.copyWith(
              remoteBrowseId: summary.remoteBrowseId,
              // Shelf summaries frequently omit edit endpoints, which is an
              // unknown capability rather than proof that access was lost.
              // Only a detailed playlist read may downgrade a known `true`.
              isEditable: binding.isEditable || summary.isEditable,
              privacy: summary.privacy,
              lastRemoteSeenAt: now,
              updatedAt: now,
            ),
            canCommit: _isPersistenceAllowed,
          );
        }
      }

      final locals = await _playlists.getCatalogPlaylists();
      _ensurePersistenceAllowed();
      for (final local in locals) {
        final isFavorites = local.id == Playlist.favoritesId;
        RemotePlaylistSummary? likedSummary;
        if (isFavorites) {
          for (final remote in remotes) {
            if (remote.isLikedMusic) {
              likedSummary = remote;
              break;
            }
          }
        }
        if ((!isFavorites && globallyBoundLocalIds.contains(local.id)) ||
            (isFavorites &&
                (bindingByLocal.containsKey(local.id) ||
                    likedSummary == null))) {
          continue;
        }
        final key = PlaylistSyncKey(
          accountKey: normalizedAccount,
          playlistId: local.id,
        );
        final binding = PlaylistSyncBinding(
          key: key,
          remotePlaylistId: likedSummary?.remotePlaylistId,
          remoteBrowseId: likedSummary?.remoteBrowseId,
          mode: newBindingMode,
          isEditable: likedSummary?.isEditable ?? true,
          privacy: likedSummary?.privacy ?? 'PRIVATE',
          localRevisionAtBase: 0,
          lastRemoteSeenAt: likedSummary == null ? null : now,
          createdAt: now,
          updatedAt: now,
        );
        _ensurePersistenceAllowed();
        await _store.upsertBinding(binding, canCommit: _isPersistenceAllowed);
        if (likedSummary == null) {
          await _store.enqueueIntent(
            key: key,
            requestedLocalRevision: local.localRevision,
            reason: 'bootstrap_create_private_remote',
            now: now,
            canCommit: _isPersistenceAllowed,
          );
        }
        bindingByLocal[local.id] = binding;
        if (binding.remotePlaylistId != null) {
          bindingByRemote[binding.remotePlaylistId!] = binding;
        }
        if (!isFavorites) {
          globallyBoundLocalIds.add(local.id);
        }
        linkedLocalCount += 1;
      }

      for (final remote in remotes) {
        _ensurePersistenceAllowed();
        if (bindingByRemote.containsKey(remote.remotePlaylistId)) {
          continue;
        }
        if (remote.isLikedMusic) {
          // LM/VLLM is YouTube Music's system "Liked Music" collection. It
          // maps to the reserved local Favorites playlist, never to a newly
          // generated local playlist.
          final existingFavorite = bindingByLocal[Playlist.favoritesId];
          if (existingFavorite == null) {
            // Favorites is a reserved playlist, but older/empty libraries may
            // not have a row for it yet.  The binding table has a foreign key
            // to playlists, so materialize the shell before inserting the
            // account binding.  Without this, a first sync on an empty
            // library fails with a SQLite foreign-key error and the user only
            // sees the generic "could not synchronize" message.
            final localFavorites = await _playlists.getCatalogPlaylist(
              Playlist.favoritesId,
            );
            if (localFavorites == null) {
              await _playlists.createCatalogPlaylist(
                id: Playlist.favoritesId,
                name: 'Favorites',
                now: now,
              );
            }
            final key = PlaylistSyncKey(
              accountKey: normalizedAccount,
              playlistId: Playlist.favoritesId,
            );
            final binding = PlaylistSyncBinding(
              key: key,
              remotePlaylistId: remote.remotePlaylistId,
              remoteBrowseId: remote.remoteBrowseId,
              mode: newBindingMode,
              isEditable: remote.isEditable,
              privacy: remote.privacy,
              localRevisionAtBase: 0,
              lastRemoteSeenAt: now,
              createdAt: now,
              updatedAt: now,
            );
            await _store.upsertBinding(
              binding,
              canCommit: _isPersistenceAllowed,
            );
            bindingByLocal[Playlist.favoritesId] = binding;
            bindingByRemote[remote.remotePlaylistId] = binding;
            linkedLocalCount += 1;
          } else {
            bindingByRemote[remote.remotePlaylistId] = existingFavorite;
          }
          continue;
        }
        final playlistId = _localPlaylistIdFactory();
        final key = PlaylistSyncKey(
          accountKey: normalizedAccount,
          playlistId: playlistId,
        );
        final binding = PlaylistSyncBinding(
          key: key,
          remotePlaylistId: remote.remotePlaylistId,
          remoteBrowseId: remote.remoteBrowseId,
          mode: newBindingMode,
          isEditable: remote.isEditable,
          privacy: remote.privacy,
          // No base on purpose: first sync performs a non-destructive union.
          localRevisionAtBase: 0,
          lastRemoteSeenAt: now,
          createdAt: now,
          updatedAt: now,
        );
        final imported = await _store.importRemotePlaylistAtomically(
          binding: binding,
          localPlaylistName: remote.title.trim().isEmpty
              ? 'YouTube Music'
              : remote.title,
          requestedLocalRevision: 1,
          reason: 'bootstrap_import_remote',
          now: now,
          canCommit: _isPersistenceAllowed,
        );
        bindingByRemote[remote.remotePlaylistId] = imported.binding;
        bindingByLocal[imported.binding.key.playlistId] = imported.binding;
        globallyBoundLocalIds.add(imported.binding.key.playlistId);
        if (imported.created) {
          importedRemoteCount += 1;
        }
      }
    }

    _ensurePersistenceAllowed();
    final bindings = await _store.listBindings(accountKey: normalizedAccount);
    _ensurePersistenceAllowed();
    final results = <PlaylistSyncKey, PlaylistSyncResult>{};
    for (final binding in bindings) {
      _ensurePersistenceAllowed();
      if (trigger != PlaylistSyncTrigger.manual &&
          binding.mode == PlaylistSyncMode.manual) {
        continue;
      }
      results[binding.key] = await _engine.sync(binding.key, trigger: trigger);
      _ensurePersistenceAllowed();
    }
    _ensurePersistenceAllowed();
    return PlaylistAccountSyncResult(
      results: Map<PlaylistSyncKey, PlaylistSyncResult>.unmodifiable(results),
      importedRemoteCount: importedRemoteCount,
      linkedLocalCount: linkedLocalCount,
      bootstrapError: bootstrapError,
    );
  }

  bool _isPersistenceAllowed() {
    final canPersist = _canPersist;
    if (canPersist == null) {
      return true;
    }
    try {
      return canPersist();
    } on Object {
      return false;
    }
  }

  void _ensurePersistenceAllowed() {
    if (!_isPersistenceAllowed()) {
      throw const PlaylistSyncFenceChanged();
    }
  }
}
