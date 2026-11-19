import '../../platform_channels/ios_local_media_channel.dart';
import 'device_audio_catalog.dart';
import 'device_audio_filter.dart';

/// Reads non-protected, locally playable tracks from the iOS Media Library.
class IosDeviceAudioCatalog implements DeviceAudioCatalog {
  IosDeviceAudioCatalog([this._channel = const IosLocalMediaChannel()]);

  final IosLocalMediaChannel _channel;
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
    final current = await _channel.permissionStatus();
    if (current == DeviceAudioPermissionStatus.permanentlyDenied ||
        current == DeviceAudioPermissionStatus.restricted) {
      await _channel.openPermissionSettings();
      return DeviceAudioCatalogResult(status: current);
    }
    final status = await _channel.requestPermission();
    return _loadGranted(
      status,
      options: options,
      bstreamRoot: bstreamRoot,
      forceRefresh: true,
    );
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
      _rawSnapshot = null;
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
