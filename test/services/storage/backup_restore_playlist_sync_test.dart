import 'dart:io';

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/services/storage/backup_service.dart';
import 'package:bstream_music/services/storage/library_operation_coordinator.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_engine.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_models.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_three_way_merger.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/sqlite_playlist_sync_store.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/youtube_music_playlist_gateway.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _favoriteKey = PlaylistSyncKey(
  accountKey: 'backup-account',
  playlistId: Playlist.favoritesId,
);
const _deletedKey = PlaylistSyncKey(
  accountKey: 'backup-account',
  playlistId: 'deleted-playlist',
);
final _now = DateTime.utc(2026, 10, 26, 12);
const _videoA = 'AbCdEfGhIj1';
const _videoB = 'BcDeFgHiJk2';
const _videoC = 'CdEfGhIjKl3';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory sandbox;
  late _TestDatabase source;
  late _TestDatabase target;
  late LibraryOperationCoordinator coordinator;
  late String sourceMedia;
  late String targetMedia;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('bstream-restore-sync-');
    source = _TestDatabase(
      p.join(sandbox.path, 'source', AppConstants.databaseName),
    );
    target = _TestDatabase(
      p.join(sandbox.path, 'target', AppConstants.databaseName),
    );
    coordinator = LibraryOperationCoordinator();
    sourceMedia = p.join(sandbox.path, 'source-media');
    targetMedia = p.join(sandbox.path, 'target-media');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return call.method == 'getTemporaryDirectory'
              ? p.join(sandbox.path, 'temp')
              : null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await source.close();
    await target.close();
    await coordinator.dispose();
    await sandbox.delete(recursive: true);
  });

  test(
    'ZIP restore rebases old mutations and unions current favorites',
    () async {
      await _seedOldSyncState(source, sourceMedia);
      final before = await _store(source).loadWork(_favoriteKey);
      expect(before!.base, isNotNull);
      expect(before.intent!.status, PlaylistSyncIntentStatus.conflict);
      expect(before.intent!.desiredSnapshot, isNotNull);
      expect(
        (await _store(
          source,
        ).loadWork(_deletedKey))!.binding.remoteDeleteRequestedAt,
        isNotNull,
      );
      final archive = await BackupService(source, coordinator).createBackupFile(
        mediaRoot: sourceMedia,
        outputPath: p.join(sandbox.path, 'snapshot.zip'),
      );
      await target.initialize();

      await BackupService(
        target,
        coordinator,
      ).restoreBackupFile(backupPath: archive.path, mediaRoot: targetMedia);

      final store = _store(target);
      final favorites = (await store.loadWork(_favoriteKey))!;
      final deleted = (await store.loadWork(_deletedKey))!;
      expect(favorites.binding.remotePlaylistId, 'LM');
      expect(favorites.binding.remoteBrowseId, 'VLLM');
      expect(favorites.binding.mode, PlaylistSyncMode.automatic);
      expect(favorites.binding.baseTitle, isNull);
      expect(favorites.binding.baseSnapshotHash, isNull);
      expect(favorites.binding.remoteRevision, isNull);
      expect(favorites.binding.localRevisionAtBase, 0);
      expect(favorites.binding.lastSyncedAt, isNull);
      expect(favorites.binding.lastRemoteSeenAt, isNull);
      expect(favorites.base, isNull);
      expect(favorites.intent, isNull);
      expect(deleted.localDeleted, isTrue);
      expect(deleted.binding.remotePlaylistId, 'remote-deleted');
      expect(deleted.binding.mode, PlaylistSyncMode.manual);
      expect(deleted.binding.remoteDeleteRequestedAt, isNull);
      expect(deleted.intent, isNull);
      final db = await target.database;
      for (final table in <String>[
        'ytm_playlist_base_items',
        'playlist_sync_intents',
        'playlist_sync_conflicts',
      ]) {
        expect(await db.query(table), isEmpty, reason: table);
      }
      expect(favorites.local.items.map((item) => item.localItemId), <String>[
        'favorite-a',
        'offline-item',
      ]);
      expect(
        favorites.local.items.every((item) => item.setVideoId == null),
        isTrue,
      );

      final gateway = _CurrentLikedGateway();
      var nextItemId = 0;
      final engine = PlaylistSyncEngine(
        store: store,
        gateway: gateway,
        merger: PlaylistThreeWayMerger(
          itemIdFactory: () => 'restored-remote-${nextItemId++}',
        ),
        mutationTokenFactory: () => 'new-after-restore',
        clock: () => _now.add(const Duration(days: 10)),
      );
      final deletedResult = await engine.sync(_deletedKey);
      final favoriteResult = await engine.sync(_favoriteKey);

      expect(deletedResult.disposition, PlaylistSyncDisposition.localDeleted);
      expect(favoriteResult.disposition, PlaylistSyncDisposition.synchronized);
      expect(gateway.fetchedIds, <String>['LM', 'LM']);
      expect(gateway.deleteCount, 0);
      expect(gateway.createCount, 0);
      expect(gateway.removedVideoIds, isEmpty);
      expect(gateway.addedVideoIds, <String>{_videoA});
      final merged = (await target.getCatalogPlaylist(Playlist.favoritesId))!;
      expect(merged.entries, hasLength(4));
      expect(
        merged.entries
            .map((entry) => entry.videoId)
            .whereType<String>()
            .toSet(),
        <String>{_videoA, _videoB, _videoC},
      );
      expect(
        merged.entries
            .singleWhere((entry) => entry.videoId == _videoA)
            .localTrackId,
        'download-a',
      );
      expect(
        merged.entries
            .singleWhere((entry) => entry.videoId == null)
            .localTrackId,
        'offline-file',
      );
      final download = (await target.getLocalTracks()).singleWhere(
        (track) => track.id == 'download-a',
      );
      expect(download.filePath, p.join(targetMedia, 'audio', 'a.m4a'));
      expect(await File(download.filePath).readAsString(), 'saved audio');
    },
  );

  test(
    'rebase failure rolls back the original SQLite sync state and media',
    () async {
      await _seedOldSyncState(source, sourceMedia);
      final archive = await BackupService(source, coordinator).createBackupFile(
        mediaRoot: sourceMedia,
        outputPath: p.join(sandbox.path, 'snapshot.zip'),
      );
      await _seedOldSyncState(target, targetMedia);
      await target.renameCatalogPlaylist(
        playlistId: Playlist.favoritesId,
        name: 'Original active favorites',
        now: _now.add(const Duration(hours: 1)),
      );
      final oldAudio = File(p.join(targetMedia, 'audio', 'a.m4a'));
      await oldAudio.writeAsString('original active audio');
      final oldSync = await _readSyncTables(target);
      target.failRebase = true;

      await expectLater(
        BackupService(
          target,
          coordinator,
        ).restoreBackupFile(backupPath: archive.path, mediaRoot: targetMedia),
        throwsA(isA<StateError>()),
      );

      expect(await _readSyncTables(target), oldSync);
      expect(
        (await target.getCatalogPlaylist(Playlist.favoritesId))!.playlist.name,
        'Original active favorites',
      );
      expect(await oldAudio.readAsString(), 'original active audio');
      expect(target.rebaseCalls, 1);
    },
  );
}

