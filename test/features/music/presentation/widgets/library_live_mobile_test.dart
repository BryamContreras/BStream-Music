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
  for (final layout in <String, Size>{
    'narrow Android': const Size(320, 568),
    'wide desktop': const Size(1100, 700),
  }.entries) {
    testWidgets(
      'Library overview artwork matches detail rows on ${layout.key}',
      (tester) async {
        tester.view
          ..devicePixelRatio = 1
          ..physicalSize = layout.value;
        tester.platformDispatcher.textScaleFactorTestValue = 1.35;
        addTearDown(() {
          tester.view
            ..resetPhysicalSize()
            ..resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });

        final track = LocalTrack(
          id: 'artwork-track',
          title: 'A deliberately long downloaded song title',
          artist: 'BStream Music',
          filePath: r'C:\Music\artwork-track.mp3',
          thumbnailPath: r'C:\Music\missing-artwork.jpg',
          addedAt: DateTime(2026),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              libraryTracksProvider.overrideWith((ref) async => [track]),
              playlistsControllerProvider.overrideWith(
                _ArtworkPlaylistsController.new,
              ),
              tiktokLiveControllerProvider.overrideWith(
                _IdleTikTokLiveController.new,
              ),
              playerControllerProvider.overrideWith(_IdlePlayerController.new),
            ],
            child: MaterialApp(
              theme: ThemeData(
                platform: layout.key.contains('Android')
                    ? TargetPlatform.android
                    : TargetPlatform.windows,
              ),
              home: Scaffold(body: LibraryPanel(onOpenPlayer: () {})),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final playlistEntry = find.byKey(
          const ValueKey('library-playlist-artwork-size'),
        );
        await tester.scrollUntilVisible(
          playlistEntry,
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        final overviewArtwork = find.byKey(
          const ValueKey('library-playlist-artwork-artwork-size'),
        );
        final overviewArtworkSize = tester.getSize(overviewArtwork);
        expect(overviewArtworkSize.width, 56);
        if (layout.key.contains('Android')) {
          expect(overviewArtworkSize.height, 56);
        }
        final overviewEntryHeight = tester.getSize(playlistEntry).height;
        expect(overviewEntryHeight, lessThanOrEqualTo(72));
        expect(
          tester.getRect(overviewArtwork).left -
              tester.getRect(playlistEntry).left,
          closeTo(12, 1),
        );

        await tester.tap(playlistEntry);
        await tester.pumpAndSettle();

        final detailArtwork = find.byKey(
          const ValueKey('library-track-artwork-artwork-track'),
        );
        expect(detailArtwork, findsOneWidget);
        expect(tester.getSize(detailArtwork), overviewArtworkSize);
        final detailTile = find
            .ancestor(of: detailArtwork, matching: find.byType(ListTile))
            .first;
        final detailEntryHeight = tester.getSize(detailTile).height;
        expect(detailEntryHeight, lessThanOrEqualTo(72));
        expect(
          (detailEntryHeight - overviewEntryHeight).abs(),
          lessThanOrEqualTo(4),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

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

  testWidgets(
    'Library uses directional push and pop and respects reduced motion',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(430, 800);
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });

      await tester.pumpWidget(_libraryHarness());
      await tester.pumpAndSettle();
      final switcher = find.byKey(const ValueKey('library-route-switcher'));
      expect(
        tester.widget<AnimatedSwitcher>(switcher).duration,
        const Duration(milliseconds: 260),
      );

      final liveEntry = find.byKey(const ValueKey('library-live-entry'));
      await tester.scrollUntilVisible(
        liveEntry,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(liveEntry);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      SlideTransition routeTransition(String key) =>
          tester.widget<SlideTransition>(
            find
                .ancestor(
                  of: find.descendant(
                    of: switcher,
                    matching: find.byKey(ValueKey(key)),
                  ),
                  matching: find.byType(SlideTransition),
                )
                .first,
          );

      expect(routeTransition('root').position.value.dx, lessThan(0));
      expect(routeTransition('live').position.value.dx, greaterThan(0));
      expect(find.byKey(const ValueKey('library-tab-title')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('library-detail-header')),
        findsOneWidget,
      );

      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(routeTransition('root').position.value.dx, lessThan(0));
      expect(routeTransition('live').position.value.dx, greaterThan(0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-tab-title')), findsOneWidget);
      expect(find.byKey(const ValueKey('library-detail-header')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(_libraryHarness(disableAnimations: true));
      await tester.pumpAndSettle();
      final reducedSwitcher = find.byKey(
        const ValueKey('library-route-switcher'),
      );
      expect(
        tester.widget<AnimatedSwitcher>(reducedSwitcher).duration,
        Duration.zero,
      );
      final reducedLiveEntry = find.byKey(const ValueKey('library-live-entry'));
      await tester.scrollUntilVisible(
        reducedLiveEntry,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(reducedLiveEntry);
      await tester.pump();

      expect(find.byKey(const ValueKey('root')), findsNothing);
      expect(find.byKey(const ValueKey('live')), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

Widget _libraryHarness({bool disableAnimations = false}) {
  return ProviderScope(
    overrides: [
      libraryTracksProvider.overrideWith((ref) async => const <LocalTrack>[]),
      playlistsControllerProvider.overrideWith(_EmptyPlaylistsController.new),
      tiktokLiveControllerProvider.overrideWith(_IdleTikTokLiveController.new),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: Scaffold(body: LibraryPanel(onOpenPlayer: () {})),
    ),
  );
}

class _EmptyPlaylistsController extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => const <Playlist>[];
}

class _ArtworkPlaylistsController extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => [
    Playlist(
      id: 'artwork-size',
      name: 'A deliberately long playlist name for responsive layout',
      trackIds: const ['artwork-track'],
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  ];
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
