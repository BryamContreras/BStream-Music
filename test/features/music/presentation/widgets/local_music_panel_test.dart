import 'dart:convert';

import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/device_audio_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/local_music_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/local_media/device_audio_catalog.dart';
import 'package:bstream_music/services/local_media/device_audio_filter.dart';
import 'package:bstream_music/services/local_media/local_media_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      expect(find.byType(PopupMenuButton), findsNothing);
      expect(
        tester
            .widget<Material>(
              find.byKey(const ValueKey('local-track-device:alpha')),
            )
            .color!
            .a,
        1,
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
          onOpenPlayer: () {},
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
