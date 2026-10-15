import 'dart:async';
import 'dart:io';

import 'dlna_cast_client.dart';
import 'media_cast_relay.dart';
import 'native_cast_client.dart';

enum CastProtocol { googleCast, dlna }

enum CastPlaybackStatus { idle, loading, playing, paused, completed }

class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    required this.protocol,
    this.address,
    this.dlnaDevice,
  });

  final String id;
  final String name;
  final CastProtocol protocol;
  final String? address;
  final DlnaDevice? dlnaDevice;
}

class CastState {
  const CastState({
    this.devices = const [],
    this.device,
    this.status = CastPlaybackStatus.idle,
    this.position = Duration.zero,
    this.duration,
    this.volume = 1,
    this.contentId,
    this.googleCastSupported = false,
    this.discovering = false,
    this.error,
  });

  final List<CastDevice> devices;
  final CastDevice? device;
  final CastPlaybackStatus status;
  final Duration position;
  final Duration? duration;
  final double volume;
  final String? contentId;
  final bool googleCastSupported;
  final bool discovering;
  final String? error;
  bool get connected => device != null;
}

/// A single remote transport for the logical player. Discovery is explicitly
/// scoped to the picker; the relay is opened only when a receiver is selected.
class CastCoordinator {
  CastCoordinator({
    NativeCastClient? nativeClient,
    DlnaCastClient? dlnaClient,
    MediaCastRelay? relay,
    this.preferDirectRemote = true,
    bool? allowDlnaDiscovery,
  }) : _native = nativeClient ?? NativeCastClient(),
       _dlna = dlnaClient ?? DlnaCastClient(),
       _relay = relay ?? MediaCastRelay(),
       _allowDlnaDiscovery = allowDlnaDiscovery ?? !Platform.isIOS {
    _nativeSubscription = _native.changes.listen(_onNative);
    _dlnaSubscription = _dlna.stateStream.listen(_onDlna);
  }

  final NativeCastClient _native;
  final DlnaCastClient _dlna;
  final MediaCastRelay _relay;
  final bool preferDirectRemote;
  // Raw SSDP on iOS requires an Apple-approved multicast entitlement.
  final bool _allowDlnaDiscovery;
  late final StreamSubscription<NativeCastState> _nativeSubscription;
  late final StreamSubscription<DlnaPlaybackState> _dlnaSubscription;
  final _changes = StreamController<CastState>.broadcast();
  List<CastDevice> _dlnaDevices = const [];
  CastDevice? _selected;
  String? _contentId;
  bool _discovering = false;
  bool _disposed = false;
  int _discoveryGeneration = 0;
  int _connectionGeneration = 0;
  int _loadGeneration = 0;
  CastState _state = const CastState();

  Stream<CastState> get changes => _changes.stream;
  CastState get state => _state;

  List<CastDevice> get _devices => [
    for (final device in _native.state.devices)
      CastDevice(
        id: device.id,
        name: device.name,
        address: device.address,
        protocol: CastProtocol.googleCast,
      ),
    ..._dlnaDevices,
  ];

  void _emit({
    CastPlaybackStatus? status,
    Duration? position,
    Duration? duration,
    double? volume,
    String? error,
  }) {
    if (_disposed) return;
    _state = CastState(
      devices: _devices,
      device: _selected,
      status: status ?? _state.status,
      position: position ?? _state.position,
      duration: duration ?? _state.duration,
      volume: volume ?? _state.volume,
      contentId: _contentId,
      googleCastSupported: _native.state.supported,
      discovering: _discovering,
      error: error,
    );
    _changes.add(_state);
  }

