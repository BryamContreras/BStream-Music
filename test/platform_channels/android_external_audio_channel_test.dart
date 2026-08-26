import 'package:bstream_music/platform_channels/android_external_audio_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses an external folder queue and preserves the selected index', () {
    final request = ExternalAudioRequest.fromPlatformEvent({
      'requestId': 'request-1',
      'selectedIndex': 1,
      'folderQueueComplete': true,
      'permissionPending': false,
      'permissionDenied': false,
      'entryGeneration': 12,
      'tracks': [
        {
          'uri': 'content://media/external/audio/media/10',
          'displayName': '01 Intro.mp3',
          'title': 'Intro',
          'artist': '<unknown>',
          'durationMs': 61000,
        },
        {
          'id': 'external:selected',
          'uri': 'content://media/external/audio/media/11',
          'displayName': '02 Song.flac',
          'artist': 'Artist',
          'durationMs': 125000,
          'mimeType': 'audio/flac',
        },
      ],
    });

    expect(request.requestId, 'request-1');
    expect(request.queueSourceId, 'external-folder:request-1');
    expect(request.selectedIndex, 1);
    expect(request.folderQueueComplete, isTrue);
    expect(request.permissionPending, isFalse);
    expect(request.permissionDenied, isFalse);
    expect(request.openPlayer, isTrue);
    expect(request.entryGeneration, 12);
    expect(
      request.tracks.first.id,
      'external:content://media/external/audio/media/10',
    );
    expect(request.tracks[1].title, '02 Song');

    final tracks = request.toLocalTracks(unknownArtist: 'Desconocido');
    expect(tracks, hasLength(2));
    expect(tracks[0].artist, 'Desconocido');
    expect(tracks[0].duration, const Duration(seconds: 61));
    expect(tracks[1].id, 'external:selected');
    expect(tracks[1].filePath, 'content://media/external/audio/media/11');
    expect(tracks[1].duration, const Duration(seconds: 125));
    expect(tracks.every((track) => track.isExternal), isTrue);
  });

  test('rejects an external request with an invalid selected index', () {
    expect(
      () => ExternalAudioRequest.fromPlatformEvent({
        'requestId': 'request-2',
        'selectedIndex': 3,
        'tracks': [
          {'uri': 'content://media/external/audio/media/10'},
        ],
      }),
      throwsFormatException,
    );
  });

  test(
    'delivers pending audio after the Android Activity is recreated',
    () async {
      const methodChannel = MethodChannel(
        'test/bstream_android_external_audio',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        expect(call.method, 'consumePendingExternalAudioEvents');
        return [
          {
            'requestId': 'recreated-activity-request',
            'selectedIndex': 0,
            'folderQueueComplete': true,
            'permissionPending': false,
            'permissionDenied': false,
            'openPlayer': false,
            'entryGeneration': 9,
            'tracks': [
              {
                'id': 'external:recreated',
                'uri': 'content://media/external/audio/media/14',
                'title': 'Backroad',
              },
            ],
          },
        ];
      });
      final channel = AndroidExternalAudioChannel(methodChannel: methodChannel);
      addTearDown(() async {
        await channel.dispose();
        messenger.setMockMethodCallHandler(methodChannel, null);
      });

      final request = await channel.requests.first;

      expect(request.requestId, 'recreated-activity-request');
      expect(request.tracks.single.title, 'Backroad');
      expect(request.openPlayer, isFalse);
      expect(request.entryGeneration, 9);
    },
  );
}
