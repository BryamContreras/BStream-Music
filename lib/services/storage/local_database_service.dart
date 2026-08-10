import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/constants/app_constants.dart';
import '../../features/music/data/models/local_track_model.dart';
import '../../features/music/data/models/playlist_model.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/playlist.dart';

class LocalDatabaseService {
  Database? _database;
  Future<Database>? _databaseFuture;

  Future<Database> get database async {
    final current = _database;
    if (current != null) {
      return current;
    }
    final pending = _databaseFuture;
    if (pending != null) {
      return pending;
    }

    final opening = _open();
    _databaseFuture = opening;
    try {
      final opened = await opening;
      _database = opened;
      return opened;
    } finally {
      if (identical(_databaseFuture, opening)) {
        _databaseFuture = null;
      }
    }
  }

  Future<void> initialize() async {
    await database;
  }

  Future<String> databasePath() async {
    final supportDirectory = await getApplicationSupportDirectory();
    await supportDirectory.create(recursive: true);
    return p.join(supportDirectory.path, AppConstants.databaseName);
  }

  /// Validates an extracted backup without migrating or mutating it.
  ///
  /// Restore uses this before touching the active library so a truncated,
  /// corrupt, or newer unsupported database can never replace user data.
  Future<void> validateBackupDatabase(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) {
      throw const FormatException(
        'El respaldo no contiene una base de datos valida.',
      );
    }

