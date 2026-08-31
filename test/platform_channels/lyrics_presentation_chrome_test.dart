import 'package:bstream_music/platform_channels/android_screen_channel.dart';
import 'package:bstream_music/platform_channels/lyrics_presentation_chrome.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hides system chrome only for Android side mode', () async {
    const androidMethodChannel = MethodChannel(
      'test/bstream_presentation_android',
    );
    final androidCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(androidMethodChannel, (call) async {
      androidCalls.add(call);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(androidMethodChannel, null);
    });

    const chrome = LyricsPresentationChrome(
      androidScreen: AndroidScreenChannel(methodChannel: androidMethodChannel),
    );

    await chrome.setSideModeActive(
      platform: TargetPlatform.android,
      active: true,
    );
    await chrome.setSideModeActive(
      platform: TargetPlatform.android,
      active: false,
    );
    await chrome.setSideModeActive(
      platform: TargetPlatform.windows,
      active: true,
    );
    await chrome.setSideModeActive(
      platform: TargetPlatform.windows,
      active: false,
    );
    await chrome.setSideModeActive(
      platform: TargetPlatform.linux,
      active: true,
    );
    await chrome.setSideModeActive(platform: TargetPlatform.iOS, active: true);

    expect(androidCalls.map((call) => call.method), [
      'setStatusBarHidden',
      'setStatusBarHidden',
    ]);
    expect(androidCalls.map((call) => call.arguments), [
      {'hidden': true},
      {'hidden': false},
    ]);
  });
}
