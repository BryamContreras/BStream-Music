import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:path/path.dart' as p;

import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/playlist.dart';

enum LibraryCsvProfile { bstream, metroList, harmony, soundiiz }

enum LibraryCsvDetectedFormat {
  bstream,
  metroList,
  harmony,
  exportify,
  soundiiz,
  generic,
}

class LibraryCsvInput {
  const LibraryCsvInput({required this.bytes, required this.fileName});

  final Uint8List bytes;
  final String fileName;
}

class LibraryCsvMembership {
  const LibraryCsvMembership({
    required this.name,
    required this.position,
    this.id,
  });

  final String name;
  final int position;
  final String? id;
}

class LibraryCsvTrack {
  const LibraryCsvTrack({
    required this.rowNumber,
    required this.title,
    required this.artist,
    this.artists = const [],
    this.album,
    this.youtubeVideoId,
    this.youtubeUrl,
    this.duration,
    this.thumbnailUrl,
    this.isrc,
    this.sourceUri,
    this.addedAt,
    this.memberships = const [],
  });

  final int rowNumber;
  final String title;
  final String artist;
  final List<String> artists;
  final String? album;
  final String? youtubeVideoId;
  final String? youtubeUrl;
  final Duration? duration;
  final String? thumbnailUrl;
  final String? isrc;
  final String? sourceUri;
  final DateTime? addedAt;
  final List<LibraryCsvMembership> memberships;

  String get displayTitle => title.trim().isEmpty
      ? (youtubeVideoId ?? youtubeUrl ?? sourceUri ?? 'Fila $rowNumber')
      : title.trim();

  String get dedupeKey {
    final videoId = youtubeVideoId?.trim();
    if (videoId != null && videoId.isNotEmpty) {
      // YouTube video IDs are case-sensitive. Lower-casing them can collapse
      // two different videos and silently drop one imported row.
      return 'youtube:$videoId';
    }
    final normalizedIsrc = isrc?.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (normalizedIsrc != null && normalizedIsrc.isNotEmpty) {
      return 'isrc:${normalizedIsrc.toLowerCase()}';
    }
    final uri = sourceUri?.trim().toLowerCase();
    if (uri != null && uri.isNotEmpty) {
      return 'uri:$uri';
    }
    final seconds = duration?.inSeconds ?? -1;
    return 'metadata:${_normalizeValue(title)}\u0000'
        '${_normalizeValue(artist)}\u0000'
        '${_normalizeValue(album ?? '')}\u0000$seconds';
  }

  LibraryCsvTrack copyWith({List<LibraryCsvMembership>? memberships}) {
    return LibraryCsvTrack(
      rowNumber: rowNumber,
      title: title,
      artist: artist,
      artists: artists,
      album: album,
      youtubeVideoId: youtubeVideoId,
      youtubeUrl: youtubeUrl,
      duration: duration,
      thumbnailUrl: thumbnailUrl,
      isrc: isrc,
      sourceUri: sourceUri,
      addedAt: addedAt,
      memberships: memberships ?? this.memberships,
    );
  }
}

class LibraryCsvDocument {
  const LibraryCsvDocument({
    required this.tracks,
    required this.detectedFormat,
    required this.defaultPlaylistName,
    required this.hasPlaylistColumn,
    this.invalidRowCount = 0,
    this.duplicateRowCount = 0,
    this.warnings = const [],
  });

  final List<LibraryCsvTrack> tracks;
  final LibraryCsvDetectedFormat detectedFormat;
  final String defaultPlaylistName;
  final bool hasPlaylistColumn;
  final int invalidRowCount;
  final int duplicateRowCount;
  final List<String> warnings;

  int get uniqueTrackCount => tracks.length;

  Set<String> get playlistNames => {
    for (final track in tracks)
      for (final membership in track.memberships)
        if (membership.name.trim().isNotEmpty) membership.name.trim(),
  };