  void _onNative(NativeCastState state) {
    if (_selected?.protocol != CastProtocol.googleCast) {
      _emit();
      return;
    }
    if (state.suspended) {
      // CAF temporarily suspends a session during reconnection (and on iOS
      // backgrounding). The receiver can STILL be playing; do not start the
      // phone decoder or tear down a working relay as if it had disconnected.
      _emit(
        status: _contentId == null ? _state.status : CastPlaybackStatus.loading,
      );
      return;
    }
    if (!state.connected) {
      _selected = null;
      _contentId = null;
      unawaited(_relay.stop());
      _emit(status: CastPlaybackStatus.idle, error: state.error);
      return;
    }
    if (_contentId == null) {
      _emit(volume: state.volume, error: state.error);
      return;
    }
    // The previous load can report one last native status during Next. Do not
    // attribute it to the new occurrence, even when the same song is repeated.
    if (_contentId != null && state.contentId != _contentId) return;
    _emit(
      status: CastPlaybackStatus.values.byName(state.status.name),
      position: state.position,
      duration: state.duration,
      volume: state.volume,
      error:
          state.status == NativeCastStatus.idle ||
              state.status == NativeCastStatus.loading
          ? state.error
          : null,
    );
  }

  void _onDlna(DlnaPlaybackState state) {
    if (_selected?.protocol != CastProtocol.dlna) return;
    if (!state.connected) {
      _selected = null;
      _contentId = null;
      unawaited(_relay.stop());
    }
    if (_contentId == null) {
      _emit(volume: state.volume, error: state.error);
      return;
    }
    _emit(
      status: state.completed
          ? CastPlaybackStatus.completed
          : state.buffering
          ? CastPlaybackStatus.loading
          : state.playing
          ? CastPlaybackStatus.playing
          : CastPlaybackStatus.paused,
      position: state.position,
      duration: state.duration,
      volume: state.volume,
      error: state.error,
    );
  }

  Future<void> startDiscovery() async {
    final generation = ++_discoveryGeneration;
    _discovering = true;
    _emit();
    // A missing/disabled Google Play Services installation must not prevent
    // discovery of standards-based DLNA receivers.
    await Future.wait([
      _native.startDiscovery().catchError((Object _) {}),
      () async {
        if (!_allowDlnaDiscovery) return;
        try {
          final devices = await _dlna.discover();
          if (_disposed || generation != _discoveryGeneration) return;
          _dlnaDevices = [
            for (final device in devices)
              CastDevice(
                id: device.id,
                name: device.name,
                address: device.address,
                protocol: CastProtocol.dlna,
                dlnaDevice: device,
              ),
          ];
        } catch (_) {
          // No network/no receiver is a valid empty result, not a player error.
        }
      }(),
    ]);
    if (_disposed || generation != _discoveryGeneration) return;
    _discovering = false;
    _emit();
  }

  Future<void> stopDiscovery() async {
    ++_discoveryGeneration;
    _discovering = false;
    await _native.stopDiscovery();
    _emit();
  }

  Future<void> connect(CastDevice device) async {
    if (_selected?.id == device.id && _selected?.protocol == device.protocol) {
      return;
    }
    await disconnect();
    final generation = ++_connectionGeneration;
    if (device.protocol == CastProtocol.googleCast) {
      await _native.connect(device.id).timeout(const Duration(seconds: 25));
    } else {
      final dlnaDevice = device.dlnaDevice;
      if (dlnaDevice == null) throw StateError('Missing DLNA receiver.');
      await _dlna.connect(dlnaDevice);
    }
    if (_disposed || generation != _connectionGeneration) {
      throw StateError('Cast connection was cancelled.');
    }
    _selected = device;
    _emit(status: CastPlaybackStatus.idle, position: Duration.zero);
  }

