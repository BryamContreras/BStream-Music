import 'dart:async';

import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/pages/artist_profile_page.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('artist app bar respects accent and transparent surface modes', (
    tester,
  ) async {
    for (final mode in SurfaceBackgroundMode.values) {
      await tester.pumpWidget(
        _artistProfileApp(
          service: _ArtistProfileService(),
          player: _RecordingPlayerController(),
          surfaceBackgroundMode: mode,
        ),
      );
      await tester.pumpAndSettle();

      final surface = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('artist-profile-app-bar-surface')),
      );
      final decoration = surface.decoration as BoxDecoration;
      expect(decoration.gradient, isA<LinearGradient>());
      expect(decoration.border, isNull);
      expect(
        find.byKey(const ValueKey('artist-profile-app-bar-blur')),
        mode == SurfaceBackgroundMode.transparent
            ? findsOneWidget
            : findsNothing,
      );
      expect(
        decoration.color!.a,
        mode == SurfaceBackgroundMode.transparent ? lessThan(1) : 1,
      );
      expect(
        tester
            .widget<Scaffold>(find.byKey(const ValueKey('artist-profile-page')))
            .extendBodyBehindAppBar,
        isTrue,
      );
      final spacer = tester.getSize(
        find.byKey(const ValueKey('artist-profile-app-bar-spacer')),
      );
      final appBar = tester.getSize(
        find.byKey(const ValueKey('artist-profile-app-bar')),
      );
      expect(spacer.height, appBar.height);
    }
  });

  testWidgets(
    'artist identity and artwork gradient render before the profile request finishes',
    (tester) async {
      final service = _ArtistProfileService()
        ..profileBlocker = Completer<InnerTubeArtistProfile>();

      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: _RecordingPlayerController(),
          artistThumbnailUrl: 'https://img.test/artist.jpg',
        ),
      );
      await tester.pump();

      expect(find.text('Artista de prueba'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artist-profile-background-blur')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('artist-profile-background-image')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('artist-profile-background-overlay')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('artist-profile-loading')),
        findsOneWidget,
      );

      service.profileBlocker!.complete(
        InnerTubeArtistProfile(
          artist: const InnerTubeArtist(
            browseId: 'UCartist123',
            name: 'Artista de prueba',
            thumbnailUrl: 'https://img.test/artist.jpg',
          ),
          popularSongs: <InnerTubeSong>[],
          albums: <InnerTubeAlbum>[],
          singles: <InnerTubeAlbum>[],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('artist-profile-loading')),
        findsNothing,
      );
      expect(service.profileCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'artist profile provider reuses a browse response for five minutes',
    () async {
      final service = _ArtistProfileService();
      final container = ProviderContainer(
        overrides: [youtubeMusicSearchProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      const request = (
        artistBrowseId: 'UCartist123',
        artistName: 'Artista de prueba',
        artistThumbnailUrl: null,
      );

      await container.read(artistProfileProvider(request).future);
      await container.read(artistProfileProvider(request).future);

      expect(service.profileCalls, 1);
    },
  );

  testWidgets('artist header labels subscribers and monthly audience', (
    tester,
  ) async {
    final service = _ArtistProfileService()
      ..profileSubscriberCount = '41.5 M de suscriptores'
      ..profileMonthlyListenerCount = 'Público mensual: 165 M usuarios';

    await tester.pumpWidget(
      _artistProfileApp(service: service, player: _RecordingPlayerController()),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('artist-subscriber-count')),
      findsOneWidget,
    );
    expect(find.text('41.5 M de suscriptores'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('artist-monthly-listener-count')),
      findsOneWidget,
    );
    expect(find.text('Público mensual: 165 M usuarios'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mix uses the advertised InnerTube playlist and starts its complete queue',
    (tester) async {
      final service = _ArtistProfileService();
      final player = _RecordingPlayerController();
      var playerOpens = 0;

      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: player,
          onOpenPlayer: () => playerOpens += 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Mix'), findsOneWidget);
      expect(find.text('Radio'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('artist-mix')));
      await tester.pumpAndSettle();

      expect(service.playlistNextCalls, 1);
      expect(service.lastPlaylistId, 'RDEMartistRadio123');
      expect(service.lastPlaylistSeedVideoId, 'radioSeed01');
      expect(service.relatedNextCalls, 0);
      expect(player.playCalls, 1);
      expect(player.lastTrack?.id, 'radioSong01');
      expect(player.lastQueue?.map((track) => track.id), <String>[
        'radioSong01',
        'radioSong02',
      ]);
      expect(player.lastQueueSourceId, 'artist:UCartist123:radio');
      expect(playerOpens, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'play button uses the complete advertised artist queue instead of the visible shelf',
    (tester) async {
      final service = _ArtistProfileService()
        ..profilePopularSongs = _popularSongs
        ..profilePlayPlaylistId = 'RDAOartistPlay123'
        ..artistPlaySongs = _artistPlaySongs;
      final player = _RecordingPlayerController();
      var playerOpens = 0;

      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: player,
          onOpenPlayer: () => playerOpens += 1,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('artist-play-all')));
      await tester.pumpAndSettle();

      expect(service.playlistNextCalls, 1);
      expect(service.lastPlaylistId, 'RDAOartistPlay123');
      expect(service.lastPlaylistSeedVideoId, isNull);
      expect(player.playCalls, 1);
      expect(player.lastTrack?.id, 'artistPlaySong01');
      expect(player.lastQueue?.map((track) => track.id), <String>[
        'artistPlaySong01',
        'artistPlaySong02',
        'artistPlaySong03',
        'artistPlaySong04',
        'artistPlaySong05',
      ]);
      expect(player.lastQueueSourceId, 'artist:UCartist123:play');
      expect(playerOpens, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'play button falls back to visible songs when the advertised queue fails',
    (tester) async {
      final service = _ArtistProfileService()
        ..profilePopularSongs = _popularSongs
        ..profilePlayPlaylistId = 'RDAOartistPlay123'
        ..artistPlayError = StateError('temporary queue failure');
      final player = _RecordingPlayerController();

      await tester.pumpWidget(
        _artistProfileApp(service: service, player: player),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('artist-play-all')));
      await tester.pumpAndSettle();

      expect(service.playlistNextCalls, 1);
      expect(player.playCalls, 1);
      expect(player.lastQueue?.map((track) => track.id), <String>[
        'popularSong01',
        'popularSong02',
        'popularSong03',
      ]);
      expect(player.lastQueueSourceId, 'artist:UCartist123:play');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'play button starts every popular song in profile order and blocks repeats while busy',
    (tester) async {
      final service = _ArtistProfileService()
        ..profilePopularSongs = _popularSongs;
      final player = _RecordingPlayerController()
        ..playBlocker = Completer<void>();
      var playerOpens = 0;

      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: player,
          onOpenPlayer: () => playerOpens += 1,
        ),
      );
      await tester.pumpAndSettle();

      final action = find.byKey(const ValueKey('artist-play-all'));
      expect(action, findsOneWidget);
      expect(tester.widget<IconButton>(action).onPressed, isNotNull);

      await tester.tap(action);
      await tester.pump();

      expect(player.playCalls, 1);
      expect(player.lastTrack?.id, 'popularSong01');
      expect(player.lastQueue?.map((track) => track.id), <String>[
        'popularSong01',
        'popularSong02',
        'popularSong03',
      ]);
      expect(player.lastQueueSourceId, 'artist:UCartist123:play');
      expect(playerOpens, 1);
      expect(tester.widget<IconButton>(action).onPressed, isNull);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('artist-mix')))
            .onPressed,
        isNull,
      );

      player.playBlocker!.complete();
      await tester.pumpAndSettle();

      expect(tester.widget<IconButton>(action).onPressed, isNotNull);
      expect(player.playCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('play button is disabled when the artist has no popular songs', (
    tester,
  ) async {
    await tester.pumpWidget(
      _artistProfileApp(
        service: _ArtistProfileService(),
        player: _RecordingPlayerController(),
      ),
    );
    await tester.pumpAndSettle();

    final action = find.byKey(const ValueKey('artist-play-all'));
    expect(action, findsOneWidget);
    expect(tester.widget<IconButton>(action).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'authenticated artist subscription toggles exactly one mutation per tap',
    (tester) async {
      final service = _ArtistProfileService();
      final account = _RecordingArtistAccount();
      final player = _RecordingPlayerController();

      await tester.pumpWidget(
        _artistProfileApp(service: service, player: player, account: account),
      );
      await tester.pumpAndSettle();

      final action = find.byKey(const ValueKey('artist-subscription'));
      expect(action, findsOneWidget);
      expect(find.text('Suscribirse'), findsOneWidget);

      await tester.tap(action);
      await tester.pumpAndSettle();

      expect(account.subscribeCalls, 1);
      expect(account.unsubscribeCalls, 0);
      expect(account.lastSubscribedChannelId, 'UCartist123');
      expect(find.text('Cancelar suscripción'), findsOneWidget);

      await tester.tap(action);
      await tester.pumpAndSettle();

      expect(account.subscribeCalls, 1);
      expect(account.unsubscribeCalls, 1);
      expect(account.lastUnsubscribedChannelId, 'UCartist123');
      expect(find.text('Suscribirse'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('subscription action stays hidden while signed out', (
    tester,
  ) async {
    await tester.pumpWidget(
      _artistProfileApp(
        service: _ArtistProfileService(),
        player: _RecordingPlayerController(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('artist-subscription')), findsNothing);
    expect(find.text('Suscribirse'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'UC artist browse id safely supplies a missing subscription channel id',
    (tester) async {
      final service = _ArtistProfileService()..profileChannelId = null;
      final account = _RecordingArtistAccount()..reportedChannelId = null;

      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: _RecordingPlayerController(),
          account: account,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('artist-subscription')));
      await tester.pumpAndSettle();

      expect(account.subscribeCalls, 1);
      expect(account.lastSubscribedChannelId, 'UCartist123');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'MPLA artist without a concrete channel never sends an invalid mutation',
    (tester) async {
      final service = _ArtistProfileService()..profileChannelId = null;
      final account = _RecordingArtistAccount()..reportedChannelId = null;

      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: _RecordingPlayerController(),
          account: account,
          artistBrowseId: 'MPLAartist123',
        ),
      );
      await tester.pumpAndSettle();

      final action = find.byKey(const ValueKey('artist-subscription'));
      expect(action, findsOneWidget);
      await tester.tap(action);
      await tester.pump();

      expect(account.subscribeCalls, 0);
      expect(account.unsubscribeCalls, 0);
      expect(
        find.text(
          const AppStrings(AppLanguage.spanish).artistSubscriptionUnavailable,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _artistProfileApp({
  required _ArtistProfileService service,
  required _RecordingPlayerController player,
  _RecordingArtistAccount? account,
  VoidCallback? onOpenPlayer,
  String? artistThumbnailUrl,
  String artistBrowseId = 'UCartist123',
  SurfaceBackgroundMode surfaceBackgroundMode = SurfaceBackgroundMode.accent,
}) {
  return ProviderScope(
    overrides: [
      youtubeMusicSearchProvider.overrideWithValue(service),
      youtubeMusicArtistAccountProvider.overrideWithValue(account),
      playerControllerProvider.overrideWith(() => player),
      favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.android,
        extensions: [AppSurfaceTheme(backgroundMode: surfaceBackgroundMode)],
      ),
      home: ArtistProfilePage(
        artistBrowseId: artistBrowseId,
        artistName: 'Artista de prueba',
        artistThumbnailUrl: artistThumbnailUrl,
        seedVideoId: 'fallback001',
        onOpenPlayer: onOpenPlayer ?? _noop,
      ),
    ),
  );
}

void _noop() {}

class _ArtistProfileService
    implements
        YouTubeMusicSearch,
        YouTubeMusicArtistProfileLookup,
        YouTubeMusicRelated,
        YouTubeMusicPlaylistQueueLookup {
  int playlistNextCalls = 0;
  int relatedNextCalls = 0;
  int profileCalls = 0;
  Completer<InnerTubeArtistProfile>? profileBlocker;
  List<InnerTubeSong> profilePopularSongs = const <InnerTubeSong>[];
  List<InnerTubeSong> artistPlaySongs = const <InnerTubeSong>[];
  String? profilePlayPlaylistId;
  Object? artistPlayError;
  String? lastPlaylistId;
  String? lastPlaylistSeedVideoId;
  String? profileChannelId = 'UCartist123';
  String? profileSubscriberCount;
  String? profileMonthlyListenerCount;

  @override
  Future<InnerTubeArtistProfile> getArtistProfile(
    String artistBrowseId, {
    String? fallbackName,
    String? fallbackThumbnailUrl,
    int songLimit = 20,
    int releaseLimit = 20,
  }) async {
    profileCalls += 1;
    final blocker = profileBlocker;
    if (blocker != null) return blocker.future;
    return InnerTubeArtistProfile(
      artist: InnerTubeArtist(
        browseId: artistBrowseId,
        name: fallbackName ?? 'Artista de prueba',
      ),
      channelId: profileChannelId,
      subscriberCount: profileSubscriberCount,
      monthlyListenerCount: profileMonthlyListenerCount,
      playPlaylistId: profilePlayPlaylistId,
      radioPlaylistId: 'RDEMartistRadio123',
      radioSeedVideoId: 'radioSeed01',
      popularSongs: profilePopularSongs,
      albums: const <InnerTubeAlbum>[],
      singles: const <InnerTubeAlbum>[],
    );
  }

  @override
  Future<InnerTubeNextPage> getPlaylistNext(
    String playlistId, {
    String? videoId,
    int limit = innerTubeDetailResultLimit,
  }) async {
    playlistNextCalls += 1;
    lastPlaylistId = playlistId;
    lastPlaylistSeedVideoId = videoId;
    final playError = artistPlayError;
    if (playlistId == profilePlayPlaylistId && playError != null) {
      throw playError;
    }
    return InnerTubeNextPage(
      songs: playlistId == profilePlayPlaylistId
          ? artistPlaySongs
          : _radioSongs,
    );
  }

  @override
  Future<InnerTubeNextPage> getNext(
    String videoId, {
    bool radio = false,
    int limit = innerTubeDetailResultLimit,
  }) async {
    relatedNextCalls += 1;
    return InnerTubeNextPage(songs: _radioSongs);
  }

  @override
  Future<InnerTubeNextPage> getNextContinuation(
    String continuation, {
    int limit = innerTubeDetailResultLimit,
  }) => throw UnimplementedError();

  @override
  Future<InnerTubeRelatedPage> getRelated(String browseId, {int limit = 20}) =>
      throw UnimplementedError();

  @override
  Future<InnerTubeRelatedPage> getRelatedContinuation(
    String continuation, {
    int limit = 20,
  }) => throw UnimplementedError();

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async => const <InnerTubeSong>[];
}

class _RecordingArtistAccount implements YouTubeMusicArtistAccount {
  bool subscribed = false;
  String? reportedChannelId = 'UCartist123';
  int subscribeCalls = 0;
  int unsubscribeCalls = 0;
  String? lastSubscribedChannelId;
  String? lastUnsubscribedChannelId;

  @override
  Future<RemoteArtistSubscriptionState?> getArtistSubscriptionState(
    String artistBrowseId,
  ) async {
    final channelId = reportedChannelId;
    if (channelId == null) return null;
    return RemoteArtistSubscriptionState(
      channelId: channelId,
      isSubscribed: subscribed,
    );
  }

  @override
  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  subscribeArtist(String channelId) async {
    subscribeCalls += 1;
    lastSubscribedChannelId = channelId;
    subscribed = true;
    return const YouTubeMusicMutationSuccess<RemotePlaylistMutationApplied>(
      RemotePlaylistMutationApplied(),
    );
  }

  @override
  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  unsubscribeArtist(String channelId) async {
    unsubscribeCalls += 1;
    lastUnsubscribedChannelId = channelId;
    subscribed = false;
    return const YouTubeMusicMutationSuccess<RemotePlaylistMutationApplied>(
      RemotePlaylistMutationApplied(),
    );
  }
}

class _RecordingPlayerController extends PlayerController {
  int playCalls = 0;
  TrackInfo? lastTrack;
  List<TrackInfo>? lastQueue;
  String? lastQueueSourceId;
  Completer<void>? playBlocker;

  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);

  @override
  Future<void> playRemote(
    TrackInfo track, {
    List<TrackInfo>? queue,
    String? queueSourceId,
  }) async {
    playCalls += 1;
    lastTrack = track;
    lastQueue = queue == null ? null : List<TrackInfo>.unmodifiable(queue);
    lastQueueSourceId = queueSourceId;
    final blocker = playBlocker;
    if (blocker != null) await blocker.future;
  }
}

final _popularSongs = <InnerTubeSong>[
  InnerTubeSong(
    videoId: 'popularSong01',
    title: 'Popular uno',
    artists: const <String>['Artista de prueba'],
    artistBrowseIds: const <String?>['UCartist123'],
  ),
  InnerTubeSong(
    videoId: 'popularSong02',
    title: 'Popular dos',
    artists: const <String>['Artista de prueba'],
    artistBrowseIds: const <String?>['UCartist123'],
  ),
  InnerTubeSong(
    videoId: 'popularSong03',
    title: 'Popular tres',
    artists: const <String>['Artista invitado'],
    artistBrowseIds: const <String?>['UCartistGuest'],
  ),
];

final _radioSongs = <InnerTubeSong>[
  InnerTubeSong(
    videoId: 'radioSong01',
    title: 'Radio uno',
    artists: const <String>['Artista de prueba'],
    artistBrowseIds: const <String?>['UCartist123'],
  ),
  InnerTubeSong(
    videoId: 'radioSong02',
    title: 'Radio dos',
    artists: const <String>['Artista invitado'],
    artistBrowseIds: const <String?>['UCartistGuest'],
  ),
];

final _artistPlaySongs = <InnerTubeSong>[
  for (var index = 1; index <= 5; index++)
    InnerTubeSong(
      videoId: 'artistPlaySong0$index',
      title: 'Canción amplia $index',
      artists: const <String>['Artista de prueba'],
      artistBrowseIds: const <String?>['UCartist123'],
    ),
];
