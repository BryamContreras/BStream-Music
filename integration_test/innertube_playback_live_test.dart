import 'package:bstream_music/services/youtube_music/playback/ejs_solver.dart';
import 'package:bstream_music/services/youtube_music/playback/headless_inappwebview_runtime.dart';
import 'package:bstream_music/services/youtube_music/playback/innertube_playback_service.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('BSTREAM_LIVE_INNERTUBE');

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
    } finally {
      await service.dispose();
    }
  }, skip: !enabled);
}
