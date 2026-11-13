import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/subscribed_artists_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/library_panel.dart';
import 'package:bstream_music/services/downloader/download_audio_metadata_service.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/storage/library_operation_coordinator.dart';
import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'refreshes local data without resolving or saving library metadata',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final first = await fixture.track('written');
      final unchanged = await fixture.track('unchanged');
      final unsupported = await fixture.track('unsupported');
      final failed = await fixture.track('failed');
      fixture.repository.tracks.addAll([first, unchanged, unsupported, failed]);
      fixture.writer.onEmbed = (call) async {
        return switch (p.basenameWithoutExtension(call.filePath)) {
          'written' => AudioMetadataWriteResult.written,
          'unchanged' => AudioMetadataWriteResult.unchanged,
          'unsupported' => AudioMetadataWriteResult.unsupported,
          _ => throw const FileSystemException(
            'Simulated metadata write failure',
          ),
        };
      };

      final summary = await fixture.controller.refresh();

      expect(summary.updated, 1);
      expect(summary.skipped, 2);
      expect(summary.failed, 1);
      expect(fixture.repository.reads, 1);
      expect(fixture.repository.writes, 0);
      expect(fixture.writer.calls, hasLength(4));
      final call = fixture.writer.calls.first;
      expect(call.title, first.title);
      expect(call.artist, first.artist);
      expect(call.album, first.album);
      expect(call.artworkPath, first.thumbnailPath);
      final state = fixture.container.read(
        downloadMetadataRefreshControllerProvider,
      );
      expect(state.running, isFalse);
      expect(state.processed, 4);
      expect(state.total, 4);
    },
  );

  test('never rewrites external, missing, or outside-root files', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final external = (await fixture.track(
      'external',
    )).copyWith(isExternal: true);
    final outside = (await fixture.track(
      'outside',
    )).copyWith(filePath: p.join(fixture.directory.path, 'outside.m4a'));
    await File(outside.filePath).writeAsBytes([1, 2, 3]);
    final missing = await fixture.track('missing');
    await File(missing.filePath).delete();
    fixture.repository.tracks.addAll([external, outside, missing]);

    final summary = await fixture.controller.refresh();

    expect(summary.skipped, 3);
    expect(summary.updated, 0);
    expect(summary.failed, 0);
    expect(fixture.writer.calls, isEmpty);
    expect(await File(outside.filePath).readAsBytes(), [1, 2, 3]);
  });

  for (final match in [
    'presented paused',
    'native paused',
    'source URL',
    'file URI',
    'source ID',
  ]) {
    test('skips the opened file when matched by $match', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final track = await fixture.track('opened');
      fixture.repository.tracks.add(track);
      final snapshot = PlayerSnapshot(
        status: PlayerStatus.paused,
        trackId: match == 'source ID'
            ? track.sourceId
            : match == 'source URL' || match == 'file URI'
            ? null
            : track.id,
        sourceUrl: match == 'source URL'
            ? track.sourceUrl
            : match == 'file URI'
            ? File(track.filePath).uri.toString()
            : null,
      );
      if (match == 'presented paused') {
        fixture.player.publish(snapshot);
      } else {
        fixture.nativePlayer.snapshot = snapshot;
      }

      final summary = await fixture.controller.refresh();

      expect(summary.skipped, 1);
      expect(fixture.writer.calls, isEmpty);
    });
  }

  test(
    'coalesces repeated actions and processes each file sequentially',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      fixture.repository.tracks.addAll([
        await fixture.track('first'),
        await fixture.track('second'),
      ]);
      final started = Completer<void>();
      final release = Completer<void>();
      final seen = <String>{};
      var active = 0;
      var maximumActive = 0;
      fixture.writer.onEmbed = (call) async {
        active++;
        if (active > maximumActive) maximumActive = active;
        if (!started.isCompleted) {
          started.complete();
          await release.future;
        }
        active--;
        return seen.add(call.filePath)
            ? AudioMetadataWriteResult.written
            : AudioMetadataWriteResult.unchanged;
      };
      final first = fixture.controller.refresh();
      await started.future;
      final second = fixture.controller.refresh();
      expect(identical(first, second), isTrue);
      expect(fixture.writer.calls, hasLength(1));
      expect(
        fixture.container
            .read(downloadMetadataRefreshControllerProvider)
            .running,
        isTrue,
      );
      release.complete();
      expect((await first).updated, 2);
      expect((await second).updated, 2);
      expect(maximumActive, 1);
      final again = await fixture.controller.refresh();
      expect(again.updated, 0);
      expect(again.skipped, 2);
      expect(fixture.repository.reads, 1);
      expect(fixture.repository.writes, 0);
    },
  );

  test(
    'revalidates cached track paths and settings after a gated migration',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final first = await fixture.track('first');
      final second = await fixture.track('second');
      fixture.repository.tracks.addAll([first, second]);
      final firstStarted = Completer<void>();
      final finishFirst = Completer<void>();
      fixture.writer.onEmbed = (call) async {
        if (call.filePath == first.filePath) {
          firstStarted.complete();
          await finishFirst.future;
        }
        return AudioMetadataWriteResult.written;
      };
      final refresh = fixture.controller.refresh();
      await firstStarted.future;
      final migratedRoot = Directory(
        p.join(fixture.directory.path, 'migrated'),
      );
      final migratedFile = File(
        p.join(migratedRoot.path, 'audio', 'second.m4a'),
      );
      final migration = fixture.coordinator.runExclusive(
        LibraryMaintenancePhase.migratingDirectory,
        () async {
          await migratedFile.parent.create(recursive: true);
          await File(second.filePath).copy(migratedFile.path);
          fixture.repository.tracks[1] = second.copyWith(
            filePath: migratedFile.path,
          );
          fixture.settings.changeRoot(migratedRoot.path);
          fixture.container.invalidate(libraryTracksProvider);
        },
      );
      finishFirst.complete();
      await migration;
      final summary = await refresh;

      expect(summary.updated, 2);
      expect(fixture.writer.calls.last.filePath, migratedFile.path);
      expect(fixture.repository.reads, 2);
      expect(fixture.repository.writes, 0);
    },
  );

  test('metadata maintenance labels and counts cover every app language', () {
    const english = AppStrings(AppLanguage.english);
    for (final language in AppLanguage.values) {
      final strings = AppStrings(language);
      final labels = [
        strings.refreshDownloadedMetadata,
        strings.downloadedMetadataProgress(7, 13),
        strings.downloadedMetadataSummary(7, 13, 5),
        strings.downloadedMetadataFailed,
      ];
      for (final label in labels) {
        expect(label.trim(), isNotEmpty, reason: language.code);
        expect(label, isNot(contains('ZXQPH')), reason: language.code);
        expect(label, isNot(contains('\uFFFD')), reason: language.code);
      }
      expect(labels[1], contains('7'));
      expect(labels[1], contains('13'));
      expect(labels[2], contains('7'));
      expect(labels[2], contains('13'));
      expect(labels[2], contains('5'));
      if (language != AppLanguage.english) {
        expect(labels[0], isNot(english.refreshDownloadedMetadata));
        expect(labels[2], isNot(english.downloadedMetadataSummary(7, 13, 5)));
      }
    }
  });

  testWidgets(
    'downloads menu starts explicit maintenance and shows its summary',
    (tester) async {
      final fixture = (await tester.runAsync(_Fixture.create))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.dispose();
        await tester.pump(Duration.zero);
      });
      fixture.repository.tracks.add(
        (await tester.runAsync(() => fixture.track('menu')))!,
      );
      final started = Completer<void>();
      final release = Completer<void>();
      fixture.writer.onEmbed = (_) async {
        started.complete();
        await release.future;
        return AudioMetadataWriteResult.written;
      };
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp(
            home: Scaffold(body: LibraryPanel(onOpenPlayer: () {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fixture.writer.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('library-downloads-entry')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('downloads-metadata-menu')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          const AppStrings(AppLanguage.spanish).refreshDownloadedMetadata,
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('downloads-refresh-metadata')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await _pumpUntil(tester, () => started.isCompleted);
      expect(
        fixture.container
            .read(downloadMetadataRefreshControllerProvider)
            .running,
        isTrue,
      );
      release.complete();
      await _pumpUntil(
        tester,
        () => !fixture.container
            .read(downloadMetadataRefreshControllerProvider)
            .running,
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          const AppStrings(
            AppLanguage.spanish,
          ).downloadedMetadataSummary(1, 0, 0),
        ),
        findsOneWidget,
      );
      expect(fixture.writer.calls, hasLength(1));
      expect(fixture.repository.writes, 0);
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail(
    'Timed out waiting for the metadata action to finish its local file work.',
  );
}

typedef _EmbedCall = ({
  String filePath,
  String title,
  String artist,
  String? album,
  String? artworkPath,
});

class _Fixture {
  _Fixture(
    this.directory,
    this.repository,
    this.writer,
    this.settings,
    this.player,
    this.nativePlayer,
    this.container,
  );

  final Directory directory;
  final _ReadOnlyRepository repository;
  final _Writer writer;
  final _Settings settings;
  final _Player player;
  final _NativePlayer nativePlayer;
  final ProviderContainer container;

  DownloadMetadataRefreshController get controller =>
      container.read(downloadMetadataRefreshControllerProvider.notifier);
  LibraryOperationCoordinator get coordinator =>
      container.read(libraryOperationCoordinatorProvider);

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'bstream-metadata-refresh-',
    );
    final repository = _ReadOnlyRepository();
    final writer = _Writer();
    final settings = _Settings(directory.path);
    final player = _Player();
    final nativePlayer = _NativePlayer();
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(repository),
        downloadAudioMetadataServiceProvider.overrideWithValue(writer),
        downloaderServiceProvider.overrideWithValue(_NoDownloads()),
        settingsControllerProvider.overrideWith(() => settings),
        playerControllerProvider.overrideWith(() => player),
        playerServiceProvider.overrideWithValue(nativePlayer),
        appStringsProvider.overrideWithValue(
          const AppStrings(AppLanguage.spanish),
        ),
        playlistsControllerProvider.overrideWith(_EmptyPlaylists.new),
        favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
        subscribedArtistsProvider.overrideWith(_EmptySubscribedArtists.new),
        catalogPlaylistsProvider.overrideWith(
          (ref) async => const <CatalogPlaylist>[],
        ),
        tiktokLiveControllerProvider.overrideWith(_IdleLive.new),
      ],
    );
    await container.read(settingsControllerProvider.future);
    await container.read(playerControllerProvider.future);
    return _Fixture(
      directory,
      repository,
      writer,
      settings,
      player,
      nativePlayer,
      container,
    );
  }

  Future<LocalTrack> track(String id) async {
    final file = File(p.join(directory.path, 'audio', '$id.m4a'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3, 4]);
    return LocalTrack(
      id: id,
      title: 'Title $id',
      artist: 'Artist',
      album: 'Album',
      filePath: file.path,
      thumbnailPath: p.join(directory.path, 'thumbnails', '$id.jpg'),
      sourceUrl: 'https://catalog.example/$id',
      sourceId: 'remote-$id',
      addedAt: DateTime.utc(2026),
    );
  }

  Future<void> dispose() async {
    container.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class _ReadOnlyRepository extends Fake implements LibraryRepository {
  final tracks = <LocalTrack>[];
  int reads = 0;
  int writes = 0;

  @override
  Future<List<LocalTrack>> getLocalTracks() async {
    reads++;
    return List.unmodifiable(tracks);
  }

  @override
  Future<void> saveLocalTrack(LocalTrack track) async {
    writes++;
    throw StateError('Metadata maintenance must not change the library row');
  }
}

class _Writer implements DownloadAudioMetadataService {
  final calls = <_EmbedCall>[];
  Future<AudioMetadataWriteResult> Function(_EmbedCall)? onEmbed;

  @override
  Future<AudioMetadataWriteResult> embed({
    required String filePath,
    required String title,
    required String artist,
    String? album,
    String? artworkPath,
  }) async {
    final call = (
      filePath: filePath,
      title: title,
      artist: artist,
      album: album,
      artworkPath: artworkPath,
    );
    calls.add(call);
    return await onEmbed?.call(call) ?? AudioMetadataWriteResult.written;
  }
}

class _Settings extends SettingsController {
  _Settings(this.root);
  String root;

  @override
  Future<SettingsState> build() async =>
      SettingsState(downloadDirectory: root, language: AppLanguage.spanish);

  void changeRoot(String next) {
    root = next;
    state = AsyncData(
      SettingsState(downloadDirectory: next, language: AppLanguage.spanish),
    );
  }
}

class _Player extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);

  void publish(PlayerSnapshot snapshot) => state = AsyncData(snapshot);
}

class _NativePlayer extends Fake implements PlayerService {
  PlayerSnapshot snapshot = const PlayerSnapshot(status: PlayerStatus.idle);

  @override
  PlayerSnapshot get currentSnapshot => snapshot;
}

class _NoDownloads extends Fake implements DownloaderService {
  @override
  Stream<DownloadProgress> get progressStream => const Stream.empty();
}

class _EmptyPlaylists extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => const [];
}

class _EmptySubscribedArtists extends SubscribedArtistsController {
  @override
  Future<List<RemoteSubscribedArtist>> build() async => const [];
}

class _IdleLive extends TikTokLiveController {
  @override
  Future<TikTokLiveState> build() async => const TikTokLiveState(
    creatorInput: '',
    status: TikTokLiveStatus.idle,
    message: '',
  );
}
