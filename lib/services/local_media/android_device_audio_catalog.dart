import '../../platform_channels/android_local_media_channel.dart';
import 'device_audio_catalog.dart';
import 'device_audio_filter.dart';

class AndroidDeviceAudioCatalog implements DeviceAudioCatalog {
  AndroidDeviceAudioCatalog([this._channel = const AndroidLocalMediaChannel()]);

  final AndroidLocalMediaChannel _channel;
  DeviceAudioCatalogSnapshot? _rawSnapshot;
  Future<DeviceAudioCatalogSnapshot>? _queryInFlight;

  @override
  Future<DeviceAudioCatalogResult> load({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) async {
    final status = await _channel.permissionStatus();
    return _loadGranted(status, options: options, bstreamRoot: bstreamRoot);
  }

  @override
  Future<DeviceAudioCatalogResult> requestPermissionAndLoad({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) async {
    final status = await _channel.requestPermission();
    return _loadGranted(status, options: options, bstreamRoot: bstreamRoot);
  }

  @override
  Future<DeviceAudioCatalogResult> refresh({
    DeviceAudioFilterOptions options = const DeviceAudioFilterOptions(),
    String? bstreamRoot,
  }) async {
    final status = await _channel.permissionStatus();
    return _loadGranted(
      status,
      options: options,
      bstreamRoot: bstreamRoot,
      forceRefresh: true,
    );
  }

  Future<DeviceAudioCatalogResult> _loadGranted(
    DeviceAudioPermissionStatus status, {
    required DeviceAudioFilterOptions options,
    required String? bstreamRoot,
    bool forceRefresh = false,
  }) async {
    if (status != DeviceAudioPermissionStatus.granted) {
      return DeviceAudioCatalogResult(status: status);
    }
    final snapshot = await _rawCatalog(forceRefresh: forceRefresh);
    return snapshot.prepare(options: options, bstreamRoot: bstreamRoot);
  }

  Future<DeviceAudioCatalogSnapshot> _rawCatalog({required bool forceRefresh}) {
    final cached = _rawSnapshot;
    if (!forceRefresh && cached != null) {
      return Future.value(cached);
    }
    final active = _queryInFlight;
    if (active != null) {
      return active;
    }
    late final Future<DeviceAudioCatalogSnapshot> request;
    request = _channel
        .queryTracks()
        .then((tracks) {
          final snapshot = DeviceAudioCatalogSnapshot(
            DeviceAudioPermissionStatus.granted,
            tracks,
          );
          _rawSnapshot = snapshot;
          return snapshot;
        })
        .whenComplete(() {
          if (identical(_queryInFlight, request)) {
            _queryInFlight = null;
          }
        });
    _queryInFlight = request;
    return request;
  }
}
