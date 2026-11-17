import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/services/storage/backup_service.dart';
import 'package:bstream_music/services/storage/library_operation_coordinator.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _now = DateTime.utc(2026, 11, 16, 12);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory sandbox;
  late String sourceMedia;
  late String targetMedia;
  late _TestDatabase source;
  late _TestDatabase target;
  late LibraryOperationCoordinator coordinator;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('bstream-playlist-zip-');
    sourceMedia = p.join(sandbox.path, 'source-media');
    targetMedia = p.join(sandbox.path, 'target-media');
    source = _TestDatabase(
      p.join(sandbox.path, 'source', AppConstants.databaseName),
    );
    target = _TestDatabase(
      p.join(sandbox.path, 'target', AppConstants.databaseName),
    );
    coordinator = LibraryOperationCoordinator();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'getTemporaryDirectory'
              ? p.join(sandbox.path, 'temporary')
              : null,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await source.close();
    await target.close();
    await coordinator.dispose();
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  Future<({File file, Archive archive})> exportLibrary({
    String downloadedFolderName = 'Downloaded songs',
  }) async {
    final file = await BackupService(source, coordinator).createBackupFile(
      mediaRoot: sourceMedia,
      outputPath: p.join(sandbox.path, 'library.zip'),
      downloadedFolderName: downloadedFolderName,
    );
    return (
      file: file,
      archive: ZipDecoder().decodeBytes(await file.readAsBytes()),
    );
  }

  test(
    'ten playlist songs and unassigned downloads export into separate folders and restore',
    () async {
      final tracks = <LocalTrack>[
        for (var index = 0; index < 12; index++)
          await _saveTrack(source, sourceMedia, 'song-$index'),
      ];
      await _playlist(
        source,
        'playlist',
        'Mi lista',
        tracks.take(10).map((track) => track.id).toList(),
      );
      final result = await exportLibrary(
        downloadedFolderName: 'Canciones descargadas',
      );
      final index = _index(result.archive);
      final paths = _trackPaths(index);
      final audioFiles = _paths(index, 'audioFiles');
      expect(audioFiles, hasLength(12));
      expect(audioFiles.toSet(), hasLength(12));
      expect(paths, hasLength(12));
      for (var number = 0; number < 10; number++) {
        expect(paths['song-$number'], startsWith('audio/Mi lista/'));
      }
      for (final id in ['song-10', 'song-11']) {
        expect(paths[id], startsWith('audio/Canciones descargadas/'));
      }
      for (final path in audioFiles) {
        expect(result.archive.find(path), isNotNull);
      }
      final playlistFiles = _paths(index, 'playlistFiles');
      expect(playlistFiles, hasLength(1));
      expect(_references(result.archive, playlistFiles.single), [
        for (var number = 0; number < 10; number++) paths['song-$number'],
      ]);

      await BackupService(
        target,
        coordinator,
      ).restoreBackupFile(backupPath: result.file.path, mediaRoot: targetMedia);
      final restored = await target.getLocalTracks();
      expect(restored, hasLength(12));
      for (final track in restored) {
        expect(
          track.filePath,
          p.join(targetMedia, p.joinAll(paths[track.id]!.split('/'))),
        );
        expect(await File(track.filePath).readAsString(), 'audio:${track.id}');
      }
      final playlist = (await target.getCatalogPlaylist('playlist'))!;
      expect(
        playlist.entries.map((entry) => entry.localTrackId),
        tracks.take(10).map((track) => track.id),
      );
    },
  );

  test(
    'shared songs have one audio file while M3U preserves other playlists and repeated occurrences',
    () async {
      await _saveTrack(source, sourceMedia, 'shared');
      await _saveTrack(source, sourceMedia, 'second-only');
      await _playlist(source, 'second', 'Fiesta', [
        'shared',
        'second-only',
        'shared',
      ], now: _now);
      await _playlist(source, 'first', 'Viaje', [
        'shared',
      ], now: _now.add(const Duration(days: 1)));
      final result = await exportLibrary();
      final index = _index(result.archive);
      final tracks = _trackPaths(index);
      expect(_paths(index, 'audioFiles'), hasLength(2));
      expect(tracks['shared'], startsWith('audio/Viaje/'));
      expect(tracks['second-only'], startsWith('audio/Fiesta/'));
      final fiesta = _paths(
        index,
        'playlistFiles',
      ).singleWhere((path) => path.startsWith('audio/Fiesta/'));
      expect(_text(result.archive, fiesta), contains('../Viaje/'));
      expect(_references(result.archive, fiesta), [
        tracks['shared'],
        tracks['second-only'],
        tracks['shared'],
      ]);
      expect(
        result.archive.where(
          (file) => file.isFile && _textIfAudio(file) == 'audio:shared',
        ),
        hasLength(1),
      );

      await BackupService(
        target,
        coordinator,
      ).restoreBackupFile(backupPath: result.file.path, mediaRoot: targetMedia);
      expect(
        (await target.getCatalogPlaylist(
          'first',
        ))!.entries.map((entry) => entry.localTrackId),
        ['shared'],
      );
      expect(
        (await target.getCatalogPlaylist(
          'second',
        ))!.entries.map((entry) => entry.localTrackId),
        ['shared', 'second-only', 'shared'],
      );
      expect(
        (await target.getLocalTracks())
            .singleWhere((track) => track.id == 'shared')
            .filePath,
        p.join(targetMedia, p.joinAll(tracks['shared']!.split('/'))),
      );
    },
  );

  test(
    'canonical catalog membership works without a cached local id and ignores deleted or missing entries',
    () async {
      const videoId = 'AbCdEfGhIj1';
      await _saveTrack(
        source,
        sourceMedia,
        'catalog-download',
        videoId: videoId,
      );
      await _saveTrack(source, sourceMedia, 'unassigned');
      await _saveTrack(source, sourceMedia, 'missing', writeFile: false);
      await _playlist(source, 'active', 'Catálogo', [], now: _now);
      await source.appendCatalogEntry(
        playlistId: 'active',
        entryId: 'catalog',
        track: CatalogTrack.youtube(videoId: videoId, title: 'Saved recording'),
        now: _now,
      );
      await source.appendCatalogEntry(
        playlistId: 'active',
        entryId: 'remote-only',
        track: CatalogTrack.youtube(
          videoId: 'BcDeFgHiJk2',
          title: 'Online only',
        ),
        now: _now,
      );
      await source.appendCatalogEntry(
        playlistId: 'active',
        entryId: 'missing',
        track: CatalogTrack.local(
          localTrackId: 'missing',
          title: 'Missing file',
        ),
        localTrackId: 'missing',
        now: _now,
      );
      await source.appendCatalogEntry(
        playlistId: 'active',
        entryId: 'removed',
        track: CatalogTrack.local(localTrackId: 'unassigned', title: 'Removed'),
        localTrackId: 'unassigned',
        now: _now,
      );
      await source.tombstoneCatalogEntry(
        playlistId: 'active',
        entryId: 'removed',
        now: _now,
      );
      await _playlist(source, 'deleted', 'Deleted folder', ['unassigned']);
      await source.tombstoneCatalogPlaylist(playlistId: 'deleted', now: _now);
      final result = await exportLibrary();
      final index = _index(result.archive);
      final paths = _trackPaths(index);
      expect(_paths(index, 'audioFiles'), hasLength(2));
      expect(paths['catalog-download'], startsWith('audio/Catálogo/'));
      expect(paths['unassigned'], startsWith('audio/Downloaded songs/'));
      expect(paths, isNot(contains('missing')));
      expect(_paths(index, 'playlistFiles'), hasLength(1));
      expect(
        _references(result.archive, _paths(index, 'playlistFiles').single),
        [paths['catalog-download']],
      );
      expect(
        result.archive.any((file) => file.name.contains('Deleted folder')),
        isFalse,
      );
    },
  );

  test(
    'tombstoned canonical occurrences override a stale unmigrated playlist projection',
    () async {
      await _saveTrack(source, sourceMedia, 'removed-song');
      await _saveTrack(source, sourceMedia, 'active-song');
      await _playlist(source, 'stale', 'Old playlist', ['removed-song']);
      await source.tombstoneCatalogEntry(
        playlistId: 'stale',
        entryId: 'stale-occurrence-0',
        now: _now,
      );
      // A partially migrated backup can retain the legacy downloaded-ID list.
      // Existing canonical tombstones must take precedence over that list.
      final database = await source.database;
      await database.update(
        'playlists',
        {
          'entries_migrated': 0,
          'track_ids': jsonEncode(['removed-song']),
        },
        where: 'id = ?',
        whereArgs: ['stale'],
      );
      await _playlist(source, 'active', 'Current playlist', ['active-song']);
      final result = await exportLibrary();
      final index = _index(result.archive);
      final paths = _trackPaths(index);
      expect(_paths(index, 'audioFiles'), hasLength(2));
      expect(paths['removed-song'], startsWith('audio/Downloaded songs/'));
      expect(paths['active-song'], startsWith('audio/Current playlist/'));
      expect(_paths(index, 'playlistFiles'), hasLength(1));
      expect(
        _references(result.archive, _paths(index, 'playlistFiles').single),
        [paths['active-song']],
      );
      expect(
        result.archive.any((file) => file.name.contains('Old playlist')),
        isFalse,
      );
    },
  );

  test(
    'portable folder names remain distinct and M3U metadata cannot inject paths',
    () async {
      final names = ['CON', 'mix', 'MIX', '../fiesta:*?', 'Downloaded songs'];
      for (var number = 0; number < names.length; number++) {
        final track = await _saveTrack(
          source,
          sourceMedia,
          'portable-$number',
          title: 'Tune\n../injected.mp3',
        );
        await _playlist(source, 'playlist-$number', names[number], [
          track.id,
        ], now: _now.add(Duration(minutes: number)));
      }
      final result = await exportLibrary();
      final index = _index(result.archive);
      final folders = _paths(index, 'audioFiles').map(p.posix.dirname).toList();
      expect(
        folders.map((folder) => folder.toLowerCase()).toSet(),
        hasLength(names.length),
      );
      for (final folder in folders) {
        final name = p.posix.basename(folder);
        expect(
          name,
          isNot(
            matches(
              RegExp(
                r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
                caseSensitive: false,
              ),
            ),
          ),
        );
        expect(name, isNot(matches(RegExp(r'[<>:"/\\|?*\x00-\x1f]'))));
        expect(name.endsWith('.') || name.endsWith(' '), isFalse);
        expect(p.posix.isWithin('audio', folder), isTrue);
      }
      for (final playlist in _paths(index, 'playlistFiles')) {
        final references = _references(result.archive, playlist);
        expect(references, hasLength(1));
        expect(result.archive.find(references.single), isNotNull);
        expect(references.single.contains('injected'), isFalse);
      }
    },
  );

  test(
    'without playlists exports the existing flat audio folder and remains restorable',
    () async {
      await _saveTrack(source, sourceMedia, 'single');
      final result = await exportLibrary();
      expect(result.archive.find('audio/single.mp3'), isNotNull);
      expect(result.archive.find('audio-index.json'), isNull);
      expect((_json(result.archive, 'manifest.json'))['schema'], 1);
      await BackupService(
        target,
        coordinator,
      ).restoreBackupFile(backupPath: result.file.path, mediaRoot: targetMedia);
      expect(
        (await target.getLocalTracks()).single.filePath,
        p.join(targetMedia, 'audio', 'single.mp3'),
      );
      expect(
        await File(p.join(targetMedia, 'audio', 'single.mp3')).readAsString(),
        'audio:single',
      );
    },
  );

  test(
    're-export after removing playlists flattens grouped music without losing same-named songs',
    () async {
      await _saveTrack(
        source,
        sourceMedia,
        'first-song',
        relativePath: p.join('disc-one', 'song.mp3'),
      );
      await _saveTrack(
        source,
        sourceMedia,
        'second-song',
        relativePath: p.join('disc-two', 'song.mp3'),
      );
      await _playlist(source, 'first', 'First playlist', ['first-song']);
      await _playlist(source, 'second', 'Second playlist', ['second-song']);
      final original = await exportLibrary();
      final originalPaths = _trackPaths(_index(original.archive));
      expect(p.posix.basename(originalPaths['first-song']!), 'song.mp3');
      expect(p.posix.basename(originalPaths['second-song']!), 'song.mp3');
      expect(
        p.posix.dirname(originalPaths['first-song']!),
        isNot(p.posix.dirname(originalPaths['second-song']!)),
      );
      await BackupService(target, coordinator).restoreBackupFile(
        backupPath: original.file.path,
        mediaRoot: targetMedia,
      );
      for (final playlist in await target.getCatalogPlaylists()) {
        await target.tombstoneCatalogPlaylist(
          playlistId: playlist.id,
          now: _now.add(const Duration(days: 2)),
        );
      }

      final flattenedFile = await BackupService(target, coordinator)
          .createBackupFile(
            mediaRoot: targetMedia,
            outputPath: p.join(sandbox.path, 'without-playlists.zip'),
          );
      final flattened = ZipDecoder().decodeBytes(
        await flattenedFile.readAsBytes(),
      );
      final index = _index(flattened);
      final audioFiles = _paths(index, 'audioFiles');
      expect(audioFiles, hasLength(2));
      expect(
        audioFiles.map((path) => path.toLowerCase()).toSet(),
        hasLength(2),
      );
      expect(audioFiles.map(p.posix.dirname).toSet(), {'audio'});
      expect(_paths(index, 'playlistFiles'), isEmpty);
      expect(
        flattened.where(
          (file) => file.isFile && file.name.startsWith('audio/'),
        ),
        hasLength(2),
      );

      final thirdMedia = p.join(sandbox.path, 'third-media');
      final third = _TestDatabase(
        p.join(sandbox.path, 'third', AppConstants.databaseName),
      );
      try {
        await BackupService(third, coordinator).restoreBackupFile(
          backupPath: flattenedFile.path,
          mediaRoot: thirdMedia,
        );
        final restored = await third.getLocalTracks();
        expect(restored.map((track) => track.id).toSet(), {
          'first-song',
          'second-song',
        });
        expect(restored.map((track) => track.filePath).toSet(), hasLength(2));
        expect(await third.getCatalogPlaylists(), isEmpty);
        for (final track in restored) {
          expect(p.dirname(track.filePath), p.join(thirdMedia, 'audio'));
          expect(
            await File(track.filePath).readAsString(),
            'audio:${track.id}',
          );
        }
      } finally {
        await third.close();
      }
    },
  );

  for (final presentPath in [p.join('Second', 'song.mp3'), 'song.mp3']) {
    test(
      'restoring never substitutes a missing same-named file when the present song is at $presentPath',
      () async {
        await _saveTrack(
          source,
          sourceMedia,
          'absent-song',
          relativePath: p.join('First', 'song.mp3'),
          writeFile: false,
        );
        await _saveTrack(
          source,
          sourceMedia,
          'present-song',
          relativePath: presentPath,
        );
        final result = await exportLibrary();
        final index = _index(result.archive);
        expect(_paths(index, 'audioFiles'), ['audio/song.mp3']);
        expect(_trackPaths(index), {'present-song': 'audio/song.mp3'});
        await BackupService(target, coordinator).restoreBackupFile(
          backupPath: result.file.path,
          mediaRoot: targetMedia,
        );
        final restored = await target.getLocalTracks();
        expect(restored.map((track) => track.id).toSet(), {
          'absent-song',
          'present-song',
        });
        final absent = restored.singleWhere(
          (track) => track.id == 'absent-song',
        );
        final present = restored.singleWhere(
          (track) => track.id == 'present-song',
        );
        expect(absent.title, 'absent-song');
        expect(absent.filePath, isNot(present.filePath));
        expect(
          p.isWithin(p.join(targetMedia, 'audio'), absent.filePath),
          isTrue,
        );
        expect(await File(absent.filePath).exists(), isFalse);
        expect(present.filePath, p.join(targetMedia, 'audio', 'song.mp3'));
        expect(
          await File(present.filePath).readAsString(),
          'audio:present-song',
        );
      },
    );
  }

  for (final tamper in [
    'missing-index',
    'unsafe-path',
    'missing-file',
    'case-collision',
    'unknown-track',
    'media-as-playlist',
    'invalid-playlist-header',
  ]) {
    test('schema 2 $tamper cannot replace the active library', () async {
      await _saveTrack(source, sourceMedia, 'source-track');
      await source.close();
      final savedDatabase = await File(source.path).readAsBytes();
      await _saveTrack(target, targetMedia, 'active-track');
      final activeFile = File(p.join(targetMedia, 'audio', 'active-track.mp3'));
      final auxiliaryOnly =
          tamper == 'media-as-playlist' || tamper == 'invalid-playlist-header';
      final audioPath = switch (tamper) {
        'unsafe-path' => 'audio/../escape.mp3',
        'media-as-playlist' => 'audio/List/source-track.mp3',
        'invalid-playlist-header' => 'audio/List/playlist.m3u8',
        _ => 'audio/Lista/source.mp3',
      };
      final audioFiles = <String>[audioPath];
      if (tamper == 'case-collision') {
        audioFiles.add('audio/lista/SOURCE.mp3');
      }
      final archive = Archive()
        ..add(
          ArchiveFile.string(
            'manifest.json',
            jsonEncode({
              'app': AppConstants.appName,
              'schema': 2,
              'database': AppConstants.databaseName,
              'audioIndex': 'audio-index.json',
            }),
          ),
        )
        ..add(
          ArchiveFile.bytes(
            'database/${AppConstants.databaseName}',
            savedDatabase,
          ),
        );
      if (tamper != 'missing-index') {
        archive.add(
          ArchiveFile.string(
            'audio-index.json',
            jsonEncode({
              'schema': 1,
              'audioFiles': auxiliaryOnly ? <String>[] : audioFiles,
              'playlistFiles': auxiliaryOnly ? [audioPath] : <String>[],
              'tracks': auxiliaryOnly
                  ? <String, String>{}
                  : {
                      (tamper == 'unknown-track'
                              ? 'unknown-track'
                              : 'source-track'):
                          audioPath,
                    },
            }),
          ),
        );
      }
      if (tamper != 'missing-file') {
        for (final path in audioFiles) {
          archive.add(ArchiveFile.string(path, 'malformed replacement'));
        }
      }
      final file = File(p.join(sandbox.path, 'tampered.zip'));
      await file.writeAsBytes(ZipEncoder().encodeBytes(archive));
      await expectLater(
        BackupService(
          target,
          coordinator,
        ).restoreBackupFile(backupPath: file.path, mediaRoot: targetMedia),
        throwsFormatException,
      );
      expect((await target.getLocalTracks()).map((track) => track.id), [
        'active-track',
      ]);
      expect(await activeFile.readAsString(), 'audio:active-track');
      expect(await File(p.join(targetMedia, 'escape.mp3')).exists(), isFalse);
    });
  }
}

