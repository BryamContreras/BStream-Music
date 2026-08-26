import 'dart:io';

import 'package:bstream_music/features/music/data/repositories/catalog_playlist_repository_impl.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_account_sync_coordinator.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_engine.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_models.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_store.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_three_way_merger.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/sqlite_playlist_sync_store.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/youtube_music_playlist_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'syncAll imports by remote ID, creates private remotes, and skips favorites',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-account-sync-',
      );
      final database = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await database.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      final repository = CatalogPlaylistRepositoryImpl(database);
      await repository.createCatalogPlaylist(
        id: Playlist.favoritesId,
        name: 'Favoritos',
        now: now,
      );
      // Same name as the remote proves that bootstrap never links by name.
      await repository.createCatalogPlaylist(
        id: 'local-one',
        name: 'Remote One',
        now: now,
      );
      final localTrack = CatalogTrack.youtube(
        videoId: 'Local000001',
        title: 'Local song',
      );
      await repository.appendCatalogEntry(
        playlistId: 'local-one',
        entryId: 'local-entry',
        track: localTrack,
        now: now,
      );

      var conflictId = 0;
      final store = SqlitePlaylistSyncStore(
        database,
        conflictIdFactory: () => 'conflict-${conflictId++}',
      );
      final gateway = _AccountGateway();
      var generatedItem = 0;
      var mutation = 0;
      final engine = PlaylistSyncEngine(
        store: store,
        gateway: gateway,
        merger: PlaylistThreeWayMerger(
          itemIdFactory: () => 'remote-entry-${generatedItem++}',
        ),
        mutationTokenFactory: () => 'mutation-${mutation++}',
        clock: () => now,
      );
      final coordinator = PlaylistAccountSyncCoordinator(
        playlists: repository,
        store: store,
        engine: engine,
        catalogGateway: gateway,
        localPlaylistIdFactory: () => 'imported-one',
        clock: () => now,
      );

      final first = await coordinator.syncAll('account');

      expect(first.linkedLocalCount, 1);
      expect(first.importedRemoteCount, 1);
      expect(gateway.createCount, 1);
      expect(gateway.createdPrivacy, 'PRIVATE');
      final bindings = await store.listBindings(accountKey: 'account');
      expect(bindings, hasLength(2));
      expect(
        bindings.map((binding) => binding.key.playlistId),
        isNot(contains(Playlist.favoritesId)),
      );
      expect(
        bindings.map((binding) => binding.mode),
        everyElement(PlaylistSyncMode.automatic),
      );
      final imported = await repository.getCatalogPlaylist('imported-one');
      expect(imported!.entries.single.videoId, 'Remote00001');

      final second = await coordinator.syncAll('account');
      expect(second.linkedLocalCount, 0);
      expect(second.importedRemoteCount, 0);
      expect(gateway.createCount, 1);
    },
  );

  test(
    'a playlist created remotely accepts a later local addition without conflict',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-account-create-then-append-',
      );
      final database = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await database.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      final repository = CatalogPlaylistRepositoryImpl(database);
      await repository.createCatalogPlaylist(
        id: 'local-new',
        name: 'New playlist',
        now: now,
      );

      var conflictId = 0;
      final store = SqlitePlaylistSyncStore(
        database,
        conflictIdFactory: () => 'conflict-${conflictId++}',
      );
      final gateway = _AccountGateway()..includeRegularRemote = false;
      var generatedItem = 0;
      var mutation = 0;
      final engine = PlaylistSyncEngine(
        store: store,
        gateway: gateway,
        merger: PlaylistThreeWayMerger(
          itemIdFactory: () => 'remote-entry-${generatedItem++}',
        ),
        mutationTokenFactory: () => 'mutation-${mutation++}',
        clock: () => now,
      );
      final coordinator = PlaylistAccountSyncCoordinator(
        playlists: repository,
        store: store,
        engine: engine,
        catalogGateway: gateway,
        localPlaylistIdFactory: () => 'unused-import',
        clock: () => now,
      );
      const key = PlaylistSyncKey(
        accountKey: 'account',
        playlistId: 'local-new',
      );

      final created = await coordinator.syncAll('account');

      expect(created.linkedLocalCount, 1);
      expect(created.importedRemoteCount, 0);
      expect(
        created.results[key]?.disposition,
        PlaylistSyncDisposition.synchronized,
      );
      expect(gateway.createCount, 1);
      expect(gateway.applyCount, 0);
      final createdWork = await store.loadWork(key);
      expect(createdWork, isNotNull);
      expect(createdWork!.binding.remotePlaylistId, 'created-one');
      expect(createdWork.binding.localRevisionAtBase, 1);
      expect(createdWork.base?.items, isEmpty);
      expect(createdWork.intent, isNull);

      await repository.appendCatalogEntry(
        playlistId: key.playlistId,
        entryId: 'local-entry',
        track: CatalogTrack.youtube(
          videoId: 'Local000001',
          title: 'Added after remote creation',
        ),
        now: now.add(const Duration(seconds: 1)),
      );
      final pendingWork = await store.loadWork(key);
      expect(pendingWork!.localRevision, 2);
      expect(pendingWork.intent?.status, PlaylistSyncIntentStatus.pending);
      expect(pendingWork.intent?.reason, 'local_append');

      final updated = await coordinator.syncAll('account');

      expect(updated.linkedLocalCount, 0);
      expect(updated.importedRemoteCount, 0);
      expect(
        updated.results[key]?.disposition,
        PlaylistSyncDisposition.synchronized,
      );
      expect(gateway.createCount, 1);
      expect(gateway.applyCount, 1);
      expect(gateway.deleteCount, 0);
      expect(
        gateway.snapshots['created-one']!.items.map((item) => item.videoId),
        const <String>['Local000001'],
      );

      final synchronized = await repository.getCatalogPlaylist(key.playlistId);
      final synchronizedWork = await store.loadWork(key);
      expect(synchronized, isNotNull);
      expect(synchronized!.entries, hasLength(1));
      expect(synchronized.entries.single.id, 'local-entry');
      expect(synchronized.entries.single.videoId, 'Local000001');
      expect(synchronizedWork, isNotNull);
      expect(synchronizedWork!.intent, isNull);
      expect(synchronizedWork.base?.items.single.videoId, 'Local000001');
      expect(synchronizedWork.local.items.single.videoId, 'Local000001');
      expect(
        synchronizedWork.binding.localRevisionAtBase,
        synchronized.playlist.localRevision,
      );
      expect(
        await store.listUnresolvedConflicts(accountKey: 'account'),
        isEmpty,
      );

      final repeated = await coordinator.syncAll('account');

      expect(
        repeated.results[key]?.disposition,
        PlaylistSyncDisposition.noChanges,
      );
      expect(gateway.createCount, 1);
      expect(gateway.applyCount, 1);
      expect(gateway.deleteCount, 0);
    },
  );

  test('binds YouTube Music Liked Music to local Favorites', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'bstream-account-sync-favorites-',
    );
    final database = _TestDatabase(p.join(sandbox.path, 'library.db'));
    addTearDown(() async {
      await database.close();
      await sandbox.delete(recursive: true);
    });
    final now = DateTime.utc(2026, 8, 22, 12);
    final repository = CatalogPlaylistRepositoryImpl(database);
    await repository.createCatalogPlaylist(
      id: Playlist.favoritesId,
      name: 'Favoritos',
      now: now,
    );
    final store = SqlitePlaylistSyncStore(
      database,
      conflictIdFactory: () => 'favorite-conflict',
    );
    final gateway = _AccountGateway()
      ..includeLikedMusic = true
      ..includeRegularRemote = false;
    final engine = PlaylistSyncEngine(
      store: store,
      gateway: gateway,
      merger: PlaylistThreeWayMerger(itemIdFactory: () => 'favorite-entry'),
      mutationTokenFactory: () => 'favorite-mutation',
      clock: () => now,
    );
    final coordinator = PlaylistAccountSyncCoordinator(
      playlists: repository,
      store: store,
      engine: engine,
      catalogGateway: gateway,
      localPlaylistIdFactory: () => 'unused-import',
      clock: () => now,
    );

    final result = await coordinator.syncAll('account');

    expect(result.importedRemoteCount, 0);
    final bindings = await store.listBindings(accountKey: 'account');
    expect(bindings, hasLength(1));
    expect(bindings.single.key.playlistId, Playlist.favoritesId);
    expect(bindings.single.remotePlaylistId, 'LM');
    expect(await repository.getCatalogPlaylists(), hasLength(1));
    expect(gateway.createCount, 0);
  });

  test(
    'first sync materializes Favorites when the local library is empty',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-account-sync-empty-favorites-',
      );
      final database = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await database.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      final repository = CatalogPlaylistRepositoryImpl(database);
      final store = SqlitePlaylistSyncStore(
        database,
        conflictIdFactory: () => 'empty-favorites-conflict',
      );
      final gateway = _AccountGateway()
        ..includeLikedMusic = true
        ..includeRegularRemote = false;
      final engine = PlaylistSyncEngine(
        store: store,
        gateway: gateway,
        merger: PlaylistThreeWayMerger(
          itemIdFactory: () => 'empty-favorites-entry',
        ),
        mutationTokenFactory: () => 'empty-favorites-mutation',
        clock: () => now,
      );
      final coordinator = PlaylistAccountSyncCoordinator(
        playlists: repository,
        store: store,
        engine: engine,
        catalogGateway: gateway,
        localPlaylistIdFactory: () => 'unused-import',
        clock: () => now,
      );

      final result = await coordinator.syncAll('account');

      expect(result.importedRemoteCount, 0);
      expect(
        (await repository.getCatalogPlaylists()).map((playlist) => playlist.id),
        contains(Playlist.favoritesId),
      );
      final bindings = await store.listBindings(accountKey: 'account');
      expect(bindings, hasLength(1));
      expect(bindings.single.key.playlistId, Playlist.favoritesId);
    },
  );

  test(
    'an incomplete shelf summary cannot downgrade known edit access',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-account-capability-',
      );
      final database = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await database.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      final repository = CatalogPlaylistRepositoryImpl(database);
      await repository.createCatalogPlaylist(
        id: 'local-one',
        name: 'Remote One',
        now: now,
      );
      var conflictId = 0;
      final store = SqlitePlaylistSyncStore(
        database,
        conflictIdFactory: () => 'conflict-${conflictId++}',
      );
      const key = PlaylistSyncKey(
        accountKey: 'account',
        playlistId: 'local-one',
      );
      await store.upsertBinding(
        PlaylistSyncBinding(
          key: key,
          remotePlaylistId: 'remote-one',
          mode: PlaylistSyncMode.automatic,
          isEditable: true,
          localRevisionAtBase: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final gateway = _AccountGateway()
        ..summaryEditable = false
        ..fetchError = const _Offline();
      final engine = PlaylistSyncEngine(
        store: store,
        gateway: gateway,
        merger: PlaylistThreeWayMerger(itemIdFactory: () => 'unused-entry'),
        mutationTokenFactory: () => 'unused-mutation',
        clock: () => now,
      );
      final coordinator = PlaylistAccountSyncCoordinator(
        playlists: repository,
        store: store,
        engine: engine,
        catalogGateway: gateway,
        localPlaylistIdFactory: () => 'unused-playlist',
        clock: () => now,
      );

      await coordinator.syncAll('account');

      final binding = (await store.listBindings(accountKey: 'account')).single;
      expect(binding.isEditable, isTrue);
    },
  );

  test(
    'switching accounts never uploads a playlist imported by another account',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-account-isolation-',
      );
      final database = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await database.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      final repository = CatalogPlaylistRepositoryImpl(database);
      var conflictId = 0;
      final store = SqlitePlaylistSyncStore(
        database,
        conflictIdFactory: () => 'conflict-${conflictId++}',
      );
      final gateway = _AccountGateway();
      var itemId = 0;
      final engine = PlaylistSyncEngine(
        store: store,
        gateway: gateway,
        merger: PlaylistThreeWayMerger(
          itemIdFactory: () => 'entry-${itemId++}',
        ),
        mutationTokenFactory: () => 'mutation-isolation',
        clock: () => now,
      );
      final coordinator = PlaylistAccountSyncCoordinator(
        playlists: repository,
        store: store,
        engine: engine,
        catalogGateway: gateway,
        localPlaylistIdFactory: () => 'imported-by-a',
        clock: () => now,
      );

      final imported = await coordinator.syncAll('account-a');
      expect(imported.importedRemoteCount, 1);
      expect(gateway.createCount, 0);
      expect(gateway.applyCount, 0);
      gateway.accountsWithoutRemotePlaylists.add('account-b');

      final switched = await coordinator.syncAll(
        'account-b',
        trigger: PlaylistSyncTrigger.automatic,
      );

      expect(switched.linkedLocalCount, 0);
      expect(switched.importedRemoteCount, 0);
      expect(switched.results, isEmpty);
      expect(gateway.createCount, 0);
      expect(gateway.applyCount, 0);
      expect(gateway.deleteCount, 0);
      expect(await store.listBindings(accountKey: 'account-b'), isEmpty);
      expect(await repository.getCatalogPlaylists(), hasLength(1));
    },
  );

  test(
    'remote import rolls back on a mid-transaction crash and retries once',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-atomic-import-',
      );
      final database = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await database.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      final repository = CatalogPlaylistRepositoryImpl(database);
      var failImport = true;
      var conflictId = 0;
      final store = SqlitePlaylistSyncStore(
        database,
        conflictIdFactory: () => 'conflict-${conflictId++}',
        beforeImportBindingPersisted: () {
          if (failImport) {
            failImport = false;
            throw const _InjectedCrash();
          }
        },
      );
      final gateway = _AccountGateway();
      var itemId = 0;
      final engine = PlaylistSyncEngine(
        store: store,
        gateway: gateway,
        merger: PlaylistThreeWayMerger(
          itemIdFactory: () => 'entry-${itemId++}',
        ),
        mutationTokenFactory: () => 'mutation-atomic',
        clock: () => now,
      );
      final coordinator = PlaylistAccountSyncCoordinator(
        playlists: repository,
        store: store,
        engine: engine,
        catalogGateway: gateway,
        localPlaylistIdFactory: () => 'atomic-import',
        clock: () => now,
      );

      await expectLater(
        coordinator.syncAll('account'),
        throwsA(isA<_InjectedCrash>()),
      );
      expect(await repository.getCatalogPlaylists(), isEmpty);
      expect(await store.listBindings(accountKey: 'account'), isEmpty);
      final db = await database.database;
      expect(await db.rawQuery('SELECT * FROM playlist_sync_intents'), isEmpty);

      final retried = await coordinator.syncAll('account');
      final repeated = await coordinator.syncAll('account');

      expect(retried.importedRemoteCount, 1);
      expect(repeated.importedRemoteCount, 0);
      expect(await repository.getCatalogPlaylists(), hasLength(1));
      expect(await store.listBindings(accountKey: 'account'), hasLength(1));
      expect(gateway.createCount, 0);
      expect(gateway.applyCount, 0);
    },
  );

  test(
    'a stale remote listing cannot import or bind local playlists',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-account-fence-',
      );
      final database = _TestDatabase(p.join(sandbox.path, 'library.db'));
      addTearDown(() async {
        await database.close();
        await sandbox.delete(recursive: true);
      });
      final now = DateTime.utc(2026, 8, 22, 12);
      final repository = CatalogPlaylistRepositoryImpl(database);
      var conflictId = 0;
      final store = SqlitePlaylistSyncStore(
        database,
        conflictIdFactory: () => 'conflict-${conflictId++}',
      );
      var sessionIsCurrent = true;
      final gateway = _AccountGateway()
        ..onListRemotePlaylists = () => sessionIsCurrent = false;
      final engine = PlaylistSyncEngine(
        store: store,
        gateway: gateway,
        merger: PlaylistThreeWayMerger(itemIdFactory: () => 'unused-entry'),
        mutationTokenFactory: () => 'unused-mutation',
        clock: () => now,
        canPersist: () => sessionIsCurrent,
      );
      final coordinator = PlaylistAccountSyncCoordinator(
        playlists: repository,
        store: store,
        engine: engine,
        catalogGateway: gateway,
        localPlaylistIdFactory: () => 'must-not-import',
        clock: () => now,
        canPersist: () => sessionIsCurrent,
      );

      await expectLater(
        coordinator.syncAll('account-a'),
        throwsA(isA<PlaylistSyncFenceChanged>()),
      );

      expect(await repository.getCatalogPlaylists(), isEmpty);
      expect(await store.listBindings(), isEmpty);
      expect(gateway.createCount, 0);
      expect(gateway.applyCount, 0);
      expect(gateway.deleteCount, 0);
    },
  );
}

