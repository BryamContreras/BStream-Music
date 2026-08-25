import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/constants/app_constants.dart';
import '../../features/music/data/models/local_track_model.dart';
import '../../features/music/data/models/playlist_model.dart';
import '../../features/music/domain/entities/catalog_playlist.dart';
import '../../features/music/domain/entities/catalog_track.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/playlist.dart';
import '../../features/music/domain/entities/playlist_entry.dart';
import '../../features/music/domain/repositories/catalog_playlist_repository.dart';
import '../recommendations/recommendation_storage_models.dart';
import '../sharing/bstream_track_link.dart';

class PlaybackEventRetentionPolicy {
  const PlaybackEventRetentionPolicy({
    this.maxAge = const Duration(days: 365),
    this.maxEvents = 20000,
    this.relatedCandidateMaxAge = const Duration(days: 7),
    this.pruneEveryWrites = 50,
  }) : assert(maxEvents == null || maxEvents >= 0),
       assert(pruneEveryWrites > 0);

  final Duration? maxAge;
  final int? maxEvents;
  final Duration? relatedCandidateMaxAge;
  final int pruneEveryWrites;
}

class PlaybackEventPruneResult {
  const PlaybackEventPruneResult({
    required this.removedByAge,
    required this.removedByCount,
    this.removedRelatedCandidates = 0,
  });

  final int removedByAge;
  final int removedByCount;
  final int removedRelatedCandidates;

  int get totalRemoved =>
      removedByAge + removedByCount + removedRelatedCandidates;
}

class LocalTrackMediaPathSnapshot {
  const LocalTrackMediaPathSnapshot({
    required this.id,
    required this.originalFilePath,
    required this.rewrittenFilePath,
    required this.originalThumbnailPath,
    required this.rewrittenThumbnailPath,
  });

  final String id;
  final String originalFilePath;
  final String rewrittenFilePath;
  final String? originalThumbnailPath;
  final String? rewrittenThumbnailPath;
}

class LocalTrackMediaRootRewrite {
  LocalTrackMediaRootRewrite(Iterable<LocalTrackMediaPathSnapshot> rows)
    : rows = List<LocalTrackMediaPathSnapshot>.unmodifiable(rows);

  final List<LocalTrackMediaPathSnapshot> rows;

  bool get isEmpty => rows.isEmpty;
}

class _DatabaseIndexDefinition {
  const _DatabaseIndexDefinition({
    required this.name,
    required this.table,
    required this.columns,
    required this.descending,
  });

  final String name;
  final String table;
  final List<String> columns;
  final List<bool> descending;
}

