import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:path/path.dart' as p;

import '../../features/music/domain/entities/device_audio_track.dart';
import 'device_audio_catalog.dart';
import 'device_audio_filter.dart';

typedef DesktopMusicRootsProvider = Future<List<Directory>> Function();

class DesktopDeviceAudioCatalog implements DeviceAudioCatalog {
  DesktopDeviceAudioCatalog([this._rootsProvider = _defaultDesktopMusicRoots]);

  final DesktopMusicRootsProvider _rootsProvider;
  List<DeviceAudioTrack>? _rawTracks;
  String? _rawBstreamRoot;
  Future<List<DeviceAudioTrack>>? _scanInFlight;
  String? _scanInFlightRoot;

  @override
  Future<DeviceAudioCatalogResult> load({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) async {
    final tracks = await _rawCatalog(bstreamRoot: bstreamRoot);
    return DeviceAudioCatalogResult(
      status: DeviceAudioPermissionStatus.notRequired,
      tracks: filterDeviceAudioTracks(
        tracks,
        options: options,
        bstreamRoot: bstreamRoot,
      ),
    );
  }

  @override
  Future<DeviceAudioCatalogResult> refresh({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) async {
    await _rawCatalog(bstreamRoot: bstreamRoot, forceRefresh: true);
    return load(options: options, bstreamRoot: bstreamRoot);
  }

  @override
  Future<DeviceAudioCatalogResult> requestPermissionAndLoad({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) => load(options: options, bstreamRoot: bstreamRoot);

  Future<List<DeviceAudioTrack>> _rawCatalog({
    required String? bstreamRoot,
    bool forceRefresh = false,
  }) async {
    final rootIdentity = _pathIdentityOrNull(bstreamRoot);
    final cached = _rawTracks;
    if (!forceRefresh && cached != null && _rawBstreamRoot == rootIdentity) {
      return cached;
    }
    final active = _scanInFlight;
    if (active != null && _scanInFlightRoot == rootIdentity) {
      return active;
    }
    if (active != null) {
      await active;
    }
    final roots = await _rootsProvider();
    final rootPaths = roots
        .map((directory) => directory.absolute.path)
        .toSet()
        .toList(growable: false);
    final request = Isolate.run(
      () => _scanDesktopAudio(rootPaths, bstreamRoot),
    );
    _scanInFlight = request;
    _scanInFlightRoot = rootIdentity;
    try {
      final tracks = List<DeviceAudioTrack>.unmodifiable(await request);
      _rawTracks = tracks;
      _rawBstreamRoot = rootIdentity;
      return tracks;
    } finally {
      if (identical(_scanInFlight, request)) {
        _scanInFlight = null;
        _scanInFlightRoot = null;
      }
    }
  }
}

Future<List<Directory>> _defaultDesktopMusicRoots() async {
  final homes = <String>{
    ?_nonEmpty(Platform.environment['HOME']),
    ?_nonEmpty(Platform.environment['USERPROFILE']),
  };
  final roots = <Directory>[];
  for (final home in homes) {
    final music = Directory(p.join(home, 'Music'));
    if (await music.exists()) {
      roots.add(music);
    }
  }
  return roots;
}

Future<List<DeviceAudioTrack>> _scanDesktopAudio(
  List<String> rootPaths,
  String? bstreamRoot,
) async {
  final tracks = <DeviceAudioTrack>[];
  final seenFiles = <String>{};
  for (final rootPath in rootPaths) {
    final root = Directory(rootPath);
    if (!await root.exists() || _isInsideRoot(root.path, bstreamRoot)) {
      continue;
    }
    final pending = <Directory>[root];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      if (_isInsideRoot(directory.path, bstreamRoot)) {
        continue;
      }
      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is Link) {
            continue;
          }
          if (entity is Directory) {
            if (!_isInsideRoot(entity.path, bstreamRoot)) {
              pending.add(entity);
            }
            continue;
          }
          if (entity is! File || !_isSupportedAudioFile(entity.path)) {
            continue;
          }
          final absolutePath = p.normalize(entity.absolute.path);
          final identity = _pathIdentity(absolutePath);
          if (!seenFiles.add(identity)) {
            continue;
          }
          tracks.add(
            _desktopTrack(
              file: entity,
              absolutePath: absolutePath,
              rootPath: root.absolute.path,
            ),
          );
        }
      } on FileSystemException {
        // One inaccessible folder must not hide the rest of the music root.
      }
    }
  }
  tracks.sort((left, right) {
    final title = left.title.toLowerCase().compareTo(right.title.toLowerCase());
    return title != 0 ? title : left.uri.compareTo(right.uri);
  });
  return List<DeviceAudioTrack>.unmodifiable(tracks);
}

