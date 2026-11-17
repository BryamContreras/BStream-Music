import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/utils/safe_file_name.dart';

typedef BackupAudioMetadata = ({
  List<Map<String, Object?>> tracks,
  List<Map<String, Object?>> playlists,
  List<Map<String, Object?>> entries,
});

typedef BackupAudioFile = ({String sourcePath, String archivePath});
typedef BackupPlaylistFile = ({String archivePath, String contents});

/// A portable ZIP layout over the existing snapshot. No media is copied,
/// decoded or hashed while planning: every existing file is emitted once.
class BackupAudioLayout {
  const BackupAudioLayout._({
    required this.audioFiles,
    required this.playlists,
    required this.trackPaths,
    required this.grouped,
  });

  final List<BackupAudioFile> audioFiles;
  final List<BackupPlaylistFile> playlists;

  /// Download IDs map to the physical ZIP member, independently of playlist
  /// membership. Several downloads may legitimately reference one file.
  final Map<String, String> trackPaths;
  final bool grouped;

  static Future<BackupAudioLayout> build({
    required String snapshotAudioRoot,
    required String originalMediaRoot,
    required BackupAudioMetadata metadata,
    String downloadedFolderName = 'Downloaded songs',
  }) async {
    final snapshot = Directory(snapshotAudioRoot);
    final files = <_AudioFile>[];
    if (await snapshot.exists()) {
      await for (final entity in snapshot.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }
        files.add(
          _AudioFile(
            sourcePath: entity.path,
            relative: p.relative(entity.path, from: snapshotAudioRoot),
          ),
        );
      }
    }
    files.sort((first, second) => first.relative.compareTo(second.relative));

    final originalAudioRoot = p.join(originalMediaRoot, 'audio');
    final roots = <String>{originalAudioRoot};
    try {
      if (await Directory(originalAudioRoot).exists()) {
        roots.add(await Directory(originalAudioRoot).resolveSymbolicLinks());
      }
    } on FileSystemException {
      // The snapshot remains usable if its original volume was detached.
    }
    final byOriginalPath = <String, _AudioFile>{
      for (final file in files)
        for (final root in roots) _pathKey(p.join(root, file.relative)): file,
    };
    final tracksById = <String, _Download>{};
    final tracksByCatalog = <String, _Download>{};
    for (final row in metadata.tracks) {
      final id = _text(row['id']);
      final original = _nativeFilePath(row['file_path']);
      if (id.isEmpty || original == null) {
        continue;
      }
      final file = byOriginalPath[_pathKey(original)];
      if (file == null) {
        continue;
      }
      final download = _Download(file, row);
      tracksById.putIfAbsent(id, () => download);
      final catalog = _text(row['catalog_key']);
      if (catalog.isNotEmpty) {
        tracksByCatalog.putIfAbsent(catalog, () => download);
      }
    }

    final entriesByPlaylist = <String, List<Map<String, Object?>>>{};
    final canonicalPlaylistIds = <String>{};
    for (final row in metadata.entries) {
      canonicalPlaylistIds.add(_text(row['playlist_id']));
      if (row['deleted_at'] != null) {
        continue;
      }
      entriesByPlaylist
          .putIfAbsent(_text(row['playlist_id']), () => [])
          .add(row);
    }
    for (final entries in entriesByPlaylist.values) {
      entries.sort((first, second) {
        final position = _integer(
          first['position'],
        ).compareTo(_integer(second['position']));
        return position != 0
            ? position
            : _text(first['item_id']).compareTo(_text(second['item_id']));
      });
    }

