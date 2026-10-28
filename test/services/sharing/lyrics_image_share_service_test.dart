import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/sharing/lyrics_image_share_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

void main() {
  late Directory temporaryDirectory;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=',
  );
  const origin = Rect.fromLTWH(12, 24, 48, 48);

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'bstream_lyrics_export_test_',
    );
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'shares a sanitized PNG with its origin and retains its source',
    () async {
      ShareParams? dispatched;
      final service = DefaultLyricsImageShareService(
        platform: () => AppPlatformType.android,
        temporaryDirectoryFactory: () async => temporaryDirectory,
        nativeShare: (params) async {
          dispatched = params;
          expect(await params.files!.single.readAsBytes(), png);
        },
      );

      await service.shareImage(
        pngBytes: png,
        title: 'A/B: song? 🎵',
        sharePositionOrigin: origin,
      );

      final params = dispatched!;
      expect(params.title, 'A/B: song? 🎵');
      expect(params.subject, 'A/B: song? 🎵');
      expect(params.sharePositionOrigin, origin);
      final file = params.files!.single;
      expect(file.mimeType, 'image/png');
      expect(file.name, startsWith('A_B_ song_ 🎵-'));
      expect(file.name, endsWith('.png'));
      expect(params.fileNameOverrides, [file.name]);
      expect(await File(file.path).exists(), isTrue);
      expect(p.isWithin(temporaryDirectory.path, file.path), isTrue);
    },
  );

  test(
    'uses a safe popover anchor and keeps dispatched files on errors',
    () async {
      File? file;
      final service = DefaultLyricsImageShareService(
        platform: () => AppPlatformType.ios,
        temporaryDirectoryFactory: () async => temporaryDirectory,
        nativeShare: (params) async {
          file = File(params.files!.single.path);
          expect(params.sharePositionOrigin, const Rect.fromLTWH(0, 0, 1, 1));
          throw StateError('Native receiver failed after dispatch');
        },
      );

      await expectLater(
        service.shareImage(
          pngBytes: png,
          title: 'CON',
          sharePositionOrigin: Rect.zero,
        ),
        throwsStateError,
      );
      expect(p.basename(file!.path), startsWith('_CON-'));
      expect(await file!.exists(), isTrue);
    },
  );

  for (final target in [AppPlatformType.android, AppPlatformType.ios]) {
    test('exports via $target document picker and cleans its source', () async {
      String? exportedPath;
      var otherPlatformCalled = false;
      Future<String?> export({
        required String sourcePath,
        required String fileName,
        required String mimeType,
      }) async {
        exportedPath = sourcePath;
        expect(await File(sourcePath).readAsBytes(), png);
        expect(fileName, endsWith('.png'));
        expect(fileName, p.basename(sourcePath));
        expect(mimeType, 'image/png');
        return 'content://selected/lyrics.png';
      }

      Future<String?> other({
        required String sourcePath,
        required String fileName,
        required String mimeType,
      }) async {
        otherPlatformCalled = true;
        return null;
      }

      final service = DefaultLyricsImageShareService(
        platform: () => target,
        temporaryDirectoryFactory: () async => temporaryDirectory,
        androidSave: target == AppPlatformType.android ? export : other,
        iosSave: target == AppPlatformType.ios ? export : other,
      );
      expect(
        await service.saveImage(pngBytes: png, title: 'My song'),
        'content://selected/lyrics.png',
      );
      expect(otherPlatformCalled, isFalse);
      expect(await File(exportedPath!).exists(), isFalse);
      expect(await Directory(p.dirname(exportedPath!)).exists(), isFalse);
    });
  }

  test(
    'preserves picker cancellation and errors while cleaning source',
    () async {
      final sources = <String>[];
      var shouldFail = false;
      final service = DefaultLyricsImageShareService(
        platform: () => AppPlatformType.android,
        temporaryDirectoryFactory: () async => temporaryDirectory,
        androidSave:
            ({
              required String sourcePath,
              required String fileName,
              required String mimeType,
            }) async {
              sources.add(sourcePath);
              if (shouldFail) throw const FileSystemException('Export failed');
              return null;
            },
      );
      expect(await service.saveImage(pngBytes: png, title: 'Song'), isNull);
      shouldFail = true;
      await expectLater(
        service.saveImage(pngBytes: png, title: 'Song'),
        throwsA(isA<FileSystemException>()),
      );
      for (final source in sources) {
        expect(await File(source).exists(), isFalse);
      }
    },
  );

  test('desktop saves bytes directly and preserves cancellation', () async {
    var saves = 0;
    final service = DefaultLyricsImageShareService(
      platform: () => AppPlatformType.linux,
      temporaryDirectoryFactory: () => throw StateError('No temp file needed'),
      desktopSave:
          ({
            required Uint8List bytes,
            required String fileName,
            required String title,
          }) async {
            saves++;
            expect(bytes, png);
            expect(title, 'Night Dancer');
            expect(fileName, startsWith('Night Dancer-'));
            return saves == 1 ? 'file:///home/music/lyrics.png' : null;
          },
    );

    expect(service.canShare, isFalse);
    expect(
      await service.saveImage(pngBytes: png, title: 'Night Dancer'),
      'file:///home/music/lyrics.png',
    );
    expect(
      await service.saveImage(pngBytes: png, title: 'Night Dancer'),
      isNull,
    );
  });

  test('unsupported sharing and invalid images never create a file', () async {
    var allocated = false;
    DefaultLyricsImageShareService serviceFor(AppPlatformType platform) =>
        DefaultLyricsImageShareService(
          platform: () => platform,
          temporaryDirectoryFactory: () async {
            allocated = true;
            return temporaryDirectory;
          },
        );

    expect(serviceFor(AppPlatformType.unsupported).canShare, isFalse);
    await expectLater(
      serviceFor(
        AppPlatformType.linux,
      ).shareImage(pngBytes: png, title: 'Song', sharePositionOrigin: origin),
      throwsUnsupportedError,
    );
    await expectLater(
      serviceFor(AppPlatformType.android).shareImage(
        pngBytes: Uint8List.fromList([1, 2, 3]),
        title: 'Song',
        sharePositionOrigin: origin,
      ),
      throwsFormatException,
    );
    await expectLater(
      serviceFor(
        AppPlatformType.android,
      ).saveImage(pngBytes: Uint8List(33 * 1024 * 1024), title: 'Song'),
      throwsFormatException,
    );
    expect(allocated, isFalse);
  });

  test('only expires marked owned exports after seven days', () async {
    final now = DateTime.now();
    final root = await Directory(
      p.join(temporaryDirectory.path, 'bstream-lyrics-images'),
    ).create();
    final expired = await Directory(
      p.join(root.path, 'image_expired'),
    ).create();
    final recent = await Directory(p.join(root.path, 'image_recent')).create();
    final unmarked = await Directory(
      p.join(root.path, 'image_unmarked'),
    ).create();
    final unrelated = await Directory(p.join(root.path, 'unrelated')).create();
    for (final directory in [expired, recent, unrelated]) {
      final marker = await File(
        p.join(directory.path, '.bstream-lyrics-image'),
      ).writeAsString('BStream lyrics image');
      if (directory != recent) {
        await marker.setLastModified(now.subtract(const Duration(days: 8)));
      }
    }
    final outside = await File(
      p.join(temporaryDirectory.path, 'keep.png'),
    ).writeAsBytes(png);
    final service = DefaultLyricsImageShareService(
      platform: () => AppPlatformType.windows,
      temporaryDirectoryFactory: () async => temporaryDirectory,
      clock: () => now,
      nativeShare: (_) async {},
    );

    await service.shareImage(
      pngBytes: png,
      title: 'Song',
      sharePositionOrigin: origin,
    );

    expect(await expired.exists(), isFalse);
    expect(await recent.exists(), isTrue);
    expect(await unmarked.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect(await outside.exists(), isTrue);
  });
}
