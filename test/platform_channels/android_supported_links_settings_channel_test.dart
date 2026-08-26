import 'package:bstream_music/platform_channels/android_supported_links_settings_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('opens the Android supported links settings', () async {
    const methodChannel = MethodChannel('test/bstream_supported_links');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    const channel = AndroidSupportedLinksSettingsChannel(
      methodChannel: methodChannel,
    );

    expect(await channel.open(), isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'openSupportedLinksSettings');
    expect(calls.single.arguments, isNull);
  });

  test('returns false when the Android integration is unavailable', () async {
    const methodChannel = MethodChannel(
      'test/bstream_supported_links_unavailable',
    );
    const channel = AndroidSupportedLinksSettingsChannel(
      methodChannel: methodChannel,
    );

    expect(await channel.open(), isFalse);
  });
}
