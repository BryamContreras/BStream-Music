import 'dart:io';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:bstream_music/services/youtube_music/playback/ejs_solver.dart';
import 'package:bstream_music/services/youtube_music/playback/headless_inappwebview_runtime.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_profile.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_router.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_playback_service.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_video_id.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _enabled = bool.fromEnvironment('BSTREAM_LIVE_INNERTUBE_MATRIX');
const _strict = bool.fromEnvironment('BSTREAM_INNERTUBE_MATRIX_STRICT');
const _includeExperimental = bool.fromEnvironment(
  'BSTREAM_INNERTUBE_MATRIX_INCLUDE_EXPERIMENTAL',
);
const _roundsDefine = String.fromEnvironment(
  'BSTREAM_INNERTUBE_MATRIX_ROUNDS',
  defaultValue: '2',
);
const _videosDefine = String.fromEnvironment(
  'BSTREAM_INNERTUBE_MATRIX_VIDEOS',
  defaultValue: 'dQw4w9WgXcQ,kJQP7kiw5Fk,9bZkp7q19f0,JGwWNGJdvx8,CevxZvSJLk8',
);
const _profilesDefine = String.fromEnvironment(
  'BSTREAM_INNERTUBE_MATRIX_PROFILES',
);
const _minimumSuccessPercentDefine = String.fromEnvironment(
  'BSTREAM_INNERTUBE_MATRIX_MIN_SUCCESS_PERCENT',
  defaultValue: '80',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'production clients resolve independently through the complete stack',
    (_) async {
      final rounds = int.tryParse(_roundsDefine);
      expect(
        rounds,
        inInclusiveRange(1, 10),
        reason: 'BSTREAM_INNERTUBE_MATRIX_ROUNDS must be between 1 and 10.',
      );
      final minimumSuccessPercent = int.tryParse(_minimumSuccessPercentDefine);
      expect(
        minimumSuccessPercent,
        inInclusiveRange(1, 100),
        reason:
            'BSTREAM_INNERTUBE_MATRIX_MIN_SUCCESS_PERCENT must be between '
            '1 and 100.',
      );
      final videoIds = _videosDefine
          .split(',')
          .map((value) => InnerTubeVideoId.extract(value.trim()))
          .whereType<InnerTubeVideoId>()
          .toList(growable: false);
      expect(
        videoIds,
        isNotEmpty,
        reason: 'BSTREAM_INNERTUBE_MATRIX_VIDEOS has no valid video IDs.',
      );

      final requestedKeys = _profilesDefine
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet();
      final knownKeys = InnerTubeClientRegistry.benchmarkCandidates
          .map((profile) => profile.key)
          .toSet();
      final unknownKeys = requestedKeys.difference(knownKeys);
      expect(
        unknownKeys,
        isEmpty,
        reason: 'BSTREAM_INNERTUBE_MATRIX_PROFILES contains unknown keys.',
      );
      final profileCatalog = _includeExperimental || requestedKeys.isNotEmpty
          ? InnerTubeClientRegistry.benchmarkCandidates
          : InnerTubeClientRegistry.defaults;
      final selected = profileCatalog
          .where((profile) {
            return requestedKeys.isEmpty || requestedKeys.contains(profile.key);
          })
          .toList(growable: false);
      expect(selected, isNotEmpty);

      final platform = AppPlatform.current;
      final supportsWebViewRuntime =
          HeadlessInAppWebViewJavaScriptRuntime.supportsPlatform(platform);
      final eligible = <InnerTubeClientProfile>[];
      final skipped = <_ProfileSkip>[];
      for (final profile in selected) {
        final unavailableReason = _unavailableReason(
          profile,
          supportsWebViewRuntime: supportsWebViewRuntime,
          allowExperimental:
              _includeExperimental || requestedKeys.contains(profile.key),
        );
        if (unavailableReason == null) {
          eligible.add(profile);
        } else {
          skipped.add(_ProfileSkip(profile, unavailableReason));
          debugPrint(
            'MATRIX_SKIP client=${profile.key} reason=$unavailableReason',
          );
        }
      }
      if (_strict) {
        expect(
          skipped,
          isEmpty,
          reason:
              'Strict profile matrix cannot skip selected clients: '
              '${skipped.map((entry) => entry.summary).join(', ')}.',
        );
      }
      if (eligible.isEmpty) {
        debugPrint(
          'MATRIX_TOTAL platform=${platform.name} clients=0 '
          'skipped=${skipped.length} valid=0 failed=0',
        );
        return;
      }

      final matrix = <_ProfileMatrixResult>[];
      for (final profile in eligible) {
        final result = await _measureProfile(
          profile,
          videoIds: videoIds,
          rounds: rounds!,
        );
        matrix.add(result);
        debugPrint(result.summary);
        final thresholdIsRequired =
            profile.availability == InnerTubeClientAvailability.stable ||
            requestedKeys.contains(profile.key);
        debugPrint(
          'MATRIX_THRESHOLD client=${profile.key} '
          'enforced=$thresholdIsRequired '
          'required=$minimumSuccessPercent% '
          'actual=${result.successPercent}% '
          'status=${result.meetsThreshold(minimumSuccessPercent!) ? 'pass' : 'below'}',
        );
      }

      final successes = matrix.fold<int>(
        0,
        (total, result) => total + result.successes,
      );
      final failures = matrix.fold<int>(
        0,
        (total, result) => total + result.failures,
      );
      debugPrint(
        'MATRIX_TOTAL platform=${platform.name} clients=${matrix.length} '
        'skipped=${skipped.length} valid=$successes failed=$failures',
      );
      if (_strict) {
        final belowThreshold = matrix
            .where(
              (result) =>
                  (result.profile.availability ==
                          InnerTubeClientAvailability.stable ||
                      requestedKeys.contains(result.profile.key)) &&
                  !result.meetsThreshold(minimumSuccessPercent!),
            )
            .toList(growable: false);
        expect(
          belowThreshold,
          isEmpty,
          reason:
              'Strict profile matrix requires every stable or explicitly '
              'selected client to meet '
              '$minimumSuccessPercent%: '
              '${belowThreshold.map((result) => result.thresholdSummary).join(', ')}.',
        );
      } else if (successes == 0) {
        debugPrint(
          'MATRIX_DIAGNOSTIC status=no-successes '
          'message=No_profile_passed_a_complete_deep-range_probe',
        );
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 45)),
  );
}

