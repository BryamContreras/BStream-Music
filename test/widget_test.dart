import 'dart:async';
import 'dart:io' as io;

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/artwork_progress_color_provider.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/library_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/download_progress_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/gradient_progress_bar.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/track_result_tile.dart';
import 'package:bstream_music/main.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/lyrics/lyrics_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
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

  testWidgets('popup menus match the active appearance surface', (
    tester,
  ) async {
    await tester.pumpWidget(_testApp());
    await tester.pump(const Duration(milliseconds: 400));

    final context = tester.element(find.byType(Scaffold).first);
    final popupTheme = Theme.of(context).popupMenuTheme;
    final colors = Theme.of(context).colorScheme;
    expect(
      popupTheme.color,
      colors.brightness == Brightness.dark
          ? AppColors.menuBackground
          : colors.surfaceContainerHighest.withValues(alpha: 0.97),
    );
    expect(popupTheme.surfaceTintColor, Colors.transparent);
    final shape = popupTheme.shape! as RoundedRectangleBorder;
    expect(
      shape.side.color,
      colors.brightness == Brightness.dark
          ? AppColors.menuBorder
          : colors.outlineVariant.withValues(alpha: 0.9),
    );
  });

  testWidgets(
    'desktop Downloads contains backup actions and auto-saves a picked folder',
    (tester) async {
      if (!io.Platform.isWindows &&
          !io.Platform.isLinux &&
          !io.Platform.isMacOS) {
        return;
      }
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final initialPath = io.Platform.isWindows
          ? r'C:\Music\Initial'
          : '/tmp/music/initial';
      final selectedPath = io.Platform.isWindows
          ? r'D:\Music\Selected'
          : '/tmp/music/selected';
      final settingsController = _FakeSettingsController(
        SettingsState(
          downloadDirectory: initialPath,
          language: AppLanguage.spanish,
        ),
      );
      var pickerCalls = 0;
      String? receivedTitle;
      String? receivedInitialDirectory;

      await tester.pumpWidget(
        _settingsTestApp(
          settingsController: settingsController,
          directoryPicker:
              ({String? dialogTitle, String? initialDirectory}) async {
                pickerCalls++;
                receivedTitle = dialogTitle;
                receivedInitialDirectory = initialDirectory;
                return selectedPath;
              },
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      final downloadsGroup = find.byKey(
        const ValueKey('downloads-settings-group'),
      );
      final directoryField = find.byKey(
        const ValueKey('download-directory-field'),
      );
      final backupActions = find.byKey(const ValueKey('backup-actions'));
      expect(downloadsGroup, findsOneWidget);
      expect(directoryField, findsOneWidget);
      expect(backupActions, findsOneWidget);
      expect(find.text('Respaldo'), findsNothing);
      expect(
        find.descendant(of: downloadsGroup, matching: find.text('Exportar')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: downloadsGroup, matching: find.text('Importar')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(backupActions).dy,
        greaterThan(tester.getBottomLeft(directoryField).dy),
      );
      expect(
        find.descendant(
          of: downloadsGroup,
          matching: find.byIcon(Icons.save_rounded),
        ),
        findsNothing,
      );
      expect(tester.widget<TextField>(directoryField).readOnly, isTrue);

      await tester.tap(find.byKey(const ValueKey('download-directory-browse')));
      await tester.pump(const Duration(milliseconds: 800));

      expect(pickerCalls, 1);
      expect(receivedTitle, 'Selecciona carpeta de descargas');
      expect(receivedInitialDirectory, initialPath);
      expect(settingsController.savedDirectories, [selectedPath]);
      expect(
        tester.widget<TextField>(directoryField).controller?.text,
        selectedPath,
      );
    },
  );

  testWidgets('cancelling the desktop folder picker keeps the current folder', (
    tester,
  ) async {
    if (!io.Platform.isWindows &&
        !io.Platform.isLinux &&
        !io.Platform.isMacOS) {
      return;
    }
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final initialPath = io.Platform.isWindows
        ? r'C:\Music\Initial'
        : '/tmp/music/initial';
    final settingsController = _FakeSettingsController(
      SettingsState(
        downloadDirectory: initialPath,
        language: AppLanguage.spanish,
      ),
    );
    var pickerCalls = 0;
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async {
              pickerCalls++;
              return null;
            },
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final directoryField = find.byKey(
      const ValueKey('download-directory-field'),
    );
    final before = tester.widget<TextField>(directoryField).controller!.text;

    await tester.tap(find.byKey(const ValueKey('download-directory-browse')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(pickerCalls, 1);
    expect(tester.widget<TextField>(directoryField).controller?.text, before);
    expect(before, initialPath);
    expect(settingsController.savedDirectories, isEmpty);
  });

  testWidgets('cancelling custom sleep timer closes safely', (tester) async {
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async => null,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personalizar'));
    await tester.pumpAndSettle();
    expect(find.text('Duracion del temporizador'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('support section opens the exact Ko-fi donation page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );
    Uri? launchedUrl;
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async => null,
        supportLauncher: (url) async {
          launchedUrl = url;
          return true;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final button = find.byKey(const ValueKey('support-development-button'));
    await tester.scrollUntilVisible(
      button,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    expect(find.text('Versión 1.2.3'), findsOneWidget);
    expect(
      find.text('¿Te gusta la app? Apoya su desarrollo ❤️'),
      findsOneWidget,
    );
    expect(
      find.text(
        'La app seguirá siendo gratuita. Si te resulta útil, puedes hacer una contribución para ayudarme a mantenerla y seguir agregando funciones.',
      ),
      findsOneWidget,
    );

    await tester.tap(button);
    await tester.pump();

    expect(launchedUrl, Uri.parse(AppConstants.supportDevelopmentUrl));
    expect(tester.takeException(), isNull);
  });

  testWidgets('support section reports when the browser cannot open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );
    await tester.pumpWidget(
      _settingsTestApp(
        settingsController: settingsController,
        directoryPicker:
            ({String? dialogTitle, String? initialDirectory}) async => null,
        supportLauncher: (_) async => false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final button = find.byKey(const ValueKey('support-development-button'));
    await tester.scrollUntilVisible(
      button,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();

    expect(find.text('No se pudo abrir la página de apoyo.'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets('download bars show realtime progress from the active task id', (
    tester,
  ) async {
    const track = TrackInfo(
      id: 'progress-track',
      title: 'Progreso visible',
      artist: 'BStream Music',
      url: 'https://example.com/watch?v=progress-track',
      thumbnailUrl: '',
      duration: Duration(minutes: 3),
    );
    final downloader = _ControllableDownloaderService();
    final container = ProviderContainer(
      overrides: [
        downloaderServiceProvider.overrideWithValue(downloader),
        desktopMediaSessionFactoryProvider.overrideWithValue(() => null),
        playerServiceProvider.overrideWithValue(_FakePlayerService()),
        libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await downloader.close();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: TrackResultTile(track: track, onOpenPlayer: () {}),
                ),
                const DownloadProgressPanel(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await container
        .read(downloadControllerProvider.notifier)
        .downloadAudio(track);
    await tester.pump();
    final taskId = container
        .read(downloadControllerProvider)[track.url]!
        .taskId;

    downloader.emitProgress(
      taskId: taskId,
      progress: 0.01,
      url: 'https://canonical.example/progress-track',
    );
    await tester.pump();

    var bars = tester
        .widgetList<GradientProgressBar>(find.byType(GradientProgressBar))
        .toList();
    expect(bars, hasLength(2));
    expect(bars.every((bar) => !bar.indeterminate), isTrue);
    expect(bars.every((bar) => bar.value == 0.01), isTrue);
    expect(
      bars.every((bar) => listEquals(bar.colors, AppColors.downloadGradient)),
      isTrue,
    );
    final downloadNote = tester.widget<Icon>(
      find.descendant(
        of: find.byType(DownloadProgressPanel),
        matching: find.byIcon(Icons.music_note_rounded),
      ),
    );
    expect(downloadNote.color, AppColors.downloadAccent);
    expect(find.textContaining('1%'), findsOneWidget);

    downloader.emitProgress(taskId: taskId, progress: 0.62);
    await tester.pump();
    bars = tester
        .widgetList<GradientProgressBar>(find.byType(GradientProgressBar))
        .toList();
    expect(bars.every((bar) => bar.value == 0.62), isTrue);

    downloader.emitProgress(taskId: taskId, progress: 0.30);
    await tester.pump();
    expect(
      container.read(downloadControllerProvider)[track.url]?.progress,
      0.62,
    );

    if (downloader.started.isCompleted) {
      downloader.complete();
    }
    await tester.pump(const Duration(milliseconds: 200));
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
    const expectedProgressColor = Color(0xFF7B8DFF);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
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
            thumbnailUrl: 'test-artwork.invalid',
            duration: Duration(minutes: 4),
          ),
        ),
        artworkProgressColorService: _FakeArtworkProgressColorService(
          expectedProgressColor,
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(tester.takeException(), isNull);

    final miniPlayerControl = tester.widget<IconButton>(
      find.byKey(const ValueKey('mini-player-primary-control')),
    );
    final miniPlayerContext = tester.element(find.byType(MiniPlayer));
    final miniGradient = AppColors.downloadGradientFor(miniPlayerContext);
    final miniProgressAccent = AppColors.downloadAccentFor(miniPlayerContext);
    final miniForeground = AppColors.playIconForegroundFor(miniPlayerContext);
    expect(
      miniPlayerControl.style?.foregroundColor?.resolve(<WidgetState>{}),
      miniForeground,
    );
    final miniGradientBox = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('mini-player-primary-gradient')),
    );
    final miniGradientDecoration = miniGradientBox.decoration as BoxDecoration;
    final actualMiniGradient =
        (miniGradientDecoration.gradient! as LinearGradient).colors;
    expect(actualMiniGradient, miniGradient);
    expect(
      miniPlayerControl.style?.backgroundColor?.resolve(<WidgetState>{}),
      Colors.transparent,
    );
    expect(
      miniPlayerControl.style?.foregroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      miniForeground.withValues(alpha: 0.62),
    );
    expect(
      miniPlayerControl.style?.backgroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      Colors.transparent,
    );
    final miniProgressAnimation = tester.widget<TweenAnimationBuilder<Color?>>(
      find.byKey(const ValueKey('mini-progress-color-animation')),
    );
    final miniProgressColor = miniProgressAnimation.tween.end;
    expect(miniProgressColor, miniProgressAccent);

    await tester.tap(find.byType(MiniPlayer));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(tester.takeException(), isNull);

    expect(find.text('En reproduccion'), findsOneWidget);
    final largeArtwork = tester.getSize(
      find.byKey(const ValueKey('player-large-artwork')),
    );
    expect(largeArtwork.width, greaterThan(220));
    expect(largeArtwork.height, closeTo(largeArtwork.width, 0.1));
    final playerControl = tester.widget<IconButton>(
      find.byKey(const ValueKey('player-primary-control')),
    );
    final playerContext = tester.element(
      find.byKey(const ValueKey('player-primary-control')),
    );
    expect(
      playerControl.style?.foregroundColor?.resolve(<WidgetState>{}),
      AppColors.playbackPrimaryForegroundFor(playerContext),
    );
    expect(
      playerControl.style?.backgroundColor?.resolve(<WidgetState>{}),
      AppColors.playbackPrimaryBackgroundFor(playerContext),
    );
    expect(
      playerControl.style?.foregroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      AppColors.playbackPrimaryDisabledForegroundFor(playerContext),
    );
    expect(
      playerControl.style?.backgroundColor?.resolve(<WidgetState>{
        WidgetState.disabled,
      }),
      AppColors.playbackPrimaryDisabledBackgroundFor(playerContext),
    );
    final playerProgressAnimation = tester
        .widget<TweenAnimationBuilder<Color?>>(
          find.byKey(const ValueKey('player-progress-color-animation')),
        );
    final playerProgressContext = tester.element(
      find.byKey(const ValueKey('player-progress-color-animation')),
    );
    expect(
      playerProgressAnimation.tween.end,
      AppColors.downloadAccentFor(playerProgressContext),
    );
    expect(find.byTooltip('Letras'), findsOneWidget);
    expect(find.byTooltip('Volumen'), findsOneWidget);
    final lyricsControl = find.byKey(const ValueKey('player-lyrics-control'));
    final shuffleControl = find.byKey(const ValueKey('player-shuffle-control'));
    final volumeControl = find.byKey(const ValueKey('player-volume-control'));
    final repeatControl = find.byKey(const ValueKey('player-repeat-control'));
    expect(
      tester.getCenter(lyricsControl).dx,
      lessThan(tester.getCenter(shuffleControl).dx),
    );
    expect(
      tester.getCenter(lyricsControl).dy,
      closeTo(tester.getCenter(shuffleControl).dy, 0.1),
    );
    expect(
      tester.getSize(lyricsControl).height,
      closeTo(tester.getSize(shuffleControl).height, 0.1),
    );
    expect(
      tester.getCenter(shuffleControl).dx,
      lessThan(tester.getCenter(repeatControl).dx),
    );
    expect(
      tester.getCenter(repeatControl).dx,
      lessThan(tester.getCenter(volumeControl).dx),
    );
    expect(
      tester.getCenter(repeatControl).dy,
      closeTo(tester.getCenter(volumeControl).dy, 0.1),
    );
    expect(
      tester.getSize(volumeControl).height,
      closeTo(tester.getSize(repeatControl).height, 0.1),
    );

    await tester.tap(find.byTooltip('Volumen'));
    await tester.pump(const Duration(milliseconds: 300));
    final popover = find.byKey(const ValueKey('volume-popover'));
    expect(popover, findsOneWidget);
    final popoverContext = tester.element(popover);
    final popoverDecoration =
        tester.widget<Container>(popover).decoration! as BoxDecoration;
    expect(
      popoverDecoration.color,
      AppColors.menuBackgroundFor(popoverContext),
    );
    expect(
      (popoverDecoration.border! as Border).top.color,
      AppColors.menuBorderFor(popoverContext),
    );

    final sliderTheme = tester.widget<SliderTheme>(
      find.descendant(of: popover, matching: find.byType(SliderTheme)),
    );
    expect(
      sliderTheme.data.activeTrackColor,
      AppColors.menuForegroundFor(popoverContext),
    );
    expect(
      sliderTheme.data.thumbColor,
      AppColors.menuForegroundFor(popoverContext),
    );
    expect(
      sliderTheme.data.inactiveTrackColor,
      AppColors.menuInactiveSliderFor(popoverContext),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('lyrics control opens the synchronized lyrics page', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testApp(
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion con letra',
            artist: 'Artista de prueba',
            trackId: 'lyrics-track',
            sourceUrl: 'https://example.com/lyrics-track',
            position: Duration(seconds: 12),
            duration: Duration(minutes: 3),
          ),
        ),
        lyricsService: _FakeLyricsService(
          const LyricsDocument(
            provider: 'LRCLIB',
            trackName: 'Cancion con letra',
            artistName: 'Artista de prueba',
            lines: [
              LyricLine(timestamp: Duration(seconds: 10), text: 'Linea activa'),
              LyricLine(
                timestamp: Duration(seconds: 20),
                text: 'Linea siguiente',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(MiniPlayer));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Letras'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('synced-lyrics-scroll')), findsOneWidget);
    expect(find.text('Linea activa'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('active-lyric-line')),
        matching: find.text('Linea activa'),
      ),
      findsOneWidget,
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
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        FlutterError.onError = previousOnError;
        debugDefaultTargetPlatformOverride = null;
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
      expect(find.byTooltip('Letras'), findsOneWidget);
      expect(find.byTooltip('Cola de reproduccion'), findsOneWidget);
      final lyricsControl = find.byKey(const ValueKey('player-lyrics-control'));
      final shuffleControl = find.byKey(
        const ValueKey('player-shuffle-control'),
      );
      final volumeControl = find.byKey(const ValueKey('player-volume-control'));
      final repeatControl = find.byKey(const ValueKey('player-repeat-control'));
      expect(
        tester.getCenter(lyricsControl).dx,
        lessThan(tester.getCenter(shuffleControl).dx),
      );
      expect(
        tester.getCenter(volumeControl).dx,
        greaterThan(tester.getCenter(repeatControl).dx),
      );
      expect(
        tester.getCenter(lyricsControl).dy,
        closeTo(tester.getCenter(shuffleControl).dy, 0.1),
      );
      expect(
        tester.getCenter(volumeControl).dy,
        closeTo(tester.getCenter(repeatControl).dy, 0.1),
      );

      await tester.tap(find.byTooltip('Cola de reproduccion'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No hay canciones en la cola actual.'), findsOneWidget);

      await tester.tap(find.byTooltip('Cola de reproduccion'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('No hay canciones en la cola actual.'), findsNothing);

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Control de Volumen'), findsNothing);
      Navigator.of(
        tester.element(find.byType(PopupMenuItem<String>).first),
      ).pop();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('Volumen'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('volume-popover')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('volume-popover')),
          matching: find.byType(Slider),
        ),
        findsOneWidget,
      );

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
      debugDefaultTargetPlatformOverride = null;
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
          localTrackFileProbeProvider.overrideWithValue(
            (_) async => LocalTrackFileAvailability.present,
          ),
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
      final playerSurface = tester.getRect(
        find.byKey(const ValueKey('desktop-player-surface')),
      );
      final queueRail = tester.getRect(
        find.byKey(const ValueKey('desktop-playback-queue-rail')),
      );
      expect(queueRail.left, playerSurface.right);
      expect(queueRail.top, 0);
      expect(queueRail.bottom, 600);
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

Widget _settingsTestApp({
  required _FakeSettingsController settingsController,
  required DownloadDirectoryPicker directoryPicker,
  SupportDevelopmentLauncher? supportLauncher,
}) {
  return ProviderScope(
    overrides: [
      settingsControllerProvider.overrideWith(() => settingsController),
      downloadDirectoryPickerProvider.overrideWithValue(directoryPicker),
      if (supportLauncher != null)
        supportDevelopmentLauncherProvider.overrideWithValue(supportLauncher),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: SettingsPanel())),
  );
}

Widget _testApp({
  PlayerService? playerService,
  LibraryRepository? libraryRepository,
  LyricsService? lyricsService,
  ArtworkProgressColorService? artworkProgressColorService,
  DownloadDirectoryPicker? directoryPicker,
}) {
  return ProviderScope(
    overrides: [
      downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
      desktopMediaSessionFactoryProvider.overrideWithValue(() => null),
      playerServiceProvider.overrideWithValue(
        playerService ?? _FakePlayerService(),
      ),
      if (lyricsService != null)
        lyricsServiceProvider.overrideWithValue(lyricsService),
      if (artworkProgressColorService != null)
        artworkProgressColorServiceProvider.overrideWithValue(
          artworkProgressColorService,
        ),
      if (directoryPicker != null)
        downloadDirectoryPickerProvider.overrideWithValue(directoryPicker),
      libraryRepositoryProvider.overrideWithValue(
        libraryRepository ?? _FakeLibraryRepository(),
      ),
    ],
    child: const BStreamMusicApp(),
  );
}

class _FakeSettingsController extends SettingsController {
  _FakeSettingsController(this.initialState);

  final SettingsState initialState;
  final List<String> savedDirectories = [];

  @override
  Future<SettingsState> build() async => initialState;

  @override
  Future<void> setDownloadDirectory(String path) async {
    savedDirectories.add(path);
    final current = await future;
    state = AsyncData(current.copyWith(downloadDirectory: path));
  }
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
    final fileName = '${options.fileName ?? id}.m4a';
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

class _FakeLyricsService implements LyricsService {
  const _FakeLyricsService(this.document);

  final LyricsDocument? document;

  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) async => document;

  @override
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  }) async => const [];

  @override
  Future<List<LyricsCandidate>> searchLyricsByTitle(
    String title, {
    required LyricsLookup context,
    int limit = 8,
  }) async => const [];

  @override
  void dispose() {}
}

class _FakeArtworkProgressColorService extends ArtworkProgressColorService {
  _FakeArtworkProgressColorService(this.color);

  final Color color;

  @override
  Future<Color> resolve(String? rawSource) async => color;
}

class _ControllableDownloaderService implements DownloaderService {
  final _progressController = StreamController<DownloadProgress>.broadcast();
  final _completion = Completer<DownloadResult>();
  final started = Completer<void>();

  String? _url;
  DownloadOptions? _options;

  @override
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    _url = url;
    _options = options;
    if (!started.isCompleted) {
      started.complete();
    }
    return _completion.future;
  }

  void emitProgress({
    required String taskId,
    required double progress,
    String? url,
  }) {
    _progressController.add(
      DownloadProgress(
        taskId: taskId,
        url: url ?? _url ?? '',
        status: DownloadProgressStatus.running,
        progress: progress,
      ),
    );
  }

  void complete() {
    if (_completion.isCompleted) {
      return;
    }
    final url = _url!;
    final options = _options!;
    final fileName = '${options.fileName ?? 'track'}.m4a';
    _completion.complete(
      DownloadResult(
        id: 'completed-progress-track',
        sourceUrl: url,
        filePath: '${options.outputDirectory}\\$fileName',
        fileName: fileName,
        mediaType: DownloadMediaType.audio,
        completedAt: DateTime(2026),
      ),
    );
  }

  Future<void> close() async {
    if (_url != null && _options != null) {
      complete();
    }
    await _progressController.close();
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
  Future<List<TrackInfo>> search(String query) async => const [];
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
  bool get supportsLocalQueueReplacement => false;

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
  Future<void> replaceLocalQueue(
    List<LocalTrack> tracks,
    int preferredIndex,
  ) async {}

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
  Future<Set<String>> purgeMissingLocalTracks(List<LocalTrack> tracks) async {
    return const <String>{};
  }

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
  Future<void> markPlayed(
    String trackId,
    DateTime playedAt, {
    String? playlistId,
  }) async {}

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