class _AccountGateway
    implements YouTubeMusicPlaylistGateway, YouTubeMusicPlaylistCatalogGateway {
  _AccountGateway() {
    final track = CatalogTrack.youtube(
      videoId: 'Remote00001',
      title: 'Remote song',
    );
    snapshots['remote-one'] = PlaylistSyncSnapshot(
      remotePlaylistId: 'remote-one',
      title: 'Remote One',
      items: <PlaylistSyncItem>[
        PlaylistSyncItem(
          videoId: 'Remote00001',
          setVideoId: 'set-remote',
          track: track,
        ),
      ],
      privacy: 'PRIVATE',
    );
  }

  final Map<String, PlaylistSyncSnapshot> snapshots =
      <String, PlaylistSyncSnapshot>{};
  int createCount = 0;
  int applyCount = 0;
  int deleteCount = 0;
  String? createdPrivacy;
  bool summaryEditable = true;
  Object? fetchError;
  void Function()? onListRemotePlaylists;
  final Set<String> accountsWithoutRemotePlaylists = <String>{};
  bool includeLikedMusic = false;
  bool includeRegularRemote = true;

  @override
  Future<List<RemotePlaylistSummary>> listRemotePlaylists({
    required String accountKey,
  }) async {
    final result = accountsWithoutRemotePlaylists.contains(accountKey)
        ? const <RemotePlaylistSummary>[]
        : <RemotePlaylistSummary>[
            if (includeRegularRemote)
              RemotePlaylistSummary(
                remotePlaylistId: 'remote-one',
                title: 'Remote One',
                privacy: 'PRIVATE',
                isEditable: summaryEditable,
              ),
            if (includeLikedMusic)
              const RemotePlaylistSummary(
                remotePlaylistId: 'LM',
                title: 'Liked Music',
                isLikedMusic: true,
              ),
          ];
    onListRemotePlaylists?.call();
    return result;
  }

  @override
  Future<PlaylistSyncSnapshot?> fetchPlaylist({
    required String accountKey,
    required String remotePlaylistId,
  }) async {
    final error = fetchError;
    if (error != null) {
      throw error;
    }
    return snapshots[remotePlaylistId];
  }

  @override
  Future<RemoteMutationReceipt> createPlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async {
    createCount += 1;
    createdPrivacy = desired.privacy;
    snapshots['created-one'] = PlaylistSyncSnapshot(
      remotePlaylistId: 'created-one',
      title: desired.title,
      items: desired.items,
      privacy: desired.privacy,
    );
    return const RemoteMutationReceipt(
      status: RemoteMutationStatus.acknowledged,
      remotePlaylistId: 'created-one',
    );
  }

  @override
  Future<RemoteMutationReceipt> applyDesiredState({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async {
    applyCount += 1;
    snapshots[observed.remotePlaylistId!] = PlaylistSyncSnapshot(
      remotePlaylistId: observed.remotePlaylistId,
      title: desired.title,
      items: desired.items,
      privacy: desired.privacy,
    );
    return const RemoteMutationReceipt(
      status: RemoteMutationStatus.acknowledged,
    );
  }

  @override
  Future<RemoteMutationReceipt> deletePlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required String mutationToken,
  }) async {
    deleteCount += 1;
    snapshots.remove(observed.remotePlaylistId);
    return const RemoteMutationReceipt(
      status: RemoteMutationStatus.acknowledged,
    );
  }
}

class _TestDatabase extends LocalDatabaseService {
  _TestDatabase(this.path);

  final String path;

  @override
  Future<String> databasePath() async => path;
}

class _Offline implements Exception {
  const _Offline();
}

class _InjectedCrash implements Exception {
  const _InjectedCrash();
}
