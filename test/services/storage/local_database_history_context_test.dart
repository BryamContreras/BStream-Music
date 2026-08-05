import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'v3 history migrates without context and persists or clears playlist IDs',
    () async {
      sqfliteFfiInit();
      final directory = await Directory.systemTemp.createTemp(
        'bstream-history-context-',
      );
      final databasePath = p.join(directory.path, 'library.db');
      final legacyDatabase = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 3,
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
        'id': 'legacy-track',
        'title': 'Legacy track',
        'artist': 'BStream Music',
        'file_path': p.join(directory.path, 'legacy.m4a'),
        'added_at': DateTime.utc(2026).toIso8601String(),
        'last_played_at': DateTime.utc(2026, 8, 3).toIso8601String(),
      });
      await legacyDatabase.close();

      final service = _TestLocalDatabaseService(databasePath);
      addTearDown(() async {
        await service.close();
        await directory.delete(recursive: true);
      });

      final migratedHistory = await service.getHistory();
      expect(migratedHistory.single.lastPlayedPlaylistId, isNull);

      const playlistId = 'playlist-1';
      await service.savePlaylist(
        Playlist(
          id: playlistId,
          name: 'Playlist',
          trackIds: const ['legacy-track'],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      );
      await service.markPlayed(
        'legacy-track',
        DateTime.utc(2026, 8, 4),
        playlistId: playlistId,
      );
      expect(
        (await service.getHistory()).single.lastPlayedPlaylistId,
        playlistId,
      );

      await service.deletePlaylist(playlistId);
      expect((await service.getHistory()).single.lastPlayedPlaylistId, isNull);
      expect(await service.getPlaylists(), isEmpty);

      await service.markPlayed(
        'legacy-track',
        DateTime.utc(2026, 8, 5),
        playlistId: playlistId,
      );
      await service.markPlayed('legacy-track', DateTime.utc(2026, 8, 6));
      expect((await service.getHistory()).single.lastPlayedPlaylistId, isNull);
    },
  );
}

class _TestLocalDatabaseService extends LocalDatabaseService {
  _TestLocalDatabaseService(this.path);

  final String path;

  @override
  Future<String> databasePath() async => path;
}
