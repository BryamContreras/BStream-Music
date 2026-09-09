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