SqlitePlaylistSyncStore _store(LocalDatabaseService service) =>
    SqlitePlaylistSyncStore(service, conflictIdFactory: () => 'old-conflict');

Future<Map<String, List<Map<String, Object?>>>> _readSyncTables(
  LocalDatabaseService service,
) async {
  final db = await service.database;
  return <String, List<Map<String, Object?>>>{
    for (final table in <String>[
      'ytm_playlist_bindings',
      'ytm_playlist_base_items',
      'playlist_sync_intents',
      'playlist_sync_conflicts',
    ])
      table: await db.query(table),
  };
}

Future<void> _seedOldSyncState(
  LocalDatabaseService service,
  String media,
) async {
  final audio = File(p.join(media, 'audio', 'a.m4a'));
  await audio.create(recursive: true);
  await audio.writeAsString('saved audio');
  await service.createCatalogPlaylist(
    id: Playlist.favoritesId,
    name: 'Imported favorites',
    now: _now,
  );
  await service.saveLocalTrack(
    LocalTrack(
      id: 'download-a',
      title: 'A',
      artist: 'Artist',
      filePath: audio.path,
      sourceId: _videoA,
      addedAt: _now,
    ),
  );
  await service.saveLocalTrack(
    LocalTrack(
      id: 'offline-file',
      title: 'Offline recording',
      artist: 'Artist',
      filePath: p.join(media, 'audio', 'offline.m4a'),
      addedAt: _now,
    ),
  );
  for (final entry in <({String id, CatalogTrack track, String? localId})>[
    (
      id: 'favorite-a',
      track: CatalogTrack.youtube(videoId: _videoA, title: 'A'),
      localId: 'download-a',
    ),
    (
      id: 'favorite-b',
      track: CatalogTrack.youtube(videoId: _videoB, title: 'B'),
      localId: null,
    ),
    (
      id: 'offline-item',
      track: CatalogTrack.local(
        localTrackId: 'offline-file',
        title: 'Offline recording',
      ),
      localId: 'offline-file',
    ),
  ]) {
    await service.appendCatalogEntry(
      playlistId: Playlist.favoritesId,
      entryId: entry.id,
      track: entry.track,
      localTrackId: entry.localId,
      now: _now,
    );
  }
  final store = _store(service);
  await store.upsertBinding(
    PlaylistSyncBinding(
      key: _favoriteKey,
      remotePlaylistId: 'LM',
      remoteBrowseId: 'VLLM',
      mode: PlaylistSyncMode.automatic,
      localRevisionAtBase: 0,
      createdAt: _now,
      updatedAt: _now,
    ),
  );
  final initial = (await store.loadWork(_favoriteKey))!;
  final baseline = PlaylistSyncSnapshot(
    remotePlaylistId: 'LM',
    title: initial.local.title,
    items: initial.local.items.map(
      (item) => item.copyWith(
        setVideoId: item.videoId == null ? null : 'old-${item.videoId}',
      ),
    ),
  );
  await store.commitSynchronized(
    key: _favoriteKey,
    mergedLocal: baseline,
    verifiedRemote: baseline.remoteProjection,
    expectedLocalRevision: initial.localRevision,
    now: _now,
  );
  await service.tombstoneCatalogEntry(
    playlistId: Playlist.favoritesId,
    entryId: 'favorite-b',
    now: _now,
  );
  final local = (await store.loadWork(_favoriteKey))!;
  await store.recordDeferred(
    key: _favoriteKey,
    requestedLocalRevision: local.localRevision,
    reason: 'old_unlike',
    now: _now,
    nextAttemptAt: _now.add(const Duration(days: 100)),
    desired: local.local.remoteProjection,
    mutationToken: 'old-frozen-mutation',
    ambiguous: true,
  );
  await store.recordConflict(
    key: _favoriteKey,
    conflict: const PlaylistSyncConflict(
      kind: PlaylistSyncConflictKind.ambiguousMutation,
      message: 'Old conflict',
    ),
    base: local.base,
    local: local.local,
    remote: baseline,
    now: _now,
  );
  await service.createCatalogPlaylist(
    id: _deletedKey.playlistId,
    name: 'Old deleted playlist',
    now: _now,
  );
  await store.upsertBinding(
    PlaylistSyncBinding(
      key: _deletedKey,
      remotePlaylistId: 'remote-deleted',
      mode: PlaylistSyncMode.manual,
      localRevisionAtBase: 0,
      createdAt: _now,
      updatedAt: _now,
    ),
  );
  await service.tombstoneCatalogPlaylist(
    playlistId: _deletedKey.playlistId,
    now: _now,
    deleteRemote: true,
    remoteAccountKey: _deletedKey.accountKey,
  );
}

