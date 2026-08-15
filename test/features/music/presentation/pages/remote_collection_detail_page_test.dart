import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/pages/remote_collection_detail_page.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      expect(find.text('Album de contrato'), findsNWidgets(2));
      expect(find.text('Artista principal'), findsOneWidget);
      expect(find.textContaining('Album'), findsWidgets);
      expect(find.textContaining('2026'), findsOneWidget);
      expect(find.textContaining('2 canciones'), findsOneWidget);
      expect(find.text('Primera cancion'), findsOneWidget);
      expect(find.text('Segunda cancion'), findsOneWidget);
      expect(player.playCalls, 0);
      expect(playerOpens, 0);

      await tester.tap(find.byKey(const ValueKey('remote-collection-play')));
      await tester.pump();

      expect(player.playCalls, 1);
      expect(player.lastTrack, same(_tracks.first));
      expect(player.lastQueue, _tracks);
      expect(player.lastQueueSourceId, 'album:MPRE-contract');
      expect(playerOpens, 1);
    },
  );

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
    expect(find.text('Album de contrato'), findsNWidgets(2));
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
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('remote-collection-detail')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('remote-collection-back')))
          .height,
      greaterThanOrEqualTo(48),
    );

    final scrollable = find.byType(CustomScrollView);
    await tester.drag(scrollable, const Offset(0, -700));
    await tester.pumpAndSettle();

    final trackTile = find.byKey(
      const ValueKey('remote-collection-track-song-1'),
    );
    expect(trackTile, findsOneWidget);
    expect(tester.getRect(trackTile).height, greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });
}

Widget _detailApp({
  required _RecordingPlayerController player,
  required FutureProvider<List<TrackInfo>> tracksProvider,
  VoidCallback? onOpenPlayer,
  String title = 'Album de contrato',
  String subtitle = 'Artista principal',
  List<String> metadata = const ['Album', '2026'],
}) {
  return ProviderScope(
    overrides: [
      playerControllerProvider.overrideWith(() => player),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      home: RemoteCollectionDetailPage(
        title: title,
        subtitle: subtitle,
        artworkSource: null,
        queueSourceId: 'album:MPRE-contract',
        tracksProvider: tracksProvider,
        emptyMessage: 'La coleccion esta vacia.',
        errorMessage: 'No se pudo cargar la coleccion.',
        onOpenPlayer: onOpenPlayer ?? _noop,
        metadata: metadata,
      ),
    ),
  );
}

void _noop() {}

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
