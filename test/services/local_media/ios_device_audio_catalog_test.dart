import 'package:bstream_music/features/music/domain/entities/device_audio_track.dart';
import 'package:bstream_music/platform_channels/ios_local_media_channel.dart';
import 'package:bstream_music/services/local_media/device_audio_catalog.dart';
import 'package:bstream_music/services/local_media/device_audio_filter.dart';
import 'package:bstream_music/services/local_media/ios_device_audio_catalog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('caches the iOS catalog and reapplies Dart filters', () async {
    final channel = _FakeIosLocalMediaChannel(
      tracks: <DeviceAudioTrack>[
        _track('song', folder: 'Music/'),
        _track('message', folder: 'WhatsApp/Media/WhatsApp Audio/'),
      ],
    );
    final catalog = IosDeviceAudioCatalog(channel);

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
  });

  test('does not query the iOS library before permission is granted', () async {
    final channel = _FakeIosLocalMediaChannel(
      permission: DeviceAudioPermissionStatus.denied,
    );
    final result = await IosDeviceAudioCatalog(channel).load();

    expect(result.permissionRequired, isTrue);
    expect(result.tracks, isEmpty);
    expect(channel.queryCalls, 0);
  });

  test(
    'opens iOS Settings instead of repeating a permanently denied prompt',
    () async {
      final channel = _FakeIosLocalMediaChannel(
        permission: DeviceAudioPermissionStatus.permanentlyDenied,
      );

      final result = await IosDeviceAudioCatalog(
        channel,
      ).requestPermissionAndLoad();

      expect(result.status, DeviceAudioPermissionStatus.permanentlyDenied);
      expect(result.permissionRequiresSettings, isTrue);
      expect(channel.permissionRequests, 0);
      expect(channel.settingsRequests, 1);
      expect(channel.queryCalls, 0);
    },
  );
}

class _FakeIosLocalMediaChannel extends IosLocalMediaChannel {
  _FakeIosLocalMediaChannel({
    this.permission = DeviceAudioPermissionStatus.granted,
    this.tracks = const <DeviceAudioTrack>[],
  }) : super(methodChannel: const MethodChannel('unused/ios_local_audio'));

  DeviceAudioPermissionStatus permission;
  final List<DeviceAudioTrack> tracks;
  int queryCalls = 0;
  int permissionRequests = 0;
  int settingsRequests = 0;

  @override
  Future<DeviceAudioPermissionStatus> permissionStatus() async => permission;

  @override
  Future<DeviceAudioPermissionStatus> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Future<bool> openPermissionSettings() async {
    settingsRequests++;
    return true;
  }

  @override
  Future<List<DeviceAudioTrack>> queryTracks() async {
    queryCalls += 1;
    return tracks;
  }
}

DeviceAudioTrack _track(String id, {required String folder}) {
  return DeviceAudioTrack(
    id: id,
    uri: 'ipod-library://item/item.m4a?id=$id',
    title: id,
    duration: const Duration(minutes: 3),
    folderId: folder,
    folderName: folder,
    relativePath: folder,
  );
}