  int get playlistCount => {
    for (final track in tracks)
      for (final membership in track.memberships)
        if (membership.name.trim().isNotEmpty)
          membership.id?.trim().isNotEmpty == true
              ? 'id:${membership.id!.trim()}'
              : 'name:${membership.name.trim().toLowerCase()}',
  }.length;

  factory LibraryCsvDocument.fromLibrary({
    required List<LocalTrack> tracks,
    required List<Playlist> playlists,
  }) {
    final memberships = <String, List<LibraryCsvMembership>>{};
    for (final playlist in playlists) {
      for (var index = 0; index < playlist.trackIds.length; index++) {
        memberships
            .putIfAbsent(playlist.trackIds[index], () => [])
            .add(
              LibraryCsvMembership(
                name: playlist.name,
                position: index + 1,
                id: playlist.id,
              ),
            );
      }
    }
    return LibraryCsvDocument(
      tracks: [
        for (var index = 0; index < tracks.length; index++)
          _trackFromLocal(
            tracks[index],
            index + 2,
            memberships[tracks[index].id] ?? const [],
          ),
      ],
      detectedFormat: LibraryCsvDetectedFormat.bstream,
      defaultPlaylistName: 'BStream Music',
      hasPlaylistColumn: true,
    );
  }
}

class LibraryCsvService {
  const LibraryCsvService();

  static const maxFileBytes = 16 * 1024 * 1024;
  static const maxRows = 10000;
  static const maxColumns = 128;
  static const maxCellCharacters = 32768;
  static const maxWarnings = 50;

