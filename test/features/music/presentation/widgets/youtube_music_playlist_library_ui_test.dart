import 'dart:async';

import 'package:bstream_music/core/theme/app_dialog.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/library_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_artwork_mosaic.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_picker_dialog.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/sharing/playlist_csv_share_service.dart';
import 'package:bstream_music/services/sharing/youtube_music_playlist_share_service.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('playlist multi-selection removes only selected occurrences', (
    tester,
  ) async {
    final fixture = _remoteCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );
    await tester.pumpWidget(
      _libraryHarness(fixture: fixture, controller: controller),
    );
    await _pumpLibrary(tester);
    await tester.tap(
      find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
    );
    await _pumpLibrary(tester);
    await tester.longPress(
      find.byKey(const ValueKey('library-catalog-entry-occurrence-a')),
    );
    await _pumpLibrary(tester);

    expect(
      find.byKey(const ValueKey('library-selection-toolbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('library-catalog-play-occurrence-b')),
      findsNothing,
    );
    await _openSelectionMenu(tester);
    await tester.tap(
      find.byKey(const ValueKey('library-selection-remove-from-playlist')),
    );
    await _pumpLibrary(tester);
    // Cancelling preserves both the selection and playlist entries.
    await tester.tap(find.text('Cancelar'));
    await _pumpLibrary(tester);
    expect(controller.removedEntryIds, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey('library-catalog-entry-occurrence-b')),
    );
    await _pumpLibrary(tester);
    await tester.tap(
      find.byKey(const ValueKey('library-catalog-entry-occurrence-a')),
    );
    await _pumpLibrary(tester);
    await _openSelectionMenu(tester);
    await tester.tap(
      find.byKey(const ValueKey('library-selection-remove-from-playlist')),
    );
    await _pumpLibrary(tester);
    await tester.tap(
      find.byKey(const ValueKey('library-selection-confirm-remove')),
    );
    await _pumpLibrary(tester);

    expect(controller.removedEntryIds, ['occurrence-b']);
    expect(
      find.byKey(const ValueKey('library-selection-toolbar')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist selected downloads use the existing batch queue', (
    tester,
  ) async {
    final fixture = _remoteCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );
    final downloads = _RecordingSelectionDownloads();
    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: controller,
        downloads: downloads,
      ),
    );
    await _pumpLibrary(tester);
    await tester.tap(
      find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
    );
    await _pumpLibrary(tester);
    await tester.longPress(
      find.byKey(const ValueKey('library-catalog-entry-occurrence-a')),
    );
    await _pumpLibrary(tester);
    await tester.tap(
      find.byKey(const ValueKey('library-catalog-entry-occurrence-b')),
    );
    await _pumpLibrary(tester);
    await _openSelectionMenu(tester);
    await tester.tap(find.byKey(const ValueKey('library-selection-download')));
    await _pumpLibrary(tester);

    expect(downloads.selectedTracks, hasLength(2));
    expect(
      downloads.selectedTracks.map((track) => track.id),
      everyElement('duplicate-video'),
    );
    expect(
      find.byKey(const ValueKey('library-selection-toolbar')),
      findsNothing,
    );
    expect(controller.removedEntryIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (platform: TargetPlatform.android, size: const Size(320, 700)),
    (platform: TargetPlatform.windows, size: const Size(1200, 800)),
  ]) {
    testWidgets(
      '${scenario.platform} playlist selection uses an overflow menu at ${scenario.size.width}px',
      (tester) async {
        tester.view.physicalSize = scenario.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = _remoteCatalogFixture();
        final controller = _RecordingPlaylistsController(
          playlist: fixture.playlist,
        );
        await tester.pumpWidget(
          _libraryHarness(
            fixture: fixture,
            controller: controller,
            platform: scenario.platform,
          ),
        );
        await _pumpLibrary(tester);
        await tester.tap(
          find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
        );
        await _pumpLibrary(tester);
        await tester.longPress(
          find.byKey(const ValueKey('library-catalog-entry-occurrence-a')),
        );
        await _pumpLibrary(tester);
        expect(
          find.byKey(const ValueKey('library-selection-count')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('library-selection-close')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('library-selection-add-to-playlist')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('library-selection-download')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('library-selection-remove-from-playlist')),
          findsNothing,
        );
        await _openSelectionMenu(tester);
        expect(
          find.byKey(const ValueKey('glass-popup-menu-surface')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('library-selection-add-to-playlist')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('library-selection-download')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('library-selection-remove-from-playlist')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        // Dismissing the popup must retain selection and leave the toolbar usable.
        await tester.tapAt(Offset(4, scenario.size.height - 4));
        await _pumpLibrary(tester);
        expect(
          find.byKey(const ValueKey('library-selection-toolbar')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('library-selection-download')),
          findsNothing,
        );
        await tester.tap(find.byKey(const ValueKey('library-selection-close')));
        await _pumpLibrary(tester);
        expect(
          find.byKey(const ValueKey('library-catalog-play-occurrence-a')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'playlist picker uses imported remote artwork and returns the local id',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      String? selectedPlaylistId;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  selectedPlaylistId = await showDialog<String>(
                    context: context,
                    builder: (_) => PlaylistPickerDialog(
                      title: 'Elegir playlist',
                      playlists: <Playlist>[
                        fixture.playlist,
                        Playlist(
                          id: Playlist.favoritesId,
                          name: 'Favoritos',
                          trackIds: const <String>[],
                          createdAt: fixture.now,
                          updatedAt: fixture.now,
                        ),
                      ],
                      tracks: const <LocalTrack>[],
                      catalogPlaylists: <CatalogPlaylist>[fixture.catalog],
                    ),
                  );
                },
                child: const Text('Abrir selector'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir selector'));
      await tester.pumpAndSettle();

      expect(find.text('Viaje importado'), findsOneWidget);
      expect(find.text('Favoritos'), findsNothing);
      expect(
        tester
            .widgetList<SourceImage>(find.byType(SourceImage))
            .map((image) => image.source),
        contains(_remoteThumbnail),
      );

      await tester.tap(find.text('Viaje importado'));
      await tester.pumpAndSettle();

      expect(selectedPlaylistId, fixture.playlist.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library counts duplicate remote occurrences and uses their imported cover',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );

      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);

      expect(fixture.playlist.trackIds, isEmpty);
      expect(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
        findsOneWidget,
      );
      expect(find.text('2 canciones · 6:14 min'), findsOneWidget);

      final artwork = find.descendant(
        of: find.byKey(
          ValueKey('library-playlist-artwork-${fixture.playlist.id}'),
        ),
        matching: find.byType(SourceImage),
      );
      expect(artwork, findsOneWidget);
      expect(tester.widget<SourceImage>(artwork).source, _remoteThumbnail);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('library collage uses four catalog covers in a square grid', (
    tester,
  ) async {
    final fixture = _multiArtworkCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );

    await tester.pumpWidget(
      _libraryHarness(fixture: fixture, controller: controller),
    );
    await _pumpLibrary(tester);

    final cover = find.byKey(
      ValueKey('library-playlist-artwork-${fixture.playlist.id}'),
    );
    final artwork = find.descendant(
      of: cover,
      matching: find.byType(SourceImage),
    );
    final images = tester
        .widgetList<SourceImage>(artwork)
        .where(
          (image) =>
              image.source?.startsWith('https://img.test/local-album-cover-') ??
              false,
        )
        .toList(growable: false);
    final sources = images.map((image) => image.source).toList(growable: false);

    expect(sources, hasLength(4));
    expect(sources.toSet(), hasLength(4));
    expect(
      sources.every(
        (source) =>
            source?.startsWith('https://img.test/local-album-cover-') ?? false,
      ),
      isTrue,
    );
    expect(
      sources.any((source) => source?.contains('ytimg.com') ?? false),
      isFalse,
    );
    expect(
      images.every(
        (image) =>
            image.fallbackSource?.endsWith('.jpg') == true &&
            image.fallbackSource!.contains('video-thumbnail-'),
      ),
      isTrue,
    );
    final cells = artwork.evaluate().toList(growable: false);
    final rectangles = cells
        .map((cell) => tester.getRect(find.byWidget(cell.widget)))
        .toList(growable: false);
    expect(rectangles.map((rect) => rect.top).toSet(), hasLength(2));
    expect(rectangles.map((rect) => rect.left).toSet(), hasLength(2));
    expect(rectangles.map((rect) => rect.size).toSet(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'playlist detail retains its cover selection while filtering and rotates on return',
    (tester) async {
      final fixture = _multiArtworkCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);

      final coverKey = ValueKey(
        'library-playlist-artwork-${fixture.playlist.id}',
      );
      final heroKey = ValueKey('library-playlist-hero-${fixture.playlist.id}');
      final initialSources = _artworkSources(tester, coverKey);
      expect(initialSources, hasLength(4));

      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);

      expect(_artworkSources(tester, heroKey), initialSources);
      expect(
        find.byKey(const ValueKey('library-playlist-background-color')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-playlist-background-photo')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-playlist-background-fade')),
        findsOneWidget,
      );

      await _openPlaylistSearch(tester, fixture.playlist.id);
      await tester.enterText(find.byType(TextField), 'No matching songs');
      await _pumpLibrary(tester);
      expect(_artworkSources(tester, heroKey), initialSources);
      await tester.enterText(find.byType(TextField), '');
      await _pumpLibrary(tester);
      expect(_artworkSources(tester, heroKey), initialSources);

      final header = find.byKey(const ValueKey('library-detail-header'));
      await tester.tap(
        find.descendant(
          of: header,
          matching: find.byIcon(Icons.arrow_back_rounded),
        ),
      );
      await _pumpLibrary(tester);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('library-detail-header')),
          matching: find.byIcon(Icons.arrow_back_rounded),
        ),
      );
      await _pumpLibrary(tester);

      final refreshedSources = _artworkSources(tester, coverKey);
      expect(refreshedSources, hasLength(4));
      expect(refreshedSources.first, isNot(initialSources.first));
      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);
      expect(_artworkSources(tester, heroKey), refreshedSources);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty playlist detail shows its cover fallback and remains usable',
    (tester) async {
      final source = _remoteCatalogFixture();
      final fixture = _RemoteCatalogFixture(
        now: source.now,
        playlist: source.playlist,
        catalog: CatalogPlaylist(
          playlist: source.playlist,
          entries: const <PlaylistEntry>[],
        ),
      );
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);
      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);

      final hero = find.byKey(
        ValueKey('library-playlist-hero-${fixture.playlist.id}'),
      );
      expect(hero, findsOneWidget);
      expect(
        find.descendant(of: hero, matching: find.byType(SourceImage)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: hero,
          matching: find.byIcon(Icons.queue_music_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('library-detail-header')),
          matching: find.byIcon(Icons.more_vert_rounded),
        ),
      );
      await _pumpLibrary(tester);
      expect(
        find.byKey(ValueKey('playlist-share-${fixture.playlist.id}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'playlist hero remains scrollable on narrow screens with large text and after rotation',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final source = _multiArtworkCatalogFixture();
      final playlist = source.playlist.copyWith(
        name:
            'Una playlist con un nombre muy largo para escuchar todos los días',
      );
      final fixture = _RemoteCatalogFixture(
        now: source.now,
        playlist: playlist,
        catalog: CatalogPlaylist(
          playlist: playlist,
          entries: source.catalog.entries,
        ),
        libraryTracks: source.libraryTracks,
      );
      final controller = _RecordingPlaylistsController(playlist: playlist);
      await tester.pumpWidget(
        _libraryHarness(
          fixture: fixture,
          controller: controller,
          textScale: 1.6,
        ),
      );
      await _pumpLibrary(tester);
      await tester.tap(find.byKey(ValueKey('library-playlist-${playlist.id}')));
      await _pumpLibrary(tester);
      await _openPlaylistSearch(tester, playlist.id);
      final heroKey = ValueKey('library-playlist-hero-${playlist.id}');
      final sources = _artworkSources(tester, heroKey);
      expect(sources, hasLength(4));
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(700, 320);
      await _pumpLibrary(tester);
      expect(_artworkSources(tester, heroKey), sources);
      expect(tester.takeException(), isNull);

      final scroll = find.byKey(const ValueKey('library-catalog-track-scroll'));
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('library-catalog-entry-entry-8')),
        scroll,
        const Offset(0, -180),
      );
      await _pumpLibrary(tester);
      expect(
        find
            .byKey(const ValueKey('library-catalog-entry-entry-8'))
            .hitTestable(),
        findsOneWidget,
      );
      await tester.drag(scroll, const Offset(0, 2000));
      await _pumpLibrary(tester);
      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Artista 8');
      await _pumpLibrary(tester);
      expect(tester.takeException(), isNull);
      expect(_artworkSources(tester, heroKey), sources);
    },
  );

  testWidgets(
    'legacy local-only playlist keeps matching list and detail covers',
    (tester) async {
      final source = _multiArtworkCatalogFixture();
      final fixture = _RemoteCatalogFixture(
        now: source.now,
        playlist: source.playlist,
        catalog: CatalogPlaylist(
          playlist: source.playlist,
          entries: const <PlaylistEntry>[],
        ),
        libraryTracks: source.libraryTracks,
      );
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);
      final sources = _artworkSources(
        tester,
        ValueKey('library-playlist-artwork-${fixture.playlist.id}'),
      );
      expect(sources, hasLength(4));
      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);
      expect(
        _artworkSources(
          tester,
          ValueKey('library-playlist-hero-${fixture.playlist.id}'),
        ),
        sources,
      );
      expect(
        find.byKey(const ValueKey('library-track-local-0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remote playlist song menu offers download and add-to-playlist actions',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);

      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);
      await tester.tap(
        find.byKey(const ValueKey('library-catalog-menu-occurrence-a')),
      );
      await tester.pump();

      expect(find.text('Descargar'), findsOneWidget);
      expect(find.text('Añadir a playlist'), findsOneWidget);
      expect(find.text('Quitar de playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('playlist rows show download progress and offer cancellation', (
    tester,
  ) async {
    final fixture = _remoteCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );
    const url = 'https://www.youtube.com/watch?v=duplicate-video';
    final downloads = _PresetDownloadController(<String, DownloadTaskState>{
      url: const DownloadTaskState(
        url: url,
        taskId: 'playlist-download-task',
        mediaType: DownloadMediaType.audio,
        status: DownloadProgressStatus.running,
        progress: 0.42,
        title: 'Canción repetida',
      ),
    });
    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: controller,
        downloads: downloads,
      ),
    );
    await _pumpLibrary(tester);

    await tester.tap(
      find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
    );
    await _pumpLibrary(tester);

    expect(
      find.byKey(const ValueKey('library-catalog-download-occurrence-a')),
      findsOneWidget,
    );
    expect(find.text('42%'), findsNWidgets(2));

    await tester.tap(
      find.byKey(const ValueKey('library-catalog-menu-occurrence-a')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cancelar descarga'), findsOneWidget);
    final cancelItem = find.ancestor(
      of: find.text('Cancelar descarga'),
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
    );
    await tester.tap(cancelItem);
    await tester.pumpAndSettle();
    expect(downloads.cancelledUrls, <String>[url]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'synchronized playlist menu shares its real name and remote identity',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      final shareService = _RecordingPlaylistShareService();
      await tester.pumpWidget(
        _libraryHarness(
          fixture: fixture,
          controller: controller,
          shareableBindings: <String, YouTubeMusicShareablePlaylistBinding>{
            fixture.playlist.id: YouTubeMusicShareablePlaylistBinding(
              localPlaylistId: fixture.playlist.id,
              remotePlaylistId: 'PLremote123',
              rawRemotePlaylistId: 'PLremote123',
              isEditable: true,
              privacy: 'UNLISTED',
            ),
          },
          authenticated: true,
          playlistShareService: shareService,
        ),
      );
      await _pumpLibrary(tester);

      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);
      final header = find.byKey(const ValueKey('library-detail-header'));
      await tester.tap(
        find.descendant(
          of: header,
          matching: find.byIcon(Icons.more_vert_rounded),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Compartir playlist'), findsOneWidget);
      await tester.tap(
        find.byKey(ValueKey('playlist-share-${fixture.playlist.id}')),
      );
      await tester.pumpAndSettle();
      await _chooseUrlShare(tester);

      expect(shareService.remotePlaylistId, 'PLremote123');
      expect(shareService.playlistName, 'Viaje importado');
      expect(shareService.message, contains('Viaje importado'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'authenticated synchronized playlist menu opens while bindings load',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      final pendingBindings =
          Completer<Map<String, YouTubeMusicShareablePlaylistBinding>>();
      final visibilityChange = _RecordingVisibilityChange();
      var bindingsReads = 0;
      await tester.pumpWidget(
        _libraryHarness(
          fixture: fixture,
          controller: controller,
          shareableBindingsFuture: pendingBindings.future,
          authenticated: true,
          makeUnlisted: visibilityChange.call,
          onBindingsRead: () => bindingsReads++,
        ),
      );
      await _pumpLibrary(tester);

      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);
      final header = find.byKey(const ValueKey('library-detail-header'));
      await tester.tap(
        find.descendant(
          of: header,
          matching: find.byIcon(Icons.more_vert_rounded),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.text('Compartir playlist'), findsOneWidget);
      expect(find.text('Renombrar playlist'), findsOneWidget);
      expect(find.text('Eliminar playlist'), findsOneWidget);
      expect(visibilityChange.calls, 0);
      expect(bindingsReads, 0);
      expect(find.byKey(const Key('playlist-share-preparing')), findsNothing);
      expect(tester.takeException(), isNull);
      pendingBindings.complete(
        const <String, YouTubeMusicShareablePlaylistBinding>{},
      );
      await tester.pump();
    },
  );

  testWidgets(
    'private synchronized playlist is changed to unlisted before sharing',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      final events = <String>[];
      final shareService = _RecordingPlaylistShareService(events: events);
      final visibilityChange = _RecordingVisibilityChange(events: events);
      await tester.pumpWidget(
        _libraryHarness(
          fixture: fixture,
          controller: controller,
          shareableBindings: <String, YouTubeMusicShareablePlaylistBinding>{
            fixture.playlist.id: YouTubeMusicShareablePlaylistBinding(
              localPlaylistId: fixture.playlist.id,
              remotePlaylistId: 'PLprivate123',
              rawRemotePlaylistId: 'VLPLprivate123',
              isEditable: true,
              privacy: 'PRIVATE',
            ),
          },
          authenticated: true,
          playlistShareService: shareService,
          makeUnlisted: visibilityChange.call,
        ),
      );
      await _pumpLibrary(tester);

      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);
      final header = find.byKey(const ValueKey('library-detail-header'));
      await tester.tap(
        find.descendant(
          of: header,
          matching: find.byIcon(Icons.more_vert_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('playlist-share-${fixture.playlist.id}')),
      );
      await tester.pumpAndSettle();
      await _chooseUrlShare(tester);

      expect(find.byKey(const Key('playlist-share-make-unlisted')), findsOne);
      expect(shareService.remotePlaylistId, isNull);
      await tester.tap(find.byKey(const Key('playlist-share-make-unlisted')));
      await tester.pumpAndSettle();

      expect(visibilityChange.localPlaylistId, fixture.playlist.id);
      expect(visibilityChange.expectedRemotePlaylistId, 'PLprivate123');
      expect(shareService.remotePlaylistId, 'PLprivate123');
      expect(events, <String>['make-unlisted', 'share']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'private playlist shows preparation progress until remote change completes',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      final preparation = Completer<void>();
      final events = <String>[];
      final shareService = _RecordingPlaylistShareService(events: events);
      final visibilityChange = _RecordingVisibilityChange(
        events: events,
        pendingOperation: preparation.future,
      );
      await tester.pumpWidget(
        _libraryHarness(
          fixture: fixture,
          controller: controller,
          shareableBindings: <String, YouTubeMusicShareablePlaylistBinding>{
            fixture.playlist.id: YouTubeMusicShareablePlaylistBinding(
              localPlaylistId: fixture.playlist.id,
              remotePlaylistId: 'PLprivate123',
              rawRemotePlaylistId: 'VLPLprivate123',
              isEditable: true,
              privacy: 'PRIVATE',
            ),
          },
          authenticated: true,
          playlistShareService: shareService,
          makeUnlisted: visibilityChange.call,
        ),
      );
      await _pumpLibrary(tester);

      await tester.tap(
        find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      );
      await _pumpLibrary(tester);
      final header = find.byKey(const ValueKey('library-detail-header'));
      await tester.tap(
        find.descendant(
          of: header,
          matching: find.byIcon(Icons.more_vert_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('playlist-share-${fixture.playlist.id}')),
      );
      await tester.pumpAndSettle();
      await _chooseUrlShare(tester);
      await tester.tap(find.byKey(const Key('playlist-share-make-unlisted')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(find.byKey(const Key('playlist-share-preparing')), findsOneWidget);
      expect(visibilityChange.calls, 1);
      expect(shareService.remotePlaylistId, isNull);
      expect(events, <String>['make-unlisted']);

      preparation.complete();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('playlist-share-preparing')), findsNothing);
      expect(shareService.remotePlaylistId, 'PLprivate123');
      expect(events, <String>['make-unlisted', 'share']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelling private playlist sharing makes no changes', (
    tester,
  ) async {
    final fixture = _remoteCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );
    final shareService = _RecordingPlaylistShareService();
    final visibilityChange = _RecordingVisibilityChange();
    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: controller,
        shareableBindings: <String, YouTubeMusicShareablePlaylistBinding>{
          fixture.playlist.id: YouTubeMusicShareablePlaylistBinding(
            localPlaylistId: fixture.playlist.id,
            remotePlaylistId: 'PLprivate123',
            rawRemotePlaylistId: 'PLprivate123',
            isEditable: true,
            privacy: 'PRIVATE',
          ),
        },
        authenticated: true,
        playlistShareService: shareService,
        makeUnlisted: visibilityChange.call,
      ),
    );
    await _pumpLibrary(tester);

    await tester.tap(
      find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
    );
    await _pumpLibrary(tester);
    final header = find.byKey(const ValueKey('library-detail-header'));
    await tester.tap(
      find.descendant(
        of: header,
        matching: find.byIcon(Icons.more_vert_rounded),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('playlist-share-${fixture.playlist.id}')),
    );
    await tester.pumpAndSettle();
    await _chooseUrlShare(tester);
    await tester.tap(find.byKey(const Key('playlist-share-private-cancel')));
    await tester.pumpAndSettle();

    expect(visibilityChange.calls, 0);
    expect(shareService.remotePlaylistId, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logged-out playlist menu shares CSV without reading YouTube', (
    tester,
  ) async {
    final fixture = _remoteCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );
    final csvService = _RecordingPlaylistCsvShareService();
    final urlService = _RecordingPlaylistShareService();
    final sync = _RecordingPlaylistSyncController();
    var bindingsReads = 0;
    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: controller,
        playlistCsvShareService: csvService,
        playlistShareService: urlService,
        playlistSyncController: sync,
        onBindingsRead: () => bindingsReads++,
      ),
    );
    await _pumpLibrary(tester);

    await _openPlaylistShare(tester, fixture.playlist.id);

    expect(find.byKey(const Key('playlist-share-format-dialog')), findsNothing);
    expect(csvService.playlists, hasLength(1));
    expect(csvService.playlists.single.playlist.id, fixture.playlist.id);
    expect(
      csvService.playlists.single.entries.map((entry) => entry.id),
      fixture.catalog.entries.map((entry) => entry.id),
    );
    expect(csvService.title, isNotEmpty);
    expect(csvService.sharePositionOrigin, isNotNull);
    expect(urlService.remotePlaylistId, isNull);
    expect(bindingsReads, 0);
    expect(sync.buildCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logged-in playlist can share CSV without a YouTube binding', (
    tester,
  ) async {
    final fixture = _multiArtworkCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );
    final csvService = _RecordingPlaylistCsvShareService();
    final urlService = _RecordingPlaylistShareService();
    final sync = _RecordingPlaylistSyncController();
    var bindingsReads = 0;
    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: controller,
        authenticated: true,
        playlistCsvShareService: csvService,
        playlistShareService: urlService,
        playlistSyncController: sync,
        onBindingsRead: () => bindingsReads++,
      ),
    );
    await _pumpLibrary(tester);

    await _openPlaylistShare(tester, fixture.playlist.id);

    final dialog = find.byKey(const Key('playlist-share-format-dialog'));
    expect(dialog, findsOneWidget);
    expect(tester.widget(dialog), isA<AppAlertDialog>());
    expect(find.byKey(const Key('playlist-share-csv')), findsOneWidget);
    expect(find.byKey(const Key('playlist-share-url')), findsOneWidget);
    expect(csvService.playlists, isEmpty);
    expect(bindingsReads, 0);

    await tester.tap(find.byKey(const Key('playlist-share-csv')));
    await tester.pumpAndSettle();

    expect(csvService.playlists, hasLength(1));
    expect(csvService.playlists.single.playlist.id, fixture.playlist.id);
    expect(
      csvService.playlists.single.entries.map((entry) => entry.id),
      fixture.catalog.entries.map((entry) => entry.id),
    );
    expect(csvService.localTracks, fixture.libraryTracks);
    expect(urlService.remotePlaylistId, isNull);
    expect(bindingsReads, 0);
    expect(sync.buildCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling playlist share format performs no share or lookup', (
    tester,
  ) async {
    final fixture = _remoteCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );
    final csvService = _RecordingPlaylistCsvShareService();
    final urlService = _RecordingPlaylistShareService();
    final visibilityChange = _RecordingVisibilityChange();
    final sync = _RecordingPlaylistSyncController();
    var bindingsReads = 0;
    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: controller,
        authenticated: true,
        playlistCsvShareService: csvService,
        playlistShareService: urlService,
        playlistSyncController: sync,
        makeUnlisted: visibilityChange.call,
        onBindingsRead: () => bindingsReads++,
      ),
    );
    await _pumpLibrary(tester);

    await _openPlaylistShare(tester, fixture.playlist.id);
    await tester.tap(find.byKey(const Key('playlist-share-format-cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('playlist-share-format-dialog')), findsNothing);
    expect(csvService.playlists, isEmpty);
    expect(urlService.remotePlaylistId, isNull);
    expect(visibilityChange.calls, 0);
    expect(bindingsReads, 0);
    expect(sync.buildCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorites offers CSV and disables URL sharing', (tester) async {
    final fixture = _remoteCatalogFixture(
      playlistId: Playlist.favoritesId,
      playlistName: 'Favoritos',
    );
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );
    final csvService = _RecordingPlaylistCsvShareService();
    final urlService = _RecordingPlaylistShareService();
    final visibilityChange = _RecordingVisibilityChange();
    final sync = _RecordingPlaylistSyncController();
    var bindingsReads = 0;
    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: controller,
        authenticated: true,
        playlistCsvShareService: csvService,
        playlistShareService: urlService,
        playlistSyncController: sync,
        makeUnlisted: visibilityChange.call,
        onBindingsRead: () => bindingsReads++,
      ),
    );
    await _pumpLibrary(tester);

    await tester.tap(
      find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
    );
    await _pumpLibrary(tester);
    final header = find.byKey(const ValueKey('library-detail-header'));
    await tester.tap(
      find.descendant(
        of: header,
        matching: find.byIcon(Icons.more_vert_rounded),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Renombrar playlist'), findsNothing);
    expect(find.text('Eliminar playlist'), findsNothing);
    await tester.tap(
      find.byKey(ValueKey('playlist-share-${fixture.playlist.id}')),
    );
    await tester.pumpAndSettle();

    final urlChoice = tester.widget<ListTile>(
      find.byKey(const Key('playlist-share-url')),
    );
    expect(urlChoice.enabled, isFalse);
    await tester.tap(find.byKey(const Key('playlist-share-url')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('playlist-share-format-dialog')),
      findsOneWidget,
    );
    expect(csvService.playlists, isEmpty);
    expect(urlService.remotePlaylistId, isNull);
    expect(bindingsReads, 0);
    await tester.tap(find.byKey(const Key('playlist-share-csv')));
    await tester.pumpAndSettle();

    expect(csvService.playlists, hasLength(1));
    expect(csvService.playlists.single.playlist.id, Playlist.favoritesId);
    expect(urlService.remotePlaylistId, isNull);
    expect(visibilityChange.calls, 0);
    expect(bindingsReads, 0);
    expect(sync.buildCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unsynchronized URL sharing explains availability without changes',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
      );
      final csvService = _RecordingPlaylistCsvShareService();
      final urlService = _RecordingPlaylistShareService();
      final visibilityChange = _RecordingVisibilityChange();
      final sync = _RecordingPlaylistSyncController();
      var bindingsReads = 0;
      await tester.pumpWidget(
        _libraryHarness(
          fixture: fixture,
          controller: controller,
          authenticated: true,
          playlistCsvShareService: csvService,
          playlistShareService: urlService,
          playlistSyncController: sync,
          makeUnlisted: visibilityChange.call,
          onBindingsRead: () => bindingsReads++,
        ),
      );
      await _pumpLibrary(tester);

      await _openPlaylistShare(tester, fixture.playlist.id);
      expect(bindingsReads, 0);
      await _chooseUrlShare(tester);

      expect(
        find.text(
          const AppStrings(AppLanguage.spanish).playlistShareUrlUnavailable,
        ),
        findsOneWidget,
      );
      expect(bindingsReads, 1);
      expect(csvService.playlists, isEmpty);
      expect(urlService.remotePlaylistId, isNull);
      expect(visibilityChange.calls, 0);
      expect(sync.buildCalls, 0);
      expect(controller.deleteScopes, isEmpty);
      expect(controller.removedEntryIds, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'linked playlist local-only action never requests YouTube deletion',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
        deleteOptions: const PlaylistDeleteOptions(
          isYouTubeMusicLinked: true,
          canDeleteFromYouTubeMusic: true,
          remoteAccountKey: 'account-a',
        ),
      );
      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);

      await _openDeleteDialog(tester, fixture.playlist.id);
      expect(
        find.byKey(const Key('playlist-delete-youtube-too')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('playlist-delete-local-only')));
      await tester.pump(const Duration(milliseconds: 350));

      expect(controller.deleteScopes, <PlaylistDeleteScope>[
        PlaylistDeleteScope.localOnly,
      ]);
      expect(find.text('Playlist eliminada.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'YouTube deletion is requested only from its explicit destructive action',
    (tester) async {
      final fixture = _remoteCatalogFixture();
      final controller = _RecordingPlaylistsController(
        playlist: fixture.playlist,
        deleteOptions: const PlaylistDeleteOptions(
          isYouTubeMusicLinked: true,
          canDeleteFromYouTubeMusic: true,
          remoteAccountKey: 'account-a',
        ),
      );
      await tester.pumpWidget(
        _libraryHarness(fixture: fixture, controller: controller),
      );
      await _pumpLibrary(tester);

      await _openDeleteDialog(tester, fixture.playlist.id);
      await tester.tap(find.byKey(const Key('playlist-delete-youtube-too')));
      await tester.pump(const Duration(milliseconds: 350));

      expect(controller.deleteScopes, <PlaylistDeleteScope>[
        PlaylistDeleteScope.youtubeMusicToo,
      ]);
      expect(
        find.textContaining('eliminación en YouTube Music quedó programada'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('catalog cards ignore position-only playback updates', (
    tester,
  ) async {
    final fixture = _remoteCatalogFixture();
    final playlists = _RecordingPlaylistsController(playlist: fixture.playlist);
    const initialSnapshot = PlayerSnapshot(
      status: PlayerStatus.playing,
      trackId: 'duplicate-video',
      title: 'Canción repetida',
      artist: 'Artista remoto',
      position: Duration(seconds: 12),
      duration: Duration(minutes: 3, seconds: 7),
    );
    final player = _MutablePlayerController(initialSnapshot);

    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: playlists,
        playerController: player,
      ),
    );
    await _pumpLibrary(tester);
    await tester.tap(
      find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
    );
    await _pumpLibrary(tester);

    final playButton = find.byKey(
      const ValueKey('library-catalog-play-occurrence-a'),
    );
    final initialButton = tester.widget<Widget>(playButton);

    player.emit(
      initialSnapshot.copyWith(position: const Duration(seconds: 13)),
    );
    await tester.pump();

    expect(
      identical(tester.widget<Widget>(playButton), initialButton),
      isTrue,
      reason: 'a playback clock tick must not rebuild catalog cards',
    );

    player.emit(
      initialSnapshot.copyWith(
        status: PlayerStatus.paused,
        position: const Duration(seconds: 14),
      ),
    );
    await tester.pump();

    expect(
      identical(tester.widget<Widget>(playButton), initialButton),
      isFalse,
      reason: 'a play/pause change must still refresh the card control',
    );
    expect(
      find.descendant(
        of: playButton,
        matching: find.byIcon(Icons.play_arrow_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist menu search clears before closing and handles back', (
    tester,
  ) async {
    final fixture = _remoteCatalogFixture();
    final controller = _RecordingPlaylistsController(
      playlist: fixture.playlist,
    );
    final navigation = LibraryNavigationController();
    addTearDown(navigation.dispose);
    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: controller,
        navigationController: navigation,
      ),
    );
    await _pumpLibrary(tester);
    await tester.tap(
      find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
    );
    await _pumpLibrary(tester);

    expect(find.byType(TextField), findsNothing);
    final header = find.byKey(const ValueKey('library-detail-header'));
    await tester.tap(
      find.descendant(
        of: header,
        matching: find.byIcon(Icons.more_vert_rounded),
      ),
    );
    await tester.pumpAndSettle();
    final searchItem = find.byKey(
      ValueKey('playlist-search-${fixture.playlist.id}'),
    );
    final downloadItem = find.byKey(
      ValueKey('playlist-download-all-${fixture.playlist.id}'),
    );
    expect(searchItem, findsOneWidget);
    expect(
      tester.getTopLeft(searchItem).dy,
      lessThan(tester.getTopLeft(downloadItem).dy),
    );
    await tester.tap(searchItem);
    await _pumpLibrary(tester);
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'no match');
    await _pumpLibrary(tester);
    await tester.tap(
      find.byKey(const ValueKey('library-filter-clear-or-close')),
    );
    await _pumpLibrary(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );

    await tester.tap(
      find.byKey(const ValueKey('library-filter-clear-or-close')),
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);

    await _openPlaylistSearch(tester, fixture.playlist.id);
    expect(navigation.canPop, isTrue);
    expect(navigation.maybePop(), isTrue);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('library-catalog-track-scroll')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('playlist play button starts the full catalog queue', (
    tester,
  ) async {
    final fixture = _remoteCatalogFixture();
    final playlists = _RecordingPlaylistsController(playlist: fixture.playlist);
    final player = _RecordingPlaybackPlayerController();
    var openedPlayer = false;
    await tester.pumpWidget(
      _libraryHarness(
        fixture: fixture,
        controller: playlists,
        playerController: player,
        onOpenPlayer: () => openedPlayer = true,
      ),
    );
    await _pumpLibrary(tester);
    await tester.tap(
      find.byKey(ValueKey('library-playlist-${fixture.playlist.id}')),
    );
    await _pumpLibrary(tester);
    final playButton = find.byKey(
      ValueKey('library-play-all-${fixture.playlist.id}'),
    );
    expect(
      find.descendant(of: playButton, matching: find.text('Reproducir')),
      findsOneWidget,
    );
    await tester.tap(playButton);
    await _pumpLibrary(tester);

    expect(player.playedPlaylistId, fixture.playlist.id);
    expect(player.playedQueue, hasLength(2));
    expect(player.playedQueue.first.entryId, 'occurrence-a');
    expect(openedPlayer, isTrue);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openDeleteDialog(WidgetTester tester, String playlistId) async {
  await tester.tap(find.byKey(ValueKey('library-playlist-$playlistId')));
  await _pumpLibrary(tester);
  final header = find.byKey(const ValueKey('library-detail-header'));
  expect(header, findsOneWidget);
  final playlistMenu = find.descendant(
    of: header,
    matching: find.byIcon(Icons.more_vert_rounded),
  );
  expect(playlistMenu, findsOneWidget);
  await tester.tap(playlistMenu);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  final deleteLabel = find.text('Eliminar playlist');
  final deleteMenuItem = find.ancestor(
    of: deleteLabel,
    matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
  );
  expect(deleteMenuItem, findsOneWidget);
  await tester.tap(deleteMenuItem);
  await tester.pump(const Duration(milliseconds: 300));

  expect(
    find.byWidgetPredicate((widget) => widget is AlertDialog),
    findsOneWidget,
  );
  expect(
    find.textContaining('Esta playlist está sincronizada'),
    findsOneWidget,
  );
}

Future<void> _pumpLibrary(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

List<String?> _artworkSources(WidgetTester tester, Key artworkKey) {
  final artwork = find.byKey(artworkKey);
  final mosaic = tester.widget<Widget>(artwork) is PlaylistArtworkMosaic
      ? artwork
      : find.descendant(
          of: artwork,
          matching: find.byType(PlaylistArtworkMosaic),
        );
  return tester
      .widget<PlaylistArtworkMosaic>(mosaic)
      .sources
      .map((source) => source.source)
      .toList(growable: false);
}

Future<void> _openSelectionMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-selection-menu')));
  await _pumpLibrary(tester);
}

Future<void> _openPlaylistSearch(WidgetTester tester, String playlistId) async {
  final header = find.byKey(const ValueKey('library-detail-header'));
  await tester.tap(
    find.descendant(of: header, matching: find.byIcon(Icons.more_vert_rounded)),
  );
  await tester.pumpAndSettle();
  final searchItem = find.byKey(ValueKey('playlist-search-$playlistId'));
  expect(searchItem, findsOneWidget);
  await tester.tap(searchItem);
  await _pumpLibrary(tester);
}

Future<void> _openPlaylistShare(WidgetTester tester, String playlistId) async {
  await tester.tap(find.byKey(ValueKey('library-playlist-$playlistId')));
  await _pumpLibrary(tester);
  final header = find.byKey(const ValueKey('library-detail-header'));
  await tester.tap(
    find.descendant(of: header, matching: find.byIcon(Icons.more_vert_rounded)),
  );
  await tester.pumpAndSettle();
  final shareItem = find.byKey(ValueKey('playlist-share-$playlistId'));
  expect(shareItem, findsOneWidget);
  await tester.tap(shareItem);
  await tester.pumpAndSettle();
}

Future<void> _chooseUrlShare(WidgetTester tester) async {
  expect(find.byKey(const Key('playlist-share-format-dialog')), findsOneWidget);
  await tester.tap(find.byKey(const Key('playlist-share-url')));
  await tester.pumpAndSettle();
}

Widget _libraryHarness({
  required _RemoteCatalogFixture fixture,
  required _RecordingPlaylistsController controller,
  Map<String, YouTubeMusicShareablePlaylistBinding> shareableBindings =
      const <String, YouTubeMusicShareablePlaylistBinding>{},
  Future<Map<String, YouTubeMusicShareablePlaylistBinding>>?
  shareableBindingsFuture,
  bool authenticated = false,
  PlaylistCsvShareService? playlistCsvShareService,
  YouTubeMusicPlaylistShareService? playlistShareService,
  _RecordingPlaylistSyncController? playlistSyncController,
  VoidCallback? onBindingsRead,
  YouTubeMusicMakePlaylistUnlistedForSharing? makeUnlisted,
  DownloadController? downloads,
  PlayerController? playerController,
  LibraryNavigationController? navigationController,
  VoidCallback? onOpenPlayer,
  TargetPlatform platform = TargetPlatform.android,
  double textScale = 1,
}) {
  return ProviderScope(
    overrides: [
      libraryTracksProvider.overrideWith((ref) async => fixture.libraryTracks),
      playlistsControllerProvider.overrideWith(() => controller),
      catalogPlaylistsProvider.overrideWith(
        (ref) async => <CatalogPlaylist>[fixture.catalog],
      ),
      catalogPlaylistProvider.overrideWith(
        (ref, playlistId) async =>
            playlistId == fixture.playlist.id ? fixture.catalog : null,
      ),
      playerControllerProvider.overrideWith(
        () => playerController ?? _IdlePlayerController(),
      ),
      if (downloads != null)
        downloadControllerProvider.overrideWith(() => downloads),
      youtubeMusicShareablePlaylistBindingDetailsProvider.overrideWith((ref) {
        onBindingsRead?.call();
        return shareableBindingsFuture ?? Future.value(shareableBindings);
      }),
      youtubeMusicPlaylistSyncControllerProvider.overrideWith(
        () => playlistSyncController ?? _RecordingPlaylistSyncController(),
      ),
      youtubeMusicAuthControllerProvider.overrideWith(
        () => authenticated
            ? _AuthenticatedYouTubeMusicAuthController()
            : _LoggedOutYouTubeMusicAuthController(),
      ),
      playlistCsvShareServiceProvider.overrideWithValue(
        playlistCsvShareService ?? _RecordingPlaylistCsvShareService(),
      ),
      if (makeUnlisted != null)
        youtubeMusicMakePlaylistUnlistedForSharingProvider.overrideWithValue(
          makeUnlisted,
        ),
      if (playlistShareService != null)
        youtubeMusicPlaylistShareServiceProvider.overrideWithValue(
          playlistShareService,
        ),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: platform),
      builder: textScale == 1
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
      home: Scaffold(
        body: LibraryPanel(
          onOpenPlayer: onOpenPlayer ?? () {},
          navigationController: navigationController,
        ),
      ),
    ),
  );
}

class _PresetDownloadController extends DownloadController {
  _PresetDownloadController(this.tasks);

  final Map<String, DownloadTaskState> tasks;
  final List<String> cancelledUrls = <String>[];

  @override
  Map<String, DownloadTaskState> build() => tasks;

  @override
  Future<bool> cancelDownload(String url) async {
    cancelledUrls.add(url);
    state = Map<String, DownloadTaskState>.from(state)..remove(url);
    return true;
  }
}

class _RecordingSelectionDownloads extends DownloadController {
  final selectedTracks = <TrackInfo>[];
  @override
  Map<String, DownloadTaskState> build() => const {};

  @override
  Future<int> downloadTracks(Iterable<TrackInfo> tracks) async {
    selectedTracks.addAll(tracks);
    return 1;
  }
}

class _RecordingPlaylistsController extends PlaylistsController {
  _RecordingPlaylistsController({
    required this.playlist,
    this.deleteOptions = const PlaylistDeleteOptions(
      isYouTubeMusicLinked: false,
      canDeleteFromYouTubeMusic: false,
    ),
  });

  final Playlist playlist;
  final PlaylistDeleteOptions deleteOptions;
  final List<PlaylistDeleteScope> deleteScopes = <PlaylistDeleteScope>[];
  final List<String> removedEntryIds = <String>[];

  @override
  Future<int> removeCatalogEntries(
    String playlistId,
    Iterable<String> entryIds,
  ) async {
    expect(playlistId, playlist.id);
    removedEntryIds.addAll(entryIds);
    return entryIds.length;
  }

  @override
  Future<List<Playlist>> build() async => <Playlist>[playlist];

  @override
  Future<PlaylistDeleteOptions> playlistDeleteOptions(String playlistId) async {
    expect(playlistId, playlist.id);
    return deleteOptions;
  }

  @override
  Future<void> deletePlaylist(
    String playlistId, {
    PlaylistDeleteScope scope = PlaylistDeleteScope.localOnly,
  }) async {
    expect(playlistId, playlist.id);
    deleteScopes.add(scope);
  }
}

class _IdlePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);
}

class _MutablePlayerController extends PlayerController {
  _MutablePlayerController(this.snapshot);

  final PlayerSnapshot snapshot;

  @override
  Future<PlayerSnapshot> build() async => snapshot;

  void emit(PlayerSnapshot nextSnapshot) {
    state = AsyncData(nextSnapshot);
  }
}

class _RecordingPlaybackPlayerController extends _IdlePlayerController {
  List<CatalogPlaybackItem> playedQueue = const <CatalogPlaybackItem>[];
  String? playedPlaylistId;

  @override
  Future<void> playCatalogPlaylist(
    CatalogPlaybackItem selected, {
    required List<CatalogPlaybackItem> queue,
    required String playlistId,
  }) async {
    playedQueue = queue;
    playedPlaylistId = playlistId;
  }
}

class _AuthenticatedYouTubeMusicAuthController
    extends YouTubeMusicAuthController {
  @override
  YouTubeMusicAuthState build() => const YouTubeMusicAuthState(
    phase: YouTubeMusicAuthPhase.authenticated,
    generation: 1,
    profile: YouTubeMusicAccountProfile(
      channelId: 'test-channel',
      displayName: 'Test account',
    ),
  );
}

class _LoggedOutYouTubeMusicAuthController extends YouTubeMusicAuthController {
  @override
  YouTubeMusicAuthState build() => const YouTubeMusicAuthState(
    phase: YouTubeMusicAuthPhase.anonymous,
    generation: 1,
  );
}

class _RecordingPlaylistSyncController
    extends YouTubeMusicPlaylistSyncController {
  int buildCalls = 0;

  @override
  YouTubeMusicPlaylistSyncState build() {
    buildCalls++;
    return const YouTubeMusicPlaylistSyncState();
  }
}

class _RecordingPlaylistCsvShareService implements PlaylistCsvShareService {
  final playlists = <CatalogPlaylist>[];
  List<LocalTrack>? localTracks;
  String? title;
  Rect? sharePositionOrigin;

  @override
  Future<void> sharePlaylist({
    required CatalogPlaylist playlist,
    required List<LocalTrack> localTracks,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    playlists.add(playlist);
    this.localTracks = List<LocalTrack>.of(localTracks);
    this.title = title;
    this.sharePositionOrigin = sharePositionOrigin;
  }
}

class _RecordingPlaylistShareService
    implements YouTubeMusicPlaylistShareService {
  _RecordingPlaylistShareService({this.events});

  final List<String>? events;
  String? remotePlaylistId;
  String? playlistName;
  String? message;

  @override
  bool canShare({
    required String remotePlaylistId,
    required String playlistName,
  }) => remotePlaylistId.trim().isNotEmpty && playlistName.trim().isNotEmpty;

  @override
  Future<void> sharePlaylist({
    required String remotePlaylistId,
    required String playlistName,
    required String message,
    required String title,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    events?.add('share');
    this.remotePlaylistId = remotePlaylistId;
    this.playlistName = playlistName;
    this.message = message;
  }
}

class _RecordingVisibilityChange {
  _RecordingVisibilityChange({this.events, this.pendingOperation});

  final List<String>? events;
  final Future<void>? pendingOperation;
  int calls = 0;
  String? localPlaylistId;
  String? expectedRemotePlaylistId;

  Future<void> call({
    required String localPlaylistId,
    required String expectedRemotePlaylistId,
  }) async {
    calls += 1;
    events?.add('make-unlisted');
    this.localPlaylistId = localPlaylistId;
    this.expectedRemotePlaylistId = expectedRemotePlaylistId;
    await pendingOperation;
  }
}

class _RemoteCatalogFixture {
  const _RemoteCatalogFixture({
    required this.now,
    required this.playlist,
    required this.catalog,
    this.libraryTracks = const <LocalTrack>[],
  });

  final DateTime now;
  final Playlist playlist;
  final CatalogPlaylist catalog;
  final List<LocalTrack> libraryTracks;
}

const _remoteThumbnail = 'https://i.ytimg.com/vi/duplicate-video/hqdefault.jpg';

_RemoteCatalogFixture _remoteCatalogFixture({
  String playlistId = 'imported-playlist',
  String playlistName = 'Viaje importado',
}) {
  final now = DateTime.utc(2026, 8, 22);
  final playlist = Playlist(
    id: playlistId,
    name: playlistName,
    trackIds: const <String>[],
    createdAt: now,
    updatedAt: now,
    localRevision: 1,
  );
  CatalogTrack duplicateTrack() => CatalogTrack.youtube(
    videoId: 'duplicate-video',
    title: 'Canción repetida',
    artists: const <String>['Artista remoto'],
    duration: const Duration(minutes: 3, seconds: 7),
    thumbnailUrl: _remoteThumbnail,
  );
  PlaylistEntry entry({
    required String id,
    required String setVideoId,
    required int position,
    DateTime? deletedAt,
  }) => PlaylistEntry(
    id: id,
    playlistId: playlist.id,
    track: duplicateTrack(),
    remoteVideoId: 'duplicate-video',
    setVideoId: setVideoId,
    position: position,
    origin: PlaylistEntryOrigin.remote,
    createdAt: now,
    updatedAt: now,
    deletedAt: deletedAt,
  );

  return _RemoteCatalogFixture(
    now: now,
    playlist: playlist,
    catalog: CatalogPlaylist(
      playlist: playlist,
      entries: <PlaylistEntry>[
        entry(id: 'occurrence-a', setVideoId: 'set-a', position: 0),
        entry(id: 'occurrence-b', setVideoId: 'set-b', position: 1),
        entry(
          id: 'deleted-occurrence',
          setVideoId: 'set-deleted',
          position: 2,
          deletedAt: now.add(const Duration(minutes: 1)),
        ),
      ],
    ),
  );
}

_RemoteCatalogFixture _multiArtworkCatalogFixture() {
  final now = DateTime.utc(2026, 8, 23);
  final localTracks = List<LocalTrack>.generate(9, (index) {
    final videoId = 'video${index.toString().padLeft(6, '0')}';
    return LocalTrack(
      id: 'local-$index',
      title: 'Canción $index',
      artist: 'Artista $index',
      filePath: '/music/song-$index.m4a',
      sourceId: videoId,
      addedAt: now,
      thumbnailPath: '/music/video-thumbnail-$index.jpg',
      thumbnailUrl: 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      catalogThumbnailUrl: 'https://img.test/local-album-cover-$index.jpg',
    );
  });
  final playlist = Playlist(
    id: 'multi-artwork-playlist',
    name: 'Muchas portadas',
    trackIds: localTracks.map((track) => track.id).toList(growable: false),
    createdAt: now,
    updatedAt: now,
  );
  final entries = List<PlaylistEntry>.generate(9, (index) {
    final videoId = localTracks[index].sourceId!;
    return PlaylistEntry(
      id: 'entry-$index',
      playlistId: playlist.id,
      track: CatalogTrack.youtube(
        videoId: videoId,
        title: localTracks[index].title,
        thumbnailUrl: 'https://img.test/album-cover-$index.jpg',
      ),
      localTrackId: localTracks[index].id,
      remoteVideoId: videoId,
      position: index,
      createdAt: now,
      updatedAt: now,
    );
  });
  return _RemoteCatalogFixture(
    now: now,
    playlist: playlist,
    catalog: CatalogPlaylist(playlist: playlist, entries: entries),
    libraryTracks: localTracks,
  );
}
