import 'package:bstream_music/features/music/presentation/pages/youtube_music_login_page.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('login starts on the exact Google HTTPS host', () {
    final uri = Uri.parse(YouTubeMusicLoginPage.initialLoginUrl.toString());
    expect(uri.scheme, 'https');
    expect(uri.host, 'accounts.google.com');
    expect(uri.userInfo, isEmpty);
    expect(uri.queryParameters['continue'], 'https://music.youtube.com/');
  });

  test('WebView settings isolate and harden the account surface', () {
    final settings = YouTubeMusicLoginPage.secureWebViewSettings();
    expect(settings.incognito, isTrue);
    expect(settings.cacheEnabled, isFalse);
    expect(settings.useShouldOverrideUrlLoading, isTrue);
    expect(settings.javaScriptEnabled, isTrue);
    expect(settings.javaScriptCanOpenWindowsAutomatically, isFalse);
    expect(settings.allowFileAccess, isFalse);
    expect(settings.allowContentAccess, isFalse);
    expect(settings.allowFileAccessFromFileURLs, isFalse);
    expect(settings.allowUniversalAccessFromFileURLs, isFalse);
    expect(settings.domStorageEnabled, isTrue);
    expect(settings.databaseEnabled, isFalse);
    expect(settings.safeBrowsingEnabled, isTrue);
    expect(
      settings.mixedContentMode,
      MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
    );
    expect(settings.saveFormData, isFalse);
    expect(settings.supportMultipleWindows, isFalse);
    expect(settings.isInspectable, isFalse);
  });
}
