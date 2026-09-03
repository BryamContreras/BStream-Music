import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_profile.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_player_response_parser.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_models.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_stream_validator.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_video_id.dart';

/// Live, raw/tokenless capability diagnostic for maintained InnerTube profiles.
///
/// This executable deliberately does not initialize EJS, WebPO, or native
/// platform-attestation providers. Profiles gated by those capabilities are
/// reported as `SKIP`, never as failed probes. Use the production profile
/// matrix integration test to measure the complete playback stack.
///
/// A successful probe includes a ranged media read beyond byte 3 MiB. This
/// exceeds the cold-start allowance and rejects first-byte false positives
/// caused by GVS PO enforcement.
Future<void> main(List<String> arguments) async {
  final roundsArgument = arguments
      .where((value) => value.startsWith('--rounds='))
      .firstOrNull;
  final rounds = int.tryParse(roundsArgument?.split('=').last ?? '') ?? 2;
  final references = arguments
      .where((value) => !value.startsWith('--'))
      .toList(growable: false);
  final videoIds =
      (references.isEmpty
              ? const <String>[
                  'dQw4w9WgXcQ',
                  'kJQP7kiw5Fk',
                  '9bZkp7q19f0',
                  'JGwWNGJdvx8',
                  'CevxZvSJLk8',
                ]
              : references)
          .map(InnerTubeVideoId.extract)
          .whereType<InnerTubeVideoId>()
          .toList(growable: false);
  if (rounds < 1 || rounds > 10 || videoIds.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/innertube_playback_benchmark.dart '
      '[--rounds=2] [video-id-or-url ...]',
    );
    exitCode = 64;
    return;
  }

  stdout.writeln(
    'Raw/tokenless InnerTube diagnostic: EJS and PO-gated profiles are '
    'reported as SKIP.',
  );
  final transport = IoInnerTubeTransport(
    connectionTimeout: const Duration(seconds: 8),
  );
  final validator = IoInnerTubeStreamValidator(
    timeout: const Duration(seconds: 10),
  );
  final parser = const InnerTubePlayerResponseParser();
  final samples = <String, List<RawBenchmarkSample>>{
    for (final profile in InnerTubeClientRegistry.benchmarkCandidates)
      profile.key: <RawBenchmarkSample>[],
  };
  try {
    final visitorData = await bootstrapRawBenchmarkVisitorData(transport);
    stdout.writeln('Visitor-data bootstrap: OK.');

    for (var round = 0; round < rounds; round += 1) {
      for (final videoId in videoIds) {
        final profiles = InnerTubeClientRegistry.benchmarkCandidates;
        for (var offset = 0; offset < profiles.length; offset += 1) {
          final profile = profiles[(offset + round) % profiles.length];
          stdout.write(
            'round=${round + 1} video=${videoId.value} '
            'client=${profile.key} ... ',
          );
          final sample = await measureRawInnerTubeProfile(
            transport,
            validator,
            parser,
            videoId,
            profile,
            visitorData: visitorData,
          );
          samples[profile.key]!.add(sample);
          stdout.writeln(sample.summary);
        }
      }
    }
  } catch (error) {
    stderr.writeln('Raw benchmark aborted: ${oneLineBenchmarkError(error)}');
    exitCode = 1;
    return;
  } finally {
    transport.close();
  }

  final results = InnerTubeClientRegistry.benchmarkCandidates
      .map((profile) => RawProfileResult(profile, samples[profile.key]!))
      .toList(growable: false);
  final ranking = results.where((result) => result.evaluated > 0).toList()
    ..sort(compareRawProfileResults);

  stdout.writeln(
    '\nRaw/tokenless deep-range ranking '
    '(capability-gated samples excluded):',
  );
  if (ranking.isEmpty) {
    stdout.writeln('No profile could be evaluated without EJS or PO tokens.');
  }
  for (var index = 0; index < ranking.length; index += 1) {
    final result = ranking[index];
    stdout.writeln(
      '${index + 1}. ${result.profile.key}: '
      '${result.successes}/${result.evaluated} valid, '
      '${result.failures} failed, '
      '${result.blocked} skipped, '
      'median=${result.medianMilliseconds?.toString() ?? '-'} ms',
    );
  }

  final gated = results.where((result) => result.blocked > 0);
  if (gated.isNotEmpty) {
    stdout.writeln('\nCapability-gated samples (not failures):');
    for (final result in gated) {
      final reasons = result.blockReasons.join(', ');
      stdout.writeln(
        '- ${result.profile.key}: SKIP ${result.blocked}/'
        '${result.samples.length}${reasons.isEmpty ? '' : ' ($reasons)'}',
      );
    }
  }

  final recommended = selectRawRecommendedProfile(results);
  stdout.writeln(
    recommended == null
        ? 'No raw/tokenless client passed every applicable deep-range probe.'
        : 'Recommended raw/tokenless default: ${recommended.key}',
  );
}

