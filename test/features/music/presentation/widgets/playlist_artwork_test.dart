import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/core/utils/image_source.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_artwork.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_artwork_mosaic.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('remote song artwork prefers its catalog cover', () {
    const track = TrackInfo(
      id: 'video000001',
      title: 'Song',
      artist: 'Artist',
      url: 'https://youtube.com/watch?v=video000001',
      thumbnailUrl: 'https://i.ytimg.com/vi/video000001/hq720.jpg',
      catalogThumbnailUrl: 'https://img.test/original-album-cover.jpg',
    );

    final artwork = preferredRemoteTrackArtworkSource(track);

    expect(artwork?.source, 'https://img.test/original-album-cover.jpg');
    expect(
      artwork?.fallbackSource,
      'https://i.ytimg.com/vi/video000001/hq720.jpg',
    );
  });

  test('video result artwork keeps the video thumbnail first', () {
    const track = TrackInfo(
      id: 'video000001',
      title: 'Official video',
      artist: 'Artist',
      url: 'https://youtube.com/watch?v=video000001',
      thumbnailUrl: 'https://i.ytimg.com/vi/video000001/hq720.jpg',
      catalogThumbnailUrl: 'https://img.test/search-video-frame.jpg',
    );

    final artwork = preferredRemoteTrackArtworkSource(
      track,
      preferCatalogArtwork: false,
    );

    expect(artwork?.source, 'https://i.ytimg.com/vi/video000001/hq720.jpg');
    expect(artwork?.fallbackSource, 'https://img.test/search-video-frame.jpg');
  });

  test('local playlist artwork prefers the canonical catalog cover', () {
    final track = LocalTrack(
      id: 'local-track',
      title: 'Song',
      artist: 'Artist',
      filePath: '/music/song.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/video-thumbnail.jpg',
      thumbnailUrl: 'https://i.ytimg.com/vi/video000001/hqdefault.jpg',
      catalogThumbnailUrl: 'https://img.test/real-album-cover.jpg',
    );

    final artwork = preferredLocalPlaylistArtworkSource(track);
    expect(artwork?.source, 'https://img.test/real-album-cover.jpg');
    expect(artwork?.fallbackSource, endsWith('video-thumbnail.jpg'));
  });

  test('individual local track keeps its saved cover as offline fallback', () {
    final track = LocalTrack(
      id: 'local-track',
      title: 'Song',
      artist: 'Artist',
      filePath: '/music/song.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/soft-saved-thumbnail.jpg',
      thumbnailUrl: 'https://i.ytimg.com/vi/video000001/hqdefault.jpg',
      catalogThumbnailUrl:
          'https://lh3.googleusercontent.com/catalog-cover=w120-h120-l90-rj',
    );

    final artwork = preferredLocalTrackArtworkSource(track);
    expect(
      artwork?.source,
      'https://lh3.googleusercontent.com/catalog-cover=w1280-h1280-l90-rj',
    );
    expect(artwork?.fallbackSource, '/music/soft-saved-thumbnail.jpg');
  });

  test('individual local track prefers its remote video over a soft file', () {
    final track = LocalTrack(
      id: 'legacy-local-track',
      title: 'Song',
      artist: 'Artist',
      filePath: '/music/song.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/soft-saved-thumbnail.jpg',
      thumbnailUrl: 'https://i.ytimg.com/vi/video000001/hqdefault.jpg',
    );

    final artwork = preferredLocalTrackArtworkSource(track);
    expect(artwork?.source, 'https://i.ytimg.com/vi/video000001/hqdefault.jpg');
    expect(artwork?.fallbackSource, '/music/soft-saved-thumbnail.jpg');
  });

  test('individual legacy track upgrades its old small Google artwork URL', () {
    final track = LocalTrack(
      id: 'legacy-google-track',
      title: 'Bonsai',
      artist: 'Artist',
      filePath: '/music/bonsai.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/soft-bonsai.jpg',
      thumbnailUrl: 'https://lh3.googleusercontent.com/bonsai=w120-h120-l90-rj',
    );

    final artwork = preferredLocalTrackArtworkSource(track);
    expect(
      artwork?.source,
      'https://lh3.googleusercontent.com/bonsai=w1280-h1280-l90-rj',
    );
    expect(artwork?.fallbackSource, '/music/soft-bonsai.jpg');
  });

  test(
    'individual device track preserves its lazy embedded artwork source',
    () {
      final source = deviceAudioArtworkSourceForUri(
        'content://media/external/audio/media/42',
      );
      final track = LocalTrack(
        id: 'external-track',
        title: 'Song',
        artist: 'Artist',
        filePath: 'content://media/external/audio/media/42',
        addedAt: DateTime.utc(2026),
        thumbnailUrl: source,
        isExternal: true,
      );

      final artwork = preferredLocalTrackArtworkSource(track);

      expect(artwork?.source, source);
      expect(artwork?.fallbackSource, isNull);
    },
  );

  test('catalog playlist artwork stays canonical before local fallbacks', () {
    final local = LocalTrack(
      id: 'local-track',
      title: 'Song',
      artist: 'Artist',
      filePath: '/music/song.m4a',
      addedAt: DateTime.utc(2026),
      thumbnailPath: '/music/video-thumbnail.jpg',
      catalogThumbnailUrl: 'https://img.test/local-catalog-cover.jpg',
    );
    final catalog = CatalogTrack.youtube(
      videoId: 'video000001',
      title: 'Song',
      thumbnailUrl: 'https://img.test/playlist-catalog-cover.jpg',
    );

    final artwork = preferredCatalogPlaylistArtworkSource(
      catalog,
      localTrack: local,
    );
    expect(artwork?.source, 'https://img.test/local-catalog-cover.jpg');
    expect(artwork?.fallbackSource, endsWith('video-thumbnail.jpg'));
  });

  test(
    'individual catalog row upgrades artwork and keeps offline fallback',
    () {
      final local = LocalTrack(
        id: 'local-track',
        title: 'Song',
        artist: 'Artist',
        filePath: '/music/song.m4a',
        addedAt: DateTime.utc(2026),
        thumbnailPath: '/music/video-thumbnail.jpg',
      );
      final catalog = CatalogTrack.youtube(
        videoId: 'video000001',
        title: 'Song',
        thumbnailUrl:
            'https://lh3.googleusercontent.com/catalog-cover=w226-h226-l90-rj',
      );

      final artwork = preferredCatalogTrackArtworkSource(
        catalog,
        localTrack: local,
      );
      expect(
        artwork?.source,
        'https://lh3.googleusercontent.com/catalog-cover=w1280-h1280-l90-rj',
      );
      expect(artwork?.fallbackSource, '/music/video-thumbnail.jpg');
    },
  );

  test('playlist rotation is stable within a day and changes later', () {
    final candidates = List<PlaylistArtworkSource>.generate(
      11,
      (index) =>
          PlaylistArtworkSource(source: 'https://img.test/cover-$index.jpg'),
    );
    final morning = DateTime(2026, 8, 23, 8);
    final evening = DateTime(2026, 8, 23, 22);
    final tomorrow = DateTime(2026, 8, 24, 8);

    final first = rotatingPlaylistArtworkSources(
      playlistId: 'playlist-a',
      candidates: candidates,
      now: morning,
    );
    final sameDay = rotatingPlaylistArtworkSources(
      playlistId: 'playlist-a',
      candidates: candidates,
      now: evening,
    );
    final nextDay = rotatingPlaylistArtworkSources(
      playlistId: 'playlist-a',
      candidates: candidates,
      now: tomorrow,
    );

    expect(first, hasLength(playlistArtworkSourceLimit));
    expect(first.toSet(), hasLength(playlistArtworkSourceLimit));
    expect(sameDay, first);
    expect(nextDay, isNot(first));
  });

  test(
    'visit seed preserves selection across rebuilds and rotates next visit',
    () {
      final candidates = List<PlaylistArtworkSource>.generate(
        16,
        (index) => PlaylistArtworkSource(source: 'https://img.test/$index.jpg'),
      );
      final first = rotatingPlaylistArtworkSources(
        playlistId: 'visit-playlist',
        candidates: candidates,
        rotationSeed: 812,
        now: DateTime(2026, 10, 26),
      );
      final rebuilt = rotatingPlaylistArtworkSources(
        playlistId: 'visit-playlist',
        candidates: candidates,
        rotationSeed: 812,
        now: DateTime(2026, 10, 27),
      );
      final nextVisit = rotatingPlaylistArtworkSources(
        playlistId: 'visit-playlist',
        candidates: candidates,
        rotationSeed: 813,
      );

      expect(first, hasLength(4));
      expect(first.toSet(), hasLength(4));
      expect(rebuilt, first);
      expect(nextVisit.first, isNot(first.first));
      expect(nextVisit, isNot(first));
    },
  );

  test(
    'mosaic selection deduplicates, preserves fallbacks and caps at four',
    () {
      final candidates = <PlaylistArtworkSource?>[
        null,
        const PlaylistArtworkSource(source: '  '),
        const PlaylistArtworkSource(
          source: ' https://img.test/0.jpg ',
          fallbackSource: ' https://img.test/backup.jpg ',
        ),
        const PlaylistArtworkSource(source: 'https://img.test/0.jpg'),
        for (var index = 1; index < 12; index++)
          PlaylistArtworkSource(source: 'https://img.test/$index.jpg'),
      ];

      final covers = rotatingPlaylistArtworkSources(
        playlistId: 'deduplicated',
        candidates: candidates,
        rotationSeed: 1,
        maximum: 99,
      );
      final allCandidates = rotatingPlaylistArtworkSources(
        playlistId: 'deduplicated',
        candidates: candidates.take(4),
        rotationSeed: 1,
      );

      expect(covers, hasLength(4));
      expect(covers.map((cover) => cover.source).toSet(), hasLength(4));
      expect(allCandidates, hasLength(1));
      expect(allCandidates.single.source, 'https://img.test/0.jpg');
      expect(
        allCandidates.single.fallbackSource,
        'https://img.test/backup.jpg',
      );
      expect(
        rotatingPlaylistArtworkSources(
          playlistId: 'deduplicated',
          candidates: candidates,
          rotationSeed: 1,
          maximum: 2,
        ),
        hasLength(2),
      );
    },
  );

  testWidgets('mosaic fills four equal cells at picker and header sizes', (
    tester,
  ) async {
    final sources = List<PlaylistArtworkSource>.generate(
      3,
      (index) => PlaylistArtworkSource(source: '/missing-cover-$index.jpg'),
    );
    for (final size in <double>[44, 56, 200]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: PlaylistArtworkMosaic(sources: sources, size: size),
          ),
        ),
      );
      final images = tester.widgetList<SourceImage>(find.byType(SourceImage));
      expect(images.map((image) => image.source), <String>[
        sources[0].source,
        sources[1].source,
        sources[2].source,
        sources[0].source,
      ]);
      for (final element in find.byType(SourceImage).evaluate()) {
        expect(
          tester.getSize(find.byWidget(element.widget)),
          Size.square(size / 2),
        );
      }
      expect(tester.takeException(), isNull);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: PlaylistArtworkMosaic(
            sources: sources.take(1).toList(),
            size: 56,
          ),
        ),
      ),
    );
    expect(find.byType(SourceImage), findsOneWidget);
    expect(tester.getSize(find.byType(SourceImage)), const Size.square(56));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'decoded landscape and portrait covers fill each square without gaps',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('bstream_mosaic_layout_'),
      );
      final folder = directory!;
      addTearDown(() {
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        folder.deleteSync(recursive: true);
      });
      final dimensions = <Size>[
        const Size(160, 80),
        const Size(80, 160),
        const Size(80, 80),
        const Size(240, 90),
      ];
      final files = <File>[];
      await tester.runAsync(() async {
        for (var index = 0; index < dimensions.length; index++) {
          final file = File('${folder.path}/cover-$index.png');
          await _writeSolidImage(
            file,
            dimensions[index],
            Colors.primaries[index],
          );
          files.add(file);
        }
      });
      final sources = files
          .map((file) => PlaylistArtworkSource(source: file.path))
          .toList(growable: false);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      for (final size in <double>[44, 56, 200]) {
        await _precacheMosaicImages(tester, files, (size / 2).ceil());
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: PlaylistArtworkMosaic(sources: sources, size: size),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pumpAndSettle();
        final images = find.byType(RawImage);
        expect(images, findsNWidgets(4));
        final mosaicRect = tester.getRect(find.byType(PlaylistArtworkMosaic));
        final expectedCellSize = Size.square(size / 2);
        final expectedRects = <Rect>[
          Rect.fromLTWH(mosaicRect.left, mosaicRect.top, size / 2, size / 2),
          Rect.fromLTWH(
            mosaicRect.center.dx,
            mosaicRect.top,
            size / 2,
            size / 2,
          ),
          Rect.fromLTWH(
            mosaicRect.left,
            mosaicRect.center.dy,
            size / 2,
            size / 2,
          ),
          Rect.fromLTWH(
            mosaicRect.center.dx,
            mosaicRect.center.dy,
            size / 2,
            size / 2,
          ),
        ];
        for (var index = 0; index < 4; index++) {
          final image = images.at(index);
          final renderImage = tester.renderObject<RenderImage>(image);
          expect(renderImage.image, isNotNull);
          expect(renderImage.fit, BoxFit.cover);
          expect(renderImage.size, expectedCellSize);
          expect(tester.getRect(image), expectedRects[index]);
          expect(
            renderImage.image!.width / renderImage.image!.height,
            closeTo(dimensions[index].aspectRatio, 0.2),
            reason: 'The decoded image must retain its original aspect ratio.',
          );
        }
        expect(tester.takeException(), isNull);
      }

      // A playlist with one source should use the complete square, rather
      // than receiving the height of that source's landscape bitmap.
      await _precacheMosaicImages(tester, files.take(1), 56);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlaylistArtworkMosaic(
                sources: sources.take(1).toList(),
                size: 56,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pumpAndSettle();
      final image = find.byType(RawImage);
      expect(image, findsOneWidget);
      final renderImage = tester.renderObject<RenderImage>(image);
      expect(renderImage.image, isNotNull);
      expect(renderImage.size, const Size.square(56));
      expect(renderImage.fit, BoxFit.cover);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    },
  );
}

Future<void> _writeSolidImage(File file, Size size, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Future<void> _precacheMosaicImages(
  WidgetTester tester,
  Iterable<File> files,
  int decodeWidth,
) async {
  final context = tester.element(find.byType(Scaffold));
  await tester.runAsync(() async {
    await Future.wait(
      files.map(
        (file) => precacheImage(
          ResizeImage(FileImage(file), width: decodeWidth),
          context,
        ),
      ),
    );
  });
}