  Future<void> load({
    required Uri source,
    required String mimeType,
    required String title,
    required String artist,
    required String contentId,
    Map<String, String> headers = const {},
    Uri? artworkUrl,
    Duration? duration,
    Duration position = Duration.zero,
    bool autoplay = true,
  }) async {
    final loadGeneration = ++_loadGeneration;
    final device = _selected;
    if (device == null) throw StateError('No connected receiver.');
    final generation = _connectionGeneration;
    final address = device.address == null
        ? null
        : InternetAddress.tryParse(device.address!);
    Uri relayUrl;
    var direct = false;
    if (source.scheme == 'file') {
      relayUrl = await _relay.startForFile(
        path: source.toFilePath(),
        contentType: mimeType,
        receiverAddress: address,
      );
    } else if (source.scheme == 'http' || source.scheme == 'https') {
      direct =
          preferDirectRemote &&
          device.protocol == CastProtocol.googleCast &&
          headers.isEmpty &&
          source.scheme == 'https' &&
          source.host != 'localhost' &&
          InternetAddress.tryParse(source.host)?.isLoopback != true;
      relayUrl = direct
          ? source
          : await _relay.startForRemote(
              source: source,
              headers: headers,
              contentType: mimeType,
              receiverAddress: address,
            );
    } else {
      throw UnsupportedError('This source cannot be accessed by a receiver.');
    }
    if (_disposed ||
        generation != _connectionGeneration ||
        loadGeneration != _loadGeneration) {
      throw StateError('Cast load was cancelled.');
    }
    _contentId = contentId;
    _emit(status: CastPlaybackStatus.loading, position: position);
    if (device.protocol == CastProtocol.googleCast) {
      Future<void> send(Uri url) => _native
          .load(
            url: url,
            mimeType: mimeType,
            title: title,
            artist: artist,
            contentId: contentId,
            artworkUrl: artworkUrl,
            duration: duration,
            position: position,
            autoplay: autoplay,
          )
          .timeout(const Duration(seconds: 20));
      try {
        await send(relayUrl);
      } catch (_) {
        if (!direct ||
            _disposed ||
            generation != _connectionGeneration ||
            loadGeneration != _loadGeneration) {
          rethrow;
        }
        // Direct CDN playback avoids forwarding bytes and survives iOS
        // suspension. Retry signed-source rejection with a bounded relay.
        relayUrl = await _relay.startForRemote(
          source: source,
          headers: headers,
          contentType: mimeType,
          receiverAddress: address,
        );
        if (_disposed ||
            generation != _connectionGeneration ||
            loadGeneration != _loadGeneration) {
          throw StateError('Cast load was cancelled.');
        }
        await send(relayUrl);
      }
    } else {
      await _dlna
          .load(
            url: relayUrl,
            mimeType: mimeType,
            title: title,
            artist: artist,
            artworkUrl: artworkUrl,
            position: position,
            autoplay: autoplay,
          )
          .timeout(const Duration(seconds: 20));
    }
    if (_disposed ||
        generation != _connectionGeneration ||
        loadGeneration != _loadGeneration) {
      throw StateError('Cast load was cancelled.');
    }
    _emit(
      status: autoplay ? CastPlaybackStatus.playing : CastPlaybackStatus.paused,
      position: position,
      duration: duration,
    );
  }

  bool get _isGoogle => _selected?.protocol == CastProtocol.googleCast;
  Future<void> play() => _isGoogle ? _native.play() : _dlna.play();
  Future<void> pause() => _isGoogle ? _native.pause() : _dlna.pause();
  Future<void> stop() async {
    ++_loadGeneration;
    if (_selected == null) return;
    if (_isGoogle) {
      await _native.stop();
    } else {
      await _dlna.stop();
    }
    _contentId = null;
    await _relay.stop();
    _emit(status: CastPlaybackStatus.idle, position: Duration.zero);
  }

  Future<void> seek(Duration position) =>
      _isGoogle ? _native.seek(position) : _dlna.seek(position);
  Future<void> setVolume(double volume) =>
      _isGoogle ? _native.setVolume(volume) : _dlna.setVolume(volume);

  Future<void> disconnect() async {
    ++_connectionGeneration;
    ++_loadGeneration;
    final previous = _selected;
    _selected = null;
    _contentId = null;
    try {
      if (previous?.protocol == CastProtocol.dlna) {
        await _dlna.disconnect();
      } else {
        await _native.disconnect();
      }
    } finally {
      await _relay.stop();
      _emit(status: CastPlaybackStatus.idle, position: Duration.zero);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    await stopDiscovery();
    _disposed = true;
    await _nativeSubscription.cancel();
    await _dlnaSubscription.cancel();
    await _native.dispose();
    await _dlna.dispose();
    await _relay.dispose();
    await _changes.close();
  }
}
