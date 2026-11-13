import 'dart:async';

import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/presentation/pages/remote_collection_detail_page.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/artwork_detail_scaffold.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_picker_dialog.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';

void main() {
  testWidgets(
    'album selection adds only marked songs and survives picker cancellation',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final player = _RecordingPlayerController();
      final playlists = _PickerPlaylistsController();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playlistsControllerProvider.overrideWith(() => playlists),
            libraryTracksProvider.overrideWith((ref) async => []),
            catalogPlaylistsProvider.overrideWith((ref) async => []),
          ],
          child: _detailApp(
            player: player,
            tracksProvider: FutureProvider((ref) async => _tracks),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Primera cancion'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('collection-selection-toolbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('track-result-play-song-1')),
        findsNothing,
      );
      await tester.tap(find.text('Segunda cancion'));
      await tester.pumpAndSettle();
      final checkboxes = tester.widgetList<Checkbox>(find.byType(Checkbox));
      expect(checkboxes.every((checkbox) => checkbox.value == true), isTrue);
      await tester.tap(find.text('Primera cancion'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('collection-selection-add-to-playlist')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('playlist-picker-create')),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('collection-selection-toolbar')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('track-result-selection-song-2')),
            )
            .value,
        isTrue,
      );
      await tester.tap(
        find.byKey(const ValueKey('collection-selection-add-to-playlist')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('playlist-picker-option-existing')),
      );
      await tester.pumpAndSettle();
      expect(playlists.receivedTracks, [_tracks.last]);
      expect(playlists.download, isFalse);
      expect(player.playCalls, 0);
      expect(
        find.byKey(const ValueKey('collection-selection-toolbar')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mix selection downloads only selected audio using the shared queue',
    (tester) async {
      final downloads = _SelectedDownloads();
      final player = _RecordingPlayerController();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [downloadControllerProvider.overrideWith(() => downloads)],
          child: _detailApp(
            player: player,
            subtitle: 'Mix recomendado',
            tracksProvider: FutureProvider((ref) async => _tracks),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Segunda cancion'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('collection-selection-download')),
      );
      await tester.pumpAndSettle();
      expect(downloads.tracks, [_tracks.last]);
      expect(player.playCalls, 0);
      expect(
        find.byKey(const ValueKey('collection-selection-toolbar')),
        findsNothing,
      );
    },
  );

  testWidgets('Back clears collection selection without leaving the detail', (
    tester,
  ) async {
    await tester.pumpWidget(
      _detailApp(
        player: _RecordingPlayerController(),
        tracksProvider: FutureProvider((ref) async => _tracks),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Primera cancion'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('collection-selection-toolbar')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsOneWidget,
    );
  });

  testWidgets(
    'albums expose the existing-playlist picker and plus without a callback',
    (tester) async {
      final controller = _PickerPlaylistsController();
      final tracksProvider = FutureProvider<List<TrackInfo>>(
        (ref) async => _tracks,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playlistsControllerProvider.overrideWith(() => controller),
            libraryTracksProvider.overrideWith((ref) async => []),
            catalogPlaylistsProvider.overrideWith((ref) async => []),
          ],
          child: _detailApp(
            player: _RecordingPlayerController(),
            tracksProvider: tracksProvider,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('remote-collection-add-to-playlist')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('playlist-picker-create')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('playlist-picker-option-existing')),
      );
      await tester.pumpAndSettle();
      expect(controller.destination, 'existing');
      expect(controller.receivedTracks, _tracks);
      expect(controller.download, isFalse);
    },
  );

  testWidgets('create playlist dialog prefills, edits and cancels safely', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              await showDialog<String>(
                context: context,
                builder: (_) => const CreatePlaylistDialog(
                  strings: AppStrings(AppLanguage.spanish),
                  initialName: 'Album de contrato',
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('create-playlist-name')),
    );
    expect(field.controller!.text, 'Album de contrato');

    await tester.enterText(
      find.byKey(const ValueKey('create-playlist-name')),
      'Mi colección',
    );
    await tester.tap(find.byKey(const ValueKey('create-playlist-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('create-playlist-name')), findsNothing);
  });

  testWidgets(
    'renders collection metadata and tracks without starting playback',
    (tester) async {
      final player = _RecordingPlayerController();
      var playerOpens = 0;
      final pendingTracks = Completer<List<TrackInfo>>();
      final tracksProvider = FutureProvider<List<TrackInfo>>(
        (ref) => pendingTracks.future,
        retry: (_, _) => null,
      );

      await tester.pumpWidget(
        _detailApp(
          player: player,
          tracksProvider: tracksProvider,
          onOpenPlayer: () => playerOpens++,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('remote-collection-loading')),
        findsOneWidget,
      );
      expect(player.playCalls, 0);
      expect(playerOpens, 0);

      pendingTracks.complete(_tracks);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('remote-collection-detail')),
        findsOneWidget,
      );
      expect(find.text('Album de contrato'), findsOneWidget);
      expect(find.text('Artista principal'), findsOneWidget);
      expect(find.textContaining('Album'), findsWidgets);
      expect(find.textContaining('2026'), findsOneWidget);
      expect(find.textContaining('2 canciones'), findsOneWidget);
      expect(find.text('Primera cancion'), findsOneWidget);
      expect(find.text('Segunda cancion'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('remote-collection-mini-player')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('track-result-play-song-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('track-result-play-song-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('track-result-menu-song-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('track-result-menu-song-2')),
        findsOneWidget,
      );
      expect(player.playCalls, 0);
      expect(playerOpens, 0);

      await tester.tap(find.byKey(const ValueKey('track-result-menu-song-1')));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
      expect(
        find.descendant(
          of: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
          matching: find.byIcon(Icons.playlist_add_rounded),
        ),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('remote-collection-play')));
      await tester.pump();

      expect(player.playCalls, 1);
      expect(player.lastTrack, same(_tracks.first));
      expect(player.lastQueue, _tracks);
      expect(player.lastQueueSourceId, 'album:MPRE-contract');
      expect(playerOpens, 1);
    },
  );

  testWidgets('the row Play button uses the owned collection queue', (
    tester,
  ) async {
    final player = _RecordingPlayerController();
    var playerOpens = 0;
    final tracksProvider = FutureProvider<List<TrackInfo>>(
      (ref) async => _tracks,
      retry: (_, _) => null,
    );

    await tester.pumpWidget(
      _detailApp(
        player: player,
        tracksProvider: tracksProvider,
        onOpenPlayer: () => playerOpens++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('track-result-play-song-2')));
    await tester.pump();

    expect(player.playCalls, 1);
    expect(player.lastTrack, same(_tracks[1]));
    expect(player.lastQueue, _tracks);
    expect(player.lastQueueSourceId, 'album:MPRE-contract');
    expect(playerOpens, 0);
  });

  for (final playFromRow in [false, true]) {
    testWidgets(
      'album cover reaches playback and every queued song (row=$playFromRow)',
      (tester) async {
        tester.view.physicalSize = const Size(360, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const albumCover = 'https://lh3.googleusercontent.com/album-cover=w512';
        final tracks = <TrackInfo>[
          _tracks.first.copyWith(
            thumbnailUrl: 'https://i.ytimg.com/vi/firstsong01/hqdefault.jpg',
            catalogThumbnailUrl:
                'https://lh3.googleusercontent.com/other-release=w120',
          ),
          _tracks.last,
        ];
        final player = _RecordingPlayerController();
        await tester.pumpWidget(
          _detailApp(
            player: player,
            tracksProvider: FutureProvider((ref) async => tracks),
            artworkSource: albumCover,
            preferCollectionArtworkForTracks: true,
          ),
        );
        await tester.pumpAndSettle();
        final action = find.byKey(
          ValueKey(
            playFromRow ? 'track-result-play-song-2' : 'remote-collection-play',
          ),
        );
        await tester.ensureVisible(action);
        await tester.tap(action);
        await tester.pump();

        expect(
          player.lastTrack!.id,
          playFromRow ? tracks.last.id : tracks.first.id,
        );
        expect(player.lastTrack!.thumbnailUrl, albumCover);
        expect(player.lastTrack!.catalogThumbnailUrl, albumCover);
        expect(player.lastQueue!.map((track) => track.thumbnailUrl), [
          albumCover,
          albumCover,
        ]);
        expect(player.lastQueue!.map((track) => track.catalogThumbnailUrl), [
          albumCover,
          albumCover,
        ]);
        expect(
          player.lastQueue!.every(
            (track) => track.metadataSource == TrackMetadataSource.youtubeMusic,
          ),
          isTrue,
        );
        expect(tracks.first.thumbnailUrl, contains('i.ytimg.com'));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'mix playback retains per-song artwork despite a collection cover',
    (tester) async {
      final tracks = _tracks
          .map(
            (track) => track.copyWith(
              thumbnailUrl: 'https://i.ytimg.com/vi/${track.id}/hqdefault.jpg',
              catalogThumbnailUrl:
                  'https://lh3.googleusercontent.com/${track.id}=w512',
            ),
          )
          .toList();
      final player = _RecordingPlayerController();
      await tester.pumpWidget(
        _detailApp(
          player: player,
          tracksProvider: FutureProvider((ref) async => tracks),
          artworkSource: 'https://lh3.googleusercontent.com/mix-cover=w512',
        ),
      );
      await tester.pumpAndSettle();
      final action = find.byKey(const ValueKey('remote-collection-play'));
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pump();
      expect(player.lastTrack, same(tracks.first));
      expect(player.lastQueue!.first, same(tracks.first));
      expect(player.lastQueue!.last, same(tracks.last));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mini player stays above gesture and three-button navigation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final tracksProvider = FutureProvider<List<TrackInfo>>(
      (ref) async => _tracks,
      retry: (_, _) => null,
    );

    for (final bottomInset in [0.0, 24.0]) {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(360, 800),
            devicePixelRatio: 1,
            padding: EdgeInsets.only(bottom: bottomInset),
            viewPadding: EdgeInsets.only(bottom: bottomInset),
          ),
          child: _detailApp(
            player: _RecordingPlayerController(),
            tracksProvider: tracksProvider,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final mini = tester.getRect(
        find.byKey(const ValueKey('remote-collection-mini-player')),
      );
      final miniPlayer = tester.getRect(
        find.byKey(const ValueKey('mini-player-container')),
      );
      expect(mini.bottom, 800);
      expect(miniPlayer.bottom, 800 - bottomInset);
      expect(
        miniPlayer.height,
        miniPlayerHeightFor(
          tester.element(find.byKey(const ValueKey('mini-player-container'))),
          mode: defaultMiniPlayerMode,
        ),
      );
      final spacer = tester.getSize(
        find.byKey(const ValueKey('remote-collection-bottom-spacer')),
      );
      expect(
        spacer.height,
        miniPlayerHeightFor(
              tester.element(
                find.byKey(const ValueKey('mini-player-container')),
              ),
              mode: defaultMiniPlayerMode,
            ) +
            bottomInset +
            24,
      );
    }
  });

  testWidgets('last collection track scrolls above the floating mini player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final tracks = <TrackInfo>[
      for (var index = 1; index <= 12; index++)
        TrackInfo(
          id: 'long-song-$index',
          title: 'Cancion $index',
          artist: 'Artista principal',
          url: 'https://www.youtube.com/watch?v=long-song-$index',
        ),
    ];
    final tracksProvider = FutureProvider<List<TrackInfo>>(
      (ref) async => tracks,
      retry: (_, _) => null,
    );

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 640),
          devicePixelRatio: 1,
          padding: EdgeInsets.only(bottom: 24),
          viewPadding: EdgeInsets.only(bottom: 24),
        ),
        child: _detailApp(
          player: _RecordingPlayerController(),
          tracksProvider: tracksProvider,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scroll = find.byType(CustomScrollView);
    await tester.drag(scroll, const Offset(0, -3000));
    await tester.pumpAndSettle();

    final lastTrack = find.byKey(
      const ValueKey('remote-collection-track-long-song-12'),
    );
    final miniPlayer = find.byKey(const ValueKey('mini-player-container'));
    expect(lastTrack, findsOneWidget);
    expect(
      tester.getRect(lastTrack).bottom,
      lessThanOrEqualTo(tester.getRect(miniPlayer).top - 20),
    );
  });

  testWidgets('collection header exposes Add to playlist for link imports', (
    tester,
  ) async {
    var addedTracks = <TrackInfo>[];
    String? receivedPlaylistName;
    final tracksProvider = FutureProvider<List<TrackInfo>>(
      (ref) async => _tracks,
      retry: (_, _) => null,
    );

    await tester.pumpWidget(
      _detailApp(
        player: _RecordingPlayerController(),
        tracksProvider: tracksProvider,
        onAddToPlaylist: (context, tracks, {initialPlaylistName}) async {
          addedTracks = tracks;
          receivedPlaylistName = initialPlaylistName;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('remote-collection-add-to-playlist')),
    );
    await tester.pump();
    expect(addedTracks, _tracks);
    expect(receivedPlaylistName, 'Album de contrato');
  });

  testWidgets(
    'tapping one track starts at it with the complete displayed queue',
    (tester) async {
      final player = _RecordingPlayerController();
      var playerOpens = 0;
      final tracksProvider = FutureProvider<List<TrackInfo>>(
        (ref) async => _tracks,
        retry: (_, _) => null,
      );

      await tester.pumpWidget(
        _detailApp(
          player: player,
          tracksProvider: tracksProvider,
          onOpenPlayer: () => playerOpens++,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('remote-collection-track-song-2')),
      );
      await tester.pump();

      expect(player.playCalls, 1);
      expect(player.lastTrack, same(_tracks[1]));
      expect(player.lastQueue, _tracks);
      expect(player.lastQueueSourceId, 'album:MPRE-contract');
      expect(playerOpens, 1);
    },
  );

  testWidgets('shows a load error and retries the failed provider explicitly', (
    tester,
  ) async {
    final player = _RecordingPlayerController();
    var loads = 0;
    final tracksProvider = FutureProvider<List<TrackInfo>>((ref) async {
      loads++;
      if (loads == 1) {
        throw StateError('temporary catalog failure');
      }
      return _tracks;
    }, retry: (_, _) => null);

    await tester.pumpWidget(
      _detailApp(player: player, tracksProvider: tracksProvider),
    );
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(
      find.byKey(const ValueKey('remote-collection-error')),
      findsOneWidget,
    );
    expect(find.text('No se pudo cargar la coleccion.'), findsOneWidget);
    expect(find.text('Album de contrato'), findsOneWidget);
    expect(player.playCalls, 0);

    await tester.tap(find.byKey(const ValueKey('remote-collection-retry')));
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.byKey(const ValueKey('remote-collection-error')), findsNothing);
    expect(find.text('Primera cancion'), findsOneWidget);
    expect(player.playCalls, 0);
  });

  testWidgets('an empty collection keeps playback disabled', (tester) async {
    final player = _RecordingPlayerController();
    final tracksProvider = FutureProvider<List<TrackInfo>>(
      (ref) async => const [],
      retry: (_, _) => null,
    );

    await tester.pumpWidget(
      _detailApp(player: player, tracksProvider: tracksProvider),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-collection-empty')),
      findsOneWidget,
    );
    expect(find.text('La coleccion esta vacia.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('remote-collection-play')),
          )
          .onPressed,
      isNull,
    );
    expect(player.playCalls, 0);
  });

  testWidgets('keeps the circular back button pinned above scrolling artwork', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
    });
    final tracksProvider = FutureProvider<List<TrackInfo>>(
      (ref) async => List.generate(
        12,
        (index) => _tracks[index % _tracks.length].copyWith(
          id: 'scroll-song-$index',
          title: 'Cancion desplazable $index',
          url: 'https://www.youtube.com/watch?v=scrollid$index',
        ),
      ),
      retry: (_, _) => null,
    );
    await tester.pumpWidget(
      _detailApp(
        player: _RecordingPlayerController(),
        tracksProvider: tracksProvider,
      ),
    );
    await tester.pumpAndSettle();

    final back = find.byKey(const ValueKey('remote-collection-back'));
    final initialBackRect = tester.getRect(back);
    final header = find.byKey(const ValueKey('remote-collection-header'));
    final initialHeaderRect = tester.getRect(header);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Album de contrato'), findsOneWidget);
    expect(initialHeaderRect.top, 0);
    expect(initialBackRect.size, const Size(48, 48));
    expect(initialBackRect.top, greaterThanOrEqualTo(24));
    expect(
      tester
          .getRect(find.byKey(const ValueKey('remote-collection-artwork')))
          .top,
      36,
      reason:
          'The cover starts below the system inset without reserving a title bar.',
    );
    final button = tester.widget<IconButton>(back);
    expect(
      button.style!.shape!.resolve(const <WidgetState>{}),
      isA<CircleBorder>(),
    );
    expect(back.hitTestable(), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      greaterThan(0),
    );
    expect(tester.getRect(back), initialBackRect);
    expect(tester.getRect(header).top, lessThan(initialHeaderRect.top));
    expect(back.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final mode in SurfaceBackgroundMode.values) {
      testWidgets(
        'collection artwork extends under transparent system bars for $brightness/$mode',
        (tester) async {
          tester.view.physicalSize = const Size(360, 640);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 24);
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetPadding();
          });
          await tester.pumpWidget(
            _detailApp(
              player: _RecordingPlayerController(),
              tracksProvider: FutureProvider((ref) async => _tracks),
              surfaceBackgroundMode: mode,
              brightness: brightness,
              artworkSource: 'https://img.test/collection.jpg',
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AppBar), findsNothing);
          expect(
            find.byKey(const ValueKey('remote-collection-app-bar-spacer')),
            findsNothing,
          );
          final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.descendant(
              of: find.byType(ArtworkDetailScaffold),
              matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
            ),
          );
          expect(region.value.statusBarColor, Colors.transparent);
          expect(region.value.systemStatusBarContrastEnforced, isFalse);
          expect(
            region.value.statusBarIconBrightness,
            brightness == Brightness.dark ? Brightness.light : Brightness.dark,
          );
          final background = find.byKey(
            const ValueKey('remote-collection-background-photo'),
          );
          expect(tester.getRect(background).top, 0);
          expect(
            tester
                .getRect(
                  find.byKey(
                    const ValueKey('remote-collection-artwork-underlay'),
                  ),
                )
                .top,
            0,
          );
          final back = find.byKey(const ValueKey('remote-collection-back'));
          expect(tester.getRect(back).top, greaterThanOrEqualTo(24));
          expect(back.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('circular close clears selection while keeping the detail open', (
    tester,
  ) async {
    await tester.pumpWidget(
      _detailApp(
        player: _RecordingPlayerController(),
        tracksProvider: FutureProvider((ref) async => _tracks),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Primera cancion'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('collection-selection-toolbar')),
      findsOneWidget,
    );
    final close = find.byKey(const ValueKey('collection-selection-close'));
    expect(tester.getSize(close), const Size(48, 48));
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('collection-selection-toolbar')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('remote-collection-back')),
      findsOneWidget,
    );
    expect(find.text('Album de contrato'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('circular back returns to the previous route', (tester) async {
    await tester.pumpWidget(
      _detailApp(
        player: _RecordingPlayerController(),
        tracksProvider: FutureProvider((ref) async => _tracks),
        openFromLauncher: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abrir coleccion'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('remote-collection-back')));
    await tester.pumpAndSettle();
    expect(find.text('Abrir coleccion'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reuses the bounded artwork decode for the blurred header background',
    (tester) async {
      final tracksProvider = FutureProvider<List<TrackInfo>>(
        (ref) async => _tracks,
        retry: (_, _) => null,
      );

      await tester.pumpWidget(
        _detailApp(
          player: _RecordingPlayerController(),
          tracksProvider: tracksProvider,
          artworkSource: 'https://i.ytimg.com/vi/firstsong01/hqdefault.jpg',
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('remote-collection-background-blur')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('remote-collection-background-overlay')),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('remote-collection-background-blur')),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
      final overlay = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('remote-collection-background-overlay')),
      );
      final overlayGradient =
          (overlay.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(overlayGradient.colors.last.a, greaterThan(0.9));
      final background = tester.widget<SourceImage>(
        find.byKey(const ValueKey('remote-collection-background-image')),
      );
      final header = find.byKey(const ValueKey('remote-collection-header'));
      final photo = find.byKey(
        const ValueKey('remote-collection-background-photo'),
      );
      expect(find.descendant(of: header, matching: photo), findsOneWidget);
      expect(tester.getRect(photo), tester.getRect(header));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('remote-collection-artwork-underlay')),
          matching: find.byType(SourceImage),
        ),
        findsNothing,
        reason: 'The album or mix list inherits color without a cover image.',
      );
      final foreground = tester.widget<ProportionalArtwork>(
        find.descendant(
          of: find.byKey(const ValueKey('remote-collection-artwork')),
          matching: find.byType(ProportionalArtwork),
        ),
      );
      expect(background.cacheWidth, foreground.cacheWidth);
      expect(background.cacheWidth, lessThanOrEqualTo(640));
    },
  );

  testWidgets('uses the lightweight gradient fallback without artwork', (
    tester,
  ) async {
    final tracksProvider = FutureProvider<List<TrackInfo>>(
      (ref) async => _tracks,
      retry: (_, _) => null,
    );

    await tester.pumpWidget(
      _detailApp(
        player: _RecordingPlayerController(),
        tracksProvider: tracksProvider,
        artworkSource: '   ',
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-collection-background-fallback')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('remote-collection-background-blur')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('remote-collection-background-image')),
      findsNothing,
    );
  });

  testWidgets('keeps artist and duration in one compact subtitle', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    const track = TrackInfo(
      id: 'long-artist',
      title: 'Canción con muchos colaboradores',
      artist:
          'Primer artista, Segundo artista, Tercer artista y Cuarto artista',
      duration: Duration(hours: 1, minutes: 2, seconds: 3),
      url: 'https://www.youtube.com/watch?v=longartist1',
    );
    final tracksProvider = FutureProvider<List<TrackInfo>>(
      (ref) async => const <TrackInfo>[track],
      retry: (_, _) => null,
    );

    await tester.pumpWidget(
      _detailApp(
        player: _RecordingPlayerController(),
        tracksProvider: tracksProvider,
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('remote-collection-track-long-artist')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Primer artista, Segundo artista, Tercer artista y Cuarto artista'
        '  -  1:02:03',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('stays usable at 320x568 with text scale 3', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final tracksProvider = FutureProvider<List<TrackInfo>>(
      (ref) async => _tracks,
      retry: (_, _) => null,
    );

    await tester.pumpWidget(
      _detailApp(
        player: _RecordingPlayerController(),
        tracksProvider: tracksProvider,
        title:
            'Un titulo de album deliberadamente largo para una pantalla pequena',
        subtitle: 'Artista principal con invitados y un nombre extenso',
        metadata: const ['Album de estudio', '2026', 'Alta resolucion'],
        artworkSource: 'https://i.ytimg.com/vi/firstsong01/hqdefault.jpg',
        disableAnimations: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsOneWidget,
    );
    final background = tester.widget<SourceImage>(
      find.byKey(const ValueKey('remote-collection-background-image')),
    );
    expect(background.cacheWidth, 512);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('remote-collection-header')),
        matching: find.byType(AnimatedSwitcher),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('remote-collection-back')))
          .height,
      greaterThanOrEqualTo(48),
    );

    final trackTile = find.byKey(
      const ValueKey('remote-collection-track-song-1'),
    );
    await tester.scrollUntilVisible(
      trackTile,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(trackTile, findsOneWidget);
    expect(tester.getRect(trackTile).height, greaterThanOrEqualTo(48));
    final playButton = find.byKey(const ValueKey('track-result-play-song-1'));
    final menuButton = find.byKey(const ValueKey('track-result-menu-song-1'));
    expect(playButton, findsOneWidget);
    expect(menuButton, findsOneWidget);
    expect(tester.getRect(playButton).shortestSide, greaterThanOrEqualTo(48));
    // The menu keeps a 48dp vertical touch target while remaining visually
    // narrow like the other playlist/result cards.
    expect(tester.getRect(menuButton).height, greaterThanOrEqualTo(48));
    expect(tester.getRect(menuButton).width, greaterThanOrEqualTo(36));
    expect(tester.takeException(), isNull);
  });
}

Widget _detailApp({
  required _RecordingPlayerController player,
  required FutureProvider<List<TrackInfo>> tracksProvider,
  VoidCallback? onOpenPlayer,
  AddRemoteTracksToPlaylist? onAddToPlaylist,
  String title = 'Album de contrato',
  String subtitle = 'Artista principal',
  List<String> metadata = const ['Album', '2026'],
  String? artworkSource,
  bool preferCollectionArtworkForTracks = false,
  bool disableAnimations = false,
  bool openFromLauncher = false,
  Brightness brightness = Brightness.light,
  SurfaceBackgroundMode surfaceBackgroundMode = SurfaceBackgroundMode.accent,
}) {
  final detailPage = RemoteCollectionDetailPage(
    title: title,
    subtitle: subtitle,
    artworkSource: artworkSource,
    preferCollectionArtworkForTracks: preferCollectionArtworkForTracks,
    queueSourceId: 'album:MPRE-contract',
    tracksProvider: tracksProvider,
    emptyMessage: 'La coleccion esta vacia.',
    errorMessage: 'No se pudo cargar la coleccion.',
    onOpenPlayer: onOpenPlayer ?? _noop,
    onAddToPlaylist: onAddToPlaylist,
    metadata: metadata,
  );
  return ProviderScope(
    overrides: [
      playerControllerProvider.overrideWith(() => player),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        brightness: brightness,
        extensions: [AppSurfaceTheme(backgroundMode: surfaceBackgroundMode)],
      ),
      builder: (context, child) {
        if (!disableAnimations) return child!;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        );
      },
      home: openFromLauncher
          ? Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(builder: (_) => detailPage),
                    ),
                    child: const Text('Abrir coleccion'),
                  ),
                ),
              ),
            )
          : detailPage,
    ),
  );
}

