import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/storage/library_operation_coordinator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LocalTrackDownloadHelper deduplication', () {
    test('always reuses an existing valid library file', () async {
      final fixture = await _DownloadFixture.create();
      addTearDown(fixture.dispose);
      final existing = await fixture.addExisting(
        sourceUrl: 'https://catalog.example/tracks/42',
      );
      var downloadStarted = false;

      final result = await fixture.helper.resolveForLibrary(
        _remoteTrack(url: 'https://catalog.example/tracks/42'),
        onDownloadStarted: () => downloadStarted = true,
      );

      expect(result.reusedExisting, isTrue);
      expect(result.track.id, existing.id);
      expect(result.track.filePath, existing.filePath);
      expect(fixture.musicRepository.downloadCalls, 0);
      expect(fixture.libraryRepository.localTracks, hasLength(1));
      expect(downloadStarted, isFalse);
    });

    test(
      'does not merge different strong URLs solely by title and artist',
      () async {
        final fixture = await _DownloadFixture.create();
        addTearDown(fixture.dispose);
        final existing = await fixture.addExisting(
          sourceUrl: 'https://catalog-a.example/tracks/42',
        );

        final result = await fixture.helper.resolveForLibrary(
          _remoteTrack(url: 'https://catalog-b.example/tracks/42'),
        );

        expect(result.reusedExisting, isFalse);
        expect(fixture.musicRepository.downloadCalls, 1);
        expect(fixture.libraryRepository.localTracks, hasLength(2));
        expect(result.track.filePath, isNot(existing.filePath));
      },
    );

    test('treats equivalent YouTube URL forms as one source', () async {
      final fixture = await _DownloadFixture.create();
      addTearDown(fixture.dispose);
      final existing = await fixture.addExisting(
        sourceUrl: 'https://youtu.be/dQw4w9WgXcQ?t=9',
      );

      final result = await fixture.helper.resolveForLibrary(
        _remoteTrack(
          id: 'dQw4w9WgXcQ',
          url: 'https://www.youtube.com/live/dQw4w9WgXcQ?feature=share',
        ),
      );

      expect(result.reusedExisting, isTrue);
      expect(result.track.id, existing.id);
      expect(result.track.filePath, existing.filePath);
      expect(fixture.musicRepository.downloadCalls, 0);
    });

    for (final invalidFile in ['missing', 'zero bytes']) {
      test('redownloads when the matching file is $invalidFile', () async {
        final fixture = await _DownloadFixture.create();
        addTearDown(fixture.dispose);
        final existing = await fixture.addExisting(
          sourceUrl: 'https://catalog.example/tracks/42',
          createFile: invalidFile != 'missing',
          contents: const [],
        );

        final result = await fixture.helper.resolveForLibrary(
          _remoteTrack(url: 'https://catalog.example/tracks/42'),
        );

        expect(result.reusedExisting, isFalse);
        expect(result.track.id, existing.id);
        expect(fixture.musicRepository.downloadCalls, 1);
        expect(await File(result.track.filePath).length(), greaterThan(0));
      });
    }

    test(
      'coalesces concurrent requests for the same source identity',
      () async {
        final releaseDownload = Completer<void>();
        final fixture = await _DownloadFixture.create(
          downloadGate: releaseDownload.future,
        );
        addTearDown(fixture.dispose);
        final firstTrack = _remoteTrack(
          id: 'dQw4w9WgXcQ',
          url: 'https://youtu.be/dQw4w9WgXcQ',
          thumbnailUrl: 'file:///missing-artwork.jpg',
        );
        final equivalentTrack = _remoteTrack(
          id: 'dQw4w9WgXcQ',
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          thumbnailUrl: 'file:///missing-artwork.jpg',
        );

        final first = fixture.helper.resolveForLibrary(firstTrack);
        final second = fixture.helper.resolveForLibrary(equivalentTrack);
        await fixture.musicRepository.firstDownloadStarted.future;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final callsBeforeCompletion = fixture.musicRepository.downloadCalls;
        releaseDownload.complete();
        final results = await Future.wait([first, second]);

        expect(callsBeforeCompletion, 1);
        expect(fixture.musicRepository.downloadCalls, 1);
        expect(results[0].track.id, results[1].track.id);
        expect(fixture.libraryRepository.localTracks, hasLength(1));
      },
    );

    test(
      'keeps coalesced and serialized resolutions gated before maintenance',
      () async {
        final releaseDownload = Completer<void>();
        final fixture = await _DownloadFixture.create(
          downloadGate: releaseDownload.future,
        );
        addTearDown(fixture.dispose);
        final firstTrack = _remoteTrack(
          id: 'dQw4w9WgXcQ',
          url: 'https://youtu.be/dQw4w9WgXcQ',
          thumbnailUrl: 'file:///missing-first-artwork.jpg',
        );
        final equivalentTrack = _remoteTrack(
          id: 'dQw4w9WgXcQ',
          url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          thumbnailUrl: 'file:///missing-equivalent-artwork.jpg',
        );
        final serializedTrack = _remoteTrack(
          id: 'another-video-id',
          url: 'https://catalog.example/tracks/serialized',
          thumbnailUrl: 'file:///missing-serialized-artwork.jpg',
        );

        final first = fixture.helper.resolveForLibrary(firstTrack);
        final coalesced = fixture.helper.resolveForLibrary(equivalentTrack);
        final serialized = fixture.helper.resolveForLibrary(serializedTrack);
        await fixture.musicRepository.firstDownloadStarted.future;

        var maintenanceRan = false;
        final maintenance = fixture.container
            .read(libraryOperationCoordinatorProvider)
            .runExclusive(
              LibraryMaintenancePhase.migratingDirectory,
              () async => maintenanceRan = true,
            );
        await Future<void>.delayed(Duration.zero);
        expect(maintenanceRan, isFalse);

        releaseDownload.complete();
        final results = await Future.wait([
          first,
          coalesced,
          serialized,
        ]).timeout(const Duration(seconds: 3));
        await maintenance.timeout(const Duration(seconds: 3));

        expect(maintenanceRan, isTrue);
        expect(fixture.musicRepository.downloadCalls, 2);
        expect(results[0].track.id, results[1].track.id);
        expect(results[2].track.id, isNot(results[0].track.id));
      },
    );

    test(
      'rejects an unrelated fallback file returned by the backend',
      () async {
        final fixture = await _DownloadFixture.create(
          returnUnrelatedFile: true,
        );
        addTearDown(fixture.dispose);

        await expectLater(
          fixture.helper.resolveForLibrary(
            _remoteTrack(url: 'https://catalog.example/tracks/42'),
          ),
          throwsA(anything),
        );

        expect(fixture.libraryRepository.localTracks, isEmpty);
      },
    );

    test(
      'persists complete InnerTube metadata without an info lookup',
      () async {
        final fixture = await _DownloadFixture.create();
        addTearDown(fixture.dispose);
        const track = TrackInfo(
          id: 'music-song-id',
          title: 'Canonical song',
          artist: 'Artist One, Artist Two',
          artists: ['Artist One', 'Artist Two'],
          album: 'Canonical album',
          url: 'https://catalog.example/tracks/inner-tube-song',
          thumbnailUrl: 'file:///missing-primary-artwork.jpg',
          catalogThumbnailUrl: 'file:///missing-catalog-artwork.jpg',
          duration: Duration(minutes: 4, seconds: 12),
          metadataSource: TrackMetadataSource.youtubeMusic,
        );

        final result = await fixture.helper.resolveForLibrary(track);

        expect(fixture.musicRepository.infoCalls, 0);
        expect(result.track.album, track.album);
        expect(result.track.artists, track.artists);
        expect(result.track.metadataSource, TrackMetadataSource.youtubeMusic);
        expect(result.track.sourceId, track.id);
        expect(result.track.thumbnailUrl, track.thumbnailUrl);
        expect(result.track.catalogThumbnailUrl, track.catalogThumbnailUrl);
      },
    );

    test('stores the catalog thumbnail when primary artwork fails', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requestedPaths = <String>[];
      server.listen((request) async {
        requestedPaths.add(request.uri.path);
        if (request.uri.path == '/catalog.jpg') {
          request.response.headers.contentType = ContentType('image', 'jpeg');
          request.response.add(const [0xFF, 0xD8, 0xFF, 0xD9]);
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
      final origin = 'http://${server.address.address}:${server.port}';
      final fixture = await _DownloadFixture.create();
      addTearDown(fixture.dispose);
      final track = TrackInfo(
        id: 'catalog-art-id',
        title: 'Artwork fallback song',
        artist: 'Catalog artist',
        artists: const ['Catalog artist'],
        album: 'Catalog album',
        url: 'https://catalog.example/tracks/artwork-fallback',
        thumbnailUrl: '$origin/primary.jpg',
        catalogThumbnailUrl: '$origin/catalog.jpg',
        duration: const Duration(minutes: 3),
        metadataSource: TrackMetadataSource.youtubeMusic,
      );

      final result = await HttpOverrides.runWithHttpOverrides(
        () => fixture.helper.resolveForLibrary(track),
        _RealHttpOverrides(),
      );

      expect(requestedPaths, ['/primary.jpg', '/catalog.jpg']);
      expect(result.track.thumbnailUrl, '$origin/catalog.jpg');
      expect(result.track.catalogThumbnailUrl, '$origin/catalog.jpg');
      expect(result.track.thumbnailPath, isNotNull);
      expect(await File(result.track.thumbnailPath!).length(), greaterThan(0));
      expect(
        await Directory(
          p.dirname(result.track.thumbnailPath!),
        ).list().where((entity) => entity.path.endsWith('.part')).isEmpty,
        isTrue,
      );
    });

    test(
      'rolls back newly downloaded audio and artwork when persistence fails',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.headers.contentType = ContentType('image', 'jpeg');
          request.response.add(const [0xFF, 0xD8, 0xFF, 0xD9]);
          await request.response.close();
        });
        final fixture = await _DownloadFixture.create(
          failSavingLocalTrack: true,
        );
        addTearDown(fixture.dispose);
        final artwork =
            'http://${server.address.address}:${server.port}/artwork.jpg';
        final track = TrackInfo(
          id: 'rollback-song-id',
          title: 'Rollback song',
          artist: 'Rollback artist',
          artists: const ['Rollback artist'],
          album: 'Rollback album',
          url: 'https://catalog.example/tracks/rollback-song',
          thumbnailUrl: artwork,
          duration: const Duration(minutes: 3),
          metadataSource: TrackMetadataSource.youtubeMusic,
        );

        await expectLater(
          HttpOverrides.runWithHttpOverrides(
            () => fixture.helper.resolveForLibrary(track),
            _RealHttpOverrides(),
          ),
          throwsA(isA<StateError>()),
        );

        final artifacts = await fixture.tempDirectory
            .list(recursive: true)
            .where((entity) => entity is File)
            .cast<File>()
            .toList();
        expect(artifacts, isEmpty);
        expect(fixture.libraryRepository.localTracks, isEmpty);
        expect(fixture.musicRepository.downloadCalls, 1);
      },
    );

    test('fills missing InnerTube fields from yt-dlp metadata only', () async {
      const url = 'https://catalog.example/tracks/incomplete-song';
      final fixture = await _DownloadFixture.create(
        resolvedInfo: const TrackInfo(
          id: 'resolved-video-id',
          title: 'Decorated video title (Official Video)',
          artist: 'Resolved Artist',
          artists: ['Resolved Artist'],
          album: 'Resolved album',
          url: url,
          thumbnailUrl: 'file:///resolved-artwork.jpg',
          duration: Duration(minutes: 3, seconds: 44),
        ),
      );
      addTearDown(fixture.dispose);
      const track = TrackInfo(
        id: 'catalog-song-id',
        title: 'Canonical title',
        artist: 'Desconocido',
        url: url,
        catalogThumbnailUrl: 'file:///catalog-artwork.jpg',
        metadataSource: TrackMetadataSource.youtubeMusic,
      );

      final result = await fixture.helper.resolveForLibrary(track);

      expect(fixture.musicRepository.infoCalls, 1);
      expect(result.track.title, 'Canonical title');
      expect(result.track.artist, 'Resolved Artist');
      expect(result.track.artists, const ['Resolved Artist']);
      expect(result.track.album, 'Resolved album');
      expect(result.track.duration, const Duration(minutes: 3, seconds: 44));
      expect(result.track.thumbnailUrl, 'file:///resolved-artwork.jpg');
      expect(result.track.catalogThumbnailUrl, track.catalogThumbnailUrl);
      expect(result.track.metadataSource, TrackMetadataSource.youtubeMusic);
      expect(result.track.sourceId, track.id);
    });

    test(
      'enriches a reused legacy row without downloading audio again',
      () async {
        final fixture = await _DownloadFixture.create();
        addTearDown(fixture.dispose);
        final existing = await fixture.addExisting(
          sourceUrl: 'https://catalog.example/tracks/42',
        );
        const canonical = TrackInfo(
          id: 'catalog-track-42',
          title: 'Canonical title',
          artist: 'First Artist, Guest Artist',
          artists: ['First Artist', 'Guest Artist'],
          album: 'Canonical album',
          url: 'https://catalog.example/tracks/42',
          thumbnailUrl: 'file:///missing-primary-artwork.jpg',
          catalogThumbnailUrl: 'file:///missing-catalog-artwork.jpg',
          duration: Duration(minutes: 3),
          metadataSource: TrackMetadataSource.youtubeMusic,
        );

        final result = await fixture.helper.resolveForLibrary(canonical);

        expect(result.reusedExisting, isTrue);
        expect(result.track.id, existing.id);
        expect(result.track.filePath, existing.filePath);
        expect(result.track.title, canonical.title);
        expect(result.track.artist, canonical.artist);
        expect(result.track.album, canonical.album);
        expect(result.track.artists, canonical.artists);
        expect(result.track.metadataSource, TrackMetadataSource.youtubeMusic);
        expect(result.track.sourceId, canonical.id);
        expect(fixture.musicRepository.downloadCalls, 0);
        expect(
          fixture.libraryRepository.localTracks.single,
          same(result.track),
        );
      },
    );
  });

  group('DownloadController deduplication', () {
    test('direct download reuses an existing library track', () async {
      final fixture = await _DownloadFixture.create();
      addTearDown(fixture.dispose);
      final existing = await fixture.addExisting(
        sourceUrl: 'https://catalog.example/tracks/42',
      );
      final track = _remoteTrack(url: 'https://catalog.example/tracks/42');

      await fixture.container
          .read(downloadControllerProvider.notifier)
          .downloadAudio(track);
      await _waitUntil(
        () =>
            fixture.container
                .read(downloadControllerProvider)[track.url]
                ?.status ==
            DownloadProgressStatus.completed,
      );

      final task = fixture.container.read(
        downloadControllerProvider,
      )[track.url]!;
      expect(task.reusedExisting, isTrue);
      expect(task.localTrack?.id, existing.id);
      expect(task.localTrack?.filePath, existing.filePath);
      expect(fixture.musicRepository.downloadCalls, 0);
    });

    test('direct library download reuses Biblioteca', () async {
      final fixture = await _DownloadFixture.create();
      addTearDown(fixture.dispose);
      final existing = await fixture.addExisting(
        sourceUrl: 'https://catalog.example/tracks/42',
      );

      final result = await fixture.container
          .read(downloadControllerProvider.notifier)
          .downloadAudioForLibrary(
            _remoteTrack(url: 'https://catalog.example/tracks/42'),
          );

      expect(result.id, existing.id);
      expect(result.filePath, existing.filePath);
      expect(fixture.musicRepository.downloadCalls, 0);
      expect(fixture.container.read(downloadControllerProvider), isEmpty);
    });

    test(
      'progress from a foreign task id cannot mutate the active task',
      () async {
        final releaseDownload = Completer<void>();
        final fixture = await _DownloadFixture.create(
          downloadGate: releaseDownload.future,
        );
        addTearDown(fixture.dispose);
        final track = _remoteTrack(url: 'https://catalog.example/tracks/42');
        final controller = fixture.container.read(
          downloadControllerProvider.notifier,
        );

        await controller.downloadAudio(track);
        await fixture.musicRepository.firstDownloadStarted.future;
        final task = fixture.container.read(
          downloadControllerProvider,
        )[track.url]!;

        fixture.progressService.emit(
          DownloadProgress(
            taskId: 'another-download-task',
            url: track.url,
            status: DownloadProgressStatus.running,
            progress: 0.73,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        var current = fixture.container.read(
          downloadControllerProvider,
        )[track.url]!;
        expect(current.taskId, task.taskId);
        expect(current.progress, isNull);

        fixture.progressService.emit(
          DownloadProgress(
            taskId: task.taskId,
            url: 'https://redirected.example/audio',
            status: DownloadProgressStatus.running,
            progress: 0.41,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        current = fixture.container.read(
          downloadControllerProvider,
        )[track.url]!;
        expect(current.progress, 0.41);

        releaseDownload.complete();
        await _waitUntil(
          () =>
              fixture.container
                  .read(downloadControllerProvider)[track.url]
                  ?.status ==
              DownloadProgressStatus.completed,
        );
      },
    );

    test(
      'yt-dlp fallback clears the primary error and restarts progress',
      () async {
        final releaseDownload = Completer<void>();
        final fixture = await _DownloadFixture.create(
          downloadGate: releaseDownload.future,
        );
        addTearDown(fixture.dispose);
        final track = _remoteTrack(url: 'https://catalog.example/tracks/42');
        await fixture.container
            .read(downloadControllerProvider.notifier)
            .downloadAudio(track);
        await fixture.musicRepository.firstDownloadStarted.future;
        final task = fixture.container.read(
          downloadControllerProvider,
        )[track.url]!;

        fixture.progressService.emit(
          DownloadProgress(
            taskId: task.taskId,
            url: track.url,
            status: DownloadProgressStatus.running,
            progress: 0.64,
          ),
        );
        fixture.progressService.emit(
          DownloadProgress(
            taskId: task.taskId,
            url: track.url,
            status: DownloadProgressStatus.failed,
            progress: 0.64,
            message: 'youtube_explode_dart fallo; usando yt-dlp',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          fixture.container
              .read(downloadControllerProvider)[track.url]
              ?.errorMessage,
          contains('youtube_explode_dart'),
        );

        fixture.progressService.emit(
          DownloadProgress(
            taskId: task.taskId,
            url: track.url,
            status: DownloadProgressStatus.queued,
            progress: 0,
            message: 'Preparando yt-dlp',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        final fallback = fixture.container.read(
          downloadControllerProvider,
        )[track.url]!;
        expect(fallback.status, DownloadProgressStatus.queued);
        expect(fallback.progress, 0);
        expect(fallback.errorMessage, isNull);

        releaseDownload.complete();
        await _waitUntil(
          () =>
              fixture.container
                  .read(downloadControllerProvider)[track.url]
                  ?.status ==
              DownloadProgressStatus.completed,
        );
      },
    );
  });
}

TrackInfo _remoteTrack({
  String id = 'remote-42',
  required String url,
  String thumbnailUrl = '',
}) {
  return TrackInfo(
    id: id,
    title: 'La misma canción',
    artist: 'El mismo artista',
    url: url,
    thumbnailUrl: thumbnailUrl,
    duration: const Duration(minutes: 3),
  );
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the expected download state.');
}

class _DownloadFixture {
  _DownloadFixture._({
    required this.tempDirectory,
    required this.libraryRepository,
    required this.musicRepository,
    required this.progressService,
    required this.container,
  });

  final Directory tempDirectory;
  final _MemoryLibraryRepository libraryRepository;
  final _RecordingMusicRepository musicRepository;
  final _ProgressOnlyDownloaderService progressService;
  final ProviderContainer container;

  LocalTrackDownloadHelper get helper =>
      container.read(localTrackDownloadHelperProvider);

  static Future<_DownloadFixture> create({
    Future<void>? downloadGate,
    bool returnUnrelatedFile = false,
    TrackInfo? resolvedInfo,
    bool failSavingLocalTrack = false,
  }) async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'bstream-download-dedupe-',
    );
    final libraryRepository = _MemoryLibraryRepository(
      failSavingLocalTrack: failSavingLocalTrack,
    );
    final musicRepository = _RecordingMusicRepository(
      downloadGate: downloadGate,
      returnUnrelatedFile: returnUnrelatedFile,
      resolvedInfo: resolvedInfo,
    );
    final progressService = _ProgressOnlyDownloaderService();
    final settingsController = _FixedSettingsController(tempDirectory.path);
    final container = ProviderContainer(
      overrides: [
        libraryRepositoryProvider.overrideWithValue(libraryRepository),
        musicRepositoryProvider.overrideWithValue(musicRepository),
        downloaderServiceProvider.overrideWithValue(progressService),
        settingsControllerProvider.overrideWith(() => settingsController),
      ],
    );
    return _DownloadFixture._(
      tempDirectory: tempDirectory,
      libraryRepository: libraryRepository,
      musicRepository: musicRepository,
      progressService: progressService,
      container: container,
    );
  }

  Future<LocalTrack> addExisting({
    required String sourceUrl,
    bool createFile = true,
    List<int> contents = const [1, 2, 3],
  }) async {
    final file = File(
      p.join(
        tempDirectory.path,
        'existing-${libraryRepository.localTracks.length}.m4a',
      ),
    );
    if (createFile) {
      await file.writeAsBytes(contents, flush: true);
    }
    final track = LocalTrack(
      id: 'existing-${libraryRepository.localTracks.length}',
      title: 'La misma canción',
      artist: 'El mismo artista',
      filePath: file.path,
      addedAt: DateTime(2025),
      sourceUrl: sourceUrl,
      duration: const Duration(minutes: 3),
    );
    libraryRepository.localTracks.add(track);
    return track;
  }

  Future<void> dispose() async {
    container.dispose();
    await progressService.close();
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  }
}

class _FixedSettingsController extends SettingsController {
  _FixedSettingsController(this.downloadDirectory);

  final String downloadDirectory;

  @override
  Future<SettingsState> build() async => SettingsState(
    downloadDirectory: downloadDirectory,
    language: AppLanguage.spanish,
  );
}

class _RecordingMusicRepository implements MusicRepository {
  _RecordingMusicRepository({
    this.downloadGate,
    this.returnUnrelatedFile = false,
    this.resolvedInfo,
  });

  final Future<void>? downloadGate;
  final bool returnUnrelatedFile;
  final TrackInfo? resolvedInfo;
  final firstDownloadStarted = Completer<void>();
  int downloadCalls = 0;
  int infoCalls = 0;

  @override
  Future<DownloadResult> downloadAudio(
    String url,
    DownloadOptions options,
  ) async {
    downloadCalls++;
    if (!firstDownloadStarted.isCompleted) {
      firstDownloadStarted.complete();
    }
    if (downloadGate != null) {
      await downloadGate;
    }
    final id = 'download-$downloadCalls';
    final fileName = returnUnrelatedFile
        ? 'unrelated-existing-audio.m4a'
        : '${options.fileName ?? id}.m4a';
    final file = File(p.join(options.outputDirectory, fileName));
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3, downloadCalls], flush: true);
    return DownloadResult(
      id: id,
      sourceUrl: url,
      filePath: file.path,
      fileName: fileName,
      mediaType: DownloadMediaType.audio,
      completedAt: DateTime(2026),
    );
  }

  @override
  Future<TrackInfo> getInfo(String url) async {
    infoCalls++;
    return resolvedInfo ??
        TrackInfo(
          id: 'resolved-id',
          title: 'La misma canción',
          artist: 'El mismo artista',
          artists: const ['El mismo artista'],
          album: 'Album resuelto',
          url: url,
          duration: const Duration(minutes: 3),
        );
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) async {
    return await getInfo(url);
  }

  @override
  Future<List<TrackInfo>> search(String query) => throw UnimplementedError();
}

class _ProgressOnlyDownloaderService implements DownloaderService {
  final _controller = StreamController<DownloadProgress>.broadcast();

  @override
  Stream<DownloadProgress> get progressStream => _controller.stream;

  void emit(DownloadProgress progress) => _controller.add(progress);

  Future<void> close() => _controller.close();

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) =>
      throw UnimplementedError();

  @override
  Future<TrackInfo> getInfo(String url) => throw UnimplementedError();

  @override
  Future<TrackInfo> getPlaybackInfo(String url) => throw UnimplementedError();

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TrackInfo>> search(String query) => throw UnimplementedError();
}

class _RealHttpOverrides extends HttpOverrides {}

class _MemoryLibraryRepository implements LibraryRepository {
  _MemoryLibraryRepository({this.failSavingLocalTrack = false});

  final bool failSavingLocalTrack;
  final List<LocalTrack> localTracks = [];

  @override
  Future<List<LocalTrack>> getLocalTracks() async => List.of(localTracks);

  @override
  Future<void> saveLocalTrack(LocalTrack track) async {
    if (failSavingLocalTrack) {
      throw StateError('simulated database write failure');
    }
    localTracks.removeWhere((existing) => existing.id == track.id);
    localTracks.add(track);
  }

  @override
  Future<void> deleteLocalTrack(String trackId) async {
    localTracks.removeWhere((track) => track.id == trackId);
  }

  @override
  Future<Set<String>> purgeMissingLocalTracks(List<LocalTrack> tracks) async =>
      const {};

  @override
  Future<void> markPlayed(
    String trackId,
    DateTime playedAt, {
    String? playlistId,
  }) async {}

  @override
  Future<List<LocalTrack>> getHistory() async => const [];

  @override
  Future<List<Playlist>> getPlaylists() async => const [];

  @override
  Future<void> savePlaylist(Playlist playlist) async {}

  @override
  Future<void> deletePlaylist(String playlistId) async {}
}
