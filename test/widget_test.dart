import 'dart:async';
import 'dart:io' as io;

import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/library_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/track_result_tile.dart';
import 'package:bstream_music/main.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return switch (call.method) {
            'getApplicationDocumentsDirectory' => 'C:\\bstream_music_test',
            'getTemporaryDirectory' => 'C:\\bstream_music_test\\temp',
            'getApplicationSupportDirectory' =>
              'C:\\bstream_music_test\\support',
            'getApplicationCacheDirectory' => 'C:\\bstream_music_test\\cache',
            _ => null,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
    });
  });

  testWidgets('renders BStream Music shell', (tester) async {
    await tester.pumpWidget(_testApp());

    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Inicio'), findsWidgets);
    expect(find.byIcon(Icons.search_rounded), findsWidgets);
    expect(find.text('Reproductor'), findsNothing);
  });

  testWidgets('system back remembers only the last two visited tabs', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(_testApp());
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Buscar').last);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Ajustes').last);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Biblioteca'), findsWidgets);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Búsqueda'), findsWidgets);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Inicio'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('track result actions live under a three dot menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(_FakePlayerService()),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TrackResultTile(
              track: const TrackInfo(
                id: 'track-result',
                title: 'Resultado',
                artist: 'BStream Music',
                url: 'https://example.com/result',
              ),
              onOpenPlayer: () {},
            ),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Descargar'), findsOneWidget);
    expect(find.text('Anadir a playlist'), findsOneWidget);
  });

  test('downloadAudioForLibrary returns the saved local track', () async {
    final libraryRepository = _FakeLibraryRepository();
    final container = ProviderContainer(
      overrides: [
        downloaderServiceProvider.overrideWithValue(
          _FakeDownloaderService(
            emitCompletedBeforeResult: true,
            resultDelay: const Duration(milliseconds: 350),
          ),
        ),
        playerServiceProvider.overrideWithValue(_FakePlayerService()),
        libraryRepositoryProvider.overrideWithValue(libraryRepository),
      ],
    );
    addTearDown(container.dispose);

    final localTrack = await container
        .read(downloadControllerProvider.notifier)
        .downloadAudioForLibrary(
          const TrackInfo(
            id: 'remote-track',
            title: 'Cancion remota',
            artist: 'BStream Music',
            url: 'https://example.com/remote-track',
            thumbnailUrl: '',
            duration: Duration(minutes: 3),
          ),
        );

    expect(localTrack.id, 'downloaded-remote-track');
    expect(localTrack.title, 'Cancion remota');
    expect(libraryRepository.localTracks, hasLength(1));
    expect(libraryRepository.localTracks.single.id, localTrack.id);
  });

  testWidgets('highlights the active track in downloaded songs', (
    tester,
  ) async {
    final libraryRepository = _FakeLibraryRepository();
    final playerService = _FakePlayerService(
      snapshot: const PlayerSnapshot(
        status: PlayerStatus.playing,
        trackId: 'active-library-track',
        title: 'Cancion que esta sonando',
        artist: 'BStream Music',
      ),
    );
    libraryRepository.localTracks.add(
      LocalTrack(
        id: 'active-library-track',
        title: 'Cancion que esta sonando',
        artist: 'BStream Music',
        filePath: r'C:\Music\active.mp3',
        addedAt: DateTime(2026),
        duration: const Duration(minutes: 3, seconds: 24),
      ),
    );

    await tester.pumpWidget(
      _testApp(
        playerService: playerService,
        libraryRepository: libraryRepository,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Canciones descargadas'));
    await tester.pump(const Duration(milliseconds: 500));

    final indicator = find.byKey(
      const ValueKey('now-playing-active-library-track'),
    );
    final activeTile = find.ancestor(
      of: indicator,
      matching: find.byType(ListTile),
    );
    expect(indicator, findsOneWidget);
    expect(
      find.descendant(
        of: activeTile,
        matching: find.byIcon(Icons.pause_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: activeTile,
        matching: find.byIcon(Icons.pause_rounded),
      ),
    );
    await tester.pump();
    expect(playerService.pauseCalls, 1);
  });

  testWidgets('returning from player keeps the opened playlist', (
    tester,
  ) async {
    final libraryRepository = _FakeLibraryRepository();
    final navigationController = LibraryNavigationController();
    addTearDown(navigationController.dispose);
    final track = LocalTrack(
      id: 'playlist-route-track',
      title: 'Cancion de playlist',
      artist: 'BStream Music',
      filePath: r'C:\Music\playlist.mp3',
      addedAt: DateTime(2026),
    );
    libraryRepository.localTracks.add(track);
    libraryRepository.playlists.add(
      Playlist(
        id: 'persistent-playlist',
        name: 'Playlist persistente',
        trackIds: [track.id],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );

    Widget libraryView() {
      return ProviderScope(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(_FakePlayerService()),
          libraryRepositoryProvider.overrideWithValue(libraryRepository),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LibraryPanel(
              onOpenPlayer: () {},
              navigationController: navigationController,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(libraryView());
    await tester.pump(const Duration(milliseconds: 500));
    navigationController.openPlaylist('persistent-playlist');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Filtrar canciones'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    await tester.pumpWidget(libraryView());
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Filtrar canciones'), findsOneWidget);
    expect(find.text('Cancion de playlist'), findsOneWidget);
  });

  testWidgets('player controls fit on narrow mobile viewports', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = errors.add;
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      FlutterError.onError = previousOnError;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _testApp(
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion larga para probar controles',
            artist: 'BStream Music',
            trackId: 'test-track',
            duration: Duration(minutes: 4),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('En reproduccion'), findsOneWidget);
    expect(
      errors.where(
        (error) => error.exceptionAsString().contains('RenderFlex overflowed'),
      ),
      isEmpty,
    );
  });

  testWidgets('player menu toggles the current local track favorite', (
    tester,
  ) async {
    final repository = _FakeLibraryRepository();
    repository.localTracks.add(
      LocalTrack(
        id: 'favorite-player-track',
        title: 'Cancion favorita',
        artist: 'BStream Music',
        filePath: r'C:\Music\favorite-player-track.m4a',
        addedAt: DateTime(2026),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(
            _FakePlayerService(
              snapshot: const PlayerSnapshot(
                status: PlayerStatus.playing,
                title: 'Cancion favorita',
                artist: 'BStream Music',
                trackId: 'favorite-player-track',
                duration: Duration(minutes: 3),
              ),
            ),
          ),
          libraryRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(
          home: Scaffold(body: ExcludeSemantics(child: PlayerPanel())),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump(const Duration(milliseconds: 700));
    final addFavoriteLabel = find.text('Anadir a favoritos');
    expect(addFavoriteLabel, findsOneWidget);

    final menuButtonFinder = find.byType(PopupMenuButton<String>);
    final menuButton = tester.widget<PopupMenuButton<String>>(menuButtonFinder);
    Navigator.of(tester.element(menuButtonFinder)).pop();
    await tester.pump(const Duration(milliseconds: 300));
    menuButton.onSelected?.call('favorite');
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      repository.playlists.last.trackIds,
      contains('favorite-player-track'),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Quitar de favoritos'), findsOneWidget);
  });

  testWidgets(
    'windows desktop player stacks artwork and exposes volume control',
    (tester) async {
      final errors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = errors.add;
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        FlutterError.onError = previousOnError;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const title = 'Cancion de escritorio para probar layout';

      await tester.pumpWidget(
        _testApp(
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: title,
              artist: 'BStream Music',
              trackId: 'desktop-track',
              duration: Duration(minutes: 4, seconds: 11),
              volume: 0.72,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byType(MiniPlayer));
      await tester.pump(const Duration(milliseconds: 500));

      final artwork = find.byIcon(Icons.music_note_rounded);
      final titleText = find.text(title);

      expect(find.text('En reproduccion'), findsOneWidget);
      expect(artwork, findsOneWidget);
      expect(titleText, findsOneWidget);
      expect(
        tester.getBottomLeft(artwork).dy,
        lessThan(tester.getTopLeft(titleText).dy),
      );
      expect(find.byTooltip('Volumen'), findsOneWidget);
      expect(find.byTooltip('Cola de reproduccion'), findsOneWidget);

      await tester.tap(find.byTooltip('Cola de reproduccion'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No hay canciones en la cola actual.'), findsOneWidget);

      await tester.tap(find.byTooltip('Cola de reproduccion'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No hay canciones en la cola actual.'), findsNothing);

      await tester.tap(find.byTooltip('Volumen'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('72%'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(Slider), findsNothing);
      expect(
        errors.where(
          (error) => error.exceptionAsString().contains('debugNeedsLayout'),
        ),
        isEmpty,
      );
      expect(
        errors.where(
          (error) =>
              error.exceptionAsString().contains('RenderFlex overflowed'),
        ),
        isEmpty,
      );
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'desktop playback queue fits minimum window and changes selected song',
    (tester) async {
      final errors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = errors.add;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 600);
      addTearDown(() {
        FlutterError.onError = previousOnError;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final player = _FakePlayerService(
        snapshot: const PlayerSnapshot(
          status: PlayerStatus.playing,
          title: 'Primera cancion',
          artist: 'BStream Music',
          trackId: 'desktop-queue-1',
          duration: Duration(minutes: 3),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(player),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(playerControllerProvider.future);

      final tracks = [
        LocalTrack(
          id: 'desktop-queue-1',
          title: 'Primera cancion',
          artist: 'BStream Music',
          filePath: r'C:\Music\desktop-queue-1.m4a',
          addedAt: DateTime(2026),
        ),
        LocalTrack(
          id: 'desktop-queue-2',
          title: 'Segunda cancion',
          artist: 'BStream Music',
          filePath: r'C:\Music\desktop-queue-2.m4a',
          addedAt: DateTime(2026),
        ),
      ];
      await container
          .read(playerControllerProvider.notifier)
          .playLocal(tracks.first, queue: tracks, useNativeQueue: false);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: ExcludeSemantics(child: PlayerPanel())),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byTooltip('Cola de reproduccion'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Cola de Reproducción - 2 Canciones'), findsOneWidget);
      expect(find.text('Primera cancion'), findsWidgets);
      expect(find.text('Segunda cancion'), findsOneWidget);
      expect(
        tester.getRect(find.byTooltip('Pausar')).bottom,
        lessThanOrEqualTo(600),
      );
      expect(
        errors.where(
          (error) =>
              error.exceptionAsString().contains('RenderFlex overflowed'),
        ),
        isEmpty,
      );

      await tester.tap(find.text('Segunda cancion'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(player.playedLocalIds.last, 'desktop-queue-2');
      expect(container.read(playbackQueueProvider).currentIndex, 1);
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'player controls resize through intermediate widths without overflow',
    (tester) async {
      final errors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = errors.add;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(520, 720);
      addTearDown(() {
        FlutterError.onError = previousOnError;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        _testApp(
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: 'Cancion para redimensionar controles',
              artist: 'BStream Music',
              trackId: 'resize-track',
              duration: Duration(minutes: 3, seconds: 47),
              volume: 0.8,
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byType(MiniPlayer));
      await tester.pump(const Duration(milliseconds: 500));

      for (final width in const [500.0, 460.0, 430.0, 390.0, 520.0]) {
        tester.view.physicalSize = Size(width, 720);
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(
        errors.where(
          (error) =>
              error.exceptionAsString().contains('RenderFlex overflowed'),
        ),
        isEmpty,
      );
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets('cancelling create playlist dialog returns to library safely', (
    tester,
  ) async {
    await _pumpTestApp(tester);

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Crear playlist'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Nueva playlist'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Biblioteca'), findsWidgets);
    expect(find.text('Nueva playlist'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back closes create playlist dialog safely', (
    tester,
  ) async {
    await _pumpTestApp(tester);

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Crear playlist'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Nueva playlist'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Biblioteca'), findsWidgets);
    expect(find.text('Nueva playlist'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpTestApp(WidgetTester tester) {
  return tester.pumpWidget(_testApp());
}

Widget _testApp({
  PlayerService? playerService,
  LibraryRepository? libraryRepository,
}) {
  return ProviderScope(
    overrides: [
      downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
      playerServiceProvider.overrideWithValue(
        playerService ?? _FakePlayerService(),
      ),
      libraryRepositoryProvider.overrideWithValue(
        libraryRepository ?? _FakeLibraryRepository(),
      ),
    ],
    child: const BStreamMusicApp(),
  );
}

class _FakeDownloaderService implements DownloaderService {
  _FakeDownloaderService({
    this.emitCompletedBeforeResult = false,
    this.resultDelay = Duration.zero,
  });

  final bool emitCompletedBeforeResult;
  final Duration resultDelay;
  final _progressController = StreamController<DownloadProgress>.broadcast();

  @override
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  @override
  Future<DownloadResult> downloadAudio(
    String url,
    DownloadOptions options,
  ) async {
    if (emitCompletedBeforeResult) {
      _progressController.add(
        DownloadProgress(
          taskId: url,
          url: url,
          status: DownloadProgressStatus.completed,
          progress: 1,
        ),
      );
    }
    if (resultDelay > Duration.zero) {
      await Future<void>.delayed(resultDelay);
    }

    final id = url.split('/').last;
    final fileName = '${options.fileName ?? id}.${options.audioFormat}';
    final filePath = '${options.outputDirectory}\\$fileName';
    return DownloadResult(
      id: 'downloaded-$id',
      sourceUrl: url,
      filePath: filePath,
      fileName: fileName,
      mediaType: DownloadMediaType.audio,
      completedAt: DateTime(2026),
    );
  }

  @override
  Future<TrackInfo> getInfo(String url) {
    throw UnimplementedError();
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) {
    throw UnimplementedError();
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TrackInfo>> search(String query) async {
    return const [];
  }
}

class _FakePlayerService implements PlayerService {
  _FakePlayerService({
    this.snapshot = const PlayerSnapshot(status: PlayerStatus.idle),
  });

  final _snapshotController = StreamController<PlayerSnapshot>.broadcast();
  final PlayerSnapshot snapshot;
  int pauseCalls = 0;
  int resumeCalls = 0;
  final List<String> playedLocalIds = [];

  @override
  PlayerSnapshot get currentSnapshot => snapshot;

  @override
  Stream<PlayerSnapshot> get snapshotStream => _snapshotController.stream;

  @override
  Future<void> dispose() async {
    await _snapshotController.close();
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> playLocal(LocalTrack track) async {
    playedLocalIds.add(track.id);
  }

  @override
  Future<void> playLocalQueue(
    List<LocalTrack> tracks,
    int initialIndex,
  ) async {}

  @override
  Future<void> playRemote(track) async {}

  @override
  Future<void> resume() async {
    resumeCalls++;
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setShuffleEnabled(bool enabled) async {}

  @override
  Future<void> setRepeatMode(PlaybackRepeatMode mode) async {}

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> stop() async {}
}

class _FakeLibraryRepository implements LibraryRepository {
  final List<LocalTrack> localTracks = [];
  final List<Playlist> playlists = [];

  @override
  Future<void> deleteLocalTrack(String trackId) async {}

  @override
  Future<void> deletePlaylist(String playlistId) async {
    playlists.removeWhere((playlist) => playlist.id == playlistId);
  }

  @override
  Future<List<LocalTrack>> getHistory() async => const [];

  @override
  Future<List<LocalTrack>> getLocalTracks() async =>
      List.unmodifiable(localTracks);

  @override
  Future<List<Playlist>> getPlaylists() async => playlists;

  @override
  Future<void> markPlayed(String trackId, DateTime playedAt) async {}

  @override
  Future<void> saveLocalTrack(LocalTrack track) async {
    localTracks.removeWhere((localTrack) => localTrack.id == track.id);
    localTracks.add(track);
  }

  @override
  Future<void> savePlaylist(Playlist playlist) async {
    playlists.add(playlist);
  }
}