void _noop() {}

class _SelectedDownloads extends DownloadController {
  List<TrackInfo>? tracks;

  @override
  Map<String, DownloadTaskState> build() => const {};

  @override
  Future<int> downloadTracks(Iterable<TrackInfo> tracks) async {
    this.tracks = tracks.toList();
    return tracks.length;
  }
}

class _PickerPlaylistsController extends PlaylistsController {
  String? destination;
  List<TrackInfo>? receivedTracks;
  bool? download;

  @override
  Future<List<Playlist>> build() async => [
    Playlist(
      id: 'existing',
      name: 'Mi playlist',
      trackIds: const [],
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
  ];

  @override
  Future<int> addRemoteTracksToPlaylist(
    String playlistId,
    Iterable<TrackInfo> tracks, {
    bool download = false,
  }) async {
    destination = playlistId;
    receivedTracks = tracks.toList();
    this.download = download;
    return tracks.length;
  }
}

class _RecordingPlayerController extends PlayerController {
  int playCalls = 0;
  TrackInfo? lastTrack;
  List<TrackInfo>? lastQueue;
  String? lastQueueSourceId;

  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);

  @override
  Future<void> playRemote(
    TrackInfo track, {
    List<TrackInfo>? queue,
    String? queueSourceId,
  }) async {
    playCalls++;
    lastTrack = track;
    lastQueue = queue == null ? null : List.unmodifiable(queue);
    lastQueueSourceId = queueSourceId;
  }
}

const _tracks = <TrackInfo>[
  TrackInfo(
    id: 'song-1',
    title: 'Primera cancion',
    artist: 'Artista principal',
    album: 'Album de contrato',
    duration: Duration(minutes: 3),
    url: 'https://www.youtube.com/watch?v=firstsong01',
  ),
  TrackInfo(
    id: 'song-2',
    title: 'Segunda cancion',
    artist: 'Artista invitado',
    album: 'Album de contrato',
    duration: Duration(minutes: 4),
    url: 'https://www.youtube.com/watch?v=secondsong2',
  ),
];