final class _ProfileSkip {
  const _ProfileSkip(this.profile, this.reason);

  final InnerTubeClientProfile profile;
  final String reason;

  String get summary => '${profile.key}:$reason';
}

String? _unavailableReason(
  InnerTubeClientProfile profile, {
  required bool supportsWebViewRuntime,
  required bool allowExperimental,
}) {
  if (!profile.isEnabled || (profile.isExperimental && !allowExperimental)) {
    return 'not-stable';
  }
  if (profile.capabilities.unsupportedByWebPo) {
    return 'platform-attestation-unavailable';
  }
  if (profile.capabilities.requiresPlayerJavaScript &&
      !supportsWebViewRuntime) {
    return 'ejs-runtime-unavailable';
  }
  if (profile.capabilities.supportsWebPo && !supportsWebViewRuntime) {
    return 'webpo-runtime-unavailable';
  }
  return null;
}

Future<_ProfileMatrixResult> _measureProfile(
  InnerTubeClientProfile profile, {
  required List<InnerTubeVideoId> videoIds,
  required int rounds,
}) async {
  final samples = <_MatrixSample>[];
  final routedProfile = _asExplicitMatrixProfile(profile);
  final ejsSolver = profile.capabilities.requiresPlayerJavaScript
      ? EjsSolver(runtime: HeadlessInAppWebViewJavaScriptRuntime())
      : null;
  final poTokenProvider = profile.capabilities.supportsWebPo
      ? BotGuardPoTokenProvider()
      : null;
  final service = InnerTubePlaybackService(
    router: InnerTubeClientRouter(
      profiles: <InnerTubeClientProfile>[routedProfile],
      primaryKey: profile.key,
    ),
    visitorDataStore: _MemoryVisitorDataStore(),
    ejsSolver: ejsSolver,
    poTokenProvider: poTokenProvider,
    requestTimeout: const Duration(seconds: 20),
    resolveTimeout: const Duration(minutes: 2),
    maxRequestAttempts: 2,
  );
  try {
    for (var round = 0; round < rounds; round += 1) {
      for (var index = 0; index < videoIds.length; index += 1) {
        final isCold = samples.isEmpty;
        final stopwatch = Stopwatch()..start();
        try {
          final resolved = await service.resolve(videoIds[index].value);
          stopwatch.stop();
          final invalidReasons = <String>[
            if (resolved.profile.key != profile.key) 'profile-mismatch',
            if (!resolved.format.hasAudio) 'no-audio',
            if (resolved.uri.scheme != 'https') 'non-https',
            if (!_isDeepOrTailProbe(resolved)) 'shallow-probe',
            if (!resolved.expiresAt.isAfter(DateTime.now())) 'expired',
          ];
          if (invalidReasons.isNotEmpty) {
            samples.add(
              _MatrixSample.failed(
                stopwatch.elapsed,
                reason: 'invalid-${invalidReasons.join('-')}',
                isCold: isCold,
              ),
            );
          } else {
            samples.add(
              _MatrixSample.success(stopwatch.elapsed, isCold: isCold),
            );
          }
        } catch (error) {
          stopwatch.stop();
          samples.add(
            _MatrixSample.failed(
              stopwatch.elapsed,
              reason: _safeFailureCategory(error),
              isCold: isCold,
            ),
          );
        }
        final sample = samples.last;
        debugPrint(
          'MATRIX_SAMPLE client=${profile.key} round=${round + 1} '
          'sample=${index + 1} phase=${isCold ? 'cold' : 'warm'} '
          '${sample.summary}',
        );
      }
    }
  } finally {
    await service.dispose();
  }
  return _ProfileMatrixResult(profile, samples);
}

