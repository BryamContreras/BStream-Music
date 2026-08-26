// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import '../../../features/music/domain/entities/catalog_track.dart';
import '../../../features/music/domain/entities/playlist.dart';
import '../../../features/music/domain/entities/playlist_entry.dart';
import '../../storage/local_database_service.dart';
import 'playlist_sync_models.dart';
import 'playlist_sync_store.dart';

typedef PlaylistConflictIdFactory = String Function();
typedef PlaylistImportFaultInjector = FutureOr<void> Function();

class SqlitePlaylistSyncStore implements PlaylistSyncStore {
  const SqlitePlaylistSyncStore(
    this._database, {
    required PlaylistConflictIdFactory conflictIdFactory,
    PlaylistImportFaultInjector? beforeImportBindingPersisted,
  }) : _conflictIdFactory = conflictIdFactory,
       _beforeImportBindingPersisted = beforeImportBindingPersisted;

  final LocalDatabaseService _database;
  final PlaylistConflictIdFactory _conflictIdFactory;
  final PlaylistImportFaultInjector? _beforeImportBindingPersisted;

  @override
  Future<PlaylistSyncWork?> loadWork(PlaylistSyncKey key) async {
    final bindings = await listBindings(accountKey: key.accountKey);
    PlaylistSyncBinding? binding;
    for (final candidate in bindings) {
      if (candidate.key == key) {
        binding = candidate;
        break;
      }
    }
    if (binding == null) {
      return null;
    }
    final local = await _database.getCatalogPlaylist(key.playlistId);
    if (local == null) {
      return null;
    }
    final db = await _database.database;
    final baseRows = await db.query(
      'ytm_playlist_base_items',
      where: 'account_key = ? AND playlist_id = ?',
      whereArgs: <Object?>[key.accountKey, key.playlistId],
      orderBy: 'ordinal ASC',
    );
    final localById = <String, PlaylistEntry>{
      for (final entry in local.entries) entry.id: entry,
    };
    final baseItems = <PlaylistSyncItem>[];
    for (final row in baseRows) {
      final localItemId = _text(row['local_item_id']);
      final videoId = _text(row['video_id']);
      final localEntry = localItemId == null ? null : localById[localItemId];
      final track =
          localEntry?.track ??
          (videoId == null
              ? CatalogTrack(
                  key: 'legacy:${row['ordinal']}',
                  provider: CatalogProvider.legacy,
                  providerId: '${row['ordinal']}',
                  title: '',
                )
              : await _database.resolveCatalogTrack(videoId: videoId) ??
                    CatalogTrack.youtube(videoId: videoId, title: ''));
      baseItems.add(
        PlaylistSyncItem(
          localItemId: localItemId,
          localTrackId: localEntry?.localTrackId,
          videoId: videoId,
          setVideoId: _text(row['set_video_id']),
          track: track,
        ),
      );
    }
    final intentRows = await db.query(
      'playlist_sync_intents',
      where: 'account_key = ? AND playlist_id = ?',
      whereArgs: <Object?>[key.accountKey, key.playlistId],
      limit: 1,
    );
    return PlaylistSyncWork(
      binding: binding,
      base: binding.baseTitle == null
          ? null
          : PlaylistSyncSnapshot(
              remotePlaylistId: binding.remotePlaylistId,
              title: binding.baseTitle!,
              items: baseItems,
              remoteRevision: binding.remoteRevision,
              isEditable: binding.isEditable,
              privacy: binding.privacy,
            ),
      local: PlaylistSyncSnapshot(
        remotePlaylistId: binding.remotePlaylistId,
        title: local.playlist.name,
        items: local.entries.map(_syncItemFromEntry),
        isEditable: binding.isEditable,
        privacy: binding.privacy,
      ),
      localRevision: local.playlist.localRevision,
      localDeleted: local.playlist.deletedAt != null,
      intent: intentRows.isEmpty ? null : _intentFromRow(intentRows.single),
    );
  }

