import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_models.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_store.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/sqlite_playlist_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('fresh v8 contains catalog and sync schema', () async {
    final sandbox = await Directory.systemTemp.createTemp('bstream-v8-fresh-');
    final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
    addTearDown(() async {
      await service.close();
      await sandbox.delete(recursive: true);
    });

    final db = await service.database;
    expect(await db.getVersion(), AppConstants.databaseVersion);
    expect(AppConstants.databaseVersion, 8);
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name']).toSet();
    expect(
      tables,
      containsAll(const <String>{
        'catalog_tracks',
        'playlist_items',
        'ytm_playlist_bindings',
        'ytm_playlist_base_items',
        'playlist_sync_intents',
        'playlist_sync_conflicts',
      }),
    );
    final itemColumns = (await db.rawQuery(
      'PRAGMA table_info(playlist_items)',
    )).map((row) => row['name']).toSet();
    expect(
      itemColumns,
      containsAll(const <String>{
        'item_id',
        'remote_video_id',
        'remote_set_video_id',
        'position',
      }),
    );
    final conflictColumns = (await db.rawQuery(
      'PRAGMA table_info(playlist_sync_conflicts)',
    )).map((row) => row['name']).toSet();
    expect(conflictColumns, contains('message'));
  });

  test(
    'playlist updates preserve creation time and revision semantics',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-playlist-portable-upsert-',
      );
      final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await service.close();
        await sandbox.delete(recursive: true);
      });
      final createdAt = DateTime.utc(2026, 8, 27, 10);
      await service.savePlaylist(
        Playlist(
          id: 'playlist-upsert',
          name: 'First',
          trackIds: const <String>['one'],
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      );
      await service.savePlaylist(
        Playlist(
          id: 'playlist-upsert',
          name: 'Second',
          trackIds: const <String>['two'],
          createdAt: createdAt.add(const Duration(days: 1)),
          updatedAt: createdAt.add(const Duration(minutes: 1)),
        ),
      );
      var stored = (await service.getPlaylists()).single;
      expect(stored.createdAt, createdAt);
      expect(stored.name, 'Second');
      expect(stored.trackIds, const <String>['two']);
      expect(stored.localRevision, 1);

      await service.savePlaylist(
        Playlist(
          id: 'playlist-upsert',
          name: 'Imported revision',
          trackIds: const <String>['three'],
          createdAt: createdAt.add(const Duration(days: 2)),
          updatedAt: createdAt.add(const Duration(minutes: 2)),
          localRevision: 7,
        ),
      );
      stored = (await service.getPlaylists()).single;
      expect(stored.createdAt, createdAt);
      expect(stored.localRevision, 7);
      expect(stored.name, 'Imported revision');
    },
  );

  test(
    'v7 migration preserves order, duplicates and missing memberships',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('bstream-v7-sync-');
      final path = p.join(sandbox.path, 'library.db');
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 7,
          onCreate: (db, _) async => _createV7Schema(db),
        ),
      );
      final now = DateTime.utc(2026, 8, 22).toIso8601String();
      await legacy.insert('local_tracks', <String, Object?>{
        'id': 'download-a',
        'title': 'Song A',
        'artist': 'Artist',
        'file_path': p.join(sandbox.path, 'a.m4a'),
        'source_url': 'https://youtu.be/AbCdEfGhIj1',
        'artists_json': '["Artist"]',
        'artist_browse_ids_json': '[]',
        'metadata_source': 'youtube_music',
        'source_id': 'AbCdEfGhIj1',
        'added_at': now,
      });
      await legacy.insert('playlists', <String, Object?>{
        'id': 'playlist-a',
        'name': 'Duplicates',
        'track_ids': jsonEncode(<String>[
          'download-a',
          'download-a',
          'missing-row',
        ]),
        'created_at': now,
        'updated_at': now,
      });
      await legacy.close();

      final service = _TestDatabase(path);
      addTearDown(() async {
        await service.close();
        await sandbox.delete(recursive: true);
      });
      final catalog = await service.getCatalogPlaylist('playlist-a');
      expect(catalog, isNotNull);
      expect(catalog!.entries, hasLength(3));
      expect(catalog.entries.map((entry) => entry.position), <int>[0, 1, 2]);
      expect(catalog.entries.map((entry) => entry.localTrackId), <String?>[
        'download-a',
        'download-a',
        null,
      ]);
      expect(
        catalog.entries.take(2).map((entry) => entry.videoId),
        everyElement('AbCdEfGhIj1'),
      );
      expect(catalog.entries.last.track.provider, CatalogProvider.legacy);
      expect(catalog.entries.map((entry) => entry.id).toSet(), hasLength(3));
      expect((await service.database).getVersion(), completion(8));
    },
  );

  test(
    'linkCatalogDownload makes all matching occurrences local-first',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-link-sync-',
      );
      final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await service.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22);
      await service.createCatalogPlaylist(id: 'p1', name: 'Remote', now: now);
      final remoteTrack = CatalogTrack.youtube(
        videoId: 'AbCdEfGhIj1',
        title: 'Song A',
        artists: const <String>['Artist'],
      );
      await service.appendCatalogEntry(
        playlistId: 'p1',
        entryId: 'entry-1',
        track: remoteTrack,
        now: now,
      );
      await service.appendCatalogEntry(
        playlistId: 'p1',
        entryId: 'entry-2',
        track: remoteTrack,
        now: now,
      );
      final before = (await service.getCatalogPlaylist('p1'))!.playlist;
      await service.saveLocalTrack(
        LocalTrack(
          id: 'download-a',
          title: 'Song A',
          artist: 'Artist',
          artists: const <String>['Artist'],
          filePath: p.join(sandbox.path, 'a.m4a'),
          sourceId: 'AbCdEfGhIj1',
          addedAt: now,
        ),
      );

      expect(
        await service.linkCatalogDownload(
          videoId: 'AbCdEfGhIj1',
          localTrackId: 'download-a',
          now: now.add(const Duration(seconds: 1)),
        ),
        2,
      );
      final after = (await service.getCatalogPlaylist('p1'))!;
      expect(
        after.entries.map((entry) => entry.localTrackId),
        everyElement('download-a'),
      );
      expect(after.entries.map((entry) => entry.id), <String>[
        'entry-1',
        'entry-2',
      ]);
      expect(after.playlist.localRevision, before.localRevision + 1);
      expect(
        await service.linkCatalogDownload(
          videoId: 'AbCdEfGhIj1',
          localTrackId: 'download-a',
        ),
        0,
      );
    },
  );

  test(
    'Favorites commit remaps a mismatched download to its source video',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-favorites-download-identity-',
      );
      final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await service.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 26, 15);
      const videoA = 'AbCdEfGhIj1';
      const videoB = 'BcDeFgHiJk2';
      final audioPath = p.join(sandbox.path, 'a.m4a');
      final trackA = CatalogTrack.youtube(videoId: videoA, title: 'Song A');
      final trackB = CatalogTrack.youtube(videoId: videoB, title: 'Song B');
      await service.createCatalogPlaylist(
        id: Playlist.favoritesId,
        name: 'Favoritos',
        now: now,
      );
      await service.appendCatalogEntry(
        playlistId: Playlist.favoritesId,
        entryId: 'favorite-a',
        track: trackA,
        now: now,
      );
      await service.saveLocalTrack(
        LocalTrack(
          id: 'download-a',
          title: 'Song A',
          artist: 'Artist A',
          filePath: audioPath,
          sourceId: videoA,
          addedAt: now,
        ),
      );
      await service.linkCatalogDownload(
        videoId: videoA,
        localTrackId: 'download-a',
        now: now.add(const Duration(seconds: 1)),
      );

      final store = SqlitePlaylistSyncStore(
        service,
        conflictIdFactory: () => 'unused-conflict',
      );
      const key = PlaylistSyncKey(
        accountKey: 'account',
        playlistId: Playlist.favoritesId,
      );
      final before = (await service.getCatalogPlaylist(
        Playlist.favoritesId,
      ))!.playlist;
      await store.upsertBinding(
        PlaylistSyncBinding(
          key: key,
          remotePlaylistId: 'LM',
          mode: PlaylistSyncMode.automatic,
          localRevisionAtBase: before.localRevision,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final merged = PlaylistSyncSnapshot(
        remotePlaylistId: 'LM',
        title: 'Favoritos',
        items: <PlaylistSyncItem>[
          PlaylistSyncItem(
            localItemId: 'favorite-a',
            localTrackId: 'download-a',
            videoId: videoB,
            setVideoId: 'set-b',
            track: trackB,
          ),
          PlaylistSyncItem(
            localItemId: 'favorite-a-imported',
            videoId: videoA,
            setVideoId: 'set-a',
            track: trackA,
          ),
        ],
      );

      await store.commitSynchronized(
        key: key,
        mergedLocal: merged,
        verifiedRemote: merged,
        expectedLocalRevision: before.localRevision,
        now: now.add(const Duration(seconds: 2)),
      );

      final favorites = (await service.getCatalogPlaylist(
        Playlist.favoritesId,
      ))!;
      expect(favorites.entries.map((entry) => entry.videoId), <String?>[
        videoB,
        videoA,
      ]);
      expect(favorites.entries.map((entry) => entry.localTrackId), <String?>[
        null,
        'download-a',
      ]);
      final db = await service.database;
      final localRow = (await db.query(
        'local_tracks',
        where: 'id = ?',
        whereArgs: const <Object?>['download-a'],
        limit: 1,
      )).single;
      expect(localRow['source_id'], videoA);
      expect(localRow['catalog_key'], trackA.key);
      expect(localRow['file_path'], audioPath);
      final playlistRow = (await db.query(
        'playlists',
        columns: const <String>['track_ids'],
        where: 'id = ?',
        whereArgs: const <Object?>[Playlist.favoritesId],
        limit: 1,
      )).single;
      expect(jsonDecode(playlistRow['track_ids']! as String), <String>[
        'download-a',
      ]);
    },
  );

  test(
    'local-only playlist deletion keeps its binding and requires opt-in remote delete',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-local-only-delete-',
      );
      final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await service.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      await service.createCatalogPlaylist(id: 'p1', name: 'Road', now: now);
      var conflictId = 0;
      final store = SqlitePlaylistSyncStore(
        service,
        conflictIdFactory: () => 'conflict-${conflictId++}',
      );
      const key = PlaylistSyncKey(accountKey: 'account', playlistId: 'p1');
      const otherKey = PlaylistSyncKey(
        accountKey: 'other-account',
        playlistId: 'p1',
      );
      await store.upsertBinding(
        PlaylistSyncBinding(
          key: key,
          remotePlaylistId: 'remote-1',
          mode: PlaylistSyncMode.automatic,
          localRevisionAtBase: 1,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await store.upsertBinding(
        PlaylistSyncBinding(
          key: otherKey,
          remotePlaylistId: 'remote-other',
          mode: PlaylistSyncMode.automatic,
          localRevisionAtBase: 1,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await store.enqueueIntent(
        key: key,
        requestedLocalRevision: 1,
        reason: 'pending_before_delete',
        now: now,
      );

      await service.tombstoneCatalogPlaylist(
        playlistId: 'p1',
        now: now.add(const Duration(seconds: 1)),
        deleteRemote: false,
      );

      final localOnly = (await store.loadWork(key))!;
      expect(localOnly.localDeleted, isTrue);
      expect(localOnly.binding.remotePlaylistId, 'remote-1');
      expect(localOnly.binding.remoteDeleteRequestedAt, isNull);
      expect(localOnly.intent, isNull);

      await service.tombstoneCatalogPlaylist(
        playlistId: 'p1',
        now: now.add(const Duration(seconds: 2)),
        deleteRemote: true,
        remoteAccountKey: 'account',
      );
      final remoteRequested = (await store.loadWork(key))!;
      expect(remoteRequested.binding.remoteDeleteRequestedAt, isNotNull);
      expect(remoteRequested.intent?.status, PlaylistSyncIntentStatus.pending);
      expect(remoteRequested.intent?.reason, 'local_delete_playlist_remote');
      final untouchedOtherAccount = (await store.loadWork(otherKey))!;
      expect(untouchedOtherAccount.binding.remoteDeleteRequestedAt, isNull);
      expect(untouchedOtherAccount.intent, isNull);

      await service.tombstoneCatalogPlaylist(
        playlistId: 'p1',
        now: now.add(const Duration(seconds: 3)),
      );
      final repeatedLocalOnly = (await store.loadWork(key))!;
      expect(repeatedLocalOnly.binding.remoteDeleteRequestedAt, isNotNull);
      expect(repeatedLocalOnly.intent?.reason, 'local_delete_playlist_remote');
    },
  );

  test(
    'local changes keep an ambiguous mutation frozen until read-back',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-ambiguous-sync-',
      );
      final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await service.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      await service.createCatalogPlaylist(id: 'p1', name: 'Road', now: now);
      final trackA = CatalogTrack.youtube(
        videoId: 'AbCdEfGhIj1',
        title: 'Song A',
      );
      await service.appendCatalogEntry(
        playlistId: 'p1',
        entryId: 'entry-a',
        track: trackA,
        now: now,
      );
      var conflictId = 0;
      final store = SqlitePlaylistSyncStore(
        service,
        conflictIdFactory: () => 'conflict-${conflictId++}',
      );
      const key = PlaylistSyncKey(accountKey: 'account', playlistId: 'p1');
      final playlist = (await service.getCatalogPlaylist('p1'))!.playlist;
      await store.upsertBinding(
        PlaylistSyncBinding(
          key: key,
          remotePlaylistId: 'remote-1',
          mode: PlaylistSyncMode.automatic,
          localRevisionAtBase: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final desired = PlaylistSyncSnapshot(
        remotePlaylistId: 'remote-1',
        title: 'Road',
        items: <PlaylistSyncItem>[
          PlaylistSyncItem(
            localItemId: 'entry-a',
            videoId: 'AbCdEfGhIj1',
            track: trackA,
          ),
        ],
      );
      await store.recordDeferred(
        key: key,
        requestedLocalRevision: playlist.localRevision,
        reason: 'ambiguous_mutation',
        now: now,
        nextAttemptAt: now.add(const Duration(seconds: 5)),
        desired: desired,
        mutationToken: 'mutation-frozen',
        error: 'timeout',
        ambiguous: true,
      );
      final frozen = (await store.loadWork(key))!.intent!;

      await service.appendCatalogEntry(
        playlistId: 'p1',
        entryId: 'entry-b',
        track: CatalogTrack.youtube(videoId: 'BcDeFgHiJk2', title: 'Song B'),
        now: now.add(const Duration(seconds: 1)),
      );
      _expectSameFrozenIntent((await store.loadWork(key))!.intent!, frozen);

      await service.saveLocalTrack(
        LocalTrack(
          id: 'download-a',
          title: 'Song A',
          artist: 'Artist',
          filePath: p.join(sandbox.path, 'a.m4a'),
          sourceId: 'AbCdEfGhIj1',
          addedAt: now,
        ),
      );
      expect(
        await service.linkCatalogDownload(
          videoId: 'AbCdEfGhIj1',
          localTrackId: 'download-a',
          now: now.add(const Duration(seconds: 2)),
        ),
        1,
      );
      final afterDownload = (await store.loadWork(key))!;
      _expectSameFrozenIntent(afterDownload.intent!, frozen);
      expect(afterDownload.localRevision, greaterThan(playlist.localRevision));
      expect(afterDownload.local.items.first.localTrackId, 'download-a');

      final verifiedRemote = PlaylistSyncSnapshot(
        remotePlaylistId: 'remote-1',
        title: 'Road',
        items: <PlaylistSyncItem>[
          PlaylistSyncItem(
            localItemId: 'entry-a',
            videoId: 'AbCdEfGhIj1',
            setVideoId: 'verified-a',
            track: trackA,
          ),
        ],
        remoteRevision: 'revision-1',
      );
      await store.commitVerifiedBaseWithNewerLocal(
        key: key,
        verifiedBase: verifiedRemote,
        verifiedRemote: verifiedRemote,
        verifiedLocalRevision: frozen.requestedLocalRevision,
        expectedLocalRevision: afterDownload.localRevision,
        now: now.add(const Duration(seconds: 3)),
      );
      final resolved = (await store.loadWork(key))!;
      expect(resolved.base!.items, hasLength(1));
      expect(resolved.base!.items.single.setVideoId, 'verified-a');
      expect(resolved.local.items, hasLength(2));
      expect(resolved.local.items.first.localTrackId, 'download-a');
      expect(resolved.intent?.status, PlaylistSyncIntentStatus.pending);
      expect(
        resolved.intent?.requestedLocalRevision,
        afterDownload.localRevision,
      );
      expect(resolved.intent?.reason, 'newer_local_after_verified_ambiguous');
      expect(resolved.intent?.desiredSnapshot, isNull);
      expect(resolved.intent?.mutationToken, isNull);
    },
  );

  test(
    'local edits keep a conflict frozen until an explicit resolution',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-conflict-freeze-',
      );
      final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await service.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      await service.createCatalogPlaylist(id: 'p1', name: 'Road', now: now);
      final trackA = CatalogTrack.youtube(
        videoId: 'AbCdEfGhIj1',
        title: 'Song A',
      );
      await service.appendCatalogEntry(
        playlistId: 'p1',
        entryId: 'entry-a',
        track: trackA,
        now: now,
      );
      var conflictId = 0;
      final store = SqlitePlaylistSyncStore(
        service,
        conflictIdFactory: () => 'conflict-${conflictId++}',
      );
      const key = PlaylistSyncKey(accountKey: 'account', playlistId: 'p1');
      final initial = (await service.getCatalogPlaylist('p1'))!.playlist;
      await store.upsertBinding(
        PlaylistSyncBinding(
          key: key,
          remotePlaylistId: 'remote-1',
          mode: PlaylistSyncMode.automatic,
          localRevisionAtBase: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final desired = PlaylistSyncSnapshot(
        remotePlaylistId: 'remote-1',
        title: 'Road',
        items: <PlaylistSyncItem>[
          PlaylistSyncItem(
            localItemId: 'entry-a',
            videoId: 'AbCdEfGhIj1',
            setVideoId: 'set-a',
            track: trackA,
          ),
        ],
      );
      await store.recordDeferred(
        key: key,
        requestedLocalRevision: initial.localRevision,
        reason: 'ambiguous_mutation',
        now: now,
        nextAttemptAt: now.add(const Duration(seconds: 5)),
        desired: desired,
        mutationToken: 'partial-write-token',
        error: 'timeout',
        ambiguous: true,
      );
      await store.recordConflict(
        key: key,
        conflict: const PlaylistSyncConflict(
          kind: PlaylistSyncConflictKind.ambiguousMutation,
          message: 'partial write',
        ),
        base: null,
        local: desired,
        remote: desired,
        now: now.add(const Duration(milliseconds: 500)),
      );
      final frozen = (await store.loadWork(key))!.intent!;
      expect(frozen.status, PlaylistSyncIntentStatus.conflict);
      expect(frozen.desiredSnapshot?.encode(), desired.encode());
      expect(frozen.mutationToken, 'partial-write-token');
      final unresolved = await store.listUnresolvedConflicts(
        accountKey: ' account ',
      );
      expect(unresolved, hasLength(1));
      expect(unresolved.single.key, key);
      expect(unresolved.single.playlistTitle, 'Road');
      expect(unresolved.single.localRevision, initial.localRevision);
      expect(
        unresolved.single.kind,
        PlaylistSyncConflictKind.ambiguousMutation,
      );
      expect(unresolved.single.message, 'partial write');
      expect(
        unresolved.single.detectedAt,
        now.add(const Duration(milliseconds: 500)),
      );
      expect(
        await store.listUnresolvedConflicts(accountKey: 'another-account'),
        isEmpty,
      );
      await expectLater(
        store.listUnresolvedConflicts(accountKey: '   '),
        throwsArgumentError,
      );

      await service.appendCatalogEntry(
        playlistId: 'p1',
        entryId: 'entry-b',
        track: CatalogTrack.youtube(videoId: 'BcDeFgHiJk2', title: 'Song B'),
        now: now.add(const Duration(seconds: 1)),
      );
      _expectSameFrozenIntent((await store.loadWork(key))!.intent!, frozen);
      await service.saveLocalTrack(
        LocalTrack(
          id: 'download-a',
          title: 'Song A',
          artist: 'Artist',
          filePath: p.join(sandbox.path, 'a.m4a'),
          sourceId: 'AbCdEfGhIj1',
          addedAt: now,
        ),
      );
      await service.linkCatalogDownload(
        videoId: 'AbCdEfGhIj1',
        localTrackId: 'download-a',
        now: now.add(const Duration(seconds: 2)),
      );
      final afterEdits = (await store.loadWork(key))!;
      _expectSameFrozenIntent(afterEdits.intent!, frozen);

      await store.resolveConflict(
        key: key,
        resolution: PlaylistSyncConflictResolution.keepLocal,
        expectedLocalRevision: afterEdits.localRevision,
        now: now.add(const Duration(seconds: 3)),
      );
      final resolved = (await store.loadWork(key))!.intent!;
      expect(resolved.status, PlaylistSyncIntentStatus.pending);
      expect(
        resolved.reason,
        playlistSyncConflictResolutionReason(
          PlaylistSyncConflictResolution.keepLocal,
        ),
      );
      expect(resolved.desiredSnapshot, isNull);
      expect(resolved.mutationToken, isNull);
      final db = await service.database;
      final conflictRows = await db.query('playlist_sync_conflicts');
      expect(conflictRows.single['resolution'], 'keepLocal');
      expect(conflictRows.single['resolved_at'], isNotNull);
      expect(
        await store.listUnresolvedConflicts(accountKey: 'account'),
        isEmpty,
      );
    },
  );

  test('binding and deferred intent updates preserve creation state', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'bstream-portable-sync-upsert-',
    );
    final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
    addTearDown(() async {
      await service.close();
      await sandbox.delete(recursive: true);
    });
    final now = DateTime.utc(2026, 8, 27, 12);
    await service.createCatalogPlaylist(id: 'p1', name: 'Road', now: now);
    final store = SqlitePlaylistSyncStore(
      service,
      conflictIdFactory: () => 'unused-conflict',
    );
    const key = PlaylistSyncKey(accountKey: 'account', playlistId: 'p1');
    await store.upsertBinding(
      PlaylistSyncBinding(
        key: key,
        remotePlaylistId: 'remote-1',
        mode: PlaylistSyncMode.automatic,
        privacy: 'PUBLIC',
        localRevisionAtBase: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await store.upsertBinding(
      PlaylistSyncBinding(
        key: key,
        remotePlaylistId: 'remote-1',
        mode: PlaylistSyncMode.automatic,
        privacy: 'PRIVATE',
        localRevisionAtBase: 0,
        createdAt: now.add(const Duration(days: 1)),
        updatedAt: now.add(const Duration(seconds: 1)),
      ),
    );

    final binding = (await store.listBindings(accountKey: 'account')).single;
    expect(binding.createdAt, now);
    expect(binding.updatedAt, now.add(const Duration(seconds: 1)));
    expect(binding.privacy, 'PRIVATE');

    await store.recordDeferred(
      key: key,
      requestedLocalRevision: 7,
      reason: 'first_attempt',
      now: now.add(const Duration(seconds: 2)),
      nextAttemptAt: now.add(const Duration(minutes: 1)),
      error: 'first error',
    );
    await store.recordDeferred(
      key: key,
      requestedLocalRevision: 3,
      reason: 'second_attempt',
      now: now.add(const Duration(seconds: 3)),
      nextAttemptAt: now.add(const Duration(minutes: 2)),
      error: 'second error',
    );

    final intent = (await store.loadWork(key))!.intent!;
    expect(intent.requestedLocalRevision, 7);
    expect(intent.reason, 'second_attempt');
    expect(intent.attemptCount, 2);
    expect(intent.createdAt, now.add(const Duration(seconds: 2)));
    expect(intent.updatedAt, now.add(const Duration(seconds: 3)));
    expect(intent.lastError, 'second error');
  });

  test('directed privacy update preserves every other binding field', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'bstream-binding-privacy-atomic-',
    );
    final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
    addTearDown(() async {
      await service.close();
      await sandbox.delete(recursive: true);
    });
    final createdAt = DateTime.utc(2026, 8, 27, 8);
    final originalUpdatedAt = createdAt.add(const Duration(minutes: 1));
    final privacyUpdatedAt = createdAt.add(const Duration(minutes: 2));
    await service.createCatalogPlaylist(
      id: 'privacy-playlist',
      name: 'Private playlist',
      now: createdAt,
    );
    final store = SqlitePlaylistSyncStore(
      service,
      conflictIdFactory: () => 'unused-conflict',
    );
    const key = PlaylistSyncKey(
      accountKey: 'account-a',
      playlistId: 'privacy-playlist',
    );
    await store.upsertBinding(
      PlaylistSyncBinding(
        key: key,
        remotePlaylistId: 'remote-exact',
        remoteBrowseId: 'VLremote-exact',
        mode: PlaylistSyncMode.automatic,
        isEditable: true,
        privacy: 'PRIVATE',
        baseTitle: 'Remote title',
        baseSnapshotHash: 'snapshot-hash',
        remoteRevision: 'remote-revision',
        localRevisionAtBase: 7,
        lastSyncedAt: createdAt.add(const Duration(seconds: 10)),
        lastRemoteSeenAt: createdAt.add(const Duration(seconds: 20)),
        createdAt: createdAt,
        updatedAt: originalUpdatedAt,
      ),
    );
    final db = await service.database;
    final before = Map<String, Object?>.from(
      (await db.query(
        'ytm_playlist_bindings',
        where: 'account_key = ? AND playlist_id = ?',
        whereArgs: const <Object?>['account-a', 'privacy-playlist'],
      )).single,
    );

    final changed = await store.updateBindingPrivacy(
      key: key,
      expectedRemotePlaylistId: 'remote-exact',
      privacy: 'UNLISTED',
      now: privacyUpdatedAt,
    );

    expect(changed, isTrue);
    final after = Map<String, Object?>.from(
      (await db.query(
        'ytm_playlist_bindings',
        where: 'account_key = ? AND playlist_id = ?',
        whereArgs: const <Object?>['account-a', 'privacy-playlist'],
      )).single,
    );
    expect(after.remove('privacy'), 'UNLISTED');
    expect(after.remove('updated_at'), privacyUpdatedAt.toIso8601String());
    before.remove('privacy');
    before.remove('updated_at');
    expect(after, before);
  });

  test(
    'directed privacy update fences remote id, account and deleting bindings',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-binding-privacy-fences-',
      );
      final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await service.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 27, 9);
      await service.createCatalogPlaylist(
        id: 'privacy-playlist',
        name: 'Private playlist',
        now: now,
      );
      final store = SqlitePlaylistSyncStore(
        service,
        conflictIdFactory: () => 'unused-conflict',
      );
      const key = PlaylistSyncKey(
        accountKey: 'account-a',
        playlistId: 'privacy-playlist',
      );
      final binding = PlaylistSyncBinding(
        key: key,
        remotePlaylistId: 'remote-exact',
        mode: PlaylistSyncMode.automatic,
        privacy: 'PRIVATE',
        localRevisionAtBase: 0,
        createdAt: now,
        updatedAt: now,
      );
      await store.upsertBinding(binding);

      expect(
        await store.updateBindingPrivacy(
          key: key,
          expectedRemotePlaylistId: ' remote-exact ',
          privacy: 'UNLISTED',
          now: now.add(const Duration(seconds: 1)),
        ),
        isFalse,
      );
      expect(
        await store.updateBindingPrivacy(
          key: const PlaylistSyncKey(
            accountKey: 'account-b',
            playlistId: 'privacy-playlist',
          ),
          expectedRemotePlaylistId: 'remote-exact',
          privacy: 'UNLISTED',
          now: now.add(const Duration(seconds: 2)),
        ),
        isFalse,
      );
      var stored = (await store.listBindings(accountKey: 'account-a')).single;
      expect(stored.privacy, 'PRIVATE');
      expect(stored.updatedAt, now);

      final deletingAt = now.add(const Duration(seconds: 3));
      await store.upsertBinding(
        binding.copyWith(
          remoteDeleteRequestedAt: deletingAt,
          updatedAt: deletingAt,
        ),
      );
      expect(
        await store.updateBindingPrivacy(
          key: key,
          expectedRemotePlaylistId: 'remote-exact',
          privacy: 'UNLISTED',
          now: now.add(const Duration(seconds: 4)),
        ),
        isFalse,
      );
      stored = (await store.listBindings(accountKey: 'account-a')).single;
      expect(stored.privacy, 'PRIVATE');
      expect(stored.updatedAt, deletingAt);
      expect(stored.remoteDeleteRequestedAt, deletingAt);
    },
  );

  test('directed privacy update rolls back when commit fence closes', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'bstream-binding-privacy-rollback-',
    );
    final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
    addTearDown(() async {
      await service.close();
      await sandbox.delete(recursive: true);
    });
    final now = DateTime.utc(2026, 8, 27, 10);
    await service.createCatalogPlaylist(
      id: 'privacy-playlist',
      name: 'Private playlist',
      now: now,
    );
    final store = SqlitePlaylistSyncStore(
      service,
      conflictIdFactory: () => 'unused-conflict',
    );
    const key = PlaylistSyncKey(
      accountKey: 'account-a',
      playlistId: 'privacy-playlist',
    );
    await store.upsertBinding(
      PlaylistSyncBinding(
        key: key,
        remotePlaylistId: 'remote-exact',
        mode: PlaylistSyncMode.automatic,
        privacy: 'PRIVATE',
        localRevisionAtBase: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );

    await expectLater(
      store.updateBindingPrivacy(
        key: key,
        expectedRemotePlaylistId: 'remote-exact',
        privacy: 'UNLISTED',
        now: now.add(const Duration(seconds: 1)),
        canCommit: () => false,
      ),
      throwsA(isA<PlaylistSyncFenceChanged>()),
    );

    final stored = (await store.listBindings(accountKey: 'account-a')).single;
    expect(stored.privacy, 'PRIVATE');
    expect(stored.updatedAt, now);
  });

  test('SQLite sync store commits base and rejects stale revisions', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'bstream-store-sync-',
    );
    final service = _TestDatabase(p.join(sandbox.path, 'library.db'));
    addTearDown(() async {
      await service.close();
      await sandbox.delete(recursive: true);
    });
    final now = DateTime.utc(2026, 8, 22);
    await service.createCatalogPlaylist(id: 'p1', name: 'Remote', now: now);
    final track = CatalogTrack.youtube(videoId: 'AbCdEfGhIj1', title: 'Song A');
    await service.appendCatalogEntry(
      playlistId: 'p1',
      entryId: 'entry-1',
      track: track,
      now: now,
    );
    var conflictId = 0;
    final store = SqlitePlaylistSyncStore(
      service,
      conflictIdFactory: () => 'conflict-${conflictId++}',
    );
    const key = PlaylistSyncKey(accountKey: 'account', playlistId: 'p1');
    final playlist = (await service.getCatalogPlaylist('p1'))!.playlist;
    await store.upsertBinding(
      PlaylistSyncBinding(
        key: key,
        remotePlaylistId: 'remote-1',
        mode: PlaylistSyncMode.automatic,
        localRevisionAtBase: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await store.enqueueIntent(
      key: key,
      requestedLocalRevision: playlist.localRevision,
      reason: 'test',
      now: now,
    );
    final work = (await store.loadWork(key))!;
    expect(work.base, isNull);
    expect(work.local.items.single.localItemId, 'entry-1');

    final verified = PlaylistSyncSnapshot(
      remotePlaylistId: 'remote-1',
      title: 'Remote',
      items: <PlaylistSyncItem>[
        PlaylistSyncItem(
          localItemId: 'entry-1',
          videoId: 'AbCdEfGhIj1',
          setVideoId: 'set-1',
          track: track,
        ),
      ],
    );
    await expectLater(
      store.commitSynchronized(
        key: key,
        mergedLocal: verified,
        verifiedRemote: verified,
        expectedLocalRevision: playlist.localRevision,
        now: now.add(const Duration(milliseconds: 500)),
        canCommit: () => false,
      ),
      throwsA(isA<PlaylistSyncFenceChanged>()),
    );
    final fenced = (await store.loadWork(key))!;
    expect(fenced.base, isNull);
    expect(fenced.intent?.status, PlaylistSyncIntentStatus.pending);
    expect(fenced.local.items.single.setVideoId, isNull);

    await store.commitSynchronized(
      key: key,
      mergedLocal: verified,
      verifiedRemote: verified,
      expectedLocalRevision: playlist.localRevision,
      now: now.add(const Duration(seconds: 1)),
    );
    final committed = (await store.loadWork(key))!;
    expect(committed.base!.items.single.setVideoId, 'set-1');
    expect(committed.intent, isNull);
    await expectLater(
      store.commitSynchronized(
        key: key,
        mergedLocal: verified,
        verifiedRemote: verified,
        expectedLocalRevision: playlist.localRevision - 1,
        now: now,
      ),
      throwsA(isA<PlaylistSyncRevisionChanged>()),
    );
  });
}

