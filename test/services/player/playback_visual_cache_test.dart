import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bstream_music/services/player/playback_visual_cache.dart';

Future<void> waitFor(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for visual cache');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory directory;
  late HttpServer server;
  late PlaybackVisualCache cache;
  final requestCounts = <String, int>{};

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bstream-visual-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requestCounts.clear();
    cache = PlaybackVisualCache(
      directory: () async => directory,
      sharedArtworkLookup: (_) async => null,
    );
  });

  tearDown(() async {
    cache.dispose();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
    'reuses complete media for the current and previous two tracks',
    () async {
      server.listen((request) async {
        request.response.headers.contentType = ContentType.binary;
        requestCounts.update(
          request.uri.path,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });

      Uri video(String id) =>
          Uri.parse('http://127.0.0.1:${server.port}/$id.mp4');
      String cover(String id) => 'http://127.0.0.1:${server.port}/$id.jpg';

      for (final id in ['a', 'b', 'c']) {
        cache.activate(
          trackKey: id,
          coverSource: cover(id),
          videoUrl: video(id),
        );
        await waitFor(
          () =>
              cache.coverPathFor(cover(id)) != null &&
              cache.videoFileFor(id, video(id)) != null,
        );
      }
      cache.activate(
        trackKey: 'a',
        coverSource: cover('a'),
        videoUrl: video('a'),
      );
      expect(cache.coverPathFor(cover('a')), isNotNull);
      expect(cache.videoFileFor('a', video('a')), isNotNull);
      expect(requestCounts['/a.jpg'], 1);
      expect(requestCounts['/a.mp4'], 1);
      final evictedVideo = File.fromUri(cache.videoFileFor('b', video('b'))!);

      cache.activate(
        trackKey: 'd',
        coverSource: cover('d'),
        videoUrl: video('d'),
      );
      await waitFor(
        () =>
            cache.coverPathFor(cover('d')) != null &&
            cache.videoFileFor('d', video('d')) != null,
      );
      expect(cache.tracksCover(cover('b')), isFalse);
      expect(cache.tracksCover(cover('a')), isTrue);
      await waitFor(() => !evictedVideo.existsSync());
    },
  );

  test(
    'stops old transfer and removes partial files on a track switch',
    () async {
      final firstChunkSent = Completer<void>();
      final releaseSlowResponse = Completer<void>();
      server.listen((request) async {
        request.response.headers.contentType = ContentType.binary;
        requestCounts.update(
          request.uri.path,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        if (request.uri.path == '/slow.mp4') {
          request.response.add([1, 2, 3]);
          await request.response.flush();
          firstChunkSent.complete();
          await releaseSlowResponse.future;
        } else {
          request.response.add([4, 5, 6]);
        }
        try {
          await request.response.close();
        } catch (_) {}
      });

      final slow = Uri.parse('http://127.0.0.1:${server.port}/slow.mp4');
      final fast = Uri.parse('http://127.0.0.1:${server.port}/fast.mp4');
      cache.activate(trackKey: 'old', coverSource: null, videoUrl: slow);
      await firstChunkSent.future.timeout(const Duration(seconds: 5));
      cache.activate(trackKey: 'new', coverSource: null, videoUrl: fast);
      releaseSlowResponse.complete();
      await waitFor(() => cache.videoFileFor('new', fast) != null);
      await waitFor(
        () => directory.listSync().whereType<File>().every(
          (file) => !file.path.contains('.part-'),
        ),
      );
      expect(cache.videoFileFor('old', slow), isNull);
      expect(requestCounts['/slow.mp4'], 1);
      expect(
        await File.fromUri(cache.videoFileFor('new', fast)!).readAsBytes(),
        [4, 5, 6],
      );
    },
  );

  test('cancels an unfinished cover without keeping a partial image', () async {
    final firstChunkSent = Completer<void>();
    final releaseSlowResponse = Completer<void>();
    server.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      if (request.uri.path == '/slow.jpg') {
        request.response.add([1, 2, 3]);
        await request.response.flush();
        firstChunkSent.complete();
        await releaseSlowResponse.future;
      } else {
        request.response.add([4, 5, 6]);
      }
      try {
        await request.response.close();
      } catch (_) {}
    });

    final slow = 'http://127.0.0.1:${server.port}/slow.jpg';
    final fast = 'http://127.0.0.1:${server.port}/fast.jpg';
    cache.activate(trackKey: 'old', coverSource: slow, videoUrl: null);
    await firstChunkSent.future.timeout(const Duration(seconds: 5));
    cache.activate(trackKey: 'new', coverSource: fast, videoUrl: null);
    releaseSlowResponse.complete();
    await waitFor(() => cache.coverPathFor(fast) != null);
    await waitFor(
      () => directory.listSync().whereType<File>().every(
        (file) => !file.path.contains('.part-'),
      ),
    );
    expect(cache.coverPathFor(slow), isNull);
    expect(await File(cache.coverPathFor(fast)!).readAsBytes(), [4, 5, 6]);
  });

  test(
    'hiding the full player cancels pending media but retains complete files',
    () async {
      final chunkSent = Completer<void>();
      final release = Completer<void>();
      server.listen((request) async {
        request.response.headers.contentType = ContentType.binary;
        if (request.uri.path == '/pending.mp4') {
          request.response.add([1]);
          await request.response.flush();
          chunkSent.complete();
          await release.future;
        } else {
          request.response.add([2, 3]);
        }
        try {
          await request.response.close();
        } catch (_) {}
      });

      final finished = Uri.parse(
        'http://127.0.0.1:${server.port}/finished.mp4',
      );
      final pending = Uri.parse('http://127.0.0.1:${server.port}/pending.mp4');
      cache.activate(
        trackKey: 'finished',
        coverSource: null,
        videoUrl: finished,
      );
      await waitFor(() => cache.videoFileFor('finished', finished) != null);
      cache.activate(trackKey: 'pending', coverSource: null, videoUrl: pending);
      await chunkSent.future.timeout(const Duration(seconds: 5));
      cache.deactivate();
      release.complete();
      await waitFor(
        () => directory.listSync().whereType<File>().every(
          (file) => !file.path.contains('.part-'),
        ),
      );
      expect(cache.videoFileFor('pending', pending), isNull);
      expect(cache.videoFileFor('finished', finished), isNotNull);
    },
  );
}
