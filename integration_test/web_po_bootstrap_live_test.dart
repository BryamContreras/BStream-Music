import 'package:bstream_music/services/youtube_music/innertube_transport.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_binding.dart';
import 'package:bstream_music/services/youtube_music/playback/po_token_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('BSTREAM_LIVE_WEB_PO');
  const strict = bool.fromEnvironment('BSTREAM_LIVE_WEB_PO_STRICT');

  testWidgets(
    'live homepage exposes a coherent WebPO bootstrap and interpreter',
    (_) async {
      final transport = IoInnerTubeTransport(
        connectionTimeout: const Duration(seconds: 8),
      );
      try {
        final response = await transport.get(
          BotGuardPoTokenProvider.homepageUri,
          headers: const <String, String>{
            'accept': '*/*',
            'accept-language': 'en-US,en;q=0.9',
            'user-agent': BotGuardPoTokenProvider.webUserAgent,
          },
          timeout: const Duration(seconds: 20),
        );
        expect(response.statusCode, inInclusiveRange(200, 299));
        final bootstrap = BotGuardResponseParser.parseHomepage(response.body);
        expect(bootstrap.source, BotGuardBootstrapSource.homepage);
        expect(bootstrap.visitorData, isNotEmpty);
        expect(bootstrap.eventId, isNotEmpty);
        expect(bootstrap.youtubeConfig['EVENT_ID'], bootstrap.eventId);

        final interpreterUri =
            BotGuardResponseParser.parseTrustedInterpreterUri(
              bootstrap.challenge.interpreterTrustedResourceUrl,
            );
        final interpreter = await transport.get(
          interpreterUri,
          headers: const <String, String>{
            'accept': '*/*',
            'referer': 'https://www.youtube.com/',
            'user-agent': BotGuardPoTokenProvider.webUserAgent,
          },
          timeout: const Duration(seconds: 20),
        );
        expect(interpreter.statusCode, inInclusiveRange(200, 299));
        expect(interpreter.body, isNotEmpty);
      } finally {
        transport.close();
      }
    },
    skip: !enabled,
  );

  testWidgets('live WebView mints full tokens or fails closed', (_) async {
    final provider = BotGuardPoTokenProvider();
    try {
      try {
        final tokens = await provider.getTokens(
          videoId: 'dQw4w9WgXcQ',
          requirements: const YoutubePoTokenRequirements(
            player: true,
            gvs: true,
            gvsBinding: YoutubePoTokenBinding.videoId,
          ),
        );
        expect(tokens.visitorData, isNotEmpty);
        expect(tokens.playerRequestPoToken, isNotEmpty);
        expect(tokens.streamingDataPoToken, tokens.playerRequestPoToken);
      } on PoTokenException catch (error) {
        if (strict) rethrow;
        expect(error.retryable, isFalse);
        expect(error.toString(), contains('withheld the integrity token'));
      }
    } finally {
      await provider.dispose();
    }
  }, skip: !enabled);
}
