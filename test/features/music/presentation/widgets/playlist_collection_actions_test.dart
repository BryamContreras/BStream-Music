import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('collections offer existing playlists before creating anything', (
    tester,
  ) async {
    final controller = _CollectionPlaylists([
      _playlist('existing', 'Mi playlist'),
    ]);
    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('playlist-picker-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('playlist-picker-create')),
      findsOneWidget,
    );
    expect(find.text('Mi playlist'), findsOneWidget);
    expect(controller.createdNames, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey('playlist-picker-option-existing')),
    );
    await tester.pumpAndSettle();

    expect(controller.destinations, ['existing']);
    expect(controller.addedTracks.single, _tracks);
    expect(controller.downloadOptions, [false]);
    expect(controller.createdNames, isEmpty);
  });

  testWidgets(
    'plus creates an editable named destination and cancellation keeps picker',
    (tester) async {
      final controller = _CollectionPlaylists([
        _playlist('existing', 'Mi playlist'),
      ]);
      await tester.pumpWidget(_app(controller));
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('playlist-picker-create')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('create-playlist-name')),
            )
            .controller!
            .text,
        'Álbum de prueba',
      );
      await tester.tap(find.byKey(const ValueKey('create-playlist-cancel')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('playlist-picker-dialog')),
        findsOneWidget,
      );
      expect(controller.createdNames, isEmpty);
      expect(controller.destinations, isEmpty);

      await tester.tap(find.byKey(const ValueKey('playlist-picker-create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('create-playlist-name')),
        'Mi nueva colección',
      );
      await tester.tap(find.byKey(const ValueKey('create-playlist-confirm')));
      await tester.pumpAndSettle();
      expect(controller.createdNames, ['Mi nueva colección']);
      expect(controller.destinations, ['new-playlist']);
      expect(controller.downloadOptions, [false]);
      expect(
        find.byKey(const ValueKey('playlist-picker-dialog')),
        findsNothing,
      );
    },
  );

  testWidgets('an empty library still offers plus on a compact scaled screen', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final controller = _CollectionPlaylists([]);
    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('playlist-picker-create')),
      findsOneWidget,
    );
    expect(find.text('Todavía no hay playlists locales.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('playlist-picker-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-playlist-confirm')));
    await tester.pumpAndSettle();
    expect(controller.createdNames, ['Álbum de prueba']);
    expect(controller.destinations, ['new-playlist']);
    expect(tester.takeException(), isNull);
  });
}

const _tracks = [
  TrackInfo(
    id: 'aaaaaaaaaaa',
    title: 'Primera',
    artist: 'Artist',
    url: 'https://youtu.be/aaaaaaaaaaa',
  ),
  TrackInfo(
    id: 'bbbbbbbbbbb',
    title: 'Segunda',
    artist: 'Artist',
    url: 'https://youtu.be/bbbbbbbbbbb',
  ),
];

Widget _app(_CollectionPlaylists controller) => ProviderScope(
  overrides: [
    playlistsControllerProvider.overrideWith(() => controller),
    libraryTracksProvider.overrideWith((ref) async => []),
    catalogPlaylistsProvider.overrideWith((ref) async => []),
    appStringsProvider.overrideWithValue(const AppStrings(AppLanguage.spanish)),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: Consumer(
        builder: (context, ref, _) => ElevatedButton(
          onPressed: () => addCollectionToPlaylist(
            context,
            ref,
            _tracks,
            initialPlaylistName: 'Álbum de prueba',
          ),
          child: const Text('Abrir'),
        ),
      ),
    ),
  ),
);

Playlist _playlist(String id, String name) => Playlist(
  id: id,
  name: name,
  trackIds: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

class _CollectionPlaylists extends PlaylistsController {
  _CollectionPlaylists(this.initial);

  final List<Playlist> initial;
  final createdNames = <String>[];
  final destinations = <String>[];
  final addedTracks = <List<TrackInfo>>[];
  final downloadOptions = <bool>[];

  @override
  Future<List<Playlist>> build() async => initial;

  @override
  Future<Playlist?> create(String name) async {
    createdNames.add(name);
    final playlist = _playlist('new-playlist', name);
    state = AsyncData([...initial, playlist]);
    return playlist;
  }

  @override
  Future<int> addRemoteTracksToPlaylist(
    String playlistId,
    Iterable<TrackInfo> tracks, {
    bool download = false,
  }) async {
    destinations.add(playlistId);
    addedTracks.add(tracks.toList());
    downloadOptions.add(download);
    return tracks.length;
  }
}
