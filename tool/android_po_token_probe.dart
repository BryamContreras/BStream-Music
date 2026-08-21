// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/platform_channels/android_ytdl_channel.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_audio_stream_selector.dart';
import 'package:bstream_music/services/downloader/adapters/youtube_explode/youtube_explode_runtime.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

typedef _ClientEntry = ({String name, YoutubeApiClient client, bool requireWatchPage});

const _defaultVideoIds = <String>[
  'dQw4w9WgXcQ',
  'kJQP7kiw5Fk',
];

typedef _AttemptResult = ({
  String clientName,
  bool usedWatchPage,
  bool usedSolver,
  int elapsedMs,
  int audioStreams,
  int totalStreams,
  String? container,
  String? codec,
  int? bitrate,
  String? error,
  bool isRateLimited,
  bool fallbackTriggered,
  String? fallbackReason,
});

class _ChainResult {
  final String videoId;
  final List<_AttemptResult> attempts;
  final _AttemptResult? selected;
  final String outcome;
  final int totalMs;

  _ChainResult({
    required this.videoId,
    required this.attempts,
    required this.selected,
    required this.outcome,
    required this.totalMs,
  });
}

Future<void> main(List<String> args) async {
  final videoIds = args.isEmpty ? _defaultVideoIds : args.toList();

  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  await Future<void>.delayed(const Duration(milliseconds: 500));

  final channel = AndroidYtdlChannel();

  print('# ANDROID_PO_TOKEN_CHAIN_BENCHMARK | ${DateTime.now().toIso8601String()}');
  print('# Video IDs: ${videoIds.join(", ")}');
  print('#');
  print('# Columns:');
  print('#  videoId');
  print('#  clientName');
  print('#  watchPage[yes/no]');
  print('#  solver[yes/no]');
  print('#  clientElapsedMs');
  print('#  audioStreams');
  print('#  totalStreams');
  print('#  container');
  print('#  codec');
  print('#  bitrate');
  print('#  error');
  print('#  rateLimited[yes/no]');
  print('#  fallback[yes/no]');
  print('#  fallbackReason');
  print('#  selected[yes/no/final]');
  print('#  chainTotalMs');
  print('');
  print('videoId|clientName|watchPage|solver|elapsedMs|audioStreams|totalStreams|container|codec|bitrate|error|rateLimited|fallback|fallbackReason|selected|chainMs');

  final allResults = <_ChainResult>[];

  for (final videoId in videoIds) {
    final result = await _probeChain(videoId, channel);
    allResults.add(result);
    _printChainResult(result);
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  await channel.disposePoTokens();

  print('');
  print('# SUMMARY');
  print('# outcome|videoId|totalMs|clientsAttempted|streamsSelected|selectedClient');
  for (final r in allResults) {
    final selectedName = r.selected?.clientName ?? 'none';
    print('# ${r.outcome}|${r.videoId}|${r.totalMs}|${r.attempts.length}|${r.selected != null ? 1 : 0}|$selectedName');
  }
}

Future<_ChainResult> _probeChain(String videoId, AndroidYtdlChannel channel) async {
  final totalStopwatch = Stopwatch()..start();
  final attempts = <_AttemptResult>[];
  _AttemptResult? selected;
  var rateLimited = false;

  final runtime = YoutubeExplodeRuntime(
    platform: AppPlatform.current,
    androidChannel: channel,
  );

  try {
    final coldTokenStopwatch = Stopwatch()..start();
    final coldToken = await channel.getPoTokens(videoId);
    coldTokenStopwatch.stop();
    print('# [PO] cold=${coldTokenStopwatch.elapsedMilliseconds}ms available=${coldToken != null}');

    if (coldToken != null) {
      final warmStopwatch = Stopwatch()..start();
      await channel.getPoTokens(videoId);
      warmStopwatch.stop();
      print('# [PO] warm=${warmStopwatch.elapsedMilliseconds}ms');
    }

    final orderedClients = <_ClientEntry>[
      (name: 'androidSdkless', client: YoutubeApiClient.androidSdkless, requireWatchPage: false),
      (name: 'visionOS', client: youtubeVisionOsClient, requireWatchPage: false),
      (name: 'visionOS+watch', client: youtubeVisionOsClient, requireWatchPage: true),
      (name: 'safari+po', client: YoutubeApiClient.safari, requireWatchPage: true),
    ];

    for (var i = 0; i < orderedClients.length; i++) {
      final entry = orderedClients[i];
      final clientName = entry.name;
      final apiClient = entry.client;
      final requireWatchPage = entry.requireWatchPage;

      final isLastClient = i == orderedClients.length - 1;
      final fastClient = await runtime.fastClient;
      final solverClient = await runtime.solverClient;

      final clientToUse = requireWatchPage ? solverClient : fastClient;

      print('# [ATTEMPT] $videoId | $clientName | watchPage=$requireWatchPage | solver=$requireWatchPage | chainPos=$i');

      final attemptStopwatch = Stopwatch()..start();
      try {
        final manifest = await clientToUse.videos.streams
            .getManifest(
              VideoId.fromString(videoId),
              ytClients: [apiClient],
              requireWatchPage: requireWatchPage,
            )
            .timeout(const Duration(seconds: 25));
        attemptStopwatch.stop();

        final audioOnly = manifest.audioOnly;
        final selectedStream = selectPreferredYoutubeAudioStream(
          audioOnly,
          requireDirectUrl: true,
        );

        if (selectedStream != null) {
          selected = (
            clientName: clientName,
            usedWatchPage: requireWatchPage,
            usedSolver: requireWatchPage,
            elapsedMs: attemptStopwatch.elapsedMilliseconds,
            audioStreams: audioOnly.length,
            totalStreams: manifest.streams.length,
            container: selectedStream.container.name,
            codec: selectedStream.audioCodec,
            bitrate: selectedStream.bitrate.bitsPerSecond,
            error: null,
            isRateLimited: false,
            fallbackTriggered: false,
            fallbackReason: null,
          );
          print('# [SELECTED] $clientName succeeded in ${attemptStopwatch.elapsedMilliseconds}ms with ${audioOnly.length} audio streams');
          break;
        } else {
          final noAudioReason = audioOnly.isEmpty ? 'no-audio-streams' : 'no-direct-url';
          print('# [SKIP] $clientName returned ${manifest.streams.length} streams but $noAudioReason in ${attemptStopwatch.elapsedMilliseconds}ms');
          attempts.add((
            clientName: clientName,
            usedWatchPage: requireWatchPage,
            usedSolver: requireWatchPage,
            elapsedMs: attemptStopwatch.elapsedMilliseconds,
            audioStreams: audioOnly.length,
            totalStreams: manifest.streams.length,
            container: null,
            codec: null,
            bitrate: null,
            error: noAudioReason,
            isRateLimited: false,
            fallbackTriggered: false,
            fallbackReason: noAudioReason,
          ));
        }
      } on RequestLimitExceededException {
        attemptStopwatch.stop();
        print('# [RATELIMIT] $clientName got RequestLimitExceeded after ${attemptStopwatch.elapsedMilliseconds}ms');
        attempts.add((
          clientName: clientName,
          usedWatchPage: requireWatchPage,
          usedSolver: requireWatchPage,
          elapsedMs: attemptStopwatch.elapsedMilliseconds,
          audioStreams: 0,
          totalStreams: 0,
          container: null,
          codec: null,
          bitrate: null,
          error: 'RequestLimitExceeded',
          isRateLimited: true,
          fallbackTriggered: !isLastClient,
          fallbackReason: 'RequestLimitExceeded',
        ));
        rateLimited = true;
        if (requireWatchPage) {
          print('# [BACKOFF] rate limit on requireWatchPage client, skipping remaining watch-page clients');
          var skipIdx = i + 1;
          while (skipIdx < orderedClients.length && orderedClients[skipIdx].requireWatchPage) {
            print('# [SKIP] skipping ${orderedClients[skipIdx].name} (requireWatchPage backoff)');
            attempts.add((
              clientName: orderedClients[skipIdx].name,
              usedWatchPage: orderedClients[skipIdx].requireWatchPage,
              usedSolver: orderedClients[skipIdx].requireWatchPage,
              elapsedMs: 0,
              audioStreams: 0,
              totalStreams: 0,
              container: null,
              codec: null,
              bitrate: null,
              error: 'skipped-backoff',
              isRateLimited: false,
              fallbackTriggered: false,
              fallbackReason: 'backoff-skip',
            ));
            skipIdx++;
          }
        }
        if (!isLastClient) continue;
      } catch (error, stackTrace) {
        attemptStopwatch.stop();
        final errorMsg = error.toString().replaceAll(RegExp(r'[\r\n|]+'), ' ');
        print('# [ERROR] $clientName threw $errorMsg after ${attemptStopwatch.elapsedMilliseconds}ms');
        print('#   $stackTrace');
        attempts.add((
          clientName: clientName,
          usedWatchPage: requireWatchPage,
          usedSolver: requireWatchPage,
          elapsedMs: attemptStopwatch.elapsedMilliseconds,
          audioStreams: 0,
          totalStreams: 0,
          container: null,
          codec: null,
          bitrate: null,
          error: errorMsg,
          isRateLimited: false,
          fallbackTriggered: !isLastClient,
          fallbackReason: errorMsg.length > 60 ? errorMsg.substring(0, 60) : errorMsg,
        ));
        if (!isLastClient) continue;
      }
    }

    totalStopwatch.stop();

    final outcome = selected != null
        ? 'success'
        : rateLimited
            ? 'rate-limited'
            : 'no-streams';

    return _ChainResult(
      videoId: videoId,
      attempts: attempts,
      selected: selected,
      outcome: outcome,
      totalMs: totalStopwatch.elapsedMilliseconds,
    );
  } finally {
    await runtime.dispose();
  }
}

void _printChainResult(_ChainResult result) {
  final chainMs = result.totalMs;
  for (var i = 0; i < result.attempts.length; i++) {
    final a = result.attempts[i];
    final isLast = i == result.attempts.length - 1 && result.selected == null;
    final selectedFlag = result.selected?.clientName == a.clientName
        ? 'selected'
        : isLast
            ? 'final'
            : 'no';
    print(
      '${result.videoId}|${a.clientName}|${a.usedWatchPage ? "yes" : "no"}|'
      '${a.usedSolver ? "yes" : "no"}|${a.elapsedMs}|${a.audioStreams}|'
      '${a.totalStreams}|${a.container ?? ""}|${a.codec ?? ""}|'
      '${a.bitrate ?? ""}|${a.error ?? ""}|${a.isRateLimited ? "yes" : "no"}|'
      '${a.fallbackTriggered ? "yes" : "no"}|${a.fallbackReason ?? ""}|$selectedFlag|'
      '${isLast ? chainMs : ""}',
    );
  }
  if (result.selected != null && result.attempts.isNotEmpty) {
    final a = result.selected!;
    print(
      '${result.videoId}|${a.clientName}|${a.usedWatchPage ? "yes" : "no"}|'
      '${a.usedSolver ? "yes" : "no"}|${a.elapsedMs}|${a.audioStreams}|'
      '${a.totalStreams}|${a.container ?? ""}|${a.codec ?? ""}|'
      '${a.bitrate ?? ""}|${a.error ?? ""}|${a.isRateLimited ? "yes" : "no"}|'
      'no||selected|$chainMs',
    );
  }
}
