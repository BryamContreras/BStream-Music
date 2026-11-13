import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'audio_source_policy.dart';

typedef AudioNetworkReader = Future<AudioNetworkKind> Function();

/// One on-demand connection snapshot, shared by streaming and downloads. There
/// is no polling or internet reachability request; unknown transport is cautious.
class AudioNetworkMonitor {
  AudioNetworkMonitor({
    AudioNetworkReader? reader,
    Stream<AudioNetworkKind>? changes,
    DateTime Function()? clock,
  }) : _reader = reader ?? _readPlatformNetwork,
       _clock = clock ?? DateTime.now {
    _subscription =
        (changes ??
                Connectivity().onConnectivityChanged.map(
                  audioNetworkForConnections,
                ))
            .listen(
              _onNetworkChange,
              onError: (Object _) => _onNetworkChange(AudioNetworkKind.unknown),
            );
  }

  final AudioNetworkReader _reader;
  final DateTime Function() _clock;
  StreamSubscription<AudioNetworkKind>? _subscription;
  AudioNetworkKind _kind = AudioNetworkKind.unknown;
  DateTime? _checkedAt;
  Future<AudioNetworkKind>? _pending;
  bool _disposed = false;
  int _readGeneration = 0;

  AudioNetworkKind get lastKnownKind => _kind;

  /// Lets callers back off retryable unknown/offline snapshots without timers
  /// or additional platform queries while the snapshot is still fresh.
  bool canRefreshAfter(Duration minimumAge) {
    if (_disposed) return false;
    final checked = _checkedAt;
    return checked == null || _clock().difference(checked) >= minimumAge;
  }

  Future<AudioNetworkKind> current() {
    if (_disposed) return Future.value(AudioNetworkKind.unknown);
    final pending = _pending;
    if (pending != null) return pending;
    final checked = _checkedAt;
    if (checked != null &&
        _clock().difference(checked) < const Duration(seconds: 3)) {
      return Future.value(_kind);
    }
    late final Future<AudioNetworkKind> request;
    request = _check().whenComplete(() {
      if (identical(_pending, request)) _pending = null;
    });
    _pending = request;
    return request;
  }

  Future<AudioNetworkKind> _check() async {
    final generation = ++_readGeneration;
    // timeout bounds the caller's wait, not the platform request. Keep a late
    // useful answer unless a newer read or network event has superseded it.
    final reading = Future<AudioNetworkKind>.sync(_reader).then((kind) {
      if (!_disposed && generation == _readGeneration) {
        _remember(kind);
      }
      return kind;
    });
    try {
      await reading.timeout(const Duration(seconds: 1));
      return _disposed ? AudioNetworkKind.unknown : _kind;
    } on Object {
      if (!_disposed && generation == _readGeneration) {
        _remember(AudioNetworkKind.unknown);
      }
      return _disposed ? AudioNetworkKind.unknown : _kind;
    }
  }

  void _remember(AudioNetworkKind kind) {
    if (_disposed) return;
    _kind = kind;
    _checkedAt = _clock();
  }

  void _onNetworkChange(AudioNetworkKind kind) {
    if (_disposed) return;
    _readGeneration++;
    _remember(kind);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _subscription?.cancel();
  }
}

Future<AudioNetworkKind> _readPlatformNetwork() async =>
    audioNetworkForConnections(await Connectivity().checkConnectivity());

AudioNetworkKind audioNetworkForConnections(List<ConnectivityResult> results) {
  // Cellular wins when a platform reports multiple active transports. A VPN
  // alone does not reveal its underlying connection and stays conservative.
  if (results.contains(ConnectivityResult.mobile) ||
      results.any((result) => result.name == 'satellite')) {
    return AudioNetworkKind.mobile;
  }
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return AudioNetworkKind.wifi;
  }
  if (results.isNotEmpty &&
      results.every((result) => result == ConnectivityResult.none)) {
    return AudioNetworkKind.offline;
  }
  return AudioNetworkKind.unknown;
}
