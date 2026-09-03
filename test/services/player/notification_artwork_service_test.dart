import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:bstream_music/core/utils/image_source.dart';
import 'package:bstream_music/services/player/just_audio_player_service.dart';
import 'package:bstream_music/services/player/notification_artwork_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  test(
    'reports a failed bind and allows a later initialization retry',
    () async {
      var attempts = 0;
      final service = NotificationArtworkService(
        serverBinder: () {
          attempts++;
          if (attempts == 1) {
            return Future<HttpServer>.error(StateError('socket unavailable'));
          }
          return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        },
      );
      addTearDown(service.dispose);

      await expectLater(service.initialize(), throwsStateError);
      await service.initialize();

      expect(attempts, 2);
    },
  );

  test(
    'serves a cached square center crop without processing during uriFor',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'bstream-notification-artwork-',
      );
      final cache = Directory(
        '${root.path}${Platform.pathSeparator}notification-cache',
      );
      final source = await _writeLandscapeFixture(root);
      final service = NotificationArtworkService(
        cacheDirectoryProvider: () async => cache,
      );
      addTearDown(() async {
        await service.dispose();
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      await service.initialize();
      final uri = service.uriFor(source.path);

      expect(uri, isNotNull);
      expect(uri!.host, InternetAddress.loopbackIPv4.address);
      expect(await cache.exists(), isFalse);

      final firstBytes = await _get(uri);
      final first = image.decodeJpg(firstBytes);
      expect(first, isNotNull);
      expect(first!.width, 640);
      expect(first.height, 640);
      _expectGreen(first.getPixel(0, 160));
      _expectGreen(first.getPixel(160, 160));
      _expectGreen(first.getPixel(319, 160));

      final cachedFiles = await cache
          .list()
          .where((entry) => entry is File && entry.path.endsWith('.jpg'))
          .toList();
      expect(cachedFiles, hasLength(1));

      // The generated derivative, rather than the original file, serves later
      // notification requests for the same native queue item.
      await source.delete();
      final secondBytes = await _get(uri);
      expect(secondBytes, orderedEquals(firstBytes));
    },
  );

  test('rejects empty, missing, and unsupported artwork sources', () async {
    final root = await Directory.systemTemp.createTemp(
      'bstream-notification-artwork-',
    );
    final service = NotificationArtworkService(
      cacheDirectoryProvider: () async => root,
    );
    addTearDown(() async {
      await service.dispose();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    await service.initialize();

    expect(service.uriFor(null), isNull);
    expect(service.uriFor('  '), isNull);
    final missingUri = service.uriFor('${root.path}/missing.jpg');
    expect(missingUri, isNotNull);
    expect(await _statusCode(missingUri!), HttpStatus.notFound);
    expect(service.uriFor('content://media/external/images/1'), isNull);
  });

  test('serves the original local artwork when decoding fails', () async {
    final root = await Directory.systemTemp.createTemp(
      'bstream-notification-artwork-',
    );
    final source = File('${root.path}${Platform.pathSeparator}unsupported.jpg');
    final original = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
    await source.writeAsBytes(original, flush: true);
    final service = NotificationArtworkService(
      cacheDirectoryProvider: () async =>
          Directory('${root.path}${Platform.pathSeparator}notification-cache'),
    );
    addTearDown(() async {
      await service.dispose();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    await service.initialize();
    final uri = service.uriFor(source.path);

    expect(uri, isNotNull);
    expect(await _get(uri!), orderedEquals(original));
  });

  test('proxies bounded iOS Media Library artwork for Now Playing', () async {
    final root = await Directory.systemTemp.createTemp(
      'bstream-notification-artwork-',
    );
    final fixture = image.Image(width: 480, height: 320)
      ..clear(image.ColorRgb8(12, 180, 90));
    var requests = 0;
    final service = NotificationArtworkService(
      cacheDirectoryProvider: () async =>
          Directory('${root.path}${Platform.pathSeparator}notification-cache'),
      deviceAudioArtworkLoader: (audioUri, targetWidth) async {
        requests++;
        expect(audioUri, 'ipod-library://item/item.m4a?id=42');
        expect(targetWidth, 640);
        return Uint8List.fromList(image.encodePng(fixture));
      },
    );
    addTearDown(() async {
      await service.dispose();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    await service.initialize();
    final source = deviceAudioArtworkSourceForUri(
      'ipod-library://item/item.m4a?id=42',
    );
    final uri = service.uriFor(source);

    expect(uri, isNotNull);
    final bytes = await _get(uri!);
    final decoded = image.decodeJpg(bytes);
    expect(decoded, isNotNull);
    expect(decoded!.width, 640);
    expect(decoded.height, 640);
    expect(requests, 1);
  });

  test(
    'bounds registered queue artwork to the configured recent set',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'bstream-notification-artwork-',
      );
      final first = await _writeLandscapeFixture(root, name: 'first.png');
      final second = await _writeLandscapeFixture(root, name: 'second.png');
      final service = NotificationArtworkService(
        cacheDirectoryProvider: () async => Directory(
          '${root.path}${Platform.pathSeparator}notification-cache',
        ),
        maximumRegisteredSources: 1,
      );
      addTearDown(() async {
        await service.dispose();
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      await service.initialize();
      final firstUri = service.uriFor(first.path)!;
      final secondUri = service.uriFor(second.path)!;

      expect(await _statusCode(firstUri), HttpStatus.notFound);
      expect(await _statusCode(secondUri), HttpStatus.ok);
    },
  );

  test(
    'player presentation keeps original artwork instead of proxy artUri',
    () {
      final item = MediaItem(
        id: 'track',
        title: 'Track',
        artUri: Uri.parse('http://127.0.0.1:1234/square.jpg'),
        extras: const <String, dynamic>{
          'displayArtwork': 'https://i.ytimg.com/vi/abcdefghijk/hq720.jpg',
        },
      );
      final legacy = MediaItem(
        id: 'legacy',
        title: 'Legacy',
        artUri: Uri.parse('https://example.test/original.jpg'),
      );

      expect(
        displayArtworkSourceForMediaItem(item),
        'https://i.ytimg.com/vi/abcdefghijk/hq720.jpg',
      );
      expect(
        displayArtworkSourceForMediaItem(legacy),
        'https://example.test/original.jpg',
      );
    },
  );
}

Future<File> _writeLandscapeFixture(
  Directory directory, {
  String name = 'landscape.png',
}) async {
  final fixture = image.Image(width: 640, height: 360);
  for (final pixel in fixture) {
    if (pixel.x < 100) {
      pixel
        ..r = 255
        ..g = 0
        ..b = 0
        ..a = 255;
    } else if (pixel.x >= 540) {
      pixel
        ..r = 0
        ..g = 0
        ..b = 255
        ..a = 255;
    } else {
      pixel
        ..r = 0
        ..g = 255
        ..b = 0
        ..a = 255;
    }
  }
  final file = File('${directory.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(image.encodePng(fixture), flush: true);
  return file;
}

Future<Uint8List> _get(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    final bytes = await response.fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    return Uint8List.fromList(bytes);
  } finally {
    client.close(force: true);
  }
}

Future<int> _statusCode(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void _expectGreen(image.Pixel pixel) {
  expect(pixel.g, greaterThan(220));
  expect(pixel.r, lessThan(30));
  expect(pixel.b, lessThan(30));
}
