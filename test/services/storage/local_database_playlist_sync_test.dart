import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
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
