import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/library_panel.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Android library exposes the TikTok LIVE queue entry', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(320, 568);
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryTracksProvider.overrideWith(
            (ref) async => const <LocalTrack>[],
          ),
          playlistsControllerProvider.overrideWith(
            _EmptyPlaylistsController.new,
          ),
          tiktokLiveControllerProvider.overrideWith(
            _IdleTikTokLiveController.new,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: LibraryPanel(onOpenPlayer: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-live-entry')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.sensors_rounded), findsOneWidget);
    expect(find.text('LIVE'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android LIVE remote item remains playable without a download', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(320, 568);
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    final liveController = _RemoteQueueTikTokLiveController();
    var openedPlayer = false;
    const strings = AppStrings(AppLanguage.spanish);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryTracksProvider.overrideWith(
            (ref) async => const <LocalTrack>[],
          ),
          playlistsControllerProvider.overrideWith(
            _EmptyPlaylistsController.new,
          ),
          tiktokLiveControllerProvider.overrideWith(() => liveController),
          playerControllerProvider.overrideWith(_IdlePlayerController.new),
          appStringsProvider.overrideWithValue(strings),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LibraryPanel(onOpenPlayer: () => openedPlayer = true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final liveEntry = find.byKey(const ValueKey('library-live-entry'));
    await tester.scrollUntilVisible(
      liveEntry,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(liveEntry);
    await tester.pumpAndSettle();

    expect(find.text('Remote song'), findsOneWidget);
    expect(find.text(strings.readyForRemotePlayback), findsOneWidget);
    final playButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
    );
    expect(playButton.onPressed, isNotNull);
    final playTarget = tester.getRect(
      find.widgetWithIcon(IconButton, Icons.play_arrow_rounded),
    );
    expect(playTarget.width, greaterThanOrEqualTo(48));
    expect(playTarget.height, greaterThanOrEqualTo(48));

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();

    expect(openedPlayer, isTrue);
    expect(liveController.playedItemId, 'remote-item');
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

class _EmptyPlaylistsController extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => const <Playlist>[];
}

class _IdleTikTokLiveController extends TikTokLiveController {
  @override
  Future<TikTokLiveState> build() async => const TikTokLiveState(
    creatorInput: '',
    status: TikTokLiveStatus.idle,
    message: 'Listo para conectar.',
  );
}

class _RemoteQueueTikTokLiveController extends TikTokLiveController {
  String? playedItemId;

  @override
  Future<TikTokLiveState> build() async => TikTokLiveState(
    creatorInput: 'creator',
    status: TikTokLiveStatus.connected,
    message: 'Conectado.',
    saveRequestsToLibrary: false,
    liveQueue: [
      LiveQueueItem(
        id: 'remote-item',
        requestedBy: 'viewer',
        query: 'Remote song',
        commandText: '!play Remote song',
        requestedAt: DateTime(2026),
        status: LiveQueueItemStatus.ready,
        remoteTrack: const TrackInfo(
          id: 'youtube-id',
          title: 'Remote song',
          artist: 'Remote artist',
          url: 'https://www.youtube.com/watch?v=youtube-id',
        ),
        saveToLibrary: false,
      ),
    ],
  );

  @override
  Future<void> playLiveQueueItem(String itemId) async {
    playedItemId = itemId;
  }
}

class _IdlePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);
}
