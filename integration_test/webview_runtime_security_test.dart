import 'dart:convert';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/services/youtube_music/playback/headless_inappwebview_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('headless JavaScript runtime stays offline and cannot navigate', (
    _,
  ) async {
    final platform = AppPlatform.current;
    if (!HeadlessInAppWebViewJavaScriptRuntime.supportsPlatform(platform)) {
      return;
    }

    final runtime = HeadlessInAppWebViewJavaScriptRuntime(platform: platform);
    try {
      await runtime.initialize(
        html:
            '<!doctype html><html><head><script>'
            'window.harnessReady = true;'
            '</script></head><body></body></html>',
        baseUrl: Uri.parse('https://www.youtube.com/'),
      );
      final raw = await runtime.callAsyncJavaScript(
        functionBody: r'''
          let navigationThrew = false;
          try {
            window.location.assign('https://example.com/escaped');
          } catch (_) {
            navigationThrew = true;
          }
          await new Promise(resolve => setTimeout(resolve, 100));

          let fetchBlocked = false;
          try {
            await fetch('https://example.com/runtime-probe');
          } catch (_) {
            fetchBlocked = true;
          }
          return JSON.stringify({
            href: window.location.href,
            harnessReady: window.harnessReady === true,
            navigationThrew,
            fetchBlocked
          });
        ''',
      );
      final result = jsonDecode(raw! as String) as Map<String, dynamic>;

      expect(result['href'], isNot(startsWith('https://example.com/')));
      expect(result['harnessReady'], isTrue);
      expect(result['fetchBlocked'], isTrue);
    } finally {
      await runtime.dispose();
    }
  });
}
