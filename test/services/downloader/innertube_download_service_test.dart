import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/services/downloader/http_audio_transfer.dart';
import 'package:bstream_music/services/downloader/innertube_download_service.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_profile.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_router.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_playback_service.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_models.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(results.single.id, 'dQw4w9WgXcQ');
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

final class _Catalog implements YouTubeMusicSearch, YouTubeMusicTrackLookup {
  static final song = InnerTubeSong(
    videoId: 'dQw4w9WgXcQ',
    title: 'Test Song',
    artists: const ['BStream'],
  );
  final List<String> queries = <String>[];

  @override
  Future<InnerTubeSong?> getSong(String videoId) async =>
      videoId == song.videoId ? song : null;

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async {
    queries.add(query);
    return <InnerTubeSong>[song];
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