Future<LocalTrack> _saveTrack(
  LocalDatabaseService database,
  String media,
  String id, {
  String? title,
  String? videoId,
  String? relativePath,
  bool writeFile = true,
}) async {
  final file = File(p.join(media, 'audio', relativePath ?? '$id.mp3'));
  if (writeFile) {
    await file.create(recursive: true);
    await file.writeAsString('audio:$id');
  }
  final track = LocalTrack(
    id: id,
    title: title ?? id,
    artist: 'Artist',
    filePath: file.path,
    sourceId: videoId,
    duration: const Duration(seconds: 180),
    addedAt: _now,
  );
  await database.saveLocalTrack(track);
  if (videoId != null) {
    await database.linkCatalogDownload(
      videoId: videoId,
      localTrackId: id,
      now: _now,
    );
  }
  return track;
}

Future<void> _playlist(
  LocalDatabaseService database,
  String id,
  String name,
  List<String> tracks, {
  DateTime? now,
}) async {
  final time = now ?? _now;
  await database.createCatalogPlaylist(id: id, name: name, now: time);
  for (var number = 0; number < tracks.length; number++) {
    final trackId = tracks[number];
    await database.appendCatalogEntry(
      playlistId: id,
      entryId: '$id-occurrence-$number',
      track: CatalogTrack.local(localTrackId: trackId, title: trackId),
      localTrackId: trackId,
      now: time,
    );
  }
}

