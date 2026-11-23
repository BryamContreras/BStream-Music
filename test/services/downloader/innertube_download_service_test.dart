import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/services/audio_sources/audio_format_details.dart';
import 'package:bstream_music/services/downloader/http_audio_transfer.dart';
import 'package:bstream_music/services/downloader/innertube_download_service.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_profile.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_router.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_playback_service.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_models.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'downloads the verified upgrade and reuses supplied catalog metadata',
    () async {
      final transfer = _UpgradeRecordingTransfer();
      const track = TrackInfo(
        id: 'dQw4w9WgXcQ',
        title: 'Canonical title',
        artist: 'Artist',
        url: 'dQw4w9WgXcQ',
      );
      final fixture = await _upgradeFixture(transfer, (
        url,
        metadata,
        baseline,
        current,
      ) async {
        expect(identical(metadata, track), isTrue);
        expect(baseline.source, AudioStreamSource.innerTube);
        expect(baseline.bitrate, 129000);
        expect(current(), isTrue);
        return _upgrade();
      });
      final result = await fixture.downloader.downloadAudio(
        track.url,
        DownloadOptions(
          outputDirectory: fixture.directory.path,
          fileName: 'Song',
          track: track,
        ),
      );
      expect(transfer.requests, ['https://jio.example/audio_320.mp4']);
      expect(result.fileName, 'Song-jiosaavn-320.m4a');
      expect(result.sourceUrl, track.url);
      expect(fixture.catalog.songLookups, 0);
      expect(File(result.filePath).readAsBytesSync(), [3, 2, 0]);
      expect(
        result.audioFormat,
        const AudioFormatDetails(
          codec: 'aac',
          mimeType: 'audio/mp4',
          bitrate: 320000,
          sampleRate: 44100,
          channels: 2,
        ),
      );
    },
  );

  test('keeps verified CD FLAC even if its bitrate was not provided', () async {
    final transfer = _UpgradeRecordingTransfer();
    final fixture = await _upgradeFixture(
      transfer,
      (url, metadata, baseline, current) async => const AudioStreamResolution(
        source: AudioStreamSource.audioExtension,
        streamUrl: 'https://addon.example/song.flac',
        streamExtension: 'flac',
        streamMimeType: 'audio/flac',
        formatId: '5f54e2dc321c89e3',
        codec: 'flac',
        sampleRate: 44100,
        channels: 2,
        bitDepth: 16,
      ),
    );
    final result = await fixture.downloader.downloadAudio(
      'dQw4w9WgXcQ',
      DownloadOptions(
        outputDirectory: fixture.directory.path,
        fileName: 'Song',
      ),
    );
    expect(transfer.requests, ['https://addon.example/song.flac']);
    expect(result.fileName, 'Song-cd-5f54e2dc321c.flac');
    expect(
      result.audioFormat,
      const AudioFormatDetails(
        codec: 'flac',
        mimeType: 'audio/flac',
        sampleRate: 44100,
        channels: 2,
        bitDepth: 16,
      ),
    );
  });

  for (final mode in [
    'unavailable',
    'lower',
    'lookup-error',
    'cdn-error',
    'local-uri',
  ]) {
    test('retains the YouTube download on $mode', () async {
      final transfer = _UpgradeRecordingTransfer(
        failUpgrade: mode == 'cdn-error',
      );
      final fixture = await _upgradeFixture(transfer, (
        url,
        metadata,
        baseline,
        current,
      ) async {
        if (mode == 'lookup-error') {
          throw StateError('Optional provider offline');
        }
        if (mode == 'local-uri') {
          return const AudioStreamResolution(
            source: AudioStreamSource.jioSaavn,
            streamUrl: 'file:///tmp/audio.m4a',
            bitrate: 320000,
          );
        }
        return mode == 'unavailable'
            ? null
            : _upgrade(bitrate: mode == 'lower' ? 96000 : 320000);
      });
      final result = await fixture.downloader.downloadAudio(
        'dQw4w9WgXcQ',
        DownloadOptions(
          outputDirectory: fixture.directory.path,
          fileName: 'Song',
        ),
      );
      expect(transfer.requests.last, 'https://yt.example/audio.m4a');
      expect(File(result.filePath).readAsBytesSync(), [1, 2, 8]);
      expect(result.audioFormat?.codec, 'mp4a.40.2');
      expect(result.audioFormat?.bitrate, 129000);
      expect(result.audioFormat?.sampleRate, 44100);
      expect(result.audioFormat?.channels, 2);
      expect(
        fixture.directory.listSync().whereType<File>().map((file) => file.path),
        [result.filePath],
      );
    });
  }

  test('cancelled quality lookup cannot start either transfer', () async {
    final entered = Completer<void>();
    final lookup = Completer<AudioStreamResolution?>();
    final transfer = _UpgradeRecordingTransfer();
    final fixture = await _upgradeFixture(transfer, (
      url,
      metadata,
      baseline,
      current,
    ) {
      entered.complete();
      return lookup.future;
    });
    final downloading = fixture.downloader.downloadAudio(
      'dQw4w9WgXcQ',
      DownloadOptions(
        outputDirectory: fixture.directory.path,
        fileName: 'Song',
        taskId: 'cancel-upgrade',
      ),
    );
    final rejected = expectLater(
      downloading,
      throwsA(
        isA<DownloaderException>().having(
          (error) => error.code,
          'code',
          'download_cancelled',
        ),
      ),
    );
    await entered.future;
    await fixture.downloader.cancelDownload('cancel-upgrade');
    lookup.complete(_upgrade());
    await rejected;
    expect(transfer.requests, isEmpty);
    expect(fixture.directory.listSync(), isEmpty);
  });

  test(
    'downloads a resolved InnerTube stream without an external tool',
    () async {
      final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bytes = List<int>.generate(4096, (index) => (index % 251) + 1);
      media.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('audio', 'mp4')
          ..contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
      });
      addTearDown(() => media.close(force: true));

      final playerTransport = _PlayerTransport(
        'http://127.0.0.1:${media.port}/audio',
      );
      final playback = InnerTubePlaybackService(
        transport: playerTransport,
        validator: _AlwaysValidStream(),
        router: InnerTubeClientRouter(
          profiles: const [InnerTubeClientRegistry.androidSdkless],
        ),
        maxRequestAttempts: 1,
      );
      final downloader = InnerTubeDownloadService(
        playback: playback,
        catalog: _Catalog(),
        transfer: HttpAudioTransfer(maxRetries: 0),
      );
      addTearDown(() async {
        await downloader.dispose();
        await playback.dispose();
      });
      final directory = await Directory.systemTemp.createTemp(
        'bstream-innertube-download-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final progress = <double?>[];
      final subscription = downloader.progressStream.listen(
        (event) => progress.add(event.progress),
      );
      addTearDown(subscription.cancel);

      final result = await downloader.downloadAudio(
        'dQw4w9WgXcQ',
        DownloadOptions(outputDirectory: directory.path),
      );

      expect(await File(result.filePath).readAsBytes(), bytes);
      expect(result.fileName, 'BStream - Test Song.m4a');
      expect(progress, contains(1));
      expect(await File('${result.filePath}.part').exists(), isFalse);
    },
  );

  test('downloads the highest-bitrate compatible audio format', () async {
    final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = <int>[0x1A, 0x45, 0xDF, 0xA3, 1, 2, 3, 4];
    final requestedPaths = <String>[];
    media.listen((request) async {
      requestedPaths.add(request.uri.path);
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('audio', 'webm')
        ..contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    addTearDown(() => media.close(force: true));

    final playerTransport = _PlayerTransport(
      'http://127.0.0.1:${media.port}/aac',
      additionalAudioFormats: <Map<String, Object?>>[
        <String, Object?>{
          'itag': 251,
          'url': 'http://127.0.0.1:${media.port}/opus',
          'mimeType': 'audio/webm; codecs="opus"',
          'bitrate': 192000,
          'contentLength': bytes.length.toString(),
        },
      ],
    );
    final playback = InnerTubePlaybackService(
      transport: playerTransport,
      validator: _AlwaysValidStream(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.androidSdkless],
      ),
      maxRequestAttempts: 1,
    );
    final downloader = InnerTubeDownloadService(
      playback: playback,
      catalog: _Catalog(),
      transfer: HttpAudioTransfer(maxRetries: 0),
    );
    addTearDown(() async {
      await downloader.dispose();
      await playback.dispose();
    });
    final directory = await Directory.systemTemp.createTemp(
      'bstream-innertube-bitrate-download-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final result = await downloader.downloadAudio(
      'dQw4w9WgXcQ',
      DownloadOptions(outputDirectory: directory.path),
    );

    expect(await File(result.filePath).readAsBytes(), bytes);
    expect(result.fileName, 'BStream - Test Song.webm');
    expect(requestedPaths, <String>['/opus']);
  });

  test('falls back to a muxed MP4 and preserves its real extension', () async {
    final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = <int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 1, 2, 3];
    media.listen((request) async {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType('video', 'mp4')
        ..contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    addTearDown(() => media.close(force: true));

    final playerTransport = _PlayerTransport(
      'http://127.0.0.1:${media.port}/muxed',
      muxedOnly: true,
    );
    final playback = InnerTubePlaybackService(
      transport: playerTransport,
      validator: _AlwaysValidStream(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.androidSdkless],
      ),
      maxRequestAttempts: 1,
    );
    final downloader = InnerTubeDownloadService(
      playback: playback,
      catalog: _Catalog(),
      transfer: HttpAudioTransfer(maxRetries: 0),
    );
    addTearDown(() async {
      await downloader.dispose();
      await playback.dispose();
    });
    final directory = await Directory.systemTemp.createTemp(
      'bstream-innertube-muxed-download-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final result = await downloader.downloadAudio(
      'dQw4w9WgXcQ',
      DownloadOptions(outputDirectory: directory.path),
    );

    expect(await File(result.filePath).readAsBytes(), bytes);
    expect(result.fileName, 'BStream - Test Song.mp4');
    expect(playerTransport.postCalls, 2);
  });

  test('AVFoundation policy never writes a WebM-only download', () async {
    final playerTransport = _PlayerTransport(
      'https://media.example/opus',
      audioItag: 251,
      audioMimeType: 'audio/webm; codecs="opus"',
    );
    final playback = InnerTubePlaybackService(
      transport: playerTransport,
      validator: _AlwaysValidStream(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.androidSdkless],
      ),
      audioFormatPredicate: isAvFoundationCompatibleInnerTubeAudio,
      maxRequestAttempts: 1,
    );
    final downloader = InnerTubeDownloadService(
      playback: playback,
      catalog: _Catalog(),
    );
    addTearDown(() async {
      await downloader.dispose();
      await playback.dispose();
    });
    final directory = await Directory.systemTemp.createTemp(
      'bstream-innertube-ios-format-download-',
    );
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      downloader.downloadAudio(
        'dQw4w9WgXcQ',
        DownloadOptions(outputDirectory: directory.path),
      ),
      throwsA(
        isA<DownloaderException>().having(
          (error) => error.details.toString(),
          'playback cause',
          contains('no audio format supported by this platform'),
        ),
      ),
    );

    expect(await directory.list().toList(), isEmpty);
    expect(playerTransport.postCalls, 1);
  });

  test('does not mask unplayable content with the muxed fallback', () async {
    final playerTransport = _PlayerTransport(
      'https://media.example/unavailable',
      playabilityStatus: 'LOGIN_REQUIRED',
    );
    final playback = InnerTubePlaybackService(
      transport: playerTransport,
      validator: _AlwaysValidStream(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.androidSdkless],
      ),
      maxRequestAttempts: 1,
    );
    final downloader = InnerTubeDownloadService(
      playback: playback,
      catalog: _Catalog(),
    );
    addTearDown(() async {
      await downloader.dispose();
      await playback.dispose();
    });
    final directory = await Directory.systemTemp.createTemp(
      'bstream-innertube-unplayable-download-',
    );
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      downloader.downloadAudio(
        'dQw4w9WgXcQ',
        DownloadOptions(outputDirectory: directory.path),
      ),
      throwsA(isA<Exception>()),
    );

    expect(playerTransport.postCalls, 1);
  });

  test(
    'refresh excludes only the exact failed profile without poisoning health',
    () async {
      final rejectedMedia = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      rejectedMedia.listen((request) async {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      });
      addTearDown(() => rejectedMedia.close(force: true));
      final acceptedMedia = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final bytes = <int>[0x49, 0x44, 0x33, 1, 2, 3, 4];
      acceptedMedia.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('audio', 'mp4')
          ..contentLength = bytes.length
          ..add(bytes);
        await request.response.close();
      });
      addTearDown(() => acceptedMedia.close(force: true));

      final playerTransport = _RoutingPlayerTransport(<int, String>{
        3: 'http://127.0.0.1:${rejectedMedia.port}/audio',
        101: 'http://127.0.0.1:${acceptedMedia.port}/audio',
      });
      final router = InnerTubeClientRouter(
        profiles: const [
          InnerTubeClientRegistry.androidSdkless,
          InnerTubeClientRegistry.visionOS,
        ],
      );
      final playback = InnerTubePlaybackService(
        transport: playerTransport,
        validator: _AlwaysValidStream(),
        router: router,
        maxRequestAttempts: 1,
      );
      final downloader = InnerTubeDownloadService(
        playback: playback,
        catalog: _Catalog(),
        transfer: HttpAudioTransfer(maxRetries: 0),
        maxStreamRefreshes: 2,
      );
      addTearDown(() async {
        await downloader.dispose();
        await playback.dispose();
      });
      final directory = await Directory.systemTemp.createTemp(
        'bstream-innertube-profile-refresh-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final result = await downloader.downloadAudio(
        'dQw4w9WgXcQ',
        DownloadOptions(outputDirectory: directory.path),
      );

      expect(await File(result.filePath).readAsBytes(), bytes);
      expect(playerTransport.clientIds, <int>[3, 3, 101]);
      expect(router.healthFor('androidSdkless').consecutiveFailures, 0);
      expect(router.healthFor('androidSdkless').cooldownUntil, isNull);
    },
  );

  test('uses YouTube Music for metadata and search', () async {
    final playback = InnerTubePlaybackService(
      transport: _PlayerTransport('https://media.example/audio'),
      validator: _AlwaysValidStream(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.androidSdkless],
      ),
      maxRequestAttempts: 1,
    );
    final downloader = InnerTubeDownloadService(
      playback: playback,
      catalog: _Catalog(),
    );
    addTearDown(() async {
      await downloader.dispose();
      await playback.dispose();
    });

    final info = await downloader.getInfo('dQw4w9WgXcQ');
    final playbackInfo = await downloader.getPlaybackInfo('dQw4w9WgXcQ');
    final results = await downloader.search('test song');

    expect(info.title, 'Test Song');
    expect(info.artist, 'BStream');
    expect(playbackInfo.streamClientProfileKey, 'androidSdkless');
    expect(playbackInfo.streamBitrate, 129000);
    expect(playbackInfo.streamSampleRate, 44100);
    expect(playbackInfo.streamChannels, 2);
    expect(results.single.id, 'dQw4w9WgXcQ');
  });

  test(
    'uses bounded URL ranges for GoogleVideo and reuses a supplied filename',
    () async {
      final catalog = _Catalog();
      final transfer = _RecordingAudioTransfer();
      final playback = InnerTubePlaybackService(
        transport: _PlayerTransport(
          'https://rr1---sn.test.googlevideo.com/videoplayback?c=IOS',
        ),
        validator: _AlwaysValidStream(),
        router: InnerTubeClientRouter(
          profiles: const [InnerTubeClientRegistry.visionOS],
        ),
        maxRequestAttempts: 1,
      );
      final downloader = InnerTubeDownloadService(
        playback: playback,
        catalog: catalog,
        transfer: transfer,
      );
      addTearDown(() async {
        await downloader.dispose();
        await playback.dispose();
      });
      final directory = await Directory.systemTemp.createTemp(
        'bstream-innertube-ranged-download-',
      );
      addTearDown(() => directory.delete(recursive: true));

      await downloader.downloadAudio(
        'dQw4w9WgXcQ',
        DownloadOptions(
          outputDirectory: directory.path,
          fileName: 'stable-library-name',
        ),
      );

      expect(catalog.songLookups, 0);
      expect(transfer.rangePlan?.totalBytes, 4096);
      expect(
        transfer.rangePlan?.transport,
        HttpAudioRangeTransport.queryParameter,
      );
      expect(transfer.rangePlan?.maximumChunkBytes, 8 * 1024 * 1024);
    },
  );

  test('uses bounded header ranges for Android GoogleVideo streams', () async {
    final transfer = _RecordingAudioTransfer();
    final playback = InnerTubePlaybackService(
      transport: _PlayerTransport(
        'https://rr1---sn.test.googlevideo.com/videoplayback?c=ANDROID',
      ),
      validator: _AlwaysValidStream(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.androidSdkless],
      ),
      maxRequestAttempts: 1,
    );
    final downloader = InnerTubeDownloadService(
      playback: playback,
      catalog: _Catalog(),
      transfer: transfer,
    );
    addTearDown(() async {
      await downloader.dispose();
      await playback.dispose();
    });
    final directory = await Directory.systemTemp.createTemp(
      'bstream-innertube-android-range-',
    );
    addTearDown(() => directory.delete(recursive: true));

    await downloader.downloadAudio(
      'dQw4w9WgXcQ',
      DownloadOptions(
        outputDirectory: directory.path,
        fileName: 'android-range',
      ),
    );

    expect(transfer.rangePlan?.totalBytes, 4096);
    expect(transfer.rangePlan?.transport, HttpAudioRangeTransport.header);
  });

  test('cancels one task and removes all partial transfer artifacts', () async {
    final transfer = _CancellableAudioTransfer();
    final playback = InnerTubePlaybackService(
      transport: _PlayerTransport('https://media.example/audio'),
      validator: _AlwaysValidStream(),
      router: InnerTubeClientRouter(
        profiles: const [InnerTubeClientRegistry.androidSdkless],
      ),
      maxRequestAttempts: 1,
    );
    final downloader = InnerTubeDownloadService(
      playback: playback,
      catalog: _Catalog(),
      transfer: transfer,
    );
    addTearDown(() async {
      await downloader.dispose();
      await playback.dispose();
    });
    final directory = await Directory.systemTemp.createTemp(
      'bstream-innertube-cancel-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final statuses = <DownloadProgressStatus>[];
    final subscription = downloader.progressStream.listen(
      (progress) => statuses.add(progress.status),
    );
    addTearDown(subscription.cancel);

    const taskId = 'cancel-this-task';
    final download = downloader.downloadAudio(
      'dQw4w9WgXcQ',
      DownloadOptions(
        outputDirectory: directory.path,
        fileName: 'cancelled-track',
        taskId: taskId,
      ),
    );
    await transfer.started.future;

    await downloader.cancelDownload(taskId);

    await expectLater(
      download,
      throwsA(
        isA<DownloaderException>().having(
          (error) => error.code,
          'code',
          'download_cancelled',
        ),
      ),
    );
    expect(await directory.list().toList(), isEmpty);
    expect(statuses, isNot(contains(DownloadProgressStatus.failed)));
  });

  test(
    'does not mistake an eleven-letter search term for a video ID',
    () async {
      final catalog = _Catalog();
      final playback = InnerTubePlaybackService(
        transport: _PlayerTransport('https://media.example/audio'),
        validator: _AlwaysValidStream(),
        router: InnerTubeClientRouter(
          profiles: const [InnerTubeClientRegistry.androidSdkless],
        ),
        maxRequestAttempts: 1,
      );
      final downloader = InnerTubeDownloadService(
        playback: playback,
        catalog: catalog,
      );
      addTearDown(() async {
        await downloader.dispose();
        await playback.dispose();
      });

      final results = await downloader.search('traicionera');

      expect(results.single.id, 'dQw4w9WgXcQ');
      expect(catalog.queries, ['traicionera']);
    },
  );
}

