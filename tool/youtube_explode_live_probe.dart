// ignore_for_file: avoid_print, depend_on_referenced_packages

import 'dart:convert';

import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_audio_stream_selector.dart';
import 'package:bstream_music/services/downloader/desktop_tool_locator.dart';
import 'package:logging/logging.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:youtube_explode_dart/solvers.dart';

const _defaultVideoIds = <String>[
  'dQw4w9WgXcQ',
  'kJQP7kiw5Fk',
  'JGwWNGJdvx8',
  'YQHsXMglC9A',
  '9bZkp7q19f0',
  'pvXTPiRjW5W',
];

typedef _ProbeAttempt = ({
  String name,
  YoutubeApiClient client,
  bool requireWatchPage,
});

Future<void> main(List<String> arguments) async {
  final useSolver = arguments.isNotEmpty && arguments.first == '--solver';
  final solverOnly = arguments.isNotEmpty && arguments.first == '--solver-only';
  final smokeSolver =
      arguments.isNotEmpty && arguments.first == '--solver-smoke';
  if (smokeSolver) {
    final solver = await DenoEJSSolver.init(
      denoExe: findBundledDenoExecutable(),
    );
    try {
      print(
        await solver.executeJavaScript(
          'JSON.stringify({"type":"smoke","ok":true})',
        ),
      );
    } finally {
      solver.dispose();
    }
    return;
  }
  final requestedIds = useSolver || solverOnly
      ? arguments.skip(1).toList()
      : arguments;
  final videoIds = requestedIds.isEmpty ? _defaultVideoIds : requestedIds;
  final attempts = <_ProbeAttempt>[
    (
      name: 'androidSdkless',
      client: YoutubeApiClient.androidSdkless,
      requireWatchPage: false,
    ),
    (
      name: 'visionOS+watch',
      client: youtubeVisionOsClient,
      requireWatchPage: true,
    ),
    (name: 'visionOS', client: youtubeVisionOsClient, requireWatchPage: false),
    (
      name: 'customIOS',
      client: youtubeCurrentIosClient,
      requireWatchPage: true,
    ),
    (
      name: 'packageIOS',
      client: youtubePackageIosClient,
      requireWatchPage: true,
    ),
    (
      name: 'androidMusic',
      client: YoutubeApiClient.androidMusic,
      requireWatchPage: true,
    ),
    (
      name: 'androidVr',
      client: youtubeCurrentAndroidVrClient,
      requireWatchPage: true,
    ),
    (name: 'tv', client: YoutubeApiClient.tv, requireWatchPage: true),
    (name: 'safari', client: YoutubeApiClient.safari, requireWatchPage: true),
  ];

  DenoEJSSolver? solver;
  YoutubeExplode? sharedClient;
  if (useSolver || solverOnly) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((record) {
      if (record.loggerName.contains('StreamClient') ||
          record.loggerName.contains('Deno')) {
        print(
          'log|${record.loggerName}|${record.level.name}|${record.message}',
        );
      }
    });
  }
  try {
    if (useSolver || solverOnly) {
      solver = await DenoEJSSolver.init(denoExe: findBundledDenoExecutable());
      sharedClient = YoutubeExplode(jsSolver: solver);
    }

    print(
      'video|client|status|elapsedMs|audioOnly|direct|container|codec|bitrate|error',
    );
    final selectedAttempts = solverOnly
        ? attempts.where((attempt) => attempt.requireWatchPage)
        : attempts;
    for (final videoId in videoIds) {
      for (final attempt in selectedAttempts) {
        await _probe(videoId, attempt, sharedClient: sharedClient);
      }
    }
  } finally {
    sharedClient?.close();
  }
}

Future<void> _probe(
  String videoId,
  _ProbeAttempt attempt, {
  YoutubeExplode? sharedClient,
}) async {
  final stopwatch = Stopwatch()..start();
  final client = sharedClient ?? YoutubeExplode();
  try {
    final manifest = await client.videos.streams
        .getManifest(
          VideoId.fromString(videoId),
          ytClients: [_cloneClient(attempt.client)],
          requireWatchPage: attempt.requireWatchPage,
        )
        .timeout(const Duration(seconds: 20));
    final selected = selectPreferredYoutubeAudioStream(
      manifest.audioOnly,
      requireDirectUrl: true,
    );
    if (selected == null) {
      _printResult(
        videoId,
        attempt.name,
        'fragmented-only',
        stopwatch,
        audioOnly: manifest.audioOnly.length,
      );
      return;
    }
    _printResult(
      videoId,
      attempt.name,
      'success',
      stopwatch,
      audioOnly: manifest.audioOnly.length,
      direct: true,
      container: selected.container.name,
      codec: selected.audioCodec,
      bitrate: selected.bitrate.bitsPerSecond,
    );
  } catch (error) {
    _printResult(videoId, attempt.name, 'failure', stopwatch, error: error);
  } finally {
    stopwatch.stop();
    if (sharedClient == null) {
      client.close();
    }
  }
}

void _printResult(
  String videoId,
  String client,
  String status,
  Stopwatch stopwatch, {
  int? audioOnly,
  bool? direct,
  String? container,
  String? codec,
  int? bitrate,
  Object? error,
}) {
  final details = error == null
      ? ''
      : _safe(error.toString().replaceAll(RegExp(r'[\r\n|]+'), ' '));
  print(
    '$videoId|$client|$status|${stopwatch.elapsedMilliseconds}|'
    '${audioOnly ?? ''}|${direct == true ? 'yes' : 'no'}|'
    '${container ?? ''}|${_safe(codec ?? '')}|${bitrate ?? ''}|$details',
  );
}

YoutubeApiClient _cloneClient(YoutubeApiClient original) {
  final payload = jsonDecode(jsonEncode(original.payload));
  final headers = jsonDecode(jsonEncode(original.headers));
  return YoutubeApiClient(
    Map<String, dynamic>.from(payload as Map),
    original.apiUrl,
    headers: Map<String, dynamic>.from(headers as Map),
  );
}

String _safe(String value) => value.replaceAll(RegExp(r'\s+'), ' ').trim();
