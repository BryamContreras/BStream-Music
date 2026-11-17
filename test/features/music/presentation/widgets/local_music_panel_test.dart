import 'dart:convert';

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/device_audio_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/local_music_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/features/music/presentation/widgets/track_play_button.dart';
import 'package:bstream_music/services/local_media/device_audio_catalog.dart';
import 'package:bstream_music/services/local_media/device_audio_filter.dart';
import 'package:bstream_music/services/local_media/local_media_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('plays all local songs or a folder directly from its card', (
    tester,
  ) async {
    final catalog = _FakeDeviceAudioCatalog(
      const DeviceAudioCatalogResult(
        status: DeviceAudioPermissionStatus.granted,
        tracks: _tracks,
      ),
    );
    final player = _RecordingLocalPlayerController();
    await tester.pumpWidget(_harness(catalog: catalog, player: player));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('local-all-songs-play')));
    await tester.pump();
    expect(player.lastQueue, hasLength(3));
    expect(player.lastQueueSourceId, 'device-local:all');

    await tester.tap(
      find.byKey(const ValueKey('local-folder-play-folder:downloads')),
    );
    await tester.pump();
    expect(player.lastQueue, hasLength(2));
    expect(player.lastQueueSourceId, 'device-local:folder:folder:downloads');
    expect(player.lastUseNativeQueue, isFalse);
  });

  for (final viewport in const [Size(360, 800), Size(1280, 900)]) {
    testWidgets(
      'folder play remains visible without hover at ${viewport.width}px',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final catalog = _FakeDeviceAudioCatalog(
          const DeviceAudioCatalogResult(
            status: DeviceAudioPermissionStatus.granted,
            tracks: _tracks,
          ),
        );
        final player = _RecordingLocalPlayerController();
        final navigation = LocalMusicNavigationController();
        addTearDown(navigation.dispose);
        var openedPlayer = 0;
        await tester.pumpWidget(
          _harness(
            catalog: catalog,
            player: player,
            navigation: navigation,
            onOpenPlayer: () => openedPlayer++,
          ),
        );
        await tester.pumpAndSettle();

        final downloadsPlay = find.byKey(
          const ValueKey('local-folder-play-folder:downloads'),
        );
        final favoritesPlay = find.byKey(
          const ValueKey('local-folder-play-folder:favorites'),
        );
        for (final button in [downloadsPlay, favoritesPlay]) {
          expect(button.hitTestable(), findsOneWidget);
          expect(tester.widget(button), isA<TrackPlayButton>());
          expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
          expect(tester.widget<TrackPlayButton>(button).onPressed, isNotNull);
        }
        expect(navigation.canPop, isFalse);

        await tester.tap(downloadsPlay);
        await tester.pump();
        expect(player.lastQueue!.map((track) => track.id), [
          'device:alpha',
          'device:beta',
        ]);
        expect(player.lastTrack?.id, 'device:alpha');
        expect(
          player.lastQueueSourceId,
          'device-local:folder:folder:downloads',
        );
        expect(player.lastQueue!.every((track) => track.isExternal), isTrue);
        expect(player.lastUseNativeQueue, isFalse);
        expect(navigation.canPop, isFalse);
        expect(find.byKey(const ValueKey('local-detail-title')), findsNothing);
        expect(openedPlayer, 1);

        await tester.tap(favoritesPlay);
        await tester.pump();
        expect(player.lastQueue!.map((track) => track.id), ['device:gamma']);
        expect(player.lastTrack?.id, 'device:gamma');
        expect(
          player.lastQueueSourceId,
          'device-local:folder:folder:favorites',
        );
        expect(navigation.canPop, isFalse);
        expect(openedPlayer, 2);

        // The card itself still browses the folder independently of its play
        // control, so tapping play cannot accidentally open the folder route.
        await tester.tap(
          find.byKey(const ValueKey('local-folder-folder:downloads')),
        );
        await tester.pumpAndSettle();
        expect(navigation.canPop, isTrue);
        expect(
          find.byKey(const ValueKey('local-detail-title')),
          findsOneWidget,
        );
        expect(player.playCalls, 2);
      },
    );
  }

  testWidgets(
    'shows all songs and distinct folders, then plays a transient full queue',
    (tester) async {
      const artworkChannel = MethodChannel('bstream_music/local_audio');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(artworkChannel, (call) async {
            if (call.method != 'loadArtwork') return null;
            return base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
            );
          });
      addTearDown(() {
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(artworkChannel, null);
      });
      final catalog = _FakeDeviceAudioCatalog(
        const DeviceAudioCatalogResult(
          status: DeviceAudioPermissionStatus.granted,
          tracks: _tracks,
        ),
      );
      final player = _RecordingLocalPlayerController();
      final navigation = LocalMusicNavigationController();
      addTearDown(navigation.dispose);

      await tester.pumpWidget(
        _harness(
          catalog: catalog,
          player: player,
          navigation: navigation,
          surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Local'), findsOneWidget);
      expect(find.text('Todas las canciones'), findsOneWidget);
      expect(find.text('Descargas'), findsOneWidget);
      expect(find.text('Favoritas'), findsOneWidget);
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('local-all-songs-entry')))
            .dx,
        6,
      );
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('local-folder-folder:downloads')),
            )
            .dx,
        6,
      );
      expect(catalog.lastOptions?.excludeWhatsAppAudio, isTrue);
      expect(catalog.lastOptions?.excludeTelegramAudio, isTrue);
      expect(catalog.lastOptions?.excludeAudioRecordings, isTrue);
      expect(catalog.lastOptions?.excludeShortAudio, isTrue);
      expect(catalog.lastBstreamRoot, '/tmp/BStream-Music');

      await tester.tap(find.byKey(const ValueKey('local-all-songs-entry')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('local-detail-title')), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);
      expect(find.byKey(const ValueKey('local-detail-menu')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local-detail-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('local-detail-search')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('local-filter-surface')),
          matching: find.byType(TextField),
        ),
        'Alpha',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local-track-device:alpha')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local-track-device:beta')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('local-filter-clear-or-close')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local-track-device:beta')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('local-filter-clear-or-close')),
      );
      await tester.pumpAndSettle();
      final localTrackCard = find.byKey(
        const ValueKey('local-track-device:alpha'),
      );
      final localTrackCardContext = tester.element(localTrackCard);
      expect(
        tester.widget<Material>(localTrackCard).color!.a,
        AppColors.cardSurfaceOpacityFor(localTrackCardContext),
      );
      final artwork = tester.widget<SourceImage>(
        find.descendant(
          of: find.byKey(const ValueKey('local-track-device:alpha')),
          matching: find.byType(SourceImage),
        ),
      );
      expect(
        artwork.source,
        'bstream-local-artwork://audio?uri=content%3A%2F%2Fmedia%2Falpha',
      );

      await tester.tap(
        find.byKey(const ValueKey('local-track-play-device:alpha')),
      );
      await tester.pump();

      expect(player.playCalls, 1);
      expect(player.lastTrack?.id, 'device:alpha');
      expect(player.lastQueue, hasLength(3));
      expect(player.lastQueue!.every((track) => track.isExternal), isTrue);
      expect(player.lastUseNativeQueue, isFalse);
      expect(player.lastQueueSourceId, 'device-local:all');

      expect(navigation.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local-all-songs-entry')),
        findsOneWidget,
      );
    },
  );

  testWidgets('requests Android audio permission before showing the catalog', (
    tester,
  ) async {
    final catalog = _FakeDeviceAudioCatalog(
      const DeviceAudioCatalogResult(
        status: DeviceAudioPermissionStatus.denied,
      ),
    );

    await tester.pumpWidget(_harness(catalog: catalog));
    await tester.pumpAndSettle();

    expect(find.text('Permite el acceso a tu música'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('local-request-permission')),
      findsOneWidget,
    );

    catalog.permissionResult = const DeviceAudioCatalogResult(
      status: DeviceAudioPermissionStatus.granted,
      tracks: _tracks,
    );
    await tester.tap(find.byKey(const ValueKey('local-request-permission')));
    await tester.pumpAndSettle();

    expect(catalog.permissionRequests, 1);
    expect(find.byKey(const ValueKey('local-all-songs-entry')), findsOneWidget);
  });
}