Future<void> _createV7Schema(Database db) async {
  await db.execute('''
    CREATE TABLE local_tracks (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL,
      file_path TEXT NOT NULL, source_url TEXT, thumbnail_url TEXT,
      catalog_thumbnail_url TEXT, thumbnail_path TEXT,
      duration_seconds INTEGER, album TEXT,
      artists_json TEXT NOT NULL DEFAULT '[]',
      artist_browse_ids_json TEXT NOT NULL DEFAULT '[]',
      metadata_source TEXT NOT NULL DEFAULT 'youtube', source_id TEXT,
      added_at TEXT NOT NULL, last_played_at TEXT,
      last_played_playlist_id TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE playlists (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, track_ids TEXT NOT NULL,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE playback_events (
      session_id TEXT PRIMARY KEY, track_key TEXT NOT NULL,
      track_id TEXT NOT NULL, video_id TEXT, title TEXT NOT NULL,
      artists_json TEXT NOT NULL DEFAULT '[]',
      artist_browse_ids_json TEXT NOT NULL DEFAULT '[]', album TEXT,
      thumbnail_url TEXT, duration_ms INTEGER, source TEXT NOT NULL,
      started_at TEXT NOT NULL, played_at TEXT NOT NULL,
      listened_ms INTEGER NOT NULL DEFAULT 0, completed INTEGER NOT NULL DEFAULT 0,
      is_favorite INTEGER, is_liked INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE related_track_candidates (
      seed_key TEXT NOT NULL, candidate_key TEXT NOT NULL,
      track_id TEXT NOT NULL, video_id TEXT, title TEXT NOT NULL,
      artists_json TEXT NOT NULL DEFAULT '[]',
      artist_browse_ids_json TEXT NOT NULL DEFAULT '[]', album TEXT,
      thumbnail_url TEXT, duration_ms INTEGER, rank INTEGER NOT NULL,
      fetched_at TEXT NOT NULL, PRIMARY KEY (seed_key, candidate_key)
    )
  ''');
  await db.execute('''
    CREATE TABLE recommendation_feed_cache (
      feed_key TEXT PRIMARY KEY, payload_json TEXT NOT NULL,
      generated_at TEXT NOT NULL, expires_at TEXT NOT NULL
    )
  ''');
}

class _TestDatabase extends LocalDatabaseService {
  _TestDatabase(this.path);

  final String path;

  @override
  Future<String> databasePath() async => path;
}

void _expectSameFrozenIntent(
  PlaylistSyncIntent actual,
  PlaylistSyncIntent expected,
) {
  expect(actual.status, expected.status);
  expect(actual.requestedLocalRevision, expected.requestedLocalRevision);
  expect(actual.reason, expected.reason);
  expect(actual.desiredSnapshot?.encode(), expected.desiredSnapshot?.encode());
  expect(actual.desiredSnapshotHash, expected.desiredSnapshotHash);
  expect(actual.mutationToken, expected.mutationToken);
  expect(actual.attemptCount, expected.attemptCount);
  expect(actual.nextAttemptAt, expected.nextAttemptAt);
  expect(actual.lastError, expected.lastError);
  expect(actual.updatedAt, expected.updatedAt);
}
