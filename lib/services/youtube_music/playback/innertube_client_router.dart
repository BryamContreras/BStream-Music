import 'innertube_client_profile.dart';

enum InnerTubeClientFailureKind {
  timeout,
  unavailable,
  rejected,
  invalidResponse,
  challengeUnavailable,
}

final class InnerTubeClientHealth {
  const InnerTubeClientHealth({
    required this.profileKey,
    required this.successes,
    required this.consecutiveFailures,
    required this.averageLatency,
    this.cooldownUntil,
    this.lastFailure,
  });

  final String profileKey;
  final int successes;
  final int consecutiveFailures;
  final Duration? averageLatency;
  final DateTime? cooldownUntil;
  final InnerTubeClientFailureKind? lastFailure;

  bool isCoolingDownAt(DateTime instant) =>
      cooldownUntil != null && instant.isBefore(cooldownUntil!);
}

/// Orders playback clients and temporarily isolates repeatedly failing ones.
///
/// The selected default remains deterministic. Successful fallback clients are
/// ranked by an exponentially weighted latency, while correctness always wins:
/// profiles in cooldown are attempted only after every healthy candidate.
final class InnerTubeClientRouter {
  InnerTubeClientRouter({
    List<InnerTubeClientProfile> profiles = InnerTubeClientRegistry.defaults,
    String? primaryKey,
    this.failuresBeforeCooldown = 2,
    this.baseCooldown = const Duration(minutes: 2),
    this.maximumCooldown = const Duration(minutes: 20),
    DateTime Function()? clock,
  }) : profiles = List<InnerTubeClientProfile>.unmodifiable(profiles),
       primaryKey =
           primaryKey ??
           (profiles.isEmpty
               ? InnerTubeClientRegistry.primary.key
               : profiles.first.key),
       _clock = clock ?? DateTime.now {
    if (this.profiles.isEmpty) {
      throw ArgumentError.value(profiles, 'profiles', 'Must not be empty.');
    }
    if (this.profiles.map((profile) => profile.key).toSet().length !=
        this.profiles.length) {
      throw ArgumentError.value(
        profiles,
        'profiles',
        'Profile keys must be unique.',
      );
    }
    if (!this.profiles.any((profile) => profile.key == this.primaryKey)) {
      throw ArgumentError.value(
        this.primaryKey,
        'primaryKey',
        'Must identify one configured profile.',
      );
    }
    if (failuresBeforeCooldown < 1) {
      throw ArgumentError.value(
        failuresBeforeCooldown,
        'failuresBeforeCooldown',
        'Must be positive.',
      );
    }
    if (baseCooldown <= Duration.zero || maximumCooldown < baseCooldown) {
      throw ArgumentError('Cooldown durations are invalid.');
    }
  }

  final List<InnerTubeClientProfile> profiles;
  final String primaryKey;
  final int failuresBeforeCooldown;
  final Duration baseCooldown;
  final Duration maximumCooldown;
  final DateTime Function() _clock;
  final Map<String, _MutableClientHealth> _health = {};

  List<InnerTubeClientProfile> candidates({
    bool skipPrimary = false,
    Set<String> excludedProfileKeys = const <String>{},
    bool supportsJavaScript = true,
    bool supportsWebPo = true,
    bool includeExperimental = false,
  }) {
    final now = _clock();
    final eligible = profiles
        .where((profile) {
          if (!profile.isEnabled ||
              (skipPrimary && profile.key == primaryKey) ||
              excludedProfileKeys.contains(profile.key)) {
            return false;
          }
          if (!includeExperimental && profile.isExperimental) {
            return false;
          }
          if (profile.capabilities.requiresPlayerJavaScript &&
              !supportsJavaScript) {
            return false;
          }
          if (profile.capabilities.supportsWebPo && !supportsWebPo) {
            return false;
          }
          // DroidGuard/iOSGuard profiles are benchmark metadata only until a
          // matching platform attestation provider is configured.
          if (profile.capabilities.unsupportedByWebPo) {
            return false;
          }
          return true;
        })
        .toList(growable: false);

    final healthy = <InnerTubeClientProfile>[];
    final cooling = <InnerTubeClientProfile>[];
    for (final profile in eligible) {
      final state = _health[profile.key];
      (state?.isCoolingDownAt(now) ?? false ? cooling : healthy).add(profile);
    }
    healthy.sort((left, right) => _compare(left, right, keepPrimary: true));
    cooling.sort((left, right) => _compare(left, right, keepPrimary: false));
    return List<InnerTubeClientProfile>.unmodifiable(<InnerTubeClientProfile>[
      ...healthy,
      ...cooling,
    ]);
  }

