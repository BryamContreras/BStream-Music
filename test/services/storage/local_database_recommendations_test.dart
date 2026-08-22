import 'dart:io';

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/services/recommendations/recommendation_storage_models.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('recommendation storage', () {
    late Directory sandbox;
    late _TestLocalDatabaseService service;

    setUp(() async {
      sqfliteFfiInit();
      sandbox = await Directory.systemTemp.createTemp(
        'bstream-recommendation-storage-',
      );
      service = _TestLocalDatabaseService(
        p.join(sandbox.path, AppConstants.databaseName),
      );
    });

    tearDown(() async {
      await service.close();
      if (await sandbox.exists()) {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'upserts a playback session and aggregates top and recent seeds',
      () async {
        final startedAt = DateTime.utc(2026, 8, 20, 12);
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'session-1',
            trackId: 'remote-track-alias',
            videoId: 'video-1',
            title: 'Initial title',
            startedAt: startedAt,
            playedAt: startedAt.add(const Duration(seconds: 30)),
            listenedMs: 30000,
            isFavorite: true,
          ),
        );
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'session-1',
            trackId: 'remote-track-alias',
            videoId: 'video-1',
            title: 'Enriched title',
            startedAt: startedAt,
            playedAt: startedAt.add(const Duration(minutes: 3)),
            listenedMs: 175000,
            completed: true,
            isFavorite: null,
            thumbnailUrl: 'https://example.com/final.jpg',
          ),
        );

        final database = await service.database;
        final storedRows = await database.query('playback_events');
        expect(storedRows, hasLength(1));
        expect(storedRows.single['listened_ms'], 175000);
        expect(storedRows.single['completed'], 1);
        expect(storedRows.single['is_favorite'], 1);
        expect(storedRows.single['title'], 'Enriched title');

        await service.recordPlaybackEvent(
          _event(
            sessionId: 'session-2',
            trackId: 'video-1',
            videoId: 'video-1',
            title: 'Enriched title',
            startedAt: startedAt.add(const Duration(hours: 1)),
            playedAt: startedAt.add(const Duration(hours: 1, minutes: 1)),
            listenedMs: 60000,
          ),
        );
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'session-local',
            trackId: 'local-track',
            title: 'Short local song',
            source: PlaybackEventSource.local,
            startedAt: startedAt.add(const Duration(hours: 2)),
            playedAt: startedAt.add(const Duration(hours: 2, seconds: 10)),
            listenedMs: 10000,
            completed: true,
            artists: const <String>['Local Artist'],
            artistBrowseIds: const <String?>[],
          ),
        );
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'session-skipped',
            trackId: 'skipped-track',
            title: 'Skipped song',
            startedAt: startedAt.add(const Duration(hours: 3)),
            playedAt: startedAt.add(const Duration(hours: 3, seconds: 5)),
            listenedMs: 5000,
          ),
        );

        final top = await service.getTopRecommendationSeeds();
        expect(top, hasLength(2));
        expect(top.first.trackKey, 'video-1');
        expect(top.first.videoId, 'video-1');
        expect(top.first.playCount, 2);
        expect(top.first.totalListenedMs, 235000);
        expect(top.first.completedCount, 1);
        expect(top.first.isFavorite, isTrue);
        expect(top.first.artistBrowseIds, const <String?>['UC-artist', null]);
        expect(top.first.canQueryYouTube, isTrue);

        final recent = await service.getRecentRecommendationSeeds();
        expect(recent.map((seed) => seed.trackKey), <String>[
          'local-track',
          'video-1',
        ]);
        expect(recent.first.canQueryYouTube, isFalse);
        expect(
          await service.getRecentRecommendationSeeds(
            since: startedAt.add(const Duration(hours: 2, minutes: 1)),
          ),
          isEmpty,
        );
      },
    );

    test(
      'keeps track key consistent when a later snapshot omits video id',
      () async {
        final startedAt = DateTime.utc(2026, 8, 20, 12);
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'stable-session',
            trackId: 'initial-alias',
            videoId: 'video-stable',
            title: 'Initial',
            startedAt: startedAt,
            playedAt: startedAt.add(const Duration(seconds: 30)),
            listenedMs: 30000,
          ),
        );
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'stable-session',
            trackId: 'later-alias',
            title: 'Enriched without video id',
            startedAt: startedAt,
            playedAt: startedAt.add(const Duration(minutes: 2)),
            listenedMs: 120000,
            completed: true,
          ),
        );

        final database = await service.database;
        final row = (await database.query('playback_events')).single;
        expect(row['track_key'], 'video-stable');
        expect(row['video_id'], 'video-stable');
        expect(
          (await service.getTopRecommendationSeeds()).single.trackKey,
          'video-stable',
        );
      },
    );

    test('replaces related snapshots, deduplicates and enforces TTL', () async {
      final fetchedAt = DateTime.utc(2026, 8, 20);
      await service.upsertRelatedCandidates(
        seedKey: 'seed-video',
        fetchedAt: fetchedAt,
        candidates: <RelatedTrackCandidate>[
          _candidate(videoId: 'candidate-1', rank: 5),
          _candidate(videoId: 'candidate-1', rank: 1),
          _candidate(videoId: 'candidate-2', rank: 2),
        ],
      );

      final fresh = await service.getRelatedCandidates(
        'seed-video',
        now: fetchedAt.add(const Duration(days: 6)),
      );
      expect(fresh.map((candidate) => candidate.videoId), <String?>[
        'candidate-1',
        'candidate-2',
      ]);
      expect(fresh.map((candidate) => candidate.rank), <int>[1, 2]);
      expect(fresh.first.fetchedAt, fetchedAt);
      expect(fresh.first.artistBrowseIds, const <String?>['UC-related']);

      expect(
        await service.getRelatedCandidates(
          'seed-video',
          now: fetchedAt.add(const Duration(days: 7)),
        ),
        isEmpty,
      );

      await service.upsertRelatedCandidates(
        seedKey: 'seed-video',
        fetchedAt: fetchedAt.add(const Duration(days: 8)),
        candidates: <RelatedTrackCandidate>[
          _candidate(videoId: 'candidate-3', rank: 0),
        ],
      );
      final replaced = await service.getRelatedCandidates(
        'seed-video',
        now: fetchedAt.add(const Duration(days: 8)),
      );
      expect(replaced.single.videoId, 'candidate-3');
    });

    test('round-trips a JSON feed and preserves expired content', () async {
      final generatedAt = DateTime.utc(2026, 8, 20);
      final feed = RecommendationFeedCache(
        feedKey: 'home',
        payload: <String, Object?>{
          'sections': <Object?>[
            <String, Object?>{
              'title': 'Because you listened',
              'videoIds': <String>['one', 'two'],
            },
          ],
          'revision': 2,
        },
        generatedAt: generatedAt,
        expiresAt: generatedAt.add(const Duration(hours: 12)),
      );
      await service.saveRecommendationFeed(feed);

      final restored = await service.loadRecommendationFeed('home');
      expect(restored, isNotNull);
      expect(restored!.payload, feed.payload);
      expect(restored.generatedAt, generatedAt);
      expect(
        restored.isExpiredAt(generatedAt.add(const Duration(hours: 13))),
        isTrue,
      );
      expect(await service.loadRecommendationFeed('missing'), isNull);
    });

    test('aggregates and limits seed rankings inside SQLite', () async {
      final base = DateTime.utc(2026, 8, 1);
      for (var index = 0; index < 40; index++) {
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'bounded-$index',
            trackId: 'video-$index',
            videoId: 'video-$index',
            title: 'Song $index',
            startedAt: base.add(Duration(minutes: index)),
            playedAt: base.add(Duration(minutes: index, seconds: 45)),
            listenedMs: 30000 + (index * 1000),
            isFavorite: index == 0 ? true : null,
          ),
        );
      }

      final top = await service.getTopRecommendationSeeds(limit: 3);
      expect(top, hasLength(3));
      expect(top.map((seed) => seed.trackKey), <String>[
        'video-0',
        'video-39',
        'video-38',
      ]);
      final recent = await service.getRecentRecommendationSeeds(limit: 4);
      expect(recent.map((seed) => seed.trackKey), <String>[
        'video-39',
        'video-38',
        'video-37',
        'video-36',
      ]);
      await expectLater(
        service.getTopRecommendationSeeds(limit: 0),
        throwsArgumentError,
      );
    });

    test('prunes events by age and count without touching favorites', () async {
      await service.close();
      service = _TestLocalDatabaseService(
        p.join(sandbox.path, AppConstants.databaseName),
        retentionPolicy: const PlaybackEventRetentionPolicy(
          maxAge: null,
          maxEvents: null,
        ),
      );
      final now = DateTime.utc(2026, 8, 20);
      await service.saveLocalTrack(
        LocalTrack(
          id: 'favorite-download',
          title: 'Favorite download',
          artist: 'Artist',
          filePath: p.join(sandbox.path, 'favorite.m4a'),
          addedAt: now,
        ),
      );
      await service.savePlaylist(
        Playlist(
          id: Playlist.favoritesId,
          name: 'Favorites',
          trackIds: const <String>['favorite-download'],
          createdAt: now,
          updatedAt: now,
        ),
      );

      final playedAt = <DateTime>[
        DateTime.utc(2024),
        now.subtract(const Duration(days: 4)),
        now.subtract(const Duration(days: 3)),
        now.subtract(const Duration(days: 2)),
        now.subtract(const Duration(days: 1)),
      ];
      for (var index = 0; index < playedAt.length; index++) {
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'retained-$index',
            trackId: 'retained-$index',
            videoId: 'retained-$index',
            title: 'Retained $index',
            startedAt: playedAt[index].subtract(const Duration(minutes: 1)),
            playedAt: playedAt[index],
            listenedMs: 60000,
          ),
        );
      }

      final generationBefore = service.recommendationGeneration;
      final result = await service.prunePlaybackEvents(
        policy: const PlaybackEventRetentionPolicy(
          maxAge: Duration(days: 30),
          maxEvents: 3,
        ),
        now: now,
      );
      expect(result.removedByAge, 1);
      expect(result.removedByCount, 1);
      expect(result.totalRemoved, 2);
      expect(service.recommendationGeneration, generationBefore + 1);

      final database = await service.database;
      final remaining = await database.query(
        'playback_events',
        columns: const <String>['session_id'],
        orderBy: 'played_at DESC, session_id DESC',
      );
      expect(remaining.map((row) => row['session_id']), <String>[
        'retained-4',
        'retained-3',
        'retained-2',
      ]);
      expect((await service.getLocalTracks()).single.id, 'favorite-download');
      final favorites = (await service.getPlaylists()).single;
      expect(favorites.id, Playlist.favoritesId);
      expect(favorites.trackIds, const <String>['favorite-download']);
    });

    test('automatically applies a configurable event cap', () async {
      await service.close();
      service = _TestLocalDatabaseService(
        p.join(sandbox.path, AppConstants.databaseName),
        retentionPolicy: const PlaybackEventRetentionPolicy(
          maxAge: null,
          maxEvents: 2,
          pruneEveryWrites: 1,
        ),
      );
      final now = DateTime.utc(2026, 8, 20);
      for (var index = 0; index < 3; index++) {
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'automatic-$index',
            trackId: 'automatic-$index',
            videoId: 'automatic-$index',
            title: 'Automatic $index',
            startedAt: now.add(Duration(minutes: index)),
            playedAt: now.add(Duration(minutes: index, seconds: 30)),
            listenedMs: 30000,
          ),
        );
      }

      final database = await service.database;
      final countRows = await database.rawQuery(
        'SELECT COUNT(*) AS event_count FROM playback_events',
      );
      final count = (countRows.single['event_count']! as num).toInt();
      expect(count, 2);
      final recent = await service.getRecentRecommendationSeeds(limit: 2);
      expect(recent.map((seed) => seed.trackKey), <String>[
        'automatic-2',
        'automatic-1',
      ]);
    });

    test(
      'pruning the final event clears old feeds and rejects late cache writes',
      () async {
        final now = DateTime.utc(2026, 8, 20);
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'last-history-session',
            trackId: 'last-video',
            videoId: 'last-video',
            title: 'Last history track',
            startedAt: now,
            playedAt: now.add(const Duration(seconds: 30)),
            listenedMs: 30000,
          ),
        );
        final historyGeneration = service.recommendationGeneration;
        expect(
          await service.saveRecommendationFeed(
            RecommendationFeedCache(
              feedKey: 'personalized-home-v1',
              payload: const <String, Object?>{'old': true},
              generatedAt: now,
              expiresAt: now.add(const Duration(hours: 1)),
            ),
            expectedGeneration: historyGeneration,
          ),
          isTrue,
        );

        final pruning = service.prunePlaybackEvents(
          policy: const PlaybackEventRetentionPolicy(
            maxAge: null,
            maxEvents: 0,
            relatedCandidateMaxAge: null,
          ),
          now: now,
        );
        final racingWrite = service.saveRecommendationFeed(
          RecommendationFeedCache(
            feedKey: 'personalized-home-v1',
            payload: const <String, Object?>{'racing': true},
            generatedAt: now,
            expiresAt: now.add(const Duration(hours: 1)),
          ),
          expectedGeneration: historyGeneration,
        );
        final result = await pruning;
        await racingWrite;

        expect(result.removedByCount, 1);
        expect(service.recommendationGeneration, historyGeneration + 1);
        expect(
          await service.loadRecommendationFeed('personalized-home-v1'),
          isNull,
        );
        expect(
          await service.saveRecommendationFeed(
            RecommendationFeedCache(
              feedKey: 'personalized-home-v1',
              payload: const <String, Object?>{'late': true},
              generatedAt: now,
              expiresAt: now.add(const Duration(hours: 1)),
            ),
            expectedGeneration: historyGeneration,
          ),
          isFalse,
        );
        expect(
          await service.loadRecommendationFeed('personalized-home-v1'),
          isNull,
        );
      },
    );

    test('prunes expired and orphaned related snapshots', () async {
      await service.close();
      service = _TestLocalDatabaseService(
        p.join(sandbox.path, AppConstants.databaseName),
        retentionPolicy: const PlaybackEventRetentionPolicy(
          maxAge: null,
          maxEvents: null,
          relatedCandidateMaxAge: Duration(days: 7),
        ),
      );
      final now = DateTime.utc(2026, 8, 20);
      for (final seed in const <String>['fresh-seed', 'expired-seed']) {
        await service.recordPlaybackEvent(
          _event(
            sessionId: 'session-$seed',
            trackId: seed,
            videoId: seed,
            title: seed,
            startedAt: now.subtract(const Duration(minutes: 1)),
            playedAt: now,
            listenedMs: 60000,
          ),
        );
      }
      await service.upsertRelatedCandidates(
        seedKey: 'fresh-seed',
        fetchedAt: now,
        candidates: <RelatedTrackCandidate>[
          _candidate(videoId: 'fresh-candidate', rank: 0),
        ],
      );
      await service.upsertRelatedCandidates(
        seedKey: 'expired-seed',
        fetchedAt: now.subtract(const Duration(days: 8)),
        candidates: <RelatedTrackCandidate>[
          _candidate(videoId: 'expired-candidate', rank: 0),
        ],
      );
      await service.upsertRelatedCandidates(
        seedKey: 'orphan-seed',
        fetchedAt: now,
        candidates: <RelatedTrackCandidate>[
          _candidate(videoId: 'orphan-candidate', rank: 0),
        ],
      );

      final result = await service.prunePlaybackEvents(now: now);

      expect(result.removedRelatedCandidates, 2);
      expect(
        await service.getRelatedCandidates('fresh-seed', now: now),
        hasLength(1),
      );
      expect(
        await service.getRelatedCandidates('expired-seed', now: now),
        isEmpty,
      );
      expect(
        await service.getRelatedCandidates('orphan-seed', now: now),
        isEmpty,
      );
    });

    test('rejects cache writes from an obsolete history generation', () async {
      final now = DateTime.utc(2026, 8, 20);
      final originalGeneration = service.recommendationGeneration;
      await service.recordPlaybackEvent(
        _event(
          sessionId: 'new-session',
          trackId: 'video-1',
          videoId: 'video-1',
          title: 'Song',
          startedAt: now,
          playedAt: now.add(const Duration(seconds: 30)),
          listenedMs: 30000,
        ),
      );
      final currentGeneration = service.recommendationGeneration;
      expect(currentGeneration, originalGeneration + 1);

      expect(
        await service.upsertRelatedCandidates(
          seedKey: 'video-1',
          candidates: <RelatedTrackCandidate>[
            _candidate(videoId: 'stale-related', rank: 0),
          ],
          expectedGeneration: originalGeneration,
        ),
        isFalse,
      );
      expect(
        await service.saveRecommendationFeed(
          RecommendationFeedCache(
            feedKey: 'home',
            payload: const <String, Object?>{'stale': true},
            generatedAt: now,
            expiresAt: now.add(const Duration(hours: 1)),
          ),
          expectedGeneration: originalGeneration,
        ),
        isFalse,
      );
      expect(await service.getRelatedCandidates('video-1'), isEmpty);
      expect(await service.loadRecommendationFeed('home'), isNull);

      expect(
        await service.saveRecommendationFeed(
          RecommendationFeedCache(
            feedKey: 'home',
            payload: const <String, Object?>{'fresh': true},
            generatedAt: now,
            expiresAt: now.add(const Duration(hours: 1)),
          ),
          expectedGeneration: currentGeneration,
        ),
        isTrue,
      );
      await service.clearRecommendationHistory();
      expect(
        await service.saveRecommendationFeed(
          RecommendationFeedCache(
            feedKey: 'home',
            payload: const <String, Object?>{'late': true},
            generatedAt: now,
            expiresAt: now.add(const Duration(hours: 1)),
          ),
          expectedGeneration: currentGeneration,
        ),
        isFalse,
      );
      expect(await service.loadRecommendationFeed('home'), isNull);
    });

    test('clearRecommendationHistory keeps downloads and playlists', () async {
      final now = DateTime.utc(2026, 8, 20);
      await service.saveLocalTrack(
        LocalTrack(
          id: 'download-1',
          title: 'Download',
          artist: 'Artist',
          filePath: p.join(sandbox.path, 'download.m4a'),
          addedAt: now,
          lastPlayedAt: now,
          lastPlayedPlaylistId: 'playlist-1',
        ),
      );
      await service.savePlaylist(
        Playlist(
          id: 'playlist-1',
          name: 'Playlist',
          trackIds: const <String>['download-1'],
          createdAt: now,
          updatedAt: now,
        ),
      );
      await service.recordPlaybackEvent(
        _event(
          sessionId: 'session-1',
          trackId: 'video-1',
          videoId: 'video-1',
          title: 'Song',
          startedAt: now,
          playedAt: now.add(const Duration(minutes: 1)),
          listenedMs: 60000,
        ),
      );
      await service.upsertRelatedCandidates(
        seedKey: 'video-1',
        candidates: <RelatedTrackCandidate>[
          _candidate(videoId: 'candidate-1', rank: 0),
        ],
      );
      await service.saveRecommendationFeed(
        RecommendationFeedCache(
          feedKey: 'home',
          payload: const <String, Object?>{'sections': <Object?>[]},
          generatedAt: now,
          expiresAt: now.add(const Duration(days: 1)),
        ),
      );

      final generationBeforeClear = service.recommendationGeneration;
      await service.clearRecommendationHistory();
      expect(service.recommendationGeneration, generationBeforeClear + 1);

      expect(await service.getTopRecommendationSeeds(), isEmpty);
      expect(await service.getRelatedCandidates('video-1'), isEmpty);
      expect(await service.loadRecommendationFeed('home'), isNull);
      final retainedTrack = (await service.getLocalTracks()).single;
      expect(retainedTrack.id, 'download-1');
      expect(retainedTrack.lastPlayedAt, isNull);
      expect(retainedTrack.lastPlayedPlaylistId, isNull);
      expect(await service.getHistory(), isEmpty);
      expect((await service.getPlaylists()).single.id, 'playlist-1');
    });
  });

  test(
    'migrates v5 to recommendation schema without losing the library',
    () async {
      sqfliteFfiInit();
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-recommendation-migration-',
      );
      final databasePath = p.join(sandbox.path, 'library.db');
      final legacyDatabase = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 5,
          onCreate: (database, _) async {
            await database.execute('''
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
              metadata_source TEXT NOT NULL DEFAULT 'youtube',
              source_id TEXT,
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
      await legacyDatabase.insert('local_tracks', <String, Object?>{
        'id': 'legacy-track',
        'title': 'Legacy track',
        'artist': 'Legacy artist',
        'file_path': p.join(sandbox.path, 'legacy.m4a'),
        'source_url': 'https://youtu.be/V5Legacy001',
        'artists_json': '["Legacy artist"]',
        'metadata_source': 'youtube',
        'added_at': DateTime.utc(2025).toIso8601String(),
      });
      await legacyDatabase.close();

      final service = _TestLocalDatabaseService(databasePath);
      addTearDown(() async {
        await service.close();
        if (await sandbox.exists()) {
          await sandbox.delete(recursive: true);
        }
      });

      final database = await service.database;
      expect(
        (await database.rawQuery('PRAGMA user_version')).single['user_version'],
        AppConstants.databaseVersion,
      );
      final localTrackColumns = await database.rawQuery(
        'PRAGMA table_info(local_tracks)',
      );
      expect(
        localTrackColumns.map((row) => row['name']),
        contains('artist_browse_ids_json'),
      );
      final tables = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      expect(
        tables.map((row) => row['name']),
        containsAll(const <String>[
          'playback_events',
          'related_track_candidates',
          'recommendation_feed_cache',
        ]),
      );
      final indexes = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      );
      expect(
        indexes.map((row) => row['name']),
        containsAll(const <String>[
          'idx_playback_events_track_played_session',
          'idx_playback_events_played_session',
        ]),
      );
      final migratedTrack = (await service.getLocalTracks()).single;
      expect(migratedTrack.id, 'legacy-track');
      expect(migratedTrack.sourceId, 'V5Legacy001');
    },
  );

  test(
    'migrates a v6 fixture and replaces its legacy playback indexes',
    () async {
      sqfliteFfiInit();
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-v6-recommendation-migration-',
      );
      final databasePath = p.join(sandbox.path, 'library.db');
      final creator = _TestLocalDatabaseService(databasePath);
      final now = DateTime.utc(2026, 8, 20);
      await creator.recordPlaybackEvent(
        _event(
          sessionId: 'v6-session',
          trackId: 'v6-video',
          videoId: 'v6-video',
          title: 'V6 song',
          startedAt: now,
          playedAt: now.add(const Duration(minutes: 1)),
          listenedMs: 60000,
        ),
      );
      await creator.close();

      final legacy = await databaseFactoryFfi.openDatabase(databasePath);
      await legacy.execute(
        'DROP INDEX IF EXISTS idx_playback_events_track_played_session',
      );
      await legacy.execute(
        'DROP INDEX IF EXISTS idx_playback_events_played_session',
      );
      await legacy.execute(
        'CREATE INDEX idx_playback_events_track_key_played_at '
        'ON playback_events(track_key, played_at)',
      );
      await legacy.execute(
        'CREATE INDEX idx_playback_events_played_at '
        'ON playback_events(played_at)',
      );
      await legacy.setVersion(6);
      await legacy.close();

      final service = _TestLocalDatabaseService(databasePath);
      addTearDown(() async {
        await service.close();
        if (await sandbox.exists()) {
          await sandbox.delete(recursive: true);
        }
      });
      final database = await service.database;
      final indexes = (await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      )).map((row) => row['name']).toSet();

      expect(await database.getVersion(), AppConstants.databaseVersion);
      expect(indexes, contains('idx_playback_events_track_played_session'));
      expect(indexes, contains('idx_playback_events_played_session'));
      expect(
        indexes,
        isNot(contains('idx_playback_events_track_key_played_at')),
      );
      expect(indexes, isNot(contains('idx_playback_events_played_at')));
      expect(
        (await service.getTopRecommendationSeeds()).single.trackKey,
        'v6-video',
      );
    },
  );

  test(
    'rejects incomplete v7 backups and repairs an active v7 schema',
    () async {
      sqfliteFfiInit();
      final sandbox = await Directory.systemTemp.createTemp(
        'bstream-v7-schema-repair-',
      );
      final databasePath = p.join(sandbox.path, 'library.db');
      final creator = _TestLocalDatabaseService(databasePath);
      await creator.saveLocalTrack(
        LocalTrack(
          id: 'preserved-track',
          title: 'Preserved',
          artist: 'Artist',
          filePath: p.join(sandbox.path, 'preserved.m4a'),
          addedAt: DateTime.utc(2026, 8, 20),
        ),
      );
      await creator.close();

      final incomplete = await databaseFactoryFfi.openDatabase(databasePath);
      await incomplete.execute(
        'ALTER TABLE local_tracks DROP COLUMN artist_browse_ids_json',
      );
      await incomplete.execute('DROP TABLE recommendation_feed_cache');
      await incomplete.execute('DROP TABLE related_track_candidates');
      await incomplete.execute('DROP TABLE playback_events');
      await incomplete.execute('DROP INDEX idx_local_tracks_source_id');
      await incomplete.execute(
        'CREATE INDEX idx_local_tracks_source_id ON local_tracks(title)',
      );
      await incomplete.close();

      final service = _TestLocalDatabaseService(databasePath);
      addTearDown(() async {
        await service.close();
        if (await sandbox.exists()) {
          await sandbox.delete(recursive: true);
        }
      });
      await expectLater(
        service.validateBackupDatabase(databasePath),
        throwsA(isA<FormatException>()),
      );

      final repaired = await service.database;
      final tables = (await repaired.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name']).toSet();
      expect(
        tables,
        containsAll(const <String>{
          'playback_events',
          'related_track_candidates',
          'recommendation_feed_cache',
        }),
      );
      final localColumns = (await repaired.rawQuery(
        'PRAGMA table_info(local_tracks)',
      )).map((row) => row['name']).toSet();
      expect(localColumns, contains('artist_browse_ids_json'));
      final sourceIdIndex = await repaired.rawQuery(
        'PRAGMA index_info(idx_local_tracks_source_id)',
      );
      expect(sourceIdIndex.map((row) => row['name']), const <String>[
        'source_id',
      ]);
      expect((await service.getLocalTracks()).single.id, 'preserved-track');
    },
  );
}

PlaybackEvent _event({
  required String sessionId,
  required String trackId,
  required String title,
  required DateTime startedAt,
  required DateTime playedAt,
  required int listenedMs,
  String? videoId,
  PlaybackEventSource source = PlaybackEventSource.streaming,
  bool completed = false,
  bool? isFavorite,
  bool? isLiked,
  String? thumbnailUrl,
  List<String> artists = const <String>['Artist One', 'Artist Two'],
  List<String?> artistBrowseIds = const <String?>['UC-artist', null],
}) {
  return PlaybackEvent(
    sessionId: sessionId,
    trackId: trackId,
    videoId: videoId,
    title: title,
    artists: artists,
    artistBrowseIds: artistBrowseIds,
    album: 'Album',
    thumbnailUrl: thumbnailUrl,
    durationMs: 180000,
    source: source,
    startedAt: startedAt,
    playedAt: playedAt,
    listenedMs: listenedMs,
    completed: completed,
    isFavorite: isFavorite,
    isLiked: isLiked,
  );
}

RelatedTrackCandidate _candidate({required String videoId, required int rank}) {
  return RelatedTrackCandidate(
    trackId: videoId,
    videoId: videoId,
    title: 'Related $videoId',
    artists: const <String>['Related Artist'],
    artistBrowseIds: const <String?>['UC-related'],
    album: 'Related Album',
    thumbnailUrl: 'https://example.com/$videoId.jpg',
    durationMs: 190000,
    rank: rank,
  );
}

class _TestLocalDatabaseService extends LocalDatabaseService {
  _TestLocalDatabaseService(
    this.path, {
    PlaybackEventRetentionPolicy retentionPolicy =
        const PlaybackEventRetentionPolicy(),
  }) : super(playbackEventRetentionPolicy: retentionPolicy);

  final String path;

  @override
  Future<String> databasePath() async => path;
}
