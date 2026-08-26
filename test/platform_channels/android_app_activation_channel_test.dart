import 'package:bstream_music/platform_channels/android_app_activation_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses supported Android app activation events', () {
    expect(
      AndroidAppActivationEvent.fromPlatformEvent({
        'activation': 'home',
        'entryGeneration': 7,
      }),
      const AndroidAppActivationEvent(
        activation: AndroidAppActivation.home,
        entryGeneration: 7,
      ),
    );
    expect(
      AndroidAppActivationEvent.fromPlatformEvent('player'),
      const AndroidAppActivationEvent(activation: AndroidAppActivation.player),
    );
    expect(
      () => AndroidAppActivationEvent.fromPlatformEvent('unknown'),
      throwsFormatException,
    );
  });

  test('delivers a pending cold-start activation', () async {
    const methodChannel = MethodChannel('test/bstream_android_app_activation');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      expect(call.method, 'consumePendingActivation');
      return {'activation': 'home', 'entryGeneration': 4};
    });
    final channel = AndroidAppActivationChannel(methodChannel: methodChannel);
    addTearDown(() async {
      await channel.dispose();
      messenger.setMockMethodCallHandler(methodChannel, null);
    });

    expect(
      await channel.activations.first,
      const AndroidAppActivationEvent(
        activation: AndroidAppActivation.home,
        entryGeneration: 4,
      ),
    );
  });
}