  Future<LibraryCsvDocument> importFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const FormatException('El archivo CSV no existe.');
    }
    final length = await file.length();
    if (length <= 0 || length > maxFileBytes) {
      throw const FormatException(
        'El archivo CSV está vacío o excede el límite de 16 MiB.',
      );
    }
    return importBytes(
      LibraryCsvInput(
        bytes: await file.readAsBytes(),
        fileName: p.basename(path),
      ),
    );
  }

  LibraryCsvDocument importBytes(LibraryCsvInput input) {
    if (input.bytes.isEmpty || input.bytes.length > maxFileBytes) {
      throw const FormatException(
        'El archivo CSV está vacío o excede el límite de 16 MiB.',
      );
    }
    var content = _decodeText(input.bytes);
    if (content.startsWith('\ufeff')) {
      content = content.substring(1);
    }
    if (content.startsWith('sep=') && content.length >= 6) {
      final end = content.indexOf(RegExp(r'[\r\n]'));
      if (end >= 0) {
        content = content.substring(end).replaceFirst(RegExp(r'^[\r\n]+'), '');
      }
    }

    final List<List<dynamic>> rows;
    try {
      rows = Csv(autoDetect: true, dynamicTyping: false).decode(content);
    } catch (error) {
      throw FormatException('El CSV no tiene una estructura válida.', error);
    }
    if (rows.isEmpty) {
      throw const FormatException('El CSV no contiene filas.');
    }
    if (rows.length > maxRows + 1) {
      throw const FormatException('El CSV excede el límite de 10000 filas.');
    }
    for (final row in rows) {
      if (row.length > maxColumns) {
        throw const FormatException('El CSV excede el límite de 128 columnas.');
      }
      for (final value in row) {
        if (value.toString().length > maxCellCharacters) {
          throw const FormatException(
            'Una celda del CSV excede el límite permitido.',
          );
        }
      }
    }

    final header = rows.first.map((value) => value.toString()).toList();
    final normalizedHeader = header.map(_normalizeHeader).toList();
    final columns = _CsvColumns.fromHeaders(normalizedHeader);
    if (columns.title == null &&
        columns.youtubeId == null &&
        columns.url == null) {
      throw const FormatException(
        'No se reconocen las columnas de título o YouTube del CSV.',
      );
    }
    final format = _detectFormat(normalizedHeader);
    final defaultPlaylistName = _defaultPlaylistName(input.fileName);
    final warnings = <String>[];
    final parsed = <String, LibraryCsvTrack>{};
    var invalidRows = 0;
    var duplicateRows = 0;

    for (var index = 1; index < rows.length; index++) {
      final rowNumber = index + 1;
      final values = rows[index].map((value) => value.toString()).toList();
      String cell(int? column) => column == null || column >= values.length
          ? ''
          : _restoreSpreadsheetCell(values[column].trim());

      final title = cell(columns.title);
      final rawArtists = cell(columns.artist);
      final artists = _parseArtists(rawArtists, format: format);
      final artist = artists.isEmpty ? rawArtists : artists.first;
      final rawId = cell(columns.youtubeId);
      final rawUrl = cell(columns.url);
      final videoId = _youtubeVideoId(rawId) ?? _youtubeVideoId(rawUrl);
      final youtubeUrl = videoId == null
          ? null
          : 'https://www.youtube.com/watch?v=$videoId';
      final sourceUri = cell(columns.sourceUri).trim();
      final isrc = _emptyToNull(cell(columns.isrc));
      if (title.isEmpty && videoId == null) {
        invalidRows++;
        _addWarning(warnings, 'Fila $rowNumber: falta título o ID de YouTube.');
        continue;
      }
      final playlistValue = cell(columns.playlist).trim();
      final memberships = <LibraryCsvMembership>[];
      if (columns.playlist != null) {
        if (playlistValue.isNotEmpty) {
          memberships.add(
            LibraryCsvMembership(
              name: _limitedPlaylistName(playlistValue),
              position: _positiveInt(cell(columns.position)) ?? rowNumber - 1,
              id: _limitedPlaylistId(cell(columns.playlistId)),
            ),
          );
        }
      } else {
        memberships.add(
          LibraryCsvMembership(
            name: defaultPlaylistName,
            position: rowNumber - 1,
          ),
        );
      }
      final track = LibraryCsvTrack(
        rowNumber: rowNumber,
        title: title,
        artist: artist,
        artists: artists,
        album: _emptyToNull(cell(columns.album)),
        youtubeVideoId: videoId,
        youtubeUrl: youtubeUrl,
        duration: _parseDuration(
          cell(columns.duration),
          header: columns.duration == null
              ? ''
              : normalizedHeader[columns.duration!],
        ),
        thumbnailUrl: _emptyToNull(cell(columns.thumbnail)),
        isrc: isrc,
        sourceUri: sourceUri.isEmpty ? _emptyToNull(rawUrl) : sourceUri,
        addedAt: DateTime.tryParse(cell(columns.addedAt)),
        memberships: memberships,
      );
      final existing = parsed[track.dedupeKey];
      if (existing == null) {
        parsed[track.dedupeKey] = track;
      } else {
        duplicateRows++;
        parsed[track.dedupeKey] = existing.copyWith(
          memberships: _mergeMemberships(existing.memberships, memberships),
        );
      }
    }
    if (parsed.isEmpty) {
      throw const FormatException('El CSV no contiene canciones válidas.');
    }
    return LibraryCsvDocument(
      tracks: List.unmodifiable(parsed.values),
      detectedFormat: format,
      defaultPlaylistName: defaultPlaylistName,
      hasPlaylistColumn: columns.playlist != null,
      invalidRowCount: invalidRows,
      duplicateRowCount: duplicateRows,
      warnings: List.unmodifiable(warnings),
    );
  }

  Uint8List exportDocument(
    LibraryCsvDocument document,
    LibraryCsvProfile profile,
  ) {
    final rows = <List<dynamic>>[_headersFor(profile)];
    switch (profile) {
      case LibraryCsvProfile.bstream:
        for (final track in document.tracks) {
          final memberships = track.memberships.isEmpty
              ? const <LibraryCsvMembership?>[null]
              : track.memberships.cast<LibraryCsvMembership?>();
          for (final membership in memberships) {
            rows.add(_bstreamRow(track, membership));
          }
        }
      case LibraryCsvProfile.metroList:
        rows.addAll(document.tracks.map(_metroListRow));
      case LibraryCsvProfile.harmony:
        for (final track in document.tracks) {
          final memberships = track.memberships.isEmpty
              ? const <LibraryCsvMembership?>[null]
              : track.memberships.cast<LibraryCsvMembership?>();
          for (final membership in memberships) {
            rows.add(_harmonyRow(track, membership));
          }
        }
      case LibraryCsvProfile.soundiiz:
        rows.addAll(document.tracks.map(_soundiizRow));
    }
    final encoded =
        Csv(lineDelimiter: '\r\n', addBom: true, dynamicTyping: false).encode(
          rows
              .map(
                (row) => row
                    .map(
                      (value) =>
                          value is String ? _safeSpreadsheetCell(value) : value,
                    )
                    .toList(growable: false),
              )
              .toList(growable: false),
        );
    return Uint8List.fromList(utf8.encode(encoded));
  }

  Future<File> createExportFile({
    required LibraryCsvDocument document,
    required LibraryCsvProfile profile,
    required String outputPath,
  }) async {
    final destination = File(outputPath);
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.part');
    if (await partial.exists()) {
      await partial.delete();
    }
    try {
      await partial.writeAsBytes(
        exportDocument(document, profile),
        flush: true,
      );
      if (await destination.exists()) {
        await destination.delete();
      }
      return await partial.rename(destination.path);
    } catch (_) {
      if (await partial.exists()) {
        await partial.delete();
      }
      rethrow;
    }
  }
}