    final groups = <_PlaylistGroup>[];
    for (final row in metadata.playlists) {
      if (row['deleted_at'] != null) {
        continue;
      }
      final id = _text(row['id']);
      if (id.isEmpty) {
        continue;
      }
      final occurrences = <_Download>[];
      final entries = entriesByPlaylist[id] ?? const [];
      if (entries.isNotEmpty) {
        for (final entry in entries) {
          final direct = tracksById[_text(entry['local_track_id'])];
          final catalog = tracksByCatalog[_text(entry['catalog_key'])];
          final download = direct ?? catalog;
          if (download != null) {
            occurrences.add(download);
          }
        }
      } else if (_integer(row['entries_migrated']) == 0 &&
          !canonicalPlaylistIds.contains(id)) {
        // Old, unmigrated databases only have the downloaded-ID projection.
        // Never revive that projection for an already migrated empty playlist.
        final rawIds = row['track_ids'];
        Object? ids;
        if (rawIds is String) {
          try {
            ids = jsonDecode(rawIds);
          } on FormatException {
            ids = null;
          }
        } else if (rawIds is List) {
          ids = rawIds;
        }
        if (ids is List) {
          for (final id in ids) {
            final download = tracksById[_text(id)];
            if (download != null) {
              occurrences.add(download);
            }
          }
        }
      }
      if (occurrences.isNotEmpty) {
        groups.add(_PlaylistGroup(_text(row['name']), occurrences));
      }
    }

    if (groups.isEmpty) {
      final used = <String>{};
      final paths = <_AudioFile, String>{
        for (final file in files)
          file: p.posix.join(
            'audio',
            _uniqueFilename(p.basename(file.sourcePath), used),
          ),
      };
      return _finish(files, paths, tracksById, const [], grouped: false);
    }

    // The library order supplied by SQLite is also the ownership order. A
    // shared file belongs to its first playlist; other M3Us point to that copy.
    final usedFolders = <String>{};
    final downloadedFolder = _uniqueFolder(
      _portableSegment(downloadedFolderName, fallback: 'Downloaded songs'),
      usedFolders,
    );
    final ownerByFile = <_AudioFile, String>{};
    final filenamesByFolder = <String, Set<String>>{};
    for (final group in groups) {
      group.folder = _uniqueFolder(
        _portableSegment(group.name, fallback: 'Playlist'),
        usedFolders,
      );
      filenamesByFolder[group.folder] = {'playlist.m3u8'};
      for (final occurrence in group.occurrences) {
        ownerByFile.putIfAbsent(occurrence.file, () => group.folder);
      }
    }
    final paths = <_AudioFile, String>{};
    for (final file in files) {
      final folder = ownerByFile[file] ?? downloadedFolder;
      final filename = _uniqueFilename(
        p.basename(file.sourcePath),
        filenamesByFolder.putIfAbsent(folder, () => {}),
      );
      paths[file] = p.posix.join('audio', folder, filename);
    }
    final playlistFiles = <BackupPlaylistFile>[];
    for (final group in groups) {
      final playlistPath = p.posix.join('audio', group.folder, 'playlist.m3u8');
      final contents = StringBuffer('#EXTM3U\n')
        ..writeln('#PLAYLIST:${_singleLine(group.name)}');
      for (final occurrence in group.occurrences) {
        final row = occurrence.metadata;
        final rawDuration = row['duration_seconds'];
        final duration = rawDuration == null ? -1 : _integer(rawDuration);
        final artist = _singleLine(_text(row['artist']));
        final title = _singleLine(_text(row['title']));
        final label = title.isEmpty
            ? _singleLine(
                p.basenameWithoutExtension(occurrence.file.sourcePath),
              )
            : artist.isEmpty
            ? title
            : '$artist - $title';
        var relative = p.posix.relative(
          paths[occurrence.file]!,
          from: p.posix.dirname(playlistPath),
        );
        if (relative.startsWith('#')) {
          relative = './$relative';
        }
        contents
          ..writeln('#EXTINF:${duration < 0 ? -1 : duration},$label')
          ..writeln(relative);
      }
      playlistFiles.add((archivePath: playlistPath, contents: '$contents'));
    }
    return _finish(files, paths, tracksById, playlistFiles, grouped: true);
  }

  static BackupAudioLayout _finish(
    List<_AudioFile> files,
    Map<_AudioFile, String> paths,
    Map<String, _Download> tracks,
    List<BackupPlaylistFile> playlists, {
    required bool grouped,
  }) => BackupAudioLayout._(
    grouped: grouped,
    audioFiles: List.unmodifiable([
      for (final file in files)
        (sourcePath: file.sourcePath, archivePath: paths[file]!),
    ]),
    playlists: List.unmodifiable(playlists),
    trackPaths: Map.unmodifiable({
      for (final entry in tracks.entries) entry.key: paths[entry.value.file]!,
    }),
  );
}

