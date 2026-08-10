import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory cacheDirectory;
  late HttpServer server;
  late RemotePlaybackCache cache;

  setUp(() async {
    cacheDirectory = await Directory.systemTemp.createTemp(
      'bstream-remote-playback-cache-',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('audio', 'mp4');
      request.response.add(List<int>.generate(2048, (index) => index % 251));
      await request.response.close();
    });
    cache = RemotePlaybackCache(
      isAndroid: true,
      cacheDirectoryProvider: () async => cacheDirectory,
    );
  });

  tearDown(() async {
    cache.dispose();
    await server.close(force: true);
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  });

  test(
    'queue changes retain only the previous, current, and next audio files',
    () async {
      final first = _track(server, 'first');
      final second = _track(server, 'second');
      final third = _track(server, 'third');
      final fourth = _track(server, 'fourth');

      await cache.retainOnlyTracks([first, second, third]);
      expect(await cache.warmResolved(first), isNotNull);
      expect(await cache.warmResolved(second), isNotNull);
      expect(await cache.warmResolved(third), isNotNull);
      expect(await _audioFiles(cacheDirectory), hasLength(3));

      await cache.retainOnlyTracks([second, third, fourth]);

      expect(await cache.cachedFile(first), isNull);
      expect(await cache.cachedFile(second), isNotNull);
      expect(await cache.cachedFile(third), isNotNull);
      expect(await cache.warmResolved(fourth), isNotNull);
      expect(await cache.cachedFile(fourth), isNotNull);
      expect(await _audioFiles(cacheDirectory), hasLength(3));
    },
  );

  test(
    'startup cleanup removes partial and expired unprotected files',
    () async {
      final now = DateTime(2026, 8, 10, 12);
      final active = _track(server, 'active');
      cache.dispose();
      cache = RemotePlaybackCache(
        isAndroid: true,
        cacheDirectoryProvider: () async => cacheDirectory,
        clock: () => now,
      );

      await cache.retainOnlyTracks([active]);
      final activeFile = await cache.warmResolved(active);
      expect(activeFile, isNotNull);
      await activeFile!.setLastModified(now.subtract(const Duration(hours: 4)));

      final expired = File('${cacheDirectory.path}/expired.m4a');
      await expired.writeAsBytes(const [1, 2, 3]);
      await expired.setLastModified(now.subtract(const Duration(minutes: 31)));
      final recent = File('${cacheDirectory.path}/recent.m4a');
      await recent.writeAsBytes(const [4, 5, 6]);
      await recent.setLastModified(now.subtract(const Duration(minutes: 20)));
      final partial = File('${cacheDirectory.path}/interrupted.part');
      await partial.writeAsBytes(const [7, 8, 9]);

      await cache.prepareSession(protectedSourceUrls: [active.url]);

      expect(await activeFile.exists(), isTrue);
      expect(await expired.exists(), isFalse);
      expect(await recent.exists(), isTrue);
      expect(await partial.exists(), isFalse);
      expect(await _audioFiles(cacheDirectory), hasLength(2));
    },
  );

  test('stopping playback can clear every remote prefetch', () async {
    final track = _track(server, 'only');
    await cache.retainOnlyTracks([track]);
    expect(await cache.warmResolved(track), isNotNull);

    await cache.retainOnlyTracks(const <TrackInfo>[]);

    expect(await cache.cachedFile(track), isNull);
    expect(await _audioFiles(cacheDirectory), isEmpty);
  });
}

TrackInfo _track(HttpServer server, String id) {
  return TrackInfo(
    id: id,
    title: 'Track $id',
    artist: 'BStream',
    url: 'https://www.youtube.com/watch?v=$id',
    streamUrl: 'http://${server.address.host}:${server.port}/$id.m4a',
  );
}

Future<List<File>> _audioFiles(Directory directory) async {
  return directory
      .list()
      .where((entity) => entity is File && !entity.path.endsWith('.part'))
      .cast<File>()
      .toList();
}