    _configureDatabaseFactory();
    Database? candidate;
    try {
      candidate = await openDatabase(
        file.path,
        readOnly: true,
        singleInstance: false,
      );

      final integrityRows = await candidate.rawQuery('PRAGMA integrity_check');
      final integrityValues = integrityRows
          .expand((row) => row.values)
          .map((value) => value?.toString().trim().toLowerCase())
          .whereType<String>()
          .toList(growable: false);
      if (integrityValues.isEmpty ||
          integrityValues.any((value) => value != 'ok')) {
        throw const FormatException(
          'La base de datos del respaldo esta corrupta.',
        );
      }

      final versionRows = await candidate.rawQuery('PRAGMA user_version');
      final rawVersion = versionRows.isEmpty
          ? null
          : versionRows.first['user_version'];
      final version = rawVersion is num
          ? rawVersion.toInt()
          : int.tryParse('$rawVersion');
      if (version == null ||
          version <= 0 ||
          version > AppConstants.databaseVersion) {
        throw const FormatException(
          'La version de la base de datos del respaldo no es compatible.',
        );
      }

      final tableRows = await candidate.rawQuery(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name IN (?, ?)",
        const ['local_tracks', 'playlists'],
      );
      final tables = tableRows
          .map((row) => row['name']?.toString())
          .whereType<String>()
          .toSet();
      if (!tables.containsAll(const {'local_tracks', 'playlists'})) {
        throw const FormatException(
          'La base de datos del respaldo no contiene la biblioteca requerida.',
        );
      }
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException(
        'No se pudo validar la base de datos del respaldo.',
        error,
      );
    } finally {
      await candidate?.close();
    }
  }

  Future<void> close() async {
    var current = _database;
    final opening = _databaseFuture;
    if (current == null && opening != null) {
      try {
        current = await opening;
      } catch (_) {
        // There is no open database to close when opening failed.
      }
    }
    if (current == null) {
      return;
    }
    await current.close();
    _database = null;
    _databaseFuture = null;
  }

  Future<List<LocalTrack>> getLocalTracks() async {
    final db = await database;
    final rows = await db.query('local_tracks', orderBy: 'added_at DESC');
    return rows.map(LocalTrackModel.fromMap).toList(growable: false);
  }

  Future<void> saveLocalTrack(LocalTrack track) async {
    final db = await database;
    await db.insert(
      'local_tracks',
      LocalTrackModel.fromEntity(track).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> rewriteLocalTrackMediaRoot({
    required String mediaRoot,
    String? oldMediaRoot,
  }) async {
    final db = await database;
    final audioRoot = p.join(mediaRoot, 'audio');
    final thumbnailsRoot = p.join(mediaRoot, 'thumbnails');
    final oldAudioRoot = oldMediaRoot == null
        ? null
        : p.join(oldMediaRoot, 'audio');
    final oldThumbnailsRoot = oldMediaRoot == null
        ? null
        : p.join(oldMediaRoot, 'thumbnails');

    await db.transaction((transaction) async {
      final rows = await transaction.query('local_tracks');
      final batch = transaction.batch();
      for (final row in rows) {
        final id = row['id']! as String;
        final filePath = row['file_path']! as String;
        final thumbnailPath = row['thumbnail_path'] as String?;
        final nextFilePath = _rewriteMediaPath(
          path: filePath,
          targetRoot: audioRoot,
          oldRoot: oldAudioRoot,
        );
        final nextThumbnailPath = thumbnailPath == null
            ? null
            : _rewriteMediaPath(
                path: thumbnailPath,
                targetRoot: thumbnailsRoot,
                oldRoot: oldThumbnailsRoot,
              );

        if (nextFilePath == filePath && nextThumbnailPath == thumbnailPath) {
          continue;
        }

        batch.update(
          'local_tracks',
          {'file_path': nextFilePath, 'thumbnail_path': nextThumbnailPath},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteLocalTrack(String trackId) async {
    final db = await database;
    await db.delete('local_tracks', where: 'id = ?', whereArgs: [trackId]);
  }

  Future<Set<String>> purgeMissingLocalTracks(List<LocalTrack> tracks) async {
    final candidates = <String, String>{};
    for (final track in tracks) {
      final id = track.id.trim();
      final filePath = track.filePath.trim();
      if (id.isNotEmpty && filePath.isNotEmpty) {
        candidates[id] = filePath;
      }
    }
    if (candidates.isEmpty) {
      return const <String>{};
    }

    final db = await database;
    return db.transaction((transaction) async {
      final removedIds = <String>{};
      for (final candidate in candidates.entries) {
        final removed = await transaction.delete(
          'local_tracks',
          where: 'id = ? AND file_path = ?',
          whereArgs: [candidate.key, candidate.value],
        );
        if (removed > 0) {
          removedIds.add(candidate.key);
        }
      }
      if (removedIds.isEmpty) {
        return const <String>{};
      }

      final playlistRows = await transaction.query('playlists');
      final batch = transaction.batch();
      for (final row in playlistRows) {
        final playlist = PlaylistModel.fromMap(row);
        final remainingTrackIds = playlist.trackIds
            .where((id) => !removedIds.contains(id))
            .toList(growable: false);
        if (remainingTrackIds.length == playlist.trackIds.length) {
          continue;
        }

        final encodedTrackIds = PlaylistModel.fromEntity(
          playlist.copyWith(trackIds: remainingTrackIds),
        ).toMap()['track_ids'];
        batch.update(
          'playlists',
          {'track_ids': encodedTrackIds},
          where: 'id = ?',
          whereArgs: [playlist.id],
        );
      }
      await batch.commit(noResult: true);
      return Set<String>.unmodifiable(removedIds);
    });
  }

  Future<void> markPlayed(
    String trackId,
    DateTime playedAt, {
    String? playlistId,
  }) async {
    final db = await database;
    await db.update(
      'local_tracks',
      {
        'last_played_at': playedAt.toIso8601String(),
        'last_played_playlist_id': playlistId,
      },
      where: 'id = ?',
      whereArgs: [trackId],
    );
  }

  Future<List<LocalTrack>> getHistory() async {
    final db = await database;
    final rows = await db.query(
      'local_tracks',
      where: 'last_played_at IS NOT NULL',
      orderBy: 'last_played_at DESC',
      limit: 50,
    );
    return rows.map(LocalTrackModel.fromMap).toList(growable: false);
  }

  Future<List<Playlist>> getPlaylists() async {
    final db = await database;
    final rows = await db.query('playlists', orderBy: 'updated_at DESC');
    return rows.map(PlaylistModel.fromMap).toList(growable: false);
  }

  Future<void> savePlaylist(Playlist playlist) async {
    final db = await database;
    await db.insert(
      'playlists',
      PlaylistModel.fromEntity(playlist).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deletePlaylist(String playlistId) async {
    final db = await database;
    await db.transaction((transaction) async {
      await transaction.update(
        'local_tracks',
        {'last_played_playlist_id': null},
        where: 'last_played_playlist_id = ?',
        whereArgs: [playlistId],
      );
      await transaction.delete(
        'playlists',
        where: 'id = ?',
        whereArgs: [playlistId],
      );
    });
  }

  Future<Database> _open() async {
    _configureDatabaseFactory();

    final dbPath = await databasePath();

    return openDatabase(
      dbPath,
      version: AppConstants.databaseVersion,
      onCreate: (db, version) async {
        await db.execute('''
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
        await db.execute('''
          CREATE TABLE playlists (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            track_ids TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await _createIndexes(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE local_tracks ADD COLUMN thumbnail_path TEXT',
          );
        }
        if (oldVersion < 3) {
          await _createIndexes(db);
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE local_tracks '
            'ADD COLUMN last_played_playlist_id TEXT',
          );
        }
      },
    );
  }

  void _configureDatabaseFactory() {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<void> _createIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_tracks_added_at '
      'ON local_tracks(added_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_tracks_last_played_at '
      'ON local_tracks(last_played_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_tracks_source_url '
      'ON local_tracks(source_url)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_playlists_updated_at '
      'ON playlists(updated_at)',
    );
  }

  String _rewriteMediaPath({
    required String path,
    required String targetRoot,
    String? oldRoot,
  }) {
    final relative = oldRoot == null
        ? p.basename(path)
        : _relativeIfInside(path: path, root: oldRoot);
    if (relative == null || relative.isEmpty) {
      return path;
    }
    return p.join(targetRoot, relative);
  }

  String? _relativeIfInside({required String path, required String root}) {
    final normalizedPath = File(path).absolute.path;
    final normalizedRoot = Directory(root).absolute.path;
    if (normalizedPath == normalizedRoot) {
      return p.basename(normalizedPath);
    }
    final prefix = '$normalizedRoot${Platform.pathSeparator}';
    if (!normalizedPath.startsWith(prefix)) {
      return null;
    }
    return p.relative(normalizedPath, from: normalizedRoot);
  }
}
