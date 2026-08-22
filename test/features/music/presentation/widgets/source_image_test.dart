import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:flutter/material.dart';
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
    },
  );
}
