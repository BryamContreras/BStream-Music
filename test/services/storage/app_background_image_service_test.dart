import 'dart:io';
import 'dart:typed_data';

import 'package:bstream_music/services/storage/app_background_image_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDirectory;
  late AppBackgroundImageService service;

  setUp(() async {
    supportDirectory = await Directory.systemTemp.createTemp('app_background_');
    service = AppBackgroundImageService(
      supportDirectoryProvider: () async => supportDirectory,
    );
  });

  tearDown(() async {
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  test(
    'stores optimized JPEG by relative name and preserves aspect ratio',
    () async {
      final photo = image.Image(width: 2400, height: 1200);
      image.fill(photo, color: image.ColorRgb8(25, 75, 125));
      final fileName = await service.saveStream(
        Stream.value(Uint8List.fromList(image.encodePng(photo))),
      );

      expect(fileName, matches(RegExp(r'^background_\d+_\d+\.jpg$')));
      final resolved = await service.resolve(fileName);
      expect(resolved, isNotNull);
      expect(path.basename(resolved!), fileName);
      final optimized = image.decodeJpg(await File(resolved).readAsBytes());
      expect(optimized, isNotNull);
      expect(optimized!.width, 2048);
      expect(optimized.height, 1024);
    },
  );

  test('bakes EXIF orientation and strips original metadata', () async {
    final photo = image.Image(width: 80, height: 40);
    image.fill(photo, color: image.ColorRgb8(175, 30, 30));
    photo.exif.imageIfd.orientation = 6;
    final fileName = await service.saveStream(
      Stream.value(Uint8List.fromList(image.encodeJpg(photo))),
    );

    final resolved = await service.resolve(fileName);
    final optimized = image.decodeJpg(await File(resolved!).readAsBytes());
    expect(optimized, isNotNull);
    expect(optimized!.width, 40);
    expect(optimized.height, 80);
    expect(optimized.exif.isEmpty, isTrue);
  });

  test('resolves the same token after the app container moves', () async {
    final photo = image.Image(width: 8, height: 8);
    final source = File(path.join(supportDirectory.path, 'original.png'));
    final sourceBytes = image.encodePng(photo);
    await source.writeAsBytes(sourceBytes);
    final fileName = await service.saveFile(source);
    expect(await source.readAsBytes(), sourceBytes);

    final relocated = Directory(path.join(supportDirectory.path, 'relocated'));
    await relocated.create();
    await Directory(
      path.join(supportDirectory.path, 'app_backgrounds'),
    ).rename(path.join(relocated.path, 'app_backgrounds'));
    final relocatedService = AppBackgroundImageService(
      supportDirectoryProvider: () async => relocated,
    );
    final resolved = await relocatedService.resolve(fileName);
    expect(resolved, path.join(relocated.path, 'app_backgrounds', fileName));
  });

  test('rejects oversize input before decoding and without saving', () async {
    final limited = AppBackgroundImageService(
      supportDirectoryProvider: () async => supportDirectory,
      maxSourceBytes: 10,
    );
    await expectLater(
      limited.saveStream(
        Stream.fromIterable([
          Uint8List.fromList(List.filled(6, 1)),
          Uint8List.fromList(List.filled(6, 2)),
        ]),
      ),
      throwsA(
        isA<AppBackgroundImageException>().having(
          (error) => error.error,
          'error',
          AppBackgroundImageError.tooLarge,
        ),
      ),
    );
    expect(
      await Directory(
        path.join(supportDirectory.path, 'app_backgrounds'),
      ).exists(),
      isFalse,
    );
  });

  test('invalid image does not create an app background', () async {
    await expectLater(
      service.saveStream(Stream.value(Uint8List.fromList([1, 2, 3]))),
      throwsA(
        isA<AppBackgroundImageException>().having(
          (error) => error.error,
          'error',
          AppBackgroundImageError.invalidImage,
        ),
      ),
    );
  });

  test('rejects path traversal tokens and deletes only own files', () async {
    final outside = File(path.join(supportDirectory.path, 'outside.jpg'));
    await outside.writeAsBytes([1, 2, 3]);
    expect(await service.resolve('../outside.jpg'), isNull);
    await service.delete('../outside.jpg');
    expect(await outside.exists(), isTrue);

    final photo = image.Image(width: 8, height: 8);
    final fileName = await service.saveStream(
      Stream.value(Uint8List.fromList(image.encodePng(photo))),
    );
    await service.delete(fileName);
    expect(await service.resolve(fileName), isNull);
  });

  test('null token needs no platform path lookup', () async {
    final withoutPlatform = AppBackgroundImageService(
      supportDirectoryProvider: () async => throw StateError('Must not run'),
    );
    expect(await withoutPlatform.resolve(null), isNull);
    await withoutPlatform.delete(null);
  });
}
