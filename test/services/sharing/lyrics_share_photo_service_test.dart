import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/sharing/lyrics_share_photo_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporaryDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'bstream_lyrics_photo_test_',
    );
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'records Android picker purpose and removes it after cancellation',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final service = DefaultLyricsSharePhotoService(
        platform: () => AppPlatformType.android,
        mobilePicker: () async {
          expect(prefs.getBool(lyricsSharePhotoPendingKey), isTrue);
          return null;
        },
        desktopPicker: () => throw StateError('Incorrect picker'),
      );

      expect(await service.pickPhoto(), isNull);
      expect(prefs.containsKey(lyricsSharePhotoPendingKey), isFalse);
    },
  );

  test('clears the Android purpose marker when the picker fails', () async {
    final service = DefaultLyricsSharePhotoService(
      platform: () => AppPlatformType.android,
      mobilePicker: () async => throw StateError('Native picker failed'),
    );

    await expectLater(service.pickPhoto(), throwsStateError);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(lyricsSharePhotoPendingKey), isFalse);
  });

  test(
    'preserves small photo dimensions and uses the iOS mobile picker',
    () async {
      final file = await _photo(temporaryDirectory, 80, 40);
      final service = DefaultLyricsSharePhotoService(
        platform: () => AppPlatformType.ios,
        mobilePicker: () async => file.path,
        desktopPicker: () => throw StateError('Incorrect picker'),
      );

      final image = (await service.pickPhoto())!;
      try {
        expect(image.width, 80);
        expect(image.height, 40);
      } finally {
        image.dispose();
      }
    },
  );

  test(
    'bounds a desktop camera photo while preserving its aspect ratio',
    () async {
      final file = await _photo(temporaryDirectory, 3200, 1600);
      final service = DefaultLyricsSharePhotoService(
        platform: () => AppPlatformType.windows,
        mobilePicker: () => throw StateError('Incorrect picker'),
        desktopPicker: () async => file.path,
      );

      final image = (await service.pickPhoto())!;
      try {
        expect(image.width, DefaultLyricsSharePhotoService.maximumDimension);
        expect(image.height, 1280);
      } finally {
        image.dispose();
      }
    },
  );

  test('rejects empty and oversized files before decoding', () async {
    final file = File('${temporaryDirectory.path}/oversized.png');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(DefaultLyricsSharePhotoService.maximumBytes + 1);
    await handle.close();
    final service = DefaultLyricsSharePhotoService(
      platform: () => AppPlatformType.linux,
      desktopPicker: () async => file.path,
    );
    await expectLater(service.pickPhoto(), throwsFormatException);

    await file.writeAsBytes([]);
    await expectLater(service.pickPhoto(), throwsFormatException);
  });

  test('a corrupt photo fails and leaves no open file handle', () async {
    final file = await File(
      '${temporaryDirectory.path}/corrupt.jpg',
    ).writeAsBytes([1, 2, 3, 4]);
    final service = DefaultLyricsSharePhotoService(
      platform: () => AppPlatformType.macos,
      desktopPicker: () async => file.path,
    );

    await expectLater(service.pickPhoto(), throwsA(anything));
    await file.delete();
    expect(await file.exists(), isFalse);
  });
}

Future<File> _photo(Directory directory, int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff5878a4), ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return await File('${directory.path}/photo.png').writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
  } finally {
    image.dispose();
    picture.dispose();
  }
}
