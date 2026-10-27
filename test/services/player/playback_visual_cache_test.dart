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
    // A cancelled asynchronous transfer may still be closing its file handle
    // on Windows. Retry only that sharing violation, not unrelated failures.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      try {
        await directory.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 32 ||
            DateTime.now().isAfter(deadline)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
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

  Future<File> sharedCover(String name, List<int> bytes) async {
    final folder = await Directory('${directory.path}/shared').create();
    return File('${folder.path}/$name').writeAsBytes(bytes);
  }

  test(
    'first selected cached catalog cover upgrades without another song',
    () async {
      const source =
          'https://lh3.googleusercontent.com/catalog=w120-h120-l90-rj';
      final low = await sharedCover('card.jpg', [1, 2, 3]);
      cache.dispose();
      cache = PlaybackVisualCache(
        directory: () async => directory,
        sharedArtworkLookup: (candidate) async =>
            candidate == source ? low : null,
      );
      final requested = Completer<void>();
      final release = Completer<void>();
      final finished = Completer<void>();
      server.listen((request) async {
        requestCounts.update(
          request.uri.path,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        requested.complete();
        await release.future;
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add([4, 5, 6, 7]);
        await request.response.close();
        finished.complete();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        cache.activate(
          trackKey: 'first-home-song',
          coverSource: source,
          videoUrl: null,
        );
        await waitFor(() => cache.coverPathFor(source) == low.path);
        await requested.future.timeout(const Duration(seconds: 5));
        expect(cache.coverPathFor(source), low.path);
        final previewRevision = cache.revision;
        release.complete();
        await waitFor(() => cache.coverPathFor(source) != low.path);
        await finished.future;
        expect(await File(cache.coverPathFor(source)!).readAsBytes(), [
          4,
          5,
          6,
          7,
        ]);
        expect(cache.revision, greaterThan(previewRevision));
        expect(requestCounts, {'/catalog=w1280-h1280-l90-rj': 1});
        expect(await low.exists(), isTrue);
      }, _ArtworkHttpOverrides(server.port));
    },
  );

  test(
    'missing high resolution retains shared preview and bounds retries',
    () async {
      const source =
          'https://lh3.googleusercontent.com/catalog=w120-h120-l90-rj';
      final low = await sharedCover('card.jpg', [1, 2, 3]);
      cache.dispose();
      cache = PlaybackVisualCache(
        directory: () async => directory,
        sharedArtworkLookup: (candidate) async =>
            candidate == source ? low : null,
      );
      final responded = Completer<void>();
      server.listen((request) async {
        requestCounts.update(
          request.uri.path,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        responded.complete();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        cache.activate(
          trackKey: 'first-home-song',
          coverSource: source,
          videoUrl: null,
        );
        await responded.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        for (var index = 0; index < 8; index++) {
          cache.activate(
            trackKey: 'first-home-song',
            coverSource: source,
            videoUrl: null,
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(cache.coverPathFor(source), low.path);
        expect(requestCounts, {'/catalog=w1280-h1280-l90-rj': 1});
        expect(await low.exists(), isTrue);
      }, _ArtworkHttpOverrides(server.port));
    },
  );

  test('cached full sized rendition avoids all cover requests', () async {
    const source = 'https://lh3.googleusercontent.com/catalog=w120-h120-l90-rj';
    const highSource =
        'https://lh3.googleusercontent.com/catalog=w1280-h1280-l90-rj';
    final high = await sharedCover('full.jpg', [4, 5, 6, 7]);
    cache.dispose();
    cache = PlaybackVisualCache(
      directory: () async => directory,
      sharedArtworkLookup: (candidate) async =>
          candidate == highSource ? high : null,
    );
    server.listen((request) async {
      requestCounts.update(
        request.uri.path,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      await request.response.close();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      cache.activate(
        trackKey: 'first-home-song',
        coverSource: source,
        videoUrl: null,
      );
      await waitFor(() => cache.coverPathFor(source) == high.path);
      cache.activate(
        trackKey: 'first-home-song',
        coverSource: source,
        videoUrl: null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requestCounts, isEmpty);
    }, _ArtworkHttpOverrides(server.port));
  });

  test(
    'exact cached YouTube preview does not prevent a sharper rendition',
    () async {
      const source = 'https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg';
      final low = await sharedCover('video-preview.jpg', [1, 2, 3]);
      cache.dispose();
      cache = PlaybackVisualCache(
        directory: () async => directory,
        sharedArtworkLookup: (candidate) async =>
            candidate == source ? low : null,
      );
      server.listen((request) async {
        requestCounts.update(
          request.uri.path,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add([7, 8, 9, 10]);
        await request.response.close();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        cache.activate(
          trackKey: 'first-video',
          coverSource: source,
          videoUrl: null,
        );
        await waitFor(() {
          final path = cache.coverPathFor(source);
          return path != null && path != low.path;
        });
        expect(requestCounts, {'/vi/abcdefghijk/hq720.jpg': 1});
        expect(await File(cache.coverPathFor(source)!).readAsBytes(), [
          7,
          8,
          9,
          10,
        ]);
      }, _ArtworkHttpOverrides(server.port));
    },
  );

  test(
    'switching songs cancels preview upgrade without publishing old result',
    () async {
      const source =
          'https://lh3.googleusercontent.com/catalog=w120-h120-l90-rj';
      final low = await sharedCover('card.jpg', [1, 2, 3]);
      cache.dispose();
      cache = PlaybackVisualCache(
        directory: () async => directory,
        sharedArtworkLookup: (candidate) async =>
            candidate == source ? low : null,
      );
      final started = Completer<void>();
      final release = Completer<void>();
      final finished = Completer<void>();
      server.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'jpeg');
        request.response.add([4, 5]);
        await request.response.flush();
        started.complete();
        await release.future;
        try {
          request.response.add([6, 7]);
          await request.response.close();
        } catch (_) {}
        finished.complete();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        cache.activate(trackKey: 'old', coverSource: source, videoUrl: null);
        await started.future.timeout(const Duration(seconds: 5));
        expect(cache.coverPathFor(source), low.path);
        cache.activate(trackKey: 'new', coverSource: null, videoUrl: null);
        final revisionAfterSwitch = cache.revision;
        release.complete();
        await finished.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(cache.coverPathFor(source), low.path);
        expect(cache.revision, revisionAfterSwitch);
        expect(await low.exists(), isTrue);
        expect(directory.listSync().whereType<File>(), isEmpty);
      }, _ArtworkHttpOverrides(server.port));
    },
  );

  test('hiding the player cancels a cached preview upgrade', () async {
    const source = 'https://lh3.googleusercontent.com/catalog=w120-h120-l90-rj';
    final low = await sharedCover('card.jpg', [1, 2, 3]);
    cache.dispose();
    cache = PlaybackVisualCache(
      directory: () async => directory,
      sharedArtworkLookup: (candidate) async =>
          candidate == source ? low : null,
    );
    final started = Completer<void>();
    final release = Completer<void>();
    final finished = Completer<void>();
    server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'jpeg');
      request.response.add([4, 5]);
      await request.response.flush();
      started.complete();
      await release.future;
      try {
        request.response.add([6, 7]);
        await request.response.close();
      } catch (_) {}
      finished.complete();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      cache.activate(trackKey: 'old', coverSource: source, videoUrl: null);
      await started.future.timeout(const Duration(seconds: 5));
      cache.deactivate();
      final revisionAfterHiding = cache.revision;
      release.complete();
      await finished.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cache.coverPathFor(source), low.path);
      expect(cache.revision, revisionAfterHiding);
      expect(await low.exists(), isTrue);
    }, _ArtworkHttpOverrides(server.port));
  });
}

class _ArtworkHttpOverrides extends HttpOverrides {
  _ArtworkHttpOverrides(this.port);

  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _RoutedArtworkClient(super.createHttpClient(context), port);
}

class _RoutedArtworkClient implements HttpClient {
  _RoutedArtworkClient(this.client, this.port);

  final HttpClient client;
  final int port;

  @override
  Duration? get connectionTimeout => client.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;

  @override
  Future<HttpClientRequest> getUrl(Uri uri) => client.getUrl(
    uri.replace(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: port,
    ),
  );

  @override
  void close({bool force = false}) => client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
