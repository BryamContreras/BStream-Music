import 'dart:convert';
import 'dart:typed_data';

import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/services/storage/library_csv_service.dart';
import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = LibraryCsvService();

  group('imports common library formats', () {
    test('imports the exact MetroList columns', () {
      final document = _importUtf8(
        service,
        fileName: 'MetroList.csv',
        content:
            'Title,Artist,Album,YouTube Video ID\r\n'
            'Get Lucky,"Daft Punk; Pharrell Williams",Random Access Memories,dQw4w9WgXcQ\r\n',
      );

      expect(document.detectedFormat, LibraryCsvDetectedFormat.metroList);
      expect(document.hasPlaylistColumn, isFalse);
      expect(document.defaultPlaylistName, 'MetroList');
      expect(document.tracks, hasLength(1));
      final track = document.tracks.single;
      expect(track.title, 'Get Lucky');
      expect(track.artist, 'Daft Punk');
      expect(track.artists, ['Daft Punk', 'Pharrell Williams']);
      expect(track.album, 'Random Access Memories');
      expect(track.youtubeVideoId, 'dQw4w9WgXcQ');
      expect(track.memberships.single.name, 'MetroList');
      expect(track.memberships.single.position, 1);
    });

    test('imports exact Harmony columns with playlist and duration', () {
      final document = _importUtf8(
        service,
        fileName: 'Harmony.csv',
        content:
            'PlaylistBrowseId,PlaylistName,MediaId,Title,Artists,Duration,'
            'ThumbnailUrl,AlbumId,AlbumTitle,ArtistIds\r\n'
            'VLPL123,Favoritas,dQw4w9WgXcQ,"Song, Live",'
            '"Artist One, Artist Two",01:02:03,https://img.example/cover.jpg,'
            'MPRE123,The Album,UC123\r\n',
      );

      expect(document.detectedFormat, LibraryCsvDetectedFormat.harmony);
      expect(document.hasPlaylistColumn, isTrue);
      final track = document.tracks.single;
      expect(track.title, 'Song, Live');
      expect(track.artists, ['Artist One', 'Artist Two']);
      expect(track.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(track.thumbnailUrl, 'https://img.example/cover.jpg');
      expect(track.album, 'The Album');
      expect(track.memberships.single.name, 'Favoritas');
      expect(track.memberships.single.position, 1);
    });

    test('imports the standard Exportify headers and millisecond duration', () {
      final document = _importUtf8(
        service,
        fileName: 'spotify-export.csv',
        content:
            'Track URI,Track Name,Album Name,Artist Name(s),Duration (ms),Added At\r\n'
            'spotify:track:0123456789,Midnight City,Hurry Up We Are Dreaming,'
            'M83,244560,2024-05-02T03:04:05Z\r\n',
      );

      expect(document.detectedFormat, LibraryCsvDetectedFormat.exportify);
      final track = document.tracks.single;
      expect(track.title, 'Midnight City');
      expect(track.artist, 'M83');
      expect(track.album, 'Hurry Up We Are Dreaming');
      expect(track.sourceUri, 'spotify:track:0123456789');
      expect(track.duration, const Duration(milliseconds: 244560));
      expect(track.addedAt, DateTime.utc(2024, 5, 2, 3, 4, 5));
    });

    test('imports a semicolon Soundiiz file with its sep directive', () {
      final document = _importUtf8(
        service,
        fileName: 'Soundiiz.csv',
        content:
            'sep=;\r\n'
            'title;artist;album;isrc\r\n'
            'Instant Crush;Daft Punk;Random Access Memories;USQX91300105\r\n',
      );

      expect(document.detectedFormat, LibraryCsvDetectedFormat.soundiiz);
      final track = document.tracks.single;
      expect(track.title, 'Instant Crush');
      expect(track.artist, 'Daft Punk');
      expect(track.album, 'Random Access Memories');
      expect(track.isrc, 'USQX91300105');
    });
  });

  group('decodes robust CSV text inputs', () {
    test('accepts an UTF-8 BOM and a quoted multiline cell', () {
      const content =
          'Title,Artist,YouTube Video ID\r\n'
          '"First line\r\nSecond line","Artist, Jr.",dQw4w9WgXcQ\r\n';
      final document = service.importBytes(
        LibraryCsvInput(
          bytes: Uint8List.fromList([
            0xEF,
            0xBB,
            0xBF,
            ...utf8.encode(content),
          ]),
          fileName: 'multiline.csv',
        ),
      );

      expect(document.tracks.single.title, 'First line\r\nSecond line');
      expect(document.tracks.single.artist, 'Artist, Jr.');
    });

    test('accepts UTF-16 little-endian with BOM', () {
      const content =
          'Title,Artist,YouTube Video ID\r\n'
          'Canción,Beyoncé,dQw4w9WgXcQ\r\n';
      final document = service.importBytes(
        LibraryCsvInput(
          bytes: _utf16LittleEndian(content),
          fileName: 'utf16.csv',
        ),
      );

      expect(document.tracks.single.title, 'Canción');
      expect(document.tracks.single.artist, 'Beyoncé');
    });

    test('falls back to Windows-1252', () {
      final bytes = <int>[
        ...ascii.encode('Title,Artist,YouTube Video ID\r\nCaf'),
        0xE9,
        ...ascii.encode(',Beyonc'),
        0xE9,
        ...ascii.encode(',dQw4w9WgXcQ\r\n'),
      ];
      final document = service.importBytes(
        LibraryCsvInput(
          bytes: Uint8List.fromList(bytes),
          fileName: 'legacy.csv',
        ),
      );

      expect(document.tracks.single.title, 'Café');
      expect(document.tracks.single.artist, 'Beyoncé');
    });
  });

  group('validation and deduplication', () {
    test('deduplicates tracks and unique playlist memberships', () {
      final document = _importUtf8(
        service,
        fileName: 'memberships.csv',
        content:
            'BStreamCsvVersion,PlaylistName,Position,MediaId,Title,Artists\r\n'
            '1,Favoritas,1,dQw4w9WgXcQ,One,Artist\r\n'
            '1,Favoritas,1,dQw4w9WgXcQ,One,Artist\r\n'
            '1,Viaje,4,dQw4w9WgXcQ,One,Artist\r\n',
      );

      expect(document.uniqueTrackCount, 1);
      expect(document.duplicateRowCount, 2);
      expect(document.tracks.single.memberships, hasLength(2));
      expect(document.tracks.single.memberships.map((entry) => entry.name), [
        'Favoritas',
        'Viaje',
      ]);
      expect(
        document.tracks.single.memberships.map((entry) => entry.position),
        [1, 4],
      );
    });

    test('does not collapse case-sensitive YouTube IDs or distinct albums', () {
      final document = _importUtf8(
        service,
        fileName: 'distinct.csv',
        content:
            'Title,Artist,Album,YouTube Video ID,DurationSeconds\n'
            'Same,Artist,Album A,Abcdefghijk,180\n'
            'Same,Artist,Album A,abcdefghijk,180\n'
            'No ID,Artist,Album A,,180\n'
            'No ID,Artist,Album B,,180\n',
      );

      expect(document.tracks, hasLength(4));
      expect(document.duplicateRowCount, 0);
    });

    test('skips invalid rows and reports bounded warnings', () {
      final rows = StringBuffer('Title,YouTube Video ID\n');
      for (var index = 0; index < 60; index++) {
        rows.writeln(',not-a-youtube-id');
      }
      rows.writeln('Valid,dQw4w9WgXcQ');

      final document = _importUtf8(
        service,
        fileName: 'partially-invalid.csv',
        content: rows.toString(),
      );

      expect(document.tracks.single.title, 'Valid');
      expect(document.invalidRowCount, 60);
      expect(document.warnings, hasLength(LibraryCsvService.maxWarnings));
      expect(document.warnings.first, contains('Fila 2'));
    });

    test('rejects an empty or oversized file', () {
      expect(
        () => service.importBytes(
          LibraryCsvInput(bytes: Uint8List(0), fileName: 'empty.csv'),
        ),
        throwsFormatException,
      );
      expect(
        () => service.importBytes(
          LibraryCsvInput(
            bytes: Uint8List(LibraryCsvService.maxFileBytes + 1),
            fileName: 'large.csv',
          ),
        ),
        throwsFormatException,
      );
    });

    test('rejects more than the maximum row count', () {
      final content = StringBuffer('Title\n');
      for (var index = 0; index <= LibraryCsvService.maxRows; index++) {
        content.writeln('Track $index');
      }

      expect(
        () => _importUtf8(
          service,
          fileName: 'too-many-rows.csv',
          content: content.toString(),
        ),
        throwsFormatException,
      );
    });

    test('rejects more than the maximum column count', () {
      final headers = <String>[
        'Title',
        for (var index = 1; index <= LibraryCsvService.maxColumns; index++)
          'Column$index',
      ];

      expect(
        () => _importUtf8(
          service,
          fileName: 'too-many-columns.csv',
          content: '${headers.join(',')}\nTrack\n',
        ),
        throwsFormatException,
      );
    });

    test('rejects a cell over the character limit', () {
      expect(
        () => _importUtf8(
          service,
          fileName: 'huge-cell.csv',
          content:
              'Title\n${'x' * (LibraryCsvService.maxCellCharacters + 1)}\n',
        ),
        throwsFormatException,
      );
    });
  });

  group('exports interoperable and safe documents', () {
    test('round-trips metadata-only catalog songs and playlist identities', () {
      final now = DateTime.utc(2026, 10, 26);
      final song = CatalogTrack.youtube(
        videoId: 'Abcdefghijk',
        title: 'Imported song',
        artists: ['Singer', 'Guest'],
        album: 'Imported album',
        duration: const Duration(minutes: 4, seconds: 5),
        thumbnailUrl: 'https://img.example/imported.jpg',
        sourceUrl: 'https://music.youtube.com/watch?v=Abcdefghijk',
      );
      CatalogPlaylist catalog(String id, String name, int position) {
        return CatalogPlaylist(
          playlist: Playlist(
            id: id,
            name: name,
            trackIds: const [],
            createdAt: now,
            updatedAt: now,
          ),
          entries: [
            PlaylistEntry(
              id: '$id-entry',
              playlistId: id,
              track: song,
              position: position,
              createdAt: now,
              updatedAt: now,
            ),
          ],
        );
      }

      final original = LibraryCsvDocument.fromLibrary(
        tracks: const [],
        playlists: const [],
        catalogPlaylists: [
          catalog(Playlist.favoritesId, 'Favoritas', 0),
          catalog('imported-one', 'Same name', 4),
          catalog('imported-two', 'Same name', 2),
        ],
      );
      final restored = service.importBytes(
        LibraryCsvInput(
          bytes: service.exportDocument(original, LibraryCsvProfile.bstream),
          fileName: 'metadata-only.csv',
        ),
      );

      expect(restored.playlistCount, 3);
      final exported = restored.tracks.single;
      expect(exported.youtubeVideoId, song.youtubeVideoId);
      expect(exported.title, song.title);
      expect(exported.artists, song.artists);
      expect(exported.album, song.album);
      expect(exported.duration, song.duration);
      expect(exported.thumbnailUrl, song.thumbnailUrl);
      expect(exported.sourceUri, song.sourceUrl);
      expect(exported.memberships.map((entry) => entry.id), [
        Playlist.favoritesId,
        'imported-one',
        'imported-two',
      ]);
      expect(exported.memberships.map((entry) => entry.position), [1, 5, 3]);
    });

    test(
      'merges streamed downloads without duplicating favorite membership',
      () {
        final now = DateTime.utc(2026, 10, 26);
        final download = LocalTrack(
          id: 'download',
          title: 'Downloaded song',
          artist: 'Singer',
          filePath: 'song.m4a',
          addedAt: now,
          sourceId: 'Abcdefghijk',
        );
        final playlist = Playlist(
          id: Playlist.favoritesId,
          name: 'Favoritas',
          trackIds: ['download'],
          createdAt: now,
          updatedAt: now,
        );
        PlaylistEntry entry(String id, String videoId, int position) {
          return PlaylistEntry(
            id: id,
            playlistId: playlist.id,
            track: CatalogTrack.youtube(
              videoId: videoId,
              title: 'Catalog song',
              artists: ['Singer'],
              album: 'Catalog album',
            ),
            position: position,
            createdAt: now,
            updatedAt: now,
          );
        }

        final document = LibraryCsvDocument.fromLibrary(
          tracks: [
            download,
            download.copyWith(id: 'second-download'),
          ],
          playlists: [playlist],
          catalogPlaylists: [
            CatalogPlaylist(
              playlist: playlist,
              entries: [
                entry('stream-only', 'abcdefghijk', 0),
                entry('downloaded', 'Abcdefghijk', 1),
                entry('duplicate-favorite', 'Abcdefghijk', 2),
              ],
            ),
          ],
        );
        final restored = service.importBytes(
          LibraryCsvInput(
            bytes: service.exportDocument(document, LibraryCsvProfile.bstream),
            fileName: 'favorites.csv',
          ),
        );

        expect(restored.tracks, hasLength(2));
        expect(restored.duplicateRowCount, 0);
        expect(restored.playlistCount, 1);
        final shared = restored.tracks.singleWhere(
          (track) => track.youtubeVideoId == 'Abcdefghijk',
        );
        expect(shared.title, download.title);
        expect(shared.album, 'Catalog album');
        expect(shared.memberships.single.id, Playlist.favoritesId);
        expect(shared.memberships.single.position, 2);
        expect(
          restored.tracks
              .singleWhere((track) => track.youtubeVideoId == 'abcdefghijk')
              .memberships
              .single
              .position,
          1,
        );
      },
    );

    test(
      'retains distinct local identities and merges catalog local copies',
      () {
        final now = DateTime.utc(2026, 10, 26);
        final first = LocalTrack(
          id: 'local-one',
          title: 'Same title',
          artist: 'Artist',
          filePath: 'first.mp3',
          addedAt: now,
        );
        final playlist = Playlist(
          id: 'local-playlist',
          name: 'Local collection',
          trackIds: ['local-one', 'local-two'],
          createdAt: now,
          updatedAt: now,
        );
        final document = LibraryCsvDocument.fromLibrary(
          tracks: [
            first,
            first.copyWith(id: 'local-two', filePath: 'second.mp3'),
          ],
          playlists: [playlist],
          catalogPlaylists: [
            CatalogPlaylist(
              playlist: playlist,
              entries: [
                for (var index = 0; index < 2; index++)
                  PlaylistEntry(
                    id: 'entry-$index',
                    playlistId: playlist.id,
                    track: CatalogTrack.local(
                      localTrackId: playlist.trackIds[index],
                      title: 'Same title',
                      artists: ['Artist'],
                    ),
                    position: index,
                    createdAt: now,
                    updatedAt: now,
                  ),
              ],
            ),
          ],
        );
        final restored = service.importBytes(
          LibraryCsvInput(
            bytes: service.exportDocument(document, LibraryCsvProfile.bstream),
            fileName: 'local.csv',
          ),
        );

        expect(restored.tracks, hasLength(2));
        expect(restored.tracks.map((track) => track.sourceUri), [
          'local:local-one',
          'local:local-two',
        ]);
        expect(
          restored.tracks.map((track) => track.memberships.single.position),
          [1, 2],
        );
      },
    );

    test(
      'uses a catalog video identity when the download lacks source metadata',
      () {
        final now = DateTime.utc(2026, 10, 26);
        final playlist = Playlist(
          id: 'catalog-playlist',
          name: 'Catalog',
          trackIds: ['download'],
          createdAt: now,
          updatedAt: now,
        );
        final document = LibraryCsvDocument.fromLibrary(
          tracks: [
            LocalTrack(
              id: 'download',
              title: 'Downloaded title',
              artist: 'Singer',
              filePath: 'song.m4a',
              addedAt: now,
            ),
          ],
          playlists: [playlist],
          catalogPlaylists: [
            CatalogPlaylist(
              playlist: playlist,
              entries: [
                PlaylistEntry(
                  id: 'matched-entry',
                  playlistId: playlist.id,
                  track: CatalogTrack.youtube(
                    videoId: 'Abcdefghijk',
                    title: 'Catalog title',
                  ),
                  localTrackId: 'download',
                  position: 3,
                  createdAt: now,
                  updatedAt: now,
                ),
              ],
            ),
          ],
        );

        expect(document.tracks, hasLength(1));
        expect(document.tracks.single.youtubeVideoId, 'Abcdefghijk');
        expect(document.tracks.single.memberships.single.position, 4);
      },
    );

    test('preserves legacy memberships while excluding catalog tombstones', () {
      final now = DateTime.utc(2026, 10, 26);
      Playlist playlist(String id) => Playlist(
        id: id,
        name: id,
        trackIds: ['download'],
        createdAt: now,
        updatedAt: now,
      );
      final catalog = playlist('catalog');
      final deleted = playlist('deleted').copyWith(deletedAt: now);
      PlaylistEntry entry(String id, int position) => PlaylistEntry(
        id: id,
        playlistId: catalog.id,
        track: CatalogTrack.youtube(videoId: 'Abcdefghijk', title: 'Song'),
        position: position,
        createdAt: now,
        updatedAt: now,
      );
      final original = LibraryCsvDocument.fromLibrary(
        tracks: [
          LocalTrack(
            id: 'download',
            title: 'Song',
            artist: 'Artist',
            filePath: 'song.mp3',
            sourceId: 'Abcdefghijk',
            addedAt: now,
          ),
        ],
        playlists: [playlist('legacy'), catalog, playlist('deleted')],
        catalogPlaylists: [
          CatalogPlaylist(
            playlist: catalog,
            entries: [
              entry('first', 1),
              entry('duplicate', 1),
              entry('second-occurrence', 3),
              entry('removed', 4).copyWith(deletedAt: now),
            ],
          ),
          CatalogPlaylist(
            playlist: deleted,
            entries: [entry('deleted-song', 0)],
          ),
        ],
      );
      final restored = service.importBytes(
        LibraryCsvInput(
          bytes: service.exportDocument(original, LibraryCsvProfile.bstream),
          fileName: 'memberships.csv',
        ),
      );

      expect(restored.tracks.single.memberships.map((entry) => entry.id), [
        'legacy',
        'catalog',
        'catalog',
      ]);
      expect(
        restored.tracks.single.memberships.map((entry) => entry.position),
        [1, 2, 4],
      );
    });

    test('writes the exact header for every supported profile', () {
      final document = _sampleDocument();
      const expectedHeaders = <LibraryCsvProfile, List<String>>{
        LibraryCsvProfile.bstream: [
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
        LibraryCsvProfile.metroList: [
          'Title',
          'Artist',
          'Album',
          'YouTube Video ID',
        ],
        LibraryCsvProfile.harmony: [
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
        LibraryCsvProfile.soundiiz: ['title', 'artist', 'album', 'isrc'],
      };

      for (final profile in LibraryCsvProfile.values) {
        final bytes = service.exportDocument(document, profile);
        expect(bytes.take(3), [0xEF, 0xBB, 0xBF], reason: '$profile BOM');
        expect(_decodeExportRows(bytes).first, expectedHeaders[profile]);
        expect(utf8.decode(bytes), contains('\r\n'));
      }
    });

    test('round-trips every BStream field and playlist membership', () {
      final original = _sampleDocument();
      final imported = service.importBytes(
        LibraryCsvInput(
          bytes: service.exportDocument(original, LibraryCsvProfile.bstream),
          fileName: 'bstream-roundtrip.csv',
        ),
      );

      expect(imported.detectedFormat, LibraryCsvDetectedFormat.bstream);
      expect(imported.uniqueTrackCount, 1);
      expect(imported.duplicateRowCount, 1);
      final track = imported.tracks.single;
      expect(track.title, original.tracks.single.title);
      expect(track.artist, original.tracks.single.artist);
      expect(track.artists, original.tracks.single.artists);
      expect(track.album, original.tracks.single.album);
      expect(track.youtubeVideoId, original.tracks.single.youtubeVideoId);
      expect(track.youtubeUrl, original.tracks.single.youtubeUrl);
      expect(track.duration, original.tracks.single.duration);
      expect(track.thumbnailUrl, original.tracks.single.thumbnailUrl);
      expect(track.isrc, original.tracks.single.isrc);
      expect(track.sourceUri, original.tracks.single.sourceUri);
      expect(track.memberships.map((membership) => membership.name), [
        'Favoritas',
        'Viaje',
      ]);
      expect(track.memberships.map((membership) => membership.position), [
        1,
        7,
      ]);
      expect(track.memberships.map((membership) => membership.id), [
        'playlist-favorites',
        'playlist-trip',
      ]);
    });

    test('neutralizes spreadsheet formulas and restores them on import', () {
      const dangerous = [
        '=1+1',
        '+SUM(A1:A2)',
        '-10',
        '@command',
        '\tTAB',
        '\rCR',
      ];
      final document = LibraryCsvDocument(
        tracks: [
          for (var index = 0; index < dangerous.length; index++)
            LibraryCsvTrack(
              rowNumber: index + 2,
              title: dangerous[index],
              artist: '=Artist$index',
              artists: ['=Artist$index'],
              youtubeVideoId: 'aaaaaaaaaa$index',
            ),
        ],
        detectedFormat: LibraryCsvDetectedFormat.bstream,
        defaultPlaylistName: 'Formulas',
        hasPlaylistColumn: true,
      );

      final bytes = service.exportDocument(document, LibraryCsvProfile.bstream);
      final rows = _decodeExportRows(bytes);
      final titleIndex = rows.first.indexOf('Title');
      final artistIndex = rows.first.indexOf('Artists');
      for (var index = 0; index < dangerous.length; index++) {
        expect(rows[index + 1][titleIndex], "'${dangerous[index]}");
        expect(rows[index + 1][artistIndex], "'=Artist$index");
      }

      final imported = service.importBytes(
        LibraryCsvInput(bytes: bytes, fileName: 'formulas.csv'),
      );
      expect(
        imported.tracks.map((track) => track.title),
        orderedEquals(dangerous),
      );
      expect(
        imported.tracks.map((track) => track.artist),
        orderedEquals([
          for (var index = 0; index < dangerous.length; index++)
            '=Artist$index',
        ]),
      );
    });
  });
}

LibraryCsvDocument _importUtf8(
  LibraryCsvService service, {
  required String fileName,
  required String content,
}) {
  return service.importBytes(
    LibraryCsvInput(
      bytes: Uint8List.fromList(utf8.encode(content)),
      fileName: fileName,
    ),
  );
}

Uint8List _utf16LittleEndian(String value) {
  final bytes = <int>[0xFF, 0xFE];
  for (final codeUnit in value.codeUnits) {
    bytes
      ..add(codeUnit & 0xFF)
      ..add(codeUnit >> 8);
  }
  return Uint8List.fromList(bytes);
}

List<List<dynamic>> _decodeExportRows(Uint8List bytes) {
  var content = utf8.decode(bytes);
  if (content.startsWith('\ufeff')) content = content.substring(1);
  return Csv(autoDetect: true, dynamicTyping: false).decode(content);
}

LibraryCsvDocument _sampleDocument() {
  const track = LibraryCsvTrack(
    rowNumber: 2,
    title: 'Café, versión en vivo',
    artist: 'Ana',
    artists: ['Ana', 'Beto'],
    album: 'Sesiones',
    youtubeVideoId: 'dQw4w9WgXcQ',
    youtubeUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    duration: Duration(minutes: 3, seconds: 25),
    thumbnailUrl: 'https://img.example/track.jpg',
    isrc: 'USQX91300105',
    sourceUri: 'spotify:track:0123456789',
    memberships: [
      LibraryCsvMembership(
        name: 'Favoritas',
        position: 1,
        id: 'playlist-favorites',
      ),
      LibraryCsvMembership(name: 'Viaje', position: 7, id: 'playlist-trip'),
    ],
  );
  return const LibraryCsvDocument(
    tracks: [track],
    detectedFormat: LibraryCsvDetectedFormat.bstream,
    defaultPlaylistName: 'BStream Music',
    hasPlaylistColumn: true,
  );
}
