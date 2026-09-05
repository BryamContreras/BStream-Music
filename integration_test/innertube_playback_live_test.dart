import 'package:bstream_music/services/youtube_music/playback/ejs_solver.dart';
import 'package:bstream_music/services/youtube_music/playback/headless_inappwebview_runtime.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_playback_service.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('BSTREAM_LIVE_INNERTUBE');
  const allowAttestationWithheld = bool.fromEnvironment(
    'BSTREAM_ALLOW_ATTESTATION_WITHHELD',
  );

  testWidgets('production fallback resolves media that passes the deep probe', (
    _,
  ) async {
    final service = InnerTubePlaybackService(
      ejsSolver: EjsSolver(runtime: HeadlessInAppWebViewJavaScriptRuntime()),
      poTokenProvider: BotGuardPoTokenProvider(),
      requestTimeout: const Duration(seconds: 20),
      resolveTimeout: const Duration(minutes: 2),
      maxRequestAttempts: 2,
    );
    try {
      final result = await service.resolve('kJQP7kiw5Fk');

      expect(result.profile.key, isNotEmpty);
      expect(result.format.hasAudio, isTrue);
      expect(result.uri.scheme, 'https');
      final effectiveLength =
          result.probe.contentLength ?? result.format.contentLength;
      final expectedOffset = effectiveLength != null && effectiveLength > 0
          ? (3 * 1024 * 1024).clamp(0, effectiveLength - 1)
          : 3 * 1024 * 1024;
      expect(result.probe.probedOffset, greaterThanOrEqualTo(expectedOffset));
      expect(result.expiresAt.isAfter(DateTime.now()), isTrue);
    } on InnerTubePlaybackException catch (error) {
      if (!allowAttestationWithheld || !_isAttestationWithheld(error.cause)) {
        rethrow;
      }
      // Public CI addresses may be denied by BotGuard even though the same
      // production fallback succeeds on residential connections. Keep this
      // one external refusal advisory without masking resolver regressions.
      // ignore: avoid_print
      print('YouTube withheld attestation from the public CI runner.');
    } finally {
      await service.dispose();
    }
  }, skip: !enabled);

  test('only a non-retryable BotGuard attestation denial is advisory', () {
    expect(
      _isAttestationWithheld(
        const PoTokenException(
          'Homepage integrity was withheld and the attestation fallback '
          'did not produce a usable token.',
          retryable: false,
        ),
      ),
      isTrue,
    );
    expect(
      _isAttestationWithheld(
        const PoTokenException(
          'Homepage integrity was withheld and the attestation fallback '
          'did not produce a usable token.',
        ),
      ),
      isFalse,
    );
    expect(
      _isAttestationWithheld(
        const PoTokenException(
          'A different resolver failure.',
          retryable: false,
        ),
      ),
      isFalse,
    );
  });
}

bool _isAttestationWithheld(Object? cause) {
  return cause is PoTokenException &&
      !cause.retryable &&
      cause.message ==
          'Homepage integrity was withheld and the attestation fallback '
              'did not produce a usable token.';
}
