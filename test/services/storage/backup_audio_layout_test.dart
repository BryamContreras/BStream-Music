import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/storage/backup_audio_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late Directory snapshot;
  late String originalRoot;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('bstream_audio_layout_');
    snapshot = Directory(p.join(sandbox.path, 'snapshot', 'audio'));
    await snapshot.create(recursive: true);
    originalRoot = p.join(sandbox.path, 'original');
  });

  tearDown(() async {
    final target = sandbox.absolute.path;
    if (!p.isWithin(Directory.systemTemp.absolute.path, target)) {
      throw StateError('Refusing to remove a directory outside the test root.');
    }
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  Future<File> audio(String relative) async {
    final file = File(p.join(snapshot.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString('saved:$relative');
    return file;
  }

  Map<String, Object?> track(
    String id,
    String relative, {
    String? catalog,
    String title = 'Title',
    String artist = 'Artist',
  }) => {
    'id': id,
    'file_path': p.join(originalRoot, 'audio', relative),
    'catalog_key': catalog,
    'title': title,
    'artist': artist,
    'duration_seconds': 125,
  };

  Future<BackupAudioLayout> build({
    List<Map<String, Object?>> tracks = const [],
    List<Map<String, Object?>> playlists = const [],
    List<Map<String, Object?>> entries = const [],
    String downloadedFolderName = 'Downloaded songs',
  }) => BackupAudioLayout.build(
    snapshotAudioRoot: snapshot.path,
    originalMediaRoot: originalRoot,
    metadata: (tracks: tracks, playlists: playlists, entries: entries),
    downloadedFolderName: downloadedFolderName,
  );

  test(
    'without playable playlists keeps one audio folder and every file',
    () async {
      await audio('a.m4a');
      await audio('untracked.mp3');
      final layout = await build(
        tracks: [
          track('a', 'a.m4a'),
          track('missing', 'missing.m4a'),
          {
            ...track('external', 'a.m4a'),
            'file_path': p.join(sandbox.path, 'other', 'a.m4a'),
          },
        ],
        playlists: [
          _playlist('empty', 'Empty'),
          _playlist('remote', 'Online only'),
        ],
        entries: [
          _entry('remote', 'remote-entry', 0, catalog: 'youtube:remote'),
        ],
      );

      expect(layout.grouped, isFalse);
      expect(layout.playlists, isEmpty);
      expect(layout.audioFiles.map((file) => file.archivePath), [
        'audio/a.m4a',
        'audio/untracked.mp3',
      ]);
      expect(layout.trackPaths, {'a': 'audio/a.m4a'});
      expect(
        await File(layout.audioFiles.first.sourcePath).readAsString(),
        'saved:a.m4a',
      );
    },
  );

  test(
    'first playlist owns shared media and M3Us preserve order and repeats',
    () async {
      for (final name in ['a.m4a', 'b.m4a', 'c.m4a', 'd.m4a']) {
        await audio(name);
      }
      final layout = await build(
        tracks: [
          track('a', 'a.m4a', artist: 'First\nArtist', title: 'A\rTitle'),
          track('b', 'b.m4a'),
          track('c', 'c.m4a'),
          track('d', 'd.m4a'),
        ],
        playlists: [
          _playlist('first', 'Primera'),
          _playlist('second', 'Segunda'),
        ],
        entries: [
          _entry('first', 'a-1', 1, local: 'a'),
          _entry('first', 'a-2', 2, local: 'a'),
          _entry('first', 'b', 0, local: 'b'),
          _entry('second', 'a', 0, local: 'a'),
          _entry('second', 'c', 1, local: 'c'),
        ],
      );

      expect(layout.grouped, isTrue);
      expect(layout.audioFiles, hasLength(4));
      expect(layout.trackPaths, {
        'a': 'audio/Primera/a.m4a',
        'b': 'audio/Primera/b.m4a',
        'c': 'audio/Segunda/c.m4a',
        'd': 'audio/Downloaded songs/d.m4a',
      });
      expect(_mediaLines(layout.playlists[0].contents), [
        'b.m4a',
        'a.m4a',
        'a.m4a',
      ]);
      expect(_mediaLines(layout.playlists[1].contents), [
        '../Primera/a.m4a',
        'c.m4a',
      ]);
      expect(
        layout.playlists[0].contents,
        contains('#EXTINF:125,First Artist - A Title\n'),
      );
      expect(layout.playlists.map((file) => file.archivePath), [
        'audio/Primera/playlist.m3u8',
        'audio/Segunda/playlist.m3u8',
      ]);
      _expectReferencesExist(layout);
    },
  );

  test(
    'catalog fallback and several IDs share the same snapshot file',
    () async {
      await audio('shared.opus');
      final layout = await build(
        tracks: [
          track('one', 'shared.opus', catalog: 'youtube:shared'),
          track('two', 'shared.opus'),
        ],
        playlists: [
          _playlist('catalog', 'Catalog'),
          _playlist('direct', 'Direct'),
        ],
        entries: [
          _entry('catalog', 'entry', 0, catalog: 'youtube:shared'),
          _entry('direct', 'entry', 0, local: 'two'),
        ],
      );
      expect(layout.audioFiles, hasLength(1));
      expect(layout.trackPaths, {
        'one': 'audio/Catalog/shared.opus',
        'two': 'audio/Catalog/shared.opus',
      });
      expect(_mediaLines(layout.playlists.last.contents), [
        '../Catalog/shared.opus',
      ]);
      _expectReferencesExist(layout);
    },
  );

  test(
    'only unmigrated playlists without catalog occurrences use legacy IDs',
    () async {
      await audio('a.mp3');
      final layout = await build(
        tracks: [track('a', 'a.mp3')],
        playlists: [
          _playlist(
            'deleted',
            'Deleted',
            deleted: true,
            migrated: false,
            ids: ['a'],
          ),
          _playlist('empty-migrated', 'Stale projection', ids: ['a']),
          _playlist(
            'with-catalog',
            'Catalog authoritative',
            migrated: false,
            ids: ['a'],
          ),
          _playlist(
            'deleted-entry',
            'Deleted occurrence',
            migrated: false,
            ids: ['a'],
          ),
          _playlist('legacy', 'Legacy', migrated: false, ids: ['a', 'a']),
        ],
        entries: [
          _entry('with-catalog', 'stream', 0, catalog: 'youtube:unavailable'),
          {
            ..._entry('deleted-entry', 'gone', 0, local: 'a'),
            'deleted_at': '2026-01-01',
          },
        ],
      );
      expect(layout.playlists, hasLength(1));
      expect(layout.playlists.single.archivePath, 'audio/Legacy/playlist.m3u8');
      expect(_mediaLines(layout.playlists.single.contents), ['a.mp3', 'a.mp3']);
      expect(layout.audioFiles, hasLength(1));
    },
  );

  test(
    'removing playlists flattens an already grouped library without losing collisions',
    () async {
      await audio(p.join('Old first', 'song.mp3'));
      await audio(p.join('Old second', 'song.mp3'));
      final layout = await build(
        tracks: [
          track('first', p.join('Old first', 'song.mp3')),
          track('second', p.join('Old second', 'song.mp3')),
        ],
      );
      expect(layout.grouped, isFalse);
      expect(layout.playlists, isEmpty);
      expect(layout.audioFiles.map((file) => file.archivePath), [
        'audio/song.mp3',
        'audio/song (2).mp3',
      ]);
      expect(layout.trackPaths, {
        'first': 'audio/song.mp3',
        'second': 'audio/song (2).mp3',
      });
      expect(
        layout.audioFiles.map((file) => file.sourcePath).toSet(),
        hasLength(2),
      );
    },
  );

  test(
    'UTF-16 truncation keeps ZIP filenames and the JSON index identical',
    () async {
      final longName = '${List.filled(139, 'a').join()}😀';
      final filename = '$longName.mp3';
      await audio(filename);
      final layout = await build(
        tracks: [track('emoji', filename)],
        playlists: [_playlist('emoji', longName)],
        entries: [_entry('emoji', 'entry', 0, local: 'emoji')],
      );
      final path = layout.trackPaths['emoji']!;
      expect(path, contains('\ufffd'));
      expect(
        path.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff),
        isFalse,
      );
      expect(utf8.decode(utf8.encode(path)), path);
      expect(jsonDecode(jsonEncode(path)), path);
      _expectReferencesExist(layout);
    },
  );

  test(
    'portable names avoid device names, aliases and the generated M3U',
    () async {
      await audio('playlist.m3u8');
      await audio('#song.mp3');
      final names = [
        'Descargas',
        'descargas',
        'CON .archive',
        '..',
        'a/b\\c:*?<>|\x7f',
        List.filled(140, '音').join(),
      ];
      final layout = await build(
        tracks: [
          track('playlist-file', 'playlist.m3u8'),
          track('hash', '#song.mp3'),
        ],
        playlists: [
          for (var index = 0; index < names.length; index++)
            _playlist('p$index', names[index]),
        ],
        entries: [
          for (var index = 0; index < names.length; index++)
            _entry('p$index', 'file', 0, local: 'playlist-file'),
          _entry('p0', 'hash', 1, local: 'hash'),
        ],
        downloadedFolderName: 'Descargas',
      );
      expect(
        layout.trackPaths['playlist-file'],
        'audio/Descargas (2)/playlist (2).m3u8',
      );
      expect(_mediaLines(layout.playlists.first.contents), [
        'playlist (2).m3u8',
        './#song.mp3',
      ]);
      final paths = [
        ...layout.audioFiles.map((file) => file.archivePath),
        ...layout.playlists.map((file) => file.archivePath),
      ];
      expect(
        paths.map((path) => path.toLowerCase()).toSet(),
        hasLength(paths.length),
      );
      for (final path in paths) {
        for (final segment in path.split('/')) {
          expect(segment, isNotEmpty);
          expect(segment, isNot(anyOf('.', '..')));
          expect(segment, isNot(matches(r'[<>:"/\\|?*\x00-\x1f\x7f]')));
          expect(segment, isNot(matches(r'[.\s]$')));
          expect(utf8.encode(segment).length, lessThanOrEqualTo(255));
          expect(segment.split('.').first.trim().toLowerCase(), isNot('con'));
        }
      }
      _expectReferencesExist(layout);
    },
  );
}

Map<String, Object?> _playlist(
  String id,
  String name, {
  bool deleted = false,
  bool migrated = true,
  List<String> ids = const [],
}) => {
  'id': id,
  'name': name,
  'deleted_at': deleted ? '2026-01-01' : null,
  'entries_migrated': migrated ? 1 : 0,
  'track_ids': jsonEncode(ids),
};

Map<String, Object?> _entry(
  String playlist,
  String id,
  int position, {
  String? local,
  String? catalog,
}) => {
  'playlist_id': playlist,
  'item_id': id,
  'position': position,
  'local_track_id': local,
  'catalog_key': catalog,
};

List<String> _mediaLines(String playlist) => const LineSplitter()
    .convert(playlist)
    .where((line) => line.isNotEmpty && !line.startsWith('#'))
    .toList();

void _expectReferencesExist(BackupAudioLayout layout) {
  final paths = layout.audioFiles.map((file) => file.archivePath).toSet();
  for (final playlist in layout.playlists) {
    for (final reference in _mediaLines(playlist.contents)) {
      final resolved = p.posix.normalize(
        p.posix.join(p.posix.dirname(playlist.archivePath), reference),
      );
      expect(paths, contains(resolved));
    }
  }
}
