import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/core/utils/cached_artwork_image_provider.dart';
import 'package:bstream_music/core/utils/image_source.dart';
import 'package:bstream_music/features/music/presentation/widgets/device_audio_artwork_image_provider.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('artwork opacity is applied directly and updates in place', (
    tester,
  ) async {
    Widget artwork(double opacity) => MaterialApp(
      home: SourceImage(
        source: 'https://example.invalid/tinted-cover.jpg',
        opacity: opacity,
        fallback: const SizedBox.shrink(),
      ),
    );
    await tester.pumpWidget(artwork(0.72));
    expect(tester.widget<Image>(find.byType(Image)).opacity?.value, 0.72);
    expect(find.byType(Opacity), findsNothing);
    await tester.pumpWidget(artwork(1));
    expect(tester.widget<Image>(find.byType(Image)).opacity, isNull);
  });

  testWidgets('player keeps the mini preview until its complete cover decodes', (
    tester,
  ) async {
    const remote = 'https://example.invalid/current-cover.jpg';
    final directory = Directory.systemTemp.createTempSync(
      'bstream-cover-scope-',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      directory.deleteSync(recursive: true);
    });
    final file = File('${directory.path}/cover.png');
    file.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    Widget scoped(int revision, String? path) => MaterialApp(
      home: PlaybackArtworkCacheScope(
        revision: revision,
        tracksSource: (source) => source == remote,
        localPathFor: (_) => path,
        child: const SourceImage(
          source: remote,
          fallback: Text('waiting for cover'),
        ),
      ),
    );

    await tester.pumpWidget(scoped(0, null));
    final pendingPreview = tester.widget<Image>(find.byType(Image));
    final previewProvider = pendingPreview.image as ResizeImage;
    expect(previewProvider.width, 256);
    expect(previewProvider.imageProvider, isA<CachedArtworkImageProvider>());

    await tester.pumpWidget(scoped(1, file.path));
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    final fullCover = images.singleWhere(
      (image) =>
          image.image is ResizeImage &&
          (image.image as ResizeImage).imageProvider is FileImage,
    );
    final frameBuilder = fullCover.frameBuilder!;
    final context = tester.element(find.byType(SourceImage).first);
    const decoded = Text('decoded frame');
    expect(frameBuilder(context, decoded, null, false), isA<Image>());
    expect(frameBuilder(context, decoded, 0, false), same(decoded));
  });

  testWidgets('hidden full player does not request remote artwork', (
    tester,
  ) async {
    for (final cachedPath in <String?>[
      null,
      'previously-completed-cover.png',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: PlaybackArtworkCacheScope(
            revision: 0,
            tracksSource: (_) => true,
            localPathFor: (_) => cachedPath,
            allowNetworkPreviews: false,
            child: const SourceImage(
              source: 'https://example.invalid/hidden-cover.jpg',
              fallback: Text('hidden cover'),
            ),
          ),
        ),
      );

      expect(find.byType(Image), findsNothing);
      expect(find.text('hidden cover'), findsOneWidget);
    }
  });

  testWidgets(
    'a sharper cached cover retains the decoded cover while its new file loads',
    (tester) async {
      const remote =
          'https://lh3.googleusercontent.com/current-cover=w120-h120-l90-rj';
      final directory = Directory.systemTemp.createTempSync(
        'bstream-cover-upgrade-',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        directory.deleteSync(recursive: true);
      });
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      );
      final previewFile = File('${directory.path}/preview.png')
        ..writeAsBytesSync(png);
      final sharpFile = File('${directory.path}/sharp.png')
        ..writeAsBytesSync(png);

      Widget scoped(int revision, String path) => MaterialApp(
        home: PlaybackArtworkCacheScope(
          revision: revision,
          tracksSource: (source) => source == remote,
          localPathFor: (_) => path,
          child: const SourceImage(
            source: remote,
            cacheWidth: 1280,
            fallback: Text('waiting for cover'),
          ),
        ),
      );
      Image cachedCover() => tester
          .widgetList<Image>(find.byType(Image))
          .singleWhere(
            (image) =>
                image.image is ResizeImage &&
                (image.image as ResizeImage).imageProvider is FileImage,
          );

      await tester.pumpWidget(scoped(1, previewFile.path));
      final previousCover = cachedCover();
      final context = tester.element(find.byType(SourceImage));
      const decodedPrevious = Text('decoded preview cover');
      expect(
        previousCover.frameBuilder!(context, decodedPrevious, 0, false),
        same(decodedPrevious),
      );

      await tester.pumpWidget(scoped(2, sharpFile.path));
      final sharperCover = cachedCover();
      final sharperProvider = sharperCover.image as ResizeImage;
      expect(sharperProvider.width, 1280);
      expect(
        (sharperProvider.imageProvider as FileImage).file.path,
        sharpFile.path,
      );
      expect(sharperCover.image, isNot(previousCover.image));
      expect(sharperCover.gaplessPlayback, isTrue);
      // Image's gapless playback retains the decoded predecessor until the
      // replacement emits a frame. Do not hide it behind a smaller preview.
      expect(
        sharperCover.frameBuilder!(context, decodedPrevious, null, false),
        same(decodedPrevious),
      );
      const decodedSharp = Text('decoded sharp cover');
      expect(
        sharperCover.frameBuilder!(context, decodedSharp, 0, false),
        same(decodedSharp),
      );

      // A decode failure replaces the retained image with the preview. A
      // later file must not assume that the full-size image is still mounted.
      expect(
        sharperCover.errorBuilder!(
          context,
          StateError('bad cached cover'),
          null,
        ),
        isA<Image>(),
      );
      await tester.pumpWidget(scoped(3, previewFile.path));
      expect(
        cachedCover().frameBuilder!(context, decodedSharp, null, false),
        isA<Image>(),
      );
    },
  );

  testWidgets('a new track does not retain the previous track cached cover', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'bstream-cover-next-track-',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      directory.deleteSync(recursive: true);
    });
    final coverFile = File('${directory.path}/cover.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    Widget scoped(int revision, String source) => MaterialApp(
      home: PlaybackArtworkCacheScope(
        revision: revision,
        tracksSource: (_) => true,
        localPathFor: (_) => coverFile.path,
        child: SourceImage(
          source: source,
          cacheWidth: 1280,
          fallback: const Text('waiting for next cover'),
        ),
      ),
    );
    Image cachedCover() => tester
        .widgetList<Image>(find.byType(Image))
        .singleWhere(
          (image) =>
              image.image is ResizeImage &&
              (image.image as ResizeImage).imageProvider is FileImage,
        );
    await tester.pumpWidget(
      scoped(1, 'https://example.invalid/previous-cover.jpg'),
    );
    final context = tester.element(find.byType(SourceImage));
    const previousPixels = Text('previous song pixels');
    cachedCover().frameBuilder!(context, previousPixels, 0, false);

    const nextSource = 'https://example.invalid/next-cover.jpg';
    await tester.pumpWidget(scoped(2, nextSource));
    final pendingPreview =
        cachedCover().frameBuilder!(context, previousPixels, null, false)
            as Image;
    final previewProvider = pendingPreview.image as ResizeImage;
    expect(previewProvider.width, 256);
    expect(
      (previewProvider.imageProvider as CachedArtworkImageProvider).url,
      nextSource,
    );
  });

  testWidgets('showing the player again waits for its cached cover frame', (
    tester,
  ) async {
    const remote = 'https://example.invalid/reopened-cover.jpg';
    final directory = Directory.systemTemp.createTempSync(
      'bstream-cover-reopen-',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      directory.deleteSync(recursive: true);
    });
    final coverFile = File('${directory.path}/cover.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    Widget scoped(bool visible) => MaterialApp(
      home: PlaybackArtworkCacheScope(
        revision: 0,
        tracksSource: (_) => true,
        localPathFor: (_) => coverFile.path,
        allowNetworkPreviews: visible,
        child: const SourceImage(
          source: remote,
          fallback: Text('hidden cover'),
        ),
      ),
    );
    Image cachedCover() => tester
        .widgetList<Image>(find.byType(Image))
        .singleWhere(
          (image) =>
              image.image is ResizeImage &&
              (image.image as ResizeImage).imageProvider is FileImage,
        );
    await tester.pumpWidget(scoped(true));
    final context = tester.element(find.byType(SourceImage));
    const previousPixels = Text('disposed image pixels');
    cachedCover().frameBuilder!(context, previousPixels, 0, false);
    await tester.pumpWidget(scoped(false));
    expect(find.byType(Image), findsNothing);
    await tester.pumpWidget(scoped(true));
    expect(
      cachedCover().frameBuilder!(context, previousPixels, null, false),
      isA<Image>(),
    );
  });

  testWidgets('full player reuses the mini preview for downloaded covers', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'bstream-local-cover-',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      directory.deleteSync(recursive: true);
    });
    final file = File('${directory.path}/downloaded-cover.png');
    file.writeAsBytesSync(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PlaybackArtworkCacheScope(
          revision: 0,
          tracksSource: (_) => false,
          localPathFor: (_) => null,
          useMiniArtworkPreview: true,
          child: SourceImage(
            source: file.path,
            cacheWidth: 1280,
            fallback: const Text('missing cover'),
          ),
        ),
      ),
    );

    final covers = tester.widgetList<Image>(find.byType(Image)).toList();
    final fullCover = covers.singleWhere(
      (image) =>
          image.image is ResizeImage &&
          (image.image as ResizeImage).width == 1280,
    );
    final frameBuilder = fullCover.frameBuilder!;
    final context = tester.element(find.byType(SourceImage).first);
    const decoded = Text('decoded frame');
    final preview = frameBuilder(context, decoded, null, false) as Image;
    expect((preview.image as ResizeImage).width, 256);
    expect(frameBuilder(context, decoded, 0, false), same(decoded));
  });

  testWidgets('SourceImage uses its fallback for missing sources', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SourceImage(
          source: 'missing-local-artwork.jpg',
          fallback: Text('fallback'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('fallback'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('ProportionalArtwork keeps its fallback for empty sources', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ProportionalArtwork(source: null, fallback: Text('fallback')),
      ),
    );

    expect(find.text('fallback'), findsOneWidget);
  });

  testWidgets(
    'SourceImage keeps downloaded artwork when its remote fallback is offline',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'bstream-source-image-',
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        PaintingBinding.instance.imageCache
          ..clear()
          ..clearLiveImages();
        directory.deleteSync(recursive: true);
      });
      final artwork = File('${directory.path}/downloaded-cover.png');
      artwork.writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
        flush: true,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: SourceImage(
            source: artwork.path,
            // The remote equivalent is intentionally unavailable; local
            // artwork must win before any network request is attempted.
            fallbackSource: 'https://offline.invalid/remote-cover.jpg',
            fallback: const Text('fallback'),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(Image), findsOneWidget);
      expect(find.text('fallback'), findsNothing);
      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image as ResizeImage;
      expect(provider.imageProvider, isA<FileImage>());
      expect((provider.imageProvider as FileImage).file.path, artwork.path);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ProportionalArtwork decodes one bounded image without a blur copy',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox.square(
            dimension: 56,
            child: ProportionalArtwork(
              source: 'https://example.invalid/artwork.jpg',
              cacheWidth: 256,
              fallback: Text('fallback'),
            ),
          ),
        ),
      );

      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(ImageFiltered), findsNothing);
      final image = tester.widget<Image>(find.byType(Image));
      final provider = image.image as ResizeImage;
      expect(provider.width, 256);
      expect(provider.imageProvider, isA<CachedArtworkImageProvider>());
    },
  );

  testWidgets('SourceImage requests a card-sized Google rendition', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SourceImage(
          source: 'https://yt3.googleusercontent.com/artist=w120-h120-l90-rj',
          cacheWidth: 320,
          fallback: Text('fallback'),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    final cached = resized.imageProvider as CachedArtworkImageProvider;
    expect(
      cached.url,
      'https://yt3.googleusercontent.com/artist=w384-h384-l90-rj',
    );
  });

  testWidgets(
    'small YouTube artwork uses one exact preview without upgrade requests',
    (tester) async {
      const exact =
          'https://i.ytimg.com/vi/dmW68lzaaqs/mqdefault.jpg?catalog=1';
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox.square(
            dimension: 56,
            child: SourceImage(
              source: 'https://i.ytimg.com/vi/dmW68lzaaqs/hq720.jpg',
              fallbackSource: exact,
              cacheWidth: 256,
              fallback: Text('fallback'),
            ),
          ),
        ),
      );

      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images, hasLength(1));
      final resized = images.single.image as ResizeImage;
      final cached = resized.imageProvider as CachedArtworkImageProvider;
      expect(cached.url, exact);
    },
  );

  testWidgets('large YouTube artwork keeps a preview under its sharp upgrade', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox.square(
          dimension: 360,
          child: SourceImage(
            source: 'https://i.ytimg.com/vi/dmW68lzaaqs/hq720.jpg',
            cacheWidth: 1280,
            fallback: Text('fallback'),
          ),
        ),
      ),
    );

    final urls = tester
        .widgetList<Image>(find.byType(Image))
        .map((image) => image.image as ResizeImage)
        .map((image) => (image.imageProvider as CachedArtworkImageProvider).url)
        .toList();
    expect(urls, <String>[
      'https://i.ytimg.com/vi/dmW68lzaaqs/mqdefault.jpg',
      'https://i.ytimg.com/vi/dmW68lzaaqs/hq720.jpg',
    ]);
    expect(find.byType(Stack), findsOneWidget);
    expect(find.byType(AnimatedOpacity), findsOneWidget);
  });

  testWidgets('SourceImage loads embedded device artwork only when rendered', (
    tester,
  ) async {
    const channel = MethodChannel('bstream_music/local_audio');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          );
        });
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final source = deviceAudioArtworkSourceForUri(
      'content://media/external/audio/media/embedded-42',
    );
    expect(calls, isEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: SourceImage(
          source: source,
          cacheWidth: 192,
          fallback: const Text('fallback'),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'loadArtwork');
    expect(calls.single.arguments, <String, Object>{
      'audioUri': 'content://media/external/audio/media/embedded-42',
      'targetWidth': 192,
    });
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<DeviceAudioArtworkImageProvider>());
    expect(find.text('fallback'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