class _CsvColumns {
  const _CsvColumns({
    this.title,
    this.artist,
    this.album,
    this.youtubeId,
    this.url,
    this.sourceUri,
    this.playlist,
    this.playlistId,
    this.position,
    this.duration,
    this.thumbnail,
    this.isrc,
    this.addedAt,
  });

  final int? title;
  final int? artist;
  final int? album;
  final int? youtubeId;
  final int? url;
  final int? sourceUri;
  final int? playlist;
  final int? playlistId;
  final int? position;
  final int? duration;
  final int? thumbnail;
  final int? isrc;
  final int? addedAt;

  factory _CsvColumns.fromHeaders(List<String> headers) {
    int? find(Set<String> aliases) {
      for (var index = 0; index < headers.length; index++) {
        if (aliases.contains(headers[index])) return index;
      }
      return null;
    }

    return _CsvColumns(
      title: find(_titleAliases),
      artist: find(_artistAliases),
      album: find(_albumAliases),
      youtubeId: find(_youtubeIdAliases),
      url: find(_urlAliases),
      sourceUri: find(_sourceUriAliases),
      playlist: find(_playlistAliases),
      playlistId: find(_playlistIdAliases),
      position: find(_positionAliases),
      duration: find(_durationAliases),
      thumbnail: find(_thumbnailAliases),
      isrc: find(const {'isrc'}),
      addedAt: find(_addedAtAliases),
    );
  }
}

const _titleAliases = {
  'title',
  'trackname',
  'song',
  'songname',
  'name',
  'titulo',
  'nombredelacancion',
};
const _artistAliases = {
  'artist',
  'artists',
  'artistnames',
  'artistname',
  'authors',
  'author',
  'artista',
  'artistas',
  'channel',
  'uploader',
};
const _albumAliases = {'album', 'albumname', 'albumtitle', 'nombrealbum'};
const _youtubeIdAliases = {
  'youtubevideoid',
  'youtubeid',
  'videoid',
  'mediaid',
  'ytid',
};
const _urlAliases = {
  'youtubeurl',
  'videourl',
  'url',
  'songurl',
  'trackurl',
  'songlink',
  'weburl',
  'sourceurl',
};
const _sourceUriAliases = {
  'trackuri',
  'sourceuri',
  'spotifyuri',
  'spotifyid',
  'appleid',
};
const _playlistAliases = {
  'playlist',
  'playlistname',
  'playlisttitle',
  'list',
  'listname',
};
const _playlistIdAliases = {'playlistid', 'bstreamplaylistid'};
const _positionAliases = {
  'position',
  'index',
  'playlistindex',
  'tracknumber',
  'orden',
  'numero',
};
const _durationAliases = {
  'duration',
  'durationms',
  'durationseconds',
  'trackdurationms',
  'trackduration',
  'length',
  'duracion',
};
const _thumbnailAliases = {
  'thumbnailurl',
  'albumimageurl',
  'imageurl',
  'coverurl',
  'artworkurl',
};
const _addedAtAliases = {'addedat', 'dateadded', 'addeddate', 'fechaagregada'};

