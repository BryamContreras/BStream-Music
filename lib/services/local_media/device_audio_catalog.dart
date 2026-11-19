import '../../core/utils/background_work.dart';
import '../../core/utils/duration_formatter.dart';
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
  }) : _summary = null;

  DeviceAudioCatalogResult._prepared(this.status, this.tracks)
    : _summary = (
        folders: groupDeviceAudioTracksByFolder(tracks),
        duration: sumKnownDurations(tracks.map((track) => track.duration)),
      );

  final DeviceAudioPermissionStatus status;
  final List<DeviceAudioTrack> tracks;
  final ({List<DeviceAudioFolder> folders, Duration? duration})? _summary;

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

  List<DeviceAudioFolder> get folders =>
      _summary?.folders ?? groupDeviceAudioTracksByFolder(tracks);

  Duration? get totalDuration {
    final summary = _summary;
    return summary == null
        ? sumKnownDurations(tracks.map((track) => track.duration))
        : summary.duration;
  }
}

/// A native scan and its most recent filter share one immutable result. Only
/// metadata goes to the worker. Permissions, media access and playback remain
/// with their respective platform services.
class DeviceAudioCatalogSnapshot {
  DeviceAudioCatalogSnapshot(this._status, Iterable<DeviceAudioTrack> tracks)
    : _tracks = List.unmodifiable(tracks);

  static const _workerTrackThreshold = 512;

  final DeviceAudioPermissionStatus _status;
  final List<DeviceAudioTrack> _tracks;
  (DeviceAudioFilterOptions, String?)? _preparedQuery;
  Future<DeviceAudioCatalogResult>? _preparedResult;

  Future<DeviceAudioCatalogResult> prepare({
    required DeviceAudioFilterOptions options,
    required String? bstreamRoot,
  }) {
    final query = (options, bstreamRoot);
    final result = _preparedResult;
    if (_preparedQuery == query && result != null) return result;
    final job = _DeviceCatalogPreparation(
      _status,
      _tracks,
      options,
      bstreamRoot,
    );
    final operation = _tracks.length < _workerTrackThreshold
        ? Future.sync(job.build)
        : runBackgroundWork(
            job.build,
            debugName: 'BStream local audio catalog',
          );
    late final Future<DeviceAudioCatalogResult> request;
    request = operation.onError<Object>((error, stack) {
      if (identical(_preparedResult, request)) _preparedResult = null;
      Error.throwWithStackTrace(error, stack);
    });
    _preparedQuery = query;
    _preparedResult = request;
    return request;
  }
}

class _DeviceCatalogPreparation {
  const _DeviceCatalogPreparation(
    this.status,
    this.tracks,
    this.options,
    this.root,
  );

  final DeviceAudioPermissionStatus status;
  final List<DeviceAudioTrack> tracks;
  final DeviceAudioFilterOptions options;
  final String? root;

  DeviceAudioCatalogResult build() => DeviceAudioCatalogResult._prepared(
    status,
    filterDeviceAudioTracks(tracks, options: options, bstreamRoot: root),
  );
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