Widget _harness({
  required _FakeDeviceAudioCatalog catalog,
  _RecordingLocalPlayerController? player,
  LocalMusicNavigationController? navigation,
  SurfaceBackgroundMode surfaceBackgroundMode = SurfaceBackgroundMode.accent,
  VoidCallback? onOpenPlayer,
}) {
  return ProviderScope(
    overrides: [
      settingsControllerProvider.overrideWith(_LocalSettingsController.new),
      deviceAudioCatalogProvider.overrideWithValue(catalog),
      playerControllerProvider.overrideWith(
        () => player ?? _RecordingLocalPlayerController(),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        extensions: [AppSurfaceTheme(backgroundMode: surfaceBackgroundMode)],
      ),
      home: Scaffold(
        body: LocalMusicPanel(
          onOpenPlayer: onOpenPlayer ?? () {},
          navigationController: navigation,
        ),
      ),
    ),
  );
}

const _tracks = <DeviceAudioTrack>[
  DeviceAudioTrack(
    id: 'device:beta',
    uri: 'content://media/beta',
    title: 'Beta',
    artist: 'Artista B',
    album: 'Álbum B',
    duration: Duration(minutes: 3),
    folderId: 'folder:downloads',
    folderName: 'Descargas',
  ),
  DeviceAudioTrack(
    id: 'device:alpha',
    uri: 'content://media/alpha',
    title: 'Alpha',
    artist: 'Artista A',
    duration: Duration(minutes: 2),
    artworkSource:
        'bstream-local-artwork://audio?uri=content%3A%2F%2Fmedia%2Falpha',
    folderId: 'folder:downloads',
    folderName: 'Descargas',
  ),
  DeviceAudioTrack(
    id: 'device:gamma',
    uri: 'content://media/gamma',
    title: 'Gamma',
    artist: 'Artista C',
    duration: Duration(minutes: 4),
    folderId: 'folder:favorites',
    folderName: 'Favoritas',
  ),
];