LibraryCsvDetectedFormat _detectFormat(List<String> headers) {
  final set = headers.toSet();
  if (set.contains('bstreamcsvversion')) {
    return LibraryCsvDetectedFormat.bstream;
  }
  if (set.contains('youtubevideoid') && set.contains('title')) {
    return LibraryCsvDetectedFormat.metroList;
  }
  if (set.contains('playlistbrowseid') && set.contains('mediaid')) {
    return LibraryCsvDetectedFormat.harmony;
  }
  if (set.contains('trackuri') && set.contains('trackname')) {
    return LibraryCsvDetectedFormat.exportify;
  }
  if (set.contains('isrc') && set.contains('title')) {
    return LibraryCsvDetectedFormat.soundiiz;
  }
  return LibraryCsvDetectedFormat.generic;
}

List<dynamic> _headersFor(LibraryCsvProfile profile) => switch (profile) {
  LibraryCsvProfile.bstream => const [
    'BStreamCsvVersion',
    'PlaylistName',
    'PlaylistId',
    'Position',
    'MediaId',
    'Title',
    'Artists',
    'Album',
    'DurationSeconds',
    'SourceUrl',
    'ThumbnailUrl',
    'ISRC',
    'SourceUri',
  ],
  LibraryCsvProfile.metroList => const [
    'Title',
    'Artist',
    'Album',
    'YouTube Video ID',
  ],
  LibraryCsvProfile.harmony => const [
    'PlaylistBrowseId',
    'PlaylistName',
    'MediaId',
    'Title',
    'Artists',
    'Duration',
    'ThumbnailUrl',
    'AlbumId',
    'AlbumTitle',
    'ArtistIds',
  ],
  LibraryCsvProfile.soundiiz => const ['title', 'artist', 'album', 'isrc'],
};

List<dynamic> _bstreamRow(
  LibraryCsvTrack track,
  LibraryCsvMembership? membership,
) => [
  '1',
  membership?.name ?? '',
  membership?.id ?? '',
  membership?.position ?? '',
  track.youtubeVideoId ?? '',
  track.title,
  _joinedArtists(track, separator: '; '),
  track.album ?? '',
  track.duration?.inSeconds ?? '',
  track.youtubeUrl ?? '',
  track.thumbnailUrl ?? '',
  track.isrc ?? '',
  track.sourceUri ?? '',
];

List<dynamic> _metroListRow(LibraryCsvTrack track) => [
  track.title,
  _joinedArtists(track, separator: '; '),
  track.album ?? '',
  track.youtubeVideoId ?? '',
];

List<dynamic> _harmonyRow(
  LibraryCsvTrack track,
  LibraryCsvMembership? membership,
) => [
  '',
  membership?.name ?? '',
  track.youtubeVideoId ?? '',
  track.title,
  _joinedArtists(track),
  _formatDuration(track.duration),
  track.thumbnailUrl ?? '',
  '',
  track.album ?? '',
  '',
];

List<dynamic> _soundiizRow(LibraryCsvTrack track) => [
  track.title,
  _joinedArtists(track),
  track.album ?? '',
  track.isrc ?? '',
];

