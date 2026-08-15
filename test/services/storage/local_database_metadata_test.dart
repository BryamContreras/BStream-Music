import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('migrates v4 local tracks to v5 metadata columns', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'bstream-metadata-migration-',
    );
    final databasePath = p.join(directory.path, 'library.db');
    final legacyDatabase = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (database, _) async {
          await database.execute('''
            CREATE TABLE local_tracks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              artist TEXT NOT NULL,
              file_path TEXT NOT NULL,
              source_url TEXT,
              thumbnail_url TEXT,
              thumbnail_path TEXT,
              duration_seconds INTEGER,
              added_at TEXT NOT NULL,
              last_played_at TEXT,
              last_played_playlist_id TEXT
            )
          ''');
          await database.execute('''
            CREATE TABLE playlists (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              track_ids TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacyDatabase.insert('local_tracks', {
      'id': 'legacy-track',
      'title': 'Legacy track',
      'artist': 'Legacy artist',
      'file_path': p.join(directory.path, 'legacy.m4a'),
      'source_url': 'https://www.youtube.com/watch?v=legacy12345',
      'added_at': DateTime.utc(2025).toIso8601String(),
    });
    await legacyDatabase.close();

    final service = _TestLocalDatabaseService(databasePath);
    addTearDown(() async {
      await service.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final database = await service.database;
    final versionRows = await database.rawQuery('PRAGMA user_version');
    expect(versionRows.single['user_version'], AppConstants.databaseVersion);
    expect(AppConstants.databaseVersion, 5);

    final tableInfo = await database.rawQuery(
      'PRAGMA table_info(local_tracks)',
    );
    final columnNames = tableInfo
        .map((column) => column['name'])
        .whereType<String>()
        .toSet();
    expect(
      columnNames,
      containsAll(const {
        'album',
        'artists_json',
        'metadata_source',
        'source_id',
        'catalog_thumbnail_url',
      }),
    );

    final migratedTrack = (await service.getLocalTracks()).single;
    expect(migratedTrack.album, isNull);
    expect(migratedTrack.artists, const ['Legacy artist']);
    expect(migratedTrack.metadataSource, TrackMetadataSource.youtube);
    expect(migratedTrack.sourceId, isNull);
    expect(migratedTrack.catalogThumbnailUrl, isNull);

    final downloadedTrack = LocalTrack(
      id: 'new-track',
      title: 'New track',
      artist: 'Artist One, Artist Two',
      artists: const ['Artist One', 'Artist Two'],
      album: 'InnerTube album',
      filePath: p.join(directory.path, 'new-track.m4a'),
      addedAt: DateTime.utc(2026, 8, 13),
      sourceUrl: 'https://www.youtube.com/watch?v=abcdefghijk',
      sourceId: 'abcdefghijk',
      thumbnailUrl: 'https://i.ytimg.com/vi/abcdefghijk/hq720.jpg',
      catalogThumbnailUrl: 'https://example.com/innertube.jpg',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    await service.saveLocalTrack(downloadedTrack);

    final savedRows = await database.query(
      'local_tracks',
      where: 'id = ?',
      whereArgs: const ['new-track'],
    );
    final savedRow = savedRows.single;
    expect(savedRow['album'], 'InnerTube album');
    expect(jsonDecode(savedRow['artists_json']! as String), const [
      'Artist One',
      'Artist Two',
    ]);
    expect(savedRow['metadata_source'], TrackMetadataSource.youtubeMusic.name);
    expect(savedRow['source_id'], 'abcdefghijk');
    expect(
      savedRow['catalog_thumbnail_url'],
      'https://example.com/innertube.jpg',
    );
  });

  test('migrates a v1 database before creating v5 indexes', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp(
      'bstream-v1-metadata-migration-',
    );
    final databasePath = p.join(directory.path, 'library.db');
    final legacyDatabase = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, _) async {
          await database.execute('''
            CREATE TABLE local_tracks (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              artist TEXT NOT NULL,
              file_path TEXT NOT NULL,
              source_url TEXT,
              thumbnail_url TEXT,
              duration_seconds INTEGER,
              added_at TEXT NOT NULL,
              last_played_at TEXT
            )
          ''');
          await database.execute('''
            CREATE TABLE playlists (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              track_ids TEXT NOT NULL,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
        },
      ),
    );
    await legacyDatabase.insert('local_tracks', {
      'id': 'v1-track',
      'title': 'Very old track',
      'artist': 'Legacy artist',
      'file_path': p.join(directory.path, 'legacy.m4a'),
      'added_at': DateTime.utc(2020).toIso8601String(),
    });
    await legacyDatabase.close();

    final service = _TestLocalDatabaseService(databasePath);
    addTearDown(() async {
      await service.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });

    final database = await service.database;
    final indexes = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    );
    expect(
      indexes.map((row) => row['name']),
      contains('idx_local_tracks_source_id'),
    );
    final migrated = (await service.getLocalTracks()).single;
    expect(migrated.id, 'v1-track');
    expect(migrated.artists, const ['Legacy artist']);
    expect(migrated.metadataSource, TrackMetadataSource.youtube);
  });
}

class _TestLocalDatabaseService extends LocalDatabaseService {
  _TestLocalDatabaseService(this.path);

  final String path;

  @override
  Future<String> databasePath() async => path;
}