AudioStreamResolution _upgrade({int bitrate = 320000}) => AudioStreamResolution(
  source: AudioStreamSource.jioSaavn,
  streamUrl: 'https://jio.example/audio_320.mp4',
  streamExtension: 'm4a',
  streamMimeType: 'audio/mp4',
  codec: 'aac',
  bitrate: bitrate,
  sampleRate: 44100,
  channels: 2,
);

Future<
  ({InnerTubeDownloadService downloader, Directory directory, _Catalog catalog})
>
_upgradeFixture(
  _UpgradeRecordingTransfer transfer,
  DownloadAudioUpgrade callback,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'bstream-provider-download-',
  );
  final playback = InnerTubePlaybackService(
    transport: _PlayerTransport('https://yt.example/audio.m4a'),
    validator: _AlwaysValidStream(),
    router: InnerTubeClientRouter(
      profiles: const [InnerTubeClientRegistry.androidSdkless],
    ),
    maxRequestAttempts: 1,
  );
  final catalog = _Catalog();
  final downloader = InnerTubeDownloadService(
    playback: playback,
    catalog: catalog,
    transfer: transfer,
    audioUpgrade: callback,
  );
  addTearDown(() async {
    await downloader.dispose();
    await playback.dispose();
    await directory.delete(recursive: true);
  });
  return (downloader: downloader, directory: directory, catalog: catalog);
}