const _requiredDatabaseIndexes = <_DatabaseIndexDefinition>[
  _DatabaseIndexDefinition(
    name: 'idx_local_tracks_added_at',
    table: 'local_tracks',
    columns: <String>['added_at'],
    descending: <bool>[false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_local_tracks_last_played_at',
    table: 'local_tracks',
    columns: <String>['last_played_at'],
    descending: <bool>[false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_local_tracks_source_url',
    table: 'local_tracks',
    columns: <String>['source_url'],
    descending: <bool>[false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_local_tracks_source_id',
    table: 'local_tracks',
    columns: <String>['source_id'],
    descending: <bool>[false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_local_tracks_catalog_key',
    table: 'local_tracks',
    columns: <String>['catalog_key'],
    descending: <bool>[false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_playlists_updated_at',
    table: 'playlists',
    columns: <String>['updated_at'],
    descending: <bool>[false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_playback_events_track_played_session',
    table: 'playback_events',
    columns: <String>['track_key', 'played_at', 'session_id'],
    descending: <bool>[false, true, true],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_playback_events_played_session',
    table: 'playback_events',
    columns: <String>['played_at', 'session_id'],
    descending: <bool>[true, true],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_related_candidates_seed_fetched_rank',
    table: 'related_track_candidates',
    columns: <String>['seed_key', 'fetched_at', 'rank'],
    descending: <bool>[false, false, false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_related_candidates_fetched_at',
    table: 'related_track_candidates',
    columns: <String>['fetched_at'],
    descending: <bool>[false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_recommendation_feed_expires_at',
    table: 'recommendation_feed_cache',
    columns: <String>['expires_at'],
    descending: <bool>[false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_catalog_tracks_provider_id',
    table: 'catalog_tracks',
    columns: <String>['provider', 'provider_id'],
    descending: <bool>[false, false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_playlist_items_playlist_position',
    table: 'playlist_items',
    columns: <String>['playlist_id', 'position', 'item_id'],
    descending: <bool>[false, false, false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_playlist_items_catalog_key',
    table: 'playlist_items',
    columns: <String>['catalog_key'],
    descending: <bool>[false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_ytm_playlist_bindings_remote',
    table: 'ytm_playlist_bindings',
    columns: <String>['account_key', 'remote_playlist_id'],
    descending: <bool>[false, false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_playlist_sync_intents_due',
    table: 'playlist_sync_intents',
    columns: <String>['status', 'next_attempt_at'],
    descending: <bool>[false, false],
  ),
  _DatabaseIndexDefinition(
    name: 'idx_playlist_sync_conflicts_open',
    table: 'playlist_sync_conflicts',
    columns: <String>['account_key', 'playlist_id', 'resolved_at'],
    descending: <bool>[false, false, false],
  ),
];

class LocalDatabaseService {
  LocalDatabaseService({
    this.playbackEventRetentionPolicy = const PlaybackEventRetentionPolicy(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PlaybackEventRetentionPolicy playbackEventRetentionPolicy;
  final DateTime Function() _clock;
  Database? _database;
  Future<Database>? _databaseFuture;
  Future<PlaybackEventPruneResult>? _automaticPruneFuture;
  int _newEventsSinceAutomaticPrune = 0;
  bool _hasRunAutomaticPrune = false;
  int _recommendationGeneration = 0;
  bool _disposed = false;

  /// In-memory epoch used to reject recommendation refreshes that started
  /// before the user cleared personalization data.
  int get recommendationGeneration => _recommendationGeneration;

  /// Invalidates recommendation work that captured the current database
  /// contents before an external replacement such as backup restore.
  void advanceRecommendationGeneration() {
    _recommendationGeneration += 1;
  }

  Future<Database> get database async {
    if (_disposed) {
      throw StateError('LocalDatabaseService has been disposed.');
    }
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

  Future<T> withDatabase<T>(Future<T> Function(Database) operation) async {
    final db = await database;
    return operation(db);
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
        'El respaldo no contiene una base de datos válida.',
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
          'La versión de la base de datos del respaldo no es compatible.',
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
      await _validateSchemaForVersion(candidate, version);
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

  /// Permanently closes this service at application/provider shutdown.
  ///
  /// [close] intentionally remains reopenable because backup restore uses it
  /// while replacing the active database. A disposed provider, however, must
  /// never be reopened by a late asynchronous continuation.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await close();
  }

  Future<List<LocalTrack>> getLocalTracks() async {
    final db = await database;
    final rows = await db.query('local_tracks', orderBy: 'added_at DESC');
    return rows.map(LocalTrackModel.fromMap).toList(growable: false);
  }

  Future<void> saveLocalTrack(LocalTrack track) async {
    if (track.isExternal) {
      throw ArgumentError.value(
        track.id,
        'track',
        'External device audio is transient and cannot be persisted in the '
            'BStream library.',
      );
    }
    final db = await database;
    await _upsertWithoutDelete(
      db,
      table: 'local_tracks',
      primaryKey: 'id',
      values: LocalTrackModel.fromEntity(track).toMap(),
    );
  }

  Future<void> rewriteLocalTrackMediaRoot({
    required String mediaRoot,
    String? oldMediaRoot,
  }) async {
    await rewriteLocalTrackMediaRootWithSnapshot(
      mediaRoot: mediaRoot,
      oldMediaRoot: oldMediaRoot,
    );
  }

  /// Rewrites paths atomically and returns the exact rows changed.
  ///
  /// Directory migration uses the returned snapshot for rollback. This avoids
  /// a broad reverse rewrite that could modify tracks which already belonged
  /// to the destination before the operation began.
  Future<LocalTrackMediaRootRewrite> rewriteLocalTrackMediaRootWithSnapshot({
    required String mediaRoot,
    String? oldMediaRoot,
    String? canonicalOldMediaRoot,
  }) async {
    final db = await database;
    final audioRoot = p.join(mediaRoot, 'audio');
    final thumbnailsRoot = p.join(mediaRoot, 'thumbnails');
    final oldAudioRoots = oldMediaRoot == null
        ? null
        : _uniquePathRoots(<String>[
            p.join(oldMediaRoot, 'audio'),
            if (canonicalOldMediaRoot != null)
              p.join(canonicalOldMediaRoot, 'audio'),
          ]);
    final oldThumbnailRoots = oldMediaRoot == null
        ? null
        : _uniquePathRoots(<String>[
            p.join(oldMediaRoot, 'thumbnails'),
            if (canonicalOldMediaRoot != null)
              p.join(canonicalOldMediaRoot, 'thumbnails'),
          ]);

    return db.transaction((transaction) async {
      final rows = await transaction.query('local_tracks');
      final batch = transaction.batch();
      final changedRows = <LocalTrackMediaPathSnapshot>[];
      for (final row in rows) {
        final id = row['id']! as String;
        final filePath = row['file_path']! as String;
        final thumbnailPath = row['thumbnail_path'] as String?;
        final nextFilePath = _rewriteMediaPath(
          path: filePath,
          targetRoot: audioRoot,
          oldRoots: oldAudioRoots,
        );
        final nextThumbnailPath = thumbnailPath == null
            ? null
            : _rewriteMediaPath(
                path: thumbnailPath,
                targetRoot: thumbnailsRoot,
                oldRoots: oldThumbnailRoots,
              );

        if (nextFilePath == filePath && nextThumbnailPath == thumbnailPath) {
          continue;
        }

        changedRows.add(
          LocalTrackMediaPathSnapshot(
            id: id,
            originalFilePath: filePath,
            rewrittenFilePath: nextFilePath,
            originalThumbnailPath: thumbnailPath,
            rewrittenThumbnailPath: nextThumbnailPath,
          ),
        );

        batch.update(
          'local_tracks',
          {'file_path': nextFilePath, 'thumbnail_path': nextThumbnailPath},
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
      return LocalTrackMediaRootRewrite(changedRows);
    });
  }

  Future<void> restoreLocalTrackMediaPaths(
    LocalTrackMediaRootRewrite rewrite,
  ) async {
    if (rewrite.isEmpty) {
      return;
    }
    final db = await database;
    await db.transaction((transaction) async {
      for (final row in rewrite.rows) {
        final rewrittenThumbnail = row.rewrittenThumbnailPath;
        final restored = await transaction.update(
          'local_tracks',
          <String, Object?>{
            'file_path': row.originalFilePath,
            'thumbnail_path': row.originalThumbnailPath,
          },
          where: rewrittenThumbnail == null
              ? 'id = ? AND file_path = ? AND thumbnail_path IS NULL'
              : 'id = ? AND file_path = ? AND thumbnail_path = ?',
          whereArgs: rewrittenThumbnail == null
              ? <Object?>[row.id, row.rewrittenFilePath]
              : <Object?>[row.id, row.rewrittenFilePath, rewrittenThumbnail],
        );
        if (restored != 1) {
          throw StateError(
            'No se pudo restaurar la ruta de medios de ${row.id}.',
          );
        }
      }
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

      // Download removal must never erase catalog playlist membership. A
      // surviving catalog entry simply falls back to streaming next time.
      final placeholders = List.filled(removedIds.length, '?').join(', ');
      await transaction.rawUpdate(
        'UPDATE playlist_items SET local_track_id = NULL '
        'WHERE local_track_id IN ($placeholders)',
        removedIds.toList(growable: false),
      );

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

  /// Inserts or updates one player session without counting it twice.
  ///
  /// The player can persist the same [PlaybackEvent.sessionId] when it crosses
  /// the listening threshold and again when playback completes. The greatest
  /// listened duration and completion state win, while newer metadata enriches
  /// the existing row.
  Future<void> recordPlaybackEvent(PlaybackEvent event) async {
    final sessionId = _requiredText(event.sessionId, 'sessionId');
    final trackId = _requiredText(event.trackId, 'trackId');
    final title = _requiredText(event.title, 'title');
    final videoId = _optionalText(event.videoId);
    if (event.listenedMs < 0) {
      throw ArgumentError.value(
        event.listenedMs,
        'listenedMs',
        'Must not be negative.',
      );
    }
    final durationMs = event.durationMs;
    if (durationMs != null && durationMs < 0) {
      throw ArgumentError.value(
        durationMs,
        'durationMs',
        'Must not be negative.',
      );
    }

    final trackKey = recommendationTrackKey(videoId: videoId, trackId: trackId);
    final values = <Object?>[
      sessionId,
      trackKey,
      trackId,
      videoId,
      title,
      jsonEncode(_normalizedStrings(event.artists)),
      jsonEncode(_normalizedArtistBrowseIds(event.artistBrowseIds)),
      _optionalText(event.album),
      _optionalText(event.thumbnailUrl),
      durationMs,
      event.source.name,
      event.startedAt.toUtc().toIso8601String(),
      event.playedAt.toUtc().toIso8601String(),
      event.listenedMs,
      event.completed ? 1 : 0,
      _nullableBoolToInt(event.isFavorite),
      _nullableBoolToInt(event.isLiked),
    ];

    final db = await database;
    final inserted = await db.transaction((transaction) async {
      final existing = await transaction.query(
        'playback_events',
        columns: const <String>['session_id'],
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
        limit: 1,
      );
      if (existing.isEmpty) {
        // Advance inside the same serialized database transaction as the new
        // event. A recommendation refresh that started from the previous
        // history revision can no longer overwrite the feed after this play.
        _recommendationGeneration += 1;
      }
      await transaction.rawInsert('''
      INSERT INTO playback_events (
        session_id,
        track_key,
        track_id,
        video_id,
        title,
        artists_json,
        artist_browse_ids_json,
        album,
        thumbnail_url,
        duration_ms,
        source,
        started_at,
        played_at,
        listened_ms,
        completed,
        is_favorite,
        is_liked
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        track_key = COALESCE(
          excluded.video_id,
          playback_events.video_id,
          excluded.track_key
        ),
        track_id = excluded.track_id,
        video_id = COALESCE(excluded.video_id, playback_events.video_id),
        title = excluded.title,
        artists_json = excluded.artists_json,
        artist_browse_ids_json = excluded.artist_browse_ids_json,
        album = COALESCE(excluded.album, playback_events.album),
        thumbnail_url = COALESCE(
          excluded.thumbnail_url,
          playback_events.thumbnail_url
        ),
        duration_ms = COALESCE(excluded.duration_ms, playback_events.duration_ms),
        source = excluded.source,
        started_at = MIN(playback_events.started_at, excluded.started_at),
        played_at = MAX(playback_events.played_at, excluded.played_at),
        listened_ms = MAX(playback_events.listened_ms, excluded.listened_ms),
        completed = MAX(playback_events.completed, excluded.completed),
        is_favorite = COALESCE(
          excluded.is_favorite,
          playback_events.is_favorite
        ),
        is_liked = COALESCE(excluded.is_liked, playback_events.is_liked)
      ''', values);
      return existing.isEmpty;
    });
    await _prunePlaybackEventsIfDue(inserted: inserted);
  }

  Future<List<RecommendationSeed>> getTopRecommendationSeeds({
    int limit = 20,
    DateTime? since,
    int minListenedMs = 30000,
  }) async {
    return _recommendationSeeds(
      since: since,
      minListenedMs: minListenedMs,
      limit: limit,
      order: _RecommendationSeedOrder.top,
    );
  }

  Future<List<RecommendationSeed>> getRecentRecommendationSeeds({
    int limit = 20,
    DateTime? since,
    int minListenedMs = 30000,
  }) async {
    return _recommendationSeeds(
      since: since,
      minListenedMs: minListenedMs,
      limit: limit,
      order: _RecommendationSeedOrder.recent,
    );
  }

  /// Applies the configured age/count budget only to recommendation events.
  /// Downloaded tracks, favorites and user playlists live in separate tables
  /// and are intentionally not part of either delete statement.
  Future<PlaybackEventPruneResult> prunePlaybackEvents({
    PlaybackEventRetentionPolicy? policy,
    DateTime? now,
  }) async {
    final effectivePolicy = policy ?? playbackEventRetentionPolicy;
    _validateRetentionPolicy(effectivePolicy);
    final effectiveNow = (now ?? _clock()).toUtc();
    final db = await database;
    return db.transaction((transaction) async {
      var removedByAge = 0;
      final maxAge = effectivePolicy.maxAge;
      if (maxAge != null) {
        final cutoff = effectiveNow.subtract(maxAge).toIso8601String();
        removedByAge = await transaction.delete(
          'playback_events',
          where: 'played_at < ?',
          whereArgs: <Object?>[cutoff],
        );
      }

      var removedByCount = 0;
      final maxEvents = effectivePolicy.maxEvents;
      if (maxEvents != null) {
        removedByCount = await transaction.rawDelete(
          '''
          DELETE FROM playback_events
          WHERE session_id IN (
            SELECT session_id
            FROM playback_events
            ORDER BY played_at DESC, session_id DESC
            LIMIT -1 OFFSET ?
          )
          ''',
          <Object?>[maxEvents],
        );
      }

      var removedRelatedCandidates = 0;
      final relatedMaxAge = effectivePolicy.relatedCandidateMaxAge;
      if (relatedMaxAge != null) {
        removedRelatedCandidates += await transaction.delete(
          'related_track_candidates',
          where: 'fetched_at < ?',
          whereArgs: <Object?>[
            effectiveNow.subtract(relatedMaxAge).toIso8601String(),
          ],
        );
      }
      removedRelatedCandidates += await transaction.rawDelete('''
        DELETE FROM related_track_candidates
        WHERE NOT EXISTS (
          SELECT 1
          FROM playback_events
          WHERE playback_events.track_key = related_track_candidates.seed_key
        )
      ''');
      final result = PlaybackEventPruneResult(
        removedByAge: removedByAge,
        removedByCount: removedByCount,
        removedRelatedCandidates: removedRelatedCandidates,
      );
      final historyRows = await transaction.rawQuery(
        'SELECT EXISTS(SELECT 1 FROM playback_events LIMIT 1) AS has_history',
      );
      final hasHistory =
          (_nullableInt(historyRows.single['has_history']) ?? 0) != 0;
      final removedFeeds = hasHistory
          ? 0
          : await transaction.delete('recommendation_feed_cache');

      // Advance the epoch before the transaction releases SQLite's write
      // lock. A cache writer queued behind this prune must observe the new
      // generation and cannot republish a feed built from deleted history.
      if (result.totalRemoved > 0 || removedFeeds > 0) {
        _recommendationGeneration += 1;
      }
      return result;
    });
  }

  /// Replaces the cached snapshot for [seedKey] atomically.
  Future<bool> upsertRelatedCandidates({
    required String seedKey,
    required List<RelatedTrackCandidate> candidates,
    DateTime? fetchedAt,
    int? expectedGeneration,
  }) async {
    final normalizedSeedKey = _requiredText(seedKey, 'seedKey');
    final normalizedFetchedAt = (fetchedAt ?? DateTime.now())
        .toUtc()
        .toIso8601String();
    final uniqueCandidates = <String, RelatedTrackCandidate>{};
    for (final candidate in candidates) {
      if (candidate.rank < 0) {
        throw ArgumentError.value(
          candidate.rank,
          'candidate.rank',
          'Must not be negative.',
        );
      }
      if (candidate.durationMs != null && candidate.durationMs! < 0) {
        throw ArgumentError.value(
          candidate.durationMs,
          'candidate.durationMs',
          'Must not be negative.',
        );
      }
      _requiredText(candidate.trackId, 'candidate.trackId');
      _requiredText(candidate.title, 'candidate.title');
      final current = uniqueCandidates[candidate.trackKey];
      if (current == null || candidate.rank < current.rank) {
        uniqueCandidates[candidate.trackKey] = candidate;
      }
    }

    final db = await database;
    return db.transaction((transaction) async {
      if (expectedGeneration != null &&
          _recommendationGeneration != expectedGeneration) {
        return false;
      }
      await transaction.delete(
        'related_track_candidates',
        where: 'seed_key = ?',
        whereArgs: <Object?>[normalizedSeedKey],
      );
      final batch = transaction.batch();
      for (final candidate in uniqueCandidates.values) {
        batch.insert('related_track_candidates', <String, Object?>{
          'seed_key': normalizedSeedKey,
          'candidate_key': candidate.trackKey,
          'track_id': candidate.trackId.trim(),
          'video_id': _optionalText(candidate.videoId),
          'title': candidate.title.trim(),
          'artists_json': jsonEncode(_normalizedStrings(candidate.artists)),
          'artist_browse_ids_json': jsonEncode(
            _normalizedArtistBrowseIds(candidate.artistBrowseIds),
          ),
          'album': _optionalText(candidate.album),
          'thumbnail_url': _optionalText(candidate.thumbnailUrl),
          'duration_ms': candidate.durationMs,
          'rank': candidate.rank,
          'fetched_at': normalizedFetchedAt,
        });
      }
      await batch.commit(noResult: true);
      return true;
    });
  }

  Future<List<RelatedTrackCandidate>> getRelatedCandidates(
    String seedKey, {
    Duration ttl = const Duration(days: 7),
    DateTime? now,
  }) async {
    final normalizedSeedKey = _requiredText(seedKey, 'seedKey');
    if (ttl.isNegative) {
      throw ArgumentError.value(ttl, 'ttl', 'Must not be negative.');
    }
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(ttl);
    final db = await database;
    final rows = await db.query(
      'related_track_candidates',
      where: 'seed_key = ? AND fetched_at > ?',
      whereArgs: <Object?>[normalizedSeedKey, cutoff.toIso8601String()],
      orderBy: 'rank ASC, candidate_key ASC',
    );
    return List<RelatedTrackCandidate>.unmodifiable(
      rows.map(_relatedCandidateFromRow),
    );
  }

  Future<bool> saveRecommendationFeed(
    RecommendationFeedCache feed, {
    int? expectedGeneration,
  }) async {
    final feedKey = _requiredText(feed.feedKey, 'feedKey');
    final generatedAt = feed.generatedAt.toUtc();
    final expiresAt = feed.expiresAt.toUtc();
    if (expiresAt.isBefore(generatedAt)) {
      throw ArgumentError.value(
        feed.expiresAt,
        'expiresAt',
        'Must not precede generatedAt.',
      );
    }

    // Encoding here validates that the payload is composed only of durable
    // JSON values before the previous cache entry is replaced.
    final payloadJson = jsonEncode(feed.payload);
    final db = await database;
    return db.transaction((transaction) async {
      if (expectedGeneration != null &&
          _recommendationGeneration != expectedGeneration) {
        return false;
      }
      await transaction.insert('recommendation_feed_cache', <String, Object?>{
        'feed_key': feedKey,
        'payload_json': payloadJson,
        'generated_at': generatedAt.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  }

  /// Loads the last feed even if expired so startup can render stale content
  /// while a background refresh runs. Call [RecommendationFeedCache.isExpiredAt]
  /// to decide whether to refresh it.
  Future<RecommendationFeedCache?> loadRecommendationFeed(
    String feedKey,
  ) async {
    final normalizedFeedKey = _requiredText(feedKey, 'feedKey');
    final db = await database;
    final rows = await db.query(
      'recommendation_feed_cache',
      where: 'feed_key = ?',
      whereArgs: <Object?>[normalizedFeedKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.single;
    try {
      final decoded = jsonDecode(row['payload_json']! as String);
      if (decoded is! Map) {
        return null;
      }
      return RecommendationFeedCache(
        feedKey: row['feed_key']! as String,
        payload: decoded.map<String, Object?>(
          (key, value) => MapEntry(key.toString(), value),
        ),
        generatedAt: DateTime.parse(row['generated_at']! as String),
        expiresAt: DateTime.parse(row['expires_at']! as String),
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Removes one cached recommendation feed only if its history epoch is
  /// still current.
  Future<bool> deleteRecommendationFeed(
    String feedKey, {
    int? expectedGeneration,
  }) async {
    final normalizedFeedKey = _requiredText(feedKey, 'feedKey');
    final db = await database;
    return db.transaction((transaction) async {
      if (expectedGeneration != null &&
          _recommendationGeneration != expectedGeneration) {
        return false;
      }
      await transaction.delete(
        'recommendation_feed_cache',
        where: 'feed_key = ?',
        whereArgs: <Object?>[normalizedFeedKey],
      );
      return true;
    });
  }

  /// Clears personalization data without touching downloads or playlists.
  Future<void> clearRecommendationHistory() async {
    // Advance before the first await so every in-flight network refresh sees
    // the new epoch before it can publish a late cache write.
    advanceRecommendationGeneration();
    final db = await database;
    await db.transaction((transaction) async {
      await transaction.delete('playback_events');
      await transaction.delete('related_track_candidates');
      await transaction.delete('recommendation_feed_cache');
      await transaction.update('local_tracks', <String, Object?>{
        'last_played_at': null,
        'last_played_playlist_id': null,
      });
    });
  }

  Future<List<Playlist>> getCatalogPlaylists({
    bool includeDeleted = false,
  }) async {
    final db = await database;
    final rows = await db.query(
      'playlists',
      where: includeDeleted ? null : 'deleted_at IS NULL',
      orderBy: 'updated_at DESC',
    );
    return rows.map(PlaylistModel.fromMap).toList(growable: false);
  }

  Future<CatalogPlaylist?> getCatalogPlaylist(
    String playlistId, {
    bool includeDeletedEntries = false,
  }) async {
    final db = await database;
    final playlistRows = await db.query(
      'playlists',
      where: 'id = ?',
      whereArgs: <Object?>[playlistId],
      limit: 1,
    );
    if (playlistRows.isEmpty) {
      return null;
    }
    final entryRows = await db.rawQuery(
      '''
        SELECT pi.*, ct.*
        FROM playlist_items AS pi
        INNER JOIN catalog_tracks AS ct
          ON ct.track_key = pi.catalog_key
        WHERE pi.playlist_id = ?
          ${includeDeletedEntries ? '' : 'AND pi.deleted_at IS NULL'}
        ORDER BY pi.position ASC, pi.item_id ASC
      ''',
      <Object?>[playlistId],
    );
    return CatalogPlaylist(
      playlist: PlaylistModel.fromMap(playlistRows.single),
      entries: entryRows.map(_playlistEntryFromRow),
    );
  }

  Future<PlaylistEntry?> getCatalogPlaylistEntry(
    String entryId, {
    bool includeDeleted = false,
  }) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
        SELECT pi.*, ct.*
        FROM playlist_items AS pi
        INNER JOIN catalog_tracks AS ct
          ON ct.track_key = pi.catalog_key
        WHERE pi.item_id = ?
          ${includeDeleted ? '' : 'AND pi.deleted_at IS NULL'}
        LIMIT 1
      ''',
      <Object?>[entryId],
    );
    return rows.isEmpty ? null : _playlistEntryFromRow(rows.single);
  }

  /// Resolves metadata without network access. Supplying [catalogKey] is the
  /// most precise route; [videoId] and [localTrackId] are convenience bridges
  /// for the existing player and download library.
  Future<CatalogTrack?> resolveCatalogTrack({
    String? catalogKey,
    String? videoId,
    String? localTrackId,
  }) async {
    final normalizedKey = _optionalText(catalogKey);
    final normalizedVideoId = _optionalText(videoId);
    final normalizedLocalId = _optionalText(localTrackId);
    if (normalizedKey == null &&
        normalizedVideoId == null &&
        normalizedLocalId == null) {
      throw ArgumentError('At least one catalog identity is required.');
    }
    final db = await database;
    final rows = normalizedKey != null
        ? await db.query(
            'catalog_tracks',
            where: 'track_key = ?',
            whereArgs: <Object?>[normalizedKey],
            limit: 1,
          )
        : normalizedVideoId != null
        ? await db.query(
            'catalog_tracks',
            where: "provider = 'youtube' AND provider_id = ?",
            whereArgs: <Object?>[normalizedVideoId],
            limit: 1,
          )
        : await db.rawQuery(
            '''
              SELECT ct.*
              FROM local_tracks AS lt
              INNER JOIN catalog_tracks AS ct
                ON ct.track_key = lt.catalog_key
              WHERE lt.id = ?
              LIMIT 1
            ''',
            <Object?>[normalizedLocalId],
          );
    return rows.isEmpty ? null : _catalogTrackFromRow(rows.single);
  }

  /// Links an existing download to every occurrence of the same YouTube video
  /// without changing playlist membership or order. Returns the number of
  /// occurrences whose local-first resolution changed.
  Future<int> linkCatalogDownload({
    required String videoId,
    required String localTrackId,
    DateTime? now,
  }) async {
    final normalizedVideoId = _requiredText(videoId, 'videoId');
    if (_canonicalYouTubeVideoId(normalizedVideoId) == null) {
      throw ArgumentError.value(
        videoId,
        'videoId',
        'Invalid YouTube video ID.',
      );
    }
    final normalizedLocalId = _requiredText(localTrackId, 'localTrackId');
    final timestamp = now ?? _clock();
    final db = await database;
    return db.transaction((transaction) async {
      final localRows = await transaction.query(
        'local_tracks',
        where: 'id = ?',
        whereArgs: <Object?>[normalizedLocalId],
        limit: 1,
      );
      if (localRows.isEmpty) {
        throw StateError('Local track $normalizedLocalId does not exist.');
      }
      final local = localRows.single;
      final durationSeconds = _nullableInt(local['duration_seconds']);
      final track = CatalogTrack.youtube(
        videoId: normalizedVideoId,
        title: local['title']?.toString() ?? '',
        artists: _decodeStringList(local['artists_json']),
        artistBrowseIds: _decodeNullableStringList(
          local['artist_browse_ids_json'],
        ),
        album: local['album']?.toString(),
        duration: durationSeconds == null
            ? null
            : Duration(seconds: durationSeconds),
        thumbnailUrl:
            local['catalog_thumbnail_url']?.toString() ??
            local['thumbnail_url']?.toString(),
        sourceUrl: local['source_url']?.toString(),
      );
      await _upsertCatalogTrack(transaction, track, timestamp);
      await transaction.update(
        'local_tracks',
        <String, Object?>{
          'catalog_key': track.key,
          'source_id': normalizedVideoId,
        },
        where: 'id = ?',
        whereArgs: <Object?>[normalizedLocalId],
      );
      final changedRows = await transaction.rawQuery(
        '''
          SELECT item_id, playlist_id
          FROM playlist_items
          WHERE deleted_at IS NULL AND (
            (
              (remote_video_id = ? OR catalog_key = ?)
              AND (local_track_id IS NULL OR local_track_id <> ?)
            ) OR (
              local_track_id = ? AND catalog_key <> ?
            )
          )
        ''',
        <Object?>[
          normalizedVideoId,
          track.key,
          normalizedLocalId,
          normalizedLocalId,
          track.key,
        ],
      );
      if (changedRows.isEmpty) {
        return 0;
      }
      await transaction.update(
        'playlist_items',
        <String, Object?>{
          'local_track_id': null,
          'updated_at': timestamp.toIso8601String(),
        },
        where: 'local_track_id = ? AND catalog_key <> ?',
        whereArgs: <Object?>[normalizedLocalId, track.key],
      );
      await transaction.update(
        'playlist_items',
        <String, Object?>{
          'catalog_key': track.key,
          'remote_video_id': normalizedVideoId,
          'local_track_id': normalizedLocalId,
          'updated_at': timestamp.toIso8601String(),
        },
        where:
            'deleted_at IS NULL AND '
            '(remote_video_id = ? OR catalog_key = ?)',
        whereArgs: <Object?>[normalizedVideoId, track.key],
      );
      final affectedPlaylistIds = changedRows
          .map((row) => row['playlist_id']!.toString())
          .toSet();
      for (final playlistId in affectedPlaylistIds) {
        final playlist = await _requireCatalogPlaylistRow(
          transaction,
          playlistId,
        );
        await _touchCatalogPlaylist(
          transaction,
          playlistId: playlistId,
          localRevision: _int(playlist['local_revision']) + 1,
          reason: 'download_linked',
          now: timestamp,
        );
      }
      return changedRows.length;
    });
  }

  Future<Playlist> createCatalogPlaylist({
    required String id,
    required String name,
    required DateTime now,
  }) async {
    final db = await database;
    final normalizedId = _requiredText(id, 'id');
    final normalizedName = _requiredText(name, 'name');
    final playlist = Playlist(
      id: normalizedId,
      name: normalizedName,
      trackIds: const <String>[],
      createdAt: now,
      updatedAt: now,
      localRevision: 1,
    );
    await db.insert('playlists', <String, Object?>{
      ...PlaylistModel.fromEntity(playlist).toMap(),
      'entries_migrated': 1,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
    return playlist;
  }

  Future<Playlist> renameCatalogPlaylist({
    required String playlistId,
    required String name,
    required DateTime now,
  }) async {
    final db = await database;
    return db.transaction((transaction) async {
      final current = await _requireCatalogPlaylistRow(transaction, playlistId);
      final nextRevision = _int(current['local_revision']) + 1;
      await transaction.update(
        'playlists',
        <String, Object?>{
          'name': _requiredText(name, 'name'),
          'updated_at': now.toIso8601String(),
          'local_revision': nextRevision,
        },
        where: 'id = ?',
        whereArgs: <Object?>[playlistId],
      );
      await _coalescePlaylistSyncIntents(
        transaction,
        playlistId: playlistId,
        localRevision: nextRevision,
        reason: 'local_rename',
        now: now,
      );
      final updated = <String, Object?>{
        ...current,
        'name': _requiredText(name, 'name'),
        'updated_at': now.toIso8601String(),
        'local_revision': nextRevision,
      };
      return PlaylistModel.fromMap(updated);
    });
  }

  Future<PlaylistEntry> appendCatalogEntry({
    required String playlistId,
    required String entryId,
    required CatalogTrack track,
    required DateTime now,
    String? localTrackId,
    PlaylistEntryOrigin origin = PlaylistEntryOrigin.local,
  }) async {
    final db = await database;
    return db.transaction((transaction) async {
      final playlist = await _requireCatalogPlaylistRow(
        transaction,
        playlistId,
      );
      await _upsertCatalogTrack(transaction, track, now);
      final positionRows = await transaction.rawQuery(
        'SELECT COALESCE(MAX(position), -1) + 1 AS next_position '
        'FROM playlist_items WHERE playlist_id = ? AND deleted_at IS NULL',
        <Object?>[playlistId],
      );
      final position = _int(positionRows.single['next_position']);
      final normalizedLocalId = _optionalText(localTrackId);
      if (normalizedLocalId != null) {
        await transaction.update(
          'local_tracks',
          <String, Object?>{'catalog_key': track.key},
          where: 'id = ?',
          whereArgs: <Object?>[normalizedLocalId],
        );
      }
      final entry = PlaylistEntry(
        id: _requiredText(entryId, 'entryId'),
        playlistId: playlistId,
        track: track,
        localTrackId: normalizedLocalId,
        position: position,
        origin: origin,
        createdAt: now,
        updatedAt: now,
      );
      await transaction.insert(
        'playlist_items',
        _playlistEntryToMap(entry),
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      final nextRevision = _int(playlist['local_revision']) + 1;
      await _touchCatalogPlaylist(
        transaction,
        playlistId: playlistId,
        localRevision: nextRevision,
        reason: 'local_append',
        now: now,
      );
      return entry;
    });
  }

  Future<void> replaceCatalogEntries({
    required String playlistId,
    required List<PlaylistEntry> entries,
    required DateTime now,
    int? expectedRevision,
  }) async {
    final db = await database;
    await db.transaction((transaction) async {
      final playlist = await _requireCatalogPlaylistRow(
        transaction,
        playlistId,
      );
      final actualRevision = _int(playlist['local_revision']);
      if (expectedRevision != null && actualRevision != expectedRevision) {
        throw PlaylistRevisionConflict(
          playlistId: playlistId,
          expected: expectedRevision,
          actual: actualRevision,
        );
      }
      final incomingIds = <String>{};
      for (var position = 0; position < entries.length; position++) {
        final entry = entries[position];
        if (entry.playlistId != playlistId) {
          throw ArgumentError.value(
            entry.playlistId,
            'entries[$position].playlistId',
            'Must match playlistId.',
          );
        }
        if (!incomingIds.add(entry.id)) {
          throw ArgumentError.value(
            entry.id,
            'entries[$position].id',
            'Occurrence IDs must be unique.',
          );
        }
        await _upsertCatalogTrack(transaction, entry.track, now);
        final normalized = entry.copyWith(
          position: position,
          updatedAt: now,
          deletedAt: null,
        );
        await _upsertWithoutDelete(
          transaction,
          table: 'playlist_items',
          primaryKey: 'item_id',
          values: _playlistEntryToMap(normalized),
        );
      }
      final activeRows = await transaction.query(
        'playlist_items',
        columns: const <String>['item_id'],
        where: 'playlist_id = ? AND deleted_at IS NULL',
        whereArgs: <Object?>[playlistId],
      );
      for (final row in activeRows) {
        final itemId = row['item_id']!.toString();
        if (!incomingIds.contains(itemId)) {
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
      await _touchCatalogPlaylist(
        transaction,
        playlistId: playlistId,
        localRevision: actualRevision + 1,
        reason: 'local_replace',
        now: now,
      );
    });
  }

  Future<void> tombstoneCatalogEntry({
    required String playlistId,
    required String entryId,
    required DateTime now,
  }) async {
    final db = await database;
    await db.transaction((transaction) async {
      final playlist = await _requireCatalogPlaylistRow(
        transaction,
        playlistId,
      );
      final changed = await transaction.update(
        'playlist_items',
        <String, Object?>{
          'deleted_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
        where: 'playlist_id = ? AND item_id = ? AND deleted_at IS NULL',
        whereArgs: <Object?>[playlistId, entryId],
      );
      if (changed == 0) {
        return;
      }
      await _touchCatalogPlaylist(
        transaction,
        playlistId: playlistId,
        localRevision: _int(playlist['local_revision']) + 1,
        reason: 'local_delete_item',
        now: now,
      );
    });
  }

  Future<void> tombstoneCatalogPlaylist({
    required String playlistId,
    required DateTime now,
    bool deleteRemote = false,
    String? remoteAccountKey,
  }) async {
    final normalizedRemoteAccountKey = remoteAccountKey?.trim();
    if (deleteRemote &&
        (normalizedRemoteAccountKey == null ||
            normalizedRemoteAccountKey.isEmpty)) {
      throw ArgumentError.value(
        remoteAccountKey,
        'remoteAccountKey',
        'The active account is required for remote deletion.',
      );
    }
    final db = await database;
    await db.transaction((transaction) async {
      final playlist = await _requireCatalogPlaylistRow(
        transaction,
        playlistId,
      );
      var revision = _int(playlist['local_revision']);
      if (playlist['deleted_at'] == null) {
        revision += 1;
        await transaction.update(
          'playlists',
          <String, Object?>{
            'deleted_at': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
            'local_revision': revision,
          },
          where: 'id = ?',
          whereArgs: <Object?>[playlistId],
        );
      } else if (!deleteRemote) {
        // A repeated local-only action must never cancel an explicit remote
        // deletion that was already persisted by a previous confirmation.
        return;
      }
      if (deleteRemote) {
        final changedBinding = await transaction.update(
          'ytm_playlist_bindings',
          <String, Object?>{
            'remote_delete_requested_at': now.toIso8601String(),
            'updated_at': now.toIso8601String(),
          },
          where:
              'playlist_id = ? AND account_key = ? AND '
              'remote_playlist_id IS NOT NULL AND is_editable = 1',
          whereArgs: <Object?>[playlistId, normalizedRemoteAccountKey],
        );
        if (changedBinding != 1) {
          throw StateError(
            'The active account cannot delete this remote playlist.',
          );
        }
        await _coalescePlaylistSyncIntents(
          transaction,
          playlistId: playlistId,
          localRevision: revision,
          reason: 'local_delete_playlist_remote',
          now: now,
          accountKey: normalizedRemoteAccountKey,
        );
      } else {
        // Local-only deletion keeps the binding as an import tombstone. Clear
        // ordinary pending work, but never discard a frozen partial write.
        await transaction.delete(
          'playlist_sync_intents',
          where: "playlist_id = ? AND status NOT IN ('ambiguous', 'conflict')",
          whereArgs: <Object?>[playlistId],
        );
      }
    });
  }

  Future<List<Playlist>> getPlaylists() async {
    final db = await database;
    final rows = await db.query('playlists', orderBy: 'updated_at DESC');
    return rows.map(PlaylistModel.fromMap).toList(growable: false);
  }

  Future<void> savePlaylist(Playlist playlist) async {
    final db = await database;
    final values = PlaylistModel.fromEntity(playlist).toMap();
    await db.rawInsert(
      '''
        INSERT INTO playlists (
          id, name, track_ids, created_at, updated_at,
          local_revision, deleted_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name = excluded.name,
          track_ids = excluded.track_ids,
          updated_at = excluded.updated_at,
          local_revision = CASE
            WHEN excluded.local_revision > playlists.local_revision
              THEN excluded.local_revision
            ELSE playlists.local_revision + 1
          END,
          deleted_at = excluded.deleted_at
      ''',
      <Object?>[
        values['id'],
        values['name'],
        values['track_ids'],
        values['created_at'],
        values['updated_at'],
        values['local_revision'],
        values['deleted_at'],
      ],
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

  Future<List<RecommendationSeed>> _recommendationSeeds({
    required DateTime? since,
    required int minListenedMs,
    required int limit,
    required _RecommendationSeedOrder order,
  }) async {
    if (limit <= 0) {
      throw ArgumentError.value(limit, 'limit', 'Must be greater than zero.');
    }
    if (minListenedMs < 0) {
      throw ArgumentError.value(
        minListenedMs,
        'minListenedMs',
        'Must not be negative.',
      );
    }
    final where = <String>['(listened_ms >= ? OR completed = 1)'];
    final arguments = <Object?>[minListenedMs];
    if (since != null) {
      where.add('played_at >= ?');
      arguments.add(since.toUtc().toIso8601String());
    }
    arguments.add(limit);

    final orderBy = switch (order) {
      _RecommendationSeedOrder.top =>
        '''
        preference_signal DESC,
        total_listened_ms DESC,
        completed_count DESC,
        play_count DESC,
        last_played_at DESC,
        track_key ASC
      ''',
      _RecommendationSeedOrder.recent =>
        '''
        last_played_at DESC,
        track_key ASC
      ''',
    };

    final db = await database;
    final rows = await db.rawQuery('''
      WITH filtered AS (
        SELECT *
        FROM playback_events
        WHERE ${where.join(' AND ')}
      ),
      aggregated AS (
        SELECT
          events.track_key AS track_key,
          COUNT(*) AS play_count,
          COALESCE(SUM(events.listened_ms), 0) AS total_listened_ms,
          COALESCE(SUM(events.completed), 0) AS completed_count,
          MAX(events.played_at) AS last_played_at,
          (
            SELECT state.is_favorite
            FROM filtered AS state
            WHERE state.track_key = events.track_key
              AND state.is_favorite IS NOT NULL
            ORDER BY state.played_at DESC, state.session_id DESC
            LIMIT 1
          ) AS seed_is_favorite,
          (
            SELECT state.is_liked
            FROM filtered AS state
            WHERE state.track_key = events.track_key
              AND state.is_liked IS NOT NULL
            ORDER BY state.played_at DESC, state.session_id DESC
            LIMIT 1
          ) AS seed_is_liked
        FROM filtered AS events
        GROUP BY events.track_key
      ),
      ranked AS (
        SELECT
          aggregated.*,
          (CASE WHEN seed_is_favorite = 1 THEN 1 ELSE 0 END) +
          (CASE WHEN seed_is_liked = 1 THEN 1 ELSE 0 END)
            AS preference_signal
        FROM aggregated
      ),
      selected AS (
        SELECT *
        FROM ranked
        ORDER BY $orderBy
        LIMIT ?
      )
      SELECT
        latest.track_key AS track_key,
        latest.track_id AS track_id,
        latest.video_id AS video_id,
        latest.title AS title,
        latest.artists_json AS artists_json,
        latest.artist_browse_ids_json AS artist_browse_ids_json,
        latest.album AS album,
        latest.thumbnail_url AS thumbnail_url,
        latest.duration_ms AS duration_ms,
        latest.source AS source,
        selected.play_count AS play_count,
        selected.total_listened_ms AS total_listened_ms,
        selected.completed_count AS completed_count,
        selected.last_played_at AS last_played_at,
        selected.seed_is_favorite AS seed_is_favorite,
        selected.seed_is_liked AS seed_is_liked,
        selected.preference_signal AS preference_signal
      FROM selected
      JOIN filtered AS latest
        ON latest.session_id = (
          SELECT candidate.session_id
          FROM filtered AS candidate
          WHERE candidate.track_key = selected.track_key
          ORDER BY candidate.played_at DESC, candidate.session_id DESC
          LIMIT 1
        )
      ORDER BY $orderBy
    ''', arguments);
    return List<RecommendationSeed>.unmodifiable(
      rows.map(_recommendationSeedFromAggregatedRow),
    );
  }

  Future<void> _prunePlaybackEventsIfDue({required bool inserted}) async {
    if (!inserted) {
      return;
    }
    _newEventsSinceAutomaticPrune += 1;
    final shouldPrune =
        !_hasRunAutomaticPrune ||
        _newEventsSinceAutomaticPrune >=
            playbackEventRetentionPolicy.pruneEveryWrites;
    if (!shouldPrune) {
      return;
    }

    final existing = _automaticPruneFuture;
    if (existing != null) {
      await existing;
      return;
    }
    _hasRunAutomaticPrune = true;
    _newEventsSinceAutomaticPrune = 0;
    final pruning = prunePlaybackEvents();
    _automaticPruneFuture = pruning;
    try {
      await pruning;
    } catch (_) {
      _hasRunAutomaticPrune = false;
      rethrow;
    } finally {
      if (identical(_automaticPruneFuture, pruning)) {
        _automaticPruneFuture = null;
      }
    }
  }

  Future<Map<String, Object?>> _requireCatalogPlaylistRow(
    DatabaseExecutor db,
    String playlistId,
  ) async {
    final rows = await db.query(
      'playlists',
      where: 'id = ?',
      whereArgs: <Object?>[playlistId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Playlist $playlistId does not exist.');
    }
    return rows.single;
  }

  Future<void> _touchCatalogPlaylist(
    DatabaseExecutor db, {
    required String playlistId,
    required int localRevision,
    required String reason,
    required DateTime now,
  }) async {
    final activeRows = await db.query(
      'playlist_items',
      columns: const <String>['local_track_id'],
      where: 'playlist_id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[playlistId],
      orderBy: 'position ASC, item_id ASC',
    );
    final legacyTrackIds = activeRows
        .map((row) => row['local_track_id']?.toString())
        .whereType<String>()
        .toList(growable: false);
    await db.update(
      'playlists',
      <String, Object?>{
        'track_ids': jsonEncode(legacyTrackIds),
        'updated_at': now.toIso8601String(),
        'local_revision': localRevision,
        'entries_migrated': 1,
      },
      where: 'id = ?',
      whereArgs: <Object?>[playlistId],
    );
    await _coalescePlaylistSyncIntents(
      db,
      playlistId: playlistId,
      localRevision: localRevision,
      reason: reason,
      now: now,
    );
  }

  Future<void> _coalescePlaylistSyncIntents(
    DatabaseExecutor db, {
    required String playlistId,
    required int localRevision,
    required String reason,
    required DateTime now,
    String? accountKey,
  }) async {
    final bindings = await db.query(
      'ytm_playlist_bindings',
      columns: const <String>['account_key'],
      where: accountKey == null
          ? 'playlist_id = ?'
          : 'playlist_id = ? AND account_key = ?',
      whereArgs: <Object?>[playlistId, ?accountKey],
    );
    final timestamp = now.toIso8601String();
    for (final binding in bindings) {
      await db.rawInsert(
        '''
          INSERT INTO playlist_sync_intents (
            account_key, playlist_id, requested_local_revision, reason,
            status, attempt_count, created_at, updated_at
          ) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
          ON CONFLICT(account_key, playlist_id) DO UPDATE SET
            requested_local_revision = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.requested_local_revision
              ELSE excluded.requested_local_revision
            END,
            reason = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.reason
              ELSE excluded.reason
            END,
            status = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.status
              ELSE 'pending'
            END,
            desired_snapshot_json = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.desired_snapshot_json
              ELSE NULL
            END,
            desired_snapshot_hash = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.desired_snapshot_hash
              ELSE NULL
            END,
            mutation_token = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.mutation_token
              ELSE NULL
            END,
            attempt_count = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.attempt_count
              ELSE 0
            END,
            next_attempt_at = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.next_attempt_at
              ELSE NULL
            END,
            last_error = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.last_error
              ELSE NULL
            END,
            updated_at = CASE
              WHEN playlist_sync_intents.status IN ('ambiguous', 'conflict')
                THEN playlist_sync_intents.updated_at
              ELSE excluded.updated_at
            END
        ''',
        <Object?>[
          binding['account_key'],
          playlistId,
          localRevision,
          reason,
          timestamp,
          timestamp,
        ],
      );
    }
  }

  Future<void> _upsertCatalogTrack(
    DatabaseExecutor db,
    CatalogTrack track,
    DateTime now,
  ) async {
    await db.rawInsert(
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
          duration_ms = COALESCE(
            excluded.duration_ms,
            catalog_tracks.duration_ms
          ),
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
        track.provider.name,
        now.toIso8601String(),
      ],
    );
  }

  Future<Database> _open() async {
    _configureDatabaseFactory();

    final dbPath = await databasePath();

    return openDatabase(
      dbPath,
      version: AppConstants.databaseVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE local_tracks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            file_path TEXT NOT NULL,
            source_url TEXT,
            thumbnail_url TEXT,
            catalog_thumbnail_url TEXT,
            thumbnail_path TEXT,
            duration_seconds INTEGER,
            album TEXT,
            artists_json TEXT NOT NULL DEFAULT '[]',
            artist_browse_ids_json TEXT NOT NULL DEFAULT '[]',
            metadata_source TEXT NOT NULL DEFAULT 'youtube',
            source_id TEXT,
            catalog_key TEXT,
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
            updated_at TEXT NOT NULL,
            local_revision INTEGER NOT NULL DEFAULT 0,
            deleted_at TEXT,
            entries_migrated INTEGER NOT NULL DEFAULT 1
          )
        ''');
        await _createRecommendationTables(db);
        await _createPlaylistSyncTables(db);
        await _createIndexes(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _addColumnIfMissing(
            db,
            table: 'local_tracks',
            column: 'thumbnail_path',
            definition: 'TEXT',
          );
        }
        if (oldVersion < 4) {
          await _addColumnIfMissing(
            db,
            table: 'local_tracks',
            column: 'last_played_playlist_id',
            definition: 'TEXT',
          );
        }
        if (oldVersion < 5) {
          await _addColumnIfMissing(
            db,
            table: 'local_tracks',
            column: 'album',
            definition: 'TEXT',
          );
          await _addColumnIfMissing(
            db,
            table: 'local_tracks',
            column: 'artists_json',
            definition: "TEXT NOT NULL DEFAULT '[]'",
          );
          await _addColumnIfMissing(
            db,
            table: 'local_tracks',
            column: 'metadata_source',
            definition: "TEXT NOT NULL DEFAULT 'youtube'",
          );
          await _addColumnIfMissing(
            db,
            table: 'local_tracks',
            column: 'source_id',
            definition: 'TEXT',
          );
          await _addColumnIfMissing(
            db,
            table: 'local_tracks',
            column: 'catalog_thumbnail_url',
            definition: 'TEXT',
          );
          await _backfillLocalTrackSourceIds(db);
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_local_tracks_source_id '
            'ON local_tracks(source_id)',
          );
        }
        if (oldVersion < 6) {
          await _addColumnIfMissing(
            db,
            table: 'local_tracks',
            column: 'artist_browse_ids_json',
            definition: "TEXT NOT NULL DEFAULT '[]'",
          );
          await _createRecommendationTables(db);
        }
        // All required columns/tables exist at this point. Version 7 replaces
        // the previous two-column playback indexes with deterministic indexes
        // that also cover the session tie-break used by retention and seeds.
        if (oldVersion < 7) {
          await db.execute(
            'DROP INDEX IF EXISTS idx_playback_events_track_key_played_at',
          );
          await db.execute(
            'DROP INDEX IF EXISTS idx_playback_events_played_at',
          );
        }
        if (oldVersion < 8) {
          await _addColumnIfMissing(
            db,
            table: 'local_tracks',
            column: 'catalog_key',
            definition: 'TEXT',
          );
          await _addColumnIfMissing(
            db,
            table: 'playlists',
            column: 'local_revision',
            definition: 'INTEGER NOT NULL DEFAULT 0',
          );
          await _addColumnIfMissing(
            db,
            table: 'playlists',
            column: 'deleted_at',
            definition: 'TEXT',
          );
          await _addColumnIfMissing(
            db,
            table: 'playlists',
            column: 'entries_migrated',
            definition: 'INTEGER NOT NULL DEFAULT 0',
          );
          await _createPlaylistSyncTables(db);
          await _backfillCatalogPlaylistData(db);
          await _createIndexes(db);
        }
      },
      onOpen: _repairAndValidateCurrentSchema,
    );
  }

  void _configureDatabaseFactory() {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<void> _repairAndValidateCurrentSchema(Database db) async {
    final tables = await _tableNames(db);
    if (!tables.containsAll(const <String>{'local_tracks', 'playlists'})) {
      throw const FormatException(
        'La base de datos activa no contiene la biblioteca requerida.',
      );
    }

    final localColumns = await _tableColumns(db, 'local_tracks');
    const additiveColumns = <String, String>{
      'thumbnail_path': 'TEXT',
      'last_played_playlist_id': 'TEXT',
      'album': 'TEXT',
      'artists_json': "TEXT NOT NULL DEFAULT '[]'",
      'metadata_source': "TEXT NOT NULL DEFAULT 'youtube'",
      'source_id': 'TEXT',
      'catalog_thumbnail_url': 'TEXT',
      'artist_browse_ids_json': "TEXT NOT NULL DEFAULT '[]'",
      'catalog_key': 'TEXT',
    };
    for (final column in additiveColumns.entries) {
      if (localColumns.add(column.key)) {
        await db.execute(
          'ALTER TABLE local_tracks ADD COLUMN ${column.key} ${column.value}',
        );
      }
    }

    await _backfillLocalTrackSourceIds(db);

    final playlistColumns = await _tableColumns(db, 'playlists');
    const additivePlaylistColumns = <String, String>{
      'local_revision': 'INTEGER NOT NULL DEFAULT 0',
      'deleted_at': 'TEXT',
      'entries_migrated': 'INTEGER NOT NULL DEFAULT 0',
    };
    for (final column in additivePlaylistColumns.entries) {
      if (playlistColumns.add(column.key)) {
        await db.execute(
          'ALTER TABLE playlists ADD COLUMN ${column.key} ${column.value}',
        );
      }
    }

    await _createRecommendationTables(db);
    await _createPlaylistSyncTables(db);
    final syncConflictColumns = await _tableColumns(
      db,
      'playlist_sync_conflicts',
    );
    if (syncConflictColumns.add('message')) {
      await db.execute(
        'ALTER TABLE playlist_sync_conflicts ADD COLUMN message TEXT',
      );
    }
    final playlistItemColumns = await _tableColumns(db, 'playlist_items');
    for (final column in const <String>{
      'remote_video_id',
      'remote_set_video_id',
    }) {
      if (playlistItemColumns.add(column)) {
        await db.execute('ALTER TABLE playlist_items ADD COLUMN $column TEXT');
      }
    }
    await _backfillCatalogPlaylistData(db);
    await _validateSchemaForVersion(db, AppConstants.databaseVersion);
    await _repairIndexes(db);
  }

  Future<void> _validateSchemaForVersion(
    DatabaseExecutor db,
    int version,
  ) async {
    final tables = await _tableNames(db);
    if (!tables.containsAll(const <String>{'local_tracks', 'playlists'})) {
      throw const FormatException(
        'La base de datos no contiene las tablas de biblioteca requeridas.',
      );
    }

    final requiredLocalColumns = <String>{
      'id',
      'title',
      'artist',
      'file_path',
      'source_url',
      'thumbnail_url',
      'duration_seconds',
      'added_at',
      'last_played_at',
      if (version >= 2) 'thumbnail_path',
      if (version >= 4) 'last_played_playlist_id',
      if (version >= 5) ...<String>{
        'album',
        'artists_json',
        'metadata_source',
        'source_id',
        'catalog_thumbnail_url',
      },
      if (version >= 6) 'artist_browse_ids_json',
      if (version >= 8) 'catalog_key',
    };
    await _requireTableColumns(
      db,
      table: 'local_tracks',
      requiredColumns: requiredLocalColumns,
    );
    await _requirePrimaryKey(db, table: 'local_tracks', columns: const ['id']);
    await _requireTableColumns(
      db,
      table: 'playlists',
      requiredColumns: <String>{
        'id',
        'name',
        'track_ids',
        'created_at',
        'updated_at',
        if (version >= 8) ...<String>{
          'local_revision',
          'deleted_at',
          'entries_migrated',
        },
      },
    );
    await _requirePrimaryKey(db, table: 'playlists', columns: const ['id']);

    if (version < 6) {
      return;
    }
    const recommendationColumns = <String, Set<String>>{
      'playback_events': <String>{
        'session_id',
        'track_key',
        'track_id',
        'video_id',
        'title',
        'artists_json',
        'artist_browse_ids_json',
        'album',
        'thumbnail_url',
        'duration_ms',
        'source',
        'started_at',
        'played_at',
        'listened_ms',
        'completed',
        'is_favorite',
        'is_liked',
      },
      'related_track_candidates': <String>{
        'seed_key',
        'candidate_key',
        'track_id',
        'video_id',
        'title',
        'artists_json',
        'artist_browse_ids_json',
        'album',
        'thumbnail_url',
        'duration_ms',
        'rank',
        'fetched_at',
      },
      'recommendation_feed_cache': <String>{
        'feed_key',
        'payload_json',
        'generated_at',
        'expires_at',
      },
    };
    for (final entry in recommendationColumns.entries) {
      if (!tables.contains(entry.key)) {
        throw FormatException(
          'La base de datos no contiene la tabla ${entry.key}.',
        );
      }
      await _requireTableColumns(
        db,
        table: entry.key,
        requiredColumns: entry.value,
      );
    }
    await _requirePrimaryKey(
      db,
      table: 'playback_events',
      columns: const ['session_id'],
    );
    await _requirePrimaryKey(
      db,
      table: 'related_track_candidates',
      columns: const ['seed_key', 'candidate_key'],
    );
    await _requirePrimaryKey(
      db,
      table: 'recommendation_feed_cache',
      columns: const ['feed_key'],
    );

    if (version < 8) {
      return;
    }
    const syncColumns = <String, Set<String>>{
      'catalog_tracks': <String>{
        'track_key',
        'provider',
        'provider_id',
        'title',
        'artists_json',
        'artist_browse_ids_json',
        'album',
        'duration_ms',
        'thumbnail_url',
        'source_url',
        'metadata_source',
        'metadata_updated_at',
      },
      'playlist_items': <String>{
        'item_id',
        'playlist_id',
        'catalog_key',
        'local_track_id',
        'remote_video_id',
        'remote_set_video_id',
        'position',
        'origin',
        'created_at',
        'updated_at',
        'deleted_at',
      },
      'ytm_playlist_bindings': <String>{
        'account_key',
        'playlist_id',
        'remote_playlist_id',
        'remote_browse_id',
        'sync_mode',
        'is_editable',
        'privacy',
        'base_title',
        'base_snapshot_hash',
        'remote_revision',
        'local_revision_at_base',
        'last_synced_at',
        'last_remote_seen_at',
        'remote_delete_requested_at',
        'created_at',
        'updated_at',
      },
      'ytm_playlist_base_items': <String>{
        'account_key',
        'playlist_id',
        'ordinal',
        'local_item_id',
        'video_id',
        'set_video_id',
      },
      'playlist_sync_intents': <String>{
        'account_key',
        'playlist_id',
        'requested_local_revision',
        'reason',
        'status',
        'desired_snapshot_json',
        'desired_snapshot_hash',
        'mutation_token',
        'attempt_count',
        'next_attempt_at',
        'last_error',
        'created_at',
        'updated_at',
      },
      'playlist_sync_conflicts': <String>{
        'conflict_id',
        'account_key',
        'playlist_id',
        'kind',
        'base_snapshot_json',
        'local_snapshot_json',
        'remote_snapshot_json',
        'detected_at',
        'resolved_at',
        'resolution',
      },
    };
    for (final entry in syncColumns.entries) {
      if (!tables.contains(entry.key)) {
        throw FormatException(
          'La base de datos no contiene la tabla ${entry.key}.',
        );
      }
      await _requireTableColumns(
        db,
        table: entry.key,
        requiredColumns: entry.value,
      );
    }
    await _requirePrimaryKey(
      db,
      table: 'catalog_tracks',
      columns: const <String>['track_key'],
    );
    await _requirePrimaryKey(
      db,
      table: 'playlist_items',
      columns: const <String>['item_id'],
    );
    await _requirePrimaryKey(
      db,
      table: 'ytm_playlist_bindings',
      columns: const <String>['account_key', 'playlist_id'],
    );
    await _requirePrimaryKey(
      db,
      table: 'ytm_playlist_base_items',
      columns: const <String>['account_key', 'playlist_id', 'ordinal'],
    );
    await _requirePrimaryKey(
      db,
      table: 'playlist_sync_intents',
      columns: const <String>['account_key', 'playlist_id'],
    );
    await _requirePrimaryKey(
      db,
      table: 'playlist_sync_conflicts',
      columns: const <String>['conflict_id'],
    );
  }

  Future<Set<String>> _tableNames(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    return rows
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .toSet();
  }

  Future<Set<String>> _tableColumns(DatabaseExecutor db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows
        .map((row) => row['name']?.toString())
        .whereType<String>()
        .toSet();
  }

  Future<void> _addColumnIfMissing(
    DatabaseExecutor db, {
    required String table,
    required String column,
    required String definition,
  }) async {
    final columns = await _tableColumns(db, table);
    if (columns.contains(column)) {
      return;
    }
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }

  Future<void> _requireTableColumns(
    DatabaseExecutor db, {
    required String table,
    required Set<String> requiredColumns,
  }) async {
    final columns = await _tableColumns(db, table);
    final missing = requiredColumns.difference(columns);
    if (missing.isNotEmpty) {
      throw FormatException(
        'La tabla $table no contiene las columnas requeridas: '
        '${missing.join(', ')}.',
      );
    }
  }

  Future<void> _requirePrimaryKey(
    DatabaseExecutor db, {
    required String table,
    required List<String> columns,
  }) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    final actual = <int, String>{};
    for (final row in rows) {
      final position = _nullableInt(row['pk']) ?? 0;
      final name = row['name']?.toString();
      if (position > 0 && name != null) {
        actual[position] = name;
      }
    }
    final ordered = <String>[];
    for (var position = 1; position <= actual.length; position++) {
      final name = actual[position];
      if (name != null) {
        ordered.add(name);
      }
    }
    if (!_sameOrderedValues(ordered, columns)) {
      throw FormatException(
        'La tabla $table no tiene la clave primaria requerida.',
      );
    }
  }

  Future<void> _backfillLocalTrackSourceIds(DatabaseExecutor db) async {
    final rows = await db.query(
      'local_tracks',
      columns: const <String>['id', 'source_url'],
      where:
          "(source_id IS NULL OR TRIM(source_id) = '') "
          'AND source_url IS NOT NULL',
    );
    if (rows.isEmpty) {
      return;
    }

    const codec = BStreamTrackLinkCodec();
    final batch = db.batch();
    var updates = 0;
    for (final row in rows) {
      final sourceUrl = row['source_url']?.toString();
      if (sourceUrl == null) {
        continue;
      }
      final videoId = codec.extractVideoId(sourceUrl);
      if (videoId == null) {
        continue;
      }
      batch.update(
        'local_tracks',
        <String, Object?>{'source_id': videoId},
        where: "id = ? AND (source_id IS NULL OR TRIM(source_id) = '')",
        whereArgs: <Object?>[row['id']],
      );
      updates += 1;
    }
    if (updates > 0) {
      await batch.commit(noResult: true);
    }
  }

  Future<void> _createPlaylistSyncTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS catalog_tracks (
        track_key TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        title TEXT NOT NULL,
        artists_json TEXT NOT NULL DEFAULT '[]',
        artist_browse_ids_json TEXT NOT NULL DEFAULT '[]',
        album TEXT,
        duration_ms INTEGER,
        thumbnail_url TEXT,
        source_url TEXT,
        metadata_source TEXT NOT NULL DEFAULT 'local',
        metadata_updated_at TEXT NOT NULL,
        UNIQUE (provider, provider_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_items (
        item_id TEXT PRIMARY KEY,
        playlist_id TEXT NOT NULL,
        catalog_key TEXT NOT NULL,
        local_track_id TEXT,
        remote_video_id TEXT,
        remote_set_video_id TEXT,
        position INTEGER NOT NULL CHECK (position >= 0),
        origin TEXT NOT NULL DEFAULT 'local',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT,
        FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
        FOREIGN KEY (catalog_key) REFERENCES catalog_tracks(track_key),
        FOREIGN KEY (local_track_id) REFERENCES local_tracks(id)
          ON DELETE SET NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ytm_playlist_bindings (
        account_key TEXT NOT NULL,
        playlist_id TEXT NOT NULL,
        remote_playlist_id TEXT,
        remote_browse_id TEXT,
        sync_mode TEXT NOT NULL DEFAULT 'manual',
        is_editable INTEGER NOT NULL DEFAULT 1 CHECK (is_editable IN (0, 1)),
        privacy TEXT,
        base_title TEXT,
        base_snapshot_hash TEXT,
        remote_revision TEXT,
        local_revision_at_base INTEGER NOT NULL DEFAULT 0,
        last_synced_at TEXT,
        last_remote_seen_at TEXT,
        remote_delete_requested_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (account_key, playlist_id),
        UNIQUE (account_key, remote_playlist_id),
        FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ytm_playlist_base_items (
        account_key TEXT NOT NULL,
        playlist_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
        local_item_id TEXT,
        video_id TEXT,
        set_video_id TEXT,
        PRIMARY KEY (account_key, playlist_id, ordinal),
        FOREIGN KEY (account_key, playlist_id)
          REFERENCES ytm_playlist_bindings(account_key, playlist_id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_sync_intents (
        account_key TEXT NOT NULL,
        playlist_id TEXT NOT NULL,
        requested_local_revision INTEGER NOT NULL,
        reason TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        desired_snapshot_json TEXT,
        desired_snapshot_hash TEXT,
        mutation_token TEXT,
        attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
        next_attempt_at TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (account_key, playlist_id),
        FOREIGN KEY (account_key, playlist_id)
          REFERENCES ytm_playlist_bindings(account_key, playlist_id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_sync_conflicts (
        conflict_id TEXT PRIMARY KEY,
        account_key TEXT NOT NULL,
        playlist_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        message TEXT,
        base_snapshot_json TEXT,
        local_snapshot_json TEXT NOT NULL,
        remote_snapshot_json TEXT,
        detected_at TEXT NOT NULL,
        resolved_at TEXT,
        resolution TEXT,
        FOREIGN KEY (account_key, playlist_id)
          REFERENCES ytm_playlist_bindings(account_key, playlist_id)
          ON DELETE CASCADE
      )
    ''');
  }

  /// Converts the legacy JSON memberships exactly once. Item identifiers are
  /// deterministic so an interrupted repair can safely be run again.
  Future<void> _backfillCatalogPlaylistData(DatabaseExecutor db) async {
    final localRows = await db.query('local_tracks');
    final catalogKeyByLocalId = <String, String>{};
    for (final row in localRows) {
      final localId = row['id']?.toString();
      if (localId == null || localId.isEmpty) {
        continue;
      }
      final videoId = _canonicalYouTubeVideoId(row['source_id']);
      final provider = videoId == null ? 'local' : 'youtube';
      final providerId = videoId ?? localId;
      final catalogKey = '$provider:$providerId';
      catalogKeyByLocalId[localId] = catalogKey;
      await db.rawInsert(
        '''
          INSERT INTO catalog_tracks (
            track_key, provider, provider_id, title, artists_json,
            artist_browse_ids_json, album, duration_ms, thumbnail_url,
            source_url, metadata_source, metadata_updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(track_key) DO NOTHING
        ''',
        <Object?>[
          catalogKey,
          provider,
          providerId,
          row['title']?.toString() ?? '',
          row['artists_json']?.toString() ?? '[]',
          row['artist_browse_ids_json']?.toString() ?? '[]',
          row['album'],
          _nullableInt(row['duration_seconds']) == null
              ? null
              : _nullableInt(row['duration_seconds'])! * 1000,
          row['catalog_thumbnail_url'] ?? row['thumbnail_url'],
          row['source_url'],
          row['metadata_source']?.toString() ?? 'local',
          row['added_at']?.toString() ?? DateTime.now().toIso8601String(),
        ],
      );
      await db.update(
        'local_tracks',
        <String, Object?>{'catalog_key': catalogKey},
        where: 'id = ? AND (catalog_key IS NULL OR catalog_key <> ?)',
        whereArgs: <Object?>[localId, catalogKey],
      );
    }

    final playlistRows = await db.query(
      'playlists',
      where: 'entries_migrated = 0',
    );
    for (final playlistRow in playlistRows) {
      final playlistId = playlistRow['id']?.toString();
      if (playlistId == null || playlistId.isEmpty) {
        continue;
      }
      final trackIds = _decodeLegacyPlaylistTrackIds(playlistRow['track_ids']);
      final createdAt =
          playlistRow['created_at']?.toString() ??
          DateTime.now().toIso8601String();
      final updatedAt = playlistRow['updated_at']?.toString() ?? createdAt;
      for (var position = 0; position < trackIds.length; position++) {
        final localId = trackIds[position];
        var catalogKey = catalogKeyByLocalId[localId];
        if (catalogKey == null) {
          final encodedId = base64Url.encode(utf8.encode(localId));
          catalogKey = 'legacy:$encodedId';
          await db.rawInsert(
            '''
              INSERT INTO catalog_tracks (
                track_key, provider, provider_id, title, artists_json,
                artist_browse_ids_json, metadata_source, metadata_updated_at
              ) VALUES (?, 'legacy', ?, ?, '[]', '[]', 'legacy', ?)
              ON CONFLICT(track_key) DO NOTHING
            ''',
            <Object?>[catalogKey, localId, localId, updatedAt],
          );
        }
        final encodedPlaylistId = base64Url.encode(utf8.encode(playlistId));
        await db.rawInsert(
          '''
            INSERT INTO playlist_items (
              item_id, playlist_id, catalog_key, local_track_id,
              remote_video_id, position, origin, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, 'legacy', ?, ?)
            ON CONFLICT(item_id) DO NOTHING
          ''',
          <Object?>[
            'legacy:$encodedPlaylistId:$position',
            playlistId,
            catalogKey,
            catalogKeyByLocalId.containsKey(localId) ? localId : null,
            catalogKey.startsWith('youtube:')
                ? catalogKey.substring('youtube:'.length)
                : null,
            position,
            createdAt,
            updatedAt,
          ],
        );
      }
      await db.update(
        'playlists',
        <String, Object?>{'entries_migrated': 1},
        where: 'id = ?',
        whereArgs: <Object?>[playlistId],
      );
    }
  }

  Future<void> _createRecommendationTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS playback_events (
        session_id TEXT PRIMARY KEY,
        track_key TEXT NOT NULL,
        track_id TEXT NOT NULL,
        video_id TEXT,
        title TEXT NOT NULL,
        artists_json TEXT NOT NULL DEFAULT '[]',
        artist_browse_ids_json TEXT NOT NULL DEFAULT '[]',
        album TEXT,
        thumbnail_url TEXT,
        duration_ms INTEGER,
        source TEXT NOT NULL,
        started_at TEXT NOT NULL,
        played_at TEXT NOT NULL,
        listened_ms INTEGER NOT NULL DEFAULT 0 CHECK (listened_ms >= 0),
        completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1)),
        is_favorite INTEGER CHECK (is_favorite IN (0, 1)),
        is_liked INTEGER CHECK (is_liked IN (0, 1))
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS related_track_candidates (
        seed_key TEXT NOT NULL,
        candidate_key TEXT NOT NULL,
        track_id TEXT NOT NULL,
        video_id TEXT,
        title TEXT NOT NULL,
        artists_json TEXT NOT NULL DEFAULT '[]',
        artist_browse_ids_json TEXT NOT NULL DEFAULT '[]',
        album TEXT,
        thumbnail_url TEXT,
        duration_ms INTEGER,
        rank INTEGER NOT NULL CHECK (rank >= 0),
        fetched_at TEXT NOT NULL,
        PRIMARY KEY (seed_key, candidate_key)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recommendation_feed_cache (
        feed_key TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        generated_at TEXT NOT NULL,
        expires_at TEXT NOT NULL
      )
    ''');
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
      'CREATE INDEX IF NOT EXISTS idx_local_tracks_source_id '
      'ON local_tracks(source_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_local_tracks_catalog_key '
      'ON local_tracks(catalog_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_playlists_updated_at '
      'ON playlists(updated_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS '
      'idx_playback_events_track_played_session '
      'ON playback_events(track_key, played_at DESC, session_id DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_playback_events_played_session '
      'ON playback_events(played_at DESC, session_id DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_related_candidates_seed_fetched_rank '
      'ON related_track_candidates(seed_key, fetched_at, rank)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_related_candidates_fetched_at '
      'ON related_track_candidates(fetched_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_recommendation_feed_expires_at '
      'ON recommendation_feed_cache(expires_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_catalog_tracks_provider_id '
      'ON catalog_tracks(provider, provider_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_playlist_items_playlist_position '
      'ON playlist_items(playlist_id, position, item_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_playlist_items_catalog_key '
      'ON playlist_items(catalog_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ytm_playlist_bindings_remote '
      'ON ytm_playlist_bindings(account_key, remote_playlist_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_playlist_sync_intents_due '
      'ON playlist_sync_intents(status, next_attempt_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_playlist_sync_conflicts_open '
      'ON playlist_sync_conflicts(account_key, playlist_id, resolved_at)',
    );
  }

  Future<void> _repairIndexes(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      "SELECT name, tbl_name FROM sqlite_master WHERE type = 'index'",
    );
    final existing = <String, String?>{
      for (final row in rows)
        if (row['name'] case final String name)
          name: row['tbl_name']?.toString(),
    };
    for (final definition in _requiredDatabaseIndexes) {
      if (!existing.containsKey(definition.name)) {
        continue;
      }
      final existingTable = existing[definition.name];
      final indexRows = await db.rawQuery(
        'PRAGMA index_xinfo(${definition.name})',
      );
      final keyRows =
          indexRows
              .where((row) => (_nullableInt(row['key']) ?? 1) == 1)
              .toList(growable: false)
            ..sort(
              (left, right) => (_nullableInt(left['seqno']) ?? 0).compareTo(
                _nullableInt(right['seqno']) ?? 0,
              ),
            );
      final columns = keyRows
          .map((row) => row['name']?.toString())
          .whereType<String>()
          .toList(growable: false);
      final descending = keyRows
          .map((row) => (_nullableInt(row['desc']) ?? 0) == 1)
          .toList(growable: false);
      if (existingTable == definition.table &&
          _sameOrderedValues(columns, definition.columns) &&
          _sameOrderedValues(descending, definition.descending)) {
        continue;
      }
      await db.execute('DROP INDEX ${definition.name}');
    }
    await db.execute(
      'DROP INDEX IF EXISTS idx_playback_events_track_key_played_at',
    );
    await db.execute('DROP INDEX IF EXISTS idx_playback_events_played_at');
    await _createIndexes(db);
  }

  bool _sameOrderedValues<T>(List<T> left, List<T> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  String _rewriteMediaPath({
    required String path,
    required String targetRoot,
    List<String>? oldRoots,
  }) {
    String? relative;
    if (oldRoots == null) {
      relative = p.basename(path);
    } else {
      for (final oldRoot in oldRoots) {
        relative = _relativeIfInside(path: path, root: oldRoot);
        if (relative != null) {
          break;
        }
      }
    }
    if (relative == null || relative.isEmpty) {
      return path;
    }
    return p.join(targetRoot, relative);
  }

  String? _relativeIfInside({required String path, required String root}) {
    final normalizedPath = p.normalize(File(path).absolute.path);
    final normalizedRoot = p.normalize(Directory(root).absolute.path);
    final pathKey = _pathComparisonKey(normalizedPath);
    final rootKey = _pathComparisonKey(normalizedRoot);
    if (pathKey == rootKey) {
      return p.basename(normalizedPath);
    }
    final prefix = rootKey.endsWith(p.separator)
        ? rootKey
        : '$rootKey${p.separator}';
    if (!pathKey.startsWith(prefix)) {
      return null;
    }
    return p.relative(normalizedPath, from: normalizedRoot);
  }

  List<String> _uniquePathRoots(Iterable<String> roots) {
    final result = <String>[];
    final seen = <String>{};
    for (final root in roots) {
      final normalized = p.normalize(Directory(root).absolute.path);
      if (seen.add(_pathComparisonKey(normalized))) {
        result.add(normalized);
      }
    }
    return result;
  }

  String _pathComparisonKey(String path) {
    final normalized = p.normalize(path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

CatalogTrack _catalogTrackFromRow(Map<String, Object?> row) {
  final providerName = row['provider']?.toString();
  final provider = CatalogProvider.values.firstWhere(
    (candidate) => candidate.name == providerName,
    orElse: () => CatalogProvider.legacy,
  );
  final durationMs = _nullableInt(row['duration_ms']);
  return CatalogTrack(
    key: row['track_key']!.toString(),
    provider: provider,
    providerId: row['provider_id']!.toString(),
    title: row['title']!.toString(),
    artists: _decodeStringList(row['artists_json']),
    artistBrowseIds: _decodeNullableStringList(row['artist_browse_ids_json']),
    album: row['album']?.toString(),
    duration: durationMs == null ? null : Duration(milliseconds: durationMs),
    thumbnailUrl: row['thumbnail_url']?.toString(),
    sourceUrl: row['source_url']?.toString(),
  );
}

PlaylistEntry _playlistEntryFromRow(Map<String, Object?> row) {
  final originName = row['origin']?.toString();
  final origin = PlaylistEntryOrigin.values.firstWhere(
    (candidate) => candidate.name == originName,
    orElse: () => PlaylistEntryOrigin.legacy,
  );
  return PlaylistEntry(
    id: row['item_id']!.toString(),
    playlistId: row['playlist_id']!.toString(),
    track: _catalogTrackFromRow(row),
    localTrackId: row['local_track_id']?.toString(),
    remoteVideoId: row['remote_video_id']?.toString(),
    setVideoId: row['remote_set_video_id']?.toString(),
    position: _int(row['position']),
    origin: origin,
    createdAt: DateTime.parse(row['created_at']!.toString()),
    updatedAt: DateTime.parse(row['updated_at']!.toString()),
    deletedAt: row['deleted_at'] == null
        ? null
        : DateTime.tryParse(row['deleted_at'].toString()),
  );
}

Map<String, Object?> _playlistEntryToMap(PlaylistEntry entry) {
  return <String, Object?>{
    'item_id': entry.id,
    'playlist_id': entry.playlistId,
    'catalog_key': entry.track.key,
    'local_track_id': entry.localTrackId,
    'remote_video_id': entry.remoteVideoId ?? entry.track.youtubeVideoId,
    'remote_set_video_id': entry.setVideoId,
    'position': entry.position,
    'origin': entry.origin.name,
    'created_at': entry.createdAt.toIso8601String(),
    'updated_at': entry.updatedAt.toIso8601String(),
    'deleted_at': entry.deletedAt?.toIso8601String(),
  };
}

enum _RecommendationSeedOrder { top, recent }

RecommendationSeed _recommendationSeedFromAggregatedRow(
  Map<String, Object?> row,
) {
  return RecommendationSeed(
    trackKey: row['track_key']! as String,
    trackId: row['track_id']! as String,
    videoId: row['video_id'] as String?,
    title: row['title']! as String,
    artists: _decodeStringList(row['artists_json']),
    artistBrowseIds: _decodeNullableStringList(row['artist_browse_ids_json']),
    album: row['album'] as String?,
    thumbnailUrl: row['thumbnail_url'] as String?,
    durationMs: _nullableInt(row['duration_ms']),
    source: _playbackSource(row['source']),
    playCount: _int(row['play_count']),
    totalListenedMs: _int(row['total_listened_ms']),
    completedCount: _int(row['completed_count']),
    lastPlayedAt: DateTime.parse(row['last_played_at']! as String),
    isFavorite: _nullableBool(row['seed_is_favorite']),
    isLiked: _nullableBool(row['seed_is_liked']),
  );
}

RelatedTrackCandidate _relatedCandidateFromRow(Map<String, Object?> row) {
  return RelatedTrackCandidate(
    trackId: row['track_id']! as String,
    videoId: row['video_id'] as String?,
    title: row['title']! as String,
    artists: _decodeStringList(row['artists_json']),
    artistBrowseIds: _decodeNullableStringList(row['artist_browse_ids_json']),
    album: row['album'] as String?,
    thumbnailUrl: row['thumbnail_url'] as String?,
    durationMs: _nullableInt(row['duration_ms']),
    rank: _int(row['rank']),
    fetchedAt: DateTime.parse(row['fetched_at']! as String),
  );
}

void _validateRetentionPolicy(PlaybackEventRetentionPolicy policy) {
  if (policy.maxAge?.isNegative ?? false) {
    throw ArgumentError.value(policy.maxAge, 'policy.maxAge');
  }
  if (policy.relatedCandidateMaxAge?.isNegative ?? false) {
    throw ArgumentError.value(
      policy.relatedCandidateMaxAge,
      'policy.relatedCandidateMaxAge',
    );
  }
  if ((policy.maxEvents ?? 0) < 0) {
    throw ArgumentError.value(policy.maxEvents, 'policy.maxEvents');
  }
  if (policy.pruneEveryWrites <= 0) {
    throw ArgumentError.value(
      policy.pruneEveryWrites,
      'policy.pruneEveryWrites',
    );
  }
}

String _requiredText(String value, String parameterName) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, parameterName, 'Must not be empty.');
  }
  return normalized;
}

String? _optionalText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

List<String> _normalizedStrings(Iterable<String> values) {
  final normalized = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final item = value.trim();
    if (item.isNotEmpty && seen.add(item)) {
      normalized.add(item);
    }
  }
  return normalized;
}

List<String?> _normalizedArtistBrowseIds(Iterable<String?> values) {
  return values
      .map((value) {
        final normalized = value?.trim();
        return normalized == null || normalized.isEmpty ? null : normalized;
      })
      .toList(growable: false);
}

List<String> _decodeStringList(Object? value) {
  try {
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is List) {
      return List<String>.unmodifiable(
        _normalizedStrings(decoded.whereType<Object>().map((item) => '$item')),
      );
    }
  } catch (_) {
    // Corrupt optional metadata must not make the entire history unusable.
  }
  return const <String>[];
}

List<String?> _decodeNullableStringList(Object? value) {
  try {
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is List) {
      return List<String?>.unmodifiable(
        _normalizedArtistBrowseIds(decoded.map((item) => item?.toString())),
      );
    }
  } catch (_) {
    // Corrupt optional metadata must not make the entire history unusable.
  }
  return const <String?>[];
}

PlaybackEventSource _playbackSource(Object? value) {
  final name = value?.toString();
  return PlaybackEventSource.values.firstWhere(
    (source) => source.name == name,
    orElse: () => PlaybackEventSource.unknown,
  );
}

int _int(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  return int.parse('$value');
}

int? _nullableInt(Object? value) => value == null ? null : _int(value);

String? _canonicalYouTubeVideoId(Object? value) {
  final candidate = value?.toString().trim();
  return candidate != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(candidate)
      ? candidate
      : null;
}

List<String> _decodeLegacyPlaylistTrackIds(Object? value) {
  try {
    final decoded = value is String ? jsonDecode(value) : value;
    if (decoded is List) {
      return List<String>.unmodifiable(
        decoded
            .map((item) => item?.toString().trim())
            .whereType<String>()
            .where((item) => item.isNotEmpty),
      );
    }
  } catch (_) {
    // A malformed legacy membership cannot be recovered safely.
  }
  return const <String>[];
}

Future<void> _upsertWithoutDelete(
  DatabaseExecutor db, {
  required String table,
  required String primaryKey,
  required Map<String, Object?> values,
}) async {
  final columns = values.keys.toList(growable: false);
  final updates = columns
      .where((column) => column != primaryKey)
      .map((column) => '$column = excluded.$column')
      .join(', ');
  final placeholders = List.filled(columns.length, '?').join(', ');
  await db.rawInsert(
    'INSERT INTO $table (${columns.join(', ')}) VALUES ($placeholders) '
    'ON CONFLICT($primaryKey) DO UPDATE SET $updates',
    columns.map((column) => values[column]).toList(growable: false),
  );
}

int? _nullableBoolToInt(bool? value) {
  return value == null ? null : (value ? 1 : 0);
}

bool? _nullableBool(Object? value) {
  return value == null ? null : _int(value) != 0;
}