LibraryCsvTrack _trackFromLocal(
  LocalTrack track,
  int rowNumber,
  List<LibraryCsvMembership> memberships,
) {
  final videoId =
      _youtubeVideoId(track.sourceId) ?? _youtubeVideoId(track.sourceUrl);
  return LibraryCsvTrack(
    rowNumber: rowNumber,
    title: track.title,
    artist: track.artist,
    artists: track.artists,
    album: track.album,
    youtubeVideoId: videoId,
    youtubeUrl: videoId == null
        ? null
        : 'https://www.youtube.com/watch?v=$videoId',
    duration: track.duration,
    thumbnailUrl: track.thumbnailUrl ?? track.catalogThumbnailUrl,
    sourceUri: track.sourceUrl,
    addedAt: track.addedAt,
    memberships: List.unmodifiable(memberships),
  );
}

String _decodeText(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _decodeUtf16(bytes.sublist(2), littleEndian: false);
  }
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    return _decodeWindows1252(bytes);
  }
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  if (bytes.length.isOdd) {
    throw const FormatException('El CSV UTF-16 está truncado.');
  }
  final units = <int>[];
  for (var index = 0; index < bytes.length; index += 2) {
    units.add(
      littleEndian
          ? bytes[index] | (bytes[index + 1] << 8)
          : (bytes[index] << 8) | bytes[index + 1],
    );
  }
  return String.fromCharCodes(units);
}

String _decodeWindows1252(List<int> bytes) {
  const replacements = <int, int>{
    0x80: 0x20AC,
    0x82: 0x201A,
    0x83: 0x0192,
    0x84: 0x201E,
    0x85: 0x2026,
    0x86: 0x2020,
    0x87: 0x2021,
    0x88: 0x02C6,
    0x89: 0x2030,
    0x8A: 0x0160,
    0x8B: 0x2039,
    0x8C: 0x0152,
    0x8E: 0x017D,
    0x91: 0x2018,
    0x92: 0x2019,
    0x93: 0x201C,
    0x94: 0x201D,
    0x95: 0x2022,
    0x96: 0x2013,
    0x97: 0x2014,
    0x98: 0x02DC,
    0x99: 0x2122,
    0x9A: 0x0161,
    0x9B: 0x203A,
    0x9C: 0x0153,
    0x9E: 0x017E,
    0x9F: 0x0178,
  };
  return String.fromCharCodes(bytes.map((byte) => replacements[byte] ?? byte));
}

String _normalizeHeader(String value) =>
    _normalizeValue(value).replaceAll(RegExp(r'[^a-z0-9]'), '');

String _normalizeValue(String value) {
  var normalized = value.toLowerCase().trim();
  const accents = {
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'â': 'a',
    'ã': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'ê': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'î': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ô': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'û': 'u',
    'ñ': 'n',
    'ç': 'c',
  };
  for (final entry in accents.entries) {
    normalized = normalized.replaceAll(entry.key, entry.value);
  }
  return normalized.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

String? _youtubeVideoId(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(value)) return value;
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  if (host == 'youtu.be') {
    final candidate = uri.pathSegments.firstOrNull;
    return candidate != null &&
            RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(candidate)
        ? candidate
        : null;
  }
  if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
    final queryId = uri.queryParameters['v'];
    if (queryId != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(queryId)) {
      return queryId;
    }
    for (var index = 0; index + 1 < uri.pathSegments.length; index++) {
      if (const {'shorts', 'embed', 'live'}.contains(uri.pathSegments[index])) {
        final candidate = uri.pathSegments[index + 1];
        if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(candidate)) {
          return candidate;
        }
      }
    }
  }
  return null;
}

