import 'package:bstream_music/features/music/domain/entities/device_audio_track.dart';
import 'package:bstream_music/platform_channels/android_local_media_channel.dart';
import 'package:bstream_music/services/local_media/android_device_audio_catalog.dart';
import 'package:bstream_music/services/local_media/device_audio_catalog.dart';
import 'package:bstream_music/services/local_media/device_audio_filter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'keeps one raw session snapshot and reapplies changed filters',
    () async {
      final channel = _FakeAndroidLocalMediaChannel(
        tracks: <DeviceAudioTrack>[
          _track('song', folder: 'Music/'),
          _track('message', folder: 'WhatsApp/Media/WhatsApp Audio/'),
        ],
      );
      final catalog = AndroidDeviceAudioCatalog(channel);

      final filtered = await catalog.load();
      final unfiltered = await catalog.load(
        options: const DeviceAudioFilterOptions(
          excludeWhatsAppAudio: false,
          excludeShortAudio: false,
        ),
      );

      expect(filtered.tracks.map((track) => track.id), <String>['song']);
      expect(unfiltered.tracks, hasLength(2));
      expect(channel.queryCalls, 1);

      await catalog.refresh();
      expect(channel.queryCalls, 2);
    },
  );

  test('does not query MediaStore while permission is denied', () async {
    final channel = _FakeAndroidLocalMediaChannel(
      permission: DeviceAudioPermissionStatus.denied,
    );
    final result = await AndroidDeviceAudioCatalog(channel).load();

    expect(result.permissionRequired, isTrue);
    expect(result.tracks, isEmpty);
    expect(channel.queryCalls, 0);
  });
}

class _FakeAndroidLocalMediaChannel extends AndroidLocalMediaChannel {
  _FakeAndroidLocalMediaChannel({
    this.permission = DeviceAudioPermissionStatus.granted,
    this.tracks = const <DeviceAudioTrack>[],
  }) : super(methodChannel: const MethodChannel('unused/local_audio'));

  DeviceAudioPermissionStatus permission;
  final List<DeviceAudioTrack> tracks;
  int queryCalls = 0;

  @override
  Future<DeviceAudioPermissionStatus> permissionStatus() async => permission;

  @override
  Future<DeviceAudioPermissionStatus> requestPermission() async => permission;

  @override
  Future<List<DeviceAudioTrack>> queryTracks() async {
    queryCalls += 1;
    return tracks;
  }
}

DeviceAudioTrack _track(String id, {required String folder}) {
  return DeviceAudioTrack(
    id: id,
    uri: 'content://media/$id',
    title: id,
    duration: const Duration(minutes: 3),
    folderId: folder,
    folderName: folder,
    relativePath: folder,
  );
}