class _LocalSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.spanish,
  );
}

class _FakeDeviceAudioCatalog implements DeviceAudioCatalog {
  _FakeDeviceAudioCatalog(this.result);

  DeviceAudioCatalogResult result;
  DeviceAudioCatalogResult? permissionResult;
  DeviceAudioFilterOptions? lastOptions;
  String? lastBstreamRoot;
  int permissionRequests = 0;

  @override
  Future<DeviceAudioCatalogResult> load({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) async {
    lastOptions = options;
    lastBstreamRoot = bstreamRoot;
    return result;
  }

  @override
  Future<DeviceAudioCatalogResult> refresh({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) => load(options: options, bstreamRoot: bstreamRoot);

  @override
  Future<DeviceAudioCatalogResult> requestPermissionAndLoad({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) async {
    permissionRequests += 1;
    result = permissionResult ?? result;
    return load(options: options, bstreamRoot: bstreamRoot);
  }
}

class _RecordingLocalPlayerController extends PlayerController {
  int playCalls = 0;
  LocalTrack? lastTrack;
  List<LocalTrack>? lastQueue;
  bool? lastUseNativeQueue;
  String? lastQueueSourceId;

  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);

  @override
  Future<void> playLocal(
    LocalTrack track, {
    List<LocalTrack>? queue,
    bool useNativeQueue = true,
    String? queueSourceId,
  }) async {
    playCalls += 1;
    lastTrack = track;
    lastQueue = queue == null ? null : List<LocalTrack>.unmodifiable(queue);
    lastUseNativeQueue = useNativeQueue;
    lastQueueSourceId = queueSourceId;
    state = AsyncData(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        album: track.album,
        trackId: track.id,
        sourceUrl: track.filePath,
        duration: track.duration,
        isExternal: track.isExternal,
      ),
    );
  }
}