/// Obtains a coherent visitor identity before any player request is measured.
///
/// The value is intentionally never logged. Fetching it outside the timed
/// samples also prevents bootstrap latency from biasing a client comparison.
Future<String> bootstrapRawBenchmarkVisitorData(
  InnerTubeTransport transport, {
  int maxAttempts = 2,
}) async {
  if (maxAttempts < 1 || maxAttempts > 5) {
    throw RangeError.range(maxAttempts, 1, 5, 'maxAttempts');
  }
  Object? lastError;
  for (var attempt = 0; attempt < maxAttempts; attempt += 1) {
    try {
      final response = await transport.get(
        Uri.https('music.youtube.com', '/', const <String, String>{
          'hl': 'en',
          'gl': 'US',
        }),
        headers: const <String, String>{
          HttpHeaders.acceptHeader: 'text/html,application/xhtml+xml',
          HttpHeaders.userAgentHeader:
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/140.0.0.0 Safari/537.36',
        },
        timeout: const Duration(seconds: 12),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('visitor bootstrap HTTP ${response.statusCode}');
      }
      return const InnerTubeBootstrapParser().parse(response.body).visitorData;
    } catch (error) {
      lastError = error;
      if (attempt + 1 < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
  }
  throw StateError(
    'Could not bootstrap visitor data after $maxAttempts attempts: '
    '${oneLineBenchmarkError(lastError ?? 'unknown error')}',
  );
}

/// Measures only the layers that are intentionally present in this raw tool.
Future<RawBenchmarkSample> measureRawInnerTubeProfile(
  InnerTubeTransport transport,
  InnerTubeStreamValidator validator,
  InnerTubePlayerResponseParser parser,
  InnerTubeVideoId videoId,
  InnerTubeClientProfile profile, {
  required String visitorData,
}) async {
  final capabilityBlock = rawCapabilityBlockReason(profile);
  if (capabilityBlock != null) {
    return RawBenchmarkSample.blocked(capabilityBlock);
  }

  final total = Stopwatch()..start();
  try {
    final request = Stopwatch()..start();
    final raw = await transport.postJson(
      profile.playerEndpoint,
      headers: <String, String>{
        ...profile.requestHeaders,
        'X-Goog-Visitor-Id': visitorData,
      },
      body: <String, Object?>{
        'context': profile.buildContext(visitorData: visitorData),
        'videoId': videoId.value,
        'contentCheckOk': true,
        'racyCheckOk': true,
        'videoCheckOk': true,
        'playbackContext': const <String, Object?>{
          'contentPlaybackContext': <String, Object?>{
            'html5Preference': 'HTML5_PREF_WANTS',
          },
        },
      },
      timeout: const Duration(seconds: 12),
    );
    request.stop();
    if (raw.statusCode < 200 || raw.statusCode >= 300) {
      return RawBenchmarkSample.failed(
        'player HTTP ${raw.statusCode}',
        request.elapsed,
      );
    }
    final decoded = jsonDecode(raw.body);
    if (decoded is! Map) {
      return RawBenchmarkSample.failed('invalid JSON', request.elapsed);
    }
    final response = parser.parse(
      Map<String, dynamic>.from(decoded),
      clientId: profile.key,
    );
    if (!response.isPlayable) {
      return RawBenchmarkSample.failed(
        response.playability.reason ?? response.playability.rawStatus,
        request.elapsed,
      );
    }
    final format = response.selectPreferredAudio();
    final uri = format?.sourceUri;
    if (format == null || uri == null) {
      return RawBenchmarkSample.failed('no direct audio', request.elapsed);
    }
    if (format.requiresSignatureDecipher ||
        uri.queryParameters.containsKey('n')) {
      return RawBenchmarkSample.blocked(
        'EJS challenge encountered',
        elapsed: request.elapsed,
      );
    }
    await validator.validate(
      uri,
      headers: <String, String>{
        HttpHeaders.userAgentHeader: profile.userAgent,
        'Origin': profile.origin,
        HttpHeaders.refererHeader: '${profile.origin}/',
      },
      contentLength: format.contentLength,
    );
    total.stop();
    return RawBenchmarkSample.success(request.elapsed, total.elapsed, format);
  } catch (error) {
    total.stop();
    return RawBenchmarkSample.failed(
      oneLineBenchmarkError(error),
      total.elapsed,
    );
  }
}

/// Returns why a profile cannot be assessed by a deliberately raw probe.
String? rawCapabilityBlockReason(InnerTubeClientProfile profile) {
  final requirements = <String>[];
  if (profile.capabilities.requiresPlayerJavaScript) {
    requirements.add('EJS');
  }
  if (profile.capabilities.supportsWebPo) {
    requirements.add('WebPO');
  } else if (profile.capabilities.unsupportedByWebPo) {
    requirements.add('platform PO');
  }
  return requirements.isEmpty ? null : '${requirements.join(' + ')} required';
}

/// Correctness ordering for results that have at least one raw measurement.
int compareRawProfileResults(RawProfileResult left, RawProfileResult right) {
  final leftPassProduct = left.successes * right.evaluated;
  final rightPassProduct = right.successes * left.evaluated;
  final passRate = rightPassProduct.compareTo(leftPassProduct);
  if (passRate != 0) return passRate;
  final evidence = right.evaluated.compareTo(left.evaluated);
  if (evidence != 0) return evidence;
  final latency = (left.medianMilliseconds ?? 1 << 30).compareTo(
    right.medianMilliseconds ?? 1 << 30,
  );
  if (latency != 0) return latency;
  return left.profile.key.compareTo(right.profile.key);
}

/// Picks a default only when every planned raw probe was actually evaluated.
InnerTubeClientProfile? selectRawRecommendedProfile(
  Iterable<RawProfileResult> results,
) {
  final candidates = results.where((result) {
    return result.evaluated > 0 &&
        result.blocked == 0 &&
        result.failures == 0 &&
        !result.profile.isExperimental &&
        !result.profile.isFallbackOnly &&
        !result.profile.capabilities.requiresPlayerJavaScript &&
        !result.profile.capabilities.mayNeedPoToken &&
        !result.profile.capabilities.unsupportedByWebPo;
  }).toList()..sort(compareRawProfileResults);
  return candidates.firstOrNull?.profile;
}

String oneLineBenchmarkError(Object value) {
  final text = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length <= 120 ? text : '${text.substring(0, 117)}...';
}

enum RawBenchmarkOutcome { valid, failed, blocked }

final class RawBenchmarkSample {
  const RawBenchmarkSample({
    required this.outcome,
    required this.requestElapsed,
    required this.totalElapsed,
    this.detail,
    this.itag,
  });

  factory RawBenchmarkSample.success(
    Duration request,
    Duration total,
    InnerTubeAudioFormat format,
  ) => RawBenchmarkSample(
    outcome: RawBenchmarkOutcome.valid,
    requestElapsed: request,
    totalElapsed: total,
    itag: format.itag,
  );

  factory RawBenchmarkSample.failed(String error, Duration elapsed) =>
      RawBenchmarkSample(
        outcome: RawBenchmarkOutcome.failed,
        requestElapsed: elapsed,
        totalElapsed: elapsed,
        detail: error,
      );

  factory RawBenchmarkSample.blocked(
    String reason, {
    Duration elapsed = Duration.zero,
  }) => RawBenchmarkSample(
    outcome: RawBenchmarkOutcome.blocked,
    requestElapsed: elapsed,
    totalElapsed: elapsed,
    detail: reason,
  );

  final RawBenchmarkOutcome outcome;
  final Duration requestElapsed;
  final Duration totalElapsed;
  final String? detail;
  final int? itag;

  bool get valid => outcome == RawBenchmarkOutcome.valid;
  bool get evaluated => outcome != RawBenchmarkOutcome.blocked;

  String get summary => switch (outcome) {
    RawBenchmarkOutcome.valid =>
      'OK itag=$itag player=${requestElapsed.inMilliseconds}ms '
          'total=${totalElapsed.inMilliseconds}ms',
    RawBenchmarkOutcome.failed => 'FAIL ${detail ?? 'unknown'}',
    RawBenchmarkOutcome.blocked => 'SKIP ${detail ?? 'capability required'}',
  };
}

final class RawProfileResult {
  const RawProfileResult(this.profile, this.samples);

  final InnerTubeClientProfile profile;
  final List<RawBenchmarkSample> samples;

  int get successes => samples.where((sample) => sample.valid).length;
  int get evaluated => samples.where((sample) => sample.evaluated).length;
  int get failures => evaluated - successes;
  int get blocked => samples.length - evaluated;

  Set<String> get blockReasons => samples
      .where((sample) => !sample.evaluated && sample.detail != null)
      .map((sample) => sample.detail!)
      .toSet();

  int? get medianMilliseconds {
    final values =
        samples
            .where((sample) => sample.valid)
            .map((sample) => sample.totalElapsed.inMilliseconds)
            .toList(growable: false)
          ..sort();
    if (values.isEmpty) return null;
    return values[values.length ~/ 2];
  }
}