class _TestDatabase extends LocalDatabaseService {
  _TestDatabase(this.path);
  final String path;
  bool failRebase = false;
  int rebaseCalls = 0;

  @override
  Future<String> databasePath() async => path;

  @override
  Future<void> rebasePlaylistSyncAfterRestore() async {
    rebaseCalls++;
    await super.rebasePlaylistSyncAfterRestore();
    if (failRebase) throw StateError('Injected failure after rebasing');
  }
}

class _CurrentLikedGateway
    implements YouTubeMusicPlaylistGateway, YouTubeMusicLikedMusicGateway {
  PlaylistSyncSnapshot current = PlaylistSyncSnapshot(
    remotePlaylistId: 'LM',
    title: 'Liked Music',
    items: <PlaylistSyncItem>[
      for (final video in <String>[_videoB, _videoC])
        PlaylistSyncItem(
          videoId: video,
          setVideoId: 'current-$video',
          track: CatalogTrack.youtube(videoId: video, title: video),
        ),
    ],
  );
  final fetchedIds = <String>[];
  Set<String> removedVideoIds = <String>{};
  Set<String> addedVideoIds = <String>{};
  int createCount = 0;
  int deleteCount = 0;

  @override
  Future<PlaylistSyncSnapshot?> fetchPlaylist({
    required String accountKey,
    required String remotePlaylistId,
  }) async {
    fetchedIds.add(remotePlaylistId);
    return current;
  }

  @override
  Future<RemoteMutationReceipt> applyLikedMusicState({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async {
    final observedIds = observed.items.map((item) => item.videoId!).toSet();
    final desiredIds = desired.items.map((item) => item.videoId!).toSet();
    removedVideoIds = observedIds.difference(desiredIds);
    addedVideoIds = desiredIds.difference(observedIds);
    current = PlaylistSyncSnapshot(
      remotePlaylistId: 'LM',
      title: 'Liked Music',
      items: desired.items.map(
        (item) => item.copyWith(setVideoId: 'current-${item.videoId}'),
      ),
    );
    return const RemoteMutationReceipt(
      status: RemoteMutationStatus.acknowledged,
      remotePlaylistId: 'LM',
    );
  }

  @override
  Future<RemoteMutationReceipt> createPlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async {
    createCount++;
    throw StateError('Restore must preserve remote IDs');
  }

  @override
  Future<RemoteMutationReceipt> applyDesiredState({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async => throw StateError('Favorites must use like state');

  @override
  Future<RemoteMutationReceipt> deletePlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required String mutationToken,
  }) async {
    deleteCount++;
    throw StateError('Restore must not replay pending deletions');
  }
}