Map<String, dynamic> _json(Archive archive, String path) =>
    jsonDecode(_text(archive, path)) as Map<String, dynamic>;

Map<String, dynamic> _index(Archive archive) {
  expect(_json(archive, 'manifest.json')['schema'], 2);
  expect(archive.find('audio-index.json'), isNotNull);
  return _json(archive, 'audio-index.json');
}

List<String> _paths(Map<String, dynamic> index, String name) =>
    (index[name] as List<dynamic>).cast<String>();

Map<String, String> _trackPaths(Map<String, dynamic> index) =>
    (index['tracks'] as Map<String, dynamic>).cast<String, String>();

String _text(Archive archive, String path) =>
    utf8.decode(archive.find(path)!.content);

String _textIfAudio(ArchiveFile file) =>
    file.name.endsWith('.mp3') ? utf8.decode(file.content) : '';

List<String> _references(Archive archive, String playlistPath) =>
    const LineSplitter()
        .convert(_text(archive, playlistPath))
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .map(
          (line) => p.posix.normalize(
            p.posix.join(p.posix.dirname(playlistPath), line),
          ),
        )
        .toList();

class _TestDatabase extends LocalDatabaseService {
  _TestDatabase(this.path);
  final String path;

  @override
  Future<String> databasePath() async => path;
}