class _AudioFile {
  const _AudioFile({required this.sourcePath, required this.relative});
  final String sourcePath;
  final String relative;
}

class _Download {
  const _Download(this.file, this.metadata);
  final _AudioFile file;
  final Map<String, Object?> metadata;
}

class _PlaylistGroup {
  _PlaylistGroup(this.name, this.occurrences);
  final String name;
  final List<_Download> occurrences;
  late String folder;
}

String _pathKey(String path) {
  final normalized = p.normalize(p.absolute(path));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

String? _nativeFilePath(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return null;
  }
  var path = raw;
  if (raw.startsWith('file:')) {
    try {
      path = File.fromUri(Uri.parse(raw)).path;
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
  return p.isAbsolute(path) ? path : null;
}

String _text(Object? value) => value?.toString().trim() ?? '';
int _integer(Object? value) =>
    value is num ? value.toInt() : int.tryParse(value?.toString() ?? '') ?? 0;

String _singleLine(String value) =>
    value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();

final _windowsDevice = RegExp(
  r'^(?:con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
  caseSensitive: false,
);

String _portableSegment(
  String name, {
  required String fallback,
  int maximumBytes = 180,
}) {
  final meaningful = name.replaceAll(RegExp(r'[.\s]+$'), '').trim();
  var result = safeFileName(
    meaningful.isEmpty ? fallback : meaningful,
  ).replaceAll('\x7f', '_').replaceAll(RegExp(r'[.\s]+$'), '');
  // The shared character cap can split a surrogate pair. ZIP filenames are
  // UTF-8 while the index is JSON; normalize malformed halves explicitly so
  // both serializations name the same file after a round trip.
  result = String.fromCharCodes(
    result.runes.map(
      (rune) => rune >= 0xd800 && rune <= 0xdfff ? 0xfffd : rune,
    ),
  );
  if (result.isEmpty || result == '.' || result == '..') {
    result = fallback;
  }
  if (_windowsDevice.hasMatch(result.split('.').first.trim())) {
    result = '_$result';
  }
  // Keep Unicode names below ordinary filesystem byte limits as well as the
  // shared helper's character limit. Leave room for extensions and suffixes.
  final bounded = StringBuffer();
  var bytes = 0;
  for (final rune in result.runes) {
    final character = String.fromCharCode(rune);
    final width = utf8.encode(character).length;
    if (bytes + width > maximumBytes) {
      break;
    }
    bytes += width;
    bounded.write(character);
  }
  return bounded.toString().replaceAll(RegExp(r'[.\s]+$'), '');
}

String _uniqueFolder(String base, Set<String> used) {
  var candidate = base;
  var suffix = 2;
  while (!used.add(candidate.toLowerCase())) {
    candidate = '$base (${suffix++})';
  }
  return candidate;
}

String _uniqueFilename(String original, Set<String> used) {
  final extension = p.extension(original);
  final sanitizedExtension = extension.isEmpty
      ? ''
      : '.${_portableSegment(extension.substring(1), fallback: 'audio', maximumBytes: 32)}';
  final base = _portableSegment(
    extension.isEmpty
        ? original
        : original.substring(0, original.length - extension.length),
    fallback: 'track',
  );
  var candidate = '$base$sanitizedExtension';
  var suffix = 2;
  while (!used.add(candidate.toLowerCase())) {
    candidate = '$base (${suffix++})$sanitizedExtension';
  }
  return candidate;
}
