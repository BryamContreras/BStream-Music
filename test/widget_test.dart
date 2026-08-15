import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/search_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/library_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/artwork_progress_color_provider.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/pages/search_view.dart';
import 'package:bstream_music/features/music/presentation/widgets/library_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/download_progress_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/gradient_progress_bar.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/features/music/presentation/widgets/track_result_tile.dart';
import 'package:bstream_music/main.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/lyrics/lyrics_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
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

  testWidgets(
    'windows mini player fills content and centers transport controls',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpWidget(
        _testApp(
          playerService: _FakePlayerService(
            snapshot: const PlayerSnapshot(
              status: PlayerStatus.playing,
              title: 'Cancion de escritorio',
              artist: 'BStream Music',
              trackId: 'desktop-mini-player-track',
              duration: Duration(minutes: 3),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      for (final viewport in const [Size(1280, 720), Size(960, 600)]) {
        tester.view.physicalSize = viewport;
        await tester.pump();

        final surface = find.byKey(const ValueKey('mini-player-surface'));
        final previous = find.byKey(
          const ValueKey('mini-player-previous-control'),
        );
        final play = find.byKey(const ValueKey('mini-player-primary-control'));
        final next = find.byKey(const ValueKey('mini-player-next-control'));
        final surfaceRect = tester.getRect(surface);
        final previousCenter = tester.getCenter(previous);
        final playCenter = tester.getCenter(play);
        final nextCenter = tester.getCenter(next);

        const sideNavigationWidth = 248.0;
        const dividerWidth = 1.0;
        final contentStart = sideNavigationWidth + dividerWidth;
        expect(surfaceRect.left, closeTo(contentStart, 0.1));
        expect(surfaceRect.width, closeTo(viewport.width - contentStart, 0.1));
        expect(playCenter.dx, closeTo(surfaceRect.center.dx, 0.1));
        expect(playCenter.dx - previousCenter.dx, closeTo(56, 0.1));
        expect(nextCenter.dx - playCenter.dx, closeTo(56, 0.1));
        expect(previousCenter.dy, closeTo(playCenter.dy, 0.1));
        expect(nextCenter.dy, closeTo(playCenter.dy, 0.1));
        expect(tester.takeException(), isNull);

        await tester.tap(previous);
        await tester.pump();
        expect(find.byKey(const ValueKey('player-tab-title')), findsNothing);
        await tester.tap(next);
        await tester.pump();
        expect(find.byKey(const ValueKey('player-tab-title')), findsNothing);
        expect(tester.takeException(), isNull);
      }
      debugDefaultTargetPlatformOverride = null;
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets('android mini player is shorter without shrinking play target', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 800);
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
            title: 'Cancion movil',
            artist: 'BStream Music',
            trackId: 'android-mini-player-track',
            duration: Duration(minutes: 3),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-surface'))).height,
      62,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-primary-control'))),
      const Size.square(48),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android bottom navigation is glassy and meets mini player', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
    });

    await tester.pumpWidget(
      _testApp(
        playerService: _FakePlayerService(
          snapshot: const PlayerSnapshot(
            status: PlayerStatus.playing,
            title: 'Cancion movil',
            artist: 'BStream Music',
            trackId: 'android-bottom-navigation-track',
            duration: Duration(minutes: 3),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    final glass = find.byKey(const ValueKey('bottom-navigation-glass'));
    final content = find.byKey(const ValueKey('bottom-navigation-content'));
    final miniPlayer = find.byKey(const ValueKey('mini-player-surface'));
    final glassDecorationFinder = find.descendant(
      of: glass,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox && widget.decoration is BoxDecoration,
      ),
    );
    final glassDecoration = tester
        .widgetList<DecoratedBox>(glassDecorationFinder)
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((decoration) => decoration.border != null);
    final context = tester.element(glass);

    expect(scaffold.extendBody, isTrue);
    expect(tester.getSize(content).height, 76);
    expect(
      find.descendant(of: glass, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    expect(
      glassDecoration.color,
      Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
    );
    expect(
      tester.getBottomLeft(miniPlayer).dy,
      closeTo(tester.getTopLeft(glass).dy, 0.1),
    );
    expect(tester.getBottomLeft(glass).dy, closeTo(800, 0.1));
    expect(
      tester.getSize(glass).height,
      closeTo(76 + MediaQuery.paddingOf(context).bottom, 0.1),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('home cards use larger mobile dimensions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final repository = _homeCardsRepository();

    await tester.pumpWidget(_testApp(libraryRepository: repository));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const ValueKey('home-recent-card'))).width,
      148,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('home-playlist-card'))).width,
      160,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('home-recent-shelf'))).height,
      200,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('home-playlist-shelf'))).height,
      212,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('home hides the complete playlist section when it is empty', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final repository = _homeCardsRepository()..playlists.clear();

    await tester.pumpWidget(_testApp(libraryRepository: repository));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Inicio'), findsWidgets);
    expect(find.text('Cancion reciente'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-recent-card')), findsOneWidget);
    expect(find.text('Mis playlists'), findsNothing);
    expect(find.text('Todavia no hay playlists locales.'), findsNothing);
    expect(find.byKey(const ValueKey('home-playlist-shelf')), findsNothing);
    expect(find.byKey(const ValueKey('home-playlist-card')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home hides the complete recent section when history is empty', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final repository = _homeCardsRepository()..history.clear();

    await tester.pumpWidget(_testApp(libraryRepository: repository));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Inicio'), findsWidgets);
    expect(find.text('Escuchado recientemente'), findsNothing);
    expect(find.text('Aun no has escuchado canciones.'), findsNothing);
    expect(find.byKey(const ValueKey('home-recent-shelf')), findsNothing);
    expect(find.byKey(const ValueKey('home-recent-card')), findsNothing);
    expect(find.text('Mis playlists'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-playlist-card')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home cards use larger desktop dimensions', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final repository = _homeCardsRepository();

    await tester.pumpWidget(_testApp(libraryRepository: repository));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(
      tester.getSize(find.byKey(const ValueKey('home-recent-card'))).width,
      176,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('home-playlist-card'))).width,
      188,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('home-recent-shelf'))).height,
      228,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('home-playlist-shelf'))).height,
      240,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  }, skip: !io.Platform.isWindows);

  testWidgets('home shelves fit text scale 3 on a 320x568 phone', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(
      _testApp(
        libraryRepository: _homeCardsRepository(),
        homeRecommendations: [
          HomeRecommendationSection(
            title: 'Para ti',
            tracks: const [
              TrackInfo(
                id: 'scaled-recommendation',
                title: 'Recomendacion de titulo largo',
                artist: 'Artista de nombre largo',
                url: 'https://www.youtube.com/watch?v=scaled',
                thumbnailUrl: '',
              ),
            ],
          ),
        ],
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-surface'))).height,
      greaterThan(62),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('mini-player-primary-control'))),
      const Size.square(48),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('bottom-navigation-content')))
          .height,
      greaterThan(76),
    );
    final navigationItems = find.descendant(
      of: find.byKey(const ValueKey('bottom-navigation-content')),
      matching: find.byType(InkWell),
    );
    expect(navigationItems, findsNWidgets(4));
    for (var index = 0; index < 4; index++) {
      final size = tester.getSize(navigationItems.at(index));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    final homeScroll = find.descendant(
      of: find.byKey(const ValueKey('home-view')),
      matching: find.byType(CustomScrollView),
    );
    // At a 3x text scale, the accessible title can legitimately move the
    // lazily-built shelves below the first viewport. Scroll to the shelf
    // before inspecting its adaptive height.
    await tester.drag(homeScroll, const Offset(0, -360));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.getSize(find.byKey(const ValueKey('home-recent-shelf'))).height,
      greaterThan(200),
    );

    await tester.drag(homeScroll, const Offset(0, -900));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'home shows online recommendation shelves and plays the selected shelf queue',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final player = _RecordingHomePlayerController();
      final sections = [
        HomeRecommendationSection(
          title: 'Para ti',
          tracks: const [
            TrackInfo(
              id: 'recommended-1',
              title: 'Recomendacion uno',
              artist: 'Artista uno',
              url: 'https://www.youtube.com/watch?v=recommend1',
              thumbnailUrl: '',
            ),
            TrackInfo(
              id: 'recommended-2',
              title: 'Recomendacion dos',
              artist: 'Artista dos',
              url: 'https://www.youtube.com/watch?v=recommend2',
              thumbnailUrl: '',
            ),
            TrackInfo(
              id: 'recommended-3',
              title: 'Recomendacion tres',
              artist: 'Artista tres',
              url: 'https://www.youtube.com/watch?v=recommend3',
              thumbnailUrl: '',
            ),
          ],
        ),
        HomeRecommendationSection(
          title: 'Novedades',
          tracks: const [
            TrackInfo(
              id: 'recommended-4',
              title: 'Recomendacion cuatro',
              artist: 'Artista cuatro',
              url: 'https://www.youtube.com/watch?v=recommend4',
              thumbnailUrl: '',
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          playerController: player,
          homeRecommendations: sections,
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(const ValueKey('home-recommendations-section-Para ti')),
        findsOneWidget,
      );
      for (final id in const [
        'recommended-1',
        'recommended-2',
        'recommended-3',
      ]) {
        expect(find.byKey(ValueKey('home-recommendation-$id')), findsOneWidget);
      }
      expect(find.text('Cancion reciente'), findsOneWidget);
      expect(find.text('Playlist de Inicio'), findsOneWidget);

      final homeScroll = find.byType(CustomScrollView);
      await tester.drag(homeScroll, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home-recommendations-section-Novedades')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('home-recommendation-recommended-4')),
        findsOneWidget,
      );

      await tester.drag(homeScroll, const Offset(0, 600));
      await tester.pumpAndSettle();

      final selected = find.byKey(
        const ValueKey('home-recommendation-recommended-2'),
      );
      await tester.drag(homeScroll, const Offset(0, -250));
      await tester.pumpAndSettle();
      await tester.tap(selected);
      await tester.pump();

      expect(player.remotePlayCalls, 1);
      expect(player.lastRemoteTrack?.id, 'recommended-2');
      expect(player.lastRemoteQueue?.map((track) => track.id), const [
        'recommended-1',
        'recommended-2',
        'recommended-3',
      ]);
      expect(
        player.lastRemoteQueue,
        isNot(contains(sections.last.tracks.single)),
      );
    },
  );

  testWidgets('home opens a mix detail and Play starts the complete queue', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final player = _RecordingHomePlayerController();
    var collectionCalls = 0;
    const browseId = 'VLRDrelaxing-mix';
    final mixTracks = const [
      TrackInfo(
        id: 'mix-track-1',
        title: 'Mix uno',
        artist: 'Artista uno',
        url: 'https://www.youtube.com/watch?v=mixtrack001',
        thumbnailUrl: '',
      ),
      TrackInfo(
        id: 'mix-track-2',
        title: 'Mix dos',
        artist: 'Artista dos',
        url: 'https://www.youtube.com/watch?v=mixtrack002',
        thumbnailUrl: '',
      ),
    ];
    final sections = [
      HomeRecommendationSection.items(
        title: 'Melodias relajantes',
        items: const [
          HomeRecommendationCollectionItem(
            HomeRecommendationCollection(
              title: 'Mix para relajarse',
              subtitle: 'YouTube Music',
              thumbnailUrl: '',
              browseId: browseId,
              playlistId: 'RDrelaxing-mix',
              kind: HomeRecommendationCollectionKind.mix,
            ),
          ),
        ],
      ),
    ];

    await tester.pumpWidget(
      _testApp(
        libraryRepository: _homeCardsRepository(),
        playerController: player,
        homeRecommendations: sections,
        homeCollectionLoader: (requestedBrowseId) async {
          collectionCalls++;
          expect(requestedBrowseId, browseId);
          return mixTracks;
        },
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(collectionCalls, 0);
    expect(player.remotePlayCalls, 0);

    final mixCard = find.byKey(
      const ValueKey('home-collection-open-$browseId'),
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(mixCard, findsOneWidget);
    expect(find.text('Mix para relajarse'), findsOneWidget);

    await tester.tap(mixCard);
    await tester.pumpAndSettle();

    expect(collectionCalls, 1);
    expect(player.remotePlayCalls, 0);
    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsOneWidget,
    );
    expect(find.text('Mix para relajarse'), findsNWidgets(2));
    expect(find.text('YouTube Music'), findsOneWidget);
    expect(find.text('Mix uno'), findsOneWidget);
    expect(find.text('Mix dos'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remote-collection-play')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(player.remotePlayCalls, 1);
    expect(player.lastRemoteTrack?.id, 'mix-track-1');
    expect(player.lastRemoteQueue?.map((track) => track.id), const [
      'mix-track-1',
      'mix-track-2',
    ]);
    expect(player.lastRemoteQueueSourceId, 'home-collection:$browseId');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'home refresh keeps recommendations visible while loading and replaces them',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final pending = Completer<List<HomeRecommendationSection>>();
      addTearDown(() {
        if (!pending.isCompleted) {
          pending.complete(const <HomeRecommendationSection>[]);
        }
      });
      var calls = 0;
      final initialSections = [
        HomeRecommendationSection(
          title: 'Antes de refrescar',
          tracks: const [
            TrackInfo(
              id: 'refresh-old-track',
              title: 'Recomendacion anterior',
              artist: 'Artista anterior',
              url: 'https://www.youtube.com/watch?v=refreshold1',
            ),
          ],
        ),
      ];
      final refreshedSections = [
        HomeRecommendationSection(
          title: 'Despues de refrescar',
          tracks: const [
            TrackInfo(
              id: 'refresh-new-track',
              title: 'Recomendacion nueva',
              artist: 'Artista nuevo',
              url: 'https://www.youtube.com/watch?v=refreshnew1',
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          homeRecommendationsLoader: () {
            calls++;
            return calls == 1 ? initialSections : pending.future;
          },
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      final refresh = find.byKey(
        const ValueKey('home-recommendations-refresh'),
      );
      expect(calls, 1);
      expect(refresh, findsOneWidget);
      expect(tester.getSize(refresh), const Size.square(48));
      expect(
        tester.widget<IconButton>(refresh).tooltip,
        'Refrescar recomendaciones',
      );
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Antes de refrescar'),
        ),
        findsOneWidget,
      );

      await tester.tap(refresh);
      await tester.pump();

      expect(calls, 2);
      expect(tester.widget<IconButton>(refresh).onPressed, isNull);
      expect(
        find.descendant(
          of: refresh,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Antes de refrescar'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-recent-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-playlist-card')), findsOneWidget);

      pending.complete(refreshedSections);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Despues de refrescar'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Antes de refrescar'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'home refresh keeps the previous feed when the network request fails',
    (tester) async {
      _configureMobileHomeViewport(tester);
      var calls = 0;
      final initialSections = [
        HomeRecommendationSection(
          title: 'Feed conservado',
          tracks: const [
            TrackInfo(
              id: 'refresh-preserved-track',
              title: 'Recomendacion conservada',
              artist: 'Artista local',
              url: 'https://www.youtube.com/watch?v=preserved1',
            ),
          ],
        ),
      ];

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          homeRecommendationsLoader: () async {
            calls++;
            if (calls == 1) {
              return initialSections;
            }
            throw const io.SocketException('offline');
          },
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      final refresh = find.byKey(
        const ValueKey('home-recommendations-refresh'),
      );
      await tester.tap(refresh);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(calls, 2);
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);
      expect(
        find.byKey(
          const ValueKey('home-recommendations-section-Feed conservado'),
        ),
        findsOneWidget,
      );
      expect(find.text('offline'), findsNothing);
      expect(find.byKey(const ValueKey('home-recent-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-playlist-card')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('home hides recommendations while loading and keeps local data', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);
    final pending = Completer<List<HomeRecommendationSection>>();
    addTearDown(() {
      if (!pending.isCompleted) {
        pending.complete(const <HomeRecommendationSection>[]);
      }
    });

    await tester.pumpWidget(
      _testApp(
        libraryRepository: _homeCardsRepository(),
        homeRecommendations: pending.future,
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    _expectLocalOnlyHome(tester);
  });

  testWidgets(
    'home hides failed recommendations and local playback still works',
    (tester) async {
      _configureMobileHomeViewport(tester);
      final player = _RecordingHomePlayerController();

      await tester.pumpWidget(
        _testApp(
          libraryRepository: _homeCardsRepository(),
          playerController: player,
          homeRecommendationsError: const io.SocketException('offline'),
        ),
      );
      await tester.pump(const Duration(seconds: 1));

      _expectLocalOnlyHome(tester);

      await tester.tap(find.byKey(const ValueKey('home-recent-card')));
      await tester.pump();

      expect(player.historyPlayCalls, 1);
      expect(player.lastHistoryTrack?.id, 'home-card-track');
      expect(player.lastHistoryQueue?.map((track) => track.id), const [
        'home-card-track',
      ]);
      expect(player.remotePlayCalls, 0);
    },
  );

  testWidgets('home hides empty recommendations and keeps local data', (
    tester,
  ) async {
    _configureMobileHomeViewport(tester);

    await tester.pumpWidget(
      _testApp(
        libraryRepository: _homeCardsRepository(),
        homeRecommendations: const <HomeRecommendationSection>[],
      ),
    );
    await tester.pump(const Duration(seconds: 1));

    _expectLocalOnlyHome(tester);
  });

  testWidgets('visible tab headings share the same themed foreground', (
    tester,
  ) async {
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
        themeMode: AppThemeMode.dark,
        accent: AppAccent.blue,
      ),
    );
    await tester.pumpWidget(_testApp(settingsController: settingsController));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final homeColor = tester
        .widget<Text>(find.byKey(const ValueKey('home-tab-title')))
        .style
        ?.color;

    await tester.tap(find.text('Buscar').last);
    await tester.pump(const Duration(milliseconds: 300));
    final searchColor = tester
        .widget<Text>(find.byKey(const ValueKey('search-tab-title')))
        .style
        ?.color;

    await tester.tap(find.text('Biblioteca').last);
    await tester.pump(const Duration(milliseconds: 300));
    final libraryColor = tester
        .widget<Text>(find.byKey(const ValueKey('library-tab-title')))
        .style
        ?.color;

    await tester.tap(find.text('Ajustes').last);
    await tester.pump(const Duration(milliseconds: 300));
    final settingsColor = tester
        .widget<Text>(find.byKey(const ValueKey('settings-tab-title')))
        .style
        ?.color;

    expect(homeColor, isNotNull);
    expect(searchColor, homeColor);
    expect(libraryColor, homeColor);
    expect(settingsColor, homeColor);
  });

  testWidgets('light popup text and icons follow the selected accent', (
    tester,
  ) async {
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
        themeMode: AppThemeMode.light,
        accent: AppAccent.blue,
      ),
    );
    await tester.pumpWidget(_testApp(settingsController: settingsController));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final context = tester.element(find.byType(Scaffold).first);
    expect(
      ProviderScope.containerOf(
        context,
      ).read(settingsControllerProvider).value?.themeMode,
      AppThemeMode.light,
    );
    final popupTheme = Theme.of(context).popupMenuTheme;
    final colors = Theme.of(context).colorScheme;
    expect(colors.brightness, Brightness.light);
    expect(popupTheme.color, AppColors.menuBackgroundFor(context));
    expect(popupTheme.textStyle?.color, AppColors.menuForegroundFor(context));
    expect(popupTheme.iconColor, AppColors.menuIconFor(context));
    expect(
      popupTheme.color,
      colors.surfaceContainerHighest.withValues(alpha: 0.97),
    );
    expect(popupTheme.surfaceTintColor, Colors.transparent);
    final shape = popupTheme.shape! as RoundedRectangleBorder;
    expect(shape.side.color, AppColors.menuBorderFor(context));
    expect(shape.side.color, colors.outlineVariant.withValues(alpha: 0.9));
  });

  testWidgets('dark popup surface stays neutral while content uses accent', (
    tester,
  ) async {
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
        themeMode: AppThemeMode.dark,
        accent: AppAccent.blue,
      ),
    );
    await tester.pumpWidget(_testApp(settingsController: settingsController));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final context = tester.element(find.byType(Scaffold).first);
    expect(
      ProviderScope.containerOf(
        context,
      ).read(settingsControllerProvider).value?.themeMode,
      AppThemeMode.dark,
    );
    final popupTheme = Theme.of(context).popupMenuTheme;
    final colors = Theme.of(context).colorScheme;
    expect(colors.brightness, Brightness.dark);
    expect(popupTheme.color, AppColors.menuBackground);
    expect(popupTheme.textStyle?.color, AppColors.menuForegroundFor(context));
    expect(popupTheme.textStyle?.color, isNot(AppColors.menuForeground));
    expect(popupTheme.iconColor, AppColors.menuIconFor(context));
    expect(popupTheme.iconColor, isNot(AppColors.menuForeground));
    final shape = popupTheme.shape! as RoundedRectangleBorder;
    expect(shape.side.color, AppColors.menuBorder);
  });

  testWidgets('desktop Downloads and Backup share the Storage settings page', (
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

    expect(find.byKey(const ValueKey('settings-card-storage')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-card-downloads')), findsNothing);
    expect(find.byKey(const ValueKey('settings-card-backup')), findsNothing);
    expect(
      find.byKey(const ValueKey('download-directory-field')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('backup-actions')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    final directoryField = find.byKey(
      const ValueKey('download-directory-field'),
    );
    expect(directoryField, findsOneWidget);
    expect(find.byKey(const ValueKey('backup-actions')), findsNothing);
    expect(find.byKey(const ValueKey('storage-import-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-import-csv')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-csv')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-import-start')), findsNothing);
    expect(find.text('Respaldo'), findsNothing);
    expect(tester.widget<TextField>(directoryField).readOnly, isTrue);

    final firstTransferCard = find.byKey(
      const ValueKey('storage-import-backup'),
    );
    expect(
      tester.getBottomLeft(directoryField).dy,
      lessThan(tester.getTopLeft(firstTransferCard).dy),
    );

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

    expect(firstTransferCard, findsOneWidget);
    expect(find.text('Exportar'), findsOneWidget);
    expect(find.text('Importar'), findsOneWidget);
    expect(directoryField, findsOneWidget);
  });

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

    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

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

    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Personalizar'));
    await tester.pumpAndSettle();
    expect(find.text('Duracion del temporizador'), findsOneWidget);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('accent palette always shows every color row', (tester) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(() => settingsController),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, isActive, _) => SettingsPanel(active: isActive),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('accent-white')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-orange')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-expand-button')), findsNothing);
    expect(find.byKey(const ValueKey('accent-red')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-cyan')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-indigo')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-lime')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-brown')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-lavender')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-ocean')), findsOneWidget);

    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('settings-card-appearance')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('accent-expand-button')), findsNothing);
    expect(find.byKey(const ValueKey('accent-red')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('accent-expand-button')), findsNothing);
    expect(find.byKey(const ValueKey('accent-red')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-ocean')), findsOneWidget);
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
    expect(find.text('Versión 1.2.4'), findsOneWidget);
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
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const ValueKey('search-tab-title')), findsOneWidget);

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

  testWidgets('library lazily builds large playlist collections', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    final repository = _FakeLibraryRepository();
    repository.playlists.addAll(
      List.generate(
        1000,
        (index) => Playlist(
          id: 'lazy-$index',
          name: 'Playlist $index',
          trackIds: const [],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ),
    );

    await tester.pumpWidget(_libraryPanelTestApp(repository: repository));
    await tester.pumpAndSettle();

    final builtPlaylists = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('library-playlist-lazy-');
    });
    expect(builtPlaylists, findsWidgets);
    expect(
      builtPlaylists.evaluate().length,
      lessThan(40),
      reason: 'Only viewport-adjacent playlist rows should be mounted.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('current search result retains visible hover feedback', (
    tester,
  ) async {
    const track = TrackInfo(
      id: 'playing-result',
      title: 'Resultado activo',
      artist: 'BStream Music',
      url: 'https://example.com/playing-result',
      thumbnailUrl: '',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(
            _FakePlayerService(
              snapshot: PlayerSnapshot(
                status: PlayerStatus.playing,
                trackId: track.id,
                sourceUrl: track.url,
                isRemote: true,
              ),
            ),
          ),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: TrackResultTile(track: track, onOpenPlayer: _noop),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final surface = find.byKey(
      const ValueKey('track-result-surface-playing-result'),
    );
    var decoration =
        tester.widget<AnimatedContainer>(surface).decoration! as BoxDecoration;
    expect((decoration.border! as Border).top.width, 1);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 300));

    decoration =
        tester.widget<AnimatedContainer>(surface).decoration! as BoxDecoration;
    expect((decoration.border! as Border).top.width, 1.4);
  });

  testWidgets('search eagerly keeps all capped result thumbnails mounted', (
    tester,
  ) async {
    final tracks = List.generate(
      20,
      (index) => TrackInfo(
        id: 'search-$index',
        title: 'Resultado $index',
        artist: 'BStream Music',
        url: 'https://example.com/search-$index',
        thumbnailUrl: '',
      ),
    );
    tester.view.physicalSize = const Size(430, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchControllerProvider.overrideWith(
            () => _FakeSearchController(tracks),
          ),
          downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
          playerServiceProvider.overrideWithValue(_FakePlayerService()),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepository()),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SearchView(onOpenPlayer: _noop)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(TrackResultTile), findsNWidgets(20));
    final artwork = tester
        .widgetList<ProportionalArtwork>(find.byType(ProportionalArtwork))
        .toList(growable: false);
    expect(artwork, hasLength(20));
    expect(artwork.every((image) => image.cacheWidth == 256), isTrue);
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
        localTrackDownloadHelperProvider.overrideWith(
          (ref) => _ControllableLocalTrackDownloadHelper(ref, downloader),
        ),
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

    await tester.runAsync(() async {
      await container
          .read(downloadControllerProvider.notifier)
          .downloadAudio(track);
      await downloader.started.future.timeout(const Duration(seconds: 5));
    });
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

    final surface = find.byKey(
      const ValueKey('track-result-surface-progress-track'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 300));
    final decoration =
        tester.widget<AnimatedContainer>(surface).decoration! as BoxDecoration;
    expect((decoration.border! as Border).top.width, 1.4);

    downloader.emitProgress(taskId: taskId, progress: 0.30);
    await tester.pump();
    expect(
      container.read(downloadControllerProvider)[track.url]?.progress,
      0.62,
    );

    await tester.runAsync(() async {
      downloader.complete();
      for (var attempt = 0; attempt < 100; attempt++) {
        if (container.read(downloadControllerProvider)[track.url]?.status ==
            DownloadProgressStatus.completed) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(
      container.read(downloadControllerProvider)[track.url]?.status,
      DownloadProgressStatus.completed,
    );
  });

  test('downloadAudioForLibrary returns the saved local track', () async {
    final tempDirectory = await io.Directory.systemTemp.createTemp(
      'bstream-library-download-test-',
    );
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
        settingsControllerProvider.overrideWith(
          () => _FakeSettingsController(
            SettingsState(
              downloadDirectory: tempDirectory.path,
              language: AppLanguage.spanish,
            ),
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

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

    expect(localTrack.id, startsWith('remote-'));
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
    expect(
      find.byKey(const ValueKey('library-track-play-playlist-route-track')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('library-track-menu-playlist-route-track')),
      findsOneWidget,
    );
  });

  testWidgets(
    'android back closes two-track selection without leaving downloads',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final repository = _FakeLibraryRepository()
        ..localTracks.addAll([
          _librarySelectionTrack('selection-a', 'Cancion A'),
          _librarySelectionTrack('selection-b', 'Cancion B'),
          _librarySelectionTrack('selection-c', 'Cancion C'),
        ]);
      final navigationController = LibraryNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _libraryPanelTestApp(
          repository: repository,
          navigationController: navigationController,
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('Canciones descargadas'));
      await tester.pump(const Duration(milliseconds: 500));

      await tester.longPress(
        find.byKey(const ValueKey('library-track-selection-a')),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.byKey(const ValueKey('library-track-selection-b')));
      await tester.pump(const Duration(milliseconds: 250));

      expect(
        find.byKey(const ValueKey('library-selection-toolbar')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('library-selection-count')))
            .data,
        '2 canciones seleccionadas',
      );
      expect(
        find.byKey(const ValueKey('selection-check-selection-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('selection-check-selection-b')),
        findsOneWidget,
      );

      expect(navigationController.canPop, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-selection-toolbar')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-detail-header')),
        findsOneWidget,
      );
      expect(find.text('Canciones descargadas'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('library-track-selection-a')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('android adds two selected tracks without duplicating playlist', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final first = _librarySelectionTrack('add-a', 'Cancion A');
    final second = _librarySelectionTrack('add-b', 'Cancion B');
    final repository = _FakeLibraryRepository()
      ..localTracks.addAll([first, second])
      ..playlists.add(
        Playlist(
          id: 'destination-playlist',
          name: 'Playlist destino',
          trackIds: [first.id],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );

    await tester.pumpWidget(_libraryPanelTestApp(repository: repository));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Canciones descargadas'));
    await tester.pump(const Duration(milliseconds: 500));
    await _selectLibraryTracks(tester, ['add-a', 'add-b']);

    await tester.tap(
      find.byKey(const ValueKey('library-selection-add-to-playlist')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Elegir playlist'), findsOneWidget);
    await tester.tap(find.text('Playlist destino'));
    await tester.pumpAndSettle();

    final playlist = repository.playlists.singleWhere(
      (entry) => entry.id == 'destination-playlist',
    );
    expect(playlist.trackIds, ['add-a', 'add-b']);
    expect(playlist.trackIds.where((id) => id == 'add-a'), hasLength(1));
    expect(repository.playlists, hasLength(1));
    expect(repository.localTracks, [first, second]);
    expect(
      find.byKey(const ValueKey('library-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android removes two playlist tracks but preserves library', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final first = _librarySelectionTrack('remove-a', 'Cancion A');
    final second = _librarySelectionTrack('remove-b', 'Cancion B');
    final third = _librarySelectionTrack('remove-c', 'Cancion C');
    final repository = _FakeLibraryRepository()
      ..localTracks.addAll([first, second, third])
      ..playlists.add(
        Playlist(
          id: 'source-playlist',
          name: 'Playlist origen',
          trackIds: [first.id, second.id, third.id],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      );
    final navigationController = LibraryNavigationController()
      ..openPlaylist('source-playlist');
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _libraryPanelTestApp(
        repository: repository,
        navigationController: navigationController,
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await _selectLibraryTracks(tester, ['remove-a', 'remove-c']);

    await tester.tap(
      find.byKey(const ValueKey('library-selection-remove-from-playlist')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(repository.localTracks, [first, second, third]);
    await tester.tap(find.widgetWithText(FilledButton, 'Quitar de playlist'));
    await tester.pumpAndSettle();

    final playlist = repository.playlists.singleWhere(
      (entry) => entry.id == 'source-playlist',
    );
    expect(playlist.trackIds, ['remove-b']);
    expect(repository.localTracks, [first, second, third]);
    expect(find.byKey(const ValueKey('library-track-remove-a')), findsNothing);
    expect(
      find.byKey(const ValueKey('library-track-remove-b')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('library-track-remove-c')), findsNothing);
    expect(
      find.byKey(const ValueKey('library-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('android batch delete cleans library and preserves shared files', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    final directory = io.Directory.systemTemp.createTempSync(
      'bstream-library-selection-',
    );
    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      for (var attempt = 0; attempt < 5 && directory.existsSync(); attempt++) {
        try {
          directory.deleteSync(recursive: true);
        } on io.FileSystemException {
          if (attempt == 4) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      }
    });
    final sharedAudio = io.File(p.join(directory.path, 'shared.m4a'));
    final sharedThumbnail = io.File(p.join(directory.path, 'shared.jpg'));
    final uniqueAudio = io.File(p.join(directory.path, 'unique.m4a'));
    final uniqueThumbnailPath = p.join(directory.path, 'unique-not-loaded.jpg');
    for (final file in [sharedAudio, uniqueAudio]) {
      file.writeAsBytesSync(const [1, 2, 3], flush: true);
    }
    sharedThumbnail.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
      flush: true,
    );
    final first = _librarySelectionTrack(
      'delete-a',
      'Cancion A',
      filePath: sharedAudio.path,
      thumbnailPath: sharedThumbnail.path,
    );
    final second = _librarySelectionTrack(
      'delete-b',
      'Cancion B',
      filePath: uniqueAudio.path,
      thumbnailPath: uniqueThumbnailPath,
    );
    final survivor = _librarySelectionTrack(
      'delete-c',
      'Cancion C',
      filePath: sharedAudio.path,
      thumbnailPath: sharedThumbnail.path,
    );
    final repository = _FakeLibraryRepository()
      ..localTracks.addAll([first, second, survivor])
      ..history.addAll([first, second, survivor])
      ..playlists.addAll([
        Playlist(
          id: 'delete-playlist',
          name: 'Playlist para borrar',
          trackIds: [first.id, second.id, survivor.id],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        Playlist(
          id: Playlist.favoritesId,
          name: 'Favoritos',
          trackIds: [first.id, second.id, survivor.id],
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ]);

    await tester.pumpWidget(_libraryPanelTestApp(repository: repository));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Canciones descargadas'));
    await tester.pump(const Duration(milliseconds: 500));
    await _selectLibraryTracks(tester, ['delete-a', 'delete-b']);

    await tester.tap(find.byKey(const ValueKey('library-selection-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(repository.localTracks, [first, second, survivor]);
    expect(sharedAudio.existsSync(), isTrue);
    expect(uniqueAudio.existsSync(), isTrue);

    await tester.tap(find.widgetWithText(FilledButton, 'Eliminar'));
    await tester.pump();
    // The delete helper deliberately waits for a frame so FileImage listeners
    // are released before Windows unlinks local artwork.
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 100 &&
          find
              .byKey(const ValueKey('library-selection-toolbar'))
              .evaluate()
              .isNotEmpty;
      attempt++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
    }
    await tester.pumpAndSettle();

    expect(repository.localTracks, [survivor]);
    expect(repository.history, [survivor]);
    for (final playlist in repository.playlists) {
      expect(playlist.trackIds, ['delete-c']);
    }
    expect(sharedAudio.existsSync(), isTrue);
    expect(sharedThumbnail.existsSync(), isTrue);
    expect(uniqueAudio.existsSync(), isFalse);
    expect(io.File(uniqueThumbnailPath).existsSync(), isFalse);
    expect(
      find.byKey(const ValueKey('library-track-delete-c')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('library-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('player controls fit on narrow mobile viewports', (tester) async {
    const expectedProgressColor = Color(0xFF7B8DFF);
    const selectedAccent = Color(0xFF3D8BFF);
    final settingsController = _FakeSettingsController(
      const SettingsState(
        downloadDirectory: '/tmp/bstream',
        language: AppLanguage.spanish,
        accent: AppAccent.blue,
      ),
    );
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
        settingsController: settingsController,
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

    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
    );
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
    final playerTheme = Theme.of(playerContext);
    final playerTabTitle = tester.widget<Text>(
      find.byKey(const ValueKey('player-tab-title')),
    );
    expect(playerTabTitle.style?.color, playerTheme.colorScheme.onSurface);
    final trackTitle = tester.widget<Text>(
      find.byKey(const ValueKey('player-track-title')),
    );
    expect(trackTitle.style?.color, AppColors.playbackTitleFor(playerContext));
    expect(trackTitle.style?.color, isNot(playerTheme.colorScheme.onSurface));
    final trackArtist = tester.widget<Text>(
      find.byKey(const ValueKey('player-track-artist')),
    );
    expect(
      trackArtist.style?.color,
      AppColors.contentSubtitleFor(playerContext),
    );
    expect(
      trackArtist.style?.color,
      isNot(playerTheme.colorScheme.onSurfaceVariant),
    );
    expect(
      playerControl.style?.foregroundColor?.resolve(<WidgetState>{}),
      playerTheme.colorScheme.onPrimary,
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
    final lyricsButton = tester.widget<TextButton>(
      find.descendant(of: lyricsControl, matching: find.byType(TextButton)),
    );
    expect(
      lyricsButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      AppColors.playbackControlForegroundFor(playerContext),
    );
    expect(
      lyricsButton.style?.foregroundColor?.resolve(<WidgetState>{}),
      isNot(playerTheme.colorScheme.onSurface),
    );
    expect(
      tester.getCenter(lyricsControl).dx,
      lessThan(
        tester
            .getCenter(find.byKey(const ValueKey('player-primary-control')))
            .dx,
      ),
    );
    expect(
      tester.getCenter(lyricsControl).dy,
      greaterThan(tester.getCenter(shuffleControl).dy),
    );
    expect(
      tester.getSize(lyricsControl).width,
      greaterThan(tester.getSize(shuffleControl).width),
    );
    expect(
      tester.getCenter(shuffleControl).dx,
      lessThan(tester.getCenter(repeatControl).dx),
    );
    expect(
      tester.getCenter(volumeControl).dx,
      greaterThan(
        tester
            .getCenter(find.byKey(const ValueKey('player-primary-control')))
            .dx,
      ),
    );
    expect(
      tester.getCenter(volumeControl).dy,
      greaterThan(tester.getCenter(repeatControl).dy),
    );
    expect(
      tester.getSize(volumeControl).width,
      greaterThan(tester.getSize(repeatControl).width),
    );
    expect(
      find.descendant(of: lyricsControl, matching: find.text('Letras')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: volumeControl, matching: find.text('Volumen')),
      findsOneWidget,
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
    final popoverTitle = tester.widget<Text>(
      find.descendant(of: popover, matching: find.text('Volumen')),
    );
    expect(
      popoverTitle.style?.color,
      AppColors.menuForegroundFor(popoverContext),
    );

    final sliderTheme = tester.widget<SliderTheme>(
      find.descendant(of: popover, matching: find.byType(SliderTheme)),
    );
    expect(sliderTheme.data.activeTrackColor, selectedAccent);
    expect(sliderTheme.data.thumbColor, selectedAccent);
    expect(
      sliderTheme.data.overlayColor,
      selectedAccent.withValues(alpha: 0.14),
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
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final lyricsControl = find.byKey(const ValueKey('player-lyrics-control'));
    final lyricsButton = find.descendant(
      of: lyricsControl,
      matching: find.byType(TextButton),
    );
    await tester.ensureVisible(lyricsControl);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<TextButton>(lyricsButton).onPressed, isNotNull);
    await tester.tap(lyricsButton);
    // The synchronized lyrics page intentionally keeps an animation/ticker
    // alive while playback advances, so pumpAndSettle would never be a valid
    // completion signal here.
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find
          .byKey(const ValueKey('synced-lyrics-scroll'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

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

  testWidgets('player title heart toggles the current local track favorite', (
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

    final favoriteControl = find.byKey(
      const ValueKey('player-favorite-control'),
    );
    expect(favoriteControl, findsOneWidget);
    expect(
      find.descendant(
        of: favoriteControl,
        matching: find.byIcon(Icons.favorite_border_rounded),
      ),
      findsOneWidget,
    );
    expect(
      tester.getCenter(favoriteControl).dx,
      greaterThan(
        tester.getCenter(find.byKey(const ValueKey('player-track-title'))).dx,
      ),
    );

    await tester.tap(favoriteControl);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      repository.playlists.last.trackIds,
      contains('favorite-player-track'),
    );
    final filledHeart = tester.widget<Icon>(
      find.descendant(
        of: favoriteControl,
        matching: find.byIcon(Icons.favorite_rounded),
      ),
    );
    final favoriteButton = tester.widget<IconButton>(favoriteControl);
    expect(
      favoriteButton.color,
      Theme.of(tester.element(favoriteControl)).colorScheme.primary,
    );
    expect(filledHeart.icon, Icons.favorite_rounded);

    await tester.tap(favoriteControl);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      repository.playlists.last.trackIds,
      isNot(contains('favorite-player-track')),
    );
  });

  testWidgets(
    'windows desktop player stacks artwork and exposes volume control',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
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
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
      );
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

      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
    skip: !io.Platform.isWindows,
  );

  testWidgets(
    'desktop playback queue fits minimum window and changes selected song',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 600);
      addTearDown(() {
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
      expect(tester.takeException(), isNull);

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
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(520, 720);
      addTearDown(() {
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
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('mini-player-metadata'))),
      );
      await tester.pump(const Duration(milliseconds: 500));

      for (final width in const [500.0, 460.0, 430.0, 390.0, 520.0]) {
        tester.view.physicalSize = Size(width, 720);
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(tester.takeException(), isNull);
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

void _noop() {}

void _configureMobileHomeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void _expectLocalOnlyHome(WidgetTester tester) {
  expect(
    find.byWidgetPredicate((widget) {
      final key = widget.key;
      if (key is! ValueKey<String>) {
        return false;
      }
      return key.value.startsWith('home-recommendation-') ||
          key.value.startsWith('home-recommendations-section-') ||
          key.value.startsWith('home-recommendations-shelf-') ||
          key.value.startsWith('home-collection-');
    }),
    findsNothing,
  );
  expect(find.text('Cancion reciente'), findsOneWidget);
  expect(find.text('Playlist de Inicio'), findsOneWidget);
  expect(find.byKey(const ValueKey('home-recent-card')), findsOneWidget);
  expect(find.byKey(const ValueKey('home-playlist-card')), findsOneWidget);
}

LocalTrack _librarySelectionTrack(
  String id,
  String title, {
  String? filePath,
  String? thumbnailPath,
}) {
  return LocalTrack(
    id: id,
    title: title,
    artist: 'BStream Music',
    filePath: filePath ?? p.join(io.Directory.systemTemp.path, '$id.m4a'),
    thumbnailPath: thumbnailPath,
    addedAt: DateTime(2026),
    duration: const Duration(minutes: 3),
  );
}

Future<void> _selectLibraryTracks(
  WidgetTester tester,
  List<String> trackIds,
) async {
  assert(trackIds.isNotEmpty);
  await tester.longPress(
    find.byKey(ValueKey('library-track-${trackIds.first}')),
  );
  await tester.pump(const Duration(milliseconds: 250));
  for (final trackId in trackIds.skip(1)) {
    await tester.tap(find.byKey(ValueKey('library-track-$trackId')));
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Widget _libraryPanelTestApp({
  required _FakeLibraryRepository repository,
  LibraryNavigationController? navigationController,
  VoidCallback? onOpenPlayer,
}) {
  final panel = Scaffold(
    body: LibraryPanel(
      onOpenPlayer: onOpenPlayer ?? _noop,
      navigationController: navigationController,
    ),
  );
  return ProviderScope(
    overrides: [
      downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
      playerServiceProvider.overrideWithValue(_FakePlayerService()),
      libraryRepositoryProvider.overrideWithValue(repository),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      home: navigationController == null
          ? panel
          : PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) {
                  navigationController.maybePop();
                }
              },
              child: panel,
            ),
    ),
  );
}

_FakeLibraryRepository _homeCardsRepository() {
  final repository = _FakeLibraryRepository();
  final track = LocalTrack(
    id: 'home-card-track',
    title: 'Cancion reciente',
    artist: 'BStream Music',
    filePath: r'C:\Music\home-card-track.mp3',
    addedAt: DateTime(2026),
  );
  repository.history.add(track);
  repository.localTracks.add(track);
  repository.playlists.add(
    Playlist(
      id: 'home-card-playlist',
      name: 'Playlist de Inicio',
      trackIds: [track.id],
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  );
  return repository;
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
    child: MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      home: const Scaffold(body: SettingsPanel()),
    ),
  );
}

Widget _testApp({
  SettingsController? settingsController,
  PlayerService? playerService,
  PlayerController? playerController,
  LibraryRepository? libraryRepository,
  LyricsService? lyricsService,
  ArtworkProgressColorService? artworkProgressColorService,
  DownloadDirectoryPicker? directoryPicker,
  FutureOr<List<HomeRecommendationSection>>? homeRecommendations,
  Object? homeRecommendationsError,
  FutureOr<List<HomeRecommendationSection>> Function()?
  homeRecommendationsLoader,
  Future<List<TrackInfo>> Function(String browseId)? homeCollectionLoader,
}) {
  return ProviderScope(
    overrides: [
      if (settingsController != null)
        settingsControllerProvider.overrideWith(() => settingsController),
      downloaderServiceProvider.overrideWithValue(_FakeDownloaderService()),
      desktopMediaSessionFactoryProvider.overrideWithValue(() => null),
      playerServiceProvider.overrideWithValue(
        playerService ?? _FakePlayerService(),
      ),
      if (playerController != null)
        playerControllerProvider.overrideWith(() => playerController),
      homeRecommendationsProvider.overrideWith((ref) {
        final loader = homeRecommendationsLoader;
        if (loader != null) {
          return loader();
        }
        final error = homeRecommendationsError;
        if (error != null) {
          throw error;
        }
        return homeRecommendations ?? const <HomeRecommendationSection>[];
      }),
      if (homeCollectionLoader != null)
        homeCollectionTracksProvider.overrideWith(
          (ref, browseId) => homeCollectionLoader(browseId),
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

class _FakeSearchController extends SearchController {
  _FakeSearchController(this.tracks);

  final List<TrackInfo> tracks;

  @override
  Future<SearchState> build() async => SearchState(
    query: 'resultados',
    pages: <SearchCategory, SearchPage>{
      SearchCategory.songs: SearchPage(
        category: SearchCategory.songs,
        backend: SearchBackend.innerTube,
        tracks: tracks,
      ),
    },
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
    final fileName = '${options.fileName ?? id}.m4a';
    final file = io.File(p.join(options.outputDirectory, fileName));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(const [1, 2, 3], flush: true);
    return DownloadResult(
      id: 'downloaded-$id',
      sourceUrl: url,
      filePath: file.path,
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

class _ControllableLocalTrackDownloadHelper extends LocalTrackDownloadHelper {
  _ControllableLocalTrackDownloadHelper(super.ref, this.downloader);

  final _ControllableDownloaderService downloader;

  @override
  Future<LocalTrackDownloadResult> resolveForLibrary(
    TrackInfo track, {
    String? taskId,
    void Function(TrackInfo track)? onResolved,
    void Function()? onDownloadStarted,
  }) async {
    onResolved?.call(track);
    onDownloadStarted?.call();
    final result = await downloader.downloadAudio(
      track.url,
      DownloadOptions(
        outputDirectory: io.Directory.systemTemp.path,
        fileName: 'progress-track',
        taskId: taskId,
      ),
    );
    final localTrack = LocalTrack(
      id: 'progress-track',
      title: track.title,
      artist: track.artist,
      filePath: result.filePath,
      addedAt: result.completedAt,
      sourceUrl: track.url,
      duration: track.duration,
    );
    return LocalTrackDownloadResult(
      track: localTrack,
      remoteTrack: track,
      reusedExisting: false,
      downloadResult: result,
    );
  }
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
    final file = io.File(p.join(options.outputDirectory, fileName));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(const [1, 2, 3], flush: true);
    _completion.complete(
      DownloadResult(
        id: 'completed-progress-track',
        sourceUrl: url,
        filePath: file.path,
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

class _RecordingHomePlayerController extends PlayerController {
  int remotePlayCalls = 0;
  int historyPlayCalls = 0;
  TrackInfo? lastRemoteTrack;
  List<TrackInfo>? lastRemoteQueue;
  String? lastRemoteQueueSourceId;
  LocalTrack? lastHistoryTrack;
  List<LocalTrack>? lastHistoryQueue;

  @override
  Future<PlayerSnapshot> build() async {
    return const PlayerSnapshot(status: PlayerStatus.idle);
  }

  @override
  Future<void> playRemote(
    TrackInfo track, {
    List<TrackInfo>? queue,
    String? queueSourceId,
  }) async {
    remotePlayCalls++;
    lastRemoteTrack = track;
    lastRemoteQueue = queue == null ? null : List.unmodifiable(queue);
    lastRemoteQueueSourceId = queueSourceId;
    state = AsyncData(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.url,
        duration: track.duration,
        isRemote: true,
      ),
    );
  }

  @override
  Future<void> playFromHistory(
    LocalTrack track, {
    List<LocalTrack>? fallbackQueue,
  }) async {
    historyPlayCalls++;
    lastHistoryTrack = track;
    lastHistoryQueue = fallbackQueue == null
        ? null
        : List.unmodifiable(fallbackQueue);
    state = AsyncData(
      PlayerSnapshot(
        status: PlayerStatus.playing,
        title: track.title,
        artist: track.artist,
        trackId: track.id,
        sourceUrl: track.filePath,
        duration: track.duration,
      ),
    );
  }
}

class _FakeLibraryRepository implements LibraryRepository {
  final List<LocalTrack> history = [];
  final List<LocalTrack> localTracks = [];
  final List<Playlist> playlists = [];

  @override
  Future<void> deleteLocalTrack(String trackId) async {
    localTracks.removeWhere((track) => track.id == trackId);
    history.removeWhere((track) => track.id == trackId);
  }

  @override
  Future<Set<String>> purgeMissingLocalTracks(List<LocalTrack> tracks) async {
    final removedIds = <String>{};
    for (final candidate in tracks) {
      final matches = localTracks.any(
        (track) =>
            track.id == candidate.id && track.filePath == candidate.filePath,
      );
      if (matches) {
        removedIds.add(candidate.id);
      }
    }
    if (removedIds.isEmpty) {
      return const <String>{};
    }

    localTracks.removeWhere((track) => removedIds.contains(track.id));
    history.removeWhere((track) => removedIds.contains(track.id));
    for (var index = 0; index < playlists.length; index++) {
      final playlist = playlists[index];
      playlists[index] = playlist.copyWith(
        trackIds: playlist.trackIds
            .where((id) => !removedIds.contains(id))
            .toList(growable: false),
      );
    }
    return Set.unmodifiable(removedIds);
  }

  @override
  Future<void> deletePlaylist(String playlistId) async {
    playlists.removeWhere((playlist) => playlist.id == playlistId);
  }

  @override
  Future<List<LocalTrack>> getHistory() async => List.unmodifiable(history);

  @override
  Future<List<LocalTrack>> getLocalTracks() async =>
      List.unmodifiable(localTracks);

  @override
  Future<List<Playlist>> getPlaylists() async => List.unmodifiable(playlists);

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
    final index = playlists.indexWhere((entry) => entry.id == playlist.id);
    if (index < 0) {
      playlists.add(playlist);
    } else {
      playlists[index] = playlist;
    }
  }
}
