import 'package:bstream_music/platform_channels/android_screen_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sets and clears the Android keep-screen-on flag', () async {
    const methodChannel = MethodChannel('test/bstream_screen');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    const channel = AndroidScreenChannel(methodChannel: methodChannel);
    await channel.setKeepScreenOn(true);
    await channel.setKeepScreenOn(false);

    expect(calls.map((call) => call.method), [
      'setKeepScreenOn',
      'setKeepScreenOn',
    ]);
    expect(calls[0].arguments, {'enabled': true});
    expect(calls[1].arguments, {'enabled': false});
  });

  test('hides and restores the Android status bar', () async {
    const methodChannel = MethodChannel('test/bstream_status_bar');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    const channel = AndroidScreenChannel(methodChannel: methodChannel);
    await channel.setStatusBarHidden(true);
    await channel.setStatusBarHidden(false);

    expect(calls.map((call) => call.method), [
      'setStatusBarHidden',
      'setStatusBarHidden',
    ]);
    expect(calls[0].arguments, {'hidden': true});
    expect(calls[1].arguments, {'hidden': false});
  });

  test('status-bar failures do not escape the Android channel', () async {
    const missingChannel = MethodChannel('test/bstream_status_bar_missing');
    const failingChannel = MethodChannel('test/bstream_status_bar_failure');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          failingChannel,
          (_) async => throw PlatformException(code: 'status_bar_failure'),
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(failingChannel, null);
    });

    await expectLater(
      const AndroidScreenChannel(
        methodChannel: missingChannel,
      ).setStatusBarHidden(true),
      completes,
    );
    await expectLater(
      const AndroidScreenChannel(
        methodChannel: failingChannel,
      ).setStatusBarHidden(true),
      completes,
    );
  });
}