bool _isDeepOrTailProbe(InnerTubeResolvedAudio resolved) {
  const deepOffset = 3 * 1024 * 1024;
  final effectiveLength =
      resolved.probe.contentLength ?? resolved.format.contentLength;
  final expectedOffset = effectiveLength != null && effectiveLength > 0
      ? deepOffset.clamp(0, effectiveLength - 1)
      : deepOffset;
  return resolved.probe.probedOffset >= expectedOffset;
}

/// The production router intentionally filters experimental profiles. A
/// profile named explicitly by this opt-in diagnostic is copied as stable only
/// inside the test process so the exact same request metadata can be measured.
InnerTubeClientProfile _asExplicitMatrixProfile(
  InnerTubeClientProfile profile,
) {
  if (!profile.isExperimental) return profile;
  return InnerTubeClientProfile(
    key: profile.key,
    clientName: profile.clientName,
    clientVersion: profile.clientVersion,
    clientId: profile.clientId,
    host: profile.host,
    origin: profile.origin,
    userAgent: profile.userAgent,
    capabilities: profile.capabilities,
    availability: InnerTubeClientAvailability.stable,
    isEmbedded: profile.isEmbedded,
    allowDynamicClientVersion: profile.allowDynamicClientVersion,
    contextValues: profile.contextValues,
    requestContextValues: profile.requestContextValues,
  );
}

String _safeFailureCategory(Object error) {
  if (error is InnerTubePlaybackException) {
    if (error.failures.any((failure) => failure.error is SocketException)) {
      return 'transport-network';
    }
    return 'playback-${error.kind?.name ?? 'no-candidate'}';
  }
  return error.runtimeType.toString().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
}

final class _MatrixSample {
  const _MatrixSample({
    required this.valid,
    required this.elapsed,
    required this.isCold,
    this.failureCategory,
  });

  factory _MatrixSample.success(Duration elapsed, {required bool isCold}) =>
      _MatrixSample(valid: true, elapsed: elapsed, isCold: isCold);

  factory _MatrixSample.failed(
    Duration elapsed, {
    required String reason,
    required bool isCold,
  }) => _MatrixSample(
    valid: false,
    elapsed: elapsed,
    isCold: isCold,
    failureCategory: reason,
  );

  final bool valid;
  final Duration elapsed;
  final bool isCold;
  final String? failureCategory;

  String get summary => valid
      ? 'OK elapsedMs=${elapsed.inMilliseconds}'
      : 'FAIL category=${failureCategory ?? 'unknown'} '
            'elapsedMs=${elapsed.inMilliseconds}';
}

final class _ProfileMatrixResult {
  const _ProfileMatrixResult(this.profile, this.samples);

  final InnerTubeClientProfile profile;
  final List<_MatrixSample> samples;

  int get successes => samples.where((sample) => sample.valid).length;
  int get failures => samples.length - successes;
  int get successPercent =>
      samples.isEmpty ? 0 : (successes * 100) ~/ samples.length;

  bool meetsThreshold(int minimumPercent) {
    return samples.isNotEmpty &&
        successes * 100 >= samples.length * minimumPercent;
  }

  String get thresholdSummary =>
      '${profile.key}=$successes/${samples.length}($successPercent%)';

  int? get medianMilliseconds => _medianMilliseconds(samples);

  int? get warmMedianMilliseconds {
    return _medianMilliseconds(samples.where((sample) => !sample.isCold));
  }

  static int? _medianMilliseconds(Iterable<_MatrixSample> source) {
    final latencies =
        source
            .where((sample) => sample.valid)
            .map((sample) => sample.elapsed.inMilliseconds)
            .toList(growable: false)
          ..sort();
    if (latencies.isEmpty) return null;
    return latencies[latencies.length ~/ 2];
  }

  String get summary {
    final coldSample = samples.isEmpty ? null : samples.first;
    final coldSummary = coldSample == null
        ? '-'
        : coldSample.valid
        ? 'OK:${coldSample.elapsed.inMilliseconds}'
        : 'FAIL:${coldSample.failureCategory ?? 'unknown'}:'
              '${coldSample.elapsed.inMilliseconds}';
    final failureCategories = samples
        .where((sample) => !sample.valid)
        .map((sample) => sample.failureCategory ?? 'unknown')
        .toSet()
        .join(',');
    return 'MATRIX_SUMMARY client=${profile.key} '
        'valid=$successes/${samples.length} failed=$failures '
        'cold=$coldSummary '
        'warmMedianMs=${warmMedianMilliseconds ?? '-'} '
        'medianMs=${medianMilliseconds ?? '-'} '
        'categories=${failureCategories.isEmpty ? '-' : failureCategories}';
  }
}

final class _MemoryVisitorDataStore implements InnerTubeVisitorDataStore {
  String? _value;

  @override
  Future<void> clear() async => _value = null;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String visitorData) async => _value = visitorData;
}