  void recordSuccess(String profileKey, Duration latency) {
    if (latency.isNegative) {
      throw ArgumentError.value(latency, 'latency', 'Must not be negative.');
    }
    final state = _health.putIfAbsent(
      profileKey,
      () => _MutableClientHealth(profileKey),
    );
    state
      ..successes += 1
      ..consecutiveFailures = 0
      ..cooldownUntil = null
      ..lastFailure = null
      ..averageLatencyMicros = state.averageLatencyMicros == null
          ? latency.inMicroseconds.toDouble()
          : (state.averageLatencyMicros! * 0.7) +
                (latency.inMicroseconds * 0.3);
  }

  void recordFailure(String profileKey, InnerTubeClientFailureKind kind) {
    final state = _health.putIfAbsent(
      profileKey,
      () => _MutableClientHealth(profileKey),
    );
    state
      ..consecutiveFailures += 1
      ..lastFailure = kind;
    if (state.consecutiveFailures < failuresBeforeCooldown) return;

    final exponent = (state.consecutiveFailures - failuresBeforeCooldown).clamp(
      0,
      8,
    );
    final multiplier = 1 << exponent;
    final cooldownMicros = (baseCooldown.inMicroseconds * multiplier).clamp(
      baseCooldown.inMicroseconds,
      maximumCooldown.inMicroseconds,
    );
    state.cooldownUntil = _clock().add(Duration(microseconds: cooldownMicros));
  }

  InnerTubeClientHealth healthFor(String profileKey) {
    final state = _health[profileKey];
    return state?.snapshot() ??
        InnerTubeClientHealth(
          profileKey: profileKey,
          successes: 0,
          consecutiveFailures: 0,
          averageLatency: null,
        );
  }

  List<InnerTubeClientHealth> get health =>
      profiles.map((profile) => healthFor(profile.key)).toList(growable: false);

  int _compare(
    InnerTubeClientProfile left,
    InnerTubeClientProfile right, {
    required bool keepPrimary,
  }) {
    if (identical(left, right) || left.key == right.key) return 0;
    if (keepPrimary) {
      if (left.key == primaryKey) return -1;
      if (right.key == primaryKey) return 1;
    }
    final leftLatency = _health[left.key]?.averageLatencyMicros;
    final rightLatency = _health[right.key]?.averageLatencyMicros;
    if (leftLatency != null && rightLatency != null) {
      final latencyOrder = leftLatency.compareTo(rightLatency);
      if (latencyOrder != 0) return latencyOrder;
    } else if (leftLatency != null) {
      return -1;
    } else if (rightLatency != null) {
      return 1;
    }
    return profiles.indexOf(left).compareTo(profiles.indexOf(right));
  }
}

final class _MutableClientHealth {
  _MutableClientHealth(this.profileKey);

  final String profileKey;
  int successes = 0;
  int consecutiveFailures = 0;
  double? averageLatencyMicros;
  DateTime? cooldownUntil;
  InnerTubeClientFailureKind? lastFailure;

  bool isCoolingDownAt(DateTime instant) =>
      cooldownUntil != null && instant.isBefore(cooldownUntil!);

  InnerTubeClientHealth snapshot() => InnerTubeClientHealth(
    profileKey: profileKey,
    successes: successes,
    consecutiveFailures: consecutiveFailures,
    averageLatency: averageLatencyMicros == null
        ? null
        : Duration(microseconds: averageLatencyMicros!.round()),
    cooldownUntil: cooldownUntil,
    lastFailure: lastFailure,
  );
}
