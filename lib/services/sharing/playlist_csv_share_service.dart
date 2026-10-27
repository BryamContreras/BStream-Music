import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../features/music/domain/entities/catalog_playlist.dart';
import '../../features/music/domain/entities/catalog_track.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../storage/library_csv_service.dart';

abstract interface class PlaylistCsvShareService {
  Future<void> sharePlaylist({
    required CatalogPlaylist playlist,
    required List<LocalTrack> localTracks,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  });
}

abstract interface class PlaylistCsvShareGateway {
  Future<void> share({
    required XFile file,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  });
}

typedef PlaylistCsvNativeShare = Future<void> Function(ShareParams params);
typedef PlaylistCsvSaveFile = Future<void> Function(XFile file, String title);

class SharePlusPlaylistCsvShareGateway implements PlaylistCsvShareGateway {
  const SharePlusPlaylistCsvShareGateway({
    this.nativeShare = _shareNative,
    this.saveFile = _saveCsvFile,
    this.isLinux = _isLinux,
  });

  final PlaylistCsvNativeShare nativeShare;
  final PlaylistCsvSaveFile saveFile;
  final bool Function() isLinux;

  @override
  Future<void> share({
    required XFile file,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    // share_plus cannot share attachments on Linux. Its save dialog still
    // delivers the same portable CSV without requiring an account or network.
    if (isLinux()) {
      await saveFile(file, title);
      return;
    }
    await nativeShare(
      ShareParams(
        files: [file],
        fileNameOverrides: [file.name],
        title: title,
        subject: subject,
        sharePositionOrigin: _safeShareOrigin(sharePositionOrigin),
      ),
    );
  }
}

/// Shares one playlist using the same BStream CSV schema as library exports.
///
/// Files survive share-sheet completion: another application can read them
/// later. Only marked exports older than seven days are reclaimed on a later
/// share, and the operating system may also reclaim its temporary directory.
class SharePlusPlaylistCsvShareService implements PlaylistCsvShareService {
  const SharePlusPlaylistCsvShareService({
    this.csvService = const LibraryCsvService(),
    this.gateway = const SharePlusPlaylistCsvShareGateway(),
    this.temporaryDirectoryFactory = getTemporaryDirectory,
  });

  final LibraryCsvService csvService;
  final PlaylistCsvShareGateway gateway;
  final Future<Directory> Function() temporaryDirectoryFactory;

  static const _directoryName = 'bstream-playlist-csv';
  static const _markerName = '.bstream-playlist-csv-share';
  static const _retention = Duration(days: 7);

  @override
  Future<void> sharePlaylist({
    required CatalogPlaylist playlist,
    required List<LocalTrack> localTracks,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    if (playlist.playlist.deletedAt != null) {
      throw const FormatException('The playlist has been deleted.');
    }
    final bytes = await compute(
      _encodePlaylistCsv,
      _PlaylistCsvExportRequest(playlist, localTracks, csvService),
    );
    final temporaryDirectory = await temporaryDirectoryFactory();
    final exportRoot = await Directory(
      p.join(temporaryDirectory.path, _directoryName),
    ).create(recursive: true);
    await _pruneExpiredExports(exportRoot);
    final exportDirectory = await exportRoot.createTemp('share_');
    final fileName = _csvFileName(playlist.playlist.name);
    final file = File(p.join(exportDirectory.path, fileName));
    try {
      await File(
        p.join(exportDirectory.path, _markerName),
      ).writeAsString('BStream playlist CSV share');
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // No share consumer has received this path yet.
      try {
        await exportDirectory.delete(recursive: true);
      } on FileSystemException {
        // Preserve the export error if temporary cleanup also fails.
      }
      rethrow;
    }
    await gateway.share(
      file: XFile(file.path, mimeType: 'text/csv', name: fileName),
      title: _shareTitle(title, playlist.playlist.name),
      subject: subject,
      sharePositionOrigin: _safeShareOrigin(sharePositionOrigin),
    );
    // Do not delete here, including when a gateway fails after dispatching.
    // Share-sheet completion does not mean its receiver has opened the file.
  }

  Future<void> _pruneExpiredExports(Directory root) async {
    try {
      final resolvedRoot = await root.resolveSymbolicLinks();
      final oldestRetained = DateTime.now().subtract(_retention);
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory ||
            !RegExp(
              r'^share_[A-Za-z0-9_-]+$',
            ).hasMatch(p.basename(entity.path))) {
          continue;
        }
        final resolved = await entity.resolveSymbolicLinks();
        if (!p.isWithin(resolvedRoot, resolved)) continue;
        final marker = File(p.join(entity.path, _markerName));
        if (await FileSystemEntity.type(marker.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        if ((await marker.lastModified()).isBefore(oldestRetained)) {
          await entity.delete(recursive: true);
        }
      }
    } on FileSystemException {
      // Cache maintenance must not prevent sharing a new export.
    }
  }
}

class _PlaylistCsvExportRequest {
  const _PlaylistCsvExportRequest(
    this.playlist,
    this.localTracks,
    this.service,
  );

