import 'dart:io';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/core/startup/app_startup_coordinator.dart';
import 'package:bstream_music/features/music/presentation/pages/youtube_music_login_page.dart';
import 'package:bstream_music/features/music/presentation/providers/mini_player_mode.dart';
import 'package:bstream_music/main.dart' show startupServicesForPlatform;
import 'package:bstream_music/services/youtube_music/playback/headless_inappwebview_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS support contract', () {
    test('routes iOS through the supported mobile platform path', () {
      expect(AppPlatform.isMobileOn(AppPlatformType.ios), isTrue);
      expect(AppPlatform.isMobileTargetPlatform(TargetPlatform.iOS), isTrue);
      expect(AppPlatform.supportsTikTokLiveOn(AppPlatformType.ios), isTrue);
      expect(AppPlatform.isMobileOn(AppPlatformType.macos), isFalse);
    });

    test('uses the embedded hardened login flow on iOS', () {
      expect(
        resolveYouTubeMusicLoginMechanism(
          isWeb: false,
          platform: TargetPlatform.iOS,
        ),
        YouTubeMusicLoginMechanism.embeddedWebView,
      );
      expect(
        isEmbeddedYouTubeMusicWebLoginSupportedOn(TargetPlatform.iOS),
        isTrue,
      );

      final settings = YouTubeMusicLoginPage.secureWebViewSettings(
        platform: TargetPlatform.iOS,
      );
      // flutter_inappwebview's iOS CookieManager reads WKWebsiteDataStore's
      // default cookie store. The login WebView must use that same store; the
      // auth port clears it before and after this isolated flow.
      expect(settings.incognito, isFalse);
      expect(settings.cacheEnabled, isFalse);
      expect(settings.javaScriptCanOpenWindowsAutomatically, isFalse);
      expect(settings.allowFileAccess, isFalse);
      expect(settings.allowUniversalAccessFromFileURLs, isFalse);
      expect(settings.isInspectable, isFalse);
      expect(
        YouTubeMusicLoginPage.shouldCancelServerTrustChallenges(
          platform: TargetPlatform.iOS,
        ),
        isFalse,
      );
      expect(
        YouTubeMusicLoginPage.shouldCancelServerTrustChallenges(
          platform: TargetPlatform.android,
        ),
        isTrue,
      );
    });

    test('enables playback challenges and a phone-sized mini player', () {
      expect(
        HeadlessInAppWebViewJavaScriptRuntime.supportsPlatform(
          AppPlatformType.ios,
        ),
        isTrue,
      );
      expect(
        defaultMiniPlayerModeForPlatform(TargetPlatform.iOS),
        MiniPlayerMode.capsule,
      );
    });

    test(
      'starts background media with native-lock-screen artwork plumbing',
      () {
        expect(
          startupServicesForPlatform(platform: AppPlatformType.ios),
          const <OptionalStartupService>{
            OptionalStartupService.notificationArtwork,
            OptionalStartupService.audioService,
          },
        );
      },
    );

    test('native runner declares the required capabilities and channels', () {
      final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(infoPlist, contains('<key>NSAppleMusicUsageDescription</key>'));
      expect(infoPlist, contains('<key>UIBackgroundModes</key>'));
      expect(infoPlist, contains('<string>audio</string>'));
      expect(infoPlist, contains('<key>NSAllowsLocalNetworking</key>'));
      expect(infoPlist, contains('<string>bstreammusic</string>'));
      expect(infoPlist, isNot(contains('NSAllowsArbitraryLoads')));

      final appDelegate = File(
        'ios/Runner/AppDelegate.swift',
      ).readAsStringSync();
      expect(appDelegate, contains('IOSLocalMediaPlugin'));
      expect(appDelegate, contains('IOSFileExportPlugin'));
      expect(appDelegate, contains('bstream_music/screen'));
      expect(appDelegate, contains('isIdleTimerDisabled'));
    });

    test('native runner resources are localized and launch dark', () {
      for (final locale in const <String>['en', 'es']) {
        final localization = File('ios/Runner/$locale.lproj/InfoPlist.strings');
        expect(localization.existsSync(), isTrue);
        expect(
          localization.readAsStringSync(),
          contains('NSAppleMusicUsageDescription'),
        );
      }

      final project = File(
        'ios/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync();
      expect(project, contains('en.lproj/InfoPlist.strings'));
      expect(project, contains('es.lproj/InfoPlist.strings'));
      expect(project, contains('IOSLocalMediaPlugin.swift in Sources'));
      expect(project, contains('IOSFileExportPlugin.swift in Sources'));

      final launchScreen = File(
        'ios/Runner/Base.lproj/LaunchScreen.storyboard',
      ).readAsStringSync();
      expect(launchScreen, contains('red="0.02352941176"'));
      expect(
        launchScreen,
        isNot(contains('key="backgroundColor" red="1" green="1" blue="1"')),
      );
    });

    test('release workflow publishes a validated unsigned IPA payload', () {
      final workflow = File(
        '.github/workflows/desktop-builds.yml',
      ).readAsStringSync();

      expect(workflow, contains('name: iOS unsigned IPA'));
      expect(workflow, contains('flutter build ios --release --no-codesign'));
      expect(workflow, contains('Payload/Runner.app/Info.plist'));
      expect(workflow, contains(r'test ! -d "$app/_CodeSignature"'));
      expect(workflow, contains(r'test ! -e "$app/embedded.mobileprovision"'));
      expect(
        workflow,
        contains(r'BStream-Music-$APP_VERSION-iOS-unsigned.ipa'),
      );
      expect(workflow, contains('- name: Upload unsigned iOS IPA'));
    });
  });
}