  @override
  Future<List<PlaylistSyncBinding>> listBindings({String? accountKey}) async {
    final db = await _database.database;
    final rows = await db.query(
      'ytm_playlist_bindings',
      where: accountKey == null ? null : 'account_key = ?',
      whereArgs: accountKey == null ? null : <Object?>[accountKey],
      orderBy: 'updated_at DESC',
    );
    return rows.map(_bindingFromRow).toList(growable: false);
  }

  @override
  Future<List<PlaylistSyncUnresolvedConflict>> listUnresolvedConflicts({
    required String accountKey,
  }) async {
    final normalizedAccount = accountKey.trim();
    if (normalizedAccount.isEmpty) {
      throw ArgumentError.value(accountKey, 'accountKey', 'Must not be empty.');
    }
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
        SELECT
          conflict.account_key,
          conflict.playlist_id,
          conflict.kind,
          conflict.message,
          conflict.detected_at,
          playlist.name AS playlist_title,
          playlist.local_revision
        FROM playlist_sync_conflicts AS conflict
        INNER JOIN playlists AS playlist
          ON playlist.id = conflict.playlist_id
        WHERE conflict.account_key = ?
          AND conflict.resolved_at IS NULL
        ORDER BY conflict.detected_at DESC, conflict.conflict_id ASC
      ''',
      <Object?>[normalizedAccount],
    );
    return List<PlaylistSyncUnresolvedConflict>.unmodifiable(
      rows.map(_unresolvedConflictFromRow),
    );
  }

  @override
  Future<void> upsertBinding(
    PlaylistSyncBinding binding, {
    bool Function()? canCommit,
  }) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      await transaction.rawInsert('''
        INSERT INTO ytm_playlist_bindings (
          account_key, playlist_id, remote_playlist_id, remote_browse_id,
          sync_mode, is_editable, privacy, base_title, base_snapshot_hash,
          remote_revision, local_revision_at_base, last_synced_at,
          last_remote_seen_at, remote_delete_requested_at, created_at,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_key, playlist_id) DO UPDATE SET
          remote_playlist_id = excluded.remote_playlist_id,
          remote_browse_id = excluded.remote_browse_id,
          sync_mode = excluded.sync_mode,
          is_editable = excluded.is_editable,
          privacy = excluded.privacy,
          base_title = excluded.base_title,
          base_snapshot_hash = excluded.base_snapshot_hash,
          remote_revision = excluded.remote_revision,
          local_revision_at_base = excluded.local_revision_at_base,
          last_synced_at = excluded.last_synced_at,
          last_remote_seen_at = excluded.last_remote_seen_at,
          remote_delete_requested_at = excluded.remote_delete_requested_at,
          updated_at = excluded.updated_at
      ''', _bindingValues(binding));
      _ensureCommitAllowed(canCommit);
    });
  }

  @override
  Future<PlaylistSyncImportResult> importRemotePlaylistAtomically({
    required PlaylistSyncBinding binding,
    required String localPlaylistName,
    required int requestedLocalRevision,
    required String reason,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    final remotePlaylistId = _text(binding.remotePlaylistId);
    if (remotePlaylistId == null) {
      throw ArgumentError.value(
        binding.remotePlaylistId,
        'binding.remotePlaylistId',
        'A remote import requires an immutable remote playlist ID.',
      );
    }
    final normalizedName = localPlaylistName.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(
        localPlaylistName,
        'localPlaylistName',
        'Must not be empty.',
      );
    }
    final db = await _database.database;
    return db.transaction((transaction) async {
      final existingRows = await transaction.query(
        'ytm_playlist_bindings',
        where: 'account_key = ? AND remote_playlist_id = ?',
        whereArgs: <Object?>[binding.key.accountKey, remotePlaylistId],
        limit: 1,
      );
      if (existingRows.isNotEmpty) {
        _ensureCommitAllowed(canCommit);
        return PlaylistSyncImportResult(
          binding: _bindingFromRow(existingRows.single),
          created: false,
        );
      }

      await transaction.insert('playlists', <String, Object?>{
        'id': binding.key.playlistId,
        'name': normalizedName,
        'track_ids': '[]',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
        'local_revision': requestedLocalRevision,
        'deleted_at': null,
        'entries_migrated': 1,
      });
      await _beforeImportBindingPersisted?.call();
      await transaction.insert('ytm_playlist_bindings', <String, Object?>{
        'account_key': binding.key.accountKey,
        'playlist_id': binding.key.playlistId,
        'remote_playlist_id': remotePlaylistId,
        'remote_browse_id': binding.remoteBrowseId,
        'sync_mode': binding.mode.name,
        'is_editable': binding.isEditable ? 1 : 0,
        'privacy': binding.privacy,
        'base_title': binding.baseTitle,
        'base_snapshot_hash': binding.baseSnapshotHash,
        'remote_revision': binding.remoteRevision,
        'local_revision_at_base': binding.localRevisionAtBase,
        'last_synced_at': binding.lastSyncedAt?.toIso8601String(),
        'last_remote_seen_at': binding.lastRemoteSeenAt?.toIso8601String(),
        'remote_delete_requested_at': binding.remoteDeleteRequestedAt
            ?.toIso8601String(),
        'created_at': binding.createdAt.toIso8601String(),
        'updated_at': binding.updatedAt.toIso8601String(),
      });
      await _upsertIntent(
        transaction,
        key: binding.key,
        requestedLocalRevision: requestedLocalRevision,
        reason: reason,
        status: PlaylistSyncIntentStatus.pending,
        now: now,
      );
      _ensureCommitAllowed(canCommit);
      return PlaylistSyncImportResult(binding: binding, created: true);
    });
  }

  @override
  Future<void> enqueueIntent({
    required PlaylistSyncKey key,
    required int requestedLocalRevision,
    required String reason,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      await _upsertIntent(
        transaction,
        key: key,
        requestedLocalRevision: requestedLocalRevision,
        reason: reason,
        status: PlaylistSyncIntentStatus.pending,
        now: now,
      );
      _ensureCommitAllowed(canCommit);
    });
  }

  @override
  Future<void> commitSynchronized({
    required PlaylistSyncKey key,
    required PlaylistSyncSnapshot mergedLocal,
    required PlaylistSyncSnapshot verifiedRemote,
    required int expectedLocalRevision,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final playlistRows = await transaction.query(
        'playlists',
        where: 'id = ?',
        whereArgs: <Object?>[key.playlistId],
        limit: 1,
      );
      if (playlistRows.isEmpty ||
          _integer(playlistRows.single['local_revision']) !=
              expectedLocalRevision) {
        throw const PlaylistSyncRevisionChanged();
      }
      final existingRows = await transaction.query(
        'playlist_items',
        where: 'playlist_id = ? AND deleted_at IS NULL',
        whereArgs: <Object?>[key.playlistId],
        orderBy: 'position ASC, item_id ASC',
      );
      final isFavorites = key.playlistId == Playlist.favoritesId;
      final localVideoIdByTrackId = <String, String>{};
      final localTrackIdByVideoId = <String, String>{};
      if (isFavorites) {
        final referencedLocalTrackIds = mergedLocal.items
            .map((item) => _text(item.localTrackId))
            .whereType<String>()
            .toSet()
            .toList(growable: false);
        final localTrackRows = referencedLocalTrackIds.isEmpty
            ? const <Map<String, Object?>>[]
            : await transaction.query(
                'local_tracks',
                columns: const <String>['id', 'source_id'],
                where:
                    'id IN (${List.filled(referencedLocalTrackIds.length, '?').join(', ')})',
                whereArgs: referencedLocalTrackIds,
              );
        for (final row in localTrackRows) {
          final localTrackId = _text(row['id']);
          final videoId = _text(row['source_id']);
          if (localTrackId == null || videoId == null) {
            continue;
          }
          localVideoIdByTrackId[localTrackId] = videoId;
        }
        for (final localTrackId in referencedLocalTrackIds) {
          final videoId = localVideoIdByTrackId[localTrackId];
          if (videoId != null) {
            localTrackIdByVideoId.putIfAbsent(videoId, () => localTrackId);
          }
        }
      }
      final effectiveLocalTrackIds = <String?>[];
      final desiredIds = <String>{};
      var contentChanged =
          playlistRows.single['name']?.toString() != mergedLocal.title ||
          existingRows.length != mergedLocal.items.length;
      for (var position = 0; position < mergedLocal.items.length; position++) {
        final item = mergedLocal.items[position];
        final proposedLocalTrackId = _text(item.localTrackId);
        final videoId = _text(item.videoId);
        final effectiveLocalTrackId = !isFavorites || videoId == null
            ? proposedLocalTrackId
            : localVideoIdByTrackId[proposedLocalTrackId] == videoId
            ? proposedLocalTrackId
            : localTrackIdByVideoId[videoId];
        effectiveLocalTrackIds.add(effectiveLocalTrackId);
        final itemId = item.localItemId;
        if (itemId == null || itemId.isEmpty) {
          throw StateError('A merged playlist item has no local UUID.');
        }
        desiredIds.add(itemId);
        await _upsertTrack(transaction, item.track, now);
        if (effectiveLocalTrackId != null &&
            (!isFavorites ||
                (videoId != null &&
                    localVideoIdByTrackId[effectiveLocalTrackId] == videoId))) {
          await transaction.update(
            'local_tracks',
            <String, Object?>{'catalog_key': item.track.key},
            where: 'id = ?',
            whereArgs: <Object?>[effectiveLocalTrackId],
          );
        }
        final existing = position < existingRows.length
            ? existingRows[position]
            : null;
        contentChanged =
            contentChanged ||
            existing == null ||
            existing['item_id']?.toString() != itemId ||
            existing['catalog_key']?.toString() != item.track.key ||
            _text(existing['local_track_id']) != effectiveLocalTrackId ||
            _text(existing['remote_video_id']) != videoId;
        await transaction.rawInsert(
          '''
            INSERT INTO playlist_items (
              item_id, playlist_id, catalog_key, local_track_id,
              remote_video_id, remote_set_video_id, position, origin,
              created_at, updated_at, deleted_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'merged', ?, ?, NULL)
            ON CONFLICT(item_id) DO UPDATE SET
              playlist_id = excluded.playlist_id,
              catalog_key = excluded.catalog_key,
              local_track_id = excluded.local_track_id,
              remote_video_id = excluded.remote_video_id,
              remote_set_video_id = excluded.remote_set_video_id,
              position = excluded.position,
              origin = 'merged',
              updated_at = excluded.updated_at,
              deleted_at = NULL
          ''',
          <Object?>[
            itemId,
            key.playlistId,
            item.track.key,
            effectiveLocalTrackId,
            videoId,
            item.setVideoId,
            position,
            now.toIso8601String(),
            now.toIso8601String(),
          ],
        );
      }
      for (final row in existingRows) {
        final itemId = row['item_id']!.toString();
        if (!desiredIds.contains(itemId)) {
          await transaction.update(
            'playlist_items',
            <String, Object?>{
              'deleted_at': now.toIso8601String(),
              'updated_at': now.toIso8601String(),
            },
            where: 'item_id = ?',
            whereArgs: <Object?>[itemId],
          );
        }
      }
      final nextRevision = contentChanged
          ? expectedLocalRevision + 1
          : expectedLocalRevision;
      await transaction.update(
        'playlists',
        <String, Object?>{
          'name': mergedLocal.title,
          'track_ids': jsonEncode(
            effectiveLocalTrackIds.whereType<String>().toList(),
          ),
          if (contentChanged) 'updated_at': now.toIso8601String(),
          'local_revision': nextRevision,
          'deleted_at': null,
          'entries_migrated': 1,
        },
        where: 'id = ? AND local_revision = ?',
        whereArgs: <Object?>[key.playlistId, expectedLocalRevision],
      );
      await transaction.delete(
        'ytm_playlist_base_items',
        where: 'account_key = ? AND playlist_id = ?',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
      );
      final remoteItems = mergedLocal.items
          // YouTube can preserve an unavailable/region-blocked occurrence
          // with only setVideoId. It still belongs to the remote base: dropping
          // it would make the next three-way merge treat that row as a new
          // remote insertion and could duplicate it.
          .where((item) => item.videoId != null || item.setVideoId != null)
          .toList(growable: false);
      for (var ordinal = 0; ordinal < remoteItems.length; ordinal++) {
        final item = remoteItems[ordinal];
        await transaction.insert('ytm_playlist_base_items', <String, Object?>{
          'account_key': key.accountKey,
          'playlist_id': key.playlistId,
          'ordinal': ordinal,
          'local_item_id': item.localItemId,
          'video_id': item.videoId,
          'set_video_id': item.setVideoId,
        });
      }
      await transaction.update(
        'ytm_playlist_bindings',
        <String, Object?>{
          'remote_playlist_id': verifiedRemote.remotePlaylistId,
          'is_editable': verifiedRemote.isEditable ? 1 : 0,
          'privacy': verifiedRemote.privacy,
          'base_title': mergedLocal.title,
          'base_snapshot_hash': verifiedRemote.semanticHash,
          'remote_revision': verifiedRemote.revisionToken,
          'local_revision_at_base': nextRevision,
          'last_synced_at': now.toIso8601String(),
          'last_remote_seen_at': now.toIso8601String(),
          'remote_delete_requested_at': null,
          'updated_at': now.toIso8601String(),
        },
        where: 'account_key = ? AND playlist_id = ?',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
      );
      await transaction.delete(
        'playlist_sync_intents',
        where: 'account_key = ? AND playlist_id = ?',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
      );
      await transaction.update(
        'playlist_sync_conflicts',
        <String, Object?>{
          'resolved_at': now.toIso8601String(),
          'resolution': 'synchronized',
        },
        where: 'account_key = ? AND playlist_id = ? AND resolved_at IS NULL',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
      );
      _ensureCommitAllowed(canCommit);
    });
  }

  @override
  Future<void> commitVerifiedBaseWithNewerLocal({
    required PlaylistSyncKey key,
    required PlaylistSyncSnapshot verifiedBase,
    required PlaylistSyncSnapshot verifiedRemote,
    required int verifiedLocalRevision,
    required int expectedLocalRevision,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final playlistRows = await transaction.query(
        'playlists',
        columns: const <String>['local_revision'],
        where: 'id = ?',
        whereArgs: <Object?>[key.playlistId],
        limit: 1,
      );
      if (playlistRows.isEmpty ||
          _integer(playlistRows.single['local_revision']) !=
              expectedLocalRevision) {
        throw const PlaylistSyncRevisionChanged();
      }

      await transaction.delete(
        'ytm_playlist_base_items',
        where: 'account_key = ? AND playlist_id = ?',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
      );
      final remoteItems = verifiedBase.items
          .where((item) => item.videoId != null || item.setVideoId != null)
          .toList(growable: false);
      for (var ordinal = 0; ordinal < remoteItems.length; ordinal++) {
        final item = remoteItems[ordinal];
        await transaction.insert('ytm_playlist_base_items', <String, Object?>{
          'account_key': key.accountKey,
          'playlist_id': key.playlistId,
          'ordinal': ordinal,
          'local_item_id': item.localItemId,
          'video_id': item.videoId,
          'set_video_id': item.setVideoId,
        });
      }
      await transaction.update(
        'ytm_playlist_bindings',
        <String, Object?>{
          'remote_playlist_id': verifiedRemote.remotePlaylistId,
          'is_editable': verifiedRemote.isEditable ? 1 : 0,
          'privacy': verifiedRemote.privacy,
          'base_title': verifiedBase.title,
          'base_snapshot_hash': verifiedRemote.semanticHash,
          'remote_revision': verifiedRemote.revisionToken,
          'local_revision_at_base': verifiedLocalRevision,
          'last_synced_at': now.toIso8601String(),
          'last_remote_seen_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
        where: 'account_key = ? AND playlist_id = ?',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
      );
      await _upsertIntent(
        transaction,
        key: key,
        requestedLocalRevision: expectedLocalRevision,
        reason: 'newer_local_after_verified_ambiguous',
        status: PlaylistSyncIntentStatus.pending,
        now: now,
      );
      _ensureCommitAllowed(canCommit);
    });
  }

  @override
  Future<void> recordDeferred({
    required PlaylistSyncKey key,
    required int requestedLocalRevision,
    required String reason,
    required DateTime now,
    required DateTime nextAttemptAt,
    PlaylistSyncSnapshot? desired,
    String? mutationToken,
    String? error,
    bool ambiguous = false,
  }) async {
    final db = await _database.database;
    await _upsertIntent(
      db,
      key: key,
      requestedLocalRevision: requestedLocalRevision,
      reason: reason,
      status: ambiguous
          ? PlaylistSyncIntentStatus.ambiguous
          : PlaylistSyncIntentStatus.pending,
      now: now,
      desired: desired,
      mutationToken: mutationToken,
      nextAttemptAt: nextAttemptAt,
      error: error,
      incrementAttempts: true,
    );
  }

  @override
  Future<void> recordConflict({
    required PlaylistSyncKey key,
    required PlaylistSyncConflict conflict,
    required PlaylistSyncSnapshot? base,
    required PlaylistSyncSnapshot local,
    required PlaylistSyncSnapshot? remote,
    required DateTime now,
  }) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final existingIntentRows = await transaction.query(
        'playlist_sync_intents',
        where: 'account_key = ? AND playlist_id = ?',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
        limit: 1,
      );
      final existingIntent = existingIntentRows.isEmpty
          ? null
          : _intentFromRow(existingIntentRows.single);
      await transaction.insert('playlist_sync_conflicts', <String, Object?>{
        'conflict_id': _conflictIdFactory(),
        'account_key': key.accountKey,
        'playlist_id': key.playlistId,
        'kind': conflict.kind.name,
        'message': _text(conflict.message),
        'base_snapshot_json': base?.encode(),
        'local_snapshot_json': local.encode(),
        'remote_snapshot_json': remote?.encode(),
        'detected_at': now.toIso8601String(),
      });
      await _upsertIntent(
        transaction,
        key: key,
        requestedLocalRevision: 0,
        reason: 'conflict_${conflict.kind.name}',
        status: PlaylistSyncIntentStatus.conflict,
        now: now,
        desired: existingIntent?.desiredSnapshot,
        mutationToken: existingIntent?.mutationToken,
        nextAttemptAt: existingIntent?.nextAttemptAt,
        error: existingIntent?.lastError,
      );
    });
  }

  @override
  Future<void> resolveConflict({
    required PlaylistSyncKey key,
    required PlaylistSyncConflictResolution resolution,
    required int expectedLocalRevision,
    required DateTime now,
  }) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final playlistRows = await transaction.query(
        'playlists',
        columns: const <String>['local_revision'],
        where: 'id = ?',
        whereArgs: <Object?>[key.playlistId],
        limit: 1,
      );
      if (playlistRows.isEmpty ||
          _integer(playlistRows.single['local_revision']) !=
              expectedLocalRevision) {
        throw const PlaylistSyncRevisionChanged();
      }
      final unresolved = await transaction.query(
        'playlist_sync_conflicts',
        columns: const <String>['conflict_id'],
        where: 'account_key = ? AND playlist_id = ? AND resolved_at IS NULL',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
        limit: 1,
      );
      if (unresolved.isEmpty) {
        throw StateError('No unresolved playlist sync conflict exists.');
      }
      await transaction.update(
        'playlist_sync_conflicts',
        <String, Object?>{
          'resolved_at': now.toIso8601String(),
          'resolution': resolution.name,
        },
        where: 'account_key = ? AND playlist_id = ? AND resolved_at IS NULL',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
      );
      await _upsertIntent(
        transaction,
        key: key,
        requestedLocalRevision: expectedLocalRevision,
        reason: playlistSyncConflictResolutionReason(resolution),
        status: PlaylistSyncIntentStatus.pending,
        now: now,
      );
    });
  }

  @override
  Future<void> commitRemoteDeleted({
    required PlaylistSyncKey key,
    required int expectedLocalRevision,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    final db = await _database.database;
    await db.transaction((transaction) async {
      final rows = await transaction.query(
        'playlists',
        columns: const <String>['local_revision'],
        where: 'id = ?',
        whereArgs: <Object?>[key.playlistId],
        limit: 1,
      );
      if (rows.isEmpty ||
          _integer(rows.single['local_revision']) != expectedLocalRevision) {
        throw const PlaylistSyncRevisionChanged();
      }
      await transaction.delete(
        'ytm_playlist_bindings',
        where: 'account_key = ? AND playlist_id = ?',
        whereArgs: <Object?>[key.accountKey, key.playlistId],
      );
      _ensureCommitAllowed(canCommit);
    });
  }

  Future<void> _upsertIntent(
    dynamic db, {
    required PlaylistSyncKey key,
    required int requestedLocalRevision,
    required String reason,
    required PlaylistSyncIntentStatus status,
    required DateTime now,
    PlaylistSyncSnapshot? desired,
    String? mutationToken,
    DateTime? nextAttemptAt,
    String? error,
    bool incrementAttempts = false,
  }) {
    return db.rawInsert(
      '''
        INSERT INTO playlist_sync_intents (
          account_key, playlist_id, requested_local_revision, reason, status,
          desired_snapshot_json, desired_snapshot_hash, mutation_token,
          attempt_count, next_attempt_at, last_error, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_key, playlist_id) DO UPDATE SET
          requested_local_revision = MAX(
            playlist_sync_intents.requested_local_revision,
            excluded.requested_local_revision
          ),
          reason = excluded.reason,
          status = excluded.status,
          desired_snapshot_json = excluded.desired_snapshot_json,
          desired_snapshot_hash = excluded.desired_snapshot_hash,
          mutation_token = excluded.mutation_token,
          attempt_count = CASE WHEN ? = 1
            THEN playlist_sync_intents.attempt_count + 1
            ELSE playlist_sync_intents.attempt_count
          END,
          next_attempt_at = excluded.next_attempt_at,
          last_error = excluded.last_error,
          updated_at = excluded.updated_at
      ''',
      <Object?>[
        key.accountKey,
        key.playlistId,
        requestedLocalRevision,
        reason,
        status.name,
        desired?.encode(),
        desired?.semanticHash,
        mutationToken,
        incrementAttempts ? 1 : 0,
        nextAttemptAt?.toIso8601String(),
        error,
        now.toIso8601String(),
        now.toIso8601String(),
        incrementAttempts ? 1 : 0,
      ],
    );
  }

  Future<void> _upsertTrack(dynamic db, CatalogTrack track, DateTime now) {
    return db.rawInsert(
      '''
        INSERT INTO catalog_tracks (
          track_key, provider, provider_id, title, artists_json,
          artist_browse_ids_json, album, duration_ms, thumbnail_url,
          source_url, metadata_source, metadata_updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(track_key) DO UPDATE SET
          title = excluded.title,
          artists_json = excluded.artists_json,
          artist_browse_ids_json = excluded.artist_browse_ids_json,
          album = COALESCE(excluded.album, catalog_tracks.album),
          duration_ms = COALESCE(excluded.duration_ms, catalog_tracks.duration_ms),
          thumbnail_url = COALESCE(
            excluded.thumbnail_url,
            catalog_tracks.thumbnail_url
          ),
          source_url = COALESCE(excluded.source_url, catalog_tracks.source_url),
          metadata_source = excluded.metadata_source,
          metadata_updated_at = excluded.metadata_updated_at
      ''',
      <Object?>[
        track.key,
        track.provider.name,
        track.providerId,
        track.title,
        jsonEncode(track.artists),
        jsonEncode(track.artistBrowseIds),
        track.album,
        track.duration?.inMilliseconds,
        track.thumbnailUrl,
        track.sourceUrl,
        'youtube_music_sync',
        now.toIso8601String(),
      ],
    );
  }
}

PlaylistSyncItem _syncItemFromEntry(PlaylistEntry entry) => PlaylistSyncItem(
  localItemId: entry.id,
  localTrackId: entry.localTrackId,
  videoId: entry.videoId,
  setVideoId: entry.setVideoId,
  track: entry.track,
);

PlaylistSyncBinding _bindingFromRow(Map<String, Object?> row) {
  return PlaylistSyncBinding(
    key: PlaylistSyncKey(
      accountKey: row['account_key']!.toString(),
      playlistId: row['playlist_id']!.toString(),
    ),
    remotePlaylistId: _text(row['remote_playlist_id']),
    remoteBrowseId: _text(row['remote_browse_id']),
    mode: PlaylistSyncMode.values.firstWhere(
      (mode) => mode.name == row['sync_mode']?.toString(),
      orElse: () => PlaylistSyncMode.manual,
    ),
    isEditable: _integer(row['is_editable']) != 0,
    privacy: _text(row['privacy']),
    baseTitle: _text(row['base_title']),
    baseSnapshotHash: _text(row['base_snapshot_hash']),
    remoteRevision: _text(row['remote_revision']),
    localRevisionAtBase: _integer(row['local_revision_at_base']),
    lastSyncedAt: _date(row['last_synced_at']),
    lastRemoteSeenAt: _date(row['last_remote_seen_at']),
    remoteDeleteRequestedAt: _date(row['remote_delete_requested_at']),
    createdAt: DateTime.parse(row['created_at']!.toString()),
    updatedAt: DateTime.parse(row['updated_at']!.toString()),
  );
}

PlaylistSyncIntent _intentFromRow(Map<String, Object?> row) {
  final encodedDesired = _text(row['desired_snapshot_json']);
  return PlaylistSyncIntent(
    key: PlaylistSyncKey(
      accountKey: row['account_key']!.toString(),
      playlistId: row['playlist_id']!.toString(),
    ),
    requestedLocalRevision: _integer(row['requested_local_revision']),
    reason: row['reason']!.toString(),
    status: PlaylistSyncIntentStatus.values.firstWhere(
      (status) => status.name == row['status']?.toString(),
      orElse: () => PlaylistSyncIntentStatus.pending,
    ),
    desiredSnapshot: encodedDesired == null
        ? null
        : PlaylistSyncSnapshot.decode(encodedDesired),
    desiredSnapshotHash: _text(row['desired_snapshot_hash']),
    mutationToken: _text(row['mutation_token']),
    attemptCount: _integer(row['attempt_count']),
    nextAttemptAt: _date(row['next_attempt_at']),
    lastError: _text(row['last_error']),
    createdAt: DateTime.parse(row['created_at']!.toString()),
    updatedAt: DateTime.parse(row['updated_at']!.toString()),
  );
}

PlaylistSyncUnresolvedConflict _unresolvedConflictFromRow(
  Map<String, Object?> row,
) {
  return PlaylistSyncUnresolvedConflict(
    key: PlaylistSyncKey(
      accountKey: row['account_key']!.toString(),
      playlistId: row['playlist_id']!.toString(),
    ),
    playlistTitle: row['playlist_title']!.toString(),
    localRevision: _integer(row['local_revision']),
    kind: PlaylistSyncConflictKind.values.firstWhere(
      (kind) => kind.name == row['kind']?.toString(),
      orElse: () => PlaylistSyncConflictKind.ambiguousMutation,
    ),
    message: _text(row['message']),
    detectedAt: DateTime.parse(row['detected_at']!.toString()),
  );
}

List<Object?> _bindingValues(PlaylistSyncBinding binding) => <Object?>[
  binding.key.accountKey,
  binding.key.playlistId,
  binding.remotePlaylistId,
  binding.remoteBrowseId,
  binding.mode.name,
  binding.isEditable ? 1 : 0,
  binding.privacy,
  binding.baseTitle,
  binding.baseSnapshotHash,
  binding.remoteRevision,
  binding.localRevisionAtBase,
  binding.lastSyncedAt?.toIso8601String(),
  binding.lastRemoteSeenAt?.toIso8601String(),
  binding.remoteDeleteRequestedAt?.toIso8601String(),
  binding.createdAt.toIso8601String(),
  binding.updatedAt.toIso8601String(),
];

String? _text(Object? value) {
  final normalized = value?.toString().trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

int _integer(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString());

void _ensureCommitAllowed(bool Function()? canCommit) {
  if (canCommit == null) {
    return;
  }
  var allowed = false;
  try {
    allowed = canCommit();
  } catch (_) {
    allowed = false;
  }
  if (!allowed) {
    throw const PlaylistSyncFenceChanged();
  }
}
