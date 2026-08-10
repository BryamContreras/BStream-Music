import 'dart:async';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory cacheDirectory;
  late HttpServer server;
  late RemotePlaybackCache cache;
  late Completer<void> variantResponseBarrier;
  late int variantResponseRequests;
  late Completer<void> slowResponseStarted;
  late Completer<void> slowResponseRelease;

  setUp(() async {
    cacheDirectory = await Directory.systemTemp.createTemp(
      'bstream-remote-playback-cache-',
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    variantResponseBarrier = Completer<void>();
    variantResponseRequests = 0;
    slowResponseStarted = Completer<void>();
    slowResponseRelease = Completer<void>();
    server.listen((request) async {
      if (request.uri.path.contains('slow-response')) {
        try {
          request.response.headers.contentType = ContentType('audio', 'mp4');
          request.response.add(List<int>.filled(256, 1));
          await request.response.flush();
          slowResponseStarted.complete();
          await slowResponseRelease.future;
          request.response.add(List<int>.filled(2048, 2));
          await request.response.close();
        } catch (_) {
          // The cache intentionally closes this connection during dispose.
        }
        return;
      }
      if (request.uri.path.contains('html')) {
        request.response.headers.contentType = ContentType('text', 'html');
        request.response.write('<html>not audio</html>');
      } else if (request.uri.path.contains('json')) {
        request.response.headers.contentType = ContentType(
          'application',
          'json',
        );
        request.response.write('{"error":"not audio"}');
      } else {
        if (request.uri.path.contains('variant-')) {
          variantResponseRequests++;
          if (variantResponseRequests == 2) {
            variantResponseBarrier.complete();
          }
          await variantResponseBarrier.future;
        }
        request.response.headers.contentType = request.uri.path.contains('webm')
            ? ContentType('audio', 'webm')
            : ContentType('audio', 'mp4');
        request.response.add(List<int>.generate(2048, (index) => index % 251));
      }
      await request.response.close();
    });
    cache = RemotePlaybackCache(
      policy: RemotePlaybackCachePolicy.android,
      cacheDirectoryProvider: () async => cacheDirectory,
    );
  });

  tearDown(() async {
    if (!slowResponseRelease.isCompleted) {
      slowResponseRelease.complete();
    }
    await cache.dispose();
    await server.close(force: true);
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  });

  test(
    'queue changes retain current, three upcoming, and previous audio files',
    () async {
      final first = _track(server, 'first');
      final second = _track(server, 'second');
      final third = _track(server, 'third');
      final fourth = _track(server, 'fourth');
      final fifth = _track(server, 'fifth');
      final sixth = _track(server, 'sixth');

      await cache.retainOnlyTracks([first, second, third, fourth, sixth]);
      expect(await cache.warmResolved(first), isNotNull);
      expect(await cache.warmResolved(second), isNotNull);
      expect(await cache.warmResolved(third), isNotNull);
      expect(await cache.warmResolved(fourth), isNotNull);
      expect(await cache.warmResolved(sixth), isNotNull);
      expect(await _audioFiles(cacheDirectory), hasLength(5));

      await cache.retainOnlyTracks([second, third, fourth, fifth, first]);

      expect(await cache.cachedFile(sixth), isNull);
      expect(await cache.cachedFile(first), isNotNull);
      expect(await cache.cachedFile(second), isNotNull);
      expect(await cache.cachedFile(third), isNotNull);
      expect(await cache.cachedFile(fourth), isNotNull);
      expect(await cache.warmResolved(fifth), isNotNull);
      expect(await cache.cachedFile(fifth), isNotNull);
      expect(await _audioFiles(cacheDirectory), hasLength(5));
    },
  );

  test(
    'protected tracks still obey file and byte quotas by priority',
    () async {
      await cache.dispose();
      cache = RemotePlaybackCache(
        policy: RemotePlaybackCachePolicy.android,
        cacheDirectoryProvider: () async => cacheDirectory,
        maximumFiles: 3,
        maximumBytes: 6 * 1024,
        maximumEntryBytes: 4 * 1024,
      );
      final tracks = [
        _track(server, 'current'),
        _track(server, 'next-1'),
        _track(server, 'next-2'),
        _track(server, 'next-3'),
        _track(server, 'previous'),
      ];

      await cache.retainOnlyTracks(tracks);
      expect(await cache.warmResolved(tracks[0]), isNotNull);
      expect(await cache.warmResolved(tracks[1]), isNotNull);
      expect(await cache.warmResolved(tracks[2]), isNotNull);
      expect(await cache.warmResolved(tracks[3]), isNull);
      expect(await cache.warmResolved(tracks[4]), isNull);

      expect(await cache.cachedFile(tracks[0]), isNotNull);
      expect(await cache.cachedFile(tracks[1]), isNotNull);
      expect(await cache.cachedFile(tracks[2]), isNotNull);
      expect(await cache.cachedFile(tracks[3]), isNull);
      expect(await cache.cachedFile(tracks[4]), isNull);
      expect(await _audioFiles(cacheDirectory), hasLength(3));
    },
  );

  test('an oversized response leaves no cached or partial file', () async {
    await cache.dispose();
    cache = RemotePlaybackCache(
      policy: RemotePlaybackCachePolicy.android,
      cacheDirectoryProvider: () async => cacheDirectory,
      maximumEntryBytes: 1024,
    );
    final track = _track(server, 'oversized');

    await cache.retainOnlyTracks([track]);
    expect(await cache.warmResolved(track), isNull);
    expect(await cache.cachedFile(track), isNull);
    expect(await cacheDirectory.list().toList(), isEmpty);
  });

  test(
    'startup cleanup removes partial and expired unprotected files',
    () async {
      final now = DateTime(2026, 8, 10, 12);
      final active = _track(server, 'active');
      await cache.dispose();
      cache = RemotePlaybackCache(
        policy: RemotePlaybackCachePolicy.android,
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

  test(
    'desktop keeps cached audio when the playback window changes or stops',
    () async {
      await cache.dispose();
      cache = RemotePlaybackCache(
        policy: RemotePlaybackCachePolicy.desktop,
        cacheDirectoryProvider: () async => cacheDirectory,
      );
      final first = _track(server, 'desktop-first');
      final second = _track(server, 'desktop-second');

      await cache.retainOnlyTracks([first]);
      expect(await cache.warmResolved(first), isNotNull);
      await cache.retainOnlyTracks([second]);
      expect(await cache.warmResolved(second), isNotNull);
      await cache.retainOnlyTracks(const <TrackInfo>[]);

      expect(await cache.cachedFile(first), isNotNull);
      expect(await cache.cachedFile(second), isNotNull);
      expect(await _audioFiles(cacheDirectory), hasLength(2));
    },
  );

  test('desktop hashes the complete canonical source URL', () async {
    await cache.dispose();
    cache = RemotePlaybackCache(
      policy: RemotePlaybackCachePolicy.desktop,
      cacheDirectoryProvider: () async => cacheDirectory,
    );
    final commonPrefix =
        'https://example.test/watch/${List.filled(120, 'a').join()}';
    final first = _track(
      server,
      'hash-first',
    ).copyWith(url: '$commonPrefix-first');
    final second = _track(
      server,
      'hash-second',
    ).copyWith(url: '$commonPrefix-second');

    await cache.retainOnlyTracks([first, second]);
    final firstFile = await cache.warmResolved(first);
    final secondFile = await cache.warmResolved(second);

    expect(firstFile, isNotNull);
    expect(secondFile, isNotNull);
    expect(firstFile!.path, isNot(secondFile!.path));
    expect(await cache.cachedFile(first), isNotNull);
    expect(await cache.cachedFile(second), isNotNull);
    expect(await _audioFiles(cacheDirectory), hasLength(2));
  });

  test('desktop cache access updates LRU eviction order', () async {
    var now = DateTime.now();
    await cache.dispose();
    cache = RemotePlaybackCache(
      policy: RemotePlaybackCachePolicy.desktop,
      cacheDirectoryProvider: () async => cacheDirectory,
      clock: () => now,
      maximumFiles: 2,
    );
    final first = _track(server, 'lru-first');
    final second = _track(server, 'lru-second');
    final third = _track(server, 'lru-third');

    await cache.retainOnlyTracks([first]);
    final firstFile = await cache.warmResolved(first);
    expect(firstFile, isNotNull);
    await firstFile!.setLastModified(now.subtract(const Duration(hours: 3)));

    await cache.retainOnlyTracks([second]);
    final secondFile = await cache.warmResolved(second);
    expect(secondFile, isNotNull);
    await secondFile!.setLastModified(now.subtract(const Duration(hours: 2)));

    now = now.add(const Duration(hours: 1));
    expect(await cache.cachedFile(first), isNotNull);
    await cache.retainOnlyTracks([third]);
    expect(await cache.warmResolved(third), isNotNull);

    expect(await cache.cachedFile(second), isNull);
    expect(await cache.cachedFile(first), isNotNull);
    expect(await cache.cachedFile(third), isNotNull);
    expect(await _audioFiles(cacheDirectory), hasLength(2));
  });

  test('desktop byte quota evicts the least recently used entry', () async {
    await cache.dispose();
    cache = RemotePlaybackCache(
      policy: RemotePlaybackCachePolicy.desktop,
      cacheDirectoryProvider: () async => cacheDirectory,
      maximumFiles: 10,
      maximumBytes: 4 * 1024,
    );
    final first = _track(server, 'bytes-first');
    final second = _track(server, 'bytes-second');
    final third = _track(server, 'bytes-third');

    await cache.retainOnlyTracks([first]);
    final firstFile = await cache.warmResolved(first);
    expect(firstFile, isNotNull);
    await firstFile!.setLastModified(
      DateTime.now().subtract(const Duration(hours: 2)),
    );
    await cache.retainOnlyTracks([second]);
    final secondFile = await cache.warmResolved(second);
    expect(secondFile, isNotNull);
    await secondFile!.setLastModified(
      DateTime.now().subtract(const Duration(hours: 1)),
    );
    await cache.retainOnlyTracks([third]);
    expect(await cache.warmResolved(third), isNotNull);

    expect(await cache.cachedFile(first), isNull);
    expect(await cache.cachedFile(second), isNotNull);
    expect(await cache.cachedFile(third), isNotNull);
    expect(await _audioFiles(cacheDirectory), hasLength(2));
  });

  test(
    'desktop startup preserves active audio and recent foreign partials',
    () async {
      final now = DateTime(2026, 8, 10, 12);
      await cache.dispose();
      cache = RemotePlaybackCache(
        policy: RemotePlaybackCachePolicy.desktop,
        cacheDirectoryProvider: () async => cacheDirectory,
        clock: () => now,
      );
      final active = _track(server, 'desktop-active');
      final activeFile = await cache.warmResolved(active);
      expect(activeFile, isNotNull);
      await activeFile!.setLastModified(
        now.subtract(const Duration(hours: 13)),
      );

      final expired = File('${cacheDirectory.path}/expired.m4a');
      await expired.writeAsBytes(const [1, 2, 3]);
      await expired.setLastModified(now.subtract(const Duration(hours: 13)));
      final empty = File('${cacheDirectory.path}/empty.m4a');
      await empty.writeAsBytes(const []);
      final recentPartial = File('${cacheDirectory.path}/foreign-recent.part');
      await recentPartial.writeAsBytes(const [4, 5, 6]);
      await recentPartial.setLastModified(
        now.subtract(const Duration(minutes: 30)),
      );
      final stalePartial = File('${cacheDirectory.path}/foreign-stale.part');
      await stalePartial.writeAsBytes(const [7, 8, 9]);
      await stalePartial.setLastModified(
        now.subtract(const Duration(hours: 2)),
      );

      await cache.prepareSession(protectedSourceUrls: [active.url]);

      expect(await activeFile.exists(), isTrue);
      expect(await expired.exists(), isFalse);
      expect(await empty.exists(), isFalse);
      expect(await recentPartial.exists(), isTrue);
      expect(await stalePartial.exists(), isFalse);
      expect(await _audioFiles(cacheDirectory), hasLength(1));
    },
  );

  test('desktop rejects successful HTML and JSON responses', () async {
    await cache.dispose();
    cache = RemotePlaybackCache(
      policy: RemotePlaybackCachePolicy.desktop,
      cacheDirectoryProvider: () async => cacheDirectory,
    );
    final html = _track(server, 'html-response');
    final json = _track(server, 'json-response');

    await cache.retainOnlyTracks([html, json]);

    expect(await cache.warmResolved(html), isNull);
    expect(await cache.warmResolved(json), isNull);
    expect(await cache.cachedFile(html), isNull);
    expect(await cache.cachedFile(json), isNull);
    expect(await cacheDirectory.list().toList(), isEmpty);
  });

  test('evict stops reusing an invalid desktop cache entry', () async {
    await cache.dispose();
    cache = RemotePlaybackCache(
      policy: RemotePlaybackCachePolicy.desktop,
      cacheDirectoryProvider: () async => cacheDirectory,
    );
    final track = _track(server, 'invalid-cache');

    await cache.retainOnlyTracks([track]);
    expect(await cache.warmResolved(track), isNotNull);

    await cache.evict(track);

    expect(await cache.cachedFile(track), isNull);
    expect(await _audioFiles(cacheDirectory), isEmpty);
  });

  test('desktop instances publish the same cache entry atomically', () async {
    await cache.dispose();
    cache = RemotePlaybackCache(
      policy: RemotePlaybackCachePolicy.desktop,
      cacheDirectoryProvider: () async => cacheDirectory,
    );
    final secondCache = RemotePlaybackCache(
      policy: RemotePlaybackCachePolicy.desktop,
      cacheDirectoryProvider: () async => cacheDirectory,
    );
    final track = _track(server, 'shared-entry');
    try {
      await Future.wait([
        cache.retainOnlyTracks([track]),
        secondCache.retainOnlyTracks([track]),
      ]);

      final results = await Future.wait([
        cache.warmResolved(track),
        secondCache.warmResolved(track),
      ]);

      expect(results, everyElement(isNotNull));
      expect(await cache.cachedFile(track), isNotNull);
      expect(await secondCache.cachedFile(track), isNotNull);
      expect(await _audioFiles(cacheDirectory), hasLength(1));
      expect(
        await cacheDirectory
            .list()
            .where((entity) => entity.path.endsWith('.part'))
            .toList(),
        isEmpty,
      );
    } finally {
      await secondCache.dispose();
    }
  });

  test(
    'desktop instances serialize different formats for one canonical source',
    () async {
      await cache.dispose();
      cache = RemotePlaybackCache(
        policy: RemotePlaybackCachePolicy.desktop,
        cacheDirectoryProvider: () async => cacheDirectory,
      );
      final secondCache = RemotePlaybackCache(
        policy: RemotePlaybackCachePolicy.desktop,
        cacheDirectoryProvider: () async => cacheDirectory,
      );
      const sourceUrl = 'https://www.youtube.com/watch?v=shared-variant';
      final m4a = _track(server, 'variant-m4a').copyWith(url: sourceUrl);
      final webm = _track(server, 'variant-webm').copyWith(url: sourceUrl);
      try {
        await Future.wait([
          cache.retainOnlyTracks([m4a]),
          secondCache.retainOnlyTracks([webm]),
        ]);

        final results = await Future.wait([
          cache.warmResolved(m4a),
          secondCache.warmResolved(webm),
        ]);

        expect(results, everyElement(isNotNull));
        expect(results[0]!.path, results[1]!.path);
        expect(await _audioFiles(cacheDirectory), hasLength(1));
      } finally {
        await secondCache.dispose();
      }
    },
  );

  test(
    'desktop dispose cancels a slow download and removes its partial',
    () async {
      await cache.dispose();
      cache = RemotePlaybackCache(
        policy: RemotePlaybackCachePolicy.desktop,
        cacheDirectoryProvider: () async => cacheDirectory,
      );
      final track = _track(server, 'slow-response');
      await cache.retainOnlyTracks([track]);

      final warmup = cache.warmResolved(track);
      await slowResponseStarted.future.timeout(const Duration(seconds: 2));
      await cache.dispose().timeout(const Duration(seconds: 2));
      if (!slowResponseRelease.isCompleted) {
        slowResponseRelease.complete();
      }

      expect(await warmup, isNull);
      expect(
        await cacheDirectory
            .list()
            .where((entity) => entity.path.endsWith('.part'))
            .toList(),
        isEmpty,
      );
    },
  );
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
      .where(
        (entity) =>
            entity is File &&
            !entity.path.endsWith('.part') &&
            !entity.path.endsWith('.lock'),
      )
      .cast<File>()
      .toList();
}