  final CatalogPlaylist playlist;
  final List<LocalTrack> localTracks;
  final LibraryCsvService service;
}

Uint8List _encodePlaylistCsv(_PlaylistCsvExportRequest request) {
  final playlist = request.playlist;
  final entries = playlist.entries
      .where(
        (entry) => !entry.isDeleted && entry.playlistId == playlist.playlist.id,
      )
      .toList(growable: false);
  final legacyPlaylist = playlist.entries.isEmpty;
  final localIds = <String>{
    if (legacyPlaylist) ...playlist.playlist.trackIds,
    for (final entry in entries) ...[
      ?entry.localTrackId,
      if (entry.track.provider == CatalogProvider.local) entry.track.providerId,
    ],
  };
  final document = LibraryCsvDocument.fromLibrary(
    tracks: request.localTracks
        .where((track) => localIds.contains(track.id))
        .toList(growable: false),
    playlists: legacyPlaylist ? [playlist.playlist] : const [],
    catalogPlaylists: legacyPlaylist
        ? const []
        : [CatalogPlaylist(playlist: playlist.playlist, entries: entries)],
  );
  final rows =
      <LibraryCsvTrack>[
        for (final track in document.tracks)
          for (final membership in track.memberships)
            if (membership.id == playlist.playlist.id)
              LibraryCsvTrack(
                rowNumber: track.rowNumber,
                title: track.title,
                artist: track.artist,
                artists: track.artists,
                album: track.album,
                youtubeVideoId: track.youtubeVideoId,
                youtubeUrl: track.youtubeUrl,
                duration: track.duration,
                isrc: track.isrc,
                // Arbitrary source/thumbnail URLs may contain credentials or local
                // paths. The canonical video identity is sufficient for sharing.
                sourceUri: track.youtubeUrl,
                addedAt: track.addedAt,
                memberships: [membership],
              ),
      ]..sort((a, b) {
        final position = a.memberships.single.position.compareTo(
          b.memberships.single.position,
        );
        return position != 0 ? position : a.rowNumber.compareTo(b.rowNumber);
      });
  return request.service.exportDocument(
    LibraryCsvDocument(
      tracks: rows,
      detectedFormat: LibraryCsvDetectedFormat.bstream,
      defaultPlaylistName: playlist.playlist.name,
      hasPlaylistColumn: true,
    ),
    LibraryCsvProfile.bstream,
  );
}

String _csvFileName(String playlistName) {
  var name = playlistName
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.toLowerCase().endsWith('.csv')) {
    name = name.substring(0, name.length - 4).trim();
  }
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = 'Playlist';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  // Keep enough room for the temporary path on Windows and for the suffix.
  final shortened = StringBuffer();
  var units = 0;
  var bytes = 0;
  for (final rune in name.runes) {
    final character = String.fromCharCode(rune);
    final characterBytes = utf8.encode(character).length;
    if (units + character.length > 120 || bytes + characterBytes > 180) break;
    shortened.write(character);
    units += character.length;
    bytes += characterBytes;
  }
  return '${shortened.toString().replaceAll(RegExp(r'[. ]+$'), '')}.csv';
}

String _shareTitle(String title, String playlistName) {
  final name = playlistName.trim();
  final normalizedTitle = title.trim();
  if (normalizedTitle.isEmpty) return name;
  if (name.isEmpty ||
      normalizedTitle.toLowerCase().contains(name.toLowerCase())) {
    return normalizedTitle;
  }
  return '$normalizedTitle: $name';
}

Rect _safeShareOrigin(Rect? origin) {
  if (origin != null &&
      origin.left.isFinite &&
      origin.top.isFinite &&
      origin.width.isFinite &&
      origin.height.isFinite &&
      origin.left >= 0 &&
      origin.top >= 0 &&
      origin.width > 0 &&
      origin.height > 0) {
    return origin;
  }
  return const Rect.fromLTWH(0, 0, 1, 1);
}

bool _isLinux() => Platform.isLinux;

Future<void> _shareNative(ShareParams params) async {
  await SharePlus.instance.share(params);
}

Future<void> _saveCsvFile(XFile file, String title) async {
  await FilePicker.saveFile(
    fileName: file.name,
    bytes: await file.readAsBytes(),
    mimeType: 'text/csv',
    dialogTitle: title,
    type: FileType.custom,
    allowedExtensions: const ['csv'],
    linuxOptions: const LinuxOptions(lockParentWindow: true),
  );
}
