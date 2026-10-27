import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/core/utils/image_source.dart';
import 'package:bstream_music/services/widgets/home_screen_widget_sync.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('bstream_music/home_widget_test');
  const artworkChannel = MethodChannel('bstream_music/local_audio');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(artworkChannel, null);
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

  test('keeps two played songs before the current queue entry', () async {
    Map<Object?, Object?>? published;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'update') {
        published = call.arguments as Map<Object?, Object?>;
      }
      return null;
    });
    final sync = HomeScreenWidgetSync(channel: channel);
    addTearDown(sync.dispose);

    sync.publish(
      trackId: 'track-e',
      title: 'E',
      artist: 'Artist',
      artworkUrl: null,
      isPlaying: true,
      isFavorite: false,
      repeatMode: 'off',
      accentColor: 0xFF22D3EE,
      languageCode: 'es',
      queue: const [
        {'id': 'track-a', 'title': 'A', 'artist': 'Artist'},
        {'id': 'track-b', 'title': 'B', 'artist': 'Artist'},
        {'id': 'track-c', 'title': 'C', 'artist': 'Artist'},
        {'id': 'track-d', 'title': 'D', 'artist': 'Artist'},
        {'id': 'track-e', 'title': 'E', 'artist': 'Artist'},
        {'id': 'track-f', 'title': 'F', 'artist': 'Artist'},
      ],
      currentQueueIndex: 4,
    );
    await Future<void>.delayed(Duration.zero);

    final encoded = jsonDecode(published!['queueJson']! as String) as List;
    expect(encoded.map((entry) => entry['id']).toList(), [
      'track-c',
      'track-d',
      'track-e',
      'track-f',
    ]);
    expect(encoded.map((entry) => entry['queueIndex']).toList(), [
      '2',
      '3',
      '4',
      '5',
    ]);
    expect(encoded.map((entry) => entry['isCurrent']).toList(), [
      false,
      false,
      true,
      false,
    ]);
  });

  test(
    'resolves covers beyond the first page of a large widget queue',
    () async {
      final resolvedQueue = Completer<List<dynamic>>();
      messenger.setMockMethodCallHandler(artworkChannel, (call) async {
        expect(call.method, 'loadArtwork');
        expect(
          (call.arguments['audioUri'] as String).startsWith(
            'content://media/audio/',
          ),
          isTrue,
        );
        return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'update') {
          final update = call.arguments as Map<Object?, Object?>;
          final queue = jsonDecode(update['queueJson']! as String) as List;
          if (queue.length == 30 &&
              queue.every((item) => item['artworkPath'] is String) &&
              !resolvedQueue.isCompleted) {
            resolvedQueue.complete(queue);
          }
        }
        return null;
      });
      final sync = HomeScreenWidgetSync(channel: channel);
      addTearDown(sync.dispose);

      sync.publish(
        trackId: 'current',
        title: 'Current',
        artist: 'Artist',
        artworkUrl: null,
        isPlaying: true,
        isFavorite: false,
        repeatMode: 'off',
        accentColor: 0xFF22D3EE,
        languageCode: 'es',
        queue: List.generate(
          30,
          (index) => {
            'id': 'local-track-$index',
            'title': 'Local track $index',
            'artist': 'Artist',
            'artworkUrl': deviceAudioArtworkSourceForUri(
              'content://media/audio/$index',
            )!,
          },
        ),
      );
      final queue = await resolvedQueue.future.timeout(
        const Duration(seconds: 5),
      );

      for (final item in queue) {
        final path = item['artworkPath'] as String;
        expect(await File(path).readAsBytes(), [0xFF, 0xD8, 0xFF, 0xD9]);
        await File(path).delete();
      }
    },
  );

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

  test('metadata changes share one pending artwork load', () async {
    final pending = Completer<Uint8List>();
    var loads = 0;
    final artworkUpdates = <Map<Object?, Object?>>[];
    messenger.setMockMethodCallHandler(artworkChannel, (call) async {
      loads++;
      return pending.future;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'updateArtworkBytes') {
        artworkUpdates.add(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
    final sync = HomeScreenWidgetSync(channel: channel);
    addTearDown(sync.dispose);

    void publish(bool playing, bool favorite) => sync.publish(
      trackId: 'track-1',
      title: 'Song',
      artist: 'Artist',
      artworkUrl: deviceAudioArtworkSourceForUri('content://media/audio/1'),
      isPlaying: playing,
      isFavorite: favorite,
      repeatMode: 'off',
      accentColor: 0xFF22D3EE,
      languageCode: 'es',
    );

    publish(false, false);
    await Future<void>.delayed(Duration.zero);
    publish(true, false);
    publish(true, true);
    await Future<void>.delayed(Duration.zero);
    expect(loads, 1);
    pending.complete(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(Duration.zero);
    expect(artworkUpdates, hasLength(1));
    expect(artworkUpdates.single['trackId'], 'track-1');

    publish(false, true);
    await Future<void>.delayed(Duration.zero);
    expect(loads, 1);
  });

  test(
    'skipping discards stale art and clearing allows the same track again',
    () async {
      final pending = <Completer<Uint8List>>[];
      final artworkUpdates = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(artworkChannel, (call) {
        final request = Completer<Uint8List>();
        pending.add(request);
        return request.future;
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'updateArtworkBytes') {
          artworkUpdates.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      });
      final sync = HomeScreenWidgetSync(channel: channel);
      addTearDown(sync.dispose);

      void publish(String? id) => sync.publish(
        trackId: id,
        title: id,
        artist: id == null ? null : 'Artist',
        artworkUrl: id == null
            ? null
            : deviceAudioArtworkSourceForUri('content://media/audio/$id'),
        isPlaying: id != null,
        isFavorite: false,
        repeatMode: 'off',
        accentColor: 0xFF22D3EE,
        languageCode: 'es',
      );

      publish('1');
      await Future<void>.delayed(Duration.zero);
      publish('2');
      await Future<void>.delayed(Duration.zero);
      expect(pending, hasLength(2));
      pending[0].complete(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);
      expect(artworkUpdates, isEmpty);
      pending[1].complete(Uint8List.fromList([2]));
      await Future<void>.delayed(Duration.zero);
      expect(artworkUpdates.single['trackId'], '2');

      publish(null);
      await Future<void>.delayed(Duration.zero);
      publish('2');
      await Future<void>.delayed(Duration.zero);
      expect(pending, hasLength(3));
      pending[2].complete(Uint8List.fromList([3]));
      await Future<void>.delayed(Duration.zero);
      expect(artworkUpdates, hasLength(2));
      expect(artworkUpdates.last['trackId'], '2');
    },
  );
}