DeviceAudioTrack _desktopTrack({
  required File file,
  required String absolutePath,
  required String rootPath,
}) {
  final metadata = _readDesktopAudioMetadata(file);
  final displayName = p.basename(absolutePath);
  final stem = p.basenameWithoutExtension(displayName).trim();
  final separator = stem.indexOf(' - ');
  final parsedArtist = separator > 0
      ? stem.substring(0, separator).trim()
      : null;
  final parsedTitle = separator > 0
      ? stem.substring(separator + 3).trim()
      : stem;
  final parent = p.dirname(absolutePath);
  final relativeParent = p.relative(parent, from: rootPath);
  final folderName = p.basename(parent).trim();
  final extension = p.extension(absolutePath).toLowerCase();
  return DeviceAudioTrack(
    id: 'device-file:${_pathIdentity(absolutePath)}',
    uri: absolutePath,
    title: metadata.title ?? (parsedTitle.isEmpty ? displayName : parsedTitle),
    artist:
        metadata.artist ??
        (parsedArtist == null || parsedArtist.isEmpty ? null : parsedArtist),
    album: metadata.album,
    duration: metadata.duration,
    folderId: 'folder:${_pathIdentity(parent)}',
    folderName: folderName.isEmpty ? 'Music' : folderName,
    displayName: displayName,
    mimeType: _audioMimeTypes[extension],
    relativePath: relativeParent == '.' ? '' : relativeParent,
    absolutePath: absolutePath,
  );
}

_DesktopAudioMetadata _readDesktopAudioMetadata(File file) {
  try {
    // Covers are deliberately skipped here. The catalog only needs lightweight
    // text and timing metadata; retaining embedded image blobs for every song
    // would make a large local library unnecessarily expensive in memory.
    final metadata = readMetadata(file, getImage: false);
    final duration = metadata.duration;
    return _DesktopAudioMetadata(
      title: _meaningfulMetadata(metadata.title),
      artist: _meaningfulMetadata(metadata.artist),
      album: _meaningfulMetadata(metadata.album),
      duration: duration != null && duration > Duration.zero ? duration : null,
    );
  } catch (_) {
    // Unsupported or malformed files remain playable and keep the filename
    // fallback instead of making one bad tag abort the whole folder scan.
    return const _DesktopAudioMetadata();
  }
}

String? _meaningfulMetadata(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.toLowerCase() == '<unknown>') {
    return null;
  }
  return normalized;
}

class _DesktopAudioMetadata {
  const _DesktopAudioMetadata({
    this.title,
    this.artist,
    this.album,
    this.duration,
  });

  final String? title;
  final String? artist;
  final String? album;
  final Duration? duration;
}

bool _isSupportedAudioFile(String filePath) =>
    _audioExtensions.contains(p.extension(filePath).toLowerCase());

bool _isInsideRoot(String candidate, String? root) {
  final normalizedRoot = _nonEmpty(root);
  if (normalizedRoot == null) {
    return false;
  }
  try {
    final candidatePath = p.normalize(p.absolute(candidate));
    final rootPath = p.normalize(p.absolute(normalizedRoot));
    return p.equals(candidatePath, rootPath) ||
        p.isWithin(rootPath, candidatePath);
  } on ArgumentError {
    return false;
  }
}

String _pathIdentity(String value) {
  final normalized = p.normalize(p.absolute(value));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

String? _pathIdentityOrNull(String? value) {
  final normalized = _nonEmpty(value);
  return normalized == null ? null : _pathIdentity(normalized);
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

const _audioExtensions = <String>{
  '.3gp',
  '.3gpp',
  '.aac',
  '.aiff',
  '.alac',
  '.flac',
  '.m4a',
  '.m4b',
  '.mka',
  '.mp3',
  '.mp4',
  '.oga',
  '.ogg',
  '.opus',
  '.vorbis',
  '.wav',
  '.weba',
  '.webm',
  '.wma',
};

const _audioMimeTypes = <String, String>{
  '.aac': 'audio/aac',
  '.flac': 'audio/flac',
  '.m4a': 'audio/mp4',
  '.mp3': 'audio/mpeg',
  '.oga': 'audio/ogg',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/opus',
  '.wav': 'audio/wav',
  '.weba': 'audio/webm',
  '.webm': 'audio/webm',
};
