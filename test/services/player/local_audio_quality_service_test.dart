import 'dart:async';
import 'dart:io';

import 'package:bstream_music/services/player/local_audio_quality_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _quality = LocalAudioQuality(
  codec: 'opus',
  mimeType: 'audio/ogg',
  sampleRate: 48000,
  bitrate: 141000,
  channels: 2,
);

String _path(String name) => p.normalize(
  File(
    p.join(Directory.systemTemp.path, 'bstream-quality-$name'),
  ).absolute.path,
);

Future<void> _drain() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('only filesystem, content and iPod-library sources are supported', () {
    for (final source in [
      '/tmp/song.flac',
      r'C:\Music\song.m4a',
      File(_path('supported.mp3')).uri.toString(),
      'content://media/external/audio/media/17',
      'ipod-library://item/item.m4a?id=17',
    ]) {
      expect(
        isSupportedLocalAudioQualitySource(source),
        isTrue,
        reason: source,
      );
    }
    for (final source in [
      '',
      '  ',
      'http://example.com/audio.mp3',
      'HTTPS://example.com/audio.mp3',
      'ftp://example.com/audio.mp3',
      'data:audio/wav;base64,AA==',
      'blob:local',
      'content:/missing-authority',
      'ipod-library:/missing-authority',
      'file:relative',
      '/tmp/bad\u0000name',
    ]) {
      expect(
        isSupportedLocalAudioQualitySource(source),
        isFalse,
        reason: source,
      );
    }
  });

  test(
    'invalid sources never start metadata IO or invoke the loader',
    () async {
      var loads = 0, stats = 0;
      final service = LocalAudioQualityService(
        loader: (_) async {
          loads++;
          return _quality;
        },
        fingerprintLoader: (_) async {
          stats++;
          return 'stable';
        },
      );
      addTearDown(service.dispose);
      expect(await service.read('https://example.com/song.mp3'), isNull);
      expect(await service.read(''), isNull);
      expect(loads, 0);
      expect(stats, 0);
    },
  );

  test('DTO accepts finite positive integers and omits malformed details', () {
    expect(LocalAudioQuality.fromMap(null), isNull);
    expect(LocalAudioQuality.fromMap({}), isNull);
    expect(
      LocalAudioQuality.fromMap({
        'codec': '  OpUs ',
        'mimeType': ' AUDIO/OGG ',
        'sampleRate': 48000.0,
        'bitrate': 141000,
        'channels': 2,
      }),
      _quality,
    );
    expect(
      LocalAudioQuality.fromMap({
        'codec': '',
        'mimeType': 12,
        'sampleRate': -48000,
        'bitrate': double.infinity,
        'channels': 65,
      }),
      isNull,
    );
    expect(
      LocalAudioQuality.fromMap({
        'codec': 'flac',
        'sampleRate': '44100',
        'bitrate': 1.5,
        'channels': double.nan,
      }),
      const LocalAudioQuality(codec: 'flac'),
    );
    expect(_quality, LocalAudioQuality.fromMap(_quality.toMap()));
    expect(
      _quality.hashCode,
      LocalAudioQuality.fromMap(_quality.toMap()).hashCode,
    );
  });

  test(
    'one in-flight read is shared and file URI aliases reuse the cache',
    () async {
      var loads = 0, stats = 0;
      final result = Completer<LocalAudioQuality?>();
      final path = _path('coalesced.opus');
      final service = LocalAudioQualityService(
        loader: (source) {
          expect(source, path);
          loads++;
          return result.future;
        },
        fingerprintLoader: (_) async {
          stats++;
          return 'stable';
        },
      );
      addTearDown(service.dispose);
      final first = service.read(path), second = service.read(path);
      expect(identical(first, second), isTrue);
      await _drain();
      expect(loads, 1);
      expect(stats, 1);
      result.complete(_quality);
      expect(await first, _quality);
      expect(await second, _quality);
      expect(await service.read(File(path).uri.toString()), _quality);
      expect(loads, 1);
      expect(stats, 2);
    },
  );

  test(
    'file fingerprint changes invalidate positive and negative cached results',
    () async {
      var revision = 0, loads = 0;
      final service = LocalAudioQualityService(
        loader: (_) async {
          loads++;
          return revision == 0 ? null : _quality;
        },
        fingerprintLoader: (_) async => revision,
      );
      addTearDown(service.dispose);
      final path = _path('updated.flac');
      expect(await service.read(path), isNull);
      expect(await service.read(path), isNull);
      expect(loads, 1);
      revision++;
      expect(await service.read(path), _quality);
      expect(loads, 2);
      expect(await service.read(path), _quality);
      revision++;
      expect(await service.read(path), _quality);
      expect(loads, 3);
    },
  );

  test('LRU capacity is bounded and a cache hit updates recency', () async {
    final loads = <String, int>{};
    final service = LocalAudioQualityService(
      maxEntries: 2,
      loader: (source) async {
        loads.update(source, (n) => n + 1, ifAbsent: () => 1);
        return _quality;
      },
      fingerprintLoader: (_) async => 'stable',
    );
    addTearDown(service.dispose);
    final a = _path('a'), b = _path('b'), c = _path('c');
    for (final path in [a, b, a, c, a, b]) {
      await service.read(path);
    }
    expect(loads, {a: 1, b: 2, c: 1});
  });

  for (final source in [
    'content://media/external/audio/media/17',
    'ipod-library://item/item.m4a?id=17',
  ]) {
    test(
      '$source expires only on demand, with no fingerprint or polling',
      () async {
        var now = DateTime(2026), loads = 0, stats = 0;
        final service = LocalAudioQualityService(
          now: () => now,
          loader: (_) async {
            loads++;
            return _quality;
          },
          fingerprintLoader: (_) async {
            stats++;
            return 'unused';
          },
        );
        addTearDown(service.dispose);
        expect(await service.read(source), _quality);
        now = now.add(const Duration(seconds: 29));
        expect(await service.read(source), _quality);
        expect(loads, 1);
        now = now.add(const Duration(seconds: 1));
        await _drain();
        expect(loads, 1, reason: 'Advancing time does not schedule a refresh');
        expect(await service.read(source), _quality);
        expect(loads, 2);
        expect(stats, 0);
      },
    );
  }

  test(
    'errors become short-lived unknown results and can be retried',
    () async {
      var now = DateTime(2026), loads = 0;
      final service = LocalAudioQualityService(
        now: () => now,
        loader: (_) async {
          if (++loads == 1) throw const FileSystemException('unavailable');
          return _quality;
        },
        fingerprintLoader: (_) async => 'stable',
      );
      addTearDown(service.dispose);
      final path = _path('retry.mp3');
      expect(await service.read(path), isNull);
      now = now.add(const Duration(seconds: 9));
      expect(await service.read(path), isNull);
      expect(loads, 1);
      now = now.add(const Duration(seconds: 1));
      expect(await service.read(path), _quality);
      expect(loads, 2);
      now = now.add(const Duration(days: 1));
      expect(await service.read(path), _quality);
      expect(
        loads,
        2,
        reason: 'An unchanged fingerprint keeps a valid file cache',
      );
    },
  );

  test(
    'fingerprint failures use a bounded TTL instead of caching forever',
    () async {
      var now = DateTime(2026), loads = 0;
      final service = LocalAudioQualityService(
        now: () => now,
        loader: (_) async {
          loads++;
          return _quality;
        },
        fingerprintLoader: (_) async =>
            throw const FileSystemException('stat failed'),
      );
      addTearDown(service.dispose);
      final path = _path('stat-failure.m4a');
      expect(await service.read(path), _quality);
      expect(await service.read(path), _quality);
      expect(loads, 1);
      now = now.add(const Duration(seconds: 30));
      expect(await service.read(path), _quality);
      expect(loads, 2);
    },
  );

  test('injected results are sanitized before they enter the cache', () async {
    final service = LocalAudioQualityService(
      loader: (_) async => const LocalAudioQuality(
        codec: ' FLAC ',
        sampleRate: -1,
        bitrate: 0,
        channels: 0,
      ),
      fingerprintLoader: (_) async => 'stable',
    );
    addTearDown(service.dispose);
    expect(
      await service.read(_path('invalid.flac')),
      const LocalAudioQuality(codec: 'flac'),
    );
  });

  test(
    'at most two requests execute concurrently while queued paths complete',
    () async {
      final pending = <String, Completer<LocalAudioQuality?>>{};
      var active = 0, maximum = 0;
      final service = LocalAudioQualityService(
        fingerprintLoader: (_) async => 'stable',
        loader: (source) async {
          active++;
          if (active > maximum) maximum = active;
          final result = Completer<LocalAudioQuality?>();
          pending[source] = result;
          try {
            return await result.future;
          } finally {
            active--;
          }
        },
      );
      addTearDown(service.dispose);
      final requests = [
        for (var i = 0; i < 10; i++) service.read(_path('queue-$i')),
      ];
      await _drain();
      expect(pending.length, 2);
      for (var completed = 0; completed < 10;) {
        final open = pending.values
            .where((value) => !value.isCompleted)
            .toList();
        expect(open, isNotEmpty);
        for (final value in open) {
          value.complete(_quality);
          completed++;
        }
        await _drain();
      }
      expect(await Future.wait(requests), everyElement(_quality));
      expect(maximum, 2);
    },
  );

  test('rapid skips cannot create an unbounded request queue', () async {
    final pending = <Completer<LocalAudioQuality?>>[];
    final service = LocalAudioQualityService(
      maxEntries: 2,
      fingerprintLoader: (_) async => 'stable',
      loader: (_) {
        final result = Completer<LocalAudioQuality?>();
        pending.add(result);
        return result.future;
      },
    );
    addTearDown(service.dispose);
    final accepted = [
      for (var i = 0; i < 4; i++) service.read(_path('bounded-$i')),
    ];
    expect(await service.read(_path('bounded-overflow')), isNull);
    await _drain();
    expect(pending.length, 2);
    for (final value in pending.toList()) {
      value.complete(_quality);
    }
    await _drain();
    expect(pending.length, 4);
    for (final value in pending.where((value) => !value.isCompleted)) {
      value.complete(_quality);
    }
    expect(await Future.wait(accepted), everyElement(_quality));
  });

  test(
    'dispose suppresses late results, releases waiters and prevents new IO',
    () async {
      final pending = <Completer<LocalAudioQuality?>>[];
      final service = LocalAudioQualityService(
        fingerprintLoader: (_) async => 'stable',
        loader: (_) {
          final result = Completer<LocalAudioQuality?>();
          pending.add(result);
          return result.future;
        },
      );
      final requests = [
        for (var i = 0; i < 3; i++) service.read(_path('disposed-$i')),
      ];
      await _drain();
      expect(pending.length, 2);
      service.dispose();
      service.dispose();
      for (final value in pending) {
        value.complete(_quality);
      }
      expect(await Future.wait(requests), everyElement(isNull));
      expect(await service.read(_path('after-dispose')), isNull);
      expect(pending.length, 2);
    },
  );

  test('cache configuration rejects invalid capacities and lifetimes', () {
    for (final size in [0, -1, 257]) {
      expect(
        () => LocalAudioQualityService(maxEntries: size),
        throwsArgumentError,
      );
    }
    expect(
      () => LocalAudioQualityService(contentCacheTtl: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => LocalAudioQualityService(
        negativeCacheTtl: const Duration(seconds: -1),
      ),
      throwsArgumentError,
    );
  });
}
