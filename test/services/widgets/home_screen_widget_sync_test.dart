import 'package:bstream_music/services/widgets/home_screen_widget_sync.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('bstream_music/home_widget_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('publishes only playback changes, not position ticks', () async {
    final updates = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'update') {
        updates.add(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
    final sync = HomeScreenWidgetSync(channel: channel);
    addTearDown(sync.dispose);

    void publish(bool playing) => sync.publish(
      trackId: 'track-1',
      title: 'Song',
      artist: 'Artist',
      artworkUrl: null,
      isPlaying: playing,
      isFavorite: false,
      repeatMode: 'off',
      accentColor: 0xFF22D3EE,
      languageCode: 'es',
    );

    publish(true);
    publish(true);
    await Future<void>.delayed(Duration.zero);
    expect(updates, hasLength(1));
    expect(updates.single['title'], 'Song');
    expect(updates.single['accentColor'], 0xFF22D3EE);
    expect(updates.single['isFavorite'], isFalse);
    expect(updates.single['repeatMode'], 'off');
    publish(false);
    await Future<void>.delayed(Duration.zero);
    expect(updates, hasLength(2));
    expect(updates.last['isPlaying'], isFalse);
  });

  test('publishes favorite and repeat changes to the widget', () async {
    final updates = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'update') {
        updates.add(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
    final sync = HomeScreenWidgetSync(channel: channel);
    addTearDown(sync.dispose);

    void publish({required bool favorite, required String repeat}) =>
        sync.publish(
          trackId: 'track-1',
          title: 'Song',
          artist: 'Artist',
          artworkUrl: null,
          isPlaying: true,
          isFavorite: favorite,
          repeatMode: repeat,
          accentColor: 0xFF22D3EE,
          languageCode: 'es',
        );

    publish(favorite: false, repeat: 'off');
    publish(favorite: true, repeat: 'all');
    await Future<void>.delayed(Duration.zero);

    expect(updates, hasLength(2));
    expect(updates.last['isFavorite'], isTrue);
    expect(updates.last['repeatMode'], 'all');
  });

  test('handles a widget command queued before Dart is ready', () async {
    final actions = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumePendingAction') return 'next';
      return null;
    });
    final sync = HomeScreenWidgetSync(
      channel: channel,
      onAction: (action) async => actions.add(action),
    );
    addTearDown(sync.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(actions, ['next']);
  });
}
