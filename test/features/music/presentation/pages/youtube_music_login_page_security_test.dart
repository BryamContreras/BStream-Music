import 'package:bstream_music/features/music/presentation/pages/youtube_music_login_page.dart';
import 'package:flutter/foundation.dart';
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

  test('Android WebView settings preserve the private hardened surface', () {
    final settings = YouTubeMusicLoginPage.secureWebViewSettings(
      platform: TargetPlatform.android,
    );
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

  test('Windows uses its isolated profile where CookieManager can read it', () {
    final settings = YouTubeMusicLoginPage.secureWebViewSettings(
      platform: TargetPlatform.windows,
    );

    expect(settings.incognito, isFalse);
    expect(settings.cacheEnabled, isFalse);
    expect(settings.isInspectable, isFalse);
  });

  test('embedded login support has an explicit platform matrix', () {
    expect(
      isEmbeddedYouTubeMusicWebLoginSupportedOn(TargetPlatform.android),
      isTrue,
    );
    expect(
      isEmbeddedYouTubeMusicWebLoginSupportedOn(TargetPlatform.windows),
      isTrue,
    );
    expect(
      isEmbeddedYouTubeMusicWebLoginSupportedOn(TargetPlatform.macOS),
      isTrue,
    );
    expect(
      isEmbeddedYouTubeMusicWebLoginSupportedOn(TargetPlatform.linux),
      isFalse,
    );
  });

  test('desktop login mechanism never replaces the Android flow', () {
    expect(
      resolveYouTubeMusicLoginMechanism(
        isWeb: false,
        platform: TargetPlatform.android,
      ),
      YouTubeMusicLoginMechanism.embeddedWebView,
    );
    expect(
      resolveYouTubeMusicLoginMechanism(
        isWeb: false,
        platform: TargetPlatform.windows,
      ),
      YouTubeMusicLoginMechanism.desktopBrowser,
    );
    expect(
      resolveYouTubeMusicLoginMechanism(
        isWeb: false,
        platform: TargetPlatform.linux,
      ),
      YouTubeMusicLoginMechanism.desktopBrowser,
    );
    expect(
      resolveYouTubeMusicLoginMechanism(
        isWeb: false,
        platform: TargetPlatform.macOS,
      ),
      YouTubeMusicLoginMechanism.embeddedWebView,
    );
    expect(
      resolveYouTubeMusicLoginMechanism(
        isWeb: true,
        platform: TargetPlatform.windows,
      ),
      YouTubeMusicLoginMechanism.unsupported,
    );
  });
}
