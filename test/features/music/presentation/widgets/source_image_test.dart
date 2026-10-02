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
