import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/services/sharing/playlist_csv_share_service.dart';
import 'package:bstream_music/services/storage/library_csv_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

void main() {
  late Directory temporaryDirectory;
  late _RecordingGateway gateway;
  late SharePlusPlaylistCsvShareService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'bstream_playlist_csv_test_',
    );
    gateway = _RecordingGateway();
    service = SharePlusPlaylistCsvShareService(
      gateway: gateway,
      temporaryDirectoryFactory: () async => temporaryDirectory,
    );
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  group('SharePlusPlaylistCsvShareService', () {
    test(
      'exports only selected active streamed and linked local tracks',
      () async {
        final playlist = _playlist(
          name: 'Viaje de verano',
          entries: [
            _entry('stream', videoId: 'aaaaaaaaaaa', position: 0),
            _entry(
              'linked',
              videoId: 'bbbbbbbbbbb',
              position: 1,
              localTrackId: 'download',
            ),
            _entry(
              'local',
              position: 2,
              track: CatalogTrack.local(
                localTrackId: 'local',
                title: 'Local catalog',
                sourceUrl: 'file:///private/catalog.flac',
                thumbnailUrl: 'https://user:secret@example.com/private.jpg',
              ),
            ),
            _entry(
              'deleted',
              videoId: 'ddddddddddd',
              position: 3,
              localTrackId: 'deleted',
              deleted: true,
            ),
            _entry(
              'foreign',
              videoId: 'eeeeeeeeeee',
              position: 4,
              playlistId: 'other-playlist',
              localTrackId: 'foreign',
            ),
          ],
        );

        await service.sharePlaylist(
          playlist: playlist,
          localTracks: [
            _local('unrelated', title: 'Unrelated private song'),
            _local('local', title: 'Local song'),
            _local('download', title: 'Downloaded song'),
            _local('deleted', title: 'Deleted song'),
            _local('foreign', title: 'Other playlist song'),
          ],
          title: 'Compartir playlist',
        );

        expect(gateway.files, hasLength(1));
        expect(gateway.files.single.name, 'Viaje de verano.csv');
        expect(gateway.files.single.mimeType, 'text/csv');
        expect(gateway.title, 'Compartir playlist: Viaje de verano');
        final document = await const LibraryCsvService().importFile(
          gateway.files.single.path,
        );
        expect(document.detectedFormat, LibraryCsvDetectedFormat.bstream);
        expect(document.tracks.map((track) => track.title), [
          'stream',
          'Downloaded song',
          'Local song',
        ]);
        expect(document.tracks.map((track) => track.youtubeVideoId), [
          'aaaaaaaaaaa',
          'bbbbbbbbbbb',
          null,
        ]);
        expect(document.tracks.map((track) => track.memberships.single.id), [
          'selected',
          'selected',
          'selected',
        ]);
        expect(
          document.tracks.map((track) => track.memberships.single.position),
          [1, 2, 3],
        );
        expect(document.playlistNames, {'Viaje de verano'});
        final content = await gateway.files.single.readAsString();
        for (final privateValue in [
          'private',
          'secret',
          'token',
          '.flac',
          'file:',
          'Unrelated',
          'Deleted song',
          'Other playlist song',
        ]) {
          expect(content, isNot(contains(privateValue)));
        }
      },
    );

    test(
      'writes repeated occurrences in playlist order with round-trip identity',
      () async {
        await service.sharePlaylist(
          playlist: _playlist(
            entries: [
              _entry('Third', videoId: 'aaaaaaaaaaa', position: 2),
              _entry('Second', videoId: 'bbbbbbbbbbb', position: 1),
              _entry('First', videoId: 'aaaaaaaaaaa', position: 0),
            ],
          ),
          localTracks: const [],
          title: '',
        );

        final content = await gateway.files.single.readAsString();
        final rows = content.trim().split('\r\n');
        expect(rows, hasLength(4));
        expect(rows[1], contains('aaaaaaaaaaa'));
        expect(rows[2], contains('bbbbbbbbbbb'));
        expect(rows[3], contains('aaaaaaaaaaa'));
        final document = await const LibraryCsvService().importFile(
          gateway.files.single.path,
        );
        expect(document.tracks, hasLength(2));
        expect(
          document.tracks.first.memberships.map(
            (membership) => membership.position,
          ),
          [1, 3],
        );
        expect(document.playlistCount, 1);
      },
    );

    test(
      'preserves favorites ID and prevents duplicate favorites membership',
      () async {
        await service.sharePlaylist(
          playlist: _playlist(
            id: Playlist.favoritesId,
            name: 'Mis favoritas',
            entries: [
              _entry(
                'First',
                videoId: 'aaaaaaaaaaa',
                playlistId: Playlist.favoritesId,
              ),
              _entry(
                'Repeated',
                videoId: 'aaaaaaaaaaa',
                playlistId: Playlist.favoritesId,
                position: 1,
              ),
            ],
          ),
          localTracks: const [],
          title: 'Compartir',
        );

        final document = await const LibraryCsvService().importFile(
          gateway.files.single.path,
        );
        expect(document.tracks.single.memberships, hasLength(1));
        expect(
          document.tracks.single.memberships.single.id,
          Playlist.favoritesId,
        );
        expect(document.tracks.single.memberships.single.name, 'Mis favoritas');
        expect(gateway.files.single.name, 'Mis favoritas.csv');
      },
    );

    test('exports legacy membership in trackIds order', () async {
      await service.sharePlaylist(
        playlist: _playlist(trackIds: ['second', 'first']),
        localTracks: [
          _local('first', title: 'First'),
          _local('unrelated', title: 'Unrelated'),
          _local('second', title: 'Second'),
        ],
        title: 'Compartir',
      );

      final document = await const LibraryCsvService().importFile(
        gateway.files.single.path,
      );
      expect(document.tracks.map((track) => track.title), ['Second', 'First']);
      expect(
        document.tracks.map((track) => track.memberships.single.position),
        [1, 2],
      );
    });

    test(
      'does not resurrect tombstoned entries from legacy track IDs',
      () async {
        await service.sharePlaylist(
          playlist: _playlist(
            trackIds: ['deleted'],
            entries: [
              _entry('Deleted', localTrackId: 'deleted', deleted: true),
            ],
          ),
          localTracks: [_local('deleted', title: 'Deleted song')],
          title: 'Compartir',
        );

        final content = await gateway.files.single.readAsString();
        expect(content, startsWith('BStreamCsvVersion,'));
        expect(content, isNot(contains('Deleted')));
        expect(content.trim().split('\r\n'), hasLength(1));
      },
    );

    test(
      'preserves names and sanitizes filenames across supported platforms',
      () async {
        final examples = <String, String>{
          'Café y música 🎵': 'Café y música 🎵.csv',
          r'Viaje/fiesta\noche:*?"<>|': 'Viaje_fiesta_noche_______.csv',
          'CON': '_CON.csv',
          'aux.csv': '_aux.csv',
          'Mi lista.CSV': 'Mi lista.csv',
          '  Noche.  ': 'Noche.csv',
          '..': 'Playlist.csv',
          '   ': 'Playlist.csv',
          'Mi\nlista\u0000': 'Mi_lista_.csv',
        };
        for (final example in examples.entries) {
          await service.sharePlaylist(
            playlist: _playlist(name: example.key),
            localTracks: const [],
            title: '',
          );
          final file = gateway.files.last;
          expect(file.name, example.value, reason: example.key);
          expect(p.basename(file.path), example.value);
        }
      },
    );

    test('limits long unicode names without splitting characters', () async {
      await service.sharePlaylist(
        playlist: _playlist(name: List.filled(200, '音🎵').join()),
        localTracks: const [],
        title: '',
      );
      final name = gateway.files.single.name;
      expect(name, endsWith('.csv'));
      expect(utf8.encode(name).length, lessThanOrEqualTo(184));
      expect(name, isNot(contains('\uFFFD')));
      expect(await File(gateway.files.single.path).exists(), isTrue);
    });

    test(
      'retains unique files for delayed and concurrent share consumers',
      () async {
        await Future.wait([
          service.sharePlaylist(
            playlist: _playlist(name: 'Viaje'),
            localTracks: const [],
            title: '',
          ),
          service.sharePlaylist(
            playlist: _playlist(name: 'Viaje'),
            localTracks: const [],
            title: '',
          ),
        ]);
        expect(gateway.files.map((file) => file.path).toSet(), hasLength(2));
        for (final file in gateway.files) {
          expect(await File(file.path).exists(), isTrue);
          expect(await file.readAsString(), contains('BStreamCsvVersion'));
        }
      },
    );

    test('prunes only marked exports older than seven days', () async {
      final root = await Directory(
        p.join(temporaryDirectory.path, 'bstream-playlist-csv'),
      ).create();
      final expired = await Directory(
        p.join(root.path, 'share_expired'),
      ).create();
      final recent = await Directory(
        p.join(root.path, 'share_recent'),
      ).create();
      final unmarked = await Directory(
        p.join(root.path, 'share_unmarked'),
      ).create();
      final unrelated = await Directory(
        p.join(root.path, 'other_directory'),
      ).create();
      for (final directory in [expired, recent, unrelated]) {
        final marker = await File(
          p.join(directory.path, '.bstream-playlist-csv-share'),
        ).writeAsString('BStream playlist CSV share');
        if (directory != recent) {
          await marker.setLastModified(
            DateTime.now().subtract(const Duration(days: 8)),
          );
        }
      }
      await service.sharePlaylist(
        playlist: _playlist(),
        localTracks: const [],
        title: '',
      );
      expect(await expired.exists(), isFalse);
      expect(await recent.exists(), isTrue);
      expect(await unmarked.exists(), isTrue);
      expect(await unrelated.exists(), isTrue);
    });

    test(
      'forwards subject and valid origin without duplicating the name',
      () async {
        const origin = Rect.fromLTWH(12, 20, 48, 48);
        await service.sharePlaylist(
          playlist: _playlist(name: 'Viaje'),
          localTracks: const [],
          title: 'Compartir Viaje',
          subject: 'Para el viaje',
          sharePositionOrigin: origin,
        );
        expect(gateway.title, 'Compartir Viaje');
        expect(gateway.subject, 'Para el viaje');
        expect(gateway.sharePositionOrigin, origin);
      },
    );

    test('provides a safe origin for absent or invalid iPad anchors', () async {
      for (final origin in <Rect?>[
        null,
        Rect.zero,
        const Rect.fromLTWH(-10, 20, 40, 40),
        const Rect.fromLTWH(10, 20, -40, 40),
        const Rect.fromLTWH(double.nan, 20, 40, 40),
        const Rect.fromLTWH(10, 20, double.infinity, 40),
      ]) {
        await service.sharePlaylist(
          playlist: _playlist(),
          localTracks: const [],
          title: '',
          sharePositionOrigin: origin,
        );
        expect(gateway.sharePositionOrigin, const Rect.fromLTWH(0, 0, 1, 1));
      }
    });

    test(
      'propagates gateway errors while retaining any dispatched attachment',
      () async {
        gateway.error = StateError('share unavailable');
        await expectLater(
          service.sharePlaylist(
            playlist: _playlist(),
            localTracks: const [],
            title: '',
          ),
          throwsStateError,
        );
        expect(gateway.files, hasLength(1));
        expect(await File(gateway.files.single.path).exists(), isTrue);
      },
    );

    test(
      'propagates temporary storage errors without invoking share',
      () async {
        service = SharePlusPlaylistCsvShareService(
          gateway: gateway,
          temporaryDirectoryFactory: () async =>
              throw const FileSystemException('no temp storage'),
        );
        await expectLater(
          service.sharePlaylist(
            playlist: _playlist(),
            localTracks: const [],
            title: '',
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(gateway.files, isEmpty);
      },
    );

    test('rejects deleted playlists before invoking share', () async {
      final playlist = _playlist();
      await expectLater(
        service.sharePlaylist(
          playlist: CatalogPlaylist(
            playlist: playlist.playlist.copyWith(deletedAt: DateTime(2026)),
            entries: playlist.entries,
          ),
          localTracks: const [],
          title: '',
        ),
        throwsFormatException,
      );
      expect(gateway.files, isEmpty);
    });
  });

  group('SharePlusPlaylistCsvShareGateway', () {
    test('uses a named CSV attachment with native sharing', () async {
      ShareParams? captured;
      final nativeGateway = SharePlusPlaylistCsvShareGateway(
        nativeShare: (params) async => captured = params,
        saveFile: (_, _) async => fail('Unexpected save dialog'),
        isLinux: () => false,
      );
      final file = XFile(
        p.join(temporaryDirectory.path, 'Mi lista.csv'),
        name: 'Mi lista.csv',
        mimeType: 'text/csv',
      );
      await nativeGateway.share(
        file: file,
        title: 'Mi lista',
        subject: 'Lista',
      );
      expect(captured!.files, [file]);
      expect(captured!.fileNameOverrides, ['Mi lista.csv']);
      expect(captured!.title, 'Mi lista');
      expect(captured!.subject, 'Lista');
      expect(captured!.text, isNull);
      expect(captured!.sharePositionOrigin, const Rect.fromLTWH(0, 0, 1, 1));
    });

    test('uses the offline file save fallback on Linux', () async {
      XFile? captured;
      String? capturedTitle;
      final linuxGateway = SharePlusPlaylistCsvShareGateway(
        nativeShare: (_) async => fail('Unexpected native file share on Linux'),
        saveFile: (file, title) async {
          captured = file;
          capturedTitle = title;
        },
        isLinux: () => true,
      );
      final file = XFile(p.join(temporaryDirectory.path, 'Viaje.csv'));
      await linuxGateway.share(file: file, title: 'Guardar Viaje');
      expect(captured, same(file));
      expect(capturedTitle, 'Guardar Viaje');
    });

    test('propagates native and save fallback errors', () async {
      for (final isLinux in [false, true]) {
        final failingGateway = SharePlusPlaylistCsvShareGateway(
          nativeShare: (_) async => throw StateError('native failed'),
          saveFile: (_, _) async => throw StateError('save failed'),
          isLinux: () => isLinux,
        );
        await expectLater(
          failingGateway.share(
            file: XFile(p.join(temporaryDirectory.path, 'Viaje.csv')),
            title: 'Viaje',
          ),
          throwsStateError,
        );
      }
    });
  });
}

final _date = DateTime(2026, 10, 26);

CatalogPlaylist _playlist({
  String id = 'selected',
  String name = 'Viaje',
  List<String> trackIds = const [],
  List<PlaylistEntry> entries = const [],
}) => CatalogPlaylist(
  playlist: Playlist(
    id: id,
    name: name,
    trackIds: trackIds,
    createdAt: _date,
    updatedAt: _date,
  ),
  entries: entries,
);

PlaylistEntry _entry(
  String title, {
  String videoId = 'aaaaaaaaaaa',
  int position = 0,
  String playlistId = 'selected',
  String? localTrackId,
  CatalogTrack? track,
  bool deleted = false,
}) => PlaylistEntry(
  id: 'entry-$title',
  playlistId: playlistId,
  track: track ?? CatalogTrack.youtube(videoId: videoId, title: title),
  position: position,
  localTrackId: localTrackId,
  createdAt: _date,
  updatedAt: _date,
  deletedAt: deleted ? _date : null,
);

LocalTrack _local(String id, {required String title}) => LocalTrack(
  id: id,
  title: title,
  artist: 'Artist',
  filePath: r'D:\private\music.flac',
  thumbnailPath: r'D:\private\cover.jpg',
  thumbnailUrl: 'file:///private/cover.jpg',
  sourceUrl: 'https://user:secret@example.com/music?token=secret',
  addedAt: _date,
);

final class _RecordingGateway implements PlaylistCsvShareGateway {
  Object? error;
  final files = <XFile>[];
  String? title;
  String? subject;
  Rect? sharePositionOrigin;

  @override
  Future<void> share({
    required XFile file,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    files.add(file);
    this.title = title;
    this.subject = subject;
    this.sharePositionOrigin = sharePositionOrigin;
    expect(await File(file.path).exists(), isTrue);
    if (error case final error?) throw error;
  }
}
