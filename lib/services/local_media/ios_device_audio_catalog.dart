import '../../features/music/domain/entities/device_audio_track.dart';
import '../../platform_channels/ios_local_media_channel.dart';
import 'device_audio_catalog.dart';
import 'device_audio_filter.dart';

/// Reads non-protected, locally playable tracks from the iOS Media Library.
class IosDeviceAudioCatalog implements DeviceAudioCatalog {
  IosDeviceAudioCatalog([this._channel = const IosLocalMediaChannel()]);

  final IosLocalMediaChannel _channel;
  List<DeviceAudioTrack>? _rawTracks;
  Future<List<DeviceAudioTrack>>? _queryInFlight;

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
      _rawTracks = null;
      return DeviceAudioCatalogResult(status: status);
    }
    final tracks = await _rawCatalog(forceRefresh: forceRefresh);
    return DeviceAudioCatalogResult(
      status: status,
      tracks: filterDeviceAudioTracks(
        tracks,
        options: options,
        bstreamRoot: bstreamRoot,
      ),
    );
  }

  Future<List<DeviceAudioTrack>> _rawCatalog({required bool forceRefresh}) {
    final cached = _rawTracks;
    if (!forceRefresh && cached != null) {
      return Future<List<DeviceAudioTrack>>.value(cached);
    }
    final active = _queryInFlight;
    if (active != null) {
      return active;
    }
    final request = _channel.queryTracks();
    _queryInFlight = request;
    return request
        .then((tracks) {
          final snapshot = List<DeviceAudioTrack>.unmodifiable(tracks);
          _rawTracks = snapshot;
          return snapshot;
        })
        .whenComplete(() {
          if (identical(_queryInFlight, request)) {
            _queryInFlight = null;
          }
        });
  }
}
