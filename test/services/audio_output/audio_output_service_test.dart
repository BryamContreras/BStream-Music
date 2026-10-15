import 'package:bstream_music/services/audio_output/audio_output_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/output');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getState') {
            return {
              'supported': true,
              'routes': [
                {
                  'id': 's',
                  'name': 'Speaker',
                  'type': 'speaker',
                  'selected': true,
                },
                {
                  'id': 'bt',
                  'name': 'BT',
                  'type': 'bluetooth',
                  'selected': false,
                },
              ],
              'volume': .55,
              'hasSystemPicker': true,
            };
          }
          if (call.method == 'selectRoute' ||
              call.method == 'showSystemPicker') {
            return true;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test('native route list and media volume read only on demand', () async {
    final service = AudioOutputService(channel: channel);
    expect(calls, isEmpty);
    final state = await service.startWatching();
    expect(state.volume, .55);
    expect(state.routes.map((route) => route.type), [
      AudioOutputType.speaker,
      AudioOutputType.bluetooth,
    ]);
    expect(state.routes.first.selected, true);
    expect(await service.selectRoute('bt'), true);
    expect(await service.showSystemPicker(), true);
    await service.setVolume(5);
    expect(calls.last.arguments, {'volume': 1.0});
    await service.dispose();
    expect(calls.last.method, 'stopWatching');
  });
  test('preference request does not falsely mark route confirmed', () {
    final state = AudioOutputState.fromMap({
      'supported': true,
      'selectionConfirmed': false,
      'requestedRouteId': 'bt',
      'volume': -1,
    });
    expect(state.selectionConfirmed, false);
    expect(state.requestedRouteId, 'bt');
    expect(state.volume, 0);
  });
  test(
    'Android selection response is a state map, not an iOS boolean',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'selectRoute') {
              return {
                'supported': true,
                'requestedRouteId': 'bt',
                'selectionConfirmed': false,
                'routes': [],
              };
            }
            return null;
          });
      final service = AudioOutputService(channel: channel);
      expect(await service.selectRoute('bt'), true);
      await service.dispose();
    },
  );
  test(
    'absent plugin is unsupported, not fabricated phone or headphones',
    () async {
      final service = AudioOutputService(
        channel: const MethodChannel('test/missing-output'),
      );
      final state = await service.startWatching();
      expect(state.supported, false);
      expect(state.routes, isEmpty);
      await service.dispose();
    },
  );
}