class _UpgradeRecordingTransfer extends HttpAudioTransfer {
  _UpgradeRecordingTransfer({this.failUpgrade = false}) : super(maxRetries: 0);
  final bool failUpgrade;
  final requests = <String>[];

  @override
  Future<HttpAudioTransferResult> download({
    required Uri uri,
    required File destination,
    Map<String, String> headers = const {},
    HttpAudioRangePlan? rangePlan,
    HttpAudioTransferProgressCallback? onProgress,
    HttpAudioTransferCancellationCallback? isCancelled,
    Stream<void>? cancellationEvents,
  }) async {
    requests.add(uri.toString());
    if (uri.host == 'jio.example' && failUpgrade) {
      await File('${destination.path}.part').writeAsBytes([9]);
      throw const HttpAudioTransferException(
        'CDN unavailable',
        kind: HttpAudioTransferFailureKind.httpStatus,
        statusCode: 403,
      );
    }
    final bytes = uri.host == 'jio.example' ? [3, 2, 0] : [1, 2, 8];
    await destination.writeAsBytes(bytes);
    return HttpAudioTransferResult(
      file: destination,
      length: bytes.length,
      attempts: 1,
      resumed: false,
    );
  }
}

final class _Catalog implements YouTubeMusicSearch, YouTubeMusicTrackLookup {
  static final song = InnerTubeSong(
    videoId: 'dQw4w9WgXcQ',
    title: 'Test Song',
    artists: const ['BStream'],
  );
  final List<String> queries = <String>[];
  int songLookups = 0;

