import '../../features/music/domain/entities/device_audio_track.dart';
import 'device_audio_filter.dart';
import 'device_audio_grouping.dart';

enum DeviceAudioPermissionStatus {
  granted,
  notDetermined,
  denied,
  permanentlyDenied,
  restricted,
  notRequired,
  unsupported,
}

class DeviceAudioCatalogResult {
  const DeviceAudioCatalogResult({
    required this.status,
    this.tracks = const <DeviceAudioTrack>[],
  });

  final DeviceAudioPermissionStatus status;
  final List<DeviceAudioTrack> tracks;

  bool get permissionRequired => switch (status) {
    DeviceAudioPermissionStatus.notDetermined ||
    DeviceAudioPermissionStatus.denied ||
    DeviceAudioPermissionStatus.permanentlyDenied ||
    DeviceAudioPermissionStatus.restricted => true,
    _ => false,
  };

  bool get permissionRequiresSettings =>
      status == DeviceAudioPermissionStatus.permanentlyDenied ||
      status == DeviceAudioPermissionStatus.restricted;

  bool get isSupported => status != DeviceAudioPermissionStatus.unsupported;

  List<DeviceAudioFolder> get folders => groupDeviceAudioTracksByFolder(tracks);
}

abstract interface class DeviceAudioCatalog {
  Future<DeviceAudioCatalogResult> load({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  });

  Future<DeviceAudioCatalogResult> requestPermissionAndLoad({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  });

  Future<DeviceAudioCatalogResult> refresh({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  });
}

class UnsupportedDeviceAudioCatalog implements DeviceAudioCatalog {
  const UnsupportedDeviceAudioCatalog();

  @override
  Future<DeviceAudioCatalogResult> load({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) async => const DeviceAudioCatalogResult(
    status: DeviceAudioPermissionStatus.unsupported,
  );

  @override
  Future<DeviceAudioCatalogResult> refresh({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) => load(options: options, bstreamRoot: bstreamRoot);

  @override
  Future<DeviceAudioCatalogResult> requestPermissionAndLoad({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) => load(options: options, bstreamRoot: bstreamRoot);
}
