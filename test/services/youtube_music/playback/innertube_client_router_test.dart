import 'package:bstream_music/services/youtube_music/playback/innertube_client_profile.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_client_router.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps the benchmark primary ahead of faster fallbacks', () {
    final router = InnerTubeClientRouter();
    router
      ..recordSuccess('visionOS', const Duration(milliseconds: 900))
      ..recordSuccess('androidSdkless', const Duration(milliseconds: 250));

    expect(
      router.candidates().take(2).map((profile) => profile.key),
      orderedEquals(<String>['visionOS', 'androidSdkless']),
    );
  });

  test('moves a repeatedly failing primary behind healthy clients', () {
    var now = DateTime.utc(2026, 8, 31);
    final router = InnerTubeClientRouter(clock: () => now);
    router
      ..recordFailure('visionOS', InnerTubeClientFailureKind.rejected)
      ..recordFailure('visionOS', InnerTubeClientFailureKind.rejected);

    expect(router.candidates().last.key, 'visionOS');
    expect(router.healthFor('visionOS').isCoolingDownAt(now), isTrue);

    now = now.add(const Duration(minutes: 3));
    expect(router.candidates().first.key, 'visionOS');
  });

  test('filters profiles whose challenge runtime is unavailable', () {
    final router = InnerTubeClientRouter();

    expect(
      router.candidates(supportsJavaScript: false, supportsWebPo: false),
      <InnerTubeClientProfile>[
        InnerTubeClientRegistry.visionOS,
        InnerTubeClientRegistry.androidSdkless,
        InnerTubeClientRegistry.visionOS01,
      ],
    );
  });

  test('fallback mode skips the default profile', () {
    final router = InnerTubeClientRouter();

    expect(
      router.candidates(skipPrimary: true).map((profile) => profile.key),
      isNot(contains('visionOS')),
    );
  });

  test('can exclude the exact profile that produced a rejected stream', () {
    final router = InnerTubeClientRouter();

    expect(
      router
          .candidates(
            skipPrimary: true,
            excludedProfileKeys: const <String>{'androidSdkless'},
          )
          .map((profile) => profile.key),
      allOf(isNot(contains('visionOS')), isNot(contains('androidSdkless'))),
    );
  });
}