  @override
  Future<InnerTubeSong?> getSong(String videoId) async {
    songLookups++;
    return videoId == song.videoId ? song : null;
  }

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async {
    queries.add(query);
    return <InnerTubeSong>[song];
  }
}

final class _RecordingAudioTransfer extends HttpAudioTransfer {
  _RecordingAudioTransfer() : super(maxRetries: 0);

  HttpAudioRangePlan? rangePlan;

  @override
  Future<HttpAudioTransferResult> download({
    required Uri uri,
    required File destination,
    Map<String, String> headers = const <String, String>{},
    HttpAudioRangePlan? rangePlan,
    HttpAudioTransferProgressCallback? onProgress,
    HttpAudioTransferCancellationCallback? isCancelled,
    Stream<void>? cancellationEvents,
  }) async {
    this.rangePlan = rangePlan;
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(const <int>[0x49, 0x44, 0x33, 1]);
    return HttpAudioTransferResult(
      file: destination,
      length: 4,
      attempts: 1,
      resumed: false,
    );
  }
}

final class _CancellableAudioTransfer extends HttpAudioTransfer {
  _CancellableAudioTransfer() : super(maxRetries: 0);

  final started = Completer<void>();

  @override
  Future<HttpAudioTransferResult> download({
    required Uri uri,
    required File destination,
    Map<String, String> headers = const <String, String>{},
    HttpAudioRangePlan? rangePlan,
    HttpAudioTransferProgressCallback? onProgress,
    HttpAudioTransferCancellationCallback? isCancelled,
    Stream<void>? cancellationEvents,
  }) async {
    await destination.parent.create(recursive: true);
    await HttpAudioTransfer.partialFileFor(
      destination,
    ).writeAsBytes(const <int>[1, 2, 3], flush: true);
    await File(
      '${destination.path}.part.if-range',
    ).writeAsString('etag\n"cancel-test"', flush: true);
    final cancellation = cancellationEvents!.first;
    if (!started.isCompleted) started.complete();
    await cancellation;
    expect(isCancelled?.call(), isTrue);
    throw const HttpAudioTransferException(
      'cancelled by test',
      kind: HttpAudioTransferFailureKind.cancelled,
    );
  }
}

