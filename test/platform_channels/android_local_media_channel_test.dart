import 'package:bstream_music/platform_channels/android_local_media_channel.dart';
import 'package:bstream_music/core/utils/image_source.dart';
import 'package:bstream_music/services/local_media/device_audio_catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('queries permission and parses complete MediaStore metadata', () async {
    const methodChannel = MethodChannel('test/local_audio');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'permissionStatus' => 'denied',
            'requestPermission' => 'granted',
            'queryTracks' => <Object?>[
              <Object?, Object?>{
                'id': 'external:content://media/external/audio/media/42',
                'uri': 'content://media/external/audio/media/42',
                'displayName': 'Song.flac',
                'title': 'Song',
                'artist': 'Artist',
                'album': 'Album',
                'durationMs': 125000,
                'mimeType': 'audio/flac',
                'relativePath': 'Music/Album/',
                'absolutePath': '/storage/emulated/0/Music/Album/Song.flac',
                'folderId': 'external_primary:music/album',
                'folderName': 'Album',
              },
            ],
            _ => null,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    const channel = AndroidLocalMediaChannel(methodChannel: methodChannel);
    expect(
      await channel.permissionStatus(),
      DeviceAudioPermissionStatus.denied,
    );
    expect(
      await channel.requestPermission(),
      DeviceAudioPermissionStatus.granted,
    );
    final tracks = await channel.queryTracks();

    expect(calls.map((call) => call.method), <String>[
      'permissionStatus',
      'requestPermission',
      'queryTracks',
    ]);
    expect(tracks, hasLength(1));
    final track = tracks.single;
    expect(track.title, 'Song');
    expect(track.artist, 'Artist');
    expect(track.album, 'Album');
    expect(track.duration, const Duration(seconds: 125));
    expect(track.folderId, 'external_primary:music/album');
    expect(track.folderName, 'Album');
    expect(track.relativePath, 'Music/Album/');
    expect(track.absolutePath, '/storage/emulated/0/Music/Album/Song.flac');
    expect(
      deviceAudioUriFromArtworkSource(track.artworkSource),
      'content://media/external/audio/media/42',
    );
    expect(
      track.toTransientLocalTrack(unknownArtist: 'Unknown').thumbnailUrl,
      track.artworkSource,
    );
  });

  test('falls back to filename and folder metadata safely', () {
    final track =
        DeviceAudioTrackPlatformModel.fromPlatformValue(<Object?, Object?>{
          'uri': 'content://media/external/audio/media/7',
          'displayName': 'Unknown title.mp3',
          'artist': '<unknown>',
          'relativePath': 'Download/Concerts/',
        });

    expect(track.title, 'Unknown title');
    expect(track.artist, isNull);
    expect(track.folderName, 'Concerts');
    expect(track.duration, isNull);
  });

  test('loads one bounded embedded artwork on demand', () async {
    const methodChannel = MethodChannel('test/local_audio_artwork');
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

    const channel = AndroidLocalMediaChannel(methodChannel: methodChannel);
    final bytes = await channel.loadArtwork(
      audioUri: 'content://media/external/audio/media/42',
      targetWidth: 5000,
    );

    expect(received?.method, 'loadArtwork');
    expect(received?.arguments, <String, Object>{
      'audioUri': 'content://media/external/audio/media/42',
      'targetWidth': 1280,
    });
    expect(bytes, <int>[1, 2, 3]);
  });
}
