import 'dart:async';

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/pages/artist_profile_page.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'long artist biography expands and collapses without losing its text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final description = List.filled(
        12,
        'Una biografía completa del artista con sus comienzos, discos y conciertos.',
      ).join(' ');
      final service = _ArtistProfileService()..profileDescription = description;
      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: _RecordingPlayerController(),
        ),
      );
      await tester.pumpAndSettle();
      final biography = find.byKey(
        const ValueKey('artist-profile-description'),
      );
      final toggle = find.byKey(const ValueKey('artist-description-toggle'));
      final collapsedHeight = tester.getSize(biography).height;
      expect(tester.widget<Text>(biography).maxLines, 4);
      expect(tester.widget<Text>(biography).data, description);
      expect(toggle, findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(biography).maxLines, isNull);
      expect(tester.getSize(biography).height, greaterThan(collapsedHeight));
      expect(
        find.text(const AppStrings(AppLanguage.spanish).showLess),
        findsOneWidget,
      );
      await tester.drag(
        find.byKey(const ValueKey('artist-profile-scroll')),
        const Offset(0, -850),
      );
      await tester.pumpAndSettle();
      expect(toggle.hitTestable(), findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(biography).maxLines, 4);
      expect(tester.getSize(biography).height, collapsedHeight);
      expect(tester.widget<Text>(biography).data, description);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('short artist biography has no expansion control', (
    tester,
  ) async {
    final service = _ArtistProfileService()
      ..profileDescription = 'Cantante y compositor.';
    await tester.pumpWidget(
      _artistProfileApp(service: service, player: _RecordingPlayerController()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cantante y compositor.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('artist-description-toggle')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'view all opens the advertised artist songs target and plays its queue',
    (tester) async {
      final service = _ArtistProfileService()
        ..profilePopularSongs = _popularSongs
        ..profileSongsBrowseTarget = _allSongsTarget
        ..allArtistSongs = _artistPlaySongs;
      final player = _RecordingPlayerController();
      var playerOpens = 0;
      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: player,
          onOpenPlayer: () => playerOpens++,
        ),
      );
      await tester.pumpAndSettle();
      expect(service.artistSongsCalls, 0);
      await _openAllArtistSongs(tester);
      expect(service.artistSongsCalls, 1);
      expect(service.lastArtistSongsTarget, _allSongsTarget);
      expect(service.lastArtistSongsTarget?.params, 'opaque-songs-params');
      expect(service.playlistNextCalls, 0);
      expect(service.relatedNextCalls, 0);
      expect(find.byKey(const ValueKey('artist-songs-page')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('remote-collection-title')))
            .data,
        'Artista de prueba',
      );
      expect(
        find.textContaining(
          const AppStrings(AppLanguage.spanish).collectionSongCount(5),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('remote-collection-track-artistPlaySong01')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('remote-collection-play')));
      await tester.pumpAndSettle();
      expect(player.playCalls, 1);
      expect(player.lastTrack?.id, 'artistPlaySong01');
      expect(
        player.lastQueue?.map((track) => track.id),
        _artistPlaySongs.map((song) => song.videoId),
      );
      expect(
        player.lastQueue!.every(
          (track) => Uri.parse(track.url).queryParameters['v'] == track.id,
        ),
        isTrue,
      );
      expect(player.lastQueueSourceId, 'artist:UCartist123:songs');
      expect(playerOpens, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'artist songs retry recovers and labels a partially loaded catalog',
    (tester) async {
      final service = _ArtistProfileService()
        ..profilePopularSongs = _popularSongs
        ..profileSongsBrowseTarget = _allSongsTarget
        ..artistSongsError = StateError('temporary browse failure');
      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: _RecordingPlayerController(),
        ),
      );
      await tester.pumpAndSettle();
      await _openAllArtistSongs(tester);
      expect(
        find.byKey(const ValueKey('remote-collection-error')),
        findsOneWidget,
      );
      expect(service.artistSongsCalls, 1);
      service
        ..artistSongsError = null
        ..allArtistSongs = _artistPlaySongs
        ..artistSongsComplete = false
        ..artistSongsTotal = 50;
      await tester.tap(find.byKey(const ValueKey('remote-collection-retry')));
      await tester.pumpAndSettle();
      expect(service.artistSongsCalls, 2);
      expect(service.lastArtistSongsTarget, _allSongsTarget);
      expect(
        find.byKey(const ValueKey('remote-collection-error')),
        findsNothing,
      );
      expect(
        find.textContaining(
          const AppStrings(AppLanguage.spanish).artistSongsLoadedCount(5, 50),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial artist songs with no advertised total show the loaded count',
    (tester) async {
      final service = _ArtistProfileService()
        ..profilePopularSongs = _popularSongs
        ..profileSongsBrowseTarget = _allSongsTarget
        ..allArtistSongs = _artistPlaySongs
        ..artistSongsComplete = false;
      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: _RecordingPlayerController(),
        ),
      );
      await tester.pumpAndSettle();
      await _openAllArtistSongs(tester);
      expect(
        find.textContaining(
          const AppStrings(AppLanguage.spanish).artistSongsPartialCount(5),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final releaseGroup in [
    (title: 'Álbumes', target: _allAlbumsTarget, keySuffix: 'albumes'),
    (title: 'Sencillos', target: _allSinglesTarget, keySuffix: 'sencillos'),
  ]) {
    testWidgets(
      'view all ${releaseGroup.keySuffix} opens the artist release grid',
      (tester) async {
        final service = _ArtistProfileService()
          ..profileAlbumsBrowseTarget = _allAlbumsTarget
          ..profileSinglesBrowseTarget = _allSinglesTarget
          ..profileAlbums = [
            InnerTubeAlbum(
              browseId: 'MPREpreviewAlbum',
              title: 'Álbum visible',
              artists: const ['Artista de prueba'],
              type: 'Album',
            ),
          ]
          ..profileSingles = [
            InnerTubeAlbum(
              browseId: 'MPREpreviewSingle',
              title: 'Sencillo visible',
              artists: const ['Artista de prueba'],
              type: 'Single',
            ),
          ]
          ..allArtistReleases = [
            InnerTubeAlbum(
              browseId: 'MPREgridRelease01',
              title: 'Lanzamiento uno',
              artists: const ['Artista de prueba'],
              type: 'Album',
              year: '2025',
            ),
            InnerTubeAlbum(
              browseId: 'MPREgridRelease02',
              title: 'Lanzamiento dos',
              artists: const ['Artista de prueba'],
              type: 'Album',
              year: '2024',
            ),
          ];
        await tester.pumpWidget(
          _artistProfileApp(
            service: service,
            player: _RecordingPlayerController(),
            artistThumbnailUrl: 'https://img.test/artist.jpg',
          ),
        );
        await tester.pumpAndSettle();

        final viewAll = find.byKey(
          ValueKey('artist-view-all-${releaseGroup.title}'),
        );
        await tester.dragUntilVisible(
          viewAll,
          find.byKey(const ValueKey('artist-profile-scroll')),
          const Offset(0, -220),
        );
        expect(viewAll, findsOneWidget);
        final sectionTitle = find.text(releaseGroup.title);
        expect(
          tester.getCenter(sectionTitle).dy,
          closeTo(tester.getCenter(viewAll).dy, 0.01),
        );
        await tester.ensureVisible(viewAll);
        await tester.tap(viewAll);
        await tester.pumpAndSettle();

        expect(service.lastArtistReleaseTarget, releaseGroup.target);
        expect(service.artistReleaseCalls, 1);
        expect(
          find.byKey(const ValueKey('artist-releases-page')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('artist-releases-artwork')),
          findsOneWidget,
        );
        final artistArtwork = tester.widget<SourceImage>(
          find.descendant(
            of: find.byKey(const ValueKey('artist-releases-artwork')),
            matching: find.byType(SourceImage),
          ),
        );
        expect(artistArtwork.source, 'https://img.test/artist.jpg');
        expect(find.text('Artista de prueba'), findsOneWidget);
        expect(
          find.text('2 ${releaseGroup.title.toLowerCase()}'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('artist-release-grid-MPREgridRelease01')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('artist-release-grid-MPREgridRelease02')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'view all ${releaseGroup.keySuffix} uses the complete profile shelf without an endpoint',
      (tester) async {
        final service = _ArtistProfileService()
          ..profileAlbums = _shelfReleases
          ..profileSingles = _shelfReleases;
        await tester.pumpWidget(
          _artistProfileApp(
            service: service,
            player: _RecordingPlayerController(),
          ),
        );
        await tester.pumpAndSettle();
        await _openAllArtistReleases(tester, releaseGroup.title);

        expect(service.artistReleaseCalls, 0);
        expect(
          find.text('2 ${releaseGroup.title.toLowerCase()}'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('artist-release-grid-MPREshelfRelease01')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('artist-release-grid-MPREshelfRelease02')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('artist-releases-partial')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final fromGrid in [false, true]) {
    for (final isSingle in [false, true]) {
      final releaseType = isSingle ? 'single' : 'album';
      final route = fromGrid ? 'view all grid' : 'artist shelf';
      testWidgets(
        '$route $releaseType playback preserves the selected release cover for every queued song',
        (tester) async {
          const strings = AppStrings(AppLanguage.spanish);
          const coverUrl = 'https://lh3.googleusercontent.com/album-cover';
          final release = InnerTubeAlbum(
            browseId: 'MPREartworkRelease',
            title: 'Lanzamiento con portada propia',
            artists: const ['Artista de prueba'],
            type: isSingle ? 'Single' : 'Album',
            thumbnailUrl: coverUrl,
          );
          final videoArtworkTracks = [
            for (var index = 1; index <= 2; index++)
              TrackInfo(
                id: 'albumVideo$index',
                title: 'Cancion $index',
                artist: 'Artista de prueba',
                url: 'https://www.youtube.com/watch?v=albumVideo$index',
                thumbnailUrl:
                    'https://i.ytimg.com/vi/albumVideo$index/hqdefault.jpg',
                catalogThumbnailUrl:
                    'https://i.ytimg.com/vi/albumVideo$index/hqdefault.jpg',
              ),
          ];
          final service = _ArtistProfileService()
            ..profileAlbums = isSingle ? [] : [release]
            ..profileSingles = isSingle ? [release] : []
            ..profileAlbumsBrowseTarget = _allAlbumsTarget
            ..profileSinglesBrowseTarget = _allSinglesTarget
            ..allArtistReleases = [release];
          final player = _RecordingPlayerController();
          var playerOpens = 0;
          await tester.pumpWidget(
            _artistProfileApp(
              service: service,
              player: player,
              onOpenPlayer: () => playerOpens++,
              albumTracks: {release.browseId: videoArtworkTracks},
            ),
          );
          await tester.pumpAndSettle();

          if (fromGrid) {
            await _openAllArtistReleases(
              tester,
              isSingle ? strings.singles : strings.albums,
            );
          }
          final releaseCard = find.byKey(
            ValueKey(
              '${fromGrid ? 'artist-release-grid' : 'artist-release'}-${release.browseId}',
            ),
          );
          await tester.ensureVisible(releaseCard);
          await tester.tap(releaseCard);
          await tester.pumpAndSettle();

          final play = fromGrid
              ? find.byKey(
                  const ValueKey('remote-collection-track-albumVideo2'),
                )
              : find.byKey(const ValueKey('remote-collection-play'));
          await tester.ensureVisible(play);
          await tester.tap(play);
          await tester.pumpAndSettle();

          expect(player.playCalls, 1);
          expect(
            player.lastTrack?.id,
            fromGrid ? 'albumVideo2' : 'albumVideo1',
          );
          expect(player.lastTrack?.thumbnailUrl, coverUrl);
          expect(player.lastTrack?.catalogThumbnailUrl, coverUrl);
          expect(
            player.lastTrack?.metadataSource,
            TrackMetadataSource.youtubeMusic,
          );
          expect(player.lastQueue?.map((track) => track.id), [
            'albumVideo1',
            'albumVideo2',
          ]);
          for (final track in player.lastQueue!) {
            expect(track.thumbnailUrl, coverUrl);
            expect(track.catalogThumbnailUrl, coverUrl);
            expect(track.metadataSource, TrackMetadataSource.youtubeMusic);
          }
          expect(
            player.lastQueueSourceId,
            'artist:UCartist123:${release.browseId}',
          );
          expect(playerOpens, 1);
          // The provider's original video metadata must remain untouched.
          expect(
            videoArtworkTracks.first.thumbnailUrl,
            'https://i.ytimg.com/vi/albumVideo1/hqdefault.jpg',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final failure in ['empty', 'error']) {
    testWidgets(
      'an $failure catalog keeps known releases and lets the artist catalog retry',
      (tester) async {
        final service = _ArtistProfileService()
          ..profileAlbumsBrowseTarget = _allAlbumsTarget
          ..profileAlbums = _shelfReleases
          ..artistReleaseError = failure == 'error'
              ? StateError('catalog temporarily unavailable')
              : null;
        await tester.pumpWidget(
          _artistProfileApp(
            service: service,
            player: _RecordingPlayerController(),
          ),
        );
        await tester.pumpAndSettle();
        await _openAllArtistReleases(
          tester,
          const AppStrings(AppLanguage.spanish).albums,
        );

        expect(service.artistReleaseCalls, 1);
        expect(find.text('2+ álbumes'), findsOneWidget);
        expect(find.text('0 álbumes'), findsNothing);
        expect(
          find.byKey(const ValueKey('artist-release-grid-MPREshelfRelease01')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('artist-releases-partial')),
          findsOneWidget,
        );
        expect(
          find.text(const AppStrings(AppLanguage.spanish).searchBrowseEmpty),
          findsNothing,
        );

        service
          ..artistReleaseError = null
          ..allArtistReleases = _shelfReleases;
        await tester.tap(find.byKey(const ValueKey('artist-releases-retry')));
        await tester.pumpAndSettle();

        expect(service.artistReleaseCalls, 2);
        expect(find.text('2 álbumes'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('artist-releases-partial')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a partial catalog retains known releases and prefers refreshed duplicates',
    (tester) async {
      final service = _ArtistProfileService()
        ..profileAlbumsBrowseTarget = _allAlbumsTarget
        ..profileAlbums = _shelfReleases
        ..artistReleasesComplete = false
        ..allArtistReleases = [
          InnerTubeAlbum(
            browseId: 'MPREshelfRelease01',
            title: 'Lanzamiento actualizado',
            artists: const ['Artista de prueba'],
          ),
          InnerTubeAlbum(
            browseId: 'MPREfetchedRelease03',
            title: 'Lanzamiento adicional',
            artists: const ['Artista de prueba'],
          ),
        ];
      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: _RecordingPlayerController(),
        ),
      );
      await tester.pumpAndSettle();
      await _openAllArtistReleases(
        tester,
        const AppStrings(AppLanguage.spanish).albums,
      );

      expect(find.text('3+ álbumes'), findsOneWidget);
      expect(find.text('Lanzamiento actualizado'), findsOneWidget);
      expect(find.text('Lanzamiento visible 1'), findsNothing);
      expect(find.text('Lanzamiento visible 2'), findsOneWidget);
      final first = find.byKey(
        const ValueKey('artist-release-grid-MPREshelfRelease01'),
      );
      final second = find.byKey(
        const ValueKey('artist-release-grid-MPREfetchedRelease03'),
      );
      final third = find.byKey(
        const ValueKey('artist-release-grid-MPREshelfRelease02'),
      );
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      expect(third, findsOneWidget);
      expect(
        tester.getTopLeft(first).dx,
        lessThan(tester.getTopLeft(second).dx),
      );
      expect(
        tester.getTopLeft(second).dx,
        lessThan(tester.getTopLeft(third).dx),
      );
      expect(
        find.byKey(const ValueKey('artist-releases-partial')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('artist-releases-retry')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('known artist releases remain visible during catalog loading', (
    tester,
  ) async {
    final blocker = Completer<InnerTubeArtistReleaseCatalog>();
    final service = _ArtistProfileService()
      ..profileAlbumsBrowseTarget = _allAlbumsTarget
      ..profileAlbums = _shelfReleases
      ..artistReleaseBlocker = blocker;
    await tester.pumpWidget(
      _artistProfileApp(service: service, player: _RecordingPlayerController()),
    );
    await tester.pumpAndSettle();
    final viewAll = find.byKey(const ValueKey('artist-view-all-Álbumes'));
    await tester.dragUntilVisible(
      viewAll,
      find.byKey(const ValueKey('artist-profile-scroll')),
      const Offset(0, -220),
    );
    await tester.tap(viewAll);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const ValueKey('artist-release-grid-MPREshelfRelease01')),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('0 álbumes'), findsNothing);

    blocker.complete(
      InnerTubeArtistReleaseCatalog(releases: _shelfReleases, isComplete: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 álbumes'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1440.0]) {
    testWidgets(
      'artist section titles, songs and releases share margins at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _ArtistProfileService()
          ..profilePopularSongs = _popularSongs
          ..profileAlbums = [
            InnerTubeAlbum(
              browseId: 'aligned-release',
              title: 'Album',
              artists: const ['Artista de prueba'],
            ),
          ];
        await tester.pumpWidget(
          _artistProfileApp(
            service: service,
            player: _RecordingPlayerController(),
          ),
        );
        await tester.pumpAndSettle();
        final expectedLeft = width > 1092 ? (width - 1080) / 2 : 6.0;
        final songRect = tester.getRect(
          find.byKey(const ValueKey('artist-popular-popularSong01')),
        );
        expect(songRect.left, closeTo(expectedLeft, 0.01));
        expect(songRect.right, closeTo(width - expectedLeft, 0.01));
        final popularTitle = find.text(
          const AppStrings(AppLanguage.spanish).popularSongs,
        );
        expect(
          tester.getRect(popularTitle).left,
          closeTo(songRect.left + 6, 0.01),
        );
        final albumTitle = find.text(
          const AppStrings(AppLanguage.spanish).albums,
        );
        expect(
          tester.getRect(albumTitle).left,
          closeTo(songRect.left + 6, 0.01),
        );
        expect(
          tester
              .getRect(
                find.byKey(const ValueKey('artist-release-aligned-release')),
              )
              .left,
          closeTo(songRect.left + 2, 0.01),
        );
        final release = find.byKey(
          const ValueKey('artist-release-aligned-release'),
        );
        expect(
          tester
              .getRect(
                find.descendant(
                  of: release,
                  matching: find.byType(SourceImage),
                ),
              )
              .left,
          closeTo(songRect.left + 2, 0.01),
        );
        expect(
          tester
              .getRect(
                find.descendant(of: release, matching: find.text('Album')),
              )
              .left,
          closeTo(songRect.left + 2, 0.01),
        );
        final photoRect = tester.getRect(
          find.byKey(const ValueKey('artist-profile-artwork')),
        );
        if (width > 700) {
          expect(photoRect.left, closeTo(songRect.left, 0.01));
        } else {
          expect(photoRect.center.dx, closeTo(width / 2, 0.01));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [320.0, 1000.0]) {
    testWidgets('artist square release cards grow subtly at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final service = _ArtistProfileService()
        ..profileAlbums = [
          InnerTubeAlbum(
            browseId: 'MPREtestRelease',
            title: 'A longer release title',
            artists: const ['Artista de prueba'],
            year: '2026',
            type: 'Album',
          ),
        ];
      await tester.pumpWidget(
        _artistProfileApp(
          service: service,
          player: _RecordingPlayerController(),
        ),
      );
      await tester.pumpAndSettle();

      final card = find.byKey(const ValueKey('artist-release-MPREtestRelease'));
      final image = find.descendant(
        of: card,
        matching: find.byType(SourceImage),
      );
      final cardSize = tester.getSize(card);
      final imageSize = tester.getSize(image);
      expect(cardSize.width, width < 700 ? 156 : 186);
      expect(imageSize.width, cardSize.width - 8);
      expect(imageSize.height, imageSize.width);
      final subtitle = find.descendant(
        of: card,
        matching: find.text('Album • 2026'),
      );
      expect(subtitle, findsOneWidget);
      expect(
        tester.getBottomLeft(subtitle).dy,
        lessThan(tester.getBottomLeft(card).dy),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('artist app bar respects every surface background mode', (
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
      final appBarFinder = find.byKey(const ValueKey('artist-profile-app-bar'));
      final appBarWidget = tester.widget<AppBar>(appBarFinder);
      final tonalSurface = Theme.of(
        tester.element(appBarFinder),
      ).colorScheme.surface;
      final transparent = mode == SurfaceBackgroundMode.transparent;
      expect(
        decoration.gradient,
        mode.isLiquidGlass ? isNull : isA<LinearGradient>(),
      );
      expect(decoration.border, isNull);
      expect(
        find.byKey(const ValueKey('artist-profile-app-bar-blur')),
        transparent ? findsOneWidget : findsNothing,
      );
      if (mode.isLiquidGlass) {
        expect(
          decoration.color,
          AppColors.tabHeaderSurfaceFor(
            tester.element(appBarFinder),
            scrolledUnder: true,
          ),
        );
      } else {
        expect(decoration.color!.a, transparent ? lessThan(1) : 1);
      }
      expect(
        find.descendant(
          of: appBarFinder,
          matching: find.byType(LiquidGlassSurface),
        ),
        mode.isLiquidGlass ? findsOneWidget : findsNothing,
      );
      expect(
        find.descendant(
          of: appBarFinder,
          matching: find.byType(BackdropFilter),
        ),
        transparent || mode.isLiquidGlass ? findsOneWidget : findsNothing,
      );
      expect(
        appBarWidget.forceMaterialTransparency,
        transparent || mode.isLiquidGlass,
      );
      expect(
        appBarWidget.backgroundColor,
        transparent || mode.isLiquidGlass
            ? Colors.transparent
            : decoration.color,
      );
      expect(appBarWidget.systemOverlayStyle?.statusBarColor, tonalSurface);
      final statusBarFinder = find.byKey(
        const ValueKey('artist-profile-status-bar-surface'),
      );
      final statusBarFill = tester.widget<ColoredBox>(
        find.descendant(of: statusBarFinder, matching: find.byType(ColoredBox)),
      );
      expect(statusBarFill.color, tonalSurface);
      final statusBarRect = tester.getRect(statusBarFinder);
      final toolbarSurfaceRect = tester.getRect(
        find.byKey(const ValueKey('artist-profile-app-bar-surface')),
      );
      expect(statusBarRect.height, 24);
      expect(statusBarRect.bottom, toolbarSurfaceRect.top);
      expect(toolbarSurfaceRect.height, kToolbarHeight);
      expect(
        tester
            .widget<Scaffold>(find.byKey(const ValueKey('artist-profile-page')))
            .extendBodyBehindAppBar,
        isTrue,
      );
      final spacer = tester.getSize(
        find.byKey(const ValueKey('artist-profile-app-bar-spacer')),
      );
      final appBar = tester.getSize(appBarFinder);
      expect(spacer.height, appBar.height);
    }
  });

  testWidgets('artist glass app bar restores its optics after scrolling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final service = _ArtistProfileService()
      ..profilePopularSongs = _popularSongs;
    await tester.pumpWidget(
      _artistProfileApp(
        service: service,
        player: _RecordingPlayerController(),
        surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
      ),
    );
    await tester.pumpAndSettle();

    final glassFinder = find.byKey(
      const ValueKey('surface-detail-liquid-glass'),
    );
    bool isMoving() =>
        tester.widget<LiquidGlassSurface>(glassFinder).backdropMotion;
    expect(isMoving(), isFalse);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('artist-profile-scroll'))),
    );
    await gesture.moveBy(const Offset(0, -160));
    await tester.pump();
    expect(isMoving(), isTrue);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(isMoving(), isFalse);
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
      final header = find.byKey(const ValueKey('artist-profile-header'));
      final photo = find.byKey(
        const ValueKey('artist-profile-background-photo'),
      );
      expect(find.descendant(of: header, matching: photo), findsOneWidget);
      expect(tester.getRect(photo), tester.getRect(header));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('artist-profile-artwork-underlay')),
          matching: find.byType(SourceImage),
        ),
        findsNothing,
        reason: 'Below the artist header only the artwork color is painted.',
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

  testWidgets('last artist song scrolls above the floating mini player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final service = _ArtistProfileService()
      ..profilePopularSongs = <InnerTubeSong>[
        for (var index = 1; index <= 12; index++)
          InnerTubeSong(
            videoId: 'longPopular$index',
            title: 'Popular $index',
            artists: const <String>['Artista de prueba'],
            artistBrowseIds: const <String?>['UCartist123'],
          ),
      ];

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 640),
          devicePixelRatio: 1,
          padding: EdgeInsets.only(bottom: 24),
          viewPadding: EdgeInsets.only(bottom: 24),
        ),
        child: _artistProfileApp(
          service: service,
          player: _RecordingPlayerController(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scroll = find.byKey(const ValueKey('artist-profile-scroll'));
    await tester.drag(scroll, const Offset(0, -3000));
    await tester.pumpAndSettle();

    final lastTrack = find.byKey(
      const ValueKey('artist-popular-longPopular12'),
    );
    final miniPlayer = find.byKey(const ValueKey('mini-player-container'));
    expect(lastTrack, findsOneWidget);
    expect(
      tester.getRect(lastTrack).bottom,
      lessThanOrEqualTo(tester.getRect(miniPlayer).top - 8),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('artist-profile-bottom-spacer')))
          .height,
      miniPlayerHeightFor(
            tester.element(miniPlayer),
            mode: defaultMiniPlayerMode,
          ) +
          24 +
          24,
    );
  });

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

const _allSongsTarget = InnerTubeBrowseTarget(
  browseId: 'VLOLartist-songs-target',
  params: 'opaque-songs-params',
);
const _allAlbumsTarget = InnerTubeBrowseTarget(
  browseId: 'VLartist-albums-target',
  params: 'opaque-albums-params',
);
const _allSinglesTarget = InnerTubeBrowseTarget(
  browseId: 'VLartist-singles-target',
  params: 'opaque-singles-params',
);

Future<void> _openAllArtistSongs(WidgetTester tester) async {
  final viewAll = find.byKey(const ValueKey('artist-view-all-songs'));
  await tester.dragUntilVisible(
    viewAll,
    find.byKey(const ValueKey('artist-profile-scroll')),
    const Offset(0, -220),
  );
  await tester.pumpAndSettle();
  await tester.tap(viewAll);
  await tester.pumpAndSettle();
}

Future<void> _openAllArtistReleases(WidgetTester tester, String title) async {
  final viewAll = find.byKey(ValueKey('artist-view-all-$title'));
  await tester.dragUntilVisible(
    viewAll,
    find.byKey(const ValueKey('artist-profile-scroll')),
    const Offset(0, -220),
  );
  await Scrollable.ensureVisible(tester.element(viewAll), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(viewAll);
  await tester.pumpAndSettle();
}

Widget _artistProfileApp({
  required _ArtistProfileService service,
  required _RecordingPlayerController player,
  _RecordingArtistAccount? account,
  VoidCallback? onOpenPlayer,
  String? artistThumbnailUrl,
  Map<String, List<TrackInfo>> albumTracks = const {},
  String artistBrowseId = 'UCartist123',
  SurfaceBackgroundMode surfaceBackgroundMode = SurfaceBackgroundMode.accent,
}) {
  return ProviderScope(
    overrides: [
      youtubeMusicSearchProvider.overrideWithValue(service),
      youtubeMusicArtistAccountProvider.overrideWithValue(account),
      for (final entry in albumTracks.entries)
        homeAlbumTracksProvider(
          entry.key,
        ).overrideWith((ref) async => entry.value),
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
        YouTubeMusicArtistSongsLookup,
        YouTubeMusicArtistReleaseCatalogLookup,
        YouTubeMusicRelated,
        YouTubeMusicPlaylistQueueLookup {
  int playlistNextCalls = 0;
  int relatedNextCalls = 0;
  int profileCalls = 0;
  Completer<InnerTubeArtistProfile>? profileBlocker;
  List<InnerTubeSong> profilePopularSongs = const <InnerTubeSong>[];
  List<InnerTubeAlbum> profileAlbums = const <InnerTubeAlbum>[];
  List<InnerTubeAlbum> profileSingles = const <InnerTubeAlbum>[];
  List<InnerTubeAlbum> allArtistReleases = const <InnerTubeAlbum>[];
  List<InnerTubeSong> artistPlaySongs = const <InnerTubeSong>[];
  String? profilePlayPlaylistId;
  Object? artistPlayError;
  String? lastPlaylistId;
  String? lastPlaylistSeedVideoId;
  String? profileChannelId = 'UCartist123';
  String? profileSubscriberCount;
  String? profileMonthlyListenerCount;
  String? profileDescription;
  InnerTubeBrowseTarget? profileSongsBrowseTarget;
  InnerTubeBrowseTarget? profileAlbumsBrowseTarget;
  InnerTubeBrowseTarget? profileSinglesBrowseTarget;
  int artistReleaseCalls = 0;
  InnerTubeBrowseTarget? lastArtistReleaseTarget;
  Object? artistReleaseError;
  Completer<InnerTubeArtistReleaseCatalog>? artistReleaseBlocker;
  bool artistReleasesComplete = true;
  int artistSongsCalls = 0;
  InnerTubeBrowseTarget? lastArtistSongsTarget;
  List<InnerTubeSong> allArtistSongs = const [];
  bool artistSongsComplete = true;
  int? artistSongsTotal;
  Object? artistSongsError;

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
        thumbnailUrl: fallbackThumbnailUrl,
      ),
      channelId: profileChannelId,
      subscriberCount: profileSubscriberCount,
      monthlyListenerCount: profileMonthlyListenerCount,
      description: profileDescription,
      songsBrowseTarget: profileSongsBrowseTarget,
      albumsBrowseTarget: profileAlbumsBrowseTarget,
      singlesBrowseTarget: profileSinglesBrowseTarget,
      playPlaylistId: profilePlayPlaylistId,
      radioPlaylistId: 'RDEMartistRadio123',
      radioSeedVideoId: 'radioSeed01',
      popularSongs: profilePopularSongs,
      albums: profileAlbums,
      singles: profileSingles,
    );
  }

  @override
  Future<InnerTubeArtistSongsDetail> getArtistSongs(
    InnerTubeBrowseTarget target, {
    int limit = 1000,
  }) async {
    artistSongsCalls++;
    lastArtistSongsTarget = target;
    final failure = artistSongsError;
    if (failure != null) throw failure;
    return InnerTubeArtistSongsDetail(
      songs: allArtistSongs,
      isComplete: artistSongsComplete,
      totalSongCount: artistSongsTotal,
    );
  }

  @override
  Future<InnerTubeArtistReleaseCatalog> getArtistReleaseCatalog(
    InnerTubeBrowseTarget target, {
    int limit = 1000,
  }) async {
    artistReleaseCalls++;
    lastArtistReleaseTarget = target;
    final failure = artistReleaseError;
    if (failure != null) throw failure;
    final blocker = artistReleaseBlocker;
    if (blocker != null) return blocker.future;
    return InnerTubeArtistReleaseCatalog(
      releases: allArtistReleases,
      isComplete: artistReleasesComplete,
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

final _shelfReleases = <InnerTubeAlbum>[
  for (var index = 1; index <= 2; index++)
    InnerTubeAlbum(
      browseId: 'MPREshelfRelease0$index',
      title: 'Lanzamiento visible $index',
      artists: const ['Artista de prueba'],
      type: 'Album',
    ),
];

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