final class _PlayerTransport implements InnerTubeTransport {
  _PlayerTransport(
    this.mediaUrl, {
    this.muxedOnly = false,
    this.playabilityStatus = 'OK',
    this.audioItag = 140,
    this.audioMimeType = 'audio/mp4; codecs="mp4a.40.2"',
    this.additionalAudioFormats = const <Map<String, Object?>>[],
  });

  final String mediaUrl;
  final bool muxedOnly;
  final String playabilityStatus;
  final int audioItag;
  final String audioMimeType;
  final List<Map<String, Object?>> additionalAudioFormats;
  int postCalls = 0;

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) async {
    postCalls += 1;
    return InnerTubeHttpResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'playabilityStatus': <String, Object?>{'status': playabilityStatus},
        'videoDetails': <String, Object?>{
          'videoId': 'dQw4w9WgXcQ',
          'title': 'Test Song',
        },
        'streamingData': <String, Object?>{
          'expiresInSeconds': '3600',
          muxedOnly ? 'formats' : 'adaptiveFormats': <Object?>[
            <String, Object?>{
              'itag': muxedOnly ? 18 : audioItag,
              'url': mediaUrl,
              'mimeType': muxedOnly
                  ? 'video/mp4; codecs="avc1.42001E, mp4a.40.2"'
                  : audioMimeType,
              'bitrate': 129000,
              'audioSampleRate': '44100',
              'audioChannels': 2,
              'contentLength': '4096',
            },
            ...additionalAudioFormats,
          ],
        },
      }),
    );
  }

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) => throw UnimplementedError();

  @override
  void close() {}
}

