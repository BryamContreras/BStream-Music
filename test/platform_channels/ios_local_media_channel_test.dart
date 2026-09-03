import 'package:bstream_music/core/utils/image_source.dart';
import 'package:bstream_music/platform_channels/ios_local_media_channel.dart';
import 'package:bstream_music/services/local_media/device_audio_catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses iOS Media Library tracks through the shared contract', () async {
    const methodChannel = MethodChannel('test/ios_local_audio');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'permissionStatus' => 'denied',
            'requestPermission' => 'granted',
            'queryTracks' => <Object?>[
              <Object?, Object?>{
                'id': 'ios-media:42',
                'uri': 'ipod-library://item/item.m4a?id=42',
                'displayName': 'Song',
                'title': 'Song',
                'artist': 'Artist',
                'album': 'Album',
                'durationMs': 125000,
                'mimeType': 'audio/mp4',
                'folderId': 'ios-media-library',
                'folderName': 'Biblioteca',
              },
            ],
            _ => null,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    const channel = IosLocalMediaChannel(methodChannel: methodChannel);
    expect(
      await channel.permissionStatus(),
      DeviceAudioPermissionStatus.denied,
    );
    expect(
      await channel.requestPermission(),
      DeviceAudioPermissionStatus.granted,
    );
    final track = (await channel.queryTracks()).single;

    expect(calls.map((call) => call.method), <String>[
      'permissionStatus',
      'requestPermission',
      'queryTracks',
    ]);
    expect(track.id, 'ios-media:42');
    expect(track.uri, 'ipod-library://item/item.m4a?id=42');
    expect(track.title, 'Song');
    expect(track.artist, 'Artist');
    expect(track.album, 'Album');
    expect(track.duration, const Duration(seconds: 125));
    expect(track.folderId, 'ios-media-library');
    expect(deviceAudioUriFromArtworkSource(track.artworkSource), track.uri);
  });

  test('requests bounded Media Library artwork', () async {
    const methodChannel = MethodChannel('test/ios_local_audio_artwork');
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          received = call;
          return Uint8List.fromList(<int>[1, 2, 3]);
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    const channel = IosLocalMediaChannel(methodChannel: methodChannel);
    final bytes = await channel.loadArtwork(
      audioUri: 'ipod-library://item/item.m4a?id=42',
      targetWidth: 5000,
    );

    expect(received?.method, 'loadArtwork');
    expect(received?.arguments, <String, Object>{
      'audioUri': 'ipod-library://item/item.m4a?id=42',
      'targetWidth': 1280,
    });
    expect(bytes, <int>[1, 2, 3]);
  });

  test(
    'distinguishes first prompt, permanent denial, and restriction',
    () async {
      const methodChannel = MethodChannel('test/ios_local_audio_permissions');
      var response = 'notDetermined';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
            if (call.method == 'openPermissionSettings') return true;
            return response;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, null);
      });

      const channel = IosLocalMediaChannel(methodChannel: methodChannel);
      expect(
        await channel.permissionStatus(),
        DeviceAudioPermissionStatus.notDetermined,
      );
      response = 'permanentlyDenied';
      expect(
        await channel.permissionStatus(),
        DeviceAudioPermissionStatus.permanentlyDenied,
      );
      response = 'restricted';
      expect(
        await channel.permissionStatus(),
        DeviceAudioPermissionStatus.restricted,
      );
      expect(await channel.openPermissionSettings(), isTrue);
    },
  );
}
