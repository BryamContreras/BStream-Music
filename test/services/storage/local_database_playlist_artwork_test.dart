import 'dart:io';

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_models.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/sqlite_playlist_sync_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory sandbox;
  late _TestDatabase service;
  final now = DateTime.utc(2026, 11, 12, 12);
  const fileName = 'playlist_e57b8304-a49c-4f51-a55f-45f776a0c062.png';

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('bstream-playlist-cover-');
    service = _TestDatabase(p.join(sandbox.path, 'library.db'));
  });

  tearDown(() async {
    await service.close();
    await sandbox.delete(recursive: true);
  });

  test(
    'v9 playlists migrate to automatic covers without losing metadata',
    () async {
      final original = Playlist(
        id: 'legacy',
        name: 'Before migration',
        trackIds: const ['one', 'two', 'one'],
        createdAt: now,
        updatedAt: now,
        localRevision: 7,
      );
      await service.savePlaylist(original);
      await service.close();
      // Version 9 has the same tables except for the new nullable cover column.
      final legacy = await databaseFactoryFfi.openDatabase(service.path);
      await legacy.execute(
        'ALTER TABLE playlists DROP COLUMN custom_artwork_file_name',
      );
      await legacy.setVersion(9);
      await legacy.close();
      await service.validateBackupDatabase(service.path);

      final migrated = (await service.getCatalogPlaylist('legacy'))!.playlist;
      expect(
        (await service.database).getVersion(),
        completion(AppConstants.databaseVersion),
      );
      expect(AppConstants.databaseVersion, 11);
      expect(migrated.name, original.name);
      expect(migrated.trackIds, original.trackIds);
      expect(migrated.createdAt, original.createdAt);
      expect(migrated.updatedAt, original.updatedAt);
      expect(migrated.localRevision, 7);
      expect(migrated.customArtworkFileName, isNull);
      expect(
        (await service.setPlaylistArtworkFileName(
          'legacy',
          fileName,
        ))!.customArtworkFileName,
        fileName,
      );
    },
  );

  test(
    'covers can be set and cleared without sync mutations, including favorites',
    () async {
      for (final id in ['playlist', Playlist.favoritesId]) {
        final original = await service.createCatalogPlaylist(
          id: id,
          name: 'Playlist $id',
          now: now,
        );
        var updated = (await service.setPlaylistArtworkFileName(id, fileName))!;
        expect(updated.customArtworkFileName, fileName);
        expect(updated.updatedAt, original.updatedAt);
        expect(updated.createdAt, original.createdAt);
        expect(updated.localRevision, original.localRevision);
        expect(updated.trackIds, original.trackIds);
        await service.close();
        updated = (await service.getCatalogPlaylist(id))!.playlist;
        expect(updated.customArtworkFileName, fileName);
        final cleared = (await service.setPlaylistArtworkFileName(id, null))!;
        expect(cleared.customArtworkFileName, isNull);
        expect(cleared.updatedAt, original.updatedAt);
        expect(cleared.localRevision, original.localRevision);
      }
      expect(
        await (await service.database).query('playlist_sync_intents'),
        isEmpty,
      );
    },
  );

  test(
    'missing or deleted playlists are never recreated by a cover update',
    () async {
      expect(
        await service.setPlaylistArtworkFileName('missing', fileName),
        isNull,
      );
      await service.createCatalogPlaylist(
        id: 'deleted',
        name: 'Deleted',
        now: now,
      );
      final db = await service.database;
      await db.update(
        'playlists',
        {'deleted_at': now.toIso8601String()},
        where: 'id = ?',
        whereArgs: ['deleted'],
      );
      expect(
        await service.setPlaylistArtworkFileName('deleted', fileName),
        isNull,
      );
      final row = (await db.query('playlists')).single;
      expect(row['deleted_at'], now.toIso8601String());
      expect(row['custom_artwork_file_name'], isNull);
      await expectLater(
        service.setPlaylistArtworkFileName('deleted', '../playlist_escape.png'),
        throwsArgumentError,
      );
    },
  );

  test('regular playlist edits retain the chosen cover', () async {
    await service.createCatalogPlaylist(
      id: 'playlist',
      name: 'Original',
      now: now,
    );
    final custom = (await service.setPlaylistArtworkFileName(
      'playlist',
      fileName,
    ))!;
    await service.savePlaylist(custom.copyWith(name: 'Renamed'));
    var restored = (await service.getCatalogPlaylist('playlist'))!.playlist;
    expect(restored.name, 'Renamed');
    expect(restored.customArtworkFileName, fileName);
    await service.savePlaylist(restored.copyWith(customArtworkFileName: null));
    restored = (await service.getCatalogPlaylist('playlist'))!.playlist;
    expect(restored.customArtworkFileName, isNull);
  });

  test(
    'a pending remote merge remains valid and preserves the local cover',
    () async {
      final playlist = await service.createCatalogPlaylist(
        id: 'playlist',
        name: 'Before sync',
        now: now,
      );
      final store = SqlitePlaylistSyncStore(
        service,
        conflictIdFactory: () => 'unused-conflict',
      );
      const key = PlaylistSyncKey(
        accountKey: 'account',
        playlistId: 'playlist',
      );
      await store.upsertBinding(
        PlaylistSyncBinding(
          key: key,
          remotePlaylistId: 'remote',
          mode: PlaylistSyncMode.automatic,
          localRevisionAtBase: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await service.setPlaylistArtworkFileName('playlist', fileName);
      final remote = PlaylistSyncSnapshot(
        remotePlaylistId: 'remote',
        title: 'Remote title',
        items: const <PlaylistSyncItem>[],
      );
      await store.commitSynchronized(
        key: key,
        mergedLocal: remote,
        verifiedRemote: remote,
        expectedLocalRevision: playlist.localRevision,
        now: now.add(const Duration(minutes: 1)),
      );
      final merged = (await service.getCatalogPlaylist('playlist'))!.playlist;
      expect(merged.name, 'Remote title');
      expect(merged.customArtworkFileName, fileName);
      expect(merged.localRevision, playlist.localRevision + 1);
    },
  );
}

class _TestDatabase extends LocalDatabaseService {
  _TestDatabase(this.path);

  final String path;

  @override
  Future<String> databasePath() async => path;
}