final class _RoutingPlayerTransport implements InnerTubeTransport {
  _RoutingPlayerTransport(this.mediaUrlsByClientId);

  final Map<int, String> mediaUrlsByClientId;
  final List<int> clientIds = <int>[];

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) async {
    final clientId = int.parse(headers['X-YouTube-Client-Name']!);
    clientIds.add(clientId);
    return InnerTubeHttpResponse(
      statusCode: 200,
      body: jsonEncode(<String, Object?>{
        'playabilityStatus': <String, Object?>{'status': 'OK'},
        'videoDetails': <String, Object?>{
          'videoId': 'dQw4w9WgXcQ',
          'title': 'Test Song',
        },
        'streamingData': <String, Object?>{
          'expiresInSeconds': '3600',
          'adaptiveFormats': <Object?>[
            <String, Object?>{
              'itag': 140,
              'url': mediaUrlsByClientId[clientId],
              'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
              'contentLength': '4096',
            },
          ],
        },
      }),
    );
  }

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) => throw UnimplementedError();

  @override
  void close() {}
}

final class _AlwaysValidStream implements InnerTubeStreamValidator {
  @override
  Future<InnerTubeStreamProbe> validate(
    Uri uri, {
    required Map<String, String> headers,
    int? contentLength,
  }) async => InnerTubeStreamProbe(
    statusCode: 206,
    elapsed: Duration.zero,
    probedOffset: 1024 * 1024,
    receivedBytes: 1,
    contentLength: contentLength,
  );
}
