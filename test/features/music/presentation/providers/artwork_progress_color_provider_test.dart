import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/providers/artwork_progress_color_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArtworkProgressColorService', () {
    test(
      'uses the shared fallback for null, empty, and invalid sources',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'bstream-artwork-progress-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final service = ArtworkProgressColorService();
        final invalidPath = File(
          '${directory.path}${Platform.pathSeparator}missing-artwork.png',
        ).path;

        for (final source in <String?>[null, '', '   ', invalidPath]) {
          expect(
            await service.resolve(source),
            ArtworkProgressColor.fallback,
            reason: 'Unexpected color for source: $source',
          );
        }
      },
    );

    test(
      'deduplicates concurrent requests for the same normalized source',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'bstream-artwork-progress-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final service = ArtworkProgressColorService();
        final source = File(
          '${directory.path}${Platform.pathSeparator}missing-artwork.png',
        ).path;

        final first = service.resolve('  $source  ');
        final second = service.resolve(source);

        expect(second, same(first));
        expect(
          await Future.wait(<Future<Color>>[first, second]),
          everyElement(ArtworkProgressColor.fallback),
        );
      },
    );

    test('serves extracted colors from cache until it is cleared', () async {
      final directory = await Directory.systemTemp.createTemp(
        'bstream-artwork-progress-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final artwork = await _writeSolidPng(
        directory,
        'artwork.png',
        Colors.red,
      );
      final service = ArtworkProgressColorService(maximumCacheEntries: 2);

      final extracted = await service.resolve(artwork.path);
      expect(extracted, isNot(ArtworkProgressColor.fallback));

      await artwork.delete();
      expect(await service.resolve(artwork.path), extracted);

      service.clearCache();
      expect(
        await service.resolve(artwork.path),
        ArtworkProgressColor.fallback,
      );
    });
  });

  group('artwork progress color providers', () {
    test(
      'expose the service and delegate family lookups without changing source',
      () async {
        const expected = Color(0xFF7B8DFF);
        final service = _RecordingArtworkProgressColorService(expected);
        final container = ProviderContainer(
          overrides: [
            artworkProgressColorServiceProvider.overrideWithValue(service),
          ],
        );
        addTearDown(container.dispose);

        expect(
          container.read(artworkProgressColorServiceProvider),
          same(service),
        );
        expect(
          await container.read(
            artworkProgressColorProvider(' artwork-source ').future,
          ),
          expected,
        );
        expect(service.sources, <String?>[' artwork-source ']);
      },
    );

    test('family provider preserves the fallback for a null source', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        await container.read(artworkProgressColorProvider(null).future),
        ArtworkProgressColor.fallback,
      );
    });
  });
}

Future<File> _writeSolidPng(
  Directory directory,
  String name,
  Color color,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 4, 4),
    ui.Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(4, 4);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  if (bytes == null) {
    throw StateError('Could not encode artwork fixture.');
  }

  final file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
  return file;
}

class _RecordingArtworkProgressColorService
    extends ArtworkProgressColorService {
  _RecordingArtworkProgressColorService(this.color);

  final Color color;
  final List<String?> sources = <String?>[];

  @override
  Future<Color> resolve(String? rawSource) async {
    sources.add(rawSource);
    return color;
  }
}
