import 'dart:async';
import 'dart:io';

import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_audio_stream_selector.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_explode_download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  group('YoutubeExplodeDownloadService', () {
    test(
      'delegates initialization, metadata, playback info, and search',
      () async {
        const track = TrackInfo(
          id: 'video-id',
          title: 'Track',
          artist: 'Artist',
          url: 'https://www.youtube.com/watch?v=video-id',
        );
        final fallback = _FakeDownloaderService(
          info: track,
          playbackInfo: track,
          searchResults: const [track],
        );
        final client = _FakeYoutubeExplodeDownloadClient(
          resolveStream: (_) async => throw UnimplementedError(),
        );
        final service = YoutubeExplodeDownloadService(
          fallback: fallback,
          client: client,
        );
        addTearDown(() async {
          await service.dispose();
          await fallback.dispose();
        });

        await service.initialize();

        expect(fallback.initializeCalls, 1);
        expect(await service.getInfo(track.url), same(track));
        expect(await service.getPlaybackInfo(track.url), same(track));
        expect(await service.search('query'), const [track]);
        expect(client.resolveCalls, 0);
      },
    );

    test(
      'downloads the managed stream to a part file and renames it',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'bstream_youtube_explode_download_',
        );
        final fallback = _FakeDownloaderService();
        final client = _FakeYoutubeExplodeDownloadClient(
          resolveStream: (_) async => YoutubeExplodeDownloadStream(
            bytes: Stream<List<int>>.fromIterable(const [
              [1, 2],
              [3, 4, 5, 6],
            ]),
            extension: 'm4a',
            videoId: 'abcdefghijk',
            contentLength: 6,
            mimeType: 'audio/mp4',
            formatId: '140',
          ),
        );
        final service = YoutubeExplodeDownloadService(
          fallback: fallback,
          client: client,
        );
        final events = <DownloadProgress>[];
        final subscription = service.progressStream.listen(events.add);
        addTearDown(() async {
          await subscription.cancel();
          await service.dispose();
          await fallback.dispose();
          if (await temp.exists()) {
            await temp.delete(recursive: true);
          }
        });

        final stalePartial = File(p.join(temp.path, 'Artist - Track.m4a.part'));
        final staleCompleted = File(p.join(temp.path, 'Artist - Track.m4a'));
        await stalePartial.writeAsBytes(const [99]);
        await staleCompleted.writeAsBytes(const [88]);

        final result = await service.downloadAudio(
          'https://www.youtube.com/watch?v=abcdefghijk',
          DownloadOptions(
            outputDirectory: temp.path,
            fileName: 'Artist - Track',
            taskId: 'task-primary',
          ),
        );

        expect(result.filePath, staleCompleted.path);
        expect(await File(result.filePath).readAsBytes(), const [
          1,
          2,
          3,
          4,
          5,
          6,
        ]);
        expect(await stalePartial.exists(), isFalse);
        expect(result.bytes, 6);
        expect(fallback.downloadCalls, 0);
        expect(client.resolveCalls, 1);
        expect(
          events.map((event) => event.status),
          containsAllInOrder(const [
            DownloadProgressStatus.queued,
            DownloadProgressStatus.running,
            DownloadProgressStatus.completed,
          ]),
        );
        expect(
          events.where(
            (event) => event.status == DownloadProgressStatus.failed,
          ),
          isEmpty,
        );
        expect(events.every((event) => event.taskId == 'task-primary'), isTrue);
        expect(events.last.message, contains('youtube_explode_dart'));
      },
    );

    test(
      'emits the primary failure, removes the partial, and falls back with the same task id',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'bstream_youtube_explode_fallback_',
        );
        final fallback = _FakeDownloaderService(
          onDownload: (service, url, options) async {
            final taskId = options.taskId!;
            service.emit(
              DownloadProgress(
                taskId: taskId,
                url: url,
                status: DownloadProgressStatus.queued,
                progress: 0,
                message: 'Preparando yt-dlp',
              ),
            );
            service.emit(
              DownloadProgress(
                taskId: taskId,
                url: url,
                status: DownloadProgressStatus.running,
                progress: 0,
                message: 'Descargando con yt-dlp',
              ),
            );
            final file = File(p.join(options.outputDirectory, 'fallback.webm'));
            await file.writeAsBytes(const [7, 8, 9], flush: true);
            service.emit(
              DownloadProgress(
                taskId: taskId,
                url: url,
                status: DownloadProgressStatus.completed,
                progress: 1,
                message: 'Descarga completada con yt-dlp',
              ),
            );
            return _completedResult(url, file);
          },
        );
        final client = _FakeYoutubeExplodeDownloadClient(
          resolveStream: (_) async => YoutubeExplodeDownloadStream(
            bytes: _streamThatFailsAfter(const [1, 2, 3]),
            extension: 'webm',
            videoId: 'abcdefghijk',
            contentLength: 6,
          ),
        );
        final service = YoutubeExplodeDownloadService(
          fallback: fallback,
          client: client,
        );
        final events = <DownloadProgress>[];
        final subscription = service.progressStream.listen(events.add);
        addTearDown(() async {
          await subscription.cancel();
          await service.dispose();
          await fallback.dispose();
          if (await temp.exists()) {
            await temp.delete(recursive: true);
          }
        });

        final result = await service.downloadAudio(
          'https://www.youtube.com/watch?v=abcdefghijk',
          DownloadOptions(
            outputDirectory: temp.path,
            fileName: 'Artist - Track',
          ),
        );

        expect(result.fileName, 'fallback.webm');
        expect(fallback.downloadCalls, 1);
        final taskId = fallback.lastOptions!.taskId;
        expect(taskId, isNotNull);
        expect(taskId, isNotEmpty);
        final primaryFailureIndex = events.indexWhere(
          (event) =>
              event.status == DownloadProgressStatus.failed &&
              event.message?.contains('falló') == true &&
              event.message?.contains('yt-dlp') == true,
        );
        final fallbackQueuedIndex = events.indexWhere(
          (event) =>
              event.status == DownloadProgressStatus.queued &&
              event.message == 'Preparando yt-dlp',
        );
        expect(primaryFailureIndex, greaterThanOrEqualTo(0));
        expect(fallbackQueuedIndex, greaterThan(primaryFailureIndex));
        expect(events.every((event) => event.taskId == taskId), isTrue);
        expect(
          await File(p.join(temp.path, 'Artist - Track.webm.part')).exists(),
          isFalse,
        );
      },
    );

    test('falls back when stream resolution exceeds its deadline', () async {
      final temp = await Directory.systemTemp.createTemp(
        'bstream_youtube_explode_resolve_timeout_',
      );
      final fallback = _FakeDownloaderService(
        onDownload: (_, url, options) async {
          final file = File(p.join(options.outputDirectory, 'fallback.m4a'));
          await file.writeAsBytes(const [7, 8, 9], flush: true);
          return _completedResult(url, file);
        },
      );
      final neverResolves = Completer<YoutubeExplodeDownloadStream>();
      final client = _FakeYoutubeExplodeDownloadClient(
        resolveStream: (_) => neverResolves.future,
      );
      final service = YoutubeExplodeDownloadService(
        fallback: fallback,
        client: client,
        resolveTimeout: const Duration(milliseconds: 20),
      );
      final events = <DownloadProgress>[];
      final subscription = service.progressStream.listen(events.add);
      addTearDown(() async {
        await subscription.cancel();
        await service.dispose();
        await fallback.dispose();
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      final result = await service.downloadAudio(
        'https://www.youtube.com/watch?v=abcdefghijk',
        DownloadOptions(outputDirectory: temp.path, fileName: 'Track'),
      );

      expect(result.fileName, 'fallback.m4a');
      expect(fallback.downloadCalls, 1);
      expect(
        events.any(
          (event) =>
              event.status == DownloadProgressStatus.failed &&
              event.message?.contains('no resolvio') == true,
        ),
        isTrue,
      );
    });

    test(
      'cancels a stalled stream and falls back after its idle timeout',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'bstream_youtube_explode_idle_timeout_',
        );
        var streamCancelled = false;
        final stalledStream = StreamController<List<int>>(
          onCancel: () {
            streamCancelled = true;
          },
        );
        final fallback = _FakeDownloaderService(
          onDownload: (_, url, options) async {
            final file = File(p.join(options.outputDirectory, 'fallback.webm'));
            await file.writeAsBytes(const [4, 5, 6], flush: true);
            return _completedResult(url, file);
          },
        );
        final client = _FakeYoutubeExplodeDownloadClient(
          resolveStream: (_) async => YoutubeExplodeDownloadStream(
            bytes: stalledStream.stream,
            extension: 'm4a',
            videoId: 'abcdefghijk',
          ),
        );
        final service = YoutubeExplodeDownloadService(
          fallback: fallback,
          client: client,
          downloadIdleTimeout: const Duration(milliseconds: 20),
          downloadTotalTimeout: const Duration(seconds: 1),
        );
        final events = <DownloadProgress>[];
        final subscription = service.progressStream.listen(events.add);
        addTearDown(() async {
          await subscription.cancel();
          await stalledStream.close();
          await service.dispose();
          await fallback.dispose();
          if (await temp.exists()) {
            await temp.delete(recursive: true);
          }
        });

        final result = await service.downloadAudio(
          'https://www.youtube.com/watch?v=abcdefghijk',
          DownloadOptions(outputDirectory: temp.path, fileName: 'Track'),
        );

        expect(result.fileName, 'fallback.webm');
        expect(streamCancelled, isTrue);
        expect(fallback.downloadCalls, 1);
        expect(
          events.any(
            (event) =>
                event.status == DownloadProgressStatus.failed &&
                event.message?.contains('dejó de recibir datos') == true,
          ),
          isTrue,
        );
        expect(
          await File(p.join(temp.path, 'Track.m4a.part')).exists(),
          isFalse,
        );
      },
    );

    test(
      'enforces a total deadline even while stream data keeps arriving',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'bstream_youtube_explode_total_timeout_',
        );
        Timer? ticker;
        var streamCancelled = false;
        late final StreamController<List<int>> endlessStream;
        endlessStream = StreamController<List<int>>(
          onListen: () {
            ticker = Timer.periodic(
              const Duration(milliseconds: 5),
              (_) => endlessStream.add(const [1]),
            );
          },
          onCancel: () {
            ticker?.cancel();
            streamCancelled = true;
          },
        );
        final fallback = _FakeDownloaderService(
          onDownload: (_, url, options) async {
            final file = File(p.join(options.outputDirectory, 'fallback.opus'));
            await file.writeAsBytes(const [2, 3, 4], flush: true);
            return _completedResult(url, file);
          },
        );
        final client = _FakeYoutubeExplodeDownloadClient(
          resolveStream: (_) async => YoutubeExplodeDownloadStream(
            bytes: endlessStream.stream,
            extension: 'webm',
            videoId: 'abcdefghijk',
          ),
        );
        final service = YoutubeExplodeDownloadService(
          fallback: fallback,
          client: client,
          downloadIdleTimeout: const Duration(seconds: 1),
          downloadTotalTimeout: const Duration(milliseconds: 60),
        );
        final events = <DownloadProgress>[];
        final subscription = service.progressStream.listen(events.add);
        addTearDown(() async {
          ticker?.cancel();
          await subscription.cancel();
          await endlessStream.close();
          await service.dispose();
          await fallback.dispose();
          if (await temp.exists()) {
            await temp.delete(recursive: true);
          }
        });

        final result = await service.downloadAudio(
          'https://www.youtube.com/watch?v=abcdefghijk',
          DownloadOptions(outputDirectory: temp.path, fileName: 'Track'),
        );

        expect(result.fileName, 'fallback.opus');
        expect(streamCancelled, isTrue);
        expect(fallback.downloadCalls, 1);
        expect(
          events.any(
            (event) =>
                event.status == DownloadProgressStatus.failed &&
                event.message?.contains('límite total') == true,
          ),
          isTrue,
        );
      },
    );

    test('does not invoke yt-dlp for a local filesystem failure', () async {
      final temp = await Directory.systemTemp.createTemp(
        'bstream_youtube_explode_filesystem_',
      );
      final blockedDirectory = File(p.join(temp.path, 'not-a-directory'));
      await blockedDirectory.writeAsString('occupied');
      final fallback = _FakeDownloaderService();
      final client = _FakeYoutubeExplodeDownloadClient(
        resolveStream: (_) async => YoutubeExplodeDownloadStream(
          bytes: Stream<List<int>>.value(const [1, 2, 3]),
          extension: 'm4a',
          videoId: 'abcdefghijk',
          contentLength: 3,
        ),
      );
      final service = YoutubeExplodeDownloadService(
        fallback: fallback,
        client: client,
      );
      addTearDown(() async {
        await service.dispose();
        await fallback.dispose();
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      await expectLater(
        service.downloadAudio(
          'https://www.youtube.com/watch?v=abcdefghijk',
          DownloadOptions(
            outputDirectory: blockedDirectory.path,
            fileName: 'Artist - Track',
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(fallback.downloadCalls, 0);
    });

    test('reports both backend failures and keeps no part file', () async {
      final temp = await Directory.systemTemp.createTemp(
        'bstream_youtube_explode_double_failure_',
      );
      final fallback = _FakeDownloaderService(
        onDownload: (_, _, _) async => throw const DownloaderException(
          'yt-dlp broke',
          code: 'yt_dlp_test_failure',
        ),
      );
      final client = _FakeYoutubeExplodeDownloadClient(
        resolveStream: (_) async => YoutubeExplodeDownloadStream(
          bytes: _streamThatFailsAfter(const [1]),
          extension: 'm4a',
          videoId: 'abcdefghijk',
          contentLength: 4,
        ),
      );
      final service = YoutubeExplodeDownloadService(
        fallback: fallback,
        client: client,
      );
      final events = <DownloadProgress>[];
      final subscription = service.progressStream.listen(events.add);
      addTearDown(() async {
        await subscription.cancel();
        await service.dispose();
        await fallback.dispose();
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });

      await expectLater(
        service.downloadAudio(
          'https://www.youtube.com/watch?v=abcdefghijk',
          DownloadOptions(
            outputDirectory: temp.path,
            fileName: 'Artist - Track',
            taskId: 'double-failure-task',
          ),
        ),
        throwsA(
          isA<DownloaderException>()
              .having(
                (error) => error.code,
                'code',
                'audio_download_all_backends_failed',
              )
              .having(
                (error) => error.message,
                'message',
                allOf(
                  contains('youtube_explode_dart'),
                  contains('yt-dlp broke'),
                ),
              ),
        ),
      );

      expect(fallback.lastOptions?.taskId, 'double-failure-task');
      expect(
        events
            .where((event) => event.status == DownloadProgressStatus.failed)
            .length,
        2,
      );
      expect(
        await File(p.join(temp.path, 'Artist - Track.m4a.part')).exists(),
        isFalse,
      );
    });
  });

  group('YouTube audio container mapping', () {
    test('keeps native containers without pretending they are MP3', () {
      expect(youtubeAudioContainerExtension(StreamContainer.mp4), 'm4a');
      expect(youtubeAudioContainerExtension(StreamContainer.webM), 'webm');
      expect(youtubeAudioContainerExtension(StreamContainer.tgpp), '3gp');
      expect(youtubeAudioContainerExtension(StreamContainer.m3u8), 'm3u8');
      expect(youtubeAudioContainerMimeType(StreamContainer.mp4), 'audio/mp4');
      expect(youtubeAudioContainerMimeType(StreamContainer.webM), 'audio/webm');
    });

    test('recognizes AAC codec labels', () {
      expect(isYoutubeAacCodec('mp4a.40.2'), isTrue);
      expect(isYoutubeAacCodec('AAC-LC'), isTrue);
      expect(isYoutubeAacCodec('opus'), isFalse);
    });

    test('prefers the default audio track and compatible AAC container', () {
      final alternate = _audioStream(
        tag: 251,
        container: 'webm',
        codec: 'opus',
        bitrate: 160000,
        audioIsDefault: false,
      );
      final defaultAac = _audioStream(
        tag: 140,
        container: 'mp4',
        codec: 'mp4a.40.2',
        bitrate: 128000,
        audioIsDefault: true,
      );

      expect(
        selectPreferredYoutubeAudioStream([alternate, defaultAac])?.tag,
        140,
      );
    });

    test('uses the highest bitrate inside the preferred MP4 AAC tier', () {
      final lowerAac = _audioStream(
        tag: 140,
        container: 'mp4',
        codec: 'mp4a.40.2',
        bitrate: 128000,
      );
      final higherAac = _audioStream(
        tag: 141,
        container: 'mp4',
        codec: 'mp4a.40.2',
        bitrate: 256000,
      );

      expect(
        selectPreferredYoutubeAudioStream([lowerAac, higherAac])?.tag,
        141,
      );
    });

    test('falls back to the highest bitrate of any audio-only format', () {
      final legacy3gpp = _audioStream(
        tag: 139,
        container: '3gpp',
        codec: 'mp4a.40.5',
        bitrate: 48000,
      );
      final opus = _audioStream(
        tag: 251,
        container: 'webm',
        codec: 'opus',
        bitrate: 160000,
      );

      expect(selectPreferredYoutubeAudioStream([legacy3gpp, opus])?.tag, 251);
    });

    test('keeps alternate tracks eligible when no default is advertised', () {
      final lowerAlternate = _audioStream(
        tag: 250,
        container: 'webm',
        codec: 'opus',
        bitrate: 96000,
        audioIsDefault: false,
      );
      final higherAlternate = _audioStream(
        tag: 251,
        container: 'webm',
        codec: 'opus',
        bitrate: 160000,
        audioIsDefault: false,
      );

      expect(
        selectPreferredYoutubeAudioStream([
          lowerAlternate,
          higherAlternate,
        ])?.tag,
        251,
      );
    });

    test('keeps fragmented streams for downloads but not raw playback', () {
      final fragmentedAac = _audioStream(
        tag: 140,
        container: 'mp4',
        codec: 'mp4a.40.2',
        bitrate: 128000,
        fragmented: true,
      );
      final directOpus = _audioStream(
        tag: 251,
        container: 'webm',
        codec: 'opus',
        bitrate: 160000,
      );

      expect(
        selectPreferredYoutubeAudioStream([fragmentedAac, directOpus])?.tag,
        140,
      );
      expect(
        selectPreferredYoutubeAudioStream([
          fragmentedAac,
          directOpus,
        ], requireDirectUrl: true)?.tag,
        251,
      );
    });

    test('returns no direct stream when every candidate is fragmented', () {
      final fragmentedAac = _audioStream(
        tag: 140,
        container: 'mp4',
        codec: 'mp4a.40.2',
        bitrate: 128000,
        fragmented: true,
      );

      expect(
        selectPreferredYoutubeAudioStream([
          fragmentedAac,
        ], requireDirectUrl: true),
        isNull,
      );
      expect(selectPreferredYoutubeAudioStream(const []), isNull);
    });
  });
}

Stream<List<int>> _streamThatFailsAfter(List<int> bytes) async* {
  yield bytes;
  throw StateError('primary stream interrupted');
}

AudioOnlyStreamInfo _audioStream({
  required int tag,
  required String container,
  required String codec,
  required int bitrate,
  bool fragmented = false,
  bool? audioIsDefault,
}) {
  return AudioOnlyStreamInfo.fromJson({
    'videoId': const {'value': 'abcdefghijk'},
    'tag': tag,
    'url': 'https://media.example/$tag',
    'container': {'name': container},
    'size': const {'totalBytes': 1024},
    'bitrate': {'bitsPerSecond': bitrate},
    'audioCodec': codec,
    'qualityLabel': 'audio',
    'fragments': fragmented
        ? const [
            {'path': '/segment-1'},
          ]
        : const [],
    'codec': 'audio/$container; codecs="$codec"',
    'audioTrack': audioIsDefault == null
        ? null
        : {
            'displayName': audioIsDefault ? 'Original' : 'Alternate',
            'id': audioIsDefault ? 'original' : 'alternate',
            'audioIsDefault': audioIsDefault,
          },
  });
}

DownloadResult _completedResult(String sourceUrl, File file) {
  return DownloadResult(
    id: 'fallback-result',
    sourceUrl: sourceUrl,
    filePath: file.path,
    fileName: p.basename(file.path),
    mediaType: DownloadMediaType.audio,
    completedAt: DateTime.now(),
    bytes: file.lengthSync(),
  );
}

typedef _DownloadHandler =
    Future<DownloadResult> Function(
      _FakeDownloaderService service,
      String url,
      DownloadOptions options,
    );

class _FakeDownloaderService implements DownloaderService {
  _FakeDownloaderService({
    this.info,
    this.playbackInfo,
    this.searchResults = const [],
    this.onDownload,
  });

  final TrackInfo? info;
  final TrackInfo? playbackInfo;
  final List<TrackInfo> searchResults;
  final _DownloadHandler? onDownload;
  final StreamController<DownloadProgress> _progressController =
      StreamController<DownloadProgress>.broadcast(sync: true);

  int initializeCalls = 0;
  int downloadCalls = 0;
  DownloadOptions? lastOptions;

  @override
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  void emit(DownloadProgress progress) => _progressController.add(progress);

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<TrackInfo> getInfo(String url) async => info!;

  @override
  Future<TrackInfo> getPlaybackInfo(String url) async => playbackInfo!;

  @override
  Future<List<TrackInfo>> search(String query) async => searchResults;

  @override
  Future<DownloadResult> downloadAudio(
    String url,
    DownloadOptions options,
  ) async {
    downloadCalls++;
    lastOptions = options;
    final handler = onDownload;
    if (handler == null) {
      throw StateError('Fallback download was not expected.');
    }
    return handler(this, url, options);
  }

  Future<void> dispose() => _progressController.close();
}

class _FakeYoutubeExplodeDownloadClient
    implements YoutubeExplodeDownloadClient {
  _FakeYoutubeExplodeDownloadClient({required this.resolveStream});

  final Future<YoutubeExplodeDownloadStream> Function(String url) resolveStream;
  int resolveCalls = 0;
  bool disposed = false;

  @override
  Future<YoutubeExplodeDownloadStream> resolve(String url) {
    resolveCalls++;
    return resolveStream(url);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