List<String> _parseArtists(
  String value, {
  required LibraryCsvDetectedFormat format,
}) {
  if (value.trim().isEmpty) return const [];
  final separator = value.contains(';')
      ? RegExp(r'\s*;\s*')
      : switch (format) {
          LibraryCsvDetectedFormat.harmony ||
          LibraryCsvDetectedFormat.exportify ||
          LibraryCsvDetectedFormat.soundiiz =>
            value.contains(',') ? RegExp(r'\s*,\s*') : null,
          _ => null,
        };
  return (separator == null ? [value] : value.split(separator))
      .map((artist) => artist.trim())
      .where((artist) => artist.isNotEmpty)
      .toList(growable: false);
}

Duration? _parseDuration(String value, {required String header}) {
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  if (normalized.contains(':')) {
    final parts = normalized.split(':').map(int.tryParse).toList();
    if (parts.any((part) => part == null) ||
        parts.length < 2 ||
        parts.length > 3) {
      return null;
    }
    final values = parts.cast<int>();
    final seconds = values.length == 3
        ? values[0] * 3600 + values[1] * 60 + values[2]
        : values[0] * 60 + values[1];
    return seconds < 0 ? null : Duration(seconds: seconds);
  }
  final number = num.tryParse(normalized);
  if (number == null || number < 0) return null;
  final isMilliseconds = header.contains('ms') || number > 100000;
  return isMilliseconds
      ? Duration(milliseconds: number.round())
      : Duration(seconds: number.round());
}

String _formatDuration(Duration? duration) {
  if (duration == null) return '';
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0
      ? '${hours.toString().padLeft(2, '0')}:$minutes:$seconds'
      : '$minutes:$seconds';
}

String _joinedArtists(LibraryCsvTrack track, {String separator = ', '}) {
  if (track.artists.isNotEmpty) return track.artists.join(separator);
  return track.artist;
}

List<LibraryCsvMembership> _mergeMemberships(
  List<LibraryCsvMembership> first,
  List<LibraryCsvMembership> second,
) {
  final result = <LibraryCsvMembership>[...first];
  for (final candidate in second) {
    if (!result.any(
      (entry) =>
          (entry.id?.trim().isNotEmpty == true &&
                  candidate.id?.trim().isNotEmpty == true
              ? entry.id!.trim() == candidate.id!.trim()
              : entry.name.toLowerCase() == candidate.name.toLowerCase()) &&
          entry.position == candidate.position,
    )) {
      result.add(candidate);
    }
  }
  return List.unmodifiable(result);
}

String _defaultPlaylistName(String fileName) {
  final value = p.basenameWithoutExtension(fileName).trim();
  return _limitedPlaylistName(value.isEmpty ? 'Playlist importada' : value);
}

String _limitedPlaylistName(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\u0000-\u001F]'), ' ').trim();
  if (cleaned.isEmpty) return 'Playlist importada';
  return cleaned.length > 120 ? cleaned.substring(0, 120).trim() : cleaned;
}

String? _limitedPlaylistId(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\u0000-\u001F]'), '').trim();
  if (!RegExp(r'^[A-Za-z0-9:_-]{1,200}$').hasMatch(cleaned)) return null;
  return cleaned;
}

int? _positiveInt(String value) {
  final parsed = int.tryParse(value.trim());
  return parsed != null && parsed > 0 ? parsed : null;
}

String? _emptyToNull(String value) =>
    value.trim().isEmpty ? null : value.trim();

void _addWarning(List<String> warnings, String warning) {
  if (warnings.length < LibraryCsvService.maxWarnings) warnings.add(warning);
}

String _safeSpreadsheetCell(String value) {
  if (value.isEmpty) return value;
  final first = value.codeUnitAt(0);
  if (const {0x3D, 0x2B, 0x2D, 0x40, 0x09, 0x0D}.contains(first)) {
    return "'$value";
  }
  return value;
}

String _restoreSpreadsheetCell(String value) {
  if (value.length < 2 || !value.startsWith("'")) return value;
  final second = value.codeUnitAt(1);
  return const {0x3D, 0x2B, 0x2D, 0x40, 0x09, 0x0D}.contains(second)
      ? value.substring(1)
      : value;
}
